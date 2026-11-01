// NativeConfigurationPage: four states, the plugin-inventory unknown rule and folds.
// SPDX-License-Identifier: MIT
//
// The unmeasured plugin list is located with `performScrollToNode` before the
// test asserts that no `0 个条目` was invented: the section is a lazy item and
// starts collapsed, so a bare absence assertion would be about the window, not
// about the page.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
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
        onOpenWebSearch: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                NativeConfigurationPage(
                    state = state,
                    onDone = onDone,
                    onToggleSection = {},
                    onOpenWebSearch = onOpenWebSearch,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** A host that applies the fold events, so the disclosure really moves. */
    private fun showLive(facts: ConfigurationFacts) {
        compose.setContent {
            var local by remember { mutableStateOf(ConfigurationLocalState()) }
            PdshTheme {
                NativeConfigurationPage(
                    state = ConfigurationScreenState.from(facts, local),
                    onDone = {},
                    onToggleSection = { id ->
                        local = local.apply(ConfigurationUiEvent.ToggleSection(id))
                    },
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty snapshot is the empty state, not the unknown state`() {
        val state = ConfigurationScreenState.from(
            ConfigurationFacts(snapshot = ConfigurationSnapshot()),
        )
        assertEquals(ConfigurationStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertTrue(state.sections.isEmpty())
        assertNull(state.webSearchRow)
        show(state)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_COUNT.format(0))
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SESSION).assertDoesNotExist()
    }

    @Test
    fun `a measured snapshot renders settings, permissions and the plugin inventory`() {
        val state = ConfigurationScreenState.from(fullFacts())
        assertEquals(ConfigurationStatus.READY, state.status)
        assertEquals("修复登录", state.sessionTitle)
        assertEquals(UiStrings.CONFIGURATION_WRITABLE_YES, state.writableValue)
        assertEquals(
            listOf(
                ConfigurationScreenState.groupSectionId("agent-loop"),
                ConfigurationScreenState.groupSectionId("bash-sandbox"),
                ConfigurationScreenState.groupSectionId("subagent"),
                ConfigurationScreenState.PERMISSION_SECTION_ID,
                ConfigurationScreenState.INFO_SECTION_ID,
                ConfigurationScreenState.EXPERIMENTAL_SECTION_ID,
                ConfigurationScreenState.INSTALLED_SECTION_ID,
            ),
            state.sections.map { it.id },
        )
        assertFalse(state.hasUnmeasuredValues)
        var done = 0
        var webSearch = 0
        show(
            state,
            onDone = { done += 1 },
            onOpenWebSearch = { webSearch += 1 },
        )

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_INTRO).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INTRO).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SESSION).assertIsDisplayed()
        compose.onNodeWithText("修复登录").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_WRITABLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_WEB_SEARCH).performClick()
        assertEquals(1, webSearch)
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_DONE).performClick()
        assertEquals(1, done)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText("最大轮次"))
        compose.onNodeWithText("最大轮次").assertIsDisplayed()
        compose.onNodeWithText("12").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(
                hasTestTag(
                    UiPageTags.CONFIGURATION_SECTION_PREFIX +
                        ConfigurationScreenState.INSTALLED_SECTION_ID,
                ),
            )
        compose.onNodeWithTag(
            UiPageTags.CONFIGURATION_SECTION_PREFIX +
                ConfigurationScreenState.INSTALLED_SECTION_ID,
        ).assertIsDisplayed()
    }

    @Test
    fun `a failed read wins over stale settings and offers retry and dismiss`() {
        val state = ConfigurationScreenState.from(fullFacts().copy(failure = "设置写入冲突"))
        assertEquals(ConfigurationStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertTrue(state.sections.isEmpty())
        assertEquals("设置写入冲突", state.failure)
        var retried = 0
        var dismissed = 0
        show(
            state,
            onRetry = { retried += 1 },
            onDismissFailure = { dismissed += 1 },
        )

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_LOAD_FAILED).assertIsDisplayed()
        compose.onNodeWithText("设置写入冲突").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText("修复登录").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_RETRY).performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `an unreported snapshot is unknown after the region is composed`() {
        val state = ConfigurationScreenState.from(ConfigurationFacts())
        assertEquals(ConfigurationStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertTrue(state.sections.isEmpty())
        show(state)

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.CONFIGURATION_UNKNOWN_DETAIL))
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_UNKNOWN_DETAIL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_UNKNOWN_DETAIL).assertIsDisplayed()
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

        val sectionTag = UiPageTags.CONFIGURATION_SECTION_PREFIX +
            ConfigurationScreenState.INSTALLED_SECTION_ID
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(sectionTag))
        compose.onNodeWithTag(sectionTag).performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasText(UiStrings.CONFIGURATION_INSTALLED_UNKNOWN))
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_COUNT.format(0))
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALLED_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `the installed-plugin fold really moves the plugin rows`() {
        val state = ConfigurationScreenState.from(fullFacts())
        val installed = state.sections.first {
            it.id == ConfigurationScreenState.INSTALLED_SECTION_ID
        }
        assertFalse(installed.expanded)
        showLive(fullFacts())

        val sectionTag = UiPageTags.CONFIGURATION_SECTION_PREFIX +
            ConfigurationScreenState.INSTALLED_SECTION_ID
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(sectionTag))
        compose.onNodeWithTag(sectionTag).performClick()
        val rowTag = UiPageTags.CONFIGURATION_PLUGIN_ROW_PREFIX + "config.installed.loader"
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST)
            .performScrollToNode(hasTestTag(rowTag))
        compose.onNodeWithTag(rowTag).assertIsDisplayed()
        compose.onNodeWithText("@deepseek-ai/dsh-loader").assertIsDisplayed()
    }

    @Test
    fun `the fold sequence is a pure function of the script`() {
        val facts = fullFacts()
        val script = listOf(
            ConfigurationUiEvent.ToggleSection(ConfigurationScreenState.INSTALLED_SECTION_ID),
            ConfigurationUiEvent.ToggleSection(ConfigurationScreenState.INSTALLED_SECTION_ID),
            ConfigurationUiEvent.ToggleSection(ConfigurationScreenState.PERMISSION_SECTION_ID),
            ConfigurationUiEvent.ToggleSection(
                ConfigurationScreenState.groupSectionId("agent-loop"),
            ),
            ConfigurationUiEvent.ToggleSection(ConfigurationScreenState.INFO_SECTION_ID),
        )

        fun run(): List<ConfigurationScreenState> {
            var local = ConfigurationLocalState()
            return buildList {
                add(ConfigurationScreenState.from(facts, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(ConfigurationScreenState.from(facts, local))
                }
            }
        }

        val states = run()
        fun expanded(id: String): List<Boolean> =
            states.map { state -> state.sections.first { it.id == id }.expanded }

        assertEquals(
            listOf(false, true, false, false, false, false),
            expanded(ConfigurationScreenState.INSTALLED_SECTION_ID),
        )
        assertEquals(
            listOf(true, true, true, false, false, false),
            expanded(ConfigurationScreenState.PERMISSION_SECTION_ID),
        )
        assertEquals(
            listOf(true, true, true, true, false, false),
            expanded(ConfigurationScreenState.groupSectionId("agent-loop")),
        )
        assertEquals(
            listOf(true, true, true, true, true, false),
            expanded(ConfigurationScreenState.INFO_SECTION_ID),
        )
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
    }
}
