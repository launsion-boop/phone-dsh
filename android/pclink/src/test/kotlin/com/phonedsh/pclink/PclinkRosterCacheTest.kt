// SPDX-License-Identifier: MIT
// C4/P18 roster-cache tests (PC-20261110-pclink-pc-roster-snapshot,
// PC-20261110-pclink-workspace-cache): envelope and bare reads, missing /
// corrupt / unknown-version handling, an empty write never clearing the old
// list, atomic no-temp-file writes, closed projection shapes and unpair scope
// isolation. The file lives on the host filesystem; no Android import.
package com.phonedsh.pclink

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PclinkRosterCacheTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var directory: Path
    private lateinit var cache: PclinkRosterCache
    private val machineId: String = C2TestSupport.pcIdentity().machineId
    private val otherMachineId: String = PclinkIdentity.generate().machineId

    private fun newCache(): PclinkRosterCache {
        directory = temporary.newFolder("roster-${System.nanoTime()}").toPath()
        cache = PclinkRosterCache(directory)
        return cache
    }

    private fun sampleSnapshot(): PclinkRosterSnapshot = PclinkRosterSnapshot(
        sessions = listOf(
            PclinkRosterSession(
                id = "session-1",
                title = "Fix the login flow",
                updatedAtMilliseconds = 1_762_000_000_123.0,
                running = true,
                blank = false,
                cwd = "/Users/me/repo",
                parentSessionId = "session-0",
                searchSnippet = "login",
            ),
            PclinkRosterSession(
                id = "session-2",
                title = "Archived",
                updatedAtMilliseconds = 1_762_000_000_000.0,
                running = false,
                blank = true,
            ),
        ),
        workspaces = listOf(
            PclinkRosterWorkspace(
                id = "workspace-1",
                title = "phoneDSH",
                path = "/Users/me/repo",
                sessionIds = listOf("session-1", "session-2"),
            ),
        ),
        workspaceOrder = listOf("workspace-1"),
        pinnedSessionIds = listOf("session-1"),
        archivedIds = listOf("session-2"),
    )

    private fun raw(value: PclinkJson): ByteArray = PclinkJsonEncoder.encode(value)

    private fun envelope(
        payload: PclinkJson,
        version: Long = 1,
        backend: String = "pc:$machineId",
        capturedAt: Long = 1_762_000_000_000,
    ): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(version),
        "capturedAtMilliseconds" to PclinkJson.Integer(capturedAt),
        "backend" to PclinkJson.Text(backend),
        "payload" to payload,
    )

    private fun payload(snapshot: PclinkRosterSnapshot): PclinkJson {
        // Round-trip through the writer to obtain the exact payload shape.
        val probe = PclinkRosterCache(temporary.newFolder("probe-${System.nanoTime()}").toPath())
        assertTrue(probe.write(machineId, snapshot, 1))
        val root = PclinkJsonParser.parseDocumentObject(Files.readAllBytes(probe.fileFor(machineId)))
        return root["payload"] ?: throw AssertionError("missing payload")
    }

    @Test
    fun roundTripWritesOneEnvelopeFileWithNoTemporaryLeftover() {
        newCache()
        val snapshot = sampleSnapshot()
        assertTrue(cache.write(machineId, snapshot, 1_762_000_000_000))
        val file = cache.fileFor(machineId)
        assertTrue(Files.isRegularFile(file))
        Files.list(directory).use { entries ->
            assertEquals("only the final file remains", 1L, entries.count())
        }
        val root = PclinkJsonParser.parseDocumentObject(Files.readAllBytes(file))
        assertEquals(1L, root["v"]?.longValue)
        assertEquals("pc:$machineId", root["backend"]?.stringValue)
        assertEquals(1_762_000_000_000L, root["capturedAtMilliseconds"]?.longValue)

        val entry = cache.read(machineId)
        assertTrue(entry is PclinkRosterCacheEntry.Stored)
        entry as PclinkRosterCacheEntry.Stored
        assertEquals(1, entry.envelopeVersion)
        assertEquals(1_762_000_000_000L, entry.capturedAtMilliseconds)
        assertEquals(snapshot, entry.snapshot)
    }

    @Test
    fun missingFileIsMissingNotCorrupt() {
        newCache()
        assertEquals(PclinkRosterCacheEntry.Missing, cache.read(machineId))
    }

    @Test
    fun corruptValueIsReportedAndNeverDeleted() {
        newCache()
        val file = cache.fileFor(machineId)
        Files.createDirectories(directory)
        Files.write(file, "{not json".toByteArray())
        val before = Files.readAllBytes(file)
        assertEquals(PclinkRosterCacheEntry.Corrupt, cache.read(machineId))
        assertArrayEquals("a corrupt cache is ignored, not erased", before, Files.readAllBytes(file))

        // A later successful refresh replaces it atomically.
        assertTrue(cache.write(machineId, sampleSnapshot(), 5))
        assertTrue(cache.read(machineId) is PclinkRosterCacheEntry.Stored)
    }

    @Test
    fun unknownVersionIsIgnoredWithoutGuessing() {
        newCache()
        Files.createDirectories(directory)
        Files.write(cache.fileFor(machineId), raw(envelope(payload(sampleSnapshot()), version = 2)))
        val entry = cache.read(machineId)
        assertTrue(entry is PclinkRosterCacheEntry.UnsupportedVersion)
        assertEquals(2L, (entry as PclinkRosterCacheEntry.UnsupportedVersion).version)
        assertTrue(Files.isRegularFile(cache.fileFor(machineId)))
    }

    @Test
    fun unknownVersionWithAFutureShapeIsStillOnlyUnsupported() {
        newCache()
        Files.createDirectories(directory)
        Files.write(
            cache.fileFor(machineId),
            raw(pclinkObject("v" to PclinkJson.Integer(2), "somethingNew" to PclinkJson.Bool(true))),
        )
        val entry = cache.read(machineId)
        assertTrue(entry is PclinkRosterCacheEntry.UnsupportedVersion)
        assertEquals(2L, (entry as PclinkRosterCacheEntry.UnsupportedVersion).version)
    }

    @Test
    fun barePayloadIsStillReadableForRollback() {
        newCache()
        Files.createDirectories(directory)
        val snapshot = sampleSnapshot()
        Files.write(cache.fileFor(machineId), raw(payload(snapshot)))
        val entry = cache.read(machineId)
        assertTrue(entry is PclinkRosterCacheEntry.Stored)
        entry as PclinkRosterCacheEntry.Stored
        assertEquals(snapshot, entry.snapshot)
        assertEquals(null, entry.envelopeVersion)
        assertEquals(null, entry.capturedAtMilliseconds)
    }

    @Test
    fun wrongBackendScopeIsCorrupt() {
        newCache()
        Files.createDirectories(directory)
        Files.write(
            cache.fileFor(machineId),
            raw(envelope(payload(sampleSnapshot()), backend = "pc:$otherMachineId")),
        )
        assertEquals(PclinkRosterCacheEntry.Corrupt, cache.read(machineId))
    }

    @Test
    fun unknownMembersAreCorruptSoNoPendingApprovalCanEnterTheCache() {
        newCache()
        Files.createDirectories(directory)
        val base = payload(sampleSnapshot())
        val withPending = pclinkObject(
            "sessions" to base["sessions"]!!,
            "workspaces" to base["workspaces"]!!,
            "workspaceOrder" to base["workspaceOrder"]!!,
            "pinnedSessionIDs" to base["pinnedSessionIDs"]!!,
            "archivedIDs" to base["archivedIDs"]!!,
            "pendingApprovals" to PclinkJson.Array(emptyList()),
        )
        Files.write(cache.fileFor(machineId), raw(envelope(withPending)))
        assertEquals(PclinkRosterCacheEntry.Corrupt, cache.read(machineId))

        // The same closed-object rule applies inside one row.
        val sessions = base["sessions"]!!.arrayValue!!
        val first = sessions[0].objectValue!!.toMutableMap()
        first["streamText"] = PclinkJson.Text("leaked content")
        val withExtraRow = pclinkObject(
            "sessions" to PclinkJson.Array(listOf(PclinkJson.Object(first)) + sessions.drop(1)),
            "workspaces" to base["workspaces"]!!,
            "workspaceOrder" to base["workspaceOrder"]!!,
            "pinnedSessionIDs" to base["pinnedSessionIDs"]!!,
            "archivedIDs" to base["archivedIDs"]!!,
        )
        Files.write(cache.fileFor(machineId), raw(envelope(withExtraRow)))
        assertEquals(PclinkRosterCacheEntry.Corrupt, cache.read(machineId))
    }

    @Test
    fun emptySnapshotIsNotPersistedAndNeverClearsTheOldList() {
        newCache()
        assertFalse(cache.write(machineId, PclinkRosterSnapshot(), 10))
        assertFalse(Files.exists(cache.fileFor(machineId)))

        assertTrue(cache.write(machineId, sampleSnapshot(), 11))
        val before = Files.readAllBytes(cache.fileFor(machineId))
        assertFalse(cache.write(machineId, PclinkRosterSnapshot(), 12))
        assertArrayEquals("the last successful list stays on disk", before, Files.readAllBytes(cache.fileFor(machineId)))
        assertTrue(cache.read(machineId) is PclinkRosterCacheEntry.Stored)
    }

    @Test
    fun removeDeletesOnlyThatPcScope() {
        newCache()
        assertTrue(cache.write(machineId, sampleSnapshot(), 20))
        assertTrue(cache.write(otherMachineId, sampleSnapshot(), 21))
        assertTrue(cache.remove(machineId))
        assertEquals(PclinkRosterCacheEntry.Missing, cache.read(machineId))
        assertTrue(cache.read(otherMachineId) is PclinkRosterCacheEntry.Stored)
        assertFalse(cache.remove(machineId))
        assertTrue(cache.remove(otherMachineId))
    }

    @Test
    fun invalidMachineIdCannotEscapeTheDirectory() {
        newCache()
        for (value in listOf("", "../escape", "ABCDE", "a".repeat(26) + "/x")) {
            val error = try {
                cache.read(value)
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("bad_frame", error?.code)
        }
        assertFalse(Files.exists(directory.resolve("escape.json")))
    }

    @Test
    fun fractionalTimestampsSurviveTheEnvelope() {
        newCache()
        val snapshot = PclinkRosterSnapshot(
            sessions = listOf(
                PclinkRosterSession(
                    id = "fractional",
                    title = "Fractional",
                    updatedAtMilliseconds = 1_762_000_000_123.5,
                    running = false,
                    blank = false,
                ),
            ),
            workspaces = listOf(
                PclinkRosterWorkspace("w", "W", "/", listOf("fractional")),
            ),
        )
        assertTrue(cache.write(machineId, snapshot, 30))
        val entry = cache.read(machineId)
        entry as PclinkRosterCacheEntry.Stored
        assertEquals(1_762_000_000_123.5, entry.snapshot.sessions[0].updatedAtMilliseconds, 0.0)
        assertNotEquals(0, Files.size(cache.fileFor(machineId)))
    }

    @Test
    fun fileIsOwnerOnlyWhenPosixIsSupported() {
        newCache()
        assertTrue(cache.write(machineId, sampleSnapshot(), 40))
        val supported = try {
            java.nio.file.FileSystems.getDefault().supportedFileAttributeViews().contains("posix")
        } catch (_: Exception) {
            false
        }
        if (!supported) return
        val permissions = Files.getPosixFilePermissions(cache.fileFor(machineId))
        assertEquals(
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            permissions,
        )
    }

    @Test
    fun invalidWriteInputIsRejectedBeforeTouchingTheFile() {
        newCache()
        val negative = try {
            cache.write(machineId, sampleSnapshot(), -1)
            null
        } catch (thrown: PclinkError) {
            thrown
        }
        assertEquals("bad_frame", negative?.code)
        assertFalse(Files.exists(cache.fileFor(machineId)))

        val emptyId = try {
            cache.write(
                machineId,
                PclinkRosterSnapshot(
                    sessions = listOf(
                        PclinkRosterSession("", "x", 1.0, false, false),
                    ),
                ),
                1,
            )
            null
        } catch (thrown: PclinkError) {
            thrown
        }
        assertEquals("bad_frame", emptyId?.code)
        assertFalse(Files.exists(cache.fileFor(machineId)))
    }
}
