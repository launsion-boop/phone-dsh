// phone-dsh — :app unit tests: SSH profiles and Keystore-held credentials.
// SPDX-License-Identifier: MIT
//
// Runs the real store over a temp directory and the in-memory SecureStore of
// `:platform` testing. No network: host-key inspection is injected.

package com.phonedsh.probe

import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.ssh.SshFailure
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.SSHConnectionDraft
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SshSettingsStoreTest {
    private val hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    private lateinit var dir: File
    private lateinit var platform: FakePlatform

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("pdsh-ssh-store").toFile()
        platform = FakePlatform()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
        platform.close()
    }

    private fun store() = SshSettingsStore(File(dir, "ssh"), platform, inspect = { _, _ -> hostKey })

    private fun draft(
        id: String? = null,
        alias: String = "box",
        host: String = "203.0.113.7",
        port: Int = 22,
        key: String = hostKey,
        password: String = "s3cret-password",
        usePrivateKey: Boolean = false,
        privateKey: String = "",
    ) = SSHConnectionDraft(id, alias, host, port, "ops", usePrivateKey, key, password, privateKey, "")

    @Test
    fun aProfileNeedsAConfirmedHostKeyAndValidFields() {
        val store = store()
        for (bad in listOf(
            draft(key = ""),
            draft(alias = "-bad"),
            draft(alias = "has space"),
            draft(host = "two words"),
            draft(port = 0),
            draft(password = ""),
            draft(key = "ssh-ed25519 not-base64!"),
        )) {
            assertThrows(SshFailure::class.java) { store.save(bad) }
        }
        assertTrue(store.facts.value.connections.isEmpty())
        assertFalse(File(dir, "ssh/${SshSettingsStore.FILE_NAME}").exists())
    }

    @Test
    fun secretsLiveOnlyInTheSecureStoreAndResolveByAlias() = runBlocking {
        val store = store()
        store.save(draft())
        val profileFile = File(dir, "ssh/${SshSettingsStore.FILE_NAME}").readText()
        assertFalse("the profile file never holds a secret", profileFile.contains("s3cret-password"))
        val saved = JSONArray(profileFile).getJSONObject(0)
        assertEquals(setOf("id", "alias", "host", "port", "username", "usePrivateKey", "trustedHostKey"), saved.keySet())
        assertEquals(setOf(SshSettingsStore.SECRET_PREFIX + saved.getString("id")), platform.storedKeys())
        assertFalse(store.facts.value.toString().contains("s3cret"))

        val connection = store.resolve("box")
        assertEquals("s3cret-password", connection.password)
        assertEquals(hostKey, connection.trustedHostKey)
        assertEquals("SshConnection(redacted)", connection.toString())
        assertEquals(connection.host, store.resolve("ops@203.0.113.7").host)
        assertEquals("box\tops@203.0.113.7:22", store.list())
        assertThrows(SshFailure::class.java) { store.resolve("unknown") }

        // A second store over the same files reads the same profile (persistence).
        assertEquals("s3cret-password", store().resolve("box").password)
    }

    @Test
    fun editingKeepsTheStoredSecretAndMovingTheHostDropsTrust() {
        val store = store()
        store.save(draft())
        val id = store.facts.value.connections.single().id
        store.save(draft(id = id, alias = "box2", password = ""))
        assertEquals("s3cret-password", store.resolve("box2").password)

        // Same key for a different host/port is refused: the editor must re-inspect.
        assertThrows(SshFailure::class.java) { store.save(draft(id = id, alias = "box2", host = "198.51.100.1", password = "")) }
        assertThrows(SshFailure::class.java) { store.save(draft(id = id, alias = "box2", port = 2222, password = "")) }

        // Switching to key auth with no key typed has nothing to keep.
        assertThrows(SshFailure::class.java) { store.save(draft(id = id, alias = "box2", usePrivateKey = true, password = "")) }
        assertThrows(SshFailure::class.java) { store.save(draft(alias = "box2")) } // duplicate alias
    }

    @Test
    fun deleteRemovesTheProfileAndItsCredential() {
        val store = store()
        store.save(draft())
        val id = store.facts.value.connections.single().id
        store.remove(id)
        assertTrue(store.facts.value.connections.isEmpty())
        assertTrue(platform.storedKeys().isEmpty())
        assertEquals("No saved SSH connections. Add a connection in Settings → SSH.", store.list())
    }

    @Test
    fun anUnreadableCredentialIsReportedNotTreatedAsEmpty() {
        val store = store()
        store.save(draft())
        val id = store.facts.value.connections.single().id
        platform.markUnreadable(SshSettingsStore.SECRET_PREFIX + id)
        val failure = assertThrows(SshFailure::class.java) { store.resolve("box") }
        assertTrue(failure.message!!.contains("cannot be read"))
    }

    @Test
    fun aCorruptProfileFileIsNotOverwritten() {
        File(dir, "ssh").mkdirs()
        val file = File(dir, "ssh/${SshSettingsStore.FILE_NAME}")
        file.writeText("{not json")
        val store = store()
        assertFalse(store.facts.value.available)
        assertThrows(SshFailure::class.java) { store.save(draft()) }
        assertEquals("{not json", file.readText())
    }

    @Test
    fun inspectionPublishesTheKeyAndFingerprintForTheRequest() {
        val store = store()
        store.handle(PdshHostAction.SshInspectHostKey("req-1", "203.0.113.7", 22))
        val deadline = System.currentTimeMillis() + 5_000
        while (store.facts.value.inspection == null && System.currentTimeMillis() < deadline) Thread.sleep(10)
        val inspection = store.facts.value.inspection!!
        assertEquals("req-1", inspection.requestId)
        assertEquals(hostKey, inspection.key)
        assertTrue(inspection.fingerprint.startsWith("SHA256:"))
        assertTrue("inspection alone trusts nothing", store.facts.value.connections.isEmpty())
    }
}
