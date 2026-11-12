// SPDX-License-Identifier: MIT

import XCTest

final class BotUIFormatTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components)!
    }

    private var now: Date { date(2026, 1, 15, 22, 12) }

    // MARK: - Dates

    func testDateTimeUsesChineseRelativeFormats() {
        XCTAssertEqual(BotUIFormat.dateTime(now, now: now), "今天 22:12")
        XCTAssertEqual(BotUIFormat.dateTime(date(2026, 10, 9, 22, 12), now: now),
                       "10月9日 22:12")
        XCTAssertEqual(BotUIFormat.dateTime(date(2025, 10, 9, 22, 12), now: now),
                       "2025年10月9日 22:12")
        XCTAssertEqual(BotUIFormat.time(date(2026, 1, 2, 9, 5)), "09:05")
        XCTAssertEqual(BotUIFormat.monthDay(date(2025, 10, 9)), "10月9日")
        XCTAssertEqual(BotUIFormat.date(now, now: now), "今天")
        XCTAssertEqual(BotUIFormat.date(date(2026, 3, 5), now: now), "3月5日")
        XCTAssertEqual(BotUIFormat.date(date(2025, 12, 31), now: now), "2025年12月31日")
    }

    func testDateTimeDoesNotTreatYesterdayAsToday() {
        let midnight = date(2026, 1, 15, 0, 10)
        XCTAssertEqual(BotUIFormat.dateTime(date(2026, 1, 14, 23, 30), now: midnight),
                       "1月14日 23:30")
        XCTAssertEqual(BotUIFormat.dateTime(date(2025, 1, 15, 0, 10), now: midnight),
                       "2025年1月15日 00:10")
    }

    func testRelativeTimeMatchesDrawerBehaviour() {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        XCTAssertEqual(BotUIFormat.relativeTime(milliseconds: 0), "还没有消息")
        XCTAssertEqual(BotUIFormat.relativeTime(milliseconds: nowMilliseconds - 30_000, now: now),
                       "刚刚")
        XCTAssertEqual(BotUIFormat.relativeTime(milliseconds: nowMilliseconds - 5 * 60_000, now: now),
                       "5 分钟前")
        XCTAssertEqual(BotUIFormat.relativeTime(milliseconds: nowMilliseconds - 3 * 3_600_000, now: now),
                       "3 小时前")
        XCTAssertEqual(BotUIFormat.relativeTime(milliseconds: nowMilliseconds - 26 * 3_600_000, now: now),
                       "1月14日")
    }

    // MARK: - Numbers

    func testCompactCount() {
        XCTAssertEqual(BotUIFormat.compactCount(0), "0")
        XCTAssertEqual(BotUIFormat.compactCount(999), "999")
        XCTAssertEqual(BotUIFormat.compactCount(9_999), "9999")
        XCTAssertEqual(BotUIFormat.compactCount(10_000), "1 万")
        XCTAssertEqual(BotUIFormat.compactCount(12_400), "1.2 万")
        XCTAssertEqual(BotUIFormat.compactCount(123_000), "12.3 万")
        XCTAssertEqual(BotUIFormat.compactCount(100_000_000), "1 亿")
        XCTAssertEqual(BotUIFormat.compactCount(-12_400), "-1.2 万")
    }

    func testPercent() {
        XCTAssertEqual(BotUIFormat.percent(used: 1, total: 4), "25%")
        XCTAssertEqual(BotUIFormat.percent(used: 0, total: 10), "0%")
        XCTAssertEqual(BotUIFormat.percent(used: 3, total: 2), "100%")
        XCTAssertEqual(BotUIFormat.percent(used: 10, total: 0), "—")
    }

    // MARK: - Routines

    func testRoutineDeliveryCoversRawAndProductionLabels() {
        XCTAssertEqual(BotUIFormat.routineDelivery("held"), "下次聊天时送达")
        XCTAssertEqual(BotUIFormat.routineDelivery("interrupt"), "立即提醒")
        XCTAssertEqual(BotUIFormat.routineDelivery("存入待处理"), "下次聊天时送达")
        XCTAssertEqual(BotUIFormat.routineDelivery("立即打断"), "立即提醒")
        XCTAssertEqual(BotUIFormat.routineDelivery("unknown-future-mode"), "其他")
        XCTAssertEqual(BotUIFormat.routineDelivery(""), "其他")
    }

    func testRoutineCreatorFromFieldsHidesIDs() {
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "user", authorization: "user-turn"),
                       "由你在对话中创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "user", authorization: "user-confirmed"),
                       "你确认后创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "agent", authorization: "user-turn"),
                       "由其他 Bot 创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "agent", authorization: "user-confirmed"),
                       "你确认后，由其他 Bot 创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "routine", authorization: "user-turn"),
                       "由例行任务创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "task-wake", authorization: "user-turn"),
                       "由子任务创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "held", authorization: "user-turn"),
                       "由后台回合创建")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "unknown", authorization: "user-turn"),
                       "其他来源")
        XCTAssertEqual(BotUIFormat.routineCreator(origin: "unknown", authorization: "user-confirmed"),
                       "你确认后创建")
    }

    func testRoutineCreatorFlattenedStringDropsReference() {
        XCTAssertEqual(BotUIFormat.routineCreator("用户回合 · bot-fixture-1"),
                       "由你在对话中创建")
        XCTAssertEqual(BotUIFormat.routineCreator("经用户确认 · routine:run-2"),
                       "你确认后创建")
        XCTAssertEqual(BotUIFormat.routineCreator("agent:call-42"), "由其他 Bot 创建")
        XCTAssertEqual(BotUIFormat.routineCreator("routine:run-2"), "由例行任务创建")
        XCTAssertEqual(BotUIFormat.routineCreator("not-a-known-creator"), "其他来源")
        XCTAssertFalse(BotUIFormat.routineCreator("用户回合 · bot-fixture-1")
            .contains("fixture"))
    }

    // MARK: - Grants

    func testGrantScope() {
        XCTAssertEqual(BotUIFormat.grantScope("until"), "长期有效")
        XCTAssertEqual(BotUIFormat.grantScope("until", expiresAt: date(2025, 11, 8)),
                       "有效至 2025年11月8日")
        XCTAssertEqual(BotUIFormat.grantScope("session"), "本次会话")
        XCTAssertEqual(BotUIFormat.grantScope("once"), "仅本次")
        XCTAssertEqual(BotUIFormat.grantScope("forever"), "其他")
        XCTAssertEqual(BotUIFormat.grantScope(""), "其他")
    }

    func testGrantSource() {
        XCTAssertEqual(BotUIFormat.grantSource("approval-card"), "来自审批卡")
        XCTAssertEqual(BotUIFormat.grantSource("approval-standing"), "来自常设审批")
        XCTAssertEqual(BotUIFormat.grantSource("approval"), "来自审批")
        XCTAssertEqual(BotUIFormat.grantSource("rule-engine"), "其他")
    }

    func testGrantOperationTitleCoversKnownOperations() {
        let cases: [(String, String)] = [
            ("write.file", "写入文件"),
            ("file.write", "写入文件"),
            ("file.edit", "编辑文件"),
            ("network-egress", "访问网络"),
            ("egress.post", "访问网络"),
            ("egress.delete", "访问网络"),
            ("rm-destructive", "删除文件"),
            ("find-delete", "删除文件"),
            ("git-destructive", "丢弃改动"),
            ("dshbot.Task", "启动子任务"),
            ("dshbot.AwaitTask", "等待子任务"),
            ("dshbot.StopSubagent", "停止子任务"),
            ("dshbot.SendToUser", "发送消息"),
            ("dshbot.SendToAgent", "给其他 Bot 发消息"),
            ("dshbot.CreateTeammate", "创建协作 Bot"),
            ("dshbot.UpdateRoutine", "修改例行任务"),
            ("dshbot.ListRoutines", "查看例行任务"),
            ("memory.read", "读取记忆"),
            ("memory.recall", "回想记忆"),
            ("memory.sort", "整理记忆"),
            ("memory.write", "写入记忆"),
            ("memory.forget", "删除记忆"),
            ("ble.devices", "发现蓝牙设备"),
            ("ble.read", "读取设备数据"),
            ("ble.link_tools", "查看设备工具"),
            ("ble.link_result", "读取设备结果"),
            ("ble.alert", "提醒设备"),
            ("ble.link_call", "调用设备工具"),
            ("device.discovery.read", "发现设备"),
            ("context.volatile", "访问会话上下文"),
            ("routine.authorize", "确认例行任务"),
            ("teammate.authorize", "确认协作 Bot"),
            ("sandbox-escalation", "提升执行权限"),
            ("approval.weak-action", "请求审批"),
            ("tool.unclassified", "执行工具"),
            ("ui.show_progress", "显示卡片"),
            ("*", "所有操作"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(BotUIFormat.grantOperationTitle(raw), expected, raw)
        }
        XCTAssertEqual(BotUIFormat.grantOperationTitle("future.operation"), "其他")
        XCTAssertEqual(BotUIFormat.grantOperationTitle(""), "其他")
    }

    func testGrantResourceSummary() {
        XCTAssertEqual(BotUIFormat.grantResourceSummary("host=api.example.test"),
                       "api.example.test")
        XCTAssertEqual(BotUIFormat.grantResourceSummary("dir=/dsh/workspace/.dshbot/agents/main/reports"),
                       "reports 文件夹")
        XCTAssertEqual(BotUIFormat.grantResourceSummary("/dsh/workspace/.dshbot/agents/main/reports/**"),
                       "reports 文件夹")
        XCTAssertEqual(BotUIFormat.grantResourceSummary("curl https://api.example.test/*"),
                       "curl https://api.example.test/*")
        XCTAssertEqual(BotUIFormat.grantResourceSummary("  "), "其他")
    }

    // MARK: - Paths

    func testWorkspaceRelativePath() {
        XCTAssertEqual(
            BotUIFormat.workspaceRelativePath("/dsh/workspace/.dshbot/agents/main/reports/**"),
            "reports/**")
        XCTAssertEqual(
            BotUIFormat.workspaceRelativePath("dir=/dsh/workspace/.dshbot/agents/main/reports"),
            "reports")
        XCTAssertEqual(
            BotUIFormat.workspaceRelativePath("/dsh/workspace/notes/a.md"),
            "notes/a.md")
        XCTAssertEqual(BotUIFormat.workspaceRelativePath("agent/profile.md"), "agent/profile.md")
    }

    func testPathSummary() {
        XCTAssertEqual(
            BotUIFormat.pathSummary("/dsh/workspace/.dshbot/agents/main/reports/**"),
            "reports 文件夹")
        XCTAssertEqual(
            BotUIFormat.pathSummary("dir=/dsh/workspace/.dshbot/agents/main/reports", isDirectory: true),
            "reports 文件夹")
        XCTAssertEqual(
            BotUIFormat.pathSummary("/dsh/workspace/.dshbot/agents/main/reports/2026/**"),
            "reports/2026 文件夹")
        XCTAssertEqual(
            BotUIFormat.pathSummary("/dsh/workspace/.dshbot/agents/main/agent/profile.md"),
            "profile.md")
        XCTAssertEqual(BotUIFormat.pathSummary("agent/profile.md"), "profile.md")
        XCTAssertEqual(
            BotUIFormat.pathSummary("/dsh/workspace/.dshbot/agents/main"),
            "Bot 工作区")
    }
}
