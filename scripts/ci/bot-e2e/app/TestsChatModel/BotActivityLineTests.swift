// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHAgentCore
import PhoneDSHBot

final class BotActivityLineTests: XCTestCase {
    // MARK: - Tool table

    func testToolTableMapsNativeAndPhoneToolsToCategories() {
        let cases: [(String, String, BotActivityCategory, String)] = [
            ("read", "{\"path\":\"/tmp/report.md\"}", .reading, "在翻文件 · report.md"),
            ("write", "{\"path\":\"/tmp/notes.md\"}", .writing, "在写文件 · notes.md"),
            ("edit", "{\"file_path\":\"/tmp/a.swift\"}", .writing, "在改文件 · a.swift"),
            ("grep", "{\"pattern\":\"TODO\"}", .searching, "在搜内容 · TODO"),
            ("web_search", "{\"queries\":[\"东京天气\"]}", .searching, "在网上搜 · 东京天气"),
            ("web_fetch", "{\"url\":\"https://www.example.com/a/b\"}", .browsing, "在开网页 · example.com"),
            ("job_output", "{\"job_id\":\"job-7\"}", .running, "等个结果 · job-7"),
            ("todo_write", "{}", .writing, "整理待办"),
            ("mcp__phone__ReadMemory", "{\"path\":\"user/diary.md\"}", .memory, "在翻记忆 · diary.md"),
            ("mcp__phone__UpdateMemory", "{\"path\":\"agent/notes.md\"}", .memory, "在记笔记 · notes.md"),
            ("mcp__phone__RecallMemory", "{\"query\":\"上周的约定\"}", .memory, "回想一下 · 上周的约定"),
            ("mcp__phone__SendToUser", "{}", .messaging, "整理回复"),
            ("mcp__phone__SendToAgent", "{\"name\":\"小海\"}", .messaging, "给队友发消息 · 小海"),
            ("mcp__phone__show_progress", "{\"title\":\"整理发布材料\"}", .writing, "更新进度 · 整理发布材料"),
            ("mcp__phone__RequestApproval", "{\"action\":\"删除旧文件\"}", .messaging, "请你确认 · 删除旧文件"),
            ("mcp__phone__android_tap", "{}", .running, "点点屏幕"),
            ("mcp__phone__android_open_uri", "{\"uri\":\"https://example.com/x\"}", .browsing, "打开链接 · example.com"),
            ("mcp__phone__ble_read", "{}", .reading, "读设备数据"),
        ]
        for (name, json, category, text) in cases {
            let phrase = BotActivityPhrases.toolActivity(forToolNamed: name, arguments: arguments(json))
            XCTAssertEqual(phrase.category, category, "category for \(name)")
            XCTAssertEqual(phrase.text, text, "text for \(name)")
        }
    }

    func testUnknownToolIsGenericWithoutLeakingItsName() {
        let phrase = BotActivityPhrases.toolActivity(
            forToolNamed: "mcp__phone__MysteryTool",
            arguments: arguments("{\"path\":\"/tmp/x\"}"))
        XCTAssertEqual(phrase.category, .generic)
        XCTAssertEqual(phrase.text, "")
        XCTAssertFalse(phrase.text.contains("MysteryTool"))
        XCTAssertEqual(BotActivityPhrases.primaryPhrase(for: .generic), "处理中")
    }

    // MARK: - Fish work style

    func testEveryCategorySelectsItsLivelyWorkingSubStyle() {
        let expected: [BotActivityCategory: BotFishWorkStyle] = [
            .reading: .reading,
            .memory: .reading,
            .searching: .searching,
            .browsing: .searching,
            .running: .running,
            .writing: .writing,
            .thinking: .generic,
            .reviewing: .generic,
            .messaging: .generic,
            .waiting: .generic,
            .replying: .generic,
            .generic: .generic,
        ]
        XCTAssertEqual(expected.count, BotActivityCategory.allCases.count)
        for category in BotActivityCategory.allCases {
            XCTAssertEqual(BotActivityPhrases.workStyle(for: category), expected[category],
                           "work style for \(category.rawValue)")
        }
    }

    // MARK: - Model description

    func testModelDescriptionWinsButCategoryStillFollowsTool() {
        let phrase = BotActivityPhrases.toolActivity(
            forToolNamed: "bash",
            arguments: arguments("{\"command\":\"cat a b c\",\"description\":\"  对比三篇日记的情绪。 \"}"))
        XCTAssertEqual(phrase.category, .running)
        XCTAssertEqual(phrase.text, "对比三篇日记的情绪")
    }

    func testDescriptionAcceptsSummaryAndLabelAndStripsPunctuation() {
        XCTAssertEqual(BotActivityPhrases.cleanedModelText("  整理结果！！ "), "整理结果")
        XCTAssertEqual(BotActivityPhrases.cleanedModelText("查一下天气…"), "查一下天气")
        XCTAssertNil(BotActivityPhrases.cleanedModelText("   。  "))
        let summary = BotActivityPhrases.toolActivity(
            forToolNamed: "read", arguments: arguments("{\"summary\":\"翻翻旧笔记\"}"))
        XCTAssertEqual(summary.text, "翻翻旧笔记")
        let label = BotActivityPhrases.toolActivity(
            forToolNamed: "read", arguments: arguments("{\"label\":\"读一读日记\"}"))
        XCTAssertEqual(label.text, "读一读日记")
    }

    func testDescriptionIsCappedAtTwentyCharacters() {
        let twenty = "一二三四五六七八九十一二三四五六七八九十"
        XCTAssertEqual(BotActivityPhrases.cleanedModelText(twenty), twenty)
        let longer = twenty + "多余的字"
        let capped = BotActivityPhrases.cleanedModelText(longer)
        XCTAssertEqual(capped?.count, 20)
        XCTAssertEqual(capped?.hasSuffix("…"), true)
        XCTAssertEqual(capped, String(twenty.prefix(19)) + "…")
    }

    // MARK: - Phase derivation

    func testFinishedToolCallBecomesReviewingUntilNextStep() {
        let turn = sessionEvent("turn/start", seq: 1, time: 1_000)
        let call = sessionEvent("tool/call", seq: 2, time: 1_100, data: [
            "callId": .string("read-1"),
            "name": .string("read"),
            "arguments": .string("{\"path\":\"/tmp/report.md\"}"),
        ])
        let result = sessionEvent("tool/result", seq: 3, time: 1_200, data: [
            "message": .object(["toolCallId": .string("read-1")]),
        ])
        let reviewing = presentation([turn, call, result], now: 1_300)
        XCTAssertEqual(reviewing.activity?.status, .toolRunning)
        XCTAssertEqual(reviewing.activity?.category, .reviewing)
        XCTAssertEqual(reviewing.activity?.detail, "看看结果 · report.md")
        XCTAssertEqual(reviewing.activity?.startedAt, 1_200)

        let step = sessionEvent("step/start", seq: 4, time: 1_400)
        let thinking = presentation([turn, call, result, step], now: 1_500)
        XCTAssertEqual(thinking.activity?.status, .thinking)
        XCTAssertEqual(thinking.activity?.category, .thinking)
        XCTAssertEqual(thinking.activity?.detail, "")
        XCTAssertEqual(thinking.activity?.startedAt, 1_400)
    }

    func testRunningToolAndStreamingKeepTheirRules() {
        let turn = sessionEvent("turn/start", seq: 1, time: 1_000)
        let call = sessionEvent("tool/call", seq: 2, time: 1_100, data: [
            "callId": .string("read-1"), "name": .string("read"),
            "arguments": .string("{\"path\":\"/tmp/report.md\"}"),
        ])
        let running = presentation([turn, call], now: 1_200)
        XCTAssertEqual(running.activity?.status, .toolRunning)
        XCTAssertEqual(running.activity?.category, .reading)
        XCTAssertEqual(running.activity?.detail, "在翻文件 · report.md")
        XCTAssertEqual(running.activity?.startedAt, 1_100)

        let stream = sessionEvent("assistant/stream", seq: 3, time: 1_300,
                                  data: ["channel": .string("text")])
        XCTAssertNil(presentation([turn, call, stream], now: 1_400).activity)

        let preview = presentation([turn], now: 1_500)
        XCTAssertEqual(preview.activity?.status, .thinking)
        XCTAssertEqual(preview.activity?.category, .thinking)
        XCTAssertEqual(preview.activity?.startedAt, 1_000)
    }

    func testHiddenFishActionProducesNoActivity() {
        let turn = sessionEvent("turn/start", seq: 1, time: 1_000)
        let fish = sessionEvent("tool/call", seq: 2, time: 1_100, data: [
            "callId": .string("fish-1"),
            "name": .string("mcp__phone__FishAction"),
            "arguments": .string("{\"action\":\"waving\"}"),
        ])
        XCTAssertNil(presentation([turn, fish], now: 1_200).activity)
    }

    // MARK: - 800 ms latest-wins

    func testRecentActivityHoldsFor800msAndLatestWins() {
        var state = BotActivityLineState()
        let first = activity("第一件事", category: .reading, startedAt: 1_000)
        let second = activity("第二件事", category: .running, startedAt: 1_100)
        let third = activity("第三件事", category: .writing, startedAt: 1_200)
        state.receive(first, at: 1_000)
        XCTAssertEqual(state.text, "第一件事")
        state.receive(second, at: 1_500)
        XCTAssertEqual(state.text, "第一件事")
        state.receive(third, at: 1_600)
        XCTAssertEqual(state.text, "第一件事")
        XCTAssertEqual(state.nextDeadline, 1_800)
        state.tick(at: 1_799)
        XCTAssertEqual(state.text, "第一件事")
        state.tick(at: 1_800)
        XCTAssertEqual(state.text, "第三件事")
        XCTAssertEqual(state.activity, third)

        // Once the window has passed, the next activity shows immediately.
        let fourth = activity("第四件事", category: .messaging, startedAt: 1_900)
        state.receive(fourth, at: 2_700)
        XCTAssertEqual(state.text, "第四件事")
    }

    func testNilActivityHidesImmediately() {
        var state = BotActivityLineState()
        state.receive(activity("在翻文件", category: .reading, startedAt: 1_000), at: 1_000)
        state.receive(nil, at: 1_100)
        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.activity)
        XCTAssertNil(state.nextDeadline)
    }

    // MARK: - Generic-only rotation

    func testOnlyGenericPhrasesRotate() {
        var thinking = BotActivityLineState()
        thinking.receive(activity("", category: .thinking, startedAt: 0), at: 0,
                         randomStart: { _ in 0 })
        XCTAssertEqual(thinking.text, "思考中…")
        thinking.tick(at: 2_400)
        XCTAssertEqual(thinking.text, "整理思绪…")
        thinking.tick(at: 4_800)
        XCTAssertEqual(thinking.text, "准备下一步…")
        thinking.tick(at: 7_200)
        XCTAssertEqual(thinking.text, "思考中…")

        var reviewing = BotActivityLineState()
        reviewing.receive(activity("", category: .reviewing, startedAt: 0), at: 0,
                          randomStart: { _ in 0 })
        XCTAssertEqual(reviewing.text, "看看结果…")
        reviewing.tick(at: 2_400)
        XCTAssertEqual(reviewing.text, "检查一下…")

        var generic = BotActivityLineState()
        generic.receive(activity("", category: .generic, startedAt: 0), at: 0,
                        randomStart: { _ in 0 })
        XCTAssertEqual(generic.text, "处理中…")
        generic.tick(at: 2_400)
        XCTAssertEqual(generic.text, "正在处理…")
    }

    func testWaitingAndReplyingUseTheirOwnPhrasePools() {
        let waiting = activity("", category: .waiting, startedAt: 0)
        XCTAssertEqual(BotActivityPhrases.rotationPhrases(for: waiting), ["等你确认"])
        XCTAssertEqual(BotActivityPhrases.primaryPhrase(for: .waiting), "等你确认")

        let replying = activity("", category: .replying, startedAt: 0)
        XCTAssertEqual(BotActivityPhrases.rotationPhrases(for: replying),
                       ["正在回复…", "组织语言…", "写回复中…"])
        XCTAssertEqual(BotActivityPhrases.primaryPhrase(for: .replying), "正在回复")
    }

    func testReplyingRotatesButWaitingDoesNot() {
        var replying = BotActivityLineState()
        replying.receive(activity("", category: .replying, startedAt: 0), at: 0,
                         randomStart: { _ in 0 })
        XCTAssertEqual(replying.text, "正在回复…")
        XCTAssertEqual(replying.nextDeadline, 2_400)
        replying.tick(at: 2_400)
        XCTAssertEqual(replying.text, "组织语言…")
        replying.tick(at: 4_800)
        XCTAssertEqual(replying.text, "写回复中…")

        var waiting = BotActivityLineState()
        waiting.receive(activity("", category: .waiting, startedAt: 0), at: 0)
        XCTAssertEqual(waiting.text, "等你确认")
        XCTAssertNil(waiting.nextDeadline)
        waiting.tick(at: 10_000)
        XCTAssertEqual(waiting.text, "等你确认")
    }

    func testConcreteToolTextAndModelDescriptionNeverRotate() {
        var tool = BotActivityLineState()
        tool.receive(activity("在翻文件 · report.md", category: .reading, startedAt: 0), at: 0)
        XCTAssertEqual(tool.text, "在翻文件 · report.md")
        tool.tick(at: 10_000)
        XCTAssertEqual(tool.text, "在翻文件 · report.md")

        var described = BotActivityLineState()
        described.receive(activity("对比三篇日记的情绪", category: .running, startedAt: 0), at: 0)
        described.tick(at: 10_000)
        XCTAssertEqual(described.text, "对比三篇日记的情绪")
    }

    func testEachNewGenericActivityPicksItsOwnRandomStart() {
        var first = BotActivityLineState()
        first.receive(activity("", category: .thinking, startedAt: 0), at: 0,
                      randomStart: { _ in 0 })
        XCTAssertEqual(first.text, "思考中…")

        var second = BotActivityLineState()
        second.receive(activity("", category: .thinking, startedAt: 0), at: 0,
                       randomStart: { _ in 2 })
        XCTAssertEqual(second.text, "准备下一步…")

        // The pending activity keeps the start index it picked when it arrived.
        var delayed = BotActivityLineState()
        delayed.receive(activity("", category: .thinking, startedAt: 0), at: 0,
                        randomStart: { _ in 0 })
        delayed.receive(activity("", category: .reviewing, startedAt: 500), at: 500,
                        randomStart: { _ in 1 })
        delayed.tick(at: 800)
        XCTAssertEqual(delayed.text, "检查一下…")
    }

    // MARK: - 60s minute suffix

    func testActivityLongerThanAMinuteAppendsMinutes() {
        var state = BotActivityLineState()
        let running = activity("在翻文件 · report.md", category: .reading, startedAt: 1_000)
        state.receive(running, at: 1_000)
        XCTAssertEqual(state.text, "在翻文件 · report.md")
        state.tick(at: 60_999)
        XCTAssertEqual(state.text, "在翻文件 · report.md")
        state.tick(at: 61_000)
        XCTAssertEqual(state.text, "在翻文件 · report.md · 1 分钟")
        state.tick(at: 121_000)
        XCTAssertEqual(state.text, "在翻文件 · report.md · 2 分钟")
    }

    func testMinuteSuffixAlsoAppliesToGenericPhrases() {
        var state = BotActivityLineState()
        let thinking = activity("", category: .thinking, startedAt: 1_000)
        state.receive(thinking, at: 1_000, randomStart: { _ in 0 })
        state.tick(at: 61_000)
        XCTAssertEqual(state.text.hasSuffix("· 1 分钟"), true)
        XCTAssertEqual(state.text.components(separatedBy: " · ").count, 2)
    }

    func testUnknownStartTimeNeverGetsAMinuteSuffix() {
        var state = BotActivityLineState()
        state.receive(activity("处理中", category: .generic, startedAt: 0), at: 0)
        state.tick(at: 10_000_000)
        XCTAssertFalse(state.text.contains("分钟"))
    }

    // MARK: - Helpers

    private func arguments(_ json: String) -> [String: PhoneDSHBot.BotJSONValue] {
        guard let value = try? JSONDecoder().decode(PhoneDSHBot.BotJSONValue.self,
                                                    from: Data(json.utf8)),
              let object = value.objectValue else { return [:] }
        return object
    }

    private func sessionEvent(_ type: String, seq: Int, time: Int64,
                              data: [String: PhoneDSHBot.BotJSONValue] = [:]) -> BotDSHSessionEvent {
        BotDSHSessionEvent(type: type, seq: seq, time: time, data: data)
    }

    private func presentation(_ events: [BotDSHSessionEvent],
                              now: Int64) -> BotRuntimePresentation {
        BotRuntimePresentationFactory.make(botID: "main", sessionID: "main",
                                           sessionEvents: events, uiEvents: [], now: now)
    }

    private func activity(_ detail: String, category: BotActivityCategory,
                          startedAt: Int64) -> BotActivity {
        BotActivity(status: .toolRunning, detail: detail, category: category,
                    startedAt: startedAt)
    }
}
