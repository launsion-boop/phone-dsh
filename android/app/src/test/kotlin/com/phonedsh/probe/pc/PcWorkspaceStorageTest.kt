// SPDX-License-Identifier: MIT
// P18 storage: drawer backend, last workspace and the C4 roster cache under the
// per-PC scope. A second store instance over the same file proves a process
// kill does not lose the selection (design §5.3).
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkIdentity
import com.phonedsh.pclink.PclinkRosterCacheEntry
import com.phonedsh.pclink.PclinkRosterSession
import com.phonedsh.pclink.PclinkRosterSnapshot
import com.phonedsh.pclink.PclinkRosterWorkspace
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcWorkspaceStorageTest {
    private val firstMachine = PclinkIdentity.generate().machineId
    private val secondMachine = PclinkIdentity.generate().machineId

    private fun directory(): Path = Files.createTempDirectory("pc-storage")

    private fun storage(
        file: MapPreferenceFile,
        directory: Path = directory(),
    ): PcWorkspaceStorage = PcWorkspaceStorage(file, directory.resolve(PcWorkspaceStorage.ROSTER_DIRECTORY))

    private fun snapshot(title: String = "build the app"): PclinkRosterSnapshot = PclinkRosterSnapshot(
        sessions = listOf(
            PclinkRosterSession(
                id = "session-1",
                title = title,
                updatedAtMilliseconds = 1_700_000_000_000.0,
                running = false,
                blank = false,
                cwd = "/work/phone-dsh",
            ),
        ),
        workspaces = listOf(
            PclinkRosterWorkspace(
                id = "workspace-1",
                title = "phone-dsh",
                path = "/work/phone-dsh",
                sessionIds = listOf("session-1"),
            ),
        ),
        workspaceOrder = listOf("workspace-1"),
        pinnedSessionIds = listOf("session-1"),
        archivedIds = emptyList(),
    )

    @Test
    fun `a fresh file resolves to the phone segment without writing`() {
        val file = MapPreferenceFile()
        val store = storage(file)
        assertEquals(PcBackend.PHONE, store.readBackend())
        assertTrue("reading a default must not materialize the key", file.values.isEmpty())
    }

    @Test
    fun `backend selection survives a new store instance and an unknown value falls back`() {
        val file = MapPreferenceFile()
        val directory = directory()
        val first = storage(file, directory)
        assertTrue(first.writeBackend(PcBackend.PC))

        val second = storage(file, directory)
        assertEquals(PcBackend.PC, second.readBackend())

        file.values[PcWorkspaceStorage.DRAWER_BACKEND_KEY] = "tablet"
        assertEquals("an unknown segment is never guessed", PcBackend.PHONE, second.readBackend())
    }

    @Test
    fun `last workspace round trips per machine and is removed with its scope`() {
        val file = MapPreferenceFile()
        val directory = directory()
        val store = storage(file, directory)
        assertNull(store.readLastWorkspace(firstMachine))
        assertTrue(store.writeLastWorkspace(firstMachine, "workspace-1"))
        assertTrue(store.writeLastWorkspace(secondMachine, "workspace-2"))
        assertEquals("workspace-1", store.readLastWorkspace(firstMachine))
        assertEquals("workspace-2", store.readLastWorkspace(secondMachine))
        assertEquals(
            "phone-dsh.pc.last-workspace.$firstMachine",
            PcWorkspaceStorage.LAST_WORKSPACE_PREFIX + firstMachine,
        )

        store.removePcScope(firstMachine)
        assertNull(store.readLastWorkspace(firstMachine))
        assertEquals("workspace-2", store.readLastWorkspace(secondMachine))
    }

    @Test
    fun `roster envelope round trips and an empty snapshot is not written`() {
        val directory = directory()
        val store = storage(MapPreferenceFile(), directory)
        val value = snapshot()
        assertTrue(store.writeRoster(firstMachine, value, 1_700_000_000_123L))

        val entry = store.readRoster(firstMachine)
        assertTrue(entry is PclinkRosterCacheEntry.Stored)
        val stored = entry as PclinkRosterCacheEntry.Stored
        assertEquals(1, stored.snapshot.sessions.size)
        assertEquals("build the app", stored.snapshot.sessions.single().title)
        assertEquals("workspace-1", stored.snapshot.workspaces.single().id)
        assertEquals(1_700_000_000_123L, stored.capturedAtMilliseconds)
        assertEquals(1, stored.envelopeVersion)
        assertEquals(firstMachine, directory.resolve(PcWorkspaceStorage.ROSTER_DIRECTORY).resolve("$firstMachine.json").fileName.toString().substringBefore('.'))

        assertFalse(store.writeRoster(firstMachine, PclinkRosterSnapshot(), 1_700_000_000_124L))
        assertEquals(
            "the last successful list is still there",
            1_700_000_000_123L,
            (store.readRoster(firstMachine) as PclinkRosterCacheEntry.Stored).capturedAtMilliseconds,
        )
    }

    @Test
    fun `unpair removes only that PC roster and last-workspace key`() {
        val file = MapPreferenceFile()
        val directory = directory()
        val store = storage(file, directory)
        assertTrue(store.writeBackend(PcBackend.PC))
        assertTrue(store.writeLastWorkspace(firstMachine, "workspace-1"))
        assertTrue(store.writeLastWorkspace(secondMachine, "workspace-2"))
        assertTrue(store.writeRoster(firstMachine, snapshot(), 1))
        assertTrue(store.writeRoster(secondMachine, snapshot("other"), 2))

        store.removePcScope(firstMachine)

        assertTrue(store.readRoster(firstMachine) is PclinkRosterCacheEntry.Missing)
        assertTrue(store.readRoster(secondMachine) is PclinkRosterCacheEntry.Stored)
        assertEquals("workspace-2", store.readLastWorkspace(secondMachine))
        assertEquals("unpair does not silently switch the drawer back", PcBackend.PC, store.readBackend())
    }

    @Test
    fun `readWorkspace returns the two per-PC facts together`() {
        val store = storage(MapPreferenceFile())
        assertTrue(store.writeLastWorkspace(firstMachine, "workspace-1"))
        assertTrue(store.writeRoster(firstMachine, snapshot(), 7))
        val stored = store.readWorkspace(firstMachine)
        assertEquals(firstMachine, stored.machineId)
        assertEquals("workspace-1", stored.lastWorkspaceId)
        assertTrue(stored.roster is PclinkRosterCacheEntry.Stored)
    }
}
