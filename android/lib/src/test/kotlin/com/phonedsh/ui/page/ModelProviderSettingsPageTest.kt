// Model-provider page: four states, the fold sequence, and the key never leaks.
// SPDX-License-Identifier: MIT
//
// The security assertions are negative on purpose: a snapshot that carries a
// whole key and a whole URL is projected, and the test proves that neither the
// composed tree nor the state's display fields contain them. `performScrollToNode`
// runs before the negative assertion because a LazyColumn item outside the
// viewport is not composed; asserting before scrolling would be a false green.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class ModelProviderSettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    /** Test-only key material; never asserted as a visible string. */
    private val fullKey: String = "sk-" + "test-only" + "-" + "never-render" + "-" + "9f3a"

    private val deepSeek = ProviderProfile(
        id = "deepseek",
        name = "DeepSeek",
        model = "deepseek-flash",
        endpoint = "https://" + "api.deepseek.com" + "/v1",
        key = ProviderKeyFact(ProviderKeyStatus.CONFIGURED, "sk-1234-9f3a"),
        selected = true,
    )

    private fun show(
        facts: ModelProviderFacts,
        onAdd: () -> Unit = {},
        onEdit: (String) -> Unit = {},
        onRetry: (() -> Unit)? = null,
    ) {
        val state = ModelProviderScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = state,
                    onAdd = onAdd,
                    onEdit = onEdit,
                    onToggleSection = {},
                    onBack = {},
                    onRetry = onRetry,
                )
            }
        }
    }

    /** A live host: the fold and the row callbacks update the projected state. */
    private fun showLive(
        facts: ModelProviderFacts,
        onAdd: () -> Unit = {},
        onEdit: (String) -> Unit = {},
        onRetry: (() -> Unit)? = null,
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(ModelProviderLocalState()) }
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(facts, local),
                    onAdd = onAdd,
                    onEdit = onEdit,
                    onToggleSection = { id -> local = local.apply(ModelProviderUiEvent.ToggleSection(id)) },
                    onBack = {},
                    onRetry = onRetry,
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty snapshot shows the empty state, not a blank list`() {
        show(ModelProviderFacts(profiles = emptyList()))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertDoesNotExist()
    }

    @Test
    fun `a configured service renders its model, redacted host and key suffix`() {
        var added = 0
        var edited: String? = null
        show(
            ModelProviderFacts(profiles = listOf(deepSeek)),
            onAdd = { added += 1 },
            onEdit = { edited = it },
        )
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek"))
        compose.onNodeWithText("DeepSeek").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DEFAULT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_MODEL.format("deepseek-flash")).assertIsDisplayed()
        // The host-only projection: no scheme and no path reaches the screen.
        compose.onNodeWithText(UiStrings.PROVIDER_ENDPOINT.format("api.deepseek.com")).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_KEY_SUFFIX.format("9f3a")).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_KEY_CONFIGURED_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek").performClick()
        assertEquals("deepseek", edited)
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        assertEquals(1, added)
    }

    @Test
    fun `a failed key read shows its own failure line and retries`() {
        var retried = 0
        show(
            ModelProviderFacts(profiles = emptyList(), failure = ProviderFailureReason.KEY_UNREADABLE),
            onRetry = { retried += 1 },
        )
        compose.onNodeWithTag(UiPageTags.PROVIDER_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_FAILURE_KEY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `no snapshot is unknown, never an empty configuration`() {
        show(ModelProviderFacts(profiles = null))
        compose.onNodeWithTag(UiPageTags.PROVIDER_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertDoesNotExist()
    }

    @Test
    fun `an unreadable key status renders 未知, not 未配置`() {
        val profile = ProviderProfile(
            id = "pending",
            name = "待检查",
            key = ProviderKeyFact(ProviderKeyStatus.UNKNOWN),
        )
        val state = ModelProviderScreenState.from(ModelProviderFacts(profiles = listOf(profile)))
        assertEquals(UiStrings.UNKNOWN, state.rows.single().keyValue)
        assertEquals(PageTone.UNKNOWN, state.rows.single().keyTone)
        show(ModelProviderFacts(profiles = listOf(profile)))
        // The row is a lazy item: locate it before asserting its copy.
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "pending"))
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.NOT_CONFIGURED).assertDoesNotExist()
    }

    // --------------------------------------------------------------- security

    /**
     * The special security test: a host hands over a whole key (in the suffix
     * field) and a whole URL; the screen and the state's display fields can only
     * contain the four-character suffix and the host.
     */
    @Test
    fun `a full key in the snapshot never reaches the screen or the state fields`() {
        val secret = ProviderProfile(
            id = "secret",
            name = "Secret",
            endpoint = "https://" + "user:pw@" + "api.example.com" + "/v1" + "?token=abc",
            key = ProviderKeyFact(ProviderKeyStatus.CONFIGURED, fullKey),
            selected = true,
        )
        val decoys = (0 until 24).map { index ->
            ProviderProfile(
                id = "filler-$index",
                name = "服务 $index",
                key = ProviderKeyFact(ProviderKeyStatus.NOT_CONFIGURED),
            )
        }
        val facts = ModelProviderFacts(profiles = decoys + secret)
        val state = ModelProviderScreenState.from(facts)
        val row = state.rows.single { it.id == "secret" }
        assertEquals(UiStrings.PROVIDER_KEY_SUFFIX.format("9f3a"), row.keySuffixLabel)
        val displays = state.rows.flatMap { view ->
            listOfNotNull(
                view.name,
                view.keyValue,
                view.keyHint,
                view.keySuffixLabel,
                view.modelLabel,
                view.endpointLabel,
            )
        }
        assertTrue("the full key is a state display field", displays.none { it.contains(fullKey) })
        assertTrue("the URL path leaked into a state field", displays.none { it.contains("://") })
        assertTrue("the URL path leaked into a state field", displays.none { it.contains("/v1") })

        show(facts)
        val rowTag = UiPageTags.PROVIDER_ROW_PREFIX + "secret"
        // Lazy proof: before scrolling, the secret row does not exist in the tree.
        compose.onAllNodesWithTag(rowTag).assertCountEquals(0)
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).performScrollToNode(hasTestTag(rowTag))
        compose.onNodeWithTag(rowTag).assertIsDisplayed()
        // The negative assertion runs on the composed tree, after the scroll.
        compose.onAllNodesWithText(fullKey, substring = true).assertCountEquals(0)
        // A partial leak (everything but the masked tail) is a leak too.
        compose.onAllNodesWithText(fullKey.dropLast(4), substring = true).assertCountEquals(0)
        compose.onNodeWithText(UiStrings.PROVIDER_KEY_SUFFIX.format("9f3a")).assertIsDisplayed()
        // No URL, full or partial, is rendered.
        compose.onAllNodesWithText("://api.example.com", substring = true).assertCountEquals(0)
        compose.onAllNodesWithText("user:pw", substring = true).assertCountEquals(0)
        compose.onAllNodesWithText("?token=abc", substring = true).assertCountEquals(0)
    }

    @Test
    fun `the masking and redaction helpers refuse to show more than a suffix`() {
        assertNull(maskKeySuffix(null))
        assertNull(maskKeySuffix(""))
        assertNull(maskKeySuffix("short"))
        assertNull(maskKeySuffix("1234567"))
        assertEquals("9f3a", maskKeySuffix(fullKey))
        assertEquals("9f3a", maskKeySuffix("  sk-1234-9f3a  "))

        assertEquals("api.example.com", redactEndpointHost("api.example.com"))
        assertEquals("api.example.com:8443", redactEndpointHost("https://" + "user:pw@" + "api.example.com:8443/v1"))
        assertNull(redactEndpointHost("ftp://api.example.com/v1"))
        assertNull(redactEndpointHost("not a host"))
        assertNull(redactEndpointHost(null))
    }

    // --------------------------------------------------------------- sequence

    @Test
    fun `the fold sequence is a pure function of the script`() {
        val facts = ModelProviderFacts(profiles = listOf(deepSeek, decoy()))
        val script = listOf(
            ModelProviderUiEvent.ToggleSection(ModelProviderScreenState.SERVICES_SECTION_ID),
            ModelProviderUiEvent.ToggleSection(ModelProviderScreenState.HELP_SECTION_ID),
            ModelProviderUiEvent.ToggleSection(ModelProviderScreenState.SERVICES_SECTION_ID),
        )
        var local = ModelProviderLocalState()
        val states = buildList {
            add(ModelProviderScreenState.from(facts, local))
            script.forEach { event ->
                local = local.apply(event)
                add(ModelProviderScreenState.from(facts, local))
            }
        }
        assertEquals(listOf(true, false, false, true), states.map { it.servicesExpanded })
        assertEquals(listOf(true, true, false, false), states.map { it.helpExpanded })
        // A fold changes visibility only: the row sequence never moves.
        assertEquals(1, states.map { it.rows }.distinct().size)
        assertEquals(SettingsDataPhase.READY, states.first().phase)

        var replay = ModelProviderLocalState()
        val replayed = buildList {
            add(ModelProviderScreenState.from(facts, replay))
            script.forEach { event ->
                replay = replay.apply(event)
                add(ModelProviderScreenState.from(facts, replay))
            }
        }
        assertEquals(states, replayed)
    }

    @Test
    fun `the live fold hides rows and brings them back`() {
        showLive(ModelProviderFacts(profiles = listOf(deepSeek)))
        compose.onNodeWithText("DeepSeek").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_SERVICES_SECTION).performClick()
        compose.onNodeWithText("DeepSeek").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.PROVIDER_HELP_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_SERVICES_SECTION).performClick()
        compose.onNodeWithText("DeepSeek").assertIsDisplayed()
        // The help group folds independently.
        compose.onNodeWithText(UiStrings.PROVIDER_PRIVACY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_HELP_SECTION).performClick()
        compose.onNodeWithText(UiStrings.PROVIDER_PRIVACY).assertDoesNotExist()
    }

    private fun decoy(): ProviderProfile = ProviderProfile(
        id = "backup",
        name = "备用服务",
        key = ProviderKeyFact(ProviderKeyStatus.NOT_CONFIGURED),
    )
}
