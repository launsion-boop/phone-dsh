// phone-dsh — :dsh / com.phonedsh.dsh.exec: the recorded exec event stream (D10).
// SPDX-License-Identifier: MIT
//
// exec.md §2 stores one entry per `idem_key`: the identity (`argv`, `cwd`,
// `exec_id`) and the complete recorded event stream. A repeated key replays that
// stream and never runs the tool again. The in-memory `RequestLedger` stores a
// `ToolOutcome`; this file is the value that outcome carries, so the ledger stays
// the single idempotency decision and this file is only the entry's shape.
//
// The entry mirrors `exec/<idem_key>.json` of exec.md §2: `v`, `kind`, `idem_key`,
// `exec_id`, `argv`, `cwd`, `created_at_ms`, `terminal`, `events`. `step_id` and
// `turn_id` are deliberately absent: they are not on the EXEC_REQ wire, the step
// record owns them, and inventing them here would make the two records disagree.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import org.json.JSONArray
import org.json.JSONObject

/** A recorded event stream that cannot be replayed. */
class ExecRecordException(
    /** Stable machine-readable code; also the terminal event code. */
    val code: String,
    detail: String,
) : IllegalArgumentException("$code: $detail") {
    companion object {
        /** The stored entry is malformed; nothing was executed by the replay. */
        const val CODE_CORRUPT: String = "record_corrupt"
    }
}

/**
 * One dedup entry (exec.md §2), as the D10 replay needs it.
 *
 * The constructor enforces the replay contract: non-empty argv, an absolute cwd,
 * one D6 `exec_id` shared by every event, a `seq` run from 0 without gaps, and a
 * terminal event last. A stream that cannot be replayed is rejected here instead
 * of being sent to the Worker as a half-history.
 */
data class ExecRecord(
    val idemKey: String,
    val execId: String,
    val argv: List<String>,
    val cwd: String,
    val createdAtMs: Long,
    val events: List<ExecEvent>,
) {
    init {
        if (!ExecRequest.IDEM_KEY_PATTERN.matches(idemKey)) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "idem_key is not 64 lowercase hex")
        }
        if (!ExecRequest.EXEC_ID_PATTERN.matches(execId)) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "exec_id is not a D6 identifier")
        }
        if (argv.isEmpty()) {
            // Empty *elements* are legal arguments ([ExecRequest]); refusing
            // them here would make a record this host wrote unreadable, so a
            // legal `rg -N ''` replay would fail with `record_corrupt`.
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "argv is empty")
        }
        if (!cwd.startsWith("/")) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "cwd is not absolute")
        }
        if (events.isEmpty()) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the stream has no event")
        }
        if (events.any { it.execId != execId }) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "an event names another exec_id")
        }
        val expected = events.indices.map { it.toLong() }
        if (events.map { it.seq } != expected) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "seq must run from 0 without gaps")
        }
        val last = events.last()
        if (last !is ExecEvent.Exit && last !is ExecEvent.Error) {
            throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the stream has no terminal event")
        }
    }

    /** exec.md §2: true because [events] ends in `exit` or `error`. */
    val terminal: Boolean get() = true

    /** The recorded entry as canonical JSON, the value the ledger stores. */
    fun toJson(): String {
        val eventArray = JSONArray()
        for (event in events) eventArray.put(JSONObject(event.fieldsJson()))
        val payload = JSONObject()
        payload.put("v", 1)
        payload.put("kind", "exec")
        payload.put("idem_key", idemKey)
        payload.put("exec_id", execId)
        payload.put("argv", JSONArray(argv))
        payload.put("cwd", cwd)
        payload.put("created_at_ms", createdAtMs)
        payload.put("terminal", terminal)
        payload.put("events", eventArray)
        return WireCodec.canonicalJson(payload.toString())
    }

    companion object {
        /**
         * Reads one recorded entry.
         *
         * @throws ExecRecordException the entry cannot be replayed
         */
        fun parse(json: String): ExecRecord {
            val canonical = try {
                WireCodec.canonicalJson(json)
            } catch (invalid: WireException) {
                throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry is not legal JSON")
            }
            val payload = try {
                JSONObject(canonical)
            } catch (invalid: RuntimeException) {
                throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry is not a JSON object")
            }
            if (payload.optInt("v", -1) != 1) {
                throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry version is not 1")
            }
            if (payload.opt("kind") != "exec") {
                throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry kind is not exec")
            }
            val idemKey = stringMember(payload, "idem_key")
            val execId = stringMember(payload, "exec_id")
            val argv = argvMember(payload)
            val cwd = stringMember(payload, "cwd")
            val createdAtMs = payload.opt("created_at_ms")?.toString()?.toLongOrNull() ?: 0L
            val recordedTerminal = payload.optBoolean("terminal", false)
            val eventArray = payload.opt("events") as? JSONArray
                ?: throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry has no events array")
            val events = ArrayList<ExecEvent>(eventArray.length())
            for (index in 0 until eventArray.length()) {
                val eventObject = eventArray.opt(index) as? JSONObject
                    ?: throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "an event is not a JSON object")
                events.add(
                    try {
                        ExecEvent.parse(eventObject.toString())
                    } catch (invalid: IllegalArgumentException) {
                        throw ExecRecordException(
                            ExecRecordException.CODE_CORRUPT,
                            "an event is malformed",
                        )
                    },
                )
            }
            val record = ExecRecord(
                idemKey = idemKey,
                execId = execId,
                argv = argv,
                cwd = cwd,
                createdAtMs = createdAtMs,
                events = events,
            )
            if (!recordedTerminal) {
                throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry is not marked terminal")
            }
            return record
        }

        private fun stringMember(payload: JSONObject, name: String): String =
            payload.opt(name) as? String
                ?: throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry needs $name")

        private fun argvMember(payload: JSONObject): List<String> {
            val array = payload.opt("argv") as? JSONArray
                ?: throw ExecRecordException(ExecRecordException.CODE_CORRUPT, "the entry needs argv")
            val argv = ArrayList<String>(array.length())
            for (index in 0 until array.length()) {
                val element = array.opt(index) as? String
                    ?: throw ExecRecordException(
                        ExecRecordException.CODE_CORRUPT,
                        "argv elements must be strings",
                    )
                argv.add(element)
            }
            return argv
        }
    }
}
