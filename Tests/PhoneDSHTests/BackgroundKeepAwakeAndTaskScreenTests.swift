// SPDX-License-Identifier: MIT
// W6-BACKGROUND keep-awake and task-screen tests.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH

final class BackgroundPluggedInKeepAwakeTests: XCTestCase {
    func testChargingAndRunningDisablesTheIdleTimer() {
        let timer = RecordingIdleTimer()
        let keepAwake = PluggedInKeepAwake(idleTimer: timer)
        let disabled = keepAwake.update(isCharging: true, hostState: .running)
        XCTAssertTrue(disabled)
        XCTAssertTrue(timer.isIdleTimerDisabled)
        XCTAssertEqual(timer.recordedChanges, [true])
    }

    func testNotChargingKeepsTheIdleTimerOn() {
        let timer = RecordingIdleTimer()
        let keepAwake = PluggedInKeepAwake(idleTimer: timer)
        keepAwake.update(isCharging: false, hostState: .running)
        XCTAssertFalse(timer.isIdleTimerDisabled)
        XCTAssertEqual(timer.recordedChanges, [])
    }

    func testChargingButParkedKeepsTheIdleTimerOn() {
        let timer = RecordingIdleTimer()
        let keepAwake = PluggedInKeepAwake(idleTimer: timer)
        keepAwake.update(isCharging: true, hostState: .parked)
        XCTAssertFalse(timer.isIdleTimerDisabled)
    }

    func testLeavingRunningRestoresTheIdleTimerIdempotently() {
        let timer = RecordingIdleTimer()
        let keepAwake = PluggedInKeepAwake(idleTimer: timer)
        keepAwake.update(isCharging: true, hostState: .running)
        keepAwake.update(isCharging: true, hostState: .running)
        XCTAssertEqual(timer.recordedChanges, [true])
        keepAwake.update(isCharging: false, hostState: .draining)
        XCTAssertEqual(timer.recordedChanges, [true, false])
        keepAwake.update(isCharging: false, hostState: .parked)
        XCTAssertEqual(timer.recordedChanges, [true, false])
        keepAwake.reset()
        XCTAssertEqual(timer.recordedChanges, [true, false])
    }

    func testTheDecisionTable() {
        XCTAssertTrue(PluggedInKeepAwake.shouldKeepAwake(isCharging: true,
                                                        hostState: .running))
        XCTAssertFalse(PluggedInKeepAwake.shouldKeepAwake(isCharging: true,
                                                          hostState: .recovering))
        XCTAssertFalse(PluggedInKeepAwake.shouldKeepAwake(isCharging: true,
                                                          hostState: .failed))
        XCTAssertFalse(PluggedInKeepAwake.shouldKeepAwake(isCharging: false,
                                                          hostState: .running))
    }

    func testManualLockIsDocumentedAsUnpreventable() {
        XCTAssertFalse(PluggedInKeepAwake.preventsManualLock)
    }
}

/// Recording brightness adapter for the task screen.
final class RecordingScreenBrightness: ScreenBrightnessControlling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    private var storedWrites: [Double] = []

    init(initial: Double?) {
        value = initial
    }

    var writes: [Double] { lock.withLock { storedWrites } }

    func screenBrightness() async -> Double? {
        lock.withLock { value }
    }

    func setScreenBrightness(_ value: Double) async {
        lock.withLock {
            self.value = value
            storedWrites.append(value)
        }
    }
}

final class BackgroundTaskScreenTests: XCTestCase {
    func testDefaultConfigurationIsPureBlackAndHintsBrightness() {
        let configuration = TaskScreenConfiguration.default
        XCTAssertTrue(configuration.dimsScreen)
        XCTAssertEqual(configuration.minimumBrightness, 0)
        XCTAssertFalse(configuration.hint.isEmpty)
        XCTAssertTrue(configuration.hint.contains("dimmed"))
    }

    func testBrightnessIsDimmedOnceAndRestored() async {
        let screen = RecordingScreenBrightness(initial: 0.7)
        let controller = TaskScreenBrightnessController(screen: screen)
        await controller.dim(minimum: 0)
        await controller.dim(minimum: 0)
        XCTAssertEqual(screen.writes, [0])
        await controller.restore()
        XCTAssertEqual(screen.writes, [0, 0.7])
        await controller.restore()
        XCTAssertEqual(screen.writes, [0, 0.7])
        XCTAssertFalse(controller.isDimmed)
    }

    func testMinimumBrightnessIsClamped() async {
        let screen = RecordingScreenBrightness(initial: 0.5)
        let controller = TaskScreenBrightnessController(screen: screen)
        await controller.dim(minimum: 1.5)
        XCTAssertEqual(screen.writes, [1])
        await controller.restore()
        XCTAssertEqual(screen.writes, [1, 0.5])
    }

    func testViewIsConstructibleWithAConfiguration() {
        let configuration = TaskScreenConfiguration(
            title: "Long task", status: "step 3", hint: "Minimum brightness",
            dimsScreen: false, minimumBrightness: 0)
        let screen = TaskScreen(configuration: configuration)
        XCTAssertEqual(screen.configuration.title, "Long task")
        XCTAssertEqual(screen.configuration.status, "step 3")
        XCTAssertFalse(screen.configuration.dimsScreen)
    }
}

final class BackgroundSchedulerPlatformTests: XCTestCase {
    func testHeadlessPlatformSchedulerOpensNoWindow() async {
        let scheduler = PlatformBackgroundTaskScheduler()
        if scheduler.kind == .none {
            let token = await scheduler.beginBackgroundTask(name: "test") {}
            XCTAssertNil(token)
        }
        // On an iOS build the same call opens a UIKit window; that path is
        // exercised by the simulator build, not by this macOS test.
        let noopScheduler = NoopBackgroundTaskScheduler()
        let noop = await noopScheduler.beginBackgroundTask(name: "test") {}
        XCTAssertNil(noop)
    }
}
