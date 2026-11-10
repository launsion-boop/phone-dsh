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
}
