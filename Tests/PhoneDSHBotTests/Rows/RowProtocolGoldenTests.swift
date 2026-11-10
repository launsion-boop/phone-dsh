// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowProtocolGoldenTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-golden-actions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSharedRowProtocolCodableVectors() throws {
        let fixture = try RowTestSupport.golden("row-protocol")
        let valid = try RowTestSupport.object(fixture["valid"], in: "row-protocol.valid")

        for key in ["row", "widgetRow"] {
            let expected = try RowTestSupport.object(valid[key], in: "row-protocol.valid.\(key)")
            let row = try RowTestSupport.decode(BotRow.self, expected)
            try RowTestSupport.assertEncoded(row, equals: expected)
            XCTAssertEqual(try JSONDecoder().decode(BotRow.self, from: JSONEncoder().encode(row)), row)
        }

        let batchObject = try RowTestSupport.object(valid["batch"], in: "row-protocol.valid.batch")
        let batch = try RowTestSupport.decode(BotRowBatch.self, batchObject)
        try RowTestSupport.assertEncoded(batch, equals: batchObject)

        let actionObject = try RowTestSupport.object(valid["action"], in: "row-protocol.valid.action")
        let action = try RowTestSupport.decode(BotUserAction.self, actionObject)
        try RowTestSupport.assertEncoded(action, equals: actionObject)

        let cardAnswerObject = try RowTestSupport.object(valid["cardAnswer"], in: "row-protocol.valid.cardAnswer")
        let cardAnswer = try RowTestSupport.decode(BotUserAction.self, cardAnswerObject)
        XCTAssertEqual(cardAnswer.kind, .cardAnswer)
        XCTAssertEqual(cardAnswer.optionID, "o1")
        XCTAssertNil(cardAnswer.text)
        try RowTestSupport.assertEncoded(cardAnswer, equals: cardAnswerObject)

        let resultObject = try RowTestSupport.object(valid["result"], in: "row-protocol.valid.result")
        let result = try RowTestSupport.decode(BotActionResult.self, resultObject)
        try RowTestSupport.assertEncoded(result, equals: resultObject)
    }

    func testPhoneAttachmentActionVectorsUseTheRealDecoderAndValidator() throws {
        let fixture = try RowTestSupport.golden("row-protocol.phone")
        let valid = try RowTestSupport.object(fixture["valid"], in: "row-protocol.phone.valid")
        for key in ["chatWithAttachments", "chatAttachmentOnly"] {
            let expected = try RowTestSupport.object(valid[key], in: "row-protocol.phone.valid.\(key)")
            let action = try RowTestSupport.decode(BotUserAction.self, expected)
            XCTAssertEqual(action.kind, .chat)
            XCTAssertEqual(action.attachments?.count, key == "chatWithAttachments" ? 2 : 1)
            try RowTestSupport.assertEncoded(action, equals: expected)
        }

        let invalidActions = try RowTestSupport.array(fixture["invalidActions"],
                                                      in: "row-protocol.phone.invalidActions")
        XCTAssertEqual(invalidActions.count, 2)
        for (index, vector) in invalidActions.enumerated() {
            do {
                let action = try RowTestSupport.decode(BotUserAction.self, vector["action"])
                XCTAssertNotNil(BotUserActionValidation.validate(action),
                                "row-protocol.phone.invalidActions[\(index)] decoded but was not rejected")
            } catch {
                // Decoder-level rejections (attachments on a non-chat kind) are
                // the other valid outcome.
            }
        }
    }

    func testInvalidActionGoldenVectorsAreRejectedByTheRealDecoderOrValidator() throws {
        let fixture = try RowTestSupport.golden("row-protocol")
        let invalidActions = try RowTestSupport.array(fixture["invalidActions"], in: "row-protocol.invalidActions")
        for (index, vector) in invalidActions.enumerated() {
            do {
                let action = try RowTestSupport.decode(BotUserAction.self, vector["action"])
                XCTAssertNotNil(BotUserActionValidation.validate(action),
                                "invalidActions[\(index)] decoded but was not rejected")
            } catch {
                // Decoder-level rejections (text/customText/attachments on a
                // non-chat kind) are the other valid outcome.
            }
        }
    }

    func testSharedActionAcceptDuplicateAndStaleVectorsUseRealDispatcher() async throws {
        let fixture = try RowTestSupport.golden("row-protocol")
        let valid = try RowTestSupport.object(fixture["valid"], in: "row-protocol.valid")
        let invalid = try RowTestSupport.array(fixture["invalid"], in: "row-protocol.invalid")
        let action = try RowTestSupport.decode(BotUserAction.self, valid["action"])
        let expectedAccepted = try RowTestSupport.decode(BotActionResult.self, valid["result"])
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        if case .accepted(let eventID) = expectedAccepted { await planner.setDefaultEventID(eventID) }
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)

        let accepted = try await dispatcher.dispatch(action)
        XCTAssertEqual(accepted, expectedAccepted)
        try RowTestSupport.assertEncoded(accepted, equals: valid["result"] as Any)

        let duplicateVector = invalid[0]
        let duplicateAction = try RowTestSupport.decode(BotUserAction.self, duplicateVector)
        let duplicate = try await dispatcher.dispatch(duplicateAction)
        let expectedDuplicate = try RowTestSupport.decode(BotActionResult.self, duplicateVector["result"])
        XCTAssertEqual(duplicate, expectedDuplicate)
        try RowTestSupport.assertEncoded(duplicate, equals: duplicateVector["result"] as Any)

        let staleVector = invalid[1]
        let staleAction = try RowTestSupport.decode(BotUserAction.self, staleVector)
        let stale = try await dispatcher.dispatch(staleAction)
        let expectedStale = try RowTestSupport.decode(BotActionResult.self, staleVector["result"])
        XCTAssertEqual(stale, expectedStale)
        try RowTestSupport.assertEncoded(stale, equals: staleVector["result"] as Any)

        let actions = await planner.actions
        XCTAssertEqual(actions, [action])
        let trusts = await planner.trusts
        XCTAssertEqual(trusts.map(\.rawValue), [BotUserActionTrust.ownerDirect.rawValue])

        try await store.close()
        let reopened = try SQLiteDomainStore(fileURL: store.fileURL, now: { 2_000 })
        let replacementDispatcher = BotUserActionDispatcher(store: reopened, planner: planner)
        let persistedDuplicate = try await replacementDispatcher.dispatch(action)
        XCTAssertEqual(persistedDuplicate, expectedDuplicate)
        let persistedActions = await planner.actions
        XCTAssertEqual(persistedActions.count, 1)
        try await reopened.close()
    }

    func testConcurrentDuplicateNonceOnlyCallsHostOnce() async throws {
        let store = try makeStore()
        let planner = RowActionPlannerDouble()
        await planner.setDefaultEventID("evt-concurrent")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = BotUserAction(nonce: "same-nonce", botID: "main", kind: .chat, text: "继续")

        async let first = dispatcher.dispatch(action)
        async let second = dispatcher.dispatch(action)
        async let third = dispatcher.dispatch(action)
        let results = try await [first, second, third]
        XCTAssertEqual(results.filter { $0 == .accepted(eventID: "evt-concurrent") }.count, 1)
        XCTAssertEqual(results.filter { $0 == .duplicate(eventID: "evt-concurrent") }.count, 2)
        let actions = await planner.actions
        XCTAssertEqual(actions.count, 1)
        try await store.close()
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }
}
