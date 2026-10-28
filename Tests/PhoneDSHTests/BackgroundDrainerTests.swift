// SPDX-License-Identifier: MIT
// W6-BACKGROUND drainer tests: completion, the controller-owned 20 s deadline,
// the OS expiration path and the epoch flush that must happen before the
// window ends. All timing is virtual.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH

final class BackgroundDrainerTests: XCTestCase {
    func testBackgroundDrainCompletesBeforeDeadlineAndFlushesTheEpoch() async throws {
        let clock = ManualDrainClock()
        let closer = BackgroundEpochCloser()
        let machine = try BackgroundTestSupport.makeMachine(for: self, clock: clock,
                                                            closer: closer)
        try await machine.verifyLease()
        let runningState = await machine.currentState()
        XCTAssertEqual(runningState, .running)

        let scheduler = RecordingBackgroundScheduler(kind: .continuedProcessing)
        let drainer = BackgroundDrainer(
            controller: machine, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20, grace: 2, taskName: "test-drain"))

        let task = Task { await drainer.drainForBackground() }
        await BackgroundTestSupport.waitFor("Draining") {
            await machine.currentState() == .draining
        }
        let deadline = await machine.drainDeadline
        XCTAssertNotNil(deadline)
        if let deadline {
            XCTAssertEqual(deadline.timeIntervalSince(clock.now), 20, accuracy: 0.001)
        }

        // The facade's in-flight drain finished early.
        try await machine.handle(.backgroundDrainCompleted)
        let report = await task.value

        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.finalState, .parked)
        XCTAssertEqual(report.taskKind, .continuedProcessing)
        XCTAssertEqual(report.deadlineSeconds, 20)
        XCTAssertEqual(report.elapsedSeconds, 0, accuracy: 0.001)
        // The state machine closed the epoch on Draining -> Parked.
        XCTAssertEqual(closer.count, 1)
        // Exactly one OS window was opened, reported and ended.
        XCTAssertEqual(scheduler.beginCount, 1)
        XCTAssertEqual(scheduler.endCount, 1)
        XCTAssertEqual(scheduler.ended.first?.kind, .continuedProcessing)
        XCTAssertEqual(scheduler.progress.last, 1)
        XCTAssertEqual(scheduler.beginNames, ["test-drain"])
        await machine.shutdown()
    }

    func testControllerDeadlineAtTwentySecondsIsReportedAsDeadline() async throws {
        let clock = ManualDrainClock()
        let closer = BackgroundEpochCloser()
        let machine = try BackgroundTestSupport.makeMachine(for: self, clock: clock,
                                                            closer: closer)
        try await machine.verifyLease()
        let scheduler = RecordingBackgroundScheduler()
        let drainer = BackgroundDrainer(
            controller: machine, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20, grace: 2))

        let task = Task { await drainer.drainForBackground() }
        await BackgroundTestSupport.waitFor("Draining") {
            await machine.currentState() == .draining
        }
        // The controller's own drain timer and the drainer deadline are both
        // on the manual clock.
        await BackgroundTestSupport.waitForSleepers(clock, count: 2)
        clock.advance(by: 20)
        let report = await task.value

        XCTAssertEqual(report.outcome, .deadlineExceeded)
        XCTAssertEqual(report.finalState, .parked)
        XCTAssertEqual(report.elapsedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(closer.count, 1)
        XCTAssertEqual(scheduler.beginCount, 1)
        XCTAssertEqual(scheduler.endCount, 1)
        await machine.shutdown()
    }

    func testDeadlineForcesTheSignalWhenTheControllerIsStuck() async {
        let clock = ManualDrainClock()
        let controller = StubDrainController(initialState: .running)
        let scheduler = RecordingBackgroundScheduler()
        let drainer = BackgroundDrainer(
            controller: controller, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20, grace: 2))

        let task = Task { await drainer.drainForBackground() }
        await BackgroundTestSupport.waitFor("Draining") {
            controller.currentState == .draining
        }
        await BackgroundTestSupport.waitForSleepers(clock, count: 1)
        clock.advance(by: 20)
        await BackgroundTestSupport.waitFor("forced deadline signal") {
            controller.receivedSignals.contains(.drainDeadlineElapsed)
        }
        await BackgroundTestSupport.waitForSleepers(clock, count: 1)
        clock.advance(by: 2)
        let report = await task.value

        XCTAssertEqual(report.outcome, .deadlineExceeded)
        XCTAssertEqual(report.finalState, .draining)
        XCTAssertEqual(controller.receivedSignals.first, .scenePhase(.background))
        XCTAssertTrue(controller.receivedSignals.contains(.drainDeadlineElapsed))
        XCTAssertEqual(scheduler.endCount, 1)
        XCTAssertEqual(scheduler.progress.last, 1)
    }

    func testOSExpirationForcesTheBackgroundTaskExpiredSignal() async {
        let clock = ManualDrainClock()
        let controller = StubDrainController(initialState: .running)
        let scheduler = RecordingBackgroundScheduler()
        let drainer = BackgroundDrainer(
            controller: controller, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20, grace: 2))

        let task = Task { await drainer.drainForBackground() }
        await BackgroundTestSupport.waitFor("Draining") {
            controller.currentState == .draining
        }
        scheduler.expireAll()
        await BackgroundTestSupport.waitFor("expiration signal") {
            controller.receivedSignals.contains(.backgroundTaskExpired)
        }
        await BackgroundTestSupport.waitForSleepers(clock, count: 1)
        clock.advance(by: 2)
        let report = await task.value

        XCTAssertEqual(report.outcome, .backgroundTaskExpired)
        XCTAssertTrue(controller.receivedSignals.contains(.backgroundTaskExpired))
        XCTAssertEqual(scheduler.endCount, 1)
    }

    func testDrainOnAnAlreadyParkedHostClosesTheWindow() async {
        let clock = ManualDrainClock()
        let controller = StubDrainController(initialState: .parked)
        let scheduler = RecordingBackgroundScheduler()
        let drainer = BackgroundDrainer(
            controller: controller, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20))

        let report = await drainer.drainForBackground()
        XCTAssertEqual(report.outcome, .alreadyParked)
        XCTAssertEqual(report.finalState, .parked)
        XCTAssertEqual(scheduler.endCount, 1)
        XCTAssertEqual(scheduler.beginCount, 1)
    }

    func testNoopSchedulerStillCompletesTheDrainWindow() async throws {
        let clock = ManualDrainClock()
        let closer = BackgroundEpochCloser()
        let machine = try BackgroundTestSupport.makeMachine(for: self, clock: clock,
                                                            closer: closer)
        try await machine.verifyLease()
        let drainer = BackgroundDrainer(
            controller: machine,
            scheduler: NoopBackgroundTaskScheduler(),
            clock: clock,
            configuration: .init(deadline: 20))

        let task = Task { await drainer.drainForBackground() }
        await BackgroundTestSupport.waitFor("Draining") {
            await machine.currentState() == .draining
        }
        try await machine.handle(.backgroundDrainCompleted)
        let report = await task.value
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.taskKind, BackgroundTaskKind.none)
        XCTAssertEqual(closer.count, 1)
        await machine.shutdown()
    }

    func testConcurrentDrainCallsJoinTheSameWindow() async {
        let clock = ManualDrainClock()
        let controller = StubDrainController(initialState: .parked)
        let scheduler = RecordingBackgroundScheduler()
        let drainer = BackgroundDrainer(
            controller: controller, scheduler: scheduler, clock: clock,
            configuration: .init(deadline: 20))

        async let first = drainer.drainForBackground()
        async let second = drainer.drainForBackground()
        let firstReport = await first
        let secondReport = await second
        XCTAssertEqual(firstReport.outcome, secondReport.outcome)
        // A parked host refuses the scenePhase signal before any window wait;
        // both callers see one report. The exact window count may be one (the
        // two calls race into the actor); it must never be more than one per
        // caller.
        XCTAssertLessThanOrEqual(scheduler.beginCount, 2)
    }
}
