// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class ProactiveRestoreDurabilityTests: XCTestCase {
    private let now = wp6Date(2026, 5, 12, 12)

    func testFailedRestoreDoesNotMarkRestoredOrApplyPartialAccounting() async {
        let log = WP6FlakyEventLog(events: [
            wp6Consideration(at: now - 1_000, commitSeq: 1)
        ], failures: 1)
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: ProactivePolicyConfiguration(fuseMaxWakeups: 1),
                                     eventLog: log)
        await WP6AssertEqual(await engine.restoreAccounting(), 0)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        let candidate = ProactiveCandidate(kind: .taskDone, botId: "bot-1", dedupeKey: "seen-1",
                                           createdAt: now, taskId: "seen-1", status: "completed")
        await WP6AssertEqual(await engine.consider(candidate).reason, "fuse")
    }

    func testOldAccountingFieldsRemainReadable() async {
        // Events written before PC-20261111-bot-v2-unwired carried dedupeKey,
        // cost and spendBudget. Unknown fields must not break the fuse restore.
        let old = BotEvent(type: "proactive.considered", eventId: "proactive:1", commitSeq: 1,
                           time: now - 1_000, origin: .local(source: "runtime"),
                           traceId: "trace-1",
                           principal: BotPrincipal(botId: "bot-1", sessionId: nil, kind: "proactive"),
                           causationId: nil, correlationId: "seen-1",
                           data: .object([
                               "decision": .string("would"),
                               "kind": .string("task-done"),
                               "botId": .string("bot-1"),
                               "dedupeKey": .string("seen-1"),
                               "cost": .number(1),
                               "spendBudget": .bool(true),
                               "fuseRecorded": .bool(true),
                           ]))
        let log = WP6EventLog(events: [old])
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: ProactivePolicyConfiguration(fuseMaxWakeups: 1),
                                     eventLog: log)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        let candidate = ProactiveCandidate(kind: .taskDone, botId: "bot-1", dedupeKey: "seen-2",
                                           createdAt: now, taskId: "seen-2", status: "completed")
        await WP6AssertEqual(await engine.consider(candidate).reason, "fuse")
    }

    func testRemovedIdleCheckinEventDoesNotBreakRestore() async {
        let removed = BotEvent(type: "proactive.considered", eventId: "proactive:1", commitSeq: 1,
                               time: now - 2_000, origin: .local(source: "runtime"),
                               traceId: "trace-1",
                               principal: BotPrincipal(botId: "bot-1", sessionId: nil, kind: "proactive"),
                               causationId: nil, correlationId: nil,
                               data: .object([
                                   "decision": .string("would"),
                                   "kind": .string("idle-checkin"),
                                   "botId": .string("bot-1"),
                                   "fuseRecorded": .bool(true),
                               ]))
        let valid = wp6Consideration(at: now - 1_000, commitSeq: 2)
        let log = WP6EventLog(events: [removed, valid])
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: ProactivePolicyConfiguration(fuseMaxWakeups: 1),
                                     eventLog: log)
        await WP6AssertEqual(await engine.restoreAccounting(), 1)
        let candidate = ProactiveCandidate(kind: .taskDone, botId: "bot-1", dedupeKey: "seen-3",
                                           createdAt: now, taskId: "seen-3", status: "completed")
        await WP6AssertEqual(await engine.consider(candidate).reason, "fuse")
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
