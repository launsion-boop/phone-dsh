// SPDX-License-Identifier: MIT
// PhoneDSHController: planned restart scheduling tests.

import Foundation
import XCTest
@testable import PhoneDSHController

private struct RestartFailure: Error, Sendable {}

/// State of the two non-step boundary conditions (budgets.md §4).
private final class BoundaryConditions: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: Int
    private var storedEpochClosed: Bool

    init(framesInFlight: Int, epochClosed: Bool) {
        self.storedFrames = framesInFlight
        self.storedEpochClosed = epochClosed
    }

    var framesInFlight: Int {
        get { lock.withLock { storedFrames } }
        set { lock.withLock { storedFrames = newValue } }
    }

    var epochClosed: Bool {
        get { lock.withLock { storedEpochClosed } }
        set { lock.withLock { storedEpochClosed = newValue } }
    }
}

final class RestartSchedulerTests: XCTestCase {
    private func makeScheduler(clock: ManualHostClock,
                               boundary: StubBoundary,
                               requester: RecordingRestartRequester,
                               interval: TimeInterval = 2 * 60 * 60) throws -> RestartScheduler {
        try RestartScheduler(clock: clock, requester: requester,
                             boundary: boundary, intervalSeconds: interval)
    }

    func testNotDueBeforeTwoHours() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        clock.advance(by: 2 * 60 * 60 - 1)
        let result = try await scheduler.poll()
        XCTAssertEqual(result, .notDue)
        XCTAssertTrue(requester.reasons.isEmpty)
        XCTAssertEqual(boundary.checks, 0, "the boundary is not consulted before the deadline")
    }

    func testDueAtTwoHoursRequestsRestartAtBoundary() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        clock.advance(by: 2 * 60 * 60)
        let result = try await scheduler.poll()
        XCTAssertEqual(result, .requested(reason: .plannedInterval))
        XCTAssertEqual(requester.reasons, [.plannedInterval])

        // The next interval starts from the restart.
        clock.advance(by: 2 * 60 * 60 - 1)
        let again = try await scheduler.poll()
        XCTAssertEqual(again, .notDue)
    }

    func testRestartIsDeferredWhileAToolCallIsRunning() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        clock.advance(by: 2 * 60 * 60)
        let deferred = try await scheduler.poll()
        XCTAssertEqual(deferred, .deferred(reason: .plannedInterval))
        XCTAssertTrue(requester.reasons.isEmpty)
        let pending = await scheduler.pendingReason
        XCTAssertEqual(pending, .plannedInterval)

        boundary.idle = true
        let requested = try await scheduler.poll()
        XCTAssertEqual(requested, .requested(reason: .plannedInterval))
        XCTAssertEqual(requester.reasons, [.plannedInterval])
    }

    func testBudgetActionForcesTheNextBoundaryRestart() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        await scheduler.requestBudgetRestart()
        let deferred = try await scheduler.poll()
        XCTAssertEqual(deferred, .deferred(reason: .budget))
        XCTAssertTrue(requester.reasons.isEmpty)

        boundary.idle = true
        let requested = try await scheduler.poll()
        XCTAssertEqual(requested, .requested(reason: .budget))
        XCTAssertEqual(requester.reasons, [.budget])
    }

    func testEngineFailureKeepsThePendingRequestForRetry() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let requester = RecordingRestartRequester()
        requester.fail(with: RestartFailure())
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        await scheduler.requestBudgetRestart()
        do {
            _ = try await scheduler.poll()
            XCTFail("the engine failure must propagate")
        } catch {
            XCTAssertTrue(error is RestartFailure)
            let pending = await scheduler.pendingReason
            XCTAssertEqual(pending, .budget)
        }
    }

    func testRestartCompletedResetsTheInterval() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        clock.advance(by: 1000)
        await scheduler.restartCompleted()
        clock.advance(by: 2 * 60 * 60 - 1)
        let result = try await scheduler.poll()
        XCTAssertEqual(result, .notDue)
        XCTAssertTrue(requester.reasons.isEmpty)
    }

    func testCancelPendingRestartStopsTheRequest() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let requester = RecordingRestartRequester()
        let scheduler = try makeScheduler(clock: clock, boundary: boundary,
                                          requester: requester)
        await scheduler.requestBudgetRestart()
        await scheduler.cancelPendingRestart()
        let result = try await scheduler.poll()
        XCTAssertEqual(result, .notDue)
        XCTAssertTrue(requester.reasons.isEmpty)
    }

    func testEngineAdapterForwardsTheMappedReasonAndPropagatesFailure() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: true)
        let engine = RecordingRestartRequester()
        let adapter = WebEngineRestartAdapter { reason in
            try await engine.requestWebContentRestart(reason: reason)
        }
        let scheduler = try RestartScheduler(clock: clock, requester: adapter,
                                             boundary: boundary,
                                             intervalSeconds: 2 * 60 * 60)
        clock.advance(by: 2 * 60 * 60)
        let result = try await scheduler.poll()
        XCTAssertEqual(result, .requested(reason: .plannedInterval))
        XCTAssertEqual(engine.reasons, [.plannedInterval])

        engine.fail(with: RestartFailure())
        await scheduler.requestBudgetRestart()
        do {
            _ = try await scheduler.poll()
            XCTFail("the engine failure must propagate through the adapter")
        } catch {
            XCTAssertTrue(error is RestartFailure)
        }
    }

    func testInvalidIntervalIsRejected() {
        XCTAssertThrowsError(try RestartScheduler(
            clock: ManualHostClock(), requester: RecordingRestartRequester(),
            boundary: StubBoundary(idle: true), intervalSeconds: 0))
    }

    // MARK: - budgets.md §4: 60 s boundary escape

    func testBoundaryWaitForcesDrainAndRestartAfterSixtySeconds() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let path = RecordingRestartPath()
        let scheduler = try RestartScheduler(clock: clock, requester: path,
                                             boundary: boundary, intervalSeconds: 7200,
                                             drainer: path)
        clock.advance(by: 2 * 60 * 60)
        let deferred = try await scheduler.poll()
        XCTAssertEqual(deferred, .deferred(reason: .plannedInterval))
        XCTAssertEqual(path.events, [], "a running tool call still blocks the restart")

        clock.advance(by: 59)
        let stillDeferred = try await scheduler.poll()
        XCTAssertEqual(stillDeferred, .deferred(reason: .plannedInterval))
        XCTAssertEqual(path.events, [])

        clock.advance(by: 1)
        let forced = try await scheduler.poll()
        XCTAssertEqual(forced, .forced(reason: .plannedInterval))
        XCTAssertEqual(path.events, [.drained(.plannedInterval),
                                      .restarted(.plannedInterval)],
                       "the host drains before the engine is restarted")
        let pending = await scheduler.pendingReason
        XCTAssertNil(pending)
        let deadline = await scheduler.boundaryDeadline
        XCTAssertNil(deadline)
    }

    func testBoundaryWaitIsPerRequestAndResetsWhenTheBoundaryArrives() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let path = RecordingRestartPath()
        let scheduler = try RestartScheduler(clock: clock, requester: path,
                                             boundary: boundary, intervalSeconds: 7200,
                                             drainer: path)
        await scheduler.requestBudgetRestart()
        let deferred = try await scheduler.poll()
        XCTAssertEqual(deferred, .deferred(reason: .budget))
        clock.advance(by: 30)
        boundary.idle = true
        let requested = try await scheduler.poll()
        XCTAssertEqual(requested, .requested(reason: .budget))
        XCTAssertEqual(path.events, [.restarted(.budget)])

        boundary.idle = false
        await scheduler.requestBudgetRestart()
        clock.advance(by: 30)
        let second = try await scheduler.poll()
        XCTAssertEqual(second, .deferred(reason: .budget),
                       "the new request gets its own 60 s, not the old deadline")
        clock.advance(by: 30)
        let forced = try await scheduler.poll()
        XCTAssertEqual(forced, .forced(reason: .budget))
        XCTAssertEqual(path.events, [.restarted(.budget),
                                      .drained(.budget), .restarted(.budget)])
    }

    func testCancelPendingRestartClearsTheBoundaryWait() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let path = RecordingRestartPath()
        let scheduler = try RestartScheduler(clock: clock, requester: path,
                                             boundary: boundary, intervalSeconds: 7200,
                                             drainer: path)
        await scheduler.requestBudgetRestart()
        _ = try await scheduler.poll()
        await scheduler.cancelPendingRestart()
        clock.advance(by: 120)
        let notDue = try await scheduler.poll()
        XCTAssertEqual(notDue, .notDue)
        XCTAssertEqual(path.events, [])

        await scheduler.requestBudgetRestart()
        let fresh = try await scheduler.poll()
        XCTAssertEqual(fresh, .deferred(reason: .budget))
        clock.advance(by: 59)
        let beforeDeadline = try await scheduler.poll()
        XCTAssertEqual(beforeDeadline, .deferred(reason: .budget))
        clock.advance(by: 1)
        let forced = try await scheduler.poll()
        XCTAssertEqual(forced, .forced(reason: .budget))
    }

    func testDrainFailureKeepsThePendingRequest() async throws {
        let clock = ManualHostClock()
        let boundary = StubBoundary(idle: false)
        let path = RecordingRestartPath()
        path.failDrain(with: RestartFailure())
        let scheduler = try RestartScheduler(clock: clock, requester: path,
                                             boundary: boundary, intervalSeconds: 7200,
                                             drainer: path)
        await scheduler.requestBudgetRestart()
        clock.advance(by: 60)
        do {
            _ = try await scheduler.poll()
            XCTFail("the drain failure must propagate")
        } catch {
            XCTAssertTrue(error is RestartFailure)
            let pending = await scheduler.pendingReason
            XCTAssertEqual(pending, .budget)
            XCTAssertEqual(path.reasons, [], "the engine is not touched after a failed drain")
        }
    }

    func testInvalidBoundaryTimeoutIsRejected() {
        XCTAssertThrowsError(try RestartScheduler(
            clock: ManualHostClock(), requester: RecordingRestartRequester(),
            boundary: StubBoundary(idle: true), boundaryTimeoutSeconds: 0))
    }

    // MARK: - budgets.md §4: complete three-condition boundary

    func testComposedBoundaryRequiresNoFrameClosedEpochAndNoExecRunning() async {
        let conditions = BoundaryConditions(framesInFlight: 1, epochClosed: false)
        let steps = StubBoundary(idle: true)
        let boundary = ToolCallBoundary(
            noFrameInFlight: { conditions.framesInFlight == 0 },
            epochClosed: { conditions.epochClosed },
            steps: steps)

        var atBoundary = await boundary.atToolCallBoundary()
        XCTAssertFalse(atBoundary, "a frame in flight is not a boundary")

        conditions.framesInFlight = 0
        atBoundary = await boundary.atToolCallBoundary()
        XCTAssertFalse(atBoundary, "an open WAL epoch is not a boundary")

        conditions.epochClosed = true
        steps.idle = false
        atBoundary = await boundary.atToolCallBoundary()
        XCTAssertFalse(atBoundary, "an exec_running step is not a boundary")

        steps.idle = true
        atBoundary = await boundary.atToolCallBoundary()
        XCTAssertTrue(atBoundary)
    }

    func testSchedulerDoesNotRestartUntilAllBoundaryConditionsAreSatisfied() async throws {
        let clock = ManualHostClock()
        let conditions = BoundaryConditions(framesInFlight: 1, epochClosed: false)
        let steps = StubBoundary(idle: true)
        let boundary = ToolCallBoundary(
            noFrameInFlight: { conditions.framesInFlight == 0 },
            epochClosed: { conditions.epochClosed },
            steps: steps)
        let path = RecordingRestartPath()
        let scheduler = try RestartScheduler(clock: clock, requester: path,
                                             boundary: boundary,
                                             intervalSeconds: 7200, drainer: path)
        clock.advance(by: 7200)
        let frameInFlight = try await scheduler.poll()
        XCTAssertEqual(frameInFlight, .deferred(reason: .plannedInterval))
        XCTAssertEqual(path.events, [])

        conditions.framesInFlight = 0
        let epochOpen = try await scheduler.poll()
        XCTAssertEqual(epochOpen, .deferred(reason: .plannedInterval))
        XCTAssertEqual(path.events, [])

        conditions.epochClosed = true
        let requested = try await scheduler.poll()
        XCTAssertEqual(requested, .requested(reason: .plannedInterval))
        XCTAssertEqual(path.events, [.restarted(.plannedInterval)])
    }

    // MARK: - HostStateMachineRestartDrainer

    func testHostDrainerClosesAdmissionAndClosesTheEpoch() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(
            for: self, clock: ManualHostClock(), closer: closer)
        _ = try await machine.verifyLease()
        XCTAssertEqual(machine.admission.current, .open)

        let drainer = HostStateMachineRestartDrainer(machine)
        try await drainer.drainForForcedRestart(reason: .budget)

        let state = await machine.state
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
        XCTAssertEqual(closer.count, 1, "the forced drain closes the WAL epoch")
    }

    func testHostDrainerRejectsRemoteAuthority() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        _ = try await machine.handle(.handoffFenceInstalled)
        _ = try await machine.handle(.handoffCompleted(remoteAdmission: .open))

        let drainer = HostStateMachineRestartDrainer(machine)
        do {
            try await drainer.drainForForcedRestart(reason: .plannedInterval)
            XCTFail("the phone must not restart locally while the remote holds the fence")
        } catch {
            XCTAssertEqual(error as? RestartDrainError, .hostNotRestartable(state: .remote))
        }
        let state = await machine.state
        XCTAssertEqual(state, .remote)
    }
}
