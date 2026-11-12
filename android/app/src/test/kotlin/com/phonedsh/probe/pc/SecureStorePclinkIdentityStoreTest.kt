// SPDX-License-Identifier: MIT
// `pclink.identity-v1` through the platform SecureStore: round-trip, absence,
// and the fail-closed "unreadable is not absent" rule (design §5.1).
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkIdentity
import com.phonedsh.pclink.PclinkError
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureStorePclinkIdentityStoreTest {
    @Test
    fun `seed round trips through the secure store under the frozen key`() = runBlocking {
        val store = FakeSecureStore()
        val identity = PclinkIdentity.generate()
        val adapter = SecureStorePclinkIdentityStore(store)

        adapter.saveSeed(identity.seed)

        assertEquals(SecureStorePclinkIdentityStore.KEY, store.values.keys.single())
        assertArrayEquals(identity.seed, adapter.loadSeed())
        assertArrayEquals(identity.seed, store.values.getValue(SecureStorePclinkIdentityStore.KEY))
    }

    @Test
    fun `an absent seed is null, never a generated identity`() {
        val adapter = SecureStorePclinkIdentityStore(FakeSecureStore())
        assertNull(adapter.loadSeed())
    }

    @Test
    fun `an unreadable seed is a storage failure, not absence`() {
        val store = FakeSecureStore()
        store.unreadable.add(SecureStorePclinkIdentityStore.KEY)
        val adapter = SecureStorePclinkIdentityStore(store)

        val error = try {
            adapter.loadSeed()
            null
        } catch (thrown: PclinkError.Storage) {
            thrown
        }

        assertEquals("storage", error?.code)
        assertEquals(SecureStorePclinkIdentityStore.IDENTITY_UNREADABLE, error?.message)
    }

    @Test
    fun `a wrongly sized value is unreadable rather than a new seed`() {
        val store = FakeSecureStore()
        store.values[SecureStorePclinkIdentityStore.KEY] = ByteArray(31)
        val adapter = SecureStorePclinkIdentityStore(store)

        val error = try {
            adapter.loadSeed()
            null
        } catch (thrown: PclinkError.Storage) {
            thrown
        }
        assertEquals(SecureStorePclinkIdentityStore.IDENTITY_UNREADABLE, error?.message)
    }

    @Test
    fun `delete removes the seed and is idempotent`() = runBlocking {
        val store = FakeSecureStore()
        val adapter = SecureStorePclinkIdentityStore(store)
        adapter.saveSeed(PclinkIdentity.generate().seed)

        adapter.deleteSeed()
        adapter.deleteSeed()

        assertFalse(store.values.containsKey(SecureStorePclinkIdentityStore.KEY))
        assertNull(adapter.loadSeed())
    }

    @Test
    fun `a write failure is a storage error and keeps no partial value`() {
        val store = FakeSecureStore().apply { failWrites = true }
        val adapter = SecureStorePclinkIdentityStore(store)

        val error = try {
            adapter.saveSeed(ByteArray(32))
            null
        } catch (thrown: PclinkError.Storage) {
            thrown
        }
        assertTrue(error != null)
        assertTrue(store.values.isEmpty())
    }
}
