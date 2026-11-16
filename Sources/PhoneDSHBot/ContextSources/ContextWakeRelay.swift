// SPDX-License-Identifier: MIT

import Foundation

/// Bridges a native context wake into the existing `WakeSignalSource` seam.
///
/// N only emits the signal. The App/composition decides whether to open a turn,
/// whether the Bot is allowed to speak, and how to dedupe across sources; the
/// relay never creates a turn, notification or user-visible row.
public actor BotContextWakeRelay: WakeSignalSource {
    private var handler: (@Sendable (WakeSignal) -> Void)?
    private var active = false

    public init() {}

    public func start(onSignal: @escaping @Sendable (WakeSignal) -> Void) {
        handler = onSignal
        active = true
    }

    public func stop() {
        handler = nil
        active = false
    }

    public func isActive() -> Bool { active }

    public func emit(_ wake: BotContextWake) {
        guard active, let handler else { return }
        handler(WakeSignal(botId: wake.botID, reason: wake.reason, at: wake.observedAt))
    }
}
