// SPDX-License-Identifier: MIT
// G2-FIX-93: host ownership of steps left open when a Worker terminates.
//
// The real PhoneDSHHost is driven with the scripted KillWorker/KillMockEngine
// over the real loopback channel. No WebKit and no packed image are involved.
// The replacement Worker either stays silent (the host must abandon the step)
// or emits the journal's terminal `resolved` record only after the host asks it
// to open the affected session for writing. That second case proves the host
// drives the phone recovery write-open route; `session/follow` is a history
// read and is never used as a reconcile trigger. The fixture uses the real
// wire shape the tool-journal encoder produces for a reconcile result.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHHarness
import PhoneDSHWire

/// Failures the planned restart can hit before the bounded orphan helper has
/// had a chance to settle a pending step. Each one still has to leave a
/// terminal D13 owner because the host enters Failed and never revisits the
/// reconciliation on reset()/bootRuntime.
private enum PlannedRestartEarlyFailure: Sendable {
    case engineRestart
    case helloTimeout
    case leaseRejected
}

private enum PlannedRestartEarlyFailureError: Error {
    case engineRestart
}

/// Wraps the scripted ``KillMockEngine`` and injects one early restart failure
/// on the replacement boot. The first boot is the ordinary host start.
private final class PlannedRestartFailingEngine: WebEngineControlling,
                                                PhoneDSHEngineEventSource,
                                                WebEngineRestartRequesting,
                                                @unchecked Sendable {
    private let base: KillMockEngine
    private let failure: PlannedRestartEarlyFailure
    private let lock = NSLock()
    private var bootCount = 0
    private var lastConfiguration: WebEngineConfiguration?

    init(worker: KillWorker, failure: PlannedRestartEarlyFailure) {
        self.base = KillMockEngine(worker: worker)
        self.failure = failure
    }

    var isLockdownModeEnabled: Bool { base.isLockdownModeEnabled }
    var isAttachedWithVisibleArea: Bool { base.isAttachedWithVisibleArea }

    func phoneDSHEvents() -> AsyncStream<WebEngineEvent> {
        base.phoneDSHEvents()
    }

    func load(_ url: URL) async throws {
        try await base.load(url)
    }

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        lock.lock()
        bootCount += 1
        let boot = bootCount
        lastConfiguration = configuration
        lock.unlock()
        guard boot > 1 else {
            try await base.bootWorker(configuration)
            return
        }
        switch failure {
        case .engineRestart:
            throw PlannedRestartEarlyFailureError.engineRestart
        case .helloTimeout:
            // The replacement engine never opens a Worker channel, so the
            // host's HELLO wait expires before the orphan helper.
            return
        case .leaseRejected:
            // The replacement Worker answers HELLO with a stale generation;
            // the host rejects the lease after the bounded reconcile.
            var stale = configuration
            var fence = stale.fence ?? WebEngineFence()
            fence.generation &+= 1
            stale.fence = fence
            try await base.bootWorker(stale)
        }
    }

    func restart() async throws {
        try await base.restart()
    }

    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        if case .engineRestart = failure {
            throw PlannedRestartEarlyFailureError.engineRestart
        }
        lock.lock()
        let configuration = lastConfiguration
        lock.unlock()
        guard let configuration else {
            throw PlannedRestartEarlyFailureError.engineRestart
        }
        try await bootWorker(configuration)
        return WebEngineRestartReport(
            reason: reason,
            bootID: configuration.bootID ?? String(repeating: "a", count: 32),
            duration: .zero)
    }
}

final class PhoneDSHScenarioOrphanStepTests: XCTestCase {
    /// Collects the host event stream without blocking a test forever.
    private final class OrphanEventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var settlementsStorage: [PhoneDSHOrphanStepSettlement] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<PhoneDSHEvent>) {
            task = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    guard case .orphanStepsSettled(let settlement) = event else { continue }
                    self.lock.lock()
                    self.settlementsStorage.append(settlement)
                    self.lock.unlock()
                }
            }
        }

        var settlements: [PhoneDSHOrphanStepSettlement] {
            lock.lock()
            defer { lock.unlock() }
            return settlementsStorage
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        deinit { task?.cancel() }
    }

    private func waitForHost(_ host: PhoneDSHHost, _ state: PhoneDSHState,
                             timeout: TimeInterval = 20) async throws {
        try await killWait(timeout: timeout) {
            let current = await host.state
            return current == state
        }
    }

    private func makeStepKey() -> String {
        "xl1-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func sendDispatch(_ worker: KillWorker, sessionID: String,
                              stepKey: String) async throws {
        _ = try await worker.sendJournal(
            sessionID: sessionID,
            record: ["type": "dispatched",
                     "key": stepKey,
                     "turn_id": "turn-1"])
        try await worker.waitForJournalAck(sessionID: sessionID, jseq: 1)
    }

    func testTerminatedWorkerOrphanStepIsAbandonedExactlyOnce() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.bootDisposition, HostBootDisposition.coldStart)
        XCTAssertEqual(diagnostics.bootReason, "empty_workspace")

        let sessionID = "orphan-1"
        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)
        let beforeHello = await worker.helloNumber()

        engine.emitTermination()
        try await killWait(timeout: 20) {
            let hello = await worker.helloNumber()
            let state = await host.state
            return hello > beforeHello && state == .running
        }

        let stepMachine = try StepMachine(root: fixture.workspace)
        try await killWait(timeout: 10) {
            let current = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
            return current?.state == .abandoned
        }
        let record = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
        XCTAssertEqual(record?.state, .abandoned)
        XCTAssertEqual(record?.settledReason, "worker-terminated")
        XCTAssertEqual(record?.history.last, .abandoned)
        let pending = await stepMachine.reconcile()
        XCTAssertTrue(pending.isEmpty)

        let recoveryCalls = await worker.recoveryCalls()
        XCTAssertTrue(recoveryCalls.contains(sessionID),
                      "the host must open the affected session for writing so DSH's "
                          + "write-open journal reconcile runs; recovery calls: \(recoveryCalls)")

        try await killWait(timeout: 5) { collector.settlements.count == 1 }
        let settlement = try XCTUnwrap(collector.settlements.first)
        XCTAssertEqual(settlement.reason, "worker-terminated")
        XCTAssertEqual(settlement.count, 1)
        XCTAssertEqual(settlement.steps,
                       [PhoneDSHOrphanStepRef(sessionID: sessionID, stepKey: stepKey)])
        XCTAssertEqual(collector.settlements.count, 1,
                       "exactly one bounded settlement event belongs to one recovery")
    }

    func testReplacementWorkerReconcilesOnWriteOpenInsteadOfBeingAbandoned() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let sessionID = "orphan-2"
        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)
        // The record does not exist until the host opens the session for
        // writing, exactly like DSH's tool-journal reconcile. Nothing is sent
        // proactively here, and no history read can produce it. The body is
        // the actual 0x30 projection of a `resolved` record (tool-journal
        // `wireRecord`), not the legacy test-only `completed` shape: `v`,
        // `t`, `type`, the real `xl1-` key, the original call id, a known
        // action and a finite timestamp.
        await worker.queueReconcileOnRecovery(
            sessionID: sessionID,
            record: ["v": 1,
                     "t": "resolved",
                     "type": "resolved",
                     "key": stepKey,
                     "call_id": "call-orphan-2",
                     "action": "backfilled-done",
                     "at": Int64(Date().timeIntervalSince1970 * 1_000)])
        let beforeHello = await worker.helloNumber()

        engine.emitTermination()
        try await killWait(timeout: 20) {
            let hello = await worker.helloNumber()
            return hello > beforeHello
        }

        try await waitForHost(host, .running)
        let stepMachine = try StepMachine(root: fixture.workspace)
        let record = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
        XCTAssertEqual(record?.state, .journaled,
                       "the write-open reconcile owns the step")
        XCTAssertNil(record?.settledReason)
        let pending = await stepMachine.reconcile()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(collector.settlements.isEmpty,
                      "a reconciled step must not publish an abandonment event")
        let recoveryCalls = await worker.recoveryCalls()
        XCTAssertTrue(recoveryCalls.contains(sessionID),
                      "the step closed only because the host drove the recovery "
                          + "write-open; recovery calls: \(recoveryCalls)")
    }

    private func reconcileRecord(_ stepKey: String, callID: String,
                                 action: String) -> [String: Any] {
        [
            "v": 1,
            "t": "resolved",
            "type": "resolved",
            "key": stepKey,
            "call_id": callID,
            "action": action,
            "at": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
    }

    /// D24 plannedRestart normally runs at a tool-call boundary, but a budget
    /// restart can interrupt one. The replacement Worker must get the same
    /// bounded write-open reconcile as a WebContent termination before the host
    /// reopens admission. The scripted Worker emits the real tool-journal
    /// `resolved` projection only in response to that write-open, so a host
    /// that merely waits or reads history cannot pass.
    func testPlannedRestartReconcilesPendingStepBeforeAdmission() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let sessionID = "planned-orphan-1"
        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)
        // A non-idempotent call whose outcome DSH can only prove as unknown:
        // the real reconcile writes `resolved(action: unknown)`. The host may
        // accept that terminal evidence, but it must not synthesize a success
        // result of its own.
        await worker.queueReconcileOnRecovery(
            sessionID: sessionID,
            record: reconcileRecord(stepKey, callID: "call-planned-orphan-1",
                                    action: "unknown"))
        let beforeHello = await worker.helloNumber()

        try await host.plannedRestart(reason: "scenario planned restart")

        let state = await host.state
        XCTAssertEqual(state, .running)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        let helloAfterRestart = await worker.helloNumber()
        XCTAssertGreaterThan(helloAfterRestart, beforeHello)

        let stepMachine = try StepMachine(root: fixture.workspace)
        let record = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
        XCTAssertEqual(record?.state, .journaled,
                       "the replacement Worker's write-open owns the terminal record")
        XCTAssertEqual(record?.history, workerLocalStepPath)
        XCTAssertNil(record?.settledReason)
        let pending = await stepMachine.reconcile()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(collector.settlements.isEmpty,
                      "a reconciled step must not publish an abandonment event")
        let recoveryCalls = await worker.recoveryCalls()
        XCTAssertTrue(recoveryCalls.contains(sessionID),
                      "the step closed only because the host drove the recovery "
                          + "write-open; recovery calls: \(recoveryCalls)")
    }

    /// The C07 `worker_kill` scenario terminates the page's Worker and then
    /// calls the ordinary facade `plannedRestart`; no engine `.terminated`
    /// event is involved. A pending non-idempotent call with no recoverable
    /// journal outcome must become the terminal `abandoned` owner after the
    /// bounded write-open, never a fabricated success/journaled step.
    func testPageWorkerKillPlannedRestartAbandonsUnprovableStep() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let sessionID = "planned-orphan-2"
        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)
        let beforeHello = await worker.helloNumber()

        // ScenarioRun's page-worker terminate: the execution context is gone
        // and the host is not told through the engine event stream. The next
        // facade call is `plannedRestart`.
        await worker.disconnect()
        try await host.plannedRestart(reason: "scenario worker kill")

        try await waitForHost(host, .running)
        let helloAfterKill = await worker.helloNumber()
        XCTAssertGreaterThan(helloAfterKill, beforeHello)

        let stepMachine = try StepMachine(root: fixture.workspace)
        let record = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
        XCTAssertEqual(record?.state, .abandoned)
        XCTAssertEqual(record?.settledReason, "planned-restart")
        XCTAssertEqual(record?.history.last, .abandoned)
        XCTAssertFalse(record?.history.contains(.journaled) ?? true,
                       "an unprovable call must never be journaled as success")
        let pending = await stepMachine.reconcile()
        XCTAssertTrue(pending.isEmpty)

        try await killWait(timeout: 5) { collector.settlements.count == 1 }
        let settlement = try XCTUnwrap(collector.settlements.first)
        XCTAssertEqual(settlement.reason, "planned-restart")
        XCTAssertEqual(settlement.count, 1)
        XCTAssertEqual(settlement.steps,
                       [PhoneDSHOrphanStepRef(sessionID: sessionID, stepKey: stepKey)])
        let recoveryCalls = await worker.recoveryCalls()
        XCTAssertTrue(recoveryCalls.contains(sessionID),
                      "the host must try DSH's write-open before abandoning; "
                          + "recovery calls: \(recoveryCalls)")
    }

    /// Negative: if the bounded reconcile helper cannot persist the terminal
    /// settlement, the planned restart must fail loud with admission closed.
    /// It must not continue to `sendOpenFrames` and reopen a host whose D13
    /// step evidence is still open.
    func testPlannedRestartHelperFailureKeepsAdmissionClosed() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let sessionID = "planned-orphan-3"
        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)

        // Block the append-only settlement path: the runtime already holds the
        // `tool_dispatched` record in memory, but `settleOrphans` cannot write
        // its terminal line. The silent replacement Worker leaves the step
        // open until the helper deadline, so the helper reaches this failure.
        let log = fixture.workspace
            .appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(sessionID + ".ndjson")
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log,
                                                withIntermediateDirectories: true)

        do {
            try await host.plannedRestart(reason: "helper-failure")
            XCTFail("a failed D13 settlement must fail the planned restart")
        } catch {
            // The restart's actionable failure is expected.
        }

        try await waitForHost(host, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .failed)
        XCTAssertEqual(diagnostics.hostState, .failed)
        XCTAssertEqual(diagnostics.admission, .closed,
                       "a helper failure must not reopen admission")
        let frames = await worker.snapshot()
        XCTAssertEqual(frames.fences, 1,
                       "no post-recovery FENCE may be sent after a failed helper")
        XCTAssertEqual(frames.lifecycles, 1,
                       "no post-recovery LIFECYCLE may be sent after a failed helper")
        XCTAssertTrue(collector.settlements.isEmpty,
                      "a failed settlement persists no event")
        let recoveryCalls = await worker.recoveryCalls()
        XCTAssertTrue(recoveryCalls.contains(sessionID),
                      "the host must have attempted the write-open")
    }

    /// Shared body of the early-failure regressions: a pending step must get
    /// the terminal `abandoned` owner even when the restart never reaches the
    /// replacement-Worker reconcile helper.
    private func assertEarlyFailureSettlesPendingStep(
        _ failure: PlannedRestartEarlyFailure,
        sessionID: String) async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = PlannedRestartFailingEngine(worker: worker, failure: failure)
        var configuration = try fixture.configuration()
        // Keep the HELLO-timeout and post-write-open grace short; the budget is
        // not extended, only scaled down for this scripted failure test.
        configuration.helloTimeout = 1.0
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = OrphanEventCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()

        let stepKey = makeStepKey()
        try await sendDispatch(worker, sessionID: sessionID, stepKey: stepKey)
        // The old page Worker is gone before the restart, matching the
        // scenario's page-worker terminate.
        await worker.disconnect()
        let framesBefore = await worker.snapshot()

        do {
            try await host.plannedRestart(reason: "early-failure")
            XCTFail("the scripted early failure must fail the planned restart")
        } catch {
            // The restart's actionable failure is expected.
        }

        try await waitForHost(host, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .failed)
        XCTAssertEqual(diagnostics.hostState, .failed)
        XCTAssertEqual(diagnostics.admission, .closed,
                       "an early restart failure must not reopen admission")

        let stepMachine = try StepMachine(root: fixture.workspace)
        let record = await stepMachine.record(sessionID: sessionID, stepKey: stepKey)
        XCTAssertEqual(record?.state, .abandoned,
                       "Failed is terminal for this incarnation; D13 must still close the step")
        XCTAssertEqual(record?.settledReason, "planned-restart")
        XCTAssertEqual(record?.history.last, .abandoned)
        XCTAssertFalse(record?.history.contains(.journaled) ?? true,
                       "an unprovable call must never be recorded as journaled success")
        let pending = await stepMachine.reconcile()
        XCTAssertTrue(pending.isEmpty)

        let recoveryCalls = await worker.recoveryCalls()
        switch failure {
        case .engineRestart, .helloTimeout:
            XCTAssertTrue(recoveryCalls.isEmpty,
                          "the failure precedes the replacement-Worker helper; "
                              + "recovery calls: \(recoveryCalls)")
        case .leaseRejected:
            XCTAssertTrue(recoveryCalls.contains(sessionID),
                          "the lease failure follows the bounded write-open; "
                              + "recovery calls: \(recoveryCalls)")
        }

        try await killWait(timeout: 5) { collector.settlements.count == 1 }
        let settlement = try XCTUnwrap(collector.settlements.first)
        XCTAssertEqual(settlement.reason, "planned-restart")
        XCTAssertEqual(settlement.count, 1)
        XCTAssertEqual(settlement.steps,
                       [PhoneDSHOrphanStepRef(sessionID: sessionID, stepKey: stepKey)])

        let frames = await worker.snapshot()
        XCTAssertEqual(frames.fences, framesBefore.fences,
                       "no post-recovery FENCE may be sent after a failed restart")
        XCTAssertEqual(frames.lifecycles, framesBefore.lifecycles,
                       "no post-recovery LIFECYCLE may be sent after a failed restart")
    }

    func testPlannedRestartEngineFailureAbandonsPendingStep() async throws {
        try await assertEarlyFailureSettlesPendingStep(
            .engineRestart, sessionID: "planned-early-engine")
    }

    func testPlannedRestartHelloTimeoutAbandonsPendingStep() async throws {
        try await assertEarlyFailureSettlesPendingStep(
            .helloTimeout, sessionID: "planned-early-hello")
    }

    func testPlannedRestartLeaseFailureAbandonsPendingStep() async throws {
        try await assertEarlyFailureSettlesPendingStep(
            .leaseRejected, sessionID: "planned-early-lease")
    }

}
