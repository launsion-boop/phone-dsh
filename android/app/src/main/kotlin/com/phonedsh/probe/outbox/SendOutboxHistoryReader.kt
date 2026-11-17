// SPDX-License-Identifier: MIT
// Feeds [SendOutboxReadBack] from the engine's own authority
// (spec/host/v1/README.md section 10, "Outcome unknown"): one `session/follow`
// snapshot gives the inbox projection and the history cursor of the same
// instant, and `session/page` walks the history back from that cursor.
//
// Kotlin end of `SessionHistoryReader.readBack` in
// `examples/probe-app/ProbeKit/Transcript/SessionHistoryReader.swift`. A local
// transcript or cache is never read here: it is not proof.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException

/** The two reads a read-back needs. A failure is thrown, never turned into an empty answer. */
internal interface SessionHistorySource {
    /** The `snapshot` item of a fresh `session/follow` of [sessionId]: `{type, cursor, projections, ...}`. */
    suspend fun followSnapshot(sessionId: String): JsonObject

    /** One `session/page` through [throughSeq], strictly before [beforeSeq] when given. */
    suspend fun page(sessionId: String, throughSeq: Long, beforeSeq: Long?): JsonValue
}

internal object SendOutboxHistoryReader {
    /**
     * Settles one entry against a single follow snapshot. Any failed or
     * unreadable read is [SendOutboxReadBack.INCONCLUSIVE]: the entry stays
     * where it is and is not resent.
     */
    suspend fun readBack(entry: SendOutboxEntry, source: SessionHistorySource): SendOutboxReadBack {
        return try {
            val snapshot = source.followSnapshot(entry.sessionId)
            // Only -1 denotes an empty history; a fractional or absent cursor is unreadable.
            val cursor = (snapshot["cursor"] as? JsonNumber)?.asLongOrNull() ?: return SendOutboxReadBack.INCONCLUSIVE
            if (cursor < -1) return SendOutboxReadBack.INCONCLUSIVE
            val inbox = ((snapshot["projections"] as? JsonObject)?.get("values") as? JsonObject)?.get("inbox")
            val firstPage = if (cursor >= 0) source.page(entry.sessionId, cursor, null) else null
            SendOutboxReadBack.resolve(
                rpcId = entry.rpcId,
                createdAtMs = entry.createdAtMs,
                inbox = inbox,
                firstPage = firstPage,
            ) { before -> source.page(entry.sessionId, cursor, before) }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            SendOutboxReadBack.INCONCLUSIVE
        }
    }
}

/** The real source: the App's `/api` client over the host channel. */
internal class DshSessionHistorySource(
    private val client: DshTurnClient,
    private val snapshotTimeoutMillis: Long = 10_000L,
) : SessionHistorySource {
    override suspend fun followSnapshot(sessionId: String): JsonObject {
        val follow = client.follow(sessionId, maxMessages = 1)
        try {
            val deadline = System.currentTimeMillis() + snapshotTimeoutMillis
            while (true) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) throw DshTurnException("follow_snapshot_timeout", "session/follow published no snapshot")
                val item = follow.next(remaining)
                    ?: throw DshTurnException("follow_snapshot_missing", "session/follow ended before its snapshot")
                when ((item["type"] as? JsonString)?.value) {
                    "error" -> throw DshTurnException("follow_error", "session/follow reported an error")
                    "end" -> throw DshTurnException("follow_snapshot_missing", "session/follow ended before its snapshot")
                    "item" -> Unit
                    else -> continue
                }
                if ((item["streamId"] as? JsonString)?.value != "follow") continue
                val value = item["value"] as? JsonObject ?: continue
                if ((value["type"] as? JsonString)?.value == "snapshot") return value
            }
        } finally {
            follow.close()
        }
    }

    override suspend fun page(sessionId: String, throughSeq: Long, beforeSeq: Long?): JsonValue {
        val request = LinkedHashMap<String, JsonValue>()
        request["address"] = JsonObject(
            linkedMapOf("kind" to JsonString("session"), "sessionId" to JsonString(sessionId)),
        )
        request["throughSeq"] = JsonNumber(throughSeq.toString())
        request["maxMessages"] = JsonNumber(PAGE_MESSAGES.toString())
        if (beforeSeq != null) request["beforeSeq"] = JsonNumber(beforeSeq.toString())
        return client.call("session/page", JsonObject(linkedMapOf("request" to JsonObject(request))))
    }

    private companion object {
        const val PAGE_MESSAGES = 60
    }
}
