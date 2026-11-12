// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.util.UUID

/** `BotTurnOrigin` kind (`turn-origin.phone.json`). */
public enum class BotTurnOriginKind(public val wire: String) {
    USER("user"),
    HELD("held"),
    AGENT("agent"),
    ROUTINE("routine"),
    TASK("task"),
    TASK_WAKE("task-wake"),
    UNKNOWN("unknown"),
}

/**
 * The frozen turn-origin classifier (`Wake/BotTurnOrigin.swift:22-93`).
 *
 * Prefix matching is exact and case-sensitive, in table order; a bare prefix
 * or a whitespace-only payload is `unknown`, never hidden. A missing or
 * non-object DSH `source`, or a non-string/missing `rpcId`, is `unknown`.
 */
public data class BotTurnOrigin(
    public val rpcId: String?,
    public val kind: BotTurnOriginKind,
) {
    public val hidden: Boolean
        get() = kind == BotTurnOriginKind.ROUTINE ||
            kind == BotTurnOriginKind.TASK ||
            kind == BotTurnOriginKind.TASK_WAKE

    public val held: Boolean
        get() = kind == BotTurnOriginKind.HELD

    public companion object {
        private val PREFIXES: List<Pair<String, BotTurnOriginKind>> = listOf(
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

        public fun parse(rpcId: String?): BotTurnOrigin {
            if (rpcId.isNullOrEmpty()) return BotTurnOrigin(rpcId, BotTurnOriginKind.UNKNOWN)
            for ((prefix, candidate) in PREFIXES) {
                if (!rpcId.startsWith(prefix)) continue
                val payload = rpcId.substring(prefix.length)
                val hasPayload = payload.any { !it.isWhitespace() }
                return BotTurnOrigin(rpcId, if (hasPayload) candidate else BotTurnOriginKind.UNKNOWN)
            }
            return BotTurnOrigin(rpcId, BotTurnOriginKind.UNKNOWN)
        }

        /** Resolve a DSH `user/message` source; missing/non-object is unknown. */
        public fun fromSource(source: Map<String, JsonValue>?): BotTurnOrigin {
            val rpcId = (source?.get("rpcId") as? JsonString)?.value
                ?: return BotTurnOrigin(null, BotTurnOriginKind.UNKNOWN)
            return parse(rpcId)
        }

        /** `BotTurnOrigin.visibleRequestId()` — `bot-<lowercase UUID with dashes>`. */
        public fun visibleRequestId(): String = "bot-${UUID.randomUUID().toString().lowercase()}"

        /** The `user-action:<nonce>` nonce, or nil for every other request id. */
        public fun userActionNonce(rpcId: String?): String? {
            if (rpcId == null || !rpcId.startsWith("user-action:")) return null
            val nonce = rpcId.substring("user-action:".length)
            return nonce.takeIf { it.any { character -> !character.isWhitespace() } }
        }

        /** `source.kind == "user"` plus a `user-action:` rpc id. */
        public fun chatActionNonce(source: Map<String, JsonValue>?): String? {
            val kind = (source?.get("kind") as? JsonString)?.value
            if (kind != "user") return null
            return userActionNonce((source["rpcId"] as? JsonString)?.value)
        }
    }
}

/** Helper for the request-object shape the transport port receives. */
internal fun JsonObject.requestMember(): Map<String, JsonValue>? =
    (members["request"] as? JsonObject)?.members
