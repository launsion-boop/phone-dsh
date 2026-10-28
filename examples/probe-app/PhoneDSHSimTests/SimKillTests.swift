// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator kill matrix (PLAN W3-SIM / W3-KILL).
//
// The matrix is {worker terminate, WebContent restart} × {after write, during
// exec, during checkpoint, during epoch close}. The facade is the real
// `PhoneDSHHost` with a deterministic engine (`KillMockEngine`) and the real
// ordered-channel scripted Worker. Those two fixtures and the acceptance
// verifier (`verifyKillWorkspace`) are the landed macOS W3-KILL sources from
// the regular SwiftPM target `PhoneDSHHarness` (linked as a package
// product), so this file adds only the simulator orchestration.
//
// After every kill the suite recovers and asserts the W3-KILL acceptance:
//   * every level-1-acked mseq is present in the WAL with the sent mutation;
//   * replaying the WAL yields exactly the materialized tree (rm/rename
//     consistency, no ghost writes);
//   * the step reconcile set is exactly the interrupted step.
//
// A real WebContent kill (an OS process outside the test) is attempted by
// `scripts/ci/sim.sh` while the smoke suite's real WKWebView is alive;
// the watcher is scoped to this simulator's WebContent pids. This test records
// an INFO row for it, never a PASS that claims a kill happened; the shell
// stamps the measured attempt into that row after the suites.
//
// NOT_VERIFIED on an iPhone: no physical-device run exists.

import Foundation
import XCTest
import PhoneDSHHarness
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

final class PhoneDSHSimKillTests: XCTestCase {
    /// 20 iterations, as W3-KILL: both kill kinds and all four timings run at
    /// least once, then seeded repeats. `PDSH_SIM_KILL_ITERATIONS` shortens it
    /// for a local debugging run.
    private static let defaultIterations = 20

    func testSimulatorKillMatrix() async throws {
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "kill", gate: "G1", directory: directory,
                                    fileName: "kill-report.json")
        var iterations = Self.defaultIterations
        if let raw = ProcessInfo.processInfo.environment["PDSH_SIM_KILL_ITERATIONS"],
           let value = Int(raw), value >= 4 {
            iterations = value
        }
        let plan = makeSimulatorKillPlan(count: iterations)
        report.set("iterations_requested", iterations)
        report.set("kinds", ["worker-terminate", "webcontent-restart"])

        var failures: [String] = []
        for (index, iteration) in plan.enumerated() {
            let started = Date()
            do {
                var metrics = try await execute(iteration, index: index)
                let elapsed = (Date().timeIntervalSince(started) * 1000).rounded()
                metrics["kind"] = iteration.kind.rawValue
                metrics["timing"] = iteration.timing.rawValue
                metrics["elapsed_ms"] = elapsed
                report.record("kill.\(index).\(iteration.kind.rawValue).\(iteration.timing.rawValue)",
                              status: .pass, gating: true, metrics: metrics,
                              threshold: simG1Threshold(
                                "g1_kill_iteration_preserves_acked_state",
                                measured: 1),
                              detail: "recovered and verified after \(iteration.kind.rawValue)")
            } catch {
                let elapsed = (Date().timeIntervalSince(started) * 1000).rounded()
                failures.append("iteration \(index) \(iteration.kind.rawValue)/"
                                + "\(iteration.timing.rawValue): \(error)")
                report.record("kill.\(index).\(iteration.kind.rawValue).\(iteration.timing.rawValue)",
                              status: .fail, gating: true,
                              metrics: ["error": String(describing: error),
                                        "elapsed_ms": elapsed],
                              threshold: simG1Threshold(
                                "g1_kill_iteration_preserves_acked_state",
                                measured: 0),
                              detail: "\(error)")
            }
        }

        let nativelyAttempted = ProcessInfo.processInfo
            .environment["PDSH_SIM_REAL_KILL"] ?? "unavailable"
        report.record("kill.real-webcontent-kill", status: .info, gating: false,
                      metrics: ["attempt": nativelyAttempted],
                      threshold: simInfoThreshold("real_webcontent_kill"),
                      detail: "the hostless test process cannot kill the "
                        + "WebContent process; scripts/ci/sim.sh attempts "
                        + "it with `xcrun simctl spawn` and records the result")

        report.set("passed", plan.count - failures.count)
        report.set("failed", failures.count)
        report.set("failures", failures)
        report.finish(ok: failures.isEmpty)
        print("sim-kill: \(plan.count - failures.count)/\(plan.count) iterations passed")
        try report.write()
        XCTAssertTrue(failures.isEmpty,
                      "kill matrix failures:\n" + failures.joined(separator: "\n"))
    }

    /// Both kill kinds × all four timings, then seeded repeats.
    private func makeSimulatorKillPlan(count: Int) -> [KillIteration] {
        let kinds: [KillKind] = [.workerTerminate, .webContentRestart]
        let timings = KillTiming.allCases
        var all: [KillIteration] = []
        for kind in kinds {
            for timing in timings {
                all.append(KillIteration(kind: kind, timing: timing))
            }
        }
        var random = KillSeededRandom(seed: 0x5EED_5EED_ABCD_0002)
        var plan = all.shuffled(using: &random)
        while plan.count < count {
            plan.append(all.randomElement(using: &random)!)
        }
        plan = Array(plan.prefix(count))
        plan.shuffle(using: &random)
        return plan
    }

    // MARK: - One iteration

    private func execute(_ iteration: KillIteration,
                         index: Int) async throws -> [String: Any] {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let executor = KillGatedExecProvider()
        let configuration = try fixture.configuration(execProvider: executor)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        do {
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
            try await worker.waitForJournalAck(sessionID: sessionID,
                                               jseq: dispatchJseq)

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
                    record: ["type": "executed", "key": stepKey])
                try await worker.waitForJournalAck(sessionID: sessionID,
                                                   jseq: checkpointJseq)
            case .duringEpochClose:
                let lastMseq = await worker.snapshot().lastMseq
                try await worker.sendBarrier(level: .epochFsync, upto: lastMseq)
            }

            let ackedAtKill = await worker.acked()
            let helloBefore = await worker.helloNumber()
            let recoveryStart = Date()

            try await performKill(iteration, host: host, worker: worker,
                                  engine: engine)
            try await waitForState(host, .running, timeout: 30)
            try await killWait(timeout: 20) {
                await worker.helloNumber() > helloBefore
            }
            let recoveryMilliseconds = (Date().timeIntervalSince(recoveryStart) * 1000)
                .rounded()

            // A kill during execution has no exit/checkpoint evidence. A late
            // completed record cannot finish that accelerator by itself.
            // Both replacement-Worker paths now run the bounded write-open
            // reconcile before reopening admission; the park/resume row is a
            // different lifecycle and keeps its open-step expectation.
            let automaticSettlement = iteration.kind == .webContentRestart
                || (iteration.kind == .workerTerminate
                    && iteration.timing != .duringEpochClose)
            if automaticSettlement {
                try await killWait(timeout: 10) {
                    let current = try? StepMachine(root: fixture.workspace)
                    return await current?.record(sessionID: sessionID, stepKey: stepKey)?.state
                        == .abandoned
                }
            }
            let stepMachine = try StepMachine(root: fixture.workspace)
            let allRecords = await stepMachine.allRecords()
            let interrupted = Set(allRecords.filter { !$0.state.isTerminal }
                .map(\.stepKey))
            let abandoned = Set(allRecords.filter { $0.state == .abandoned }
                .map(\.stepKey))
            if automaticSettlement {
                guard interrupted.isEmpty else {
                    throw KillError.invalidState(
                        "reconcile listed \(interrupted.sorted()), expected no open step")
                }
                guard abandoned == Set([stepKey]) else {
                    throw KillError.invalidState(
                        "abandoned listed \(abandoned.sorted()), expected [\(stepKey)]")
                }
            } else {
                guard interrupted == Set([stepKey]) else {
                    throw KillError.invalidState(
                        "reconcile listed \(interrupted.sorted()), expected [\(stepKey)]")
                }
                guard abandoned.isEmpty else {
                    throw KillError.invalidState(
                        "an un-terminated recovery abandoned \(abandoned.sorted())")
                }
            }

            // Resume the scripted task on the recovered host: finish the
            // step, then a rename (remove + write), a removal and a new write.
            let completedJseq = try await worker.sendJournal(
                sessionID: sessionID,
                record: ["type": "completed", "key": stepKey])
            try await worker.waitForJournalAck(sessionID: sessionID,
                                               jseq: completedJseq)
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
                    "acked watermark regressed across recovery: "
                    + "\(ackedAtKill) -> \(ackedFinal)")
            }

            try await host.stop()
            executor.finish()
            var verification = try await verifyKillWorkspace(
                fixture.workspace, worker: worker, ackedUpto: ackedFinal,
                expectedInterrupted: !automaticSettlement && iteration.timing == .duringExec
                    ? [stepKey] : [],
                expectedAbandoned: automaticSettlement ? [stepKey] : [])
            verification["acked_at_kill"] = ackedAtKill
            verification["recovery_ms"] = recoveryMilliseconds
            return verification
        } catch {
            executor.finish()
            try? await host.stop()
            throw error
        }
    }

    private func performKill(_ iteration: KillIteration,
                             host: PhoneDSHHost,
                             worker: KillWorker,
                             engine: KillMockEngine) async throws {
        switch iteration.kind {
        case .webContentRestart:
            // The engine's public termination event takes the D14
            // Running -> Recovering edge and calls the engine restart path.
            engine.emitTermination()
        case .workerTerminate:
            // A bare channel loss has no public event; the D24 planned-restart
            // recovery path is the host/controller API that recovers it.
            if iteration.timing == .duringEpochClose {
                let parking = Task { try await host.park() }
                try await waitForState(host, .draining, timeout: 10)
                await worker.disconnect()
                try await parking.value
                try await host.resume()
            } else {
                await worker.disconnect()
                try await host.plannedRestart(reason: "sim-kill-matrix")
            }
        case .hostSIGKILL:
            throw KillError.invalidState(
                "host SIGKILL has no public API on the simulator")
        }
    }

    private func waitForState(_ host: PhoneDSHHost,
                              _ state: PhoneDSHState,
                              timeout: TimeInterval) async throws {
        try await killWait(timeout: timeout) {
            await host.state == state
        }
    }
}

/// The simulator matrix uses the landed `KillMockEngine`, whose boot is the
/// engine's restart: add the reason-bearing restart requirement so
/// `PhoneDSHHost` takes the same `WebEngineRestartRequesting` path a real
/// `WebEngine` does. Without this, the host would fall back to `bootWorker` and
/// the test would not exercise the engine restart seam.
extension KillMockEngine: WebEngineRestartRequesting {
    public func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        guard let configuration = lastConfiguration else {
            throw KillError.invalidState("the engine was never booted")
        }
        let clock = ContinuousClock()
        let started = clock.now
        try await bootWorker(configuration)
        return WebEngineRestartReport(
            reason: reason,
            bootID: configuration.bootID ?? "sim-kill",
            duration: started.duration(to: clock.now))
    }
}
