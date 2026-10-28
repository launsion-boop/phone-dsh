// SPDX-License-Identifier: MIT
// PhoneDSHController: D13 step state machine tests.

import Foundation
import XCTest
@testable import PhoneDSHController

final class StepMachineTests: XCTestCase {
    private let session = "session-1"
    private let turn = "turn-1"
    private let key = "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    private func makeMachine(_ test: XCTestCase, root: URL? = nil) throws -> StepMachine {
        try StepMachine(root: root ?? ControllerTestSupport.root(for: test),
                        clock: ManualHostClock())
    }

    private func dispatch(_ machine: StepMachine, step: String = "1",
                          execID: String? = nil) async throws {
        let record = try ControllerTestSupport.journalRecord(
            type: "dispatched", stepID: step, turnID: turn,
            key: key, execID: execID)
        try await machine.observeJournal(sessionID: session, jseq: 1, record: record)
    }

    private func complete(_ machine: StepMachine, step: String = "1",
                          execID: String? = nil, jseq: UInt64 = 2) async throws {
        let record = try ControllerTestSupport.journalRecord(
            type: "completed", stepID: step, turnID: turn,
            key: key, execID: execID)
        try await machine.observeJournal(sessionID: session, jseq: jseq, record: record)
    }

    // MARK: - Worker-local path (D20)

    func testWorkerLocalStepsRecordExactlyThreeTransitions() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)
        let afterDispatch = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(afterDispatch?.state, .toolDispatched)
        XCTAssertEqual(afterDispatch?.history, [.toolDispatched])

        try await complete(machine)
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.history, workerLocalStepPath)
        XCTAssertNil(record?.execID)
        XCTAssertEqual(record?.idemKey, key)
        XCTAssertEqual(record?.jseq, 2)
    }

    func testDispatchedWorkerLocalStepIsIncompleteAtReconcile() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(self, root: root)
        try await dispatch(machine)
        let incomplete = await machine.reconcile()
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(incomplete.first?.state, .toolDispatched)

        try await complete(machine)
        let after = await machine.reconcile()
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Orphan settlement (G2-FIX-93)

    func testSettleOrphansAbandonsAndPersistsTerminalState() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(self, root: root)
        try await dispatch(machine)

        let settled = try await machine.settleOrphans(reason: "worker-terminated")
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.state, .abandoned)
        XCTAssertEqual(settled.first?.settledReason, "worker-terminated")
        XCTAssertEqual(settled.first?.history.last, .abandoned)
        let pending = await machine.reconcile()
        XCTAssertTrue(pending.isEmpty, "abandoned is terminal for reconcile")

        // exec.md §4: the append-only line and the per-step snapshot both carry
        // the terminal state and the machine-readable reason.
        let sessionLog = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session + ".ndjson")
        let logText = try String(contentsOf: sessionLog, encoding: .utf8)
        let lastLine = try XCTUnwrap(logText.split(separator: "\n").last)
        let logObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        XCTAssertEqual(logObject["state"] as? String, "abandoned")
        XCTAssertEqual(logObject["settled_reason"] as? String, "worker-terminated")

        let snapshot = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent(key + ".json")
        let snapshotObject = try ControllerTestSupport.readJSON(snapshot)
        XCTAssertEqual(snapshotObject["state"] as? String, "abandoned")
        XCTAssertEqual(snapshotObject["settled_reason"] as? String, "worker-terminated")

        // A process restart reads the terminal state back; a second settlement
        // is a no-op and late journal evidence cannot revive the step.
        let reloaded = try makeMachine(self, root: root)
        let reloadedRecord = await reloaded.record(sessionID: session, stepKey: key)
        XCTAssertEqual(reloadedRecord?.state, .abandoned)
        XCTAssertEqual(reloadedRecord?.settledReason, "worker-terminated")
        XCTAssertEqual(reloadedRecord?.history.last, .abandoned)
        let reloadedPending = await reloaded.reconcile()
        XCTAssertTrue(reloadedPending.isEmpty)
        let secondSettlement = try await reloaded.settleOrphans(reason: "again")
        XCTAssertTrue(secondSettlement.isEmpty)

        try await complete(reloaded)
        let afterLateCompletion = await reloaded.record(sessionID: session, stepKey: key)
        XCTAssertEqual(afterLateCompletion?.state, .abandoned,
                       "a late completed record must not rewrite an abandoned step")
    }

    func testSettleOrphansLeavesJournaledStepsUntouched() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)
        try await complete(machine)
        let settled = try await machine.settleOrphans(reason: "worker-terminated")
        XCTAssertTrue(settled.isEmpty)
        let record = await machine.record(sessionID: session, stepKey: key)
        XCTAssertEqual(record?.state, .journaled)
        XCTAssertNil(record?.settledReason)
    }

    // MARK: - Accelerator path (all seven)

    func testAcceleratorRecordsAllSevenStatesInOrder() async throws {
        let machine = try makeMachine(self)
        try await machine.recordModelStreaming(sessionID: session, turnID: turn)
        let streamID = "exec-1"
        try await dispatch(machine, execID: streamID)

        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "start"))
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(
                type: "exit", extra: ["exit_code": 0]))
        let executed = try ControllerTestSupport.journalRecord(
            type: "executed", stepID: "1", turnID: turn, key: key, execID: streamID)
        try await machine.observeJournal(sessionID: session, jseq: 2, record: executed)
        _ = try await machine.observeWalWritten(sessionID: session, turnID: turn,
                                                stepID: "1", mseq: 9)
        try await complete(machine, execID: streamID, jseq: 3)

        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.history, acceleratorStepPath)
        XCTAssertEqual(record?.mseq, 9)
        XCTAssertEqual(record?.execID, streamID)
    }

    func testLatePreflightReleaseDoesNotMutateAnAbandonedStep() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)
        _ = try await machine.bindAccelerator(toolKey: key, execID: "late-preflight")
        _ = try await machine.settleOrphans(reason: "worker-terminated")
        let before = await machine.record(sessionID: session, stepID: "1")
        _ = try await machine.releaseAccelerator(toolKey: key, execID: "late-preflight")
        let after = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(before?.state, .abandoned)
        XCTAssertEqual(after, before, "a late preflight reply cannot rewrite terminal evidence")
    }

    func testZeroRequiredMseqIsValidAcceleratorWalEvidence() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)
        _ = try await machine.bindAccelerator(toolKey: key, execID: "exec-zero")
        let start = try ControllerTestSupport.execEvent(type: "start", execID: "exec-zero")
        _ = try await machine.observeExecEvent(toolKey: key, execID: "exec-zero", event: start)
        let exit = try ControllerTestSupport.execEvent(type: "exit", execID: "exec-zero")
        _ = try await machine.observeExecEvent(toolKey: key, execID: "exec-zero", event: exit)
        _ = try await machine.observeAcceleratorWAL(toolKey: key,
                                                    requiresMseq: 0, ackedMseq: 0)
        let executed = try ControllerTestSupport.journalRecord(
            type: "executed", stepID: "1", turnID: turn, key: key, execID: "exec-zero")
        try await machine.observeJournal(sessionID: session, jseq: 2, record: executed)
        try await complete(machine, execID: "exec-zero", jseq: 3)
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.mseq, 0)
        XCTAssertEqual(record?.history, Array(acceleratorStepPath.dropFirst()))
    }

    func testExecutedJournalRecordDrivesCheckpointForAccelerator() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-2"
        try await dispatch(machine, execID: streamID)
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "start"))
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "exit"))
        let executed = try ControllerTestSupport.journalRecord(
            type: "executed", stepID: "1", turnID: turn, key: key, execID: streamID)
        try await machine.observeJournal(sessionID: session, jseq: 2, record: executed)
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .checkpointApplied)
    }

    func testTerminalErrorEventMovesToExitPersisted() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-3"
        try await dispatch(machine, execID: streamID)
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "start"))
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(
                type: "error", extra: ["code": "spawn_failed"]))
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .exitPersisted)
    }

    func testCompletedBeforeWalAckIsNotGuessedForAccelerator() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-4"
        try await dispatch(machine, execID: streamID)
        try await complete(machine, execID: streamID, jseq: 2)
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .toolDispatched,
                       "the journaled transition needs the WAL evidence for an accelerator")
        XCTAssertEqual(record?.history, [.toolDispatched])
    }

    func testReplayingAnEarlierStateIsIgnored() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)
        try await complete(machine)
        let before = await machine.record(sessionID: session, stepID: "1")
        try await dispatch(machine)
        let after = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(after?.state, .journaled)
        XCTAssertEqual(after?.history, before?.history)
    }

    // MARK: - Evidence ordering and validation

    func testExecStartWithoutDispatchCreatesTheStepAtDispatchFirst() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-5"
        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "start"))
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .execRunning)
        XCTAssertEqual(record?.history, [.toolDispatched, .execRunning])
    }

    func testTerminalEventWithoutStartIsRejected() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-6"
        try await dispatch(machine, execID: streamID)
        do {
            _ = try await machine.observeExecEvent(
                sessionID: session, turnID: turn, stepID: "1", execID: streamID,
                event: ControllerTestSupport.execEvent(type: "exit"))
            XCTFail("exit_persisted comes only after exec_running")
        } catch {
            XCTAssertEqual(error as? StepMachineError,
                           .outOfOrder(from: .toolDispatched, to: .exitPersisted))
        }
    }

    func testInvalidSessionIdentifierIsRejectedBeforePathUse() async throws {
        let machine = try makeMachine(self)
        let record = try ControllerTestSupport.journalRecord(
            type: "dispatched", stepID: "1", turnID: turn)
        do {
            try await machine.observeJournal(sessionID: "../escape", jseq: 1, record: record)
            XCTFail("D6 identifiers must be validated before path use")
        } catch {
            XCTAssertEqual(error as? StepMachineError, .invalidIdentifier("../escape"))
        }
    }

    func testInvalidStepOrdinalIsRejected() async throws {
        let machine = try makeMachine(self)
        for invalid in ["0", "01", "-1", "step"] {
            let record = try ControllerTestSupport.journalRecord(
                type: "dispatched", stepID: invalid, turnID: turn)
            do {
                try await machine.observeJournal(sessionID: session, jseq: 1, record: record)
                XCTFail("invalid D20 step_id \(invalid) was accepted")
            } catch {
                XCTAssertTrue(error is StepMachineError)
            }
        }
    }

    // MARK: - Boundary

    func testBoundaryIsIdleOnlyWhenNoStepIsExecRunning() async throws {
        let machine = try makeMachine(self)
        let streamID = "exec-7"
        try await dispatch(machine, execID: streamID)
        let idleBeforeExec = await machine.isIdle
        XCTAssertTrue(idleBeforeExec, "tool_dispatched is not exec_running")

        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "start"))
        let idleDuringExec = await machine.isIdle
        XCTAssertFalse(idleDuringExec)

        _ = try await machine.observeExecEvent(
            sessionID: session, turnID: turn, stepID: "1", execID: streamID,
            event: ControllerTestSupport.execEvent(type: "exit"))
        let idleAfterExit = await machine.isIdle
        XCTAssertTrue(idleAfterExit)
        let boundary = await machine.atToolCallBoundary()
        XCTAssertTrue(boundary)
    }

    // MARK: - Persistence and reconcile

    func testPersistenceRoundTripAndSnapshotPath() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(self, root: root)
        try await dispatch(machine)

        // D20: the canonical snapshot is identified by the journal key, not
        // the informational decimal ordinal.
        let snapshot = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent(key + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        // The decimal-ordinal snapshot of the original W2 form stays readable.
        let legacySnapshot = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySnapshot.path))
        let json = try ControllerTestSupport.readJSON(snapshot)
        XCTAssertEqual(json["state"] as? String, "tool_dispatched")
        XCTAssertEqual(json["step_id"] as? String, "1")
        XCTAssertEqual(json["turn_id"] as? String, turn)

        // exec.md §4: the same canonical snake_case state name is written to
        // the append-only session log, so an external reader can parse both
        // artifacts with the specification names.
        let sessionLog = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session + ".ndjson")
        let logText = try String(contentsOf: sessionLog, encoding: .utf8)
        let firstLine = try XCTUnwrap(logText.split(separator: "\n").first)
        let logObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        XCTAssertEqual(logObject["state"] as? String, "tool_dispatched")

        let reloaded = try makeMachine(self, root: root)
        let record = await reloaded.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .toolDispatched)
        XCTAssertEqual(record?.history, [.toolDispatched])
        let incomplete = await reloaded.reconcile()
        XCTAssertEqual(incomplete.map(\.stepID), ["1"])
    }

    func testStepKeyIsTheIdempotencyKeyAndLocatesTheRecord() async throws {
        let machine = try makeMachine(self)
        try await dispatch(machine)

        let byKey = await machine.record(sessionID: session, stepKey: key)
        XCTAssertEqual(byKey?.stepKey, key)
        XCTAssertEqual(byKey?.idemKey, key)
        XCTAssertEqual(byKey?.stepID, "1", "the decimal ordinal stays informational")
        let unknown = await machine.record(
            sessionID: session, stepKey: "xl1-ffffffffffffffffffffffffffffffff")
        XCTAssertNil(unknown)
    }

    func testTornFinalNDJSONLineIsIgnoredOnBoot() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try makeMachine(self, root: root)
        try await dispatch(machine)

        let log = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session + ".ndjson")
        let snapshot = root.appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.removeItem(at: snapshot)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"step_id\"".utf8))
        try handle.close()

        let reloaded = try makeMachine(self, root: root)
        let record = await reloaded.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.state, .toolDispatched,
                       "a torn final line must not corrupt the durable prefix")
    }

    func testModelStreamingIsAttachedToTheDispatchedStep() async throws {
        let machine = try makeMachine(self)
        try await machine.recordModelStreaming(sessionID: session, turnID: turn)
        try await dispatch(machine)
        let record = await machine.record(sessionID: session, stepID: "1")
        XCTAssertEqual(record?.history, [.modelStreaming, .toolDispatched])
    }
}
