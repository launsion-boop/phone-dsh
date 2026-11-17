// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Cloud-scheduled occurrence execution reuses the routine claim/settle path.
/// These tests drive the real `RoutineScheduler`/`RoutineMachine`/`WakeInbox`
/// with a real SQLite store; no second execution path is introduced.
final class RoutineCloudOccurrenceTests: XCTestCase {
    private let occurrenceKey = String(repeating: "a1b2", count: 16) // 64 hex chars

    private struct Fixture {
        let root: URL
        let clock: WP6Clock
        let machine: RoutineMachine
        let inbox: WakeInbox
        let sink: WP6RoutineSink
        let runs: WP6RunLog
        let scheduler: RoutineScheduler
    }

    private func fixture(runner: @escaping RoutineScheduler.Runner,
                         cancelRunner: RoutineScheduler.CancelRunner? = nil,
                         available: @escaping RoutineScheduler.Availability = { _ in true },
                         settings: @escaping @Sendable () -> ProactiveSettings = { wp6Settings() },
                         at now: Int64) throws -> Fixture {
        let root = try wp6TempDirectory(self)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return await runner(request) },
            cancelRunner: cancelRunner,
            available: available, settings: settings, now: { clock.now })
        return Fixture(root: root, clock: clock, machine: machine, inbox: inbox,
                       sink: sink, runs: runs, scheduler: scheduler)
    }

    func testCloudOccurrenceUsesTheExistingRoutinePath() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("Two things today.") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Daily digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)

        let outcome = await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot)
        let expectedRunID = RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey)

        XCTAssertEqual(outcome, .settled(status: .succeeded, runId: expectedRunID, attempt: 1))
        XCTAssertEqual(f.runs.count, 1)
        XCTAssertEqual(f.runs.all.first?.runId, expectedRunID)
        XCTAssertEqual(f.runs.all.first?.attempt, 1)
        XCTAssertTrue(f.runs.all.first?.wake.text.contains("[SAND_HIDDEN_PROMPT]") ?? false)
        XCTAssertTrue(f.runs.all.first?.wake.text.contains("Daily digest") ?? false)

        let fetched_settled = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let settled = try XCTUnwrap(fetched_settled)
        XCTAssertEqual(settled.runState?.runId, expectedRunID)
        XCTAssertEqual(settled.runState?.status, .succeeded)
        XCTAssertEqual(settled.lastResult?.scheduledFor, slot)
        XCTAssertEqual(settled.lastResult?.text, "Two things today.")
        XCTAssertNotEqual(settled.nextRunAt, slot)

        await WP6AssertEqual(await f.sink.rows.count, 1)
        await WP6AssertEqual(await f.sink.rows.first?.routineId, "digest")
        // A held routine still reaches the held inbox exactly once.
        try await WP6AssertEqual(try await f.inbox.items().count, 1)
        try await WP6AssertEqual(try await f.inbox.items().first?.kind, "routine-result")
        try await WP6AssertEqual(try await f.inbox.items().first?.deliveryKey, "digest:1")
    }

    func testDuplicateCloudDeliveryDoesNotRunTwice() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("done") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let s = f.scheduler

        let first = await s.runCloudOccurrence(routineId: "digest", occurrenceKey: occurrenceKey,
                                               scheduledFor: slot)
        XCTAssertEqual(first.settledStatus, .succeeded)
        let second = await s.runCloudOccurrence(routineId: "digest", occurrenceKey: occurrenceKey,
                                                scheduledFor: slot)
        XCTAssertEqual(second, .alreadySettled(status: .succeeded,
                                               runId: RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey),
                                               attempt: 1))
        XCTAssertEqual(f.runs.count, 1)
        await WP6AssertEqual(await f.sink.rows.count, 1)
        try await WP6AssertEqual(try await f.inbox.items().count, 1)
    }

    func testLocalBestEffortRunCoversTheSameSlot() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("local run") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        // The local scheduler fires first (best effort while the app is alive).
        try await f.scheduler.tick()
        XCTAssertEqual(f.runs.count, 1)
        XCTAssertNotEqual(f.runs.all.first?.runId,
                          RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey))

        let outcome = await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(outcome.settledStatus, .succeeded)
        if case .alreadySettled(let status, _, _) = outcome {
            XCTAssertEqual(status, .succeeded)
        } else {
            XCTFail("expected the local run to cover the same slot, got \(outcome)")
        }
        XCTAssertEqual(f.runs.count, 1)
        await WP6AssertEqual(await f.sink.rows.count, 1)
    }

    func testOverlappingRunIsSkippedWithoutASecondClaim() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let gate = CloudRunGate()
        let f = try fixture(runner: { _ in
            await gate.signalStarted()
            await gate.waitForRelease()
            return .success("slow result")
        }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let s = f.scheduler
        let task = Task { await s.runCloudOccurrence(routineId: "digest",
                                                     occurrenceKey: occurrenceKey,
                                                     scheduledFor: slot) }
        await gate.waitUntilStarted()
        // A *different* occurrence arriving while one run is in flight is the
        // overlap case; the same occurrence is `in_progress` (never re-claimed).
        let overlap = await s.runCloudOccurrence(routineId: "digest",
                                                 occurrenceKey: String(repeating: "c3", count: 32),
                                                 scheduledFor: slot + 1)
        XCTAssertEqual(overlap, .skipped(reason: "overlap"))
        await gate.release()
        let first = await task.value
        XCTAssertEqual(first.settledStatus, .succeeded)
        XCTAssertEqual(f.runs.count, 1)
    }

    func testNotReadyLeasesStayWithTheCaller() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("should not run") },
                            available: { _ in false }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let outcome = await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(outcome, .notReady)
        XCTAssertEqual(f.runs.count, 0)
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        XCTAssertNil(routine.runState)
        XCTAssertEqual(routine.attempt, 0)
    }

    func testQuietHoursDeferTheOccurrenceAndTheLocalLadderStillRuns() async throws {
        let quietAt = wp6Date(2026, 5, 12, 23, 30, timeZone: "Asia/Taipei")
        let quietEnd = wp6Date(2026, 5, 13, 8, timeZone: "Asia/Taipei")
        let f = try fixture(runner: { _ in .success("morning digest") },
                            settings: { wp6Settings(quietStart: "23:00", quietEnd: "08:00",
                                                    timeZone: "Asia/Taipei") },
                            at: quietAt)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Night digest", prompt: "digest",
            schedule: .interval(everyMinutes: 10, timezone: "Asia/Taipei"),
            now: quietAt - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let s = f.scheduler
        let outcome = await s.runCloudOccurrence(routineId: "digest",
                                                 occurrenceKey: occurrenceKey,
                                                 scheduledFor: slot)
        XCTAssertEqual(outcome, .skipped(reason: "quiet"))
        XCTAssertEqual(f.runs.count, 0)
        let fetched_deferred = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let deferred = try XCTUnwrap(fetched_deferred)
        XCTAssertEqual(deferred.nextRunAt, quietEnd)
        XCTAssertEqual(deferred.quietDefer?.scheduledFor, slot)
        XCTAssertEqual(deferred.attempt, 0)

        f.clock.set(quietEnd)
        try await s.tick()
        XCTAssertEqual(f.runs.count, 1)
        await WP6AssertEqual(await f.sink.rows.count, 1)
    }

    func testCrashRecoveryDoesNotReplayANonIdempotentOccurrence() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("must not run") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Expensive", prompt: "do the irreversible thing",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "expensive")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "expensive")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        // Simulate the process dying after `begin` persisted a cloud run.
        let runID = RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey)
        let claim = try await f.machine.begin(
            botId: "bot-a", routineId: "expensive", startedAt: now, scheduledFor: slot,
            leaseOwner: "cloud", leaseTTLMs: 60_000, runId: runID)
        XCTAssertEqual(claim?.claimed, true)

        // A fresh scheduler recovers the interrupted attempt.
        let recoveredScheduler = RoutineScheduler(
            botId: "bot-a", machine: f.machine, inbox: f.inbox, sink: f.sink,
            runner: { request in f.runs.append(request); return .success("must not run") },
            available: { _ in true }, settings: { wp6Settings() },
            now: { f.clock.now + 3_600_000 })
        let actions = try await recoveredScheduler.recover()
        XCTAssertEqual(actions.first?.action, "needs-reconciliation")
        let fetched_recovered = try await f.machine.get(botId: "bot-a", routineId: "expensive")
        let recovered = try XCTUnwrap(fetched_recovered)
        XCTAssertEqual(recovered.runState?.status, .needsReconciliation)

        let outcome = await recoveredScheduler.runCloudOccurrence(
            routineId: "expensive", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(outcome, .alreadySettled(status: .needsReconciliation, runId: runID, attempt: 1))
        XCTAssertEqual(f.runs.count, 0)
    }

    func testIdempotentCrashRetryStaysALocalDecision() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("retry") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Idempotent", prompt: "sync the list",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"), idempotent: true,
            now: now - 3_600_000, id: "idem")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "idem")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let runID = RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey)
        _ = try await f.machine.begin(
            botId: "bot-a", routineId: "idem", startedAt: now, scheduledFor: slot,
            leaseOwner: "cloud", leaseTTLMs: 60_000, runId: runID)
        let recoveredScheduler = RoutineScheduler(
            botId: "bot-a", machine: f.machine, inbox: f.inbox, sink: f.sink,
            runner: { request in f.runs.append(request); return .success("retry") },
            available: { _ in true }, settings: { wp6Settings() }, now: { f.clock.now })
        _ = try await recoveredScheduler.recover()
        let outcome = await recoveredScheduler.runCloudOccurrence(
            routineId: "idem", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(outcome.settledStatus, .failed)
        // The cloud occurrence itself is never replayed under the same key; the
        // existing local idempotent-retry flag decides whether a fresh local
        // attempt happens at the next tick.
        XCTAssertEqual(f.runs.count, 0)
        try await recoveredScheduler.tick()
        XCTAssertEqual(f.runs.count, 1)
        XCTAssertNotEqual(f.runs.all.first?.runId, runID)
    }

    func testUserCancelOfACloudRunSettlesCancelledWithoutAForcedNotification() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let gate = CloudRunGate()
        let f = try fixture(runner: { _ in
            await gate.signalStarted()
            await gate.waitForRelease()
            return RoutineExecutionResult(status: .cancelled)
        }, cancelRunner: { _ in RoutineCancellationResult(cancelled: true) }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let run = Task { await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot) }
        await gate.waitUntilStarted()
        let cancelling = Task { await f.scheduler.cancelRunning(routineId: "digest") }
        await gate.release()
        let outcome = await run.value
        let cancellation = await cancelling.value
        XCTAssertTrue(cancellation.cancelled)
        XCTAssertEqual(outcome, .settled(status: .cancelled,
                                         runId: RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey),
                                         attempt: 1))
        let fetched_delivery = try await f.machine.delivery("digest:1", botId: "bot-a")
        let delivery = try XCTUnwrap(fetched_delivery)
        XCTAssertEqual(delivery.resultStatus, .cancelled)
        XCTAssertEqual(delivery.cancelOrigin, "user")
        // A user cancel is not a failure notification.
        await WP6AssertEqual(await f.sink.rows.count, 1)
        await WP6AssertEqual(await f.sink.rows.first?.status, "idle")
    }

    func testCloudOccurrenceSurvivesAStoreReopenWithoutADuplicateRun() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .success("first and only") }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let first = await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(first.settledStatus, .succeeded)

        // A new store over the same SQLite file is the process-restart case.
        let reopenedMachine = try wp6Machine(root: f.root)
        let reopenedInbox = try wp6Inbox(root: f.root)
        let reopenedRuns = WP6RunLog()
        let reopenedSink = WP6RoutineSink()
        let reopened = RoutineScheduler(
            botId: "bot-a", machine: reopenedMachine, inbox: reopenedInbox, sink: reopenedSink,
            runner: { request in reopenedRuns.append(request); return .success("duplicate") },
            available: { _ in true }, settings: { wp6Settings() }, now: { f.clock.now })
        _ = try await reopened.recover()
        let second = await reopened.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot)
        XCTAssertEqual(second, .alreadySettled(
            status: .succeeded,
            runId: RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey), attempt: 1))
        XCTAssertEqual(reopenedRuns.count, 0)
        // The held item is still the single item from the first run.
        try await WP6AssertEqual(try await reopenedInbox.items().count, 1)
    }

    func testPeriodicRecoveryDoesNotRecoverAnInFlightCloudRun() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let gate = CloudRunGate()
        let f = try fixture(runner: { _ in
            await gate.signalStarted()
            await gate.waitForRelease()
            return .success("finished after recovery tick")
        }, at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let fetched_slot = try await f.machine.get(botId: "bot-a", routineId: "digest")?.nextRunAt
        let slot = try XCTUnwrap(fetched_slot)
        let task = Task { await f.scheduler.runCloudOccurrence(
            routineId: "digest", occurrenceKey: occurrenceKey, scheduledFor: slot) }
        await gate.waitUntilStarted()
        // The scheduler's periodic restore pass must treat its own unexpired
        // lease as a live run, not as a crash.
        let actions = try await f.scheduler.recover()
        XCTAssertTrue(actions.isEmpty)
        await gate.release()
        let outcome = await task.value
        XCTAssertEqual(outcome.settledStatus, .succeeded)
        XCTAssertEqual(f.runs.count, 1)
        await WP6AssertEqual(await f.sink.rows.count, 1)
    }

    func testCloudRunIdIsStableAndBounded() {
        let key = String(repeating: "f", count: 64)
        XCTAssertEqual(RoutineScheduler.cloudRunId(occurrenceKey: key), "cloud-" + key)
        XCTAssertEqual(RoutineScheduler.cloudRunId(occurrenceKey: key),
                       RoutineScheduler.cloudRunId(occurrenceKey: key))
        XCTAssertEqual(RoutineScheduler.cloudRunId(occurrenceKey: ""), "cloud-occurrence")
        let unsafe = String(repeating: "../", count: 200)
        let sanitized = RoutineScheduler.cloudRunId(occurrenceKey: unsafe)
        XCTAssertTrue(sanitized.hasPrefix("cloud-"))
        XCTAssertLessThanOrEqual(sanitized.count, 126)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(".."))
    }
}

/// Small async rendezvous used to hold a runner open while a second occurrence
/// call observes the in-flight state.
private actor CloudRunGate {
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func signalStarted() {
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
