// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import ProbeKit
import PhoneDSH
import PhoneDSHHarness

final class PA_RuntimeToolLoopTests: XCTestCase {
    func testMockModelUpstreamSingleToolRoundTripAndLatency() async throws {
        let mock = MockModelUpstream()
        let mockURL = try mock.start()
        defer { mock.stop() }
        let suite = "PA_RuntimeToolLoopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = PA_RuntimeSecretStore()
        let settings = PhoneModelProviderSettings(defaults: defaults, secretStore: secrets, environment: [:])
        let profile = ProviderProfile(id: "mock-anthropic", displayName: "Mock Anthropic",
                                      baseURL: mockURL.absoluteString, model: "mock-model")
        try settings.upsert(profile, apiKey: "mock-test-key")
        let resolver = NativeMainGatewayClientProvider(settings: settings, responseLogRoot: nil)
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor("bash", summary: "正在读取文件")])
        let adapter = try NativeMainAgentAdapter(clientResolver: resolver, toolInvoker: invoker)
        let turn = pa_runtimeTurn()
        let events = try await pa_runtimeCollect(adapter.run(turn: turn))

        XCTAssertNil(pa_runtimeFailure(events))
        XCTAssertTrue(pa_runtimeCompletedText(events)?.contains("Done: a.txt contains hi.") == true)
        XCTAssertEqual(invoker.calls.map(\.name), ["bash"])
        XCTAssertEqual(invoker.calls.first?.mandateID, turn.mandate?.mandateID)
        XCTAssertEqual(mock.requestCount, 2)
        XCTAssertEqual(mock.requests.first?.apiKey, "mock-test-key")
        let secondBody = try XCTUnwrap(mock.requests.last?.body)
        XCTAssertTrue(MockModelUpstream.lastMessageHasToolResult(secondBody))
        let latency = await adapter.latencyRecorder.latency(for: turn.turnID)
        XCTAssertEqual(latency?.requestSentAt.count, 2)
        XCTAssertNotNil(latency?.firstTextDeltaAt)
        XCTAssertEqual(latency?.outcome, "completed")
    }

    func testMultipleToolsAreInvokedAndReturnedInOrder() async throws {
        let toolReply = PA_RuntimeTransportReply(events: [
            .messageStart,
            .toolUseStart(index: 0, id: "one", name: "github_pull_get", inputJSON: "{}"),
            .toolInputDelta(index: 0, partialJSON: "{\"number\":1}"),
            .contentBlockStop(index: 0),
            .toolUseStart(index: 1, id: "two", name: "gmail_thread_get", inputJSON: "{}"),
            .toolInputDelta(index: 1, partialJSON: "{\"id\":\"thread\"}"),
            .contentBlockStop(index: 1),
            .messageDelta(stopReason: "tool_use"), .messageStop,
        ])
        let transport = PA_RuntimeScriptedTransport(replies: [toolReply, pa_runtimeTextResponse("done")])
        let invoker = PA_RuntimeToolInvoker(descriptors: [
            pa_runtimeDescriptor(), pa_runtimeDescriptor("gmail.thread.get", summary: "正在查看 Gmail"),
        ])
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport),
                                                 toolInvoker: invoker)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn()))
        XCTAssertEqual(pa_runtimeCompletedText(events), "done")
        XCTAssertEqual(invoker.calls.map(\.name), ["github.pull.get", "gmail.thread.get"])
        let lastMessage = try XCTUnwrap(transport.requests.last?.messages.last)
        XCTAssertEqual(lastMessage.content.count, 2)
    }

    func testToolFailureIsBackfilledInsteadOfDropped() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeToolResponse(), pa_runtimeTextResponse("handled"),
        ])
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor()]) { _, _ in
            ToolInvocationResult(toolCallID: "", contentJSON: "{\"error\":\"denied\"}", isError: true)
        }
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport),
                                                 toolInvoker: invoker)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn()))
        XCTAssertEqual(pa_runtimeCompletedText(events), "handled")
        guard let block = transport.requests.last?.messages.last?.content.first,
              case .toolResult(_, let content, let isError) = block else {
            return XCTFail("missing tool_result")
        }
        XCTAssertTrue(isError)
        XCTAssertTrue(content.contains("denied"))
    }

    func testUnknownToolReturnsErrorWithoutInvokingConnector() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeToolResponse(name: "not_registered"), pa_runtimeTextResponse("recovered"),
        ])
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor()])
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport),
                                                 toolInvoker: invoker)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn()))
        XCTAssertEqual(pa_runtimeCompletedText(events), "recovered")
        XCTAssertTrue(invoker.calls.isEmpty)
        guard let block = transport.requests.last?.messages.last?.content.first,
              case .toolResult(_, _, let isError) = block else {
            return XCTFail("missing unknown-tool result")
        }
        XCTAssertTrue(isError)
    }

    func testToolLimitStopsBeforeAnotherSideEffect() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeToolResponse(id: "one"), pa_runtimeToolResponse(id: "two"),
            pa_runtimeToolResponse(id: "three"),
        ])
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor()])
        let adapter = try NativeMainAgentAdapter(
            clientResolver: PA_RuntimeFixedResolver(transport: transport), toolInvoker: invoker,
            toolConfiguration: NativeToolLoopConfiguration(maximumToolCalls: 2))
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn()))
        XCTAssertEqual(pa_runtimeFailure(events), .toolLimitExceeded)
        XCTAssertEqual(invoker.calls.count, 2)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testCancellationDuringToolExecutionEndsStream() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [pa_runtimeToolResponse()])
        let state = PA_RuntimeBlockingState()
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor()]) { _, _ in
            state.markStarted()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return ToolInvocationResult(toolCallID: "", contentJSON: "{}")
        }
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport),
                                                 toolInvoker: invoker)
        let turn = pa_runtimeTurn()
        let consumer = Task { try await pa_runtimeCollect(adapter.run(turn: turn)) }
        try await pa_runtimeWait { state.isStarted }
        await adapter.cancel(turnID: turn.turnID)
        let events = try await consumer.value
        XCTAssertEqual(pa_runtimeFailure(events), .cancelled)
        XCTAssertEqual(invoker.calls.count, 1)
        var latency: MainTurnLatency?
        for _ in 0..<100 where latency == nil {
            latency = await adapter.latencyRecorder.latency(for: turn.turnID)
            if latency == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(latency?.outcome, "cancelled")
    }

    func testQueuedTurnStartsOnlyAfterCancelledActiveTurnFinishes() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeToolResponse(), pa_runtimeTextResponse("second"),
        ])
        let state = PA_RuntimeBlockingState()
        let invoker = PA_RuntimeToolInvoker(descriptors: [pa_runtimeDescriptor()]) { _, _ in
            state.markStarted()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return ToolInvocationResult(toolCallID: "", contentJSON: "{}")
        }
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport),
                                                 toolInvoker: invoker)
        let first = pa_runtimeTurn()
        let second = pa_runtimeTurn(mandate: nil, text: "second")
        let firstConsumer = Task { try await pa_runtimeCollect(adapter.run(turn: first)) }
        let secondConsumer = Task { try await pa_runtimeCollect(adapter.run(turn: second)) }
        try await pa_runtimeWait { state.isStarted }
        XCTAssertEqual(transport.requests.count, 1)
        await adapter.cancel(turnID: first.turnID)
        _ = try await firstConsumer.value
        let secondEvents = try await secondConsumer.value
        XCTAssertEqual(pa_runtimeCompletedText(secondEvents), "second")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testToolResultTruncationIsMarked() {
        let result = ToolInvocationResult(toolCallID: "id", contentJSON: String(repeating: "界", count: 2_000))
        let truncated = MainToolResultTruncator.truncate(result, maximumBytes: 1_024)
        XCTAssertLessThanOrEqual(truncated.contentJSON.utf8.count, 1_024)
        XCTAssertTrue(truncated.contentJSON.contains("truncated"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(truncated.contentJSON.utf8)))
    }
}

private final class PA_RuntimeBlockingState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }
}
