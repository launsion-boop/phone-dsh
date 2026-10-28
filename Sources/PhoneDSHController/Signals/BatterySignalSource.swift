// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: battery signal.
//
// budgets.md §3 `battery / low power mode`: below 20 % while not charging, or
// Low Power Mode on, limits the sub-agent cap to one and disables optional
// accelerators; the budgets are never raised. iOS reads `UIDevice` battery
// level/state and the documented power-state notifications; macOS only exposes
// Low Power Mode here, so its level is `nil` and it never claims to be
// charging.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Supplies a battery / low-power-mode snapshot.
public protocol BatteryStateProviding: Sendable {
    /// Samples the platform state.
    func batterySnapshot() async -> BatterySnapshot
}

/// `UIDevice` battery and `ProcessInfo` low-power-mode adapter.
///
/// Battery monitoring must be enabled before `batteryLevel`/`batteryState`
/// report useful values (Apple-documented `UIDevice.isBatteryMonitoringEnabled`
/// behaviour). This adapter enables it once, on first use. A negative
/// `batteryLevel` is the documented "unknown" value and becomes `nil`.
public final class DeviceBatteryProvider: BatteryStateProviding, @unchecked Sendable {
    public init() {}

    public func batterySnapshot() async -> BatterySnapshot {
        #if canImport(UIKit)
        return await MainActor.run {
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled {
                device.isBatteryMonitoringEnabled = true
            }
            let level: Double? = device.batteryLevel < 0
                ? nil : Double(device.batteryLevel)
            let charging: Bool
            switch device.batteryState {
            case .charging, .full: charging = true
            case .unplugged, .unknown: charging = false
            @unknown default: charging = false
            }
            return BatterySnapshot(level: level,
                                   isLowPowerModeEnabled:
                                       ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   isCharging: charging)
        }
        #else
        return await withCheckedContinuation { continuation in
            continuation.resume(returning: BatterySnapshot(
                level: nil,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                isCharging: false))
        }
        #endif
    }
}

/// A fixed snapshot provider for Apps that read the values themselves.
public struct StaticBatteryProvider: BatteryStateProviding {
    public var snapshot: BatterySnapshot

    public init(_ snapshot: BatterySnapshot) {
        self.snapshot = snapshot
    }

    public func batterySnapshot() async -> BatterySnapshot { snapshot }
}

/// Publishes ``BatterySnapshot`` values from platform battery notifications.
///
/// Every accepted notification resamples the injected provider; the source
/// only publishes a value that differs from the last one. `refresh()` is
/// public so an App delegate can force a sample at scene-phase changes where
/// iOS posts no battery notification.
public final class BatterySignalSource: @unchecked Sendable {
    /// Notification names that mean the battery or power mode changed.
    public let notifications: [Notification.Name]
    private let provider: any BatteryStateProviding
    private let hub = SignalBroadcaster<BatterySnapshot>()
    private let gate = SignalValueGate<BatterySnapshot>()
    private let bag: NotificationObserverBag
    private let lock = NSLock()
    private var running = false

    /// Creates a battery source.
    ///
    /// - Parameters:
    ///   - notificationCenter: Injected center; tests use a private instance.
    ///   - notifications: Change notifications; defaults to the documented
    ///     battery-level, battery-state and power-state notifications.
    ///   - provider: Snapshot reader; defaults to ``DeviceBatteryProvider``.
    public init(notificationCenter: NotificationCenter = .default,
                notifications: [Notification.Name] = BatterySignalSource.platformNotifications,
                provider: any BatteryStateProviding = DeviceBatteryProvider()) {
        self.notifications = notifications
        self.provider = provider
        self.bag = NotificationObserverBag(center: notificationCenter)
    }

    /// Documented battery / low-power-mode notifications.
    public static var platformNotifications: [Notification.Name] {
        #if canImport(UIKit)
        return [UIDevice.batteryLevelDidChangeNotification,
                UIDevice.batteryStateDidChangeNotification,
                Notification.Name.NSProcessInfoPowerStateDidChange]
        #else
        return [Notification.Name.NSProcessInfoPowerStateDidChange]
        #endif
    }

    /// The platform source.
    public static func platform(notificationCenter: NotificationCenter = .default)
        -> BatterySignalSource {
        BatterySignalSource(notificationCenter: notificationCenter)
    }

    /// Battery snapshots; the last value is replayed.
    public var stream: AsyncStream<BatterySnapshot> { hub.stream() }

    /// Registers the observers and samples once.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        bag.observe(notifications) { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
        Task { await self.refresh() }
    }

    /// Removes the observers and finishes the stream.
    public func stop() {
        lock.withLock { running = false }
        bag.removeAll()
        hub.finish()
    }

    /// Samples the provider, publishes a changed value and returns it.
    @discardableResult
    public func refresh() async -> BatterySnapshot {
        let snapshot = await provider.batterySnapshot()
        let isRunning = lock.withLock { running }
        if isRunning, gate.accept(snapshot) {
            hub.yield(snapshot)
        }
        return snapshot
    }
}
