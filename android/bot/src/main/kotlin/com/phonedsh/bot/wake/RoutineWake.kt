// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.bot.routines.Routine
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineJson
import com.phonedsh.bot.routines.RoutineRunStatus
import com.phonedsh.bot.routines.RoutineScheduleMath
import com.phonedsh.bot.routines.RoutineTime

enum class RoutineWakeMode(val rawValue: String) {
    DUE("due"),
    ON_DEMAND("on-demand"),
    ;

    companion object {
        fun from(value: String?): RoutineWakeMode = when (value) {
            "due", null -> DUE
            "on-demand" -> ON_DEMAND
            else -> throw RoutineError.InvalidRoutine("unknown routine wake mode: $value")
        }
    }
}

/** The hidden-wake payload (`BotWakeRoutineVector.wake`). */
data class RoutineWake(
    val text: String,
    val cue: String = "routine",
    val mode: RoutineWakeMode,
)

/** The model's final reply after `[quiet]` normalization. */
data class RoutineReply(val text: String, val quiet: Boolean)

/**
 * The hidden routine prompt and automation-status block
 * (`Sources/PhoneDSHBot/Wake/RoutineWake.swift`; `golden/wake-routine.json`).
 *
 * The prompt is a host-inserted structured frame, so the routine title/prompt
 * are placed into it verbatim (they are the user's own saved instruction), and
 * the run is declared as not a user message. `<automation_status>` is the
 * authoritative routine list for the model.
 */
object RoutineWakeBuilder {
    fun normalizeReply(value: String?): RoutineReply {
        var text = (value ?: "").trim()
        val leading = text.takeWhile { it == '`' }.length
        if (leading > 0) {
            val delimiter = "`".repeat(leading)
            if (text.length >= leading * 2 && text.endsWith(delimiter)) {
                text = text.drop(leading).dropLast(leading).trim()
            }
        }
        if (text.isEmpty() || text.lowercase() == "[quiet]") {
            return RoutineReply(text = "", quiet = true)
        }
        return RoutineReply(text = text, quiet = false)
    }

    fun build(
        routine: Routine,
        mode: RoutineWakeMode = RoutineWakeMode.DUE,
        lang: String = "zh",
        firedAt: Long,
        now: Long,
    ): RoutineWake {
        if (routine.id.trim().isEmpty()) {
            throw RoutineError.InvalidRoutine("routine.id is missing")
        }
        if (routine.title.trim().isEmpty()) {
            throw RoutineError.InvalidRoutine("routine.title is missing")
        }
        if (routine.prompt.trim().isEmpty()) {
            throw RoutineError.InvalidRoutine("routine prompt is missing")
        }
        val schedule = routine.schedule.validated()
        val zh = lang != "en"
        val timestamp = formatTimestamp(now, schedule.timezone)
        val fired = formatFired(firedAt, schedule.timezone)
        val scheduleText = RoutineScheduleMath.describe(schedule, lang = if (zh) "zh" else "en")
        val expression = RoutineScheduleMath.expression(schedule)?.let { " ($it)" } ?: ""
        val verb = if (mode == RoutineWakeMode.DUE) "is due" else "was run on demand"
        val firedLabel = if (mode == RoutineWakeMode.DUE) "fired" else "started"
        val routineLine = "[routine] \"${routine.title}\" (folder ${routine.id}) $verb — " +
            "$scheduleText$expression, $firedLabel $fired."
        val secondSentence = if (mode == RoutineWakeMode.DUE) {
            if (zh) {
                "这是你自己保存的例行指令按排程触发，不是用户刚刚发来的消息。"
            } else {
                "This is your own standing order firing on schedule, not a message the user just typed."
            }
        } else {
            if (zh) {
                "用户在应用里按了这条例行指令的“立即运行”；这就是那次运行，不是用户刚打的消息。"
            } else {
                "The user pressed Run now on this standing order in the app; this is that run, " +
                    "not a message they typed."
            }
        }
        val closing = if (mode == RoutineWakeMode.DUE) {
            if (zh) {
                "现在执行。你的最终回复就是这次运行的结果，会显示在例行任务卡片上给用户看；" +
                    "语气随意，像顺口提起一件你记得处理的事，不要宣布“例行任务已执行”。" +
                    "如果保存的指令说没有变化时保持安静，而且确实没有新东西，最终回复只写 [quiet]，" +
                    "不要写任何别的字，也不要写“（无变化）”之类的填充；没有人在等这条。" +
                    "如果做不到，在最终回复里说明原因。本次运行不要调用 SendToUser。" +
                    "这是排程要求的，不是用户刚刚要求的，内容要自成一体。"
            } else {
                "Carry it out now. Your final reply is this run's result: it is delivered to the user " +
                    "on the routine card, so write it casually, the way you'd mention something you " +
                    "remembered to handle, not by announcing a routine. If the saved instruction says " +
                    "to stay quiet when there's nothing to report and there's nothing new, reply with " +
                    "exactly [quiet] and nothing else, rather than filler like \"(no change.)\"; nobody " +
                    "is waiting on this. If it can't be done, say why in the final reply. Do not call " +
                    "SendToUser in this run. Keep it self-contained — the schedule asked for this, not " +
                    "the user just now."
            }
        } else {
            if (zh) {
                "现在执行。你的最终回复就是这次运行的结果，会显示在例行任务卡片上给用户看；" +
                    "语气随意，像顺口提起一件你记得处理的事，不要宣布“例行任务已执行”。" +
                    "如果保存的指令说没有变化时保持安静，而且确实没有新东西，最终回复只写 [quiet]，" +
                    "不要写任何别的字，也不要写“（无变化）”之类的填充；没有人在等这条。" +
                    "如果做不到，在最终回复里说明原因。本次运行不要调用 SendToUser。" +
                    "这是用户要求现在运行的，但没有输入新内容，内容要自成一体。"
            } else {
                "Carry it out now. Your final reply is this run's result: it is delivered to the user " +
                    "on the routine card, so write it casually, the way you'd mention something you " +
                    "remembered to handle, not by announcing a routine. If the saved instruction says " +
                    "to stay quiet when there's nothing to report and there's nothing new, reply with " +
                    "exactly [quiet] and nothing else, rather than filler like \"(no change.)\"; nobody " +
                    "is waiting on this. If it can't be done, say why in the final reply. Do not call " +
                    "SendToUser in this run. Keep it self-contained — the user asked to run this now, " +
                    "but typed nothing new."
            }
        }
        val lines = listOf(
            "<timestamp>$timestamp</timestamp>",
            "<user_query>",
            "[SAND_HIDDEN_PROMPT][SAND_TRUSTED_AUTOMATION_PROMPT]",
            "",
            routineLine,
            secondSentence,
            if (zh) "你保存的每次要做的事：" else "What you saved to do each time:",
            routine.prompt,
            if (zh) {
                "如果保存的指令写明了具体的 MCP 工具调用，参数可能已经过时" +
                    "（这条指令可能是很久以前写的），使用前先确认当前的工具 schema。"
            } else {
                "If the saved instruction spells out a specific MCP tool call, treat its arguments as " +
                    "possibly stale — this standing order may have been written long ago — and confirm " +
                    "the current tool schema before relying on them."
            },
            closing,
            "</user_query>",
        )
        return RoutineWake(text = lines.joinToString("\n"), mode = mode)
    }

    fun formatTimestamp(milliseconds: Long, timezone: String): String =
        RoutineTime.formatTimestamp(milliseconds, timezone)

    fun formatFired(milliseconds: Long, timezone: String): String =
        RoutineTime.formatFired(milliseconds, timezone)
}

/** The `<automation_status>` block and its unreadable fallback. */
object AutomationStatus {
    fun block(routines: List<Routine>, now: Long, lang: String = "zh"): String {
        val zh = lang != "en"
        val lines = ArrayList<String>()
        lines += "<automation_status>"
        lines += if (zh) {
            "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
        } else {
            "Your routines are listed below. This reminder is authoritative: " +
                "with none listed, you have none."
        }
        val sorted = routines.sortedWith(compareBy({ it.createdAt }, { it.id }))
        if (sorted.isEmpty()) {
            lines += if (zh) {
                "没有已启用的例行任务。不会有例行任务触发。"
            } else {
                "No enabled routines. No routine will fire."
            }
        } else {
            lines += sorted.map { line(it, now, zh) }
        }
        lines += "</automation_status>"
        return lines.joinToString("\n")
    }

    fun unreadable(error: Throwable, lang: String = "zh"): String {
        val zh = lang != "en"
        val reason = RoutineJson.collapseWhitespace(error.message ?: "unknown error")
        val lines = listOf(
            "<automation_status>",
            if (zh) {
                "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
            } else {
                "Your routines are listed below. This reminder is authoritative: " +
                    "with none listed, you have none."
            },
            if (zh) {
                "例行任务状态暂时无法读取（${RoutineJson.prefixCodePoints(reason, 200)}）；" +
                    "这不代表没有例行任务。"
            } else {
                "Routine status is temporarily unavailable " +
                    "(${RoutineJson.prefixCodePoints(reason, 200)}); this does not mean you have no routines."
            },
            "</automation_status>",
        )
        return lines.joinToString("\n")
    }

    private fun line(routine: Routine, now: Long, zh: Boolean): String {
        var schedule = RoutineScheduleMath.describe(routine.schedule, lang = if (zh) "zh" else "en")
        val suffix = if (zh) "（${routine.schedule.timezone}）" else " (${routine.schedule.timezone})"
        if (schedule.endsWith(suffix)) schedule = schedule.dropLast(suffix.length)
        RoutineScheduleMath.expression(routine.schedule)?.let { schedule += " ($it)" }
        val fields = ArrayList<String>()
        fields += routine.id
        fields += "folder ${routine.id}"
        fields += routine.title
        fields += schedule
        fields += routine.schedule.timezone
        if (routine.runState?.status == RoutineRunStatus.NEEDS_RECONCILIATION) {
            fields += "needs-reconciliation"
        } else {
            var nextAt = routine.nextRunAt
            if (routine.enabled && nextAt == null) {
                nextAt = runCatching {
                    RoutineScheduleMath.nextRunAt(
                        routine.schedule, now = now,
                        createdAt = routine.createdAt, lastRunAt = routine.lastRunAt,
                    )
                }.getOrNull()
            }
            val next = if (routine.enabled) {
                RoutineTime.formatMinute(nextAt, routine.schedule.timezone) ?: "—"
            } else {
                null
            }
            fields += "next run ${next ?: "—"}"
            val deferred = routine.quietDefer
            if (deferred != null && routine.enabled) {
                val until = RoutineTime.formatMinute(deferred.until, routine.schedule.timezone) ?: "—"
                fields += "quiet-deferred until $until"
            } else {
                fields += if (routine.enabled) "enabled" else "paused"
            }
        }
        fields += lastRunField(routine)
        return "- ${fields.joinToString(" | ")}"
    }

    private fun lastRunField(routine: Routine): String {
        val result = routine.lastResult ?: return "last never"
        if (result.status == RoutineRunStatus.STARTED) return "last running"
        val at = result.finishedAt ?: result.startedAt
        val clock = RoutineTime.formatMinute(at, routine.schedule.timezone)
        return if (clock != null) {
            "last ${result.status.rawValue} $clock"
        } else {
            "last ${result.status.rawValue}"
        }
    }
}
