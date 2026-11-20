// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the host timer and OS-channel projector for WakeDemands.
//
// host contract `spec/host/v1/README.md` §10.3.3–§10.3.4: the projection is a
// pure function of `(nowMs, resident, demands)`. While resident, one host timer
// fires at `residentTimerAtMs` and asks the orchestrator for a
// `.scheduledDemand` wake. Every ledger change, every background entry and
// every park recomputes the projection and submits `backgroundEarliestMs` to
// `BGAppRefreshTask` and `BGProcessingTask` — resident or not, because
// suspension can happen at any moment. A lost wake only delays work: the next
// wake of any kind runs every due demand.

import Foundation

@MainActor
public final class WakeScheduler {
    /// The three things the scheduler cannot own itself: the one wake entry,
    /// the OS projection, and whether the process is resident (foreground or
    /// held by an existing audio keep-alive — never created here).
    public struct Projection {
        /// Asks the orchestrator for one `.scheduledDemand` wake. `nil` lease:
        /// a resident host timer is authorized by foreground/resident audio,
        /// never by a fabricated deadline.
        public let wake: @MainActor () async -> Void
        /// Submits (or cancels, when `nil`) the background-task projection for
        /// `backgroundEarliestMs`.
        public let project: @MainActor (_ backgroundEarliestMs: Int64?) -> Void
        /// True while the process is in the foreground or held by an existing
        /// audio keep-alive.
        public let isResident: @MainActor () -> Bool

        public init(wake: @escaping @MainActor () async -> Void,
                    project: @escaping @MainActor (Int64?) -> Void,
                    isResident: @escaping @MainActor () -> Bool) {
            self.wake = wake
            self.project = project
            self.isResident = isResident
        }
    }

    private let ledger: WakeDemandLedger
    private let projection: Projection
    private var timerTask: Task<Void, Never>?
    private var running = false
    private var projected = false
    private var projectedBackground: Int64?
    /// Last ledger availability error, for diagnostics. The previous
    /// projection is kept: an unreadable ledger is retried, never replaced.
    public private(set) var lastError: WakeDemandLedgerError?

    public init(ledger: WakeDemandLedger, projection: Projection) {
        self.ledger = ledger
        self.projection = projection
    }

    public func start() {
        guard !running else { return }
        running = true
        Task { await refresh() }
    }

    public func stop() {
        running = false
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Ledger writes (each one re-projects)

    public func upsert(_ demand: WakeDemand) async throws {
        try await ledger.upsert(demand)
        await refresh()
    }

    public func remove(source: WakeDemandSource, key: String) async throws {
        try await ledger.remove(source: source, key: key)
        await refresh()
    }

    public func removeAll(source: WakeDemandSource) async throws {
        try await ledger.removeAll(source: source)
        await refresh()
    }

    // MARK: - Reads

    public func demands() async throws -> [WakeDemand] {
        try await ledger.all()
    }

    public func dueDemands(source: WakeDemandSource, nowMs: Int64) async throws -> [WakeDemand] {
        try await ledger.dueDemands(source: source, nowMs: nowMs)
    }

    public func nextDemand() async throws -> WakeDemand? {
        try await ledger.nextDemand()
    }

    /// The projection for the current ledger and residency (diagnostics/tests).
    public func plan(nowMs: Int64 = WakeDemandLedger.nowMs()) async throws -> WakeProjection {
        WakeProjection.plan(nowMs: nowMs, resident: projection.isResident(),
                            demands: try await ledger.all())
    }

    // MARK: - Projection

    /// Recomputes the projection and re-arms the resident timer. Called after
    /// every ledger write, on start, and when the App returns to the
    /// foreground (residency may have changed).
    public func refresh() async {
        guard running else { return }
        let now = WakeDemandLedger.nowMs()
        let demands: [WakeDemand]
        do {
            demands = try await ledger.all()
            lastError = nil
        } catch {
            // Protected data not available yet (or an I/O failure): keep the
            // previous projection and retry on the next ledger change, unlock
            // or wake. Never project an empty ledger over a real one.
            lastError = error as? WakeDemandLedgerError
            return
        }
        let plan = WakeProjection.plan(nowMs: now, resident: projection.isResident(),
                                       demands: demands)
        if !projected || projectedBackground != plan.backgroundEarliestMs {
            projected = true
            projectedBackground = plan.backgroundEarliestMs
            projection.project(plan.backgroundEarliestMs)
        }
        rearm(plan.residentTimerAtMs, nowMs: now)
    }

    /// The App is leaving the foreground / a host is about to park (I5): the
    /// resident timer may not run, so submit the projection to the OS now.
    public func enterBackground() async {
        let now = WakeDemandLedger.nowMs()
        let demands: [WakeDemand]
        do {
            demands = try await ledger.all()
            lastError = nil
        } catch {
            lastError = error as? WakeDemandLedgerError
            return
        }
        let plan = WakeProjection.plan(nowMs: now, resident: projection.isResident(),
                                       demands: demands)
        projected = true
        projectedBackground = plan.backgroundEarliestMs
        projection.project(plan.backgroundEarliestMs)
        rearm(plan.residentTimerAtMs, nowMs: now)
    }

    private func rearm(_ residentTimerAtMs: Int64?, nowMs: Int64) {
        timerTask?.cancel()
        timerTask = nil
        guard running, let fireAt = residentTimerAtMs else { return }
        let delayMs = max(0, fireAt - nowMs)
        timerTask = Task { @MainActor [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.timerTask = nil
            await self.projection.wake()
            // Deliberately no immediate re-arm: a due demand that its producer
            // has not yet acknowledged must not spin the timer. The producer's
            // next ledger write (or the next external wake) re-arms.
        }
    }
}
