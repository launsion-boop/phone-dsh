// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class WakeInboxDurabilityTests: XCTestCase {
    func testConcurrentEnqueueRecoveryAndOutOfOrderCommitUseSQLiteSnapshot() async throws {
        let root = try wp6TempDirectory(self)
        let file = root.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let store = SQLiteWakeInboxStore(domainStore: domain, botId: "bot-a")
        let first = WakeInbox(store: store)
        let second = WakeInbox(store: store)
        let item = try WakeInboxItem(id: "held-1", kind: "routine-result", title: "Digest",
                                     text: "result", requestId: "daily:1", createdAt: 1)
        async let inserted = first.enqueue(item)
        async let duplicate = second.enqueue(item)
        let results = try await [inserted, duplicate]
        XCTAssertEqual(results.filter(\.duplicate).count, 1)
        try await WP6AssertEqual(try await first.items().count, 1)
        try await WP6AssertEqual(try await first.commit("missing-stage"), 0)

        let staged = try await first.stage(now: 2, key: "stage-1")
        XCTAssertEqual(staged.items.first?.state, .staged)
        try await domain.close()

        let reopenedDomain = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let reopened = WakeInbox(store: SQLiteWakeInboxStore(domainStore: reopenedDomain, botId: "bot-a"))
        try await WP6AssertEqual(try await reopened.recover(), 1)
        try await WP6AssertEqual(try await reopened.items().first?.state, .pending)
        let restaged = try await reopened.stage(now: 3, key: "stage-2")
        try await WP6AssertEqual(try await reopened.commit(restaged.key), 1)
        try await WP6AssertEqual(try await reopened.commit(restaged.key), 0)
        try await WP6AssertEqual(try await reopened.items(), [])
        try await reopenedDomain.close()

        let finalDomain = try SQLiteDomainStore(fileURL: file, now: { 3_000 })
        let final = WakeInbox(store: SQLiteWakeInboxStore(domainStore: finalDomain, botId: "bot-a"))
        try await WP6AssertEqual(try await final.items(), [])
        let commEvents = try await finalDomain.events(after: 0, limit: 20).filter {
            ["comm.inbound", "comm.outbound", "comm.reply"].contains($0.type)
        }
        XCTAssertEqual(commEvents.count, 5)
        try await finalDomain.close()
    }
}
