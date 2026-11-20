// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

#if os(iOS)
/// PLAN §2.8 bridge for Bot channels.
///
/// A Bot channel (a device task result arriving over BLE, a Bot MCP request on
/// the local listener) writes its request to the existing durable store first;
/// only then does it emit a `WakeSignal`. This bridge maps that signal to the
/// one launch entry, `EngineLaunchOrchestrator.shared.wake(_:lease:)`. It never
/// starts the engine, never calls the Bot and never grants anything: the
/// orchestrator's `EngineLaunchPolicy` decides boot / resume / native-only /
/// defer from the current foreground, residency and host state.
///
/// `lease` is nil because these are process-resident channels (the process is
/// alive to have received the request). The policy reads residency/foreground
/// from its own state; fabricating a timed lease would claim an OS window the
/// channel never received.
@MainActor
enum BotWakeBridge {
    /// Installs the handler before `prepare` returns, so a device result that
    /// arrives immediately after phase A still finds a live wake path.
    static func install(_ source: BotChannelWakeSource) async {
        await source.start { signal in
            guard let reason = WakeReason(rawValue: signal.reason) else { return }
            Task { @MainActor in
                _ = await EngineLaunchOrchestrator.shared.wake(reason, lease: nil)
            }
        }
    }
}
#endif
