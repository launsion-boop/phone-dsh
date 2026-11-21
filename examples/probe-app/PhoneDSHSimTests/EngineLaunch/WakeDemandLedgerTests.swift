// SPDX-License-Identifier: MIT
// PLAN §2.9 / host §10.3.2: the host ledger is the durable home of every
// future due time. These cases drive the real actor and its real file,
// including the protected-data failure mode that must never discard it.
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: directory.path)
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
        let all = try await ledger.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.dueAtMs, 5_000)
    }

    func testSourceAndKeyAreIndependent() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("same", 1_000, source: .botRoutine))
        try await ledger.upsert(demand("same", 2_000, source: .dshSchedule))
        let two = try await ledger.all()
        XCTAssertEqual(two.count, 2)
        try await ledger.remove(source: .botRoutine, key: "same")
        let rest = try await ledger.all()
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.source, .dshSchedule)
    }

    func testLedgerSurvivesANewInstance() async throws {
        let first = WakeDemandLedger(directory: directory)
        try await first.upsert(demand("bot-a", 42_000))
        let second = WakeDemandLedger(directory: directory)
        let restored = try await second.demand(source: .botRoutine, key: "bot-a")
        XCTAssertEqual(restored?.dueAtMs, 42_000)
        XCTAssertEqual(restored?.kind, .recurring)
        XCTAssertEqual(restored?.userVisible, true)
    }

    func testEarliestAndDueOrdering() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("late", 9_000))
        try await ledger.upsert(demand("early", 1_000))
        try await ledger.upsert(demand("middle", 5_000))
        let earliest = try await ledger.earliestDueAt()
        XCTAssertEqual(earliest, 1_000)
        let due = try await ledger.dueDemands(nowMs: 5_000)
        XCTAssertEqual(due.map(\.key), ["early", "middle"])
        let next = try await ledger.nextDemand()
        XCTAssertEqual(next?.key, "early")
    }

    func testDueNowUsesContractOrder() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        // Same due time: source order (botRoutine, connectorScan, dshSchedule,
        // hostRetry), then key.
        try await ledger.upsert(demand("b", 1_000, source: .botRoutine))
        try await ledger.upsert(demand("a", 1_000, source: .botRoutine))
        try await ledger.upsert(demand("gmail", 1_000, source: .connectorScan))
        try await ledger.upsert(demand("schedule", 1_000, source: .dshSchedule))
        let due = try await ledger.dueDemands(nowMs: 1_000)
        XCTAssertEqual(due.map(\.id), ["botRoutine:a", "botRoutine:b",
                                       "connectorScan:gmail", "dshSchedule:schedule"])
    }

    func testConsumedOnceDemandsAreDroppedButRecurringStay() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("once", 1_000, source: .hostRetry, kind: .once))
        try await ledger.upsert(demand("recurring", 1_000, source: .hostRetry, kind: .recurring))
        try await ledger.removeConsumedOnceDemands(source: .hostRetry, nowMs: 2_000)
        let rest = try await ledger.all()
        XCTAssertEqual(rest.map(\.key), ["recurring"])
    }

    func testCorruptDocumentIsMovedAsideAndTreatedAsEmpty() async throws {
        let file = directory.appendingPathComponent("wake-demands.json")
        try Data("{not json".utf8).write(to: file)
        let ledger = WakeDemandLedger(directory: directory)
        let all = try await ledger.all()
        XCTAssertEqual(all, [])
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt-") }
        XCTAssertFalse(backups.isEmpty)
    }

    func testUnreadableDocumentIsNotDiscardedAndRetries() async throws {
        // A directory at the file path makes `Data(contentsOf:)` fail the way
        // protected data does: the file exists but cannot be read now.
        let file = directory.appendingPathComponent("wake-demands.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let ledger = WakeDemandLedger(directory: directory)
        do {
            _ = try await ledger.all()
            XCTFail("expected unavailable")
        } catch let error as WakeDemandLedgerError {
            XCTAssertEqual(error, .unavailable)
        }
        // The path was not moved aside; it is still there for the retry.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.contains("corrupt-") })

        // Protected data became available: the same ledger reads on retry.
        try FileManager.default.removeItem(at: file)
        try Data("""
        {"version":1,"demands":[{"source":"dshSchedule","key":"schedule","dueAtMs":5000,"kind":"recurring","userVisible":false}]}
        """.utf8).write(to: file)
        let restored = try await ledger.all()
        XCTAssertEqual(restored.map(\.id), ["dshSchedule:schedule"])
    }

    func testUnavailableLedgerRefusesWrites() async throws {
        let file = directory.appendingPathComponent("wake-demands.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let ledger = WakeDemandLedger(directory: directory)
        do {
            try await ledger.upsert(demand("bot-a", 1_000))
            XCTFail("expected unavailable")
        } catch let error as WakeDemandLedgerError {
            XCTAssertEqual(error, .unavailable)
        }
        // No partial file was written over the existing path.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPersistFailureRollsBackMemory() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        try await ledger.upsert(demand("bot-a", 1_000))
        // Make the directory unwritable so the next atomic write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: directory.path)
        do {
            try await ledger.upsert(demand("bot-a", 9_000))
            XCTFail("expected persist failure")
        } catch {
            // Expected: the write failed.
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: directory.path)
        let all = try await ledger.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.dueAtMs, 1_000, "the in-memory value must roll back")
    }

    func testEmptyLedgerHasNoDueTime() async throws {
        let ledger = WakeDemandLedger(directory: directory)
        let earliest = try await ledger.earliestDueAt()
        let next = try await ledger.nextDemand()
        XCTAssertNil(earliest)
        XCTAssertNil(next)
    }

    func testConnectorScanCadenceHonoursTheDemand() {
        let now: Int64 = 1_800_000_000_000
        func scan(_ key: String, dueAt: Int64) -> WakeDemand {
            WakeDemand(source: .connectorScan, key: key, dueAtMs: dueAt,
                       kind: .recurring, userVisible: false)
        }
        // A connector with no demand yet is due once: its first scan only
        // establishes the cursor. An unauthorised connector never counts.
        XCTAssertTrue(ConnectorScanCadence.hasDueWork(
            authorized: ["gmail"], demands: [], nowMs: now))
        XCTAssertFalse(ConnectorScanCadence.hasDueWork(
            authorized: [], demands: [scan("gmail", dueAt: now - 1)], nowMs: now))
        // A completed scan's future demand suppresses the scan; a due demand
        // (or an overdue one) allows it.
        let future = scan("gmail", dueAt: now + 60_000)
        XCTAssertFalse(ConnectorScanCadence.hasDueWork(
            authorized: ["gmail"], demands: [future], nowMs: now))
        XCTAssertTrue(ConnectorScanCadence.hasDueWork(
            authorized: ["gmail"], demands: [scan("gmail", dueAt: now)], nowMs: now))
        XCTAssertTrue(ConnectorScanCadence.hasDueWork(
            authorized: ["gmail"], demands: [scan("gmail", dueAt: now - 1)], nowMs: now))
        // A second authorised connector without a demand makes the pass due.
        XCTAssertTrue(ConnectorScanCadence.hasDueWork(
            authorized: ["gmail", "github"], demands: [future], nowMs: now))
    }
}
