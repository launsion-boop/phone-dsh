// SPDX-License-Identifier: MIT

import CoreGraphics
import XCTest
@testable import PhoneDSHBot

/// Regression tests for the transcript container decisions behind
/// `BotChatPage`: eager mode renders a bounded suffix, and only a user-driven
/// scroll may stop tail following. The 2026-11-12 field samples were stuck in
/// `LazySubviewPlacements` with the keyboard open; the eager window and the
/// tail policy remove the estimate/scroll feedback while keeping the old lazy
/// container available for the tester's A/B run.
final class BotTranscriptLayoutSupportTests: XCTestCase {
    // MARK: - Eager window

    func testEagerWindowRendersTheNewestRowsAndReportsTheHiddenCount() {
        let rows = Array(0..<100)
        let window = BotTranscriptLayoutSupport.window(rows, limit: 40, eager: true)
        XCTAssertEqual(window.rows, Array(60..<100))
        XCTAssertEqual(window.rows.last, 99)
        XCTAssertEqual(window.hidden, 60)
    }

    func testEagerWindowKeepsEveryRowWhenItFits() {
        let rows = Array(0..<12)
        let window = BotTranscriptLayoutSupport.window(rows, limit: 40, eager: true)
        XCTAssertEqual(window.rows, rows)
        XCTAssertEqual(window.hidden, 0)
        XCTAssertEqual(window.rows.count, rows.count)
    }

    func testLazyModeKeepsTheFullLoadedList() {
        let rows = Array(0..<100)
        let window = BotTranscriptLayoutSupport.window(rows, limit: 40, eager: false)
        XCTAssertEqual(window.rows, rows)
        XCTAssertEqual(window.hidden, 0)
    }

    func testEagerWindowNeverDropsTheNewestRow() {
        let rows = Array(0..<4)
        let window = BotTranscriptLayoutSupport.window(rows, limit: 0, eager: true)
        XCTAssertEqual(window.rows, [3])
        XCTAssertEqual(window.hidden, 3)
    }

    // MARK: - Tail following

    func testNearTailAcceptsTheViewportBottomAndJustAboveIt() {
        XCTAssertTrue(BotTranscriptLayoutSupport.isNearTail(
            tailY: 844, viewportHeight: 844))
        XCTAssertTrue(BotTranscriptLayoutSupport.isNearTail(
            tailY: 0, viewportHeight: 844))
        XCTAssertTrue(BotTranscriptLayoutSupport.isNearTail(
            tailY: 844 + 60, viewportHeight: 844))
        XCTAssertTrue(BotTranscriptLayoutSupport.isNearTail(
            tailY: -0.4, viewportHeight: 844))
    }

    func testNearTailRejectsAFarScrollAndUnmeasuredMetrics() {
        XCTAssertFalse(BotTranscriptLayoutSupport.isNearTail(
            tailY: 844 + 61, viewportHeight: 844))
        XCTAssertFalse(BotTranscriptLayoutSupport.isNearTail(
            tailY: .greatestFiniteMagnitude, viewportHeight: 844))
        XCTAssertFalse(BotTranscriptLayoutSupport.isNearTail(
            tailY: 400, viewportHeight: 0))
    }

    func testKeyboardOrComposerResizeAloneCannotStopFollowing() {
        // Even a tail that is now far below a shorter viewport must not turn
        // following off: the resize path is not user-driven.
        XCTAssertNil(BotTranscriptLayoutSupport.updatedFollowsTail(
            current: true, userDriven: false,
            tailY: 1_200, viewportHeight: 400))
        XCTAssertNil(BotTranscriptLayoutSupport.updatedFollowsTail(
            current: true, userDriven: false,
            tailY: 100, viewportHeight: 400))
    }

    func testUserScrollAwayStopsFollowingAndBackResumesIt() {
        let away = BotTranscriptLayoutSupport.updatedFollowsTail(
            current: true, userDriven: true,
            tailY: 1_600, viewportHeight: 700)
        XCTAssertEqual(away, false)
        let back = BotTranscriptLayoutSupport.updatedFollowsTail(
            current: false, userDriven: true,
            tailY: 690, viewportHeight: 700)
        XCTAssertEqual(back, true)
    }

    func testUserScrollWithUnknownMetricsKeepsTheCurrentFlag() {
        XCTAssertNil(BotTranscriptLayoutSupport.updatedFollowsTail(
            current: true, userDriven: true,
            tailY: .greatestFiniteMagnitude, viewportHeight: 700))
        XCTAssertNil(BotTranscriptLayoutSupport.updatedFollowsTail(
            current: false, userDriven: true,
            tailY: 400, viewportHeight: 0))
    }
}
