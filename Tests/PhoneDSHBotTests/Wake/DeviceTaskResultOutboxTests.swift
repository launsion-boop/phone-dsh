// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class DeviceTaskResultOutboxTests: XCTestCase {
    private func notice(_ key: String = "task-key-1") -> DeviceTaskResultNotice {
        DeviceTaskResultNotice(
            deviceID: "sensor-1", deviceDisplayName: "厨房传感器",
            taskID: "task-1", idempotencyKey: key, goal: "检查厨房温度",
            status: .completed, result: "当前 23°C，处于目标区间。",
            createdAt: 1_760_000_003_000)
    }

    private func makeStore(_ root: URL) throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }

    private func inbox(_ store: SQLiteDomainStore) -> WakeInbox {
        WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-a"))
    }

    func testRecordBeforeEnqueueIsReplayedAfterRestartAndDeduped() async throws {
        let root = try wp6TempDirectory(self)
        let domain = try makeStore(root)
        let first = DeviceTaskResultOutbox(domain: domain, now: { 2_000 })
        let value = notice()
        try await first.record(value, botID: "bot-a")
        let pendingIDs = await first.pendingEventIDs(botID: "bot-a")
        XCTAssertEqual(pendingIDs, [DeviceTaskResultOutbox.recordEventID(for: value)])

        // Simulates a crash between the durable record and the inbox write.
        let restarted = DeviceTaskResultOutbox(domain: domain, now: { 2_000 })
        let inbox = inbox(domain)
        let delivered = try await restarted.redeliver(botID: "bot-a", in: inbox)
        XCTAssertEqual(delivered, 1)
        let items = try await inbox.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].requestId, value.requestID)
        let stillPending = await restarted.pendingEventIDs(botID: "bot-a")
        XCTAssertTrue(stillPending.isEmpty)

        // A second startup with an acknowledgement present must not add a
        // second item.
        let third = DeviceTaskResultOutbox(domain: domain, now: { 3_000 })
        let thirdCount = try await third.redeliver(botID: "bot-a", in: inbox)
        let finalItems = try await inbox.items()
        XCTAssertEqual(thirdCount, 0)
        XCTAssertEqual(finalItems.count, 1)
    }

    func testEnqueueWritesRecordThenAckAndConsumedItemIsNotResurrected() async throws {
        let root = try wp6TempDirectory(self)
        let domain = try makeStore(root)
        let inbox = inbox(domain)
        let outbox = DeviceTaskResultOutbox(domain: domain, now: { 2_000 })
        let value = notice()
        let first = try await outbox.enqueue(value, botID: "bot-a", in: inbox)
        XCTAssertFalse(first.duplicate)
        let second = try await outbox.enqueue(value, botID: "bot-a", in: inbox)
        XCTAssertTrue(second.duplicate)
        let afterDuplicate = try await inbox.items()
        XCTAssertEqual(afterDuplicate.count, 1)

        let staged = try await inbox.stage(now: 10_000)
        XCTAssertEqual(staged.items.count, 1)
        _ = try await inbox.commit(staged.key)
        let committed = try await inbox.items()
        XCTAssertEqual(committed.count, 0)

        let restarted = DeviceTaskResultOutbox(domain: domain, now: { 3_000 })
        let replayCount = try await restarted.redeliver(botID: "bot-a", in: inbox)
        let afterReplay = try await inbox.items()
        XCTAssertEqual(replayCount, 0)
        XCTAssertEqual(afterReplay.count, 0)
    }

    func testRecordEventAndAckAreDurableAndScopedToTheBot() async throws {
        let root = try wp6TempDirectory(self)
        let domain = try makeStore(root)
        let outbox = DeviceTaskResultOutbox(domain: domain, now: { 2_000 })
        let value = notice()
        try await outbox.enqueue(value, botID: "bot-a", in: inbox(domain))

        let events = try await domain.events(after: 0, limit: 100)
        let record = try XCTUnwrap(events.first {
            $0.eventId == DeviceTaskResultOutbox.recordEventID(for: value)
        })
        let ack = try XCTUnwrap(events.first {
            $0.eventId == DeviceTaskResultOutbox.acknowledgementEventID(for: value)
        })
        XCTAssertEqual(record.type, DeviceTaskResultOutbox.recordEventType)
        XCTAssertEqual(record.principal.botId, "bot-a")
        XCTAssertEqual(ack.type, DeviceTaskResultOutbox.acknowledgementEventType)
        XCTAssertEqual(ack.causationId, record.eventId)
        XCTAssertEqual(record.data["deviceTaskResult"]?["taskID"]?.stringValue, "task-1")

        // Another Bot's replay never consumes this Bot's notice.
        let other = DeviceTaskResultOutbox(domain: domain, now: { 3_000 })
        let otherCount = try await other.redeliver(botID: "bot-b", in: inbox(domain))
        XCTAssertEqual(otherCount, 0)
    }

    func testCodableRoundTripKeepsTheNoticeIdentity() throws {
        let value = notice()
        let decoded = try JSONDecoder().decode(
            DeviceTaskResultNotice.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.itemID, value.itemID)
        XCTAssertEqual(decoded.requestID, value.requestID)
    }
}
