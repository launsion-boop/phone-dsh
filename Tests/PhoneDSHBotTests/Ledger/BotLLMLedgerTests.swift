// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotLLMLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testFrozenGoldenUsesRealCodecAndCacheFormula() throws {
        let fixture = try botGolden("llm-ledger")
        let valid = fixture["valid"] as! [String: Any]
        let record = try botDecode(BotLLMLedgerRecord.self, valid)
        XCTAssertEqual(record.cacheHitRatio, 40.0 / 150.0)
        XCTAssertEqual(record.ttftMs, 125)
        XCTAssertEqual(record.durationMs, 900)
        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.outputTokens, 20)
        XCTAssertEqual(record.cacheReadTokens, 40)
        XCTAssertEqual(record.cacheWriteTokens, 10)
        XCTAssertEqual(try botJSONObject(record) as? NSDictionary, valid as NSDictionary)

        var withoutTTFT = valid
        withoutTTFT.removeValue(forKey: "ttftMs")
        withoutTTFT["durationMs"] = NSNull()
        let noTiming = try botDecode(BotLLMLedgerRecord.self, withoutTTFT)
        let encoded = try botJSONObject(noTiming) as! [String: Any]
        XCTAssertNil(encoded["ttftMs"])
        XCTAssertTrue(encoded["durationMs"] is NSNull)
        var nullTTFT = valid
        nullTTFT["ttftMs"] = NSNull()
        XCTAssertThrowsError(try botDecode(BotLLMLedgerRecord.self, nullTTFT))

        var wrongRatio = valid
        wrongRatio["cacheHitRatio"] = 0.5
        XCTAssertThrowsError(try botDecode(BotLLMLedgerRecord.self, wrongRatio)) { error in
            XCTAssertEqual((error as? BotLLMLedgerError)?.field, "cacheHitRatio")
        }
        var unknownMember = valid
        unknownMember["costUsd"] = 1
        XCTAssertThrowsError(try botDecode(BotLLMLedgerRecord.self, unknownMember))
    }

    func testEveryStepAppendsDurableRecordAndSurvivesReopen() async throws {
        let fixture = try botGolden("llm-ledger")
        let record = try botDecode(BotLLMLedgerRecord.self, fixture["valid"]!)
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let ledger = BotLLMLedger(eventLog: store, eventId: { "ledger:test:step-1" })
        await assertEqualAsync(try await ledger.append(record), 1)
        await assertEqualAsync(try await ledger.append(record), 1)
        await assertEqualAsync(try await store.headCommitSeq(), 1)
        let events = try await store.events(after: 0, limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "ledger.usage_recorded")
        XCTAssertEqual(events[0].time, 1_760_000_000_000)
        XCTAssertEqual(try JSONDecoder().decode(BotLLMLedgerRecord.self, from: events[0].data.encoded()), record)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let reopenedLedger = BotLLMLedger(eventLog: reopened, eventId: { "ledger:test:step-1" })
        await assertEqualAsync(try await reopenedLedger.append(record), 1)
        let second = BotLLMLedgerRecord(
            ts: record.ts, botId: record.botId, sessionId: record.sessionId,
            purpose: .workerTurn, model: record.model, provider: record.provider,
            inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4,
            ttftMs: nil, durationMs: nil, status: "error", errorKind: "timeout")
        let secondLedger = BotLLMLedger(eventLog: reopened, eventId: { "ledger:test:step-2" })
        await assertEqualAsync(try await secondLedger.append(second), 2)
        await assertEqualAsync(try await reopenedLedger.records(), [record, second])
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }
}
