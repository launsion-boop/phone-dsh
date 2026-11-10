// SPDX-License-Identifier: MIT
// A switch keeps whatever the old page was already drawing — transcript rows
// or an empty-state card — and only a truly blank page gets a same-height
// placeholder. The loading pill waits 300 ms from the switch's real start (not
// the tap), so the drawer close and a fast open never flash it.

import XCTest

final class SessionSwitchPresentationPolicyTests: XCTestCase {
    func testOldTranscriptRowsAreKeptDuringSwitch() {
        XCTAssertEqual(
            SessionSwitchPresentationPolicy.backdrop(for: .transcriptRows),
            .keepOldContent)
    }

    func testOldEmptyStateCardIsKeptDuringSwitch() {
        XCTAssertEqual(
            SessionSwitchPresentationPolicy.backdrop(for: .emptyStateCard),
            .keepOldContent,
            "engine / provider / new-session cards are old-page content, not a blank frame")
    }

    func testOnlyACompletelyBlankPageGetsTheHeightPlaceholder() {
        XCTAssertEqual(
            SessionSwitchPresentationPolicy.backdrop(for: .blank),
            .placeholder)
    }

    func testIndicatorAppearsOnlyAtTheThreeHundredMillisecondThreshold() {
        XCTAssertEqual(SessionSwitchPresentationPolicy.indicatorDelay, .milliseconds(300))
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: .zero))
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: .milliseconds(299)))
        XCTAssertTrue(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: .milliseconds(300)))
        XCTAssertTrue(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: .milliseconds(900)))
    }

    func testIndicatorTimerStartsAtTheSwitchNotAtTheTapOrDrawerClose() {
        // The phone drawer owns the first 0.22s. At 300ms after the tap the
        // worker has only run 80ms, so this must still be below the delay.
        let afterTap = Duration.milliseconds(300)
        let close = Duration.milliseconds(
            Int((HomeDrawerSwitchPolicy.closeDuration * 1_000).rounded()))
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: afterTap - close),
            "counting from the tap would show the pill 80ms into the real work")
        XCTAssertTrue(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: afterTap),
            "300ms after the worker starts, not after the tap")
    }

    func testNoIndicatorWhileTheDrawerIsStillClosing() {
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: true, elapsedSinceWorkStarted: nil),
            "the worker has not started yet, so its 300ms timer has not started")
    }

    func testAFinishedSwitchNeverShowsTheIndicator() {
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: false, elapsedSinceWorkStarted: .milliseconds(299)),
            "a switch that lands inside the delay shows no pill at all")
        XCTAssertFalse(SessionSwitchPresentationPolicy.showsIndicator(
            isSwitching: false, elapsedSinceWorkStarted: .milliseconds(900)),
            "the overlay must be gone once the new history has landed")
    }
}
