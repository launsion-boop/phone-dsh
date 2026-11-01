// Host contract 1 — the seven commands and their value types.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * One command the host sends to one harness session.
 *
 * The session id is carried by [AgentHarness.send], not by this object. `kind`
 * is the only discriminator and the variant set is closed by
 * `spec/host/v1/schema/harness-command.schema.json`.
 *
 * **Idempotency.** [Prompt], [Steer], [PermissionResponse] and
 * [QuestionResponse] carry a `request_id` and are idempotent by it: sending the
 * same command twice must execute at most once. That guarantee is the
 * *backend's* obligation (a backend deduplicates on `request_id`); the host
 * still sends one command per call. [Cancel], [CancelWithCause] and [Shutdown]
 * have no `request_id` on the wire — the schema deliberately does not key them
 * — so [requestId] is `null` for those three and a repeated send is simply a
 * repeated (harmless) operation, not a deduplicated one.
 */
public sealed interface HarnessCommand {
    /** The wire discriminator. */
    public val kind: Kind

    /**
     * The idempotency key when the contract defines one, else `null`.
     *
     * A decoder must never invent one for [Cancel], [CancelWithCause] or
     * [Shutdown]: the schema has no such member on those variants and
     * `additionalProperties` is `false`.
     */
    public val requestId: String?

    /** The seven command kinds, in schema order. */
    public enum class Kind(public val wire: String) {
        PROMPT("prompt"),
        STEER("steer"),
        CANCEL("cancel"),
        CANCEL_WITH_CAUSE("cancel_with_cause"),
        PERMISSION_RESPONSE("permission_response"),
        QUESTION_RESPONSE("question_response"),
        SHUTDOWN("shutdown"),
        ;

        public companion object {
            public fun fromWire(wire: String): Kind? = entries.firstOrNull { it.wire == wire }
        }
    }

    /**
     * Starts a new turn. `request_id` makes it idempotent.
     *
     * Attachments are optional; a backend with image support accepts image
     * attachments and must reject other MIME types with `unsupported`.
     */
    public data class Prompt(
        public val text: String,
        override val requestId: String,
        public val attachments: List<HarnessAttachment> = emptyList(),
    ) : HarnessCommand {
        override val kind: Kind get() = Kind.PROMPT
    }

    /**
     * Adds guidance to the running turn.
     *
     * Legal only while a turn runs and only when
     * [HarnessCapabilities.steer] is `true`; otherwise the backend reports
     * `invalid_request`.
     */
    public data class Steer(
        public val text: String,
        override val requestId: String,
    ) : HarnessCommand {
        override val kind: Kind get() = Kind.STEER
    }

    /** Cancels the running turn without a cause on the wire. */
    public data object Cancel : HarnessCommand {
        override val kind: Kind get() = Kind.CANCEL
        override val requestId: String? get() = null
    }

    /**
     * Cancels the running turn with a cause the backend can journal.
     *
     * A backend that cannot carry a cause may treat it as [Cancel].
     */
    public data class CancelWithCause(public val cause: AgentCancelCause) : HarnessCommand {
        override val kind: Kind get() = Kind.CANCEL_WITH_CAUSE
        override val requestId: String? get() = null
    }

    /**
     * Answers a [HarnessKind.PermissionRequested].
     *
     * A backend without "always" degrades [PermissionDecision.ALLOW_ALWAYS] to
     * once and asks again next turn.
     */
    public data class PermissionResponse(
        override val requestId: String,
        public val decision: PermissionDecision,
    ) : HarnessCommand {
        override val kind: Kind get() = Kind.PERMISSION_RESPONSE
    }

    /**
     * Answers a [HarnessKind.QuestionRequested].
     *
     * [answer] is always a string: when it parses as a JSON object it maps
     * question ids to selections, otherwise it is the free-text answer.
     * Answering a request the backend no longer holds is `invalid_request`,
     * never a silent drop.
     */
    public data class QuestionResponse(
        override val requestId: String,
        public val answer: String,
    ) : HarnessCommand {
        override val kind: Kind get() = Kind.QUESTION_RESPONSE
    }

    /** Asks a backend with a remote shutdown to stop; otherwise `unsupported`. */
    public data object Shutdown : HarnessCommand {
        override val kind: Kind get() = Kind.SHUTDOWN
        override val requestId: String? get() = null
    }
}

/** An attachment sent with [HarnessCommand.Prompt]. */
public data class HarnessAttachment(
    public val name: String,
    /** MIME type, for example `image/png`. */
    public val mimeType: String,
    /** Base64 text, exactly the schema's `data_base64` member. */
    public val dataBase64: String,
)

/** Decision for a permission request raised by the harness. */
public enum class PermissionDecision(public val wire: String) {
    ALLOW_ONCE("allow_once"),
    ALLOW_ALWAYS("allow_always"),
    DENY("deny"),
    ;

    public companion object {
        public fun fromWire(wire: String): PermissionDecision? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * Why the host asks a harness to cancel a turn.
 *
 * The host contract is flat (four cause kinds); DSH's `session/cancel` request
 * is nested. [toDshCause] is the one encoding of that crosswalk (host README
 * §4):
 *
 * | Host cause | DSH `session/cancel` cause |
 * |---|---|
 * | [User] | `{"kind":"user"}` |
 * | [Hook] | `{"kind":"hook","reason":{"kind":"hook"}}` |
 * | [Budget] | `{"kind":"hook","reason":{"kind":"budget","detail":"…"}}` |
 * | [Timeout] | `{"kind":"hook","reason":{"kind":"timeout","detail":"…"}}` |
 */
public sealed interface AgentCancelCause {
    /** Stable cause kind: `user`, `hook`, `budget` or `timeout`. */
    public val kind: String

    /** The user pressed cancel. */
    public data object User : AgentCancelCause {
        override val kind: String get() = "user"
    }

    /** A host hook cancelled the turn. */
    public data object Hook : AgentCancelCause {
        override val kind: String get() = "hook"
    }

    /** A model/token/step budget ran out. */
    public data class Budget(public val detail: String) : AgentCancelCause {
        override val kind: String get() = "budget"
    }

    /** A wall-clock or delivery deadline expired. */
    public data class Timeout(public val detail: String) : AgentCancelCause {
        override val kind: String get() = "timeout"
    }

    /** Returns the exact DSH `session/cancel` cause value described in the table above. */
    public fun toDshCause(): JsonValue = when (this) {
        is User -> JsonObject(linkedMapOf("kind" to JsonString("user")))
        is Hook -> JsonObject(
            linkedMapOf(
                "kind" to JsonString("hook"),
                "reason" to JsonObject(linkedMapOf("kind" to JsonString("hook"))),
            ),
        )
        is Budget -> hookReason(JsonObject(linkedMapOf("kind" to JsonString("budget"), "detail" to JsonString(detail))))
        is Timeout -> hookReason(JsonObject(linkedMapOf("kind" to JsonString("timeout"), "detail" to JsonString(detail))))
    }

    private fun hookReason(reason: JsonObject): JsonObject = JsonObject(
        linkedMapOf(
            "kind" to JsonString("hook"),
            "reason" to reason,
        ),
    )
}
