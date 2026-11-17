// SPDX-License-Identifier: MIT
// The authoritative read-back that settles an `outcomeUnknown` send
// (spec/host/v1/README.md section 10, "Outcome unknown").
//
// Kotlin end of `examples/probe-app/ProbeKit/Outbox/SendOutboxReadBack.swift`.
// Pure: the caller hands over one follow snapshot (its inbox projection and its
// first history page) and a way to read the page before a sequence number.
// Nothing here touches the outbox; the caller applies the result.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

internal enum class SendOutboxReadBack {
    /** A durable `user/message` carries the rpcId: `accepted`, then `durable`. */
    JOURNALED,

    /** The engine holds the prompt in its inbox; its `user/message` follows the next turn start. `accepted`. */
    HELD,

    /** One consistent snapshot proves the engine never received the request: back to `queued`. */
    ABSENT,

    /** Nothing was proven. The entry stays `outcomeUnknown` and is not resent. */
    INCONCLUSIVE,
    ;

    companion object {
        const val DEFAULT_MAX_PAGES: Int = 40
        private const val MAX_SAFE_INTEGER: Long = 9_007_199_254_740_991L
        private val INBOX_LANES = listOf("next-turn", "next-step")

        /**
         * How long an unknown submit must settle before absence may be concluded:
         * 3 s, doubling per attempt, at most 300 s.
         */
        fun settleDelayMs(attempts: Int): Long {
            val doublings = maxOf(0, minOf(attempts, 8) - 1)
            return minOf(3_000L shl doublings, 300_000L)
        }

        /**
         * Resolves one `outcomeUnknown` entry against one follow snapshot.
         *
         * [inbox] is the snapshot's inbox projection (`{"next-turn": [...],
         * "next-step": [...]}`), or null when the snapshot has none. [firstPage]
         * is the snapshot's newest history page (`{"records": [{"event": {...}}],
         * "hasMore": bool}`), or null when the session has no durable log.
         * [loadEarlier] reads the page strictly before the given event `seq`; a
         * failure it throws is rethrown, so a failed read never looks like absence.
         *
         * The walk goes to the beginning of the history. [createdAtMs] is part of
         * the entry's identity for the caller but cannot end the walk early: the
         * phone clock may have changed, so an older timestamp proves nothing.
         */
        suspend fun resolve(
            rpcId: String,
            @Suppress("UNUSED_PARAMETER") createdAtMs: Long,
            inbox: JsonValue?,
            firstPage: JsonValue?,
            maxPages: Int = DEFAULT_MAX_PAGES,
            loadEarlier: suspend (beforeSeq: Long) -> JsonValue,
        ): SendOutboxReadBack {
            var inboxKnown = false
            val inboxObject = inbox as? JsonObject
            if (inboxObject != null) {
                inboxKnown = true
                // Both lanes are required by the pinned inbox wire state.
                for (lane in INBOX_LANES) {
                    val items = (inboxObject[lane] as? JsonArray)?.values
                    if (items == null) {
                        inboxKnown = false
                        continue
                    }
                    for (item in items) {
                        val kind = sourceKind((item as? JsonObject)?.get("source"))
                        if (kind == null) {
                            inboxKnown = false
                            continue
                        }
                        if (kind.first == "user" && kind.second == rpcId) return HELD
                    }
                }
            }

            var page = firstPage
            var previousBefore: Long? = null
            var pages = 0
            var historyKnown = true
            while (page != null) {
                coroutineContext.ensureActive()
                pages += 1
                val current = page as? JsonObject ?: return INCONCLUSIVE
                val records = (current["records"] as? JsonArray)?.values ?: return INCONCLUSIVE
                val hasMore = (current["hasMore"] as? JsonBool)?.value ?: return INCONCLUSIVE
                val events = ArrayList<JsonObject>(records.size)
                for (record in records) {
                    events.add((record as? JsonObject)?.get("event") as? JsonObject ?: return INCONCLUSIVE)
                }
                for (event in events) {
                    val type = (event["type"] as? JsonString)?.value
                    if (type == null) {
                        historyKnown = false
                        continue
                    }
                    if (type != "user/message") continue
                    val kind = sourceKind((event["data"] as? JsonObject)?.get("source"))
                    if (kind == null) {
                        historyKnown = false
                        continue
                    }
                    if (kind.first == "user" && kind.second == rpcId) return JOURNALED
                }
                if (!hasMore) break
                if (pages >= maxPages) return INCONCLUSIVE
                val before = pageCursor(events) ?: return INCONCLUSIVE
                if (previousBefore != null && before >= previousBefore) return INCONCLUSIVE
                previousBefore = before
                page = loadEarlier(before)
            }
            return if (inboxKnown && historyKnown) ABSENT else INCONCLUSIVE
        }

        /** `(kind, rpcId)` of a readable message source; null when the source cannot be read. */
        private fun sourceKind(source: JsonValue?): Pair<String, String?>? {
            val value = source as? JsonObject ?: return null
            val kind = (value["kind"] as? JsonString)?.value ?: return null
            return kind to (value["rpcId"] as? JsonString)?.value
        }

        /** The smallest `seq` of the page. An unreadable `seq` rejects the page instead of skipping history. */
        private fun pageCursor(events: List<JsonObject>): Long? {
            if (events.isEmpty()) return null
            var minimum: Long? = null
            for (event in events) {
                val seq = (event["seq"] as? JsonNumber)?.asLongOrNull() ?: return null
                if (seq < 0 || seq > MAX_SAFE_INTEGER) return null
                minimum = if (minimum == null) seq else minOf(minimum, seq)
            }
            return minimum
        }
    }
}
