// SPDX-License-Identifier: MIT
import Foundation

/// Preparation only: queue admission and delivery receipts remain owned by SendOutbox.
public enum ChatDeliveryPreparation: Equatable, Sendable {
    case ready, start, resume, wait, deferred, needsAttention

    public static func decide(foreground: Bool, keepingAlive: Bool, hostPresent: Bool,
                              parked: Bool, transitioning: Bool, busy: Bool,
                              transportReady: Bool, requiresRecovery: Bool, userPaused: Bool = false) -> Self {
        if requiresRecovery || userPaused { return .needsAttention }
        // A retained process is not permission to boot WebContent in the background.
        if !foreground && (!keepingAlive || !hostPresent || parked) { return .deferred }
        if transitioning || busy { return .wait }
        if !hostPresent { return .start }
        if parked { return .resume }
        return transportReady ? .ready : .wait
    }
}
