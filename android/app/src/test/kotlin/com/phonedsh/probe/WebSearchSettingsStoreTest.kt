// phone-dsh — :app tests: the independent Search/Fetch settings and launch plan.
// SPDX-License-Identifier: MIT
//
// `spec/v1/gateway-independent-search.md` §3 and §5: the document, the separate
// key account, "a changed address deletes the key", "no key without an address",
// the Worker variables published only for a complete setup, and independent mode
// replacing the official grant without a fallback. The base rules themselves are
// judged by the shared cases in `:net`'s `IndependentSearchWebToolsTest`; here the
// same file drives the store so the page path cannot accept a base the gateway refuses.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.WebSearchFailureReason
import com.phonedsh.ui.page.WebSearchMode
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebSearchSettingsStoreTest {
    private val base = "https://pdsh.tonoai.cn/v1/web"
    private val searchKey = "sk-search-" + "NOT-A-REAL-KEY-7788"
    private val modelKey = "sk-model-" + "NOT-A-REAL-KEY-1234"

    private class MapSecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        val values = mutableMapOf<String, ByteArray>()
        var failDelete: Boolean = false

        override suspend fun put(key: String, value: ByteArray) { values[key] = value.copyOf() }
        override suspend fun get(key: String): SecureLookup =
            values[key]?.let { SecureLookup.Found(it.copyOf()) } ?: SecureLookup.Absent
        override suspend fun delete(key: String) {
            if (failDelete) throw IllegalStateException("fixture delete failure")
            values.remove(key)
        }
    }

    private val secure = MapSecureStore()
    private val keys = ApiKeyStore(secure)
    private val directory: Path = Files.createTempDirectory("pdsh-web-search")
    private val file: File = directory.resolve(WebSearchSettingsStore.FILE_NAME).toFile()
    private val store = WebSearchSettingsStore(file, keys, log = {})

    private fun configured(): WebSearchSettingsStore {
        assertTrue(store.setMode(WebSearchSettingsMode.SEARCH_API).changed)
        assertTrue(store.commitAddress(base).changed)
        assertTrue(store.commitKey(searchKey).changed)
        return store
    }

    private fun sharedBases(): List<Pair<String, String?>> {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "spec/v1/golden/gateway/independent-search/cases.json").isFile) dir = dir.parentFile
        val text = File(requireNotNull(dir) { "repository root not found" }, "spec/v1/golden/gateway/independent-search/cases.json").readText()
        val root = JsonValue.parse(text) as JsonObject
        return (root["bases"] as JsonArray).values.map { value ->
            val row = value as JsonObject
            (row["input"] as JsonString).value to (row["canonical"] as? JsonString)?.value
        }
    }

    @Test
    fun anAbsentDocumentFollowsTheModel() {
        assertEquals(WebSearchSettingsRead.Absent, store.read())
        assertEquals(ApiKeyState.Absent, store.keyState())
    }

    @Test
    fun theDocumentHoldsNoKeyAndTheKeyUsesItsOwnAccount() {
        keys.save(modelKey)
        configured()
        assertEquals(
            WebSearchSettingsRead.Stored(WebSearchSettings(WebSearchSettingsMode.SEARCH_API, base)),
            store.read(),
        )
        val text = file.readText()
        assertFalse(text.contains(searchKey))
        assertEquals(setOf(ApiKeyStore.ACCOUNT, WebSearchSettingsStore.ACCOUNT), secure.values.keys)
        assertEquals(searchKey, store.readKey())
        assertEquals("the model key is untouched", modelKey, keys.readKey())
    }

    @Test
    fun theStoreAcceptsExactlyTheSharedCanonicalBases() {
        for ((input, canonical) in sharedBases()) {
            val fresh = WebSearchSettingsStore(directory.resolve("case-${input.hashCode()}.json").toFile(), keys, log = {})
            val result = fresh.commitAddress(input)
            val read = fresh.read()
            if (canonical == null) {
                assertFalse("${input.trim()} must be refused", result.changed)
                assertEquals(WebSearchSettingsRead.Absent, read)
            } else {
                assertEquals(
                    WebSearchSettingsRead.Stored(WebSearchSettings(WebSearchSettingsMode.SEARCH_API, canonical)),
                    read,
                )
            }
        }
    }

    @Test
    fun aKeyNeedsAStoredAddress() {
        store.setMode(WebSearchSettingsMode.SEARCH_API)
        val result = store.commitKey(searchKey)
        assertFalse(result.changed)
        assertEquals(ApiKeyState.Absent, store.keyState())
    }

    @Test
    fun aChangedAddressDeletesTheOldKeyFirst() {
        configured()
        val result = store.commitAddress("https://other.example.com/v1/web")
        assertTrue(result.changed)
        assertEquals(ApiKeyState.Absent, store.keyState())
        assertTrue(requireNotNull(result.message).contains("原来的密钥已删除"))
        assertFalse(result.message!!.contains(searchKey))
    }

    @Test
    fun theSameAddressKeepsTheKey() {
        configured()
        assertFalse(store.commitAddress("$base/").changed)
        assertEquals(searchKey, store.readKey())
    }

    @Test
    fun aKeyThatCannotBeDeletedBlocksTheAddressChange() {
        configured()
        secure.failDelete = true
        assertFalse(store.commitAddress("https://other.example.com/v1/web").changed)
        assertEquals(
            WebSearchSettingsRead.Stored(WebSearchSettings(WebSearchSettingsMode.SEARCH_API, base)),
            store.read(),
        )
    }

    @Test
    fun switchingToFollowModelKeepsTheServiceAndRemoveDeletesBoth() {
        configured()
        assertTrue(store.setMode(WebSearchSettingsMode.FOLLOW_MODEL).changed)
        assertEquals(searchKey, store.readKey())
        assertTrue(store.remove().changed)
        assertEquals(WebSearchSettingsRead.Absent, store.read())
        assertEquals(ApiKeyState.Absent, store.keyState())
    }

    @Test
    fun anUnknownOrInvalidDocumentIsUnreadable() {
        file.parentFile.mkdirs()
        for (text in listOf(
            "not json",
            """{"version":2,"mode":"search-api","baseUrl":"$base"}""",
            """{"version":1,"mode":"other","baseUrl":"$base"}""",
            """{"version":1,"mode":"search-api","baseUrl":"$base/"}""",
            """{"version":1,"mode":"search-api","baseUrl":"$base","extra":true}""",
            """{"version":1,"mode":"search-api"}""",
        )) {
            file.writeText(text)
            assertEquals(text, WebSearchSettingsRead.Unreadable, store.read())
            assertFalse(store.commitAddress(base).changed)
        }
        assertTrue("removal recovers an unreadable document", store.remove().changed)
        assertEquals(WebSearchSettingsRead.Absent, store.read())
    }

    // ---------------------------------------------------------------- launch plan

    private val official = OfficialWebSearchLaunch(
        credentialAccount = "provider.official",
        environment = com.phonedsh.gateway.OfficialDeepSeekWebTools.workerEnvironment(),
    )

    @Test
    fun aCompleteIndependentSetupPublishesItsBaseAndReplacesTheOfficialGrant() {
        configured()
        var officialAsked = false
        val plan = WebSearchLaunchPlan.resolve(store.read(), store::keyState, proxyRequested = true) {
            officialAsked = true
            official
        }
        assertEquals(WebSearchLaunchPlan.Independent(base), plan)
        assertFalse("independent mode never consults the model grant", officialAsked)
        assertEquals(
            mapOf(
                "PDSH_WEB_SEARCH_PROVIDER" to "deepseek-search-api",
                "PDSH_WEB_FETCH_PROVIDER" to "deepseek-fetch-api",
                "DEEPSEEK_SEARCH_API_BASE_URL" to base,
                "DEEPSEEK_SEARCH_API_KEY" to "phone-host-injects-search-key",
            ),
            plan.environment,
        )
        assertFalse(plan.environment.values.any { it.contains(searchKey) })
    }

    @Test
    fun anIncompleteIndependentSetupLeavesBothToolsOff() {
        store.setMode(WebSearchSettingsMode.SEARCH_API)
        val noAddress = WebSearchLaunchPlan.resolve(store.read(), store::keyState, true) { official }
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_ADDRESS), noAddress)
        store.commitAddress(base)
        val noKey = WebSearchLaunchPlan.resolve(store.read(), store::keyState, true) { official }
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_KEY), noKey)
        assertTrue(noKey.environment.isEmpty())
        store.commitKey(searchKey)
        val noEdge = WebSearchLaunchPlan.resolve(store.read(), store::keyState, false) { official }
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.NO_HOST_EDGE), noEdge)
        val unusable = WebSearchLaunchPlan.resolve(store.read(), { ApiKeyState.Unreadable("fixture") }, true) { official }
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.KEY_UNUSABLE), unusable)
        val broken = WebSearchLaunchPlan.resolve(WebSearchSettingsRead.Unreadable, store::keyState, true) { official }
        assertEquals(WebSearchLaunchPlan.Off(WebSearchLaunchPlan.UNREADABLE), broken)
    }

    @Test
    fun followModelKeepsTheOfficialDecision() {
        assertEquals(
            WebSearchLaunchPlan.Official(official),
            WebSearchLaunchPlan.resolve(WebSearchSettingsRead.Absent, store::keyState, true) { official },
        )
        configured()
        store.setMode(WebSearchSettingsMode.FOLLOW_MODEL)
        assertEquals(
            WebSearchLaunchPlan.Off(null),
            WebSearchLaunchPlan.resolve(store.read(), store::keyState, true) { null },
        )
    }

    // ---------------------------------------------------------------- facts + actions

    @Test
    fun theFactsAreWritableAndCarryOnlyTheKeyTail() {
        val follow = webSearchFacts(store, officialEnabled = true, modelConfigured = true, proxyRequested = true, engineStarted = FactState.YES)
        assertEquals(WebSearchMode.FOLLOW_MODEL, follow.mode)
        assertEquals(FactState.YES, follow.writable)
        assertNull(follow.readOnlyReason)

        store.setMode(WebSearchSettingsMode.SEARCH_API)
        val pending = webSearchFacts(store, false, true, true, FactState.NO)
        assertEquals(WebSearchMode.SEARCH_API, pending.mode)
        assertEquals(FactState.NO, pending.hasCredential)
        assertEquals(WebSearchLaunchPlan.NO_ADDRESS, pending.launchWarning)

        store.commitAddress(base)
        store.commitKey(searchKey)
        val ready = webSearchFacts(store, false, true, true, FactState.NO)
        assertEquals(FactState.YES, ready.hasCredential)
        assertNull(ready.launchWarning)
        assertEquals(searchKey.takeLast(4), ready.keyTail?.takeLast(4))
        assertFalse(ready.toString().contains(searchKey))

        file.writeText("broken")
        val broken = webSearchFacts(store, false, true, true, FactState.NO)
        assertEquals(WebSearchMode.SEARCH_API, broken.mode)
        assertEquals(WebSearchFailureReason.CONFIG_UNREADABLE, broken.failure)
    }

    @Test
    fun theHostActionsLandInTheStoreAndTheirLinesNeverQuoteTheKey() {
        val results = listOf(
            handleWebSearchAction(PdshHostAction.SetWebSearchMode(WebSearchMode.SEARCH_API), store),
            handleWebSearchAction(PdshHostAction.CommitWebSearchAddress(" $base/ "), store),
            handleWebSearchAction(PdshHostAction.CommitWebSearchKey(searchKey), store),
        ).map(::requireNotNull)
        assertTrue(results.all { it.changed })
        assertEquals(searchKey, store.readKey())
        assertTrue(results.none { it.message.orEmpty().contains(searchKey) })
        assertTrue(requireNotNull(handleWebSearchAction(PdshHostAction.ClearWebSearchKey, store)).changed)
        assertEquals(ApiKeyState.Absent, store.keyState())
        assertTrue(requireNotNull(handleWebSearchAction(PdshHostAction.RemoveWebSearchConfiguration, store)).changed)
        assertEquals(WebSearchSettingsRead.Absent, store.read())
        assertNull("other actions are not web-search writes", handleWebSearchAction(PdshHostAction.RefreshWebSearch, store))
        assertFalse(requireNotNull(handleWebSearchAction(PdshHostAction.ClearWebSearchKey, null)).changed)
    }
}
