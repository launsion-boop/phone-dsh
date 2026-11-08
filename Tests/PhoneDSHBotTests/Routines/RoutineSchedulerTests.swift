// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutineSchedulerTests: XCTestCase {
    func testSilentHeldAndInterruptDeliveryTiers() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        _ = try await machine.create(botId: "bot-a", title: "Held", prompt: "report",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: now - 600_000, id: "held")
        _ = try await machine.create(botId: "bot-a", title: "Silent", prompt: "stay quiet",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: now - 600_000, id: "silent")
        _ = try await machine.create(botId: "bot-a", title: "Interrupt", prompt: "report now",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     delivery: .interrupt, interruptReason: "someone is waiting",
                                     now: now - 600_000, id: "interrupt")
        let runs = WP6RunLog()
        let deliverer = WP6NotificationDeliverer()
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { clock.now }, deliverer: deliverer)
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink, proactive: engine,
            runner: { request in
                runs.append(request)
                if request.routine.id == "silent" { return .success("[quiet]") }
                return .success(request.routine.id == "interrupt" ? "Three blockers. Second sentence." : "Held result.")
            },
            available: { _ in true }, settings: { wp6Settings() }, now: { clock.now }
        )
        try await scheduler.tick()

        XCTAssertEqual(runs.count, 3)
        await WP6AssertEqual(await sink.rows.count, 3)
        await WP6AssertEqual(await sink.unreadCount, 2)
        try await WP6AssertEqual(try await inbox.items().count, 2)
        XCTAssertEqual(deliverer.notifications.count, 1)
        XCTAssertEqual(deliverer.notifications[0].body, "Three blockers.")
        XCTAssertEqual(deliverer.notifications[0].deepLink,
                       "phonedsh://bot/bot-a/row/routine-run-interrupt-1")
        try await WP6AssertEqual(try await machine.delivery("interrupt:1", botId: "bot-a")?.notified, "sent")
        try await WP6AssertEqual(try await machine.delivery("silent:1", botId: "bot-a")?.quiet, true)
        try await WP6AssertEqual(try await machine.delivery("held:1", botId: "bot-a")?.status, .delivered)
    }

    func testQuietHoursPersistDeferralAndUrgentReasonIsMandatory() async throws {
        let root = try wp6TempDirectory(self)
        let quietAt = wp6Date(2026, 5, 12, 23, timeZone: "Asia/Taipei")
        let quietEnd = wp6Date(2026, 5, 13, 8, timeZone: "Asia/Taipei")
        let clock = WP6Clock(quietAt)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        let settings = wp6Settings(quietStart: "23:00", quietEnd: "08:00", timeZone: "Asia/Taipei")
        _ = try await machine.create(botId: "bot-a", title: "Night digest", prompt: "digest",
                                     schedule: .daily(time: "23:00", timezone: "Asia/Taipei"),
                                     now: quietAt - 3_600_000, id: "quiet")
        _ = try await machine.create(botId: "bot-a", title: "Incident", prompt: "check production",
                                     schedule: .daily(time: "23:00", timezone: "Asia/Taipei"),
                                     urgent: true, urgentReason: "production is down",
                                     now: quietAt - 3_600_000, id: "urgent")
        _ = try await machine.store.mutate(botId: "bot-a") { document in
            document.routines.append(Routine(id: "legacy-invalid", agentId: "bot-a", title: "Invalid urgent",
                                             prompt: "do not bypass", schedule: .daily(time: "23:00", timezone: "Asia/Taipei"),
                                             urgent: true, createdAt: quietAt - 3_600_000, nextRunAt: quietAt))
            return RoutineMutation(value: (), botId: "bot-a")
        }
        let runs = WP6RunLog()
        let makeScheduler: () -> RoutineScheduler = {
            RoutineScheduler(botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
                             runner: { request in runs.append(request); return .success("still down") },
                             available: { _ in true }, settings: { settings }, now: { clock.now })
        }
        try await makeScheduler().tick()
        XCTAssertEqual(runs.all.map(\.routine.id), ["urgent"])
        let deferred = try await machine.get(botId: "bot-a", routineId: "quiet")
        XCTAssertEqual(deferred?.attempt, 0)
        XCTAssertEqual(deferred?.nextRunAt, quietEnd)
        XCTAssertEqual(deferred?.quietDefer?.scheduledFor, quietAt)
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "legacy-invalid")?.nextRunAt, quietEnd)

        try await makeScheduler().tick()
        XCTAssertEqual(runs.count, 1)
        clock.set(quietEnd)
        try await makeScheduler().tick()
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.all.map(\.routine.id), ["urgent", "legacy-invalid", "quiet"])
        try await WP6AssertNil(try await machine.get(botId: "bot-a", routineId: "quiet")?.quietDefer)
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "quiet")?.lastResult?.quietDeferredFrom, quietAt)
        await XCTAssertThrowsErrorAsync(try await machine.create(botId: "bot-a", title: "Bad", prompt: "x",
                                                                 schedule: .interval(everyMinutes: 5), urgent: true,
                                                                 now: quietAt))
        await XCTAssertThrowsErrorAsync(try await machine.create(botId: "bot-a", title: "Bad interrupt", prompt: "x",
                                                                 schedule: .interval(everyMinutes: 5), delivery: .interrupt,
                                                                 now: quietAt))
    }

    func testWebContentUnavailableQueuesAndRecoveryRunsSequentiallyOnce() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        for id in ["first", "second"] {
            _ = try await machine.create(botId: "bot-a", title: id, prompt: "run \(id)",
                                         schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                         now: now - 600_000, id: id)
        }
        let available = WP6Flag(false)
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in
                runs.append(request)
                XCTAssertTrue(request.wake.text.hasPrefix("<timestamp>"))
                XCTAssertTrue(request.wake.text.contains("[SAND_HIDDEN_PROMPT][SAND_TRUSTED_AUTOMATION_PROMPT]"))
                return .success("done \(request.routine.id)")
            },
            available: { _ in available.current }, settings: { wp6Settings() }, now: { clock.now }
        )
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 0)
        try await WP6AssertEqual(try await scheduler.queuedRoutines().count, 2)
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "first")?.attempt, 0)
        await WP6AssertEqual(await sink.rows.count, 0)

        available.set(true)
        try await scheduler.tick()
        XCTAssertEqual(runs.all.map(\.routine.id), ["first", "second"])
        await WP6AssertEqual(await sink.rows.count, 2)
        try await WP6AssertEqual(try await inbox.items().count, 2)
        try await WP6AssertEqual(try await scheduler.queuedRoutines().count, 0)
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 2)
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "first")?.attempt, 1)
    }

    func testTimeoutCancelsAndUnconfirmedCancellationNeedsReconciliation() async throws {
        for confirmed in [true, false] {
            let root = try wp6TempDirectory(self)
            let now = wp6Date(2026, 5, 12, 12)
            let clock = WP6Clock(now)
            let machine = try wp6Machine(root: root)
            _ = try await machine.create(botId: "bot-a", title: "Timeout", prompt: "wait",
                                         schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                         delivery: .interrupt, interruptReason: "must know",
                                         now: now - 600_000, id: "timeout")
            let proactive = WP6Proactive()
            let scheduler = RoutineScheduler(
                botId: "bot-a", machine: machine, inbox: try wp6Inbox(root: root), sink: WP6RoutineSink(),
                proactive: proactive,
                runner: { _ in
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        return .success("too late")
                    } catch {
                        return RoutineExecutionResult(status: .cancelled, error: "cancelled", cancelledBy: "timeout")
                    }
                },
                cancelRunner: { _ in RoutineCancellationResult(cancelled: confirmed) },
                available: { _ in true },
                settings: { wp6Settings() }, now: { clock.now }, runTimeoutMs: 20, cancelGraceMs: 50
            )
            try await scheduler.tick()
            let delivery = try await machine.delivery("timeout:1", botId: "bot-a")
            XCTAssertEqual(delivery?.resultStatus, confirmed ? .timedOut : .needsReconciliation)
            XCTAssertEqual(delivery?.cancelOrigin, "timeout")
            XCTAssertEqual(delivery?.text, "")
            try await WP6AssertEqual(try await wp6Inbox(root: root).items().count, 0)
            await WP6AssertEqual(await proactive.candidates.count, confirmed ? 1 : 0)
        }
    }

    func testOverlapIsSkippedAndCrashRecoveryIsBounded() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        _ = try await machine.create(botId: "bot-a", title: "Overlap", prompt: "wait",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     idempotent: true, now: now - 600_000, id: "overlap")
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: try wp6Inbox(root: root), sink: WP6RoutineSink(),
            runner: { _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return .success("done")
            }, available: { _ in true }, settings: { wp6Settings() }, now: { clock.now }
        )
        let ticking = Task { try await scheduler.tick() }
        var started = false
        for _ in 0..<100 {
            if try await machine.get(botId: "bot-a", routineId: "overlap")?.runState?.status == .started {
                started = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(started)
        try await scheduler.tick()
        try await ticking.value
        try await WP6AssertGreaterThanOrEqual(try await machine.get(botId: "bot-a", routineId: "overlap")?.skipCount ?? 0, 1)

        _ = try await machine.create(botId: "bot-a", title: "Crash", prompt: "work",
                                     schedule: .interval(everyMinutes: 5), idempotent: true,
                                     now: now, id: "crash")
        _ = try await machine.begin(botId: "bot-a", routineId: "crash", startedAt: now)
        let first = try await machine.recover(botId: "bot-a", now: now + 1)
        XCTAssertEqual(first.first?.action, "retry")
        _ = try await machine.begin(botId: "bot-a", routineId: "crash", startedAt: now + 2)
        let second = try await machine.recover(botId: "bot-a", now: now + 3)
        XCTAssertEqual(second.first?.action, "needs-reconciliation")
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "crash")?.runState?.status,
                       .needsReconciliation)
        let status = AutomationStatus.block(routines: try await machine.list(botId: "bot-a"), now: now + 3)
        XCTAssertTrue(status.contains("needs-reconciliation"))
    }

    func testCrashBetweenSinkAndLedgerReplaysWithoutDuplicateRows() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let sink = WP6RoutineSink()
        _ = try await machine.create(botId: "bot-a", title: "Digest", prompt: "digest",
                                     schedule: .interval(everyMinutes: 5), now: now, id: "daily")
        _ = try await machine.begin(botId: "bot-a", routineId: "daily", startedAt: now, runId: "run-1")
        let pendingFinish = try await machine.finish(botId: "bot-a", routineId: "daily",
                                                     status: .succeeded, text: "result",
                                                     finishedAt: now + 1)
        let finished = try XCTUnwrap(pendingFinish)
        _ = try await machine.claimDelivery("daily:1", botId: "bot-a", now: now + 2)
        _ = try await sink.deliver(RoutineAutomation(delivery: try XCTUnwrap(finished.delivery)))
        let scheduler = RoutineScheduler(botId: "bot-a", machine: machine, inbox: try wp6Inbox(root: root),
                                         sink: sink, runner: { _ in .success("unused") },
                                         available: { _ in true }, settings: { wp6Settings() }, now: { clock.now })
        try await scheduler.recover()
        await WP6AssertEqual(await sink.rows.count, 1)
        await WP6AssertEqual(await sink.duplicateCalls, 1)
        try await WP6AssertEqual(try await machine.delivery("daily:1", botId: "bot-a")?.status, .delivered)
        try await WP6AssertEqual(try await wp6Inbox(root: root).items().count, 1)
    }
}
