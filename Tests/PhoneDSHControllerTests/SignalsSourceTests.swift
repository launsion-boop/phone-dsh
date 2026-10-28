// SPDX-License-Identifier: MIT
// Tests for the platform signal sources (W6-BACKGROUND).
//
// Every source is driven through injected dependencies: a private
// NotificationCenter, a stub thermal/battery provider, a fake NWPathMonitor and
// a static memory-proxy sample. No test touches a real application object, a
// network interface or a device battery.

import Foundation
import XCTest
import PhoneDSHController

/// Stub thermal provider; the test changes the value between notifications.
final class StubThermalProvider: ThermalPressureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ThermalPressure

    init(_ value: ThermalPressure) {
        self.value = value
    }

    var thermalPressure: ThermalPressure {
        lock.withLock { value }
    }

    func set(_ newValue: ThermalPressure) {
        lock.withLock { value = newValue }
    }
}

/// Stub battery provider.
final class StubBatteryProvider: BatteryStateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: BatterySnapshot

    init(_ value: BatterySnapshot) {
        self.value = value
    }

    func set(_ newValue: BatterySnapshot) {
        lock.withLock { value = newValue }
    }

    func batterySnapshot() async -> BatterySnapshot {
        lock.withLock { value }
    }
}

/// Fake NWPathMonitor: the test pushes statuses synchronously.
final class FakeNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NetworkPathStatus) -> Void)?
    private var startCount = 0
    private var stopCount = 0

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }

    func start(handler: @escaping @Sendable (NetworkPathStatus) -> Void) {
        lock.withLock {
            startCount += 1
            self.handler = handler
        }
    }

    func stop() {
        let handler: (@Sendable (NetworkPathStatus) -> Void)? = lock.withLock {
            stopCount += 1
            let handler = self.handler
            self.handler = nil
            return handler
        }
        _ = handler
    }

    func push(_ status: NetworkPathStatus) {
        let handler = lock.withLock { self.handler }
        handler?(status)
    }
}

final class SignalsScenePhaseTests: XCTestCase {
    private let active = Notification.Name("xl.signals.active")
    private let inactive = Notification.Name("xl.signals.inactive")
    private let background = Notification.Name("xl.signals.background")

    private var bindings: ScenePhaseNotifications {
        ScenePhaseNotifications(active: [active], inactive: [inactive],
                                background: [background])
    }

    func testNotificationCenterMapsScenePhase() async {
        let center = NotificationCenter()
        let source = ScenePhaseSignalSource(notificationCenter: center,
                                            notifications: bindings,
                                            initial: nil)
        let stream = source.stream
        source.start()
        center.post(name: inactive, object: nil)
        center.post(name: background, object: nil)
        let values = await collect(2, from: stream)
        XCTAssertEqual(values, [.inactive, .background])
        source.stop()
    }

    func testInitialPhaseIsTheFirstValue() async {
        let center = NotificationCenter()
        let source = ScenePhaseSignalSource(notificationCenter: center,
                                            notifications: bindings,
                                            initial: .active)
        let stream = source.stream
        source.start()
        let values = await collect(1, from: stream)
        XCTAssertEqual(values, [.active])
        source.stop()
    }

    func testStopRemovesObserversAndFinishesTheStream() async {
        let center = NotificationCenter()
        let source = ScenePhaseSignalSource(notificationCenter: center,
                                            notifications: bindings,
                                            initial: .active)
        let stream = source.stream
        source.start()
        source.stop()
        center.post(name: background, object: nil)
        // The buffered initial value is still delivered, but the stopped
        // source publishes nothing after it and the stream finishes.
        let values = await collect(2, from: stream)
        XCTAssertEqual(values, [.active])
    }

    func testPlatformBindingCoversForegroundAndBackground() {
        let platform = ScenePhaseNotifications.platform
        XCTAssertFalse(platform.active.isEmpty)
        XCTAssertFalse(platform.inactive.isEmpty)
        XCTAssertFalse(platform.background.isEmpty)
    }

    func testCurrentPlatformPhaseDoesNotTrapOffAnApplication() {
        // The value depends on whether a test host application is running;
        // reading it must be safe and return a defined phase or nil.
        if let phase = ScenePhaseSignalSource.currentPlatformPhase() {
            XCTAssertTrue(ScenePhase.allCases.contains(phase))
        }
    }
}

final class SignalsThermalBatteryTests: XCTestCase {
    func testThermalNotificationSamplesTheProvider() async {
        let center = NotificationCenter()
        let name = Notification.Name("xl.signals.thermal")
        let provider = StubThermalProvider(.nominal)
        let source = ThermalSignalSource(notificationCenter: center,
                                        notifications: [name],
                                        provider: provider,
                                        initial: .nominal)
        let stream = source.stream
        source.start()
        provider.set(.serious)
        center.post(name: name, object: nil)
        let values = await collect(2, from: stream)
        XCTAssertEqual(values, [.nominal, .serious])
        source.stop()
    }

    func testThermalRepeatedValueIsNotRepublished() async {
        let name = Notification.Name("xl.signals.thermal.repeat")
        let center = NotificationCenter()
        let provider = StubThermalProvider(.fair)
        let source = ThermalSignalSource(notificationCenter: center,
                                        notifications: [name],
                                        provider: provider,
                                        initial: .fair)
        let stream = source.stream
        source.start()
        _ = source.refresh()
        _ = source.refresh()
        let values = await collect(1, from: stream)
        XCTAssertEqual(values, [.fair])
        source.stop()
    }

    func testProcessInfoThermalMapping() {
        XCTAssertEqual(ThermalPressure(processInfoState: .nominal), .nominal)
        XCTAssertEqual(ThermalPressure(processInfoState: .fair), .fair)
        XCTAssertEqual(ThermalPressure(processInfoState: .serious), .serious)
        XCTAssertEqual(ThermalPressure(processInfoState: .critical), .critical)
    }

    func testBatteryNotificationSamplesLowPowerMode() async {
        let center = NotificationCenter()
        let name = Notification.Name("xl.signals.battery")
        let provider = StubBatteryProvider(
            BatterySnapshot(level: 0.8, isLowPowerModeEnabled: false, isCharging: false))
        let source = BatterySignalSource(notificationCenter: center,
                                         notifications: [name],
                                         provider: provider)
        let stream = source.stream
        source.start()
        _ = await source.refresh()
        provider.set(BatterySnapshot(level: 0.1, isLowPowerModeEnabled: true,
                                     isCharging: false))
        center.post(name: name, object: nil)
        _ = await source.refresh()
        let values = await collect(2, from: stream)
        XCTAssertEqual(values?.last, BatterySnapshot(level: 0.1,
                                                     isLowPowerModeEnabled: true,
                                                     isCharging: false))
        XCTAssertEqual(values?.count, 2)
        source.stop()
    }

    func testPlatformBatteryNotificationListIsNotEmpty() {
        XCTAssertFalse(BatterySignalSource.platformNotifications.isEmpty)
    }
}

final class SignalsNetworkPathTests: XCTestCase {
    func testFakeMonitorPushesPathStatuses() async {
        let monitor = FakeNetworkPathMonitor()
        let source = NetworkPathSignalSource(monitor: monitor)
        let stream = source.stream
        source.start()
        XCTAssertEqual(monitor.starts, 1)
        monitor.push(.satisfied)
        monitor.push(.unsatisfied)
        let values = await collect(2, from: stream)
        XCTAssertEqual(values, [.satisfied, .unsatisfied])
        source.stop()
        XCTAssertEqual(monitor.stops, 1)
    }

    func testInitialStatusIsEmittedOnce() async {
        let monitor = FakeNetworkPathMonitor()
        let source = NetworkPathSignalSource(monitor: monitor, initial: .requiresConnection)
        let stream = source.stream
        source.start()
        let values = await collect(1, from: stream)
        XCTAssertEqual(values, [.requiresConnection])
        source.stop()
    }
}

final class SignalsMemoryProxyTests: XCTestCase {
    func testWithinBudgetDecisionIsClear() async {
        let sample = MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": 1024, "/dsh/tmp": 1024],
            sessionBytes: 0, webContentTerminations: 0)
        let source = MemoryProxySignalSource(
            provider: StaticMemoryProxyProvider(sample),
            monitor: BudgetMonitor(table: .eightGB),
            interval: 0)
        let decision = await source.refresh()
        XCTAssertTrue(decision.isClear)
        let samples = await collect(1, from: source.stream)
        XCTAssertEqual(samples, [sample])
        let decisions = await collect(1, from: source.decisions)
        XCTAssertEqual(decisions, [decision])
        source.stop()
    }

    func testBudgetMonitorDrivesTheFirstAction() async {
        let table = BudgetTable.eightGB
        let sample = MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": table.workspaceBytes + 1],
            sessionBytes: 0, webContentTerminations: 0)
        let source = MemoryProxySignalSource(
            provider: StaticMemoryProxyProvider(sample),
            monitor: BudgetMonitor(table: table),
            interval: 0)
        let decision = await source.refresh()
        XCTAssertEqual(decision.action, .clearTmp)
        XCTAssertEqual(decision.vfsLimitBytes, table.vfsLogicalBytes)
        source.stop()
    }

    func testStartWithoutAPollIntervalSamplesOnce() async {
        let sample = MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": 2048],
            sessionBytes: 0, webContentTerminations: 0)
        let source = MemoryProxySignalSource(
            provider: StaticMemoryProxyProvider(sample),
            monitor: BudgetMonitor(table: .eightGB),
            interval: 0)
        let stream = source.stream
        source.start()
        let samples = await collect(1, from: stream)
        XCTAssertEqual(samples, [sample])
        source.stop()
    }

    func testRepeatedTerminationsAreAlsoPressure() async {
        let sample = MemoryProxySample(
            vfsBytesByPrefix: [:], sessionBytes: 0,
            webContentTerminations: BudgetMonitor.defaultTerminationThreshold)
        let source = MemoryProxySignalSource(
            provider: StaticMemoryProxyProvider(sample),
            monitor: BudgetMonitor(table: .eightGB, terminationThreshold: 3),
            interval: 0)
        let decision = await source.refresh()
        XCTAssertEqual(decision.action, .plannedRestart)
        source.stop()
    }
}

final class SignalsPlatformHostSignalsTests: XCTestCase {
    func testCompositeForwardsEachSourceAndOwnerInjectedSignals() async {
        let center = NotificationCenter()
        let sceneName = Notification.Name("xl.signals.composite.scene")
        let thermalName = Notification.Name("xl.signals.composite.thermal")
        let scene = ScenePhaseSignalSource(
            notificationCenter: center,
            notifications: ScenePhaseNotifications(active: [sceneName],
                                                   inactive: [], background: []),
            initial: nil)
        let thermal = ThermalSignalSource(
            notificationCenter: center,
            notifications: [thermalName],
            provider: StubThermalProvider(.nominal),
            initial: .nominal)
        let battery = BatterySignalSource(
            notificationCenter: center,
            notifications: [],
            provider: StubBatteryProvider(
                BatterySnapshot(level: 0.5, isLowPowerModeEnabled: false,
                                isCharging: true)))
        let network = NetworkPathSignalSource(monitor: FakeNetworkPathMonitor(),
                                              initial: .satisfied)
        let signals = PlatformHostSignals(scenePhase: scene, thermal: thermal,
                                          battery: battery, network: network,
                                          memoryProxy: nil)

        let sceneStream = signals.scenePhase
        let thermalStream = signals.thermal
        let batteryStream = signals.battery
        let pathStream = signals.path
        signals.start()
        center.post(name: sceneName, object: nil)

        let phases = await collect(1, from: sceneStream)
        XCTAssertEqual(phases, [.active])
        let pressures = await collect(1, from: thermalStream)
        XCTAssertEqual(pressures, [.nominal])
        let paths = await collect(1, from: pathStream)
        XCTAssertEqual(paths, [.satisfied])

        // The battery source samples asynchronously on start; its stream is
        // observable and carries the injected snapshot once sampled.
        let batteries = await collect(1, from: batteryStream)
        XCTAssertEqual(batteries?.first?.level, 0.5)

        let termination = WebContentTermination(wasForeground: true,
                                                terminationCount: 2)
        signals.send(termination)
        let terminations = await collect(1, from: signals.webContentTerminated)
        XCTAssertEqual(terminations, [termination])

        let expiration = BackgroundTaskExpiration(taskID: "task-1",
                                                  remainingSeconds: 3)
        signals.send(expiration)
        let expirations = await collect(1, from: signals.backgroundTaskExpiring)
        XCTAssertEqual(expirations, [expiration])

        // No memory-proxy source: the stream is finished instead of hanging.
        let memory = await collect(1, from: signals.memoryProxy)
        XCTAssertEqual(memory, [])

        signals.stop()
    }
}
