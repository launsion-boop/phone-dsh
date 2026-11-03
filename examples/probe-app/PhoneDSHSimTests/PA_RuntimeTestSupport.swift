// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import ProbeKit
import PhoneDSH
import PhoneDSHAgentCore

struct PA_RuntimeTransportReply {
    let events: [AnthropicStreamEvent]
    let error: Error?

    init(events: [AnthropicStreamEvent], error: Error? = nil) {
        self.events = events
        self.error = error
    }
}

final class PA_RuntimeScriptedTransport: AnthropicMessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [PA_RuntimeTransportReply]
    private(set) var requests: [AnthropicMessagesRequest] = []

    init(replies: [PA_RuntimeTransportReply]) {
        self.replies = replies
    }

    func stream(_ request: AnthropicMessagesRequest)
    -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                guard let reply else {
                    continuation.finish(throwing: MainFailure.invalidResponse("no scripted response"))
                    return
                }
                for event in reply.events {
                    if Task.isCancelled {
                        continuation.finish(throwing: MainFailure.cancelled)
                        return
                    }
                    continuation.yield(event)
                }
                continuation.finish(throwing: reply.error)
            }
        }
    }
}

struct PA_RuntimeToolCall {
    let name: String
    let argumentsJSON: String
    let mandateID: UUID?
}

final class PA_RuntimeToolInvoker: ConnectorToolInvoker, @unchecked Sendable {
    let descriptors: [ConnectorToolDescriptor]
    private let lock = NSLock()
    private(set) var calls: [PA_RuntimeToolCall] = []
    private let handler: @Sendable (String, String) async -> ToolInvocationResult

    init(descriptors: [ConnectorToolDescriptor],
         handler: @escaping @Sendable (String, String) async -> ToolInvocationResult = { _, _ in
             ToolInvocationResult(toolCallID: "", contentJSON: "{\"ok\":true}")
         }) {
        self.descriptors = descriptors
        self.handler = handler
    }

    func invoke(_ name: String, argumentsJSON: String,
                caller: ToolCaller) async -> ToolInvocationResult {
        let mandateID: UUID?
        if case .personalAgent(let mandate) = caller {
            mandateID = mandate.mandateID
        } else {
            mandateID = nil
        }
        lock.lock()
        calls.append(PA_RuntimeToolCall(name: name, argumentsJSON: argumentsJSON, mandateID: mandateID))
        lock.unlock()
        return await handler(name, argumentsJSON)
    }
}

struct PA_RuntimeFixedResolver: MainModelClientResolving {
    let transport: any AnthropicMessagesTransport
    let model: String
    let maxTokens: Int

    init(transport: any AnthropicMessagesTransport, model: String = "test-model", maxTokens: Int = 2_048) {
        self.transport = transport
        self.model = model
        self.maxTokens = maxTokens
    }

    func resolveClient() throws -> (client: any AnthropicMessagesTransport, model: String, maxTokens: Int) {
        (transport, model, maxTokens)
    }
}

struct PA_RuntimeFailingResolver: MainModelClientResolving {
    let failure: MainFailure

    func resolveClient() throws -> (client: any AnthropicMessagesTransport, model: String, maxTokens: Int) {
        throw failure
    }
}

final class PA_RuntimeSecretStore: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock()
        values[reference] = secret
        lock.unlock()
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        values[reference] = nil
        lock.unlock()
    }
}

func pa_runtimeDescriptor(_ name: String = "github.pull.get", summary: String = "正在查看 GitHub")
-> ConnectorToolDescriptor {
    ConnectorToolDescriptor(internalName: name, connectorID: name.split(separator: ".").first.map(String.init) ?? "test",
                            effect: .read, inputSchemaJSON: "{\"type\":\"object\"}", summary: summary)
}

func pa_runtimeMandate(repository: String = "owner/repo") -> WorkMandate {
    WorkMandate(mandateID: UUID(), version: 1, requestID: UUID(), principal: "person",
                source: .phone, goal: "inspect the current task", allowedActions: [.read],
                allowedEvidenceRefs: [], targets: MandateTargets(
                    gmailThreadIDs: ["thread-target-42"], recipientIdentities: ["person@example.com"],
                    repository: repository, issueOrPRNumbers: [42], origin: .userNamed),
                validUntil: Date().addingTimeInterval(3_600))
}

func pa_runtimeTurn(mandate: WorkMandate? = pa_runtimeMandate(), text: String = "inspect") -> MainTurnInput {
    MainTurnInput(requestID: UUID(), principal: "person", conversationID: UUID(), text: text, mandate: mandate)
}

func pa_runtimeTextResponse(_ text: String) -> PA_RuntimeTransportReply {
    PA_RuntimeTransportReply(events: [
        .messageStart,
        .textDelta(index: 0, text: text),
        .contentBlockStop(index: 0),
        .messageDelta(stopReason: "end_turn"),
        .messageStop,
    ])
}

func pa_runtimeToolResponse(id: String = "toolu_1", name: String = "github_pull_get",
                            inputJSON: String = "{\"number\":42}", index: Int = 0)
-> PA_RuntimeTransportReply {
    let split = max(0, inputJSON.count / 2)
    let midpoint = inputJSON.index(inputJSON.startIndex, offsetBy: split)
    return PA_RuntimeTransportReply(events: [
        .messageStart,
        .toolUseStart(index: index, id: id, name: name, inputJSON: "{}"),
        .toolInputDelta(index: index, partialJSON: String(inputJSON[..<midpoint])),
        .toolInputDelta(index: index, partialJSON: String(inputJSON[midpoint...])),
        .contentBlockStop(index: index),
        .messageDelta(stopReason: "tool_use"),
        .messageStop,
    ])
}

func pa_runtimeCollect(_ stream: AsyncThrowingStream<MainEvent, Error>) async throws -> [MainEvent] {
    var events: [MainEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

func pa_runtimeFailure(_ events: [MainEvent]) -> MainFailure? {
    for event in events {
        if case .failed(let failure) = event { return failure }
    }
    return nil
}

func pa_runtimeCompletedText(_ events: [MainEvent]) -> String? {
    for event in events {
        if case .completed(let message) = event { return message.text }
    }
    return nil
}

func pa_runtimeWait(timeout: TimeInterval = 5, condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("condition did not become true within \(timeout) seconds")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
