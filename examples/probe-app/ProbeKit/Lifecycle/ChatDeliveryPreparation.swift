// SPDX-License-Identifier: MIT
import Foundation

/// Preparation only: queue admission and delivery receipts remain owned by SendOutbox.
public enum ChatDeliveryPreparation: Equatable, Sendable {
    case ready, start, resume, wait, deferred, needsAttention

    /// The single execution-eligibility answer (host contract §10.1). The App may run the engine
    /// while it is not in the background, or while the system keeps the process resident with an
    /// audio keep-alive: the chat's own, or another owner such as a connected TonoLink board.
    public static func executionEligible(foreground: Bool, keepingAlive: Bool,
                                         residentAudio: Bool) -> Bool {
        foreground || keepingAlive || residentAudio
    }

    public static func decide(foreground: Bool, keepingAlive: Bool, hostPresent: Bool,
                              parked: Bool, transitioning: Bool, busy: Bool,
                              transportReady: Bool, requiresRecovery: Bool, userPaused: Bool = false,
                              residentAudio: Bool = false) -> Self {
        if requiresRecovery || userPaused { return .needsAttention }
        // A background callback alone is not permission to boot or resume WebContent; a process
        // held resident by audio is, so a device command runs without waiting for the user.
        guard executionEligible(foreground: foreground, keepingAlive: keepingAlive,
                                residentAudio: residentAudio) else { return .deferred }
        if transitioning || busy { return .wait }
        if !hostPresent { return .start }
        if parked { return .resume }
        return transportReady ? .ready : .wait
    }
}
