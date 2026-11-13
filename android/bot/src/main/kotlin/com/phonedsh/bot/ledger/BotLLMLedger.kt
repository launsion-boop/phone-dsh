// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.invalidCursor
import java.util.UUID

/**
 * Appends and replays the P25 LLM ledger (`BotLLMLedger.swift`).
 *
 * One `ledger.usage_recorded` durable event per model step; the event `data`
 * is exactly the 14-required-member [BotLLMLedgerRecord] object. There is no
 * table, no file and no new envelope type (`store.md` §6.3).
 */
public class BotLLMLedger(
    private val store: BotDomainStore,
    private val makeEventId: () -> String = {
        "$EVENT_TYPE:${UUID.randomUUID().toString().lowercase()}"
    },
) {
    /**
     * Appends one record and returns its commit sequence. The id is produced
     * by [makeEventId] before the append; appending the same id again is the
     * store's idempotent no-op and returns the existing sequence.
     */
    public fun append(record: BotLLMLedgerRecord): Long {
        record.validate()
        val eventId = makeEventId()
        if (eventId.isEmpty()) {
            throw BotLLMLedgerException("eventId", "event id must not be empty")
        }
        val time = BotLLMLedgerRecord.eventTimeMillis(record.ts)
            ?: throw BotLLMLedgerException("ts", "timestamp must be an ISO-8601 date")
        val event = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = EVENT_TYPE,
            eventId = eventId,
            commitSeq = null,
            time = time,
            origin = BotEventOrigin.Local("runtime"),
            traceId = "trace:$eventId",
            principal = BotPrincipal(
                botId = record.botId,
                sessionId = record.sessionId,
                kind = record.purpose.principalKind,
                capabilities = emptyList(),
            ),
            causationId = null,
            correlationId = record.sessionId,
            data = record.toJson(),
        )
        return store.append(event)
    }

    /**
     * Replays ledger records in commit order, skipping every other event type.
     * [after] is the exclusive commit cursor and [limit] must be positive; the
     * page size matches the Swift reader's 1,000-event scan.
     */
    public fun records(after: Int = 0, limit: Int = 1_000): List<BotLLMLedgerRecord> {
        if (limit <= 0) throw invalidCursor("limit must be positive")
        val records = ArrayList<BotLLMLedgerRecord>()
        var cursor = after
        while (records.size < limit) {
            val events = store.events(cursor, PAGE_SIZE)
            if (events.isEmpty()) break
            for (event in events) {
                val sequence = event.commitSeq ?: continue
                if (sequence > Int.MAX_VALUE) {
                    throw invalidCursor("commitSeq $sequence exceeds the Int cursor range")
                }
                cursor = sequence.toInt()
                if (event.type != EVENT_TYPE) continue
                records += BotLLMLedgerRecord.fromJson(event.data)
                if (records.size == limit) break
            }
            if (events.size < PAGE_SIZE) break
        }
        return records
    }

    public companion object {
        public const val EVENT_TYPE: String = "ledger.usage_recorded"
        public const val PAGE_SIZE: Int = 1_000
    }
}
