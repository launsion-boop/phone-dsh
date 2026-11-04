// 快捷键: the keyboard shortcut reference, and the reset gesture.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/NativeShortcutsPage.swift` (93
// lines) at iOS HEAD, mirrored through `spec/ui/v1/pages/native-shortcuts.json`
// (3 sections / 5 rows / 2 actions):
//
//   * 应用命令 — one row per `NativeShortcutAction` (发送消息 / 另一种发送行为 /
//     停止当前回复 / 打开设置 / 打开快捷键速查 / 回到最新), the value being the
//     *effective* binding;
//   * 固定输入操作（只读） — three literal rows: 换行 ⇧↩, 发送 ↩, 另一种发送行为 ⌘↩;
//   * an untitled third section with one destructive row, 恢复全部默认, disabled
//     while no override exists (`NativeShortcutsPage.swift:22-27`).
//
// Editing is out of this page's contract: the Swift file's `NativeShortcutEditor`
// is a *private* struct in the same file, and the extracted contract lists only
// the page's own actions (the row's `NavigationLink` destination is recorded as
// `NativeShortcutEditor`, not as a sub-page with its own sections/actions).
// Android has no shortcut store to write yet either, so the rows are the
// baseline's read-only reference table: tapping one is not offered, and the
// in-card footnote says the host owns the bindings instead of drawing a row that
// opens nothing.
//
// Data: `NativeShortcutsFacts.overrides` is the host's shortcut store. `null`
// means *not read*: every value renders 未知 and no default binding is invented
// (an unread store is not "all defaults"). `emptyMap()` means *read, no
// overrides*: the rows show the baseline's defaults and 恢复全部默认 is disabled,
// exactly as `.disabled(preferences.shortcutOverrides.isEmpty)` does.
//
// Geometry: the sub-page frame, the inset-grouped card and the 52.33 pt row come
// from `com.phonedsh.ui.surface`; no length or colour is re-typed here.
//
// Contract note: 恢复全部默认 is the contract's one labelled action and the
// untitled third group's criterion row, so it is drawn as a page-local row whose
// text is a `UiStrings` literal and whose tap target is the row itself. The
// command rows take their titles from `ChatShortcutAction.title` (data), which is
// the baseline's own `nativeShortcutTitle(action)` shape: they are data rows, not
// named actions, so the two platforms stay comparable.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsGroupedRow
import com.phonedsh.ui.surface.SettingsGroupedRowHeight
import com.phonedsh.ui.surface.SettingsListTopInset
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsValueTrailingInset
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/**
 * The six application commands, in `NativeShortcutAction.allCases`' order.
 *
 * @param id the baseline's raw value (the contract's stable id).
 * @param title the row's fixed label (`nativeShortcutTitle(action)`).
 */
public enum class ChatShortcutAction(public val id: String, public val title: String) {
    SEND("send", UiStrings.SHORTCUTS_ACTION_SEND),
    ALTERNATE("alternate", UiStrings.SHORTCUTS_ACTION_ALTERNATE),
    STOP("stop", UiStrings.SHORTCUTS_ACTION_STOP),
    SETTINGS("settings", UiStrings.SHORTCUTS_ACTION_SETTINGS),
    SHORTCUTS("shortcuts", UiStrings.SHORTCUTS_ACTION_SHORTCUTS),
    LATEST("latest", UiStrings.SHORTCUTS_ACTION_LATEST),
}

/**
 * One keyboard binding: a key plus the four modifiers.
 *
 * The representation is the baseline's (`NativeShortcut` in
 * `NativeChatPreferences.swift`), because the display order (⌃⌥⇧⌘ then the key)
 * is part of the copy the pages show.
 */
@Immutable
public data class ChatShortcut(
    public val key: String,
    public val command: Boolean = false,
    public val option: Boolean = false,
    public val shift: Boolean = false,
    public val control: Boolean = false,
) {
    /** The baseline's `display`: modifiers in ⌃⌥⇧⌘ order, then the key. */
    public val display: String
        get() = buildString {
            if (control) append(MODIFIER_CONTROL)
            if (option) append(MODIFIER_OPTION)
            if (shift) append(MODIFIER_SHIFT)
            if (command) append(MODIFIER_COMMAND)
            append(keyDisplay)
        }

    public companion object {
        /** `NativeShortcutAction.defaultShortcut`, action by action. */
        public fun defaultFor(action: ChatShortcutAction): ChatShortcut = when (action) {
            ChatShortcutAction.SEND -> ChatShortcut(key = KEY_RETURN)
            ChatShortcutAction.ALTERNATE -> ChatShortcut(key = KEY_RETURN, command = true)
            ChatShortcutAction.STOP -> ChatShortcut(key = KEY_ESCAPE)
            ChatShortcutAction.SETTINGS -> ChatShortcut(key = KEY_COMMA, command = true)
            ChatShortcutAction.SHORTCUTS -> ChatShortcut(key = KEY_SLASH, command = true)
            ChatShortcutAction.LATEST -> ChatShortcut(key = KEY_DOWN_ARROW, command = true)
        }
    }
}

/** The key's own glyph: `return` / `escape` / `downArrow` are named, the rest are characters. */
private val ChatShortcut.keyDisplay: String
    get() = when (key) {
        KEY_RETURN -> RETURN_GLYPH
        KEY_ESCAPE -> ESCAPE_GLYPH
        KEY_DOWN_ARROW -> DOWN_ARROW_GLYPH
        else -> key.uppercase()
    }

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The page's read-only input.
 *
 * @param overrides the host's non-default bindings. `null` means the host did not
 *   report its shortcut store (未知, no invented defaults); an empty map means it
 *   reported the store and there are no overrides.
 * @param writable whether the host can persist a change. 恢复全部默认 is offered
 *   only for `FactState.YES`, because resetting is a write.
 */
@Immutable
public data class NativeShortcutsFacts(
    public val overrides: Map<ChatShortcutAction, ChatShortcut>? = null,
    public val writable: FactState = FactState.UNKNOWN,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * One 应用命令 row.
 *
 * @param action the command.
 * @param value the effective binding's display; `null` when the store was unread.
 * @param overridden true when the host stores a non-default binding.
 */
@Immutable
public data class ShortcutCommandRowView(
    public val action: ChatShortcutAction,
    public val value: String?,
    public val overridden: Boolean,
)

/** One 固定输入操作 row: literal copy, not a preference. */
@Immutable
public data class ShortcutFixedRowView(
    public val id: String,
    public val label: String,
    public val keys: String,
)

/**
 * The page state.
 *
 * @param commands the six commands, in the baseline's order.
 * @param fixed the three fixed rows, in the baseline's order.
 * @param storeKnown whether the host reported its shortcut store at all.
 * @param canResetAll true only when the store was read, holds at least one
 *   override, and the host can write — the three conditions `.disabled` encodes
 *   in the baseline plus the host's measured write capability.
 */
@Immutable
public data class NativeShortcutsScreenState(
    public val commands: List<ShortcutCommandRowView>,
    public val fixed: List<ShortcutFixedRowView>,
    public val storeKnown: Boolean,
    public val canResetAll: Boolean,
) {
    public companion object {
        public const val FIXED_NEW_LINE_ID: String = "new-line"
        public const val FIXED_SEND_ID: String = "send"
        public const val FIXED_ALTERNATE_ID: String = "alternate"

        /** Projects the facts into the three sections' rows. Pure. */
        public fun from(facts: NativeShortcutsFacts): NativeShortcutsScreenState {
            val overrides = facts.overrides
            val commands = ChatShortcutAction.entries.map { action ->
                val override = overrides?.get(action)
                ShortcutCommandRowView(
                    action = action,
                    value = if (overrides == null) {
                        null
                    } else {
                        (override ?: ChatShortcut.defaultFor(action)).display
                    },
                    overridden = override != null,
                )
            }
            return NativeShortcutsScreenState(
                commands = commands,
                fixed = listOf(
                    ShortcutFixedRowView(
                        id = FIXED_NEW_LINE_ID,
                        label = UiStrings.SHORTCUTS_FIXED_NEW_LINE,
                        keys = UiStrings.SHORTCUTS_FIXED_NEW_LINE_KEYS,
                    ),
                    ShortcutFixedRowView(
                        id = FIXED_SEND_ID,
                        label = UiStrings.SHORTCUTS_FIXED_SEND,
                        keys = UiStrings.SHORTCUTS_FIXED_SEND_KEYS,
                    ),
                    ShortcutFixedRowView(
                        id = FIXED_ALTERNATE_ID,
                        label = UiStrings.SHORTCUTS_FIXED_ALTERNATE,
                        keys = UiStrings.SHORTCUTS_FIXED_ALTERNATE_KEYS,
                    ),
                ),
                storeKnown = overrides != null,
                canResetAll = overrides != null &&
                    overrides.isNotEmpty() &&
                    facts.writable == FactState.YES,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/**
 * The 快捷键 page.
 *
 * @param state the pure screen state ([NativeShortcutsScreenState.from]).
 * @param onResetAll the 恢复全部默认 gesture; only reachable when
 *   [NativeShortcutsScreenState.canResetAll].
 * @param onBack leave the page (the baseline's pushed-page back chevron).
 */
@Composable
public fun NativeShortcutsPage(
    state: NativeShortcutsScreenState,
    onResetAll: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    SettingsSubPageFrame(
        modifier = modifier,
        title = UiStrings.SHORTCUTS_TITLE,
        onBack = onBack,
        backGlyph = PAGE_BACK_GLYPH,
        backTag = UiPageTags.SHORTCUTS_BACK,
        grouped = true,
        rootTag = UiPageTags.SHORTCUTS_ROOT,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.SHORTCUTS_LIST),
            contentPadding = PaddingValues(
                top = SettingsListTopInset,
                bottom = tokens.spacing.cardInset,
            ),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            item(key = "commands") {
                Column {
                    SettingsSectionLabel(
                        UiStrings.SHORTCUTS_SECTION_COMMANDS,
                        tag = UiPageTags.SHORTCUTS_ROOT + ".commands",
                    )
                    SettingsGroupCard {
                        state.commands.forEachIndexed { index, row ->
                            SettingsGroupedRow(
                                title = row.action.title,
                                value = row.value ?: UiStrings.UNKNOWN,
                                valueInk = if (row.value == null) {
                                    tokens.colors.tertiary
                                } else {
                                    tokens.colors.secondary
                                },
                                dividerBelow = index != state.commands.lastIndex,
                                modifier = Modifier.testTag(
                                    UiPageTags.SHORTCUTS_COMMAND_PREFIX + row.action.id,
                                ),
                            )
                        }
                        SettingsFootnoteRow(
                            text = if (state.storeKnown) {
                                UiStrings.SHORTCUTS_READ_ONLY_HINT
                            } else {
                                UiStrings.SHORTCUTS_UNKNOWN_HINT
                            },
                            modifier = Modifier.testTag(UiPageTags.SHORTCUTS_HINT),
                            dividerBelow = false,
                        )
                    }
                }
            }
            item(key = "fixed") {
                Column {
                    SettingsSectionLabel(
                        UiStrings.SHORTCUTS_SECTION_FIXED,
                        tag = UiPageTags.SHORTCUTS_ROOT + ".fixed",
                    )
                    SettingsGroupCard {
                        state.fixed.forEachIndexed { index, row ->
                            SettingsGroupedRow(
                                title = row.label,
                                value = row.keys,
                                dividerBelow = index != state.fixed.lastIndex,
                                modifier = Modifier.testTag(
                                    UiPageTags.SHORTCUTS_FIXED_PREFIX + row.id,
                                ),
                            )
                        }
                    }
                }
            }
            item(key = "reset") {
                // No section label: the baseline's third group is untitled, and
                // its row is the contract's criterion for that group.
                SettingsGroupCard {
                    ShortcutResetRow(
                        enabled = state.canResetAll,
                        onReset = onResetAll,
                        modifier = Modifier.testTag(UiPageTags.SHORTCUTS_RESET),
                    )
                }
            }
        }
    }
}

/**
 * The 恢复全部默认 row: destructive ink, the row itself is the tap target, and
 * the label is the contract's action/criterion literal.
 */
@Composable
private fun ShortcutResetRow(
    enabled: Boolean,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = SettingsGroupedRowHeight)
            .clickable(enabled = enabled, role = Role.Button, onClick = onReset)
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
            text = UiStrings.SHORTCUTS_RESET_ALL,
            style = settingsLabelStyle().copy(
                color = if (enabled) tokens.colors.danger else tokens.colors.tertiary,
            ),
        )
    }
}

/** The keys the baseline names instead of showing a character (`NativeShortcut`). */
private const val KEY_RETURN: String = "return"
private const val KEY_ESCAPE: String = "escape"
private const val KEY_DOWN_ARROW: String = "downArrow"
private const val KEY_COMMA: String = ","
private const val KEY_SLASH: String = "/"

/** The display glyphs for the three named keys. */
private const val RETURN_GLYPH: String = "↩"
private const val ESCAPE_GLYPH: String = "esc"
private const val DOWN_ARROW_GLYPH: String = "↓"

/** The modifier glyphs, in the baseline's display order. */
private const val MODIFIER_CONTROL: String = "⌃"
private const val MODIFIER_OPTION: String = "⌥"
private const val MODIFIER_SHIFT: String = "⇧"
private const val MODIFIER_COMMAND: String = "⌘"

/** The tokens this page reads; `PageTokenReferenceTest` pins the inventory. */
internal object NativeShortcutsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_ICON_TEXT,
    )
}
