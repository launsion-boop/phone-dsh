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
    func testButtonsOwnTheirSweepWhenNoWakeIsInFlight() {
        XCTAssertTrue(EngineAdoptionPolicy.shouldSweep(incarnationChanged: true,
                                                       wakeInFlight: false))
    }

    func testAWakeInFlightOwnsTheSweep() {
        XCTAssertFalse(EngineAdoptionPolicy.shouldSweep(incarnationChanged: true,
                                                        wakeInFlight: true))
    }

    func testOnlyANewIncarnationOwesASweep() {
        XCTAssertFalse(EngineAdoptionPolicy.shouldSweep(incarnationChanged: false,
                                                        wakeInFlight: false))
    }
}
