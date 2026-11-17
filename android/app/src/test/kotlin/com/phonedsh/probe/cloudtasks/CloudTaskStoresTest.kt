// SPDX-License-Identifier: MIT
// phone-dsh — :app tests: the phone task queue's app stores.
//
// spec/v1/cloud-tasks.md §2, §3, §7: the two preference keys by the contract's
// names in the app's preferences file, one `SecureStore` item per key id whose
// unreadable state is an `IOException` (never "no key"), and the three-valued
// account read.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.account.TonoAccountProtocol
import com.phonedsh.account.TonoSessionRecord
import com.phonedsh.cloudtasks.CloudTaskIdentity
import com.phonedsh.cloudtasks.CloudTaskKeyStore
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.probe.PreferenceFile
import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CloudTaskStoresTest {
    private class FakeSecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.entries.first()
        val values = HashMap<String, ByteArray>()
        var unreadable = false
        var failure: Exception? = null

        override suspend fun put(key: String, value: ByteArray) {
            failure?.let { throw it }
            values[key] = value.copyOf()
        }

        override suspend fun get(key: String): SecureLookup {
            failure?.let { throw it }
            return when {
                unreadable -> SecureLookup.Unreadable("key-invalidated")
                key in values -> SecureLookup.Found(values.getValue(key))
                else -> SecureLookup.Absent
            }
        }

        override suspend fun delete(key: String) {
            failure?.let { throw it }
            values.remove(key)
        }
    }

    private class MapPreferenceFile : PreferenceFile {
        val values = HashMap<String, Any>()
        val committed = ArrayList<String>()

        override fun string(key: String): String? = values[key] as? String
        override fun integer(key: String): Int? = values[key] as? Int
        override fun boolean(key: String): Boolean? = values[key] as? Boolean
        override fun putString(key: String, value: String): Boolean = true.also { values[key] = value }
        override fun putInt(key: String, value: Int): Boolean = true.also { values[key] = value }
        override fun putBoolean(key: String, value: Boolean): Boolean = true.also { values[key] = value }
        @Suppress("UNCHECKED_CAST")
        override fun stringSet(key: String): Set<String>? = values[key] as? Set<String>
        override fun putStringSet(key: String, value: Set<String>): Boolean = true.also { values[key] = value }
        override fun commitString(key: String, value: String): Boolean = putString(key, value).also { committed += key }
        override fun commitInt(key: String, value: Int): Boolean = putInt(key, value).also { committed += key }
        override fun commitBoolean(key: String, value: Boolean): Boolean = putBoolean(key, value).also { committed += key }
        override fun commitStringSet(key: String, value: Set<String>): Boolean = putStringSet(key, value).also { committed += key }
        override fun remove(key: String) { values.remove(key) }
    }

    private inline fun expectIo(block: () -> Unit) {
        try {
            block()
            fail("expected an IOException")
        } catch (_: IOException) {
        }
    }

    // ---- keys

    @Test
    fun aKeyRecordIsOneSecureStoreItemUnderTheContractsName() {
        val store = FakeSecureStore()
        val keys = SecureStoreCloudTaskKeyStore(store)

        assertNull(keys.load("k-1"))
        keys.save("k-1", byteArrayOf(1, 2, 3))

        assertEquals(setOf("cloud-tasks.key.k-1"), store.values.keys)
        assertEquals(CloudTaskKeyStore.storageKey("k-1"), store.values.keys.single())
        assertArrayEquals(byteArrayOf(1, 2, 3), keys.load("k-1"))
        keys.delete("k-1")
        assertTrue(store.values.isEmpty())
    }

    @Test
    fun anUnreadableOrFailingStoreIsAnIOExceptionNeverNoKey() {
        val store = FakeSecureStore()
        val keys = SecureStoreCloudTaskKeyStore(store)
        keys.save("k-1", byteArrayOf(1))

        store.unreadable = true
        expectIo { keys.load("k-1") }

        store.unreadable = false
        store.failure = IllegalStateException("keystore")
        expectIo { keys.load("k-1") }
        expectIo { keys.save("k-2", byteArrayOf(2)) }
        expectIo { keys.delete("k-1") }
        store.failure = IOException("disk")
        expectIo { keys.save("k-2", byteArrayOf(2)) }
    }

    // ---- preferences

    @Test
    fun thePreferencesUseTheContractsKeyNamesAndCommitEveryWrite() {
        val file = MapPreferenceFile()
        val preferences = PreferenceFileCloudTaskPreferences(file)

        assertNull("absent = off", preferences.boolean(CloudTaskIdentity.ENABLED_KEY))
        assertEquals(false, CloudTaskIdentity.isEnabled(preferences))
        val deviceId = CloudTaskIdentity.deviceId(preferences)!!
        preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, true)

        assertEquals(deviceId, file.values["phone-dsh.bot.cloud.device-id.v1"])
        assertEquals(true, file.values["phone-dsh.cloud-tasks.enabled.v1"])
        assertEquals(
            listOf("phone-dsh.bot.cloud.device-id.v1", "phone-dsh.cloud-tasks.enabled.v1"),
            file.committed,
        )
        assertEquals("one install has one device id", deviceId, CloudTaskIdentity.deviceId(preferences))
    }

    // ---- account

    private fun record(userId: String?): ByteArray =
        TonoAccountProtocol.encodeRecord(TonoSessionRecord("rt_TEST_REFRESH_1", 1_794_700_000_000, userId, "1234"))

    @Test
    fun theAccountReadHasThreeAnswers() {
        fun read(bytes: () -> ByteArray?, live: Boolean) = TonoCloudTaskAccountReader(bytes) { live }()

        assertEquals(CloudTaskAccount.SignedIn("u-1"), read({ record("u-1") }, live = true))
        assertEquals(CloudTaskAccount.SignedOut, read({ null }, live = false))
        assertEquals("a record the session could not delete is not a sign-in",
            CloudTaskAccount.SignedOut, read({ record("u-1") }, live = false))
        assertEquals("an unreadable store is not signed out",
            CloudTaskAccount.Unknown, read({ throw IOException("locked") }, live = false))
        assertEquals("signed in, record not stored yet", CloudTaskAccount.Unknown, read({ null }, live = true))
        assertEquals("signed in without a user id", CloudTaskAccount.Unknown, read({ record(null) }, live = true))
        assertEquals(CloudTaskAccount.Unknown, read({ byteArrayOf(1, 2) }, live = true))
    }

    @Test
    fun onlyAUserIdThatFitsTheJournalBecomesAPrincipal() {
        assertEquals("account:u-1", CloudTaskAdmissionBridge.principal("u-1"))
        assertNull(CloudTaskAdmissionBridge.principal(""))
        assertNull(CloudTaskAdmissionBridge.principal("a b"))
        assertNull(CloudTaskAdmissionBridge.principal("x".repeat(129)))
    }
}
