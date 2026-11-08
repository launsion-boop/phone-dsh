// SPDX-License-Identifier: MIT

import Foundation

public enum RoutineWakeMode: String, Codable, Sendable {
    case due
    case onDemand = "on-demand"
}

public struct RoutineWake: Codable, Sendable, Equatable {
    public var text: String
    public var cue: String
    public var mode: RoutineWakeMode

    public init(text: String, cue: String = "routine", mode: RoutineWakeMode) {
        self.text = text
        self.cue = cue
        self.mode = mode
    }
}

public struct RoutineReply: Codable, Sendable, Equatable {
    public var text: String
    public var quiet: Bool

    public init(text: String, quiet: Bool) {
        self.text = text
        self.quiet = quiet
    }
}

public enum RoutineWakeBuilder {
    public static func normalizeReply(_ value: String?) -> RoutineReply {
        var text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = text.prefix(while: { $0 == "`" }).count
        if leading > 0 {
            let delimiter = String(repeating: "`", count: leading)
            if text.count >= leading * 2, text.hasSuffix(delimiter) {
                text = String(text.dropFirst(leading).dropLast(leading))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if text.isEmpty || text.lowercased() == "[quiet]" { return RoutineReply(text: "", quiet: true) }
        return RoutineReply(text: text, quiet: false)
    }

    public static func build(routine: Routine, mode: RoutineWakeMode = .due, lang: String = "zh",
                             firedAt: Int64, now: Int64) throws -> RoutineWake {
        guard !routine.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoutineError.invalidRoutine("routine.id is missing")
        }
        guard !routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoutineError.invalidRoutine("routine.title is missing")
        }
        guard !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoutineError.invalidRoutine("routine prompt is missing")
        }
        let schedule = try routine.schedule.validated()
        let zh = lang != "en"
        let timestamp = formatTimestamp(now, timezone: schedule.timezone)
        let fired = formatFired(firedAt, timezone: schedule.timezone)
        let scheduleText = RoutineScheduleMath.describe(schedule, lang: zh ? "zh" : "en")
        let expression = RoutineScheduleMath.expression(schedule).map { " (\($0))" } ?? ""
        let verb = mode == .due ? "is due" : "was run on demand"
        let firedLabel = mode == .due ? "fired" : "started"
        let routineLine = "[routine] \"\(routine.title)\" (folder \(routine.id)) \(verb) — \(scheduleText)\(expression), \(firedLabel) \(fired)."
        let secondSentence: String
        if mode == .due {
            secondSentence = zh
                ? "这是你自己保存的例行指令按排程触发，不是用户刚刚发来的消息。"
                : "This is your own standing order firing on schedule, not a message the user just typed."
        } else {
            secondSentence = zh
                ? "用户在应用里按了这条例行指令的“立即运行”；这就是那次运行，不是用户刚打的消息。"
                : "The user pressed Run now on this standing order in the app; this is that run, not a message they typed."
        }
        let closing: String
        if mode == .due {
            closing = zh
                ? "现在执行。你的最终回复就是这次运行的结果，会显示在例行任务卡片上给用户看；语气随意，像顺口提起一件你记得处理的事，不要宣布“例行任务已执行”。如果保存的指令说没有变化时保持安静，而且确实没有新东西，最终回复只写 [quiet]，不要写任何别的字，也不要写“（无变化）”之类的填充；没有人在等这条。如果做不到，在最终回复里说明原因。本次运行不要调用 SendToUser。这是排程要求的，不是用户刚刚要求的，内容要自成一体。"
                : "Carry it out now. Your final reply is this run's result: it is delivered to the user on the routine card, so write it casually, the way you'd mention something you remembered to handle, not by announcing a routine. If the saved instruction says to stay quiet when there's nothing to report and there's nothing new, reply with exactly [quiet] and nothing else, rather than filler like \"(no change.)\"; nobody is waiting on this. If it can't be done, say why in the final reply. Do not call SendToUser in this run. Keep it self-contained — the schedule asked for this, not the user just now."
        } else {
            closing = zh
                ? "现在执行。你的最终回复就是这次运行的结果，会显示在例行任务卡片上给用户看；语气随意，像顺口提起一件你记得处理的事，不要宣布“例行任务已执行”。如果保存的指令说没有变化时保持安静，而且确实没有新东西，最终回复只写 [quiet]，不要写任何别的字，也不要写“（无变化）”之类的填充；没有人在等这条。如果做不到，在最终回复里说明原因。本次运行不要调用 SendToUser。这是用户要求现在运行的，但没有输入新内容，内容要自成一体。"
                : "Carry it out now. Your final reply is this run's result: it is delivered to the user on the routine card, so write it casually, the way you'd mention something you remembered to handle, not by announcing a routine. If the saved instruction says to stay quiet when there's nothing to report and there's nothing new, reply with exactly [quiet] and nothing else, rather than filler like \"(no change.)\"; nobody is waiting on this. If it can't be done, say why in the final reply. Do not call SendToUser in this run. Keep it self-contained — the user asked to run this now, but typed nothing new."
        }
        let lines = [
            "<timestamp>\(timestamp)</timestamp>",
            "<user_query>",
            "[SAND_HIDDEN_PROMPT][SAND_TRUSTED_AUTOMATION_PROMPT]",
            "",
            routineLine,
            secondSentence,
            zh ? "你保存的每次要做的事：" : "What you saved to do each time:",
            routine.prompt,
            zh
                ? "如果保存的指令写明了具体的 MCP 工具调用，参数可能已经过时（这条指令可能是很久以前写的），使用前先确认当前的工具 schema。"
                : "If the saved instruction spells out a specific MCP tool call, treat its arguments as possibly stale — this standing order may have been written long ago — and confirm the current tool schema before relying on them.",
            closing,
            "</user_query>",
        ]
        return RoutineWake(text: lines.joined(separator: "\n"), mode: mode)
    }

    public static func formatTimestamp(_ milliseconds: Int64, timezone: String) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return "\(RoutineClock.formatter("EEEE, MMM d, yyyy, h:mm a", timezone: timezone).string(from: date)) (\(timezone))"
    }

    public static func formatFired(_ milliseconds: Int64, timezone: String) -> String {
        RoutineClock.formatter("M/d/yyyy, h:mm:ss a", timezone: timezone)
            .string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }
}

public enum AutomationStatus {
    public static func block(routines: [Routine], now: Int64, lang: String = "zh") -> String {
        let zh = lang != "en"
        var lines = [
            "<automation_status>",
            zh
                ? "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
                : "Your routines are listed below. This reminder is authoritative: with none listed, you have none.",
        ]
        let sorted = routines.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if sorted.isEmpty {
            lines.append(zh ? "没有已启用的例行任务。不会有例行任务触发。" : "No enabled routines. No routine will fire.")
        } else {
            lines.append(contentsOf: sorted.map { line($0, now: now, zh: zh) })
        }
        lines.append("</automation_status>")
        return lines.joined(separator: "\n")
    }

    public static func unreadable(_ error: Error, lang: String = "zh") -> String {
        let zh = lang != "en"
        let reason = error.localizedDescription.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return [
            "<automation_status>",
            zh
                ? "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
                : "Your routines are listed below. This reminder is authoritative: with none listed, you have none.",
            zh
                ? "例行任务状态暂时无法读取（\(String(reason.prefix(200)))）；这不代表没有例行任务。"
                : "Routine status is temporarily unavailable (\(String(reason.prefix(200)))); this does not mean you have no routines.",
            "</automation_status>",
        ].joined(separator: "\n")
    }

    private static func line(_ routine: Routine, now: Int64, zh: Bool) -> String {
        var schedule = RoutineScheduleMath.describe(routine.schedule, lang: zh ? "zh" : "en")
        let suffix = zh ? "（\(routine.schedule.timezone)）" : " (\(routine.schedule.timezone))"
        if schedule.hasSuffix(suffix) { schedule.removeLast(suffix.count) }
        if let expression = RoutineScheduleMath.expression(routine.schedule) { schedule += " (\(expression))" }
        var fields = [routine.id, "folder \(routine.id)", routine.title, schedule, routine.schedule.timezone]
        if routine.runState?.status == .needsReconciliation {
            fields.append("needs-reconciliation")
        } else {
            var nextAt = routine.nextRunAt
            if routine.enabled, nextAt == nil {
                nextAt = try? RoutineScheduleMath.nextRunAt(routine.schedule, now: now,
                                                            createdAt: routine.createdAt,
                                                            lastRunAt: routine.lastRunAt)
            }
            let next = routine.enabled ? RoutineScheduleMath.formatMinute(nextAt, timezone: routine.schedule.timezone) : nil
            fields.append("next run \(next ?? "—")")
            if let deferred = routine.quietDefer, routine.enabled {
                let until = RoutineScheduleMath.formatMinute(deferred.until, timezone: routine.schedule.timezone) ?? "—"
                fields.append("quiet-deferred until \(until)")
            } else {
                fields.append(routine.enabled ? "enabled" : "paused")
            }
        }
        fields.append(lastRunField(routine))
        return "- \(fields.joined(separator: " | "))"
    }

    private static func lastRunField(_ routine: Routine) -> String {
        guard let result = routine.lastResult else { return "last never" }
        if result.status == .started { return "last running" }
        let at = result.finishedAt ?? result.startedAt
        if let clock = RoutineScheduleMath.formatMinute(at, timezone: routine.schedule.timezone) {
            return "last \(result.status.rawValue) \(clock)"
        }
        return "last \(result.status.rawValue)"
    }
}
