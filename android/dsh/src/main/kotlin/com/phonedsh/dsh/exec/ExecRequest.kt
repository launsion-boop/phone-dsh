// phone-dsh — :dsh / com.phonedsh.dsh.exec: EXEC_REQ, channel.md §4.2.
// SPDX-License-Identifier: MIT
//
// The request value and its one strict decoder. Nothing here starts work: an
// EXEC_REQ that fails any rule below is refused before ExecBridge sees it, and
// the refusal names a stable code (channel.md §10 `BAD_PAYLOAD`), the offending
// member and a stable reason. exec.md §1 fixes the `idem_key` shape, §2.2 fixes
// the `grace_ms` range and the 3000 ms default. The JSON is canonicalised by the
// one codec (`WireCodec`, §5) before members are read, so duplicate names,
// fractions, exponents and malformed input are protocol errors rather than
// values this file has to guess about.
//
// The values are never copied into an error message. An EXEC_REQ can carry a
// path in `argv`, and an error that quotes it would leak that path into a log or
// an EXEC_EVT; the decoder therefore reports only protocol member names.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * A refused EXEC_REQ.
 *
 * [code] is the channel-level code the host reports (always `BAD_PAYLOAD` for a
 * malformed request, channel.md §10); [field] and [reason] are the stable,
 * member-level detail tests and logs may match. No member *value* is included in
 * the message.
 */
class ExecRequestException(
    /** The protocol member that failed, e.g. `exec_id` or `stdin.data`. */
    val field: String,
    /** Why it failed; [Reason.wireName] is stable. */
    val reason: Reason,
    detail: String,
) : IllegalArgumentException("$CODE [$field/${reason.wireName}]: $detail") {
    /** channel.md §10: a malformed EXEC_REQ is a payload error. */
    val code: String get() = CODE

    /** The stable failure vocabulary. */
    enum class Reason(val wireName: String) {
        /** Not canonical-valid JSON, or not one JSON object. */
        MALFORMED_JSON("malformed_json"),

        /** A required member is absent. */
        MISSING("missing_field"),

        /** The member has the wrong JSON type. */
        WRONG_TYPE("wrong_type"),

        /** `exec_id` violates the D6 shape. */
        BAD_IDENTIFIER("bad_identifier"),

        /** `idem_key` is not exactly 64 lowercase hex characters. */
        BAD_IDEM_KEY("bad_idem_key"),

        /** An integer or array length is outside its documented range. */
        OUT_OF_RANGE("out_of_range"),

        /** A value is in range but not in the enumerated domain. */
        BAD_VALUE("bad_value"),

        /** A member the schema does not define; `additionalProperties: false`. */
        UNKNOWN_MEMBER("unknown_member"),
    }

    companion object {
        /** channel.md §10. */
        const val CODE: String = "BAD_PAYLOAD"
    }
}

/**
 * The `stdin` member of EXEC_REQ (channel.md §4.2, exec-bridge v1).
 *
 * An absent member means [Ignore], so an accelerator that reads no stdin sees
 * end-of-file immediately, which is the request default as well.
 */
sealed interface StdinSpec {
    /** No stdin: the command sees EOF at once. */
    data object Ignore : StdinSpec

    /** The Worker feeds stdin over EXEC_CTL `stdin`; nothing is buffered here. */
    data object Pipe : StdinSpec

    /** Complete stdin bytes, base64 on the wire. */
    data class Data(val base64: String) : StdinSpec {
        init {
            try {
                Base64.getDecoder().decode(base64)
            } catch (invalid: IllegalArgumentException) {
                throw ExecRequestException(
                    field = "stdin.data",
                    reason = ExecRequestException.Reason.BAD_VALUE,
                    detail = "stdin.data must be base64",
                )
            }
        }

        /** Decoded length in bytes. */
        val sizeBytes: Int get() = Base64.getDecoder().decode(base64).size
    }
}

/** The `tier` member; transport metadata, not part of the identity (exec.md §2). */
enum class ExecTier(val wireName: String) {
    INTERACTIVE("interactive"),
    SESSION("session"),
    BATCH("batch"),
}

/** The `confine.mode` member; never a rejection criterion (exec.md §3, D20). */
enum class ConfineMode(val wireName: String) {
    READ_ONLY("read-only"),
    WORKSPACE_WRITE("workspace-write"),
}

/** The `confine` member; validated, then not negotiated (exec.md §3). */
data class Confine(
    val mode: ConfineMode,
    val workspaceRoot: String,
) {
    init {
        if (!workspaceRoot.startsWith("/")) {
            throw ExecRequestException(
                field = "confine.workspace_root",
                reason = ExecRequestException.Reason.BAD_VALUE,
                detail = "confine.workspace_root must be an absolute path",
            )
        }
    }
}

/**
 * One EXEC_REQ (channel.md §4.2), validated at construction.
 *
 * Required members: [execId], [argv], [cwd], [requiresMseq], [idemKey]. Optional
 * members take the documented defaults; an absent `grace_ms` is
 * [DEFAULT_GRACE_MS], as exec.md §2.2 requires.
 */
data class ExecRequest(
    val execId: String,
    val argv: List<String>,
    val cwd: String,
    val env: Map<String, String?> = emptyMap(),
    val deadline: Long? = null,
    val graceMs: Long = DEFAULT_GRACE_MS,
    val stdin: StdinSpec = StdinSpec.Ignore,
    val tier: ExecTier? = null,
    val confine: Confine? = null,
    val requiresMseq: Long,
    val idemKey: String,
) {
    init {
        if (!EXEC_ID_PATTERN.matches(execId)) {
            throw ExecRequestException(
                field = "exec_id",
                reason = ExecRequestException.Reason.BAD_IDENTIFIER,
                detail = "exec_id must match ${EXEC_ID_PATTERN.pattern}",
            )
        }
        if (argv.isEmpty()) {
            throw ExecRequestException(
                field = "argv",
                reason = ExecRequestException.Reason.OUT_OF_RANGE,
                detail = "argv must name the program",
            )
        }
        // An empty *element* is a legal argument, not a malformed payload.
        // channel.md §4.2 types argv as "array of strings" and §10's list of
        // BAD_PAYLOAD causes (bad JSON, identifier, capability set, level or
        // length field) does not include an element's content; exec.md §1's
        // canonical-JSON identity and `idem_key` derivation both carry `""`
        // unchanged. `rg -N ''` is therefore a well-formed request and the host
        // must dispatch it — rejecting it with BAD_PAYLOAD closed the ordered
        // channel for a request the Worker is entitled to send.
        if (!cwd.startsWith("/")) {
            throw ExecRequestException(
                field = "cwd",
                reason = ExecRequestException.Reason.BAD_VALUE,
                detail = "cwd must be an absolute path",
            )
        }
        if (graceMs < MIN_GRACE_MS || graceMs > MAX_GRACE_MS) {
            throw ExecRequestException(
                field = "grace_ms",
                reason = ExecRequestException.Reason.OUT_OF_RANGE,
                detail = "grace_ms must be $MIN_GRACE_MS..$MAX_GRACE_MS",
            )
        }
        if (requiresMseq < 0L) {
            throw ExecRequestException(
                field = "requires_mseq",
                reason = ExecRequestException.Reason.OUT_OF_RANGE,
                detail = "requires_mseq must be non-negative",
            )
        }
        if (deadline != null && deadline < 0L) {
            throw ExecRequestException(
                field = "deadline",
                reason = ExecRequestException.Reason.OUT_OF_RANGE,
                detail = "deadline must be non-negative",
            )
        }
        if (!IDEM_KEY_PATTERN.matches(idemKey)) {
            throw ExecRequestException(
                field = "idem_key",
                reason = ExecRequestException.Reason.BAD_IDEM_KEY,
                detail = "idem_key must be 64 lowercase hex characters",
            )
        }
    }

    /**
     * The request as canonical JSON, including members that were defaulted.
     *
     * This is the argument object an exec tool receives: it lets a tool read
     * `argv`, `env` and the rest without a second wire dialect.
     */
    fun toJson(): String {
        val payload = JSONObject()
        payload.put("exec_id", execId)
        payload.put("argv", JSONArray(argv))
        payload.put("cwd", cwd)
        val envObject = JSONObject()
        for ((name, value) in env) envObject.put(name, value ?: JSONObject.NULL)
        payload.put("env", envObject)
        deadline?.let { payload.put("deadline", it) }
        payload.put("grace_ms", graceMs)
        payload.put("stdin", stdinJson())
        tier?.let { payload.put("tier", it.wireName) }
        confine?.let {
            val confineObject = JSONObject()
            confineObject.put("mode", it.mode.wireName)
            confineObject.put("workspace_root", it.workspaceRoot)
            payload.put("confine", confineObject)
        }
        payload.put("requires_mseq", requiresMseq)
        payload.put("idem_key", idemKey)
        return WireCodec.canonicalJson(payload.toString())
    }

    private fun stdinJson(): JSONObject = when (stdin) {
        StdinSpec.Ignore -> JSONObject().put("mode", "ignore")
        StdinSpec.Pipe -> JSONObject().put("mode", "pipe")
        is StdinSpec.Data -> JSONObject().put("mode", "data").put("data", stdin.base64)
    }

    companion object {
        /** exec.md §2.2: absent `grace_ms` means 3000 ms. */
        const val DEFAULT_GRACE_MS: Long = 3000L

        /** exec.md §2.2: the lower bound; 0 is a payload error, never a default. */
        const val MIN_GRACE_MS: Long = 1L

        /** exec.md §2.2: the upper bound; the host never clamps silently. */
        const val MAX_GRACE_MS: Long = 60_000L

        /** channel.md §6 / D6. */
        val EXEC_ID_PATTERN: Regex = Regex("[A-Za-z0-9._-]{1,64}")

        /** exec.md §1: 64 lowercase hex characters. */
        val IDEM_KEY_PATTERN: Regex = Regex("[0-9a-f]{64}")

        private val TOP_LEVEL_MEMBERS: Set<String> = setOf(
            "exec_id",
            "argv",
            "cwd",
            "env",
            "deadline",
            "grace_ms",
            "stdin",
            "tier",
            "confine",
            "requires_mseq",
            "idem_key",
        )

        /**
         * Decodes one `0x20` payload.
         *
         * @throws ExecRequestException the request must not enter execution
         * @throws com.phonedsh.wire.WireUnavailable the native codec is missing
         */
        fun parse(payloadJson: String): ExecRequest {
            val canonical = canonicalPayload(payloadJson)
            val payload = try {
                JSONObject(canonical)
            } catch (malformed: RuntimeException) {
                fail("", ExecRequestException.Reason.MALFORMED_JSON, "EXEC_REQ must be a JSON payload")
            }
            rejectUnknown(payload, TOP_LEVEL_MEMBERS, "")

            val execId = requiredString(payload, "exec_id")
            val argv = requiredArgv(payload)
            val cwd = requiredString(payload, "cwd")
            val requiresMseq = requiredLong(payload, "requires_mseq")
            val idemKey = requiredString(payload, "idem_key")
            val env = readEnv(payload)
            val deadline = optionalLong(payload, "deadline")
            val graceMs = optionalLong(payload, "grace_ms") ?: DEFAULT_GRACE_MS
            val stdin = readStdin(payload)
            val tier = readTier(payload)
            val confine = readConfine(payload)

            return ExecRequest(
                execId = execId,
                argv = argv,
                cwd = cwd,
                env = env,
                deadline = deadline,
                graceMs = graceMs,
                stdin = stdin,
                tier = tier,
                confine = confine,
                requiresMseq = requiresMseq,
                idemKey = idemKey,
            )
        }

        private fun canonicalPayload(json: String): String = try {
            WireCodec.canonicalJson(json)
        } catch (invalid: WireException) {
            fail(
                "",
                ExecRequestException.Reason.MALFORMED_JSON,
                "EXEC_REQ is not legal canonical JSON (${invalid.code})",
            )
        }

        private fun requiredString(payload: JSONObject, name: String): String =
            requiredString(payload, name, name)

        private fun requiredString(payload: JSONObject, name: String, field: String): String {
            if (!payload.has(name)) {
                fail(field, ExecRequestException.Reason.MISSING, "$field is required")
            }
            val value = payload.opt(name)
            if (value !is String) {
                fail(field, ExecRequestException.Reason.WRONG_TYPE, "$field must be a string")
            }
            return value
        }

        private fun requiredArgv(payload: JSONObject): List<String> {
            if (!payload.has("argv")) {
                fail("argv", ExecRequestException.Reason.MISSING, "argv is required")
            }
            val array = payload.opt("argv") as? JSONArray
                ?: fail("argv", ExecRequestException.Reason.WRONG_TYPE, "argv must be an array of strings")
            if (array.length() == 0) {
                fail("argv", ExecRequestException.Reason.OUT_OF_RANGE, "argv must not be empty")
            }
            val argv = ArrayList<String>(array.length())
            for (index in 0 until array.length()) {
                val element = array.opt(index)
                if (element !is String) {
                    fail("argv", ExecRequestException.Reason.WRONG_TYPE, "argv elements must be strings")
                }
                // No emptiness check: see [ExecRequest.init]. `""` is an
                // argument, and refusing it here is what closed the channel.
                argv.add(element)
            }
            return argv
        }

        private fun requiredLong(payload: JSONObject, name: String): Long {
            if (!payload.has(name)) {
                fail(name, ExecRequestException.Reason.MISSING, "$name is required")
            }
            return integer(payload.opt(name), name)
        }

        private fun optionalLong(payload: JSONObject, name: String): Long? {
            if (!payload.has(name)) return null
            return integer(payload.opt(name), name)
        }

        private fun integer(value: Any?, field: String): Long {
            if (value == null || value === JSONObject.NULL || value !is Number) {
                fail(field, ExecRequestException.Reason.WRONG_TYPE, "$field must be an integer")
            }
            val text = value.toString()
            if (text.any { it == '.' || it == 'e' || it == 'E' }) {
                fail(field, ExecRequestException.Reason.WRONG_TYPE, "$field must be an integer")
            }
            return text.toLongOrNull()
                ?: fail(field, ExecRequestException.Reason.OUT_OF_RANGE, "$field is outside the 64-bit range")
        }

        private fun readEnv(payload: JSONObject): Map<String, String?> {
            if (!payload.has("env")) return emptyMap()
            val envObject = payload.opt("env") as? JSONObject
                ?: fail("env", ExecRequestException.Reason.WRONG_TYPE, "env must be a JSON object")
            val env = LinkedHashMap<String, String?>()
            val names = envObject.keys()
            while (names.hasNext()) {
                val name = names.next()
                val value = envObject.opt(name)
                env[name] = when {
                    value is String -> value
                    value === JSONObject.NULL -> null
                    else -> fail(
                        "env",
                        ExecRequestException.Reason.WRONG_TYPE,
                        "env values must be strings or null",
                    )
                }
            }
            return env
        }

        private fun readStdin(payload: JSONObject): StdinSpec {
            if (!payload.has("stdin")) return StdinSpec.Ignore
            val stdinObject = payload.opt("stdin") as? JSONObject
                ?: fail("stdin", ExecRequestException.Reason.WRONG_TYPE, "stdin must be a JSON object")
            rejectUnknown(stdinObject, setOf("mode", "data"), "stdin")
            val mode = requiredString(stdinObject, "mode", "stdin.mode")
            return when (mode) {
                "ignore" -> {
                    if (stdinObject.has("data")) {
                        fail(
                            "stdin",
                            ExecRequestException.Reason.UNKNOWN_MEMBER,
                            "stdin.data is only legal with mode=data",
                        )
                    }
                    StdinSpec.Ignore
                }

                "pipe" -> {
                    if (stdinObject.has("data")) {
                        fail(
                            "stdin",
                            ExecRequestException.Reason.UNKNOWN_MEMBER,
                            "stdin.data is only legal with mode=data",
                        )
                    }
                    StdinSpec.Pipe
                }

                "data" -> StdinSpec.Data(requiredString(stdinObject, "data", "stdin.data"))

                else -> fail(
                    "stdin.mode",
                    ExecRequestException.Reason.BAD_VALUE,
                    "stdin.mode must be ignore, data or pipe",
                )
            }
        }

        private fun readTier(payload: JSONObject): ExecTier? {
            if (!payload.has("tier")) return null
            val value = payload.opt("tier")
            if (value !is String) {
                fail("tier", ExecRequestException.Reason.WRONG_TYPE, "tier must be a string")
            }
            return ExecTier.entries.firstOrNull { it.wireName == value }
                ?: fail(
                    "tier",
                    ExecRequestException.Reason.BAD_VALUE,
                    "tier must be interactive, session or batch",
                )
        }

        private fun readConfine(payload: JSONObject): Confine? {
            if (!payload.has("confine")) return null
            val confineObject = payload.opt("confine") as? JSONObject
                ?: fail("confine", ExecRequestException.Reason.WRONG_TYPE, "confine must be a JSON object")
            rejectUnknown(confineObject, setOf("mode", "workspace_root"), "confine")
            val modeName = requiredString(confineObject, "mode", "confine.mode")
            val mode = ConfineMode.entries.firstOrNull { it.wireName == modeName }
                ?: fail(
                    "confine.mode",
                    ExecRequestException.Reason.BAD_VALUE,
                    "confine.mode must be read-only or workspace-write",
                )
            val root = requiredString(confineObject, "workspace_root", "confine.workspace_root")
            return Confine(mode = mode, workspaceRoot = root)
        }

        private fun rejectUnknown(payload: JSONObject, allowed: Set<String>, field: String) {
            val names = payload.keys()
            while (names.hasNext()) {
                val name = names.next()
                if (name !in allowed) {
                    // The member name itself can be attacker-chosen; it is not echoed.
                    fail(
                        field,
                        ExecRequestException.Reason.UNKNOWN_MEMBER,
                        "EXEC_REQ carries a member the schema does not define",
                    )
                }
            }
        }

        private fun fail(field: String, reason: ExecRequestException.Reason, detail: String): Nothing =
            throw ExecRequestException(field, reason, detail)
    }
}
