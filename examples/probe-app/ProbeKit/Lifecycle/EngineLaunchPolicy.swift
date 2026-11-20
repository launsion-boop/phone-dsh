// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — one pure decision: may this wake run engine work, and
// what transition does it need?
//
// host contract `spec/host/v1/README.md` §10.2 (P06, frozen r1). The inputs are
// exactly the golden vector tuple in `spec/host/v1/golden/engine-launch.json`;
// the Swift and Kotlin implementations both read that one file.

import Foundation

/// The engine state a decision starts from (golden `hostState`).
public enum EngineHostState: String, Codable, Sendable, Equatable, CaseIterable {
    /// No host in this process.
    case absent
    /// A host is running (parked or not is separate).
    case running
    /// A host exists but is parked (background pause).
    case parked
    /// The last host failed; a fresh boot is the way out.
    case failed

    public var isPresent: Bool { self != .absent }
}

/// The closed decision set of host §10.2 (golden `decisions[6]`).
public enum EngineLaunchDecision: String, Codable, Sendable, Equatable, CaseIterable {
    /// Boot the engine (`hostState` absent/failed and the caller is eligible).
    case boot
    /// Resume the parked host.
    case resume
    /// A host is already running; only the ReadySweep remains.
    case ready
    /// Not eligible for an engine transition: run only the engine-free phase A
    /// and leave the rest to the next wake.
    case nativeOnly
    /// Nothing may run now; the request waits for the next foreground return.
    case deferred = "defer"
    /// Manual recovery is authoritative: no automatic boot, the existing user
    /// facing recovery state stays.
    case needsAttention
}

/// Pure decision function (host §10.2, frozen r1; order must not change).
///
/// 1. `needsReset` → `.needsAttention`
/// 2. `userStopped` → `.deferred`
/// 3. host running → `.ready`
/// 4. eligible = foreground || residentAudio
///    || (leaseRemainingMs != nil && leaseRemainingMs >= requiredLease)
/// 5. not eligible → `.nativeOnly`
/// 6. parked → `.resume`; absent/failed → `.boot`
///
/// `reason` selects the lease source at the caller only; it does not branch.
public enum EngineLaunchPolicy {
    public static func decide(reason: WakeReason,
                              foreground: Bool,
                              residentAudio: Bool,
                              hostState: EngineHostState,
                              leaseRemainingMs: Int64?,
                              userStopped: Bool,
                              needsReset: Bool) -> EngineLaunchDecision {
        _ = reason
        // The user's own commands are authoritative over every wake.
        if needsReset { return .needsAttention }
        if userStopped { return .deferred }
        if hostState == .running { return .ready }
        let requiredLease = hostState == .parked
            ? EngineLaunchThresholds.minLeaseForResumeMs
            : EngineLaunchThresholds.minLeaseForColdBootMs
        let eligible = foreground || residentAudio
            || (leaseRemainingMs.map { $0 >= requiredLease } ?? false)
        if !eligible { return .nativeOnly }
        return hostState == .parked ? .resume : .boot
    }

    /// True when the engine transition could not be authorized and the caller
    /// should book a `BGProcessingTask` for a later, longer window.
    public static func needsProcessingFallback(decision: EngineLaunchDecision) -> Bool {
        decision == .nativeOnly
    }
}

/// What one ``EngineLaunchOrchestrator/wake(_:lease:)`` actually did.
///
/// App-internal (never on the wire); the contract fixes only the decision
/// values, which this outcome carries verbatim.
public struct EngineLaunchOutcome: Sendable, Equatable {
    public enum EngineResult: String, Sendable, Equatable {
        /// No engine transition was requested (ready / nativeOnly / defer).
        case notRequested
        case booted
        case resumed
        case failed
    }

    public let wakeId: String
    public let reason: WakeReason
    public let engineIncarnation: Int
    public let decision: EngineLaunchDecision
    public let engine: EngineResult
    /// The merged ReadySweep report (steps 1–7); `nil` when no sweep ran.
    public let sweep: ReadySweepReport?

    public init(wakeId: String, reason: WakeReason, engineIncarnation: Int,
                decision: EngineLaunchDecision, engine: EngineResult,
                sweep: ReadySweepReport? = nil) {
        self.wakeId = wakeId
        self.reason = reason
        self.engineIncarnation = engineIncarnation
        self.decision = decision
        self.engine = engine
        self.sweep = sweep
    }
}
