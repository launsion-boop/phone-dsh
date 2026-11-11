// SPDX-License-Identifier: MIT

import Foundation

/// Shared display formatting for the Bot surfaces.
///
/// Dates are always Simplified Chinese (`zh_CN`) with a 24-hour clock and the
/// current time zone, so an English system locale never leaks
/// `Oct 9, 2025 at 4:58 PM` into the Chinese UI.
///
/// Raw host values (routine delivery, creator references, grant scopes,
/// operation ids, workspace paths) are mapped here instead of at each call
/// site. Every mapper falls back to ``unknownValue``; callers keep the raw
/// value in the detail/accessibility surface instead of printing it.
enum BotUIFormat {
    /// Display fallback for an enum-like value this build does not know.
    static let unknownValue = "其他"

    /// Fixed locale shared by every Bot date/time surface (including
    /// `DatePicker` labels): Simplified Chinese.
    static let locale = Locale(identifier: "zh_CN")

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = locale
        value.timeZone = TimeZone.current
        return value
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter()
        value.locale = locale
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone.current
        value.dateFormat = format
        return value
    }

    private static let timeFormatter = formatter("HH:mm")
    private static let monthDayFormatter = formatter("M月d日")
    private static let yearMonthDayFormatter = formatter("yyyy年M月d日")

    // MARK: - Date and time

    /// `今天 22:12`, `10月9日 22:12` (this year), or
    /// `2025年10月9日 22:12` (other years). Fixed zh_CN, 24-hour clock.
    static func dateTime(_ date: Date, now: Date = Date()) -> String {
        "\(dayPart(date, now: now)) \(time(date))"
    }

    /// `今天`, `10月9日` (this year), or `2025年10月9日` (other years).
    static func date(_ date: Date, now: Date = Date()) -> String {
        dayPart(date, now: now)
    }

    /// `HH:mm`.
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// `M月d日` without a year, used by the drawer's compact relative time.
    static func monthDay(_ date: Date) -> String {
        monthDayFormatter.string(from: date)
    }

    /// Drawer-style relative time: `刚刚`, `5 分钟前`, `3 小时前`, then
    /// `M月d日` for anything older than a day.
    static func relativeTime(milliseconds: Int64, now: Date = Date()) -> String {
        guard milliseconds > 0 else { return "还没有消息" }
        let value = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let seconds = now.timeIntervalSince(value)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return monthDay(value)
    }

    private static func dayPart(_ date: Date, now: Date) -> String {
        let value = calendar
        if value.isDate(date, inSameDayAs: now) { return "今天" }
        if value.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDayFormatter.string(from: date)
        }
        return yearMonthDayFormatter.string(from: date)
    }

    // MARK: - Numbers

    /// `9999`, `1.2 万`, `1 亿`. One decimal place for 万/亿, trailing `.0`
    /// removed.
    static func compactCount(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = value.magnitude
        if magnitude >= 100_000_000 {
            return sign + compactDecimal(Double(magnitude) / 100_000_000) + " 亿"
        }
        if magnitude >= 10_000 {
            return sign + compactDecimal(Double(magnitude) / 10_000) + " 万"
        }
        return "\(value)"
    }

    /// `25%`. The ratio is clamped to 0…100%; a non-positive total renders
    /// `—` instead of dividing by zero.
    static func percent(used: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        let ratio = min(100, max(0, Double(used) / Double(total) * 100))
        return "\(Int(ratio.rounded()))%"
    }

    private static func compactDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Routines

    /// `held` → `下次聊天时送达`, `interrupt` → `立即提醒`. The current
    /// production adapter's Chinese labels and the raw enum values both work;
    /// anything else falls back to ``unknownValue``.
    static func routineDelivery(_ rawValue: String) -> String {
        switch key(rawValue) {
        case "held", "存入待处理", "queued", "下次聊天时送达":
            return "下次聊天时送达"
        case "interrupt", "立即打断", "立即提醒":
            return "立即提醒"
        default:
            return unknownValue
        }
    }

    /// Human-readable creator label from `RoutineCreator`'s fields. IDs
    /// (`rpcId`/`turnId`/`sessionId`) never appear here.
    static func routineCreator(origin: String, authorization: String) -> String {
        let confirmed = ["user-confirmed", "经用户确认"].contains(key(authorization))
        let source: String
        switch key(origin) {
        case "user": source = "你"
        case "agent": source = "其他 Bot"
        case "routine": source = "例行任务"
        case "task", "task-wake": source = "子任务"
        case "held": source = "后台回合"
        default: source = "其他来源"
        }
        let separator = source == "其他 Bot" ? " " : ""
        if confirmed {
            if source == "你" || source == "其他来源" { return "你确认后创建" }
            return "你确认后，由\(source)\(separator)创建"
        }
        switch source {
        case "你": return "由你在对话中创建"
        case "其他来源": return "其他来源"
        default: return "由\(source)\(separator)创建"
        }
    }

    /// Maps the flattened `creator` string the UI currently carries
    /// (`用户回合 · <id>` / `经用户确认 · <id>`) without showing the id.
    static func routineCreator(_ rawValue: String) -> String {
        let value = key(rawValue)
        guard !value.isEmpty else { return unknownValue }
        if value.contains("经用户确认") || value.contains("user-confirmed") {
            return "你确认后创建"
        }
        if value.contains("用户回合") || value.contains("user-turn") || value.contains("对话中") {
            return "由你在对话中创建"
        }
        if value.contains("其他 bot") || value.contains("bot") || value.contains("agent") {
            return "由其他 Bot 创建"
        }
        if value.contains("例行任务") || value.contains("routine") {
            return "由例行任务创建"
        }
        if value.contains("子任务") || value.contains("task") {
            return "由子任务创建"
        }
        if value.contains("后台") || value.contains("held") {
            return "由后台回合创建"
        }
        return "其他来源"
    }

    // MARK: - Grants

    /// `until` → `长期有效`, or `有效至 2025年11月8日` when an expiry is
    /// known; `session` → `本次会话`; `once` → `仅本次`.
    static func grantScope(_ rawValue: String, expiresAt: Date? = nil) -> String {
        switch key(rawValue) {
        case "until":
            guard let expiresAt else { return "长期有效" }
            return "有效至 \(date(expiresAt))"
        case "session": return "本次会话"
        case "once": return "仅本次"
        default: return unknownValue
        }
    }

    /// `approval-card` → `来自审批卡`, `approval-standing` → `来自常设审批`.
    static func grantSource(_ rawValue: String) -> String {
        switch key(rawValue) {
        case "approval-card": return "来自审批卡"
        case "approval-standing": return "来自常设审批"
        case "approval": return "来自审批"
        default: return unknownValue
        }
    }

    /// Human title for one grant/approval operation id. Covers the file,
    /// egress, memory, DShBot, BLE, device, UI and approval-pattern operations
    /// the Bot package can emit.
    static func grantOperationTitle(_ rawValue: String) -> String {
        let value = key(rawValue)
        if value.hasPrefix("egress.") { return "访问网络" }
        if value.hasPrefix("ui.") { return "显示卡片" }
        switch value {
        case "write.file", "file.write": return "写入文件"
        case "file.edit": return "编辑文件"
        case "network-egress": return "访问网络"
        case "rm-destructive", "find-delete": return "删除文件"
        case "git-destructive": return "丢弃改动"
        case "dshbot.task": return "启动子任务"
        case "dshbot.awaittask": return "等待子任务"
        case "dshbot.stopsubagent": return "停止子任务"
        case "dshbot.sendtouser": return "发送消息"
        case "dshbot.sendtoagent": return "给其他 Bot 发消息"
        case "dshbot.createteammate": return "创建协作 Bot"
        case "dshbot.updateroutine": return "修改例行任务"
        case "dshbot.listroutines": return "查看例行任务"
        case "memory.read": return "读取记忆"
        case "memory.recall": return "回想记忆"
        case "memory.sort": return "整理记忆"
        case "memory.write": return "写入记忆"
        case "memory.forget": return "删除记忆"
        case "ble.devices": return "发现蓝牙设备"
        case "ble.read": return "读取设备数据"
        case "ble.link_tools": return "查看设备工具"
        case "ble.link_result": return "读取设备结果"
        case "ble.alert": return "提醒设备"
        case "ble.link_call": return "调用设备工具"
        case "device.discovery.read": return "发现设备"
        case "context.volatile": return "访问会话上下文"
        case "routine.authorize": return "确认例行任务"
        case "teammate.authorize": return "确认协作 Bot"
        case "sandbox-escalation": return "提升执行权限"
        case "approval.weak-action": return "请求审批"
        case "tool.unclassified": return "执行工具"
        case "*", "all": return "所有操作"
        default: return unknownValue
        }
    }

    /// One-line summary for a grant/approval resource. `dir=` paths become a
    /// folder summary, `host=` values keep the host, and workspace paths lose
    /// their absolute prefix. Free-form values (for example a recorded
    /// command) are returned trimmed; detail views may still show the full
    /// value.
    static func grantResourceSummary(_ resource: String) -> String {
        let value = trimmed(resource)
        guard !value.isEmpty else { return unknownValue }
        let lower = value.lowercased()
        if lower.hasPrefix("dir=") { return pathSummary(value, isDirectory: true) }
        if lower.hasPrefix("host=") {
            let host = trimmed(String(value.dropFirst(5)))
            return host.isEmpty ? unknownValue : host
        }
        if value.contains("/.dshbot/agents/") || value.hasPrefix("/") || value.contains("/**") {
            return pathSummary(value)
        }
        return value
    }

    // MARK: - Paths

    /// Drops the host workspace prefix so a path can be shown relative to the
    /// Bot's workspace: `…/.dshbot/agents/main/reports/**` → `reports/**`.
    static func workspaceRelativePath(_ path: String) -> String {
        var value = trimmed(path)
        if value.lowercased().hasPrefix("dir=") { value = String(value.dropFirst(4)) }
        if let marker = value.range(of: "/.dshbot/agents/") {
            let remainder = value[marker.upperBound...]
            guard let slash = remainder.firstIndex(of: "/") else { return "" }
            return String(remainder[remainder.index(after: slash)...])
        }
        if let marker = value.range(of: "/dsh/workspace/") {
            return String(value[marker.upperBound...])
        }
        return value
    }

    /// `…/reports/**` → `reports 文件夹`; `…/reports/2026` (directory) →
    /// `reports/2026 文件夹`; `…/agent/profile.md` → `profile.md`. The full
    /// path stays in the detail view.
    static func pathSummary(_ path: String, isDirectory: Bool = false) -> String {
        var value = trimmed(path)
        var directory = isDirectory
        if value.lowercased().hasPrefix("dir=") {
            value = String(value.dropFirst(4))
            directory = true
        }
        var relative = workspaceRelativePath(value)
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty, relative != "." else { return "Bot 工作区" }
        if relative.hasSuffix("/**") {
            relative = String(relative.dropLast(3))
            directory = true
        }
        if relative.hasSuffix("/") {
            relative.removeLast()
            directory = true
        }
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let last = parts.last else { return "Bot 工作区" }
        if directory { return "\(parts.joined(separator: "/")) 文件夹" }
        return last
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ value: String) -> String {
        trimmed(value).lowercased()
    }

    // MARK: - Memory

    /// Human label for a memory document author. `kind` and `source` are the
    /// `BotMemoryAuthorKind` / `BotMemorySourceKind` raw values; unknown values
    /// map to ``unknownValue`` so a raw enum never reaches the main view.
    ///
    /// Added by the ui-memi unit: appended at the end of the file so the shared
    /// formatter layer stays append-only.
    static func memoryAuthor(kind: String, source: String? = nil) -> String {
        let author = key(kind)
        let origin = source.map(key)
        switch author {
        case "chat":
            switch origin {
            case "user-turn": return "对话中的你"
            case "agent-message": return "这个 Bot"
            case "hidden-wake": return "后台对话"
            case "routine": return "例行任务"
            case "task": return "子任务"
            case "maintenance": return "维护整理"
            default: return "对话"
            }
        case "task": return "子任务"
        case "routine": return "例行任务"
        case "team": return "其他 Bot"
        case "proactive": return "主动提醒"
        case "watchdog": return "后台检查"
        case "maintainer": return "维护整理"
        case "ui": return "页面操作"
        case "migration": return "迁移"
        case "system": return "系统"
        default: return unknownValue
        }
    }
}
