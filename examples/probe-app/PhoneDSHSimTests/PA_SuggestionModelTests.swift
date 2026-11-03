// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

@MainActor
final class PA_SuggestionModelTests: XCTestCase {
    func testEmptySuggestionsDoNotShowACard() async throws {
        let fixture = try await makeFixture(suggestionResults: [[]])
        await fixture.model.send("只是回答这个问题")
        try await settle()
        XCTAssertNil(fixture.model.suggestion)
        XCTAssertEqual(fixture.agent.inputs, ["只是回答这个问题"])
    }

    func testChoosingSuggestionStartsARealTurnAndDismissesItAcrossReload() async throws {
        let fixture = try await makeFixture(suggestionResults: [["查看这个 PR 的新阻塞", "整理成一封简短邮件"], []])
        await fixture.model.send("分析当前 PR")
        try await settle()
        let suggestion = try XCTUnwrap(fixture.model.suggestion)
        XCTAssertEqual(suggestion.options, ["查看这个 PR 的新阻塞", "整理成一封简短邮件"])

        await fixture.model.chooseSuggestion("查看这个 PR 的新阻塞")
        try await settle()
        XCTAssertEqual(fixture.agent.inputs, ["分析当前 PR", "查看这个 PR 的新阻塞"])
        XCTAssertNil(fixture.model.suggestion)

        let restored = try await fixture.makeModel()
        await restored.load()
        XCTAssertNil(restored.suggestion)
        let dismissed = await fixture.store.isDismissed(turnID: suggestion.turnID)
        XCTAssertTrue(dismissed)
    }

    func testManualDismissPersistsWithoutStartingAnotherTurn() async throws {
        let fixture = try await makeFixture(suggestionResults: [["继续处理后续任务"]])
        await fixture.model.send("先完成当前任务")
        try await settle()
        _ = try XCTUnwrap(fixture.model.suggestion)
        await fixture.model.dismissSuggestion()
        XCTAssertNil(fixture.model.suggestion)
        XCTAssertEqual(fixture.agent.inputs, ["先完成当前任务"])

        let restored = try await fixture.makeModel()
        await restored.load()
        XCTAssertNil(restored.suggestion)
    }

    private func settle() async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFixture(suggestionResults: [[String]]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-SuggestionModel-\(UUID().uuidString)")
        let domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let agent = PA_SuggestionMainAgent()
        let generator = PA_SuggestionGenerator(results: suggestionResults)
        let store = SuggestionStore(rootDirectory: root)
        let conversations = ConversationStore(domain: domain)
        let model = PersonalAgentModel(conversationID: UUID(), principal: "owner", agent: agent,
                                       conversations: conversations, memories: MemoryStore(domain: domain),
                                       followUps: FollowUpStore(domain: domain),
                                       suggestionGenerator: generator, suggestionStore: store)
        await model.load()
        return Fixture(model: model, agent: agent, store: store,
                       makeModel: {
                           PersonalAgentModel(conversationID: model.conversationID, principal: "owner",
                                              agent: agent, conversations: conversations,
                                              memories: MemoryStore(domain: domain),
                                              followUps: FollowUpStore(domain: domain),
                                              suggestionGenerator: generator, suggestionStore: store)
                       })
    }

    private struct Fixture {
        let model: PersonalAgentModel
        let agent: PA_SuggestionMainAgent
        let store: SuggestionStore
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

private final class PA_SuggestionGenerator: SuggestionGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String]]

    init(results: [[String]]) { self.results = results }

    func generate(turn: MainTurnInput, answer: AssistantMessage) async throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return results.isEmpty ? [] : results.removeFirst()
    }
}
