// SPDX-License-Identifier: MIT

import XCTest
import CoreGraphics
import PhoneDSHAgentCore
import PhoneDSHBot

final class BotActivityLineTests: XCTestCase {
    // MARK: - Tool table

    func testToolTableMapsNativeAndPhoneToolsToCategories() {
        let cases: [(String, String, BotActivityCategory, String)] = [
            ("bash", "{\"command\":\"xcodebuild build\"}", .running, "正在处理"),
            ("read", "{\"path\":\"/tmp/report.md\"}", .reading, "在翻文件 · report.md"),
            ("write", "{\"path\":\"/tmp/notes.md\"}", .writing, "在写文件 · notes.md"),
            ("edit", "{\"file_path\":\"/tmp/a.swift\"}", .writing, "在改文件 · a.swift"),
            ("grep", "{\"pattern\":\"TODO\"}", .searching, "在搜内容 · TODO"),
            ("web_search", "{\"queries\":[\"东京天气\"]}", .searching, "在网上搜 · 东京天气"),
            ("web_fetch", "{\"url\":\"https://www.example.com/a/b\"}", .browsing, "在开网页 · example.com"),
            ("job_output", "{\"job_id\":\"job-7\"}", .running, "等待结果"),
            ("todo_write", "{}", .writing, "整理待办"),
            ("mcp__phone__ReadMemory", "{\"path\":\"user/diary.md\"}", .memory, "在翻记忆 · diary.md"),
            ("mcp__phone__UpdateMemory", "{\"path\":\"agent/notes.md\"}", .memory, "在记笔记 · notes.md"),
            ("mcp__phone__RecallMemory", "{\"query\":\"上周的约定\"}", .memory, "回想一下 · 上周的约定"),
            ("mcp__phone__SendToUser", "{}", .messaging, "整理回复"),
            ("mcp__phone__SendToAgent", "{\"bot_name\":\"小海\",\"agent_id\":\"agent-9\"}",
             .messaging, "给其他 Bot 发消息 · 小海"),
            ("mcp__phone__show_progress", "{\"title\":\"整理发布材料\"}", .writing, "更新进度 · 整理发布材料"),
            ("mcp__phone__RequestApproval", "{\"action\":\"delete.files\",\"detail\":\"删除旧文件\"}",
             .messaging, "请你确认 · 删除旧文件"),
            ("mcp__phone__android_tap", "{}", .running, "点点屏幕"),
            ("mcp__phone__android_open_uri", "{\"uri\":\"https://example.com/x\"}",
             .browsing, "打开链接 · example.com"),
            ("mcp__phone__ble_read", "{}", .reading, "看看设备状态"),
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

    /// Every internal identifier class the old targets leaked: job/agent/task/
    /// routine/device/request IDs, Android package/permission, the approval
    /// action code, and Android's internal list filter. None may gain a
    /// `· target`, and none may appear in the phrase.
    func testInternalIdentifiersNeverBecomeTargets() {
        let cases: [(String, String, String)] = [
            ("job_output", "{\"job_id\":\"job-7\"}", "等待结果"),
            ("job_kill", "{\"job_id\":\"job-7\"}", "停止任务"),
            ("task", "{\"agent_id\":\"agent-9\"}", "启动子任务"),
            ("awaittask", "{\"task_id\":\"task-42\"}", "等子任务结果"),
            ("stopsubagent", "{\"task_id\":\"task-42\"}", "停止子任务"),
            ("updateroutine", "{\"routine_id\":\"routine-3\"}", "修改例行任务"),
            ("sendtoagent", "{\"agent_id\":\"agent-9\"}", "给其他 Bot 发消息"),
            ("requestapproval", "{\"action\":\"delete.files\"}", "请你确认"),
            ("android_launch_app", "{\"package\":\"com.example.app\"}", "打开应用"),
            ("android_force_stop", "{\"package\":\"com.example.app\"}", "关掉应用"),
            ("android_clear_app_data", "{\"package\":\"com.example.app\"}", "清除应用数据"),
            ("android_set_app_enabled", "{\"package\":\"com.example.app\",\"enabled\":true}",
             "启用或停用应用"),
            ("android_install_existing_app", "{\"package\":\"com.example.app\"}", "恢复应用"),
            ("android_uninstall_app", "{\"package\":\"com.example.app\"}", "卸载应用"),
            ("android_app_permission",
             "{\"package\":\"com.example.app\",\"permission\":\"android.permission.CAMERA\"}",
             "调整应用权限"),
            ("android_package_info", "{\"package\":\"com.example.app\"}", "看看应用信息"),
            ("android_list_packages", "{\"kind\":\"third-party\"}", "看看有哪些应用"),
            ("android_list_apk_files", "{\"directory\":\"/sdcard/Download\"}", "找找安装包"),
            ("ble_read", "{\"device_id\":\"device-a\",\"profile\":\"battery\"}", "看看设备状态"),
            ("ble_alert", "{\"device_id\":\"device-a\"}", "让设备提醒"),
            ("ble_link_tools", "{\"device_id\":\"device-a\"}", "看看设备功能"),
            ("ble_link_call", "{\"device_id\":\"device-a\",\"name\":\"light.set\"}", "操作设备"),
            ("ble_link_result", "{\"device_id\":\"device-a\",\"request_id\":\"req-5\"}",
             "看看设备反馈"),
        ]
        let forbidden = ["job-7", "agent-9", "task-42", "routine-3", "device-a", "req-5",
                         "com.example", "android.permission", "light.set", "delete.files",
                         "third-party", "/sdcard"]
        for (name, json, expected) in cases {
            let phrase = BotActivityPhrases.toolActivity(forToolNamed: name, arguments: arguments(json))
            XCTAssertEqual(phrase.text, expected, "text for \(name)")
            XCTAssertFalse(phrase.text.contains(" · "), "unexpected target for \(name)")
            for token in forbidden {
                XCTAssertFalse(phrase.text.contains(token), "\(name) leaked \(token)")
            }
        }
    }

    /// The positive half of the rule: targets may only be file names, search
    /// terms, domains, task/Bot/routine titles, device display names or a
    /// human approval detail — even when an internal ID rides along.
    func testTargetsUseOnlyHumanReadableValues() {
        let cases: [(String, String, String)] = [
            ("read", "{\"path\":\"/tmp/报告.md\"}", "在翻文件 · 报告.md"),
            ("web_search", "{\"query\":\"东京天气\"}", "在网上搜 · 东京天气"),
            ("web_fetch", "{\"url\":\"https://docs.example.com/a/b\"}",
             "在开网页 · docs.example.com"),
            ("task", "{\"task_title\":\"整理周报\",\"agent_id\":\"agent-9\"}",
             "启动子任务 · 整理周报"),
            ("updateroutine", "{\"title\":\"早间简报\",\"routine_id\":\"routine-3\"}",
             "修改例行任务 · 早间简报"),
            ("sendtoagent", "{\"bot_name\":\"小海\",\"agent_id\":\"agent-9\"}",
             "给其他 Bot 发消息 · 小海"),
            ("createteammate", "{\"name\":\"小海\"}", "创建协作 Bot · 小海"),
            ("requestapproval", "{\"detail\":\"删除旧文件\",\"action\":\"delete.files\"}",
             "请你确认 · 删除旧文件"),
            ("android_install_apk", "{\"path\":\"/sdcard/下载/更新.apk\"}",
             "安装应用 · 更新.apk"),
            ("android_delete_apk_file", "{\"path\":\"/sdcard/下载/旧包.apk\"}",
             "删除安装包 · 旧包.apk"),
            ("android_list_packages", "{\"query\":\"聊天\"}", "看看有哪些应用 · 聊天"),
            ("show_attachment", "{\"path\":\"/tmp/发布说明.pdf\"}",
             "送上附件 · 发布说明.pdf"),
            ("ble_read", "{\"device_id\":\"device-a\",\"device_name\":\"客厅灯\"}",
             "看看设备状态 · 客厅灯"),
        ]
        for (name, json, expected) in cases {
            let phrase = BotActivityPhrases.toolActivity(forToolNamed: name, arguments: arguments(json))
            XCTAssertEqual(phrase.text, expected, "text for \(name)")
        }
    }

    /// The jargon audit: activity phrases must not describe the mechanism
    /// (command/shell/background/context/log) or the team/subagent machinery.
    func testActivityPhrasesUsePlainUserLanguage() {
        let cases: [(String, String)] = [
            ("bash", "正在处理"),
            ("mcp__phone__android_shell", "在手机上操作"),
            ("mcp__phone__android_command_help", "看看怎么操作"),
            ("job_list", "看看进展"),
            ("mcp__phone__BotVolatileContext", "看看情况"),
            ("mcp__phone__android_logcat", "看看手机情况"),
            ("mcp__phone__Task", "启动子任务"),
            ("mcp__phone__AwaitTask", "等子任务结果"),
            ("mcp__phone__StopSubagent", "停止子任务"),
            ("mcp__phone__ListRoutines", "看看例行任务"),
            ("mcp__phone__SendToAgent", "给其他 Bot 发消息"),
            ("mcp__phone__CreateTeammate", "创建协作 Bot"),
            ("mcp__phone__ble_link_tools", "看看设备功能"),
            ("mcp__phone__ble_link_call", "操作设备"),
            ("mcp__phone__ble_link_result", "看看设备反馈"),
        ]
        let banned = ["命令", "Shell", "后台", "上下文", "日志", "委派", "子代理", "队友"]
        for (name, expected) in cases {
            let text = BotActivityPhrases.toolActivity(forToolNamed: name,
                                                       arguments: arguments("{}")).text
            XCTAssertEqual(text, expected, "text for \(name)")
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(name) leaked \(word)")
            }
        }
    }

    // MARK: - Chat tool row labels

    /// The Bot chat tool row reuses the host effect labels for UI cards and the
    /// activity phrases elsewhere. It must never fall back to the raw wire name.
    func testChatToolRowLabelsUseExistingVocabularyWithoutRawNames() {
        let cases: [(String, String)] = [
            ("bash", "正在处理"),
            ("mcp__phone__android_shell", "在手机上操作"),
            ("mcp__phone__ReadMemory", "在翻记忆"),
            ("mcp__phone__SendToAgent", "给其他 Bot 发消息"),
            ("mcp__phone__ask_user", "询问用户"),
            ("mcp__phone__show_progress", "显示进度卡片"),
            ("mcp__phone__show_document", "显示文件卡片"),
            ("mcp__phone__RequestApproval", "请求用户授权"),
            ("mcp__phone__MysteryTool", "工具操作"),
            ("", "工具操作"),
        ]
        for (name, expected) in cases {
            let label = BotActivityPhrases.toolRowLabel(forToolNamed: name)
            XCTAssertEqual(label, expected, "label for \(name)")
            XCTAssertFalse(label.contains("mcp__"), "raw namespace for \(name)")
            XCTAssertFalse(label.contains("__"), "raw separator for \(name)")
        }
    }

    /// The failed-row summary and the Worker's final identity-reclaim error are
    /// one sentence. The row must recognize both the legacy wire text and the
    /// new human text, and neither may expose the internal tag.
    func testFailedToolRowSummaryMatchesIdentityReclaimMessage() {
        let reason = "与 App 的连接已失效，已尝试恢复，请稍后重试。"
        let wire = "Error: [identity-bridge] App MCP did not accept the call registration: unauthorized"
        for raw in [wire, reason] {
            let summary = BotActivityPhrases.toolRowSummary(forErrorText: raw)
            XCTAssertEqual(summary, reason, "summary for \(raw)")
            XCTAssertFalse(summary.contains("identity-bridge"), "internal tag leaked")
            XCTAssertFalse(summary.contains("unauthorized"), "wire error leaked")
        }
    }

    // MARK: - Drawer status line

    /// The drawer contract reuses the chat line's minute suffix; the drawer has
    /// no rotation, so an empty detail keeps the category's first phrase.
    func testDrawerStatusLineReusesTheChatMinuteSuffix() {
        let running = activity("正在处理", category: .running, startedAt: 1_000)
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: running, now: 1_000),
                       "正在处理")
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: running, now: 61_000),
                       "正在处理 · 1 分钟")
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: running, now: 121_000),
                       "正在处理 · 2 分钟")

        let thinking = activity("", category: .thinking, startedAt: 1_000)
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: thinking, now: 1_000), "思考中")
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: thinking, now: 121_000),
                       "思考中 · 2 分钟")

        let unknownStart = activity("处理中", category: .generic, startedAt: 0)
        XCTAssertEqual(BotActivityPhrases.drawerStatusText(for: unknownStart, now: 10_000_000),
                       "处理中")
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

    // MARK: - Shimmer sweep

    /// The glint is a pure function of time: −1 → 1 across one 1.6s period,
    /// wrapping on both ends of the reference interval. Keeping it here means
    /// the view only applies it to a mask offset and the logic-only targets
    /// can check it without a renderer.
    func testActivitySweepPhaseIsPureAndWraps() {
        func phase(_ seconds: TimeInterval) -> CGFloat {
            BotActivitySweep.phase(at: Date(timeIntervalSinceReferenceDate: seconds))
        }
        XCTAssertEqual(BotActivitySweep.period, 1.6, accuracy: 0.0001)
        XCTAssertEqual(phase(0), -1, accuracy: 0.0001)
        XCTAssertEqual(phase(BotActivitySweep.period * 0.25), -0.5, accuracy: 0.0001)
        XCTAssertEqual(phase(BotActivitySweep.period * 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(phase(BotActivitySweep.period * 0.75), 0.5, accuracy: 0.0001)
        XCTAssertEqual(phase(BotActivitySweep.period), -1, accuracy: 0.0001)
        XCTAssertEqual(phase(-BotActivitySweep.period * 0.5), 0, accuracy: 0.0001)
        for step in 0...32 {
            let value = phase(Double(step) * 0.05)
            XCTAssertGreaterThanOrEqual(value, -1)
            XCTAssertLessThanOrEqual(value, 1)
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

    func testFinishedToolCallKeepsItsOwnSentenceAsReviewing() {
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
        XCTAssertEqual(reviewing.activity?.status, .thinking)
        XCTAssertEqual(reviewing.activity?.category, .reviewing)
        XCTAssertEqual(reviewing.activity?.detail, "在翻文件 · report.md")
        XCTAssertEqual(reviewing.activity?.startedAt, 1_200)

        let step = sessionEvent("step/start", seq: 4, time: 1_400)
        let thinking = presentation([turn, call, result, step], now: 1_500)
        XCTAssertEqual(thinking.activity?.status, .thinking)
        XCTAssertEqual(thinking.activity?.category, .reviewing)
        XCTAssertEqual(thinking.activity?.detail, "在翻文件 · report.md")
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

        // A committed public sentence for a later step never replaces the
        // in-flight call's own sentence or its lifecycle.
        let step = sessionEvent("step/start", seq: 3, time: 1_200, data: ["step": .number(2)])
        let sentence = sessionEvent("assistant/message", seq: 4, time: 1_300, data: [
            "message": .object(["content": .array([.object([
                "type": .string("text"), "text": .string("定位重连失败用例"),
            ])])]),
        ])
        XCTAssertEqual(presentation([turn, call, step, sentence], now: 1_400).activity?.detail,
                       "在翻文件 · report.md")

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
        XCTAssertEqual(presentation([turn, fish], now: 1_200).activity?.detail, "等待响应")
    }

    /// One sentence per real call. These exercise the real factory and policy
    /// over the shared `activity-evidence-v2.1` oracle; shared legacy phrase
    /// tests remain to protect deferred Android compatibility.
    func testIOSEvidenceLifecycleVectors() throws {
        struct Expected: Decodable { let status: String; let detail: String; let category: String; let startedAt: Int64 }
        struct Case: Decodable { let id: String; let events: [JSONValue]; let expected: Expected? }
        struct Vectors: Decodable { let now: Int64; let cases: [Case] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let path = root.appendingPathComponent("spec/ui/v1/bot/ios/activity-evidence-vectors.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: path))
        XCTAssertEqual(vectors.cases.count, 91)
        for vector in vectors.cases {
            let live = BotRuntimePresentationFactory.live(botID: "main", events: vector.events,
                                                          now: vectors.now).activity
            // The durable session log and the live frames share one reducer, so
            // the same events must produce the same activity.
            let durable = presentation(sessionEvents(vector.events), now: vectors.now).activity
            guard let expected = vector.expected else {
                XCTAssertNil(live, vector.id)
                XCTAssertNil(durable, vector.id)
                continue
            }
            XCTAssertNotNil(live, vector.id)
            XCTAssertEqual(live?.status.rawValue, expected.status, vector.id)
            XCTAssertEqual(live?.detail, expected.detail, vector.id)
            XCTAssertEqual(live?.category.rawValue, expected.category, vector.id)
            XCTAssertEqual(live?.startedAt, expected.startedAt, vector.id)
            XCTAssertEqual(durable, live, vector.id)
        }
    }

    func testDisplayTextKeepsRealTaskObjects() {
        for raw in ["对比 #174 与 main 的三个冲突文件",
                    "读取 BotChatModel.swift 中的发送逻辑",
                    "查看 BotChatModel.swift",
                    "回复李光浩的邮件",
                    "检查《周三例会》纪要"] {
            XCTAssertEqual(BotActivityEvidence.displayText(raw), raw, raw)
        }
        // First line, collapsed whitespace, trailing punctuation stripped.
        XCTAssertEqual(BotActivityEvidence.displayText("检查会议记录\n然后整理结论"), "检查会议记录")
        XCTAssertEqual(BotActivityEvidence.displayText("  对比   #174   与 main  "), "对比 #174 与 main")
        XCTAssertEqual(BotActivityEvidence.displayText("整理结果！！"), "整理结果")
        XCTAssertNil(BotActivityEvidence.displayText("   。  "))
    }

    func testDisplayTextRejectsFillersCompletionClaimsAndCredentials() {
        for raw in ["思考中", "处理中", "我来看看", "好的", "稍等", "开始",
                    "已收到读取结果", "已完成所有验证", "已确认可以合并",
                    "completed all steps", "done",
                    "Bearer secret-value", "api_key=abc123",
                    "sk-proj-AbCdEf123456", "ghp_0123456789abcdef",
                    "xoxb-1234-5678", "AKIAIOSFODNN7EXAMPLE"] {
            XCTAssertNil(BotActivityEvidence.displayText(raw), raw)
        }
        XCTAssertEqual(BotActivityEvidence.displayText("Meeting notes review"), "Meeting notes review")
        XCTAssertEqual(BotActivityEvidence.displayText("检查 3.5 小时"), "检查 3.5 小时")
    }

    func testLongPublicAnswerShortensAtClauseBoundary() {
        // A repeated short clause is cut at the last clause punctuation in the
        // 28-character CJK bound, so one real progress sentence is shown.
        let clauses = String(repeating: "对比 #174 与 main 的冲突文件，", count: 40)
        XCTAssertEqual(BotActivityEvidence.displayText(clauses),
                       "对比 #174 与 main 的冲突文件")
        XCTAssertEqual(BotActivityEvidence.displayText(
            "我先检查这个问题的完整原因。后面还有很长的解释内容不应上屏。"),
            "我先检查这个问题的完整原因")
        // Non-CJK text uses the 56-character bound and an ellipsis tail.
        let latin = String(repeating: "abcdef ghij ", count: 10)
        let shortened = BotActivityEvidence.displayText(latin)
        XCTAssertEqual(shortened?.count, 56)
        XCTAssertEqual(shortened?.hasSuffix("…"), true)
    }

    func testLongPathObjectUsesTheBasename() {
        let path = "/workspace/examples/probe-app/PhoneDSHProbe/Bot/BotChatModel.swift"
        let call = BotActivityEvidence.action(forToolNamed: "read",
                                              arguments: arguments("{\"file_path\":\"\(path)\"}"))
        XCTAssertEqual(call.category, .reading)
        XCTAssertEqual(call.text, "在翻文件 · BotChatModel.swift")
    }

    func testDisplayedURLObjectIsTheHostOnly() {
        let call = BotActivityEvidence.action(forToolNamed: "web_fetch", arguments: arguments(
            "{\"url\":\"https://user:password@localhost/report?token=secret&view=1\"}"))
        XCTAssertEqual(call.text, "在开网页 · localhost")
        XCTAssertEqual(BotActivityEvidence.displayHost(
            "https://github.com/launsion-boop/phone-dsh/pull/174"), "github.com")
    }

    func testEvidenceActionUsesIntentThenObjectThenLabel() {
        XCTAssertEqual(BotActivityEvidence.action(forToolNamed: "bash", arguments: arguments(
            "{\"description\":\"对比 #174 与 main 的冲突文件\",\"command\":\"git diff\"}")).text,
            "对比 #174 与 main 的冲突文件")
        XCTAssertEqual(BotActivityEvidence.action(forToolNamed: "bash",
            arguments: arguments("{\"command\":\"git status\"}")).text, "正在运行命令")
        XCTAssertEqual(BotActivityEvidence.action(forToolNamed: "mcp__phone__Task", arguments: arguments(
            "{\"task_title\":\"核对 #174 的合并状态\",\"prompt\":\"x\"}")).text,
            "核对 #174 的合并状态")
        XCTAssertEqual(BotActivityEvidence.action(forToolNamed: "mcp__phone__Task",
            arguments: arguments("{\"prompt\":\"x\"}")).text, "启动子任务")
        XCTAssertEqual(BotActivityEvidence.action(forToolNamed: "mcp__phone__MysteryTool",
            arguments: arguments("{\"description\":\"伪造进度\"}")).text, "等待操作结果")
    }

    /// v2.1: text-channel deltas accumulate within one step; the durable
    /// `assistant/message` replaces the accumulated text instead of being
    /// appended to it, so a single streamed fragment is never the sentence.
    func testSameStepTextDeltasAccumulateAndMessageReplacesThem() {
        let turn = sessionEvent("turn/start", seq: 1, time: 100)
        let step = sessionEvent("step/start", seq: 2, time: 150, data: ["step": .number(1)])
        let first = sessionEvent("assistant/stream", seq: 3, time: 160, data: [
            "step": .number(1), "channel": .string("text"), "text": .string("对比 #174 "),
        ])
        let second = sessionEvent("assistant/stream", seq: 4, time: 170, data: [
            "step": .number(1), "channel": .string("text"), "text": .string("与 main 的 README"),
        ])
        let message = sessionEvent("assistant/message", seq: 5, time: 180, data: [
            "step": .number(1),
            "message": .object(["content": .array([.object([
                "type": .string("text"), "text": .string("对比 #174 与 main 的 README"),
            ])])]),
        ])
        let call = sessionEvent("tool/call", seq: 6, time: 200, data: [
            "step": .number(1), "callId": .string("a"), "name": .string("read"),
            "arguments": .object(["file_path": .string("/dsh/workspace/README.md")]),
        ])
        let expected = "对比 #174 与 main 的 README"
        XCTAssertEqual(presentation([turn, step, first, second, call], now: 300).activity?.detail,
                       expected)
        XCTAssertEqual(presentation([turn, step, first, message, call], now: 300).activity?.detail,
                       expected)

        // A delta after the durable message starts a new segment for that step.
        let later = sessionEvent("assistant/stream", seq: 7, time: 195, data: [
            "step": .number(1), "channel": .string("text"), "text": .string("再看 B 的失败"),
        ])
        let laterCall = sessionEvent("tool/call", seq: 8, time: 300, data: [
            "step": .number(1), "callId": .string("b"), "name": .string("read"),
            "arguments": .object(["file_path": .string("/dsh/workspace/README.md")]),
        ])
        XCTAssertEqual(presentation([turn, step, message, later, laterCall], now: 400).activity?.detail,
                       "再看 B 的失败")

        // A new step clears the accumulated candidate.
        let nextStep = sessionEvent("step/start", seq: 8, time: 210, data: ["step": .number(2)])
        let nextCall = sessionEvent("tool/call", seq: 9, time: 220, data: [
            "step": .number(2), "callId": .string("b"), "name": .string("read"),
            "arguments": .object(["file_path": .string("/dsh/workspace/b.md")]),
        ])
        XCTAssertEqual(presentation([turn, step, first, message, nextStep, nextCall],
                                    now: 300).activity?.detail,
                       "在翻文件 · b.md")
    }

    /// Real live traffic: `streamStart`, several `textDelta` frames, then the
    /// session's own continuously numbered events. The accumulated public
    /// sentence must be complete, the real sequence must not be overtaken by
    /// synthetic events, and live must equal durable for the same events.
    func testLiveFramesKeepRealEventOrderAndTheAccumulatedSentence() {
        var projection = BotLiveFishProjection(botID: "main")
        func frame(_ type: String, seq: Int, time: Int64,
                   data: [String: JSONValue]) -> BotLiveFrame {
            .event(.object([
                "type": .string(type), "seq": .number(Double(seq)),
                "time": .number(Double(time)), "data": .object(data),
            ]))
        }
        projection.receive(frame("turn/start", seq: 1, time: 100,
                                 data: ["turn": .number(1)]), now: 100)
        projection.receive(frame("step/start", seq: 2, time: 150,
                                 data: ["turn": .number(1), "step": .number(1)]), now: 150)
        projection.receive(.streamStart, now: 160)
        for chunk in ["对比 #174 ", "与 main ", "的 README"] {
            projection.receive(.textDelta(chunk), now: 170)
        }
        // Token count must not add records or advance the live sequence.
        for _ in 0..<100 { projection.receive(.textDelta("…"), now: 175) }
        let syntheticSeqs = projection.records.compactMap { record -> Int? in
            guard record["type"]?.stringValue == "assistant/stream" else { return nil }
            return record["seq"]?.intValue
        }
        XCTAssertEqual(syntheticSeqs.count, 1)
        XCTAssertLessThanOrEqual(syntheticSeqs.first ?? .max, 3)
        XCTAssertLessThan(projection.records.count, 10)

        projection.receive(frame("tool/call", seq: 3, time: 200, data: [
            "turn": .number(1), "step": .number(1), "callId": .string("a"),
            "name": .string("read"),
            "arguments": .object(["file_path": .string("/workspace/README.md")]),
        ]), now: 200)
        projection.receive(frame("tool/result", seq: 4, time: 220, data: [
            "turn": .number(1), "step": .number(1),
            "message": .object(["toolCallId": .string("a"), "isError": .bool(false)]),
        ]), now: 220)
        let live = projection.presentation(now: 300).activity
        XCTAssertEqual(live?.detail, "对比 #174 与 main 的 README")
        XCTAssertEqual(live?.status, .thinking)
        XCTAssertEqual(live?.category, .reviewing)

        // The same logical events through the durable entry point: live and
        // durable agree, and the deltas read as one sentence, not a fragment.
        let durable = presentation([
            sessionEvent("turn/start", seq: 1, time: 100, data: ["turn": .number(1)]),
            sessionEvent("step/start", seq: 2, time: 150,
                         data: ["turn": .number(1), "step": .number(1)]),
            sessionEvent("assistant/stream", seq: 3, time: 160, data: [
                "step": .number(1), "channel": .string("text"), "text": .string("对比 #174 "),
            ]),
            sessionEvent("assistant/stream", seq: 4, time: 165, data: [
                "step": .number(1), "channel": .string("text"),
                "text": .string("与 main 的 README"),
            ]),
            sessionEvent("tool/call", seq: 5, time: 200, data: [
                "turn": .number(1), "step": .number(1), "callId": .string("a"),
                "name": .string("read"),
                "arguments": .object(["file_path": .string("/workspace/README.md")]),
            ]),
            sessionEvent("tool/result", seq: 6, time: 220, data: [
                "turn": .number(1), "step": .number(1),
                "message": .object(["toolCallId": .string("a"), "isError": .bool(false)]),
            ]),
        ], now: 300).activity
        XCTAssertEqual(durable, live)
    }

    /// v3.3: the optional `activity` argument of the five host-native work
    /// tools is the per-call model sentence for that call.
    func testActivityParameterWinsAcrossTheFiveWorkTools() {
        let cases: [(String, String, BotActivityCategory, String)] = [
            ("read", "{\"file_path\":\"/dsh/workspace/pr/174-notes.md\",\"activity\":\"核对 #174 的合并资料\"}",
             .reading, "核对 #174 的合并资料"),
            ("glob", "{\"pattern\":\"**/*.swift\",\"activity\":\"定位 #174 的改动文件\"}",
             .searching, "定位 #174 的改动文件"),
            ("grep", "{\"pattern\":\"conflict\",\"activity\":\"核对 #174 的冲突记录\"}",
             .searching, "核对 #174 的冲突记录"),
            ("web_search", "{\"query\":\"PR 174 merge status\",\"activity\":\"查 #174 的合并状态\"}",
             .searching, "查 #174 的合并状态"),
            ("web_fetch", "{\"url\":\"https://example.com/pr/174\",\"activity\":\"核对 #174 的合并页\"}",
             .browsing, "核对 #174 的合并页"),
        ]
        for (name, json, category, text) in cases {
            let phrase = BotActivityEvidence.action(forToolNamed: name, arguments: arguments(json))
            XCTAssertEqual(phrase.category, category, name)
            XCTAssertEqual(phrase.text, text, name)
        }
    }

    func testActivityParameterBeatsPublicTextAndShortens() {
        let turn = sessionEvent("turn/start", seq: 1, time: 100)
        let step = sessionEvent("step/start", seq: 2, time: 150, data: ["step": .number(1)])
        let publicText = sessionEvent("assistant/stream", seq: 3, time: 180, data: [
            "step": .number(1), "channel": .string("text"),
            "text": .string("对比 #174 与 main 的 README"),
        ])
        let call = sessionEvent("tool/call", seq: 4, time: 200, data: [
            "step": .number(1), "callId": .string("a"), "name": .string("read"),
            "arguments": .object([
                "file_path": .string("/dsh/workspace/README.md"),
                "activity": .string("核对 #174 的合并资料"),
            ]),
        ])
        XCTAssertEqual(presentation([turn, step, publicText, call], now: 300).activity?.detail,
                       "核对 #174 的合并资料")

        let longCall = sessionEvent("tool/call", seq: 5, time: 250, data: [
            "step": .number(1), "callId": .string("b"), "name": .string("read"),
            "arguments": .object([
                "file_path": .string("/dsh/workspace/pr/174-notes.md"),
                "activity": .string("核对 #174 与 main 的三个冲突文件，然后继续检查远端分支的合并状态"),
            ]),
        ])
        XCTAssertEqual(presentation([turn, step, longCall], now: 300).activity?.detail,
                       "核对 #174 与 main 的三个冲突文件")
    }

    func testActivityParameterFallsBackWhenUnusable() {
        let turn = sessionEvent("turn/start", seq: 1, time: 100)
        let step = sessionEvent("step/start", seq: 2, time: 150, data: ["step": .number(1)])
        let publicText = sessionEvent("assistant/stream", seq: 3, time: 180, data: [
            "step": .number(1), "channel": .string("text"), "text": .string("定位重连失败用例"),
        ])
        func call(seq: Int, id: String, activity: JSONValue?) -> BotDSHSessionEvent {
            var fields: [String: JSONValue] = ["file_path": .string("/dsh/workspace/report.md")]
            if let activity { fields["activity"] = activity }
            return sessionEvent("tool/call", seq: seq, time: 200, data: [
                "step": .number(1), "callId": .string(id), "name": .string("read"),
                "arguments": .object(fields),
            ])
        }
        // Empty and non-string values are unusable, so the same-step public
        // progress still wins over the object fallback.
        XCTAssertEqual(presentation([turn, step, publicText, call(seq: 4, id: "a", activity: .string(""))],
                                    now: 300).activity?.detail,
                       "定位重连失败用例")
        XCTAssertEqual(presentation([turn, step, publicText, call(seq: 5, id: "b", activity: .number(7))],
                                    now: 300).activity?.detail,
                       "定位重连失败用例")
        // Without any usable model sentence the short object fallback runs.
        XCTAssertEqual(presentation([turn, step, call(seq: 6, id: "c", activity: nil)],
                                    now: 300).activity?.detail,
                       "在翻文件 · report.md")
    }

    func testProductionEvidenceLabelsDoNotInventTimedProgress() {
        for category in [BotActivityCategory.thinking, .reviewing, .replying, .generic] {
            let current = BotActivityEvidence.normalized(activity("", category: category, startedAt: 0))
            var state = BotActivityLineState()
            state.receive(current, at: 0)
            let original = state.text
            XCTAssertFalse(original.isEmpty)
            XCTAssertNil(state.nextDeadline)
            for time: Int64 in [2_400, 4_800, 30_000] {
                state.tick(at: time)
                XCTAssertEqual(state.text, original, "No new event must not invent a new action")
            }
        }
    }

    func testEvidencePriorityKeepsApprovalAndStopAuthoritative() {
        let tool = BotActivity(status: .toolRunning, detail: "读取会议记录", category: .reading, startedAt: 100)
        XCTAssertEqual(BotActivityEvidence.lineActivity(factory: tool, streaming: true,
            pendingApprovals: 0, visible: true)?.detail, tool.detail)
        XCTAssertEqual(BotActivityEvidence.lineActivity(factory: tool, streaming: true,
            pendingApprovals: 1, visible: true)?.detail, "等你确认")
        XCTAssertNil(BotActivityEvidence.lineActivity(factory: tool, streaming: true,
            pendingApprovals: 0, visible: false))
        XCTAssertEqual(BotActivityEvidence.lineActivity(factory: nil, streaming: true,
            pendingApprovals: 0, visible: true)?.detail, "正在回复")
        XCTAssertEqual(BotActivityEvidence.lineActivity(factory: nil, streaming: false,
            pendingApprovals: 0, visible: true)?.detail, "等待响应")
    }

    // MARK: - 800 ms latest-wins

    func testUrgentDisplayReplacesAndClearsPendingProgress() {
        for urgent in [activity("等你确认", category: .waiting, startedAt: 0),
                       activity("读取失败，请重试", category: .reviewing, startedAt: 0)] {
            var state = BotActivityLineState()
            state.receive(activity("读取 #174 的笔记", category: .reading, startedAt: 1_000), at: 1_000)
            state.receive(activity("核对 main 的笔记", category: .reading, startedAt: 1_100), at: 1_100)
            XCTAssertEqual(state.text, "读取 #174 的笔记")
            state.receive(urgent, at: 1_150, immediately: true)
            XCTAssertEqual(state.text, urgent.detail)
            state.tick(at: 1_800)
            XCTAssertEqual(state.text, urgent.detail, "obsolete pending work must not reappear")
            XCTAssertNil(state.nextDeadline)
        }
    }

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

    /// Decodes the shared vector's raw events exactly as `live` does, so the
    /// durable entry point runs over the same values.
    private func sessionEvents(_ events: [JSONValue]) -> [BotDSHSessionEvent] {
        events.enumerated().compactMap { index, event in
            guard let type = event["type"]?.stringValue else { return nil }
            var data: [String: PhoneDSHBot.BotJSONValue] = [:]
            if case .object(let object)? = event["data"] { data = object }
            let time = Int64((event["time"]?.numberValue ?? 0).rounded())
            return BotDSHSessionEvent(type: type, seq: event["seq"]?.intValue ?? index,
                                      time: max(0, time), data: data)
        }
    }

    // MARK: - Header lifecycle

    func testHeaderWorkingUsesLivelyFishAndTurnActivity() {
        let reading = BotActivity(status: .toolRunning, detail: "在翻文件 · a.md", category: .reading)
        let presence = BotHeaderPresence.resolve(turnActive: true, lineActivity: reading,
                                                 pendingApprovals: 0, fishState: .working)
        XCTAssertEqual(presence.phase, .working)
        XCTAssertEqual(presence.line, reading)
        XCTAssertEqual(presence.motion, .lively)
        XCTAssertEqual(presence.workStyle, .reading)
        XCTAssertEqual(presence.fishState, .working)
        XCTAssertFalse(presence.lineIsQuiet)
        XCTAssertTrue(presence.showsActivityBubble)
    }

    func testHeaderWorkingBeforeFirstEventLooksBusy() {
        let thinking = BotActivity(status: .thinking, detail: "", category: .thinking)
        for idle in [BotFishLifecycle.idle, .sleeping, .standby] {
            let presence = BotHeaderPresence.resolve(turnActive: true, lineActivity: thinking,
                                                     pendingApprovals: 0, fishState: idle)
            XCTAssertEqual(presence.fishState, .thinking, "\(idle)")
        }
    }

    func testHeaderApprovalInsideTurnIsQuietAndAlerting() {
        let waiting = BotActivity(status: .thinking, detail: "", category: .waiting)
        let presence = BotHeaderPresence.resolve(turnActive: true, lineActivity: waiting,
                                                 pendingApprovals: 1, fishState: .alerting)
        XCTAssertEqual(presence.phase, .working)
        XCTAssertEqual(presence.fishState, .alerting)
        XCTAssertTrue(presence.lineIsQuiet)
        XCTAssertEqual(presence.workStyle, .generic)
        XCTAssertTrue(presence.showsActivityBubble)
    }

    func testHeaderPendingApprovalAfterTurnKeepsStaticLine() {
        let one = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                            pendingApprovals: 1, fishState: .alerting)
        XCTAssertEqual(one.phase, .waitingForYou)
        XCTAssertEqual(one.motion, .standard)
        XCTAssertTrue(one.lineIsQuiet)
        XCTAssertTrue(one.showsActivityBubble)
        var line = BotActivityLineState()
        line.receive(one.line, at: 0)
        XCTAssertEqual(line.text, "等你确认")
        XCTAssertNil(line.nextDeadline)

        let two = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                            pendingApprovals: 2, fishState: .alerting)
        line = BotActivityLineState()
        line.receive(two.line, at: 0)
        XCTAssertEqual(line.text, "2 项等你确认")
    }

    func testHeaderIdleHasNoLineAndStandardFish() {
        let presence = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                                 pendingApprovals: 0, fishState: .sleeping)
        XCTAssertEqual(presence.phase, .idle)
        XCTAssertNil(presence.line)
        XCTAssertEqual(presence.motion, .standard)
        XCTAssertEqual(presence.fishState, .sleeping)
        XCTAssertFalse(presence.showsActivityBubble)
    }

    /// The bottom bubble is the one activity surface: it is on for every
    /// phase that carries a sentence — a running turn, an approval after its
    /// turn, and a failure report — and off when the Bot is settled. The old
    /// working-only `showsTypingBubble` mapping is gone.
    func testActivityBubbleFollowsThePresenceLine() {
        // Thinking / awaiting reply / tool running / streaming all resolve
        // to `.working` and must carry the bubble and its sentence.
        let running: [(BotActivity, Int)] = [
            (BotActivity(status: .thinking, detail: "等待响应", category: .thinking), 0),
            (BotActivity(status: .thinking, detail: "", category: .waiting), 0),
            (BotActivity(status: .toolRunning, detail: "在翻文件 · a.md", category: .reading), 0),
            (BotActivity(status: .streaming, detail: "正在回复", category: .replying), 0),
        ]
        for (activity, approvals) in running {
            let presence = BotHeaderPresence.resolve(turnActive: true, lineActivity: activity,
                                                     pendingApprovals: approvals,
                                                     fishState: .thinking)
            XCTAssertEqual(presence.phase, .working, "\(activity.category)")
            XCTAssertNotNil(presence.line, "\(activity.category)")
            XCTAssertTrue(presence.showsActivityBubble, "\(activity.category)")
            XCTAssertFalse(presence.lineIsProblem, "\(activity.category)")
        }

        // The final assistant row: the turn is over and the sentence is gone,
        // so the bubble is gone too.
        let settled = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                                pendingApprovals: 0, fishState: .idle)
        XCTAssertNil(settled.line)
        XCTAssertFalse(settled.showsActivityBubble)

        // An error keeps its sentence for six seconds: the bubble shows it in
        // the danger tint, quietly (no glint).
        let failed = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                               pendingApprovals: 0, fishState: .sad,
                                               problem: "连接中断")
        XCTAssertNotNil(failed.line)
        XCTAssertTrue(failed.showsActivityBubble)
        XCTAssertTrue(failed.lineIsQuiet)
        XCTAssertTrue(failed.lineIsProblem)

        // Waiting for the user's approval after the turn: the bubble shows
        // the static「等你确认」sentence (resolved from the empty detail by
        // `BotActivityLineState`), no glint.
        let waiting = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                                pendingApprovals: 1, fishState: .alerting)
        XCTAssertNotNil(waiting.line)
        XCTAssertTrue(waiting.showsActivityBubble)
        XCTAssertTrue(waiting.lineIsQuiet)
        XCTAssertFalse(waiting.lineIsProblem)
    }

    func testHeaderProblemWinsAndJoinsLinesQuietly() {
        let thinking = BotActivity(status: .thinking, category: .thinking)
        let presence = BotHeaderPresence.resolve(turnActive: true, lineActivity: thinking,
                                                 pendingApprovals: 1, fishState: .sad,
                                                 problem: "附件「a」未附加：超限\n 附件「b」未附加：超限 \n")
        XCTAssertEqual(presence.phase, .problem)
        XCTAssertEqual(presence.line?.detail, "附件「a」未附加：超限；附件「b」未附加：超限")
        XCTAssertTrue(presence.lineIsQuiet)
        XCTAssertTrue(presence.lineIsProblem)
        XCTAssertTrue(presence.showsActivityBubble)
        XCTAssertEqual(presence.motion, .standard)
        XCTAssertEqual(presence.fishState, .sad)
    }

    func testHeaderBlankProblemIsIgnored() {
        let presence = BotHeaderPresence.resolve(turnActive: false, lineActivity: nil,
                                                 pendingApprovals: 0, fishState: .idle,
                                                 problem: " \n ")
        XCTAssertEqual(presence.phase, .idle)
        XCTAssertNil(presence.line)
        XCTAssertFalse(presence.lineIsProblem)
        XCTAssertFalse(presence.showsActivityBubble)
    }

    private func activity(_ detail: String, category: BotActivityCategory,
                          startedAt: Int64) -> BotActivity {
        BotActivity(status: .toolRunning, detail: detail, category: category,
                    startedAt: startedAt)
    }
}
