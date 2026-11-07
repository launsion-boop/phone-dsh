// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class ProactiveSourcesTests: XCTestCase {
    private let now = wp6Date(2026, 5, 12, 12)

    private func event(type: String, data: [String: BotJSONValue]) -> BotEvent {
        BotEvent(type: type, eventId: "event-1", commitSeq: 1, time: now,
                 origin: .local(source: "test"), traceId: "trace-1",
                 principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "test"),
                 causationId: nil, correlationId: nil, data: .object(data))
    }

    func testRoutineSourceFiltersHeldQuietAndHandledRuns() async {
        let sources = ProactiveSources(now: { self.now })
        var data: [String: BotJSONValue] = [
            "routineId": .string("daily"), "runId": .string("run-1"), "attempt": .number(1),
            "status": .string("succeeded"), "delivery": .string("held"), "quiet": .bool(false),
            "routineTitle": .string("Digest"), "resultExcerpt": .string("First sentence. More."),
        ]
        await WP6AssertEqual(await sources.candidates(for: event(type: "routine.run_finished", data: data)).count, 0)
        data["delivery"] = .string("interrupt")
        data["quiet"] = .bool(true)
        await WP6AssertEqual(await sources.candidates(for: event(type: "routine.run_finished", data: data)).count, 0)
        data["quiet"] = .bool(false)
        data["proactiveHandled"] = .bool(true)
        await WP6AssertEqual(await sources.candidates(for: event(type: "routine.run_finished", data: data)).count, 0)
        data.removeValue(forKey: "proactiveHandled")
        let candidates = await sources.candidates(for: event(type: "routine.run_finished", data: data))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].body, "First sentence.")
        XCTAssertEqual(candidates[0].notificationRowIDForTest, "routine-run-daily-1")
    }

    func testTaskReminderAndIdleSources() async {
        let sources = ProactiveSources(now: { self.now }, idleAfterMs: 1_000)
        let task = await sources.candidates(for: event(type: "task.settled", data: [
            "taskId": .string("task-1"), "attempt": .number(2), "status": .string("completed"),
            "title": .string("Backup"), "summary": .string("Backup finished."),
        ]))
        XCTAssertEqual(task.count, 1)
        XCTAssertEqual(task[0].summary, "Backup finished.")
        _ = await sources.addReminder(ProactiveReminder(reminderId: "rem-1", botId: "bot-a",
                                                        text: "Stand up", dueAt: now))
        _ = await sources.candidates(for: event(type: "conversation.turn_ended", data: [:]))
        let due = await sources.tick(now: now + 2_000)
        XCTAssertEqual(due.map(\.kind), [.reminder, .idleCheckin])
        XCTAssertEqual(due[0].body, "Stand up")
        XCTAssertEqual(due[1].silentForMs, 2_000)
    }

    func testEnabledTriageCanRejectWithoutBypassingDeterministicRules() async {
        let client = WP6TriageClient(reply: "```json\n{\"actionable\":false,\"reason\":\"noise\"}\n```")
        let deliverer = WP6NotificationDeliverer()
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { self.now },
                                     triage: ProactiveTriageGate(client: client, enabled: true),
                                     deliverer: deliverer)
        let candidate = ProactiveCandidate(kind: .taskDone, botId: "bot-a", dedupeKey: "task-1",
                                           createdAt: now, taskId: "task-1", status: "completed")
        let decision = await engine.consider(candidate)
        XCTAssertEqual(decision.reason, "triage")
        XCTAssertEqual(deliverer.notifications.count, 0)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].purpose, "triage")
    }
}

private final class WP6TriageClient: ProactiveTriageClient, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: String
    private(set) var requests: [ProactiveTriageRequest] = []

    init(reply: String) { self.reply = reply }

    func complete(_ request: ProactiveTriageRequest) async throws -> String {
        lock.withLock { requests.append(request) }
        return reply
    }
}

private extension ProactiveCandidate {
    var notificationRowIDForTest: String? { rowId }
}
