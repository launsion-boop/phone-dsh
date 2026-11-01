// Host contract 1 — the DSH authoring type to host event projection.
// SPDX-License-Identifier: MIT
//
// Input is one `session/follow` event as the Worker wrote it (`type`, `seq`,
// `data`); output is the host event of `spec/host/v1/event-kinds.md` §1, or
// nothing when the table has no row. The rules implemented here are the table's,
// not an invention:
//
//  * a DSH type with no row is dropped and its `seq` still counts as consumed
//    (host README §2.2 rule 2);
//  * `seq` is copied only when the Worker supplied one; a best-effort event has
//    no `seq` and never becomes a durable row;
//  * `turn-%04d` comes from `data.turn` (the goldens' shape), with
//    `data.turn_id` accepted for the two turn-edge types whose schema names an
//    integer `turn_id`;
//  * one `assistant/message` that carries `data.usage` yields the
//    `assistant_message` row and the folded `usage` row (event-kinds.md §1).
//
// This package is the only vocabulary translation in the Android tree. Neither
// the UI nor the turn client renames a Worker type itself.

package com.phonedsh.hostevents

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.util.Locale

/**
 * One host event projected from a Worker `session/follow` event.
 *
 * @param kind the closed host kind.
 * @param seq the Worker's durable `seq`, or `null` when the source was best
 *   effort and carried none.
 * @param dshType the Worker's authoring type, verbatim.
 * @param turnId `turn-%04d` when the source named a turn, else `null`.
 * @param data the source's `data` object, or `null`.
 * @param raw the complete source object, untouched.
 */
data class HostEvent(
    val kind: HostEventKind,
    val seq: Long?,
    val dshType: String,
    val turnId: String?,
    val data: JsonObject?,
    val raw: JsonObject,
) {
    /** `true` when the Worker put a durable seq on this source event. */
    val durable: Boolean get() = seq != null

    /** The trajectory row type of event-kinds.md §1, or `null`. */
    val projectionType: String? get() = kind.projectionType

    /** `data.reason.kind` for `turn_ended`, else `null`. */
    val turnEndReason: String? get() {
        if (kind != HostEventKind.TURN_ENDED) return null
        val reason = data?.get("reason") as? JsonObject ?: return null
        return (reason["kind"] as? JsonString)?.value
    }

    /** A one-line, logcat-friendly projection; never the event body. */
    fun describe(): String = buildString {
        append("kind=").append(kind.wire)
        append(" dsh=").append(dshType)
        append(" seq=").append(seq ?: "-")
        if (turnId != null) append(" turn=").append(turnId)
        when (kind) {
            HostEventKind.TOOL_CALL -> {
                text("name")?.let { append(" tool=").append(it) }
                text("callId")?.let { append(" call=").append(it) }
            }

            HostEventKind.TOOL_RESULT -> {
                text("callId")?.let { append(" call=").append(it) }
                (data?.get("isError") as? JsonBool)?.value?.let { append(" isError=").append(it) }
            }

            HostEventKind.TURN_ENDED -> turnEndReason?.let { append(" reason=").append(it) }
            else -> Unit
        }
    }

    private fun text(name: String): String? = (data?.get(name) as? JsonString)?.value

    companion object {
        /**
         * Projects one Worker event, or returns `null` when event-kinds.md §1
         * has no row for its type.
         */
        fun project(raw: JsonObject): HostEvent? {
            val dshType = (raw["type"] as? JsonString)?.value ?: return null
            val kind = HostEventProjection.hostKindOf(dshType) ?: return null
            return build(kind, dshType, raw)
        }

        internal fun build(kind: HostEventKind, dshType: String, raw: JsonObject): HostEvent {
            val seq = (raw["seq"] as? JsonNumber)?.asLongOrNull()
            val data = raw["data"] as? JsonObject
            return HostEvent(
                kind = kind,
                seq = seq,
                dshType = dshType,
                turnId = turnIdOf(data),
                data = data,
                raw = raw,
            )
        }

        private fun turnIdOf(data: JsonObject?): String? {
            if (data == null) return null
            val turn = (data["turn"] as? JsonNumber)?.asLongOrNull()
                ?: (data["turn_id"] as? JsonNumber)?.asLongOrNull()
                ?: return null
            return String.format(Locale.ROOT, "turn-%04d", turn)
        }
    }
}

/**
 * The table of event-kinds.md §1, applied to the Worker's authoring types.
 *
 * The five kinds with no production producer today (`assistant_delta`,
 * `reasoning_delta`, `progress`, `exited`, `inbox_spliced`) are not reachable
 * from a DSH authoring type in this tree; they stay in [HostEventKind] because
 * a consumer must still recognise them if a newer Worker sends one.
 */
object HostEventProjection {
    private val DSH_TO_HOST: Map<String, HostEventKind> = mapOf(
        "assistant/message" to HostEventKind.ASSISTANT_MESSAGE,
        "permission/request" to HostEventKind.PERMISSION_REQUESTED,
        "question/request" to HostEventKind.QUESTION_REQUESTED,
        "session/start" to HostEventKind.SESSION_STATUS,
        "tool/call" to HostEventKind.TOOL_CALL,
        "tool/result" to HostEventKind.TOOL_RESULT,
        "turn/end" to HostEventKind.TURN_ENDED,
        "turn/start" to HostEventKind.TURN_STARTED,
        "user/message" to HostEventKind.USER_MESSAGE,
    )

    /** The host kind for one Worker authoring type, or `null` when there is no row. */
    fun hostKindOf(dshType: String): HostEventKind? = DSH_TO_HOST[dshType]

    /**
     * Every host event one Worker event yields.
     *
     * Almost always zero or one. The one exception is the folded `usage` row of
     * event-kinds.md §1: an `assistant/message` carrying `data.usage` yields
     * `assistant_message` and `usage` with the same seq.
     */
    fun projectAll(raw: JsonObject): List<HostEvent> {
        val primary = HostEvent.project(raw) ?: return emptyList()
        if (primary.kind != HostEventKind.ASSISTANT_MESSAGE) return listOf(primary)
        val usage = primary.data?.get("usage") as? JsonObject ?: return listOf(primary)
        val folded = HostEvent(
            kind = HostEventKind.USAGE,
            seq = primary.seq,
            dshType = primary.dshType,
            turnId = primary.turnId,
            data = usage,
            raw = primary.raw,
        )
        return listOf(primary, folded)
    }

    /** Every durable event a `session/follow` snapshot carries, in record order. */
    fun projectSnapshot(value: JsonObject): List<HostEvent> {
        val records = value["records"] as? JsonArray ?: return emptyList()
        val events = ArrayList<HostEvent>(records.values.size)
        for (record in records.values) {
            val event = (record as? JsonObject)?.get("event") as? JsonObject ?: continue
            events += projectAll(event)
        }
        return events
    }

    /** The host kind names, in the order of the enum (all fifteen). */
    fun kindNames(): List<String> = HostEventKind.entries.map { it.wire }

    /** `true` when [value] is a JSON object with a `type` string. */
    fun looksLikeEvent(value: JsonValue?): Boolean =
        value is JsonObject && value["type"] is JsonString
}
