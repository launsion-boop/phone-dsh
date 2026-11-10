// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: sender-side pacing for established `e2e` frames (§3.8,
// `pclink-v1.5`). The relay pair bucket is a drop boundary, not a queue: the
// phone must not write faster than the pair rate or a frame is lost and the
// session's contiguous seq breaks. This type is a pure token bucket; the
// client's single outbound writer is the only caller, so queue order is seq
// order.

import Foundation

/// One local token bucket with the relay's full-bucket single-frame overdraft.
public struct PCLinkOutboundPacer: Sendable, Equatable {
    /// Reference rate: 0.9 MiB/s (margin under the relay's 1 MiB/s pair rate).
    public static let referenceRateBytesPerSecond: Double = 0.9 * 1_048_576
    /// Reference burst: 3.5 MiB (margin under the relay's 4 MiB pair burst).
    public static let referenceBurstBytes: Double = 3.5 * 1_048_576

    public let rateBytesPerSecond: Double
    public let burstBytes: Double
    private var tokens: Double
    private var lastRefill: Date?

    public init(rateBytesPerSecond: Double = PCLinkOutboundPacer.referenceRateBytesPerSecond,
                burstBytes: Double = PCLinkOutboundPacer.referenceBurstBytes) {
        precondition(rateBytesPerSecond > 0 && burstBytes > 0, "pacing values must be positive")
        self.rateBytesPerSecond = rateBytesPerSecond
        self.burstBytes = burstBytes
        self.tokens = burstBytes
        self.lastRefill = nil
    }

    /// Refill at `now`, clamped to the burst. A negative balance (approved
    /// overdraft) recovers at the configured rate.
    public mutating func refill(at now: Date) {
        guard let lastRefill else {
            self.lastRefill = now
            return
        }
        if now > lastRefill {
            tokens = min(burstBytes, tokens + now.timeIntervalSince(lastRefill) * rateBytesPerSecond)
            self.lastRefill = now
        }
    }

    /// Wait needed before `bytes` may be written; does not consume tokens.
    /// A frame larger than the burst waits for a full bucket, then overdraws.
    public mutating func delayBeforeSending(bytes: Int, at now: Date) -> TimeInterval {
        refill(at: now)
        let cost = Double(max(0, bytes))
        if cost <= tokens + 1e-9 { return 0 }
        if cost > burstBytes && tokens >= burstBytes - 1e-9 { return 0 }
        let required = cost > burstBytes ? burstBytes : cost
        return max(0, (required - tokens) / rateBytesPerSecond)
    }

    /// Charge one approved frame. May go negative only after an approved
    /// overdraft.
    public mutating func consume(bytes: Int, at now: Date) {
        refill(at: now)
        tokens -= Double(max(0, bytes))
    }

    /// Current balance (test/diagnostic helper).
    public var availableTokens: Double { tokens }
}
