// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.sha256

/** The P26 write-before-enqueue and acknowledgement protocol used by iOS. */
class ConnectorUpdateOutbox(
    private val domain: BotDomainStore,
    private val inbox: WakeInbox,
) {
    @Synchronized
    fun enqueue(update: HeldConnectorUpdate, createdAt: Long) {
        val requestId = "${update.connector}:${update.cursorFrom}:${update.cursorTo}"
        val digest = sha256(requestId.toByteArray(Charsets.UTF_8))
        val recordId = "connector-update:$digest"
        val ackId = "connector-update-ack:$digest"
        if (domain.event(ackId) != null) return
        val prior = domain.event(recordId)
        if (prior != null) {
            deliver(decode(prior), recordId, ackId)
            return
        }
        val item = item(update, requestId, createdAt)

        domain.append(event("comm.inbound", recordId, item, mapOf(
            "connector" to JsonString(update.connector),
            "connectorUpdate" to JsonObject(mapOf(
                "connector" to JsonString(update.connector),
                "cursorFrom" to JsonString(update.cursorFrom),
                "cursorTo" to JsonString(update.cursorTo),
                "createdAt" to JsonNumber(createdAt.toString()),
                "items" to JsonArray(update.items),
            )),
        )))
        deliver(item, recordId, ackId)
    }

    @Synchronized
    fun redeliver() {
        var cursor = 0
        while (true) {
            val events = domain.events(cursor, 500)
            for (event in events) {
                cursor = event.commitSeq?.toInt() ?: continue
                if (event.type != "comm.inbound" || event.principal.botId != inbox.botId) continue
                if ((event.data as? JsonObject)?.get("connectorUpdate") == null) continue
                val ackId = "connector-update-ack:" + event.eventId.removePrefix("connector-update:")
                if (domain.event(ackId) != null) continue
                deliver(decode(event), event.eventId, ackId)
            }
            if (events.size < 500) return
        }
    }

    private fun decode(event: BotEvent): WakeInboxItem {
        val update = (event.data as JsonObject)["connectorUpdate"] as JsonObject
        require(update.members.keys == setOf("connector", "cursorFrom", "cursorTo", "createdAt", "items"))
        val data = HeldConnectorUpdate(
            (update["connector"] as JsonString).value,
            (update["cursorFrom"] as JsonString).value,
            (update["cursorTo"] as JsonString).value,
            (update["items"] as JsonArray).values.map { it as JsonObject },
        )
        return item(data, requireNotNull(event.correlationId), event.time)
    }

    private fun deliver(item: WakeInboxItem, recordId: String, ackId: String) {
        check(inbox.enqueue(item).ok) { "Connector update was not enqueued" }
        domain.append(event("comm.reply", ackId, item,
            mapOf("connectorUpdateAck" to JsonString(recordId)), recordId))
    }

    private fun event(type: String, id: String, item: WakeInboxItem,
                      data: Map<String, JsonValue>, cause: String? = null): BotEvent =
        BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = type,
            eventId = id,
            commitSeq = null,
            time = item.createdAt,
            origin = BotEventOrigin.Local("comm-service"),
            traceId = id,
            principal = BotPrincipal(inbox.botId, null, "chat", emptyList()),
            causationId = cause,
            correlationId = item.requestId,
            data = JsonObject(data + ("botId" to JsonString(inbox.botId))),
        )

    private fun item(update: HeldConnectorUpdate, requestId: String, createdAt: Long) =
        WakeInboxItem(
            id = "connector-update:$requestId",
            kind = "connector-update",
            text = "${update.connector}: ${update.items.size} new item(s) since ${update.cursorFrom}.",
            requestId = requestId,
            createdAt = createdAt,
            connectorUpdate = update,
        )
}
