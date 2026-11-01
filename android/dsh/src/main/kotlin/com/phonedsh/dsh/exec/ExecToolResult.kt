// phone-dsh — :dsh / com.phonedsh.dsh.exec: what an exec tool returns.
// SPDX-License-Identifier: MIT
//
// D12's accelerators are in-process, read-only library tools; they produce bytes
// and exit facts, not a process handle. The existing tool seam
// (`PhoneTool.invoke`) answers a `ToolOutcome.Success(resultJson)`, so this file
// fixes the one JSON contract for that result:
//
//   {"status":"exited","code":0,"signal":null,"quiescent":true,
//    "stdout":"<base64>","stderr":"<base64>"}
//
// `status`, `code`, `signal` and `quiescent` are the exit fields of exec-bridge
// v1 §4.1 (the same domain the EXEC_EVT exit event carries); `stdout`/`stderr`
// are base64 because output on the wire is base64 (golden exec-evt-2). Absent
// streams mean zero bytes. The bridge turns this value into one `start`, zero or
// more `output` events and one immediate `exit`, all with `seq` from 0.
//
// One cap exists here and nowhere else: a single event must fit the 16 MiB frame
// of channel.md §1 after base64 expansion. 8 MiB of raw bytes expands to about
// 10.7 MiB, leaving room for the header and the event members; a larger stream is
// refused as a terminal `output_too_large` instead of producing a frame the codec
// would have to reject.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import java.util.Base64
import org.json.JSONObject

/** An exec tool result the bridge cannot turn into events. */
class ExecToolResultException(
    /** Stable machine-readable code; it becomes the terminal event code. */
    val code: String,
    detail: String,
) : IllegalArgumentException("$code: $detail") {
    companion object {
        /** The result does not follow the contract above. */
        const val CODE_INVALID: String = "tool_result_invalid"

        /** One stream exceeds [MAX_STREAM_BYTES] before base64. */
        const val CODE_TOO_LARGE: String = "output_too_large"
    }
}

/**
 * The completed output of one exec tool invocation.
 *
 * A regular class, not a data class: [stdout] and [stderr] are byte arrays and
 * value equality over them would need `contentEquals` anyway.
 */
class ExecToolResult(
    val status: ExecEvent.ExitStatus,
    val code: Int?,
    val signal: String?,
    val quiescent: Boolean,
    val stdout: ByteArray,
    val stderr: ByteArray,
) {
    /**
     * The ordered event stream for [execId]: `start` at seq 0, one `output` per
     * non-empty stream, and the single terminal `exit`.
     */
    fun events(execId: String): List<ExecEvent> {
        val events = ArrayList<ExecEvent>(4)
        events.add(ExecEvent.Start(execId = execId, seq = 0L))
        if (stdout.isNotEmpty()) {
            events.add(
                ExecEvent.Output(
                    execId = execId,
                    seq = events.size.toLong(),
                    stream = ExecEvent.Stream.STDOUT,
                    data = Base64.getEncoder().encodeToString(stdout),
                ),
            )
        }
        if (stderr.isNotEmpty()) {
            events.add(
                ExecEvent.Output(
                    execId = execId,
                    seq = events.size.toLong(),
                    stream = ExecEvent.Stream.STDERR,
                    data = Base64.getEncoder().encodeToString(stderr),
                ),
            )
        }
        events.add(
            ExecEvent.Exit(
                execId = execId,
                seq = events.size.toLong(),
                code = code,
                signal = signal,
                status = status,
                quiescent = quiescent,
                stdoutBytes = stdout.size.toLong(),
                stderrBytes = stderr.size.toLong(),
            ),
        )
        return events
    }

    companion object {
        /** Raw bytes per stream; see the header comment for the frame-budget basis. */
        const val MAX_STREAM_BYTES: Int = 8 * 1024 * 1024

        /**
         * Reads one result object.
         *
         * @throws ExecToolResultException the result is malformed or too large
         */
        fun parse(json: String): ExecToolResult {
            val canonical = try {
                WireCodec.canonicalJson(json)
            } catch (invalid: WireException) {
                throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result is not legal JSON",
                )
            }
            val payload = try {
                JSONObject(canonical)
            } catch (invalid: RuntimeException) {
                throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result is not a JSON object",
                )
            }
            val statusName = payload.opt("status") as? String
                ?: throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result needs a status",
                )
            val status = ExecEvent.ExitStatus.fromWire(statusName)
                ?: throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result status is unknown",
                )
            val codeValue = payload.opt("code")
            val code = when {
                codeValue == null || codeValue === JSONObject.NULL -> null
                codeValue is Number -> codeValue.toInt()
                else -> throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result code must be an integer or null",
                )
            }
            val signalValue = payload.opt("signal")
            val signal = when {
                signalValue == null || signalValue === JSONObject.NULL -> null
                signalValue is String -> signalValue
                else -> throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result signal must be a string or null",
                )
            }
            val quiescent = try {
                if (payload.has("quiescent")) payload.getBoolean("quiescent") else true
            } catch (invalid: RuntimeException) {
                throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result quiescent must be a boolean",
                )
            }
            val stdout = stream(payload, "stdout")
            val stderr = stream(payload, "stderr")
            return ExecToolResult(
                status = status,
                code = code,
                signal = signal,
                quiescent = quiescent,
                stdout = stdout,
                stderr = stderr,
            )
        }

        private fun stream(payload: JSONObject, name: String): ByteArray {
            val value = payload.opt(name) ?: return ByteArray(0)
            if (value === JSONObject.NULL) return ByteArray(0)
            val text = value as? String
                ?: throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result $name must be base64",
                )
            val bytes = try {
                Base64.getDecoder().decode(text)
            } catch (invalid: IllegalArgumentException) {
                throw ExecToolResultException(
                    ExecToolResultException.CODE_INVALID,
                    "the tool result $name must be base64",
                )
            }
            if (bytes.size > MAX_STREAM_BYTES) {
                throw ExecToolResultException(
                    ExecToolResultException.CODE_TOO_LARGE,
                    "one output stream exceeds the event budget",
                )
            }
            return bytes
        }
    }
}
