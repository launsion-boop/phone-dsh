// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: thermal signal.
//
// budgets.md §3 `thermalState`: `fair` limits the sub-agent cap to one;
// `serious`/`critical` pause new work at the next tool-call boundary and
// suggest a handoff. The value comes from the documented
// `ProcessInfo.thermalState` property and changes through
// `ProcessInfo.thermalStateDidChangeNotification`.

import Foundation

/// Supplies the current `ProcessInfo` thermal pressure.
public protocol ThermalPressureProviding: Sendable {
    /// The current pressure at the time of the call.
    var thermalPressure: ThermalPressure { get }
}

/// Adapter over `ProcessInfo.processInfo.thermalState`.
public struct ProcessInfoThermalProvider: ThermalPressureProviding {
    public init() {}

    public var thermalPressure: ThermalPressure {
        ThermalPressure(processInfoState: ProcessInfo.processInfo.thermalState)
    }
}

extension ThermalPressure {
    /// Maps the documented four-level `ProcessInfo.ThermalState`.
    ///
    /// A future level added by Apple is treated as `.critical`: the budget may
    /// never be raised by an unknown system state.
    public init(processInfoState state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

/// Publishes ``ThermalPressure`` values from the platform thermal state.
public final class ThermalSignalSource: @unchecked Sendable {
    /// Notification names that mean the thermal state changed.
    public let notifications: [Notification.Name]
    private let provider: any ThermalPressureProviding
    private let initialPressure: ThermalPressure?
    private let hub = SignalBroadcaster<ThermalPressure>()
    private let gate: SignalValueGate<ThermalPressure>
    private let bag: NotificationObserverBag
    private let lock = NSLock()
    private var running = false

    /// Creates a thermal source.
    ///
    /// - Parameters:
    ///   - notificationCenter: Injected center; tests use a private instance.
    ///   - notifications: Change notifications, defaulting to
    ///     `ProcessInfo.thermalStateDidChangeNotification`.
    ///   - provider: Thermal-state reader; defaults to `ProcessInfo`.
    ///   - initial: Value emitted first; defaults to the provider's value.
    public init(notificationCenter: NotificationCenter = .default,
                notifications: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification],
                provider: any ThermalPressureProviding = ProcessInfoThermalProvider(),
                initial: ThermalPressure? = nil) {
        self.notifications = notifications
        self.provider = provider
        self.initialPressure = initial
        self.bag = NotificationObserverBag(center: notificationCenter)
        self.gate = SignalValueGate(initial: nil)
    }

    /// The platform source (`ProcessInfo.thermalState`).
    public static func platform(notificationCenter: NotificationCenter = .default)
        -> ThermalSignalSource {
        ThermalSignalSource(notificationCenter: notificationCenter)
    }

    /// Thermal-pressure values; the last value is replayed.
    public var stream: AsyncStream<ThermalPressure> { hub.stream() }

    /// Registers the change observer and publishes the initial value once.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        bag.observe(notifications) { [weak self] in self?.refresh() }
        emit(initialPressure ?? provider.thermalPressure)
    }

    /// Removes the observer and finishes the stream.
    public func stop() {
        lock.withLock { running = false }
        bag.removeAll()
        hub.finish()
    }

    /// Samples the provider and publishes the value when it changed. Returns
    /// the sampled value so an App adapter can drive the stream without a
    /// notification (for example on foreground return).
    @discardableResult
    public func refresh() -> ThermalPressure {
        let value = provider.thermalPressure
        emit(value)
        return value
    }

    private func emit(_ pressure: ThermalPressure) {
        let isRunning = lock.withLock { running }
        guard isRunning, gate.accept(pressure) else { return }
        hub.yield(pressure)
    }
}
