// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Phone-side client for the reliable cloud scheduler (`spec/cloud/v1`, G-3B).
///
/// Division of responsibility (A09/E7):
/// - the cloud stores opaque ids, times, revisions, leases and receipts and
///   computes due occurrences; it never stores prompts, messages, results or
///   credentials and never runs an agent;
/// - this client turns a leased occurrence into an ordinary local routine run
///   through `RoutineScheduler.runCloudOccurrence`, dedupes by the
///   deterministic occurrence run id and reports a closed outcome.
///
/// The client keeps no durable wake/receipt queue: the cloud event log is the
/// durable inbox, and the local `RoutineDocument` already records the run that
/// an occurrence produced. After a process restart the client reconciles the
/// cloud state, compares it with the local run record and only then writes a
/// receipt, so an unknown outcome is never blindly replayed (A08).
public actor CloudScheduleClient {
    public struct Configuration: Sendable, Equatable {
        /// Events per poll/reconcile page. Contract: 1..32.
        public var pageLimit: Int
        /// Lease requested from the cloud. Contract: 1..900; the routine run
        /// budget is 600 s + 5 s cancel grace by default, so ask for 660 s.
        public var leaseSeconds: Int
        /// Cadence while the app is active.
        public var activeIntervalMS: Int64
        /// First retry delay after a retryable failure.
        public var baseBackoffMS: Int64
        /// Upper bound for retry delay.
        public var maxBackoffMS: Int64
        /// A server/local clock difference above this is treated as an error.
        public var maxClockSkewMS: Int64
        /// Do not start a run when the lease has less than this much time left
        /// beyond the run budget.
        public var leaseStartGuardMS: Int64
        /// Reconcile pages fetched in one pass.
        public var maxReconcilePages: Int

        public init(pageLimit: Int = 16, leaseSeconds: Int = 660,
                    activeIntervalMS: Int64 = 60_000, baseBackoffMS: Int64 = 1_000,
                    maxBackoffMS: Int64 = 300_000, maxClockSkewMS: Int64 = 300_000,
                    leaseStartGuardMS: Int64 = 30_000, maxReconcilePages: Int = 8) {
            self.pageLimit = max(1, min(32, pageLimit))
            self.leaseSeconds = max(1, min(900, leaseSeconds))
            self.activeIntervalMS = max(1_000, activeIntervalMS)
            self.baseBackoffMS = max(100, baseBackoffMS)
            self.maxBackoffMS = max(self.baseBackoffMS, maxBackoffMS)
            self.maxClockSkewMS = max(1_000, maxClockSkewMS)
            self.leaseStartGuardMS = max(0, leaseStartGuardMS)
            self.maxReconcilePages = max(1, maxReconcilePages)
        }
    }

    public enum CycleResult: Sendable, Equatable {
        /// Nothing to do (no events, or not started/active).
        case idle
        /// Registrations/removals were pushed to the cloud.
        case synced(Int)
        /// Events were executed or resolved with a receipt.
        case processed(Int)
        /// The engine is not ready or the scheduler owns a run; keep leases.
        case notReady
        /// The lease is too short to start a run; let it expire or reconcile.
        case leaseTooShort
        /// The cycle failed; `diagnostic` is a stable code without user text.
        case failed(String)
    }

    public nonisolated let botID: String
    public nonisolated let deviceID: String
    public nonisolated let configuration: Configuration

    private let transport: any CloudScheduleTransport
    private let machine: RoutineMachine
    private let scheduler: RoutineScheduler
    private let readiness: @Sendable () async -> Bool
    private let authorizer: any CloudScheduleAuthorizing
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async -> Void

    private var started = false
    private var active = false
    private var loopTask: Task<Void, Never>?
    private var cycleInFlight = false
    private var needsFullSync = true
    private var needsReconcile = true
    private var reconcileCursorMS: Int64 = 0
    private var backoffMS: Int64 = 0
    private var serverOffsetMS: Int64 = 0
    private struct SyncedState: Sendable, Equatable {
        var seq: Int64
        var enabled: Bool
    }

    private var lastKnownCloud: [String: RoutineCloudSchedule] = [:]
    private var syncedState: [String: SyncedState] = [:]
    private var pendingDeletions: [String: Int64] = [:]
    private var lastDiagnostic: String?

    public init(botID: String, deviceID: String,
                transport: any CloudScheduleTransport,
                machine: RoutineMachine, scheduler: RoutineScheduler,
                authorizer: any CloudScheduleAuthorizing = CloudScheduleAuthorizer(),
                readiness: @escaping @Sendable () async -> Bool,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleep: @escaping @Sendable (Int64) async -> Void = { milliseconds in
                    guard milliseconds > 0 else { return }
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                },
                configuration: Configuration = Configuration()) {
        self.botID = botID
        self.deviceID = deviceID
        self.transport = transport
        self.machine = machine
        self.scheduler = scheduler
        self.authorizer = authorizer
        self.readiness = readiness
        self.now = now
        self.sleep = sleep
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        active = true
        needsFullSync = true
        needsReconcile = true
        startLoop()
    }

    public func stop() {
        started = false
        active = false
        loopTask?.cancel()
        loopTask = nil
    }

    /// Foreground/scene activation: one immediate cycle, then the normal
    /// active cadence. The client never claims WebView liveness; while the app
    /// is suspended the cloud event log simply keeps pending events.
    public func activate() async {
        active = true
        needsFullSync = true
        if started { startLoop() }
        _ = await runCycle()
    }

    public func deactivate() {
        active = false
    }

    /// Any routine consent/schedule edit calls this. A full re-sync is cheap
    /// (opaque ids + timing only) and heals a server that lost its schedule
    /// rows; only changed routines produce a routine snapshot write.
    public func noteSchedulesChanged() {
        needsFullSync = true
    }

    public func currentDiagnostic() -> String? { lastDiagnostic }
    public func clockOffsetMS() -> Int64 { serverOffsetMS }

    // MARK: - Test / integration entry points

    /// One complete sync → reconcile → poll cycle without the loop. Tests and
    /// the E integration harness drive this directly with a controllable
    /// clock/transport; production uses `start()`/`activate()`.
    @discardableResult
    public func pollOnce() async -> CycleResult {
        await runCycle()
    }

    @discardableResult
    public func synchronizeNow() async -> CycleResult {
        do {
            let count = try await synchronize(force: true)
            return .synced(count)
        } catch let error as CloudScheduleTransportError {
            noteFailure(error)
            return .failed(error.diagnosticCode)
        } catch {
            noteFailure(nil)
            return .failed("transport")
        }
    }

    // MARK: - Loop

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.isRunning() else { return }
                if await self.isActive() {
                    _ = await self.runCycle()
                    await self.sleep(await self.nextDelay())
                } else {
                    await self.sleep(1_000)
                }
            }
        }
    }

    private func isRunning() -> Bool { started }
    private func isActive() -> Bool { active }
    private func nextDelay() -> Int64 {
        backoffMS > 0 ? min(backoffMS, configuration.maxBackoffMS) : configuration.activeIntervalMS
    }

    // MARK: - Cycle

    @discardableResult
    private func runCycle() async -> CycleResult {
        guard !cycleInFlight else { return .idle }
        cycleInFlight = true
        defer { cycleInFlight = false }
        do {
            if needsReconcile {
                let reconciled = try await reconcilePending()
                if reconciled > 0 { return .processed(reconciled) }
            }
            if needsFullSync || hasPendingSyncs() {
                _ = try await synchronize(force: needsFullSync)
            }
            guard await readiness() else { return .notReady }
            let poll = try await transport.poll(CloudSchedulePollRequest(
                deviceID: deviceID, botID: botID,
                limit: configuration.pageLimit,
                leaseSeconds: configuration.leaseSeconds))
            noteServerTime(poll.serverTimeMS)
            let result = try await process(poll.events)
            backoffMS = 0
            lastDiagnostic = nil
            switch result {
            case .processed(let count):
                return count > 0 ? .processed(count) : .idle
            case .notReady:
                return .notReady
            case .leaseTooShort:
                return .leaseTooShort
            }
        } catch let error as CloudScheduleTransportError {
            if case .cancelled = error { return .idle }
            noteFailure(error)
            return .failed(error.diagnosticCode)
        } catch is CancellationError {
            return .idle
        } catch {
            noteFailure(nil)
            return .failed("transport")
        }
    }

    private func noteFailure(_ error: CloudScheduleTransportError?) {
        lastDiagnostic = error?.diagnosticCode ?? "transport"
        let retryAfter: Int64? = {
            guard let error else { return nil }
            switch error {
            case .rateLimited(let retryAfterMS), .server(_, let retryAfterMS):
                return retryAfterMS
            default:
                return nil
            }
        }()
        if let retryAfter, retryAfter > 0 {
            backoffMS = min(max(retryAfter, configuration.baseBackoffMS), configuration.maxBackoffMS)
            return
        }
        let doubled = backoffMS == 0
            ? configuration.baseBackoffMS
            : min(backoffMS * 2, configuration.maxBackoffMS)
        backoffMS = max(configuration.baseBackoffMS, doubled)
    }

    private func noteServerTime(_ serverTimeMS: Int64) {
        guard serverTimeMS > 0 else { return }
        serverOffsetMS = serverTimeMS - now()
        if abs(serverOffsetMS) > configuration.maxClockSkewMS {
            lastDiagnostic = "clock_skew"
        }
    }

    private func serverNow() -> Int64 { now() + serverOffsetMS }

    // MARK: - Sync

    private func hasPendingSyncs() -> Bool {
        !pendingDeletions.isEmpty
    }

    @discardableResult
    private func synchronize(force: Bool) async throws -> Int {
        let routines = (try? await machine.list(botId: botID)) ?? []
        var current: [String: RoutineCloudSchedule] = [:]
        var registrations: [CloudScheduleRegistration] = []
        var removed: [CloudScheduleRemoval] = []
        for routine in routines {
            guard let cloud = routine.cloudSchedule else { continue }
            current[routine.id] = cloud
            let enabled = cloud.enabled && routine.enabled
            let synced = syncedState[routine.id]
            if enabled {
                // A phased interval is not representable in the frozen wire
                // (local phase is an arbitrary interval offset, wire phase is
                // 0–59 minute-of-hour). Fail closed: keep it local instead of
                // registering a different schedule.
                guard routine.schedule.phaseMinutes == nil else {
                    lastDiagnostic = "phase_unsupported:\(routine.id)"
                    continue
                }
                guard force || synced == nil || synced?.seq != cloud.seq
                    || synced?.enabled != true else { continue }
                registrations.append(CloudScheduleRegistration(
                    routineID: routine.id, botID: botID, revision: cloud.seq,
                    enabled: true, schedule: CloudScheduleSpec(routine.schedule),
                    catchUp: "latest", authorizationRef: cloud.authorizationRef,
                    operation: synced == nil ? "register" : "update"))
            } else {
                guard force || synced == nil || synced?.seq != cloud.seq
                    || synced?.enabled != false else { continue }
                // DELETE must name the revision the cloud currently has, not
                // the newly bumped local revision: disabling the routine
                // advances seq locally while the server still holds the last
                // accepted revision.
                let expected = synced?.seq ?? cloud.seq
                removed.append(CloudScheduleRemoval(routineID: routine.id, revision: expected))
            }
        }
        for (routineID, last) in lastKnownCloud where current[routineID] == nil {
            // A routine deleted while this client was running. After a cold
            // start the id is unknown; the first wake for it is refused and
            // cancelled, which heals the stale server row.
            pendingDeletions[routineID] = max(1, last.seq)
        }
        for (routineID, revision) in pendingDeletions
        where !removed.contains(where: { $0.routineID == routineID }) {
            removed.append(CloudScheduleRemoval(routineID: routineID, revision: revision))
        }
        lastKnownCloud = current
        guard force || !registrations.isEmpty || !removed.isEmpty else { return 0 }
        let response = try await transport.sync(CloudScheduleSyncRequest(
            deviceID: deviceID, botID: botID,
            registrations: registrations, removed: removed))
        noteServerTime(response.serverTimeMS)
        for registration in response.accepted {
            syncedState[registration.routineID] = SyncedState(
                seq: registration.revision, enabled: true)
        }
        for routineID in response.removedAccepted {
            pendingDeletions.removeValue(forKey: routineID)
            if let revision = response.removedRevisions[routineID] {
                syncedState[routineID] = SyncedState(seq: revision, enabled: false)
            } else if let request = removed.first(where: { $0.routineID == routineID }) {
                syncedState[routineID] = SyncedState(seq: request.revision, enabled: false)
            }
        }
        if !response.rejected.isEmpty {
            needsFullSync = true
        } else {
            needsFullSync = false
        }
        for rejection in response.rejected {
            lastDiagnostic = "sync:\(rejection.routineID):\(rejection.code)"
            if rejection.code == "revision_conflict" {
                // The cloud already has a newer revision (for example a
                // previous sync succeeded but the local store was restored
                // from a backup). Move the local revision past it and retry;
                // never lower the cloud's revision. When the error does not
                // carry the current revision, advance by one so successive
                // cycles still converge instead of repeating the same sync.
                let current = rejection.currentRevision
                    ?? ((lastKnownCloud[rejection.routineID]?.seq ?? 0) + 1)
                _ = try? await machine.advanceCloudScheduleRevision(
                    botId: botID, routineId: rejection.routineID,
                    atLeast: current, now: now())
                needsFullSync = true
            }
        }
        return response.accepted.count + response.removedAccepted.count
    }

    // MARK: - Reconcile (unknown outcome first, never blind replay)

    @discardableResult
    private func reconcilePending() async throws -> Int {
        var since = reconcileCursorMS
        var pages = 0
        var processed = 0
        repeat {
            let page = try await transport.reconcile(CloudScheduleReconcileRequest(
                deviceID: deviceID, sinceMS: since, limit: configuration.pageLimit))
            noteServerTime(page.serverTimeMS)
            if page.nextCursorMS > since { since = page.nextCursorMS }
            for event in page.events where event.botID == botID {
                switch try await processEvent(event) {
                case .processed: processed += 1
                case .ignored, .notReady, .leaseTooShort: continue
                }
            }
            pages += 1
            if page.events.count < configuration.pageLimit { break }
        } while pages < configuration.maxReconcilePages
        reconcileCursorMS = since
        needsReconcile = false
        return processed
    }

    // MARK: - Events

    private enum EventProcessing: Sendable, Equatable {
        case processed
        case ignored
        case notReady
        case leaseTooShort
    }

    private enum ProcessResult: Sendable, Equatable {
        case processed(Int)
        case notReady
        case leaseTooShort
    }

    private func process(_ events: [CloudScheduleEvent]) async throws -> ProcessResult {
        guard !events.isEmpty else { return .processed(0) }
        let sorted = events
            .filter { $0.botID == botID }
            .sorted { ($0.occurrenceAtMS, $0.eventID) < ($1.occurrenceAtMS, $1.eventID) }
        var latestByRoutine: [String: CloudScheduleEvent] = [:]
        for event in sorted { latestByRoutine[event.routineID] = event }
        let groups = latestByRoutine.values.sorted {
            ($0.occurrenceAtMS, $0.eventID) < ($1.occurrenceAtMS, $1.eventID)
        }
        var processed = 0
        for chosen in groups {
            // Coalesce older pending occurrences of the same routine: the
            // v2 "missed runs are caught up at most once" rule. The newest
            // occurrence is the one that may run.
            for older in sorted where older.routineID == chosen.routineID
                && older.eventID != chosen.eventID {
                try await acknowledge(older, outcome: .skipped, reason: .superseded)
                processed += 1
            }
            switch try await processEvent(chosen) {
            case .processed: processed += 1
            case .ignored: continue
            case .notReady:
                return processed > 0 ? .processed(processed) : .notReady
            case .leaseTooShort:
                return processed > 0 ? .processed(processed) : .leaseTooShort
            }
        }
        return .processed(processed)
    }

    private func processEvent(_ event: CloudScheduleEvent) async throws -> EventProcessing {
        guard event.botID == botID else { return .ignored }
        guard event.deviceID == deviceID else { return .ignored }
        guard await readiness() else { return .notReady }
        guard let routine = try? await machine.get(botId: botID, routineId: event.routineID) else {
            try await acknowledge(event, outcome: .skipped, reason: .disabled)
            try? await transport.cancelRoutine(CloudScheduleCancelRequest(
                deviceID: deviceID, routineID: event.routineID,
                expectedRevision: event.scheduleRevision))
            return .processed
        }
        if let refusal = await authorizer.refusal(for: routine) {
            try await acknowledge(event, outcome: .skipped, reason: refusal)
            if refusal == .revoked || refusal == .disabled {
                try? await transport.cancelRoutine(CloudScheduleCancelRequest(
                    deviceID: deviceID, routineID: event.routineID,
                    expectedRevision: routine.cloudSchedule?.seq ?? event.scheduleRevision))
            }
            return .processed
        }
        if routine.cloudSchedule?.seq != event.scheduleRevision {
            // The event was produced for an older authorization/schedule
            // revision. Do not run it; ask for a full re-sync.
            try await acknowledge(event, outcome: .skipped, reason: .revoked)
            needsFullSync = true
            return .processed
        }
        let budget = await scheduler.cloudRunBudgetMs
        let remaining = event.lease.expiresAtMS - serverNow()
        guard remaining > budget + configuration.leaseStartGuardMS else {
            return .leaseTooShort
        }
        let run = await scheduler.runCloudOccurrence(
            routineId: event.routineID,
            occurrenceKey: event.occurrenceKey,
            scheduledFor: event.occurrenceAtMS)
        switch run {
        case .notReady:
            return .notReady
        case .skipped(let reason):
            if reason == "in_progress" { return .notReady }
            try await acknowledge(event, outcome: .skipped, reason: Self.reason(fromSkip: reason))
            return .processed
        case .waitingApproval:
            try await acknowledge(event, outcome: .skipped, reason: .needsReconciliation)
            return .processed
        case .settled(let status, _, _):
            try await acknowledge(event, outcome: Self.outcome(fromSettled: status),
                                  reason: Self.reason(fromSettled: status))
            return .processed
        case .alreadySettled(let status, _, _):
            // A local run already covered this occurrence: resolve the cloud
            // event from the local record, never by running it again.
            try await acknowledge(event, outcome: Self.outcome(fromSettled: status),
                                  reason: Self.reason(fromAlreadySettled: status))
            return .processed
        }
    }

    private func acknowledge(_ event: CloudScheduleEvent,
                             outcome: CloudScheduleOutcome,
                             reason: CloudScheduleReason?) async throws {
        let request = CloudScheduleReceiptRequest(
            deviceID: deviceID, eventID: event.eventID,
            receiptID: Self.receiptID(eventID: event.eventID,
                                      occurrenceKey: event.occurrenceKey),
            occurrenceKey: event.occurrenceKey, outcome: outcome, reason: reason,
            completedAtMS: now(), localRunID: event.localRunID)
        do {
            _ = try await transport.acknowledge(request)
        } catch let error as CloudScheduleTransportError {
            if case .conflict = error {
                // A terminal decision already won (cancel or another ACK).
                // Reconcile on the next cycle decides the event state; never
                // re-run because a receipt was rejected.
                lastDiagnostic = error.diagnosticCode
                return
            }
            throw error
        }
    }

    // MARK: - Mapping (frozen closed enums only)

    private static func outcome(fromSettled status: RoutineRunStatus) -> CloudScheduleOutcome {
        switch status {
        case .succeeded: return .delivered
        case .cancelled: return .cancelled
        case .needsReconciliation: return .unknown
        case .failed, .timedOut: return .failed
        case .scheduled, .started, .waitingApproval: return .failed
        }
    }

    private static func reason(fromSettled status: RoutineRunStatus) -> CloudScheduleReason? {
        switch status {
        case .succeeded, .cancelled: return nil
        case .timedOut: return .timeout
        case .needsReconciliation: return .needsReconciliation
        case .failed: return .runFailed
        case .scheduled, .started, .waitingApproval: return .needsReconciliation
        }
    }

    private static func reason(fromAlreadySettled status: RoutineRunStatus) -> CloudScheduleReason? {
        switch status {
        case .succeeded, .cancelled: return nil
        case .failed: return .localAttempt
        case .timedOut: return .timeout
        case .needsReconciliation: return .needsReconciliation
        case .waitingApproval: return .needsReconciliation
        case .scheduled, .started: return .localAttempt
        }
    }

    private static func reason(fromSkip reason: String) -> CloudScheduleReason {
        switch reason {
        case "overlap": return .overlap
        case "quiet": return .quiet
        case "disabled": return .disabled
        case "revoked": return .revoked
        case "superseded": return .superseded
        case "needs_reconciliation": return .needsReconciliation
        case "waiting_approval": return .needsReconciliation
        default: return .unavailable
        }
    }

    /// Stable per (event, occurrence) idempotency key. The same key is reused
    /// when a receipt is retried after an ACK loss, so the server can
    /// first-wins it.
    public static func receiptID(eventID: String, occurrenceKey: String) -> String {
        let digest = SHA256.hash(data: Data("receipt:\(eventID):\(occurrenceKey)".utf8))
        return "r-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
