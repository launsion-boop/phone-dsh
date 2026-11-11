// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

/// What the Bot is doing, in the vocabulary the status line and the fish
/// avatar share. `rawValue` is part of that seam: the fish unit maps these
/// names onto its own work style, so they must not be renamed.
enum BotActivityCategory: String, Equatable, Sendable, CaseIterable {
    case thinking
    case reading
    case searching
    case browsing
    case running
    case writing
    case memory
    case messaging
    case reviewing
    case generic
}

/// One resolved tool status: the category always follows the tool name (the
/// fish avatar uses it), while `text` may be the model's own `description`.
struct BotToolActivityPhrase: Equatable, Sendable {
    var category: BotActivityCategory
    /// Empty means "no concrete text": the live line rotates the category's
    /// generic phrases and the drawer shows its primary phrase.
    var text: String
}

/// Pure tool → category/phrase table plus the timing state machine for the
/// single activity line. No SwiftUI, no clock: callers pass `now` in
/// milliseconds so the whole file is deterministic in unit tests.
enum BotActivityPhrases {
    typealias RuntimeJSON = PhoneDSHBot.BotJSONValue

    // MARK: - Tool table

    private struct Rule {
        var category: BotActivityCategory
        var phrase: String
        /// Argument keys tried in order for the `· target` suffix.
        var targetKeys: [String] = []
        /// Render an URL target as its host instead of its last path segment.
        var targetIsURL = false
        /// Use only the first element when the target is a string array.
        var targetArray = false
    }

    /// Every tool the Bot can actually call: the DSH native allowlist from
    /// `plugins/bot-runtime/src/prompt/assemble.ts`, the `mcp__phone__` catalog
    /// in `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`, the device discovery
    /// tools, and the native Android/Bluetooth tools forwarded through the
    /// same `mcp__phone__` namespace. Keys are the bare, lowercased tool name.
    private static let rules: [String: Rule] = [
        // DSH native tools (PHONE_NATIVE_TOOLS).
        "bash": Rule(category: .running, phrase: "跑个命令"),
        "read": Rule(category: .reading, phrase: "在翻文件",
                     targetKeys: ["path", "file_path", "filePath"]),
        "write": Rule(category: .writing, phrase: "在写文件",
                      targetKeys: ["path", "file_path", "filePath"]),
        "edit": Rule(category: .writing, phrase: "在改文件",
                     targetKeys: ["path", "file_path", "filePath"]),
        "glob": Rule(category: .searching, phrase: "在找文件",
                     targetKeys: ["pattern", "path"]),
        "grep": Rule(category: .searching, phrase: "在搜内容",
                     targetKeys: ["pattern", "include", "path"]),
        "web_search": Rule(category: .searching, phrase: "在网上搜",
                           targetKeys: ["query", "queries"], targetArray: true),
        "web_fetch": Rule(category: .browsing, phrase: "在开网页",
                          targetKeys: ["url"], targetIsURL: true),
        "job_list": Rule(category: .running, phrase: "看看后台"),
        "job_output": Rule(category: .running, phrase: "等个结果",
                           targetKeys: ["job_id"]),
        "job_kill": Rule(category: .running, phrase: "停掉任务",
                         targetKeys: ["job_id"]),
        "todo_write": Rule(category: .writing, phrase: "整理待办"),
        "create_goal": Rule(category: .writing, phrase: "定个目标",
                            targetKeys: ["objective"]),
        "get_goal": Rule(category: .reading, phrase: "看看目标"),
        "update_goal": Rule(category: .writing, phrase: "更新目标",
                            targetKeys: ["objective"]),

        // Bot card, team, memory and routine tools (mcp__phone__*).
        "sendtouser": Rule(category: .messaging, phrase: "整理回复"),
        "send_to_user": Rule(category: .messaging, phrase: "整理回复"),
        "ask_user": Rule(category: .messaging, phrase: "想问问你",
                         targetKeys: ["question"]),
        "show_next_steps": Rule(category: .messaging, phrase: "给你选项"),
        "show_attachment": Rule(category: .messaging, phrase: "送上附件",
                                targetKeys: ["path"]),
        "show_document": Rule(category: .reading, phrase: "打开文档",
                              targetKeys: ["title", "path"]),
        "show_progress": Rule(category: .writing, phrase: "更新进度",
                              targetKeys: ["title"]),
        "show_checklist": Rule(category: .writing, phrase: "列个清单",
                               targetKeys: ["title"]),
        "show_link": Rule(category: .messaging, phrase: "放上链接",
                          targetKeys: ["url", "links"], targetIsURL: true),
        "updatememory": Rule(category: .memory, phrase: "在记笔记",
                             targetKeys: ["path"]),
        "readmemory": Rule(category: .memory, phrase: "在翻记忆",
                           targetKeys: ["path"]),
        "recallmemory": Rule(category: .memory, phrase: "回想一下",
                             targetKeys: ["query"]),
        "task": Rule(category: .messaging, phrase: "委派任务",
                     targetKeys: ["task_title", "agent_id"]),
        "awaittask": Rule(category: .running, phrase: "等任务结果",
                          targetKeys: ["task_id"]),
        "stopsubagent": Rule(category: .running, phrase: "停掉任务",
                             targetKeys: ["task_id"]),
        "updateroutine": Rule(category: .writing, phrase: "改例行任务",
                              targetKeys: ["title", "routine_id"]),
        "listroutines": Rule(category: .reading, phrase: "看看例行"),
        "requestapproval": Rule(category: .messaging, phrase: "请你确认",
                                targetKeys: ["action", "detail"]),
        "sendtoagent": Rule(category: .messaging, phrase: "给队友发消息",
                            targetKeys: ["bot_name", "name", "agent_id"]),
        "createteammate": Rule(category: .messaging, phrase: "创建新队友",
                               targetKeys: ["name"]),
        "botvolatilecontext": Rule(category: .reading, phrase: "读读上下文"),

        // Device discovery (BotDeviceToolProvider).
        "bluetooth.scan": Rule(category: .searching, phrase: "找找设备"),
        "network.browse": Rule(category: .searching, phrase: "看看网络"),

        // Native Android tools forwarded through mcp__phone__.
        "android_connect": Rule(category: .running, phrase: "连接手机"),
        "android_status": Rule(category: .reading, phrase: "看看手机"),
        "android_device_info": Rule(category: .reading, phrase: "看设备信息"),
        "android_shell": Rule(category: .running, phrase: "跑条命令"),
        "android_screenshot": Rule(category: .reading, phrase: "看看屏幕"),
        "android_ui_dump": Rule(category: .reading, phrase: "看看界面"),
        "android_tap": Rule(category: .running, phrase: "点点屏幕"),
        "android_swipe": Rule(category: .running, phrase: "滑一下屏幕"),
        "android_key": Rule(category: .running, phrase: "按一下键"),
        "android_input_text": Rule(category: .running, phrase: "输入文字"),
        "android_launch_app": Rule(category: .running, phrase: "打开应用",
                                   targetKeys: ["package", "packageName"]),
        "android_force_stop": Rule(category: .running, phrase: "关掉应用",
                                   targetKeys: ["package", "packageName"]),
        "android_clear_app_data": Rule(category: .running, phrase: "清应用数据",
                                       targetKeys: ["package", "packageName"]),
        "android_set_app_enabled": Rule(category: .running, phrase: "启用或停用",
                                        targetKeys: ["package", "packageName"]),
        "android_install_apk": Rule(category: .running, phrase: "安装应用",
                                    targetKeys: ["package", "packageName", "path"]),
        "android_install_existing_app": Rule(category: .running, phrase: "恢复应用",
                                             targetKeys: ["package", "packageName"]),
        "android_uninstall_app": Rule(category: .running, phrase: "卸载应用",
                                      targetKeys: ["package", "packageName"]),
        "android_app_permission": Rule(category: .running, phrase: "改应用权限",
                                       targetKeys: ["package", "permission"]),
        "android_list_packages": Rule(category: .searching, phrase: "列一下应用",
                                      targetKeys: ["kind", "query"]),
        "android_package_info": Rule(category: .reading, phrase: "看看应用信息",
                                     targetKeys: ["package", "packageName"]),
        "android_list_users": Rule(category: .reading, phrase: "看看用户"),
        "android_open_uri": Rule(category: .browsing, phrase: "打开链接",
                                 targetKeys: ["uri", "url"], targetIsURL: true),
        "android_logcat": Rule(category: .reading, phrase: "翻翻日志"),
        "android_list_apk_files": Rule(category: .searching, phrase: "找找安装包",
                                       targetKeys: ["directory"]),
        "android_delete_apk_file": Rule(category: .running, phrase: "删个安装包",
                                        targetKeys: ["path"]),
        "android_command_help": Rule(category: .reading, phrase: "看看命令帮助"),

        // Native Bluetooth tools forwarded through mcp__phone__.
        "ble_devices": Rule(category: .searching, phrase: "找找设备"),
        "ble_read": Rule(category: .reading, phrase: "读设备数据",
                         targetKeys: ["profile", "device_id"]),
        "ble_alert": Rule(category: .running, phrase: "给设备提醒",
                          targetKeys: ["device_id"]),
        "ble_link_tools": Rule(category: .reading, phrase: "看看设备能力"),
        "ble_link_call": Rule(category: .running, phrase: "调用设备",
                              targetKeys: ["name"]),
        "ble_link_result": Rule(category: .reading, phrase: "取设备结果",
                                targetKeys: ["request_id"]),
    ]

    private static let genericRule = Rule(category: .generic, phrase: "处理中")

    /// Resolve one `tool/call`. A model-written `description`/`summary`/`label`
    /// always wins over the category phrase; the category still follows the
    /// tool name so the fish avatar keeps its reading/searching/… style.
    static func toolActivity(forToolNamed rawName: String,
                             arguments: [String: RuntimeJSON]) -> BotToolActivityPhrase {
        let rule = rules[bareToolName(rawName).lowercased()] ?? genericRule
        if let described = cleanedModelText(modelText(arguments)) {
            return BotToolActivityPhrase(category: rule.category, text: described)
        }
        // Unknown tools (and known tools deliberately left generic) rotate the
        // generic phrases instead of leaking a raw tool name.
        guard rule.category != .generic else {
            return BotToolActivityPhrase(category: .generic, text: "")
        }
        let target = targetText(rule: rule, arguments: arguments)
        return BotToolActivityPhrase(category: rule.category,
                                     text: target.isEmpty ? rule.phrase : "\(rule.phrase) · \(target)")
    }

    /// The category alone, for callers that only need the avatar style.
    static func category(forToolNamed rawName: String) -> BotActivityCategory {
        (rules[bareToolName(rawName).lowercased()] ?? genericRule).category
    }

    /// `mcp__phone__ReadMemory` → `ReadMemory`; plain names pass through.
    static func bareToolName(_ rawName: String) -> String {
        let parts = rawName.components(separatedBy: "__")
        guard rawName.hasPrefix("mcp__"), parts.count > 2 else { return rawName }
        return parts.dropFirst(2).joined(separator: "__")
    }

    // MARK: - Model-written text

    private static func modelText(_ arguments: [String: RuntimeJSON]) -> String? {
        for key in ["description", "summary", "label"] {
            guard let value = arguments[key]?.stringValue else { continue }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    /// Trim whitespace and sentence-final punctuation, then cap the status
    /// text at 20 characters including the ellipsis.
    static func cleanedModelText(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let punctuation = CharacterSet(charactersIn: "。！？!?；;，,、.…")
        while let scalar = text.unicodeScalars.last, punctuation.contains(scalar) {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > 20 { return String(text.prefix(19)) + "…" }
        return text
    }

    // MARK: - Targets

    private static func targetText(rule: Rule, arguments: [String: RuntimeJSON]) -> String {
        for key in rule.targetKeys {
            guard let value = arguments[key] else { continue }
            if rule.targetArray, case .array(let values) = value {
                if let first = values.compactMap({ $0.stringValue }).first(where: { !$0.isEmpty }) {
                    return shortTarget(first)
                }
                continue
            }
            guard let text = value.stringValue, !text.isEmpty else { continue }
            if rule.targetIsURL, let host = urlHost(text) { return shortTarget(host) }
            return shortTarget(text)
        }
        return ""
    }

    /// The target shown after `·`: the path's last component, or the URL host,
    /// capped at 42 characters like the existing status detail.
    static func shortTarget(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .filter { !$0.isEmpty }.last ?? text
        return base.count > 42 ? "\(base.prefix(39))…" : base
    }

    static func urlHost(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: candidate)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Reviewing text may carry the finished call's target; without one it is
    /// empty so the live line rotates the reviewing phrases.
    static func reviewingText(forToolNamed rawName: String,
                              arguments: [String: RuntimeJSON]) -> String {
        let rule = rules[bareToolName(rawName).lowercased()] ?? genericRule
        guard rule.category != .generic else { return "" }
        let target = targetText(rule: rule, arguments: arguments)
        guard !target.isEmpty else { return "" }
        return "\(primaryPhrase(for: .reviewing)) · \(target)"
    }

    // MARK: - Generic phrases

    /// Phrases used only when the activity has no model description and no
    /// concrete tool target. Thinking/reviewing/generic each have variants;
    /// every other category is a single static phrase.
    static func rotationPhrases(for activity: BotActivity) -> [String] {
        guard activity.detail.isEmpty else { return [primaryPhrase(for: activity.category)] }
        switch activity.category {
        case .thinking: return ["思考中…", "整理思绪…", "准备下一步…"]
        case .reviewing: return ["看看结果…", "检查一下…", "整理结论…"]
        case .generic: return ["处理中…", "正在处理…", "马上就好…"]
        default: return [primaryPhrase(for: activity.category)]
        }
    }

    /// First/only phrase for a category; the drawer uses it when the activity
    /// has no concrete detail.
    static func primaryPhrase(for category: BotActivityCategory) -> String {
        switch category {
        case .thinking: return "思考中"
        case .reading: return "在翻文件"
        case .searching: return "在搜内容"
        case .browsing: return "在开网页"
        case .running: return "处理中"
        case .writing: return "在写文件"
        case .memory: return "在翻记忆"
        case .messaging: return "整理回复"
        case .reviewing: return "看看结果"
        case .generic: return "处理中"
        }
    }

    // MARK: - Fish work style

    /// The App-only `.lively` working sub-style for a category. `BotFishView`
    /// ignores it unless the lifecycle is `.working`; it never becomes a
    /// lifecycle state or enters the FishDirector schema.
    static func workStyle(for category: BotActivityCategory) -> BotFishWorkStyle {
        switch category {
        case .reading, .memory: return .reading
        case .searching, .browsing: return .searching
        case .running: return .running
        case .writing: return .writing
        case .thinking, .reviewing, .messaging, .generic: return .generic
        }
    }

    // MARK: - 60s suffix

    /// `0` before a full minute, then the whole minutes for the same activity.
    static func sustainedMinutes(for activity: BotActivity, now: Int64) -> Int {
        guard activity.startedAt > 0, now >= activity.startedAt else { return 0 }
        let elapsed = now - activity.startedAt
        guard elapsed >= BotActivityLineState.minuteMillis else { return 0 }
        return max(1, Int(elapsed / BotActivityLineState.minuteMillis))
    }
}

/// Timing/selection machine for the one activity line. Each displayed
/// activity is visible for at least 800 ms; newer activities replace each
/// other only as the latest one, and switch when that window closes. Only
/// activities without a concrete detail rotate (every 2.4 s) through the
/// category's generic phrases; the same activity appends `· N 分钟` once it
/// has been running for a full minute.
struct BotActivityLineState: Equatable {
    static let minimumVisibleMillis: Int64 = 800
    static let rotationIntervalMillis: Int64 = 2_400
    static let minuteMillis: Int64 = 60_000

    private(set) var activity: BotActivity?
    private(set) var text = ""
    /// The next time either the pending latest activity becomes visible or
    /// the current text changes; `nil` means no scheduled change.
    private(set) var nextDeadline: Int64?

    private var displayedAt: Int64 = 0
    private var phraseStart = 0
    private var pending: BotActivity?
    private var pendingAt: Int64?
    private var pendingStart = 0

    static var now: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    /// Feed the current factory activity. Passing nil hides the line at once
    /// (turn end/streaming); a different activity arriving inside the 800 ms
    /// window is remembered as the latest pending one.
    mutating func receive(_ next: BotActivity?, at now: Int64,
                          randomStart: (Int) -> Int = { count in
                              count <= 1 ? 0 : Int.random(in: 0..<count)
                          }) {
        guard let next else {
            activity = nil
            text = ""
            nextDeadline = nil
            displayedAt = 0
            pending = nil
            pendingAt = nil
            return
        }
        if activity == next {
            // The same phase was projected again; drop an obsolete pending
            // switch and refresh the minute suffix/rotation.
            pending = nil
            pendingAt = nil
            refresh(at: now)
            return
        }
        if activity == nil || now - displayedAt >= Self.minimumVisibleMillis {
            show(next, at: now, startIndex: Self.startIndex(for: next, randomStart: randomStart))
        } else {
            pending = next
            pendingAt = displayedAt + Self.minimumVisibleMillis
            pendingStart = Self.startIndex(for: next, randomStart: randomStart)
            updateDeadline(now: now)
        }
    }

    /// Advance the clock. Call at `nextDeadline` (or any later time).
    mutating func tick(at now: Int64) {
        if let pending, let pendingAt, now >= pendingAt {
            self.pending = nil
            self.pendingAt = nil
            show(pending, at: now, startIndex: pendingStart)
            return
        }
        refresh(at: now)
    }

    private mutating func show(_ next: BotActivity, at now: Int64, startIndex: Int) {
        activity = next
        displayedAt = now
        phraseStart = startIndex
        pending = nil
        pendingAt = nil
        refresh(at: now)
    }

    private mutating func refresh(at now: Int64) {
        guard let activity else {
            text = ""
            nextDeadline = nil
            return
        }
        var base: String
        if !activity.detail.isEmpty {
            base = activity.detail
        } else {
            let phrases = BotActivityPhrases.rotationPhrases(for: activity)
            if phrases.isEmpty {
                base = BotActivityPhrases.primaryPhrase(for: activity.category)
            } else if phrases.count == 1 {
                base = phrases[0]
            } else {
                let elapsed = max(0, now - displayedAt)
                let step = Int(elapsed / Self.rotationIntervalMillis)
                base = phrases[(phraseStart + step) % phrases.count]
            }
        }
        let minutes = BotActivityPhrases.sustainedMinutes(for: activity, now: now)
        text = minutes > 0 ? "\(base) · \(minutes) 分钟" : base
        updateDeadline(now: now)
    }

    private mutating func updateDeadline(now: Int64) {
        var deadlines: [Int64] = []
        if let pendingAt, pending != nil {
            deadlines.append(max(now, pendingAt))
        }
        if let activity {
            if activity.detail.isEmpty {
                let phrases = BotActivityPhrases.rotationPhrases(for: activity)
                if phrases.count > 1 {
                    let elapsed = max(0, now - displayedAt)
                    let step = elapsed / Self.rotationIntervalMillis
                    deadlines.append(displayedAt + (step + 1) * Self.rotationIntervalMillis)
                }
            }
            if activity.startedAt > 0 {
                deadlines.append(Self.nextMinuteBoundary(for: activity.startedAt, now: now))
            }
        }
        nextDeadline = deadlines.filter { $0 > now }.min()
    }

    private static func startIndex(for activity: BotActivity,
                                   randomStart: (Int) -> Int) -> Int {
        let count = BotActivityPhrases.rotationPhrases(for: activity).count
        guard count > 1 else { return 0 }
        return randomStart(count) % count
    }

    private static func nextMinuteBoundary(for startedAt: Int64, now: Int64) -> Int64 {
        if now < startedAt + minuteMillis { return startedAt + minuteMillis }
        let minutes = (now - startedAt) / minuteMillis
        return startedAt + (minutes + 1) * minuteMillis
    }
}
