// SPDX-License-Identifier: MIT

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Charging, Low Power Mode and App lifecycle observations.
///
/// This source does not claim a "system idle" fact: iOS has no public API for
/// that. `app.foreground`/`app.background` describe this App only; BGTask remains
/// best-effort and is not turned into an idle fact here.
public final class PowerIdleSource: BotContextSource, BotContextSourceStreaming,
                                     @unchecked Sendable {
    public let kind: BotContextSourceKind = .power
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var observers: [NSObjectProtocol] = []
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?
    private var lastCharging: Bool?

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization { .authorized }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock()
        activeRevision = permissionRevision
        self.emit = emit
        lock.unlock()

        addObserver(Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.handleLowPowerChanged()
        }
#if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        addObserver(UIDevice.batteryStateDidChangeNotification) { [weak self] in
            self?.handleBatteryChanged()
        }
        addObserver(UIDevice.batteryLevelDidChangeNotification) { [weak self] in
            self?.handleBatteryLevelChanged()
        }
        addObserver(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.handleAppState(active: true)
        }
        addObserver(UIApplication.willResignActiveNotification) { [weak self] in
            self?.handleAppState(active: false)
        }
        if UIApplication.shared.applicationState == .active {
            handleAppState(active: true)
        }
        handleBatteryChanged()
#endif
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            handleLowPowerChanged()
        }
    }

    public func stop() async {
        lock.lock()
        let tokens = observers
        observers = []
        activeRevision = nil
        emit = nil
        lastCharging = nil
        buffer.clear()
        lock.unlock()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    private func addObserver(_ name: Notification.Name, _ body: @escaping @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: nil) { _ in body() }
        lock.lock()
        observers.append(token)
        lock.unlock()
    }

    private func handleBatteryChanged() {
#if canImport(UIKit)
        let state = UIDevice.current.batteryState
        let charging: Bool?
        switch state {
        case .charging, .full: charging = true
        case .unplugged: charging = false
        case .unknown: charging = nil
        @unknown default: charging = nil
        }
        guard let charging else { return }
        lock.lock()
        let previous = lastCharging
        lastCharging = charging
        lock.unlock()
        guard previous != charging else { return }
        emitObservation(
            kind: charging ? .powerChargingStarted : .powerChargingStopped,
            payload: .object([
                "charging": .bool(charging),
                "batteryState": .string(String(describing: state)),
                "batteryLevel": .number(Double(UIDevice.current.batteryLevel)),
            ]),
            versionBasis: .providerVersion,
            versionValue: "\(state.rawValue):\(UIDevice.current.batteryLevel)",
            uncertainty: BotContextUncertainty(
                level: .low, reason: "battery-state-is-sampled-by-the-os", completeness: .complete),
            wakeRequested: true)
#endif
    }

    private func handleBatteryLevelChanged() {
        // The level alone is not a context fact worth a wake; it only keeps the
        // next charging-state observation fresh.
        lock.lock()
        let sink = emit
        lock.unlock()
        guard sink != nil else { return }
    }

    private func handleLowPowerChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        emitObservation(
            kind: enabled ? .powerLowPowerEnabled : .powerLowPowerDisabled,
            payload: .object(["lowPowerMode": .bool(enabled)]),
            versionBasis: .providerVersion,
            versionValue: enabled ? "enabled" : "disabled",
            uncertainty: BotContextUncertainty(level: .low, completeness: .complete),
            wakeRequested: true)
    }

    private func handleAppState(active: Bool) {
        emitObservation(
            kind: active ? .appForeground : .appBackground,
            payload: .object(["appActive": .bool(active)]),
            versionBasis: .providerVersion,
            versionValue: active ? "active" : "inactive",
            uncertainty: BotContextUncertainty(level: .low, completeness: .complete),
            wakeRequested: false)
    }

    private func emitObservation(kind observationKind: BotContextObservationKind,
                                 payload: BotJSONValue,
                                 versionBasis: BotContextSourceVersionBasis,
                                 versionValue: String,
                                 uncertainty: BotContextUncertainty,
                                 wakeRequested: Bool) {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink else { return }
        let stamp = now()
        guard let observation = try? BotContextObservation(
            id: "power:\(observationKind.rawValue):\(stamp)",
            source: .power,
            kind: observationKind,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .known(versionBasis, value: versionValue, observedAt: stamp),
            uncertainty: uncertainty,
            delivery: .os,
            payload: payload,
            dedupeKey: "power:\(observationKind.rawValue):\(stamp / 60_000)",
            wakeRequested: wakeRequested) else { return }
        buffer.append(observation)
        sink(observation)
    }
}
