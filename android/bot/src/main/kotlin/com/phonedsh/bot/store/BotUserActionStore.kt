// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionValidation

/** The plan a P27 planner commits for one user action (`store.md` §10.1). */
public data class BotUserActionPlan(
    public val event: BotEvent,
    public val effects: List<BotEffect> = emptyList(),
)

/**
 * The one user-action transaction (`store.md` §10.3). Validation and the
 * nonce/event/effect conflict checks run before any write; the event, every
 * effect enqueue event/row and the nonce commit or roll back together.
 */
public class BotUserActionTransaction(
    private val store: BotDomainStore,
    private val outbox: BotEffectOutbox,
) {
    public fun performAndRecord(action: BotUserAction, plan: BotUserActionPlan): BotActionResult =
        store.inTransaction {
            // 1. Nonce lookup. A duplicate is keyed by (botID, nonce), never by
            // the retry's event id or plan.
            val existing = nonceEventID(action.botID, action.nonce)
            if (existing != null) return@inTransaction BotActionResult.Duplicate(existing)

            // 2. Frozen action validation; no write and no nonce consumption.
            BotUserActionValidation.validate(action)?.let { return@inTransaction it }

            // 3. The plan envelope: durable and owned by the action's Bot.
            BotEventCodec.validate(plan.event, BotEventCodec.Mode.APPEND)
            if (BotEventCodec.isEphemeral(plan.event.type) ||
                plan.event.principal.botId != action.botID
            ) {
                throw invalidTransition("action event must be durable and belong to the action bot")
            }

            // 4. A different nonce reusing an event id is an invalid transition,
            // not a duplicate.
            if (store.existingSequence(plan.event.eventId) != null) {
                throw invalidTransition("action eventId already exists: ${plan.event.eventId}")
            }

            // 5. Effect keys are unique in the plan and absent from the outbox.
            val keys = HashSet<String>()
            for (effect in plan.effects) {
                if (!keys.add(effect.effectKey)) {
                    throw invalidTransition("duplicate effectKey in action plan: ${effect.effectKey}")
                }
                if (outbox.effectRecord(effect.effectKey) != null) {
                    throw invalidTransition("action effectKey already exists: ${effect.effectKey}")
                }
            }

            // 6. The action event.
            val sequence = store.headCommitSeqInternal() + 1
            store.insertEvent(plan.event, sequence)

            // 7. Effects occupy contiguous sequences after the action event.
            for (effect in plan.effects) outbox.enqueueEffectInTransaction(effect)

            // 8. The nonce.
            store.driver.execute(
                "INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq) " +
                    "VALUES (?, ?, ?, ?)",
                listOf(
                    SqlValue.Text(action.botID), SqlValue.Text(action.nonce),
                    SqlValue.Text(plan.event.eventId), SqlValue.Integer(sequence),
                ),
            )
            store.checkCrashPoint("user-action-nonce")
            BotActionResult.Accepted(plan.event.eventId)
        }

    private fun nonceEventID(botID: String, nonce: String): String? {
        val row = store.driver.query(
            "SELECT event_id, created_commit_seq FROM bot_user_action_nonces " +
                "WHERE bot_id = ? AND nonce = ?",
            listOf(SqlValue.Text(botID), SqlValue.Text(nonce)),
        ).firstOrNull() ?: return null
        val eventID = row.text("event_id")
            ?: throw corrupted("invalid bot_user_action_nonces row")
        val created = row.integer("created_commit_seq")
            ?: throw corrupted("invalid bot_user_action_nonces row")
        val header = store.driver.query(
            "SELECT commit_seq FROM bot_event_headers WHERE event_id = ?",
            listOf(SqlValue.Text(eventID)),
        ).firstOrNull()
        if (header?.integer("commit_seq") != created) {
            throw corrupted("user action nonce does not reference its committed event")
        }
        return eventID
    }
}
