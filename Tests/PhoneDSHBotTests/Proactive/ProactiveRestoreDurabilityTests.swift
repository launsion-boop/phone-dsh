// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class ProactiveRestoreDurabilityTests: XCTestCase {
    func testFailedRestoreDoesNotMarkRestoredOrApplyPartialAccounting() async {
        let now = wp6Date(2026, 5, 12, 12)
        let log = WP6FlakyEventLog(events: [
            wp6Consideration(at: now - 1_000, commitSeq: 1, dedupeKey: "seen-1")
        ], failures: 1)
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { now },
                                     policy: ProactivePolicyConfiguration(dailyBudget: 2), eventLog: log)
        await WP6AssertEqual(await engine.restoreAccounting(), 0)
        await WP6AssertEqual(await engine.budgetSpent(), 0)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        await WP6AssertEqual(await engine.budgetSpent(), 1)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        await WP6AssertEqual(await engine.budgetSpent(), 1)
        let candidate = ProactiveCandidate(kind: .taskDone, botId: "bot-1", dedupeKey: "seen-1",
                                           createdAt: now, taskId: "seen-1", status: "completed")
        await WP6AssertEqual(await engine.consider(candidate).reason, "duplicate")
    }
}

private actor WP6FlakyEventLog: BotEventLog {
    private let stored: [BotEvent]
    private var failures: Int

    init(events: [BotEvent], failures: Int) {
        stored = events
        self.failures = failures
    }

    func append(_ event: BotEvent) async throws -> Int {
        throw SQLiteDomainStoreError.closed
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        if failures > 0 {
            failures -= 1
            throw SQLiteDomainStoreError.closed
        }
        return Array(stored.filter { ($0.commitSeq ?? 0) > commitSeq }.prefix(limit))
    }
}
