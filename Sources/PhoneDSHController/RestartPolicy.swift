// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: when a planned WebContent
// restart is justified.
//
// The old policy was a fixed two-hour timer: it restarted healthy engines and
// still restarted nothing when memory was actually tight. The triggers now
// describe a reason (pressure, a WebContent death, a long uptime) and the
// restart still executes only at a tool-call boundary, where no turn is in
// flight.

import Foundation

public struct RestartPolicy: Equatable, Sendable {
    public enum Trigger: String, Equatable, Sendable {
        /// Engine heap above `heapFraction` of the tier budget for
        /// `requiredSamples` consecutive samples.
        case heapPressure
        /// The WebContent process died at least once since the last restart.
        case webContentTermination
        /// Continuous uptime reached `maximumUptime`.
        case maximumUptime
    }

    /// 24 h of continuous running is the ceiling; below it only a symptom
    /// triggers a restart.
    public var maximumUptime: TimeInterval
    /// Fraction of the tier's engine-heap budget that counts as pressure.
    public var heapFraction: Double
    /// Consecutive high samples before the pressure trigger fires.
    public var requiredSamples: Int
    /// How often the caller samples (the reason a run must last this long).
    public var sampleInterval: TimeInterval

    public init(maximumUptime: TimeInterval = 24 * 60 * 60,
                heapFraction: Double = 0.75,
                requiredSamples: Int = 3,
                sampleInterval: TimeInterval = 60) {
        self.maximumUptime = maximumUptime
        self.heapFraction = max(0, min(1, heapFraction))
        self.requiredSamples = max(1, requiredSamples)
        self.sampleInterval = max(1, sampleInterval)
    }

    /// The shipped policy: 75% heap for three one-minute samples, one
    /// WebContent termination, or 24 h uptime.
    public static let standard = RestartPolicy()

    /// Evaluates one sample.
    ///
    /// `highSamples` is the caller's running count of consecutive samples
    /// above the threshold: it keeps accumulating while a turn is in flight so
    /// a long turn cannot hide pressure, and the trigger is withheld until the
    /// caller reports a tool-call boundary.
    ///
    /// - Returns: the trigger to execute (nil when none applies yet) and the
    ///   counter the caller must carry into the next sample.
    public func evaluate(engineHeapBytes: Int?,
                         heapBudgetBytes: Int,
                         uptime: TimeInterval,
                         highSamples: Int,
                         webContentTerminated: Bool,
                         atToolBoundary: Bool) -> (trigger: Trigger?, nextHighSamples: Int) {
        var next = max(0, highSamples)
        if let heap = engineHeapBytes, heapBudgetBytes > 0,
           Double(heap) > Double(heapBudgetBytes) * heapFraction {
            next += 1
        } else {
            next = 0
        }
        guard atToolBoundary else { return (nil, next) }
        if next >= requiredSamples { return (.heapPressure, 0) }
        if webContentTerminated { return (.webContentTermination, 0) }
        if uptime >= maximumUptime { return (.maximumUptime, 0) }
        return (nil, next)
    }
}
