// SPDX-License-Identifier: MIT
// PLAN §2.9 I1/I2: the host ledger is the durable home of every future due
// time. These cases drive the real actor and its real file.
import XCTest
import ProbeKit

final class WakeDemandLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-demands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func demand(_ key: String, _ dueAt: Int64,
                        source: WakeDemandSource = .botRoutine,
                        kind: WakeDemandKind = .recurring) -> WakeDemand {
        WakeDemand(source: source, key: key, dueAtMs: dueAt, kind: kind, userVisible: true)
    }

    func testUpsertIsIdempotentBySourceAndKey() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("bot-a", 1_000))
        try await ledger.upsert(demand("bot-a", 5_000))
        let all = await ledger.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.dueAtMs, 5_000)
    }

    func testSourceAndKeyAreIndependent() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("bot-a", 1_000, source: .botRoutine))
        try await ledger.upsert(demand("bot-a", 2_000, source: .dshSchedule))
        let two = await ledger.all()
        XCTAssertEqual(two.count, 2)
        try await ledger.remove(source: .botRoutine, key: "bot-a")
        let rest = await ledger.all()
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.source, .dshSchedule)
    }

    func testLedgerSurvivesANewInstance() async throws {
        let first = WakeDemandLedger(directory: directory)
        try await first.upsert(demand("bot-a", 42_000))
        let second = WakeDemandLedger(directory: directory)
        let restored = await second.demand(source: .botRoutine, key: "bot-a")
        XCTAssertEqual(restored?.dueAtMs, 42_000)
        XCTAssertEqual(restored?.kind, .recurring)
        XCTAssertEqual(restored?.userVisible, true)
    }

    func testEarliestAndDueOrdering() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("late", 9_000))
        try await ledger.upsert(demand("early", 1_000))
        try await ledger.upsert(demand("middle", 5_000))
        let earliest = await ledger.earliestDueAt()
        XCTAssertEqual(earliest, 1_000)
        let due = await ledger.dueDemands(nowMs: 5_000)
        XCTAssertEqual(due.map(\.key), ["early", "middle"])
        let next = await ledger.nextDemand()
        XCTAssertEqual(next?.key, "early")
    }

    func testConsumedOnceDemandsAreDroppedButRecurringStay() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("once", 1_000, source: .hostRetries, kind: .once))
        try await ledger.upsert(demand("recurring", 1_000, source: .hostRetries, kind: .recurring))
        try await ledger.removeConsumedOnceDemands(source: .hostRetries, nowMs: 2_000)
        let rest = await ledger.all()
        XCTAssertEqual(rest.map(\.key), ["recurring"])
    }

    func testCorruptDocumentIsMovedAsideAndTreatedAsEmpty() async throws {
        let file = directory.appendingPathComponent("wake-demands.json")
        try Data("{not json".utf8).write(to: file)
        let ledger = WakeDemandLedger(directory: directory)
        let all = await ledger.all()
        XCTAssertEqual(all, [])
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt-") }
        XCTAssertFalse(backups.isEmpty)
    }

    func testEmptyLedgerHasNoDueTime() async {
        let ledger = WakeDemandLedger(directory: directory)
        let earliest = await ledger.earliestDueAt()
        let next = await ledger.nextDemand()
        XCTAssertNil(earliest)
        XCTAssertNil(next)
    }
}
