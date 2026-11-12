// 聊天外观: the phone-sized appearance, font-size and process-collapse controls.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/ChatPreferencesPage.swift` (84
// lines) at iOS HEAD, mirrored through `spec/ui/v1/pages/chat-preferences.json`
// (4 sections / 5 rows / 4 labelled actions):
//
//   * 外观      — a picker (跟随系统 / 浅色 / 深色) + footer;
//   * 字号      — two steppers (正文 10...22, 代码 10...16) + footer;
//   * 过程折叠  — a picker (完成时 / 下一条消息) + footer;
//   * 转录      — a picker (紧凑 / 标准 / 详细 / 完整), no footer.
//
// The pickers are `Picker`s in a `List(.insetGrouped)`: the row carries the
// label and the current value, taps open the option list below the row. The
// baseline's 完成 is the sheet's only chrome action and closes the page.
//
// Data: `ChatPreferencesFacts` is the host's read-only snapshot. The values are
// the *same* preference set the settings index's 通用 tab reports
// (`SettingsPreferences`: appearance / transcriptView / collapseTiming /
// fontSizeConversation / fontSizeCode), so this page reuses that vocabulary
// instead of inventing a second settings store. The page's own copy differs from
// the settings tab's by design: the baseline words the transcript picker 紧凑 /
// 标准 / 详细 / 完整 here and 简洁 / 标准 / 详细 / 完全展开 there, and the
// collapse picker 完成时 / 下一条消息 here and 回答结束后 / 下次有新消息时 there.
// Both wordings are mirrored; the *values* are shared.
//
// A value the host did not report is `null` and renders 未知 — never the first
// option of the menu, and never an invented default size. A write is only
// offered when the host reported that it can write the setting (`writable` is
// `FactState.YES`); otherwise the controls are disabled and the family's
// read-only line says why, exactly as the settings index does.
//
// What the state layer owns, and what the view owns: the state projects the
// facts into the typed values, their display strings and the option lists (all
// testable on the JVM); the *fixed labels* — the four section titles, the five
// row labels and the footers — stay in the view as `UiStrings` literals. That
// split is deliberate: `page_structure_check.py` compares the contract's section
// titles and action labels against **literal** call-site arguments, and a
// `SettingsSectionLabel(row.title)` / `MenuRow(label = row.label)` call would be
// reported as an unresolved expression instead of 外观 / 折叠时机 / 转录密度.
// The section label is therefore called **positionally**
// (`SettingsSectionLabel(UiStrings.X)`): the checker resolves a `*SectionLabel`
// call from its first positional argument (or a `text =` named one), and its
// parameter here is named `title`, so rewriting the call as `title = …` would
// hide the title from the gate without changing a pixel.
//
// Geometry: the sub-page frame, the inset-grouped card, the 52.33 pt row, the
// 1 pt separator and the 16 / 39.33 pt row insets all come from
// `com.phonedsh.ui.surface` (`SettingsChrome.kt`), which reads them from
// `SettingsMetrics` / `tokens.json`. This page re-types no length and no colour.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsChevronSlot
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsGroupedRowHeight
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.SettingsListTopInset
import com.phonedsh.ui.surface.SettingsMenuChevron
import com.phonedsh.ui.surface.SettingsRowFrame
import com.phonedsh.ui.surface.SettingsRowLabel
import com.phonedsh.ui.surface.SettingsRowValue
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSeparatorInset
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsTrailingSlot
import com.phonedsh.ui.surface.SettingsValueTrailingInset
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Vocabulary: one option of a chat-preference picker
// ---------------------------------------------------------------------------

/**
 * One entry of a picker's menu, in the baseline's order.
 *
 * @param id the preference value's stable id (the enum's own id).
 * @param label the visible text; the baseline's word for this *page*.
 */
@Immutable
public data class ChatPreferencesOption(public val id: String, public val label: String)

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The page's read-only input.
 *
 * @param appearance 外观; `null` means the host did not report it (未知).
 * @param textFontSize 正文, in pt; `null` means unread.
 * @param codeFontSize 代码, in pt; `null` means unread.
 * @param collapseTiming 折叠时机; `null` means unread.
 * @param transcriptView 转录密度; `null` means unread.
 * @param writable whether the host can persist a change. `FactState.UNKNOWN` is
 *   not a "no": it leaves the controls disabled and reports the fact, because a
 *   control that looks live but writes nowhere is the one thing this host must
 *   not draw.
 */
@Immutable
public data class ChatPreferencesFacts(
    public val appearance: SettingsAppearance? = null,
    public val textFontSize: Int? = null,
    public val codeFontSize: Int? = null,
    public val collapseTiming: CollapseTiming? = null,
    public val transcriptView: TranscriptViewMode? = null,
    public val writable: FactState = FactState.UNKNOWN,
) {
    public companion object {
        /**
         * Projects the settings snapshot (the host's one preference read) into
         * this page's facts.
         *
         * @param preferences the 通用 tab's preference values; every field is
         *   nullable because the host may not have read it.
         * @param writable the measured write capability (for example
         *   `ConfigurationSnapshot.settingsWritable`).
         */
        public fun from(
            preferences: SettingsPreferences,
            writable: FactState = FactState.UNKNOWN,
        ): ChatPreferencesFacts = ChatPreferencesFacts(
            appearance = preferences.appearance,
            textFontSize = preferences.fontSizeConversation,
            codeFontSize = preferences.fontSizeCode,
            collapseTiming = preferences.collapseTiming,
            transcriptView = preferences.transcriptView,
            writable = writable,
        )
    }
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * The page state: the reported values, their display strings, the pickers'
 * option lists and the steppers' range checks.
 *
 * @param appearance the reported appearance, or `null` (未知).
 * @param textFontSize / @param codeFontSize the reported sizes in pt, or `null`.
 * @param collapseTiming / @param transcriptView the other two reported pickers.
 * @param writable the host's write capability; the controls are enabled only for
 *   `FactState.YES`.
 */
@Immutable
public data class ChatPreferencesScreenState(
    public val appearance: SettingsAppearance?,
    public val textFontSize: Int?,
    public val codeFontSize: Int?,
    public val collapseTiming: CollapseTiming?,
    public val transcriptView: TranscriptViewMode?,
    public val writable: FactState,
) {
    /** True when the host reported that it can persist a change. */
    public val enabled: Boolean get() = writable == FactState.YES

    /** 外观's current value, in this page's wording; `null` when unread. */
    public val appearanceValue: String? get() = appearance?.let { appearanceChatLabel(it) }

    /** 正文's value, `<n>pt`; `null` when unread. */
    public val textFontSizeValue: String? get() = fontSizeValue(textFontSize)

    /** 代码's value, `<n>pt`; `null` when unread. */
    public val codeFontSizeValue: String? get() = fontSizeValue(codeFontSize)

    /** 折叠时机's current value; `null` when unread. */
    public val collapseTimingValue: String? get() = collapseTiming?.let { collapseChatLabel(it) }

    /** 转录密度's current value; `null` when unread. */
    public val transcriptViewValue: String? get() = transcriptView?.let { transcriptChatLabel(it) }

    public val appearanceOptions: List<ChatPreferencesOption>
        get() = APPEARANCE_ORDER.map { ChatPreferencesOption(it.id, appearanceChatLabel(it)) }

    public val collapseTimingOptions: List<ChatPreferencesOption>
        get() = COLLAPSE_ORDER.map { ChatPreferencesOption(it.id, collapseChatLabel(it)) }

    public val transcriptViewOptions: List<ChatPreferencesOption>
        get() = TRANSCRIPT_ORDER.map { ChatPreferencesOption(it.id, transcriptChatLabel(it)) }

    /** The 正文 stepper may move down/up while it stays inside 10...22. */
    public val canDecreaseText: Boolean
        get() = textFontSize != null && textFontSize > TEXT_SIZE_RANGE.first
    public val canIncreaseText: Boolean
        get() = textFontSize != null && textFontSize < TEXT_SIZE_RANGE.last

    /** The 代码 stepper may move down/up while it stays inside 10...16. */
    public val canDecreaseCode: Boolean
        get() = codeFontSize != null && codeFontSize > CODE_SIZE_RANGE.first
    public val canIncreaseCode: Boolean
        get() = codeFontSize != null && codeFontSize < CODE_SIZE_RANGE.last

    public companion object {
        /** `NativeFontRole.text.sizeRange` (`ChatPreferencesPage.swift:32`). */
        public val TEXT_SIZE_RANGE: IntRange = 10..22

        /** `NativeFontRole.code.sizeRange` (`ChatPreferencesPage.swift:38`). */
        public val CODE_SIZE_RANGE: IntRange = 10..16

        /** The appearance menu's order: 跟随系统 / 浅色 / 深色 (`:18-20`). */
        public val APPEARANCE_ORDER: List<SettingsAppearance> = listOf(
            SettingsAppearance.SYSTEM,
            SettingsAppearance.LIGHT,
            SettingsAppearance.DARK,
        )

        /** The collapse menu's order: 完成时 / 下一条消息 (`:52-53`). */
        public val COLLAPSE_ORDER: List<CollapseTiming> = listOf(
            CollapseTiming.COMPLETION,
            CollapseTiming.NEXT_INPUT,
        )

        /** The transcript menu's order: 紧凑 / 标准 / 详细 / 完整 (`:66-69`). */
        public val TRANSCRIPT_ORDER: List<TranscriptViewMode> = listOf(
            TranscriptViewMode.COMPACT,
            TranscriptViewMode.STANDARD,
            TranscriptViewMode.DETAILED,
            TranscriptViewMode.VERBOSE,
        )

        /**
         * Projects the facts into the page state.
         *
         * Pure: the same facts always render the same values and option lists, so
         * a JVM test can replay every reported / unreported combination without a
         * device.
         */
        public fun from(facts: ChatPreferencesFacts): ChatPreferencesScreenState =
            ChatPreferencesScreenState(
                appearance = facts.appearance,
                textFontSize = facts.textFontSize,
                codeFontSize = facts.codeFontSize,
                collapseTiming = facts.collapseTiming,
                transcriptView = facts.transcriptView,
                writable = facts.writable,
            )

        private fun fontSizeValue(size: Int?): String? =
            size?.let { UiStrings.CHAT_PREFERENCES_FONT_SIZE_FORMAT.format(it) }
    }
}

/** 外观's word on *this* page; the values are shared with the settings index. */
private fun appearanceChatLabel(appearance: SettingsAppearance): String = when (appearance) {
    SettingsAppearance.SYSTEM -> UiStrings.CHAT_PREFERENCES_APPEARANCE_SYSTEM
    SettingsAppearance.LIGHT -> UiStrings.CHAT_PREFERENCES_APPEARANCE_LIGHT
    SettingsAppearance.DARK -> UiStrings.CHAT_PREFERENCES_APPEARANCE_DARK
}

/** 折叠时机's word on this page (`完成时` / `下一条消息`, not the settings tab's). */
private fun collapseChatLabel(timing: CollapseTiming): String = when (timing) {
    CollapseTiming.COMPLETION -> UiStrings.CHAT_PREFERENCES_COLLAPSE_COMPLETION
    CollapseTiming.NEXT_INPUT -> UiStrings.CHAT_PREFERENCES_COLLAPSE_NEXT_INPUT
}

/** 转录密度's word on this page (`紧凑` / `完整`, not the settings tab's). */
private fun transcriptChatLabel(mode: TranscriptViewMode): String = when (mode) {
    TranscriptViewMode.COMPACT -> UiStrings.CHAT_PREFERENCES_DENSITY_COMPACT
    TranscriptViewMode.STANDARD -> UiStrings.CHAT_PREFERENCES_DENSITY_STANDARD
    TranscriptViewMode.DETAILED -> UiStrings.CHAT_PREFERENCES_DENSITY_DETAILED
    TranscriptViewMode.VERBOSE -> UiStrings.CHAT_PREFERENCES_DENSITY_VERBOSE
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/** The four sections' ids, used for the lazy items and the pickers' open state. */
private const val APPEARANCE_SECTION: String = "appearance"
private const val FONT_SECTION: String = "font"
private const val COLLAPSE_SECTION: String = "collapse"
private const val TRANSCRIPT_SECTION: String = "transcript"

/**
 * The 聊天外观 page.
 *
 * @param state the pure screen state ([ChatPreferencesScreenState.from]).
 * @param onSelectAppearance the 外观 menu picked an entry.
 * @param onSelectCollapseTiming the 折叠时机 menu picked an entry.
 * @param onSelectTranscriptView the 转录密度 menu picked an entry.
 * @param onSetTextFontSize the 正文 stepper moved to a new size.
 * @param onSetCodeFontSize the 代码 stepper moved to a new size.
 * @param onDone the baseline's 完成: close the sheet.
 */
@Composable
public fun ChatPreferencesPage(
    state: ChatPreferencesScreenState,
    onSelectAppearance: (SettingsAppearance) -> Unit,
    onSelectCollapseTiming: (CollapseTiming) -> Unit,
    onSelectTranscriptView: (TranscriptViewMode) -> Unit,
    onSetTextFontSize: (Int) -> Unit,
    onSetCodeFontSize: (Int) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    // Which picker is open. The fold is view-local chrome (the same shape the
    // settings index's menu rows use), not a ScreenState event.
    var expandedSection by remember { mutableStateOf<String?>(null) }
    SettingsSubPageFrame(
        modifier = modifier,
        title = UiStrings.CHAT_PREFERENCES_TITLE,
        grouped = true,
        rootTag = UiPageTags.CHAT_PREFERENCES_ROOT,
        trailing = {
            ChatPreferencesBarAction(
                label = UiStrings.SETTINGS_DONE,
                onClick = onDone,
                modifier = Modifier.testTag(UiPageTags.CHAT_PREFERENCES_DONE),
            )
        },
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.CHAT_PREFERENCES_LIST),
            contentPadding = PaddingValues(
                top = SettingsListTopInset,
                bottom = tokens.spacing.cardInset,
            ),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            item(key = APPEARANCE_SECTION) {
                Column {
                    SettingsSectionLabel(
                        UiStrings.CHAT_PREFERENCES_SECTION_APPEARANCE,
                        tag = UiPageTags.CHAT_PREFERENCES_SECTION_PREFIX + APPEARANCE_SECTION,
                    )
                    SettingsGroupCard {
                        ChatPreferencesMenuRow(
                            label = UiStrings.CHAT_PREFERENCES_ROW_APPEARANCE,
                            value = state.appearanceValue,
                            expanded = expandedSection == APPEARANCE_SECTION,
                            enabled = state.enabled,
                            options = state.appearanceOptions,
                            selectedOptionId = state.appearance?.id,
                            dividerBelow = false,
                            onToggle = {
                                expandedSection =
                                    if (expandedSection == APPEARANCE_SECTION) null else APPEARANCE_SECTION
                            },
                            onSelect = { optionId ->
                                expandedSection = null
                                SettingsAppearance.entries
                                    .firstOrNull { it.id == optionId }
                                    ?.let(onSelectAppearance)
                            },
                            modifier = Modifier.testTag(UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "appearance"),
                        )
                        SettingsFootnoteRow(
                            text = UiStrings.CHAT_PREFERENCES_FOOTER_APPEARANCE,
                            dividerBelow = false,
                        )
                    }
                }
            }
            item(key = FONT_SECTION) {
                Column {
                    SettingsSectionLabel(
                        UiStrings.CHAT_PREFERENCES_SECTION_FONT,
                        tag = UiPageTags.CHAT_PREFERENCES_SECTION_PREFIX + FONT_SECTION,
                    )
                    SettingsGroupCard {
                        ChatPreferencesStepperRow(
                            label = UiStrings.CHAT_PREFERENCES_ROW_FONT_TEXT,
                            value = state.textFontSizeValue,
                            enabled = state.enabled,
                            canDecrease = state.canDecreaseText,
                            canIncrease = state.canIncreaseText,
                            dividerBelow = true,
                            onDecrease = {
                                state.textFontSize?.let { onSetTextFontSize(it - 1) }
                            },
                            onIncrease = {
                                state.textFontSize?.let { onSetTextFontSize(it + 1) }
                            },
                            modifier = Modifier.testTag(UiPageTags.CHAT_PREFERENCES_STEPPER_PREFIX + "text"),
                        )
                        ChatPreferencesStepperRow(
                            label = UiStrings.CHAT_PREFERENCES_ROW_FONT_CODE,
                            value = state.codeFontSizeValue,
                            enabled = state.enabled,
                            canDecrease = state.canDecreaseCode,
                            canIncrease = state.canIncreaseCode,
                            dividerBelow = true,
                            onDecrease = {
                                state.codeFontSize?.let { onSetCodeFontSize(it - 1) }
                            },
                            onIncrease = {
                                state.codeFontSize?.let { onSetCodeFontSize(it + 1) }
                            },
                            modifier = Modifier.testTag(UiPageTags.CHAT_PREFERENCES_STEPPER_PREFIX + "code"),
                        )
                        SettingsFootnoteRow(
                            text = UiStrings.CHAT_PREFERENCES_FOOTER_FONT,
                            dividerBelow = false,
                        )
                    }
                }
            }
            item(key = COLLAPSE_SECTION) {
                Column {
                    SettingsSectionLabel(
                        UiStrings.CHAT_PREFERENCES_SECTION_COLLAPSE,
                        tag = UiPageTags.CHAT_PREFERENCES_SECTION_PREFIX + COLLAPSE_SECTION,
                    )
                    SettingsGroupCard {
                        ChatPreferencesMenuRow(
                            label = UiStrings.CHAT_PREFERENCES_ROW_COLLAPSE,
                            value = state.collapseTimingValue,
                            expanded = expandedSection == COLLAPSE_SECTION,
                            enabled = state.enabled,
                            options = state.collapseTimingOptions,
                            selectedOptionId = state.collapseTiming?.id,
                            dividerBelow = false,
                            onToggle = {
                                expandedSection =
                                    if (expandedSection == COLLAPSE_SECTION) null else COLLAPSE_SECTION
                            },
                            onSelect = { optionId ->
                                expandedSection = null
                                CollapseTiming.entries
                                    .firstOrNull { it.id == optionId }
                                    ?.let(onSelectCollapseTiming)
                            },
                            modifier = Modifier.testTag(
                                UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "collapse",
                            ),
                        )
                        SettingsFootnoteRow(
                            text = UiStrings.CHAT_PREFERENCES_FOOTER_COLLAPSE,
                            dividerBelow = false,
                        )
                    }
                }
            }
            item(key = TRANSCRIPT_SECTION) {
                Column {
                    SettingsSectionLabel(
                        UiStrings.CHAT_PREFERENCES_SECTION_TRANSCRIPT,
                        tag = UiPageTags.CHAT_PREFERENCES_SECTION_PREFIX + TRANSCRIPT_SECTION,
                    )
                    SettingsGroupCard {
                        // No footer: the baseline's transcript section has none.
                        ChatPreferencesMenuRow(
                            label = UiStrings.CHAT_PREFERENCES_ROW_TRANSCRIPT,
                            value = state.transcriptViewValue,
                            expanded = expandedSection == TRANSCRIPT_SECTION,
                            enabled = state.enabled,
                            options = state.transcriptViewOptions,
                            selectedOptionId = state.transcriptView?.id,
                            dividerBelow = false,
                            onToggle = {
                                expandedSection = if (expandedSection == TRANSCRIPT_SECTION) {
                                    null
                                } else {
                                    TRANSCRIPT_SECTION
                                }
                            },
                            onSelect = { optionId ->
                                expandedSection = null
                                TranscriptViewMode.entries
                                    .firstOrNull { it.id == optionId }
                                    ?.let(onSelectTranscriptView)
                            },
                            modifier = Modifier.testTag(
                                UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "transcript",
                            ),
                        )
                    }
                }
            }
            if (!state.enabled) {
                item(key = "read-only") {
                    SettingsGroupCard {
                        SettingsFootnoteRow(
                            text = UiStrings.HOST_READ_ONLY_HINT,
                            dividerBelow = false,
                        )
                    }
                }
            }
        }
    }
}

/**
 * The bar's 完成: 17 pt accent text in the 44 pt bar.
 *
 * The first parameter is [label] on purpose: the page-structure contract lists
 * 完成 as a labelled action, and a page-local composable whose first parameter is
 * the visible label is the checker's documented wrapper idiom. The label is
 * passed in, never assembled, so the gate reads the same word the bar draws.
 */
@Composable
private fun ChatPreferencesBarAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = label,
        style = settingsLabelStyle().copy(color = tokens.colors.accent),
        maxLines = 1,
        modifier = modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(tokens.spacing.iconText),
    )
}

/**
 * One picker row plus its option list.
 *
 * The label is the first parameter for the same reason as the bar action: 外观 /
 * 折叠时机 / 转录密度 are the contract's three picker actions. The option rows
 * take their text from [options], so they are data rows rather than named
 * actions.
 *
 * Disclosure provenance: the iOS source is a SwiftUI `Picker`
 * (`ChatPreferencesPage.swift:14`, `:48`, `:62`), whose options are a system
 * menu. It is not a `DisclosureGroup` and the source has no `withAnimation` /
 * `motion.disclosure`; the inline list below is Android's rendering of that menu,
 * so it deliberately stays static instead of inventing §7 body motion.
 */
@Composable
private fun ChatPreferencesMenuRow(
    label: String,
    value: String?,
    expanded: Boolean,
    enabled: Boolean,
    options: List<ChatPreferencesOption>,
    selectedOptionId: String?,
    dividerBelow: Boolean,
    onToggle: () -> Unit,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight)
                .clickable(enabled = enabled, role = Role.Button, onClick = onToggle)
                .padding(
                    start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    end = SettingsValueTrailingInset,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                )
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = label,
                style = settingsLabelStyle().copy(
                    color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
                ),
                modifier = Modifier.weight(1f),
            )
            SettingsRowValue(
                text = value ?: UiStrings.UNKNOWN,
                ink = if (value == null) tokens.colors.tertiary else tokens.colors.secondary,
            )
            SettingsTrailingSlot {
                SettingsMenuChevron(
                    ink = if (enabled) tokens.colors.secondary else tokens.colors.tertiary,
                )
            }
        }
        if (expanded) {
            options.forEach { option ->
                ChatPreferencesOptionRow(
                    option = option,
                    selected = option.id == selectedOptionId,
                    enabled = enabled,
                    onSelect = onSelect,
                    modifier = Modifier.testTag(
                        UiPageTags.CHAT_PREFERENCES_OPTION_PREFIX + option.id,
                    ),
                )
            }
        } else if (dividerBelow) {
            SettingsHairline(modifier = Modifier.padding(horizontal = SettingsSeparatorInset))
        }
    }
}

/** One entry of an open picker: the row's text comes from state, plus a ✓. */
@Composable
private fun ChatPreferencesOptionRow(
    option: ChatPreferencesOption,
    selected: Boolean,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = SettingsGroupedRowHeight)
            .clickable(enabled = enabled, role = Role.RadioButton) { onSelect(option.id) }
            .padding(
                start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                end = SettingsValueTrailingInset,
                top = tokens.spacing.iconText,
                bottom = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = option.label,
            style = settingsLabelStyle().copy(
                color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
            ),
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            BasicText(
                text = CHECK_GLYPH,
                style = settingsLabelStyle().copy(color = tokens.colors.accent),
            )
        }
        SettingsChevronSlot(withChevron = false)
    }
}

/** A stepper row: label, value in pt, then the baseline's − / + controls. */
@Composable
private fun ChatPreferencesStepperRow(
    label: String,
    value: String?,
    enabled: Boolean,
    canDecrease: Boolean,
    canIncrease: Boolean,
    dividerBelow: Boolean,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    SettingsRowFrame(dividerBelow = dividerBelow, modifier = modifier) {
        SettingsRowLabel(text = label, enabled = enabled, modifier = Modifier.weight(1f))
        SettingsRowValue(
            text = value ?: UiStrings.UNKNOWN,
            ink = if (value == null) tokens.colors.tertiary else tokens.colors.secondary,
        )
        StepperControl(
            mark = DECREASE_GLYPH,
            description = UiStrings.CHAT_PREFERENCES_STEPPER_DECREASE,
            enabled = enabled && canDecrease,
            onClick = onDecrease,
        )
        StepperControl(
            mark = INCREASE_GLYPH,
            description = UiStrings.CHAT_PREFERENCES_STEPPER_INCREASE,
            enabled = enabled && canIncrease,
            onClick = onIncrease,
        )
    }
}

/**
 * One stepper control: a glyph in a 44 pt tap target.
 *
 * [mark] is deliberately not named `glyph`/`label`: the page-local wrapper
 * idiom the contract checker recognises keys on a first parameter called
 * `label`/`description`/`glyph`, and these two controls are chrome (− / +), not
 * named actions — the contract does not list them and the checker must not
 * invent them.
 */
@Composable
private fun StepperControl(
    mark: String,
    description: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .defaultMinSize(
                minWidth = tokens.geometry.pageRowMinHeight,
                minHeight = tokens.geometry.pageRowMinHeight,
            )
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = mark,
            style = settingsLabelStyle().copy(
                color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
            ),
        )
    }
}

/** The steppers' two control glyphs (`Stepper`'s own − / +). */
private const val DECREASE_GLYPH: String = "−"
private const val INCREASE_GLYPH: String = "+"

/** The selected option's checkmark. */
private const val CHECK_GLYPH: String = "✓"

/** The tokens this page reads; `PageTokenReferenceTest` pins the inventory. */
internal object ChatPreferencesPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_ICON_TEXT,
    )
}
