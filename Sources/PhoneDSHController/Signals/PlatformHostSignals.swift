// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: platform signals.
//
// PLAN §2.5 and budgets.md §3. `PlatformHostSignals` is the production
// ``HostSignals`` implementation: it merges the scene-phase, thermal, battery,
// network-path and memory-proxy sources and exposes the two signals that the
// App owns directly — WebContent termination (WKWebView delegate) and
// background-task expiration (the OS background task). The controller still
// imports no platform framework; only this directory does, behind
// `#if canImport(UIKit)` / `#if canImport(AppKit)`.
//
// Everything here is an observation adapter. The host state machine decides
// the D14 transition from a value; these sources never change admission.

import Foundation
import PhoneDSHLog

/// Production ``HostSignals`` for iOS and macOS.
///
/// ```swift
/// let signals = PlatformHostSignals.make(
///     workspaceLog: workspaceLog,
///     webContentTerminations: { engine.terminationCount })
/// signals.start()
/// let controller = ...
/// for await phase in signals.scenePhase { ... }
/// engine.onTerminate { signals.send(WebContentTermination(...)) }
/// ```
///
/// The WebContent-termination and background-expiration streams are injected by
/// their owners (the WKWebView delegate and the background task) through
/// ``send(_:)``. They are not derived by this class, because only the owner
/// knows whether the process termination was foreground and which task
/// expired.
public final class PlatformHostSignals: HostSignals, @unchecked Sendable {
    /// Scene-phase source (App lifecycle notifications).
    public let scenePhaseSource: ScenePhaseSignalSource
    /// Thermal-state source (`ProcessInfo`).
    public let thermalSource: ThermalSignalSource
    /// Battery / low-power-mode source (`UIDevice` on iOS).
    public let batterySource: BatterySignalSource
    /// Network-path source (`NWPathMonitor`).
    public let networkSource: NetworkPathSignalSource
    /// Memory-proxy source (`WorkspaceLog.metrics()` through `BudgetMonitor`),
    /// when a workspace log was supplied.
    public let memoryProxySource: MemoryProxySignalSource?

    private let terminatedHub = SignalBroadcaster<WebContentTermination>()
    private let expirationHub = SignalBroadcaster<BackgroundTaskExpiration>()
    private let lock = NSLock()
    private var started = false

    /// Creates the composite from explicit sources (tests use this initializer
    /// with private notification centers and fakes).
    public init(scenePhase: ScenePhaseSignalSource,
                thermal: ThermalSignalSource,
                battery: BatterySignalSource,
                network: NetworkPathSignalSource,
                memoryProxy: MemoryProxySignalSource? = nil) {
        self.scenePhaseSource = scenePhase
        self.thermalSource = thermal
        self.batterySource = battery
        self.networkSource = network
        self.memoryProxySource = memoryProxy
    }

    /// Creates the complete production set.
    ///
    /// - Parameters:
    ///   - workspaceLog: When present, the memory-proxy source samples it and
    ///     runs the budget monitor. The facade normally already owns a
    ///     `BudgetMonitor`; pass it with the `monitor` parameter so the
    ///     diagnostics and this signal share the pressure episode.
    ///   - webContentTerminations: Counter owned by the WebKit delegate.
    ///   - engineHeapBytes: Optional WebContent heap probe; when present the
    ///     memory-proxy sample also carries the heap branch of the budget
    ///     actions.
    ///   - notificationCenter: Injected center; defaults to `.default`.
    ///   - monitor: Budget monitor to reuse; a fresh one by default.
    public static func make(workspaceLog: WorkspaceLog? = nil,
                            webContentTerminations: @escaping @Sendable () -> UInt64 = { 0 },
                            engineHeapBytes: @escaping @Sendable () -> Int? = { nil },
                            notificationCenter: NotificationCenter = .default,
                            monitor: BudgetMonitor = BudgetMonitor())
        -> PlatformHostSignals {
        let memory: MemoryProxySignalSource?
        if let workspaceLog {
            memory = MemoryProxySignalSource(
                provider: WorkspaceLogMemoryProxyProvider(
                    log: workspaceLog,
                    webContentTerminations: webContentTerminations,
                    engineHeapBytes: engineHeapBytes),
                monitor: monitor,
                interval: MemoryProxySignalSource.defaultIntervalSeconds,
                clock: SystemHostClock())
        } else {
            memory = nil
        }
        return PlatformHostSignals(
            scenePhase: .platform(notificationCenter: notificationCenter),
            thermal: .platform(notificationCenter: notificationCenter),
            battery: .platform(notificationCenter: notificationCenter),
            network: .platform(),
            memoryProxy: memory)
    }

    // MARK: - HostSignals

    public var scenePhase: AsyncStream<ScenePhase> { scenePhaseSource.stream }
    public var thermal: AsyncStream<ThermalPressure> { thermalSource.stream }
    public var battery: AsyncStream<BatterySnapshot> { batterySource.stream }
    public var path: AsyncStream<NetworkPathStatus> { networkSource.stream }
    public var memoryProxy: AsyncStream<MemoryProxySample> {
        memoryProxySource?.stream ?? AsyncStream { continuation in
            continuation.finish()
        }
    }
    public var webContentTerminated: AsyncStream<WebContentTermination> {
        terminatedHub.stream()
    }
    public var backgroundTaskExpiring: AsyncStream<BackgroundTaskExpiration> {
        expirationHub.stream()
    }

    // MARK: - Ownership

    /// Starts every observable source. Idempotent.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        scenePhaseSource.start()
        thermalSource.start()
        batterySource.start()
        networkSource.start()
        memoryProxySource?.start()
    }

    /// Stops every source and finishes every stream. The App calls this from
    /// `applicationWillTerminate` / the macOS terminate path.
    public func stop() {
        lock.withLock { started = false }
        scenePhaseSource.stop()
        thermalSource.stop()
        batterySource.stop()
        networkSource.stop()
        memoryProxySource?.stop()
        terminatedHub.finish()
        expirationHub.finish()
    }

    // MARK: - Owner-injected signals

    /// Publishes a WebKit WebContent-process termination.
    public func send(_ termination: WebContentTermination) {
        terminatedHub.yield(termination)
    }

    /// Publishes an OS background-task expiration so the controller can force
    /// the drain deadline (budgets.md §3).
    public func send(_ expiration: BackgroundTaskExpiration) {
        expirationHub.yield(expiration)
    }
}
