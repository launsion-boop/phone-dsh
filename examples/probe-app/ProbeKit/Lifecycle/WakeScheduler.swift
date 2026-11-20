// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the host timer and OS-channel projector for WakeDemands.
//
// PLAN §2.9 I5: while the process is resident, one host timer fires at the
// earliest `dueAt` and asks the orchestrator for a `.scheduledDemand` wake.
// On every ledger change — and again when the App is about to leave the
// foreground — the earliest due time is projected onto the OS channels the App
// has: BGAppRefreshTask, BGProcessingTask and (for `userVisible` demands) a
// local notification. A lost wake only delays work: the next wake sweeps every
// due demand from the durable ledger.

import Foundation

@MainActor
public final class WakeScheduler {
    /// The two things the scheduler cannot own itself: the one wake entry and
    /// the OS projection. Both are injected by the App.
    public struct Projection {
        /// Asks the orchestrator for one `.scheduledDemand` wake. `nil` lease:
        /// a resident host timer is authorized by foreground/resident audio,
        /// never by a fabricated deadline.
        public let wake: @MainActor () async -> Void
        /// Submits (or cancels, when `nil`) the background-task projection for
        /// this earliest due time.
        public let project: @MainActor (_ earliestDueAtMs: Int64?) -> Void

        public init(wake: @escaping @MainActor () async -> Void,
                    project: @escaping @MainActor (Int64?) -> Void) {
            self.wake = wake
            self.project = project
        }
    }

    private let ledger: WakeDemandLedger
    private let projection: Projection
    private var timerTask: Task<Void, Never>?
    private var running = false
    private var projected = false
    private var projectedEarliest: Int64?

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

    public func demands() async -> [WakeDemand] {
        await ledger.all()
    }

    public func dueDemands(source: WakeDemandSource, nowMs: Int64) async -> [WakeDemand] {
        await ledger.dueDemands(source: source, nowMs: nowMs)
    }

    public func nextDemand() async -> WakeDemand? {
        await ledger.nextDemand()
    }

    // MARK: - Projection

    /// Recomputes the resident timer and re-projects when the earliest due
    /// time changed. Called after every ledger write and at start.
    public func refresh() async {
        guard running else { return }
        let next = await ledger.nextDemand()
        if !projected || projectedEarliest != next?.dueAtMs {
            projected = true
            projectedEarliest = next?.dueAtMs
            projection.project(next?.dueAtMs)
        }
        rearm(next: next)
    }

    /// The App is leaving the foreground (or the host is about to park): the
    /// resident timer will not run, so project the earliest due time now.
    public func enterBackground() async {
        projected = true
        projectedEarliest = await ledger.earliestDueAt()
        projection.project(projectedEarliest)
    }

    private func rearm(next: WakeDemand?) {
        timerTask?.cancel()
        timerTask = nil
        guard running, let next else { return }
        let now = WakeDemandLedger.nowMs()
        let delayMs = max(0, next.dueAtMs - now)
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
