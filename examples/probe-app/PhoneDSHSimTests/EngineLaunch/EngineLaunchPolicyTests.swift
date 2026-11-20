// SPDX-License-Identifier: MIT
// Host §10.2 decision order (frozen r1). The golden vectors drive the same
// function in EngineLaunchGoldenTests; these cases pin the order itself so a
// refactor cannot reorder the branches while the golden is unchanged.
import XCTest
import ProbeKit

final class EngineLaunchPolicyTests: XCTestCase {
    private func decide(_ reason: WakeReason = .foreground,
                        foreground: Bool = false,
                        residentAudio: Bool = false,
                        hostState: EngineHostState = .absent,
                        leaseRemainingMs: Int64? = nil,
                        userStopped: Bool = false,
                        needsReset: Bool = false) -> EngineLaunchDecision {
        EngineLaunchPolicy.decide(reason: reason, foreground: foreground,
                                  residentAudio: residentAudio, hostState: hostState,
                                  leaseRemainingMs: leaseRemainingMs,
                                  userStopped: userStopped, needsReset: needsReset)
    }

    func testUserAuthorityComesBeforeEverything() {
        XCTAssertEqual(decide(foreground: true, hostState: .running, needsReset: true), .needsAttention)
        XCTAssertEqual(decide(foreground: true, hostState: .absent, needsReset: true), .needsAttention)
        XCTAssertEqual(decide(foreground: true, hostState: .absent, userStopped: true), .deferred)
        XCTAssertEqual(decide(foreground: false, residentAudio: true, hostState: .parked,
                              userStopped: true), .deferred)
    }

    func testRunningHostIsReadyWithoutTouchingTheEngine() {
        XCTAssertEqual(decide(foreground: true, hostState: .running), .ready)
        // Even without eligibility, a running host is not a transition.
        XCTAssertEqual(decide(hostState: .running), .ready)
    }

    func testForegroundAndResidentAudioAuthorizeTransitions() {
        for (foreground, resident) in [(true, false), (false, true), (true, true)] {
            XCTAssertEqual(decide(foreground: foreground, residentAudio: resident,
                                  hostState: .absent), .boot)
            XCTAssertEqual(decide(foreground: foreground, residentAudio: resident,
                                  hostState: .parked), .resume)
        }
    }

    func testLeaseIsTheOnlyBackgroundAuthorization() {
        XCTAssertEqual(decide(hostState: .absent), .nativeOnly)
        XCTAssertEqual(decide(hostState: .parked), .nativeOnly)
        XCTAssertEqual(decide(hostState: .failed), .nativeOnly)
        XCTAssertEqual(decide(hostState: .absent,
                              leaseRemainingMs: EngineLaunchThresholds.minLeaseForColdBootMs), .boot)
        XCTAssertEqual(decide(hostState: .absent,
                              leaseRemainingMs: EngineLaunchThresholds.minLeaseForColdBootMs - 1), .nativeOnly)
        XCTAssertEqual(decide(hostState: .parked,
                              leaseRemainingMs: EngineLaunchThresholds.minLeaseForResumeMs), .resume)
        // A parked host uses the resume threshold even when it is below the
        // cold-boot threshold.
        XCTAssertEqual(decide(hostState: .parked,
                              leaseRemainingMs: EngineLaunchThresholds.minLeaseForResumeMs - 1), .nativeOnly)
    }

    func testFailedHostBootsWhenEligible() {
        XCTAssertEqual(decide(foreground: true, hostState: .failed), .boot)
        XCTAssertEqual(decide(hostState: .failed,
                              leaseRemainingMs: EngineLaunchThresholds.minLeaseForColdBootMs), .boot)
    }

    func testReasonNeverBranches() {
        // The reason chooses the lease source at the caller only (r1).
        for reason in WakeReason.allCases {
            XCTAssertEqual(decide(reason, foreground: true, hostState: .absent), .boot)
            XCTAssertEqual(decide(reason, hostState: .absent), .nativeOnly)
        }
    }

    func testFrozenConstants() {
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForColdBootMs, 20_000)
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForResumeMs, 8_000)
        XCTAssertEqual(EngineLaunchThresholds.parkMarginMs, 5_000)
        XCTAssertEqual(EngineLaunchThresholds.cloudPullFreshnessMs, 30_000)
        XCTAssertEqual(EngineLaunchThresholds.connectorScanIntervalMs, 1_800_000)
        XCTAssertEqual(EngineLaunchThresholds.minBackgroundDelayMs, 60_000)
    }

    func testProcessingFallbackOnlyForNativeOnly() {
        XCTAssertTrue(EngineLaunchPolicy.needsProcessingFallback(decision: .nativeOnly))
        XCTAssertFalse(EngineLaunchPolicy.needsProcessingFallback(decision: .boot))
        XCTAssertFalse(EngineLaunchPolicy.needsProcessingFallback(decision: .resume))
        XCTAssertFalse(EngineLaunchPolicy.needsProcessingFallback(decision: .ready))
        XCTAssertFalse(EngineLaunchPolicy.needsProcessingFallback(decision: .deferred))
    }
}

final class ReadySweepPolicyTests: XCTestCase {
    func testGateIsParkMarginPlusStepBudget() {
        for step in ReadySweepStep.allCases {
            let gate = EngineLaunchThresholds.parkMarginMs + ReadySweepPolicy.stepBudgetMs(for: step)
            XCTAssertTrue(ReadySweepPolicy.shouldRun(step, remainingMs: gate), "\(step)")
            XCTAssertFalse(ReadySweepPolicy.shouldRun(step, remainingMs: gate - 1), "\(step)")
        }
    }

    func testFrozenStepBudgets() {
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .userOutbox), 2_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .externalAdmission), 2_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .cloudTaskPull), 5_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .botHeldInbox), 2_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .missedRoutines), 5_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .connectorScan), 10_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .approvalReminderSync), 1_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .dshSchedule), 3_000)
        XCTAssertEqual(ReadySweepPolicy.stepBudgetMs(for: .hostRetries), 2_000)
    }

    func testStepsAreInTheContractOrder() {
        XCTAssertEqual(ReadySweepStep.allCases.map(\.ordinal), Array(1...9))
        XCTAssertEqual(ReadySweepStep.allCases.first, .userOutbox)
        XCTAssertEqual(ReadySweepStep.allCases.last, .hostRetries)
    }
}

final class WakeLeaseTests: XCTestCase {
    func testDeadlineMath() {
        let lease = WakeLease(reason: .cloudTaskPush, grantedAtMs: 1_000, deadlineMs: 31_000)
        XCTAssertEqual(lease.remainingMs(nowMs: 1_000), 30_000)
        XCTAssertEqual(lease.remainingMs(nowMs: 31_000), 0)
        XCTAssertEqual(lease.remainingMs(nowMs: 99_000), 0)
        XCTAssertFalse(lease.isExpired(nowMs: 30_999))
        XCTAssertTrue(lease.isExpired(nowMs: 31_000))
    }

    func testResidencyHasNoDeadline() {
        let lease = WakeLease.resident(.boardWake, nowMs: 5_000)
        XCTAssertEqual(lease.remainingMs(nowMs: 5_000), .max)
        XCTAssertEqual(lease.remainingMs(nowMs: .max / 2), .max)
        XCTAssertFalse(lease.isExpired(nowMs: .max / 2))
    }

    func testBackgroundTimeBuildsARealDeadline() {
        let lease = WakeLease.fromBackgroundTime(.cloudTaskPush, remainingMs: 29.5,
                                                 nowMs: 1_000)
        XCTAssertEqual(lease.deadlineMs, 30_500)
        let unbounded = WakeLease.fromBackgroundTime(.cloudTaskPush,
                                                     remainingMs: .infinity, nowMs: 1_000)
        XCTAssertEqual(unbounded.deadlineMs, .max)
    }
}
