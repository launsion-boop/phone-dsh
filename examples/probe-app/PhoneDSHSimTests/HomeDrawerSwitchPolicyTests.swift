// SPDX-License-Identifier: MIT
// The drawer's optimistic session switch: a tap paints the target selection and
// title at once, the actual open waits for the drawerClosed event (the wide
// sidebar only needs one runloop), a failure rolls back to the old session, and
// only the last tap may touch the page.

import ProbeKit
import XCTest

final class HomeDrawerSwitchPolicyTests: XCTestCase {
    private let open = HomeDrawerSwitchPolicy.Session(id: "session-a", title: "会话甲")
    private let other = HomeDrawerSwitchPolicy.Session(id: "session-b", title: "会话乙")
    private let third = HomeDrawerSwitchPolicy.Session(id: "session-c", title: "会话丙")

    func testThePhoneDrawerClosesButThePersistentSidebarDoesNot() {
        XCTAssertTrue(HomeDrawerSwitchPolicy.closesDrawer(isPersistent: false))
        XCTAssertFalse(HomeDrawerSwitchPolicy.closesDrawer(isPersistent: true))
    }

    func testTapPaintsTheSelectionAndTitleBeforeTheSwitchStarts() {
        let tap = HomeDrawerSwitchPolicy.tap(
            other, currentSessionID: open.id, pending: nil)
        XCTAssertEqual(tap, .beginSwitch(other))
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.displayed(current: open, pending: .init(target: other, generation: 7)),
            other,
            "the target title/row must be drawn before the engine opens it")
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.displayed(current: open, pending: nil),
            open,
            "without a pending switch the open session is still the display source")
    }

    func testPhoneSwitchWaitsForTheDrawerClosedEvent() {
        let gate = HomeDrawerSwitchPolicy.startGate(isPersistent: false)
        XCTAssertEqual(gate, .afterDrawerClosed)
        XCTAssertFalse(
            HomeDrawerSwitchPolicy.startsSwitch(gate, on: .runloopYielded),
            "starting in the tap frame is what swallows the 0.22s close animation")
        XCTAssertTrue(HomeDrawerSwitchPolicy.startsSwitch(gate, on: .drawerClosed))
        XCTAssertEqual(HomeDrawerSwitchPolicy.closeDuration, 0.22)
    }

    func testPersistentSidebarStartsOnTheNextRunloopWithoutClosing() {
        let gate = HomeDrawerSwitchPolicy.startGate(isPersistent: true)
        XCTAssertEqual(gate, .nextRunloop)
        XCTAssertFalse(HomeDrawerSwitchPolicy.closesDrawer(isPersistent: true))
        XCTAssertTrue(
            HomeDrawerSwitchPolicy.startsSwitch(gate, on: .runloopYielded),
            "the wide sidebar never closes, so it must not wait for drawerClosed")
    }

    func testTapOnTheOpenSessionOnlyCloses() {
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.tap(open, currentSessionID: open.id, pending: nil),
            .close)
    }

    func testRepeatedTapOnThePendingTargetDoesNotStartASecondSwitch() {
        let pending = HomeDrawerSwitchPolicy.Pending(target: other, generation: 1)
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.tap(other, currentSessionID: open.id, pending: pending),
            .close,
            "the latest intent is already this target; no concurrent duplicate switch")
    }

    func testANewerTapSupersedesTheInFlightOne() {
        let first = HomeDrawerSwitchPolicy.Pending(target: other, generation: 1)
        let tap = HomeDrawerSwitchPolicy.tap(
            third, currentSessionID: open.id, pending: first)
        guard case .beginSwitch(let target) = tap else {
            return XCTFail("a different row starts the newer switch")
        }
        XCTAssertEqual(target, third)
        let second = HomeDrawerSwitchPolicy.Pending(target: target, generation: 2)
        XCTAssertFalse(HomeDrawerSwitchPolicy.isLatest(1, latest: second.generation))
        XCTAssertTrue(HomeDrawerSwitchPolicy.isLatest(2, latest: second.generation))
        XCTAssertNil(
            HomeDrawerSwitchPolicy.committed(first, generation: 1, latest: second.generation),
            "the first switch must not land after the second tap")
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.committed(second, generation: 2, latest: second.generation),
            third)
    }

    func testFailureRollsBackToTheOldSessionAndTitle() {
        let pending = HomeDrawerSwitchPolicy.Pending(target: other, generation: 2)
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.rolledBack(current: open, pending: pending, generation: 2, latest: 2),
            open)
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.displayed(
                current: HomeDrawerSwitchPolicy.rolledBack(current: open, pending: pending, generation: 2, latest: 2),
                pending: nil),
            open,
            "clearing the pending target restores the previous row and header title")
        XCTAssertNil(
            HomeDrawerSwitchPolicy.rolledBack(current: open, pending: pending, generation: 1, latest: 2),
            "a stale failure cannot roll back the newer tap")
    }

    func testFailureAfterANewerTapIsIgnored() {
        let stale = HomeDrawerSwitchPolicy.Pending(target: other, generation: 1)
        let latest = HomeDrawerSwitchPolicy.Pending(target: third, generation: 2)
        XCTAssertNil(HomeDrawerSwitchPolicy.committed(stale, generation: 1, latest: latest.generation))
        XCTAssertNil(HomeDrawerSwitchPolicy.rolledBack(current: open, pending: stale, generation: 1,
                                                       latest: latest.generation))
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.displayed(current: open, pending: latest),
            third,
            "the newer tap stays selected while the stale completion is discarded")
    }

    func testTheOptimisticTargetStaysVisibleWhileTheRecoveryWorkerWaits() {
        let pending = HomeDrawerSwitchPolicy.Pending(target: other, generation: 4)
        XCTAssertEqual(
            HomeDrawerSwitchPolicy.displayed(current: open, pending: pending),
            other,
            "the tap frame paints the target before the worker starts")
        XCTAssertEqual(
            ChatResumeRecovery.sessionSwitchGate(
                parked: true, hostLifecycleTransition: false,
                rebuilding: false, hostAvailable: true, backoffScheduled: false),
            .waitForRecovery,
            "the worker waits instead of opening a second pending switch")
        XCTAssertEqual(
            ChatResumeRecovery.sessionSwitchGate(
                parked: false, hostLifecycleTransition: false,
                rebuilding: false, hostAvailable: true, backoffScheduled: false),
            .runNow,
            "after the lifecycle settles the same pending target runs exactly once")
        XCTAssertFalse(
            HomeDrawerSwitchPolicy.isLatest(3, latest: pending.generation),
            "a newer tap supersedes the waiting worker")
    }
}
