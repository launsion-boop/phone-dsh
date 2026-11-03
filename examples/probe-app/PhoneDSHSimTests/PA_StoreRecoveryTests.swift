// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

final class PA_StoreRecoveryTests: XCTestCase {
    func testReopenReconstructsQueuedAndInterruptedTurnsAndRestoresSummary() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-StoreRecovery-\(UUID().uuidString)/domain.sqlite")
        let conversationID = UUID()
        let firstID: UUID
        let secondID: UUID
        do {
            let domain = try SQLiteDomainStore(fileURL: url)
            let store = ConversationStore(domain: domain)
            try await store.prepare()
            let first = try await store.enqueue(text: "第一周先处理 A", source: source(), conversationID: conversationID)
            let second = try await store.enqueue(text: "B 暂停", source: source(), conversationID: conversationID)
            firstID = first.id
            secondID = second.id
            try await store.markRunning(first.id)
            try await store.recordStatus(StatusLine(text: "正在读取", phase: .reading), turnID: first.id)
            let messages = try await store.messages(conversationID: conversationID)
            let summary = ConversationSummary(conversationID: conversationID,
                                              coveredRange: messages[0].sequence...messages[0].sequence,
                                              revision: 1, sourceCursor: messages[0].sequence,
                                              text: "当前重点是 A，B 暂停；保留用户限制。")
            try await store.saveSummary(summary)
        }

        let reopened = ConversationStore(domain: try SQLiteDomainStore(fileURL: url))
        try await reopened.prepare()
        let recovery = try await reopened.recover(conversationID: conversationID)
        XCTAssertEqual(recovery.queuedTurns.map(\.id), [secondID])
        XCTAssertEqual(recovery.interruptedTurns.map(\.id), [firstID])
        let interrupted = try await reopened.turn(firstID)
        XCTAssertEqual(interrupted?.state, .interrupted)
        XCTAssertNil(interrupted?.terminalStatus)
        XCTAssertTrue(interrupted?.failure?.contains("未自动重放") == true)
        let restoredSummary = try await reopened.latestSummary(conversationID: conversationID)
        XCTAssertEqual(restoredSummary?.text, "当前重点是 A，B 暂停；保留用户限制。")
        let restoredMessages = try await reopened.messages(conversationID: conversationID)
        XCTAssertEqual(restoredMessages.map(\.text), ["第一周先处理 A", "B 暂停"])
    }

    func testPendingQuestionAndPaginationSurviveReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-QuestionRecovery-\(UUID().uuidString)/domain.sqlite")
        let conversationID = UUID()
        let turnID: UUID
        let question = PendingQuestion(text: "要处理哪一个项目？", choices: ["A", "B"])
        do {
            let domain = try SQLiteDomainStore(fileURL: url)
            let store = ConversationStore(domain: domain)
            try await store.prepare()
            let turn = try await store.enqueue(text: "处理项目", source: source(), conversationID: conversationID)
            turnID = turn.id
            try await store.recordQuestion(question, turnID: turn.id)
            _ = try await store.enqueue(text: "下一条", source: source(), conversationID: conversationID)
        }
        let store = ConversationStore(domain: try SQLiteDomainStore(fileURL: url))
        let restoredTurn = try await store.turn(turnID)
        let restoredQuestions = try await store.pendingQuestions(conversationID: conversationID)
        XCTAssertEqual(restoredTurn?.state, .waitingForUser)
        XCTAssertEqual(restoredQuestions, [question])
        let page = try await store.messages(conversationID: conversationID, limit: 1)
        XCTAssertEqual(page.map(\.text), ["下一条"])
        let older = try await store.messages(conversationID: conversationID, before: page[0].sequence, limit: 1)
        XCTAssertEqual(older.map(\.text), ["处理项目"])
    }

    private func source() -> SourceEnvelope {
        SourceEnvelope(requestID: UUID(), principal: "owner", source: .phone,
                       replyTo: .phoneChat, grantVersion: 1, receivedAt: Date())
    }
}
