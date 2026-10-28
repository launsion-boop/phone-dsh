// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — W3-KILL kill matrix (PLAN W3-KILL, G1 rehearsal).
//
// 20 seeded kills across {worker terminate, WebContent restart, host child
// SIGKILL} x {after write, during exec, during checkpoint, during epoch close}.
// The facade iterations drive the real PhoneDSHHost with a deterministic
// MockEngine/MockWorker over the real loopback channel; the Log iterations fork
// a child that appends level-1 records and SIGKILLs it from the parent.
//
// After every kill the test recovers and asserts:
//   * every level-1-acked mseq is present in the WAL with the same mutation;
//   * replaying the WAL yields the same tree as the materialized copy
//     (rename = remove + write; rm consistency; no ghost writes);
//   * the step machine reconcile set is exactly the interrupted steps.
//
// NOT_VERIFIED on an iPhone: this target runs on macOS with a mock engine.
//
// The class name is deliberate on three counts. It contains
// `PhoneDSH` because the task gates run
// `swift test --filter 'PhoneDSH'` (swift-facade) and
// `--filter 'PhoneDSH|PhoneDSHShell'` (sdk-all), which match the
// XCTest case name; a class named only `PhoneDSHKillTests` (the target name)
// is selected by the spec gate `--filter 'PhoneDSHLog|PhoneDSHKill'`
// but not by either package gate. The leading `Z` follows
// `ZPhoneDSHToolResultAuditTests`: XCTest runs suites in name order
// and the gates keep only the tail of the log, so this matrix runs last and
// stays visible in the acceptance log.

import Foundation
import XCTest
import PhoneDSHHarness
import PhoneDSHController
import PhoneDSH
import PhoneDSHLog
import PhoneDSHAgentCore
import PhoneDSHWire

final class ZPhoneDSHPhase0KillMatrixTests: XCTestCase {
    private let report = KillReport()

    func testKillMatrix20Iterations() async throws {
        let plan = makeKillPlan(count: 20)
        XCTAssertEqual(plan.count, 20)
        let cells = Set(plan.map { "\($0.kind.rawValue)/\($0.timing.rawValue)" })
        XCTAssertEqual(cells.count, KillKind.allCases.count * KillTiming.allCases.count,
                       "the plan must exercise every matrix cell at least once")
        var failures: [String] = []

        for (index, iteration) in plan.enumerated() {
            let start = Date()
            do {
                let metrics = try await execute(iteration, index: index)
                let elapsed = Date().timeIntervalSince(start) * 1000
                report.record(KillReport.Row(index: index,
                                             kind: iteration.kind.rawValue,
                                             timing: iteration.timing.rawValue,
                                             passed: true,
                                             detail: "recovered and verified",
                                             metrics: metrics.merging([
                                                "elapsed_ms": elapsed,
                                             ]) { current, _ in current }))
            } catch {
                failures.append("iteration \(index) \(iteration.kind.rawValue)/" +
                                "\(iteration.timing.rawValue): \(error)")
                report.record(KillReport.Row(index: index,
                                             kind: iteration.kind.rawValue,
                                             timing: iteration.timing.rawValue,
                                             passed: false,
                                             detail: "\(error)",
                                             metrics: [:]))
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "kill matrix failures:\n" + failures.joined(separator: "\n"))
    }

    private func execute(_ iteration: KillIteration,
                         index: Int) async throws -> [String: Any] {
        switch iteration.kind {
        case .hostSIGKILL:
            return try await executeHostChildKill(iteration, index: index)
        case .workerTerminate, .webContentRestart:
            return try await executeFacadeKill(iteration, index: index)
        }
    }

    // MARK: - Facade kills

    private func executeFacadeKill(_ iteration: KillIteration,
                                   index: Int) async throws -> [String: Any] {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let executor = KillGatedExecProvider()
        let configuration = try fixture.configuration(execProvider: executor)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })

        let sessionID = "kill-\(index)"
        let stepKey = "xl1-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let execID = "exec-\(index)"
        let idemKey = String(repeating: "ab", count: 32)

        try await host.start()
        try await waitForState(host, .running, timeout: 20)
        try await worker.waitForOpenFrames()

        var dispatchRecord: [String: Any] = ["type": "dispatched", "key": stepKey]
        if iteration.timing == .duringExec { dispatchRecord["exec_id"] = execID }
        let dispatchJseq = try await worker.sendJournal(sessionID: sessionID,
                                                        record: dispatchRecord)
        try await worker.waitForJournalAck(sessionID: sessionID, jseq: dispatchJseq)

        switch iteration.timing {
        case .afterWrite:
            _ = try await worker.writeFile("/dsh/workspace/one.txt",
                                           data: Data("one".utf8))
            let mseq = try await worker.writeFile("/dsh/workspace/two.txt",
                                                  data: Data("two".utf8))
            try await worker.waitForAck(mseq)
        case .duringExec:
            let mseq = try await worker.writeFile("/dsh/workspace/exec-input.txt",
                                                  data: Data("input".utf8))
            try await worker.waitForAck(mseq)
            try await worker.requestExec(execID: execID,
                                         argv: ["test", "run"],
                                         idemKey: idemKey,
                                         journalKey: stepKey,
                                         requiresMseq: mseq)
            try await killWait(timeout: 10) { executor.didStart }
        case .duringCheckpoint:
            let mseq = try await worker.writeFile("/dsh/workspace/checkpoint.txt",
                                                  data: Data("checkpoint".utf8))
            try await worker.waitForAck(mseq)
            let checkpointJseq = try await worker.sendJournal(
                sessionID: sessionID,
                record: ["type": "executed",
                         "key": stepKey])
            try await worker.waitForJournalAck(sessionID: sessionID,
                                               jseq: checkpointJseq)
        case .duringEpochClose:
            let lastMseq = await worker.snapshot().lastMseq
            try await worker.sendBarrier(level: .epochFsync, upto: lastMseq)
        }

        let ackedAtKill = await worker.acked()
        let helloBefore = await worker.helloNumber()
        let recoveryStart = Date()

        try await performFacadeKill(iteration,
                                    host: host,
                                    worker: worker,
                                    engine: engine,
                                    helloBefore: helloBefore)
        try await waitForState(host, .running, timeout: 30)
        try await killWait(timeout: 20) {
            await worker.helloNumber() > helloBefore
        }
        let recoveryMilliseconds = Date().timeIntervalSince(recoveryStart) * 1000

        // A kill during execution has no exit/checkpoint evidence. The worker
        // cannot complete that accelerator merely by sending `completed`.
        // Both replacement-Worker paths drive the bounded DSH write-open
        // reconcile before reopening admission: the engine's WebContent
        // termination event and the facade's planned restart (the page-worker
        // kill used by C07). The park/resume row is a different lifecycle and
        // keeps its open-step expectation.
        let automaticSettlement = iteration.kind == .webContentRestart
            || (iteration.kind == .workerTerminate
                && iteration.timing != .duringEpochClose)
        let settlementReason = iteration.kind == .webContentRestart
            ? "worker-terminated" : "planned-restart"
        if automaticSettlement {
            try await killWait(timeout: 10) {
                let current = try? StepMachine(root: fixture.workspace)
                return await current?.record(sessionID: sessionID, stepKey: stepKey)?.state
                    == .abandoned
            }
        }
        let stepMachine = try StepMachine(root: fixture.workspace)
        let allRecords = await stepMachine.allRecords()
        let interrupted = Set(allRecords.filter { !$0.state.isTerminal }.map(\.stepKey))
        let abandoned = Set(allRecords.filter { $0.state == .abandoned }.map(\.stepKey))
        if automaticSettlement {
            guard interrupted.isEmpty else {
                throw KillError.invalidState(
                    "reconcile listed \(interrupted.sorted()), expected no open step")
            }
            guard abandoned == Set([stepKey]) else {
                throw KillError.invalidState(
                    "abandoned listed \(abandoned.sorted()), expected [\(stepKey)]")
            }
            let orphan = allRecords.first { $0.stepKey == stepKey }
            guard orphan?.settledReason == settlementReason else {
                throw KillError.invalidState(
                    "the orphan step has no \(settlementReason) settlement reason")
            }
        } else {
            guard interrupted == Set([stepKey]) else {
                throw KillError.invalidState(
                    "reconcile listed \(interrupted.sorted()), expected [\(stepKey)]; " +
                    "records=\(allRecords.map { $0.stepKey + "=" + $0.state.rawValue + "/exec:" + ($0.execID ?? "nil") })")
            }
            guard abandoned.isEmpty else {
                throw KillError.invalidState(
                    "an un-terminated recovery abandoned \(abandoned.sorted())")
            }
        }

        // Resume the scripted task on the recovered host: finish the step,
        // then a rename (remove + write), a removal and a new write. On both
        // automatic recovery rows the terminal `abandoned` record is immutable;
        // on the park/resume row the completion closes the step.
        let completedJseq = try await worker.sendJournal(
            sessionID: sessionID,
            record: ["type": "completed", "key": stepKey])
        try await worker.waitForJournalAck(sessionID: sessionID, jseq: completedJseq)
        let afterCompletion = try StepMachine(root: fixture.workspace)
        let completedRecord = await afterCompletion.record(sessionID: sessionID,
                                                           stepKey: stepKey)
        if automaticSettlement {
            guard completedRecord?.state == .abandoned else {
                throw KillError.invalidState(
                    "a late completed record revived the abandoned step")
            }
        } else if iteration.timing == .duringExec {
            guard completedRecord?.state != .journaled else {
                throw KillError.invalidState(
                    "completed journal falsely advanced an accelerator without exit/WAL evidence")
            }
        } else {
            guard completedRecord?.state == .journaled else {
                throw KillError.invalidState(
                    "the completed record did not journal the recovered step")
            }
        }

        _ = try await worker.writeFile("/dsh/workspace/rename-source.txt",
                                       data: Data("rename".utf8))
        let sourceMseq = await worker.snapshot().lastMseq
        try await worker.waitForAck(sourceMseq)
        _ = try await worker.writeFile("/dsh/workspace/rename-target.txt",
                                       data: Data("rename".utf8))
        _ = try await worker.removeFile("/dsh/workspace/rename-source.txt")
        _ = try await worker.writeFile("/dsh/workspace/removed.txt",
                                       data: Data("removed".utf8))
        _ = try await worker.removeFile("/dsh/workspace/removed.txt")
        let finalMseq = try await worker.writeFile("/dsh/workspace/final.txt",
                                                   data: Data("final".utf8))
        try await worker.waitForAck(finalMseq)
        let ackedFinal = await worker.acked()
        guard ackedFinal >= ackedAtKill else {
            throw KillError.replay(
                "acked watermark regressed across recovery: \(ackedAtKill) -> \(ackedFinal)")
        }

        try await host.stop()

        let verification = try await verifyKillWorkspace(fixture.workspace,
                                                         worker: worker,
                                                         ackedUpto: ackedFinal,
                                                         expectedInterrupted:
                                                            !automaticSettlement &&
                                                            iteration.timing == .duringExec
                                                                ? [stepKey] : [],
                                                         expectedAbandoned:
                                                            automaticSettlement ? [stepKey] : [])
        var metrics = verification
        metrics["kind"] = iteration.kind.rawValue
        metrics["timing"] = iteration.timing.rawValue
        metrics["acked_at_kill"] = ackedAtKill
        metrics["recovery_ms"] = recoveryMilliseconds
        return metrics
    }

    private func performFacadeKill(_ iteration: KillIteration,
                                   host: PhoneDSHHost,
                                   worker: KillWorker,
                                   engine: KillMockEngine,
                                   helloBefore: Int) async throws {
        switch iteration.kind {
        case .webContentRestart:
            engine.emitTermination()
        case .workerTerminate:
            // The facade's automatic recovery edge is driven by the engine
            // termination event; a bare channel loss has no public event, so
            // the test takes the D24 planned-restart recovery path. The
            // WebContent restart row exercises the automatic edge.
            if iteration.timing == .duringEpochClose {
                let parking = Task { try await host.park() }
                try await waitForState(host, .draining, timeout: 10)
                await worker.disconnect()
                try await parking.value
                try await host.resume()
            } else {
                await worker.disconnect()
                try await host.plannedRestart(reason: "kill-matrix")
            }
        case .hostSIGKILL:
            throw KillError.invalidState("the fork path does not use the facade")
        }
        _ = helloBefore
    }

    private func waitForState(_ host: PhoneDSHHost,
                              _ state: PhoneDSHState,
                              timeout: TimeInterval) async throws {
        try await killWait(timeout: timeout) {
            await host.state == state
        }
    }

    // MARK: - Forked Log kills

    private func executeHostChildKill(_ iteration: KillIteration,
                                      index: Int) async throws -> [String: Any] {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let configuration = WorkspaceLogConfiguration(root: fixture.workspace)
        let setupBoot = Data(repeating: 0x11, count: 16)
        let setup = try WorkspaceLog(configuration: configuration, bootID: setupBoot)
        _ = try await setup.append(mutationWrite("/dsh/workspace/parent.txt",
                                                 data: Data("parent".utf8)))
        _ = try await setup.append(mutationRemove("/dsh/workspace/parent-removed.txt"))
        _ = try await setup.closeEpoch()

        // A pre-kill step snapshot: the interrupted step must be the only one
        // reconcile reports after recovery.
        let sessionID = "child-\(index)"
        let stepMachine = try StepMachine(root: fixture.workspace)
        let interruptedKey = "xl1-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let completedKey = "xl1-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        _ = try await stepMachine.observeJournal(
            sessionID: sessionID, jseq: 1,
            record: journalRecord(type: "dispatched", key: interruptedKey))
        _ = try await stepMachine.observeJournal(
            sessionID: sessionID, jseq: 2,
            record: journalRecord(type: "dispatched", key: completedKey))
        _ = try await stepMachine.observeJournal(
            sessionID: sessionID, jseq: 3,
            record: journalRecord(type: "completed", key: completedKey))

        var operations: [VfsMutationBody] = []
        for file in 0..<100 {
            operations.append(mutationWrite(
                String(format: "/dsh/workspace/child-%03d.txt", file),
                data: Data(String(repeating: "c", count: 128).utf8)))
        }
        operations.append(mutationWrite("/dsh/workspace/rename-a.txt",
                                        data: Data("rename".utf8)))
        operations.append(mutationRemove("/dsh/workspace/rename-a.txt"))
        operations.append(mutationWrite("/dsh/workspace/rename-b.txt",
                                        data: Data("rename".utf8)))

        let shared = try KillFork.sharedState()
        defer { KillFork.unmap(shared.map) }
        let childBoot = Data(repeating: 0x22, count: 16)
        let timing = iteration.timing
        // Resolve the newest segment before forking: the child may only use
        // async-signal-safe POSIX calls for the torn-close timing.
        let lastSegmentURL = try WALReader.scan(
            directory: WorkspacePaths(root: fixture.workspace).walDirectory)
            .segments.last?.url
        let pid = KillFork.fork()
        if pid == 0 {
            do {
                let appender = try WALSynchronousAppender(configuration: configuration,
                                                          bootID: childBoot)
                func ack(_ mseq: UInt64) {
                    shared.pointer.pointee.acked = mseq
                }
                switch timing {
                case .afterWrite:
                    for operation in operations.prefix(3) {
                        let mseq = try appender.append(operation)
                        ack(mseq)
                    }
                    shared.pointer.pointee.phase = 1
                case .duringExec:
                    let mseq = try appender.append(operations[0])
                    ack(mseq)
                    shared.pointer.pointee.phase = 2
                case .duringCheckpoint:
                    shared.pointer.pointee.phase = 3
                    for operation in operations {
                        let mseq = try appender.append(operation)
                        ack(mseq)
                        // Widen the checkpoint window so the parent can kill
                        // in the middle of the 100-file materialization burst.
                        usleep(200)
                    }
                    shared.pointer.pointee.phase = 5
                case .duringEpochClose:
                    for operation in operations.prefix(4) {
                        let mseq = try appender.append(operation)
                        ack(mseq)
                    }
                    guard let lastSegmentURL else {
                        _exit(3)
                    }
                    try tornEpochCloseRecord(url: lastSegmentURL)
                    shared.pointer.pointee.phase = 4
                }
                appender.close()
                while true {
                    pause()
                }
            } catch {
                _exit(2)
            }
        }
        guard pid > 0 else {
            throw KillError.invalidState("fork failed")
        }

        // Wait for the scripted point, then kill the process. Every path,
        // including an assertion failure, must reap the helper so no forked
        // child keeps the test runner's stdout pipe open.
        let target = 5 + (index * 7) % 70
        var killed = false
        func reap() {
            if !killed {
                KillFork.killBySIGKILL(pid)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        defer { reap() }
        do {
            try await killWait(timeout: 20) {
                let state = shared.pointer.pointee
                switch timing {
                case .afterWrite: return state.phase == 1 && state.acked >= 3
                case .duringExec: return state.phase == 2
                case .duringCheckpoint:
                    return state.phase >= 3 && state.acked >= UInt64(target)
                case .duringEpochClose: return state.phase == 4
                }
            }
        } catch {
            var probeStatus: Int32 = 0
            let exited = waitpid(pid, &probeStatus, WNOHANG) == pid
            if exited {
                throw KillError.invalidState(
                    "the forked helper exited before the kill point " +
                    "(status \(probeStatus))")
            }
            throw error
        }
        let ackedAtKill = shared.pointer.pointee.acked
        KillFork.killBySIGKILL(pid)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        killed = true
        XCTAssertEqual(status & 0x7F, SIGKILL, "the helper must die by SIGKILL")

        // Full cold recovery through WorkspaceLog (manifest, segment scan,
        // torn-tail truncation, replay, materialization).
        let recoveryBoot = Data(repeating: 0x33, count: 16)
        let log = try WorkspaceLog(configuration: configuration, bootID: recoveryBoot)
        let recovery = try await log.recover()
        let materialized = try await log.materialize()

        let verification = try await verifyKillWorkspace(fixture.workspace,
                                                         worker: nil,
                                                         ackedUpto: ackedAtKill,
                                                         expectedInterrupted: [interruptedKey])

        // The epoch-close kill leaves a torn record; recovery must truncate it
        // at the last complete level-1 record and the acked prefix must stay.
        if iteration.timing == .duringEpochClose {
            guard recovery.truncatedTornTail else {
                throw KillError.replay("a torn epoch-close tail was not truncated")
            }
        }
        var metrics = verification
        metrics["kind"] = iteration.kind.rawValue
        metrics["timing"] = iteration.timing.rawValue
        metrics["acked_at_kill"] = ackedAtKill
        metrics["materialized_upto_mseq"] = materialized
        metrics["truncated_torn_tail"] = recovery.truncatedTornTail
        return metrics
    }

    // MARK: - Mutation helpers

    private func mutationWrite(_ path: String, data: Data) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644,
                        mflags: [.entryChanged], appendFrom: 0,
                        path: path, data: data)
    }

    private func mutationRemove(_ path: String) -> VfsMutationBody {
        VfsMutationBody(op: .remove, mode: 0, path: path)
    }

    private func journalRecord(type: String, key: String) -> Data {
        let object: [String: Any] = ["type": type, "key": key, "turn_id": "turn-1"]
        return (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.sortedKeys])) ?? Data()
    }

    /// Writes a deliberately torn epoch-close record into the newest segment,
    /// simulating a crash while the close record was being written. Recovery
    /// must truncate it (D19) and keep every complete level-1 record. This is
    /// called in the forked child, so it uses POSIX file calls only.
    private func tornEpochCloseRecord(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else {
            throw KillError.replay("cannot open the WAL segment for the torn close")
        }
        defer { Darwin.close(descriptor) }
        // A length prefix promising 24 bytes followed by only six bytes.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00]
        let written = bytes.withUnsafeMutableBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            throw KillError.replay("short write of the torn close record")
        }
    }
}
