// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the wake lease that authorizes background engine work.
//
// host contract `spec/host/v1/README.md` §10.2 (P06). A lease is created once
// per wake from the OS-granted execution window: `beginBackgroundTask` for a
// push, a `BGProcessingTask`'s expiration, an Android Worker's stop signal, or
// process residency while an audio keep-alive holds the App (board / BLE).

import Foundation

/// `{ wakeId, reason, grantedAt, deadline }` (PLAN §2.3).
///
/// A lease with `deadlineMs == .max` describes residency rather than an OS
/// deadline: the process is held by an audio keep-alive, so there is no clock
/// to run out. The decision function treats residency through
/// `residentAudio`, never through a fabricated remaining time.
public struct WakeLease: Equatable, Sendable, Identifiable {
    /// Shared with the OS expiry callback, which can revoke ahead of the clock.
    public final class Revocation: @unchecked Sendable, Equatable {
        private let lock = NSLock()
        private var revoked = false

        public init() {}
        public var isRevoked: Bool { lock.withLock { revoked } }
        public func revoke() { lock.withLock { revoked = true } }
        public static func == (lhs: Revocation, rhs: Revocation) -> Bool { lhs === rhs }
    }

    private let revocation: Revocation?

    /// Stable id of one wake; `(engineIncarnation, wakeId)` is the merge key.
    public let wakeId: String
    public let reason: WakeReason
    public let grantedAtMs: Int64
    public let deadlineMs: Int64

    public init(wakeId: String = UUID().uuidString.lowercased(),
                reason: WakeReason,
                grantedAtMs: Int64,
                deadlineMs: Int64, revocation: Revocation? = nil) {
        self.wakeId = wakeId
        self.reason = reason
        self.grantedAtMs = grantedAtMs
        self.deadlineMs = deadlineMs
        self.revocation = revocation
    }

    public var id: String { wakeId }

    /// Remaining lease in milliseconds, never negative.
    public func remainingMs(nowMs: Int64 = WakeLease.nowMs()) -> Int64 {
        guard revocation?.isRevoked != true else { return 0 }
        guard deadlineMs != .max else { return .max }
        return max(0, deadlineMs - nowMs)
    }

    /// True when the OS window already elapsed.
    public func isExpired(nowMs: Int64 = WakeLease.nowMs()) -> Bool {
        remainingMs(nowMs: nowMs) <= 0
    }

    /// Residency-based lease: the process is held, not a timed OS window.
    public static func resident(_ reason: WakeReason, nowMs: Int64 = WakeLease.nowMs()) -> WakeLease {
        WakeLease(reason: reason, grantedAtMs: nowMs, deadlineMs: .max)
    }

    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
