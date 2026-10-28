// SPDX-License-Identifier: MIT
// Contract tests for the real tool-journal record shape (PLAN D20 amended).
//
// The fixtures below are copied verbatim from the merged tool-journal tests:
// - plugins/tests/journal.test.ts ("records survive reload; a torn final
//   line is ignored", the `store.append` literals),
// - plugins/tests/journal-sync.test.ts:16-19,28-34 ("journal append sends
//   0x30 and resolves only at the level-1 ack", the `start` fixture and the
//   assertion that the 0x30 wire projection carries `type: "dispatched"`).
//
// They keep the exact field set and key order of the source records. The wire
// projection adds a `type` field (journal.ts `wireRecord`); both variants are
// exercised. The production start/done/resolved records carry no `turn_id` and
// no decimal `step_id`; the step identity is the `key` (`xl1-<32hex>`).

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHWire

/// Captures controller log lines so "unknown shapes are logged" is assertable.
private final class RecordingControllerLogger: ControllerLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(ControllerLogLevel, String)] = []

    var entries: [(ControllerLogLevel, String)] {
        lock.withLock { stored }
    }

    var messages: [String] {
        entries.map(\.1)
    }

    func log(_ level: ControllerLogLevel, _ message: String) {
        lock.withLock { stored.append((level, message)) }
    }
}

final class StepMachineJournalContractTests: XCTestCase {
    /// Verbatim from plugins/tests/journal.test.ts:26.
    private let verbatimStart = """
    {"v":1,"t":"start","key":"k","call_id":"c1","tool":"bash","class":"non-idempotent","args_sha256":"a","schema_sha256":"b","profile":"pdsh-phone/1+test","at":1}
    """
    /// Verbatim from plugins/tests/journal.test.ts:27.
    private let verbatimDone = """
    {"v":1,"t":"done","key":"k","call_id":"c1","result":{"content":[{"type":"text","text":"ok"}],"isError":false},"at":2}
    """
    /// Verbatim from plugins/tests/journal.test.ts:39.
    private let verbatimResolved = """
    {"v":1,"t":"resolved","key":"k","call_id":"c1","action":"unknown","at":1}
    """
    /// Verbatim start fixture fields from plugins/tests/journal-sync.test.ts:
    /// the 0x30 projection adds the `type` asserted by that test.
    private let verbatimSyncStart = """
    {"v":1,"t":"start","key":"xl1-c1","call_id":"c1","tool":"bash","class":"non-idempotent","args_sha256":"a","schema_sha256":null,"profile":"p","at":1,"turn_id":"1","step_id":"1"}
    """

    private func makeMachine(root: URL? = nil,
                             logger: any ControllerLogging = StderrControllerLogger(),
                             test: XCTestCase) throws -> StepMachine {
        try StepMachine(root: root ?? ControllerTestSupport.root(for: test),
                        clock: ManualHostClock(), logger: logger)
    }

    private func appendType(_ wireType: String, to record: String) -> Data {
        let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBrace = String(trimmed.dropLast())
        return Data((withoutBrace + ",\"type\":\"\(wireType)\"}").utf8)
    }

    // MARK: - Verbatim records, no turn_id / step_id

    func testVerbatimJournalTestStartRecordIsKeyedByItsJournalKey() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(root: root, test: self)
        let record = try await machine.observeJournal(
            sessionID: "s1", jseq: 1, record: Data(verbatimStart.utf8))

        XCTAssertEqual(record?.stepKey, "k")
        XCTAssertEqual(record?.state, .toolDispatched)
        XCTAssertNil(record?.stepID, "the real journal record has no decimal step_id")
        XCTAssertNil(record?.turnID, "the real journal record has no turn_id")
        XCTAssertEqual(record?.jseq, 1)

        let byKey = await machine.record(sessionID: "s1", stepKey: "k")
        XCTAssertEqual(byKey?.state, .toolDispatched)

        // D20: the snapshot path is driven by the journal key.
        let snapshot = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent("s1", isDirectory: true)
            .appendingPathComponent("k.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let json = try ControllerTestSupport.readJSON(snapshot)
        XCTAssertEqual(json["state"] as? String, "tool_dispatched")
        XCTAssertEqual(json["idem_key"] as? String, "k")
        XCTAssertNil(json["step_id"])
    }

    func testVerbatimJournalTestDoneRecordBecomesJournaled() async throws {
        let machine = try makeMachine(test: self)
        _ = try await machine.observeJournal(sessionID: "s1", jseq: 1,
                                             record: Data(verbatimStart.utf8))
        let record = try await machine.observeJournal(sessionID: "s1", jseq: 2,
                                                       record: Data(verbatimDone.utf8))

        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.history, workerLocalStepPath)
        XCTAssertEqual(record?.stepKey, "k")
        XCTAssertEqual(record?.jseq, 2)
        let incomplete = await machine.reconcile()
        XCTAssertTrue(incomplete.isEmpty)
    }

    func testVerbatimJournalTestResolvedRecordBecomesJournaled() async throws {
        let machine = try makeMachine(test: self)
        _ = try await machine.observeJournal(sessionID: "s1", jseq: 1,
                                             record: Data(verbatimStart.utf8))
        let record = try await machine.observeJournal(sessionID: "s1", jseq: 2,
                                                       record: Data(verbatimResolved.utf8))

        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.history, workerLocalStepPath)
        XCTAssertEqual(record?.stepKey, "k")
    }

    func testVerbatimJournalSyncStartProjectsToToolDispatchedByWireType() async throws {
        let machine = try makeMachine(test: self)
        // `type` wins over the retained local `t` in the 0x30 projection.
        let wire = appendType("dispatched", to: verbatimSyncStart)
        let record = try await machine.observeJournal(sessionID: "s1", jseq: 1,
                                                       record: wire)
        XCTAssertEqual(record?.stepKey, "xl1-c1")
        XCTAssertEqual(record?.state, .toolDispatched)
        XCTAssertEqual(record?.stepID, "1", "legacy informational fields stay informational")
        XCTAssertEqual(record?.idemKey, "xl1-c1")
        let snapshot = machine.root
            .appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent("s1", isDirectory: true)
            .appendingPathComponent("xl1-c1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    }

    // MARK: - JOURNAL frame body

    func testJournalBodySuppliesTheSessionIDForTheStepIdentity() async throws {
        let body = JournalBody(jseq: 7, sessionID: "session-from-frame",
                               record: Data(verbatimStart.utf8))
        let machine = try makeMachine(test: self)
        let record = try await machine.observeJournal(body)
        XCTAssertEqual(record?.sessionID, "session-from-frame")
        let byKey = await machine.record(sessionID: "session-from-frame", stepKey: "k")
        XCTAssertEqual(byKey?.state, .toolDispatched)
    }

    // MARK: - Unknown shapes are never silently ignored

    func testUnknownJournalShapeIsCountedAndLogged() async throws {
        let logger = RecordingControllerLogger()
        let machine = try makeMachine(logger: logger, test: self)
        let record = try await machine.observeJournal(
            sessionID: "s1", jseq: 1,
            record: Data("{\"v\":1,\"t\":\"mystery\",\"key\":\"xl1-c1\"}".utf8))

        XCTAssertNil(record)
        let metrics = await machine.metrics()
        XCTAssertEqual(metrics.journalRecords, 1)
        XCTAssertEqual(metrics.unknownJournalRecords, 1)
        XCTAssertEqual(metrics.journalRecordsApplied, 0)
        XCTAssertTrue(logger.messages.contains { $0.contains("mystery") })
    }

    func testJournalHeaderIsCountedAsIgnoredAndLogged() async throws {
        let logger = RecordingControllerLogger()
        let machine = try makeMachine(logger: logger, test: self)
        let record = try await machine.observeJournal(
            sessionID: "s1", jseq: 1,
            record: Data("{\"v\":1,\"t\":\"header\",\"session_id\":\"s1\",\"profile\":\"p\",\"at\":1}".utf8))

        XCTAssertNil(record)
        let metrics = await machine.metrics()
        XCTAssertEqual(metrics.journalRecords, 1)
        XCTAssertEqual(metrics.journalRecordsIgnored, 1)
        XCTAssertEqual(metrics.unknownJournalRecords, 0)
        XCTAssertTrue(logger.messages.contains { $0.contains("header") })
    }

    func testRecordWithoutKeyOrLegacyIdentityIsCountedAndLogged() async throws {
        let logger = RecordingControllerLogger()
        let machine = try makeMachine(logger: logger, test: self)
        let record = try await machine.observeJournal(
            sessionID: "s1", jseq: 1,
            record: Data("{\"v\":1,\"t\":\"start\",\"call_id\":\"c1\"}".utf8))

        XCTAssertNil(record)
        let metrics = await machine.metrics()
        XCTAssertEqual(metrics.unknownJournalRecords, 1)
        XCTAssertTrue(logger.messages.contains { $0.contains("no D20 key") })
    }

    // MARK: - D6 before path use

    func testInvalidStepKeyIsRejectedBeforePathUse() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(root: root, test: self)
        let record = Data("{\"v\":1,\"t\":\"start\",\"key\":\"../escape\"}".utf8)
        do {
            _ = try await machine.observeJournal(sessionID: "s1", jseq: 1, record: record)
            XCTFail("the D6 grammar is checked before the key becomes a path")
        } catch {
            XCTAssertEqual(error as? StepMachineError, .invalidIdentifier("../escape"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("steps", isDirectory: true)
                .appendingPathComponent("s1", isDirectory: true).path),
            "no session directory is created for an invalid key")
    }

    func testExecEvidenceFindsAKeyOnlyDispatchAndMovesToExecRunning() async throws {
        let machine = try makeMachine(test: self)
        _ = try await machine.observeJournal(sessionID: "s1", jseq: 1,
                                             record: Data(verbatimStart.utf8))
        let running = try await machine.observeExecEvent(
            sessionID: "s1", turnID: "t1", stepID: "1", execID: "exec-1",
            event: ControllerTestSupport.execEvent(type: "start"),
            idemKey: "k")
        XCTAssertEqual(running.state, .execRunning)

        let boundary = ToolCallBoundary(
            noFrameInFlight: { true }, epochClosed: { true }, steps: machine)
        let atBoundary = await boundary.atToolCallBoundary()
        XCTAssertFalse(atBoundary, "an exec_running step blocks the composed boundary")

        _ = try await machine.observeExecEvent(
            sessionID: "s1", turnID: "t1", stepID: "1", execID: "exec-1",
            event: ControllerTestSupport.execEvent(type: "exit"),
            idemKey: "k")
        let afterExit = await boundary.atToolCallBoundary()
        XCTAssertTrue(afterExit)
    }

    func testKeyOnlyRecordSurvivesReloadAndReconcile() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try makeMachine(root: root, test: self)
        _ = try await first.observeJournal(sessionID: "s1", jseq: 1,
                                           record: Data(verbatimStart.utf8))

        let second = try makeMachine(root: root, test: self)
        let record = await second.record(sessionID: "s1", stepKey: "k")
        XCTAssertEqual(record?.state, .toolDispatched)
        XCTAssertNil(record?.stepID)
        let incomplete = await second.reconcile()
        XCTAssertEqual(incomplete.map(\.stepKey), ["k"])
    }
}
