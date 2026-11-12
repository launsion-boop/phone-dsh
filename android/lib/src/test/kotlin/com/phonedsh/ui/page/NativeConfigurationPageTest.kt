// NativeConfigurationPage: four states, the plugin-inventory unknown rule and folds.
// SPDX-License-Identifier: MIT
//
// The unmeasured plugin list is located with `performScrollToNode` before the
// test asserts that no `0 个条目` was invented: the section is a lazy item and
// starts collapsed, so a bare absence assertion would be about the window, not
// about the page.
package com.phonedsh.ui.page

import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.sheet.SheetDetents
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class NativeConfigurationPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun fullFacts(): ConfigurationFacts = ConfigurationFacts(
        snapshot = ConfigurationSnapshot(
            sessionTitle = "修复登录",
            settingsWritable = FactState.YES,
            groups = listOf(
                ConfigurationGroup(
                    namespace = "agent-loop",
                    title = "自动执行轮次",
                    detail = "控制自动执行的轮次上限",
                    writable = FactState.YES,
                    revision = 1,
                    fields = listOf(
                        ConfigurationField(
                            id = "maxTurns",
                            title = "最大轮次",
                            value = "12",
                            detail = "超过后停止自动执行",
                        ),
                        ConfigurationField(
                            id = "autoContinue",
                            title = "自动继续",
                            value = "关闭",
                        ),
                    ),
                ),
                ConfigurationGroup(
                    namespace = "bash-sandbox",
                    title = "终端",
                    detail = "命令在沙箱里执行",
                    writable = FactState.NO,
                    revision = 1,
                    fields = listOf(
                        ConfigurationField(id = "sandbox", title = "沙箱", value = "开启"),
                        ConfigurationField(id = "network", title = "网络", value = "白名单"),
                    ),
                ),
                ConfigurationGroup(
                    namespace = "subagent",
                    title = "子 Agent",
                    detail = "子任务使用的默认设置",
                    writable = FactState.YES,
                    revision = 1,
                    fields = listOf(
                        ConfigurationField(id = "enabled", title = "启用", value = "开启"),
                    ),
                ),
            ),
            permissionModes = listOf(
                ConfigurationPermissionMode(id = "standard", name = "标准", detail = "每次询问"),
                ConfigurationPermissionMode(id = "full", name = "完全", detail = "不询问"),
            ),
            defaultPermissionModeId = "standard",
            permissionRevision = 1,
            plugins = listOf(
                ConfigurationPlugin(
                    id = "loader",
                    module = "@deepseek-ai/dsh-loader",
                    enabled = FactState.YES,
                    phase = "active",
                ),
                ConfigurationPlugin(
                    id = "shell",
                    module = "@deepseek-ai/dsh-shell",
                    enabled = FactState.NO,
                    phase = "disabled",
                ),
            ),
            experimentalPlugins = listOf(
                ConfigurationExperimentalPlugin(
                    id = "agent-team",
                    title = "智能体团队",
                    status = "Worker 当前已加载 · active",
                    loaded = FactState.YES,
                ),
                ConfigurationExperimentalPlugin(
                    id = "voice-input",
                    title = "语音输入",
                    status = "Worker 未加载",
                    loaded = FactState.NO,
                ),
            ),
            pluginManagementMessage = "插件可查看；安装和启用需在桌面 DSH 管理。",
        ),
    )

    private fun show(
        state: ConfigurationScreenState,
        onDone: () -> Unit = {},
        onRefresh: (() -> Unit)? = null,
        onOpenWebSearch: (() -> Unit)? = null,
        onOpenPluginInventory: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
        onSaveGroup: ((String) -> Unit)? = null,
        onDiscardGroup: ((String) -> Unit)? = null,
        onResetField: ((String, String) -> Unit)? = null,
        onPickDefaultPermission: (() -> Unit)? = null,
        onSaveDefaultPermission: (() -> Unit)? = null,
        onDiscardDefaultPermission: (() -> Unit)? = null,
        onSaveGroupDrafts: ((String, Map<String, String>) -> Unit)? = null,
        onApplyDefaultPermission: ((String) -> Unit)? = null,
        onConfigurationWrite: (suspend (ConfigurationWriteRequest) -> ConfigurationWriteReceipt)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                NativeConfigurationPage(
                    state = state,
                    onDone = onDone,
                    onRefresh = onRefresh,
                    onToggleSection = {},
                    onOpenWebSearch = onOpenWebSearch,
                    onOpenPluginInventory = onOpenPluginInventory,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                    onSaveGroup = onSaveGroup,
                    onDiscardGroup = onDiscardGroup,
                    onResetField = onResetField,
                    onPickDefaultPermission = onPickDefaultPermission,
                    onSaveDefaultPermission = onSaveDefaultPermission,
                    onDiscardDefaultPermission = onDiscardDefaultPermission,
                    onSaveGroupDrafts = onSaveGroupDrafts,
                    onApplyDefaultPermission = onApplyDefaultPermission,
                    onConfigurationWrite = onConfigurationWrite,
                )
            }
        }
    }

    /** A host that applies the fold events, so the disclosure really moves. */
    private fun showLive(
        facts: ConfigurationFacts,
        onOpenPluginInventory: (() -> Unit)? = null,
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(ConfigurationLocalState()) }
            PdshTheme {
                NativeConfigurationPage(
                    state = ConfigurationScreenState.from(facts, local),
                    onDone = {},
                    onToggleSection = { id ->
                        local = local.apply(ConfigurationUiEvent.ToggleSection(id))
                    },
                    onOpenPluginInventory = onOpenPluginInventory,
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty snapshot shows the source-owned configuration sections`() {
        val state = ConfigurationScreenState.from(
            ConfigurationFacts(snapshot = ConfigurationSnapshot()),
        )
        assertEquals(ConfigurationStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertEquals(4, state.sections.count { ConfigurationScreenState.isGroupSection(it.id) })
        assertTrue(state.webSearchRow != null)
        show(state)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_COUNT.format(0))
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SESSION).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_WRITABLE).assertDoesNotExist()
    }

    @Test
    fun `a measured snapshot renders settings, permissions and the plugin inventory`() {
        val state = ConfigurationScreenState.from(fullFacts())
        assertEquals(ConfigurationStatus.READY, state.status)
        assertEquals("修复登录", state.sessionTitle)
        assertEquals(UiStrings.CONFIGURATION_WRITABLE_YES, state.writableValue)
        assertEquals(
            listOf(
                ConfigurationScreenState.groupSectionId("subagent"),
                ConfigurationScreenState.groupSectionId("subagent-model-selection-settings"),
                ConfigurationScreenState.groupSectionId("agent-loop"),
                ConfigurationScreenState.groupSectionId("bash-sandbox"),
                ConfigurationScreenState.EXPERIMENTAL_SECTION_ID,
                ConfigurationScreenState.INSTALLED_SECTION_ID,
            ),
            state.sections.map { it.id },
        )
        assertEquals("标准", state.permission.selected?.name)
        assertTrue(state.permission.isUnknown.not())
        assertTrue(state.builtInExpanded)
        assertFalse(state.aboutExpanded)
        assertFalse(state.hasUnmeasuredValues)
        var done = 0
        var webSearch = 0
        show(
            state,
            onDone = { done += 1 },
            onOpenWebSearch = { webSearch += 1 },
        )

        compose.onNodeWithText(UiStrings.CONFIGURATION_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INTRO).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SESSION).assertDoesNotExist()
        compose.onNodeWithText("修复登录").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_WRITABLE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_WEB_SEARCH))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_WEB_SEARCH).performClick()
        assertEquals(1, webSearch)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_ROOT + ".back").performClick()
        assertEquals(1, done)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText("最大轮次"))
        compose.onNodeWithText("最大轮次").assertIsDisplayed()
        compose.onNodeWithText("12").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_INSTALLED))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_INSTALLED).assertIsDisplayed()
    }

    @Test
    fun `a missing built-in namespace shows the source unavailable fallback`() {
        val state = ConfigurationScreenState.from(fullFacts())
        val missing = state.sections.first {
            it.id == ConfigurationScreenState.groupSectionId("subagent-model-selection-settings")
        }
        assertTrue(missing.unavailable)
        assertEquals("子 Agent 模型", missing.title)
        assertEquals("暂不可用", missing.rows.single().title)
        assertTrue(missing.rows.single().subtitle!!.contains("不支持"))

        show(state)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(
                UiPageTags.CONFIGURATION_SECTION_PREFIX + missing.id,
            ))
        compose.onNodeWithText("子 Agent 模型").assertIsDisplayed()
        compose.onAllNodesWithText("暂不可用")[0].assertIsDisplayed()
    }

    @Test
    fun `a failed read shows its source error before the configuration sections`() {
        val state = ConfigurationScreenState.from(fullFacts().copy(failure = "设置写入冲突"))
        assertEquals(ConfigurationStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertTrue(state.sections.any { it.id == ConfigurationScreenState.groupSectionId("subagent") })
        assertEquals("设置写入冲突", state.failure)
        var retried = 0
        show(
            state,
            onRefresh = { retried += 1 },
        )

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_FAILURE).assertIsDisplayed()
        compose.onNodeWithText("设置写入冲突").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_REFRESH).assertIsDisplayed().performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `an unreported snapshot keeps source sections and no generic unknown summary`() {
        val state = ConfigurationScreenState.from(ConfigurationFacts())
        assertEquals(ConfigurationStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertTrue(state.sections.any { it.id == ConfigurationScreenState.groupSectionId("subagent") })
        show(state)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText("子 Agent"))
        compose.onNodeWithText("子 Agent").assertIsDisplayed()
        compose.onAllNodesWithText("暂不可用")[0].assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_UNKNOWN_STATE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_COUNT.format(0))
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_WRITABLE_YES).assertDoesNotExist()
    }

    @Test
    fun `an unreadable plugin inventory says unknown, never zero entries`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot).copy(plugins = null)
        val state = ConfigurationScreenState.from(facts.copy(snapshot = snapshot))
        assertEquals(ConfigurationStatus.READY, state.status)
        val installed = state.sections.first {
            it.id == ConfigurationScreenState.INSTALLED_SECTION_ID
        }
        assertEquals(UiStrings.UNKNOWN, installed.trailing)
        assertEquals(UiStrings.CONFIGURATION_INSTALLED_UNKNOWN, installed.emptyText)
        showLive(facts.copy(snapshot = snapshot))

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_INSTALLED))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_INSTALLED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_COUNT.format(0))
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `the loaded plugin row opens its inventory subpage`() {
        var opens = 0
        showLive(fullFacts(), onOpenPluginInventory = { opens += 1 })

        val inventoryTag = UiPageTags.CONFIGURATION_INSTALLED
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(inventoryTag))
        compose.onNodeWithTag(inventoryTag).assertIsDisplayed().performClick()
        assertEquals(1, opens)
        compose.onNodeWithText("@deepseek-ai/dsh-loader").assertDoesNotExist()
    }

    @Test
    fun `the loaded plugin row is disabled explicitly without an inventory route`() {
        showLive(fullFacts())
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_INSTALLED))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_INSTALLED).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.UNAVAILABLE).assertIsDisplayed()
    }

    @Test
    fun `插件说明 opens its modal sheet with the source content`() {
        showLive(fullFacts())

        // Source-only explanatory content must not be mixed into the page list.
        compose.onNodeWithText(UiStrings.CONFIGURATION_SCOPE_SECTION).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PLUGIN_INFO_ACTION).performClick()

        compose.waitForIdle()
        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_SHEET_TAG).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_PLUGIN_INFO).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SCOPE_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SCOPE_TEXT).assertIsDisplayed()
        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_LIST_TAG)
            .performScrollToNode(hasText(UiStrings.CONFIGURATION_LIMITS_SECTION))
        compose.onNodeWithText(UiStrings.CONFIGURATION_LIMITS_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_LIST_TAG)
            .performScrollToNode(hasText(UiStrings.CONFIGURATION_ONLY_LOADED_TEXT))
        compose.onNodeWithText(UiStrings.CONFIGURATION_ONLY_LOADED_TEXT).assertIsDisplayed()
    }

    @Test
    fun `插件说明 Done invokes the semantic dismissal callback`() {
        var dismissals = 0
        compose.setContent {
            PdshTheme {
                ConfigurationPluginInformationSheet(
                    managementMessage = "插件仅能在桌面 DSH 安装。",
                    onDone = { dismissals += 1 },
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_DONE_TAG)
            .assertIsDisplayed()
            .assertHasClickAction()
            .performSemanticsAction(SemanticsActions.OnClick)
        // 完成 leaves through the shared sheet's platform hide.
        compose.waitUntil(timeoutMillis = 5_000) { dismissals == 1 }
        assertEquals(1, dismissals)
    }

    @Test
    fun `plugin info sheet uses the frozen detents and system back dismisses it`() {
        // The page id, not a local detent choice. Scrim tap and drag-down stay
        // device-only; Robolectric does not route touches into the sheet window.
        assertEquals(TokenDetentSetId.MEDIUM_LARGE, SheetDetents.forPage("configurationInfo"))
        assertEquals(
            listOf(TokenDetent.MEDIUM, TokenDetent.LARGE),
            SheetDetents.detents(SheetDetents.forPage("configurationInfo")),
        )

        showLive(fullFacts())
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PLUGIN_INFO_ACTION).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_SHEET_TAG).assertIsDisplayed()

        pressBackAndSettle()

        compose.onNodeWithTag(CONFIGURATION_PLUGIN_INFO_SHEET_TAG).assertDoesNotExist()
    }

    @Test
    fun `configuration groups are static sections and inventory stays outside them`() {
        var opens = 0
        showLive(fullFacts(), onOpenPluginInventory = { opens += 1 })
        val agentHeader = UiPageTags.CONFIGURATION_SECTION_PREFIX +
            ConfigurationScreenState.groupSectionId("agent-loop")
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(agentHeader))
        compose.onNodeWithTag(agentHeader).assertIsDisplayed().assertHasNoClickAction()
        compose.onNodeWithText(UiStrings.CONFIGURATION_BUILT_IN_SECTION).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SESSION).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_WRITABLE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText("工具"))
        compose.onNodeWithText("工具").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION).assertExists()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_INSTALLED))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_INSTALLED).assertIsDisplayed().performClick()
        assertEquals(1, opens)
    }

    @Test
    fun `the page does not invent a plugin-add menu absent from the source`() {
        showLive(fullFacts())

        compose.onNodeWithText(UiStrings.CONFIGURATION_ADD_DISABLED).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_ADD_PLUGIN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALL_THIRD_PARTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_CREATE_WITH_AGENT).assertDoesNotExist()
    }

    @Test
    fun `an unread permission catalog says unknown and shows no save pair`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot).copy(
            permissionModes = null,
            defaultPermissionModeId = null,
        )
        val state = ConfigurationScreenState.from(facts.copy(snapshot = snapshot))
        assertTrue(state.permission.isUnknown)
        assertTrue(state.hasUnmeasuredValues)
        show(state)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION))
        compose.onNodeWithText(UiStrings.CONFIGURATION_PERMISSION_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertDoesNotExist()
    }

    @Test
    fun `the permission row and its save pair arm only with a host write`() {
        var picked = 0
        var saved = 0
        var discarded = 0
        show(
            ConfigurationScreenState.from(fullFacts()),
            onPickDefaultPermission = { picked += 1 },
            onSaveDefaultPermission = { saved += 1 },
            onDiscardDefaultPermission = { discarded += 1 },
        )

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION_ROW))
        compose.onNodeWithText(UiStrings.CONFIGURATION_DEFAULT_PERMISSION_ROW)
            .assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_DISCARD).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_ROW).performClick()
        assertEquals(1, picked)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_DISCARD).assertDoesNotExist()
        assertEquals(0, saved)
        assertEquals(0, discarded)
    }

    @Test
    fun `a startup-locked default permission shows the reason and arms no selector`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot).copy(
            defaultPermissionWritable = false,
            defaultPermissionReadOnlyReason = UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON,
        )
        var picked = 0
        val state = ConfigurationScreenState.from(facts.copy(snapshot = snapshot))
        assertFalse(state.permission.writable)
        show(
            state,
            onPickDefaultPermission = { picked += 1 },
            onConfigurationWrite = { request ->
                ConfigurationWriteReceipt(request.requestId, success = true)
            },
        )

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_ROW).assertHasNoClickAction()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_READ_ONLY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON, substring = true)
            .assertIsDisplayed()
        compose.onNodeWithTag("pdsh.configuration.permission-option.full").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_DISCARD).assertDoesNotExist()
        compose.runOnIdle { assertEquals(0, picked) }
    }

    @Test
    fun `an overridden field reset uses the confirmed writer instead of a legacy callback`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot)
        val groups = snapshot.groups.orEmpty().map { group ->
            if (group.namespace != "agent-loop") {
                group
            } else {
                group.copy(
                    fields = group.fields.orEmpty().mapIndexed { index, field ->
                        if (index == 0) field.copy(
                            overridden = true,
                            kind = ConfigurationFieldKind.TOGGLE,
                            value = "false",
                        ) else field
                    },
                )
            }
        }
        val state = ConfigurationScreenState.from(
            facts.copy(snapshot = snapshot.copy(groups = groups)),
        )
        val groupId = ConfigurationScreenState.groupSectionId("agent-loop")
        var pageState by mutableStateOf(state)
        var reset: ConfigurationWriteRequest.ResetField? = null
        var save: ConfigurationWriteRequest.SaveGroup? = null
        val resetAck = CompletableDeferred<ConfigurationWriteReceipt>()
        var legacyResetCalled = false
        compose.setContent {
            PdshTheme {
                NativeConfigurationPage(
                    state = pageState,
                    onDone = {},
                    onToggleSection = {},
                    onResetField = { _, _ -> legacyResetCalled = true },
                    onConfigurationWrite = { request ->
                        when (request) {
                            is ConfigurationWriteRequest.ResetField -> {
                                reset = request
                                resetAck.await()
                            }
                            is ConfigurationWriteRequest.SaveGroup -> {
                                save = request
                                ConfigurationWriteReceipt(request.requestId, success = true)
                            }
                            else -> ConfigurationWriteReceipt(request.requestId, success = false)
                        }
                    },
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_SECTION_PREFIX + groupId))
        val resetTag = UiPageTags.CONFIGURATION_ROW_RESET_PREFIX + "$groupId.maxTurns"
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(resetTag))
        compose.onNodeWithTag(resetTag).performClick()
        compose.waitUntil(3_000) { reset != null }
        assertEquals("agent-loop", requireNotNull(reset).namespace)
        assertEquals("maxTurns", requireNotNull(reset).field)
        assertEquals(1, requireNotNull(reset).expectedRevision)
        assertFalse(legacyResetCalled)

        val toggleTag = "pdsh.configuration.field.agent-loop.maxTurns"
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(toggleTag))
        // Source fields are disabled while their namespace reset is pending.
        // This prevents a new user draft from being created under the old ACK.
        compose.onNodeWithTag(toggleTag).assertIsNotEnabled()
        val newerGroups = groups.map { group ->
            if (group.namespace == "agent-loop") group.copy(revision = 2) else group
        }
        pageState = ConfigurationScreenState.from(
            facts.copy(snapshot = requireNotNull(facts.snapshot).copy(groups = newerGroups)),
        )
        resetAck.complete(ConfigurationWriteReceipt(requireNotNull(reset).requestId, success = true))
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(toggleTag))
        compose.onNodeWithTag(toggleTag).assertIsEnabled().performClick()
        val saveTag = UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(saveTag))
        compose.onNodeWithTag(saveTag).assertIsDisplayed().performClick()
        compose.waitUntil(3_000) { save != null }
        assertEquals(2, requireNotNull(save).expectedRevision)
        assertEquals(mapOf("maxTurns" to "true"), requireNotNull(save).patch)
    }

    @Test
    fun `a schema toggle stages a typed patch and saves it with the group`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot)
        val groups = snapshot.groups.orEmpty().map { group ->
            if (group.namespace != "agent-loop") group else group.copy(
                revision = 7,
                fields = group.fields.orEmpty().mapIndexed { index, field ->
                    if (index == 0) field.copy(kind = ConfigurationFieldKind.TOGGLE, value = "关闭") else field
                },
            )
        }
        val state = ConfigurationScreenState.from(
            facts.copy(snapshot = snapshot.copy(groups = groups)),
        )
        val groupId = ConfigurationScreenState.groupSectionId("agent-loop")
        var request: ConfigurationWriteRequest.SaveGroup? = null
        show(
            state,
            onConfigurationWrite = { candidate ->
                request = candidate as? ConfigurationWriteRequest.SaveGroup
                ConfigurationWriteReceipt(candidate.requestId, success = true)
            },
        )
        val toggleTag = "pdsh.configuration.field.agent-loop.maxTurns"
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(toggleTag))
        compose.onNodeWithTag(toggleTag).performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId).performClick()
        assertEquals("agent-loop", requireNotNull(request).namespace)
        assertEquals(7, requireNotNull(request).expectedRevision)
        assertEquals("true", requireNotNull(request).patch["maxTurns"])
    }

    @Test
    fun `dirty groups show actions, failed or stale receipts retain drafts, and confirmed receipt clears them`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot)
        val groups = snapshot.groups.orEmpty().map { group ->
            if (group.namespace != "agent-loop") group else group.copy(
                fields = group.fields.orEmpty().mapIndexed { index, field ->
                    if (index == 0) field.copy(kind = ConfigurationFieldKind.TOGGLE, value = "关闭") else field
                },
            )
        }
        val state = ConfigurationScreenState.from(facts.copy(snapshot = snapshot.copy(groups = groups)))
        val groupId = ConfigurationScreenState.groupSectionId("agent-loop")
        var first = true
        val requests = mutableListOf<ConfigurationWriteRequest>()
        show(
            state,
            onConfigurationWrite = { request ->
                requests += request
                if (first) {
                    first = false
                    ConfigurationWriteReceipt("late-other-request", success = true)
                } else {
                    ConfigurationWriteReceipt(request.requestId, success = true)
                }
            },
        )

        val saveTag = UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId
        val discardTag = UiPageTags.CONFIGURATION_GROUP_DISCARD_PREFIX + groupId
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_SECTION_PREFIX + groupId))
        compose.onNodeWithTag(saveTag).assertDoesNotExist()
        compose.onNodeWithTag(discardTag).assertDoesNotExist()

        val fieldTag = "pdsh.configuration.field.agent-loop.maxTurns"
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(fieldTag))
        compose.onNodeWithTag(fieldTag).performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(saveTag))
        compose.onNodeWithTag(saveTag).assertIsDisplayed().performClick()
        compose.waitUntil(3_000) { requests.size == 1 }
        assertTrue(requests.single() is ConfigurationWriteRequest.SaveGroup)
        compose.onNodeWithTag(saveTag).assertIsDisplayed()
        compose.onNodeWithText("写入确认与当前请求不匹配，草稿仍保留。").assertIsDisplayed()

        compose.onNodeWithTag(saveTag).performClick()
        compose.waitUntil(3_000) { requests.size == 2 }
        compose.waitForIdle()
        val request = requests.last() as ConfigurationWriteRequest.SaveGroup
        assertEquals("agent-loop", request.namespace)
        assertEquals(mapOf("maxTurns" to "true"), request.patch)
        compose.onNodeWithTag(saveTag).assertDoesNotExist()
    }

    @Test
    fun `model route picker is source-aware and never renders allowedModels JSON`() {
        val raw = "[{\"provider\":\"provider-a\",\"model\":\"model-one\"}]"
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot)
        val modelGroup = ConfigurationGroup(
            namespace = "subagent-model-selection-settings",
            title = "子 Agent 模型",
            writable = FactState.YES,
            revision = 1,
            fields = listOf(
                ConfigurationField("enabled", "允许子 Agent 选择模型", value = "开启", kind = ConfigurationFieldKind.TOGGLE),
                ConfigurationField("allowedModels", "允许的子 Agent 模型", value = raw,
                    kind = ConfigurationFieldKind.MODEL_SELECTION, rawValue = raw),
            ),
        )
        val routes = listOf(
            ConfigurationModelRoute("provider-a", "Provider A", "model-one", "Model One"),
            ConfigurationModelRoute("provider-b", "Provider B", "model-two", "Model Two"),
        )
        val state = ConfigurationScreenState.from(
            facts.copy(snapshot = snapshot.copy(
                groups = snapshot.groups.orEmpty() + modelGroup,
                modelRoutes = routes,
                selectedSubagentModelIds = setOf("provider-a/model-one"),
            )),
        )
        var saved: ConfigurationWriteRequest.SaveGroup? = null
        show(
            state,
            onConfigurationWrite = { request ->
                saved = request as? ConfigurationWriteRequest.SaveGroup
                ConfigurationWriteReceipt(request.requestId, success = true)
            },
        )
        compose.onNodeWithText(raw).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText("Model One"))
        compose.onNodeWithText("Model One").assertIsDisplayed()
        compose.onNodeWithText("Model Two").performClick()
        val groupId = ConfigurationScreenState.groupSectionId("subagent-model-selection-settings")
        val saveTag = UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(saveTag))
        compose.onNodeWithTag(saveTag).performClick()
        compose.waitUntil(3_000) { saved != null }
        val allowed = JsonValue.parse(requireNotNull(saved).patch.getValue("allowedModels")) as JsonArray
        assertEquals(setOf("provider-a/model-one", "provider-b/model-two"), allowed.values.map { row ->
            val objectRow = row as JsonObject
            "${(objectRow["provider"] as JsonString).value}/${(objectRow["model"] as JsonString).value}"
        }.toSet())
    }

    @Test
    fun `refresh is disabled while drafts are dirty`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot)
        val groups = snapshot.groups.orEmpty().map { group ->
            if (group.namespace != "agent-loop") group else group.copy(
                fields = group.fields.orEmpty().mapIndexed { index, field ->
                    if (index == 0) field.copy(kind = ConfigurationFieldKind.TOGGLE, value = "关闭") else field
                },
            )
        }
        var refreshes = 0
        show(
            ConfigurationScreenState.from(facts.copy(snapshot = snapshot.copy(groups = groups))),
            onRefresh = { refreshes++ },
        )
        val refreshTag = UiPageTags.CONFIGURATION_REFRESH
        compose.onNodeWithTag(refreshTag).assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag("pdsh.configuration.field.agent-loop.maxTurns"))
        compose.onNodeWithTag("pdsh.configuration.field.agent-loop.maxTurns").performClick()
        compose.onNodeWithTag(refreshTag).assertIsNotEnabled()
        assertEquals(0, refreshes)
    }

    @Test
    fun `save request keeps the revision captured by its first draft after newer facts arrive`() {
        val facts = fullFacts()
        val baseSnapshot = requireNotNull(facts.snapshot)
        val baseGroups = baseSnapshot.groups.orEmpty().map { group ->
            if (group.namespace != "agent-loop") group else group.copy(
                revision = 1,
                fields = group.fields.orEmpty().mapIndexed { index, field ->
                    if (index == 0) field.copy(kind = ConfigurationFieldKind.TOGGLE, value = "false") else field
                },
            )
        }
        var pageState by mutableStateOf(
            ConfigurationScreenState.from(facts.copy(snapshot = baseSnapshot.copy(groups = baseGroups))),
        )
        val groupId = ConfigurationScreenState.groupSectionId("agent-loop")
        var captured: ConfigurationWriteRequest.SaveGroup? = null
        compose.setContent {
            PdshTheme {
                NativeConfigurationPage(
                    state = pageState,
                    onDone = {},
                    onToggleSection = {},
                    onConfigurationWrite = { request ->
                        captured = request as? ConfigurationWriteRequest.SaveGroup
                        ConfigurationWriteReceipt(request.requestId, success = false, message = "revision changed")
                    },
                )
            }
        }

        val fieldTag = "pdsh.configuration.field.agent-loop.maxTurns"
        val saveTag = UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(fieldTag))
        compose.onNodeWithTag(fieldTag).performClick()
        // A reread reports a newer revision while the local edit stays staged.
        val newerGroups = baseGroups.map { group ->
            if (group.namespace == "agent-loop") group.copy(revision = 2) else group
        }
        pageState = ConfigurationScreenState.from(facts.copy(snapshot = baseSnapshot.copy(groups = newerGroups)))
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(hasTestTag(saveTag))
        compose.onNodeWithTag(saveTag).performClick()
        compose.waitUntil(3_000) { captured != null }
        assertEquals(1, requireNotNull(captured).expectedRevision)
        assertEquals(mapOf("maxTurns" to "true"), requireNotNull(captured).patch)
        compose.onNodeWithTag(saveTag).assertIsDisplayed()
        compose.onNodeWithText("revision changed").assertIsDisplayed()
    }

    @Test
    fun `permission write keeps the revision captured when its draft was selected`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot).copy(permissionRevision = 7)
        var pageState by mutableStateOf(ConfigurationScreenState.from(facts.copy(snapshot = snapshot)))
        var captured: ConfigurationWriteRequest.SaveDefaultPermission? = null
        compose.setContent {
            PdshTheme {
                NativeConfigurationPage(
                    state = pageState,
                    onDone = {},
                    onToggleSection = {},
                    onConfigurationWrite = { request ->
                        captured = request as? ConfigurationWriteRequest.SaveDefaultPermission
                        ConfigurationWriteReceipt(request.requestId, success = false, message = "revision changed")
                    },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION))
        compose.onNodeWithTag("pdsh.configuration.permission-option.full").assertExists().assertIsEnabled()
        compose.onNodeWithTag("pdsh.configuration.permission-option.full").performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE))
        compose.onNodeWithText("已选择").assertExists()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertExists()
        pageState = ConfigurationScreenState.from(
            facts.copy(snapshot = snapshot.copy(permissionRevision = 8)),
        )
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).performClick()
        compose.waitUntil(3_000) { captured != null }
        assertEquals(7, requireNotNull(captured).expectedRevision)
        assertEquals("full", requireNotNull(captured).modeId)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertIsDisplayed()
        compose.onNodeWithText("revision changed").assertIsDisplayed()
    }

    @Test
    fun `configuration state preserves source group order without an inline tools group`() {
        val facts = fullFacts()
        val state = ConfigurationScreenState.from(facts)
        assertEquals(
            listOf(
                "subagent",
                "subagent-model-selection-settings",
                "agent-loop",
                "bash-sandbox",
            ).map { ConfigurationScreenState.groupSectionId(it) },
            state.sections.take(4).map { it.id },
        )
        assertEquals("自动执行轮次", state.sections[2].title)
        assertEquals("子 Agent 模型", state.sections[1].title)
        assertTrue(state.sections.drop(4).any { it.id == ConfigurationScreenState.EXPERIMENTAL_SECTION_ID })
        assertTrue(state.sections.drop(4).any { it.id == ConfigurationScreenState.INSTALLED_SECTION_ID })
        assertTrue(state.webSearchRow != null)
    }
    // ------------------------------------------------------------------ pills

    @Test
    fun `the source inline toolbar has only About and Refresh actions`() {
        val state = ConfigurationScreenState.from(fullFacts())
        show(state)
        compose.onNodeWithText(UiStrings.CONFIGURATION_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INTRO).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PLUGIN_INFO_ACTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_REFRESH).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_ADD_PLUGIN).assertDoesNotExist()
    }

    @Test
    fun `the 刷新 pill re-reads the snapshot when the host handed a command`() {
        var refreshes = 0
        show(
            ConfigurationScreenState.from(fullFacts()),
            onRefresh = { refreshes += 1 },
        )
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_REFRESH).assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_REFRESH).performClick()
        assertEquals(1, refreshes)
    }

    @Test
    fun `a partial host failure draws the orange warning line`() {
        val facts = fullFacts()
        val partial = facts.copy(
            snapshot = facts.snapshot!!.copy(
                settingsFailure = "请先启动 DSH 主机，再读取插件和设置。",
            ),
        )
        val state = ConfigurationScreenState.from(partial)
        assertEquals(1, state.notes.size)
        val sentence = UiStrings.CONFIGURATION_PARTIAL_FAILURE_FORMAT
            .format("请先启动 DSH 主机，再读取插件和设置。")
        show(state)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_NOTE_PREFIX + state.notes.single().id))
        compose.onNodeWithText(sentence).assertIsDisplayed()
    }

    /**
     * Robolectric models the sheet as its own dialog; dispatch on that dialog's
     * owner exactly as the platform window would, then let the hide animation
     * finish on the test clock.
     */
    private fun pressBackAndSettle() {
        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }
}
