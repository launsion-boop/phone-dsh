// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * The frozen turn-origin classification from `spec/bot/v1/README.md` §4.1.
 * The only input is the DSH `user/message.data.source.rpcId` minted by the
 * host; message text never participates.
 */
enum class BotTurnOriginKind(val rawValue: String) {
    USER("user"),
    HELD("held"),
    AGENT("agent"),
    ROUTINE("routine"),
    TASK("task"),
    TASK_WAKE("task-wake"),
    UNKNOWN("unknown"),
    ;

    companion object {
        fun from(value: String?): BotTurnOriginKind =
            entries.firstOrNull { it.rawValue == value } ?: UNKNOWN
    }
}

/** What the memory layer may treat the turn as (v2 §1.3–§1.5). */
enum class BotMemorySourceKind(val rawValue: String) {
    USER_TURN("user-turn"),
    AGENT_MESSAGE("agent-message"),
    ROUTINE("routine"),
    TASK("task"),
    HIDDEN_WAKE("hidden-wake"),
}

/**
 * One resolved turn origin. `hidden`, `held` and `memorySource` are derived
 * from `kind`, never re-derived from message text.
 *
 * A bare prefix or a whitespace-only payload is `unknown`, not the prefix's
 * origin: a request id is only classified when the host actually appended a
 * payload. This matches every invalid case in
 * `spec/bot/v1/golden/turn-origin.phone.json`.
 */
class BotTurnOrigin private constructor(
    val rpcId: String?,
    val kind: BotTurnOriginKind,
) {
    val hidden: Boolean
        get() = when (kind) {
            BotTurnOriginKind.ROUTINE, BotTurnOriginKind.TASK, BotTurnOriginKind.TASK_WAKE -> true
            BotTurnOriginKind.USER, BotTurnOriginKind.HELD,
            BotTurnOriginKind.AGENT, BotTurnOriginKind.UNKNOWN,
            -> false
        }

    val held: Boolean get() = kind == BotTurnOriginKind.HELD

    val memorySource: BotMemorySourceKind
        get() = when (kind) {
            BotTurnOriginKind.USER -> BotMemorySourceKind.USER_TURN
            BotTurnOriginKind.HELD, BotTurnOriginKind.AGENT, BotTurnOriginKind.UNKNOWN ->
                BotMemorySourceKind.AGENT_MESSAGE
            BotTurnOriginKind.ROUTINE -> BotMemorySourceKind.ROUTINE
            BotTurnOriginKind.TASK -> BotMemorySourceKind.TASK
            BotTurnOriginKind.TASK_WAKE -> BotMemorySourceKind.HIDDEN_WAKE
        }

    override fun equals(other: Any?): Boolean =
        other is BotTurnOrigin && other.rpcId == rpcId && other.kind == kind

    override fun hashCode(): Int = (rpcId?.hashCode() ?: 0) * 31 + kind.hashCode()

    override fun toString(): String = "BotTurnOrigin(rpcId=$rpcId, kind=${kind.rawValue})"

    companion object {
        /** The prefix table, in match order. */
        private val prefixes: List<Pair<String, BotTurnOriginKind>> = listOf(
            "user-action:" to BotTurnOriginKind.USER,
            "card-answer:" to BotTurnOriginKind.USER,
            "bot-" to BotTurnOriginKind.USER,
            "held:" to BotTurnOriginKind.HELD,
            "agent:" to BotTurnOriginKind.AGENT,
            "routine:" to BotTurnOriginKind.ROUTINE,
            "task-turn:" to BotTurnOriginKind.TASK,
            "task-settled:" to BotTurnOriginKind.TASK_WAKE,
            "task-interrupted:" to BotTurnOriginKind.TASK_WAKE,
        )

        fun parse(rpcId: String?): BotTurnOrigin {
            if (rpcId.isNullOrEmpty()) return BotTurnOrigin(rpcId, BotTurnOriginKind.UNKNOWN)
            for ((prefix, candidate) in prefixes) {
                if (!rpcId.startsWith(prefix)) continue
                val payload = rpcId.substring(prefix.length)
                val hasPayload = payload.any { !it.isWhitespace() }
                return BotTurnOrigin(
                    rpcId,
                    if (hasPayload) candidate else BotTurnOriginKind.UNKNOWN,
                )
            }
            return BotTurnOrigin(rpcId, BotTurnOriginKind.UNKNOWN)
        }

        /**
         * Resolve the origin recorded on a DSH `user/message` event. Missing or
         * non-object `source` is unknown, never hidden.
         */
        fun from(source: Map<String, JsonValue>?): BotTurnOrigin {
            val rpcId = (source?.get("rpcId") as? JsonString)?.value
            return parse(rpcId)
        }

        fun from(source: JsonObject?): BotTurnOrigin =
            from(source?.members)

        // MARK: - Host-minted request ids

        fun userActionRequestId(nonce: String): String = "user-action:$nonce"

        /** A card tap is a real user action: the option value becomes a normal chat message. */
        fun cardAnswerRequestId(nonce: String): String = "card-answer:$nonce"

        fun visibleRequestId(uuid: String): String = "bot-${uuid.lowercase()}"

        fun heldRequestId(digest: String): String = "held:$digest"

        fun agentRequestId(callId: String): String = "agent:$callId"

        fun routineRequestId(runId: String): String = "routine:$runId"

        fun taskTurnRequestId(taskId: String): String = "task-turn:$taskId"

        fun taskSettledRequestId(taskId: String): String = "task-settled:$taskId"

        fun taskInterruptedRequestId(taskId: String): String = "task-interrupted:$taskId"

        /** The `user-action:` nonce, or null for every other request id. */
        fun userActionNonce(from: String?): String? {
            if (from == null || !from.startsWith("user-action:")) return null
            val nonce = from.substring("user-action:".length)
            return if (nonce.any { !it.isWhitespace() }) nonce else null
        }
    }
}

/**
 * The user-message authority of the turn currently executing a tool.
 * `isUserTurn` is the only input deciding whether a routine change may proceed
 * without an approval card; a held turn is deliberately not a user turn.
 */
data class BotTurnAuthority(
    val rpcId: String?,
    val turnId: String?,
    val sessionId: String,
    val origin: BotTurnOriginKind,
    val isUserTurn: Boolean,
    val approvalId: String? = null,
) {
    val approvalSourceDescription: String
        get() = when (origin) {
            BotTurnOriginKind.AGENT -> "由其他 Bot 的消息（${rpcId ?: "未知 callId"}）触发"
            BotTurnOriginKind.ROUTINE -> "由例行任务回合触发"
            BotTurnOriginKind.TASK, BotTurnOriginKind.TASK_WAKE -> "由 Task 子会话触发"
            BotTurnOriginKind.HELD -> "由带 held 块的回合触发"
            BotTurnOriginKind.USER -> "由用户回合触发"
            BotTurnOriginKind.UNKNOWN -> "回合来源未知（没有用户消息引用）"
        }
}
