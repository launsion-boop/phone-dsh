// SPDX-License-Identifier: MIT
package com.phonedsh.bot.team

import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.rows.BotAgentRef
import com.phonedsh.bot.rows.BotTeamAgentCommRecord
import com.phonedsh.bot.wake.BotTurnAuthority
import com.phonedsh.bot.wake.BotTurnOriginKind
import com.phonedsh.bot.wake.WakeInboxEnqueue
import com.phonedsh.bot.wake.WakeInboxItem
import com.phonedsh.agentcore.JsonValue

/**
 * The hand-off hop that opened the caller's current turn.
 *
 * It is what makes an answer to the **immediate previous hop** a reply rather
 * than a cycle (`spec/bot/v1/team.md` §2.3.1): `SendToAgent` can write the
 * exchange's `reply` row and exchange-shaped held item only when it knows which
 * request/thread handed the turn over. The value is in-memory only, exactly
 * like the chain; a host that cannot supply it keeps the historical cycle
 * rejection.
 */
public data class BotAgentInboundHop(
    /** The Bot that handed the current turn to the caller (`chain[chain.size - 2]`). */
    public val senderID: String,
    /** The exchange's `requestId` (`agent:<sender callId>`). */
    public val requestID: String,
    /** The exchange's `threadID`; the reply row and held item join it. */
    public val threadID: String,
    /** How the hop was delivered: `"now"` or `"queued"`. */
    public val delivery: String,
    /** The inbound message's title, used for the held reply title. */
    public val title: String? = null,
) {
    /** `now` on both sides is the only wake combination; `queued` stays silent. */
    public fun wakesReply(replyDelivery: String): Boolean =
        delivery == "now" && replyDelivery == "now"
}

/**
 * Where one Bot stands inside the current hand-off chain.
 *
 * `depth` is the inbound hop depth (0 for a user turn). `chain` contains the
 * Bot ids already visited by the current hand-off, including the caller, so a
 * target already present in the chain is a cycle — unless it is the immediate
 * previous hop and [inbound] identifies that hop. `turn` and `existingRowIDs`
 * let the caller allocate the upstream `t<turn>u` inbound row id without
 * asking the transcript owner.
 */
public data class BotAgentCommContext(
    public val depth: Int = 0,
    public val chain: List<String> = emptyList(),
    public val turn: Int = 0,
    public val existingRowIDs: Set<String> = emptySet(),
    /** The hop that opened the current turn, or null for a user turn/legacy host. */
    public val inbound: BotAgentInboundHop? = null,
) {
    /**
     * The hop that handed the current turn to [callerID], when the chain still
     * ends with the caller and that hop is the element immediately before it.
     * This separates a legitimate reply from a real cycle; anything else returns
     * null and follows the frozen v1 depth/cycle rejection.
     */
    public fun immediatePreviousHop(callerID: String): BotAgentInboundHop? {
        val hop = inbound ?: return null
        if (depth < 1 || callerID.isEmpty() || chain.size < 2) return null
        if (chain.last() != callerID) return null
        if (chain[chain.size - 2] != hop.senderID) return null
        if (hop.senderID == callerID) return null
        return hop
    }
}

/**
 * One `now` delivery. The host opens (or queues behind) a visible target turn
 * and resolves with the final assistant text. A busy target is queued, never
 * interrupted. Cancelling the waiting coroutine must stop waiting; the target
 * turn itself may still finish.
 */
public data class BotAgentDeliveryRequest(
    public val sender: BotAgentRef,
    public val target: BotAgentRef,
    /** Full prompt: `[agent] <name> (id: <id>)[ — <title>]: <message>`. */
    public val promptText: String,
    public val message: String,
    public val title: String?,
    public val threadId: String,
    public val requestId: String,
    public val delivery: String = "now",
    public val hop: Int,
    /** Chain the target must use for its own SendToAgent calls; includes sender and target. */
    public val chain: List<String>,
)

public data class BotAgentDeliveryReply(
    public val text: String,
    public val replyEntryId: String? = null,
    public val status: String? = null,
)

public data class BotTeamHeldRequest(
    public val botID: String,
    public val item: WakeInboxItem,
    /**
     * The in-progress hand-off this held message opens, or null when the item
     * is a reply/notification rather than a new hop. A reply must not extend
     * the chain or the sender of the original message would look like it is
     * already inside the chain and its next send would be rejected as a cycle.
     */
    public val handOff: BotAgentCommContext? = null,
    /**
     * Best-effort single wake of [botID] after the item is durably enqueued.
     * Only an explicit reply to a `now` hand-off sets this (`team.md` §2.3.1);
     * queued deliveries and automatic held replies leave it `false` and stay
     * silent. A duplicate enqueue never wakes.
     */
    public val wake: Boolean = false,
)

public sealed class BotTeamHostError(message: String) : Exception(message) {
    public class BotNotFound(public val id: String) : BotTeamHostError("Unknown Bot: $id")

    public class InvalidTarget(public val reason: String) :
        BotTeamHostError("Invalid agent target: $reason")

    public object DeliveryTimeout : BotTeamHostError("目标 Bot 未在时限内完成回合。")

    public class DeliveryFailed(public val reason: String) :
        BotTeamHostError("Agent delivery failed: $reason")

    public class Rejected(public val reason: String) : BotTeamHostError(reason)
}

/**
 * Who asked for a teammate Bot. The description enters the new Bot's persona,
 * so the authoring turn is recorded durably when the Bot is created.
 */
public data class BotTeammateAuthor(
    public val origin: BotTurnOriginKind,
    public val authorization: Authorization,
    public val rpcId: String? = null,
    public val turnId: String? = null,
    public val sessionId: String? = null,
    public val approvalID: String? = null,
) {
    public enum class Authorization(public val wire: String) {
        USER_TURN("user-turn"),
        USER_CONFIRMED("user-confirmed"),
    }

    public fun toJson(): com.phonedsh.agentcore.JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        rpcId?.let { members["rpcId"] = com.phonedsh.agentcore.JsonString(it) }
        turnId?.let { members["turnId"] = com.phonedsh.agentcore.JsonString(it) }
        sessionId?.let { members["sessionId"] = com.phonedsh.agentcore.JsonString(it) }
        members["origin"] = com.phonedsh.agentcore.JsonString(origin.rawValue)
        members["authorization"] = com.phonedsh.agentcore.JsonString(authorization.wire)
        approvalID?.let { members["approvalID"] = com.phonedsh.agentcore.JsonString(it) }
        return com.phonedsh.agentcore.JsonObject(members)
    }

    public companion object {
        /**
         * A non-user author must already carry the approval that allowed the
         * creation; the tool refuses to fabricate `user-confirmed` without it.
         */
        public fun fromAuthority(authority: BotTurnAuthority): BotTeammateAuthor? {
            if (authority.isUserTurn) {
                return BotTeammateAuthor(
                    origin = authority.origin,
                    authorization = Authorization.USER_TURN,
                    rpcId = authority.rpcId,
                    turnId = authority.turnId,
                    sessionId = authority.sessionId,
                )
            }
            val approvalID = authority.approvalId
            if (approvalID.isNullOrEmpty()) return null
            return BotTeammateAuthor(
                origin = authority.origin,
                authorization = Authorization.USER_CONFIRMED,
                rpcId = authority.rpcId,
                turnId = authority.turnId,
                sessionId = authority.sessionId,
                approvalID = approvalID,
            )
        }
    }
}

/**
 * The host seam the App layer implements.
 *
 * The tools only see this interface, so a test can inject a fake roster,
 * delivery queue and held inbox. The live per-Bot turn and the durable
 * `agent.comm` row are owned by the App; this module only knows the seam.
 */
public interface BotTeamHost {
    /** Full roster, including hidden Bots and the repaired main-Bot pointer. */
    public suspend fun roster(): BotRoster

    /**
     * Create one Bot. `color`/`hairstyle` null means "let the profile store
     * choose the explicit blue/long default".
     */
    public suspend fun createBot(
        name: String,
        description: String,
        color: BotFishColor?,
        hairstyle: BotFishHairstyle?,
        author: BotTeammateAuthor?,
    ): BotProfile

    /** Current hand-off context for the Bot that is calling a team tool. */
    public suspend fun agentCommContext(botID: String): BotAgentCommContext

    /**
     * Idempotency lookup: the thread already opened for this request id, or
     * null. Outbound rows are keyed by `requestID`; `reply` rows keep the
     * exchange `requestID` and are also indexed by their `callID`
     * (`team.md` §2.4, §2.9).
     */
    public suspend fun existingAgentCommThread(botID: String, requestID: String): String?

    /**
     * Open (or queue behind) a visible target turn and await its final text.
     *
     * For the duration of the target turn the host installs an active context
     * on the target (`depth = request.hop`, `chain = request.chain`) **including**
     * the [BotAgentInboundHop] built from this request, then releases it; that
     * is what lets the target answer the sender with `SendToAgent` (`team.md`
     * §2.3.1).
     */
    public suspend fun deliverToAgent(request: BotAgentDeliveryRequest): BotAgentDeliveryReply

    /**
     * Enqueue one held item for `request.botID`; the key is `item.requestId`.
     * A non-null [BotTeamHeldRequest.handOff] installs a one-shot pending context
     * (chain and inbound) consumed by the target's next team-tool call.
     * [BotTeamHeldRequest.wake] asks for one best-effort wake after a
     * non-duplicate enqueue; a duplicate never wakes.
     */
    public suspend fun enqueueHeld(request: BotTeamHeldRequest): WakeInboxEnqueue

    /** Persist one agent-comm row for `record.botID` and bump unread. */
    public suspend fun recordAgentComm(record: BotTeamAgentCommRecord)
}

