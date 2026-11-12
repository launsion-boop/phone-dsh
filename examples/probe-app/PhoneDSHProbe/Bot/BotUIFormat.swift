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

    /// The one human shape of the read-only presence bridge line. The
    /// internal failure code stays in the diagnostic log; the page only says
    /// what happened and when. It deliberately does not claim the connection
    /// recovered, because the host clears the record on success instead.
    static func bridgeFailure(atMilliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(atMilliseconds) / 1_000)
        return "最近一次与 App 的连接校验失败 · \(dateTime(date, now: now))"
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

// MARK: - Routine page/card presentation (appended for ui-rou)

extension BotUIFormat {
    /// `Asia/Shanghai` → `上海时间（UTC+8）`. The raw IANA identifier stays in
    /// the routine detail surface; an unknown zone falls back to
    /// ``unknownValue`` instead of leaking the identifier into the main row.
    static func routineTimeZone(_ rawValue: String) -> String {
        let identifier = trimmed(rawValue)
        guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else {
            return unknownValue
        }
        let cityName: String
        switch key(identifier) {
        case "asia/shanghai", "prc", "asia/chongqing", "asia/harbin": cityName = "上海时间"
        case "asia/tokyo", "japan": cityName = "东京时间"
        case "asia/seoul", "rok": cityName = "首尔时间"
        case "asia/singapore": cityName = "新加坡时间"
        case "asia/hong_kong", "hongkong": cityName = "香港时间"
        case "asia/taipei": cityName = "台北时间"
        case "asia/macau": cityName = "澳门时间"
        case "asia/bangkok": cityName = "曼谷时间"
        case "asia/jakarta": cityName = "雅加达时间"
        case "asia/kolkata", "asia/calcutta": cityName = "印度时间"
        case "asia/dubai": cityName = "迪拜时间"
        case "europe/london", "gb": cityName = "伦敦时间"
        case "europe/paris": cityName = "巴黎时间"
        case "europe/berlin": cityName = "柏林时间"
        case "america/new_york": cityName = "纽约时间"
        case "america/los_angeles": cityName = "洛杉矶时间"
        case "australia/sydney": cityName = "悉尼时间"
        case "utc", "gmt", "etc/utc", "etc/gmt": cityName = "协调世界时"
        default: cityName = identifier == TimeZone.current.identifier ? "当前时区" : ""
        }
        let offset = utcOffset(zone.secondsFromGMT(for: Date()))
        return cityName.isEmpty ? "\(offset) 时区" : "\(cityName)（\(offset)）"
    }

    /// `succeeded` + text → the result text; without text, a human status
    /// sentence. Raw error/status values stay in the detail surface.
    static func routineRunResult(status: String, text: String, error: String?) -> String {
        let result = trimmed(text)
        if !result.isEmpty { return result }
        switch key(status) {
        case "succeeded": return "已完成。"
        case "failed": return "上次运行失败。"
        case "timed-out": return "上次运行超时，已结束。"
        case "cancelled": return "上次运行已取消。"
        case "needs-reconciliation": return "上次运行结果未确认。"
        case "started": return "正在运行。"
        case "scheduled": return "等待下次触发。"
        case "waiting-approval": return "等待审批。"
        default:
            return trimmed(error ?? "").isEmpty ? "还没有运行结果。" : "上次运行没有完成。"
        }
    }

    /// The effect record (`routine.deliver · … · unknown-outcome`) becomes one
    /// human sentence. The raw record is kept in the routine detail surface.
    static func routineEffectSummary(operation: String, reason: String?) -> String {
        let operationKey = key(operation)
        let reasonKey = key(reason ?? "")
        if operationKey == "routine.deliver" || operationKey.hasSuffix(".deliver") {
            switch reasonKey {
            case "generation-conflict":
                return "已尝试发送提醒，但发送记录被覆盖，结果未确认。"
            case "receiver-mismatch":
                return "已尝试发送提醒，但接收方不一致，结果未确认。"
            default:
                return "已尝试发送提醒，送达结果未确认。"
            }
        }
        return "已尝试执行这次操作，结果未确认。"
    }

    /// Raw effect reference for the detail disclosure (operation · target ·
    /// reason), never shown in the main routine row.
    static func routineEffectReference(operation: String, target: String, reason: String?) -> String {
        "\(trimmed(operation)) · \(trimmed(target)) · \(trimmed(reason ?? "unknown"))"
    }

    /// `投递结果未知：连接在确认前中断` → `连接在确认前中断。`. Known internal
    /// tokens or an all-English error fall back to a neutral sentence; the raw
    /// error stays in the detail disclosure.
    static func routineReconciliationReason(_ rawValue: String?) -> String? {
        guard var reason = rawValue.map(trimmed), !reason.isEmpty else { return nil }
        let prefixes = [
            "投递结果未知：", "投递结果未知:", "執行結果未知，需要確認：",
            "执行结果未知，需要确认：", "执行结果未知：", "结果未知：", "未知原因：",
        ]
        for prefix in prefixes where reason.hasPrefix(prefix) {
            reason.removeFirst(prefix.count)
            break
        }
        reason = trimmed(reason)
        guard !reason.isEmpty else { return nil }
        let asciiOnly = reason.unicodeScalars.allSatisfy(\.isASCII)
            && reason.contains(where: { $0.isLetter })
        if asciiOnly || routineFreeTextNeedsDetail(reason) {
            return "这次运行在确认结果前中断。"
        }
        if let last = reason.last, "。！？.!?".contains(last) { return reason }
        return reason + "。"
    }

    /// Free text written by the routine creator (constraints / completion
    /// criteria) that carries internal tool names, bracketed prompt tokens,
    /// record references or backticked snippets. Such text is not paraphrased:
    /// the main row shows a short factual pointer and the raw text moves to the
    /// detail disclosure.
    static func routineFreeTextNeedsDetail(_ rawValue: String) -> Bool {
        let value = trimmed(rawValue)
        guard !value.isEmpty else { return false }
        if value.contains("`") || value.contains("://") { return true }
        if value.range(of: #"\[[^\]\n]{1,40}\]"#, options: .regularExpression) != nil {
            return true
        }
        if value.range(of: #"\b[A-Z][a-z]+(?:[A-Z][a-z0-9]+)+\b"#,
                       options: .regularExpression) != nil {
            return true
        }
        let lowered = value.lowercased()
        let knownTokens = [
            "sendtouser", "sendtoagent", "updateroutine", "listroutines",
            "createteammate", "readmemory", "writememory", "recallmemory",
            "forgetmemory", "awaittask", "stopsubagent", "record://",
        ]
        return knownTokens.contains { lowered.contains($0) }
    }

    /// Detail-only creator reference: human origin/authorization plus the raw
    /// ids the main row never prints.
    static func routineCreatorDetail(origin: String, authorization: String,
                                     references: [String]) -> String {
        let originLabel: String
        switch key(origin) {
        case "user": originLabel = "用户回合"
        case "agent": originLabel = "其他 Bot"
        case "routine": originLabel = "例行任务"
        case "task", "task-wake": originLabel = "子任务"
        case "held": originLabel = "后台回合"
        default: originLabel = "其他来源"
        }
        let authorizationLabel = key(authorization) == "user-confirmed"
            ? "你确认后创建" : "由你在对话中创建"
        var parts = ["来源：\(originLabel)", "授权：\(authorizationLabel)"]
        let ids = references.map(trimmed).filter { !$0.isEmpty }
        if !ids.isEmpty { parts.append("引用：\(ids.joined(separator: "、"))") }
        return parts.joined(separator: "；")
    }

    /// The scheduler's free-form context may carry a raw delivery mode in old
    /// rows (`held · 非紧急`). Drop those raw tokens and render the remaining
    /// sentences on their own line instead of concatenating them under the
    /// title.
    static func routineAutomationContext(_ rawValue: String) -> String? {
        let value = trimmed(rawValue)
        guard !value.isEmpty else { return nil }
        let rawDeliveryTokens: Set<String> = [
            "held", "interrupt", "queued", "存入待处理", "立即打断", "立即提醒",
            "下次聊天时送达",
        ]
        let parts = value.split(separator: "·")
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty && !rawDeliveryTokens.contains(key($0)) }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private static func utcOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3_600
        let minutes = (magnitude % 3_600) / 60
        if minutes == 0 { return "UTC\(sign)\(hours)" }
        return "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}

// MARK: - Grants and approvals (appended by ui-grc)

extension BotUIFormat {
    /// Resource summary for one grant/approval operation. Network resources
    /// keep only the host (`curl https://api.example.test/*` →
    /// `api.example.test`); every other value delegates to the path-aware
    /// ``grantResourceSummary(_:)``. The full value survives in the detail view.
    static func grantResourceSummary(_ resource: String, operation: String) -> String {
        let value = trimmed(resource)
        guard !value.isEmpty else { return unknownValue }
        let normalizedOperation = key(operation)
        if normalizedOperation == "network-egress" || normalizedOperation.hasPrefix("egress.") {
            if let host = urlHost(in: value) { return host }
            if key(value).hasPrefix("host=") { return grantResourceSummary(value) }
            return "网络资源"
        }
        return grantResourceSummary(value)
    }

    /// Human label for one approval record decision. `scope` only matters for
    /// an allow; `status` wins for timeout/expiry/cancellation because those
    /// are recorded as a deny with a separate status.
    static func approvalDecision(_ decision: String, scope: String? = nil,
                                 status: String? = nil) -> String {
        switch key(status ?? "") {
        case "expired": return "已过期（视为拒绝）"
        case "timed-out", "timed_out", "timedout", "timeout": return "已超时（视为拒绝）"
        case "cancelled", "canceled": return "已取消"
        default: break
        }
        let normalizedScope = key(scope ?? "")
        switch key(decision) {
        case "allowonce", "allow-once", "allow":
            switch normalizedScope {
            case "session": return "本次会话允许"
            case "until": return "总是允许"
            default: return "允许一次"
            }
        case "always", "allowed":
            switch normalizedScope {
            case "session": return "本次会话允许"
            case "once": return "允许一次"
            default: return "总是允许"
            }
        case "deny", "denied": return "拒绝"
        default: return unknownValue
        }
    }

    private static func urlHost(in value: String) -> String? {
        guard let range = value.range(of: #"https?://[^\s/]+"#,
                                      options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return URL(string: String(value[range]))?.host
    }
}
