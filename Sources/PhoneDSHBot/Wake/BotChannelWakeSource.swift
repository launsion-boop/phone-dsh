// SPDX-License-Identifier: MIT

import Foundation

/// A Bot-side wake channel that already wrote its request durably.
///
/// PLAN §2.8: a wake adapter does exactly three things — receive the request,
/// write it to the existing durable store (journal / outbox / wake inbox), and
/// hand it to the one launch orchestrator. This type is that hand-off for Bot
/// channels (a device task result arriving over BLE, a Bot MCP HTTP request on
/// the loopback listener). It never starts the engine and never calls the Bot.
///
/// It conforms to the existing `WakeSignalSource` so the Bot wake surfaces keep
/// one interface; `signal(botId:reason:at:)` is called only after the durable
/// write succeeded. The App installs a handler that maps the signal to
/// `EngineLaunchOrchestrator.shared.wake(_:lease:)`.
public final class BotChannelWakeSource: WakeSignalSource, @unchecked Sendable {
    public static let bleRequestReason = "bleRequest"
    public static let lanRequestReason = "lanRequest"

    private let lock = NSLock()
    private var handler: (@Sendable (WakeSignal) -> Void)?

    public init() {}

    public func start(onSignal: @escaping @Sendable (WakeSignal) -> Void) async {
        lock.withLock { handler = onSignal }
    }

    public func stop() async {
        lock.withLock { handler = nil }
    }

    /// Emits one already-durable signal. With no handler installed (a build
    /// without the launch orchestrator) it is a no-op: the durable request
    /// stays queued for the next foreground pass instead of being lost.
    public func signal(botId: String, reason: String, at: Int64) {
        guard !botId.isEmpty, !reason.isEmpty else { return }
        let signal = WakeSignal(botId: botId, reason: reason, at: at)
        let handler = lock.withLock { self.handler }
        handler?(signal)
    }

    /// True while a handler is installed. Diagnostic seam for the App wiring
    /// and tests; it grants nothing by itself.
    public var isInstalled: Bool {
        lock.withLock { handler != nil }
    }
}
