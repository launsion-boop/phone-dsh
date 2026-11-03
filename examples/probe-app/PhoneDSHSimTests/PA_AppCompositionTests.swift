// SPDX-License-Identifier: MIT

@testable import PhoneDSHProbe
@testable import ProbeKit
import XCTest

final class PA_AppCompositionTests: XCTestCase {
    @MainActor
    func testCompositionSharesConnectorsButKeepsDSHReadOnly() throws {
        let composition = try AppComposition(root: temporaryRoot())
        XCTAssertTrue(composition.dshToolBridge.handles.contains("github.pull.get"))
        XCTAssertTrue(composition.dshToolBridge.handles.contains("gmail.search"))
        XCTAssertFalse(composition.dshToolBridge.handles.contains("github.issue.comment"))
        XCTAssertFalse(composition.dshToolBridge.handles.contains("gmail.message.send"))
        XCTAssertTrue(composition.connectorTools.descriptors.contains { $0.internalName == "github.issue.comment" })
        XCTAssertTrue(composition.connectorTools.descriptors.contains { $0.internalName == "gmail.message.send" })
    }

    func testContextIncludesPriorConversationAndMemoryButNotCurrentTurnTwice() async throws {
        let domain = try SQLiteDomainStore(fileURL: temporaryRoot().appendingPathComponent("domain.sqlite"))
        let conversations = ConversationStore(domain: domain)
        let memories = MemoryStore(domain: domain)
        let followUps = FollowUpStore(domain: domain)
        try await conversations.prepare()
        try await memories.prepare()
        try await followUps.prepare()
        let conversationID = UUID()
        let firstSource = SourceEnvelope(requestID: UUID(), principal: "owner", source: .phone,
                                         replyTo: .phoneChat, grantVersion: 0, receivedAt: Date())
        let first = try await conversations.enqueue(text: "上周先处理 A", source: firstSource,
                                                   conversationID: conversationID)
        try await conversations.complete(first, message: AssistantMessage(text: "好的"))
        let currentSource = SourceEnvelope(requestID: UUID(), principal: "owner", source: .phone,
                                           replyTo: .phoneChat, grantVersion: 0, receivedAt: Date())
        let current = try await conversations.enqueue(text: "现在继续", source: currentSource,
                                                     conversationID: conversationID)
        _ = try await memories.ingestUserInstruction(
            "记住：回答保持简短", principal: "owner",
            source: MemorySource(kind: .phone, reference: "test", detail: "test"))
        let provider = PersonalAgentContextProvider(conversations: conversations, memories: memories,
                                                    followUps: followUps,
                                                    operations: try FileOperationLedger(root: temporaryRoot()))
        let snapshot = try await provider.snapshot(for: current.input)
        XCTAssertEqual(snapshot.currentText, "现在继续")
        XCTAssertEqual(snapshot.messages.map(\.text), ["上周先处理 A", "好的"])
        XCTAssertEqual(snapshot.memory.map(\.text), ["回答保持简短"])
        XCTAssertTrue(snapshot.responseStylePrompt.contains("结论先行"))
    }

    @MainActor
    func testChatTurnCarriesPersistedMandateIntoNativeRuntime() async throws {
        let root = temporaryRoot()
        let domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let conversations = ConversationStore(domain: domain)
        let agent = PA_CapturingMainAgent()
        let model = PersonalAgentModel(conversationID: UUID(), principal: "owner", agent: agent,
                                       conversations: conversations, memories: MemoryStore(domain: domain),
                                       followUps: FollowUpStore(domain: domain),
                                       operations: try FileOperationLedger(root: root),
                                       ingress: try MainIngress(root: root))
        await model.load()
        await model.send("查看 deepseek-ai/dsh-superagent-prototype 的仓库状态")
        let turn = try XCTUnwrap(agent.capturedTurn())
        let mandate = try XCTUnwrap(turn.mandate)
        XCTAssertEqual(mandate.requestID, turn.requestID)
        XCTAssertEqual(mandate.targets.repository, "deepseek-ai/dsh-superagent-prototype")
        XCTAssertEqual(mandate.allowedActions, [.read])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PA-Composition-\(UUID().uuidString)")
    }
}

private final class PA_CapturingMainAgent: MainAgentPort, @unchecked Sendable {
    private let lock = NSLock()
    private var turn: MainTurnInput?

    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        lock.lock()
        self.turn = turn
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(AssistantMessage(text: "已完成")))
            continuation.finish()
        }
    }

    func cancel(turnID: UUID) async {}

    func capturedTurn() -> MainTurnInput? {
        lock.lock()
        defer { lock.unlock() }
        return turn
    }
}
