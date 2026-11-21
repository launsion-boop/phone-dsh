// SPDX-License-Identifier: MIT
import Foundation

/// Preparation only: queue admission and delivery receipts remain owned by SendOutbox.
public enum ChatDeliveryPreparation: Equatable, Sendable {
    case ready, start, resume, wait, deferred, needsAttention

    /// The single execution-eligibility answer (host contract §10.1). The App may run the engine
    /// while it is not in the background, or while the system keeps the process resident with an
    /// audio keep-alive: the chat's own, or another owner such as a connected TonoLink board.
    ///
    /// A wake lease is the third branch (host §10.2): a push / BGTask callback may boot or resume
    /// while the remaining lease still clears the threshold for the transition it needs. Without a
    /// lease a background callback alone never authorizes WebContent.
    public static func executionEligible(foreground: Bool, keepingAlive: Bool,
                                         residentAudio: Bool,
                                         leaseRemainingMs: Int64? = nil,
                                         leaseThresholdMs: Int64 = EngineLaunchThresholds.minLeaseForColdBootMs) -> Bool {
        if foreground || keepingAlive || residentAudio { return true }
        guard let remaining = leaseRemainingMs else { return false }
        return remaining > 0 && remaining >= leaseThresholdMs
    }

    public static func decide(foreground: Bool, keepingAlive: Bool, hostPresent: Bool,
                              parked: Bool, transitioning: Bool, busy: Bool,
                              transportReady: Bool, requiresRecovery: Bool, userPaused: Bool = false,
                              residentAudio: Bool = false,
                              leaseRemainingMs: Int64? = nil,
                              leaseThresholdMs: Int64 = EngineLaunchThresholds.minLeaseForColdBootMs) -> Self {
        if requiresRecovery || userPaused { return .needsAttention }
        // A background callback alone is not permission to boot or resume WebContent; a process
        // held resident by audio or a wake lease large enough for the transition is.
        guard executionEligible(foreground: foreground, keepingAlive: keepingAlive,
                                residentAudio: residentAudio,
                                leaseRemainingMs: leaseRemainingMs,
                                leaseThresholdMs: leaseThresholdMs) else { return .deferred }
        if transitioning || busy { return .wait }
        if !hostPresent { return .start }
        if parked { return .resume }
        return transportReady ? .ready : .wait
    }
}
