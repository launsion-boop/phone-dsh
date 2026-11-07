// Web-search page: the mode the page follows, the address, the key, when it applies.
// SPDX-License-Identifier: MIT
//
// The structure assertions follow the 2026-11-01 contract
// (`spec/ui/v1/pages/web-search-settings.json`): 用哪一份搜索 / 地址 / 密钥状态 /
// the untitled delete group / 什么时候生效 / 需要处理 / 还要知道. The point of the
// page is that a mode the host did not report is never drawn as "follow the
// model", and that neither the address nor the key is ever read back from the
// host: both are drafts whose commit the user controls.
//
// Every assertion below the fold scrolls the lazy list first: a LazyColumn item
// outside the viewport is not composed, so asserting before scrolling would be a
// false negative.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.SpecFixtures
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
import java.nio.file.Files

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class WebSearchSettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(
        facts: WebSearchFacts,
        onRetry: (() -> Unit)? = null,
        onModeChange: (WebSearchMode) -> Unit = {},
        onCommitKey: (String) -> Unit = {},
        onClearKey: () -> Unit = {},
        onRemoveConfiguration: () -> Unit = {},
        onStartEngine: () -> Unit = {},
        onStopEngine: () -> Unit = {},
    ) {
        val state = WebSearchScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                WebSearchSettingsPage(
                    state = state,
                    onToggle = {},
                    onSelectBackend = {},
                    onToggleBackends = {},
                    onBack = {},
                    onRetry = onRetry,
                    onModeChange = onModeChange,
                    onCommitKey = onCommitKey,
                    onClearKey = onClearKey,
                    onRemoveConfiguration = onRemoveConfiguration,
                    onStartEngine = onStartEngine,
                    onStopEngine = onStopEngine,
                )
            }
        }
    }

    private fun showLive(facts: WebSearchFacts) {
        compose.setContent {
            var local by remember { mutableStateOf(WebSearchLocalState()) }
            PdshTheme {
                WebSearchSettingsPage(
                    state = WebSearchScreenState.from(facts, local),
                    onToggle = {},
                    onSelectBackend = {},
                    onToggleBackends = { local = local.apply(WebSearchUiEvent.ToggleBackends) },
                    onBack = {},
                )
            }
        }
    }

    /**
     * Compose with facts the host can answer: after 保存密钥, a confirming host
     * applies [confirmFacts] (by default flipping [WebSearchFacts.hasCredential]
     * to `YES`); with [confirmCredential] false it never answers, so the draft
     * must stay in the field. [confirmFacts] is what lets a test model an
     * already-configured host acknowledging a replacement through a new key tail.
     */
    private fun showLiveCredential(
        facts: WebSearchFacts,
        confirmCredential: Boolean = true,
        onCommitKey: (String) -> Unit = {},
        confirmFacts: (WebSearchFacts) -> WebSearchFacts = {
            it.copy(hasCredential = FactState.YES)
        },
    ) {
        compose.setContent {
            var liveFacts by remember { mutableStateOf(facts) }
            PdshTheme {
                WebSearchSettingsPage(
                    state = WebSearchScreenState.from(liveFacts),
                    onToggle = {},
                    onSelectBackend = {},
                    onToggleBackends = {},
                    onBack = {},
                    onModeChange = {},
                    onCommitKey = { key ->
                        onCommitKey(key)
                        if (confirmCredential) {
                            liveFacts = confirmFacts(liveFacts)
                        }
                    },
                    onClearKey = {},
                    onRemoveConfiguration = {},
                )
            }
        }
    }

    /** Compose the lazy item whose text is [text], then leave it on screen. */
    private fun scrollTo(text: String) {
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasText(text))
    }

    private fun scrollToTag(tag: String) {
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasTestTag(tag))
    }

    // ------------------------------------------------------------------- mode

    @Test
    fun `the mode group is the page's first section and both modes are named`() {
        show(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL))
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_MODE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_FOLLOW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_API).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_FOLLOW_HINT).assertIsDisplayed()
        // The support line says 未知 rather than promising a search the host
        // never reported.
        scrollTo(UiStrings.WEB_SEARCH_FOLLOW_UNKNOWN)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_FOLLOW_UNKNOWN).assertIsDisplayed()
        // The address, the key and the delete row belong to the page's own service.
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_ADDRESS).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_KEY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_SERVICE).assertDoesNotExist()
    }

    @Test
    fun `picking the page's own service calls the host with the new mode`() {
        var picked: WebSearchMode? = null
        show(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL), onModeChange = { picked = it })
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_API).performClick()
        assertEquals(WebSearchMode.SEARCH_API, picked)
    }

    @Test
    fun `a model service without search says so instead of promising it`() {
        val supported = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, modelSearchSupported = FactState.YES),
        )
        assertEquals(UiStrings.WEB_SEARCH_FOLLOW_SUPPORTED, supported.followHint)
        val unsupported = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, modelSearchSupported = FactState.NO),
        )
        assertEquals(UiStrings.WEB_SEARCH_FOLLOW_UNSUPPORTED, unsupported.followHint)
        val missing = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, noModelProfile = true),
        )
        assertEquals(UiStrings.WEB_SEARCH_FOLLOW_NO_PROFILE, missing.followHint)
    }

    // ------------------------------------------------------- address and key

    @Test
    fun `the page's own service renders 地址, 密钥状态 and the untitled delete row`() {
        show(
            WebSearchFacts(
                mode = WebSearchMode.SEARCH_API,
                hasCredential = FactState.YES,
                keyTail = "sk-1234-9f3a",
            ),
        )
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_ADDRESS).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_ADDRESS_FOOTER)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_ADDRESS_FOOTER).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_SECTION_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_KEY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_KEY_LABEL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_KEY_STORED).assertIsDisplayed()
        // The tail is the last four characters, never the key.
        compose.onNodeWithText(UiStrings.WEB_SEARCH_KEY_TAIL.format("9f3a")).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_KEY_FOOTER)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_KEY_FOOTER).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_CLEAR_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_DELETE_SERVICE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_SERVICE).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_DELETE_FOOTER)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_FOOTER).assertIsDisplayed()
    }

    @Test
    fun `保存 is the only button and it only sends what was typed`() {
        var committed: String? = null
        show(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.NO),
            onCommitKey = { committed = it },
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
            .performTextInput("  " + "sk-" + "pasted" + "-9f3a  ")
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        assertEquals("sk-" + "pasted" + "-9f3a", committed)
    }

    @Test
    fun `the key field masks its draft and declares password semantics`() {
        val secret = "sk-" + "pasted" + "-9f3a"
        showLiveCredential(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.NO),
            confirmCredential = false,
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        compose.onAllNodesWithText(secret, substring = true).assertCountEquals(0)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Password))
    }

    @Test
    fun `a host-confirmed save clears the key draft and offers 清除密钥`() {
        val secret = "sk-" + "pasted" + "-9f3a"
        showLiveCredential(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.NO),
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        // The host now reports the key as configured: the draft has done its job.
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")),
        )
        scrollTo(UiStrings.WEB_SEARCH_CLEAR_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).assertIsDisplayed()
    }

    @Test
    fun `a save the host never confirms keeps the key draft`() {
        val secret = "sk-" + "pasted" + "-9f3a"
        showLiveCredential(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.NO),
            confirmCredential = false,
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        // The draft is still non-empty, so 保存密钥 stays enabled; dropping a
        // pasted credential the host never acknowledged would be worse.
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).assertIsEnabled()
        compose.onAllNodesWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).assertCountEquals(0)
    }

    @Test
    fun `an already-configured host that never answers keeps the replacement draft`() {
        val secret = "sk-" + "replacement" + "-7c2e"
        showLiveCredential(
            WebSearchFacts(
                mode = WebSearchMode.SEARCH_API,
                hasCredential = FactState.YES,
                keyTail = "sk-1234-9f3a",
            ),
            confirmCredential = false,
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        // The credential was already configured before the commit, so a yes that
        // was already there is not an acknowledgement of this replacement: the
        // masked draft (one bullet per character) must stay and 保存密钥 stay
        // enabled instead of silently losing the key the host never stored.
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.EditableText,
                AnnotatedString("•".repeat(secret.length)),
            ),
        )
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).assertIsEnabled()
    }

    @Test
    fun `an already-configured host acknowledges a replacement with a new key tail`() {
        val secret = "sk-" + "replacement" + "-7c2e"
        showLiveCredential(
            WebSearchFacts(
                mode = WebSearchMode.SEARCH_API,
                hasCredential = FactState.YES,
                keyTail = "sk-1234-9f3a",
            ),
            confirmFacts = { it.copy(keyTail = "sk-" + "replacement" + "-7c2e") },
        )
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        // A stored key's new tail is the host's observable acknowledgement that
        // this replacement landed, so the draft has done its job.
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")),
        )
    }

    @Test
    fun `a key the host reports as unknown is 未知, not 还没存`() {
        val state = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.UNKNOWN),
        )
        assertEquals(UiStrings.UNKNOWN, state.keyStatusLabel)
        assertFalse(state.hasCredential)
        val stored = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.YES),
        )
        assertTrue(stored.hasCredential)
        assertNull(stored.keyTailLabel)
    }

    // ------------------------------------------------------------- confirmations

    @Test
    fun `删除这个搜索服务 confirms with 删除 and only then removes`() {
        var removed = 0
        show(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API),
            onRemoveConfiguration = { removed += 1 },
        )
        scrollTo(UiStrings.WEB_SEARCH_DELETE_SERVICE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_SERVICE).performClick()
        // Nothing is removed until the alert is confirmed.
        assertEquals(0, removed)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_TEXT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE).performClick()
        assertEquals(1, removed)
    }

    @Test
    fun `清除密钥 confirms with 清除 and can be cancelled`() {
        var cleared = 0
        show(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.YES),
            onClearKey = { cleared += 1 },
        )
        scrollTo(UiStrings.WEB_SEARCH_CLEAR_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).performClick()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CANCEL).performClick()
        assertEquals(0, cleared)
        scrollTo(UiStrings.WEB_SEARCH_CLEAR_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).performClick()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR).performClick()
        assertEquals(1, cleared)
    }

    // ------------------------------------------------------------- when it applies

    @Test
    fun `什么时候生效 offers exactly the engine action that applies`() {
        var started = 0
        show(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, engineStarted = FactState.NO),
            onStartEngine = { started += 1 },
        )
        scrollTo(UiStrings.WEB_SEARCH_SECTION_APPLY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_APPLY).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_RESTART_HINT_IDLE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_RESTART_HINT_IDLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_STOP_ENGINE).assertDoesNotExist()
        scrollTo(UiStrings.WEB_SEARCH_START_ENGINE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_START_ENGINE).performClick()
        assertEquals(1, started)
    }

    @Test
    fun `a running engine stops instead of starting`() {
        var stopped = 0
        val state = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, engineStarted = FactState.YES),
        )
        assertTrue(state.canStopEngine)
        assertFalse(state.canStartEngine)
        assertEquals(UiStrings.WEB_SEARCH_RESTART_HINT_RUNNING, state.restartHint)
        show(
            WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, engineStarted = FactState.YES),
            onStopEngine = { stopped += 1 },
        )
        compose.onNodeWithText(UiStrings.WEB_SEARCH_START_ENGINE).assertDoesNotExist()
        scrollTo(UiStrings.WEB_SEARCH_STOP_ENGINE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_STOP_ENGINE).performClick()
        assertEquals(1, stopped)
    }

    // ------------------------------------------------------------------ warnings

    @Test
    fun `需要处理 is absent when the engine reported nothing`() {
        show(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL))
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_WARNING).assertDoesNotExist()
    }

    @Test
    fun `需要处理 renders the warning and the line that says it goes away`() {
        show(
            WebSearchFacts(
                mode = WebSearchMode.FOLLOW_MODEL,
                launchWarning = "本地引擎没有搜索能力",
            ),
        )
        scrollTo(UiStrings.WEB_SEARCH_SECTION_WARNING)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_WARNING).assertIsDisplayed()
        scrollTo("本地引擎没有搜索能力")
        compose.onNodeWithText("本地引擎没有搜索能力").assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_WARNING_TAIL)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_WARNING_TAIL).assertIsDisplayed()
    }

    // -------------------------------------------------------------------- notes

    @Test
    fun `还要知道 folds and unfolds from the live event`() {
        val contractPath = SpecFixtures.repoRoot.resolve("spec/ui/v1/pages/web-search-settings.json")
        val contract = JsonValue.parse(String(Files.readAllBytes(contractPath), Charsets.UTF_8)) as JsonObject
        val sections = (contract["sections"] as JsonArray).values.map { it as JsonObject }
        val notes = sections.single { (it["id"] as? JsonString)?.value == "还要知道" }
        val rows = (notes["rows"] as JsonArray).values.map { it as JsonObject }
        val note = rows.single {
            (it["provenance"] as? JsonString)?.value == "WebSearchSettingsPage.swift:313"
        }
        val expected = (note["label"] as JsonString).value
        val obsolete = "用模型服务自带的搜索时,抓网页这件事也归它管,这里不再单独设。"
        assertTrue("the current contract must reject the obsolete note", expected != obsolete)

        showLive(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL))
        scrollTo(UiStrings.WEB_SEARCH_SECTION_NOTES)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_NOTES).assertIsDisplayed()
        scrollTo(expected)
        compose.onNodeWithText(expected).assertIsDisplayed()
        compose.onNodeWithText(obsolete).assertDoesNotExist()
        scrollTo(UiStrings.WEB_SEARCH_SECTION_NOTES)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_NOTES).performClick()
        compose.onNodeWithText(expected).assertDoesNotExist()
        scrollTo(UiStrings.WEB_SEARCH_SECTION_NOTES)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SECTION_NOTES).performClick()
        scrollTo(expected)
        compose.onNodeWithText(expected).assertIsDisplayed()
        compose.onNodeWithText(obsolete).assertDoesNotExist()
    }

    @Test
    fun `the fold sequence is a pure function of the script`() {
        val facts = WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL)
        var local = WebSearchLocalState()
        val states = buildList {
            add(WebSearchScreenState.from(facts, local))
            repeat(2) {
                local = local.apply(WebSearchUiEvent.ToggleBackends)
                add(WebSearchScreenState.from(facts, local))
            }
        }
        assertEquals(listOf(true, false, true), states.map { it.notesExpanded })
        assertEquals(1, states.map { it.mode }.distinct().size)
        assertEquals(SettingsDataPhase.READY, states.first().phase)
    }

    // ------------------------------------------------------------------- failure

    @Test
    fun `a failed read keeps its red line and retries through the glyph`() {
        var retried = 0
        show(
            WebSearchFacts(failure = WebSearchFailureReason.KEY_UNREADABLE),
            onRetry = { retried += 1 },
        )
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_FAILURE_KEY).assertIsDisplayed()
        // The contract declares no retry label; the affordance is the glyph.
        compose.onNodeWithText("↻").performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `a read-only host keeps every control visible`() {
        val state = WebSearchScreenState.from(
            WebSearchFacts(mode = WebSearchMode.SEARCH_API, writable = FactState.NO),
        )
        assertFalse(state.canWrite)
        show(WebSearchFacts(mode = WebSearchMode.SEARCH_API, writable = FactState.NO))
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_API).assertIsDisplayed()
        scrollTo(UiStrings.WEB_SEARCH_DELETE_SERVICE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_SERVICE).assertIsDisplayed()
    }

    @Test
    fun `the page never renders a host address or key`() {
        // The facts carry no address and no key at all: both fields are drafts.
        show(
            WebSearchFacts(
                mode = WebSearchMode.SEARCH_API,
                hasCredential = FactState.YES,
                keyTail = "sk-1234-9f3a",
            ),
        )
        compose.onAllNodesWithText("api.deepseek.com", substring = true).assertCountEquals(1)
        compose.onAllNodesWithText("sk-1234-9f3a", substring = true).assertCountEquals(0)
    }
}
