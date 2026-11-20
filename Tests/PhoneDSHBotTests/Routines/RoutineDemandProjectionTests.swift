// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// PLAN §2.9 I2: routine due times live on the host, not only in the engine.
/// The projection is pure; the scheduler hook re-projects after a state change.
final class RoutineDemandProjectionTests: XCTestCase {
    func testEarliestRunnableRoutineBecomesOneVisibleDemand() {
        let routines = [
            Self.routine(id: "later", nextRunAt: 5_000),
            Self.routine(id: "soon", nextRunAt: 2_000),
            Self.routine(id: "disabled", nextRunAt: 1_000, enabled: false),
            Self.routine(id: "no-next", nextRunAt: nil),
            Self.routine(id: "reconciling", nextRunAt: 500,
                         status: .needsReconciliation),
            Self.routine(id: "approval", nextRunAt: 400, status: .waitingApproval),
        ]
        let demand = RoutineDemandProjection.demand(botID: "bot-a", routines: routines)
        XCTAssertEqual(demand?.source, BotWakeDemand.botRoutineSource)
        XCTAssertEqual(demand?.key, "bot-a")
        XCTAssertEqual(demand?.dueAtMs, 2_000)
        XCTAssertEqual(demand?.kind, .recurring)
        XCTAssertEqual(demand?.userVisible, true)
    }

    func testNoRunnableRoutineProducesNoDemand() {
        XCTAssertNil(RoutineDemandProjection.earliestDueAt([]))
        XCTAssertNil(RoutineDemandProjection.demand(botID: "bot-a", routines: [
            Self.routine(id: "off", nextRunAt: 1_000, enabled: false),
            Self.routine(id: "waiting", nextRunAt: 2_000, status: .waitingApproval),
        ]))
    }

    func testQuietDeferralUsesTheAlreadyAdvancedNextRunAt() {
        // nextRunAt is the quiet-hours end; the projection trusts it and never
        // re-derives a time from quietDefer.scheduledFor.
        let deferred = Self.routine(id: "night", nextRunAt: 8_000,
                                    quietDefer: RoutineQuietDefer(
                                        until: 8_000, scheduledFor: 1_000, at: 500))
        XCTAssertEqual(RoutineDemandProjection.earliestDueAt([deferred]), 8_000)
    }

    func testSchedulerReProjectsAfterATick() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let runs = WP6RunLog()
        let sink = RecordingDemandSink()
        _ = try await machine.create(botId: "bot-a", title: "Catch up", prompt: "work",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: now - 600_000, id: "catch-up")
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: WP6RoutineSink(),
            runner: { request in runs.append(request); return .success("ok") },
            available: { _ in true }, settings: { wp6Settings() }, now: { clock.now },
            onDemandChanged: {
                let routines = (try? await machine.list(botId: "bot-a")) ?? []
                if let demand = RoutineDemandProjection.demand(botID: "bot-a", routines: routines) {
                    await sink.upsert(demand)
                } else {
                    await sink.remove(source: BotWakeDemand.botRoutineSource, key: "bot-a")
                }
            })

        try await scheduler.tick()

        XCTAssertEqual(runs.count, 1)
        let upserts = await sink.upserts
        let last = try XCTUnwrap(upserts.last)
        XCTAssertEqual(last.key, "bot-a")
        XCTAssertGreaterThan(last.dueAtMs, now,
                             "after the catch-up the next due time moved past now")
        XCTAssertEqual(last.kind, .recurring)
        XCTAssertTrue(last.userVisible)
    }

    func testSchedulerRemovesTheDemandWhenNoRoutineCanRun() async throws {
        let root = try wp6TempDirectory(self)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = RecordingDemandSink()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: WP6RoutineSink(),
            runner: { _ in .success("ok") }, available: { _ in true },
            settings: { wp6Settings() }, now: { 1_000 },
            onDemandChanged: {
                let routines = (try? await machine.list(botId: "bot-a")) ?? []
                if let demand = RoutineDemandProjection.demand(botID: "bot-a", routines: routines) {
                    await sink.upsert(demand)
                } else {
                    await sink.remove(source: BotWakeDemand.botRoutineSource, key: "bot-a")
                }
            })

        try await scheduler.tick()

        let removed = await sink.removed
        XCTAssertFalse(removed.isEmpty)
        XCTAssertTrue(removed.allSatisfy { $0.0 == BotWakeDemand.botRoutineSource && $0.1 == "bot-a" },
                      "the cache path and the tick both re-project idempotently")
    }

    // MARK: - Fixtures

    private static func routine(id: String, nextRunAt: Int64?, enabled: Bool = true,
                                status: RoutineRunStatus? = nil,
                                quietDefer: RoutineQuietDefer? = nil) -> Routine {
        Routine(id: id, agentId: "bot-a", title: id, prompt: "p",
                schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                enabled: enabled, createdAt: 0,
                runState: status.map {
                    RoutineRunState(runId: "run-\(id)", attempt: 1, status: $0,
                                    startedAt: 0)
                },
                quietDefer: quietDefer, nextRunAt: nextRunAt)
    }
}

private actor RecordingDemandSink: BotWakeDemanding {
    private(set) var upserts: [BotWakeDemand] = []
    private(set) var removed: [(String, String)] = []
    private(set) var removedSources: [String] = []

    func upsert(_ demand: BotWakeDemand) async { upserts.append(demand) }
    func remove(source: String, key: String) async { removed.append((source, key)) }
    func removeAll(source: String) async { removedSources.append(source) }
}
