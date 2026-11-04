// Model-provider page: four states, the fold sequence, the editor, and no key leak.
// SPDX-License-Identifier: MIT
//
// The structure assertions follow the 2026-11-01 contract
// (`spec/ui/v1/pages/model-provider-settings.json`): 服务 / the untitled action
// group (`添加模型服务`, `编辑默认服务`) / 生效方式, plus the editor's 模型目录 and
// 密钥. The security assertions are negative on purpose: a snapshot that carries
// a whole key and a whole URL is projected, and the test proves that neither the
// composed tree nor the state's display fields contain them.
// `performScrollToNode` runs before the negative assertion because a LazyColumn
// item outside the viewport is not composed; asserting before scrolling would be
// a false green.
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
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.activity.ComponentActivity
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshBackLevel
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
    val compose = createAndroidComposeRule<ComponentActivity>()

    /** Test-only key material; never asserted as a visible string. */
    private val fullKey: String = "sk-" + "test-only" + "-" + "never-render" + "-" + "9f3a"

    private val deepSeek = ProviderProfile(
        id = "deepseek",
        name = "DeepSeek",
        model = "deepseek-flash",
        endpoint = "https://" + "api.deepseek.com" + "/v1",
        key = ProviderKeyFact(ProviderKeyStatus.CONFIGURED, "sk-1234-9f3a"),
        selected = true,
        active = true,
    )

    private fun assertInlineTitle(text: String) {
        val title = compose.onNodeWithText(text).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val back = compose.onNodeWithContentDescription(UiStrings.BACK)
            .assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val density = compose.activity.resources.displayMetrics.density
        // Inline means the title shares the navigation row with Back/Cancel.
        // Robolectric's synthetic font metrics double CJK glyph height, so raw
        // text height is not an on-device typography measurement.
        assertEquals("$text belongs to the navigation bar", back.center.y, title.center.y, density)
    }

    private fun show(
        facts: ModelProviderFacts,
        onAdd: () -> Unit = {},
        onEdit: (String) -> Unit = {},
        onTest: (ProviderDraft) -> Unit = {},
        onSave: (ProviderDraft, String) -> Unit = { _, _ -> },
        onRetry: (() -> Unit)? = null,
        onStartEngine: () -> Unit = {},
        onDelete: (String) -> Unit = {},
        onSelect: (String) -> Unit = {},
        onGetModels: (ProviderDraft, String) -> Unit = { _, _ -> },
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
                    onStartEngine = onStartEngine,
                    onTest = onTest,
                    onSave = onSave,
                    onDelete = onDelete,
                    onSelect = onSelect,
                    onGetModels = onGetModels,
                )
            }
        }
    }

    @Test
    fun `connection test progress and failure stay inline without closing or replacing the editor draft`() {
        var testedDraft: ProviderDraft? = null
        val facts = mutableStateOf(ModelProviderFacts(profiles = emptyList()))
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(facts.value),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = {},
                    onBack = {},
                    onTest = { draft ->
                        testedDraft = draft
                        facts.value = facts.value.copy(
                            connectionTest = ProviderConnectionTestFact(
                                profileId = draft.id,
                                isNew = draft.isNew,
                                isTesting = true,
                            ),
                        )
                    },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        val nameField = compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}")
        // The source keeps Test disabled until the new provider has a name, URL,
        // model and valid model row; fill the required name before exercising it.
        nameField.performTextInput("测试服务")
        compose.onNodeWithTag("pdsh.provider.advanced").performScrollTo().performClick()
        compose.onNodeWithTag("pdsh.provider.test").performScrollTo().assertIsEnabled().performClick()
        assertTrue(requireNotNull(testedDraft).isNew)
        compose.onNodeWithText(UiStrings.PROVIDER_TESTING).performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        compose.onNodeWithText("测试服务").performScrollTo().assertIsDisplayed()

        // The host publishes only a safe result fact. Recomposition must retain
        // the inline editor and its typed draft; the key field is never replaced
        // by the host's result payload.
        compose.runOnIdle {
            facts.value = facts.value.copy(
                connectionTest = ProviderConnectionTestFact(
                    profileId = "",
                    isNew = true,
                    isTesting = false,
                    succeeded = false,
                    message = "密钥被服务拒绝（HTTP 401）。",
                ),
            )
        }
        compose.onNodeWithTag("pdsh.provider.test-result").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("密钥被服务拒绝（HTTP 401）。").assertIsDisplayed()
        nameField.performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("测试服务").assertIsDisplayed()
    }

    /** A live host: the fold and the row callbacks update the projected state. */
    private fun showLive(facts: ModelProviderFacts) {
        compose.setContent {
            var local by remember { mutableStateOf(ModelProviderLocalState()) }
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(facts, local),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = { id -> local = local.apply(ModelProviderUiEvent.ToggleSection(id)) },
                    onBack = {},
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty snapshot shows the empty state inside the service group`() {
        show(ModelProviderFacts(profiles = emptyList()))
        assertInlineTitle(UiStrings.MODEL_PROVIDER_TITLE)
        compose.onNodeWithTag(UiPageTags.PROVIDER_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_EMPTY_HINT).assertIsDisplayed()
        // The contract's untitled action group stays reachable with no rows.
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithText(UiStrings.PROVIDER_ADD_SERVICE).assertIsDisplayed()
    }

    @Test
    fun `a configured service renders its model, redacted host and key suffix`() {
        var added = 0
        show(
            ModelProviderFacts(profiles = listOf(deepSeek)),
            onAdd = { added += 1 },
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
        // The row's own actions: the contract's 编辑 / 删除.
        compose.onNodeWithText(UiStrings.PROVIDER_EDIT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE).assertIsDisplayed()
        // 添加模型服务 is the untitled group's criterion row.
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        assertEquals(1, added)
    }

    @Test
    fun `saved next-launch default is not marked as the active provider`() {
        val active = deepSeek.copy(selected = false, active = true)
        val next = ProviderProfile(
            id = "next",
            name = "Next service",
            model = "next-model",
            endpoint = "https://next.example.test/v1",
            key = ProviderKeyFact(ProviderKeyStatus.NOT_CONFIGURED),
            selected = true,
            active = false,
        )
        val facts = ModelProviderFacts(profiles = listOf(active, next), engineStarted = FactState.YES)
        val state = ModelProviderScreenState.from(facts)
        assertTrue(state.rows.first { it.id == "deepseek" }.active == true)
        assertFalse(state.rows.first { it.id == "deepseek" }.selected)
        assertTrue(state.rows.first { it.id == "next" }.selected)
        assertFalse(state.rows.first { it.id == "next" }.active == true)
        assertTrue(state.restartHint.contains("重新打开 App"))

        show(facts)
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "next"))
        compose.onNodeWithText("下次默认").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DEFAULT).assertDoesNotExist()
    }

    @Test
    fun `the apply footer renders only its hint and start action`() {
        var started = 0
        show(
            ModelProviderFacts(profiles = listOf(deepSeek), engineStarted = FactState.NO),
            onStartEngine = { started += 1 },
        )
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_APPLY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasText(PROVIDER_APPLY_HINT_STOPPED))
        compose.onNodeWithText(PROVIDER_APPLY_HINT_STOPPED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasText(UiStrings.PROVIDER_START_ENGINE))
        compose.onNodeWithText(UiStrings.PROVIDER_START_ENGINE).performClick()
        assertEquals(1, started)
    }

    @Test
    fun `empty page footer is neutral and does not claim a save already happened`() {
        val state = ModelProviderScreenState.from(
            ModelProviderFacts(profiles = emptyList(), engineStarted = FactState.NO),
        )
        assertEquals(PROVIDER_APPLY_HINT_STOPPED, state.restartHint)
        assertFalse(state.restartHint.contains("已保存"))
        assertFalse(state.restartHint.contains("环境"))
        show(ModelProviderFacts(profiles = emptyList(), engineStarted = FactState.NO))
        compose.onNodeWithText(PROVIDER_APPLY_HINT_STOPPED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_APPLY).assertDoesNotExist()
    }

    @Test
    fun `a running engine swaps the hint and hides the start action`() {
        val state = ModelProviderScreenState.from(
            ModelProviderFacts(profiles = listOf(deepSeek), engineStarted = FactState.YES),
        )
        assertEquals(PROVIDER_APPLY_HINT_RUNNING, state.restartHint)
        assertFalse(state.canStartEngine)
        assertEquals(
            PROVIDER_APPLY_HINT_STOPPED,
            ModelProviderScreenState(phase = SettingsDataPhase.READY).restartHint,
        )
        show(ModelProviderFacts(profiles = listOf(deepSeek), engineStarted = FactState.YES))
        compose.onNodeWithText(UiStrings.PROVIDER_START_ENGINE).assertDoesNotExist()
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
        // The contract declares no retry label; the affordance is the glyph.
        compose.onNodeWithText("↻").performClick()
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

    @Test
    fun `a service the host never named wears the page's own label`() {
        val unnamed = ProviderProfile(id = "blank", name = "   ")
        val state = ModelProviderScreenState.from(ModelProviderFacts(profiles = listOf(unnamed)))
        assertTrue(state.rows.single().nameIsFallback)
        assertEquals(UiStrings.MODEL_PROVIDER_TITLE, state.rows.single().name)
        show(ModelProviderFacts(profiles = listOf(unnamed)))
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "blank"))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ROW_PREFIX + "blank").assertIsDisplayed()
        // The title and the unnamed row both say 模型服务.
        compose.onAllNodesWithText(UiStrings.MODEL_PROVIDER_TITLE).assertCountEquals(2)
    }

    // ------------------------------------------------------------------ editor

    @Test
    fun `next launch selection does not claim to be the active provider`() {
        val active = deepSeek.copy(selected = false, active = true)
        val next = ProviderProfile(
            id = "next",
            name = "Next service",
            model = "next-model",
            endpoint = "https://next.example.test/v1",
            key = ProviderKeyFact(ProviderKeyStatus.NOT_CONFIGURED),
            selected = true,
            active = false,
        )
        val facts = ModelProviderFacts(profiles = listOf(active, next), engineStarted = FactState.YES)
        val state = ModelProviderScreenState.from(facts)
        assertTrue(state.rows.first { it.id == "deepseek" }.active == true)
        assertFalse(state.rows.first { it.id == "deepseek" }.selected)
        assertTrue(state.rows.first { it.id == "next" }.selected)
        assertFalse(state.rows.first { it.id == "next" }.active == true)
        assertTrue(state.restartHint.contains("重新打开 App"))

        show(facts)
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "next"))
        compose.onNodeWithText("下次默认").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DEFAULT).assertDoesNotExist()
    }

    @Test
    fun `添加模型服务 keeps connection fields on editor and pushes advanced settings`() {
        show(ModelProviderFacts(profiles = emptyList()))
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertDoesNotExist()
        assertInlineTitle(UiStrings.PROVIDER_ADD_SERVICE)
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_CONNECTION).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_FIELD_NAME).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_API_URL).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_IMPORT_CLIPBOARD).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MODEL_LABEL).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_FETCH).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DEFAULT_MODEL).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_MODEL_ID).assertDoesNotExist()

        compose.onNodeWithTag("pdsh.provider.advanced").performScrollTo().performClick()
        assertInlineTitle(UiStrings.PROVIDER_ADVANCED)
        compose.onNodeWithText(UiStrings.PROVIDER_ADVANCED_SECTION).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_REASONING_EFFORT).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_MODEL_ID).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_TEXT_INPUT).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_IMAGE_INPUT).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_MODEL).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_ADD_MODEL).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_KEY_CONNECTION).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_TEST_CONNECTION).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.SAVE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CANCEL).assertDoesNotExist()
    }

    @Test
    fun `advanced editor pushes a real back bar from an embedded settings tab`() {
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(ModelProviderFacts(profiles = emptyList())),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = {},
                    onBack = {},
                    embedded = true,
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        compose.onNodeWithTag("pdsh.provider.advanced").performScrollTo().performClick()
        compose.onNodeWithText(UiStrings.PROVIDER_ADVANCED).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).assertIsDisplayed()
    }

    @Test
    fun `system back consumes advanced then editor before the route`() {
        var routeBackCount = 0
        val backLevel = PdshBackLevel()
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(ModelProviderFacts(profiles = emptyList())),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = {},
                    onBack = { routeBackCount++ },
                    backLevel = backLevel,
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        compose.waitForIdle()
        assertTrue(backLevel.available)

        compose.onNodeWithTag("pdsh.provider.advanced").performScrollTo().performClick()
        compose.onNodeWithText(UiStrings.PROVIDER_ADVANCED).assertIsDisplayed()
        compose.runOnIdle { assertTrue(backLevel.consume()) }
        compose.onNodeWithText(UiStrings.PROVIDER_ADD_SERVICE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_CONNECTION).assertIsDisplayed()

        compose.runOnIdle { assertTrue(backLevel.consume()) }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertIsDisplayed()
        compose.runOnIdle { assertFalse(backLevel.available) }
        assertEquals(0, routeBackCount)
    }

    @Test
    fun `the API key field is a password field and never the generic text field`() {
        show(ModelProviderFacts(profiles = listOf(deepSeek)))
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek"))
        compose.onNodeWithText(UiStrings.PROVIDER_EDIT).performClick()
        val keyField = compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_KEY_FIELD_REPLACE}")
        keyField.performScrollTo().assertIsDisplayed()
        keyField.assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Password))
    }

    @Test
    fun `tapping a service selects it while the edit action opens the editor`() {
        var selected: String? = null
        var edited: String? = null
        show(
            ModelProviderFacts(profiles = listOf(deepSeek)),
            onSelect = { selected = it },
            onEdit = { edited = it },
        )
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek"))
        compose.onNodeWithText("DeepSeek").performClick()
        assertEquals("deepseek", selected)
        assertNull(edited)
        compose.onNodeWithText(UiStrings.PROVIDER_EDIT).performClick()
        assertEquals("deepseek", edited)
    }

    @Test
    fun `the editor's cancel returns to the service list`() {
        show(ModelProviderFacts(profiles = listOf(deepSeek)))
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        compose.onNodeWithText(UiStrings.CANCEL).performClick()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}").assertDoesNotExist()
    }

    @Test
    fun `failed save keeps the exact editor draft and shows the host reason inline`() {
        var submitted: ProviderDraft? = null
        var requestId: String? = null
        val facts = mutableStateOf(ModelProviderFacts(profiles = emptyList()))
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(facts.value),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = {},
                    onBack = {},
                    onSave = { draft, id ->
                        submitted = draft
                        requestId = id
                        facts.value = facts.value.copy(
                            providerSave = ProviderSaveFact(
                                requestId = id,
                                profileId = draft.id,
                                isNew = draft.isNew,
                                isSaving = true,
                            ),
                        )
                    },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        val nameField = compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}")
        nameField.performTextInput("用户服务")
        compose.onNodeWithText(UiStrings.SAVE).performClick()
        assertEquals("用户服务", submitted?.name)
        assertTrue(requestId?.isNotBlank() == true)
        compose.onNodeWithText("保存中…").assertIsDisplayed()

        compose.runOnIdle {
            val draft = requireNotNull(submitted)
            facts.value = facts.value.copy(
                providerSave = ProviderSaveFact(
                    requestId = requireNotNull(requestId),
                    profileId = draft.id,
                    isNew = draft.isNew,
                    isSaving = false,
                    succeeded = false,
                    message = "本机存储不可写，本次未保存",
                ),
            )
        }
        compose.onNodeWithTag("pdsh.provider.save-result").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("本机存储不可写，本次未保存").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CANCEL).assertIsDisplayed()
        nameField.performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("用户服务").assertIsDisplayed()
    }

    @Test
    fun `successful provider save closes only the matching editor request`() {
        val facts = mutableStateOf(ModelProviderFacts(profiles = emptyList()))
        compose.setContent {
            PdshTheme {
                ModelProviderSettingsPage(
                    state = ModelProviderScreenState.from(facts.value),
                    onAdd = {},
                    onEdit = {},
                    onToggleSection = {},
                    onBack = {},
                    onSave = { draft, requestId ->
                        facts.value = facts.value.copy(
                            providerSave = ProviderSaveFact(
                                requestId = requestId,
                                profileId = if (draft.isNew) "generated-profile" else draft.id,
                                isNew = draft.isNew,
                                isSaving = false,
                                succeeded = true,
                                message = "已保存到本机",
                            ),
                        )
                    },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ADD))
        compose.onNodeWithTag(UiPageTags.PROVIDER_ADD).performClick()
        compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}")
            .performTextInput("新服务")
        compose.onNodeWithText(UiStrings.SAVE).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.provider.field.${UiStrings.PROVIDER_FIELD_NAME}").assertDoesNotExist()
    }

    // ----------------------------------------------------------------- delete

    @Test
    fun `the delete confirmation carries the row's name, as the baseline formats it`() {
        var deleted: String? = null
        show(ModelProviderFacts(profiles = listOf(deepSeek)), onDelete = { deleted = it })
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek"))
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE).performClick()
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_CONFIRM_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_CONFIRM_TEXT).assertIsDisplayed()
        // `删除 %@` with the service's name: the formatted copy, not the template.
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_NAMED.format("DeepSeek")).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_NAMED.format("DeepSeek")).performClick()
        assertEquals("deepseek", deleted)
    }

    @Test
    fun `the delete confirmation can be cancelled`() {
        var deleted: String? = null
        show(ModelProviderFacts(profiles = listOf(deepSeek)), onDelete = { deleted = it })
        compose.onNodeWithTag(UiPageTags.PROVIDER_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROVIDER_ROW_PREFIX + "deepseek"))
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE).performClick()
        compose.onNodeWithText(UiStrings.CANCEL).performClick()
        assertNull(deleted)
        compose.onNodeWithText(UiStrings.PROVIDER_DELETE_CONFIRM_TITLE).assertDoesNotExist()
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

    // ------------------------------------------------------------------ draft

    @Test
    fun `a new draft starts from the adapter's documented defaults`() {
        val draft = ProviderDraft.new()
        assertTrue(draft.isNew)
        assertEquals(ProviderDraft.DEFAULT_ENDPOINT, draft.endpoint)
        assertEquals(ProviderDraft.DEFAULT_MODEL, draft.model)
        // Saving needs a display name first; the URL is already the default one.
        assertFalse(draft.canSave)
        assertTrue(draft.copy(name = "DeepSeek").canSave)
        assertEquals(UiStrings.PROVIDER_PROTOCOL_ANTHROPIC, draft.protocolHint)
        // The key is not a fact: a new draft starts empty.
        assertEquals("", draft.apiKey)
    }

    @Test
    fun `an existing draft never reads the stored endpoint or key back`() {
        val state = ModelProviderScreenState.from(ModelProviderFacts(profiles = listOf(deepSeek)))
        val draft = ProviderDraft.from(state.rows.single())
        assertFalse(draft.isNew)
        assertEquals("DeepSeek", draft.name)
        assertEquals("deepseek-flash", draft.model)
        assertEquals("", draft.endpoint)
        assertEquals("", draft.apiKey)
        assertTrue(draft.canSave)
    }

    // --------------------------------------------------------------- sequence

    @Test
    fun `the fold sequence is a pure function of the script`() {
        val facts = ModelProviderFacts(profiles = listOf(deepSeek, decoy()))
        val script = listOf(
            ModelProviderUiEvent.ToggleSection(ModelProviderScreenState.SERVICES_SECTION_ID),
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
        assertEquals(listOf(true, false, true), states.map { it.servicesExpanded })
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

    /**
     * L74: the 服务 header is a plain label, and the rows below it are always
     * drawn.
     *
     * The baseline's header is `Text("服务")` on a Section with no disclosure
     * (`ModelProviderSettingsPage.swift:85-86`), and its row list is not foldable.
     * The Android page used to draw `⌄ 服务 … 1 项`, which is a control iOS does
     * not have — so the header must not react to a tap and the row must stay.
     */
    @Test
    fun `the services header is a plain label and never folds the rows away`() {
        showLive(ModelProviderFacts(profiles = listOf(deepSeek)))
        compose.onNodeWithText("DeepSeek").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROVIDER_SERVICES_SECTION).performClick()
        compose.onNodeWithText("DeepSeek").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_SECTION_APPLY).assertDoesNotExist()
    }

    private fun decoy(): ProviderProfile = ProviderProfile(
        id = "backup",
        name = "备用服务",
        key = ProviderKeyFact(ProviderKeyStatus.NOT_CONFIGURED),
    )
}
