// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.SqliteJdbcDriver
import com.phonedsh.bot.wake.BotWakeInboxStore
import com.phonedsh.bot.wake.WakeInbox
import org.junit.Assert.assertEquals
import java.nio.file.Files
import java.nio.file.Path
import java.time.LocalDateTime
import java.time.ZoneId

/** Reads a `spec/bot/v2/golden/<name>.json` vector from disk. */
object V2Golden {
    fun load(name: String): JsonObject {
        val path = GoldenFixture.repoRoot.resolve("spec/bot/v2/golden/$name.json")
        return JsonValue.parse(Files.readString(path)) as JsonObject
    }

    fun parse(text: String): JsonValue = JsonValue.parse(text)

    fun canonical(value: JsonValue): String = BotJson.canonical(value)

    /**
     * Ignores explicit `null` members so a golden that writes `"x": null` can be
     * compared with the writer's omitted form (CCR-7: absent ≡ null).
     */
    fun dropNulls(value: JsonValue): JsonValue = when (value) {
        is JsonObject -> JsonObject(
            value.members.mapNotNull { (key, member) ->
                if (member is JsonNull) null else key to dropNulls(member)
            }.toMap(LinkedHashMap()),
        )
        is JsonArray -> JsonArray(value.values.map(::dropNulls))
        else -> value
    }

    fun assertEquivalent(expected: JsonValue, actual: JsonValue, message: String) {
        assertEquals(message, canonical(dropNulls(expected)), canonical(dropNulls(actual)))
    }

    fun at(value: JsonValue?, vararg path: String): JsonValue? {
        var current = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key) ?: return null
        }
        return current
    }

    fun string(value: JsonValue?, vararg path: String): String {
        val found = at(value, *path) as? com.phonedsh.agentcore.JsonString
            ?: throw AssertionError("missing string at ${path.joinToString(".")}")
        return found.value
    }

    fun long(value: JsonValue?, vararg path: String): Long {
        val found = at(value, *path) as? com.phonedsh.agentcore.JsonNumber
            ?: throw AssertionError("missing number at ${path.joinToString(".")}")
        return found.asLongOrNull() ?: throw AssertionError("not an integer at ${path.joinToString(".")}")
    }

    fun objects(value: JsonValue?, vararg path: String): List<JsonValue> =
        (at(value, *path) as? JsonArray)?.values ?: emptyList()
}

/** A manually advanced clock; every scheduler test uses one. */
class FakeClock(var now: Long) {
    fun advance(milliseconds: Long): Long {
        now += milliseconds
        return now
    }

    fun set(milliseconds: Long) {
        now = milliseconds
    }
}

fun epoch(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: String): Long =
    LocalDateTime.of(year, month, day, hour, minute, second)
        .atZone(ZoneId.of(zone))
        .toInstant()
        .toEpochMilli()

/**
 * A throwaway SQLite P25 store plus the routine/held-inbox views over it. The
 * same `BotDomainStore` instance backs both, which is exactly how the host
 * wires them: one event log, no second authority.
 */
class RoutineTestHarness(clock: FakeClock = FakeClock(0)) : AutoCloseable {
    val clock: FakeClock = clock
    val file: Path = Files.createTempFile("pdsh-routines", ".sqlite")

    val domain: BotDomainStore
    val routines: BotRoutineStore
    val machine: RoutineMachine
    val inbox: WakeInbox

    init {
        Files.deleteIfExists(file)
        domain = BotDomainStore(SqliteJdbcDriver(file.toString()), clock = { this.clock.now })
        routines = BotRoutineStore(domain, clock = { this.clock.now })
        machine = RoutineMachine(routines)
        inbox = WakeInbox(BotWakeInboxStore(domain, clock = { this.clock.now }), "main")
    }

    /** A fresh store view over the same log, as a restarted process would build. */
    fun reopenedRoutines(): RoutineMachine =
        RoutineMachine(BotRoutineStore(domain, clock = { this.clock.now }))

    fun reopenedInbox(): WakeInbox =
        WakeInbox(BotWakeInboxStore(domain, clock = { this.clock.now }), "main")

    fun eventTypes(): List<String> = domain.events(0, 10_000).map { it.type }

    fun eventCount(): Long = domain.headCommitSeq()

    override fun close() {
        runCatching { domain.close() }
        runCatching { Files.deleteIfExists(file) }
    }
}

/** Records the delivery rows the host would render. */
class RecordingResultSink : RoutineResultSink {
    val delivered = ArrayList<RoutineAutomation>()

    var failNext: Boolean = false

    override fun deliver(automation: RoutineAutomation): Boolean {
        if (failNext) {
            failNext = false
            throw RoutineError.InvalidRoutine("sink exploded")
        }
        delivered += automation
        return true
    }
}

/** A runner whose handles are controlled by the test. */
class ScriptedRunner : RoutineRunner {
    inner class Handle(val request: RoutineRunRequest) : RoutineRunHandle {
        var result: RoutineExecutionResult? = null
        var cancelResult: RoutineCancellationResult = RoutineCancellationResult(cancelled = true)
        var cancelCalls: Int = 0

        fun finish(result: RoutineExecutionResult) {
            this.result = result
        }

        override fun resultOrNull(): RoutineExecutionResult? = result

        override fun cancel(reason: String): RoutineCancellationResult {
            cancelCalls++
            return cancelResult
        }
    }

    val started = ArrayList<Handle>()
    var onStart: (Handle) -> Unit = { }

    override fun start(request: RoutineRunRequest): RoutineRunHandle {
        val handle = Handle(request)
        started += handle
        onStart(handle)
        return handle
    }
}
