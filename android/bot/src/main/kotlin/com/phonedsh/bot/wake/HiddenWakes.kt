// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

/**
 * The hidden parent-wake prompts (D8 §8;
 * `MCP/BotDSHRemoteRuntime.swift:869-881`, `:1126-1132`, `:1298-1302`).
 *
 * The task id, title, status and result excerpt are host-inserted structure, so
 * every non-host field goes through [HeldMessages.escapedHeldField] before it
 * reaches the prompt. The prompt request id is derived from the task id
 * ([BotTurnOrigin.taskSettledRequestId] / [BotTurnOrigin.taskInterruptedRequestId])
 * so a replay reuses it instead of opening a second turn.
 */
object HiddenWakes {
    fun taskSettled(
        taskId: String,
        title: String,
        status: String,
        excerpt: String,
        lang: String = "zh",
    ): String {
        val body = "${HeldMessages.escapedHeldField(title)} | " +
            "${HeldMessages.escapedHeldField(status)} | " +
            "${HeldMessages.escapedHeldField(taskId)}\n" +
            HeldMessages.escapedHeldField(
                com.phonedsh.bot.routines.RoutineJson.prefixCodePoints(excerpt, 1_200),
            )
        return "[SAND_HIDDEN_PROMPT][subagent]\n$body"
    }

    fun taskInterrupted(taskId: String, title: String, lang: String = "zh"): String {
        val zh = lang != "en"
        val body = "${HeldMessages.escapedHeldField(title)} | interrupted | " +
            "${HeldMessages.escapedHeldField(taskId)}\n" +
            if (zh) {
                "App 重启时中断了这个任务，结果还不完整。"
            } else {
                "The app restarted while this task was running; its result is incomplete."
            }
        return "[SAND_HIDDEN_PROMPT][subagent]\n$body"
    }

    fun taskDenied(
        taskId: String,
        title: String,
        error: String,
        approvalId: String? = null,
    ): Prompt {
        val body = "${HeldMessages.escapedHeldField(title)} | denied | " +
            "${HeldMessages.escapedHeldField(taskId)}\n" +
            "用户没有批准待确认的操作（${HeldMessages.escapedHeldField(error)}）。" +
            "任务已经结束，没有执行。请如实告诉用户这次任务被拒绝了，不要把它说成已完成。"
        val requestId = if (approvalId == null) {
            BotTurnOrigin.taskSettledRequestId(taskId)
        } else {
            "task-settled:$taskId:approval:$approvalId"
        }
        return Prompt(text = "[SAND_HIDDEN_PROMPT][subagent]\n$body", requestId = requestId)
    }

    /** A prompt plus the request id the replay must reuse. */
    data class Prompt(val text: String, val requestId: String)
}
