// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import java.util.UUID

/**
 * One atomic routine mutation: the new document, the optional lifecycle events
 * appended in the same batch, and the event id of the snapshot itself.
 *
 * `persistSnapshot=false` plus no events means "no write" (a read-only branch
 * or a repeated skip that must not add an event).
 */
data class RoutineMutation<V>(
    val value: V,
    val document: RoutineDocument,
    val events: List<BotEvent> = emptyList(),
    val persistSnapshot: Boolean = true,
    val botId: String,
    val snapshotEventId: String? = null,
)

/**
 * The durable routine snapshot seam (Swift `RoutineStore`).
 *
 * Replay is "latest snapshot event wins" per Bot; every mutation appends one
 * `routine.defined|updated|deleted` snapshot plus its lifecycle events in one
 * batch, so a reader never observes half of one mutation.
 *
 * The read and the batch are two statements (as in the Swift `mutateRoutine`):
 * callers serialise mutations per Bot (the scheduler and the tool surface are
 * single-writer), and the batch itself is still all-or-nothing.
 */
interface RoutineStore {
    fun read(botId: String): RoutineDocument

    fun <V> mutate(botId: String, body: (RoutineDocument) -> RoutineMutation<V>): V
}

/** The P25-backed store. It adds no table and no event type. */
class BotRoutineStore(
    private val store: BotDomainStore,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : RoutineStore {
    override fun read(botId: String): RoutineDocument {
        var document = RoutineDocument()
        var cursor = 0
        while (true) {
            val events = store.events(cursor, REPLAY_PAGE_SIZE)
            if (events.isEmpty()) break
            for (event in events) {
                cursor = (event.commitSeq ?: continue).toInt()
                if (event.type !in snapshotEventTypes) continue
                val snapshot = DurableSnapshot.optionalDocumentObject(event.data, botId) ?: continue
                document = RoutineDocument.fromJson(com.phonedsh.agentcore.JsonObject(snapshot))
            }
            if (events.size < REPLAY_PAGE_SIZE) break
        }
        return document
    }

    override fun <V> mutate(botId: String, body: (RoutineDocument) -> RoutineMutation<V>): V {
        val previous = read(botId)
        val mutation = body(previous)
        if (!mutation.persistSnapshot && mutation.events.isEmpty()) return mutation.value
        val type = when {
            mutation.document.routines.size > previous.routines.size -> "routine.defined"
            mutation.document.routines.size < previous.routines.size -> "routine.deleted"
            else -> "routine.updated"
        }
        val eventId = mutation.snapshotEventId ?: "routine-snapshot:${UUID.randomUUID().toString().lowercase()}"
        val snapshot = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = type,
            eventId = eventId,
            commitSeq = null,
            time = clock(),
            origin = BotEventOrigin.Local("scheduler"),
            traceId = "trace:$eventId",
            principal = BotPrincipal(botId = botId, sessionId = null, kind = "routine", capabilities = emptyList()),
            causationId = null,
            correlationId = botId,
            data = DurableSnapshot.envelope(mutation.document.toJson(), botId),
        )
        store.appendBatch(listOf(snapshot) + mutation.events)
        return mutation.value
    }

    companion object {
        const val REPLAY_PAGE_SIZE: Int = 500

        val snapshotEventTypes: Set<String> = setOf("routine.defined", "routine.updated", "routine.deleted")
    }
}
