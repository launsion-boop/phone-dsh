// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A routine run parks on a durable approval instead of ending as a timeout,
/// then resumes the same attempt (allowed) or fails explicitly (denied /
/// expired). The runner is a scripted closure; no model or Worker is involved.
final class RoutineApprovalPauseTests: XCTestCase {
    private func makeScheduler(
        machine: RoutineMachine, inbox: WakeInbox, sink: WP6RoutineSink,
        clock: WP6Clock, runs: WP6RunLog,
        onResume: @escaping @Sendable () -> RoutineExecutionResult = { .success("continued") }
    ) -> RoutineScheduler {
        RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in
                runs.append(request)
                if request.resumeApprovalID == nil {
                    return .waiting(approvalID: "approval-routine-1",
                                    sessionID: "gb-routine-1")
                }
                return onResume()
            },
            available: { _ in true }, settings: { wp6Settings() },
            now: { clock.now })
    }

    private func createRoutine(_ machine: RoutineMachine, now: Int64) async throws {
        _ = try await machine.create(
            botId: "bot-a", title: "Approval routine", prompt: "do the saved work",
            schedule: .interval(everyMinutes: 5, timezone: "UTC"),
            now: now - 600_000, id: "approval-routine")
    }

    func testRoutineRunParksWithoutDeliveryAndResumesAfterApproval() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        try await createRoutine(machine, now: now)
        let runs = WP6RunLog()
        let scheduler = makeScheduler(
            machine: machine, inbox: inbox, sink: sink, clock: clock, runs: runs)

        try await scheduler.tick()
        let parked = try await machine.get(botId: "bot-a", routineId: "approval-routine")
        XCTAssertEqual(parked?.runState?.status, .waitingApproval)
        XCTAssertEqual(parked?.runState?.waitingApprovalID, "approval-routine-1")
        XCTAssertEqual(parked?.runState?.waitingSessionID, "gb-routine-1")
        XCTAssertEqual(runs.count, 1)
        let noDelivery = await sink.rows
        XCTAssertTrue(noDelivery.isEmpty)
        let entries = await scheduler.waitingApprovalEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.approvalID, "approval-routine-1")

        // A tick while parked must not start a second attempt.
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 1)

        await scheduler.approvalResolved(
            approvalId: "approval-routine-1", sessionId: "gb-routine-1", allowed: true)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.all.last?.resumeApprovalID, "approval-routine-1")
        XCTAssertEqual(runs.all.last?.resumeSessionID, "gb-routine-1")
        let resumed = try await machine.get(botId: "bot-a", routineId: "approval-routine")
        XCTAssertEqual(resumed?.runState?.status, .succeeded)
        XCTAssertEqual(resumed?.runState?.waitingApprovalID, nil)
        let rows = await sink.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.result, "continued")
        let entriesAfter = await scheduler.waitingApprovalEntries()
        XCTAssertTrue(entriesAfter.isEmpty)
    }

    func testDeniedRoutineApprovalEndsTheRunAsFailed() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        try await createRoutine(machine, now: now)
        let runs = WP6RunLog()
        let scheduler = makeScheduler(
            machine: machine, inbox: inbox, sink: sink, clock: clock, runs: runs)
        try await scheduler.tick()

        await scheduler.approvalResolved(
            approvalId: "approval-routine-1", sessionId: "gb-routine-1", allowed: false)
        let denied = try await machine.get(botId: "bot-a", routineId: "approval-routine")
        XCTAssertEqual(denied?.runState?.status, .failed)
        XCTAssertEqual(denied?.runState?.error, "approval_denied")
        XCTAssertNil(denied?.runState?.waitingApprovalID)
        XCTAssertEqual(runs.count, 1, "a denial must not run the prompt")
        let rows = await sink.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.error, "approval_denied")
        XCTAssertFalse(rows.first?.result.isEmpty ?? true)
    }

    func testExpiredRoutineApprovalEndsTheRunWithTheExpiryCause() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        try await createRoutine(machine, now: now)
        let runs = WP6RunLog()
        let scheduler = makeScheduler(
            machine: machine, inbox: inbox, sink: sink, clock: clock, runs: runs)
        try await scheduler.tick()

        await scheduler.approvalResolved(
            approvalId: "approval-routine-1", sessionId: "gb-routine-1",
            allowed: false, expired: true)
        let expired = try await machine.get(botId: "bot-a", routineId: "approval-routine")
        XCTAssertEqual(expired?.runState?.status, .failed)
        XCTAssertEqual(expired?.runState?.error, "approval_expired")
        XCTAssertEqual(runs.count, 1)
    }

    func testEarlyDecisionBeforeParkIsAppliedWhenTheRunStops() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        try await createRoutine(machine, now: now)
        let runs = WP6RunLog()
        let scheduler = makeScheduler(
            machine: machine, inbox: inbox, sink: sink, clock: clock, runs: runs)
        // The decision lands before the scheduler persists `waiting-approval`.
        await scheduler.approvalResolved(
            approvalId: "approval-routine-1", sessionId: "gb-routine-1", allowed: true)
        try await scheduler.tick()
        XCTAssertEqual(runs.count, 2)
        let resumed = try await machine.get(botId: "bot-a", routineId: "approval-routine")
        XCTAssertEqual(resumed?.runState?.status, .succeeded)
        let rows = await sink.rows
        XCTAssertEqual(rows.count, 1)
    }
}
