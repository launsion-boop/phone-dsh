// phone-dsh — :dsh / com.phonedsh.dsh.exec: the durable D10 dedup table.
// SPDX-License-Identifier: MIT
//
// exec.md §2: the host keeps a persistent dedup table under
// `Library/xl/<workspace_id>/exec/`, one file per key, `exec/<idem_key>.json`,
// written with the temp-file + rename + directory-fsync rule. This class is the
// file backend of that table; the `RequestLedger` interface is unchanged, so
// `PhoneToolBridge` and the exec bridge do not learn a second idempotency path:
//
//   * `admit` writes the *intent* entry and fsyncs it before the tool body can
//     run, so a kill mid-execution leaves a record instead of a blank;
//   * `complete` replaces the entry with the full recorded stream (or the
//     structured failure), atomically;
//   * `abandon` removes an entry whose call never produced an outcome, because
//     the worker may legitimately retry it.
//
// The file of a completed success *is* the ExecRecord of exec.md §2
// (`v, kind, idem_key, exec_id, argv, cwd, created_at_ms, terminal, events`)
// plus the ledger's `tool` member, so replay needs no translation. A failure
// carries an `outcome` object instead of an event stream; a recovered in-flight
// intent is terminalized with the `interrupted` error of exec.md §2 and answers
// `Replay` from then on, never a re-execution.
//
// Durability goes through the one `:platform` SPI (`atomicReplace` +
// `fsyncPath`). `RequestLedger` is synchronous by design (the tool gate calls it
// from dispatch code), while the SPI is suspend, so this adapter is the single
// place that bridges the two with `runBlocking`; the SPI implementation does its
// own IO dispatch, so no coroutine is blocked on a filesystem call it owns.
//
// The table is bounded by [maxEntries]. Eviction removes the oldest *completed*
// entries only; an in-flight entry is never forgotten, because forgetting it
// would allow the same key to execute twice.

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.tools.RequestLedger
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject

/** The exec dedup table could not be read, written or replayed. */
class ExecLedgerException(
    detail: String,
    cause: Throwable? = null,
) : IllegalStateException("exec ledger: $detail", cause)

/**
 * The file-backed [RequestLedger] of exec.md §2.
 *
 * @param workspaceRoot the workspace directory the host already owns
 *   (`Library/xl/<workspace_id>`); the entries live in its `exec/` child, so no
 *   absolute path is stored anywhere
 * @param durability the one durable-write SPI; every entry write is atomic and
 *   directory-fsynced
 * @param clock wall time for the entry's `created_at_ms`, which orders eviction
 * @param maxEntries bound on retained entries; completed entries are evicted
 *   oldest-first, in-flight entries never
 */
class FileRequestLedger(
    workspaceRoot: Path,
    private val durability: Durability,
    private val clock: Clock,
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) : RequestLedger {
    init {
        require(maxEntries > 0) { "maxEntries must be positive, was $maxEntries" }
    }

    /** `exec/`, the dedup directory of exec.md §2. */
    private val entriesDirectory: Path = workspaceRoot.resolve(EXEC_DIRECTORY)

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()

    init {
        try {
            Files.createDirectories(entriesDirectory)
        } catch (failure: IOException) {
            throw ExecLedgerException(
                "cannot create the exec ledger directory: ${failure.message}",
                failure,
            )
        }
        load()
    }

    /** One in-memory index row; the file is the authority. */
    private class Entry(
        val key: String,
        val tool: String,
        val createdAtMs: Long,
        var outcome: ToolOutcome? = null,
    ) {
        val completed: Boolean get() = outcome != null
    }

    override fun admit(requestId: String, tool: String): RequestLedger.Admission =
        synchronized(lock) {
            requireKey(requestId)
            val existing = entries[requestId]
            if (existing != null) {
                val outcome = existing.outcome
                return if (outcome != null) {
                    RequestLedger.Admission.Replay(existing.tool, outcome)
                } else {
                    RequestLedger.Admission.InFlight
                }
            }
            val entry = Entry(key = requestId, tool = tool, createdAtMs = clock.nowMillis())
            write(entry, outcome = null)
            entries[requestId] = entry
            trim(keep = requestId)
            RequestLedger.Admission.Proceed
        }

    override fun complete(requestId: String, outcome: ToolOutcome) {
        synchronized(lock) {
            requireKey(requestId)
            val existing = entries[requestId]
            val entry = if (existing != null) {
                existing
            } else {
                // The intent write precedes the tool run; a missing row here would
                // be a caller defect. Keep the outcome rather than losing a
                // replay, and take the identity the record itself carries.
                val record = (outcome as? ToolOutcome.Success)?.let { success ->
                    try {
                        ExecRecord.parse(success.resultJson)
                    } catch (invalid: IllegalArgumentException) {
                        null
                    }
                }
                Entry(
                    key = requestId,
                    tool = record?.argv?.firstOrNull() ?: UNKNOWN_TOOL,
                    createdAtMs = record?.createdAtMs ?: clock.nowMillis(),
                )
            }
            write(entry, outcome)
            entry.outcome = outcome
            entries[requestId] = entry
            trim(keep = requestId)
        }
    }

    override fun abandon(requestId: String) {
        synchronized(lock) {
            requireKey(requestId)
            if (entries.remove(requestId) == null) return
            delete(requestId)
        }
    }

    /** Entries currently tracked, in admission order (tests and diagnostics). */
    fun tracked(): List<String> = synchronized(lock) { entries.keys.toList() }

    // ---- persistence -----------------------------------------------------

    /**
     * Writes one entry through the SPI. `atomicReplace` publishes the temp file
     * by rename; the explicit directory fsync afterwards is the observable
     * "rename is durable" step of wal.md §7.1, not a duplicate of an
     * implementation detail (the same order as `WorkspaceLog.writeManifest`).
     */
    private fun write(entry: Entry, outcome: ToolOutcome?) {
        val path = pathOf(entry.key)
        val bytes = encode(entry, outcome).toByteArray(Charsets.UTF_8)
        try {
            runBlocking { durability.atomicReplace(path) { temporary -> Files.write(temporary, bytes) } }
            runBlocking { durability.fsyncPath(entriesDirectory) }
        } catch (failure: IOException) {
            throw ExecLedgerException(
                "cannot persist the entry ${path.fileName}: ${failure.message}",
                failure,
            )
        }
    }

    private fun delete(key: String) {
        val path = pathOf(key)
        try {
            if (Files.deleteIfExists(path)) {
                runBlocking { durability.fsyncPath(entriesDirectory) }
            }
        } catch (failure: IOException) {
            throw ExecLedgerException(
                "cannot remove the abandoned entry ${path.fileName}: ${failure.message}",
                failure,
            )
        }
    }

    /** The canonical on-disk shape of one entry. */
    private fun encode(entry: Entry, outcome: ToolOutcome?): String {
        val payload = JSONObject()
        payload.put("v", VERSION)
        payload.put("kind", KIND)
        payload.put("idem_key", entry.key)
        payload.put("tool", entry.tool)
        payload.put("created_at_ms", entry.createdAtMs)
        if (outcome == null) {
            payload.put("terminal", false)
            payload.put("events", JSONArray())
            return canonical(payload)
        }
        when (outcome) {
            is ToolOutcome.Success -> {
                val record = try {
                    ExecRecord.parse(outcome.resultJson)
                } catch (invalid: IllegalArgumentException) {
                    // Not an exec record: keep it replayable verbatim rather than
                    // writing a file a later boot cannot reconstruct.
                    payload.put("terminal", true)
                    payload.put("events", JSONArray())
                    payload.put("outcome", outcomeEnvelope("success", result = outcome.resultJson))
                    return canonical(payload)
                }
                val recorded = JSONObject(record.toJson())
                for (name in recorded.keys()) payload.put(name, recorded.get(name))
                payload.put("tool", entry.tool)
                return canonical(payload)
            }

            is ToolOutcome.Failure -> {
                payload.put("terminal", true)
                payload.put("events", JSONArray())
                payload.put("outcome", outcomeEnvelope(
                    kind = "failure",
                    code = outcome.code,
                    message = outcome.message,
                ))
            }
        }
        return canonical(payload)
    }

    private fun outcomeEnvelope(
        kind: String,
        result: String? = null,
        code: String? = null,
        message: String? = null,
    ): JSONObject = JSONObject().apply {
        put("kind", kind)
        result?.let { put("result", it) }
        code?.let { put("code", it) }
        message?.let { put("message", it) }
    }

    private fun canonical(payload: JSONObject): String = WireCodec.canonicalJson(payload.toString())

    // ---- load and retention ----------------------------------------------

    /**
     * Rebuilds the index from the entry files of `exec/`.
     *
     * A completed entry restores the outcome it records. An intent entry with no
     * terminal event is the "host died mid-execution" case of exec.md §2: it is
     * terminalized with an `interrupted` error and answers `Replay` on the next
     * request. A file that cannot be read is fail-loud: a partial replay table
     * could execute a side effect twice.
     *
     * ### The recovered intent has no execution identity
     *
     * `RequestLedger.admit` receives only the key and the tool, and the intent is
     * written there, before the tool body runs: it cannot carry `argv`, `cwd` or
     * `exec_id`. So a retry of a crashed execution whose `argv` or `cwd` changed
     * replays `interrupted` instead of `exec_id_conflict`. This is a deliberate,
     * documented weakening: the guarantee that matters — the side effect is
     * never executed a second time — holds; only the precision of the error code
     * is lost, and it cannot distinguish "same call retried" from "same key,
     * different call". A stricter conflict check would have to bind a second
     * identity source before dispatch, i.e. duplicate the very fact this table
     * is the single authority for.
     */
    private fun load() {
        val names = ArrayList<String>()
        try {
            Files.newDirectoryStream(entriesDirectory).use { stream ->
                for (path in stream) {
                    if (Files.isRegularFile(path)) names.add(path.fileName.toString())
                }
            }
        } catch (failure: IOException) {
            throw ExecLedgerException(
                "cannot list the exec ledger directory: ${failure.message}",
                failure,
            )
        }
        names.sort()
        for (name in names) {
            if (!name.endsWith(SUFFIX)) continue
            val key = name.dropLast(SUFFIX.length)
            if (!ExecRequest.IDEM_KEY_PATTERN.matches(key)) continue
            val path = entriesDirectory.resolve(name)
            val payload = readPayload(path)
            if (payload.optInt("v", -1) != VERSION) {
                throw ExecLedgerException("${path.fileName} has an unknown version")
            }
            if (payload.opt("kind") != KIND) {
                throw ExecLedgerException("${path.fileName} is not an exec entry")
            }
            if (payload.opt("idem_key") != key) {
                throw ExecLedgerException("${path.fileName} names another idem_key")
            }
            val createdAtMs = payload.opt("created_at_ms")?.toString()?.toLongOrNull() ?: 0L
            val recorded = readOutcome(path, payload)
            if (recorded != null) {
                entries[key] = Entry(key, toolOf(payload, recorded), createdAtMs, recorded)
                continue
            }
            val interrupted = ToolOutcome.Failure(CODE_INTERRUPTED, MESSAGE_INTERRUPTED)
            val entry = Entry(key, toolOf(payload, interrupted), createdAtMs, interrupted)
            write(entry, interrupted)
            entries[key] = entry
        }
        trim(keep = null)
    }

    private fun readPayload(path: Path): JSONObject {
        val text = try {
            Files.readAllBytes(path).toString(Charsets.UTF_8)
        } catch (failure: IOException) {
            throw ExecLedgerException("cannot read ${path.fileName}: ${failure.message}", failure)
        }
        val canonical = try {
            WireCodec.canonicalJson(text)
        } catch (invalid: WireException) {
            throw ExecLedgerException("${path.fileName} is not legal JSON (${invalid.code})", invalid)
        }
        return try {
            JSONObject(canonical)
        } catch (invalid: RuntimeException) {
            throw ExecLedgerException("${path.fileName} is not a JSON object", invalid)
        }
    }

    /** The outcome an entry records, or null for an intent that never finished. */
    private fun readOutcome(path: Path, payload: JSONObject): ToolOutcome? {
        val envelope = payload.opt("outcome")
        if (envelope is JSONObject) {
            return when (val kind = envelope.opt("kind")) {
                "success" -> ToolOutcome.Success(stringMember(path, envelope, "result"))
                "failure" -> ToolOutcome.Failure(
                    stringMember(path, envelope, "code"),
                    stringMember(path, envelope, "message"),
                )

                else -> throw ExecLedgerException("${path.fileName} has an unknown outcome kind")
            }
        }
        if (!payload.optBoolean("terminal", false)) return null
        val events = payload.opt("events") as? JSONArray
            ?: throw ExecLedgerException("${path.fileName} is terminal but has no events")
        if (events.length() == 0) {
            throw ExecLedgerException("${path.fileName} is terminal but records no outcome")
        }
        val record = try {
            ExecRecord.parse(payload.toString())
        } catch (invalid: IllegalArgumentException) {
            throw ExecLedgerException("${path.fileName} is not a replayable exec record", invalid)
        }
        return ToolOutcome.Success(record.toJson())
    }

    private fun toolOf(payload: JSONObject, outcome: ToolOutcome): String {
        (payload.opt("tool") as? String)?.let { if (it.isNotEmpty()) return it }
        return (outcome as? ToolOutcome.Success)?.let { success ->
            try {
                ExecRecord.parse(success.resultJson).argv.firstOrNull()
            } catch (invalid: IllegalArgumentException) {
                null
            }
        } ?: UNKNOWN_TOOL
    }

    private fun stringMember(path: Path, payload: JSONObject, name: String): String =
        payload.opt(name) as? String
            ?: throw ExecLedgerException("${path.fileName} needs a string $name")

    /**
     * Keeps the table at [maxEntries]. Candidates are completed entries only,
     * oldest `created_at_ms` first (the key breaks ties so a run is
     * deterministic). [keep] is the row currently being written: it is never
     * evicted, so `complete` cannot drop the result it just made durable.
     */
    private fun trim(keep: String?) {
        if (entries.size <= maxEntries) return
        val candidates = entries.values
            .filter { it.completed && it.key != keep }
            .sortedWith(compareBy({ it.createdAtMs }, { it.key }))
        for (candidate in candidates) {
            if (entries.size <= maxEntries) break
            entries.remove(candidate.key)
            // `delete` fsyncs the directory when a file was actually removed.
            delete(candidate.key)
        }
    }

    private fun pathOf(key: String): Path = entriesDirectory.resolve(key + SUFFIX)

    private fun requireKey(key: String) {
        require(ExecRequest.IDEM_KEY_PATTERN.matches(key)) {
            "the exec ledger is keyed by a 64-lowercase-hex idem_key"
        }
    }

    companion object {
        /** exec.md §2: the dedup table lives in `exec/` under the workspace root. */
        const val EXEC_DIRECTORY: String = "exec"

        /** The entry file suffix. */
        const val SUFFIX: String = ".json"

        /** The entry version of exec.md §2. */
        const val VERSION: Int = 1

        /** The only entry kind this table stores. */
        const val KIND: String = "exec"

        /** exec.md §2: a host death mid-execution answers this terminal code. */
        const val CODE_INTERRUPTED: String = "interrupted"

        /** Enough for a turn's tool calls without unbounded growth. */
        const val DEFAULT_MAX_ENTRIES: Int = 1024

        private const val UNKNOWN_TOOL: String = ""

        private const val MESSAGE_INTERRUPTED: String =
            "the host died before the terminal exec event; the execution was not retried"
    }
}
