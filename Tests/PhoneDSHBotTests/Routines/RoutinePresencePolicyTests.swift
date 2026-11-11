// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutinePresencePolicyTests: XCTestCase {
    private func routine(_ id: String, nextRunAt: Int64?, enabled: Bool = true,
                         status: RoutineRunStatus? = nil,
                         deferred: RoutineQuietDefer? = nil) -> Routine {
        Routine(
            id: id, agentId: "bot-a", title: id, prompt: "work",
            schedule: .interval(everyMinutes: 30), enabled: enabled,
            createdAt: 1_000, runState: status.map {
                RoutineRunState(runId: "run-\(id)", attempt: 1, status: $0, startedAt: 1_000)
            }, quietDefer: deferred, nextRunAt: nextRunAt)
    }

    func testKeepAliveWindowIncludesDueAndOverdueEnabledRoutines() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("due", nextRunAt: now + 60_000)], now: now))
        XCTAssertTrue(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("overdue", nextRunAt: now - 60_000)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("later", nextRunAt: now + RoutinePresencePolicy.keepAliveWindowMs + 1)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("paused", nextRunAt: now + 60_000, enabled: false)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("reconcile", nextRunAt: now + 60_000, status: .needsReconciliation)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("never", nextRunAt: nil)], now: now))
    }

    func testLevelFollowsTheLadder() {
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: true, keepingAlive: true, scheduledNotificationCount: 2), .foreground)
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: false, keepingAlive: true, scheduledNotificationCount: 0), .backgroundKeepAlive)
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: false, keepingAlive: false, scheduledNotificationCount: 2), .scheduledNotification)
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: false, keepingAlive: false, scheduledNotificationCount: 0), .scheduledNotification)
    }

    func testDeferredRoutinesExposeOriginalAndDeferredTimes() {
        let deferred = RoutineQuietDefer(until: 120_000, scheduledFor: 60_000, at: 30_000)
        let values = RoutinePresencePolicy.deferred([
            routine("late", nextRunAt: 120_000, deferred: deferred),
            routine("plain", nextRunAt: 90_000),
        ])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].routineId, "late")
        XCTAssertEqual(values[0].scheduledFor, 60_000)
        XCTAssertEqual(values[0].deferredUntil, 120_000)
    }
}
