// phone-dsh — :dsh / com.phonedsh.dsh.exec: EXEC_CTL, channel.md §4.4.
// SPDX-License-Identifier: MIT
//
// One `0x22` frame is `{exec_id, op}` plus `data` for `op = stdin` (goldens
// `exec-ctl-1.json` cancel and `exec-ctl-2.json` stdin). The decoder is strict
// for the same reason the EXEC_REQ decoder is: a control with an unknown member
// or a missing `data` must not be guessed at, and an invalid `exec_id` must not
// reach the live table. A refusal is `BAD_PAYLOAD` (channel.md §10); `exec/`
// only names the frame, the host owns the type byte and the error frame.
//
// What the two operations can honestly do for an in-process accelerator
// (exec.md §3: these tools produce bytes, not a process handle):
//
//   * `cancel` — there is no process to signal. The live execution is ended
//     with one terminal `exit` whose status is `cancelled` (exec-bridge v1 §4.4
//     maps cancel to a cancelled exit), and the log refuses every later event.
//   * `stdin` — an in-process accelerator never gets a stdin pipe, so a pipe
//     request is refused before dispatch (`ExecBridge.onRequest`). A stdin
//     control that still arrives is refused explicitly with the existing
//     `unsupported` code of exec.md §3 (the same code the landed handler uses
//     for "stdin is not supported: the provider has no stdin", which is
//     exec-bridge v1's 501); it is never dropped silently.
//
// The control has no reply frame on the ordered channel, which is why a refusal
// is an EXEC_EVT `error`: [ExecControlOutcome] says whether it was written into
// a live stream or has to be sent as a standalone terminal event by the host.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import java.util.Base64
import org.json.JSONObject

/** An EXEC_CTL payload that cannot be dispatched. */
class ExecControlException(
    /** The protocol member that failed, e.g. `exec_id` or `op`. */
    val field: String,
    /** The shared EXEC_REQ member vocabulary; the reasons are the same shapes. */
    val reason: ExecRequestException.Reason,
    detail: String,
) : IllegalArgumentException("$CODE [$field/${reason.wireName}]: $detail") {
    /** channel.md §10: a malformed control is a payload error. */
    val code: String get() = CODE

    companion object {
        /** channel.md §10. */
        const val CODE: String = "BAD_PAYLOAD"
    }
}

/**
 * One decoded `EXEC_CTL` frame.
 *
 * [execId] is validated against D6 at construction, because it is used as a
 * lookup key in the live table and (on the host side) to address an execution.
 */
sealed interface ExecControl {
    /** The targeted execution's D6 identifier. */
    val execId: String

    /** The wire `op` value; stable and case-sensitive. */
    val op: String

    /** `op = cancel`: terminate the execution. */
    data class Cancel(override val execId: String) : ExecControl {
        init {
            requireExecId(execId)
        }

        override val op: String get() = OP_CANCEL
    }

    /**
     * `op = stdin`: base64 bytes for the execution's stdin pipe.
     *
     * The decoder validates the base64, so a malformed [data] never becomes a
     * control. The in-process bridge still refuses the operation, because no
     * such pipe exists (see the file header).
     */
    data class Stdin(
        override val execId: String,
        val data: String,
    ) : ExecControl {
        init {
            requireExecId(execId)
            try {
                Base64.getDecoder().decode(data)
            } catch (invalid: IllegalArgumentException) {
                throw ExecControlException(
                    field = "data",
                    reason = ExecRequestException.Reason.BAD_VALUE,
                    detail = "data must be base64",
                )
            }
        }

        override val op: String get() = OP_STDIN

        /** The decoded stdin bytes. */
        val bytes: ByteArray get() = Base64.getDecoder().decode(data)
    }

    companion object {
        /** channel.md §2: the frame type name the codec maps to `0x22`. */
        const val WIRE_TYPE: String = "EXEC_CTL"

        /** channel.md §4.4: the two operations. */
        const val OP_CANCEL: String = "cancel"

        /** channel.md §4.4. */
        const val OP_STDIN: String = "stdin"

        private val MEMBERS: Set<String> = setOf("exec_id", "op", "data")

        /**
         * Decodes one `0x22` payload.
         *
         * @throws ExecControlException the control must not be dispatched
         * @throws com.phonedsh.wire.WireUnavailable the native codec is missing
         */
        fun parse(payloadJson: String): ExecControl {
            val canonical = try {
                WireCodec.canonicalJson(payloadJson)
            } catch (invalid: WireException) {
                throw ExecControlException(
                    field = "",
                    reason = ExecRequestException.Reason.MALFORMED_JSON,
                    detail = "EXEC_CTL is not legal canonical JSON (${invalid.code})",
                )
            }
            val payload = try {
                JSONObject(canonical)
            } catch (malformed: RuntimeException) {
                throw ExecControlException(
                    field = "",
                    reason = ExecRequestException.Reason.MALFORMED_JSON,
                    detail = "EXEC_CTL must be a JSON payload",
                )
            }
            val names = payload.keys()
            while (names.hasNext()) {
                val name = names.next()
                if (name !in MEMBERS) {
                    throw ExecControlException(
                        field = "",
                        reason = ExecRequestException.Reason.UNKNOWN_MEMBER,
                        detail = "EXEC_CTL carries a member the schema does not define",
                    )
                }
            }
            val execId = requiredString(payload, "exec_id")
            if (!ExecRequest.EXEC_ID_PATTERN.matches(execId)) {
                throw ExecControlException(
                    field = "exec_id",
                    reason = ExecRequestException.Reason.BAD_IDENTIFIER,
                    detail = "exec_id must match ${ExecRequest.EXEC_ID_PATTERN.pattern}",
                )
            }
            val op = requiredString(payload, "op")
            return when (op) {
                OP_CANCEL -> {
                    if (payload.has("data")) {
                        throw ExecControlException(
                            field = "data",
                            reason = ExecRequestException.Reason.UNKNOWN_MEMBER,
                            detail = "data is only legal with op=stdin",
                        )
                    }
                    Cancel(execId)
                }

                OP_STDIN -> {
                    if (!payload.has("data")) {
                        throw ExecControlException(
                            field = "data",
                            reason = ExecRequestException.Reason.MISSING,
                            detail = "data is required with op=stdin",
                        )
                    }
                    Stdin(execId = execId, data = requiredString(payload, "data"))
                }

                else -> throw ExecControlException(
                    field = "op",
                    reason = ExecRequestException.Reason.BAD_VALUE,
                    detail = "op must be cancel or stdin",
                )
            }
        }

        private fun requiredString(payload: JSONObject, name: String): String {
            if (!payload.has(name)) {
                throw ExecControlException(
                    field = name,
                    reason = ExecRequestException.Reason.MISSING,
                    detail = "$name is required",
                )
            }
            val value = payload.opt(name)
            if (value !is String) {
                throw ExecControlException(
                    field = name,
                    reason = ExecRequestException.Reason.WRONG_TYPE,
                    detail = "$name must be a string",
                )
            }
            return value
        }

        private fun requireExecId(execId: String) {
            if (!ExecRequest.EXEC_ID_PATTERN.matches(execId)) {
                throw ExecControlException(
                    field = "exec_id",
                    reason = ExecRequestException.Reason.BAD_IDENTIFIER,
                    detail = "exec_id must match ${ExecRequest.EXEC_ID_PATTERN.pattern}",
                )
            }
        }
    }
}

/**
 * What [ExecBridge.onControl] did with one control.
 *
 * The ordered channel has no EXEC_CTL reply frame, so the two observable
 * channels are the execution's own EXEC_EVT stream and, when there is no stream
 * to write to, a standalone terminal event the host sends ([Emit]).
 */
sealed interface ExecControlOutcome {
    /** The live execution was ended; its subscribers receive the terminal event. */
    data object Applied : ExecControlOutcome

    /** No live execution with that id (or it had already ended); nothing changed. */
    data object Ignored : ExecControlOutcome

    /** The live stream now carries a terminal refusal with [code]; no other reply. */
    data class Refused(val code: String) : ExecControlOutcome

    /** No live stream exists; the host sends this standalone terminal event. */
    data class Emit(val event: ExecEvent) : ExecControlOutcome
}
