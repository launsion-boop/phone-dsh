// phone-dsh — :dsh / com.phonedsh.dsh.exec: EXEC_EVT, channel.md §4.3.
// SPDX-License-Identifier: MIT
//
// One execution is one ordered event stream. Every event is one canonical JSON
// object carrying `exec_id` and a per-execution `seq` from 0 (exec.md §4.1 of the
// exec-bridge shape); there is no binary prefix and no batching. `exit` is a
// single event of its own: this file has no union/merge operation, and a caller
// that sends the events in order necessarily sends `exit` immediately after the
// streams reached EOF (channel.md §4.3, exec.md §3).
//
// Encoding goes through the one codec (`WireCodec`): the event object is
// canonicalised by the Rust codec and wrapped as an `EXEC_EVT` (`0x21`) frame.
// The byte-for-byte golden vectors exec-evt-1/2 are asserted in the tests, so the
// member set below is not allowed to drift from spec/v1/golden/frames.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import java.util.Base64
import org.json.JSONObject

/**
 * One `EXEC_EVT` event.
 *
 * Implementations are immutable values; `seq` is assigned by the producer
 * ([ExecBridge]/[ExecToolResult]) and starts at 0 for each execution.
 */
sealed interface ExecEvent {
    /** D6 identifier of the execution; always present on the wire. */
    val execId: String

    /** Per-execution sequence, from 0, no gaps. */
    val seq: Long

    /** The `type` member: `start`, `output`, `exit`, `quiescent` or `error`. */
    val type: String

    /** The event object as canonical JSON (channel.md §5). */
    fun fieldsJson(): String

    /**
     * One `EXEC_EVT` frame carrying this event.
     *
     * [frameSeq] is the channel sequence of channel.md §1, which is a different
     * space from [seq]; the host connection owns it.
     */
    fun encode(frameSeq: Long): ByteArray {
        val frame = JSONObject()
        frame.put("type", WIRE_TYPE)
        frame.put("fields", JSONObject(fieldsJson()))
        return WireCodec.encode(frame.toString(), frameSeq)
    }

    /** The streams an [Output] event can carry. */
    enum class Stream(val wireName: String) {
        STDOUT("stdout"),
        STDERR("stderr"),
        ;

        companion object {
            /** The wire name, or null for an unknown value. */
            fun fromWire(name: String): Stream? = entries.firstOrNull { it.wireName == name }
        }
    }

    /** The `exit.status` domain of exec-bridge v1 §4.1. */
    enum class ExitStatus(val wireName: String) {
        EXITED("exited"),
        SIGNALED("signaled"),
        CANCELLED("cancelled"),
        TIMED_OUT("timed_out"),
        REJECTED("rejected"),
        FAILED("failed"),
        ;

        companion object {
            /** The wire name, or null for an unknown value. */
            fun fromWire(name: String): ExitStatus? = entries.firstOrNull { it.wireName == name }
        }
    }

    /** The execution started. `replayed` is true only on a D10 replay. */
    data class Start(
        override val execId: String,
        override val seq: Long = ExecEvent.SEQUENCE_START,
        val replayed: Boolean = false,
    ) : ExecEvent {
        init {
            require(seq >= 0L) { "seq must be non-negative, was $seq" }
        }

        override val type: String get() = "start"

        override fun fieldsJson(): String = canonicalEvent {
            put("type", type)
            put("exec_id", execId)
            put("seq", seq)
            if (replayed) put("replayed", true)
        }
    }

    /** One chunk of stdout or stderr; [data] is base64 on the wire. */
    data class Output(
        override val execId: String,
        override val seq: Long,
        val stream: Stream,
        val data: String,
    ) : ExecEvent {
        init {
            require(seq >= 0L) { "seq must be non-negative, was $seq" }
            try {
                Base64.getDecoder().decode(data)
            } catch (invalid: IllegalArgumentException) {
                throw IllegalArgumentException("EXEC_EVT output data must be base64", invalid)
            }
        }

        override val type: String get() = "output"

        override fun fieldsJson(): String = canonicalEvent {
            put("type", type)
            put("exec_id", execId)
            put("seq", seq)
            put("stream", stream.wireName)
            put("data", data)
        }
    }

    /**
     * The terminal process event. It is not coalesced with output: `exit` is the
     * whole event, and the host sends it as its own frame the moment it exists.
     */
    data class Exit(
        override val execId: String,
        override val seq: Long,
        val code: Int?,
        val signal: String?,
        val status: ExitStatus,
        val quiescent: Boolean,
        val stdoutBytes: Long,
        val stderrBytes: Long,
    ) : ExecEvent {
        init {
            require(seq >= 0L) { "seq must be non-negative, was $seq" }
            require(stdoutBytes >= 0L) { "stdout_bytes must be non-negative" }
            require(stderrBytes >= 0L) { "stderr_bytes must be non-negative" }
        }

        override val type: String get() = "exit"

        override fun fieldsJson(): String = canonicalEvent {
            put("type", type)
            put("exec_id", execId)
            put("seq", seq)
            put("code", code ?: JSONObject.NULL)
            put("signal", signal ?: JSONObject.NULL)
            put("status", status.wireName)
            put("quiescent", quiescent)
            put("stdout_bytes", stdoutBytes)
            put("stderr_bytes", stderrBytes)
        }
    }

    /** Background children are gone; sends only after an exit with `quiescent=false`. */
    data class Quiescent(
        override val execId: String,
        override val seq: Long,
    ) : ExecEvent {
        init {
            require(seq >= 0L) { "seq must be non-negative, was $seq" }
        }

        override val type: String get() = "quiescent"

        override fun fieldsJson(): String = canonicalEvent {
            put("type", type)
            put("exec_id", execId)
            put("seq", seq)
        }
    }

    /** A terminal refusal or failure; [message] is fixed text, never argv. */
    data class Error(
        override val execId: String,
        override val seq: Long,
        val code: String,
        val message: String,
    ) : ExecEvent {
        init {
            require(seq >= 0L) { "seq must be non-negative, was $seq" }
            require(code.isNotEmpty()) { "an error event needs a stable code" }
        }

        override val type: String get() = "error"

        override fun fieldsJson(): String = canonicalEvent {
            put("type", type)
            put("exec_id", execId)
            put("seq", seq)
            put("code", code)
            put("message", message)
        }
    }

    companion object {
        /** channel.md §2: the frame type name the codec maps to `0x21`. */
        const val WIRE_TYPE: String = "EXEC_EVT"

        /** exec.md §2: a replay is emitted from `seq = 0`. */
        const val SEQUENCE_START: Long = 0L

        /**
         * Reads one recorded event object.
         *
         * Only completed, canonical records pass through here (D10 replay), so
         * every value is validated again rather than trusted because it was
         * produced earlier.
         *
         * @throws IllegalArgumentException the object is not an EXEC_EVT event
         */
        fun parse(json: String): ExecEvent {
            val canonical = try {
                WireCodec.canonicalJson(json)
            } catch (invalid: WireException) {
                throw IllegalArgumentException("EXEC_EVT is not legal canonical JSON", invalid)
            }
            val payload = try {
                JSONObject(canonical)
            } catch (invalid: RuntimeException) {
                throw IllegalArgumentException("EXEC_EVT is not a JSON object", invalid)
            }
            val type = payload.opt("type") as? String
                ?: throw IllegalArgumentException("EXEC_EVT needs a string type")
            val execId = payload.opt("exec_id") as? String
                ?: throw IllegalArgumentException("EXEC_EVT needs a string exec_id")
            if (!ExecRequest.EXEC_ID_PATTERN.matches(execId)) {
                throw IllegalArgumentException("EXEC_EVT exec_id is not a D6 identifier")
            }
            val seq = longMember(payload, "seq")
            return when (type) {
                "start" -> ExecEvent.Start(
                    execId = execId,
                    seq = seq,
                    replayed = payload.optBoolean("replayed", false),
                )

                "output" -> {
                    val streamName = payload.opt("stream") as? String
                        ?: throw IllegalArgumentException("EXEC_EVT output needs a stream")
                    val stream = Stream.fromWire(streamName)
                        ?: throw IllegalArgumentException("EXEC_EVT output stream is unknown")
                    val data = payload.opt("data") as? String
                        ?: throw IllegalArgumentException("EXEC_EVT output needs string data")
                    ExecEvent.Output(execId = execId, seq = seq, stream = stream, data = data)
                }

                "exit" -> {
                    val statusName = payload.opt("status") as? String
                        ?: throw IllegalArgumentException("EXEC_EVT exit needs a status")
                    val status = ExitStatus.fromWire(statusName)
                        ?: throw IllegalArgumentException("EXEC_EVT exit status is unknown")
                    if (!payload.has("quiescent")) {
                        throw IllegalArgumentException("EXEC_EVT exit needs quiescent")
                    }
                    ExecEvent.Exit(
                        execId = execId,
                        seq = seq,
                        code = optionalInt(payload.opt("code")),
                        signal = optionalString(payload.opt("signal")),
                        status = status,
                        quiescent = payload.getBoolean("quiescent"),
                        stdoutBytes = optionalLong(payload, "stdout_bytes"),
                        stderrBytes = optionalLong(payload, "stderr_bytes"),
                    )
                }

                "quiescent" -> ExecEvent.Quiescent(execId = execId, seq = seq)

                "error" -> {
                    val code = payload.opt("code") as? String
                        ?: throw IllegalArgumentException("EXEC_EVT error needs a code")
                    val message = payload.opt("message") as? String
                        ?: throw IllegalArgumentException("EXEC_EVT error needs a message")
                    ExecEvent.Error(execId = execId, seq = seq, code = code, message = message)
                }

                else -> throw IllegalArgumentException("EXEC_EVT type is unknown")
            }
        }

        private fun longMember(payload: JSONObject, name: String): Long {
            val value = payload.opt(name)
                ?: throw IllegalArgumentException("EXEC_EVT needs $name")
            if (value === JSONObject.NULL) {
                throw IllegalArgumentException("EXEC_EVT $name must be an integer")
            }
            return value.toString().toLongOrNull()
                ?: throw IllegalArgumentException("EXEC_EVT $name must be an integer")
        }

        private fun optionalInt(value: Any?): Int? = when {
            value == null || value === JSONObject.NULL -> null
            value is Number -> value.toInt()
            else -> throw IllegalArgumentException("EXEC_EVT code must be an integer or null")
        }

        private fun optionalString(value: Any?): String? = when {
            value == null || value === JSONObject.NULL -> null
            value is String -> value
            else -> throw IllegalArgumentException("EXEC_EVT signal must be a string or null")
        }

        private fun optionalLong(payload: JSONObject, name: String): Long {
            val value = payload.opt(name) ?: return 0L
            if (value === JSONObject.NULL) return 0L
            val parsed = value.toString().toLongOrNull()
                ?: throw IllegalArgumentException("EXEC_EVT $name must be an integer")
            if (parsed < 0L) throw IllegalArgumentException("EXEC_EVT $name must be non-negative")
            return parsed
        }
    }
}

/**
 * Canonicalises an event object through the one codec.
 *
 * Member order, escaping and number form are the codec's, not this file's; a
 * hand-built object here would be a second canonical-JSON implementation.
 */
private fun canonicalEvent(block: JSONObject.() -> Unit): String =
    WireCodec.canonicalJson(JSONObject().apply(block).toString())
