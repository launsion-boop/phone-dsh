// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// ReadySweep step 5 calls the existing `RoutineScheduler.tick()`: several
/// missed occurrences of one routine catch up once, the next run moves past
/// `now`, and repeated sweeps do not duplicate the run.
final class RoutineCatchUpTests: XCTestCase {
    func testSeveralMissedOccurrencesRunOnceAndAdvancePastNow() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        let createdAt = now - 3 * 60 * 60 * 1_000
        _ = try await machine.create(botId: "bot-a", title: "Digest", prompt: "digest",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: createdAt, id: "digest")
        let firstMissed = createdAt + 5 * 60 * 1_000
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return .success("ok") },
            available: { _ in true }, settings: { wp6Settings() }, now: { clock.now })

        try await scheduler.tick()

        XCTAssertEqual(runs.count, 1, "a catch-up must not replay every missed occurrence")
        let fetchedDigest = try await machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetchedDigest)
        XCTAssertEqual(routine.lastResult?.scheduledFor, firstMissed)
        XCTAssertGreaterThan(routine.nextRunAt ?? 0, now,
                             "the next run must be in the future, not another missed slot")

        // The same wake may run the step only once, but a later wake (or a
        // retried step) must still be idempotent: the routine already moved on.
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 1)
    }

    func testAnUnavailableEngineLeavesTheRoutineForTheNextSweep() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        _ = try await machine.create(botId: "bot-a", title: "Late", prompt: "late",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: now - 20 * 60 * 1_000, id: "late")
        let runs = WP6RunLog()
        let available = WP6Flag(false)
        let makeScheduler = {
            RoutineScheduler(
                botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
                runner: { request in runs.append(request); return .success("ok") },
                available: { _ in available.current },
                settings: { wp6Settings() }, now: { clock.now })
        }

        try await makeScheduler().tick()
        XCTAssertEqual(runs.count, 0)
        let fetchedPending = try await machine.get(botId: "bot-a", routineId: "late")
        let pending = try XCTUnwrap(fetchedPending)
        XCTAssertLessThanOrEqual(pending.nextRunAt ?? .max, now)

        available.set(true)
        try await makeScheduler().tick()
        XCTAssertEqual(runs.count, 1)
        let fetchedCaughtUp = try await machine.get(botId: "bot-a", routineId: "late")
        let caughtUp = try XCTUnwrap(fetchedCaughtUp)
        XCTAssertGreaterThan(caughtUp.nextRunAt ?? 0, now)
    }

    func testQuietHoursStillDeferAndDoNotBypassWithoutAnUrgentReason() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 23, timeZone: "Asia/Taipei")
        let quietEnd = wp6Date(2026, 5, 13, 8, timeZone: "Asia/Taipei")
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        _ = try await machine.create(botId: "bot-a", title: "Night", prompt: "night",
                                     schedule: .daily(time: "23:00", timezone: "Asia/Taipei"),
                                     now: now - 60 * 60 * 1_000, id: "night")
        let settings = wp6Settings(quietStart: "23:00", quietEnd: "08:00", timeZone: "Asia/Taipei")
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return .success("ok") },
            available: { _ in true }, settings: { settings }, now: { clock.now })

        try await scheduler.tick()
        XCTAssertEqual(runs.count, 0)
        let fetchedDeferred = try await machine.get(botId: "bot-a", routineId: "night")
        let deferred = try XCTUnwrap(fetchedDeferred)
        XCTAssertEqual(deferred.nextRunAt, quietEnd)
        XCTAssertEqual(deferred.quietDefer?.scheduledFor, now,
                       "the original scheduled time is kept for the delivered row")

        clock.set(quietEnd)
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.all.first?.routine.id, "night")
    }
}
