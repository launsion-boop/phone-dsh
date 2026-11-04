// Instrumented evidence for the Worker env: placeholder only, state reported.
// SPDX-License-Identifier: MIT
//
// The Worker never holds the model key (`spec/v1/gateway-security.md` §2; the iOS
// baseline hands `phone-host-injects-mcp-key` to the Worker and lets the host
// inject the real credential at the network edge). This suite pins that on a
// device:
//   * every state — configured, absent, invalid — puts the **same non-secret
//     placeholder** into `DEEPSEEK_API_KEY`, never the stored key;
//   * a stored key's bytes never appear anywhere in the env string;
//   * `PDSH_MODEL_KEY_STATE` is the honest part of the answer (configured /
//     absent / invalid), always present;
//   * the key members do not depend on the endpoint: a launch with **no base
//     URL** still reports the placeholder and the state, and only the endpoint
//     members (`DEEPSEEK_BASE_URL`, `PDSH_MODEL_NAME`, `DSH_TELEMETRY_DISABLED`)
//     are gated on `base != null`;
//   * the real key's only exit is `modelCredentialProvider()`, scoped to the
//     model origin and protocol path, failing closed when it cannot resolve;
//   * the settings page only ever receives four characters;
//   * the process's own logcat never contains the key.
//
// The last check reads `logcat -d` as this app's UID, which on API 26+ only shows
// this UID's own entries: that is exactly the claim ("this app never logs the
// key"), not "nobody on the device logged it".

package com.phonedsh.probe

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayRequestHeaders
import com.phonedsh.ui.page.ProviderKeyStatus
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import org.json.JSONObject
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
class ProbeLaunchConfigInstrumentedTest {

    private lateinit var context: Context
    private lateinit var store: ApiKeyStore

    private val baseUrl: String = "https://api.example.com/v1"
    private val egressOrigin: String = "http://127.0.0.1:7861"

    /** Obviously fake; nothing here is a credential. */
    private val fakeKey: String = "sk-test-NOT-A-REAL-KEY-0000"

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        store = ApiKeyStore.install(context)
        store.clear()
    }

    @After
    fun tearDown() {
        store.clear()
    }

    // ---- absent ----------------------------------------------------------

    @Test
    fun anAbsentKeyAddsNoKeyMemberToTheWorkerEnv() {
        val raw = environment()

        val env = JSONObject(raw)
        assertEquals(baseUrl, env.getString("DEEPSEEK_BASE_URL"))
        assertEquals("deepseek-flash", env.getString("PDSH_MODEL_NAME"))
        assertEquals("1", env.getString("DSH_TELEMETRY_DISABLED"))
        // `gateway-security.md` §2: the Worker never holds the real key, so the env carries the
        // recognisable placeholder in every state and the state variable says what is true.
        assertEquals(
            "the Worker sees the placeholder, never a key",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals(
            "the value the Worker sends and the value the sanitizer drops are one value",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            ProbeLaunchConfig.WORKER_KEY_PLACEHOLDER,
        )
        assertEquals("absent", env.getString("PDSH_MODEL_KEY_STATE"))
        assertFalse("the old app placeholder must stay gone", raw.contains("pdsh-app-placeholder"))
        assertEquals(ProviderKeyStatus.NOT_CONFIGURED, ApiKeyStore.install(context).fact().status)
    }

    @Test
    fun aLaunchWithoutAnEndpointProducesNoEnvAtAll() {
        assertNull(ProbeLaunchConfig.from(null, debuggable = true).workerEnvironment())
        assertNull(
            "a non-http endpoint is dropped, and with it the env",
            ProbeLaunchConfig.from(intent(baseExtra = "ftp://api.example.com/v1"), debuggable = true).workerEnvironment(),
        )
    }

    // ---- no base URL -----------------------------------------------------
    //
    // `baseUrl` and the key are two independent facts. Gating the key members on
    // `base != null` made a launch without a base URL report *no key at all*, so the
    // Worker said `no API key` when the missing fact was the base URL. These tests
    // pin the split: the key members are always present in an env, the endpoint
    // members only when a base URL was named.

    @Test
    fun aLaunchWithoutABaseUrlStillReportsTheKeyState() {
        store.save(fakeKey)

        val raw = environmentWithoutBase()
        val env = JSONObject(raw)

        assertEquals(
            "the placeholder is a fact about the Worker, not about the endpoint",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals(
            "a stored key is configured even when the launch named no base URL",
            "configured",
            env.getString("PDSH_MODEL_KEY_STATE"),
        )
        assertFalse("the endpoint member must not be invented", env.has("DEEPSEEK_BASE_URL"))
        assertFalse("the endpoint facts stay gated", env.has("PDSH_MODEL_NAME"))
        assertFalse("the endpoint facts stay gated", env.has("DSH_TELEMETRY_DISABLED"))
        assertEquals("the limit is not an endpoint fact", "16777216", env.getString("PDSH_SINGLE_FILE_LIMIT_BYTES"))
        assertEquals("the key's bytes never enter the env", 0, countOf(raw, fakeKey))
    }

    @Test
    fun aLaunchWithoutABaseUrlAndWithoutAKeySaysAbsent() {
        val env = JSONObject(environmentWithoutBase())

        assertEquals(
            "the placeholder is still the value, never an empty member",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals("no key is absent, not an unknown", "absent", env.getString("PDSH_MODEL_KEY_STATE"))
        assertFalse(env.has("DEEPSEEK_BASE_URL"))
    }

    @Test
    fun aLaunchWithoutABaseUrlAndWithoutALimitProducesNoEnvAtAll() {
        store.save(fakeKey)
        assertNull(
            "both facts absent means nothing to send — the pre-existing contract",
            ProbeLaunchConfig.from(null, debuggable = true).workerEnvironment(singleFileLimitBytes = null),
        )
        assertNull(
            "a config with no base and no limit is the same nothing",
            ProbeLaunchConfig(deepseekBaseUrl = null)
                .workerEnvironment(modelProxyMounted = false, singleFileLimitBytes = null),
        )
    }

    @Test
    fun aLaunchWithABaseUrlKeepsTheSameEndpointsAsBefore() {
        store.save(fakeKey)

        val env = JSONObject(environment())

        // The fix moved the key block out of `base != null`; nothing about the
        // with-base shape may change.
        assertEquals(baseUrl, env.getString("DEEPSEEK_BASE_URL"))
        assertEquals("deepseek-flash", env.getString("PDSH_MODEL_NAME"))
        assertEquals("1", env.getString("DSH_TELEMETRY_DISABLED"))
        assertEquals(
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals("configured", env.getString("PDSH_MODEL_KEY_STATE"))
    }

    @Test
    fun aMountedEdgeStillOmitsTheRealBaseUrlWithoutLosingTheKeyState() {
        store.save(fakeKey)

        val env = JSONObject(
            ProbeLaunchConfig.from(intent(), debuggable = true)
                .workerEnvironment(modelProxyMounted = true, singleFileLimitBytes = LIMIT),
        )

        assertFalse("the mounted edge owns DEEPSEEK_BASE_URL", env.has("DEEPSEEK_BASE_URL"))
        assertEquals(
            "the key state does not depend on which side owns the base",
            "configured",
            env.getString("PDSH_MODEL_KEY_STATE"),
        )
        assertEquals(
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
    }

    // ---- valid -----------------------------------------------------------

    @Test
    fun aStoredKeyNeverEntersTheWorkerEnv() {
        store.save(fakeKey)

        val raw = environment()
        val env = JSONObject(raw)

        // The rule under test: a stored key changes the *state*, never the env's key member.
        // This test used to assert the opposite (the real key injected exactly once) because the
        // demo's model traffic bypasses the host gateway. That made the Worker able to log the
        // key, which is precisely what §2 forbids.
        assertEquals(
            "the Worker still sees the placeholder, not the stored key",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals("configured", env.getString("PDSH_MODEL_KEY_STATE"))
        assertEquals("the key must appear zero times in the env", 0, countOf(raw, fakeKey))
        assertFalse("the old app placeholder must stay gone", raw.contains("pdsh-app-placeholder"))
    }

    @Test
    fun theGatewayProviderResolvesTheStoredKeyForTheModelPathOnly() {
        store.save(fakeKey)
        val candidate: GatewayCredentialProvider? = config().modelCredentialProvider()
        assertNotNull("a launch with an endpoint and a store must build a provider", candidate)
        val provider: GatewayCredentialProvider = candidate!!

        assertEquals(
            GatewayCredential.Bearer(fakeKey),
            provider.resolve(CredentialScope("api.example.com", "/v1/messages", "https", null)),
        )
        assertEquals(
            "a same-host non-model path never sees the model key",
            GatewayCredential.None,
            provider.resolve(CredentialScope("api.example.com", "/v1/mcp/tools", "https", null)),
        )
        assertEquals(
            "the egress origin is deliberately key-free",
            GatewayCredential.None,
            provider.resolve(CredentialScope("127.0.0.1", "/health", "http", 7861)),
        )
    }

    @Test
    fun withoutAKeyTheGatewayProviderFailsClosed() {
        val candidate = config().modelCredentialProvider()
        assertNotNull(candidate)
        val provider = candidate!!

        try {
            provider.resolve(CredentialScope("api.example.com", "/v1/messages", "https", null))
            fail("no key must fail closed, never become an anonymous model request")
        } catch (expected: CredentialUnavailableException) {
            assertFalse(expected.message.orEmpty().contains(fakeKey))
        }
    }

    @Test
    fun theSettingsFactCarriesOnlyTheFourCharacterSuffix() {
        store.save(fakeKey)

        val fact = config().keyFact()

        assertEquals(ProviderKeyStatus.CONFIGURED, fact.status)
        assertNotNull(fact.suffix)
        assertEquals(4, fact.suffix!!.length)
        assertEquals(fakeKey.takeLast(4), fact.suffix)
        assertFalse("the fact must not carry the key", fact.toString().contains(fakeKey))
        assertFalse("nor its first eight characters", fact.toString().contains(fakeKey.substring(0, 8)))
    }

    // ---- invalid ---------------------------------------------------------

    @Test
    fun anUnreadableStoredKeyKeepsTheKeyOutAndSaysInvalid() {
        store.save(fakeKey)
        // The production way a stored key becomes unusable: the Keystore entry is
        // gone while the ciphertext file remains, so the value cannot be decrypted.
        deleteSecureStoreKeys()

        val raw = environment()
        val env = JSONObject(raw)

        assertEquals(
            "an unusable key still leaves the placeholder, not an empty member",
            GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER,
            env.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals("invalid", env.getString("PDSH_MODEL_KEY_STATE"))
        assertFalse(raw.contains(fakeKey))
        assertEquals("the page shows 不可用, never 未配置", ProviderKeyStatus.INVALID, store.fact().status)

        val candidate = config().modelCredentialProvider()
        assertNotNull("the provider still exists", candidate)
        try {
            candidate!!.resolve(CredentialScope("api.example.com", "/v1/messages", "https", null))
            fail("an unusable key must fail closed")
        } catch (expected: CredentialUnavailableException) {
            assertFalse(expected.message.orEmpty().contains(fakeKey))
        }
    }

    // ---- logcat ----------------------------------------------------------

    @Test
    fun theKeyNeverAppearsInThisProcessesOwnLogcat() {
        store.save(fakeKey)
        // Exercise every path that touches the key, including the env the Worker
        // would receive and the page fact.
        environment()
        store.fact()
        store.read()
        config().modelCredentialProvider()?.resolve(
            CredentialScope("api.example.com", "/v1/messages", "https", null),
        )

        val log = readProcessLogcat()
        assertNotNull(
            "logcat must be readable as this app's UID for the leak check to mean anything",
            log,
        )
        assertFalse("the model key must never reach logcat", log!!.contains(fakeKey))
        assertFalse("no Authorization header may reach logcat", log.contains("Bearer $fakeKey"))
    }

    // ---- helpers ---------------------------------------------------------

    private fun intent(baseExtra: String = baseUrl): Intent = Intent()
        .putExtra(ProbeLaunchConfig.EXTRA_BASE_URL, baseExtra)
        .putExtra(ProbeLaunchConfig.EXTRA_EGRESS_ORIGIN, egressOrigin)

    private fun config(): ProbeLaunchConfig = ProbeLaunchConfig.from(intent(), debuggable = true)

    /** The production no-base shape: the tier limit is passed, no base URL extra. */
    private fun environmentWithoutBase(): String {
        val env = ProbeLaunchConfig.from(Intent().putExtra(ProbeLaunchConfig.EXTRA_EGRESS_ORIGIN, egressOrigin), debuggable = true)
            .workerEnvironment(singleFileLimitBytes = LIMIT)
        assertNotNull("the limit alone must still produce an env", env)
        return env!!
    }

    private fun environment(): String {
        val env = config().workerEnvironment()
        assertNotNull("a launch with a valid endpoint must produce an env", env)
        return env!!
    }

    private fun countOf(haystack: String, needle: String): Int {
        var count = 0
        var index = haystack.indexOf(needle)
        while (index >= 0) {
            count++
            index = haystack.indexOf(needle, index + needle.length)
        }
        return count
    }

    private fun deleteSecureStoreKeys() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (alias in keyStore.aliases().toList()) {
            if (alias.startsWith("pdsh.secure.")) keyStore.deleteEntry(alias)
        }
    }

    /** This process's own log entries, or `null` when the binary is not runnable. */
    private fun readProcessLogcat(): String? = try {
        val process = ProcessBuilder(LOGCAT, "-d", "-v", "brief").redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor(LOG_DRAIN_SECONDS, TimeUnit.SECONDS)
        process.destroy()
        text
    } catch (failure: Exception) {
        null
    }

    private companion object {
        const val LOGCAT: String = "/system/bin/logcat"
        const val LOG_DRAIN_SECONDS: Long = 5

        /** `HostBudgetTier`'s 2 GiB row, `budgets.md` §4 — the production call always passes one. */
        const val LIMIT: Long = 16L * 1024 * 1024
    }
}
