// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: signal sources.
//
// PLAN §2.5 and spec/v1/budgets.md §3. `HostSignals` is the injected
// observation surface; the App adapts scenePhase, thermalState, battery,
// NWPathMonitor, the memory proxy, WebContent termination and the background
// task to it. `RecordedSignals` is the deterministic test double and
// `SignalBus` merges several sources (for example the App adapter plus
// WebKit's termination delegate) into one.

import Foundation

/// Test double for ``HostSignals``. Values are buffered per stream and the
/// last value is replayed to a late subscriber.
public final class RecordedSignals: HostSignals, @unchecked Sendable {
    private let scenePhaseHub = SignalBroadcaster<ScenePhase>()
    private let thermalHub = SignalBroadcaster<ThermalPressure>()
    private let batteryHub = SignalBroadcaster<BatterySnapshot>()
    private let pathHub = SignalBroadcaster<NetworkPathStatus>()
    private let memoryProxyHub = SignalBroadcaster<MemoryProxySample>()
    private let terminatedHub = SignalBroadcaster<WebContentTermination>()
    private let backgroundHub = SignalBroadcaster<BackgroundTaskExpiration>()

    public init() {}

    public var scenePhase: AsyncStream<ScenePhase> { scenePhaseHub.stream() }
    public var thermal: AsyncStream<ThermalPressure> { thermalHub.stream() }
    public var battery: AsyncStream<BatterySnapshot> { batteryHub.stream() }
    public var path: AsyncStream<NetworkPathStatus> { pathHub.stream() }
    public var memoryProxy: AsyncStream<MemoryProxySample> { memoryProxyHub.stream() }
    public var webContentTerminated: AsyncStream<WebContentTermination> {
        terminatedHub.stream()
    }
    public var backgroundTaskExpiring: AsyncStream<BackgroundTaskExpiration> {
        backgroundHub.stream()
    }

    public func sendScenePhase(_ value: ScenePhase) { scenePhaseHub.yield(value) }
    public func sendThermal(_ value: ThermalPressure) { thermalHub.yield(value) }
    public func sendBattery(_ value: BatterySnapshot) { batteryHub.yield(value) }
    public func sendPath(_ value: NetworkPathStatus) { pathHub.yield(value) }
    public func sendMemoryProxy(_ value: MemoryProxySample) { memoryProxyHub.yield(value) }
    public func sendWebContentTermination(_ value: WebContentTermination) {
        terminatedHub.yield(value)
    }
    public func sendBackgroundTaskExpiration(_ value: BackgroundTaskExpiration) {
        backgroundHub.yield(value)
    }

    /// Finishes every stream; a stopped App adapter does the same.
    public func finish() {
        scenePhaseHub.finish()
        thermalHub.finish()
        batteryHub.finish()
        pathHub.finish()
        memoryProxyHub.finish()
        terminatedHub.finish()
        backgroundHub.finish()
    }
}

/// Combines several ``HostSignals`` sources into one observation surface.
/// Each source keeps its own stream; the bus forwards every element to one
/// merged stream per signal.
public struct SignalBus: HostSignals {
    public let sources: [any HostSignals]

    public init(_ sources: [any HostSignals]) {
        self.sources = sources
    }

    public init(_ sources: any HostSignals...) {
        self.sources = sources
    }

    public var scenePhase: AsyncStream<ScenePhase> {
        Self.merge(sources.map(\.scenePhase))
    }

    public var thermal: AsyncStream<ThermalPressure> {
        Self.merge(sources.map(\.thermal))
    }

    public var battery: AsyncStream<BatterySnapshot> {
        Self.merge(sources.map(\.battery))
    }

    public var path: AsyncStream<NetworkPathStatus> {
        Self.merge(sources.map(\.path))
    }

    public var memoryProxy: AsyncStream<MemoryProxySample> {
        Self.merge(sources.map(\.memoryProxy))
    }

    public var webContentTerminated: AsyncStream<WebContentTermination> {
        Self.merge(sources.map(\.webContentTerminated))
    }

    public var backgroundTaskExpiring: AsyncStream<BackgroundTaskExpiration> {
        Self.merge(sources.map(\.backgroundTaskExpiring))
    }

    static func merge<Element: Sendable>(
        _ streams: [AsyncStream<Element>]
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let tasks = streams.map { stream in
                Task {
                    for await element in stream {
                        continuation.yield(element)
                    }
                }
            }
            continuation.onTermination = { _ in
                for task in tasks { task.cancel() }
            }
        }
    }
}
