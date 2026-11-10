// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — foreground-only elapsed time.
//
// A phone App is frozen whenever it leaves the foreground; the wall clock keeps
// running while its tasks do not. The resume budgets and the boot-timings line
// must describe work the process actually performed, so both subtract the
// background intervals. This is a small lock-protected value because the host
// reads it from the coordinator actor while `setForeground` runs on the main
// actor.

import Foundation

/// Accumulates elapsed time only while the App is in the foreground.
///
/// The caller marks the two scene-phase edges with ``setForeground(_:at:)`` and
/// samples ``activeMilliseconds(at:)``. A sample during a background interval
/// returns the accumulated foreground duration without the frozen tail.
public final class PhoneDSHForegroundClock: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground: Bool
    private var accumulated: TimeInterval
    private var intervalStartedAt: Date

    /// - Parameters:
    ///   - isForeground: the phase at construction; the host defaults to the
    ///     historical "foreground until told otherwise" rule.
    ///   - now: injectable wall clock for tests.
    public init(isForeground: Bool = true, now: Date = Date()) {
        self.foreground = isForeground
        self.accumulated = 0
        self.intervalStartedAt = now
    }

    /// Applies one scene-phase edge. Repeating the current phase is a no-op, so
    /// a duplicated `.inactive` cannot drop foreground time.
    public func setForeground(_ value: Bool, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard foreground != value else { return }
        if foreground {
            accumulated += max(0, date.timeIntervalSince(intervalStartedAt))
        }
        foreground = value
        intervalStartedAt = date
    }

    /// Whether the App is currently in the foreground.
    public var isForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foreground
    }

    /// Foreground seconds accumulated up to `date`.
    public func activeSeconds(at date: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard foreground else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(intervalStartedAt))
    }

    /// Foreground milliseconds accumulated up to `date`.
    public func activeMilliseconds(at date: Date = Date()) -> Double {
        activeSeconds(at: date) * 1_000
    }
}
