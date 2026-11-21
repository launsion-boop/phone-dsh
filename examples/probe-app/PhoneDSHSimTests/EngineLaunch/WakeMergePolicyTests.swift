// SPDX-License-Identifier: MIT
// Host §10.2.5 merge rule and §10.3 I4 adoption sweep: the pure policy the
// orchestrator applies when wakes overlap or an engine instance appears.
import XCTest
import ProbeKit

final class WakeMergePolicyTests: XCTestCase {
    func testNoWakeInFlightStarts() {
        XCTAssertEqual(WakeMergePolicy.action(hasInFlight: false, phase: nil), .start)
        XCTAssertEqual(WakeMergePolicy.action(hasInFlight: false, phase: .stageD), .start)
    }

    func testWakeBeforeStageDJoinsTheBoot() {
        for phase in [WakePhase.stageA, .stageB, .stageC] {
            XCTAssertEqual(WakeMergePolicy.action(hasInFlight: true, phase: phase),
                           .joinInFlight, "\(phase)")
        }
    }

    func testWakeDuringStageDCollapsesToOneFollowUp() {
        XCTAssertEqual(WakeMergePolicy.action(hasInFlight: true, phase: .stageD),
                       .mergePending)
    }

    func testMergedLeasePrefersForegroundResidency() {
        let lease = WakeLease(reason: .cloudTaskPush, grantedAtMs: 0, deadlineMs: 30_000)
        XCTAssertNil(WakeMergePolicy.mergedLease(nil, lease, nowMs: 0))
        XCTAssertNil(WakeMergePolicy.mergedLease(lease, nil, nowMs: 0))
        XCTAssertNil(WakeMergePolicy.mergedLease(nil, nil, nowMs: 0))
    }

    func testMergedLeaseKeepsTheLongestRemaining() {
        let short = WakeLease(reason: .cloudTaskPush, grantedAtMs: 0, deadlineMs: 10_000)
        let long = WakeLease(reason: .bgAppRefresh, grantedAtMs: 0, deadlineMs: 40_000)
        XCTAssertEqual(WakeMergePolicy.mergedLease(short, long, nowMs: 0), long)
        XCTAssertEqual(WakeMergePolicy.mergedLease(long, short, nowMs: 0), long)
        // Remaining time, not the raw deadline, decides.
        let lateGrant = WakeLease(reason: .cloudTaskPush, grantedAtMs: 20_000, deadlineMs: 30_000)
        XCTAssertEqual(WakeMergePolicy.mergedLease(lateGrant, short, nowMs: 20_000), lateGrant)
    }
}

final class EngineAdoptionPolicyTests: XCTestCase {
    func testOnlyTheCurrentIncarnationMaySweep() {
        XCTAssertTrue(EngineAdoptionPolicy.shouldSweep(isCurrentIncarnation: true))
        XCTAssertFalse(EngineAdoptionPolicy.shouldSweep(isCurrentIncarnation: false))
    }
}

final class WakeMergeStateTests: XCTestCase {
    private func request(_ id: String, lease: WakeLease? = nil,
                         reason: WakeReason = .foreground) -> WakeMergeState.Request {
        WakeMergeState.Request(reason: reason, lease: lease, wakeId: id)
    }

    func testNothingInFlightRunsNow() {
        var state = WakeMergeState()
        let first = request("w1")
        XCTAssertEqual(state.arrive(first), .start(first))
        XCTAssertEqual(state.inFlight?.wakeId, "w1")
        XCTAssertEqual(state.phase, .stageA)
    }

    func testArrivalsBeforeStageDJoinTheBoot() {
        var state = WakeMergeState()
        let first = request("boot")
        XCTAssertEqual(state.arrive(first), .start(first))
        state.enter(.stageB)
        let push = request("push", lease: WakeLease(reason: .cloudTaskPush, grantedAtMs: 0, deadlineMs: 30_000),
                           reason: .cloudTaskPush)
        XCTAssertEqual(state.arrive(push), .join(first))
        XCTAssertNil(state.pending)
    }

    func testStageDArrivalsCollapseIntoOneFollowUp() {
        var state = WakeMergeState()
        let first = request("boot")
        XCTAssertEqual(state.arrive(first), .start(first))
        state.enter(.stageD)
        let push = request("push", lease: WakeLease(reason: .cloudTaskPush, grantedAtMs: 0, deadlineMs: 30_000),
                           reason: .cloudTaskPush)
        guard case .pending(let merged1) = state.arrive(push) else {
            return XCTFail("expected a pending follow-up")
        }
        XCTAssertEqual(merged1.wakeId, "push")
        // A second and third arrival merge into the SAME pending request.
        guard case .pending(let merged2) = state.arrive(request("push2", reason: .boardWake)) else {
            return XCTFail("expected the same pending follow-up")
        }
        XCTAssertEqual(merged2.wakeId, "push")
        guard case .pending(let merged3) = state.arrive(request("push3")) else {
            return XCTFail("expected the same pending follow-up")
        }
        XCTAssertEqual(merged3.wakeId, "push")
        XCTAssertEqual(state.pending?.wakeId, "push")
        // The follow-up is the run that starts next, and it owns the outcome
        // every merged caller awaits.
        XCTAssertEqual(state.finish()?.wakeId, "push")
        XCTAssertEqual(state.inFlight?.wakeId, "push")
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.phase, .stageA)
    }

    func testPendingKeepsTheWidestEligibility() {
        var state = WakeMergeState()
        let first = request("boot")
        XCTAssertEqual(state.arrive(first), .start(first))
        state.enter(.stageD)
        let short = WakeLease(reason: .cloudTaskPush, grantedAtMs: 0, deadlineMs: 10_000)
        let long = WakeLease(reason: .bgAppRefresh, grantedAtMs: 0, deadlineMs: 40_000)
        _ = state.arrive(request("short", lease: short, reason: .cloudTaskPush), nowMs: 0)
        _ = state.arrive(request("long", lease: long, reason: .bgAppRefresh), nowMs: 0)
        XCTAssertEqual(state.pending?.lease, long)
        // A foreground arrival (nil lease) beats any lease.
        _ = state.arrive(request("foreground", lease: nil, reason: .foreground), nowMs: 0)
        XCTAssertNil(state.pending?.lease)
    }

    func testAdoptionDuringStageDBecomesTheOneFollowUp() {
        var state = WakeMergeState()
        let boot = request("boot")
        XCTAssertEqual(state.arrive(boot), .start(boot))
        state.enter(.stageD)
        // Three adoption notices for the new incarnation: one follow-up.
        _ = state.arrive(request("adopt-1", reason: .foreground))
        _ = state.arrive(request("adopt-2", reason: .foreground))
        _ = state.arrive(request("adopt-3", reason: .foreground))
        let followUp = state.finish()
        XCTAssertEqual(followUp?.wakeId, "adopt-1")
        XCTAssertEqual(state.inFlight?.wakeId, "adopt-1")
        XCTAssertNil(state.finish())
    }
}
