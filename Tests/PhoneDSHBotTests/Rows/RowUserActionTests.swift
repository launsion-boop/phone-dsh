// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowUserActionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-actions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testEveryActionKindIsForwardedWithHostOwnedTrust() async throws {
        let actions = [
            BotUserAction(nonce: "chat", botID: "main", kind: .chat, text: "继续"),
            BotUserAction(nonce: "answer", botID: "main", kind: .cardAnswer, cardID: "card-1", optionID: "yes"),
            BotUserAction(nonce: "answer-secondary", botID: "main", kind: .cardAnswer, cardID: "card-1", optionID: "later"),
            BotUserAction(nonce: "dismiss", botID: "main", kind: .cardDismiss, cardID: "card-1"),
            BotUserAction(nonce: "approval", botID: "main", kind: .approval, approvalID: "approval-1",
                          decision: .allowOnce, digest: "digest-1"),
            BotUserAction(nonce: "stop", botID: "main", kind: .stopTask, threadID: "thread-1")
        ]
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        for action in actions {
            await planner.setEventID("evt-\(action.nonce)", for: action.nonce)
        }
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)

        for action in actions {
            let result = try await dispatcher.dispatch(action)
            XCTAssertEqual(result, .accepted(eventID: "evt-\(action.nonce)"))
        }
        let forwarded = await planner.actions
        let trusts = await planner.trusts
        XCTAssertEqual(forwarded, actions)
        XCTAssertEqual(trusts.map(\.rawValue), Array(repeating: "owner_direct", count: actions.count))
        try await store.close()
    }

    func testRejectedOrStaleActionDoesNotConsumeNonce() async throws {
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        await planner.setEventID("evt-approval", for: "approval-retry")
        await planner.setEventID("evt-bad-answer", for: "bad-answer")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        var answer = BotUserAction(nonce: "bad-answer", botID: "main", kind: .cardAnswer, cardID: "card-1")
        let rejected = try await dispatcher.dispatch(answer)
        XCTAssertEqual(rejected, .rejected(reason: "missing_card_answer"))
        await assertNilAsync(try await store.eventID(botID: "main", nonce: "bad-answer"))
        answer.optionID = ""
        let emptyRejected = try await dispatcher.dispatch(answer)
        XCTAssertEqual(emptyRejected, .rejected(reason: "missing_card_answer"))
        await assertNilAsync(try await store.eventID(botID: "main", nonce: "bad-answer"))

        answer.optionID = "yes"
        await assertEqualAsync(try await dispatcher.dispatch(answer), .accepted(eventID: "evt-bad-answer"))
        await assertEqualAsync(try await dispatcher.dispatch(answer), .duplicate(eventID: "evt-bad-answer"))

        var approval = BotUserAction(nonce: "approval-retry", botID: "main", kind: .approval,
                                     approvalID: "approval-1", decision: .deny, digest: "wrong")
        let stale = try await dispatcher.dispatch(approval)
        XCTAssertEqual(stale, .stale(reason: "digest_mismatch"))
        await assertNilAsync(try await store.eventID(botID: "main", nonce: "approval-retry"))
        approval.digest = "digest-1"
        let accepted = try await dispatcher.dispatch(approval)
        XCTAssertEqual(accepted, .accepted(eventID: "evt-approval"))
        let duplicate = try await dispatcher.dispatch(approval)
        XCTAssertEqual(duplicate, .duplicate(eventID: "evt-approval"))
        try await store.close()
    }

    func testPlannerRejectionCanBeCorrectedAndRetried() async throws {
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        let action = BotUserAction(nonce: "planner-rejected", botID: "main", kind: .chat, text: "继续")
        await planner.setOutcome(.rejected(reason: "owner_denied"), for: action.nonce)
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        await assertEqualAsync(try await dispatcher.dispatch(action), .rejected(reason: "owner_denied"))
        await assertNilAsync(try await store.eventID(botID: "main", nonce: action.nonce))
        await assertEqualAsync(try await store.headCommitSeq(), 0)

        await planner.clearOutcome(for: action.nonce)
        await planner.setEventID("evt-planner-rejected", for: action.nonce)
        await assertEqualAsync(try await dispatcher.dispatch(action), .accepted(eventID: "evt-planner-rejected"))
        try await store.close()
    }


    func testChatWithoutTextButWithAttachmentsIsAccepted() async throws {
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        let action = BotUserAction(
            nonce: "attachment-only", botID: "main", kind: .chat, text: "",
            attachments: [attachment("周报.pdf")])
        await planner.setEventID("evt-attachment-only", for: action.nonce)
        let result = try await BotUserActionDispatcher(store: store, planner: planner).dispatch(action)
        XCTAssertEqual(result, .accepted(eventID: "evt-attachment-only"))
        try await store.close()
    }

    func testTooManyAttachmentsAreRejectedBeforePlanning() async throws {
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        let action = BotUserAction(
            nonce: "too-many", botID: "main", kind: .chat, text: "",
            attachments: (0..<11).map { attachment("file-\($0).txt") })
        let result = try await BotUserActionDispatcher(store: store, planner: planner).dispatch(action)
        XCTAssertEqual(result, .rejected(reason: "too_many_attachments"))
        let forwarded = await planner.actions
        XCTAssertTrue(forwarded.isEmpty)
        try await store.close()
    }

    func testAttachmentsAreLimitedToChatActions() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "nonce": "card-attachments", "botID": "main", "kind": "cardAnswer",
            "cardID": "card-1", "optionID": "o1",
            "attachments": [[
                "name": "a.txt", "path": "/dsh/workspace/a.txt", "size": 1,
                "mimeType": "text/plain", "kind": "file",
            ]],
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(BotUserAction.self, from: data))
    }

    private func attachment(_ name: String) -> BotAttachment {
        BotAttachment(name: name, path: "/dsh/workspace/imports/attachments-att-1/\(name)",
                      size: 128, mimeType: "text/plain", kind: "file")
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }
}
