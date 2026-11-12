// SPDX-License-Identifier: MIT
// The drawer's 新会话 reason policy: a transient session switch keeps the
// capsule disabled but must not insert the reason line.

import XCTest

final class HomeDrawerNewSessionPolicyTests: XCTestCase {
    func testTransientSwitchDoesNotShowAReasonButStaysDisabled() {
        XCTAssertNil(HomeDrawerNewSessionPolicy.reason(
            isStarted: true, turnRunning: false, keepingAlive: false))
        XCTAssertTrue(HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: true, busy: true, turnRunning: false, keepingAlive: false))
    }

    func testRunningTurnShowsTheTurnReason() {
        XCTAssertEqual(HomeDrawerNewSessionPolicy.reason(
            isStarted: true, turnRunning: true, keepingAlive: false), .turnRunning)
        XCTAssertTrue(HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: true, busy: false, turnRunning: true, keepingAlive: false))
    }

    func testBackgroundKeepAliveShowsTheTurnReason() {
        XCTAssertEqual(HomeDrawerNewSessionPolicy.reason(
            isStarted: true, turnRunning: false, keepingAlive: true), .turnRunning)
    }

    func testStartingEngineDoesNotClaimItIsStopped() {
        XCTAssertNil(HomeDrawerNewSessionPolicy.reason(
            isStarted: false, turnRunning: false, keepingAlive: false,
            engineStarting: true))
        // It stays disabled for the short boot, but without moving the reason
        // line away from the list.
        XCTAssertTrue(HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: false, busy: true, turnRunning: false, keepingAlive: false))
    }

    func testStoppedEngineStillShowsItsOwnReason() {
        XCTAssertEqual(HomeDrawerNewSessionPolicy.reason(
            isStarted: false, turnRunning: false, keepingAlive: false), .engineNotStarted)
        XCTAssertTrue(HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: false, busy: false, turnRunning: false, keepingAlive: false))
    }

    func testAvailableCapsuleIsEnabled() {
        XCTAssertNil(HomeDrawerNewSessionPolicy.reason(
            isStarted: true, turnRunning: false, keepingAlive: false))
        XCTAssertFalse(HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: true, busy: false, turnRunning: false, keepingAlive: false))
    }
}
