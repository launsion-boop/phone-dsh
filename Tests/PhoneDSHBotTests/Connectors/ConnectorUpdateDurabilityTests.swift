// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// `connector-update` durability: write-before-enqueue, replay with the cursor
/// interval as the dedupe key, and the frozen item semantics enforced by the
/// real `WakeInboxItem` codec.
final class ConnectorUpdateDurabilityTests: XCTestCase {
    func testEnqueueWritesRecordItemAndAcknowledgement() async throws {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = try wp6Inbox(root: root)
        let outbox = ConnectorUpdateOutbox(domain: store, now: { 2_000 })
        let update = try Self.gmailUpdate()

        let result = try await outbox.enqueue(update, botID: "bot-a", in: inbox)

        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.duplicate)
        let items = try await inbox.items()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, "connector-update")
        XCTAssertEqual(item.connector, "gmail")
        XCTAssertEqual(item.cursorFrom, "100")
        XCTAssertEqual(item.cursorTo, "200")
        XCTAssertEqual(item.count, 2)
        XCTAssertEqual(item.items?.map(\.id), ["m1", "m2"])
        XCTAssertEqual(item.requestId, "gmail:100:200")
        XCTAssertEqual(item.state, .pending)

        let events = try await store.events(after: 0, limit: 100)
        let record = try XCTUnwrap(events.first {
            $0.eventId == ConnectorUpdateOutbox.recordEventID(for: update)
        })
        let ack = try XCTUnwrap(events.first {
            $0.eventId == ConnectorUpdateOutbox.acknowledgementEventID(for: update)
        })
        XCTAssertEqual(record.type, ConnectorUpdateOutbox.recordEventType)
        XCTAssertEqual(record.data["connectorUpdate"]?["connector"]?.stringValue, "gmail")
        XCTAssertEqual(record.data["connectorUpdate"]?["cursorFrom"]?.stringValue, "100")
        XCTAssertEqual(ack.type, ConnectorUpdateOutbox.acknowledgementEventType)
        XCTAssertEqual(ack.causationId, record.eventId)
        await XCTAssertTrueAsync(await outbox.pendingEventIDs(botID: "bot-a").isEmpty)
    }

    func testTheSameIntervalIsAtMostOneItem() async throws {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = try wp6Inbox(root: root)
        let outbox = ConnectorUpdateOutbox(domain: store, now: { 2_000 })
        let update = try Self.gmailUpdate()

        _ = try await outbox.enqueue(update, botID: "bot-a", in: inbox)
        let second = try await outbox.enqueue(update, botID: "bot-a", in: inbox)

        XCTAssertTrue(second.duplicate)
        try await WP6AssertEqual(try await inbox.items().count, 1)
        let events = try await store.events(after: 0, limit: 100)
        let recordEvents = events.filter {
            $0.eventId == ConnectorUpdateOutbox.recordEventID(for: update)
        }
        XCTAssertEqual(recordEvents.count, 1)
    }

    func testCrashBetweenRecordAndEnqueueIsReplayedOnLaunch() async throws {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = try wp6Inbox(root: root)
        let update = try Self.githubUpdate()
        // First process wrote the durable record, then died before enqueueing.
        let first = ConnectorUpdateOutbox(domain: store, now: { 1_000 })
        try await first.record(update, botID: "bot-a")
        try await XCTAssertTrueAsync(try await inbox.items().isEmpty)

        let second = ConnectorUpdateOutbox(domain: store, now: { 2_000 })
        let replayed = try await second.redeliver(botID: "bot-a", in: inbox)

        XCTAssertEqual(replayed, 1)
        let replayedItems = try await inbox.items()
        let item = try XCTUnwrap(replayedItems.first)
        XCTAssertEqual(item.connector, "github")
        XCTAssertEqual(item.items?.first?.repo, "octo/repo")
        await XCTAssertTrueAsync(await second.pendingEventIDs(botID: "bot-a").isEmpty)
        // A second replay after the acknowledgement does not resurrect it.
        try await WP6AssertEqual(try await second.redeliver(botID: "bot-a", in: inbox), 0)
        try await WP6AssertEqual(try await inbox.items().count, 1)
    }

    func testConsumedItemIsNotResurrectedByReplay() async throws {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = try wp6Inbox(root: root)
        let update = try Self.gmailUpdate()
        let outbox = ConnectorUpdateOutbox(domain: store, now: { 2_000 })
        _ = try await outbox.enqueue(update, botID: "bot-a", in: inbox)
        let staged = try await inbox.stage(now: 3_000, key: "turn-1")
        XCTAssertEqual(staged.items.count, 1)
        try await inbox.commit(staged.key)

        let reopened = ConnectorUpdateOutbox(domain: store, now: { 4_000 })
        try await WP6AssertEqual(try await reopened.redeliver(botID: "bot-a", in: inbox), 0)
        try await XCTAssertTrueAsync(try await inbox.items().isEmpty)
    }

    func testConnectorUpdateItemValidationIsFailClosed() throws {
        let items = [
            ConnectorMetadataItem(id: "m1", at: 1, from: "a", subject: "s"),
            ConnectorMetadataItem(id: "m2", at: 2, from: "b", subject: "t"),
        ]
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "x",
            requestId: "gmail:1:2", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "2", count: 3, items: items))
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:1", kind: "connector-update", text: "x",
            requestId: "gmail:1:1", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "1", count: 2, items: items))
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "x",
            requestId: "gmail:1:2", createdAt: 0, connector: "unknown",
            cursorFrom: "1", cursorTo: "2", count: 2, items: items))
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "x",
            requestId: "gmail:1:3", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "2", count: 2, items: items))
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "x",
            requestId: "gmail:1:2", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "2", count: 2, items: [items[0], items[0]]))
        XCTAssertThrowsError(try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "x",
            requestId: "gmail:1:2", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "2", count: 1, items: items))

        let valid = try WakeInboxItem(
            id: "connector-update:gmail:1:2", kind: "connector-update", text: "gmail: 2 new messages",
            requestId: "gmail:1:2", createdAt: 0, connector: "gmail",
            cursorFrom: "1", cursorTo: "2", count: 2, items: items)
        XCTAssertEqual(valid.count, 2)
    }

    func testOlderItemsStillDecodeWithoutConnectorMembers() throws {
        let json = #"""
            {"id":"held-1","kind":"routine-result","text":"done","requestId":"r:1",
             "createdAt":1000,"state":"pending"}
            """#
        let item = try JSONDecoder().decode(WakeInboxItem.self, from: Data(json.utf8))
        XCTAssertNil(item.connector)
        XCTAssertNil(item.items)
    }

    // MARK: - Fixtures

    static func gmailUpdate() throws -> ConnectorUpdateRecord {
        try ConnectorUpdateRecord(
            connector: .gmail, cursorFrom: "100", cursorTo: "200",
            items: [
                .init(id: "m1", at: 10, from: "QA <qa@example.com>", subject: "One"),
                .init(id: "m2", at: 20, from: "Ops <ops@example.com>", subject: "Two"),
            ],
            createdAt: 1_000)
    }

    static func githubUpdate() throws -> ConnectorUpdateRecord {
        try ConnectorUpdateRecord(
            connector: .github, cursorFrom: "2026-11-20T00:00:00Z",
            cursorTo: "2026-11-20T01:00:00Z",
            items: [.init(id: "n1", at: 10, repo: "octo/repo", title: "Deploy")],
            createdAt: 1_000)
    }
}
