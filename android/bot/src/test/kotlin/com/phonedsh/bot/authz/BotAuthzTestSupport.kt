// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import org.junit.Assert.assertEquals

class MutableClock(var value: Long)

/** In-memory implementation of the port the B5a1 adapter will back by P25. */
class InMemoryAuthzEventLog : BotAuthzEventLog {
    private var nextSequence = 0L
    private val stored = ArrayList<BotAuthzEvent>()

    @Synchronized
    fun all(): List<BotAuthzEvent> = stored.toList()

    @Synchronized
    override fun append(event: BotAuthzEvent): Long {
        val sequence = ++nextSequence
        stored += event.copy(sequence = sequence)
        return sequence
    }

    @Synchronized
    override fun events(after: Long, limit: Int): List<BotAuthzEvent> =
        stored.filter { it.sequence > after }.take(limit)
}

/** Deterministic timer used instead of sleeping on the real wall clock. */
class ManualApprovalScheduler(private val clock: MutableClock) : BotApprovalScheduler {
    private data class Task(val due: Long, val action: () -> Unit, var cancelled: Boolean = false)

    private val tasks = ArrayList<Task>()

    override fun schedule(delayMilliseconds: Long, action: () -> Unit): BotApprovalCancellation {
        val task = Task(clock.value + maxOf(0L, delayMilliseconds), action)
        tasks += task
        return BotApprovalCancellation { task.cancelled = true }
    }

    /** Advances the injected clock to [clock].value + [milliseconds] and fires due tasks. */
    fun advanceBy(milliseconds: Long) {
        val target = clock.value + milliseconds
        while (true) {
            val due = tasks.filter { !it.cancelled && it.due <= target }
                .minByOrNull { it.due } ?: break
            tasks.remove(due)
            clock.value = maxOf(clock.value, due.due)
            due.action()
        }
        clock.value = target
    }

    fun runDue() {
        val target = clock.value
        while (true) {
            val due = tasks.filter { !it.cancelled && it.due <= target }
                .minByOrNull { it.due } ?: break
            tasks.remove(due)
            due.action()
        }
    }
}

fun assertJsonEquals(message: String, expected: JsonValue, actual: JsonValue) {
    assertEquals(message, BotJson.canonical(expected), BotJson.canonical(actual))
}

fun jsonObject(vararg pairs: Pair<String, JsonValue>): JsonObject = BotJson.objectOf(*pairs)
