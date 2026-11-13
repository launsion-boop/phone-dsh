// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.wake.WakeInboxItem
import com.phonedsh.bot.wake.WakeInboxState
import java.security.MessageDigest
import java.text.BreakIterator
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * The four row directions the upstream agent-comm transcript uses.
 *
 * - `outbound`: the sender's row for a message it just sent.
 * - `inbound`: the sender's row carrying the target's reply.
 * - `incoming`: the target's user row opened by an `[agent]` prompt.
 * - `reply`: the target's assistant row patched to name the sender.
 */
public enum class BotAgentCommDirection(public val wire: String) {
    OUTBOUND("outbound"),
    INBOUND("inbound"),
    INCOMING("incoming"),
    REPLY("reply"),
    ;

    public companion object {
        public fun from(value: String?): BotAgentCommDirection? =
            entries.firstOrNull { it.wire == value }
    }
}

/**
 * `toAgent` / `fromAgent` peer reference. `kind` is `"agent"` upstream and is
 * omitted on `fromAgent` rows written by the team tool.
 */
public data class BotAgentRef(
    public val id: String,
    public val name: String,
    public val kind: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["id"] = JsonString(id)
        members["name"] = JsonString(name)
        kind?.let { members["kind"] = JsonString(it) }
        return JsonObject(members)
    }

    public companion object {
        /** Null unless the object carries a non-empty id or name (Swift `BotAgentRef(json:)`). */
        public fun fromJson(value: JsonValue?): BotAgentRef? {
            val members = (value as? JsonObject)?.members ?: return null
            val id = Buffers.string(members["id"]) ?: ""
            val name = Buffers.string(members["name"]) ?: ""
            if (id.isEmpty() && name.isEmpty()) return null
            return BotAgentRef(id = id, name = name, kind = Buffers.string(members["kind"]))
        }
    }
}

/**
 * The upstream `agentComm` object. Every field except `direction` is optional
 * so old rows (which only carried `toAgent`/`fromAgent`) still decode.
 */
public data class BotAgentComm(
    public val direction: BotAgentCommDirection,
    public val targetId: String? = null,
    public val targetName: String? = null,
    public val fromAgentId: String? = null,
    public val fromAgentName: String? = null,
    public val message: String? = null,
    public val replyText: String? = null,
    public val requestId: String? = null,
    public val threadId: String? = null,
    public val firstEntryId: String? = null,
    public val replyEntryId: String? = null,
    public val delivery: String? = null,
    public val status: String? = null,
    public val title: String? = null,
    public val hop: Int? = null,
    public val callId: String? = null,
    public val error: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["direction"] = JsonString(direction.wire)
        put(members, "targetId", targetId)
        put(members, "targetName", targetName)
        put(members, "fromAgentId", fromAgentId)
        put(members, "fromAgentName", fromAgentName)
        put(members, "message", message)
        put(members, "replyText", replyText)
        put(members, "requestId", requestId)
        put(members, "threadId", threadId)
        put(members, "firstEntryId", firstEntryId)
        put(members, "replyEntryId", replyEntryId)
        put(members, "delivery", delivery)
        put(members, "status", status)
        put(members, "title", title)
        hop?.let { members["hop"] = JsonNumber(it.toString()) }
        put(members, "callId", callId)
        put(members, "error", error)
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotAgentComm? {
            val members = (value as? JsonObject)?.members ?: return null
            val direction = BotAgentCommDirection.from(Buffers.string(members["direction"]))
                ?: return null
            return BotAgentComm(
                direction = direction,
                targetId = Buffers.string(members["targetId"]),
                targetName = Buffers.string(members["targetName"]),
                fromAgentId = Buffers.string(members["fromAgentId"]),
                fromAgentName = Buffers.string(members["fromAgentName"]),
                message = Buffers.string(members["message"]),
                replyText = Buffers.string(members["replyText"]),
                requestId = Buffers.string(members["requestId"]),
                threadId = Buffers.string(members["threadId"]),
                firstEntryId = Buffers.string(members["firstEntryId"]),
                replyEntryId = Buffers.string(members["replyEntryId"]),
                delivery = Buffers.string(members["delivery"]),
                status = Buffers.string(members["status"]),
                title = Buffers.string(members["title"]),
                hop = Buffers.long(members["hop"])?.toInt(),
                callId = Buffers.string(members["callId"]),
                error = Buffers.string(members["error"]),
            )
        }
    }
}

/**
 * Row identity and thread identity from upstream `agentComm.cjs`.
 *
 * The outbound row id is `agent-outbound-<sha256>` over the sender id, the
 * target id, the request id (or empty) and the row sequence, joined with one
 * NUL. Every row of an exchange shares `threadId = <rowId>@<seq>:agent-comm`.
 */
public object BotAgentCommIdentity {
    public const val ROW_ID_PREFIX: String = "agent-outbound-"
    private const val SEGMENT_SEPARATOR: String = "\u0000"

    public fun outboundRowID(
        senderAgentID: String,
        targetID: String,
        requestID: String?,
        seq: Long,
    ): String {
        val input = listOf(
            senderAgentID,
            targetID,
            requestID ?: "",
            seq.toString(),
        ).joinToString(SEGMENT_SEPARATOR)
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.UTF_8))
        return ROW_ID_PREFIX + digest.joinToString("") { byte ->
            (byte.toInt() and 0xFF).toString(16).padStart(2, '0')
        }
    }

    public fun threadID(rowID: String, seq: Long?): String =
        if (seq != null) "$rowID@$seq:agent-comm" else "$rowID:agent-comm"

    /** `t<turn>u`, with a numeric suffix on the rare collision inside one turn. */
    public fun turnRowID(turn: Int, existingIDs: Set<String> = emptySet()): String {
        val normalized = maxOf(0, turn)
        var id = "t${normalized}u"
        var suffix = 2
        while (id in existingIDs) {
            id = "t${normalized}u$suffix"
            suffix += 1
        }
        return id
    }
}

/**
 * The per-`BotTeamTools` sequence frozen by `team.md` §2.5:
 *
 * ```
 * base = nowMilliseconds * 1_000       (overflow fallback: nowMilliseconds)
 * seq  = base + (counter % 1_000)
 * ```
 *
 * The counter is not a durable sequence domain and must not be used as a
 * `commitSeq`.
 */
public class BotAgentCommSequence(private val now: () -> Long) {
    private val counter: AtomicLong = AtomicLong(0)

    public fun next(): Long {
        val milliseconds = now()
        val scaled = try {
            Math.multiplyExact(milliseconds, 1_000L)
        } catch (_: ArithmeticException) {
            milliseconds
        }
        val value = counter.getAndIncrement()
        return scaled + (value % 1_000L)
    }
}

/**
 * One durable agent-comm row as the host should project it. The tools write
 * the sender's `outbound` row before delivery and its `inbound` row after the
 * reply; a host may reuse the same record type for the target's `incoming` and
 * `reply` rows.
 */
public data class BotTeamAgentCommRecord(
    public val rowID: String,
    public val botID: String,
    public val direction: BotAgentCommDirection,
    public val role: String,
    public val text: String,
    public val threadID: String,
    public val requestID: String,
    public val fromAgent: BotAgentRef? = null,
    public val toAgent: BotAgentRef? = null,
    public val delivery: String? = null,
    public val status: String? = null,
    public val title: String? = null,
    public val hop: Int? = null,
    public val turn: Int? = null,
    public val callID: String? = null,
    public val replyEntryID: String? = null,
    public val error: String? = null,
) {
    public fun agentComm(): BotAgentComm = when (direction) {
        BotAgentCommDirection.OUTBOUND -> BotAgentComm(
            direction = BotAgentCommDirection.OUTBOUND,
            targetId = toAgent?.id,
            targetName = toAgent?.name,
            message = text,
            requestId = requestID,
            threadId = threadID,
            delivery = delivery,
            status = status,
            title = title,
            hop = hop,
            callId = callID,
        )
        BotAgentCommDirection.INBOUND -> BotAgentComm(
            direction = BotAgentCommDirection.INBOUND,
            fromAgentId = fromAgent?.id,
            fromAgentName = fromAgent?.name,
            replyText = text,
            requestId = requestID,
            threadId = threadID,
            replyEntryId = replyEntryID,
            error = error,
        )
        BotAgentCommDirection.INCOMING -> BotAgentComm(
            direction = BotAgentCommDirection.INCOMING,
            fromAgentId = fromAgent?.id,
            fromAgentName = fromAgent?.name,
            message = text,
            requestId = requestID,
            threadId = threadID,
            hop = hop,
        )
        BotAgentCommDirection.REPLY -> BotAgentComm(
            direction = BotAgentCommDirection.REPLY,
            targetId = toAgent?.id,
            targetName = toAgent?.name,
            message = text,
            requestId = requestID,
            threadId = threadID,
        )
    }

    /** Data for the existing `agent.comm` Bot event; no second envelope. */
    public fun eventData(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["id"] = JsonString(rowID)
        members["rowID"] = JsonString(rowID)
        members["role"] = JsonString(role)
        members["text"] = JsonString(text)
        members["direction"] = JsonString(direction.wire)
        members["threadId"] = JsonString(threadID)
        members["requestId"] = JsonString(requestID)
        members["agentComm"] = agentComm().toJson()
        fromAgent?.let { members["fromAgent"] = it.toJson() }
        toAgent?.let { members["toAgent"] = it.toJson() }
        delivery?.let { members["delivery"] = JsonString(it) }
        status?.let { members["status"] = JsonString(it) }
        title?.let { members["title"] = JsonString(it) }
        hop?.let { members["hop"] = JsonNumber(it.toString()) }
        turn?.let { members["turn"] = JsonNumber(it.toString()) }
        callID?.let { members["callId"] = JsonString(it) }
        replyEntryID?.let { members["replyEntryId"] = JsonString(it) }
        error?.let { members["error"] = JsonString(it) }
        return JsonObject(members)
    }

    /**
     * The durable P25 `agent.comm` event for this row. `eventId` is
     * `agent.comm:<rowID>`, the principal is the row's Bot in `team` kind, the
     * origin is `local(source:"comm-service")`, the trace id is
     * `agent-comm:<threadID>` and the correlation id is the request id.
     */
    public fun toEvent(time: Long): BotEvent = BotEvent(
        schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
        type = "agent.comm",
        eventId = "agent.comm:$rowID",
        commitSeq = null,
        time = time,
        origin = BotEventOrigin.Local("comm-service"),
        traceId = "agent-comm:$threadID",
        principal = BotPrincipal(
            botId = botID,
            sessionId = null,
            kind = "team",
            capabilities = emptyList(),
        ),
        causationId = null,
        correlationId = requestID,
        data = eventData(),
    )

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["rowID"] = JsonString(rowID)
        members["botID"] = JsonString(botID)
        members["direction"] = JsonString(direction.wire)
        members["role"] = JsonString(role)
        members["text"] = JsonString(text)
        fromAgent?.let { members["fromAgent"] = it.toJson() }
        toAgent?.let { members["toAgent"] = it.toJson() }
        members["threadID"] = JsonString(threadID)
        members["requestID"] = JsonString(requestID)
        delivery?.let { members["delivery"] = JsonString(it) }
        status?.let { members["status"] = JsonString(it) }
        title?.let { members["title"] = JsonString(it) }
        hop?.let { members["hop"] = JsonNumber(it.toString()) }
        turn?.let { members["turn"] = JsonNumber(it.toString()) }
        callID?.let { members["callID"] = JsonString(it) }
        replyEntryID?.let { members["replyEntryID"] = JsonString(it) }
        error?.let { members["error"] = JsonString(it) }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotTeamAgentCommRecord? {
            val members = (value as? JsonObject)?.members ?: return null
            val rowID = Buffers.string(members["rowID"]) ?: return null
            val botID = Buffers.string(members["botID"]) ?: return null
            val direction = BotAgentCommDirection.from(Buffers.string(members["direction"]))
                ?: return null
            val role = Buffers.string(members["role"]) ?: return null
            val text = Buffers.string(members["text"]) ?: ""
            val threadID = Buffers.string(members["threadID"]) ?: return null
            val requestID = Buffers.string(members["requestID"]) ?: return null
            return BotTeamAgentCommRecord(
                rowID = rowID,
                botID = botID,
                direction = direction,
                role = role,
                text = text,
                threadID = threadID,
                requestID = requestID,
                fromAgent = BotAgentRef.fromJson(members["fromAgent"]),
                toAgent = BotAgentRef.fromJson(members["toAgent"]),
                delivery = Buffers.string(members["delivery"]),
                status = Buffers.string(members["status"]),
                title = Buffers.string(members["title"]),
                hop = Buffers.long(members["hop"])?.toInt(),
                turn = Buffers.long(members["turn"])?.toInt(),
                callID = Buffers.string(members["callID"]),
                replyEntryID = Buffers.string(members["replyEntryID"]),
                error = Buffers.string(members["error"]),
            )
        }

        /**
         * Read one `agent.comm` event's `data` (or a projected row body).
         *
         * New writers always include `agentComm`; rows written before the team
         * revision may omit it, so every field falls back to the top-level
         * `direction`/`toAgent`/`fromAgent`/`text`/`threadId`/`requestId`
         * members. The event `data` has no `botID`, so the caller supplies the
         * row owner (the event principal's bot id).
         */
        public fun fromEventData(
            value: JsonValue?,
            botID: String,
        ): BotTeamAgentCommRecord? {
            val members = (value as? JsonObject)?.members ?: return null
            val comm = (members["agentComm"] as? JsonObject)?.members ?: emptyMap()
            val direction = BotAgentCommDirection.from(Buffers.string(members["direction"]))
                ?: BotAgentCommDirection.from(Buffers.string(comm["direction"]))
                ?: return null
            val rowID = Buffers.string(members["rowID"])
                ?: Buffers.string(members["id"])
                ?: return null
            val threadID = Buffers.string(members["threadId"])
                ?: Buffers.string(comm["threadId"])
                ?: return null
            val requestID = Buffers.string(members["requestId"])
                ?: Buffers.string(comm["requestId"])
                ?: return null
            val role = Buffers.string(members["role"]) ?: when (direction) {
                BotAgentCommDirection.OUTBOUND, BotAgentCommDirection.REPLY -> "assistant"
                BotAgentCommDirection.INBOUND, BotAgentCommDirection.INCOMING -> "user"
            }
            val text = Buffers.string(members["text"])
                ?: Buffers.string(comm["replyText"])
                ?: Buffers.string(comm["message"])
                ?: ""
            fun peer(topLevel: String, prefix: String): BotAgentRef? {
                BotAgentRef.fromJson(members[topLevel])?.let { return it }
                val id = Buffers.string(comm["${prefix}Id"]) ?: ""
                val name = Buffers.string(comm["${prefix}Name"]) ?: ""
                if (id.isEmpty() && name.isEmpty()) return null
                return BotAgentRef(id = id, name = name)
            }
            return BotTeamAgentCommRecord(
                rowID = rowID,
                botID = botID,
                direction = direction,
                role = role,
                text = text,
                threadID = threadID,
                requestID = requestID,
                fromAgent = peer("fromAgent", "fromAgent"),
                toAgent = peer("toAgent", "target"),
                delivery = Buffers.string(members["delivery"])
                    ?: Buffers.string(comm["delivery"]),
                status = Buffers.string(members["status"]) ?: Buffers.string(comm["status"]),
                title = Buffers.string(members["title"]) ?: Buffers.string(comm["title"]),
                hop = Buffers.long(members["hop"])?.toInt()
                    ?: Buffers.long(comm["hop"])?.toInt(),
                turn = Buffers.long(members["turn"])?.toInt(),
                callID = Buffers.string(members["callId"]) ?: Buffers.string(comm["callId"]),
                replyEntryID = Buffers.string(members["replyEntryId"])
                    ?: Buffers.string(comm["replyEntryId"]),
                error = Buffers.string(members["error"]) ?: Buffers.string(comm["error"]),
            )
        }
    }
}

/**
 * Held-inbox item builders for the two team writes (`team.md` §2.6, §2.10).
 * Both use the existing v2 `agent-held` kind; the reply item deliberately has
 * no hand-off context.
 */
public object BotAgentCommHeld {
    public const val TEXT_LIMIT: Int = 1_200

    public fun heldID(createdAt: Long, randomHex: String = randomHex8()): String =
        "held-${createdAt.toString(36)}-${randomHex.take(8).lowercase()}"

    public fun queuedItem(
        id: String,
        fromAgent: BotAgentRef,
        title: String?,
        message: String,
        requestId: String,
        threadId: String,
        createdAt: Long,
    ): WakeInboxItem = WakeInboxItem(
        id = id,
        kind = "agent-held",
        fromAgentId = fromAgent.id,
        fromAgentName = fromAgent.name,
        title = title,
        text = message,
        requestId = requestId,
        threadId = threadId,
        createdAt = createdAt,
        state = WakeInboxState.PENDING,
    )

    public fun replyItem(
        id: String,
        fromAgent: BotAgentRef,
        originalTitle: String?,
        replyText: String,
        requestId: String,
        threadId: String,
        createdAt: Long,
    ): WakeInboxItem = WakeInboxItem(
        id = id,
        kind = "agent-held",
        fromAgentId = fromAgent.id,
        fromAgentName = fromAgent.name,
        title = replyTitle(originalTitle),
        text = prefixGraphemes(replyText, TEXT_LIMIT),
        requestId = "reply:$requestId",
        threadId = threadId,
        createdAt = createdAt,
        state = WakeInboxState.PENDING,
    )

    public fun replyTitle(originalTitle: String?): String =
        if (!originalTitle.isNullOrEmpty()) "回复：$originalTitle" else "回复"

    /** Swift `String.prefix(count)`: [count] Unicode characters on grapheme boundaries. */
    public fun prefixGraphemes(value: String, count: Int): String {
        if (count <= 0) return ""
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(value)
        var end = iterator.first()
        var taken = 0
        while (taken < count) {
            val next = iterator.next()
            if (next == BreakIterator.DONE) return value
            end = next
            taken += 1
        }
        return value.substring(0, end)
    }

    private fun randomHex8(): String =
        UUID.randomUUID().toString().replace("-", "").take(8).lowercase()
}

/**
 * Truncate to a UTF-16-unit limit on a grapheme boundary. This is the
 * `CreateTeammate` 300-unit rule, not the held reply's 1,200-character rule.
 */
public object BotAgentCommText {
    public fun truncateUtf16(value: String, limit: Int): String {
        if (limit <= 0) return ""
        if (value.length <= limit) return value
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(value)
        var end = iterator.first()
        while (true) {
            val next = iterator.next()
            if (next == BreakIterator.DONE || next > limit) break
            end = next
        }
        return value.substring(0, end)
    }
}

private fun put(members: MutableMap<String, JsonValue>, key: String, value: String?) {
    if (value != null) members[key] = JsonString(value)
}

/** Small accessors shared by the row codecs. */
private object Buffers {
    fun string(value: JsonValue?): String? = (value as? JsonString)?.value

    fun long(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()
}
