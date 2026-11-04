// The Settings family's iOS-baseline states, as pure screen states.
// SPDX-License-Identifier: MIT
//
// Why this file exists: a parity capture is only comparable while its *content* is
// the baseline's content. Every value below is copied from the matching
// `docs/receipts/ios-baseline-screens/ios-settings*.png`, so the Android frame and
// the iOS frame carry the same words in the same order and what is left to compare
// is geometry, not wording:
//
//   `ios-settings.png`          权限 未设置, 语言 跟随系统, 外观 浅色, 工作步骤展示 详细,
//                               工作步骤收起时机 回答结束后, 显示代码工作视图 on, 快捷键 编辑,
//                               繁忙时的发送行为 排队发送 (the 5-tab 通用 tab)
//   `ios-settings-network.png`  allow-all off + the same 15 hosts, in file order
//   `ios-settings-model.png`    one selected service, 读不到密钥 (the key store is unreadable)
//   `ios-settings-search.png`   沿用模型服务 selected, 独立 DeepSeek 搜索 API second
//   `ios-settings-runtime.png`  engine stopped (状态 已停止)
//   `ios-settings-about.png`    版本 0.1.0
//   `ios-settings-plugins.png`  two built-in groups plus the three permission presets
//
// Nothing here reads a clock, a locale, a file or the engine: each builder is a
// pure function, so the capture is reproducible. A field whose value the iOS shot
// does not show stays at the state's default rather than being filled with invented
// content. The Android-only rows (the platform appendix) are part of the page, so
// they are given their representative facts instead of being hidden.
package com.phonedsh.ui.screenshot

import com.phonedsh.ui.page.AboutFacts
import com.phonedsh.ui.page.AboutScreenState
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.CollapseTiming
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.ConfigurationField
import com.phonedsh.ui.page.ConfigurationGroup
import com.phonedsh.ui.page.ConfigurationPermissionMode
import com.phonedsh.ui.page.ConfigurationScreenState
import com.phonedsh.ui.page.ConfigurationSnapshot
import com.phonedsh.ui.page.EgressAllowListFacts
import com.phonedsh.ui.page.EgressAllowListScreenState
import com.phonedsh.ui.page.EgressRule
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.page.ModelProviderFacts
import com.phonedsh.ui.page.ModelProviderScreenState
import com.phonedsh.ui.page.ProviderKeyFact
import com.phonedsh.ui.page.ProviderKeyStatus
import com.phonedsh.ui.page.ProviderProfile
import com.phonedsh.ui.page.RuntimeDetailsScreenState
import com.phonedsh.ui.page.RuntimeFacts
import com.phonedsh.ui.page.RuntimeSnapshot
import com.phonedsh.ui.page.SettingsAppearance
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsLanguage
import com.phonedsh.ui.page.SettingsPreferences
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.WebSearchMode
import com.phonedsh.ui.page.WebSearchFacts
import com.phonedsh.ui.page.WebSearchScreenState
import com.phonedsh.ui.page.TranscriptViewMode
import com.phonedsh.ui.page.WebSearchSummary

/** The seven iOS Settings-family states, one builder each. */
object SettingsParitySamples {
    /** `ios-settings.png`: the baseline's unset service name. */
    const val DEFAULT_SERVICE: String = "默认模型服务"

    /** `ios-settings.png`: the version the baseline prints. */
    const val VERSION: String = "0.1.0"

    /** `ios-settings-network.png`: the allow-list count in the index row. */
    const val EGRESS_COUNT: Int = 15

    /**
     * `ios-settings-network.png`: the 15 addresses, in the baseline's own order.
     *
     * The first and the last of the visible rows are copied from the shot; the ones
     * the shot scrolls past are the same list the iOS egress defaults ship.
     */
    val EGRESS_HOSTS: List<String> = listOf(
        "wttr.in",
        "api.open-meteo.com",
        "geocoding-api.open-meteo.com",
        "api.github.com",
        "raw.githubusercontent.com",
        "github.com",
        "pypi.org",
        "files.pythonhosted.org",
        "registry.npmjs.org",
        "cdn.jsdelivr.net",
        "unpkg.com",
        "en.wikipedia.org",
        "api.duckduckgo.com",
        "html.duckduckgo.com",
        "lite.duckduckgo.com",
    )

    /**
     * `page-settings-default`: the 通用 tab in `settings-chat.png`'s state.
     *
     * The shot shows 权限 未设置 with its 选择新会话的默认权限模式 footnote, 语言
     * 跟随系统, 外观 浅色, 字号大小 with no value, 工作步骤展示 详细, 工作步骤收起时机
     * 回答结束后, 显示代码工作视图 on, 快捷键 编辑, 繁忙时的发送行为 排队发送. Every
     * value below is that shot's.
     */
    fun indexState(): SettingsScreenState = SettingsScreenState.from(
        SettingsFacts(
            defaultPermissionTier = null,
            preferences = SettingsPreferences(
                language = SettingsLanguage.SYSTEM,
                appearance = SettingsAppearance.LIGHT,
                transcriptView = TranscriptViewMode.DETAILED,
                collapseTiming = CollapseTiming.COMPLETION,
                developerTools = FactState.YES,
                performanceUsage = PerformanceUsage.COMPACT,
            ),
            backgroundKeepAlive = FactState.YES,
            busyEnterMode = BusyEnterMode.QUEUE,
            versionName = VERSION,
            platform = SettingsPlatformFacts(
                notifications = FactState.YES,
                batteryExemption = FactState.NO,
                predictiveBack = FactState.YES,
            ),
        ),
    )

    /**
     * `page-settings-about`: **版本 0.1.0 and the one sentence, nothing else.**
     *
     * L79 removed the Android-only platform appendix (系统 card) and the 构建号
     * row: `settings-about.json` describes iOS's page as one `版本` row plus the
     * `会话记录和文件都保存在这台手机上。` sentence, and `NativeShell.swift:897-908`
     * is exactly that. Passing the platform facts made the Android panel draw a
     * second 262 pt card the baseline does not have (27.6 % of the frame).
     */
    fun aboutState(): AboutScreenState = AboutScreenState.from(
        AboutFacts(version = VERSION),
    )

    /** `page-settings-model`: one selected service whose key the host cannot read. */
    fun modelProviderState(): ModelProviderScreenState = ModelProviderScreenState.from(
        ModelProviderFacts(
            profiles = listOf(
                ProviderProfile(
                    id = "default",
                    name = DEFAULT_SERVICE,
                    model = "deepseek-flash",
                    endpoint = "https://api.deepseek.com/anthropic",
                    key = ProviderKeyFact(status = ProviderKeyStatus.UNKNOWN),
                    selected = true,
                ),
            ),
            writable = FactState.YES,
        ),
    )

    /** `page-settings-network`: allow-all off, 15 addresses. */
    fun egressState(): EgressAllowListScreenState = EgressAllowListScreenState.from(
        EgressAllowListFacts(
            rules = EGRESS_HOSTS.mapIndexed { index, host ->
                EgressRule(id = "rule-$index", host = host)
            },
            writable = FactState.YES,
        ),
    )

    /** `page-settings-plugins`: two built-in groups and three permission presets. */
    fun configurationState(): ConfigurationScreenState = ConfigurationScreenState.from(
        ConfigurationFacts(
            snapshot = ConfigurationSnapshot(
                sessionTitle = com.phonedsh.ui.UiStrings.SETTINGS,
                settingsWritable = FactState.YES,
                groups = listOf(
                    ConfigurationGroup(
                        namespace = "agent-loop",
                        title = "子 Agent",
                        detail = "允许主 Agent 派生一个子 Agent。",
                        writable = FactState.YES,
                        fields = listOf(
                            ConfigurationField(
                                id = "agent-loop.enabled",
                                title = "允许派生子 Agent",
                                value = "开",
                            ),
                        ),
                    ),
                    ConfigurationGroup(
                        namespace = "terminal",
                        title = "终端",
                        detail = "内置终端的默认设置。",
                        writable = FactState.YES,
                        fields = listOf(
                            ConfigurationField(
                                id = "terminal.shell",
                                title = "默认 Shell",
                                value = "/system/bin/sh",
                            ),
                        ),
                    ),
                ),
                permissionModes = listOf(
                    ConfigurationPermissionMode(id = "read-only", name = "仅可查看"),
                    ConfigurationPermissionMode(id = "workspace-write", name = "工作区内修改"),
                    ConfigurationPermissionMode(id = "danger-full-access", name = "完全权限"),
                ),
                defaultPermissionModeId = "workspace-write",
                // The iOS shot's host is NOT connected: its page draws the orange
                // warning `请先启动 DSH 主机，再读取插件和设置。` above the groups
                // (`NativeConfigurationPage.swift:15-20`) while the group rows stay.
                // Without this line the Android side of the pair cannot show the
                // warning line at all, and the pair would compare two host states.
                settingsFailure = "请先启动 DSH 主机，再读取插件和设置。",
            ),
        ),
    )

    /** `page-settings-runtime`: the engine is stopped, which is what the shot shows. */
    fun runtimeState(): RuntimeDetailsScreenState = RuntimeDetailsScreenState.from(
        RuntimeFacts(snapshot = RuntimeSnapshot(engine = FactState.NO)),
    )

    /**
     * `page-settings-search`: 用模型服务自带的 selected, and the model service does
     * carry search (the 2026-11-01 contract's mode group, not the old switch).
     */
    fun webSearchState(): WebSearchScreenState = WebSearchScreenState.from(
        WebSearchFacts(
            mode = WebSearchMode.FOLLOW_MODEL,
            modelSearchSupported = FactState.YES,
            hasCredential = FactState.YES,
            keyTail = "9f3a",
            engineStarted = FactState.NO,
            writable = FactState.YES,
        ),
    )
}
