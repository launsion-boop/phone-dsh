// Host contract 1 — the fifteen event kinds of spec/host/v1.
// SPDX-License-Identifier: MIT
//
// `spec/host/v1/event-kinds.md` §1 is the authority. Its left column is the host
// `kind` a consumer sees; its middle column is the trajectory projection type.
// The two vocabularies are not the same thing: `turn_started` is a host kind and
// `turn/start` is a projection type, and neither may be written where the other
// belongs.
//
// The table below is total on purpose. A `when` over [HostEventKind] cannot
// forget a member, and a new kind in the schema has to be added here (with its
// golden column) before the compiler is happy again.

package com.phonedsh.hostevents

/**
 * The closed host-kind set of `spec/host/v1/schema/harness-event.schema.json`.
 *
 * @param wire the snake_case value an event's `kind` member carries.
 * @param projectionType the trajectory row type of event-kinds.md §1, or `null`
 *   when the kind has no projection row.
 * @param durable `true` when the schema requires `seq` on this variant, i.e.
 *   when it is replayed after a resume cursor.
 */
enum class HostEventKind(
    val wire: String,
    val projectionType: String?,
    val durable: Boolean,
) {
    ASSISTANT_MESSAGE("assistant_message", "assistant/message", true),
    PERMISSION_REQUESTED("permission_requested", "permission/request", false),
    QUESTION_REQUESTED("question_requested", "question/request", false),
    SESSION_STATUS("session_status", "session/start", false),
    TOOL_CALL("tool_call", "tool/call", true),
    TOOL_RESULT("tool_result", "tool/result", true),
    TURN_ENDED("turn_ended", "turn/end", true),
    TURN_STARTED("turn_started", "turn/start", true),
    USER_MESSAGE("user_message", "user/message", true),
    USAGE("usage", "assistant/message", true),
    ASSISTANT_DELTA("assistant_delta", null, false),
    REASONING_DELTA("reasoning_delta", null, false),
    PROGRESS("progress", null, true),
    EXITED("exited", null, false),
    INBOX_SPLICED("inbox_spliced", null, true),
    ;

    companion object {
        /** The wire value to kind map; unknown values are `null`, never guessed. */
        fun fromWire(wire: String): HostEventKind? = entries.firstOrNull { it.wire == wire }
    }
}
