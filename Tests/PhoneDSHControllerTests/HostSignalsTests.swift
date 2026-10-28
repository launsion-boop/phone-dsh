// SPDX-License-Identifier: MIT
// PhoneDSHController: HostSignals test double and signal bus tests.

import Foundation
import XCTest
@testable import PhoneDSHController

final class HostSignalsTests: XCTestCase {
    func testRecordedSignalsDeliversScenePhase() async throws {
        let signals = RecordedSignals()
        let stream = signals.scenePhase
        let collector = Task { await collect(1, from: stream) }
        signals.sendScenePhase(.background)
        let values = await collector.value ?? []
        XCTAssertEqual(values, [.background])
        signals.finish()
    }

    func testRecordedSignalsReplaysTheLastValueToALateSubscriber() async {
        let signals = RecordedSignals()
        signals.sendPath(.unsatisfied)
        let stream = signals.path
        let values = await collect(1, from: stream) ?? []
        XCTAssertEqual(values, [.unsatisfied])
    }

    func testRecordedSignalsFinishesStreams() async {
        let signals = RecordedSignals()
        let stream = signals.thermal
        signals.finish()
        let values = await collect(1, from: stream) ?? []
        XCTAssertTrue(values.isEmpty)
    }

    func testSignalBusMergesTwoSources() async throws {
        let first = RecordedSignals()
        let second = RecordedSignals()
        let bus = SignalBus(first, second)
        first.sendScenePhase(.active)
        second.sendScenePhase(.background)
        let values = await collect(2, from: bus.scenePhase) ?? []
        XCTAssertEqual(Set(values), Set([ScenePhase.active, ScenePhase.background]))
        first.finish()
        second.finish()
    }

    func testSignalBusForwardsBackgroundTaskExpiration() async {
        let first = RecordedSignals()
        let second = RecordedSignals()
        let bus = SignalBus([first, second])
        let expiration = BackgroundTaskExpiration(taskID: "task-1",
                                                  remainingSeconds: 5)
        second.sendBackgroundTaskExpiration(expiration)
        let values = await collect(1, from: bus.backgroundTaskExpiring) ?? []
        XCTAssertEqual(values, [expiration])
        first.finish()
        second.finish()
    }

    func testSignalBusCoversEverySignal() async {
        // Compile-time coverage: every HostSignals property is reachable on the
        // bus, so adding a signal to the protocol must update both types.
        let bus = SignalBus(RecordedSignals())
        _ = bus.scenePhase
        _ = bus.thermal
        _ = bus.battery
        _ = bus.path
        _ = bus.memoryProxy
        _ = bus.webContentTerminated
        _ = bus.backgroundTaskExpiring
    }
}
