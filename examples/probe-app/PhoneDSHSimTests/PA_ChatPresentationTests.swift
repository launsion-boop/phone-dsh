// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

@MainActor
final class PA_ChatPresentationTests: XCTestCase {
    func testStatusIsTransientAndCompletedAnswerReplacesItWithoutTechnicalContent() async throws {
        let fixture = try await makeModel(events: [
            .status(StatusLine(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                               text: "正在查看 Gmail", phase: .reading)),
            .status(StatusLine(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                               text: "正在整理结果", phase: .reading)),
            .toolCall(ToolInvocation(id: "call-1", name: "gmail.search", argumentsJSON: "{\"secret\":true}")),
            .toolResult(ToolInvocationResult(toolCallID: "call-1", contentJSON: "{\"raw\":\"bash\"}")),
            .textDelta("结论。"),
            .completed(AssistantMessage(text: """
            <thinking>隐藏推理</thinking>已总结 12 封邮件。
            ```bash
            rm -rf example
            ```
            {"rawTool":true}
            TaskRun ID: 123e4567-e89b-12d3-a456-426614174000
            """)),
        ])
        await fixture.model.send("总结邮件")
        XCTAssertNil(fixture.model.activeStatus)
        XCTAssertTrue(fixture.model.streamingText.isEmpty)
        XCTAssertEqual(fixture.model.messages.filter { $0.role == .assistant }.count, 1)
        let visible = fixture.model.messages.filter { $0.role == .assistant }.map(\.text).joined()
        XCTAssertTrue(visible.contains("已总结 12 封邮件"))
        for forbidden in ["thinking", "隐藏推理", "bash", "rm -rf", "rawTool", "TaskRun", "gmail.search", "secret"] {
            XCTAssertFalse(visible.contains(forbidden), "不应展示 \(forbidden)")
        }
        let turns = try await fixture.conversations.turns(conversationID: fixture.model.conversationID)
        XCTAssertEqual(turns.first?.state, .completed)
        XCTAssertNil(turns.first?.terminalStatus)
    }

    func testQuestionChoicesFailureAndConcisePromptStayMinimal() async throws {
        let question = PendingQuestion(text: "选择要处理的 PR", choices: ["PR #1", "PR #2"])
        let fixture = try await makeModel(events: [.question(question)])
        await fixture.model.send("处理 PR")
        XCTAssertEqual(fixture.model.pendingQuestion, question)
        let persistedQuestions = try await fixture.conversations.pendingQuestions(
            conversationID: fixture.model.conversationID)
        XCTAssertEqual(persistedQuestions, [question])
        let restored = PersonalAgentModel(conversationID: fixture.model.conversationID, principal: "owner",
                                          agent: PA_MainAgentPort(events: []), conversations: fixture.conversations,
                                          memories: MemoryStore(domain: fixture.domain),
                                          followUps: FollowUpStore(domain: fixture.domain))
        await restored.load()
        XCTAssertEqual(restored.pendingQuestion, question)
        XCTAssertTrue(PersonalAgentTextPolicy.conciseSystemPrompt.contains("1–3 个短句"))
        XCTAssertEqual(PersonalAgentTextPolicy.failureText(.provider("{\"token\":\"bad\"}")),
                       "模型服务暂时不可用，请稍后重试。")
    }

    func testRunningStatusAndQueuedMessageRemainVisibleUntilCompletion() async throws {
        let domain = try SQLiteDomainStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-ChatQueue-\(UUID().uuidString)/domain.sqlite"))
        let conversations = ConversationStore(domain: domain)
        let agent = PA_ControlledMainAgentPort()
        let model = PersonalAgentModel(conversationID: UUID(), principal: "owner", agent: agent,
                                       conversations: conversations, memories: MemoryStore(domain: domain),
                                       followUps: FollowUpStore(domain: domain))
        await model.load()
        let first = Task { await model.send("第一条") }
        for _ in 0..<1_000 where agent.continuationCount == 0 || model.activeStatus?.text != "正在处理第一条" {
            await Task.yield()
        }
        guard agent.continuationCount == 1 else {
            XCTFail("第一条回合未开始")
            agent.completeFirst()
            await first.value
            return
        }
        XCTAssertEqual(model.activeStatus?.text, "正在处理第一条")
        await model.send("第二条")
        XCTAssertEqual(model.queuedTurns.map(\.text), ["第二条"])
        agent.completeFirst()
        await first.value
        XCTAssertNil(model.activeStatus)
        XCTAssertTrue(model.queuedTurns.isEmpty)
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.map(\.text), ["第一条完成", "第二条完成"])
    }

    func testDailyBriefArtifactRequiresRealChanges() {
        let snapshot = DailyBriefSnapshot(id: "brief-1", createdAt: Date(), items: [
            DailyBriefItem(id: "item", sourceID: "source", sourceName: "来源", title: "真实更新",
                           summary: "", link: nil, publishedAt: nil),
        ])
        XCTAssertNil(DailyBriefChatArtifact.make(snapshot: snapshot, newItemCount: 0))
        XCTAssertEqual(DailyBriefChatArtifact.make(snapshot: snapshot, newItemCount: 1)?.kind, "dailyBrief")
    }

    private func makeModel(events: [MainEvent]) async throws ->
    (model: PersonalAgentModel, conversations: ConversationStore, domain: SQLiteDomainStore) {
        let domain = try SQLiteDomainStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-Chat-\(UUID().uuidString)/domain.sqlite"))
        let conversations = ConversationStore(domain: domain)
        let memories = MemoryStore(domain: domain)
        let followUps = FollowUpStore(domain: domain)
        try await conversations.prepare()
        try await memories.prepare()
        try await followUps.prepare()
        let model = PersonalAgentModel(conversationID: UUID(), principal: "owner",
                                       agent: PA_MainAgentPort(events: events), conversations: conversations,
                                       memories: memories, followUps: followUps)
        await model.load()
        return (model, conversations, domain)
    }
}

private final class PA_ControlledMainAgentPort: MainAgentPort, @unchecked Sendable {
    private let lock = NSLock()
    private var firstContinuation: AsyncThrowingStream<MainEvent, Error>.Continuation?
    private var calls = 0
    var continuationCount: Int { lock.lock(); defer { lock.unlock() }; return firstContinuation == nil ? 0 : 1 }

    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        lock.lock()
        calls += 1
        let isFirst = calls == 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if isFirst {
                lock.lock()
                firstContinuation = continuation
                lock.unlock()
                continuation.yield(.status(StatusLine(text: "正在处理第一条", phase: .reading)))
            } else {
                continuation.yield(.completed(AssistantMessage(text: "第二条完成")))
                continuation.finish()
            }
        }
    }

    func completeFirst() {
        lock.lock()
        let continuation = firstContinuation
        firstContinuation = nil
        lock.unlock()
        continuation?.yield(.completed(AssistantMessage(text: "第一条完成")))
        continuation?.finish()
    }

    func cancel(turnID: UUID) async {}
}

private final class PA_MainAgentPort: MainAgentPort, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MainEvent]

    init(events: [MainEvent]) { self.events = events }

    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        lock.lock()
        let events = self.events
        self.events = []
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(turnID: UUID) async {}
}
