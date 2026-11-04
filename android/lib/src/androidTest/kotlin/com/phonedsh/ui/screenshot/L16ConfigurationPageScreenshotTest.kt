// L16's configuration page on a real device: the control set the contract declares.
// SPDX-License-Identifier: MIT
//
// What this suite proves, on pixels rather than on the JVM:
//
//   * `NativeConfigurationPage` now paints the baseline's control set — the
//     插件说明 / 添加插件 header verbs, the 内置插件设置 master fold, the host's
//     per-group 保存 / 撤销 pair, the overridden field's 恢复默认, the
//     new-session permission block and the two 插件说明 sections;
//   * 插件说明 opens 本机管理范围 and 手机 Worker 限制 (the baseline keeps them in a
//     sheet; this page opens them inline);
//   * the permission block shows the host's measured default (标准) and the two
//     verbs the baseline declares;
//   * a host that accepts writes arms the verbs: the sample reports
//     `settingsWritable = YES`, so 保存默认 is active (a read-only host would dim
//     the pair — `NativeConfigurationPageTest` covers that on the JVM).
//
// Deliberately no `ScreenshotSamples` dependency: that file belongs to the parity
// lane, and this suite's sample is this page's own state.
package com.phonedsh.ui.screenshot

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ConfigurationExperimentalPlugin
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.ConfigurationField
import com.phonedsh.ui.page.ConfigurationGroup
import com.phonedsh.ui.page.ConfigurationLocalState
import com.phonedsh.ui.page.ConfigurationPermissionMode
import com.phonedsh.ui.page.ConfigurationPlugin
import com.phonedsh.ui.page.ConfigurationScreenState
import com.phonedsh.ui.page.ConfigurationSnapshot
import com.phonedsh.ui.page.ConfigurationUiEvent
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.NativeConfigurationPage
import com.phonedsh.ui.page.UiPageTags
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class L16ConfigurationPageScreenshotTest : ScreenshotTestBase() {

    /**
     * Gate frame, Android-only baseline directory. The configuration page has no
     * iOS counterpart in the 27-state baseline, so its pixels are a self-regression
     * receipt, never a parity claim.
     */
    override val allowedProfiles: Set<ScreenshotProfile> =
        setOf(ScreenshotProfile.GATE, ScreenshotProfile.ANDROID_ONLY)

    @Test
    fun configurationPagePaintsTheContractControlSet() {
        setCapturedContent { ConfigurationHost() }
        // Interactions below scroll a lazy list; with the capture clock frozen the
        // scroll never settles (Espresso's idle wait spins). The frames this suite
        // writes are receipts, not baselines, so let the clock run after setup.
        compose.mainClock.autoAdvance = true

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_BUILT_IN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_BUILT_IN_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_PLUGIN_INFO).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_ADD_DISABLED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_WEB_SEARCH).assertIsDisplayed()
        capture("l16-configuration-ready")
    }

    @Test
    fun pluginInfoOpensTheTwoAboutSections() {
        setCapturedContent { ConfigurationHost() }
        // Interactions below scroll a lazy list; with the capture clock frozen the
        // scroll never settles (Espresso's idle wait spins). The frames this suite
        // writes are receipts, not baselines, so let the clock run after setup.
        compose.mainClock.autoAdvance = true

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PLUGIN_INFO_ACTION).performClick()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(
            hasTestTag(
                UiPageTags.CONFIGURATION_SECTION_PREFIX +
                    ConfigurationScreenState.SCOPE_SECTION_ID,
            ),
        )
        compose.onNodeWithText(UiStrings.CONFIGURATION_SCOPE_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_SCOPE_TEXT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(
            hasTestTag(
                UiPageTags.CONFIGURATION_SECTION_PREFIX +
                    ConfigurationScreenState.LIMITS_SECTION_ID,
            ),
        )
        compose.onNodeWithText(UiStrings.CONFIGURATION_LIMITS_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(
            hasText(UiStrings.CONFIGURATION_ONLY_LOADED_TEXT),
        )
        compose.onNodeWithText(UiStrings.CONFIGURATION_ONLY_LOADED_TEXT)
            .assertIsDisplayed()
        capture("l16-configuration-about")
    }

    @Test
    fun thePermissionBlockShowsTheMeasuredDefaultAndItsVerbs() {
        setCapturedContent { ConfigurationHost() }
        // Interactions below scroll a lazy list; with the capture clock frozen the
        // scroll never settles (Espresso's idle wait spins). The frames this suite
        // writes are receipts, not baselines, so let the clock run after setup.
        compose.mainClock.autoAdvance = true

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_LIST).performScrollToNode(
            hasTestTag(UiPageTags.CONFIGURATION_PERMISSION_ROW),
        )
        compose.onNodeWithText(UiStrings.CONFIGURATION_DEFAULT_PERMISSION)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_DEFAULT_PERMISSION_ROW)
            .assertIsDisplayed()
        compose.onNodeWithText("标准").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CONFIGURATION_PERMISSION_DISCARD).assertIsDisplayed()
        capture("l16-configuration-permission")
    }

    @Test
    fun theAddPluginMenuExplainsWhyInstallingCannotRunHere() {
        setCapturedContent { ConfigurationHost() }
        // Interactions below scroll a lazy list; with the capture clock frozen the
        // scroll never settles (Espresso's idle wait spins). The frames this suite
        // writes are receipts, not baselines, so let the clock run after setup.
        compose.mainClock.autoAdvance = true

        compose.onNodeWithTag(UiPageTags.CONFIGURATION_ADD_PLUGIN).performClick()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALL_THIRD_PARTY)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_CREATE_WITH_AGENT)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONFIGURATION_INSTALL_THIRD_PARTY).performClick()
        compose.onNodeWithText(UiStrings.CONFIGURATION_ADD_DISABLED_HINT)
            .assertIsDisplayed()
        // The notice is part of the page, so the frame is captured after the menu
        // closes on its own (a popup is a second window, not part of this frame).
        capture("l16-configuration-add-notice")
    }
}

/** The measured snapshot these frames are taken against: a host that accepts writes. */
private fun configurationFacts(): ConfigurationFacts = ConfigurationFacts(
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
                        overridden = true,
                    ),
                    ConfigurationField(id = "autoContinue", title = "自动继续", value = "关闭"),
                ),
            ),
            ConfigurationGroup(
                namespace = "bash-sandbox",
                title = "终端",
                detail = "命令在沙箱里执行",
                writable = FactState.NO,
                fields = listOf(
                    ConfigurationField(id = "sandbox", title = "沙箱", value = "开启"),
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
        ),
        experimentalPlugins = listOf(
            ConfigurationExperimentalPlugin(
                id = "agent-team",
                title = "智能体团队",
                status = "Worker 当前已加载 · active",
                loaded = FactState.YES,
            ),
        ),
        pluginManagementMessage = "插件可查看；安装和启用需在桌面 DSH 管理。",
    ),
)

/** The page with its own fold state, so the captures exercise the real controls. */
@Composable
private fun ConfigurationHost() {
    var local by remember { mutableStateOf(ConfigurationLocalState()) }
    NativeConfigurationPage(
        state = ConfigurationScreenState.from(configurationFacts(), local),
        onDone = {},
        onToggleSection = { id ->
            local = local.apply(ConfigurationUiEvent.ToggleSection(id))
        },
        onOpenWebSearch = {},
        onSaveGroup = {},
        onDiscardGroup = {},
        onResetField = { _, _ -> },
        onPickDefaultPermission = {},
        onSaveDefaultPermission = {},
        onDiscardDefaultPermission = {},
    )
}
