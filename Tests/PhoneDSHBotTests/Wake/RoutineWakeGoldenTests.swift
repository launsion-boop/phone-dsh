// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutineWakeGoldenTests: XCTestCase {
    func testWakeRoutineSharedGolden() throws {
        let vector = try wp6Golden("wake-routine")
        let valid = try XCTUnwrap(vector["valid"] as? [String: Any])
        let routineObject = try XCTUnwrap(valid["quietDefer"])
        let routine = try JSONDecoder().decode(Routine.self, from: JSONSerialization.data(withJSONObject: routineObject))
        let expectedWake = try XCTUnwrap(valid["wake"] as? [String: Any])

        let wake = try RoutineWakeBuilder.build(routine: routine, mode: .due, lang: "zh",
                                                firedAt: 1_760_000_000_000, now: 1_760_000_000_000)
        XCTAssertEqual(wake.text, expectedWake["text"] as? String)
        XCTAssertEqual(wake.cue, expectedWake["cue"] as? String)
        XCTAssertEqual(wake.mode.rawValue, expectedWake["mode"] as? String)
        XCTAssertEqual(RoutineScheduleMath.expression(routine.schedule), valid["scheduleExpr"] as? String)

        let quiet = RoutineWakeBuilder.normalizeReply("[quiet]")
        let expectedQuiet = try XCTUnwrap(valid["quietReply"] as? [String: Any])
        XCTAssertEqual(quiet.text, expectedQuiet["text"] as? String)
        XCTAssertEqual(quiet.quiet, expectedQuiet["quiet"] as? Bool)
        let result = RoutineWakeBuilder.normalizeReply("有新结果")
        let expectedResult = try XCTUnwrap(valid["resultReply"] as? [String: Any])
        XCTAssertEqual(result.text, expectedResult["text"] as? String)
        XCTAssertEqual(result.quiet, expectedResult["quiet"] as? Bool)

        let routineItem = try WakeInboxItem(id: "held-1", kind: "routine-result", title: "晨间简报",
                                            text: "有三项变化", createdAt: 1_760_000_000_000,
                                            ranAt: 1_760_000_000_000)
        let subagent = try WakeInboxItem(id: "task-1", kind: "subagent-result", text: "检查完成",
                                         createdAt: 1_760_000_000_000, taskId: "task-1", status: "ok")
        XCTAssertEqual(HeldMessages.block(items: [routineItem, subagent], lang: "zh", timezone: "Asia/Taipei"),
                       valid["heldBlock"] as? String)
        XCTAssertEqual(AutomationStatus.block(routines: [routine], now: 1_760_000_000_000, lang: "zh"),
                       valid["automationStatus"] as? String)

        let flags = try RoutineDeliveryFlags(urgent: true, urgentReason: "生产故障",
                                             delivery: .interrupt, interruptReason: "用户正在等待")
        let expectedFlags = try JSONDecoder().decode(RoutineDeliveryFlags.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(valid["deliveryFlags"])))
        XCTAssertEqual(flags, expectedFlags)

        let invalid = try XCTUnwrap(vector["invalid"] as? [[String: Any]])
        let interrupt = try XCTUnwrap(invalid.first { $0["kind"] as? String == "interrupt_without_reason" })
        XCTAssertThrowsError(try RoutineDeliveryFlags(delivery: .interrupt)) { error in
            XCTAssertEqual(error.localizedDescription, interrupt["error"] as? String)
        }
        for kind in ["quiet_at_23_30", "quiet_at_noon"] {
            let entry = try XCTUnwrap(invalid.first { $0["kind"] as? String == kind })
            let at = wp6Date(2026, 11, 5, kind == "quiet_at_23_30" ? 23 : 12,
                             kind == "quiet_at_23_30" ? 30 : 0, timeZone: "Asia/Taipei")
            let settings = wp6Settings(quietStart: "23:00", quietEnd: "08:00", timeZone: "Asia/Taipei")
            XCTAssertEqual(RoutineQuietHours.contains(at, settings: settings), entry["value"] as? Bool)
        }
    }

    func testOnDemandWakeAndScheduleExpressions() throws {
        let base = Routine(id: "weekly", agentId: "main", title: "Weekly", prompt: "do it",
                           schedule: .weekly(time: "08:30", weekdays: [1, 7], timezone: "Asia/Taipei"),
                           createdAt: 1_760_000_000_000)
        let wake = try RoutineWakeBuilder.build(routine: base, mode: .onDemand, lang: "en",
                                                firedAt: 1_760_000_000_000, now: 1_760_000_000_000)
        XCTAssertTrue(wake.text.contains("was run on demand"))
        XCTAssertTrue(wake.text.contains("The user pressed Run now"))
        XCTAssertEqual(RoutineScheduleMath.expression(base.schedule), "30 8 * * 1,7")
        XCTAssertEqual(RoutineScheduleMath.expression(.daily(time: "08:30", timezone: "Asia/Taipei")), "30 8 * * *")
        XCTAssertEqual(RoutineScheduleMath.expression(.interval(everyMinutes: 30, phaseMinutes: 17)), "@every 30m/17m")
        XCTAssertEqual(try RoutineSchedule.parse("CRON_TZ=Asia/Taipei 30 8 * * *"),
                       try RoutineSchedule.cron("30 8 * * *", timezone: "Asia/Taipei").validated())
        XCTAssertThrowsError(try RoutineSchedule.parse("@every 1m"))
        XCTAssertEqual(try RoutineScheduleMath.nextRunAt(.daily(time: "08:30", timezone: "Asia/Taipei"),
                                                        now: 1_760_000_000_000), 1_760_056_200_000)
    }

    func testNotificationDeepLinkRoundTrip() {
        let link = BotNotificationDeepLink.make(botId: "bot/a", rowId: "row 1")
        XCTAssertEqual(link, "phonedsh://bot/bot%2Fa/row/row%201")
        let parsed = BotNotificationDeepLink.parse(link)
        XCTAssertEqual(parsed?.botId, "bot/a")
        XCTAssertEqual(parsed?.rowId, "row 1")
        XCTAssertNil(BotNotificationDeepLink.parse("https://example.com/bot/a/row/b"))
    }
}
