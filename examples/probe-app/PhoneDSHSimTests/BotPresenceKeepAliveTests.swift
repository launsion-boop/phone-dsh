// SPDX-License-Identifier: MIT
// App-side keep-alive and routine-notification contract tests.
//
// The production decision lives in PhoneDSHBot so the App and the macOS eval
// harness cannot drift. These tests prove the App test bundle links that real
// policy and the routine deep link used by local notifications.

import XCTest
import PhoneDSHBot

final class BotPresenceKeepAliveTests: XCTestCase {
    private func routine(_ id: String, dueAt: Int64?, enabled: Bool = true) -> Routine {
        Routine(id: id, agentId: "bot-a", title: id, prompt: "work",
                schedule: .interval(everyMinutes: 30), enabled: enabled,
                createdAt: 1_000, nextRunAt: dueAt)
    }

    func testBackgroundKeepAliveIncludesABotRoutineInsideTheWindow() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("soon", dueAt: now + 5 * 60_000)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("later", dueAt: now + 30 * 60_000)], now: now))
        XCTAssertFalse(RoutinePresencePolicy.hasRoutineDueSoon(
            [routine("paused", dueAt: now + 60_000, enabled: false)], now: now))
    }

    func testPresenceLadderAndRoutineDeepLinkAreTheNotificationContract() {
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: true, keepingAlive: true, scheduledNotificationCount: 3), .foreground)
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: false, keepingAlive: true, scheduledNotificationCount: 0), .backgroundKeepAlive)
        XCTAssertEqual(RoutinePresencePolicy.level(
            appActive: false, keepingAlive: false, scheduledNotificationCount: 3), .scheduledNotification)

        let link = BotRoutineDeepLink.make(botId: "bot-a", routineId: "routine-1")
        XCTAssertEqual(link, "phonedsh://bot/bot-a/routine/routine-1")
        XCTAssertEqual(BotRoutineDeepLink.parse(link)?.botId, "bot-a")
        XCTAssertEqual(BotRoutineDeepLink.parse(link)?.routineId, "routine-1")
        XCTAssertNil(BotRoutineDeepLink.parse("phonedsh://bot/bot-a/row/routine-1"))
    }
}
