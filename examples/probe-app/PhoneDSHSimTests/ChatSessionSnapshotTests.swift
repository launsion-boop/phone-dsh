// SPDX-License-Identifier: MIT
// Cached session list/title snapshot shown before the engine is reachable.

import Foundation
import ProbeKit
import XCTest

final class ChatSessionSnapshotTests: XCTestCase {
    func testRoundTripsTheLastSuccessfulSessionList() throws {
        let snapshot = ChatSessionSnapshot(
            sessions: [
                .init(id: "s1", title: "修复恢复白屏", updatedAtMilliseconds: 1_760_000_000_000,
                      running: false, blank: false, cwd: "/dsh/workspace"),
                .init(id: "s2", title: "新会话", updatedAtMilliseconds: 1_760_000_100_000,
                      running: true, blank: true),
            ],
            workspaces: [.init(id: "w1", title: "Workspace", path: "/dsh/workspace",
                               sessionIDs: ["s1", "s2"])],
            workspaceOrder: ["w1"],
            pinnedSessionIDs: ["s1"],
            archivedIDs: ["s2"])
        let data = try XCTUnwrap(snapshot.encoded())
        XCTAssertEqual(ChatSessionSnapshot.decode(data), snapshot)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testCorruptOrEmptySnapshotLeavesTheLiveListAlone() throws {
        XCTAssertNil(ChatSessionSnapshot.decode(Data("not json".utf8)))
        let empty = ChatSessionSnapshot()
        XCTAssertTrue(empty.isEmpty)
        let decoded = try XCTUnwrap(empty.encoded().flatMap(ChatSessionSnapshot.decode))
        XCTAssertTrue(decoded.isEmpty)
    }
}

final class ChatTranscriptTailPolicyTests: XCTestCase {
    func testShorterTranscriptNeverScrollsIntoABlankBand() {
        XCTAssertFalse(ChatTranscriptTailPolicy.shouldScrollToTail(
            contentHeight: 200, viewportHeight: 600, hasRows: true))
        XCTAssertFalse(ChatTranscriptTailPolicy.shouldSettleAfterInitial(
            contentHeight: 0, viewportHeight: 600, hasRows: true),
            "before the first measurement there is no safe target")
    }

    func testTheAwayPillNeedsMoreThanTheNearFollowingBand() {
        // 44pt is the near-following tolerance; 96pt is the deliberate-away
        // margin so a touch plus streamed growth cannot flip the pill.
        XCTAssertFalse(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 640, viewportHeight: 600))
        XCTAssertFalse(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 696, viewportHeight: 600))
        XCTAssertTrue(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 697, viewportHeight: 600))
        XCTAssertFalse(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 640, viewportHeight: 600, margin: 44))
        XCTAssertTrue(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 645, viewportHeight: 600, margin: 44),
            "the caller may pass the old near tolerance explicitly")
        XCTAssertTrue(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 645, viewportHeight: 600, margin: 24))
        XCTAssertFalse(ChatTranscriptTailPolicy.isAwayFromTail(
            tailY: 600, viewportHeight: 0))
    }

    func testOverflowingTranscriptAnchorsToTheMeasuredTail() {
        XCTAssertTrue(ChatTranscriptTailPolicy.shouldScrollToTail(
            contentHeight: 900, viewportHeight: 600, hasRows: true))
        XCTAssertTrue(ChatTranscriptTailPolicy.shouldSettleAfterInitial(
            contentHeight: 900, viewportHeight: 600, hasRows: true))
    }

    func testEmptyTimelineDoesNotScroll() {
        XCTAssertFalse(ChatTranscriptTailPolicy.shouldScrollToTail(
            contentHeight: 900, viewportHeight: 600, hasRows: false))
    }

    func testShortTranscriptAtTheTopIsVisible() {
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 200, contentOffsetY: 0, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 200, contentOffsetY: 0, viewportHeight: 600, hasRows: true), .none)
    }

    func testShortTranscriptPushedAwayFromItsTopIsBlankAndReturnsToTop() {
        XCTAssertTrue(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 200, contentOffsetY: 12, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 200, contentOffsetY: 12, viewportHeight: 600, hasRows: true),
            .scrollToTop)
    }

    func testLongTranscriptAtItsRealBottomIsVisible() {
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_200, contentOffsetY: 600, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 1_200, contentOffsetY: 600, viewportHeight: 600, hasRows: true),
            .none)
    }

    func testOffsetPastEstimatedContentIsBlankAndReturnsToLastRow() {
        XCTAssertTrue(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_200, contentOffsetY: 1_201, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 1_200, contentOffsetY: 1_201, viewportHeight: 600, hasRows: true),
            .scrollToLastRow)
        XCTAssertTrue(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_200, contentOffsetY: 1_800, viewportHeight: 600, hasRows: true))
    }

    func testNegativeOffsetIsTopOverscrollNotABlankViewport() {
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_200, contentOffsetY: -40, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 1_200, contentOffsetY: -40, viewportHeight: 600, hasRows: true),
            .none)
    }

    func testTopInsetIsRemovedBeforeJudgingVisibility() {
        // At the top the raw offset is -topInset; it normalizes to content 0.
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 900, contentOffsetY: -59, viewportHeight: 600,
            contentInsetTop: 59, contentInsetBottom: 34, hasRows: true))
    }

    func testKeyboardInsetsShrinkTheUsableViewport() {
        // 600 − 100 top − 300 bottom = 200 usable points. The normalized
        // bottom offset is 900 − 200 = 700 (raw 600 after the top inset).
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 900, contentOffsetY: 600, viewportHeight: 600,
            contentInsetTop: 100, contentInsetBottom: 300, hasRows: true))
        // Raw 840 normalizes to 940, past the 900-point content bottom.
        XCTAssertTrue(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 900, contentOffsetY: 840, viewportHeight: 600,
            contentInsetTop: 100, contentInsetBottom: 300, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 900, contentOffsetY: 840, viewportHeight: 600,
            contentInsetTop: 100, contentInsetBottom: 300, hasRows: true),
            .scrollToLastRow)
    }

    func testNoRowsOrUnmeasuredGeometryNeverCorrects() {
        for (height, viewport, rows) in [(CGFloat(1_200), CGFloat(600), false),
                                         (CGFloat(0), CGFloat(600), true),
                                         (CGFloat(1_200), CGFloat(0), true)] {
            XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
                contentHeight: height, contentOffsetY: 2_000, viewportHeight: viewport,
                hasRows: rows))
            XCTAssertEqual(ChatTranscriptTailPolicy.correction(
                contentHeight: height, contentOffsetY: 2_000, viewportHeight: viewport,
                hasRows: rows), .none)
        }
    }

    func testNonFiniteGeometryNeverCorrects() {
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: .nan, contentOffsetY: 2_000, viewportHeight: 600, hasRows: true))
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_200, contentOffsetY: .infinity, viewportHeight: 600, hasRows: true))
        XCTAssertEqual(ChatTranscriptTailPolicy.correction(
            contentHeight: 1_200, contentOffsetY: .infinity, viewportHeight: 600, hasRows: true),
            .none)
    }

    func testToleranceKeepsTheLastPointOfContentVisible() {
        XCTAssertFalse(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_000, contentOffsetY: 999, viewportHeight: 600, hasRows: true))
        XCTAssertTrue(ChatTranscriptTailPolicy.viewportIsBlank(
            contentHeight: 1_000, contentOffsetY: 999.5, viewportHeight: 600, hasRows: true))
    }
}
