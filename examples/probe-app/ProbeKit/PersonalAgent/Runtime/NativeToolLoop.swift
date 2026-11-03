// SPDX-License-Identifier: MIT

import Foundation

public struct NativeToolLoopConfiguration: Sendable, Equatable {
    public let maximumToolCalls: Int
    public let maximumToolResultBytes: Int

    public init(maximumToolCalls: Int = 8, maximumToolResultBytes: Int = 32 * 1024) {
        self.maximumToolCalls = max(1, maximumToolCalls)
        self.maximumToolResultBytes = max(1_024, maximumToolResultBytes)
    }
}

public enum MainToolResultTruncator {
    public static func truncate(_ result: ToolInvocationResult,
                                maximumBytes: Int) -> ToolInvocationResult {
        let content = result.contentJSON
        guard content.utf8.count > maximumBytes else { return result }
        let marker = "\n…[tool result truncated]"
        let prefixLimit = max(0, maximumBytes - marker.utf8.count - 256)
        var prefix = ""
        var used = 0
        for scalar in content.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > prefixLimit { break }
            prefix.unicodeScalars.append(scalar)
            used += size
        }
        let object: [String: Any] = [
            "truncated": true,
            "originalBytes": content.utf8.count,
            "content": prefix + marker,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let bounded = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"truncated\":true}"
        return ToolInvocationResult(toolCallID: result.toolCallID,
                                    contentJSON: bounded, isError: result.isError)
    }
}

public struct NativeToolLoop: Sendable {
    private let invoker: any ConnectorToolInvoker
    private let codec: ToolNameCodec
    private let configuration: NativeToolLoopConfiguration
    private let adapter = AnthropicMessagesAdapter()

    public init(invoker: any ConnectorToolInvoker, codec: ToolNameCodec,
                configuration: NativeToolLoopConfiguration = NativeToolLoopConfiguration()) {
        self.invoker = invoker
        self.codec = codec
        self.configuration = configuration
    }

    func run(client: any AnthropicMessagesTransport, model: String, maxTokens: Int,
             context: MainAssembledContext, mandate: WorkMandate?,
             telemetry: MainTurnLatencyTracker,
             isCancelled: @escaping @Sendable () -> Bool,
             emit: @escaping @Sendable (MainEvent) -> Void) async throws -> AssistantMessage {
        var messages = context.messages
        var responseText = ""
        var toolCallCount = 0
        let tools = codec.anthropicTools
        while true {
            try Self.checkCancellation(isCancelled)
            let request = adapter.makeRequest(model: model,
                                              context: MainAssembledContext(
                                                systemPrompt: context.systemPrompt,
                                                messages: messages,
                                                estimatedTokens: context.estimatedTokens,
                                                tokenEstimationMethod: context.tokenEstimationMethod,
                                                recentMessages: context.recentMessages,
                                                rollingSummary: context.rollingSummary),
                                              tools: tools, maxTokens: maxTokens)
            telemetry.markRequest()
            var accumulator = AnthropicResponseAccumulator()
            do {
                for try await event in client.stream(request) {
                    try Self.checkCancellation(isCancelled)
                    if case .textDelta(_, let text) = event {
                        telemetry.markText()
                        emit(.textDelta(text))
                    }
                    try accumulator.apply(event)
                }
            } catch is CancellationError {
                throw MainFailure.cancelled
            } catch {
                if isCancelled() || Task.isCancelled { throw MainFailure.cancelled }
                throw error
            }
            try accumulator.validated()
            responseText += accumulator.text
            let toolUses = accumulator.toolUses
            if toolUses.isEmpty {
                guard accumulator.stopReason != "tool_use" else {
                    throw MainFailure.invalidResponse("stop_reason is tool_use but no tool_use block exists")
                }
                return AssistantMessage(text: responseText)
            }
            guard accumulator.stopReason == "tool_use" else {
                throw MainFailure.invalidResponse("tool_use response did not end with stop_reason=tool_use")
            }
            messages.append(accumulator.assistantMessage())
            var results: [AnthropicContentBlock] = []
            for toolUse in toolUses {
                try Self.checkCancellation(isCancelled)
                toolCallCount += 1
                if toolCallCount > configuration.maximumToolCalls {
                    emit(.status(StatusLine(text: "工具调用已达本回合上限，请缩小任务后重试", phase: .reading)))
                    throw MainFailure.toolLimitExceeded
                }
                let internalName: String
                do {
                    internalName = try codec.internalName(forModelName: toolUse.name)
                } catch {
                    let result = Self.errorResult(toolCallID: toolUse.id, code: "unknown_tool",
                                                  message: "the requested tool is not registered")
                    emit(.status(StatusLine(text: "模型请求了不可用工具", phase: .reading)))
                    emit(.toolResult(result))
                    results.append(.toolResult(toolCallID: toolUse.id,
                                               content: result.contentJSON, isError: true))
                    continue
                }
                guard let mandate else {
                    throw MainFailure.invalidResponse("a tool call requires a current WorkMandate")
                }
                let invocation = ToolInvocation(id: toolUse.id, name: internalName,
                                                argumentsJSON: toolUse.inputJSON)
                emit(.toolCall(invocation))
                let descriptor = codec.descriptor(internalName: internalName)
                let phase: MainStatusPhase = descriptor?.effect == .read ? .reading : .writing
                emit(.status(StatusLine(text: descriptor?.summary ?? "正在调用工具", phase: phase)))
                let rawResult = await invoker.invoke(internalName,
                                                     argumentsJSON: toolUse.inputJSON,
                                                     caller: .personalAgent(mandate: mandate))
                try Self.checkCancellation(isCancelled)
                let result = MainToolResultTruncator.truncate(
                    ToolInvocationResult(toolCallID: toolUse.id,
                                         contentJSON: rawResult.contentJSON,
                                         isError: rawResult.isError),
                    maximumBytes: configuration.maximumToolResultBytes)
                emit(.toolResult(result))
                results.append(.toolResult(toolCallID: toolUse.id,
                                           content: result.contentJSON, isError: result.isError))
            }
            messages.append(AnthropicMessage(role: .user, content: results))
        }
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() || Task.isCancelled { throw MainFailure.cancelled }
    }

    private static func errorResult(toolCallID: String, code: String,
                                    message: String) -> ToolInvocationResult {
        let data = try? JSONSerialization.data(withJSONObject: ["error": code, "message": message],
                                               options: [.sortedKeys])
        return ToolInvocationResult(toolCallID: toolCallID,
                                    contentJSON: data.flatMap { String(data: $0, encoding: .utf8) }
                                        ?? "{\"error\":\"unknown_tool\"}",
                                    isError: true)
    }
}
