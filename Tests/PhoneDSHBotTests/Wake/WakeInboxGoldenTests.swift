// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class WakeInboxGoldenTests: XCTestCase {
    func testSharedEnqueueStageCommitVector() async throws {
        let vector = try wp6Golden("held-inbox")
        let valid = try XCTUnwrap(vector["valid"] as? [String: Any])
        let enqueued = try XCTUnwrap(valid["enqueued"] as? [String: Any])
        let expectedItem = try JSONDecoder().decode(WakeInboxItem.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(enqueued["item"])))
        let root = try wp6TempDirectory(self)
        let inbox = try wp6Inbox(root: root)

        let inserted = try await inbox.enqueue(expectedItem)
        XCTAssertTrue(inserted.ok)
        XCTAssertFalse(inserted.duplicate)
        XCTAssertEqual(inserted.item, expectedItem)

        var duplicateInput = expectedItem
        duplicateInput.id = "held-duplicate"
        duplicateInput.text = "重复内容"
        let duplicate = try await inbox.enqueue(duplicateInput)
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(duplicate.item, expectedItem)

        let staged = try await inbox.stage(now: 1_760_000_002_000, key: "stage-1")
        let expectedStaged = try XCTUnwrap(valid["staged"] as? [String: Any])
        XCTAssertEqual(staged.key, expectedStaged["key"] as? String)
        let expectedItems = try XCTUnwrap(expectedStaged["items"] as? [[String: Any]])
        XCTAssertEqual(staged.items.count, expectedItems.count)
        for (actual, expected) in zip(staged.items, expectedItems) {
            XCTAssertEqual(actual, try JSONDecoder().decode(WakeInboxItem.self,
                from: JSONSerialization.data(withJSONObject: expected)))
        }
        try await WP6AssertEqual(try await inbox.commit(staged.key), 1)
        try await WP6AssertEqual(try await inbox.items(), [])
    }

    func testInvalidItemsAndAtLeastOnceRecovery() async throws {
        XCTAssertThrowsError(try WakeInboxItem(id: "", kind: "routine-result", text: "x", createdAt: 0))
        XCTAssertThrowsError(try WakeInboxItem(id: "held-2", kind: "routine-result", text: "x",
                                               createdAt: 0, state: .staged, stagedAt: 1, stagedKey: ""))
        let root = try wp6TempDirectory(self)
        let inbox = try wp6Inbox(root: root)
        let item = try WakeInboxItem(id: "held-1", kind: "routine-result", text: "result",
                                     requestId: "daily:1", createdAt: 1)
        _ = try await inbox.enqueue(item)
        let staged = try await inbox.stage(now: 2, key: "stage-1")
        let reopened = try wp6Inbox(root: root)
        try await WP6AssertEqual(try await reopened.recover(), 1)
        try await WP6AssertEqual(try await reopened.items().first?.state, .pending)
        let restaged = try await reopened.stage(now: 3, key: "stage-2")
        XCTAssertEqual(restaged.items.first?.id, staged.items.first?.id)
        try await WP6AssertEqual(try await reopened.revert(restaged.key), 1)
        try await WP6AssertEqual(try await reopened.items().count, 1)
        let final = try await reopened.stage(now: 4, key: "stage-3")
        try await WP6AssertEqual(try await reopened.commit(final.key), 1)
    }

    func testClosedStoreFailsClosed() async throws {
        let root = try wp6TempDirectory(self)
        let domainStore = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: domainStore, botId: "bot-a"))
        try await domainStore.close()
        let item = try WakeInboxItem(id: "held-1", kind: "routine-result", text: "x", createdAt: 1)
        await XCTAssertThrowsErrorAsync(try await inbox.enqueue(item))
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
