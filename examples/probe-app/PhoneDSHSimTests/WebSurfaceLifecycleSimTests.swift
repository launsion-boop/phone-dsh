// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator: Web surface lifecycle regression.
//
// These are the lifecycle defects the Web surface review found:
//
//   * a background park was applied to a `.failed` host, which only moved the
//     facade to `.stopped` while the controller stayed `Failed`; the next
//     resume() threw and the explicit userReset() retry became unreachable;
//   * stop() waited a fixed 30 s while a scene-triggered resume may be inside
//     the host's 240 s hello timeout, then called host.stop() beside the still
//     starting resume;
//   * the failed-host reset only checked the `starting` flag, so a retry that
//     arrived while a park/resume owned the host could shut the anchor down
//     underneath it. Start, reset, park, resume and stop now wait on one
//     lifecycle token.
//
// The production gate/policy is compiled into this hostless target (it has no
// SwiftUI/UIKit dependency), so these tests exercise the same rules the app
// runs. This is simulator evidence, never device evidence.
//
// `XCTestCase.fulfillment(of:timeout:)` returns Void in this SDK, so the tests
// assert the gate's real ordering and completion through a main-actor event
// log instead of comparing a waiter result to `.timedOut`.

import Foundation
import XCTest

/// Records which lifecycle owner acted, in order. The tests keep this on the
/// main actor, so an acquisition that ran before `end()` is already visible
/// in `events`; the negative mutual-exclusion assertions need no fixed wait.
@MainActor
private final class LifecycleEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func has(_ event: String) -> Bool {
        events.contains(event)
    }
}

@MainActor
final class WebSurfaceLifecycleSimTests: XCTestCase {
    func testFailedHostStaysRetryableInsteadOfBeingParked() {
        // A failed controller has no Parked edge; parking it loses userReset().
        XCTAssertFalse(WebSurfaceLifecyclePolicy.allowsPark(hostFailed: true))
        XCTAssertTrue(WebSurfaceLifecyclePolicy.allowsPark(hostFailed: false))

        // A stale parked flag must not override the failure and start a resume
        // that throws on every retry.
        XCTAssertFalse(WebSurfaceLifecyclePolicy.allowsResume(parked: true,
                                                              hostFailed: true))
        XCTAssertTrue(WebSurfaceLifecyclePolicy.allowsResume(parked: true,
                                                             hostFailed: false))
        XCTAssertFalse(WebSurfaceLifecyclePolicy.allowsResume(parked: false,
                                                              hostFailed: false))
    }

    func testTeardownWaitsForInFlightResumeToEnd() async {
        let gate = WebSurfaceLifecycleGate()
        let events = LifecycleEventLog()
        XCTAssertTrue(gate.begin(stopping: false))
        events.record("resume began")
        XCTAssertTrue(gate.isTransitioning)
        // A second start/park/resume cannot claim the transition token while
        // the first one is still booting the Worker.
        XCTAssertFalse(gate.begin(stopping: false))

        let waiter = Task { @MainActor in
            events.record("teardown waiting")
            await gate.waitUntilIdle()
            events.record("teardown proceeded")
        }
        // The waiter has announced that it is entering the gate. `end()` has
        // not run, so an implementation that returned without waiting would
        // already have recorded "teardown proceeded"; the gate deliberately
        // has no timer that could release it here.
        await waitForLifecycleCondition { events.has("teardown waiting") }
        XCTAssertEqual(events.events, ["resume began", "teardown waiting"])
        XCTAssertTrue(gate.isTransitioning)

        gate.end()
        events.record("resume ended")
        await waitForLifecycleCondition { events.has("teardown proceeded") }
        await waiter.value
        XCTAssertEqual(events.events,
                       ["resume began", "teardown waiting",
                        "resume ended", "teardown proceeded"])
        XCTAssertFalse(gate.isTransitioning)
    }

    func testStoppingRefusesNewTransitionsUntilTeardownBegins() {
        let gate = WebSurfaceLifecycleGate()
        XCTAssertFalse(gate.begin(stopping: true))
        XCTAssertFalse(gate.isTransitioning)

        // After the teardown request is cleared the same gate is reusable.
        XCTAssertTrue(gate.begin(stopping: false))
        gate.end()
        XCTAssertTrue(gate.begin(stopping: false))
        gate.end()
    }

    func testFailedResetWaitsForInFlightParkInsteadOfOverlapping() async {
        let gate = WebSurfaceLifecycleGate()
        let events = LifecycleEventLog()
        // A background park owns the token and is still draining.
        XCTAssertTrue(gate.begin(stopping: false))
        events.record("park began")

        // The retry/reset path must not shut the anchor down beside that park:
        // it waits for the same token, then becomes the next transition.
        let reset = Task { @MainActor in
            events.record("reset waiting")
            guard await gate.acquire(stopping: false) else {
                events.record("reset refused")
                return
            }
            events.record("reset acquired")
            XCTAssertTrue(gate.isTransitioning,
                          "reset must own the lifecycle token after acquire")
            gate.end()
            events.record("reset ended")
        }

        // Announce the wait first. While the park still owns the token, a reset
        // that acquired without waiting would already appear in `events`.
        await waitForLifecycleCondition { events.has("reset waiting") }
        XCTAssertEqual(events.events, ["park began", "reset waiting"],
                       "failed reset ran while the park still owned the host")
        XCTAssertTrue(gate.isTransitioning)

        gate.end()
        events.record("park ended")
        await waitForLifecycleCondition { events.has("reset ended") }
        await reset.value
        XCTAssertEqual(events.events,
                       ["park began", "reset waiting", "park ended",
                        "reset acquired", "reset ended"])
        XCTAssertFalse(gate.isTransitioning)
    }

    func testFailedResetWaitsForInFlightResumeInsteadOfOverlapping() async {
        let gate = WebSurfaceLifecycleGate()
        let events = LifecycleEventLog()
        // A foreground resume is still inside the host's hello timeout.
        XCTAssertTrue(gate.begin(stopping: false))
        events.record("resume began")

        let reset = Task { @MainActor in
            events.record("reset waiting")
            guard await gate.acquire(stopping: false) else {
                events.record("reset refused")
                return
            }
            events.record("reset acquired")
            XCTAssertTrue(gate.isTransitioning,
                          "reset must own the lifecycle token after acquire")
            gate.end()
            events.record("reset ended")
        }

        // Same ordering contract as the park case: the reset may only acquire
        // after `end()` releases the resume's token.
        await waitForLifecycleCondition { events.has("reset waiting") }
        XCTAssertEqual(events.events, ["resume began", "reset waiting"],
                       "failed reset ran while the resume still owned the host")
        XCTAssertTrue(gate.isTransitioning)

        gate.end()
        events.record("resume ended")
        await waitForLifecycleCondition { events.has("reset ended") }
        await reset.value
        XCTAssertEqual(events.events,
                       ["resume began", "reset waiting", "resume ended",
                        "reset acquired", "reset ended"])
        XCTAssertFalse(gate.isTransitioning)
    }

    func testStopWaitsForInFlightTransitionInsteadOfTearingItDown() async {
        let gate = WebSurfaceLifecycleGate()
        let events = LifecycleEventLog()
        XCTAssertTrue(gate.begin(stopping: false))
        events.record("resume began")

        // `stop()` uses the exclusive acquisition: it blocks until the park or
        // resume really ends, then stops as the only owner of the host.
        let stop = Task { @MainActor in
            events.record("stop waiting")
            await gate.acquireExclusive()
            events.record("stop acquired")
            XCTAssertTrue(gate.isTransitioning,
                          "stop must own the lifecycle token after acquire")
            gate.end()
            events.record("stop ended")
        }

        // The stop has announced its wait but the resume still owns the token,
        // so the stop must not have torn anything down yet.
        await waitForLifecycleCondition { events.has("stop waiting") }
        XCTAssertEqual(events.events, ["resume began", "stop waiting"],
                       "stop tore down a host while its transition was running")
        XCTAssertTrue(gate.isTransitioning)

        gate.end()
        events.record("resume ended")
        await waitForLifecycleCondition { events.has("stop ended") }
        await stop.value
        XCTAssertEqual(events.events,
                       ["resume began", "stop waiting", "resume ended",
                        "stop acquired", "stop ended"])
        XCTAssertFalse(gate.isTransitioning)
    }

    func testTeardownOwnershipRefusesANewReset() async {
        let gate = WebSurfaceLifecycleGate()
        XCTAssertTrue(gate.begin(stopping: false))
        gate.end()

        // Once `stopping` is set, `acquire` must not let a reset start; the
        // teardown's exclusive acquisition owns the next move.
        let claimed = await gate.acquire(stopping: true)
        XCTAssertFalse(claimed)
        XCTAssertFalse(gate.isTransitioning)
    }
}

@MainActor
private extension WebSurfaceLifecycleSimTests {
    /// Waits for a main-actor condition with a test-only upper bound. The
    /// production gate has no deadline: this bound only keeps a broken waiter
    /// from hanging the suite, and it is never used to prove that a waiter is
    /// still blocked (that is asserted from the recorded event order).
    func waitForLifecycleCondition(_ condition: @MainActor () -> Bool,
                                   timeout: TimeInterval = 5,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("lifecycle condition not reached within \(timeout)s",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
