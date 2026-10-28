// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the bounded abort escalation owner (G2-FIX-105).
//
// G2-FIX-9 made the drain await `session/cancel` and verify that the DSH
// session journaled its own terminal `turn/end`. That contract holds while the
// Worker can *run* the cancel. It does not hold when the Worker's execution
// channel is owned by a blocked job: the cancel RPC is never processed, the
// session layer cannot journal anything, and at the drain deadline the host
// used to fail loud with an open turn and tear the Worker down anyway.
//
// This file owns the missing second layer. Inside the same drain window, after
// the cooperative cancel has had its share (``DrainEscalationPlan``), it:
//
//   1. stops the old Worker/WebContent (the engine's two-phase termination
//      lever) and lets the write-direction handlers that were already
//      dispatching finish;
//   2. only then repacks the VFS overlay, so a frame the old page accepted
//      cannot land behind the image the replacement mounts;
//   3. boots the replacement Worker and waits for its HELLO;
//   4. uses the phone-only DSH resume/repair route: `AgentLoop.resume` opens
//      the stored session and the pinned session layer appends its
//      `interrupted` tail closers. A fresh Worker has no live Agent for
//      `session/cancel` to address, so the old cancel-only sequence could not
//      settle a real interrupted turn;
//   5. re-drives `session/cancel` as the second lever, then polls the
//      materialized journal (bounded) until every live session is terminal and
//      retries the whole sequence at most
//      ``DrainEscalationPlan/maximumWorkerTerminations`` times.
//
// It never writes a session record: Swift only reads `session.v*.jsonl` and
// verifies the record DSH wrote. The terminal reason is whatever the pinned
// session layer chose: a live `session/cancel` journals
// `{kind:'aborted', ...}`, while the resume repair of a process that was killed
// mid-turn journals `{kind:'interrupted'}` (pinned DSH
// `packages/core/session/src/repair.ts`). The host does not pick or rewrite it;
// it only requires a terminal `turn/end` before teardown. Every step is bounded
// by the drain deadline passed in; an exhausted budget returns an ``Outcome``
// and the facade keeps its fail-loud path (open turn, no terminal record) as
// the only remaining outcome.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHLog

/// One bounded terminate + replace + re-drive + verify attempt.
struct PhoneDSHAbortEscalationAttempt: Equatable, Sendable {
    /// The overlay repack completed, so the replacement Worker mounts the
    /// journal this drain has to settle.
    var packedOverlay: Bool
    /// The old Worker/WebContent was terminated and the replacement booted.
    var workerTerminated: Bool
    /// The replacement Worker completed its HELLO handshake.
    var freshWorkerReady: Bool
    /// The replacement Worker ran DSH's own resume/repair and appended the
    /// interrupted-turn closers.
    var recoveryResumed: Bool
    /// The abort RPC reached the replacement Worker.
    var cancelDelivered: Bool
    /// The materialized journal was terminal for every escalated session when
    /// the attempt's verify budget expired.
    var sawTerminalTurn: Bool
    /// The last error of this attempt, for diagnostics and the fail-loud text.
    var lastError: String?

    init(packedOverlay: Bool = false,
                workerTerminated: Bool = false,
                freshWorkerReady: Bool = false,
                recoveryResumed: Bool = false,
                cancelDelivered: Bool = false,
                sawTerminalTurn: Bool = false,
                lastError: String? = nil) {
        self.packedOverlay = packedOverlay
        self.workerTerminated = workerTerminated
        self.freshWorkerReady = freshWorkerReady
        self.recoveryResumed = recoveryResumed
        self.cancelDelivered = cancelDelivered
        self.sawTerminalTurn = sawTerminalTurn
        self.lastError = lastError
    }
}

/// The result of one escalation sequence.
struct PhoneDSHAbortEscalationOutcome: Equatable, Sendable {
    var attempts: [PhoneDSHAbortEscalationAttempt]
    var lastError: String?
    /// Set when the old connection did not quiesce. The close may already have
    /// lost a queued inbound write, so no later attempt may pack the overlay or
    /// boot a replacement: the whole drain must fail loud instead.
    var nonRetryable: Bool

    init(attempts: [PhoneDSHAbortEscalationAttempt] = [],
                lastError: String? = nil,
                nonRetryable: Bool = false) {
        self.attempts = attempts
        self.lastError = lastError
        self.nonRetryable = nonRetryable
    }

    /// Whether the caller may run another terminate + pack + boot attempt.
    var retryable: Bool { !nonRetryable }

    /// Number of Worker/WebContent terminations this drain performed.
    var terminations: Int { attempts.filter { $0.workerTerminated }.count }

    /// Whether any attempt observed a terminal journal record.
    var settled: Bool { attempts.contains { $0.sawTerminalTurn } }

    /// One-line description for the fail-loud error and the console trace.
    var diagnostic: String {
        var parts = attempts.map { attempt in
            var flags: [String] = []
            if attempt.packedOverlay { flags.append("overlay") }
            if attempt.workerTerminated { flags.append("terminated") }
            if attempt.freshWorkerReady { flags.append("rebooted") }
            if attempt.recoveryResumed { flags.append("recovery") }
            if attempt.cancelDelivered { flags.append("cancel") }
            if attempt.sawTerminalTurn { flags.append("terminal") }
            return "[" + flags.joined(separator: ",") + "]"
        }
        if let lastError { parts.append("error: \(lastError)") }
        return parts.joined(separator: " ")
    }
}

/// Owns the bounded escalation that settles a DSH session which could not
/// process `session/cancel` inside the drain window.
///
/// The facade constructs one per drain. The component is a plain value: it
/// captures the current engine, log, coordinator and transport and reads the
/// journal through the caller's ``hasTerminalTurn`` closure, so it cannot
/// accidentally observe a stale host incarnation.
struct PhoneDSHAbortEscalator: Sendable {
    /// Boot id whose overlay route the replacement Worker loads.
    let bootID: String
    /// The engine that can terminate the Worker/WebContent and boot another.
    let engine: any WebEngineControlling
    /// Workspace log used to refresh the overlay and to materialize the
    /// journal the caller verifies.
    let log: WorkspaceLog
    /// Ordered-channel registry that knows when the replacement Worker said
    /// HELLO.
    let coordinator: PhoneDSHChannelCoordinator
    /// Transport used to re-drive the `session/cancel` at the
    /// replacement Worker.
    let transport: any DSHRemoteTransport
    /// Maximum bounded terminate + replace + verify attempts this sequence
    /// may perform (a failed attempt still counts).
    let maximumTerminations: Int

    /// Creates the escalation owner for one drain.
    ///
    /// - Parameters:
    ///   - bootID: the boot id the engine's overlay route was configured with.
    ///   - engine: the engine controlling the Worker/WebContent.
    ///   - log: the workspace log whose materialized journal is verified.
    ///   - coordinator: the ordered-channel HELLO registry.
    ///   - transport: a transport for the replacement Worker.
    ///   - maximumTerminations: at most this many bounded terminations.
    init(bootID: String,
                engine: any WebEngineControlling,
                log: WorkspaceLog,
                coordinator: PhoneDSHChannelCoordinator,
                transport: any DSHRemoteTransport,
                maximumTerminations: Int = DrainEscalationPlan.maximumWorkerTerminations) {
        self.bootID = bootID
        self.engine = engine
        self.log = log
        self.coordinator = coordinator
        self.transport = transport
        self.maximumTerminations = max(1, maximumTerminations)
    }

    /// Runs the bounded escalation sequence.
    ///
    /// - Parameters:
    ///   - sessionIDs: the sessions whose journals are still open. Every one
    ///     must reach a terminal turn for ``hasTerminalTurn`` to report true.
    ///   - deadline: the outer drain verification deadline
    ///     (``DrainEscalationPlan/verifyDeadline``); no step runs past it.
    ///   - hasTerminalTurn: reads the materialized journal and reports whether
    ///     every escalated session has closed its turn. The caller owns the
    ///     read (and its incremental cache); this component never writes it.
    /// - Returns: what each bounded attempt observed. The caller still owns the
    ///   fail-loud decision if the outcome did not settle.
    func terminateAndReboot(
        sessionIDs: [String],
        deadline: Date,
        hasTerminalTurn: @escaping @Sendable () async -> Bool
    ) async -> PhoneDSHAbortEscalationOutcome {
        var outcome = PhoneDSHAbortEscalationOutcome()
        guard !sessionIDs.isEmpty else { return outcome }
        let recovery = transport as? any PhoneDSHRecoveryCalling
        while outcome.attempts.count < maximumTerminations {
            guard Date() < deadline else { break }
            var attempt = PhoneDSHAbortEscalationAttempt()
            // The HELLO count belongs to the incarnation that is about to be
            // stopped. It is captured before any coordinator reset.
            let helloCount = await coordinator.helloCountValue()
            // Capture the connections that may still accept an inbound write
            // before the old Worker is stopped. Only a clean peer EOF (or a
            // receive loop that never started) proves a finished connection is
            // history; a retired boot id or an accepted mseq at/below the WAL
            // tail does not cover frames still queued in the socket/decoder.
            let drainConnectionIDs = await coordinator.connectionIDsToDrain()
            let terminating = engine as? any WebEngineWorkerTerminating
            var restartReport: WebEngineRestartReport?
            // The HELLO sequence is raised again by the fallback immediately
            // before its replacement restart: an interim page booted by the
            // first combined restart must never satisfy this wait.
            var replacementHelloSequence = helloCount

            if let terminating {
                // Arm the incarnation barrier before the stop: an old Worker
                // that reconnects during `terminateWorker()` registers as
                // untrusted and its retired boot id is rejected when its HELLO
                // arrives.
                await coordinator.armReplacementBarrier()

                // (1) Stop the old Worker first. Packing the overlay before it
                // is gone would publish a snapshot the old page can still
                // append behind; the replacement would then mount stale VFS
                // state even though the host WAL holds the newer writes.
                let terminateBudget = stepBudget(until: deadline, share: 0.3,
                                                 minimum: 0.5)
                let terminated = await phoneDSHResultWithinDeadline(terminateBudget) {
                    try await terminating.terminateWorker()
                }
                switch terminated {
                case .success?:
                    attempt.workerTerminated = true
                case .failure(let error)?:
                    attempt.lastError = "terminate: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "terminate timed out"
                    outcome.lastError = attempt.lastError
                }
                guard attempt.workerTerminated else {
                    outcome.attempts.append(attempt)
                    break
                }

                // (2) Stop the old connection before any replacement
                // transport is resolved. Closing it admits no further frame;
                // the wait then covers the handlers that were already
                // dispatching and the receive loop that was still unwinding.
                // It uses the whole drain deadline, and a non-quiescent
                // result fails the attempt instead of repacking a view that
                // may lag the WAL tail.
                let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
                    timeout: max(0, deadline.timeIntervalSinceNow),
                    requiringCleanEnd: drainConnectionIDs,
                    requiringCleanEndForUncaptured: true)
                guard quiet else {
                    // A non-quiescent close has already stopped the connection
                    // from taking new frames, but the decoded writes may still
                    // be dispatching. Do not retire the incarnation or clear
                    // its connections: a later attempt must not see an empty
                    // table and mistake that for quiescence. Fail the whole
                    // escalation instead; the Host stops after a non-retryable
                    // outcome and never packs on top of this state.
                    attempt.lastError = "the old Worker's inbound writes did not "
                        + "quiesce before the overlay repack"
                    outcome.lastError = attempt.lastError
                    outcome.nonRetryable = true
                    outcome.attempts.append(attempt)
                    break
                }
                await coordinator.prepareForReboot(retiringCurrentIncarnation: true)
                // A connection that registered while prepareForReboot closed
                // the previous sweep belongs to the stopped incarnation too.
                // Retire it before the pack so its socket cannot append a
                // frame behind the overlay the replacement mounts.
                let raceConnectionIDs = await coordinator.connectionIDs()
                await coordinator.retireReplacementCandidates(raceConnectionIDs)

                // (3) Repack only after the old Worker is gone and its accepted
                // inbound writes are durable in the materialized tree. The
                // materialized watermark must cover the WAL tail at pack time;
                // otherwise the replacement would mount a stale view.
                let packBudget = stepBudget(until: deadline, share: 0.3,
                                            minimum: 0.5)
                let packed = await phoneDSHResultWithinDeadline(packBudget) {
                    try await Self.packOverlayCoveringWALTail(log, bootID: bootID)
                }
                switch packed {
                case .success?:
                    attempt.packedOverlay = true
                case .failure(let error)?:
                    attempt.lastError = "overlay: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "overlay repack timed out"
                    outcome.lastError = attempt.lastError
                }
                guard attempt.packedOverlay else {
                    // Booting a stale overlay would lose writes that are in
                    // the WAL but not in the image. Fail this attempt instead.
                    outcome.attempts.append(attempt)
                    break
                }

                // (4) Boot the replacement page. The engine's restart lever
                // uses a fresh boot id; the loopback serves the overlay we just
                // packed for the host boot id. Without a restart report there
                // is no post-pack boot identity to bind to the replacement
                // HELLO, so an unverifiable page must never be adopted.
                guard engine is any WebEngineRestartRequesting else {
                    attempt.lastError = "the engine cannot report the replacement "
                        + "boot id; refusing to adopt an unverifiable Worker"
                    outcome.lastError = attempt.lastError
                    outcome.nonRetryable = true
                    outcome.attempts.append(attempt)
                    break
                }
                let restartBudget = stepBudget(until: deadline, share: 0.8,
                                               minimum: 0.75)
                let restarted = await phoneDSHResultWithinDeadline(restartBudget) {
                    try await Self.restart(engine)
                }
                switch restarted {
                case .success(let report)?:
                    restartReport = report
                case .failure(let error)?:
                    attempt.lastError = "restart: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "restart timed out"
                    outcome.lastError = attempt.lastError
                }
            } else {
                // Compatibility path for engines that only expose the combined
                // restart lever. There is no separate stop phase here: the
                // engine's `restart` is the only operation that actually
                // destroys the old Worker/WebContent, so it has to run before
                // the old connection is touched. A legacy engine whose page is
                // still alive can never satisfy the clean-EOF requirement, and
                // requiring it here used to make this whole path non-retryable
                // without ever packing or booting anything.
                //
                // The combined restart also boots an interim page before the
                // overlay is repacked. We use it only as the stop lever, drain
                // the connections it left behind, pack the overlay, and then
                // call the same lever once more to boot the replacement that
                // actually mounts the fresh image. The interim page receives no
                // host traffic in between.
                await coordinator.armReplacementBarrier()
                let stopBudget = stepBudget(until: deadline, share: 0.25,
                                            minimum: 0.25)
                let stopped = await phoneDSHResultWithinDeadline(stopBudget) {
                    try await Self.restart(engine)
                }
                switch stopped {
                case .success?:
                    attempt.workerTerminated = true
                case .failure(let error)?:
                    attempt.lastError = "terminate: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "terminate timed out"
                    outcome.lastError = attempt.lastError
                }
                guard attempt.workerTerminated else {
                    outcome.attempts.append(attempt)
                    break
                }

                // The combined restart returning successfully is not, by
                // itself, proof that the old page stopped before it could
                // append more VFS/journal writes. The captured pre-restart
                // connections therefore stay strict: they must reach a clean
                // peer EOF (or have never started) before the overlay is
                // packed. If this engine only manages a host close, an idle
                // watchdog end or a transport failure, the attempt fails loud
                // rather than accepting a socket that may still hide an
                // accepted write. A legacy engine that really destroyed the old
                // Worker produces that peer EOF when its page goes away.
                let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
                    timeout: max(0, deadline.timeIntervalSinceNow),
                    requiringCleanEnd: drainConnectionIDs)
                guard quiet else {
                    // Even the compatibility path must not pack over handlers
                    // that are still dispatching: the connection table stays
                    // intact and the whole drain fails loud.
                    attempt.lastError = "the old Worker's inbound writes did not "
                        + "quiesce before the overlay repack"
                    outcome.lastError = attempt.lastError
                    outcome.nonRetryable = true
                    outcome.attempts.append(attempt)
                    break
                }
                // The interim page can already own an accepted HELLO and a
                // live socket by the time the old connection drained. Clearing
                // the table in prepareForReboot also closes those sockets, so
                // the interim page cannot append a VFS/JOURNAL frame behind the
                // overlay this attempt is about to pack. A connection that
                // races the clear is retired before the pack too.
                await coordinator.prepareForReboot(retiringCurrentIncarnation: true)
                let raceConnectionIDs = await coordinator.connectionIDs()
                await coordinator.retireReplacementCandidates(raceConnectionIDs)
                let packBudget = stepBudget(until: deadline, share: 0.25,
                                            minimum: 0.25)
                let packed = await phoneDSHResultWithinDeadline(packBudget) {
                    try await Self.packOverlayCoveringWALTail(log, bootID: bootID)
                }
                switch packed {
                case .success?:
                    attempt.packedOverlay = true
                case .failure(let error)?:
                    attempt.lastError = "overlay: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "overlay repack timed out"
                    outcome.lastError = attempt.lastError
                }
                guard attempt.packedOverlay else {
                    outcome.attempts.append(attempt)
                    break
                }
                // A second combined restart can only be trusted when the
                // engine returns the post-pack boot id. Without it the wait
                // below would accept any new HELLO as the replacement, and a
                // delayed interim page could receive resume/cancel. Stop before
                // booting a page whose identity this interface cannot prove.
                guard engine is any WebEngineRestartRequesting else {
                    attempt.lastError = "the legacy engine cannot report the "
                        + "replacement boot id; refusing to adopt an unverifiable "
                        + "interim Worker"
                    outcome.lastError = attempt.lastError
                    outcome.nonRetryable = true
                    outcome.attempts.append(attempt)
                    break
                }
                // A connection that appears while the overlay packs belongs to
                // the old or interim page, never to the restart below. Capture
                // and close it before the replacement boots; retiring its id
                // also refuses a HELLO that races the restart.
                let preReplacementConnectionIDs = await coordinator.connectionIDs()
                await coordinator.retireReplacementCandidates(
                    preReplacementConnectionIDs)
                replacementHelloSequence = await coordinator.helloCountValue()
                // This is the boot whose HELLO/recovery the caller will use,
                // so only its report may bind the replacement barrier.
                restartReport = nil
                let restartBudget = stepBudget(until: deadline, share: 0.55,
                                               minimum: 0.1)
                let restarted = await phoneDSHResultWithinDeadline(restartBudget) {
                    try await Self.restart(engine)
                }
                switch restarted {
                case .success(let report)?:
                    restartReport = report
                case .failure(let error)?:
                    attempt.lastError = "restart: \(String(describing: error))"
                    outcome.lastError = attempt.lastError
                case nil:
                    attempt.lastError = "restart timed out"
                    outcome.lastError = attempt.lastError
                }
                // Retire the captured pre-restart sockets again: the sweep
                // before the restart may have suspended and a late interim
                // HELLO can arrive in that window. Only a connection created by
                // this restart can remain current.
                await coordinator.retireReplacementCandidates(
                    preReplacementConnectionIDs)
            }

            // (5) Wait for the replacement incarnation's HELLO. Without it the
            // recovery/cancel RPCs below would be addressed at the dead
            // connection. The coordinator installed an incarnation barrier
            // before the pack: a HELLO carrying an old boot id is rejected, and
            // once the engine's restart report is known only its boot id can
            // satisfy the wait (with the replaced session epoch and fence as
            // lower bounds).
            if attempt.workerTerminated {
                guard let replacementBootID = restartReport?.bootID else {
                    attempt.lastError = "the replacement restart did not report "
                        + "a boot id; refusing to accept an unidentifiable HELLO"
                    outcome.lastError = attempt.lastError
                    outcome.nonRetryable = true
                    outcome.attempts.append(attempt)
                    break
                }
                await coordinator.expectReplacementWorker(
                    bootID: replacementBootID)
                let helloBudget = stepBudget(until: deadline, share: 0.6,
                                             minimum: 0.25)
                if (try? await coordinator.waitForHello(
                        after: replacementHelloSequence,
                        expecting: replacementBootID,
                        timeout: helloBudget)) != nil {
                    attempt.freshWorkerReady = true
                } else {
                    attempt.lastError = "the replacement Worker did not complete HELLO"
                    outcome.lastError = attempt.lastError
                }
            }

            // (6) Let DSH close the interrupted turn itself. A fresh Worker
            // has no live Agent for `session/cancel` to address, and the pinned
            // session layer appends the `interrupted` tail closers in the
            // durable first phase of its resume path. The route performs that
            // repair without publishing an Agent (so a pending inbox prompt is
            // preserved) and without a prompt; Swift still verifies the
            // journal record below rather than trusting the route's answer.
            if attempt.freshWorkerReady, let recovery {
                var recoveryError: String?
                for sessionID in sessionIDs {
                    let budget = stepBudget(until: deadline, share: 0.6,
                                            minimum: 1.0)
                    guard budget > 0 else { break }
                    let repairBudget = PhoneDSHRecoveryBudget(
                        timeoutMilliseconds: Int((budget * 1_000).rounded(.down)),
                        maximumMilliseconds:
                            PhoneDSHRecoveryProtocol.maximumResumeBudgetMilliseconds)
                    let repaired = await phoneDSHResultWithinDeadline(budget) {
                        try await recovery.resumeSessionForRecovery(
                            sessionID, budget: repairBudget)
                    }
                    switch repaired {
                    case .success?:
                        attempt.recoveryResumed = true
                    case .failure(let error)?:
                        recoveryError = String(describing: error)
                    case nil:
                        recoveryError = "resume timed out for \(sessionID)"
                    }
                }
                if let recoveryError {
                    attempt.lastError = "resume: \(recoveryError)"
                    outcome.lastError = attempt.lastError
                }
            }

            // (7) Keep the public cancel as the second-best lever. On a fresh
            // Worker it may report `session/not-found` after the resume already
            // closed the turn; a successful cancel is still what closes a
            // Worker that recovered the session without the resume route.
            if attempt.freshWorkerReady {
                let harness = DSHRemoteHarness(transport: transport)
                var cancelError: String?
                for sessionID in sessionIDs {
                    let budget = stepBudget(until: deadline, share: 0.25,
                                            minimum: 0.1)
                    guard budget > 0 else { break }
                    let cancellation = await phoneDSHResultWithinDeadline(budget) {
                        try await harness.send(.cancel, to: sessionID)
                    }
                    switch cancellation {
                    case .success?:
                        attempt.cancelDelivered = true
                    case .failure(let error)?:
                        cancelError = String(describing: error)
                    case nil:
                        cancelError = "cancel timed out for \(sessionID)"
                    }
                }
                if let cancelError {
                    attempt.lastError = "cancel: \(cancelError)"
                    outcome.lastError = attempt.lastError
                }
            }

            // (8) Verify inside this attempt's own share of the window before
            // deciding to retry the termination. The caller re-reads the same
            // journal after this returns; this poll is what makes a retry
            // meaningful rather than another blind restart.
            let settleDeadline = Date().addingTimeInterval(
                stepBudget(until: deadline, share: 0.5, minimum: 0.15))
            while Date() < settleDeadline, Date() < deadline {
                if await hasTerminalTurn() {
                    attempt.sawTerminalTurn = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if attempt.sawTerminalTurn { outcome.lastError = nil }
            outcome.attempts.append(attempt)
            if attempt.sawTerminalTurn { break }
        }
        return outcome
    }

    /// Materializes the WAL and returns the boot overlay only when the
    /// materialized watermark covers the accepted WAL tail observed after the
    /// quiesce wait. `overlay()` materializes again, so a record appended
    /// between the check and the pack is still covered; a record appended
    /// after the pack is impossible once the old connection has closed.
    ///
    /// - Parameters:
    ///   - log: the workspace log whose materialized tree the replacement mounts.
    ///   - bootID: boot id whose overlay path the replacement loads.
    /// - Returns: the written overlay URL.
    private static func packOverlayCoveringWALTail(
        _ log: WorkspaceLog,
        bootID: String
    ) async throws -> URL {
        let materialized = try await log.materialize()
        let positions = await log.positions()
        guard materialized >= positions.ackedMseq else {
            throw PhoneDSHError.invalidState(
                "the materialized watermark \(materialized) is below the WAL tail "
                    + "\(positions.ackedMseq); refusing to pack a stale overlay")
        }
        return try await log.overlay(bootID: bootID)
    }

    /// One bounded step of the escalation, never past `deadline`.
    ///
    /// - Parameters:
    ///   - deadline: the outer verification deadline.
    ///   - share: fraction of the remaining window this step may use.
    ///   - minimum: floor that keeps a step schedulable in a short window.
    /// - Returns: seconds to allow, `0` when the window is exhausted.
    private func stepBudget(until deadline: Date, share: Double, minimum: TimeInterval) -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return 0 }
        return min(remaining, max(minimum, remaining * share))
    }

    /// Terminates the current Worker/WebContent and boots another.
    ///
    /// The preferred lever is the engine's restart report API
    /// (``WebEngineRestartRequesting``); the W0 skeleton's
    /// ``WebEngineControlling/restart()`` remains the fallback. Neither method
    /// writes a DSH session record.
    private static func restart(_ engine: any WebEngineControlling) async throws
        -> WebEngineRestartReport? {
        if let requesting = engine as? WebEngineRestartRequesting {
            return try await requesting.restart(reason: .webContentTerminated)
        } else {
            try await engine.restart()
            return nil
        }
    }
}
