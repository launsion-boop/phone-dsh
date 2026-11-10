// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — controllable scheduler clock.
//
// The production composition accepts an optional `now`/`sleep` seam for
// `RoutineScheduler`; the eval runner connects both here. A short scheduler
// interval sleep parks until `advance(seconds:)`, while the long routine
// deadline sleeps keep the real clock so a mock routine cannot be reported as
// timed out just because the scenario clock moved.

import Foundation
import PhoneDSHBot

final class EvalSchedulerClock: @unchecked Sendable {
    /// Long sleeps (the routine run/cancel deadline) stay real; only the
    /// scheduler's short tick interval is controlled by this clock.
    private static let controlledSleepCeilingMs: Int64 = 60_000

    private let lock = NSLock()
    private var currentMs: Int64
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWake = false

    init(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.currentMs = now
    }

    /// Scheduler clock, in epoch milliseconds.
    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return currentMs
    }

    /// Moves the scheduler clock forward and wakes one scheduler tick. When a
    /// tick is already in flight there is no sleeper to resume, so the next
    /// `sleep` consumes the pending wake and runs the tick immediately.
    func advance(seconds: Int64) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            currentMs += max(0, seconds) * 1000
            if self.waiters.isEmpty {
                self.pendingWake = true
                return []
            }
            let pending = self.waiters
            self.waiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    /// `RoutineScheduler.Sleeper` body for the injected seam.
    func sleep(milliseconds: Int64) async {
        if milliseconds > Self.controlledSleepCeilingMs {
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            return
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingWake {
                pendingWake = false
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Releases every parked sleeper so a stopped scheduler task can observe
    /// cancellation and exit. Safe to call more than once.
    func wakeAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let pending = self.waiters
            self.waiters.removeAll()
            self.pendingWake = false
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}
