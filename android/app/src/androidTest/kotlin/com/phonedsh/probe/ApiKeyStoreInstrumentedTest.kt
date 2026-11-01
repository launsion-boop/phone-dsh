// Instrumented evidence for the model-key store: a real AndroidKeyStore.
// SPDX-License-Identifier: MIT
//
// Only a device has an AndroidKeyStore, so the round-trip, the "ciphertext is not
// plaintext" claim, the no-backup location and the fail-closed "keystore entry is
// gone" state are AndroidJUnit tests. The mapping cases that do not need a device
// (Unreadable, blank, short, store failure) run against an in-memory `SecureStore`
// here as well, so the three states are pinned even on a device whose Keystore
// behaves differently.
//
// Every key-shaped literal is obviously fake; nothing on this path logs, and the
// last test reads this process's own logcat to check that.

package com.phonedsh.probe

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ui.page.ProviderKeyStatus
import java.io.File
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ApiKeyStoreInstrumentedTest {

    private lateinit var context: Context
    private lateinit var secureStore: AndroidSecureStore
    private lateinit var store: ApiKeyStore

    /** Obviously fake, and long enough for the page's eight-character mask floor. */
    private val fakeKey: String = "sk-test-NOT-A-REAL-KEY-0000"

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        secureStore = AndroidSecureStore(context)
        store = ApiKeyStore(secureStore)
        store.clear()
    }

    @After
    fun tearDown() {
        store.clear()
    }

    // ---- the real Keystore envelope --------------------------------------

    @Test
    fun aStoredKeyComesBackEqual() {
        store.save(fakeKey)

        val state = store.read()

        assertTrue("expected Valid, was $state", state is ApiKeyState.Valid)
        assertEquals(fakeKey, (state as ApiKeyState.Valid).value)
    }

    @Test
    fun theCiphertextFileDoesNotHoldTheKey() {
        store.save(fakeKey)

        val directory = File(context.noBackupFilesDir, SECURE_STORE_DIR)
        assertTrue("the envelope directory must exist", directory.isDirectory)
        val files = directory.listFiles().orEmpty()
        assertTrue("the ciphertext file must exist", files.isNotEmpty())
        val plain = fakeKey.toByteArray(Charsets.UTF_8)
        val prefix = fakeKey.substring(0, 8).toByteArray(Charsets.UTF_8)
        for (file in files) {
            val bytes = file.readBytes()
            assertFalse("no file may hold the key (${file.name})", contains(bytes, plain))
            assertFalse("no file may hold even the first eight characters (${file.name})", contains(bytes, prefix))
        }
    }

    @Test
    fun theEnvelopeLivesOutsideEveryBackupRoot() {
        store.save(fakeKey)

        val directory = File(context.noBackupFilesDir, SECURE_STORE_DIR).canonicalFile
        assertTrue(directory.isDirectory)
        assertTrue(
            "noBackupFilesDir is skipped by Auto Backup and device transfer",
            directory.path.startsWith(context.noBackupFilesDir.canonicalPath + File.separator),
        )
        assertFalse(
            "the key must never live under filesDir",
            directory.path.startsWith(context.filesDir.canonicalPath + File.separator),
        )
        val databases = context.getDatabasePath("unused").parentFile?.canonicalPath
        assertNotNull("the databases root must resolve", databases)
        assertFalse(
            "the key must never live in a SQLite database directory",
            directory.path.startsWith("$databases" + File.separator),
        )
    }

    @Test
    fun aKeyWhoseKeystoreEntryIsGoneIsInvalidNotAbsent() {
        store.save(fakeKey)
        assertTrue("the fresh save must be readable", store.read() is ApiKeyState.Valid)

        // The production way this happens: the Keystore entry is gone (app-data
        // restore, keystore reset, key eviction) while the ciphertext file stays.
        deleteSecureStoreKeys()

        val state = store.read()
        assertTrue("an unreadable stored key is INVALID, never ABSENT: $state", state is ApiKeyState.Invalid)
        assertEquals(ProviderKeyStatus.INVALID, store.fact().status)
        try {
            store.readKey()
            fail("the injection path must fail closed, not report 'no key'")
        } catch (expected: CredentialUnavailableException) {
            assertFalse(
                "the failure message must not carry key material",
                expected.message.orEmpty().contains(fakeKey),
            )
        }
    }

    @Test
    fun theFactCarriesOnlyTheLastFourCharacters() {
        store.save(fakeKey)

        val fact = store.fact()

        assertEquals(ProviderKeyStatus.CONFIGURED, fact.status)
        val suffix = fact.suffix
        assertNotNull("a configured key must carry a suffix", suffix)
        assertEquals("only four characters", 4, suffix!!.length)
        assertEquals(fakeKey.takeLast(4), suffix)
        assertFalse("the fact must not echo the key", fact.toString().contains(fakeKey))
        assertFalse("the fact must not echo the key prefix", fact.toString().contains(fakeKey.substring(0, 8)))
        assertFalse("four characters are not the key", suffix == fakeKey)
    }

    @Test
    fun anAbsentKeyIsNotConfiguredAndCarriesNoSuffix() {
        store.clear()

        val state = store.read()
        val fact = store.fact()

        assertTrue("expected Absent, was $state", state is ApiKeyState.Absent)
        assertEquals(ProviderKeyStatus.NOT_CONFIGURED, fact.status)
        assertNull(fact.suffix)
        assertNull("absent means no key to inject", store.readKey())
    }

    @Test
    fun theSecurityLevelIsReportedNotAssumed() {
        // StrongBox and TEE are optional hardware; the honest level is measured by
        // the envelope and reported, never assumed to be the strongest one.
        assertTrue(store.securityLevel in SecurityLevel.entries)
    }

    // ---- the three states over an in-memory envelope ---------------------

    @Test
    fun anUnreadableEnvelopeIsInvalid() {
        val fake = FakeSecureStore(SecureLookup.Unreadable("key-invalidated"))
        val inMemory = ApiKeyStore(fake)

        val state = inMemory.read()

        assertTrue("expected Invalid, was $state", state is ApiKeyState.Invalid)
        assertEquals("key-invalidated", (state as ApiKeyState.Invalid).reason)
        assertEquals(ProviderKeyStatus.INVALID, inMemory.fact().status)
    }

    @Test
    fun aBlankStoredValueIsInvalid() {
        val inMemory = ApiKeyStore(FakeSecureStore(SecureLookup.Found("   ".toByteArray(Charsets.UTF_8))))

        assertTrue(inMemory.read() is ApiKeyState.Invalid)
        assertEquals(ProviderKeyStatus.INVALID, inMemory.fact().status)
    }

    @Test
    fun aTooShortStoredValueIsInvalid() {
        val inMemory = ApiKeyStore(FakeSecureStore(SecureLookup.Found("sk-test".toByteArray(Charsets.UTF_8))))

        assertTrue("a seven-character value has no safe four-character suffix", inMemory.read() is ApiKeyState.Invalid)
    }

    @Test
    fun aStoredValueWithWhitespaceIsInvalid() {
        val inMemory = ApiKeyStore(
            FakeSecureStore(SecureLookup.Found("sk-test NOT A REAL KEY".toByteArray(Charsets.UTF_8))),
        )

        assertTrue("a header value cannot contain whitespace", inMemory.read() is ApiKeyState.Invalid)
    }

    @Test
    fun aFailedStoreReadIsInvalidNotAbsent() {
        val fake = FakeSecureStore(SecureLookup.Absent, getFailure = IllegalStateException("keystore unavailable"))
        val inMemory = ApiKeyStore(fake)

        val state = inMemory.read()

        assertTrue("a store failure is not 'no key': $state", state is ApiKeyState.Invalid)
        assertEquals("key-store-unavailable", (state as ApiKeyState.Invalid).reason)
    }

    @Test
    fun theValidStateNeverPrintsTheKey() {
        val text = ApiKeyState.Valid(fakeKey).toString()
        assertFalse(text.contains(fakeKey))
        assertTrue(text.contains("***"))
    }

    // ---- helpers ---------------------------------------------------------

    /** An in-memory envelope, so the state mapping runs without a device key. */
    private class FakeSecureStore(
        private val lookup: SecureLookup,
        private val getFailure: Exception? = null,
    ) : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE

        override suspend fun put(key: String, value: ByteArray) = Unit

        override suspend fun get(key: String): SecureLookup {
            getFailure?.let { throw it }
            return lookup
        }

        override suspend fun delete(key: String) = Unit
    }

    /**
     * Deletes every Keystore alias this app owns, the way an app-data restore or a
     * Keystore reset does: the ciphertext stays, the wrapping key does not.
     */
    private fun deleteSecureStoreKeys() {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        for (alias in keyStore.aliases().toList()) {
            if (alias.startsWith(KEYSTORE_ALIAS_PREFIX)) keyStore.deleteEntry(alias)
        }
    }

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || haystack.size < needle.size) return false
        outer@ for (start in 0..haystack.size - needle.size) {
            for (offset in needle.indices) {
                if (haystack[start + offset] != needle[offset]) continue@outer
            }
            return true
        }
        return false
    }

    private companion object {
        const val ANDROID_KEYSTORE: String = "AndroidKeyStore"

        /** `AndroidSecureStore`'s alias prefix (`ALIAS_PREFIX`). */
        const val KEYSTORE_ALIAS_PREFIX: String = "pdsh.secure."

        /** `AndroidSecureStore`'s `STORE_DIR` under `noBackupFilesDir`. */
        const val SECURE_STORE_DIR: String = "secure-store"
    }
}
