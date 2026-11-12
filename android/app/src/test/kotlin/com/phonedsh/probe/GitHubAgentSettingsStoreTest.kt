// GitHubAgentSettingsStore: token record, write opt-in, env facts and provider wrap.
// SPDX-License-Identifier: MIT
//
// The Swift port is `Tests/PhoneDSHTests/GitHubAgentCredentialTests.swift`:
// `testWritesNeedBothATokenAndTheExplicitOptIn` lives here, and the `/v1/http`
// scope matrix lives in `:net`'s `GitHubAgentCredentialProviderTest`.
package com.phonedsh.probe

import com.phonedsh.engine.WorkerEnvironment
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GitHubAgentCredentialProvider
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GitHubAgentSettingsStoreTest {
    private class MapSecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        val values = LinkedHashMap<String, ByteArray>()
        val unreadable = HashSet<String>()
        var failWrites = false

        override suspend fun put(key: String, value: ByteArray) {
            if (failWrites) throw java.io.IOException("write failed")
            values[key] = value.copyOf()
        }

        override suspend fun get(key: String): SecureLookup = when {
            key in unreadable -> SecureLookup.Unreadable("key-invalidated")
            values.containsKey(key) -> SecureLookup.Found(values.getValue(key).copyOf())
            else -> SecureLookup.Absent
        }

        override suspend fun delete(key: String) {
            values.remove(key)
        }
    }

    private class MapPreferenceFile : PreferenceFile {
        val values = LinkedHashMap<String, Any?>()
        var failCommits = false

        override fun string(key: String): String? = values[key] as? String
        override fun integer(key: String): Int? = values[key] as? Int
        override fun boolean(key: String): Boolean? = values[key] as? Boolean
        override fun putString(key: String, value: String): Boolean = set(key, value)
        override fun putInt(key: String, value: Int): Boolean = set(key, value)
        override fun putBoolean(key: String, value: Boolean): Boolean = set(key, value)
        override fun stringSet(key: String): Set<String>? = null
        override fun putStringSet(key: String, value: Set<String>): Boolean = set(key, value)
        override fun commitString(key: String, value: String): Boolean = set(key, value)
        override fun commitInt(key: String, value: Int): Boolean = set(key, value)
        override fun commitBoolean(key: String, value: Boolean): Boolean {
            if (failCommits) return false
            values[key] = value
            return true
        }
        override fun commitStringSet(key: String, value: Set<String>): Boolean = set(key, value)
        override fun remove(key: String) {
            values.remove(key)
        }

        private fun set(key: String, value: Any?): Boolean {
            values[key] = value
            return true
        }
    }

    private class RecordingBase : GatewayCredentialProvider {
        val scopes = mutableListOf<CredentialScope>()
        override fun resolve(scope: CredentialScope): GatewayCredential =
            GatewayCredential.ApiKey("x-api-key", "model-key").also { scopes += scope }
    }

    private fun store(
        secure: MapSecureStore = MapSecureStore(),
        preferences: MapPreferenceFile = MapPreferenceFile(),
    ) = GitHubAgentSettingsStore(secure, preferences)

    private fun githubScope() = CredentialScope(
        service = GitHubAgentCredentialProvider.GITHUB_HOST,
        audience = "/repos/octo/example",
        scheme = "https",
        port = 443,
    )

    @Test
    fun `an absent token is zero and the write opt in defaults to false`() {
        val store = store()
        assertFalse(store.hasToken())
        assertFalse(store.allowWrites())
        assertEquals("0", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertEquals("0", WorkerEnvironment.githubWriteEnvironmentValue(store.environment()))
        assertTrue("the feature is enabled on this host", store.environment().enabled)
    }

    @Test
    fun `saving a token reports auth but not write access`() {
        val secure = MapSecureStore()
        val store = store(secure)
        assertTrue(store.saveToken("  ghp_test  "))

        assertTrue(store.hasToken())
        assertEquals(
            "the token sits under the iOS service + account key, not a literal",
            "ghp_test",
            String(secure.values.getValue(GitHubAgentSettingsStore.SECURE_KEY), Charsets.UTF_8),
        )
        assertEquals("1", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertEquals("0", WorkerEnvironment.githubWriteEnvironmentValue(store.environment()))
    }

    @Test
    fun `writes need both a token and the explicit opt in`() {
        val preferences = MapPreferenceFile()
        val store = store(preferences = preferences)

        assertTrue(store.setAllowWrites(true))
        assertEquals(
            "the iOS UserDefaults key string is the protocol",
            "phone-dsh.github.agent.allow-writes",
            GitHubAgentSettingsStore.ALLOW_WRITES_KEY,
        )
        assertEquals(
            "the write is persisted in SharedPreferences under that key",
            true,
            preferences.values[GitHubAgentSettingsStore.ALLOW_WRITES_KEY],
        )
        assertEquals(
            "an opt-in without a token is not write access",
            "0",
            WorkerEnvironment.githubWriteEnvironmentValue(store.environment()),
        )

        store.saveToken("ghp_test")
        assertEquals("1", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertEquals("1", WorkerEnvironment.githubWriteEnvironmentValue(store.environment()))

        store.setAllowWrites(false)
        assertEquals("1", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertEquals("0", WorkerEnvironment.githubWriteEnvironmentValue(store.environment()))
    }

    @Test
    fun `deleting removes the record and keeps the opt in`() {
        val secure = MapSecureStore()
        val preferences = MapPreferenceFile()
        val store = store(secure, preferences)
        store.setAllowWrites(true)
        store.saveToken("ghp_test")

        assertTrue(store.deleteToken())
        assertFalse(store.hasToken())
        assertEquals("0", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertEquals("0", WorkerEnvironment.githubWriteEnvironmentValue(store.environment()))
        assertFalse("the token is gone", secure.values.containsKey(GitHubAgentSettingsStore.SECURE_KEY))
        assertTrue("the write opt-in is a separate record", store.allowWrites())

        assertTrue("delete is idempotent", store.deleteToken())
        assertTrue(secure.values.isEmpty())
    }

    @Test
    fun `an empty or multiline token is refused before the store`() {
        val secure = MapSecureStore()
        val store = store(secure)
        for (value in listOf("", "   ", "ghp_one\ntwo", "ghp_one\r\ntwo")) {
            assertFalse(store.saveToken(value))
        }
        assertTrue(secure.values.isEmpty())
        assertFalse(store.hasToken())
    }

    @Test
    fun `an unreadable record is absent, not an invented token`() {
        val secure = MapSecureStore()
        secure.values[GitHubAgentSettingsStore.SECURE_KEY] = "ghp_test".toByteArray()
        secure.unreadable += GitHubAgentSettingsStore.SECURE_KEY
        val store = store(secure)

        assertFalse(store.hasToken())
        assertEquals("0", WorkerEnvironment.githubAuthEnvironmentValue(store.environment()))
        assertNull(store.tokenSource().readToken())
    }

    @Test
    fun `a failed write is not reported as a stored token`() {
        val secure = MapSecureStore().apply { failWrites = true }
        val store = store(secure)
        assertFalse(store.saveToken("ghp_test"))
        assertFalse(store.hasToken())
    }

    @Test
    fun `the store wraps the gateway provider with the github scope`() {
        val store = store()
        store.saveToken("ghp_test")
        val base = RecordingBase()
        val provider = store.credentialProvider(base)

        assertEquals(
            GatewayCredential.Bearer("ghp_test"),
            provider.resolve(githubScope()),
        )
        val model = CredentialScope("model.example", "/v1/chat/completions", "https", 443)
        assertEquals(GatewayCredential.ApiKey("x-api-key", "model-key"), provider.resolve(model))
        assertEquals("only the model scope reached the base provider", listOf(model), base.scopes)
    }

    @Test
    fun `the facts never carry the token`() {
        val store = store()
        store.saveToken("ghp_super_secret")
        assertFalse(store.facts.value.toString().contains("ghp_super_secret"))
        assertFalse(store.environment().toString().contains("ghp_super_secret"))
    }
}
