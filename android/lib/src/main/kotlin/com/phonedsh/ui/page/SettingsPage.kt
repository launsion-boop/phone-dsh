// Settings: the PR22 grouped phone-settings index and its local child pages.
// SPDX-License-Identifier: MIT
//
// The index follows `examples/probe-app/PhoneDSHProbe/SettingsPage.swift` at
// iOS HEAD: Models and agents, Permissions and privacy, Conversation, Sessions
// and files, Engine, About. The former segmented shell is gone; [SettingsTab]
// survives only as the host's deep-entry key, and [tabContent] is used only for
// that direct entry.
//
// Values are copied from [SettingsFacts] and [SettingsPreferences]. A null host
// fact is shown as unknown/unavailable, and an optional host action is disabled
// when its caller has not supplied a real destination. The host still owns the
// permission, provider, session-count, permission-summary, and callback wiring.
//
// Index rows use the PR22 48pt minimum grouped-list pitch, registered
// [com.phonedsh.ui.icon.PdshIcons], and the shared HomeSpec semantic palette.
// The old pure `SettingsScreenState.sections` projection remains for the shared
// settings preference IDs consumed by the existing PreferenceStore.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.EngineLifecycleFacts
import com.phonedsh.ui.state.EngineLifecycleStatus
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsChevronSlot
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsGroupedRow
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.settingsSystemInk
import com.phonedsh.ui.surface.LocalSettingsRowInk
import com.phonedsh.ui.surface.SettingsListTopInset
import com.phonedsh.ui.surface.SettingsMenuChevron
import com.phonedsh.ui.surface.SettingsMenuChevronSlot
import com.phonedsh.ui.surface.SettingsMenuTrailingInset
import com.phonedsh.ui.surface.SettingsNavBar
import com.phonedsh.ui.surface.SettingsRowFrame
import com.phonedsh.ui.surface.SettingsRowLabel
import com.phonedsh.ui.surface.SettingsRowValue
import com.phonedsh.ui.surface.SettingsSegmentedPicker
import com.phonedsh.ui.surface.SettingsSegmentPaddingV
import com.phonedsh.ui.surface.SettingsSegmentTopGap
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsSwitch
import com.phonedsh.ui.surface.SettingsSwitchTrailingInset
import com.phonedsh.ui.surface.SettingsTrailingSlot
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/**
 * The five tabs, in the baseline's order and with its words.
 *
 * `shortTitle` is the segmented segment's text (`SettingsPage.swift:21-29`);
 * `title` is the tab's full name and the `navigationTitle` its page sets
 * (`SettingsPage.swift:12-20`). [barTitle] is `null` for the four tabs whose page
 * draws a 34 pt large title instead of an inline one, so the shell does not draw
 * a second title above the content's own.
 */
public enum class SettingsTab(
    public val id: String,
    public val shortTitle: String,
    public val title: String,
) {
    GENERAL("general", "通用", "通用设置"),
    MODELS("models", "模型", "模型服务"),
    PLUGINS("plugins", "插件", "内置插件"),
    PERMISSIONS("permissions", "手机权限", "手机权限"),
    PRESETS("presets", "预设", "Agent 预设"),
    ;

    /**
     * The inline title the shell's 44 pt bar draws, or `null` when the tab's page
     * owns a large title. 通用 is the one tab the baseline renders inline.
     */
    public val barTitle: String? get() = if (this == GENERAL) title else null

    public companion object {
        /** The order the segmented picker draws. */
        public val order: List<SettingsTab> = entries.toList()
    }
}

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

/** 语言: the three choices `SettingsPage.swift:109-114` offers, in its order. */
public enum class SettingsLanguage(public val id: String, public val label: String) {
    ZH("zh", "中文"),
    EN("en", "English"),
    SYSTEM("system", "跟随系统"),
}

/** 外观: `SettingsPage.swift:115-120`. */
public enum class SettingsAppearance(public val id: String, public val label: String) {
    LIGHT("light", "浅色"),
    DARK("dark", "深色"),
    SYSTEM("system", "跟随系统"),
}

/** 工作步骤展示: `SettingsPage.swift:131-137`, four modes in the baseline's order. */
public enum class TranscriptViewMode(public val id: String, public val label: String) {
    COMPACT("compact", "简洁"),
    STANDARD("standard", "标准"),
    DETAILED("detailed", "详细"),
    VERBOSE("verbose", "完全展开"),
}

/** 工作步骤收起时机: `SettingsPage.swift:138-142`. */
public enum class CollapseTiming(public val id: String, public val label: String) {
    COMPLETION("completion", "回答结束后"),
    NEXT_INPUT("nextInput", "下次有新消息时"),
}

/** 性能与用量: `SettingsPage.swift:156-160`. */
public enum class PerformanceUsage(public val id: String, public val label: String) {
    COMPACT("compact", "简洁"),
    DETAILED("detailed", "详细"),
}

/** How one row behaves when it is tapped. */
public enum class SettingsRowKind {
    /** Opens a page (the baseline's NavigationLink): label, value, chevron. */
    NAVIGATION,

    /** Label and value without a chevron (当前版本, the appendix facts). */
    VALUE,

    /** A switch (后台运行, 显示代码工作视图). */
    TOGGLE,

    /** A picker rendered as an inline menu (语言, 外观, 工作步骤展示, …). */
    MENU,

    /** The 13 pt explanatory line inside a card. Carries [SettingsRowView.text]. */
    FOOTNOTE,

    /** A plain in-card action such as acknowledging a failed engine. */
    ACTION,
}

/**
 * Where a navigation row goes.
 *
 * The set is unchanged from the flat index: `PdshRoute`'s exhaustive `when` over
 * this enum is another lane's file, so a new value here would be a build break
 * there. The three rows that need a destination this app does not have (字号大小,
 * 快捷键, and 开源许可, which is an iOS-only list) hand their id to the host, which
 * maps them to a route or to nothing.
 *
 * L55 appended two values that are **not** routes: [ABOUT] and [DEV_TOOLS] are
 * sub-surfaces of the settings sheet itself. In the baseline the about page is a
 * settings-family page (`SettingsAboutPage`, preview-only after PR #13), and the
 * developer-tools page that hosted `MemoryPage`/`ProbesPage`/`BackgroundPage`/
 * `TaskScreenPage` was deleted by the same PR — so their Android entries belong
 * inside the sheet, not on the route stack. `PdshSettingsRows.targetOf` returns
 * `null` for both, and `SettingsRoute` swaps its own body instead.
 */
public enum class SettingsDestination {
    PERMISSION_DEFAULTS,
    MODEL_PROVIDER,
    MCP,

    /** SSH 主机: saved native SSH connections (docs/native-ssh.md). */
    SSH,

    /** 蓝牙设备: scan + standard GATT (`spec/device/v1/android-standard-gatt.md`). */
    BLUETOOTH,
    WEB_SEARCH,
    EGRESS,
    PLUGIN_CONFIGURATION,
    COMMAND,
    RUNTIME_DETAILS,
    LICENSES,
    EXPORT_DIAGNOSTICS,
    SHORTCUTS,

    /** 关于: the settings about page (版本 / 平台 / 开源许可). */
    ABOUT,

    /** 开发者工具: the Android-only index of the pages iOS left without an entry. */
    DEV_TOOLS,
}

/** One entry of a menu row's menu. */
@Immutable
public data class SettingsMenuOption(
    /** The persisted id the host writes (the baseline's `@AppStorage` tag). */
    public val id: String,
    public val title: String,
)

/**
 * The row id a picker reported, and the option id it reported.
 *
 * One callback shape for all five pickers (语言 / 外观 / 工作步骤展示 /
 * 工作步骤收起时机 / 性能与用量) keeps [SettingsPage]'s signature from growing one
 * parameter per row. 繁忙时的发送行为 keeps its own typed callback because the
 * host already writes a [BusyEnterMode] for it.
 */
@Immutable
public data class SettingsPreferenceChoice(
    public val rowId: String,
    public val optionId: String,
)

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The Android-only platform facts the appendix card reports.
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
 * The 通用 tab's five preferences, one field per picker or switch.
 *
 * Every field is nullable/`UNKNOWN` on purpose: `null` means "the host did not
 * report this value", which renders 未设置 — not the first option of the menu,
 * which would be a plausible default the user never chose.
 *
 * @param language 语言 (`SettingsPage.swift:109`).
 * @param appearance 外观 (`:115`).
 * @param fontSizeConversation 字号大小 › 会话内容 (`:121-125`), in px.
 * @param fontSizeCode 字号大小 › 代码.
 * @param fontSizeTerminal 字号大小 › 终端.
 * @param transcriptView 工作步骤展示 (`:131`).
 * @param collapseTiming 工作步骤收起时机 (`:138`).
 * @param developerTools 显示代码工作视图 (`:143`, a switch).
 * @param shortcutCount 快捷键 › 编辑 (`:145`): how many bindings the host has, or
 *   `null` when it does not count them.
 * @param performanceUsage 性能与用量 (`:156`).
 */
@Immutable
public data class SettingsPreferences(
    public val language: SettingsLanguage? = null,
    public val appearance: SettingsAppearance? = null,
    public val fontSizeConversation: Int? = null,
    public val fontSizeCode: Int? = null,
    public val fontSizeTerminal: Int? = null,
    /** Host-stored font names; null means the host cannot report this role. */
    public val fontFamilyConversation: String? = null,
    public val fontFamilyCode: String? = null,
    public val fontFamilyTerminal: String? = null,
    public val transcriptView: TranscriptViewMode? = null,
    public val collapseTiming: CollapseTiming? = null,
    public val developerTools: FactState = FactState.UNKNOWN,
    public val shortcutCount: Int? = null,
    public val performanceUsage: PerformanceUsage? = null,
)

/**
 * The page's read-only input.
 *
 * @param defaultPermissionTier the host's preset for new sessions; `null` when
 *   it has none or reports a preset this page does not know.
 * @param preferences the 通用 tab's five preferences.
 * @param backgroundKeepAlive the 后台运行 switch (Android-only); `UNKNOWN`
 *   renders 未知 and no switch, because a switch in a position we did not read
 *   would be a guess.
 * @param busyEnterMode 繁忙时的发送行为; `null` = 未知.
 * @param versionName 当前版本; `null` = 未知.
 * @param searchLaunchWarning the active surface's launch warning, verbatim; it
 *   has the first claim on the appendix status line.
 * @param engineStarted whether the local engine is up; needed for the
 *   "重启本地引擎后生效。" branch.
 * @param networkConfigurationChanged the network configuration differs from the
 *   engine's running one.
 * @param didSave a save happened.
 * @param platform the Android-only appendix facts.
 * @param modelProviderName / @param mcpServerCount / @param webSearch /
 *   @param egressAddressCount are the host's answers about the pages the 模型 and
 *   插件 tabs render. This sheet no longer draws them: after PR #13 those are
 *   whole pages, not rows. They stay on the facts object because the host reports
 *   them and the tab pages' own states are built from the same snapshot; a
 *   consumer that reads them from here is reading the summary, not the page.
 */
@Immutable
public data class SettingsFacts(
    public val defaultPermissionTier: PermissionTier? = null,
    /** Permission modes actually reported by `permissionPresets/catalog`; null means unread. */
    public val defaultPermissionAvailableTiers: Set<PermissionTier>? = null,
    /** Whether the host reports this one field writable (not the provider-wide flag). */
    public val defaultPermissionWritable: Boolean = false,
    /** A confirmed permission default write is in flight. */
    public val defaultPermissionBusy: Boolean = false,
    /** Actual source read/write failure, if reported. */
    public val defaultPermissionFailure: String? = null,
    /**
     * Why the new-session default is read-only, when the host measured a lock
     * instead of a plain refusal (the phone image's startup home patch).
     */
    public val defaultPermissionReadOnlyReason: String? = null,
    /** True when the lock is the startup overlay rather than a provider-wide refusal. */
    public val defaultPermissionStartupLocked: Boolean = false,
    public val preferences: SettingsPreferences = SettingsPreferences(),
    public val backgroundKeepAlive: FactState = FactState.UNKNOWN,
    public val busyEnterMode: BusyEnterMode? = null,
    public val versionName: String? = null,
    public val searchLaunchWarning: String? = null,
    public val engineStarted: FactState = FactState.UNKNOWN,
    public val networkConfigurationChanged: Boolean = false,
    public val didSave: Boolean = false,
    public val platform: SettingsPlatformFacts? = null,
    public val modelProviderName: String? = null,
    /** Whether provider/key setup is required; true includes first-run and missing-key cases, null means unread. */
    public val providerSetupRequired: Boolean? = null,
    public val mcpServerCount: Int? = null,
    public val webSearch: WebSearchSummary? = null,
    public val egressAddressCount: Int? = null,
    /** Current engine lifecycle and reset requirement; null means unread. */
    public val engineLifecycle: EngineLifecycleFacts? = null,
    /** Counts read by the host's session manager; null means unread. */
    public val folderCount: Int? = null,
    public val archivedSessionCount: Int? = null,
    /** Permission grant summary read from the host; null means unread. */
    public val phonePermissionSummary: String? = null,
    /** Android package `versionCode`; null means the host did not report the build value. */
    public val buildNumber: String? = null,
    /** Raw package version for About; the index may use a separate signing-qualified label. */
    public val rawVersionName: String? = null,
)

/** The web-search page's summary; kept for the host's snapshot, not drawn here. */
public enum class WebSearchSummary {
    /** 沿用模型服务: explicit fallback, official Messages endpoint only. */
    FOLLOW_MODEL,

    /** 独立 DeepSeek 搜索 API. */
    SEARCH_API,

    /** 网页搜索配置不可读: the baseline's one wording for an unreadable config. */
    UNREADABLE,
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One row of the 通用 tab. */
@Immutable
public data class SettingsRowView(
    public val id: String,
    public val kind: SettingsRowKind,
    /** The row's fixed label; empty for a [SettingsRowKind.FOOTNOTE] row. */
    public val title: String,
    /** Trailing value; `null` when the baseline renders an empty value. */
    public val value: String? = null,
    /** The footnote's text; only a [SettingsRowKind.FOOTNOTE] row has one. */
    public val text: String? = null,
    /** Optional explanatory second line under the label (the appendix facts). */
    public val subtitle: String? = null,
    public val tone: PageTone = PageTone.NORMAL,
    /** Target of a NAVIGATION row. */
    public val destination: SettingsDestination? = null,
    /** TOGGLE position; only meaningful when the facts reported one. */
    public val checked: Boolean = false,
    public val enabled: Boolean = true,
    /** MENU entries; empty for every other kind. */
    public val options: List<SettingsMenuOption> = emptyList(),
    /** MENU selection; `null` = 未知. */
    public val selectedOptionId: String? = null,
    /** The baseline draws a 1 pt separator under every row except a card's last. */
    public val dividerBelow: Boolean = true,
)

/**
 * One card of the 通用 tab: its id and the rows in the baseline's order.
 *
 * The card titles are not here: after PR #13 the baseline renders **no** section
 * headers on this page (only two footnotes *inside* cards), so a card has no
 * title to carry. The Android-only appendix card is labelled by its own row
 * copy, not by a header, for the same reason.
 */
@Immutable
public data class SettingsSectionView(
    public val id: String,
    public val rows: List<SettingsRowView>,
)

/** The complete 通用 tab state. */
@Immutable
public data class SettingsScreenState(
    public val sections: List<SettingsSectionView>,
    public val engineLifecycle: EngineLifecycleFacts? = null,
    public val modelProviderName: String? = null,
    public val providerSetupRequired: Boolean? = null,
    public val folderCount: Int? = null,
    public val archivedSessionCount: Int? = null,
    public val phonePermissionSummary: String? = null,
    public val versionName: String? = null,
    public val preferences: SettingsPreferences = SettingsPreferences(),
    public val defaultPermissionTier: PermissionTier? = null,
    public val defaultPermissionAvailableTiers: Set<PermissionTier>? = null,
    public val defaultPermissionWritable: Boolean = false,
    public val defaultPermissionBusy: Boolean = false,
    public val defaultPermissionFailure: String? = null,
    public val defaultPermissionReadOnlyReason: String? = null,
    public val defaultPermissionStartupLocked: Boolean = false,
    public val busyEnterMode: BusyEnterMode? = null,
) {
    /** One row by id. */
    public fun row(id: String): SettingsRowView? =
        sections.firstNotNullOfOrNull { section -> section.rows.firstOrNull { it.id == id } }

    /** One card by id, or `null` when this projection has no such card. */
    public fun section(id: String): SettingsSectionView? = sections.firstOrNull { it.id == id }

    public companion object {
        /** The 权限 card (`SettingsPage.swift:100-106`). */
        public const val PERMISSION_SECTION_ID: String = "permission"
        public const val ENGINE_SECTION_ID: String = "engine"
        public const val ENGINE_STATUS_ROW_ID: String = "engine.status"
        public const val ENGINE_RESTART_ROW_ID: String = "engine.restart"
        public const val ENGINE_RESTART_HINT_ROW_ID: String = "engine.restartHint"

        /** The 语言 / 外观 / 字号大小 card (`:108-128`). */
        public const val PREFERENCES_SECTION_ID: String = "preferences"

        /** The 工作步骤展示 … 快捷键 card (`:130-148`). */
        public const val WORK_SECTION_ID: String = "work"

        /** The 繁忙时的发送行为 / 性能与用量 card (`:150-161`). */
        public const val COMPOSER_SECTION_ID: String = "composer"

        /** The 当前版本 / 开源许可 card (`:163-166`). */
        public const val ABOUT_SECTION_ID: String = "about"

        /** The Android-only appendix card (see the file header). */
        public const val PLATFORM_SECTION_ID: String = "platform"

        /** Row ids, in the order the baseline renders them. */
        public const val PERMISSION_ROW_ID: String = "permission.default"
        public const val PERMISSION_NOTE_ROW_ID: String = "permission.note"
        public const val LANGUAGE_ROW_ID: String = "preference.language"
        public const val APPEARANCE_ROW_ID: String = "preference.appearance"
        public const val FONT_SIZE_ROW_ID: String = "preference.fontSize"
        public const val FONT_NOTE_ROW_ID: String = "preference.fontNote"

        /**
         * 字号大小 › 正文: the chat-appearance page's text-size stepper.
         *
         * The index's 字号大小 row is one navigation row; the steppers live on
         * `ChatPreferencesPage`, so a size write needs a row id of its own. The
         * option id is the new size as decimal text, and the host clamps it to
         * the baseline's range (10...22, `NativeChatPreferences.swift:41`).
         */
        public const val TEXT_FONT_SIZE_ROW_ID: String = "preference.fontSize.text"

        /** 字号大小 › 代码 (10...16); same shape as [TEXT_FONT_SIZE_ROW_ID]. */
        public const val CODE_FONT_SIZE_ROW_ID: String = "preference.fontSize.code"

        /**
         * 字号大小 › 终端 (10...20).
         *
         * No stepper draws this row today: the index reports all three sizes and
         * the chat-appearance page has 正文 / 代码 controls only. The id exists so
         * the host's stored terminal size has one write vocabulary with the other
         * two, and so a future 终端 control needs no new seam.
         */
        public const val TERMINAL_FONT_SIZE_ROW_ID: String = "preference.fontSize.terminal"
        public const val TRANSCRIPT_VIEW_ROW_ID: String = "work.transcriptView"
        public const val COLLAPSE_TIMING_ROW_ID: String = "work.collapseTiming"
        public const val DEVELOPER_TOOLS_ROW_ID: String = "work.developerTools"
        public const val SHORTCUTS_ROW_ID: String = "work.shortcuts"
        public const val BUSY_ENTER_ROW_ID: String = "composer.busyEnter"
        public const val PERFORMANCE_ROW_ID: String = "composer.performanceUsage"
        public const val VERSION_ROW_ID: String = "about.version"
        public const val LICENSES_ROW_ID: String = "about.licenses"
        public const val BACKGROUND_ROW_ID: String = "platform.backgroundKeepAlive"
        public const val EXPORT_ROW_ID: String = "platform.exportDiagnostics"
        public const val DEV_TOOLS_ROW_ID: String = "developer.tools"
        public const val NOTIFICATIONS_ROW_ID: String = "platform.notifications"
        public const val BATTERY_ROW_ID: String = "platform.battery"
        public const val BACK_ROW_ID: String = "platform.back"
        public const val STATUS_ROW_ID: String = "platform.status"

        /** Projects the facts into the five mirrored cards plus the appendix. */
        public fun from(facts: SettingsFacts): SettingsScreenState {
            val preferences = facts.preferences
            val backgroundKnown = facts.backgroundKeepAlive != FactState.UNKNOWN
            val developerToolsKnown = preferences.developerTools != FactState.UNKNOWN

            // Card 1: 权限 + the one footnote that explains it (`:100-106`).
            val permission = SettingsSectionView(
                id = PERMISSION_SECTION_ID,
                rows = listOf(
                    SettingsRowView(
                        id = PERMISSION_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = ROW_PERMISSION,
                        value = permissionTitle(facts.defaultPermissionTier),
                        tone = if (facts.defaultPermissionTier == null) PageTone.UNKNOWN else PageTone.NORMAL,
                        destination = SettingsDestination.PERMISSION_DEFAULTS,
                    ),
                    SettingsRowView(
                        id = PERMISSION_NOTE_ROW_ID,
                        kind = SettingsRowKind.FOOTNOTE,
                        title = "",
                        text = NOTE_PERMISSION_SCOPE,
                        dividerBelow = false,
                    ),
                ),
            )

            // Card 2: 语言 / 外观 / 字号大小 + footnote (`:108-128`).
            val preferencesCard = SettingsSectionView(
                id = PREFERENCES_SECTION_ID,
                rows = listOf(
                    pickerRow(
                        id = LANGUAGE_ROW_ID,
                        title = ROW_LANGUAGE,
                        selection = preferences.language?.label,
                        options = SettingsLanguage.entries.map { SettingsMenuOption(it.id, it.label) },
                        selectedId = preferences.language?.id,
                    ),
                    pickerRow(
                        id = APPEARANCE_ROW_ID,
                        title = ROW_APPEARANCE,
                        selection = preferences.appearance?.label,
                        options = SettingsAppearance.entries.map { SettingsMenuOption(it.id, it.label) },
                        selectedId = preferences.appearance?.id,
                    ),
                    SettingsRowView(
                        id = FONT_SIZE_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = ROW_FONT_SIZE,
                        value = fontSizeValue(preferences),
                        tone = if (fontSizeValue(preferences) == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    ),
                    SettingsRowView(
                        id = FONT_NOTE_ROW_ID,
                        kind = SettingsRowKind.FOOTNOTE,
                        title = "",
                        text = NOTE_FONT_SCOPE,
                        dividerBelow = false,
                    ),
                ),
            )

            // Card 3: 工作步骤展示 / 收起时机 / 显示代码工作视图 / 快捷键 (`:130-148`).
            val work = SettingsSectionView(
                id = WORK_SECTION_ID,
                rows = listOf(
                    pickerRow(
                        id = TRANSCRIPT_VIEW_ROW_ID,
                        title = ROW_TRANSCRIPT_VIEW,
                        selection = preferences.transcriptView?.label,
                        options = TranscriptViewMode.entries.map { SettingsMenuOption(it.id, it.label) },
                        selectedId = preferences.transcriptView?.id,
                    ),
                    pickerRow(
                        id = COLLAPSE_TIMING_ROW_ID,
                        title = ROW_COLLAPSE_TIMING,
                        selection = preferences.collapseTiming?.label,
                        options = CollapseTiming.entries.map { SettingsMenuOption(it.id, it.label) },
                        selectedId = preferences.collapseTiming?.id,
                    ),
                    SettingsRowView(
                        id = DEVELOPER_TOOLS_ROW_ID,
                        kind = if (developerToolsKnown) SettingsRowKind.TOGGLE else SettingsRowKind.VALUE,
                        title = ROW_DEVELOPER_TOOLS,
                        value = when (preferences.developerTools) {
                            FactState.YES -> UiStrings.SETTINGS_BACKGROUND_ON
                            FactState.NO -> UiStrings.SETTINGS_BACKGROUND_OFF
                            FactState.UNKNOWN -> UiStrings.UNKNOWN
                        },
                        tone = when (preferences.developerTools) {
                            FactState.YES -> PageTone.ON
                            FactState.NO -> PageTone.NORMAL
                            FactState.UNKNOWN -> PageTone.UNKNOWN
                        },
                        checked = preferences.developerTools == FactState.YES,
                        enabled = developerToolsKnown,
                    ),
                    SettingsRowView(
                        id = SHORTCUTS_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        // The row was drawn without a destination, so tapping it did
                        // nothing while the contract calls this page `must`.
                        destination = SettingsDestination.SHORTCUTS,
                        title = ROW_SHORTCUTS,
                        value = preferences.shortcutCount
                            ?.let { UiStrings.ROW_COUNT.format(it) }
                            ?: VALUE_EDIT,
                        tone = PageTone.NORMAL,
                        dividerBelow = false,
                    ),
                ),
            )

            // Card 4: 繁忙时的发送行为 / 性能与用量 (`:150-161`).
            val composer = SettingsSectionView(
                id = COMPOSER_SECTION_ID,
                rows = listOf(
                    pickerRow(
                        id = BUSY_ENTER_ROW_ID,
                        title = ROW_BUSY_ENTER,
                        selection = facts.busyEnterMode?.let { busyEnterLabel(it) },
                        options = BUSY_ENTER_OPTIONS,
                        selectedId = facts.busyEnterMode?.id,
                    ),
                    pickerRow(
                        id = PERFORMANCE_ROW_ID,
                        title = ROW_PERFORMANCE,
                        selection = preferences.performanceUsage?.label,
                        options = PerformanceUsage.entries.map { SettingsMenuOption(it.id, it.label) },
                        selectedId = preferences.performanceUsage?.id,
                        dividerBelow = false,
                    ),
                ),
            )

            // Card 5: 当前版本 / 开源许可 (`:163-166`).
            val about = SettingsSectionView(
                id = ABOUT_SECTION_ID,
                rows = listOf(
                    SettingsRowView(
                        id = VERSION_ROW_ID,
                        // L55: the version row opens the about page. The label and
                        // the value are unchanged; only the chevron and the
                        // destination are new, and both are the settings sheet's
                        // own (no route).
                        kind = SettingsRowKind.NAVIGATION,
                        title = ROW_VERSION,
                        value = facts.versionName ?: UiStrings.UNKNOWN,
                        tone = if (facts.versionName == null) PageTone.UNKNOWN else PageTone.NORMAL,
                        destination = SettingsDestination.ABOUT,
                    ),
                    SettingsRowView(
                        id = LICENSES_ROW_ID,
                        kind = SettingsRowKind.NAVIGATION,
                        title = UiStrings.ABOUT_LICENSES,
                        subtitle = UiStrings.SETTINGS_LICENSES_ANDROID_ONLY,
                        destination = SettingsDestination.LICENSES,
                        dividerBelow = false,
                    ),
                ),
            )

            // The Android-only card: two controls this app has and iOS does not,
            // three whitelisted platform facts, and the one status line.
            val status = statusLine(facts)
            val appendix = SettingsSectionView(
                id = PLATFORM_SECTION_ID,
                rows = buildList {
                    add(
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
                    )
                    add(
                        SettingsRowView(
                            id = EXPORT_ROW_ID,
                            kind = SettingsRowKind.NAVIGATION,
                            title = UiStrings.SETTINGS_ROW_EXPORT,
                            destination = SettingsDestination.EXPORT_DIAGNOSTICS,
                        ),
                    )
                    // L55: the four developer pages iOS deleted with the
                    // developer-tools page (Memory / 设备探针 / 后台保活 / 任务屏)
                    // plus the two product pages its baseline never wired
                    // (每日简报 / 会话活动) live behind this one Android-only row.
                    // The contract gate cannot see a settings row, so this entry
                    // is proven on a device (uiautomator) instead.
                    add(
                        SettingsRowView(
                            id = DEV_TOOLS_ROW_ID,
                            kind = SettingsRowKind.NAVIGATION,
                            title = ROW_DEV_TOOLS,
                            destination = SettingsDestination.DEV_TOOLS,
                        ),
                    )
                    addAll(platformRows(facts.platform ?: SettingsPlatformFacts()))
                    if (status != null) {
                        add(
                            SettingsRowView(
                                id = STATUS_ROW_ID,
                                kind = SettingsRowKind.FOOTNOTE,
                                title = "",
                                text = status,
                                dividerBelow = false,
                            ),
                        )
                    }
                },
            )

            val engineSection = facts.engineLifecycle?.let { lifecycle ->
                SettingsSectionView(
                    id = ENGINE_SECTION_ID,
                    rows = buildList {
                        add(
                            SettingsRowView(
                                id = ENGINE_STATUS_ROW_ID,
                                kind = SettingsRowKind.VALUE,
                                title = UiStrings.ENGINE_STATE_LABEL,
                                value = lifecycle.statusLabel ?: lifecycle.status.settingsLabel(),
                                dividerBelow = lifecycle.needsReset,
                            ),
                        )
                        if (lifecycle.needsReset) {
                            add(
                                SettingsRowView(
                                    id = ENGINE_RESTART_ROW_ID,
                                    kind = SettingsRowKind.ACTION,
                                    title = UiStrings.ENGINE_RESTART,
                                ),
                            )
                            add(
                                SettingsRowView(
                                    id = ENGINE_RESTART_HINT_ROW_ID,
                                    kind = SettingsRowKind.FOOTNOTE,
                                    title = "",
                                    text = UiStrings.ENGINE_RESTART_HINT,
                                    dividerBelow = false,
                                ),
                            )
                        }
                    },
                )
            }
            return SettingsScreenState(
                sections = buildList {
                    add(permission)
                    engineSection?.let(::add)
                    add(preferencesCard)
                    add(work)
                    add(composer)
                    add(about)
                    add(appendix)
                },
                engineLifecycle = facts.engineLifecycle,
                modelProviderName = facts.modelProviderName,
                providerSetupRequired = facts.providerSetupRequired,
                folderCount = facts.folderCount,
                archivedSessionCount = facts.archivedSessionCount,
                phonePermissionSummary = facts.phonePermissionSummary,
                versionName = facts.versionName,
                preferences = preferences,
                defaultPermissionTier = facts.defaultPermissionTier,
                defaultPermissionAvailableTiers = facts.defaultPermissionAvailableTiers,
                defaultPermissionWritable = facts.defaultPermissionWritable,
                defaultPermissionBusy = facts.defaultPermissionBusy,
                defaultPermissionFailure = facts.defaultPermissionFailure,
                defaultPermissionReadOnlyReason = facts.defaultPermissionReadOnlyReason,
                defaultPermissionStartupLocked = facts.defaultPermissionStartupLocked,
                busyEnterMode = facts.busyEnterMode,
            )
        }

        /**
         * One picker row.
         *
         * A row whose selection was not reported is a MENU row with a 未知 value
         * but no selected option: the menu still opens (the user may set it), and
         * none of the entries is drawn as the current one.
         */
        private fun pickerRow(
            id: String,
            title: String,
            selection: String?,
            options: List<SettingsMenuOption>,
            selectedId: String?,
            dividerBelow: Boolean = true,
        ): SettingsRowView = SettingsRowView(
            id = id,
            kind = SettingsRowKind.MENU,
            title = title,
            value = selection ?: UiStrings.SETTINGS_PERMISSION_UNSET,
            tone = if (selection == null) PageTone.UNKNOWN else PageTone.NORMAL,
            options = options,
            selectedOptionId = selectedId,
            dividerBelow = dividerBelow,
        )

        /** 字号大小's value: the three px sizes, or 未设置 when the host read none. */
        private fun fontSizeValue(preferences: SettingsPreferences): String? {
            val sizes = listOfNotNull(
                preferences.fontSizeConversation,
                preferences.fontSizeCode,
                preferences.fontSizeTerminal,
            )
            return if (sizes.isEmpty()) null else sizes.joinToString(" / ") { "$it px" }
        }

        /** The baseline's status line precedence: warning, then restart, then saved. */
        private fun statusLine(facts: SettingsFacts): String? = when {
            facts.searchLaunchWarning != null -> facts.searchLaunchWarning
            facts.engineStarted == FactState.YES && facts.networkConfigurationChanged ->
                UiStrings.SETTINGS_FOOTER_RESTART
            facts.didSave -> UiStrings.SETTINGS_FOOTER_SAVED
            else -> null
        }

        /** 权限: the host's preset title, or 未设置 when it reported none. */
        private fun permissionTitle(tier: PermissionTier?): String =
            tier?.let { tierTitle(it) } ?: UiStrings.SETTINGS_PERMISSION_UNSET

        private fun busyEnterLabel(mode: BusyEnterMode): String = when (mode) {
            BusyEnterMode.QUEUE -> UiStrings.BUSY_ENTER_QUEUE
            BusyEnterMode.STEER -> UiStrings.BUSY_ENTER_STEER
        }

        /** The three presets in the menu order the chat permission menu uses. */
        internal fun tierTitle(tier: PermissionTier): String = when (tier) {
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

private fun EngineLifecycleStatus.settingsLabel(): String = when (this) {
    EngineLifecycleStatus.UNKNOWN -> UiStrings.UNKNOWN
    EngineLifecycleStatus.STOPPED -> UiStrings.ENGINE_STATE_STOPPED
    EngineLifecycleStatus.STARTING -> UiStrings.ENGINE_STATE_STARTING
    EngineLifecycleStatus.RUNNING -> UiStrings.ENGINE_STATE_RUNNING
    EngineLifecycleStatus.RECOVERING -> UiStrings.ENGINE_STATE_RECOVERING
    EngineLifecycleStatus.FAILED -> UiStrings.ENGINE_STATE_FAILED
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
    public val enabled: Boolean = true,
)

/**
 * The 权限 sub-page's state, mirroring the baseline's PermissionDefaultsPage
 * (`SettingsPage.swift:218-245`).
 *
 * @param note the baseline's one explanatory line, verbatim.
 * @param options the three presets in menu order.
 * @param readOnlyReason why the selector is disabled, when the host measured a lock.
 */
@Immutable
public data class PermissionDefaultsState(
    public val note: String = UiStrings.PERMISSION_DEFAULTS_NOTE,
    public val options: List<PermissionOptionView> = emptyList(),
    public val busy: Boolean = false,
    public val writable: Boolean = false,
    public val failure: String? = null,
    public val statusMessage: String? = null,
    public val readOnlyReason: String? = null,
) {
    public companion object {
        /** Projects the host's current preset into the three option rows. */
        public fun from(
            selected: PermissionTier?,
            languageId: String? = null,
            availableTiers: Set<PermissionTier>? = null,
            writable: Boolean = false,
            busy: Boolean = false,
            failure: String? = null,
            readOnlyReason: String? = null,
            startupLocked: Boolean = false,
        ): PermissionDefaultsState {
            val lockReason = when {
                writable -> null
                startupLocked -> UiStrings.settingsNativeText(
                    languageId,
                    UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON,
                    UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON_EN,
                )
                !readOnlyReason.isNullOrBlank() -> readOnlyReason
                else -> UiStrings.settingsNativeText(
                    languageId,
                    UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON,
                    UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON_EN,
                )
            }
            return PermissionDefaultsState(
                note = UiStrings.settingsNativeText(
                    languageId,
                    UiStrings.PERMISSION_DEFAULTS_NOTE,
                    UiStrings.PERMISSION_DEFAULTS_SCOPE_EN,
                ),
                busy = busy,
                writable = writable,
                failure = failure,
                readOnlyReason = lockReason,
                statusMessage = failure ?: when {
                    busy -> UiStrings.settingsNativeText(languageId, "正在保存…", "Saving…")
                    !writable -> lockReason
                    availableTiers != null && availableTiers.isEmpty() -> UiStrings.settingsNativeText(
                        languageId,
                        "主机未提供本页支持的未来会话权限选项。",
                        "The host did not offer any default permission options supported here.",
                    )
                    else -> null
                },
                options = listOf(
                    PermissionTier.VIEW_ONLY,
                    PermissionTier.WORKSPACE_WRITE,
                    PermissionTier.FULL_ACCESS,
                ).map { tier ->
                    PermissionOptionView(
                        tier = tier,
                        title = UiStrings.settingsNativeText(languageId, SettingsScreenState.tierTitle(tier), when (tier) {
                            PermissionTier.VIEW_ONLY -> "Read only"
                            PermissionTier.WORKSPACE_WRITE -> "Workspace write"
                            PermissionTier.FULL_ACCESS -> "Full access"
                        }),
                        selected = tier == selected,
                        enabled = writable && !busy && availableTiers?.contains(tier) == true,
                    )
                },
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The grouped PR22 Settings index. A direct non-General [tab] remains a host deep-entry.
 *
 * @param state the immutable host snapshot (`SettingsScreenState.from`).
 * @param onNavigate a navigation row was tapped.
 * @param onToggleBackgroundKeepAlive the 后台运行 switch was flipped.
 * @param onSelectBusyEnterMode 繁忙时的发送行为 picked a mode.
 * @param onBack leave the sheet (the baseline's 完成).
 * @param tab the host-owned deep-entry key; it does not render a segmented picker.
 * @param onSelectTab retained for source compatibility with the previous host shell.
 * @param onSelectPreference one of the other four pickers reported a choice.
 * @param onToggleDeveloperTools 显示代码工作视图 was flipped.
 * @param tabContent the selected deep-entry page. Its caller supplies any page-specific
 *   wiring; when absent, the page reports unavailable rather than inventing content.
 */
@Composable
public fun SettingsPage(
    state: SettingsScreenState,
    onNavigate: (SettingsDestination) -> Unit,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
    onSelectBusyEnterMode: (BusyEnterMode) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    tab: SettingsTab = SettingsTab.GENERAL,
    onSelectTab: (SettingsTab) -> Unit = {},
    onSelectPreference: ((SettingsPreferenceChoice) -> Unit)? = null,
    onSelectFontFamily: ((rowId: String, family: String) -> Unit)? = null,
    onToggleDeveloperTools: ((Boolean) -> Unit)? = null,
    onRestartEngine: (() -> Unit)? = null,
    tabContent: (@Composable (SettingsTab) -> Unit)? = null,
    onOpenAgentPresets: (() -> Unit)? = null,
    onOpenPhonePermissions: (() -> Unit)? = null,
    onOpenPluginsTools: (() -> Unit)? = null,
    onOpenFolders: (() -> Unit)? = null,
    onOpenArchivedSessions: (() -> Unit)? = null,
    onSelectDefaultPermission: ((PermissionTier) -> Unit)? = null,
    licenseEntries: List<AndroidLicenseNotice>? = null,
    backLevel: com.phonedsh.ui.nav.PdshBackLevel? = null,
    /** Retained by the settings host while an external settings child is open. */
    indexListState: androidx.compose.foundation.lazy.LazyListState = androidx.compose.foundation.lazy.rememberLazyListState(),
) {
    // The old tab enum is retained as the deep-link vocabulary used by the host.
    // A non-General incoming tab is still rendered as the requested pushed page.
    if (tab != SettingsTab.GENERAL) {
        if (tabContent != null) tabContent(tab) else SettingsTabUnavailable(tab)
        return
    }

    var page by remember { mutableStateOf(SettingsIndexPage.ROOT) }
    com.phonedsh.ui.nav.RouteBackLevel(backLevel, page != SettingsIndexPage.ROOT) {
        page = SettingsIndexPage.ROOT
    }
    val tokens = LocalUiTokens.current
    val preferences = state.preferences
    val lifecycle = state.engineLifecycle
    val languageId = preferences.language?.id
    val language = when (languageId) {
        "zh" -> UiStrings.SETTINGS_LANGUAGE_ZH
        "en" -> UiStrings.SETTINGS_LANGUAGE_EN
        "system" -> UiStrings.settingsNativeText(languageId, "跟随系统", "System")
        else -> UiStrings.settingsNativeText(languageId, UiStrings.SETTINGS_PERMISSION_UNSET, "Not set")
    }
    val appearance = when (preferences.appearance?.id) {
        "system" -> UiStrings.settingsNativeText(languageId, "跟随系统", "System")
        "light" -> UiStrings.settingsNativeText(languageId, "浅色", "Light")
        "dark" -> UiStrings.settingsNativeText(languageId, "深色", "Dark")
        else -> UiStrings.settingsNativeText(languageId, UiStrings.SETTINGS_PERMISSION_UNSET, "Not set")
    }
    val fontSize = preferences.fontSizeConversation?.let { "$it pt" } ?: UiStrings.UNKNOWN
    val providerValue = when {
        state.providerSetupRequired == true -> "需要设置"
        state.modelProviderName != null -> state.modelProviderName
        else -> UiStrings.UNAVAILABLE
    }
    val folderValue = state.folderCount?.toString() ?: UiStrings.UNAVAILABLE
    val archivedValue = state.archivedSessionCount?.toString() ?: UiStrings.UNAVAILABLE
    val permissionSummary = state.phonePermissionSummary ?: UiStrings.UNKNOWN

    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .fillMaxSize()
            .background(tokens.colors.page)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        SettingsNavBar(
            title = if (page == SettingsIndexPage.ROOT) UiStrings.settingsNativeText(
                state.preferences.language?.id, UiStrings.SETTINGS, UiStrings.SETTINGS_EN,
            ) else page.title(state.preferences.language?.id),
            leading = if (page == SettingsIndexPage.ROOT) null else {
                {
                    com.phonedsh.ui.icon.PdshIconView(
                        icon = com.phonedsh.ui.icon.PdshIcon.CHEVRON_LEFT,
                        size = com.phonedsh.ui.HomeMetrics.composerIcon,
                        tint = tokens.colors.textPrimary,
                        contentDescription = UiStrings.settingsNativeText(state.preferences.language?.id, UiStrings.BACK, "Back"),
                        modifier = Modifier
                            .clickable(role = Role.Button) { page = SettingsIndexPage.ROOT }
                            .testTag("pdsh.settings.index.back")
                            .padding(tokens.spacing.iconText),
                    )
                }
            },
            trailing = {
                SettingsBarAction(
                label = UiStrings.settingsNativeText(state.preferences.language?.id, UiStrings.SETTINGS_DONE, UiStrings.SETTINGS_DONE_EN),
                    onClick = onBack,
                    modifier = Modifier.testTag(UiPageTags.SETTINGS_DONE),
                )
            },
        )
        when (page) {
            SettingsIndexPage.ROOT -> SettingsIndexList(
                state = state,
                listState = indexListState,
                language = language,
                appearance = appearance,
                fontSize = fontSize,
                providerValue = providerValue,
                folderValue = folderValue,
                archivedValue = archivedValue,
                permissionSummary = permissionSummary,
                onNavigate = { destination ->
                    when (destination) {
                        SettingsDestination.PERMISSION_DEFAULTS -> page = SettingsIndexPage.PERMISSION_DEFAULTS
                        SettingsDestination.LICENSES -> page = SettingsIndexPage.LICENSES
                        SettingsDestination.SHORTCUTS -> onNavigate(destination)
                        else -> onNavigate(destination)
                    }
                },
                onSelectPreference = onSelectPreference,
                onSelectDefaultPermission = onSelectDefaultPermission,
                onToggleBackgroundKeepAlive = onToggleBackgroundKeepAlive,
                onOpenAgentPresets = onOpenAgentPresets,
                onOpenPhonePermissions = onOpenPhonePermissions,
                onOpenPluginsTools = onOpenPluginsTools,
                onOpenFolders = onOpenFolders,
                onOpenArchivedSessions = onOpenArchivedSessions,
                onOpenLocalPage = { page = it },
                onRestartEngine = onRestartEngine,
            )
            SettingsIndexPage.FONT_SIZE -> FontSizeSettingsPage(
                preferences = preferences,
                languageId = preferences.language?.id,
                onSelectPreference = onSelectPreference,
                onSelectFontFamily = onSelectFontFamily,
            )
            SettingsIndexPage.CONVERSATION -> ConversationSettingsPage(
                preferences = preferences,
                languageId = preferences.language?.id,
                busyEnterMode = state.busyEnterMode,
                onSelectPreference = onSelectPreference,
                onSelectBusyEnterMode = onSelectBusyEnterMode,
                onToggleDeveloperTools = onToggleDeveloperTools,
            )
            SettingsIndexPage.PERMISSION_DEFAULTS -> PermissionDefaultsPage(
                state = PermissionDefaultsState.from(
                    selected = state.defaultPermissionTier,
                    languageId = state.preferences.language?.id,
                    availableTiers = state.defaultPermissionAvailableTiers,
                    writable = state.defaultPermissionWritable,
                    busy = state.defaultPermissionBusy,
                    failure = state.defaultPermissionFailure,
                    readOnlyReason = state.defaultPermissionReadOnlyReason,
                    startupLocked = state.defaultPermissionStartupLocked,
                ),
                onSelect = if (state.defaultPermissionWritable) onSelectDefaultPermission else null,
                onBack = { page = SettingsIndexPage.ROOT },
                embedded = true,
            )
            SettingsIndexPage.LICENSES -> LicensesPage(entries = licenseEntries, embedded = true, onBack = { page = SettingsIndexPage.ROOT })
        }
    }
}

private enum class SettingsIndexPage(val titleZh: String, val titleEn: String) {
    ROOT(UiStrings.SETTINGS, UiStrings.SETTINGS_EN),
    FONT_SIZE("字号", UiStrings.SETTINGS_ROW_FONT_SIZE_EN),
    CONVERSATION(UiStrings.SETTINGS_ROW_WORK_DETAILS, UiStrings.SETTINGS_ROW_WORK_DETAILS_EN),
    PERMISSION_DEFAULTS(UiStrings.PERMISSION_DEFAULTS_TITLE, UiStrings.PERMISSION_DEFAULTS_TITLE_EN),
    LICENSES(UiStrings.ABOUT_LICENSES, "Open-source licenses");

    fun title(languageId: String?): String = UiStrings.settingsNativeText(languageId, titleZh, titleEn)
}

@Composable
private fun SettingsIndexList(
    state: SettingsScreenState,
    listState: androidx.compose.foundation.lazy.LazyListState,
    language: String,
    appearance: String,
    fontSize: String,
    providerValue: String,
    folderValue: String,
    archivedValue: String,
    permissionSummary: String,
    onNavigate: (SettingsDestination) -> Unit,
    onSelectPreference: ((SettingsPreferenceChoice) -> Unit)?,
    onOpenAgentPresets: (() -> Unit)?,
    onOpenPhonePermissions: (() -> Unit)?,
    onOpenPluginsTools: (() -> Unit)?,
    onOpenFolders: (() -> Unit)?,
    onOpenArchivedSessions: (() -> Unit)?,
    onOpenLocalPage: (SettingsIndexPage) -> Unit,
    onRestartEngine: (() -> Unit)?,
    onSelectDefaultPermission: ((PermissionTier) -> Unit)?,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
) {
    val languageId = state.preferences.language?.id
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    fun tierTitle(tier: PermissionTier?): String = when (tier) {
        PermissionTier.VIEW_ONLY -> native(UiStrings.PERMISSION_TIER_VIEW_ONLY, "Read only")
        PermissionTier.WORKSPACE_WRITE -> native(UiStrings.PERMISSION_TIER_WORKSPACE_WRITE, "Workspace write")
        PermissionTier.FULL_ACCESS -> native(UiStrings.PERMISSION_TIER_FULL_ACCESS, "Full access")
        null -> native(UiStrings.SETTINGS_PERMISSION_UNSET, "Not set")
    }
    val sections = listOf(
        SettingsIndexSection("modelsAgents", native(UiStrings.SETTINGS_SECTION_MODELS_AGENTS, UiStrings.SETTINGS_SECTION_MODELS_AGENTS_EN), listOf(
            SettingsIndexEntry("modelProvider", native("模型服务", UiStrings.MODEL_PROVIDER_TITLE_EN), com.phonedsh.ui.icon.PdshIcon.CPU, providerValue, callback = { onNavigate(SettingsDestination.MODEL_PROVIDER) }),
            SettingsIndexEntry("agentPresets", native("Agent 预设", "Agent presets"), com.phonedsh.ui.icon.PdshIcon.PEOPLE,
                value = if (onOpenAgentPresets == null) UiStrings.UNAVAILABLE else null,
                enabled = onOpenAgentPresets != null, callback = onOpenAgentPresets),
            SettingsIndexEntry("pluginsTools", native("插件与工具", "Plugins and tools"), com.phonedsh.ui.icon.PdshIcon.PUZZLE,
                value = if (onOpenPluginsTools == null) UiStrings.UNAVAILABLE else null,
                enabled = onOpenPluginsTools != null, callback = onOpenPluginsTools),
        )),
        SettingsIndexSection("permissionsPrivacy", native(UiStrings.SETTINGS_SECTION_PERMISSIONS_PRIVACY, UiStrings.SETTINGS_SECTION_PERMISSIONS_PRIVACY_EN), listOf(
            SettingsIndexEntry("permissionDefaults", native("新会话默认权限", UiStrings.PERMISSION_DEFAULTS_TITLE_EN), com.phonedsh.ui.icon.PdshIcon.LOCK_SHIELD,
                tierTitle(state.defaultPermissionTier), callback = { onNavigate(SettingsDestination.PERMISSION_DEFAULTS) }),
            SettingsIndexEntry("phonePermissions", native("手机权限", UiStrings.PHONE_PERMISSIONS_TITLE_EN), com.phonedsh.ui.icon.PdshIcon.HAND, permissionSummary,
                enabled = onOpenPhonePermissions != null, callback = onOpenPhonePermissions),
            SettingsIndexEntry("network", native("网络访问", UiStrings.SETTINGS_ROW_NETWORK_EN), com.phonedsh.ui.icon.PdshIcon.NETWORK, callback = { onNavigate(SettingsDestination.EGRESS) }),
            SettingsIndexEntry("mcp", native("MCP 与局域网设备", "MCP and LAN devices"), com.phonedsh.ui.icon.PdshIcon.DATABASE, callback = { onNavigate(SettingsDestination.MCP) }),
            SettingsIndexEntry("ssh", native("SSH 主机", "SSH hosts"), com.phonedsh.ui.icon.PdshIcon.TERMINAL, callback = { onNavigate(SettingsDestination.SSH) }),
            SettingsIndexEntry("bluetooth", native("蓝牙设备", "Bluetooth devices"), com.phonedsh.ui.icon.PdshIcon.NETWORK, callback = { onNavigate(SettingsDestination.BLUETOOTH) }),
        )),
        SettingsIndexSection("conversation", native(UiStrings.SETTINGS_SECTION_CONVERSATION, UiStrings.SETTINGS_SECTION_CONVERSATION_EN), listOf(
            SettingsIndexEntry.menu("appearance", native("外观", UiStrings.SETTINGS_ROW_APPEARANCE_EN), com.phonedsh.ui.icon.PdshIcon.GEAR, appearance,
                listOf(SettingsMenuOption("system", native("跟随系统", "System")), SettingsMenuOption("light", native("浅色", "Light")), SettingsMenuOption("dark", native("深色", "Dark"))),
                SettingsScreenState.APPEARANCE_ROW_ID, state.preferences.appearance?.id, onSelectPreference),
            SettingsIndexEntry.menu("language", native(UiStrings.SETTINGS_ROW_LANGUAGE, UiStrings.SETTINGS_ROW_LANGUAGE_EN), com.phonedsh.ui.icon.PdshIcon.GLOBE, language,
                listOf(SettingsMenuOption("system", native("跟随系统", "System")), SettingsMenuOption("zh", UiStrings.SETTINGS_LANGUAGE_ZH), SettingsMenuOption("en", UiStrings.SETTINGS_LANGUAGE_EN)),
                SettingsScreenState.LANGUAGE_ROW_ID, state.preferences.language?.id, onSelectPreference),
            SettingsIndexEntry("fontSize", native("字号", UiStrings.SETTINGS_ROW_FONT_SIZE_EN), com.phonedsh.ui.icon.PdshIcon.TEXT_SIZE, fontSize, callback = { onOpenLocalPage(SettingsIndexPage.FONT_SIZE) }),
            SettingsIndexEntry("workDetails", native(UiStrings.SETTINGS_ROW_WORK_DETAILS, UiStrings.SETTINGS_ROW_WORK_DETAILS_EN), com.phonedsh.ui.icon.PdshIcon.LIST, callback = { onOpenLocalPage(SettingsIndexPage.CONVERSATION) }),
            SettingsIndexEntry("shortcuts", native("快捷键", UiStrings.SETTINGS_ROW_SHORTCUTS_EN), com.phonedsh.ui.icon.PdshIcon.COMMAND, callback = { onNavigate(SettingsDestination.SHORTCUTS) }),
        )),
        SettingsIndexSection("sessionsFiles", native(UiStrings.SETTINGS_SECTION_SESSIONS_FILES, UiStrings.SETTINGS_SECTION_SESSIONS_FILES_EN), listOf(
            SettingsIndexEntry("folders", native("文件夹", "Folders"), com.phonedsh.ui.icon.PdshIcon.FOLDER, folderValue,
                enabled = onOpenFolders != null, callback = onOpenFolders),
            SettingsIndexEntry("archivedSessions", native(UiStrings.SETTINGS_ROW_ARCHIVED_SESSIONS, UiStrings.SETTINGS_ROW_ARCHIVED_SESSIONS_EN), com.phonedsh.ui.icon.PdshIcon.ARCHIVE, archivedValue,
                enabled = onOpenArchivedSessions != null, callback = onOpenArchivedSessions),
        )),
        SettingsIndexSection("engine", native("引擎", UiStrings.SETTINGS_ROW_ENGINE_EN), buildList {
            add(SettingsIndexEntry("engineStatus", native("引擎状态", UiStrings.SETTINGS_ROW_ENGINE_EN), com.phonedsh.ui.icon.PdshIcon.BOLT,
                state.engineLifecycle?.statusLabel ?: state.engineLifecycle?.status?.settingsLabel() ?: UiStrings.UNKNOWN))
            if (state.engineLifecycle?.needsReset == true) {
                add(SettingsIndexEntry("engineRestart", native("重新启动引擎", UiStrings.SETTINGS_ROW_RESTART_EN), com.phonedsh.ui.icon.PdshIcon.REFRESH,
                    value = if (onRestartEngine == null) UiStrings.UNAVAILABLE else null,
                    enabled = onRestartEngine != null, callback = onRestartEngine))
            }
            add(SettingsIndexEntry("runtimeDetails", native("运行状态", UiStrings.SETTINGS_ROW_RUNTIME_EN), com.phonedsh.ui.icon.PdshIcon.WAVEFORM, callback = { onNavigate(SettingsDestination.RUNTIME_DETAILS) }))
        }, footer = if (state.engineLifecycle?.needsReset == true) native(UiStrings.SETTINGS_ENGINE_RESET_FOOTER, UiStrings.SETTINGS_ENGINE_RESET_FOOTER_EN) else null),
        SettingsIndexSection("about", native("关于", "About"), listOf(
            SettingsIndexEntry("about", native("关于 Phone DSH", "About Phone DSH"), com.phonedsh.ui.icon.PdshIcon.INFO, callback = { onNavigate(SettingsDestination.ABOUT) }),
            SettingsIndexEntry("version", native("版本", "Version"), com.phonedsh.ui.icon.PdshIcon.NUMBER, state.versionName ?: UiStrings.UNKNOWN),
            SettingsIndexEntry("licenses", native(UiStrings.ABOUT_LICENSES, "Open-source licenses"), com.phonedsh.ui.icon.PdshIcon.DOCUMENT, callback = { onOpenLocalPage(SettingsIndexPage.LICENSES) }),
        )),
        androidSettingsSection(
            state = state,
            onNavigate = onNavigate,
            onToggleBackgroundKeepAlive = onToggleBackgroundKeepAlive,
        ),
    )
    androidx.compose.foundation.lazy.LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().navigationBarsPadding().testTag(SETTINGS_INDEX_LIST_TAG),
        contentPadding = PaddingValues(top = com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset),
        verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
    ) {
        sections.forEach { section ->
            item(key = section.title) {
                Column {
                    com.phonedsh.ui.surface.SettingsSectionLabel(section.title, tag = UiPageTags.SETTINGS_INDEX_GROUP_PREFIX + section.id)
                    SettingsGroupCard {
                        section.entries.forEachIndexed { index, entry ->
                            SettingsIndexRow(entry, dividerBelow = index != section.entries.lastIndex)
                        }
                    }
                    section.footer?.let { com.phonedsh.ui.surface.SettingsFootnoteRow(text = it) }
                }
            }
        }
    }
}

private const val SETTINGS_INDEX_LIST_TAG: String = UiTags.SETTINGS_LIST

private fun androidSettingsSection(
    state: SettingsScreenState,
    onNavigate: (SettingsDestination) -> Unit,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
): SettingsIndexSection {
    val background = state.row(SettingsScreenState.BACKGROUND_ROW_ID)
    val notifications = state.row(SettingsScreenState.NOTIFICATIONS_ROW_ID)
    val battery = state.row(SettingsScreenState.BATTERY_ROW_ID)
    val predictiveBack = state.row(SettingsScreenState.BACK_ROW_ID)
    val status = state.row(SettingsScreenState.STATUS_ROW_ID)?.text
    return SettingsIndexSection(
        id = "platform",
        title = "平台差异",
        entries = buildList {
            background?.let { row ->
                add(SettingsIndexEntry(
                    id = "platform.backgroundKeepAlive",
                    title = row.title,
                    icon = com.phonedsh.ui.icon.PdshIcon.BOLT,
                    value = if (row.kind == SettingsRowKind.TOGGLE) null else row.value,
                    enabled = row.enabled,
                    toggleChecked = if (row.kind == SettingsRowKind.TOGGLE) row.checked else null,
                    onToggle = if (row.kind == SettingsRowKind.TOGGLE && row.enabled) onToggleBackgroundKeepAlive else null,
                ))
            }
            add(SettingsIndexEntry(
                id = "platform.exportDiagnostics",
                title = UiStrings.SETTINGS_ROW_EXPORT,
                icon = com.phonedsh.ui.icon.PdshIcon.DOCUMENT,
                callback = { onNavigate(SettingsDestination.EXPORT_DIAGNOSTICS) },
            ))
            add(SettingsIndexEntry(
                id = "platform.developerTools",
                title = "开发者工具",
                icon = com.phonedsh.ui.icon.PdshIcon.GEAR,
                callback = { onNavigate(SettingsDestination.DEV_TOOLS) },
            ))
            notifications?.let { row -> add(platformFactEntry("platform.notifications", row, com.phonedsh.ui.icon.PdshIcon.HAND)) }
            battery?.let { row -> add(platformFactEntry("platform.battery", row, com.phonedsh.ui.icon.PdshIcon.BOLT)) }
            predictiveBack?.let { row -> add(platformFactEntry("platform.predictiveBack", row, com.phonedsh.ui.icon.PdshIcon.CHEVRON_LEFT)) }
        },
        footer = status,
    )
}

private fun platformFactEntry(
    id: String,
    row: SettingsRowView,
    icon: com.phonedsh.ui.icon.PdshIcon,
): SettingsIndexEntry = SettingsIndexEntry(
    id = id,
    title = row.title,
    icon = icon,
    value = row.value ?: UiStrings.UNKNOWN,
    subtitle = row.subtitle,
    enabled = false,
)

private data class SettingsIndexSection(val id: String, val title: String, val entries: List<SettingsIndexEntry>, val footer: String? = null)
private data class SettingsIndexEntry(
    val id: String,
    val title: String,
    val icon: com.phonedsh.ui.icon.PdshIcon,
    val value: String? = null,
    val enabled: Boolean = true,
    val callback: (() -> Unit)? = null,
    val options: List<SettingsMenuOption> = emptyList(),
    val rowId: String? = null,
    val onSelectPreference: ((SettingsPreferenceChoice) -> Unit)? = null,
    val selectedOptionId: String? = null,
    val subtitle: String? = null,
    val toggleChecked: Boolean? = null,
    val onToggle: ((Boolean) -> Unit)? = null,
) {
    companion object {
        fun menu(id: String, title: String, icon: com.phonedsh.ui.icon.PdshIcon, value: String,
                 options: List<SettingsMenuOption>, rowId: String, selectedOptionId: String?,
                 onSelect: ((SettingsPreferenceChoice) -> Unit)?) = SettingsIndexEntry(
            id = id, title = title, icon = icon, value = value, options = options,
            rowId = rowId, selectedOptionId = selectedOptionId,
            enabled = onSelect != null, onSelectPreference = onSelect,
        )
    }
}

@Composable
private fun SettingsIndexRow(entry: SettingsIndexEntry, dividerBelow: Boolean) {
    val tokens = LocalUiTokens.current
    var expanded by remember { mutableStateOf(false) }
    val click: (() -> Unit)? = if (!entry.enabled) null else when {
        entry.onToggle != null -> ({ entry.onToggle.invoke(entry.toggleChecked != true) })
        entry.callback != null -> entry.callback
        entry.options.isNotEmpty() -> ({ expanded = !expanded })
        else -> null
    }
    androidx.compose.foundation.layout.Column {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = com.phonedsh.ui.SettingsMetrics.GROUPED_LIST_MIN_ROW_HEIGHT_PT.dp)
                .then(if (click != null) Modifier.clickable(
                    enabled = entry.enabled,
                    role = if (entry.onToggle != null) Role.Switch else Role.Button,
                ) { click() } else Modifier)
                .testTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + entry.id)
                .semantics(mergeDescendants = true) {
                    if (entry.onToggle != null) {
                        stateDescription = if (entry.toggleChecked == true) UiStrings.SETTINGS_BACKGROUND_ON else UiStrings.SETTINGS_BACKGROUND_OFF
                    }
                },
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            com.phonedsh.ui.icon.PdshIconView(
                icon = entry.icon,
                size = com.phonedsh.ui.HomeMetrics.composerIcon,
                tint = tokens.colors.textPrimary,
                contentDescription = null,
                modifier = Modifier.padding(start = tokens.geometry.pageOuterMarginH),
            )
            Column(modifier = Modifier.weight(1f).padding(start = tokens.spacing.iconText)) {
                androidx.compose.foundation.text.BasicText(
                    text = entry.title,
                    style = settingsLabelStyle().copy(color = if (entry.enabled) tokens.colors.textPrimary else tokens.colors.textTertiary),
                )
                entry.subtitle?.let { subtitle ->
                    androidx.compose.foundation.text.BasicText(
                        text = subtitle,
                        style = settingsLabelStyle().copy(color = tokens.colors.textSecondary),
                        maxLines = 2,
                    )
                }
            }
            entry.value?.let { value ->
                BoxWithConstraints {
                    androidx.compose.foundation.text.BasicText(
                        text = value,
                        style = settingsLabelStyle().copy(color = tokens.colors.textSecondary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .widthIn(max = maxWidth * 0.5f)
                            .testTag(UiPageTags.SETTINGS_INDEX_VALUE_PREFIX + entry.id),
                    )
                }
            }
            if (entry.onToggle != null) {
                SettingsSwitch(checked = entry.toggleChecked == true, enabled = entry.enabled)
            } else if (entry.options.isNotEmpty()) {
                com.phonedsh.ui.icon.PdshIconView(
                    icon = com.phonedsh.ui.icon.PdshIcon.CHEVRON_DOWN,
                    size = com.phonedsh.ui.HomeMetrics.composerIcon,
                    tint = tokens.colors.textSecondary,
                    contentDescription = null,
                    modifier = Modifier.padding(horizontal = tokens.spacing.iconText),
                )
            } else if (click != null) {
                com.phonedsh.ui.icon.PdshIconView(
                    icon = com.phonedsh.ui.icon.PdshIcon.CHEVRON_RIGHT,
                    size = com.phonedsh.ui.HomeMetrics.composerIcon,
                    tint = tokens.colors.textSecondary,
                    contentDescription = null,
                    modifier = Modifier.padding(horizontal = tokens.spacing.iconText),
                )
            } else {
                Spacer(modifier = Modifier.width(tokens.spacing.cardInset))
            }
        }
        if (entry.options.isNotEmpty() && expanded) {
            entry.options.forEachIndexed { index, option ->
                SettingsGroupedRow(
                    title = option.title,
                    modifier = Modifier.testTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "${entry.id}.option.${option.id}"),
                    dividerBelow = index != entry.options.lastIndex,
                    trailing = if (option.id == entry.selectedOptionId) ({
                        com.phonedsh.ui.icon.PdshIconView(
                            icon = com.phonedsh.ui.icon.PdshIcon.CHECK,
                            size = com.phonedsh.ui.HomeMetrics.composerIcon,
                            tint = tokens.colors.textPrimary,
                            contentDescription = "已选择",
                        )
                    }) else null,
                    onClick = {
                        expanded = false
                        entry.rowId?.let { rowId -> entry.onSelectPreference?.invoke(SettingsPreferenceChoice(rowId, option.id)) }
                    },
                )
            }
        }
        if (dividerBelow) SettingsHairline()
    }
}


/**
 * A row value's ink on this page.
 *
 * iOS draws every value in the system secondary (#8A8A8E), including the "unset"
 * wording (未设置); the theme's `tertiary` (#9A9AA2) that the tone mapping used to
 * pick is three steps lighter than the baseline. The tone still chooses when no
 * override is provided (the other settings pages).
 */
@Composable
private fun settingsPageValueInk(tone: PageTone): Color {
    // A block body, not `= expr`: `page_structure_check.py` delimits a function by
    // its braces, and an expression body made it swallow the next declarations
    // (the gate then read 完成's `text = label` as an unresolved action).
    val ink = LocalSettingsRowInk.current
    return ink?.value ?: tone.settingsInk(LocalUiTokens.current)
}

/** The Android side's stable tag prefix for the segmented picker. */
internal const val SETTINGS_TAB_TAG_PREFIX: String = "pdsh.settings.tab."

/**
 * The sheet's trailing 完成 (`SettingsPage.swift:77`): the 17 pt row-label ink in
 * the accent, the baseline's `.trailingBarText()`.
 *
 * It is declared here rather than taken from `com.phonedsh.ui.surface`
 * (`SettingsNavAction`) for one specific reason: the page-structure contract reads
 * an action label from a page-local wrapper whose first parameter is `label`
 * (`spec/ui/v1/README.md` §1 — `SessionTextAction(label=…)`, `InfoRow(…,
 * onClick=…)` or a `label:`-first wrapper), and the shared control's first
 * parameter is `text`. Declaring the control here is what makes `完成` a declared
 * action of this page instead of the contract's one missing label; the word, the
 * ink, the tag and the gesture are unchanged.
 *
 * @param label the action's word; also its accessibility name.
 * @param onClick dismiss the sheet.
 * @param modifier the caller's tag and placement.
 */
@Composable
private fun SettingsBarAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    // ios-settings.png (measured): 完成 is a **white capsule with black ink**
    // (x 302.7-389.7, y 60.0-104.7), not a bare blue text button. The blue word
    // read as a link and lost the control's shape on the real page.
    BasicText(
        text = label,
        style = settingsLabelStyle().copy(color = tokens.colors.primary),
        maxLines = 1,
        modifier = modifier
            .clip(CircleShape)
            .background(tokens.colors.input)
            .border(tokens.stroke.hairline, tokens.colors.borderLight, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(tokens.spacing.cardInset),
    )
}

/**
 * The 通用 tab: six cards, five of them the baseline's, one Android-only.
 *
 * @param state the pure screen state.
 * @param onNavigate a navigation row was tapped.
 * @param onToggleBackgroundKeepAlive the 后台运行 switch was flipped.
 * @param onSelectBusyEnterMode 繁忙时的发送行为 picked a mode.
 * @param onSelectPreference one of the four generic pickers reported a choice.
 * @param onToggleDeveloperTools 显示代码工作视图 was flipped.
 */
@Composable
public fun GeneralTabBody(
    state: SettingsScreenState,
    onNavigate: (SettingsDestination) -> Unit,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
    onSelectBusyEnterMode: (BusyEnterMode) -> Unit,
    modifier: Modifier = Modifier,
    onSelectPreference: (SettingsPreferenceChoice) -> Unit = {},
    onToggleDeveloperTools: (Boolean) -> Unit = {},
    onRestartEngine: (() -> Unit)? = null,
) {
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .navigationBarsPadding()
            .testTag(UiTags.SETTINGS_LIST),
        contentPadding = PaddingValues(top = SettingsListTopInset),
        verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
    ) {
        // The six cards, in the baseline's order; each card is one item, so the
        // 38.67 pt gap between cards is the list's own spacing and the card never
        // straddles a scroll boundary.
        state.sections.forEach { section ->
            item(key = "card.${section.id}") {
                SettingsGroupCard {
                    // One row per call site, in the state's order: the card draws
                    // the 1 pt separator under every row that is not last, so the
                    // number of lines in a card is `rows - 1` — exactly what the
                    // baseline's card measures.
                    section.rows.forEach { row ->
                        SettingsCardRow(
                            row = row,
                            onNavigate = onNavigate,
                            onToggleBackgroundKeepAlive = onToggleBackgroundKeepAlive,
                            onSelectBusyEnterMode = onSelectBusyEnterMode,
                            onSelectPreference = onSelectPreference,
                            onToggleDeveloperTools = onToggleDeveloperTools,
                            onRestartEngine = onRestartEngine,
                        )
                    }
                }
            }
        }
    }
}

/**
 * One row of a card, dispatched on its kind.
 *
 * Each kind is a different control, so this is one `when` rather than a
 * parameterised row: a switch, a menu, a footnote and a value row do not share a
 * layout, they share a *pitch* (52.33 pt) and that lives in the chrome.
 */
@Composable
private fun SettingsCardRow(
    row: SettingsRowView,
    onNavigate: (SettingsDestination) -> Unit,
    onToggleBackgroundKeepAlive: (Boolean) -> Unit,
    onSelectBusyEnterMode: (BusyEnterMode) -> Unit,
    onSelectPreference: (SettingsPreferenceChoice) -> Unit,
    onToggleDeveloperTools: (Boolean) -> Unit,
    onRestartEngine: (() -> Unit)?,
) {
    val tags = Modifier.testTag(UiPageTags.SETTINGS_ROW_PREFIX + row.id)
    when (row.kind) {
        SettingsRowKind.FOOTNOTE -> SettingsFootnoteRow(text = row.text ?: "", modifier = tags, centre = true)

        SettingsRowKind.TOGGLE -> SettingsSwitchCardRow(
            row = row,
            modifier = tags,
            onToggle = if (row.id == SettingsScreenState.DEVELOPER_TOOLS_ROW_ID) {
                onToggleDeveloperTools
            } else {
                onToggleBackgroundKeepAlive
            },
        )

        SettingsRowKind.MENU -> SettingsMenuCardRow(
            row = row,
            modifier = tags,
            onSelect = { optionId ->
                if (row.id == SettingsScreenState.BUSY_ENTER_ROW_ID) {
                    BusyEnterMode.entries.firstOrNull { it.id == optionId }?.let(onSelectBusyEnterMode)
                } else {
                    onSelectPreference(SettingsPreferenceChoice(rowId = row.id, optionId = optionId))
                }
            },
        )

        SettingsRowKind.VALUE -> SettingsGroupedRow(
            title = row.title,
            modifier = tags,
            value = row.value,
            valueInk = settingsPageValueInk(row.tone),
            subtitle = row.subtitle,
            dividerBelow = row.dividerBelow,
        )

        SettingsRowKind.NAVIGATION -> SettingsGroupedRow(
            title = row.title,
            modifier = tags,
            value = row.value,
            valueInk = settingsPageValueInk(row.tone),
            subtitle = row.subtitle,
            chevron = true,
            dividerBelow = row.dividerBelow,
            enabled = row.enabled,
            onClick = row.destination?.let { destination -> { onNavigate(destination) } },
        )

        SettingsRowKind.ACTION -> SettingsGroupedRow(
            title = row.title,
            modifier = tags,
            accentTitle = true,
            dividerBelow = row.dividerBelow,
            enabled = row.enabled && onRestartEngine != null,
            onClick = onRestartEngine,
        )

    }
}

/** A switch row: label, switch, and the reported state as its description. */
@Composable
private fun SettingsSwitchCardRow(
    row: SettingsRowView,
    modifier: Modifier,
    onToggle: (Boolean) -> Unit,
) {
    SettingsRowFrame(
        dividerBelow = row.dividerBelow,
        enabled = row.enabled,
        role = Role.Switch,
        onClick = { onToggle(!row.checked) },
        stateValue = row.value,
        // The baseline tracks the switch to the card edge, not to the text
        // column: `ios-settings.png` puts the switch's right edge at x=1115 px
        // and the card's at x=1157 px (14 pt), while a row's value stops 39.33 pt
        // short to leave room for the chevron column.
        trailingInset = SettingsSwitchTrailingInset,
        modifier = modifier.testTag(UiPageTags.SETTINGS_ROW_TOGGLE),
    ) {
        SettingsRowLabel(text = row.title, enabled = row.enabled, modifier = Modifier.weight(1f))
        SettingsSwitch(checked = row.checked, enabled = row.enabled)
    }
}

/**
 * A picker row, rendered as an inline menu: the value and the baseline's
 * `chevron.up.chevron.down` on the trigger, the options below it once opened.
 *
 * The trigger's label is fixed copy; the options are state text.
 */
@Composable
private fun SettingsMenuCardRow(
    row: SettingsRowView,
    modifier: Modifier,
    onSelect: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    var expanded by remember { mutableStateOf(false) }
    val unknown = row.tone == PageTone.UNKNOWN
    Column(modifier = modifier) {
        SettingsRowFrame(
            dividerBelow = row.dividerBelow && !expanded,
            // A menu row's value + up-down chevron sit 17.6 pt from the card edge,
            // not the navigation row's 39.33: see SettingsMetrics.MENU_*.
            trailingInset = SettingsMenuTrailingInset,
            onClick = { expanded = !expanded },
        ) {
            SettingsRowLabel(text = row.title, modifier = Modifier.weight(1f))
            SettingsRowValue(
                text = row.value ?: UiStrings.UNKNOWN,
                ink = settingsPageValueInk(if (unknown) PageTone.UNKNOWN else PageTone.NORMAL),
            )
            SettingsTrailingSlot(width = SettingsMenuChevronSlot) {
                SettingsMenuChevron(
                    ink = settingsPageValueInk(if (unknown) PageTone.UNKNOWN else PageTone.NORMAL),
                )
            }
        }
        if (expanded) {
            row.options.forEach { option ->
                val selected = option.id == row.selectedOptionId
                SettingsRowFrame(
                    dividerBelow = false,
                    role = Role.RadioButton,
                    onClick = {
                        expanded = false
                        onSelect(option.id)
                    },
                    modifier = Modifier.testTag(UiPageTags.SETTINGS_ROW_OPTION_PREFIX + option.id),
                ) {
                    SettingsRowLabel(text = option.title, modifier = Modifier.weight(1f))
                    if (selected) {
                        com.phonedsh.ui.icon.PdshIconView(
                            icon = com.phonedsh.ui.icon.PdshIcon.CHECK,
                            size = com.phonedsh.ui.HomeMetrics.composerIcon,
                            tint = tokens.colors.accent,
                            contentDescription = "已选择",
                        )
                    }
                    SettingsChevronSlot(withChevron = false)
                }
            }
        }
    }
}

/**
 * A tab this host has not wired yet.
 *
 * It says so, once, in the baseline's footnote ink — it does not draw a plausible
 * page. `tabContent` is how a host fills it.
 */
@Composable
private fun SettingsTabUnavailable(tab: SettingsTab) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(SETTINGS_TAB_TAG_PREFIX + tab.id + ".unavailable")
            .padding(top = SettingsSegmentTopGap),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = tab.title,
            style = settingsLabelStyle().copy(color = tokens.colors.primary),
            modifier = Modifier.padding(
                start = tokens.geometry.pageOuterMarginH,
                end = tokens.geometry.pageOuterMarginH,
            ),
        )
        BasicText(
            text = UiStrings.UNAVAILABLE,
            style = LocalUiType.current.secondary.copy(color = tokens.colors.tertiary),
            modifier = Modifier.padding(
                start = tokens.geometry.pageOuterMarginH,
                end = tokens.geometry.pageOuterMarginH,
            ),
        )
    }
}



/** The value ink: the baseline's secondary for a plain value, a tone for a fact. */
private fun PageTone.settingsInk(tokens: UiTokens): Color = when (this) {
    PageTone.NORMAL -> tokens.colors.secondary
    PageTone.ON -> tokens.colors.success
    PageTone.DEGRADED -> tokens.colors.warning
    PageTone.UNKNOWN -> tokens.colors.tertiary
}

/** The menu entries of 繁忙时的发送行为, in the baseline's order. */
private val BUSY_ENTER_OPTIONS: List<SettingsMenuOption> = listOf(
    SettingsMenuOption(id = BusyEnterMode.QUEUE.id, title = UiStrings.BUSY_ENTER_QUEUE),
    SettingsMenuOption(id = BusyEnterMode.STEER.id, title = UiStrings.BUSY_ENTER_STEER),
)

/** The 快捷键 row's value when the host does not count the bindings. */
private const val VALUE_EDIT: String = "编辑"


/**
 * Page-level copy that `UiStrings` does not carry yet.
 *
 * `UiStrings.kt` is another lane's file, so the five-tab rewrite's new labels
 * live here, next to the call sites that use them, and are listed in the lane
 * report as the strings to move. Everything the flat index already had still
 * comes from `UiStrings`.
 */
private const val ROW_PERMISSION: String = "权限"
private const val ROW_LANGUAGE: String = "语言"
private const val ROW_APPEARANCE: String = "外观"
private const val ROW_FONT_SIZE: String = "字号大小"
private const val ROW_TRANSCRIPT_VIEW: String = "工作步骤展示"
private const val ROW_COLLAPSE_TIMING: String = "工作步骤收起时机"
private const val ROW_DEVELOPER_TOOLS: String = "显示代码工作视图"

/** The Android-only entry to the pages iOS has no entry for (L55). */
private const val ROW_DEV_TOOLS: String = "开发者工具"
private const val ROW_SHORTCUTS: String = "快捷键"
private const val ROW_BUSY_ENTER: String = "繁忙时的发送行为"
private const val ROW_PERFORMANCE: String = "性能与用量"
private const val ROW_VERSION: String = "当前版本"
private const val NOTE_PERMISSION_SCOPE: String = "选择新会话的默认权限模式"
private const val NOTE_FONT_SCOPE: String = "仅影响会话内容、代码和终端的字号"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads, so a new reference cannot slip in unlisted and a stale entry fails too.
 */
internal object SettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PAGE,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.COLORS_TEXT_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BORDER_LIGHT,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
    )
}
