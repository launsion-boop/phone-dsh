// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHController
import XCTest
@testable import PhoneDSH

final class ExecIntentBindingTests: XCTestCase {
    func testStartQueuedBeforeBindingKeepsExactWALRequirement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecIntentBindingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = try StepMachine(root: root)
        let recorder = PhoneDSHLedgerRecorder(
            ledger: try SideEffectLedger(root: root), stepMachine: machine)
        _ = try await machine.observeJournal(sessionID: "session-race", jseq: 1,
            record: Data(#"{"type":"start","key":"xl1-race"}"#.utf8))
        let required: UInt64 = 4435
        let start = Data("""
        {"exec_id":"exec-race","replayed":false,"seq":0,"type":"start"}
        """.utf8)
        await recorder.record(start, ackedMseq: required)
        await recorder.bindIntent(execID: "exec-race", idemKey: String(repeating: "a", count: 64),
                                  argv: ["phone", "files.list", "{}"], cwd: "/dsh/workspace",
                                  toolKey: "xl1-race", requiresMseq: required)
        let exit = Data("""
        {"code":0,"exec_id":"exec-race","quiescent":true,"seq":1,"signal":null,"status":"exited","type":"exit"}
        """.utf8)
        await recorder.record(exit, ackedMseq: required)
        let record = await machine.record(sessionID: "session-race", stepKey: "xl1-race")
        let evidence = try XCTUnwrap(record?.execEvidence?["exec-race"])
        XCTAssertEqual(evidence.requiresMseq, required)
        XCTAssertTrue(evidence.started)
        XCTAssertTrue(evidence.terminal)
        XCTAssertTrue(evidence.walAcknowledged)
        XCTAssertFalse(evidence.persistenceFailed)
        let failure = await recorder.lastPersistenceError
        XCTAssertNil(failure)
        let entry = try await SideEffectLedger(root: root).entry(
            forKey: String(repeating: "a", count: 64))
        XCTAssertEqual(entry?.requiresMseq, required)
        XCTAssertEqual(entry?.events.count, 2)
    }

    func testExecBeforeDispatchedJournalReconcilesInOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecIntentBindingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = try StepMachine(root: root)
        let recorder = PhoneDSHLedgerRecorder(
            ledger: try SideEffectLedger(root: root), stepMachine: machine)
        let required: UInt64 = 4435
        let key = "xl1-before-journal"
        let idemKey = String(repeating: "b", count: 64)
        await recorder.bindIntent(execID: "exec-before-journal", idemKey: idemKey,
                                  argv: ["phone", "files.list", "{}"], cwd: "/dsh/workspace",
                                  toolKey: key, requiresMseq: required)
        let start = Data("""
        {"exec_id":"exec-before-journal","replayed":false,"seq":0,"type":"start"}
        """.utf8)
        await recorder.record(start, ackedMseq: required)
        let exit = Data("""
        {"code":0,"exec_id":"exec-before-journal","quiescent":true,"seq":1,"signal":null,"status":"exited","type":"exit"}
        """.utf8)
        await recorder.record(exit, ackedMseq: required)

        var failure = await recorder.lastPersistenceError
        XCTAssertNil(failure)
        _ = try await machine.observeJournal(sessionID: "session-before-journal", jseq: 1,
            record: Data(#"{"type":"start","key":"xl1-before-journal"}"#.utf8))
        await recorder.reconcile(toolKey: key)

        let record = await machine.record(sessionID: "session-before-journal", stepKey: key)
        let evidence = try XCTUnwrap(record?.execEvidence?["exec-before-journal"])
        XCTAssertEqual(evidence.requiresMseq, required)
        XCTAssertTrue(evidence.started)
        XCTAssertTrue(evidence.terminal)
        XCTAssertTrue(evidence.walAcknowledged)
        XCTAssertFalse(evidence.persistenceFailed)
        failure = await recorder.lastPersistenceError
        XCTAssertNil(failure)
        let entry = try await SideEffectLedger(root: root).entry(forKey: idemKey)
        XCTAssertEqual(entry?.requiresMseq, required)
        XCTAssertEqual(entry?.events.count, 2)
    }
}
