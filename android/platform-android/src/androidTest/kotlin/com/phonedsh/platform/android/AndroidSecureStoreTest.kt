// Instrumented evidence for the SecureStore three-state and the honest level.
// SPDX-License-Identifier: MIT
//
// Only a device has an AndroidKeyStore, so these are AndroidJUnit tests. The
// "invalidated" state is produced the way a lock-screen credential change
// produces it: the ciphertext stays where it is and its Keystore entry no longer
// exists. The assertion then pins the fail-closed answer and the fact that the
// reason carries no stack or key material.

package com.phonedsh.platform.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import java.io.File
import java.security.KeyStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidSecureStoreTest {

    private lateinit var context: Context
    private lateinit var store: SecureStore

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        store = AndroidSecureStore(context)
    }

    @Test
    fun aStoredSecretComesBackAsFound() = runBlocking {
        val value = byteArrayOf(0x00, 0x01, 0x02, 0x7F, 0x80.toByte(), 0xFF.toByte())
        store.put("reclaim-token", value)

        val result = store.get("reclaim-token")

        assertTrue("expected Found, was $result", result is SecureLookup.Found)
        assertArrayEquals(value, (result as SecureLookup.Found).value)
    }

    @Test
    fun aDeletedSecretIsAbsentAndDeleteIsIdempotent() = runBlocking {
        store.put("gone", byteArrayOf(1))
        store.delete("gone")

        assertSame(SecureLookup.Absent, store.get("gone"))
        store.delete("gone")
        assertSame(SecureLookup.Absent, store.get("gone"))
    }

    @Test
    fun aKeyWhoseKeystoreEntryVanishedIsUnreadableAndLeaksNoFailureText() = runBlocking {
        val key = "reclaim-token-${System.nanoTime()}"
        store.put(key, byteArrayOf(9, 8, 7))
        assertTrue("precondition: the secret is readable", store.get(key) is SecureLookup.Found)

        // The lock-screen credential changed / the key was evicted: the bytes
        // are still on disk, the key is not.
        deleteEveryKeystoreEntry()

        val result = store.get(key)
        assertTrue("expected Unreadable, was $result", result is SecureLookup.Unreadable)
        val reason = (result as SecureLookup.Unreadable).reason
        assertEquals("the reason is a short display-safe label", "key-invalidated", reason)
        assertFalse("no control characters", reason.any { it.isISOControl() })
        assertFalse("no exception text", reason.contains("Exception"))
        assertFalse("no stack trace", reason.contains(" at "))
        assertFalse("no key material", reason.contains(key))
        assertTrue("a label, not a log line", reason.length <= 32)
    }

    @Test
    fun theLevelIsOneOfTheThreeAndIsReported() {
        val level = store.level
        // Printed so the receipt can name what the emulator actually provided.
        println("AndroidSecureStore.level = $level")

        assertTrue("unexpected security level $level", level in SecurityLevel.entries)
    }

    @Test
    fun theCiphertextLivesInNoBackupFilesDirAndIsNotPlaintext() = runBlocking {
        val secret = "plaintext-credential-${System.nanoTime()}"
        store.put("no-backup-${System.nanoTime()}", secret.toByteArray())

        val storeDir = File(context.noBackupFilesDir, "secure-store")
        val ciphertexts = storeDir.listFiles().orEmpty().filter { it.name.endsWith(".bin") }

        assertTrue("no ciphertext file under noBackupFilesDir", ciphertexts.isNotEmpty())
        assertFalse(
            "Auto Backup must not see the store (plan R11)",
            File(context.filesDir, "secure-store").exists(),
        )
        val leaked = ciphertexts.any { file ->
            file.readBytes().toString(Charsets.UTF_8).contains(secret)
        }
        assertFalse("the plaintext reached the ciphertext file", leaked)
    }

    private fun deleteEveryKeystoreEntry() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keyStore.aliases().toList().forEach { alias -> keyStore.deleteEntry(alias) }
    }
}
