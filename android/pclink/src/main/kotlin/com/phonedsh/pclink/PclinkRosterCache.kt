// SPDX-License-Identifier: MIT
// P18 PC roster/workspace cache (PC-20261110-pclink-pc-roster-snapshot,
// PC-20261110-pclink-workspace-cache).
//
// One file per paired PC, keyed by its machineId. The value is the versioned
// envelope
//
//   {"v":1,"capturedAtMilliseconds":<n>,"backend":"pc:<machineId>",
//    "payload":<roster projection>}
//
// and every read also accepts the bare payload (the rollback / hand-written
// case). A missing file, a corrupt value and an unknown `v` are all reported
// distinctly and never erase what the caller has on screen: this module only
// reads and writes the cache, it never owns the live list. Writes are atomic
// (temp file + fsync + rename + directory fsync) and an empty roster is never
// written, so the last successful `session/list` stays available.
//
// The projection is deliberately narrow: no pending approvals, queue, stream
// content, tool output, transcript or key material can be represented, and an
// unknown member in a stored object makes that value `Corrupt` instead of being
// silently accepted. The Android directory is supplied by the caller; P18 owns
// its registered path (design §5.3).
package com.phonedsh.pclink

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions

/** One row of the persisted `session/list` projection (never wire content). */
data class PclinkRosterSession(
    val id: String,
    val title: String,
    val updatedAtMilliseconds: Double,
    val running: Boolean,
    val blank: Boolean,
    val cwd: String? = null,
    val parentSessionId: String? = null,
    val searchSnippet: String? = null,
)

/** One persisted `workspace/follow` group. */
data class PclinkRosterWorkspace(
    val id: String,
    val title: String,
    val path: String,
    val sessionIds: List<String>,
)

/**
 * The last successful PC roster projection. It is a cache, not a schema: the
 * PC's `session/list`/`workspace/follow` answers remain authoritative.
 */
data class PclinkRosterSnapshot(
    val sessions: List<PclinkRosterSession> = emptyList(),
    val workspaces: List<PclinkRosterWorkspace> = emptyList(),
    val workspaceOrder: List<String> = emptyList(),
    val pinnedSessionIds: List<String> = emptyList(),
    val archivedIds: List<String> = emptyList(),
) {
    /** An empty snapshot is never persisted (there would be nothing to paint). */
    val isEmpty: Boolean get() = sessions.isEmpty() && workspaces.isEmpty()
}

/** The result of [PclinkRosterCache.read]. */
sealed interface PclinkRosterCacheEntry {
    /**
     * A usable value. [envelopeVersion] is `1` for the envelope and `null` for
     * a bare payload (which carries no capture date).
     */
    data class Stored(
        val snapshot: PclinkRosterSnapshot,
        val capturedAtMilliseconds: Long?,
        val envelopeVersion: Int?,
    ) : PclinkRosterCacheEntry

    /** No cache file for this PC. */
    data object Missing : PclinkRosterCacheEntry

    /** Present but not decodable (bad JSON, wrong scope, unknown member, …). */
    data object Corrupt : PclinkRosterCacheEntry

    /** A well-formed envelope written by a newer format; ignored, never guessed. */
    data class UnsupportedVersion(val version: Long) : PclinkRosterCacheEntry
}

/**
 * File-backed PC roster cache. All methods validate [machineId] before touching
 * the filesystem, so a DSH value can never escape [directory]. The directory is
 * created on the first successful write, not on reads.
 */
class PclinkRosterCache(private val directory: Path) {
    fun read(machineId: String): PclinkRosterCacheEntry {
        requireMachineId(machineId)
        val file = fileFor(machineId)
        if (!Files.isRegularFile(file)) return PclinkRosterCacheEntry.Missing
        return try {
            val root = PclinkJsonParser.parseDocumentObject(Files.readAllBytes(file))
            if (root["v"] != null) {
                decodeEnvelope(root, machineId)
            } else {
                PclinkRosterCacheEntry.Stored(
                    snapshot = decodeSnapshot(root),
                    capturedAtMilliseconds = null,
                    envelopeVersion = null,
                )
            }
        } catch (_: Exception) {
            PclinkRosterCacheEntry.Corrupt
        }
    }

    /**
     * Writes the envelope for [machineId]. Returns `false` without touching the
     * file when [snapshot] is empty; throws [PclinkError.BadFrame] for an
     * invalid projection and [PclinkError.Storage] for an I/O failure.
     *
     * [capturedAtMilliseconds] is the time the successful `session/list`
     * answer was observed; it is only used for display/staleness, never to
     * decide whether to write or read.
     */
    fun write(
        machineId: String,
        snapshot: PclinkRosterSnapshot,
        capturedAtMilliseconds: Long,
    ): Boolean {
        requireMachineId(machineId)
        if (capturedAtMilliseconds < 0) {
            throw PclinkError.BadFrame("capturedAtMilliseconds must not be negative")
        }
        if (snapshot.isEmpty) return false
        val payload = encodeSnapshot(snapshot)
        val envelope = pclinkObject(
            "v" to PclinkJson.Integer(CURRENT_VERSION.toLong()),
            "capturedAtMilliseconds" to PclinkJson.Integer(capturedAtMilliseconds),
            "backend" to PclinkJson.Text(backendScope(machineId)),
            "payload" to payload,
        )
        val bytes = PclinkJsonEncoder.encode(envelope)
        try {
            atomicWrite(fileFor(machineId), bytes)
        } catch (error: PclinkError) {
            throw error
        } catch (error: Exception) {
            throw PclinkError.Storage("cannot write the PC roster cache: ${error.message}")
        }
        return true
    }

    /**
     * Removes exactly one PC scope (unpair / a different machine). Other
     * machine files and every phone-scope cache are untouched. Returns whether
     * a file was removed.
     */
    fun remove(machineId: String): Boolean {
        requireMachineId(machineId)
        val file = fileFor(machineId)
        return try {
            val removed = Files.deleteIfExists(file)
            if (removed) {
                file.parent?.let { parent ->
                    if (Files.isDirectory(parent)) fsyncDirectory(parent)
                }
            }
            removed
        } catch (error: Exception) {
            throw PclinkError.Storage("cannot remove the PC roster cache: ${error.message}")
        }
    }

    internal fun fileFor(machineId: String): Path = directory.resolve("$machineId.json")

    private fun decodeEnvelope(root: PclinkJson, machineId: String): PclinkRosterCacheEntry {
        // Report a future format before validating this format's members: an
        // unknown `v` is ignored, never guessed (§P18 / rollback row).
        val version = root["v"]?.longValue ?: return PclinkRosterCacheEntry.Corrupt
        if (version != CURRENT_VERSION.toLong()) {
            return PclinkRosterCacheEntry.UnsupportedVersion(version)
        }
        val members = root.closedObject(
            required = setOf("v", "capturedAtMilliseconds", "backend", "payload"),
        )
        if (members["backend"]?.stringValue != backendScope(machineId)) {
            return PclinkRosterCacheEntry.Corrupt
        }
        val capturedAt = numberToLong(members["capturedAtMilliseconds"])
            ?: return PclinkRosterCacheEntry.Corrupt
        if (capturedAt < 0) return PclinkRosterCacheEntry.Corrupt
        val payload = members["payload"] ?: return PclinkRosterCacheEntry.Corrupt
        val snapshot = try {
            decodeSnapshot(payload)
        } catch (_: PclinkError) {
            return PclinkRosterCacheEntry.Corrupt
        }
        return PclinkRosterCacheEntry.Stored(snapshot, capturedAt, version.toInt())
    }

    private fun encodeSnapshot(snapshot: PclinkRosterSnapshot): PclinkJson {
        for (session in snapshot.sessions) {
            if (session.id.isEmpty()) throw PclinkError.BadFrame("roster session id is empty")
            if (!session.updatedAtMilliseconds.isFinite() || session.updatedAtMilliseconds < 0) {
                throw PclinkError.BadFrame("roster session updatedAtMilliseconds is invalid")
            }
        }
        for (workspace in snapshot.workspaces) {
            if (workspace.id.isEmpty()) throw PclinkError.BadFrame("roster workspace id is empty")
            for (sessionId in workspace.sessionIds) {
                if (sessionId.isEmpty()) throw PclinkError.BadFrame("roster workspace session id is empty")
            }
        }
        return pclinkObject(
            "sessions" to PclinkJson.Array(snapshot.sessions.map(::encodeSession)),
            "workspaces" to PclinkJson.Array(snapshot.workspaces.map(::encodeWorkspace)),
            "workspaceOrder" to PclinkJson.Array(snapshot.workspaceOrder.map { PclinkJson.Text(it) }),
            "pinnedSessionIDs" to PclinkJson.Array(snapshot.pinnedSessionIds.map { PclinkJson.Text(it) }),
            "archivedIDs" to PclinkJson.Array(snapshot.archivedIds.map { PclinkJson.Text(it) }),
        )
    }

    private fun encodeSession(session: PclinkRosterSession): PclinkJson {
        val members = linkedMapOf<String, PclinkJson>(
            "id" to PclinkJson.Text(session.id),
            "title" to PclinkJson.Text(session.title),
            "updatedAtMilliseconds" to decimalOrInteger(session.updatedAtMilliseconds),
            "running" to PclinkJson.Bool(session.running),
            "blank" to PclinkJson.Bool(session.blank),
        )
        session.cwd?.let { members["cwd"] = PclinkJson.Text(it) }
        session.parentSessionId?.let { members["parentSessionID"] = PclinkJson.Text(it) }
        session.searchSnippet?.let { members["searchSnippet"] = PclinkJson.Text(it) }
        return PclinkJson.Object(members)
    }

    private fun encodeWorkspace(workspace: PclinkRosterWorkspace): PclinkJson = pclinkObject(
        "id" to PclinkJson.Text(workspace.id),
        "title" to PclinkJson.Text(workspace.title),
        "path" to PclinkJson.Text(workspace.path),
        "sessionIDs" to PclinkJson.Array(workspace.sessionIds.map { PclinkJson.Text(it) }),
    )

    private fun decodeSnapshot(value: PclinkJson): PclinkRosterSnapshot {
        val members = value.closedObject(
            required = setOf(
                "sessions", "workspaces", "workspaceOrder", "pinnedSessionIDs", "archivedIDs",
            ),
        )
        val sessions = members.getValue("sessions").arrayValue
            ?: throw PclinkError.BadFrame("roster sessions is not an array")
        val workspaces = members.getValue("workspaces").arrayValue
            ?: throw PclinkError.BadFrame("roster workspaces is not an array")
        return PclinkRosterSnapshot(
            sessions = sessions.map(::decodeSession),
            workspaces = workspaces.map(::decodeWorkspace),
            workspaceOrder = stringArray(members.getValue("workspaceOrder"), "workspaceOrder"),
            pinnedSessionIds = stringArray(members.getValue("pinnedSessionIDs"), "pinnedSessionIDs"),
            archivedIds = stringArray(members.getValue("archivedIDs"), "archivedIDs"),
        )
    }

    private fun decodeSession(value: PclinkJson): PclinkRosterSession {
        val members = value.closedObject(
            required = setOf("id", "title", "updatedAtMilliseconds", "running", "blank"),
            optional = setOf("cwd", "parentSessionID", "searchSnippet"),
        )
        val id = string(members["id"], "session.id")
        if (id.isEmpty()) throw PclinkError.BadFrame("roster session id is empty")
        val updatedAt = numberToDouble(members["updatedAtMilliseconds"])
            ?: throw PclinkError.BadFrame("session.updatedAtMilliseconds")
        if (!updatedAt.isFinite() || updatedAt < 0) {
            throw PclinkError.BadFrame("session.updatedAtMilliseconds")
        }
        return PclinkRosterSession(
            id = id,
            title = string(members["title"], "session.title"),
            updatedAtMilliseconds = updatedAt,
            running = members["running"]?.boolValue
                ?: throw PclinkError.BadFrame("session.running"),
            blank = members["blank"]?.boolValue
                ?: throw PclinkError.BadFrame("session.blank"),
            cwd = optionalString(members["cwd"], "session.cwd"),
            parentSessionId = optionalString(members["parentSessionID"], "session.parentSessionID"),
            searchSnippet = optionalString(members["searchSnippet"], "session.searchSnippet"),
        )
    }

    private fun decodeWorkspace(value: PclinkJson): PclinkRosterWorkspace {
        val members = value.closedObject(required = setOf("id", "title", "path", "sessionIDs"))
        val id = string(members["id"], "workspace.id")
        if (id.isEmpty()) throw PclinkError.BadFrame("roster workspace id is empty")
        return PclinkRosterWorkspace(
            id = id,
            title = string(members["title"], "workspace.title"),
            path = string(members["path"], "workspace.path"),
            sessionIds = stringArray(members.getValue("sessionIDs"), "workspace.sessionIDs"),
        )
    }

    private fun string(value: PclinkJson?, field: String): String =
        value?.stringValue ?: throw PclinkError.BadFrame("$field must be a string")

    private fun optionalString(value: PclinkJson?, field: String): String? = when {
        value == null || value is PclinkJson.Null -> null
        value is PclinkJson.Text -> value.value
        else -> throw PclinkError.BadFrame("$field must be a string")
    }

    private fun stringArray(value: PclinkJson, field: String): List<String> {
        val values = value.arrayValue ?: throw PclinkError.BadFrame("$field must be an array")
        return values.mapIndexed { index, item ->
            item.stringValue ?: throw PclinkError.BadFrame("$field[$index] must be a string")
        }
    }

    private fun numberToDouble(value: PclinkJson?): Double? = when (value) {
        is PclinkJson.Integer -> value.value.toDouble()
        is PclinkJson.Decimal -> value.value
        else -> null
    }

    private fun numberToLong(value: PclinkJson?): Long? = when (value) {
        is PclinkJson.Integer -> value.value
        is PclinkJson.Decimal -> {
            val double = value.value
            if (!double.isFinite()) null else double.toLong()
        }
        else -> null
    }

    private fun decimalOrInteger(value: Double): PclinkJson {
        if (!value.isFinite()) throw PclinkError.BadFrame("non-finite roster timestamp")
        val asLong = value.toLong()
        return if (asLong.toDouble() == value) PclinkJson.Integer(asLong) else PclinkJson.Decimal(value)
    }

    private fun atomicWrite(target: Path, data: ByteArray) {
        val parent = target.toAbsolutePath().parent
            ?: throw PclinkError.Storage("roster cache file has no parent")
        Files.createDirectories(parent)
        val temporary = Files.createTempFile(parent, ".${target.fileName}.tmp.", "")
        var moved = false
        try {
            FileChannel.open(
                temporary,
                StandardOpenOption.WRITE,
                StandardOpenOption.TRUNCATE_EXISTING,
            ).use { channel ->
                val buffer = ByteBuffer.wrap(data)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            ownerOnly(temporary)
            try {
                Files.move(
                    temporary,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                // The Android app sandbox always supports a same-directory
                // rename. A filesystem without ATOMIC_MOVE cannot honour the
                // all-or-nothing guarantee, so fail instead of pretending.
                throw PclinkError.Storage("the roster cache directory does not support atomic replace")
            }
            moved = true
            ownerOnly(target)
            fsyncDirectory(parent)
        } finally {
            if (!moved) Files.deleteIfExists(temporary)
        }
    }

    private fun ownerOnly(path: Path) {
        try {
            Files.setPosixFilePermissions(
                path,
                PosixFilePermissions.asFileAttribute(
                    setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                ).value(),
            )
        } catch (_: UnsupportedOperationException) {
            // Non-POSIX filesystem: the app UID sandbox remains the boundary.
        } catch (_: Exception) {
            // Keep the write successful; do not claim POSIX 0600 everywhere.
        }
    }

    private fun fsyncDirectory(directory: Path) {
        try {
            FileChannel.open(directory, StandardOpenOption.READ).use { it.force(true) }
        } catch (_: IOException) {
            // Not available on every filesystem; the rename is still atomic.
        } catch (_: Exception) {
            // Same: durability is best-effort, atomicity is not.
        }
    }

    private fun backendScope(machineId: String): String = "pc:$machineId"

    private fun requireMachineId(machineId: String) {
        if (!PclinkValidation.isMachineId(machineId)) {
            throw PclinkError.BadFrame("machineId is not a PCLink machineId")
        }
    }

    companion object {
        const val CURRENT_VERSION: Int = 1
    }
}
