// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal

/**
 * Durable write-before-enqueue transport for the read-only device task result
 * notice (`DeviceTaskResultOutbox.swift`; v2 §2).
 *
 * 1. `comm.inbound` with `deviceTaskResult` is appended.
 * 2. `WakeInbox.enqueue` inserts the item (deduped by `requestId`).
 * 3. `comm.reply` with `deviceTaskResultAck` marks the record delivered.
 *
 * Startup replays every record without an acknowledgement. A record already
 * enqueued but not acknowledged re-enqueues as a duplicate; a record whose item
 * was consumed after acknowledgement is not resurrected.
 */
class DeviceTaskResultOutbox(
    private val domain: BotDomainStore,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private data class Pending(val botId: String, val notice: DeviceTaskResultNotice)

    private val pending = LinkedHashMap<String, Pending>()
    private val acknowledged = HashSet<String>()
    private var restored = false

    fun record(notice: DeviceTaskResultNotice, botId: String) {
        val eventId = recordEventID(notice)
        val members = LinkedHashMap<String, com.phonedsh.agentcore.JsonValue>()
        members["botId"] = JsonString(botId)
        members["deviceTaskResult"] = notice.toJson()
        if (notice.status == DeviceTaskResultNotice.Status.UNKNOWN_OUTCOME) {
            members["requiresReconciliation"] = JsonBool(true)
        }
        val event = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = RECORD_EVENT_TYPE,
            eventId = eventId,
            commitSeq = null,
            time = notice.createdAt,
            origin = BotEventOrigin.Local("comm-service"),
            traceId = "device-task-result:${notice.digest}",
            principal = BotPrincipal(botId = botId, sessionId = null, kind = "chat", capabilities = emptyList()),
            causationId = null,
            correlationId = notice.requestID,
            data = JsonObject(members),
        )
        domain.append(event)
        pending[eventId] = Pending(botId, notice)
        acknowledged.remove(eventId)
    }

    /** Records, enqueues and acknowledges one notice; a duplicate is still acknowledged. */
    fun enqueue(notice: DeviceTaskResultNotice, botId: String, inbox: WakeInbox): WakeInboxEnqueue {
        record(notice, botId)
        val result = inbox.enqueue(notice.wakeInboxItem())
        acknowledge(notice, botId)
        return result
    }

    /** Startup replay for one Bot; returns the number of records re-enqueued. */
    fun redeliver(botId: String, inbox: WakeInbox): Int {
        restoreIfNeeded()
        var count = 0
        val entries = pending.entries.sortedBy { it.key }
        for ((eventId, entry) in entries) {
            if (entry.botId != botId || eventId in acknowledged) continue
            inbox.enqueue(entry.notice.wakeInboxItem())
            acknowledge(entry.notice, entry.botId)
            count++
        }
        return count
    }

    fun pendingEventIDs(botId: String): List<String> = pending.entries
        .filter { it.value.botId == botId && it.key !in acknowledged }
        .map { it.key }
        .sorted()

    private fun acknowledge(notice: DeviceTaskResultNotice, botId: String) {
        val recordID = recordEventID(notice)
        val event = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = ACKNOWLEDGEMENT_EVENT_TYPE,
            eventId = acknowledgementEventID(notice),
            commitSeq = null,
            time = maxOf(clock(), notice.createdAt),
            origin = BotEventOrigin.Local("comm-service"),
            traceId = "device-task-result-ack:${notice.digest}",
            principal = BotPrincipal(botId = botId, sessionId = null, kind = "chat", capabilities = emptyList()),
            causationId = recordID,
            correlationId = notice.requestID,
            data = objectOf(
                listOf(
                    "botId" to JsonString(botId),
                    "deviceTaskResultAck" to JsonString(recordID),
                ),
            ),
        )
        domain.append(event)
        acknowledged += recordID
    }

    private fun restoreIfNeeded() {
        if (restored) return
        var cursor = 0
        while (true) {
            val events = domain.events(cursor, REPLAY_PAGE_SIZE)
            if (events.isEmpty()) break
            for (event in events) {
                val sequence = event.commitSeq ?: continue
                if (sequence <= cursor) continue
                cursor = sequence.toInt()
                when (event.type) {
                    RECORD_EVENT_TYPE -> {
                        val entry = pending(event) ?: continue
                        pending[event.eventId] = entry
                    }
                    ACKNOWLEDGEMENT_EVENT_TYPE -> {
                        val members = (event.data as? JsonObject)?.members ?: continue
                        val recordID = members.optionalString("deviceTaskResultAck") ?: continue
                        acknowledged += recordID
                    }
                    else -> continue
                }
            }
            if (events.size < REPLAY_PAGE_SIZE) break
        }
        restored = true
    }

    private fun pending(event: BotEvent): Pending? {
        val members = (event.data as? JsonObject)?.members ?: return null
        val botId = members.optionalString("botId") ?: return null
        val value = members["deviceTaskResult"] ?: return null
        return Pending(botId, DeviceTaskResultNotice.fromJson(value))
    }

    companion object {
        const val RECORD_EVENT_TYPE: String = "comm.inbound"
        const val ACKNOWLEDGEMENT_EVENT_TYPE: String = "comm.reply"
        const val REPLAY_PAGE_SIZE: Int = 500

        fun recordEventID(notice: DeviceTaskResultNotice): String =
            "device-task-result:${notice.digest}"

        fun acknowledgementEventID(notice: DeviceTaskResultNotice): String =
            "device-task-result-ack:${notice.digest}"
    }
}
