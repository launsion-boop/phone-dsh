// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.probe.outbox.DurableFileStore
import java.io.File
import java.nio.file.Files
import java.nio.file.NoSuchFileException

internal enum class WakeDemandSource { botRoutine, connectorScan, dshSchedule, hostRetry }
internal enum class WakeDemandKind { once, recurring }

internal data class WakeDemandKey(val source: WakeDemandSource, val key: String) {
    init { require(key.matches(Regex("[A-Za-z0-9._:-]{1,128}"))) }
}

internal data class WakeDemand(
    val identity: WakeDemandKey,
    val dueAtMs: Long,
    val kind: WakeDemandKind,
    val userVisible: Boolean,
) {
    init { require(dueAtMs >= 0) }

    fun toJson() = JsonObject(mapOf(
        "source" to JsonString(identity.source.name),
        "key" to JsonString(identity.key),
        "dueAtMs" to JsonNumber(dueAtMs.toString()),
        "kind" to JsonString(kind.name),
        "userVisible" to JsonBool(userVisible),
    ))

    companion object {
        fun fromJson(json: JsonValue): WakeDemand {
            val row = json as? JsonObject ?: error("Expected a wake demand object")
            require(row.members.keys == setOf("source", "key", "dueAtMs", "kind", "userVisible"))
            return WakeDemand(
                WakeDemandKey(
                    WakeDemandSource.valueOf((row["source"] as JsonString).value),
                    (row["key"] as JsonString).value,
                ),
                requireNotNull((row["dueAtMs"] as JsonNumber).asLongOrNull()),
                WakeDemandKind.valueOf((row["kind"] as JsonString).value),
                (row["userVisible"] as JsonBool).value,
            )
        }
    }
}

internal data class WakeProjection(
    val residentTimerAtMs: Long?,
    val backgroundEarliestMs: Long?,
    val dueNow: List<WakeDemandKey>,
) {
    companion object {
        const val MIN_BACKGROUND_DELAY_MS = 60_000L

        fun plan(nowMs: Long, resident: Boolean, demands: List<WakeDemand>): WakeProjection {
            require(nowMs in 0..Long.MAX_VALUE - MIN_BACKGROUND_DELAY_MS)
            require(demands.map { it.identity }.toSet().size == demands.size)
            val sorted = demands.sortedWith(compareBy(
                { it.dueAtMs }, { it.identity.source.ordinal }, { it.identity.key },
            ))
            val earliest = sorted.firstOrNull()?.dueAtMs ?: return WakeProjection(null, null, emptyList())
            return WakeProjection(
                if (resident) maxOf(nowMs, earliest) else null,
                maxOf(nowMs + MIN_BACKGROUND_DELAY_MS, earliest),
                sorted.takeWhile { it.dueAtMs <= nowMs }.map { it.identity },
            )
        }
    }
}

/** Each mutation reads the current snapshot first. An unreadable snapshot is never replaced. */
internal class WakeDemandLedger(
    private val file: File,
    private val storage: DurableFileStore = DurableFileStore(),
) {
    @Synchronized
    fun read(): List<WakeDemand> {
        val bytes = try {
            Files.readAllBytes(file.toPath())
        } catch (_: NoSuchFileException) {
            return emptyList()
        }
        val rows = (JsonValue.parse(bytes.toString(Charsets.UTF_8)) as JsonArray).values.map(WakeDemand::fromJson)
        require(rows.map { it.identity }.toSet().size == rows.size)
        return rows
    }

    @Synchronized
    fun update(identity: WakeDemandKey, demand: WakeDemand?) {
        require(demand == null || demand.identity == identity)
        val before = read().associateBy { it.identity }
        if (before[identity] == demand) return
        val next = before.toMutableMap()
        if (demand == null) next.remove(identity) else next[identity] = demand
        val encoded = JsonArray(next.values.map(WakeDemand::toJson)).toJsonString()
        storage.writeAtomically(file, encoded.toByteArray(Charsets.UTF_8))
    }
}
