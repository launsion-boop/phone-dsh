// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutineDurabilityTests: XCTestCase {
    private let now = wp6Date(2026, 5, 12, 12)

    func testRunSnapshotsAndLifecycleShareAtomicBatchesAcrossReopen() async throws {
        let root = try wp6TempDirectory(self)
        let file = root.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { self.now })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: domain))
        _ = try await machine.create(botId: "bot-a", title: "Digest", prompt: "work",
                                     schedule: .interval(everyMinutes: 5), idempotent: true,
                                     now: now, id: "daily")
        _ = try await machine.begin(botId: "bot-a", routineId: "daily", startedAt: now, runId: "run-1")

        let started = try await domain.events(after: 1, limit: 2)
        XCTAssertEqual(started.map(\.type), ["routine.updated", "routine.run_started"])
        XCTAssertEqual(started.map(\.commitSeq), [2, 3])
        XCTAssertEqual(started[0].batch?.id, started[1].batch?.id)
        XCTAssertEqual(started[0].batch?.total, 2)
        let startedSnapshot = try XCTUnwrap(DurableEventSnapshots.decode(
            RoutineDocument.self, from: started[0], botId: "bot-a"))
        XCTAssertEqual(startedSnapshot.routines[0].runState?.status, .started)
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { self.now + 1 })
        let recoveredMachine = RoutineMachine(store: SQLiteRoutineStore(domainStore: reopened))
        try await WP6AssertEqual(try await recoveredMachine.get(botId: "bot-a", routineId: "daily")?.runState?.status, .started)
        _ = try await recoveredMachine.finish(botId: "bot-a", routineId: "daily", status: .succeeded,
                                              text: "result", finishedAt: now + 10,
                                              attempt: 1, runId: "run-1")
        let finished = try await reopened.events(after: 3, limit: 2)
        XCTAssertEqual(finished.map(\.type), ["routine.updated", "routine.run_finished"])
        XCTAssertEqual(finished[0].batch?.id, finished[1].batch?.id)
        let finishedSnapshot = try XCTUnwrap(DurableEventSnapshots.decode(
            RoutineDocument.self, from: finished[0], botId: "bot-a"))
        XCTAssertEqual(finishedSnapshot.routines[0].runState?.status, .succeeded)
        XCTAssertEqual(finishedSnapshot.deliveries["daily:1"]?.status, .pending)
        try await reopened.close()

        let final = try SQLiteDomainStore(fileURL: file, now: { self.now + 2 })
        let finalMachine = RoutineMachine(store: SQLiteRoutineStore(domainStore: final))
        let delivery = try await finalMachine.delivery("daily:1", botId: "bot-a")
        XCTAssertEqual(delivery?.status, .pending)
        XCTAssertEqual(delivery?.text, "result")
        try await final.close()
    }

    func testBeforeCommitRollsBackSnapshotAndLifecycleTogether() async throws {
        let root = try wp6TempDirectory(self)
        let file = root.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { self.now })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: domain))
        _ = try await machine.create(botId: "bot-a", title: "Digest", prompt: "work",
                                     schedule: .interval(everyMinutes: 5), now: now, id: "daily")
        await domain.armCrashPoint("before-commit")
        await XCTAssertThrowsErrorAsync(try await machine.begin(botId: "bot-a", routineId: "daily",
                                                                startedAt: now, runId: "run-rollback"))
        try await WP6AssertEqual(try await domain.headCommitSeq(), 1)
        try await WP6AssertEqual(try await machine.get(botId: "bot-a", routineId: "daily")?.runState, nil)
        try await WP6AssertEqual(try await domain.events(after: 0, limit: 10).filter { $0.type == "routine.run_started" }.count, 0)
        try await domain.close()
    }

    func testConcurrentCreateUpdateAndRepeatedFinishDoNotLoseUpdates() async throws {
        let root = try wp6TempDirectory(self)
        let domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { self.now })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: domain))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = try await machine.create(botId: "bot-a", title: "Routine \(index)", prompt: "work",
                                                 schedule: .interval(everyMinutes: 5), now: self.now,
                                                 id: "routine-\(index)")
                }
            }
            try await group.waitForAll()
        }
        try await WP6AssertEqual(try await machine.list(botId: "bot-a").count, 12)
        _ = try await machine.begin(botId: "bot-a", routineId: "routine-0", startedAt: now, runId: "run-shared")

        // Use a task group rather than multiple `async let` bindings: the
        // Xcode 26.2 Swift runtime crashes on this test's two async-let
        // teardowns ("freed pointer was not the last allocation", in
        // asyncLet_finish_after_task_completion). The concurrency being tested
        // is update-vs-finish, not the async-let lowering.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await machine.update(
                    botId: "bot-a", routineId: "routine-0",
                    patch: RoutinePatch(title: "Updated title"), now: self.now + 1)
            }
            group.addTask {
                _ = try await machine.finish(
                    botId: "bot-a", routineId: "routine-0", status: .succeeded,
                    text: "result", finishedAt: self.now + 2, attempt: 1, runId: "run-shared")
            }
            try await group.waitForAll()
        }
        let duplicateFinish = try await machine.finish(
            botId: "bot-a", routineId: "routine-0", status: .succeeded,
            text: "duplicate", finishedAt: now + 3, attempt: 1, runId: "run-shared")
        let duplicateResult = try XCTUnwrap(duplicateFinish)
        XCTAssertTrue(duplicateResult.ignored)

        let fetched = try await machine.get(botId: "bot-a", routineId: "routine-0")
        let current = try XCTUnwrap(fetched)
        XCTAssertEqual(current.title, "Updated title")
        XCTAssertEqual(current.runState?.status, .succeeded)
        XCTAssertEqual(current.lastResult?.text, "result")
        let finishedEvents = try await domain.events(after: 0, limit: 100).filter {
            $0.type == "routine.run_finished" && $0.runId == "run-shared"
        }
        XCTAssertEqual(finishedEvents.count, 1)
        try await domain.verifyIntegrity()
        try await domain.close()
    }
}
