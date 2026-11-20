// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the pluggable wake-source adapter seam (PLAN §2.8).
//
// One adapter per channel (board / BLE, cloud push, LAN listener, PC relay).
// An adapter does exactly three things: receive the request, write it to the
// existing durable store first (external admission journal / outbox / wake
// inbox), then hand it to the launch coordinator. It never starts the engine
// and never calls the Bot directly; engine-first and ReadySweep belong to the
// one coordinator.

import Foundation

/// A channel that can wake the App.
///
/// `start(deliver:)` installs the coordinator entry. The adapter calls it only
/// after its request is durable, and with the lease the channel could obtain
/// (a push's `beginBackgroundTask` window, a BGTask expiration, or `nil` while
/// the process is resident). `stop()` releases the channel without touching
/// the engine.
@MainActor
public protocol WakeSource: AnyObject {
    /// Channel identity; recorded in every lease the adapter builds.
    var wakeReason: WakeReason { get }

    func start(deliver: @escaping @MainActor (WakeLease?) async -> Void)

    func stop()
}
