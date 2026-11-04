// The first production consumer of the domain store: the session transcript cache.
// SPDX-License-Identifier: MIT
//
// ---- what this is, and what it is not --------------------------------------
// The authoritative session/message record on this platform is the host WAL and
// the journal (`:dsh` `WorkspaceLog` / `JournalStore`), exactly as it is on the
// iOS baseline, where `ChatModel` reads history back through
// `loadSessionHistory(after:)` rather than from any app-level database. This
// class does **not** become a second authority for those events and cannot: it
// only stores what the app itself rendered, projected from events it already
// received.
//
// What it restores is the iOS baseline's `transcript-snapshots/<sessionID>.json`
// (`examples/probe-app/PhoneDSHProbe/ChatModel.swift:2512-2599`): the last
// settled items plus the session the app last opened, so a cold start can paint
// the last screen before the worker is up. On iOS that is a directory of atomic
// JSON files; here it is one domain of the local `DomainStore`, because
// `docs/design/phone-dsh-app/PRD.md:169` names the transcript as DomainStore
// content ("原始证据、转写、Main 过程、任务引用和 Memory 均指向同一个本地
// DomainStore"). The *behaviour* is the baseline's; the *storage* is the PRD's.
//
// ---- why DomainStore, and not a third JSON file ----------------------------
// `:dsh` already owns `host-state.json` and the journal. A third hand-rolled
// JSON file next to them would be a third durability story in one process. The
// domain store's own contract — one writer, atomic transactions, absolute
// per-domain quota, `updated_at` monotonic across restarts — is exactly the set
// of properties this cache needs and none of the properties it must not claim
// (no WAL, no power-loss ladder; see `DomainStore`'s header).
//
// ---- layout ----------------------------------------------------------------
// Domain [`DomainNames.SESSION`], two kinds of key:
//
//   `current`         the session id this app last opened. The analogue of the
//                     baseline's `currentSessionDefaultsKey`, kept as its own
//                     row so it can be cleared independently of the payload and
//                     so "the last session" is a recorded fact rather than
//                     "whichever row was written last".
//   `turn/<id>`       one encoded [`ArchivedTurn`] per session.
//
// The `turn/` prefix is what makes [`sessionIds`] a range scan rather than a
// full-domain walk.
//
// ---- failure model ---------------------------------------------------------
// A row that cannot be decoded is reported as `null` by [`latest`], never as a
// partially-decoded turn: a cache that invents half a transcript is worse than
// one that shows nothing. It is not deleted either — silent data loss is what
// `spec/v1/budgets.md` §5 forbids — so the next successful save for that session
// replaces it.

package com.phonedsh.domain.session

import com.phonedsh.domain.DomainEntry
import com.phonedsh.domain.DomainNames
import com.phonedsh.domain.DomainStore

/** One command a turn's `tool_call` events named. */
class ArchivedCommand(
    val id: String,
    val command: String,
) {
    override fun equals(other: Any?): Boolean =
        other is ArchivedCommand && id == other.id && command == other.command

    override fun hashCode(): Int = 31 * id.hashCode() + command.hashCode()

    override fun toString(): String = "ArchivedCommand(id=$id, command=$command)"
}

/** One path a write tool named, and which tool named it. */
class ArchivedWrite(
    val path: String,
    val toolName: String?,
) {
    override fun equals(other: Any?): Boolean =
        other is ArchivedWrite && path == other.path && toolName == other.toolName

    override fun hashCode(): Int = 31 * path.hashCode() + (toolName?.hashCode() ?: 0)

    override fun toString(): String = "ArchivedWrite(path=$path, toolName=$toolName)"
}

/**
 * The rendered outcome of one completed turn, as it is stored.
 *
 * Every field is a projection of events the worker already sent: nothing here is
 * inferred from a tool name, and an empty list means the turn named nothing —
 * never "the store lost it".
 *
 * @param sessionId the worker's session id; must not be blank.
 * @param completedAtMs the wall-clock instant the app observed completion.
 * @param kinds the projected host event kinds, in wire order.
 * @param commands the tool calls that named a command.
 * @param writes the write tools that named a path.
 * @throws IllegalArgumentException when [sessionId] is blank or the lists exceed
 *   [`SessionArchive.CAPACITY`].
 */
class ArchivedTurn(
    val sessionId: String,
    val completedAtMs: Long,
    val kinds: List<String> = emptyList(),
    val commands: List<ArchivedCommand> = emptyList(),
    val writes: List<ArchivedWrite> = emptyList(),
) {
    init {
        require(sessionId.isNotBlank()) { "an archived turn needs a non-blank session id" }
        require(kinds.size <= SessionArchive.CAPACITY) {
            "kinds holds ${kinds.size} items; the baseline keeps at most ${SessionArchive.CAPACITY}"
        }
        require(commands.size <= SessionArchive.CAPACITY) {
            "commands holds ${commands.size} items; the baseline keeps at most ${SessionArchive.CAPACITY}"
        }
        require(writes.size <= SessionArchive.CAPACITY) {
            "writes holds ${writes.size} items; the baseline keeps at most ${SessionArchive.CAPACITY}"
        }
    }

    override fun equals(other: Any?): Boolean =
        other is ArchivedTurn &&
            sessionId == other.sessionId &&
            completedAtMs == other.completedAtMs &&
            kinds == other.kinds &&
            commands == other.commands &&
            writes == other.writes

    override fun hashCode(): Int {
        var result = sessionId.hashCode()
        result = 31 * result + completedAtMs.hashCode()
        result = 31 * result + kinds.hashCode()
        result = 31 * result + commands.hashCode()
        result = 31 * result + writes.hashCode()
        return result
    }

    override fun toString(): String =
        "ArchivedTurn(sessionId=$sessionId, kinds=${kinds.size}, " +
            "commands=${commands.size}, writes=${writes.size})"
}

/**
 * The transcript cache over one [DomainStore].
 *
 * Every method is synchronous and touches disk; the [DomainStore] header's
 * threading rule applies unchanged — callers must not run these on the Android
 * main thread. They are safe for concurrent callers because the store
 * serialises them.
 *
 * @param store the domain store this cache owns its `session` domain of. The
 *   caller owns the store's lifetime; this class never closes it.
 */
class SessionArchive(private val store: DomainStore) {
    /**
     * Stores [turn] and makes its session the current one, in one transaction.
     *
     * The two writes are one unit on purpose: a payload without a pointer would
     * be invisible to [`latest`], and a pointer without a payload would make a
     * cold start fail after promising a session. Either both land or neither.
     *
     * @throws com.phonedsh.domain.QuotaExceededException when the `session`
     *   domain would cross its absolute quota. The write is not applied and the
     *   previous contents of the domain are unchanged.
     */
    fun save(turn: ArchivedTurn) {
        val payload = SessionArchiveCodec.encode(turn)
        store.transaction {
            // The order is unobservable from outside — the two writes commit
            // together — but the pointer goes first because it is the smaller
            // value: a quota refusal then lands on the payload, after the pointer
            // was already written, so the rollback path is the one a test drives.
            put(DomainNames.SESSION, CURRENT_KEY, turn.sessionId.toByteArray(Charsets.UTF_8))
            put(DomainNames.SESSION, payloadKey(turn.sessionId), payload)
        }
    }

    /**
     * The current session's turn, or `null` when there is none to trust.
     *
     * `null` covers three distinct situations and deliberately does not
     * distinguish them, because the caller's action is the same for all three:
     * no `current` row (nothing was ever saved, or it was cleared), a `current`
     * row whose payload row is gone (the pair was broken by an outside write),
     * and a payload that does not decode (a row written by a different schema or
     * damaged on disk). A restored UI must not claim a turn it could not read.
     */
    fun latest(): ArchivedTurn? {
        val sessionId = currentSessionId() ?: return null
        val payload = store.get(DomainNames.SESSION, payloadKey(sessionId)) ?: return null
        val turn = SessionArchiveCodec.decodeOrNull(payload) ?: return null
        // A payload filed under one session id but carrying another is a write
        // bug or a hand-edited row. Report nothing rather than a turn whose id
        // disagrees with the pointer that found it.
        return if (turn.sessionId == sessionId) turn else null
    }

    /**
     * The session id this app last opened, or `null`.
     *
     * Readable on its own so the sessions page can mark the current row without
     * decoding a payload; it is the same value [`save`] recorded.
     */
    fun currentSessionId(): String? {
        val bytes = store.get(DomainNames.SESSION, CURRENT_KEY) ?: return null
        val sessionId = bytes.toString(Charsets.UTF_8)
        return sessionId.ifBlank { null }
    }

    /**
     * The session ids this cache holds a turn for, in key order.
     *
     * A read only: it does not decode the payloads, so one damaged row cannot
     * hide the others.
     */
    fun sessionIds(): List<String> {
        if (store.usageBytes(DomainNames.SESSION) == 0L) return emptyList()
        val entries: List<DomainEntry> =
            store.list(DomainNames.SESSION, PAYLOAD_PREFIX, MAXIMUM_LISTED_SESSIONS)
        return entries.map { it.key.removePrefix(PAYLOAD_PREFIX) }
    }

    /** How many turns the cache holds. Reads the domain's usage, not its rows. */
    fun sessionCount(): Int = sessionIds().size

    /**
     * Drops the pointer, leaving the payload rows in place.
     *
     * @return whether a `current` row existed. Used when the app decides the
     *   last session must not be reopened (the baseline clears
     *   `currentSessionDefaultsKey` for a session it will not resume); the
     *   history itself is not destroyed by that decision.
     */
    fun clearCurrent(): Boolean = store.delete(DomainNames.SESSION, CURRENT_KEY)

    private fun payloadKey(sessionId: String): String = PAYLOAD_PREFIX + sessionId

    companion object {
        /** The domain this cache is the only writer of. */
        const val DOMAIN: String = DomainNames.SESSION

        /** The SQLite file the composition root opens. */
        const val DATABASE_NAME: String = "phonedsh-domain.db"

        /**
         * How many items of each list one turn may keep.
         *
         * The value is the iOS baseline's, not a spec constant: `ChatModel`
         * stores `items.filter { !$0.streaming }.suffix(400)`. Keeping the same
         * number means a session rendered after a restore holds the same tail on
         * both platforms.
         */
        const val CAPACITY: Int = 400

        /**
         * The absolute byte quota of the `session` domain.
         *
         * Not a spec number: `spec/v1/budgets.md` §5 has no DomainStore row (it
         * budgets the WAL, the response log, the journal and `video/`), so this
         * is the composition root's policy. 4 MiB holds thousands of
         * 400-item turns of projected text while staying small enough that a
         * runaway writer fails loudly instead of filling the device.
         */
        const val QUOTA_BYTES: Long = 4L * 1024L * 1024L

        /** The pointer row; see the header. */
        internal const val CURRENT_KEY = "current"

        /** The payload key prefix; a range scan on it lists the sessions. */
        internal const val PAYLOAD_PREFIX = "turn/"

        /**
         * The most sessions one [`sessionIds`] call returns.
         *
         * A read bound, not a retention policy: the cache never evicts (silent
         * deletion is what §5 forbids), so this only keeps one call from
         * materialising an unbounded list. A caller that needs more pages.
         */
        const val MAXIMUM_LISTED_SESSIONS: Int = 1000
    }
}

/**
 * The stored encoding of one [ArchivedTurn].
 *
 * Positional and count-prefixed rather than JSON: the payload is opaque bytes to
 * the store, and a count-prefixed record needs no parser, no escaping of
 * structural characters and no length ambiguity. It stays readable in
 * `cast(value as text)` because the only escapes are for the three characters
 * that would otherwise be structural.
 *
 * ```
 * pdsh-session-archive/1
 * <esc(sessionId)>
 * <completedAtMs>
 * <kinds.size>
 * <esc(kind)> ...
 * <commands.size>
 * <esc(id)>\t<esc(command)> ...
 * <writes.size>
 * <esc(path)>\t<esc(toolName or empty)>
 * ```
 *
 * A missing `toolName` and an empty one are the same value: [ArchivedWrite]
 * cannot hold a blank tool name, because "the event carried no tool name" and
 * "the event carried an empty tool name" are the same fact.
 */
internal object SessionArchiveCodec {
    private const val MAGIC = "pdsh-session-archive/1"

    /**
     * A per-field cap, so one damaged row cannot make the decoder allocate a
     * megabyte per line. The quota bounds the row; this bounds the parse.
     */
    private const val MAXIMUM_FIELD_CHARS = 8192

    /**
     * The most characters one *line* may hold.
     *
     * Escaping can double a field (`\` -> `\\`), and a pair line carries two of
     * them, so the line bound is four times the field bound. Using the field
     * bound here would make the decoder reject records the encoder itself
     * produced — the round-trip test with backslash-heavy text is what would
     * catch it.
     */
    private const val MAXIMUM_LINE_CHARS = MAXIMUM_FIELD_CHARS * 4 + 8

    /** The most lines one record may hold; `CAPACITY` per list plus header. */
    private const val MAXIMUM_LINES = SessionArchive.CAPACITY * 3 + 8

    fun encode(turn: ArchivedTurn): ByteArray = buildString(256) {
        append(MAGIC).append('\n')
        append(escape(turn.sessionId)).append('\n')
        append(turn.completedAtMs).append('\n')

        append(turn.kinds.size).append('\n')
        turn.kinds.forEach { append(escape(it)).append('\n') }

        append(turn.commands.size).append('\n')
        turn.commands.forEach { command ->
            append(escape(command.id)).append('\t').append(escape(command.command)).append('\n')
        }

        append(turn.writes.size).append('\n')
        turn.writes.forEach { write ->
            append(escape(write.path)).append('\t').append(escape(write.toolName ?: "")).append('\n')
        }
    }.toByteArray(Charsets.UTF_8)

    /** The decoded record, or `null` when the bytes are not a record this version wrote. */
    fun decodeOrNull(bytes: ByteArray): ArchivedTurn? = try {
        Reader(bytes.toString(Charsets.UTF_8)).decode()
    } catch (malformed: IllegalArgumentException) {
        null
    } catch (malformed: IndexOutOfBoundsException) {
        null
    }

    private fun escape(value: String): String {
        require(value.length <= MAXIMUM_FIELD_CHARS) {
            "an archived field is ${value.length} chars; the cap is $MAXIMUM_FIELD_CHARS"
        }
        val builder = StringBuilder(value.length)
        for (character in value) {
            when (character) {
                '\\' -> builder.append("\\\\")
                '\n' -> builder.append("\\n")
                '\r' -> builder.append("\\r")
                '\t' -> builder.append("\\t")
                else -> builder.append(character)
            }
        }
        return builder.toString()
    }

    private fun unescape(value: String): String {
        val builder = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val character = value[index]
            if (character != '\\') {
                builder.append(character)
                index += 1
                continue
            }
            require(index + 1 < value.length) { "a trailing escape at offset $index" }
            builder.append(
                when (val escaped = value[index + 1]) {
                    '\\' -> '\\'
                    'n' -> '\n'
                    'r' -> '\r'
                    't' -> '\t'
                    else -> throw IllegalArgumentException("unknown escape \\$escaped")
                },
            )
            index += 2
        }
        return builder.toString()
    }

    private class Reader(private val text: String) {
        private var offset = 0
        private var linesRead = 0

        fun decode(): ArchivedTurn {
            require(line() == MAGIC) { "not a session archive record" }
            val sessionId = unescape(line())
            val completedAtMs = longLine()
            val kinds = List(intLine(cap = SessionArchive.CAPACITY)) { unescape(line()) }
            val commands = List(intLine(cap = SessionArchive.CAPACITY)) {
                val (id, command) = pair(line())
                ArchivedCommand(unescape(id), unescape(command))
            }
            val writes = List(intLine(cap = SessionArchive.CAPACITY)) {
                val (path, tool) = pair(line())
                ArchivedWrite(unescape(path), unescape(tool).ifBlank { null })
            }
            require(offset == text.length) { "trailing content at offset $offset" }
            return ArchivedTurn(sessionId, completedAtMs, kinds, commands, writes)
        }

        private fun line(): String {
            require(linesRead < MAXIMUM_LINES) { "the record holds more than $MAXIMUM_LINES lines" }
            linesRead += 1
            val newline = text.indexOf('\n', offset)
            require(newline >= 0) { "unterminated line at offset $offset" }
            require(newline - offset <= MAXIMUM_LINE_CHARS) {
                "a line is ${newline - offset} chars; the cap is $MAXIMUM_LINE_CHARS"
            }
            val value = text.substring(offset, newline)
            offset = newline + 1
            return value
        }

        /** A `left<TAB>right` line. The right side may be empty; the left may not. */
        private fun pair(value: String): Pair<String, String> {
            val tab = value.indexOf('\t')
            require(tab >= 0) { "a pair line is missing its tab" }
            return value.substring(0, tab) to value.substring(tab + 1)
        }

        private fun longLine(): Long =
            line().toLongOrNull() ?: throw IllegalArgumentException("a long line is not a number")

        private fun intLine(cap: Int): Int {
            val parsed = line().toIntOrNull()
                ?: throw IllegalArgumentException("a count line is not an integer")
            require(parsed in 0..cap) { "a count of $parsed is outside 0..$cap" }
            return parsed
        }
    }
}
