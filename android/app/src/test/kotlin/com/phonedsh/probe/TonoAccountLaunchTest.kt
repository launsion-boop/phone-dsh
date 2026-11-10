// phone-dsh — :app tests: the tono-account launch gates (spec/v1/tono-account.md §4).
// SPDX-License-Identifier: MIT
//
// A signed-in account stands in for a missing independent-search key only for
// the cloud origin; every other base keeps the existing NO_KEY outcome. The
// session record is one SecureStore item whose unreadable state is not "absent".

package com.phonedsh.probe

import com.phonedsh.account.TonoAccessTokenSource
import com.phonedsh.account.TonoAccountKeySource
import com.phonedsh.gateway.TonoCloudResponsePolicy
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class TonoAccountLaunchTest {

    private class Tokens(override val hasSession: Boolean) : TonoAccessTokenSource {
        override fun accessToken(): String? = if (hasSession) "at_TEST_ACCESS_1" else null
        override fun invalidate(token: String) {}
    }

    private val cloudBase = TonoCloudResponsePolicy.CLOUD_ORIGIN + "/v1/web"
    private val otherBase = "https://search.example.com"

    private fun plan(base: String, tokens: TonoAccessTokenSource?): WebSearchLaunchPlan =
        WebSearchLaunchPlan.resolve(
            settings = WebSearchSettingsRead.Stored(WebSearchSettings(WebSearchSettingsMode.SEARCH_API, base)),
            independentKey = { ApiKeyState.Absent },
            proxyRequested = true,
            accountCovers = { TonoAccountKeySource.usesAccount(it, tokens) },
            official = { null },
        )

    @Test
    fun aSignedInAccountCoversTheMissingKeyOnlyForTheCloudBase() {
        assertEquals(WebSearchLaunchPlan.Independent(cloudBase), plan(cloudBase, Tokens(hasSession = true)))
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_KEY), plan(cloudBase, Tokens(hasSession = false)))
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_KEY), plan(cloudBase, null))
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_KEY), plan(otherBase, Tokens(hasSession = true)))
    }

    private class FakeSecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.entries.first()
        val values = HashMap<String, ByteArray>()
        var unreadable = false
        override suspend fun put(key: String, value: ByteArray) { values[key] = value.copyOf() }
        override suspend fun get(key: String): SecureLookup = when {
            unreadable -> SecureLookup.Unreadable("test")
            key in values -> SecureLookup.Found(values.getValue(key))
            else -> SecureLookup.Absent
        }
        override suspend fun delete(key: String) { values.remove(key) }
    }

    @Test
    fun theRecordIsOneSecureStoreItem() {
        val secure = FakeSecureStore()
        val store = SecureStoreTonoAccountStore(secure)
        assertNull(store.load())
        store.save(byteArrayOf(1, 2, 3))
        assertEquals(setOf(SecureStoreTonoAccountStore.KEY), secure.values.keys)
        assertArrayEquals(byteArrayOf(1, 2, 3), store.load())
        secure.unreadable = true
        try {
            store.load()
            fail("an unreadable record is not an absent one")
        } catch (_: IOException) {
        }
        secure.unreadable = false
        store.delete()
        assertNull(store.load())
    }
}
