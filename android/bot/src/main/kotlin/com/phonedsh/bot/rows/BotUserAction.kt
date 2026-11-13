// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.bot.optionalArray
import com.phonedsh.bot.optionalString
import com.phonedsh.bot.requiredString

/** `user-action.schema.json` `kind`. */
public enum class BotUserActionKind(public val wire: String) {
    CHAT("chat"),
    CARD_ANSWER("cardAnswer"),
    CARD_DISMISS("cardDismiss"),
    APPROVAL("approval"),
    STOP_TASK("stopTask"),
    ;

    public companion object {
        public fun fromWire(value: String): BotUserActionKind =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown user action kind: $value")
    }
}

/** `user-action.schema.json` `decision`. */
public enum class BotApprovalDecision(public val wire: String) {
    ALLOW_ONCE("allowOnce"),
    ALWAYS("always"),
    DENY("deny"),
    ;

    public companion object {
        public fun fromWire(value: String): BotApprovalDecision =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown approval decision: $value")
    }
}

/**
 * A user action from the UI (`user-action.schema.json`).
 *
 * Decoding mirrors the Swift reference: a `cardAnswer` carrying `text`, any
 * action carrying `customText`, and attachments on a non-`chat` kind are
 * rejected at the decoder. Unknown members (for example the golden's expected
 * `result` envelope) are ignored, as Swift `Codable` ignores them.
 */
public data class BotUserAction(
    public val nonce: String,
    public val botID: String,
    public val kind: BotUserActionKind,
    public val text: String? = null,
    public val cardID: String? = null,
    public val optionID: String? = null,
    public val approvalID: String? = null,
    public val decision: BotApprovalDecision? = null,
    public val digest: String? = null,
    public val threadID: String? = null,
    public val attachments: List<BotAttachment>? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["nonce"] = JsonString(nonce)
        members["botID"] = JsonString(botID)
        members["kind"] = JsonString(kind.wire)
        text?.let { members["text"] = JsonString(it) }
        cardID?.let { members["cardID"] = JsonString(it) }
        optionID?.let { members["optionID"] = JsonString(it) }
        approvalID?.let { members["approvalID"] = JsonString(it) }
        decision?.let { members["decision"] = JsonString(it.wire) }
        digest?.let { members["digest"] = JsonString(it) }
        threadID?.let { members["threadID"] = JsonString(it) }
        attachments?.let { list -> members["attachments"] = JsonArray(list.map { it.toJson() }) }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotUserAction {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("user action must be an object")
            if (members.containsKey("customText")) {
                throw BotJsonException(
                    "cardAnswer must not contain customText; free-form replies use kind=chat")
            }
            val kind = BotUserActionKind.fromWire(members.requiredString("kind"))
            if (kind == BotUserActionKind.CARD_ANSWER && members.containsKey("text")) {
                throw BotJsonException(
                    "cardAnswer must not contain text; free-form replies use kind=chat")
            }
            if (kind != BotUserActionKind.CHAT && members.containsKey("attachments")) {
                throw BotJsonException("only chat actions may carry attachments")
            }
            val nonce = members.requiredString("nonce")
            val botID = members.requiredString("botID")
            val decision = members.optionalString("decision")?.let { BotApprovalDecision.fromWire(it) }
            val attachments = members.optionalArray("attachments")?.map { BotAttachment.fromJson(it) }
            return BotUserAction(
                nonce = nonce,
                botID = botID,
                kind = kind,
                text = members.optionalString("text"),
                cardID = members.optionalString("cardID"),
                optionID = members.optionalString("optionID"),
                approvalID = members.optionalString("approvalID"),
                decision = decision,
                digest = members.optionalString("digest"),
                threadID = members.optionalString("threadID"),
                attachments = attachments,
            )
        }
    }
}

/** `action-result.schema.json` `BotActionResult v1`. */
public sealed interface BotActionResult {
    public val status: String

    public data class Accepted(public val eventID: String) : BotActionResult {
        override val status: String get() = "accepted"
    }

    public data class Duplicate(public val eventID: String) : BotActionResult {
        override val status: String get() = "duplicate"
    }

    public data class Stale(public val reason: String) : BotActionResult {
        override val status: String get() = "stale"
    }

    public data class Rejected(public val reason: String) : BotActionResult {
        override val status: String get() = "rejected"
    }

    public fun toJson(): JsonObject = when (this) {
        is Accepted -> BotJson.objectOf(
            "status" to JsonString("accepted"),
            "eventID" to JsonString(eventID),
        )
        is Duplicate -> BotJson.objectOf(
            "status" to JsonString("duplicate"),
            "eventID" to JsonString(eventID),
        )
        is Stale -> BotJson.objectOf(
            "status" to JsonString("stale"),
            "reason" to JsonString(reason),
        )
        is Rejected -> BotJson.objectOf(
            "status" to JsonString("rejected"),
            "reason" to JsonString(reason),
        )
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotActionResult {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("action result must be an object")
            return when (val status = members.requiredString("status")) {
                "accepted" -> Accepted(members.requiredString("eventID"))
                "duplicate" -> Duplicate(members.requiredString("eventID"))
                "stale" -> Stale(members.requiredString("reason"))
                "rejected" -> Rejected(members.requiredString("reason"))
                else -> throw BotJsonException("unknown action result status: $status")
            }
        }
    }
}

/**
 * The pure part of the user-action admission rules.
 *
 * The nonce store is out of this lane's scope; [resolve] models the Swift
 * dispatcher's ordering by accepting the event id of an already-committed
 * nonce. It returns `null` when the action is admissible.
 */
public object BotUserActionValidation {
    public fun resolve(action: BotUserAction, alreadyCommittedEventID: String?): BotActionResult? {
        if (alreadyCommittedEventID != null) return BotActionResult.Duplicate(alreadyCommittedEventID)
        return validate(action)
    }

    public fun validate(action: BotUserAction): BotActionResult? {
        if (action.nonce.isEmpty() || action.botID.isEmpty()) {
            return BotActionResult.Rejected("invalid_action")
        }
        if (action.kind != BotUserActionKind.CHAT && action.attachments != null) {
            return BotActionResult.Rejected("unexpected_attachments")
        }
        when (action.kind) {
            BotUserActionKind.CHAT -> {
                val attachments = action.attachments ?: emptyList()
                if (attachments.size > BotAttachmentPolicy.MAX_COUNT) {
                    return BotActionResult.Rejected("too_many_attachments")
                }
                val invalid = attachments.any {
                    it.name.isEmpty() || it.path.isEmpty() || it.kind.isEmpty() || it.size < 0
                }
                if (invalid) return BotActionResult.Rejected("invalid_attachment")
                val text = (action.text ?: "").trim()
                if (text.isEmpty() && attachments.isEmpty()) {
                    return BotActionResult.Rejected("missing_text")
                }
            }
            BotUserActionKind.CARD_ANSWER -> {
                if (action.cardID.isNullOrEmpty()) return BotActionResult.Rejected("missing_card_id")
                if (action.text != null) {
                    return BotActionResult.Rejected("unexpected_card_answer_field")
                }
                if (action.optionID.isNullOrEmpty()) {
                    return BotActionResult.Rejected("missing_card_answer")
                }
            }
            BotUserActionKind.CARD_DISMISS -> {
                if (action.cardID.isNullOrEmpty()) return BotActionResult.Rejected("missing_card_id")
            }
            BotUserActionKind.APPROVAL -> {
                if (action.approvalID.isNullOrEmpty() || action.decision == null) {
                    return BotActionResult.Rejected("invalid_approval")
                }
                if (action.digest.isNullOrEmpty()) {
                    return BotActionResult.Stale("digest_mismatch")
                }
            }
            BotUserActionKind.STOP_TASK -> {
                if (action.threadID.isNullOrEmpty()) {
                    return BotActionResult.Rejected("missing_thread_id")
                }
            }
        }
        return null
    }
}

/** The event id of an accepted/duplicate result, else null. */
public val BotActionResult.eventIDOrNull: String?
    get() = when (this) {
        is BotActionResult.Accepted -> eventID
        is BotActionResult.Duplicate -> eventID
        is BotActionResult.Stale, is BotActionResult.Rejected -> null
    }

/** The reason of a stale/rejected result, else null. */
public val BotActionResult.reasonOrNull: String?
    get() = when (this) {
        is BotActionResult.Stale -> reason
        is BotActionResult.Rejected -> reason
        is BotActionResult.Accepted, is BotActionResult.Duplicate -> null
    }
