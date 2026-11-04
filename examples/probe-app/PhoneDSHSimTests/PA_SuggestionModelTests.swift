// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

@MainActor
final class PA_SuggestionModelTests: XCTestCase {
    func testEmptySuggestionsDoNotShowACard() async throws {
        let fixture = try await makeFixture(results: [.none])
        await fixture.model.send("只是回答这个问题")
        try await settle()
        XCTAssertNil(fixture.model.suggestion)
        XCTAssertEqual(fixture.agent.inputs, ["只是回答这个问题"])
    }

    func testChoosingSuggestionStartsARealTurnAndIsNotDismissal() async throws {
        let fixture = try await makeFixture(results: [
            .card(makeCard(options: [
                SuggestionOption(id: "blockers", label: "查看这个 PR 的新阻塞",
                                 userRequest: "请评论 owner/repo #29：Approved"),
                SuggestionOption(id: "reply", label: "整理成简短邮件", userRequest: "整理成简短邮件"),
            ])), .none,
        ])
        await fixture.model.send("分析当前 PR")
        try await settle()
        let suggestion = try XCTUnwrap(fixture.model.suggestion)
        await fixture.model.chooseSuggestion(suggestion.options[0])
        try await settle()
        XCTAssertEqual(fixture.agent.inputs, ["分析当前 PR", "查看这个 PR 的新阻塞"])
        XCTAssertEqual(fixture.agent.inputs.last, suggestion.options[0].label)
        XCTAssertNil(fixture.model.suggestion)
        let outcome = await fixture.store.outcome(cardID: suggestion.cardID)
        XCTAssertEqual(outcome, .selected)

        let restored = try await fixture.makeModel()
        await restored.load()
        XCTAssertNil(restored.suggestion)
    }

    func testManualDismissPersistsWithoutStartingAnotherTurn() async throws {
        let fixture = try await makeFixture(results: [
            .card(makeCard(options: [
                SuggestionOption(id: "continue", label: "继续处理后续任务", userRequest: "继续处理后续任务"),
            ])),
        ])
        await fixture.model.send("先完成当前任务")
        try await settle()
        let suggestion = try XCTUnwrap(fixture.model.suggestion)
        await fixture.model.dismissSuggestion()
        XCTAssertNil(fixture.model.suggestion)
        XCTAssertEqual(fixture.agent.inputs, ["先完成当前任务"])
        let outcome = await fixture.store.outcome(cardID: suggestion.cardID)
        XCTAssertEqual(outcome, .dismissed)

        let restored = try await fixture.makeModel()
        await restored.load()
        XCTAssertNil(restored.suggestion)
    }

    func testDeclineIsPersistedSeparatelyFromDismissal() async throws {
        let fixture = try await makeFixture(results: [
            .card(makeCard(options: [
                SuggestionOption(id: "continue", label: "继续处理后续任务", userRequest: "继续处理后续任务"),
            ])),
        ])
        await fixture.model.send("先完成当前任务")
        try await settle()
        let suggestion = try XCTUnwrap(fixture.model.suggestion)
        await fixture.model.declineSuggestion()
        let outcome = await fixture.store.outcome(cardID: suggestion.cardID)
        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(fixture.agent.inputs, ["先完成当前任务"])
    }

    func testClarificationSelectionUsesPendingQuestionAndSelectedOutcome() async throws {
        let fixture = try await makeFixture(results: [
            .card(makeCard(kind: .clarification, options: [
                SuggestionOption(id: "a", label: "选择 A", userRequest: "按 A 方案继续，但不要发送"),
                SuggestionOption(id: "b", label: "选择 B", userRequest: "按 B 方案继续"),
            ])),
        ])
        await fixture.model.send("需要先确认方案")
        try await settle()
        let question = try XCTUnwrap(fixture.model.pendingQuestion)
        XCTAssertNil(fixture.model.suggestion)
        await fixture.model.answerPendingQuestion("选择 A")
        XCTAssertEqual(fixture.agent.inputs, ["需要先确认方案", "选择 A"])
        let outcome = await fixture.store.outcome(cardID: question.id)
        XCTAssertEqual(outcome, .selected)
        let turns = try await fixture.conversations.turns(conversationID: fixture.model.conversationID)
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.allSatisfy { $0.state == .completed })
    }

    func testClosingClarificationLeavesTaskSafelyPausedWithoutGuessing() async throws {
        let fixture = try await makeFixture(results: [
            .card(makeCard(kind: .clarification, options: [
                SuggestionOption(id: "a", label: "选择 A", userRequest: "按 A 方案继续"),
            ])),
        ])
        await fixture.model.send("需要先确认方案")
        try await settle()
        let question = try XCTUnwrap(fixture.model.pendingQuestion)
        await fixture.model.dismissPendingQuestion()
        XCTAssertNil(fixture.model.pendingQuestion)
        XCTAssertEqual(fixture.agent.inputs, ["需要先确认方案"])
        let outcome = await fixture.store.outcome(cardID: question.id)
        XCTAssertEqual(outcome, .dismissed)
        let turns = try await fixture.conversations.turns(conversationID: fixture.model.conversationID)
        XCTAssertEqual(turns.last?.state, .interrupted)
    }

    private func settle() async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFixture(results: [SuggestionGenerationResult]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-SuggestionModel-\(UUID().uuidString)")
        let domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let agent = PA_SuggestionMainAgent()
        let generator = PA_SuggestionGenerator(results: results)
        let store = SuggestionStore(rootDirectory: root)
        let conversations = ConversationStore(domain: domain)
        let model = PersonalAgentModel(conversationID: UUID(), principal: "owner", agent: agent,
                                       conversations: conversations, memories: MemoryStore(domain: domain),
                                       followUps: FollowUpStore(domain: domain),
                                       suggestionGenerator: generator, suggestionStore: store)
        await model.load()
        return Fixture(model: model, agent: agent, store: store, conversations: conversations,
                       makeModel: {
                           PersonalAgentModel(conversationID: model.conversationID, principal: "owner",
                                              agent: agent, conversations: conversations,
                                              memories: MemoryStore(domain: domain),
                                              followUps: FollowUpStore(domain: domain),
                                              suggestionGenerator: generator, suggestionStore: store)
                       })
    }

    private func makeCard(kind: SuggestionKind = .nextSteps, options: [SuggestionOption]) -> SuggestionCard {
        let turnID = UUID()
        return SuggestionCard(conversationID: turnID, turnID: turnID, principal: "owner", accountID: "local",
                              suppressionKeys: [SuggestionSuppressionKey(action: options[0].id,
                                                                        target: "conversation")],
                              kind: kind, question: "接下来可以做什么？", options: options,
                              allowCustom: true, dismissOnMoveOn: kind == .nextSteps)
    }

    private struct Fixture {
        let model: PersonalAgentModel
        let agent: PA_SuggestionMainAgent
        let store: SuggestionStore
        let conversations: ConversationStore
        let makeModel: () -> PersonalAgentModel
    }
}

private final class PA_SuggestionMainAgent: MainAgentPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var inputs: [String] = []

    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        lock.lock()
        inputs.append(turn.text)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(AssistantMessage(text: "本轮回答：\(turn.text)")))
            continuation.finish()
        }
    }

    func cancel(turnID: UUID) async {}
}

private final class PA_SuggestionGenerator: StructuredSuggestionGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SuggestionGenerationResult]

    init(results: [SuggestionGenerationResult]) { self.results = results }

    func generateCard(turn: MainTurnInput, answer: AssistantMessage,
                      metadata: SuggestionHostMetadata) async -> SuggestionGenerationResult {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { return .none }
        switch results.removeFirst() {
        case .none, .suppressed:
            return .none
        case .card(let card):
            return .card(SuggestionCard(
                schemaVersion: card.schemaVersion, cardID: card.cardID,
                conversationID: turn.conversationID, turnID: turn.turnID,
                principal: turn.principal, accountID: card.accountID,
                createdAt: card.createdAt, expiresAt: card.expiresAt,
                suppressionKeys: card.suppressionKeys, kind: card.kind,
                question: card.question, options: card.options,
                allowCustom: card.allowCustom, dismissOnMoveOn: card.dismissOnMoveOn,
                multiSelect: card.multiSelect, outcome: card.outcome))
        }
    }
}
