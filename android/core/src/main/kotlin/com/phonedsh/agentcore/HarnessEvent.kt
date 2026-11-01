// Host contract 1 — the fifteen event kinds and the stream envelope.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * The closed set of host event kinds.
 *
 * `spec/host/v1/schema/harness-event.schema.json` and
 * `spec/host/v1/event-kinds.md` §1 are the authority: exactly fifteen
 * snake_case values, each with a fixed durability. This enum is the single
 * Kotlin enumeration of those values; [HarnessKind] carries the payloads.
 *
 * A decoder that meets a `kind` absent here MUST drop the event, keep reading
 * and count its `seq` as consumed (host README §2.2 rule 2). It may never pass
 * the unknown value through, rename it, or park it in a side channel.
 *
 * [durable] is not a hint: `seq` is present exactly on durable events and is
 * absent on best-effort events (schema `required` lists and host README §4).
 */
public enum class HarnessKindName(
    public val wire: String,
    public val durable: Boolean,
) {
    /** Streaming assistant text; best effort, never replayed. */
    ASSISTANT_DELTA("assistant_delta", false),

    /** Streaming reasoning/thinking text; best effort, never replayed. */
    REASONING_DELTA("reasoning_delta", false),

    /** One durable assistant message. */
    ASSISTANT_MESSAGE("assistant_message", true),

    /** One durable tool invocation. */
    TOOL_CALL("tool_call", true),

    /** One durable tool result; `summary` is the bounded UI projection. */
    TOOL_RESULT("tool_result", true),

    /** A live permission ask; best effort, no `seq`. */
    PERMISSION_REQUESTED("permission_requested", false),

    /** A live question ask; best effort, no `seq`. */
    QUESTION_REQUESTED("question_requested", false),

    /** One user-role message the model sees. */
    USER_MESSAGE("user_message", true),

    /** The user-role messages one inbox splice inserted. */
    INBOX_SPLICED("inbox_spliced", true),

    /** A turn started; durable. */
    TURN_STARTED("turn_started", true),

    /** A turn ended; durable. */
    TURN_ENDED("turn_ended", true),

    /** Long-task progress; durable and also a synthetic-row carrier. */
    PROGRESS("progress", true),

    /** A live session status line; best effort, no `seq`. */
    SESSION_STATUS("session_status", false),

    /** Token usage; durable and folded into the assistant/message projection. */
    USAGE("usage", true),

    /** The session stream ended for good; a transport fact, never replayed. */
    EXITED("exited", false),
    ;

    public companion object {
        private val byWire: Map<String, HarnessKindName> = entries.associateBy { it.wire }

        /** Returns the kind for a wire label, or `null` when this contract version does not know it (drop it). */
        public fun fromWire(wire: String): HarnessKindName? = byWire[wire]
    }
}

/**
 * The payload of one event, keyed by [HarnessKindName].
 *
 * Each variant is closed: a member that the schema does not define for that
 * kind is ignored on decode and never emitted. The best-effort kinds
 * ([HarnessKindName.durable] `false`) carry no `seq`.
 */
public sealed interface HarnessKind {
    /** The wire kind of this payload. */
    public val kindName: HarnessKindName

    /** Streaming assistant text. */
    public data class AssistantDelta(public val text: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.ASSISTANT_DELTA
    }

    /** Streaming reasoning/thinking text. */
    public data class ReasoningDelta(public val text: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.REASONING_DELTA
    }

    /** One durable assistant message. */
    public data class AssistantMessage(public val text: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.ASSISTANT_MESSAGE
    }

    /** One durable tool invocation; [arguments] is arbitrary JSON owned by the tool. */
    public data class ToolCall(
        public val callId: String,
        public val name: String,
        public val arguments: JsonValue,
    ) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.TOOL_CALL
    }

    /** One durable tool result; [summary] is the bounded, single-line UI projection. */
    public data class ToolResult(
        public val callId: String,
        public val isError: Boolean,
        public val summary: String,
    ) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.TOOL_RESULT
    }

    /** A live permission ask; answer it with [HarnessCommand.PermissionResponse]. */
    public data class PermissionRequested(public val request: HarnessPermissionRequest) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.PERMISSION_REQUESTED
    }

    /** A live question ask; answer it with [HarnessCommand.QuestionResponse]. */
    public data class QuestionRequested(public val request: HarnessQuestion) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.QUESTION_REQUESTED
    }

    /** One user-role message the model sees. */
    public data class UserMessage(public val text: String, public val source: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.USER_MESSAGE
    }

    /** The user-role messages one inbox splice inserted, in insertion order. */
    public data class InboxSpliced(public val messages: List<HarnessUserInput>) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.INBOX_SPLICED
    }

    /** A turn started. */
    public data class TurnStarted(public val turnId: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.TURN_STARTED
    }

    /** A turn ended; [reason] is the compatibility projection. */
    public data class TurnEnded(
        public val turnId: String,
        public val reason: HarnessTurnEnd,
    ) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.TURN_ENDED
    }

    /** Progress of a long task; drives background-task progress UI. */
    public data class Progress(
        public val phase: String,
        public val step: Long,
        public val of: Long? = null,
    ) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.PROGRESS
    }

    /** A live session status line (for example `running`, `idle`, `error: …`). */
    public data class SessionStatus(public val status: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.SESSION_STATUS
    }

    /** Token usage; a consumer MUST NOT emit a separate trajectory row for it (event-kinds.md §1). */
    public data class Usage(
        public val inputTokens: Long,
        public val outputTokens: Long,
    ) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.USAGE
    }

    /** The harness process / session ended for good. */
    public data class Exited(public val reason: String) : HarnessKind {
        override val kindName: HarnessKindName get() = HarnessKindName.EXITED
    }
}

/**
 * One event of a session stream: "a line on the stream".
 *
 * The envelope always carries [sessionId], [timeMs] and [kind]. [seq] is
 * present exactly on durable events: durable events are replayed after a
 * resume cursor and must be strictly increasing per session; an event without
 * `seq` is best effort and is never replayed.
 *
 * [seq] is an ordinal, not a count: DSH maps `dsh seq * 8 + part`, so gaps are
 * legal and the first durable `seq` may be `0`. Never infer "events missed"
 * from a gap.
 *
 * [toolResultDetail], [rawTurnEndKind] and [rawTurnEndCause] are optional
 * members of the schema's `tool_result` / `turn_ended` variants; they live on
 * the envelope here because the reference implementation puts them there, and
 * they are `null` for every other kind.
 */
public data class HarnessEvent(
    public val sessionId: String,
    /** Milliseconds since the Unix epoch, matching the journal. */
    public val timeMs: Long,
    /** Durable sequence number; `null` for best-effort events. */
    public val seq: Long?,
    public val kind: HarnessKind,
    /** Complete tool-result text for audit consumers; only on [HarnessKindName.TOOL_RESULT]. */
    public val toolResultDetail: HarnessToolResultDetail? = null,
    /**
     * DSH `turn/end.data.reason.kind`, preserved verbatim on a
     * [HarnessKindName.TURN_ENDED] event. [HarnessKind.TurnEnded.reason] stays
     * the stable compatibility projection.
     */
    public val rawTurnEndKind: String? = null,
    /** The cause nested under the DSH turn-end reason, as compact JSON text, when present. */
    public val rawTurnEndCause: String? = null,
) {
    /** Whether this event is durable (has a `seq` and may be replayed). */
    public val isDurable: Boolean get() = seq != null
}

/** Risk class of a tool, used by permission prompts and by the phone's own approval gate. */
public enum class HarnessToolRisk(public val wire: String) {
    /** Reads data, no side effects. */
    READ_ONLY("read_only"),

    /** Changes state outside the conversation (messages, files, calendar). */
    SIDE_EFFECT("side_effect"),

    /** Operates the phone's user interface; needs a user-granted UI lease. */
    UI("ui"),
    ;

    public companion object {
        public fun fromWire(wire: String): HarnessToolRisk? = entries.firstOrNull { it.wire == wire }
    }
}

/** A permission request raised by the harness. */
public data class HarnessPermissionRequest(
    public val requestId: String,
    public val tool: String,
    public val summary: String,
    public val risk: HarnessToolRisk,
    /** Optional expiry, milliseconds since the Unix epoch (`expires_at_ms`). */
    public val expiresAtMs: Long? = null,
)

/** One independently answerable question in a request. */
public data class HarnessQuestionItem(
    public val id: String,
    public val prompt: String,
    public val options: List<String> = emptyList(),
    public val multiple: Boolean = false,
)

/**
 * A question request raised by the harness.
 *
 * [questions] absent means the single flat [prompt] (host README §2.2 rule 5).
 */
public data class HarnessQuestion(
    public val requestId: String,
    public val prompt: String,
    public val options: List<String> = emptyList(),
    public val questions: List<HarnessQuestionItem>? = null,
)

/** One model-visible user-role message carried by a durable event. */
public data class HarnessUserInput(
    /** Concatenated text blocks, exactly as the model sees them. */
    public val text: String,
    /** Producer-declared source kind (`user`, `goal`, `webhook`, …, or `unknown`); never guessed. */
    public val source: String,
)

/** Why a turn ended; the compatibility projection of the producer's raw reason. */
public sealed interface HarnessTurnEnd {
    public val kind: String

    public data object Completed : HarnessTurnEnd {
        override val kind: String get() = "completed"
    }

    public data object Cancelled : HarnessTurnEnd {
        override val kind: String get() = "cancelled"
    }

    public data class Failed(public val message: String) : HarnessTurnEnd {
        override val kind: String get() = "failed"
    }

    /** The harness stopped because a budget (steps, tokens, time) ran out. */
    public data class BudgetExhausted(public val detail: String) : HarnessTurnEnd {
        override val kind: String get() = "budget_exhausted"
    }
}

/**
 * The complete tool-result record for audit and evidence consumers.
 *
 * [text] keeps newlines, bounded only by the audit limit (64 KiB). When
 * [truncated] is true it ends with an explicit spill marker naming the durable
 * session log and the DSH event; [sessionLogPath] points at the untruncated
 * record.
 */
public data class HarnessToolResultDetail(
    public val text: String,
    public val truncated: Boolean,
    /** DSH session-journal seq of the `tool/result` record. */
    public val eventSeq: Long,
    /** Pointer to the untruncated record in the VFS. */
    public val sessionLogPath: String,
)
