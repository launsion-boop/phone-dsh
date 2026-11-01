// Settings: the iOS settings index, section by section.
// SPDX-License-Identifier: MIT
//
// Authority: examples/probe-app/PhoneDSHProbe/SettingsPage.swift, line for line.
// Its body renders exactly three groups and nothing else:
//   * mainGroup: five rows, no header (权限 / 写之前 / 模型服务 / MCP / 后台运行);
//   * toolsGroup: header 工具, five rows (网页搜索 / 网络访问 / 插件与模型 / 命令 /
//     发送消息时) and one conditional footer line;
//   * aboutGroup: header 关于, three rows (版本 / 开源许可 / 导出诊断).
// Thirteen rows in total. The Swift file also declares seven private Section vars
// that its body never references (runtimeSection, advancedSection, modelSection,
// webSearchSection, mcpSection, networkSection, backgroundSection,
// conversationSection, aboutSection, developerGroup, developerSection); they are
// not rendered and therefore not mirrored, and each one is listed with its reason
// in the lane report instead of being invented into this page.
//
// Data: every value comes from SettingsFacts, the host's read-only snapshot. A
// field the host cannot report is null and renders the baseline's own "unset"
// wording (未设置 / 未配置) or 未知, never a plausible default. The rows and their
// sections always exist: "this setting exists but its value is unreadable" and
// "this setting does not exist" are different statements.
//
// Platform appendix: the three fact rows after 关于 are Android-only. They exist
// because `spec/platform/whitelist.json` rows `platform.post-notifications-degraded`,
// `platform.battery-exemption-policy` and `platform.predictive-back` require the
// degradation to be visible, and iOS has no counterpart for any of the three. The
// appendix is placed last and has no fold, so the mirrored three sections come
// first and unchanged.
//
// Structure: the page writes the baseline's groups and rows out one call site at
// a time, with the fixed copy as `UiStrings` constants, and takes only the values,
// tones and destinations from `SettingsScreenState`. `spec/ui/v1/tools/page_structure_check.py`
// compares that structure with `spec/ui/v1/pages/settings.json`; a title read from
// the state would be invisible to it, and the copy here is fixed anyway.
//
// ScreenState: `SettingsScreenState.from(facts)` is pure. This page has no fold
// and no other local event, so replaying the same facts yields the same state;
// the only transient UI state is whether the 发送消息时 picker is expanded, which
// is an affordance, not a spec'd state.
//
// Geometry: page-level tokens only. Two baseline numbers have no token and are
// marked `unverified geometry` where they are used (the group header's 24pt top
// inset and the 20pt chevron slot).
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/**
 * The three permission presets, in the baseline's menu order (完全权限 last).
 *
 * The wording is the same wording the chat permission menu uses, and the order
 * is the one the baseline fixes. A host that reports a preset id this enum does
 * not know reports `null` instead; the page then says 未设置 rather than mapping
 * an unknown tier onto one of the three.
 */
public enum class PermissionTier {
    VIEW_ONLY,
    WORKSPACE_WRITE,
    FULL_ACCESS,
}

/**
 * What the composer does with a message sent while a turn is running.
 *
 * The ids are the baseline's `@AppStorage("phone-dsh.composer.busyEnter")` tags,
 * so a host can persist the same value the iOS build persists.
 */
public enum class BusyEnterMode(public val id: String) {
    QUEUE("queue"),
    STEER("steer"),
}

/** The web-search row's trailing value; the host decides which one it is. */
public enum class WebSearchSummary {
    /** 沿用模型服务: explicit fallback, official Messages endpoint only. */
    FOLLOW_MODEL,

    /** 独立 DeepSeek 搜索 API. */
    SEARCH_API,

    /** 网页搜索配置不可读: the baseline's one wording for an unreadable config. */
    UNREADABLE,
}

/** How one row behaves when it is tapped. */
public enum class SettingsRowKind {
    /** Opens a page (the baseline's NavigationLink): label, value, chevron. */
    NAVIGATION,

    /** Label and value without a chevron (写之前, 版本). */
    VALUE,

    /** The 后台运行 switch. */
    TOGGLE,

    /** The 发送消息时 picker, rendered as a menu. */
    MENU,

    /** A plain action row without a chevron (插件与模型, 导出诊断). */
    ACTION,
}

/** Where a navigation or action row goes. The page owns no Activity and no route. */
public enum class SettingsDestination {
    PERMISSION_DEFAULTS,
    MODEL_PROVIDER,
    MCP,
    WEB_SEARCH,
    EGRESS,
    PLUGIN_CONFIGURATION,
    COMMAND,
    RUNTIME_DETAILS,
    LICENSES,
    EXPORT_DIAGNOSTICS,
}

/** One entry of a menu row's menu. */
@Immutable
public data class SettingsMenuOption(
    public val mode: BusyEnterMode,
    public val title: String,
)

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The Android-only platform facts the appendix group reports.
 *
 * Each field is three-valued on purpose: whether the user granted a permission
 * and whether we could read the grant are different answers.
 */
@Immutable
public data class SettingsPlatformFacts(
    /** `platform.post-notifications-degraded`: denied notifications degrade the turn to foreground-only. */
    public val notifications: FactState = FactState.UNKNOWN,
    /** `platform.battery-exemption-policy`: Play builds guide, they never request the exemption. */
    public val batteryExemption: FactState = FactState.UNKNOWN,
    /** `platform.predictive-back`: the platform form of the back gesture, not a capability loss. */
    public val predictiveBack: FactState = FactState.UNKNOWN,
)

/**
 * The page's read-only input, one field per mirrored row.
 *
 * Every nullable field is a value the host may not have. `null` never becomes a
 * plausible default: the permission rows say 未设置, the model and MCP rows say
 * 未配置 (the baseline's own wording for "there is none"), and the rows whose
 * baseline has no "none" case say 未知.
 *
 * @param defaultPermissionTier the host's preset for new sessions; `null` when
 *   it has none or reports a preset this page does not know.
 * @param modelProviderName the selected service's display name; `null` = 未配置.
 * @param mcpServerCount the server count the host listed; `null` = not listed
 *   (engine not started) and renders 未配置, exactly like the baseline.
 * @param backgroundKeepAlive the 后台运行 switch; `UNKNOWN` renders 未知 and no
 *   switch, because a switch in a position we did not read would be a guess.
 * @param webSearch the web-search summary; `null` renders 网页搜索配置不可读.
 * @param egressAddressCount the number of allow-listed addresses; `null` = 未知.
 * @param busyEnterMode the 发送消息时 value; `null` = 未知.
 * @param versionName the app version; `null` = 未知.
 * @param searchLaunchWarning the active surface's launch warning, verbatim; it
 *   has the first claim on the tools footer.
 * @param engineStarted whether the local engine is up; needed for the
 *   "重启本地引擎后生效。" footer branch.
 * @param networkConfigurationChanged the network configuration differs from the
 *   engine's running one.
 * @param didSave a save happened. The baseline declares this flag and clears it
 *   when the egress value changes, but never sets it true; the branch is
 *   mirrored so the host can drive it.
 * @param platform the Android-only appendix facts.
 */
@Immutable
public data class SettingsFacts(
    public val defaultPermissionTier: PermissionTier? = null,
    public val modelProviderName: String? = null,
    public val mcpServerCount: Int? = null,
    public val backgroundKeepAlive: FactState = FactState.UNKNOWN,
    public val webSearch: WebSearchSummary? = null,
    public val egressAddressCount: Int? = null,
    public val busyEnterMode: BusyEnterMode? = null,
    public val versionName: String? = null,
    public val searchLaunchWarning: String? = null,
    public val engineStarted: FactState = FactState.UNKNOWN,
    public val networkConfigurationChanged: Boolean = false,
    public val didSave: Boolean = false,
    public val platform: SettingsPlatformFacts? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One row of the mirrored page. */
@Immutable
public data class SettingsRowView(
    public val id: String,
    public val kind: SettingsRowKind,
    public val title: String,
    /** Trailing value; `null` when the baseline renders an empty value. */
    public val value: String? = null,
    /** Optional explanatory second line; only the platform appendix has one. */
    public val subtitle: String? = null,
    public val tone: PageTone = PageTone.NORMAL,
    /** Target of a NAVIGATION or ACTION row. */
    public val destination: SettingsDestination? = null,
    /** TOGGLE position; only meaningful when the facts reported one. */
    public val checked: Boolean = false,
    public val enabled: Boolean = true,
    /** MENU entries; empty for every other kind. */
    public val options: List<SettingsMenuOption> = emptyList(),
    /** MENU selection; `null` = 未知. */
    public val mode: BusyEnterMode? = null,
    /** The baseline draws a hairline under every row except 发送消息时 and 导出诊断. */
    public val dividerBelow: Boolean = true,
)

/**
 * One section: its id, its rows and its optional footer.
 *
 * The group titles are not here: they are fixed copy, so the page writes them (as
 * the Swift body does) and `spec/ui/v1/tools/page_structure_check.py` can compare
 * them with the iOS contract. The first group has no title at all.
 */
@Immutable
public data class SettingsSectionView(
    public val id: String,
    public val rows: List<SettingsRowView>,
    public val footer: String? = null,
)

/** The complete settings screen state. */
@Immutable
public data class SettingsScreenState(
    public val sections: List<SettingsSectionView>,
) {
    /**
     * One row by id.
     *
     * The page renders the baseline's rows one by one (the structure is fixed
     * copy, so it belongs in the view), and looks each row's value up here. A
     * state built by hand without that id renders nothing for it, rather than a
     * row the baseline does not have.
     */
    public fun row(id: String): SettingsRowView? =
        sections.firstNotNullOfOrNull { section -> section.rows.firstOrNull { it.id == id } }

    /** The footer of one section, or `null` when the baseline has none there. */
    public fun footer(sectionId: String): String? =
        sections.firstOrNull { it.id == sectionId }?.footer

    public companion object {
        /** The untitled first group. */
        public const val MAIN_SECTION_ID: String = "main"

        /** The 工具 group. */
        public const val TOOLS_SECTION_ID: String = "tools"

        /** The 关于 group. */
        public const val ABOUT_SECTION_ID: String = "about"

        /** The Android-only platform appendix. */
        public const val PLATFORM_SECTION_ID: String = "platform"

        /** Row ids, in the order the baseline renders them. */
        public const val PERMISSION_ROW_ID: String = "permission"
        public const val ASK_ROW_ID: String = "askBeforeWrite"
        public const val MODEL_ROW_ID: String = "modelService"
        public const val MCP_ROW_ID: String = "mcp"
        public const val BACKGROUND_ROW_ID: String = "backgroundKeepAlive"
        public const val WEB_SEARCH_ROW_ID: String = "webSearch"
        public const val NETWORK_ROW_ID: String = "networkAccess"
        public const val PLUGINS_ROW_ID: String = "plugins"
        public const val COMMAND_ROW_ID: String = "command"

        /**
         * The §1-mandated 运行时详情 row.
         *
         * `spec/ui/v1/README.md` §1 lists RuntimeDetailsPage's 入口 as
         * `页头运行状态点、设置行`; the iOS body does not render that row (only the
         * never-referenced `advancedSection` declares it), so this row is the one
         * place where §1 and the baseline body disagree and §1 wins.
         */
        public const val RUNTIME_ROW_ID: String = "runtimeDetails"
        public const val BUSY_ENTER_ROW_ID: String = "busyEnter"
        public const val VERSION_ROW_ID: String = "version"
        public const val LICENSES_ROW_ID: String = "licenses"
        public const val EXPORT_ROW_ID: String = "exportDiagnostics"

        /** Appendix row ids; page-owned, a host item cannot shadow them. */
        public const val NOTIFICATIONS_ROW_ID: String = "platform.notifications"
        public const val BATTERY_ROW_ID: String = "platform.battery"
        public const val BACK_ROW_ID: String = "platform.back"

        /** Projects the facts into the three mirrored sections plus the appendix. */
        public fun from(facts: SettingsFacts): SettingsScreenState {
            val permissionTitle = permissionTitle(facts.defaultPermissionTier)
            val askValue = askBeforeWriteValue(facts.defaultPermissionTier)
            val backgroundKnown = facts.backgroundKeepAlive != FactState.UNKNOWN

            val main = SettingsSectionView(
                id = MAIN_SECTION_ID,
                rows = listOf(
                    SettingsRowView(
                        id = PERMISSION_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.SETTINGS_ROW_PERMISSION,
                        value = permissionTitle,
                        destination = SettingsDestination.PERMISSION_DEFAULTS,
                    ),
                    SettingsRowView(
                        id = ASK_ROW_ID,
                        kind = SettingsRowKind.VALUE,
                        title = UiStrings.SETTINGS_ROW_ASK_BEFORE_WRITE,
                        value = askValue,
                    ),
                    SettingsRowView(
                        id = MODEL_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.SETTINGS_ROW_MODEL_SERVICE,
                        value = facts.modelProviderName ?: UiStrings.NOT_CONFIGURED,
                        destination = SettingsDestination.MODEL_PROVIDER,
                    ),
                    SettingsRowView(
                        id = MCP_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.SETTINGS_ROW_MCP,
                        value = mcpValue(facts.mcpServerCount),
                        destination = SettingsDestination.MCP,
                    ),
                    // The baseline's last main-group row still draws its hairline.
                    SettingsRowView(
                        id = BACKGROUND_ROW_ID,
                        kind = if (backgroundKnown) SettingsRowKind.TOGGLE else SettingsRowKind.VALUE,
                        title = UiStrings.SETTINGS_ROW_BACKGROUND,
                        value = when (facts.backgroundKeepAlive) {
                            FactState.YES -> UiStrings.SETTINGS_BACKGROUND_ON
                            FactState.NO -> UiStrings.SETTINGS_BACKGROUND_OFF
                            FactState.UNKNOWN -> UiStrings.UNKNOWN
                        },
                        tone = when (facts.backgroundKeepAlive) {
                            FactState.YES -> PageTone.ON
                            FactState.NO -> PageTone.NORMAL
                            FactState.UNKNOWN -> PageTone.UNKNOWN
                        },
                        checked = facts.backgroundKeepAlive == FactState.YES,
                        enabled = backgroundKnown,
                    ),
                ),
            )

            val tools = SettingsSectionView(
                id = TOOLS_SECTION_ID,
                rows = listOf(
                    SettingsRowView(
                        id = WEB_SEARCH_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.WEB_SEARCH_TITLE,
                        value = webSearchValue(facts.webSearch),
                        tone = if (facts.webSearch == null || facts.webSearch == WebSearchSummary.UNREADABLE) {
                            PageTone.UNKNOWN
                        } else {
                            PageTone.NORMAL
                        },
                        destination = SettingsDestination.WEB_SEARCH,
                    ),
                    SettingsRowView(
                        id = NETWORK_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.SETTINGS_ROW_NETWORK,
                        value = facts.egressAddressCount
                            ?.let { UiStrings.EGRESS_RULE_COUNT.format(it) }
                            ?: UiStrings.UNKNOWN,
                        tone = if (facts.egressAddressCount == null) PageTone.UNKNOWN else PageTone.NORMAL,
                        destination = SettingsDestination.EGRESS,
                    ),
                    SettingsRowView(
                        id = PLUGINS_ROW_ID,
                        kind = SettingsRowKind.ACTION,
                        title = UiStrings.SETTINGS_ROW_PLUGINS,
                        destination = SettingsDestination.PLUGIN_CONFIGURATION,
                    ),
                    SettingsRowView(
                        id = COMMAND_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.TOOLS,
                        destination = SettingsDestination.COMMAND,
                    ),
                    SettingsRowView(
                        id = RUNTIME_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.RUNTIME_TITLE,
                        destination = SettingsDestination.RUNTIME_DETAILS,
                    ),
                    SettingsRowView(
                        id = BUSY_ENTER_ROW_ID,
                        kind = SettingsRowKind.MENU,
                        title = UiStrings.SETTINGS_ROW_SEND,
                        value = busyEnterValue(facts.busyEnterMode),
                        tone = if (facts.busyEnterMode == null) PageTone.UNKNOWN else PageTone.NORMAL,
                        options = BUSY_ENTER_OPTIONS,
                        mode = facts.busyEnterMode,
                        dividerBelow = false,
                    ),
                ),
                footer = toolsFooter(facts),
            )

            val about = SettingsSectionView(
                id = ABOUT_SECTION_ID,
                rows = listOf(
                    SettingsRowView(
                        id = VERSION_ROW_ID,
                        kind = SettingsRowKind.VALUE,
                        title = UiStrings.ABOUT_SECTION_VERSION,
                        value = facts.versionName ?: UiStrings.UNKNOWN,
                        tone = if (facts.versionName == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    ),
                    SettingsRowView(
                        id = LICENSES_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.ABOUT_LICENSES,
                        destination = SettingsDestination.LICENSES,
                    ),
                    SettingsRowView(
                        id = EXPORT_ROW_ID,
                        kind = SettingsRowKind.ACTION,
                        title = UiStrings.SETTINGS_ROW_EXPORT,
                        destination = SettingsDestination.EXPORT_DIAGNOSTICS,
                        dividerBelow = false,
                    ),
                ),
            )

            val platform = facts.platform ?: SettingsPlatformFacts()
            val appendix = SettingsSectionView(
                id = PLATFORM_SECTION_ID,
                rows = platformRows(platform),
            )

            return SettingsScreenState(sections = listOf(main, tools, about, appendix))
        }

        /** The baseline's footer precedence: warning, then restart, then saved. */
        private fun toolsFooter(facts: SettingsFacts): String? = when {
            facts.searchLaunchWarning != null -> facts.searchLaunchWarning
            facts.engineStarted == FactState.YES && facts.networkConfigurationChanged ->
                UiStrings.SETTINGS_FOOTER_RESTART
            facts.didSave -> UiStrings.SETTINGS_FOOTER_SAVED
            else -> null
        }

        /** 权限: the host's preset title, or 未设置 when it reported none. */
        private fun permissionTitle(tier: PermissionTier?): String = tier?.let { tierTitle(it) } ?: UiStrings.SETTINGS_PERMISSION_UNSET

        /**
         * 写之前: the second row only reports the "ask or not" half the tier decides.
         * The baseline compares the tier's title with 完全权限; an unknown tier makes
         * both rows say 未设置, so the pair never contradicts itself.
         */
        private fun askBeforeWriteValue(tier: PermissionTier?): String = tier?.let {
            if (it == PermissionTier.FULL_ACCESS) UiStrings.SETTINGS_ASK_NO_MORE else UiStrings.SETTINGS_ASK_EVERY_TIME
        } ?: UiStrings.SETTINGS_PERMISSION_UNSET

        /** MCP: the baseline collapses "engine not up" and "no servers" into 未配置. */
        private fun mcpValue(count: Int?): String =
            if (count == null || count == 0) UiStrings.NOT_CONFIGURED else UiStrings.SETTINGS_MCP_SERVER_COUNT.format(count)

        private fun webSearchValue(summary: WebSearchSummary?): String = when (summary) {
            WebSearchSummary.FOLLOW_MODEL -> UiStrings.SEARCH_SUMMARY_FOLLOW_MODEL
            WebSearchSummary.SEARCH_API -> UiStrings.SEARCH_SUMMARY_SEARCH_API
            WebSearchSummary.UNREADABLE, null -> UiStrings.SEARCH_SUMMARY_UNREADABLE
        }

        private fun busyEnterValue(mode: BusyEnterMode?): String = when (mode) {
            BusyEnterMode.QUEUE -> UiStrings.BUSY_ENTER_QUEUE
            BusyEnterMode.STEER -> UiStrings.BUSY_ENTER_STEER
            null -> UiStrings.UNKNOWN
        }

        private fun tierTitle(tier: PermissionTier): String = when (tier) {
            PermissionTier.VIEW_ONLY -> UiStrings.PERMISSION_TIER_VIEW_ONLY
            PermissionTier.WORKSPACE_WRITE -> UiStrings.PERMISSION_TIER_WORKSPACE_WRITE
            PermissionTier.FULL_ACCESS -> UiStrings.PERMISSION_TIER_FULL_ACCESS
        }

        private fun platformRows(facts: SettingsPlatformFacts): List<SettingsRowView> = listOf(
            SettingsRowView(
                id = NOTIFICATIONS_ROW_ID,
                kind = SettingsRowKind.VALUE,
                title = UiStrings.SETTINGS_NOTIFICATIONS,
                value = when (facts.notifications) {
                    FactState.YES -> UiStrings.SETTINGS_NOTIFICATIONS_ON
                    FactState.NO -> UiStrings.SETTINGS_NOTIFICATIONS_DEGRADED
                    FactState.UNKNOWN -> UiStrings.UNKNOWN
                },
                tone = when (facts.notifications) {
                    FactState.YES -> PageTone.ON
                    FactState.NO -> PageTone.DEGRADED
                    FactState.UNKNOWN -> PageTone.UNKNOWN
                },
                subtitle = when (facts.notifications) {
                    FactState.YES -> UiStrings.SETTINGS_NOTIFICATIONS_ON_HINT
                    FactState.NO -> UiStrings.SETTINGS_NOTIFICATIONS_DEGRADED_HINT
                    FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                },
            ),
            SettingsRowView(
                id = BATTERY_ROW_ID,
                kind = SettingsRowKind.VALUE,
                title = UiStrings.SETTINGS_BATTERY,
                value = when (facts.batteryExemption) {
                    FactState.YES -> UiStrings.SETTINGS_BATTERY_EXEMPT
                    FactState.NO -> UiStrings.SETTINGS_BATTERY_NOT_EXEMPT
                    FactState.UNKNOWN -> UiStrings.UNKNOWN
                },
                tone = when (facts.batteryExemption) {
                    FactState.YES -> PageTone.ON
                    FactState.NO -> PageTone.DEGRADED
                    FactState.UNKNOWN -> PageTone.UNKNOWN
                },
                subtitle = when (facts.batteryExemption) {
                    FactState.YES -> UiStrings.SETTINGS_BATTERY_EXEMPT_HINT
                    FactState.NO -> UiStrings.SETTINGS_BATTERY_NOT_EXEMPT_HINT
                    FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                },
            ),
            SettingsRowView(
                id = BACK_ROW_ID,
                kind = SettingsRowKind.VALUE,
                title = UiStrings.SETTINGS_BACK,
                value = when (facts.predictiveBack) {
                    FactState.YES -> UiStrings.SETTINGS_BACK_PREDICTIVE
                    FactState.NO -> UiStrings.SETTINGS_BACK_NOT_ENABLED
                    FactState.UNKNOWN -> UiStrings.UNKNOWN
                },
                // The back form is a platform difference, not a capability the
                // user lost: it is never inked as a degradation.
                tone = when (facts.predictiveBack) {
                    FactState.YES -> PageTone.ON
                    FactState.NO -> PageTone.NORMAL
                    FactState.UNKNOWN -> PageTone.UNKNOWN
                },
                subtitle = when (facts.predictiveBack) {
                    FactState.YES -> UiStrings.SETTINGS_BACK_PREDICTIVE_HINT
                    FactState.NO -> UiStrings.SETTINGS_BACK_NOT_ENABLED_HINT
                    FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                },
                dividerBelow = false,
            ),
        )
    }
}

/**
 * One permission preset row of the 新会话默认权限 sub-page.
 *
 * @param tier the preset this row selects.
 * @param title its wording, in the same words the chat permission menu uses.
 * @param selected whether it is the current preset.
 */
@Immutable
public data class PermissionOptionView(
    public val tier: PermissionTier,
    public val title: String,
    public val selected: Boolean,
)

/**
 * The 权限 sub-page's state, mirroring the baseline's PermissionDefaultsPage.
 *
 * @param note the baseline's one explanatory line, verbatim.
 * @param options the three presets in menu order.
 */
@Immutable
public data class PermissionDefaultsState(
    public val note: String = UiStrings.PERMISSION_DEFAULTS_NOTE,
    public val options: List<PermissionOptionView> = emptyList(),
) {
    public companion object {
        /** Projects the host's current preset into the three option rows. */
        public fun from(selected: PermissionTier?): PermissionDefaultsState = PermissionDefaultsState(
            options = listOf(
                PermissionTier.VIEW_ONLY,
                PermissionTier.WORKSPACE_WRITE,
                PermissionTier.FULL_ACCESS,
            ).map { tier ->
                PermissionOptionView(
                    tier = tier,
                    title = when (tier) {
                        PermissionTier.VIEW_ONLY -> UiStrings.PERMISSION_TIER_VIEW_ONLY
                        PermissionTier.WORKSPACE_WRITE -> UiStrings.PERMISSION_TIER_WORKSPACE_WRITE
                        PermissionTier.FULL_ACCESS -> UiStrings.PERMISSION_TIER_FULL_ACCESS
                    },
                    selected = tier == selected,
                )
            },
        )
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The settings index: the baseline's thirteen rows, one call site each.
 *
 * The structure is written out here, as it is in the Swift body, because the row
 * order, the group titles and the row labels are fixed copy rather than host data.
 * `spec/ui/v1/tools/page_structure_check.py` reads exactly this: a label passed as
 * a `UiStrings` constant is comparable to the iOS contract, a label read from the
 * state is not. Values, tones and destinations still come from
 * [SettingsScreenState] through `row(id)`; only the data is dynamic.
 *
 * @param state the pure screen state (`SettingsScreenState.from`).
 * @param onNavigate a navigation or action row was tapped.
 * @param onToggleBackgroundKeepAlive the 后台运行 switch was flipped.
 * @param onSelectBusyEnterMode the 发送消息时 picker picked a mode.
 * @param onBack leave the page (the baseline's 完成).
 */
@Composable
public fun SettingsPage(
    state: SettingsScreenState,
    onNavigate: (SettingsDestination) -> Unit,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
    onSelectBusyEnterMode: (BusyEnterMode) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PageFrame(
        title = UiStrings.SETTINGS,
        // The baseline's only chrome action is 完成 (a modal sheet's cancellation
        // action, leading in iOS). This frame has one trailing action slot, so the
        // wording and the effect match and the side differs.
        actions = { SettingsDoneAction(onDone = onBack) },
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiTags.SETTINGS_LIST),
        ) {
            // mainGroup (SettingsPage.swift:69): five rows and no group header.
            item(key = "row.permission") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_PERMISSION,
                    row = state.row(SettingsScreenState.PERMISSION_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.ask") {
                SettingsValueRow(row = state.row(SettingsScreenState.ASK_ROW_ID))
            }
            item(key = "row.model") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_MODEL_SERVICE,
                    row = state.row(SettingsScreenState.MODEL_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.mcp") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_MCP,
                    row = state.row(SettingsScreenState.MCP_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.background") {
                val background = state.row(SettingsScreenState.BACKGROUND_ROW_ID)
                if (background?.kind == SettingsRowKind.TOGGLE) {
                    SettingsSwitchRow(
                        label = UiStrings.SETTINGS_ROW_BACKGROUND,
                        row = background,
                        onToggle = onToggleBackgroundKeepAlive,
                    )
                } else {
                    // Unread: no switch position is drawn (see SettingsFacts).
                    SettingsValueRow(row = background)
                }
            }

            // toolsGroup (SettingsPage.swift:86): header, five rows, one footer.
            item(key = "section.tools") {
                SettingsSectionHeader(
                    title = UiStrings.SETTINGS_GROUP_TOOLS,
                    sectionId = SettingsScreenState.TOOLS_SECTION_ID,
                )
            }
            item(key = "row.web-search") {
                SettingsActionRow(
                    label = UiStrings.WEB_SEARCH_TITLE,
                    row = state.row(SettingsScreenState.WEB_SEARCH_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.network") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_NETWORK,
                    row = state.row(SettingsScreenState.NETWORK_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.plugins") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_PLUGINS,
                    row = state.row(SettingsScreenState.PLUGINS_ROW_ID),
                    chevron = false,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.command") {
                SettingsActionRow(
                    label = UiStrings.TOOLS,
                    row = state.row(SettingsScreenState.COMMAND_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.runtime") {
                // §1's 入口 column names two ways in: the page-header status dot
                // and this row. The baseline body renders neither row (its only
                // declaration is the never-referenced advancedSection), so §1 wins.
                SettingsActionRow(
                    label = UiStrings.RUNTIME_TITLE,
                    row = state.row(SettingsScreenState.RUNTIME_ROW_ID),
                    chevron = true,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.busy-enter") {
                SettingsPickerRow(
                    row = state.row(SettingsScreenState.BUSY_ENTER_ROW_ID),
                    onSelect = onSelectBusyEnterMode,
                )
            }
            val toolsFooter = state.footer(SettingsScreenState.TOOLS_SECTION_ID)
            if (toolsFooter != null) {
                item(key = "footer.tools") {
                    SettingsFooter(text = toolsFooter, sectionId = SettingsScreenState.TOOLS_SECTION_ID)
                }
            }

            // aboutGroup (SettingsPage.swift:118): header, three rows.
            item(key = "section.about") {
                SettingsSectionHeader(
                    title = UiStrings.ABOUT,
                    sectionId = SettingsScreenState.ABOUT_SECTION_ID,
                )
            }
            item(key = "row.version") {
                SettingsValueRow(row = state.row(SettingsScreenState.VERSION_ROW_ID))
            }
            item(key = "row.licenses") {
                // iOS's LicensesPage lists SwiftTerm and swift-nio; this app ships
                // neither, so there is nothing to open. The row stays (the baseline
                // has it) and explains itself instead of navigating nowhere.
                SettingsActionRow(
                    label = UiStrings.ABOUT_LICENSES,
                    row = state.row(SettingsScreenState.LICENSES_ROW_ID),
                    chevron = false,
                    enabled = false,
                    note = UiStrings.SETTINGS_LICENSES_ANDROID_ONLY,
                    onOpen = onNavigate,
                )
            }
            item(key = "row.export") {
                SettingsActionRow(
                    label = UiStrings.SETTINGS_ROW_EXPORT,
                    row = state.row(SettingsScreenState.EXPORT_ROW_ID),
                    chevron = false,
                    onOpen = onNavigate,
                )
            }

            // The Android-only appendix (whitelisted in
            // `spec/ui/v1/pages/_whitelist.json` as `settings.platform-appendix`).
            item(key = "section.platform") {
                SettingsSectionHeader(
                    title = UiStrings.SETTINGS_PLATFORM,
                    sectionId = SettingsScreenState.PLATFORM_SECTION_ID,
                )
            }
            item(key = "row.notifications") {
                SettingsValueRow(row = state.row(SettingsScreenState.NOTIFICATIONS_ROW_ID))
            }
            item(key = "row.battery") {
                SettingsValueRow(row = state.row(SettingsScreenState.BATTERY_ROW_ID))
            }
            item(key = "row.back") {
                SettingsValueRow(row = state.row(SettingsScreenState.BACK_ROW_ID))
            }
        }
    }
}

/**
 * The 新会话默认权限 sub-page the 权限 row opens.
 *
 * The baseline keeps it as an inline child page, so it lives here rather than in a
 * page of its own. Its note is the one sentence that explains the scope of the
 * setting, kept word for word.
 *
 * @param state the pure sub-page state (`PermissionDefaultsState.from`).
 * @param onSelect a preset was tapped; the host writes it and re-projects.
 * @param onBack leave the sub-page.
 */
@Composable
public fun PermissionDefaultsPage(
    state: PermissionDefaultsState,
    onSelect: (PermissionTier) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    PageFrame(
        title = UiStrings.PERMISSION_DEFAULTS_TITLE,
        onBack = onBack,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.PERMISSION_DEFAULTS_LIST),
        ) {
            item(key = "note") {
                PermissionNote(text = state.note)
            }
            items(count = state.options.size, key = { index -> "option.${state.options[index].tier.name}" }) { index ->
                val option = state.options[index]
                PermissionOptionRow(option = option, onClick = { onSelect(option.tier) })
            }
        }
    }
}

/** The baseline's group header: 13pt, secondary ink, 24 above and 8 below. */
@Composable
private fun SettingsSectionHeader(title: String, sectionId: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = title,
        style = type.caption.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_SECTION_PREFIX + sectionId)
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                start = tokens.geometry.pageOuterMarginH,
                end = tokens.geometry.pageOuterMarginH,
                // The baseline's header insets are 24/8. tokens.json has no 24,
                // so the nearest page-level spacing (cardInset, 12) is used; the 8
                // has an exact token. The missing 24 is reported as a spec gap.
                top = tokens.spacing.cardInset,
                bottom = tokens.spacing.codeToolbar,
            )
            .semantics { heading() },
    )
}

/**
 * One row that opens something: label, trailing value, optional chevron.
 *
 * The label is a parameter so the page's call site carries the literal: the
 * structure gate compares that literal with the iOS contract.
 */
@Composable
private fun SettingsActionRow(
    label: String,
    row: SettingsRowView?,
    chevron: Boolean,
    onOpen: (SettingsDestination) -> Unit,
    enabled: Boolean = true,
    note: String? = null,
) {
    if (row == null) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val destination = row.destination
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_ROW_PREFIX + row.id),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(
                    enabled = enabled,
                    role = Role.Button,
                    onClick = { destination?.let(onOpen) },
                )
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                )
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = label,
                style = type.body.copy(
                    color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
                ),
                modifier = Modifier.weight(1f),
            )
            val value = row.value
            if (value != null) {
                BasicText(
                    text = value,
                    style = type.secondary.copy(color = row.tone.settingsInk(tokens)),
                    maxLines = 1,
                    // The baseline truncates in the middle; Compose 1.7 has no
                    // middle ellipsis, so the end is truncated.
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (chevron) {
                // unverified geometry: the baseline reserves a 20pt chevron slot;
                // the closest token is the 6pt iconText gap.
                BasicText(
                    text = ROW_CHEVRON,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        }
        if (note != null) {
            BasicText(
                text = note,
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier.padding(
                    start = tokens.geometry.pageOuterMarginH,
                    end = tokens.geometry.pageOuterMarginH,
                    bottom = tokens.spacing.badgeInsetV,
                ),
            )
        }
        if (row.dividerBelow) {
            SettingsDivider()
        }
    }
}

/**
 * One read-only row: label and value from the state, no tap target.
 *
 * The label stays dynamic on purpose: these rows are information, not actions
 * (`写之前` reports a fact, `版本` a build string, the appendix three platform
 * facts), and the structure gate must not count them among the baseline's actions.
 */
@Composable
private fun SettingsValueRow(row: SettingsRowView?) {
    if (row == null) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_ROW_PREFIX + row.id),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                )
                .semantics(mergeDescendants = true) {},
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                BasicText(
                    text = row.title,
                    style = type.body.copy(color = tokens.colors.primary),
                    modifier = Modifier.weight(1f),
                )
                val value = row.value
                if (value != null) {
                    BasicText(
                        text = value,
                        style = type.secondary.copy(color = row.tone.settingsInk(tokens)),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            val subtitle = row.subtitle
            if (subtitle != null) {
                BasicText(
                    text = subtitle,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        }
        if (row.dividerBelow) {
            SettingsDivider()
        }
    }
}

/**
 * 后台运行: the switch row.
 *
 * A tap target with the switch role, drawn in words like the other settings rows;
 * the label is a parameter for the same reason as [SettingsActionRow].
 */
@Composable
private fun SettingsSwitchRow(
    label: String,
    row: SettingsRowView?,
    onToggle: (Boolean) -> Unit,
) {
    if (row == null) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_ROW_PREFIX + row.id),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .testTag(UiPageTags.SETTINGS_ROW_TOGGLE)
                .clickable(
                    enabled = row.enabled,
                    role = Role.Switch,
                    onClick = { onToggle(!row.checked) },
                )
                .semantics(mergeDescendants = true) {
                    if (row.value != null) stateDescription = row.value
                }
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = label,
                style = type.body.copy(
                    color = if (row.enabled) tokens.colors.primary else tokens.colors.tertiary,
                ),
                modifier = Modifier.weight(1f),
            )
            val value = row.value
            if (value != null) {
                BasicText(
                    text = value,
                    style = type.secondary.copy(color = row.tone.settingsInk(tokens)),
                )
            }
        }
        if (row.dividerBelow) {
            SettingsDivider()
        }
    }
}

/**
 * 发送消息时: the baseline's menu picker, rendered as an inline choice.
 *
 * The trigger's label is dynamic and the two options are state text, so neither is
 * one of the contract's labelled actions (the contract marks the picker itself as
 * having no label). Tapping the row reveals the two modes below it.
 */
@Composable
private fun SettingsPickerRow(
    row: SettingsRowView?,
    onSelect: (BusyEnterMode) -> Unit,
) {
    if (row == null) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var expanded by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_ROW_PREFIX + row.id),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(role = Role.Button, onClick = { expanded = !expanded })
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                )
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = row.title,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            val value = row.value
            if (value != null) {
                BasicText(
                    text = value,
                    style = type.secondary.copy(color = row.tone.settingsInk(tokens)),
                )
            }
        }
        if (expanded) {
            row.options.forEach { option ->
                val selected = option.mode == row.mode
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                        .testTag(UiPageTags.SETTINGS_ROW_OPTION_PREFIX + option.mode.id)
                        .clickable(
                            role = Role.RadioButton,
                            onClick = {
                                expanded = false
                                onSelect(option.mode)
                            },
                        )
                        .padding(
                            horizontal = tokens.geometry.pageOuterMarginH,
                            vertical = tokens.spacing.iconText,
                        )
                        .semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    BasicText(
                        text = option.title,
                        style = type.body.copy(
                            color = if (selected) tokens.colors.accent else tokens.colors.primary,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    if (selected) {
                        BasicText(
                            text = CHECKMARK,
                            style = type.body.copy(color = tokens.colors.accent),
                        )
                    }
                }
            }
        }
        if (row.dividerBelow) {
            SettingsDivider()
        }
    }
}

/** The section footer line: 13pt, secondary ink, directly under the rows. */
@Composable
private fun SettingsFooter(text: String, sectionId: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SETTINGS_FOOTER_PREFIX + sectionId)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The baseline's self-drawn hairline: 16 to 386 on a 402pt-wide screen. */
@Composable
private fun SettingsDivider() {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .height(tokens.stroke.hairline)
            .background(tokens.colors.border),
    )
}

/** 完成: the baseline's only chrome action on this sheet. */
@Composable
private fun SettingsDoneAction(onDone: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.SETTINGS_DONE,
        style = type.body.copy(color = tokens.colors.accent),
        modifier = Modifier
            .testTag(UiPageTags.SETTINGS_DONE)
            .clickable(role = Role.Button, onClick = onDone)
            .padding(tokens.spacing.iconText),
    )
}

/** The 新会话默认权限 note: the baseline's scope sentence, in caption ink. */
@Composable
private fun PermissionNote(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.secondary.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PERMISSION_DEFAULTS_NOTE)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                // The note sits above the option group like a group header; its
                // 24pt inset has no token, so the same 12pt approximation applies.
                vertical = tokens.spacing.cardInset,
            ),
    )
}

/** One preset: title, and a checkmark on the selected one. */
@Composable
private fun PermissionOptionRow(option: PermissionOptionView, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PERMISSION_DEFAULTS_OPTION_PREFIX + option.tier.name)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = option.title,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        if (option.selected) {
            BasicText(
                text = CHECKMARK,
                style = type.body.copy(color = tokens.colors.accent),
            )
        }
    }
}

/** The value ink: the baseline's secondary for a plain value, a tone for a fact. */
private fun PageTone.settingsInk(tokens: UiTokens): Color = when (this) {
    PageTone.NORMAL -> tokens.colors.secondary
    PageTone.ON -> tokens.colors.success
    PageTone.DEGRADED -> tokens.colors.warning
    PageTone.UNKNOWN -> tokens.colors.tertiary
}

/** The menu entries of 发送消息时, in the baseline's order. */
private val BUSY_ENTER_OPTIONS: List<SettingsMenuOption> = listOf(
    SettingsMenuOption(mode = BusyEnterMode.QUEUE, title = UiStrings.BUSY_ENTER_QUEUE),
    SettingsMenuOption(mode = BusyEnterMode.STEER, title = UiStrings.BUSY_ENTER_STEER),
)

private const val ROW_CHEVRON: String = "›"
private const val CHECKMARK: String = "✓"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads, so a new reference cannot slip in unlisted and a stale entry fails too.
 */
internal object SettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
        UiTokenNames.SPACING_CARD_INSET,
    )
}
