// phone-dsh — :dsh / com.phonedsh.dsh.journal: the journaled-and-durable prune rule.
// SPDX-License-Identifier: MIT
//
// ---- the rule budgets.md §5 states ----------------------------------------
// "Journal | 64 MiB | Prune entries whose step is `journaled` and durable; still
// over → Failed." The store contains only durable bytes — a record is appended
// and fsynced before its ACK, and the one non-durable shape (a torn tail) is
// truncated during recovery before any prune can see it. So the decision this
// file makes is the *other* half of the sentence: **is the entry's step
// `journaled`?**
//
// ---- how a step is identified ---------------------------------------------
// D13 records a step per tool call and locates it by `(session, turn, step)`.
// The store is already per session, so the key here is `turn_id + step_id`;
// when a record carries no `step_id` the idempotency `key` (then `call_id`) is
// the fallback, because `exec.md` §1 derives the key from the same call. A
// record with no locator at all is never pruned: it may be evidence for a step
// this host cannot name yet, and budgets.md forbids dropping that silently.
//
// ---- what "journaled" means ------------------------------------------------
// `exec.md` §4 state 7: "the journal's completed record is durable". In the
// wire projection the worker emits `completed` for a finished call and
// `resolved` for a settled interrupted call, so the step is journaled once one
// of those terminal records **for the same step key** is in the store. The
// whole step group is then prunable, not just the terminal line: the
// `dispatched` record of a completed step is no longer evidence anything can
// need, and dropping a group atomically keeps the file's remaining records a
// consistent observation log.
//
// ---- why the record is parsed at all --------------------------------------
// The wire record is opaque, but pruning is explicitly a policy over the D13
// step state, and the host does not own a step log yet (exec.md §4: the App
// writes `steps/<session>.ndjson`). Until that store is injectable, the only
// in-host evidence for "journaled" is the record's own `type` and locator. The
// parse is tolerant on purpose: anything unreadable is *retained* (fail safe).

package com.phonedsh.dsh.journal

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * The `budgets.md` §5 prune decision, as a pure function over record facts.
 *
 * Nothing here touches a file: [JournalStore] reads the entries and this object
 * answers which groups may be dropped, so the data-safety rule can be tested
 * without a filesystem (the same split as `:core`'s `DroppableRule`).
 */
internal object JournalPruneRule {
    /**
     * The two facts a prune decision needs from one opaque record.
     *
     * @property stepKey the D13 locator, or `null` when the record is not JSON
     *   or carries no `turn_id`/`step_id`/`key`/`call_id`.
     * @property terminal `true` for the worker's `completed`/`resolved`
     *   projection, the record that makes a step `journaled` (exec.md §4).
     */
    data class Facts(val stepKey: String?, val terminal: Boolean)

    /** A record that cannot be read is retained: fail safe, never fail open. */
    val UNPRUNABLE: Facts = Facts(stepKey = null, terminal = false)

    /**
     * Reads [record]'s locator and terminal flag.
     *
     * A non-JSON record, a non-object, or a missing member yields a fact that
     * cannot be pruned; it never throws, because a prune must not be able to
     * turn a future record dialect into a host failure.
     */
    fun facts(record: ByteArray): Facts {
        val value = try {
            JsonValue.parse(String(record, Charsets.UTF_8))
        } catch (_: RuntimeException) {
            return UNPRUNABLE
        }
        val objectValue = value as? JsonObject ?: return UNPRUNABLE
        val type = (objectValue["type"] as? JsonString)?.value
        val step = (objectValue["step_id"] as? JsonString)?.value
        val turn = (objectValue["turn_id"] as? JsonString)?.value
        val key = (objectValue["key"] as? JsonString)?.value
            ?: (objectValue["call_id"] as? JsonString)?.value
        val stepKey = when {
            step != null && turn != null -> "$turn\n$step"
            step != null -> step
            key != null -> key
            else -> null
        }
        val terminal = type == COMPLETED || type == RESOLVED
        return Facts(stepKey = stepKey, terminal = terminal)
    }

    /**
     * The groups that may be dropped, oldest first.
     *
     * A group is every entry sharing one [Facts.stepKey], and it is included
     * only when at least one of its entries is [Facts.terminal]. The returned
     * index arrays are ordered by their first entry, so a caller that stops
     * early always frees the oldest journaled evidence first.
     */
    fun droppableGroups(entries: List<Facts>): List<IntArray> {
        val byStep = LinkedHashMap<String, MutableList<Int>>()
        val terminalSteps = HashSet<String>()
        for ((index, facts) in entries.withIndex()) {
            val key = facts.stepKey ?: continue
            byStep.getOrPut(key) { ArrayList() }.add(index)
            if (facts.terminal) terminalSteps.add(key)
        }
        return byStep.entries
            .filter { it.key in terminalSteps }
            .sortedBy { it.value.first() }
            .map { it.value.toIntArray() }
    }

    /** The worker's wire projection of a completed call (`exec.md` §4). */
    private const val COMPLETED = "completed"

    /** The worker's wire projection of a settled interrupted call. */
    private const val RESOLVED = "resolved"
}
