// SPDX-License-Identifier: MIT
// W1-B: engine lifecycle, session switch and send are three independent
// states. A starting engine must not block browsing, and a running turn must
// not be interrupted to activate another session.

import XCTest
import ProbeKit

final class ChatStatePolicyTests: XCTestCase {
    func testEnginePhaseIsIndependentOfSwitchAndSend() {
        XCTAssertEqual(ChatStatePolicy.enginePhase(
            hostPresent: false, startInProgress: true,
            needsReset: false, failed: false, parked: false), .starting)
        XCTAssertEqual(ChatStatePolicy.enginePhase(
            hostPresent: true, startInProgress: false,
            needsReset: false, failed: false, parked: false), .running)
        XCTAssertEqual(ChatStatePolicy.enginePhase(
            hostPresent: false, startInProgress: false,
            needsReset: false, failed: false, parked: false), .stopped)
        XCTAssertEqual(ChatStatePolicy.enginePhase(
            hostPresent: true, startInProgress: false,
            needsReset: true, failed: false, parked: false), .failed)

        let starting = ChatStateSnapshot(engine: .starting,
                                         sessionSwitch: .idle, send: .sending)
        XCTAssertEqual(starting.engine, .starting)
        XCTAssertEqual(starting.send, .sending)
    }

    func testBrowsingIsAllowedInEveryPhase() {
        for phase in [ChatEnginePhase.stopped, .starting, .running, .failed] {
            XCTAssertTrue(ChatStatePolicy.canBrowse(phase))
        }
    }

    func testActivationNeedsRunningAndNoSwitch() {
        XCTAssertTrue(ChatStatePolicy.canActivateSession(
            phase: .running, switchPhase: .idle, hostTransition: false))
        XCTAssertFalse(ChatStatePolicy.canActivateSession(
            phase: .starting, switchPhase: .idle, hostTransition: false))
        XCTAssertFalse(ChatStatePolicy.canActivateSession(
            phase: .running, switchPhase: .switching, hostTransition: false))
        XCTAssertFalse(ChatStatePolicy.canActivateSession(
            phase: .running, switchPhase: .idle, hostTransition: true))
    }

    func testSendIsAlwaysAccepted() {
        for phase in [ChatEnginePhase.stopped, .starting, .running, .failed] {
            XCTAssertTrue(ChatStatePolicy.canAcceptSend(phase))
        }
    }

    func testTurnIsNeverInterruptedForActivation() {
        XCTAssertFalse(ChatStatePolicy.mayActivateDuringTurn(true))
        XCTAssertTrue(ChatStatePolicy.mayActivateDuringTurn(false))
    }
}
