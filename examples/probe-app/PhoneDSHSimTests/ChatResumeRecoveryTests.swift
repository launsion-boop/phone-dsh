// SPDX-License-Identifier: MIT
// phone-dsh — App-side resume recovery policy tests.
//
// The host tests own the D14 state machine and the resume budgets. These tests
// cover the App's decision table: rebuild once after a failed resume, then show
// the manual button; queue a session switch or a prompt during recovery instead
// of refusing it; and log only the visibility enum.

import XCTest
import ProbeKit

final class ChatResumeRecoveryTests: XCTestCase {
    func testResumeFailureRebuildsExactlyOnceThenOffersManualRestart() {
        XCTAssertEqual(ChatResumeRecovery.maximumAutomaticRebuilds, 1)
        XCTAssertEqual(
            ChatResumeRecovery.decision(afterResumeFailure: 0), .rebuildEngine)
        XCTAssertEqual(
            ChatResumeRecovery.decision(afterResumeFailure: 1), .offerManualRestart)
        XCTAssertEqual(
            ChatResumeRecovery.decision(afterResumeFailure: 2), .offerManualRestart)
    }

    func testTheOneRebuildCannotRunTwiceInTheSameForegroundReturn() {
        var rebuilds = 0
        var decision = ChatResumeRecovery.decision(afterResumeFailure: rebuilds)
        if decision == .rebuildEngine { rebuilds += 1 }
        decision = ChatResumeRecovery.decision(afterResumeFailure: rebuilds)
        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(decision, .offerManualRestart)
    }

    func testRecoveryBannerShowsNormalThenSlowText() {
        XCTAssertNil(ChatResumeRecovery.bannerText(
            parked: false, hostLifecycleTransition: false,
            rebuilding: false, slow: false))
        XCTAssertEqual(ChatResumeRecovery.bannerText(
            parked: true, hostLifecycleTransition: false,
            rebuilding: false, slow: false), "引擎恢复中…")
        XCTAssertEqual(ChatResumeRecovery.bannerText(
            parked: false, hostLifecycleTransition: true,
            rebuilding: false, slow: false), "引擎恢复中…")
        XCTAssertEqual(ChatResumeRecovery.bannerText(
            parked: true, hostLifecycleTransition: false,
            rebuilding: false, slow: true), "恢复较慢，正在重新启动引擎…")
        XCTAssertEqual(ChatResumeRecovery.bannerText(
            parked: true, hostLifecycleTransition: false,
            rebuilding: true, slow: false), "恢复较慢，正在重新启动引擎…")
    }

    func testSessionSwitchWaitsDuringEveryRecoveryPhase() {
        let phases: [(Bool, Bool, Bool)] = [
            (true, false, false),   // parked
            (false, true, false),   // park/resume transition
            (false, false, true),   // automatic full rebuild
            (true, true, true),
        ]
        for (parked, transition, rebuilding) in phases {
            XCTAssertEqual(
                ChatResumeRecovery.sessionSwitchGate(
                    parked: parked, hostLifecycleTransition: transition,
                    rebuilding: rebuilding, hostAvailable: true,
                    backoffScheduled: false),
                .waitForRecovery,
                "the already-painted optimistic target waits instead of queueing twice")
            XCTAssertTrue(ChatResumeRecovery.shouldQueuePrompt(
                parked: parked, hostLifecycleTransition: transition,
                rebuilding: rebuilding))
        }
        XCTAssertEqual(
            ChatResumeRecovery.sessionSwitchGate(
                parked: false, hostLifecycleTransition: false,
                rebuilding: false, hostAvailable: true, backoffScheduled: false),
            .runNow)
        XCTAssertFalse(ChatResumeRecovery.shouldQueuePrompt(
            parked: false, hostLifecycleTransition: false, rebuilding: false))
    }

    func testAScheduledBackoffKeepsTheWorkerWaitingUntilTheEngineIsBack() {
        XCTAssertEqual(
            ChatResumeRecovery.sessionSwitchGate(
                parked: false, hostLifecycleTransition: false,
                rebuilding: false, hostAvailable: false, backoffScheduled: true),
            .waitForRecovery,
            "a D24 boot that is already scheduled must not turn the tap into an error")
        XCTAssertEqual(
            ChatResumeRecovery.sessionSwitchGate(
                parked: false, hostLifecycleTransition: false,
                rebuilding: false, hostAvailable: false, backoffScheduled: false),
            .engineUnavailable,
            "after the recovery budgets fail the normal start/restart path decides")
    }

    func testVisibilityWarningsLogOnlyTheEnumToken() {
        XCTAssertEqual(ChatResumeRecovery.visibilityToken(
            fromConsoleText: "webview-visibility=not_attached; the WKWebView is not attached"),
            "not_attached")
        XCTAssertEqual(ChatResumeRecovery.visibilityToken(
            fromConsoleText: "webview-visibility=not_occlusion_visible; hidden page"),
            "not_occlusion_visible")
        XCTAssertEqual(ChatResumeRecovery.visibilityToken(
            fromConsoleText: "webview-visibility=not_visible_timeout; continued"),
            "not_visible_timeout")
        XCTAssertNil(ChatResumeRecovery.visibilityToken(
            fromConsoleText: "some ordinary page console line"))
        XCTAssertEqual(ChatResumeRecovery.queuedSessionHint, "恢复完成后自动切换")
        XCTAssertEqual(ChatResumeRecovery.queuedPromptHint, "恢复完成后自动发送")
        XCTAssertEqual(
            ChatResumeRecovery.recoveryTip(message: "引擎恢复中…",
                                           hint: "恢复完成后自动切换"),
            "引擎恢复中… · 恢复完成后自动切换",
            "the tips pill is one line, never a second banner row")
    }
}
