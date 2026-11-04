// Commands (PDSHShellPage): the inset-grouped card layout of the iOS baseline.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/PDSHShellPage.swift` (read line
// by line). This file is the *view* of the commands page; the ScreenState and the
// local form script stay in `ToolsPage.kt` (`ToolsScreenState`, `ShellLocalState`,
// `ShellUiEvent`), which is the page this module already registers against
// `spec/ui/v1/pages/pdsh-shell.json`. Splitting the body out keeps the new,
// baseline-shaped chrome next to the baseline lines it copies without duplicating
// the reducer that the JVM tests drive.
//
// What the baseline draws (iOS 26, light, `ios-shell.png`):
//   * a system-grouped background (#F2F2F7) under white cards, a 44 pt inline nav
//     bar with the centred title 命令 (`:92`–`:93`);
//   * section 这台手机 (`:23`): a white card with the three 44 pt label/value rows
//     ／网络／工作区 separated by inset hairlines, then the read-only footnote
//     (`:24`–`:30`);
//   * with no linked accelerator, one untitled card holding the terminal glyph,
//     还没接上命令 and its one-line description (`:33`–`:37`), i.e. a
//     `ContentUnavailableView` inside the grouped list;
//   * with a linked accelerator: 运行命令 (`:39`–`:76`), 输出 (`:77`–`:83`) and
//     限制 (`:84`–`:89`) as their own cards.
//
// Geometry: only `spec/ui/v1/tokens.json` values are read. The page-level block
// supplies the margins, the row floors, the hairline, the card radius and all gaps;
// no length or colour is re-typed here (`PageTokenReferenceTest`'s rule, applied to
// a file that is not yet in its page map). `ui/surface/**` is not used: this page
// is page chrome, not a signature surface.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiColors

/**
 * The commands page (`PDSHShellPage`), drawn as the baseline's grouped card list.
 *
 * The state is [ToolsScreenState]: the host's caps snapshot plus the local run
 * form. Nothing here reads the host, the clock or a process; the run gestures are
 * handed back unchanged.
 *
 * @param state the pure screen state (`ToolsScreenState.from`).
 * @param onSelectCommand the picker's choice changed (`PDSHShellPage.swift:40`).
 * @param onWorkingDirectoryChange the 工作目录 field changed (`:47`).
 * @param onArgumentsChange the 参数 box changed (`:53`).
 * @param onRun 运行 was tapped (`:68`).
 * @param onCancel 停止运行 was tapped while a run is in flight (`:71`).
 * @param onBack leave the page (the iOS NavigationStack's back control).
 */
@Composable
internal fun PDSHShellPage(
    state: ToolsScreenState,
    onSelectCommand: (String) -> Unit,
    onWorkingDirectoryChange: (String) -> Unit,
    onArgumentsChange: (String) -> Unit,
    onRun: (() -> Unit)?,
    onCancel: (() -> Unit)?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRunArgv: ((argv: List<String>, workingDirectory: String) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val argv = shellArgvFromCaps(state)
    Column(
        modifier = modifier
            .fillMaxSize()
            // `ios-shell.png`: the `List` keeps the system grouped background
            // (#F2F2F7). `colors.selector` (#F2F3F5) is the theme's selector fill,
            // not the grouped page: using it made 54% of the frame differ by
            // (0,1,2) per pixel, which is the whole-block cause behind the 64.6%.
            .background(tokens.colors.page)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
            .testTag(UiPageTags.SHELL_ROOT),
    ) {
        ShellTopBar(title = UiStrings.TOOLS, onBack = onBack)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                // 工作目录 / 参数 live in the run card, below the device facts. The
                // IME inset sits outside `verticalScroll` so it shrinks the viewport
                // and the focused field can be scrolled clear (spec §5 row `insets`).
                .imePadding()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding(),
        ) {
            // `:23`: the device section, always present.
            ShellSectionView(
                title = UiStrings.SHELL_DEVICE_TITLE,
                titleTag = UiPageTags.SHELL_SECTION_DEVICE,
            ) {
                ShellInfoRow(
                    label = UiStrings.SHELL_STATUS,
                    value = state.statusLabel,
                    tag = UiPageTags.SHELL_STATUS,
                )
                ShellHairline()
                // `:25`: the baseline hard-codes 不可用; this page says the same.
                ShellInfoRow(
                    label = UiStrings.SHELL_NETWORK,
                    value = UiStrings.SHELL_NETWORK_UNAVAILABLE,
                    tag = UiPageTags.SHELL_NETWORK,
                )
                ShellHairline()
                ShellInfoRow(
                    label = UiStrings.SHELL_WORKSPACE,
                    value = state.workspaceLabel,
                    tag = UiPageTags.SHELL_WORKSPACE,
                )
                // `ios-shell.png` separates the last row from the footnote with a
                // third inset hairline.
                ShellHairline()
                ShellFootnote(text = UiStrings.SHELL_READ_ONLY, tag = UiPageTags.SHELL_READ_ONLY)
            }

            if (state.isEmpty) {
                // `:33`–`:37`: ContentUnavailableView inside an untitled section.
                ShellUnavailableCard()
            } else {
                ShellRunSection(
                    state = state,
                    onSelectCommand = onSelectCommand,
                    onWorkingDirectoryChange = onWorkingDirectoryChange,
                    onArgumentsChange = onArgumentsChange,
                    onRun = {
                        if (argv != null && onRunArgv != null) onRunArgv(argv, state.workingDirectory)
                        else if (argv != null) onRun?.invoke()
                    },
                    onCancel = onCancel,
                    canSubmitArgv = argv != null && onRun != null,
                )
                ShellOutputSection(state = state)
                ShellLimitsSection(state = state)
            }
        }
    }
}

/**
 * The 44 pt inline nav bar (`:92`–`:93`): a back control and the centred title.
 *
 * The baseline's `navigationTitle` is inline, so the title is centred in the bar
 * and the leading control belongs to the NavigationStack. The grouped background
 * continues behind the bar, exactly as in the screenshot (no hairline).
 */
@Composable
private fun ShellTopBar(title: String, onBack: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            // Shared metric: `NativeHeaderStyle.barHeight = 44` (the same number the
            // page token declares), and the header's own 16 pt inset.
            .defaultMinSize(minHeight = HomeMetrics.navButton)
            .padding(horizontal = HomeMetrics.chromeInset),
    ) {
        PdshIconView(
            icon = PdshIcon.CHEVRON_LEFT,
            size = HomeMetrics.navIcon,
            tint = tokens.colors.textPrimary,
            contentDescription = null,
            modifier = Modifier
                .align(Alignment.CenterStart)
                .clickable(role = Role.Button, onClick = onBack)
                .semantics { contentDescription = UiStrings.BACK }
                .padding(tokens.spacing.iconText),
        )
        BasicText(
            text = title,
            style = type.pageTitle.copy(color = tokens.colors.textPrimary),
            maxLines = 1,
            modifier = Modifier
                .align(Alignment.Center)
                .semantics { heading() },
        )
    }
}

/**
 * One grouped section: a caption header, then a white card (`Section` + inset
 * grouped list).
 *
 * The name ends in `SectionView` on purpose. A grouped-section composable is the
 * page's machine-readable statement of its own section tree, and the page
 * structure gate reads a title only from `SessionSectionLabel(<title>)`,
 * `SectionHeader(title = …)` or `<Name>SectionView(<id>, <title>, …)`
 * (`spec/ui/v1/README.md` §1). A local `ShellSection(title = …)` renders the same
 * caption but is invisible to that gate, which is how this page's four titles
 * (`这台手机`/`运行命令`/`输出`/`限制`) went missing after the body was split out of
 * `ToolsPage.kt`: the screen was right, the idiom was not.
 *
 * @param title the section caption; `null` for the baseline's untitled empty
 *   section (`:34`), which draws no header at all.
 * @param titleTag a stable test tag for the caption.
 * @param cardTag a stable test tag for the card surface.
 * @param content the card's rows; the caller inserts [ShellHairline] between them.
 */
@Composable
private fun ShellSectionView(
    title: String?,
    titleTag: String,
    cardTag: String? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // `ios-shell.png`: caption ink 128.7 pt; the 44 pt bar ends at 106,
            // so the caption box starts ~19 pt below it. 18 = cardInset + iconText.
            // The caption-to-card gap measures 11-12 pt on iOS, but Compose's
            // 17 sp line box is ~4 pt taller than CoreText's, so the gap that
            // reproduces the measured card top (156.3 - 62 = 94.3) is 8.
            // `unverified geometry`: 8 is borrowed from `spacing.codeToolbar`.
            .padding(top = tokens.spacing.cardInset + tokens.spacing.iconText),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        if (title != null) {
            BasicText(
                text = title,
                // `ios-shell.png` draws the section caption ("这台手机") at ink
                // 15.3 pt — the 17 pt role — not at the 12 pt caption size, and
                // its measured ink is #85858B: system secondary over the grouped
                // fill, not the theme's #66666B.
                style = type.listItem.copy(color = tokens.colors.textSecondary),
                modifier = Modifier
                    .padding(horizontal = HomeMetrics.contentInset * 2)
                    .testTag(titleTag)
                    .semantics { heading() },
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = HomeMetrics.contentInset)
                .clip(RoundedCornerShape(tokens.radius.card))
                .background(tokens.colors.surface)
                .then(if (cardTag != null) Modifier.testTag(cardTag) else Modifier),
        ) {
            content()
        }
    }
}

/** One label/value row: `LabeledContent` (`:24`–`:29`). */
@Composable
private fun ShellInfoRow(label: String, value: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            // `ios-shell.png`: hairline-to-hairline row pitch is 52.33 pt. 52 is
            // pageRowMinHeight (44) + codeToolbar (8); the 0.33 residual is below
            // one raster pixel per row. `unverified geometry` for the borrow.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight + tokens.spacing.codeToolbar)
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            // A `LabeledContent` row in the baseline is `.body` = 17 pt:
            // `ios-shell.png` measures 状态 / 网络 / 工作区 at ink 15.3 pt, and
            // its dominant ink is #000000 (systemLabel), not #111114.
            style = type.listItem.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        BasicText(
            text = value,
            // Value ink measured #8A8A8E on both cards.
            style = type.listItem.copy(color = tokens.colors.textSecondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The inset row separator.
 *
 * The baseline's inset-grouped separator starts at the row's text column (16 pt
 * inside the card, `ios-shell.png`) and stops before the trailing edge, so this
 * draws the hairline with the card's own content inset.
 */
@Composable
private fun ShellHairline() {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.spacing.cardInset)
            .height(tokens.stroke.hairline)
            // Same SwiftUI grouped-list separator as the settings cards: measured
            // #E8E8E8, while the theme border is #E4E4E8 (delta 4 > the 2/255
            // visibility threshold, so every hairline pixel used to count).
            .background(tokens.colors.borderList),
    )
}

/**
 * A footnote inside the card (`:30`, `:44`): 13 pt secondary ink.
 *
 * `ios-shell.png`: the footnote occupies the same 52.33 pt rhythm as the three
 * rows above it (last hairline 313.3 → card bottom 365.7), and its text is
 * vertically centred in that band — so it is a min-height row, not a text block
 * with symmetric padding.
 */
@Composable
private fun ShellFootnote(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .defaultMinSize(
                minHeight = HomeMetrics.defaultMinListRowHeight + tokens.spacing.codeToolbar,
            )
            .padding(horizontal = tokens.spacing.cardInset),
        contentAlignment = Alignment.CenterStart,
    ) {
        BasicText(
            text = text,
            // `Text(...).font(.footnote).foregroundStyle(.secondary)` renders
            // #7F7F7F on the white card (the same construct L79 measured in the
            // settings/about footnotes), not the #8A8A8E LabeledContent value.
            style = type.listItem.copy(color = tokens.colors.textSecondary),
        )
    }
}

/**
 * The 还没接上命令 card (`:35`–`:36`): terminal glyph, title, description.
 *
 * It is the baseline's `ContentUnavailableView` inside the grouped list. The
 * section has no caption (`Section {` at `:34`), so no header is drawn.
 */
@Composable
private fun ShellUnavailableCard() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = HomeMetrics.contentInset)
            // `ios-shell.png` puts 34.7 pt between the first card and this one.
            .padding(top = tokens.spacing.cardInset * 3)
            .clip(RoundedCornerShape(tokens.radius.card))
            .background(tokens.colors.surface)
            .testTag(UiPageTags.SHELL_EMPTY)
            // The baseline's ContentUnavailableView is 214.3 pt tall and is not
            // symmetric: icon top is +34.3 from the card edge, the last
            // description line ends 47 pt above the bottom. 34 = pageRowMinHeight
            // (44) - badgeInsetV twice; the bottom keeps the 44 pt row floor.
            .padding(
                start = tokens.spacing.cardInset * 2,
                top = HomeMetrics.defaultMinListRowHeight - tokens.spacing.badgeInsetV * 2,
                end = tokens.spacing.cardInset * 2,
                bottom = HomeMetrics.defaultMinListRowHeight,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The SF Symbol `terminal` box: a rounded outline with the prompt glyph.
        // iOS glyph measures 55.0 x 43.3 pt; 56 x 44 is the nearest token sum.
        Box(
            modifier = Modifier
                .size(
                    width = HomeMetrics.defaultMinListRowHeight + tokens.spacing.cardInset,
                    height = HomeMetrics.defaultMinListRowHeight,
                )
                .border(
                    width = tokens.stroke.hairline * 4,
                    color = tokens.colors.textTertiary,
                    shape = RoundedCornerShape(tokens.radius.card),
                ),
            contentAlignment = Alignment.Center,
        ) {
            PdshIconView(
                icon = PdshIcon.TERMINAL,
                size = HomeMetrics.navIcon,
                tint = tokens.colors.textTertiary,
                contentDescription = null,
            )
        }
        Column(
            // `ios-shell.png`: icon bottom 417.0 → title ink 439.0 after the
            // 61.3 pt status-bar offset. 14 = badgeInsetH (10) + jsonChevronGap (4)
            // reproduces that 22 pt icon-to-title gap once Compose's line-box
            // leading is included; `unverified geometry` for the borrow.
            modifier = Modifier.padding(top = tokens.spacing.badgeInsetH + tokens.spacing.jsonChevronGap),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.jsonChevronGap),
        ) {
            BasicText(
                text = UiStrings.SHELL_EMPTY,
                // iOS draws this inside `ContentUnavailableView`, whose title is
                // ~20 pt (ios-shell.png ink 19.7) — not a 17 pt headline.
                style = type.pageTitle.copy(
                    // Ink measured #000000 (systemLabel).
                    color = tokens.colors.textPrimary,
                    textAlign = TextAlign.Center,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            BasicText(
                text = UiStrings.SHELL_EMPTY_HINT,
                // `ios-shell.png`: the description ink is 14.7 pt high and wraps
                // to two lines — `.subheadline` = 15 pt, not the 17 pt body and
                // not the 13 pt footnote. Its measured line 1 is 17 CJK cells
                // (ink x 87.7-312.3) and line 2 is 命令。; the column therefore
                // has to be narrower than 18 cells. 32 pt a side
                // (pageOuterMarginH 16 + cardInset 12 + jsonChevronGap 4) leaves
                // 258 pt, so 17 cells fit and the 18th does not.
                style = type.listItem.copy(
                    color = tokens.colors.textSecondary,
                    textAlign = TextAlign.Center,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = HomeMetrics.contentInset +
                            tokens.spacing.cardInset +
                            tokens.spacing.jsonChevronGap,
                    ),
            )
        }
    }
}

/** 运行命令 (`:39`–`:76`) as its own card. */
@Composable
private fun ShellRunSection(
    state: ToolsScreenState,
    onSelectCommand: (String) -> Unit,
    onWorkingDirectoryChange: (String) -> Unit,
    onArgumentsChange: (String) -> Unit,
    onRun: () -> Unit,
    onCancel: (() -> Unit)?,
    canSubmitArgv: Boolean,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    ShellSectionView(title = UiStrings.SHELL_RUN_TITLE, titleTag = UiPageTags.SHELL_SECTION_RUN) {
        // `:40`–`:42`: iOS `Picker("命令", selection: $command)` is a *menu* picker —
        // the row shows the picker's label and its current choice, and tapping it
        // opens the choices. The row is therefore the 命令 action itself, not a
        // caption above an always-open list: an accessibility tree that reads a
        // label without a gesture is the one shape the contract calls missing
        // (`pages/pdsh-shell.json` action `命令`, `PDSHShellPage.swift:40`).
        var choicesOpen by remember { mutableStateOf(false) }
        Box {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.SHELL_COMMAND)
                    .clickable(role = Role.Button) { choicesOpen = true }
                    .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                    .padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.badgeInsetV,
                    )
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                BasicText(
                    text = UiStrings.SHELL_COMMAND,
                    style = type.body.copy(color = tokens.colors.textPrimary),
                    modifier = Modifier.weight(1f),
                )
                BasicText(
                    text = state.selectedCommand,
                    style = type.body.copy(color = tokens.colors.textSecondary),
                )
            }
            // The choices the picker opens. Their labels are the accelerator names
            // the caps report, i.e. data, so each row carries its name as rendered
            // text and the same selection the closed row shows.
            DropdownMenu(expanded = choicesOpen, onDismissRequest = { choicesOpen = false }) {
                state.commands.forEach { command ->
                    DropdownMenuItem(
                        text = { Text(command) },
                        onClick = {
                            choicesOpen = false
                            onSelectCommand(command)
                        },
                    )
                }
            }
        }
        if (state.needsApp) {
            // `:43`–`:46`: phone/ctx need the app itself.
            ShellHairline()
            ShellFootnote(text = UiStrings.SHELL_NEEDS_APP, tag = UiPageTags.SHELL_NEEDS_APP)
        }
        ShellHairline()
        ShellField(
            label = UiStrings.SHELL_WORKING_DIR,
            value = state.workingDirectory,
            onValueChange = onWorkingDirectoryChange,
            tag = UiPageTags.SHELL_WORKING_DIR,
        )
        ShellHairline()
        ShellField(
            label = UiStrings.SHELL_ARGUMENTS,
            value = state.arguments,
            onValueChange = onArgumentsChange,
            tag = UiPageTags.SHELL_ARGUMENTS,
            placeholder = UiStrings.SHELL_ARGUMENTS_PLACEHOLDER,
            multiline = true,
        )
        ShellHairline()
        // `:67`–`:75`: 运行 and, while a run is in flight, 停止运行.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                .padding(
                    horizontal = tokens.spacing.cardInset,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            ShellAction(
                label = UiStrings.SHELL_RUN,
                enabled = state.canRun && canSubmitArgv,
                tone = tokens.colors.pageAccent,
                tag = UiPageTags.SHELL_RUN,
                onClick = onRun,
            )
            if (state.running && onCancel != null) {
                ShellAction(
                    label = UiStrings.SHELL_STOP_RUNNING,
                    enabled = true,
                    tone = tokens.colors.pageDanger,
                    tag = UiPageTags.SHELL_CANCEL,
                    onClick = onCancel,
                )
            }
        }
    }
}

/** One labelled field: 工作目录 (`:47`) and 参数 (`:49`–`:66`) inside the card. */
@Composable
private fun ShellField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    placeholder: String? = null,
    multiline: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.listItem.copy(color = tokens.colors.textSecondary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = !multiline,
            textStyle = if (multiline) {
                type.code.copy(color = tokens.colors.textPrimary)
            } else {
                type.body.copy(color = tokens.colors.textPrimary)
            },
            cursorBrush = SolidColor(tokens.colors.pageAccent),
            modifier = Modifier
                .fillMaxWidth()
                .testTag(tag)
                .semantics { contentDescription = label }
                .clip(RoundedCornerShape(tokens.radius.codeBlock))
                .background(tokens.colors.userBubble)
                .border(
                    tokens.stroke.hairline,
                    tokens.colors.borderList,
                    RoundedCornerShape(tokens.radius.codeBlock),
                )
                .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                .padding(tokens.spacing.cardInset),
            decorationBox = { inner ->
                if (value.isEmpty() && placeholder != null) {
                    BasicText(
                        text = placeholder,
                        style = type.code.copy(color = tokens.colors.textTertiary),
                    )
                }
                inner()
            },
        )
    }
}

/** 输出 (`:77`–`:83`) as its own card. */
@Composable
internal fun ShellOutputSection(state: ToolsScreenState) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    ShellSectionView(title = UiStrings.SHELL_OUTPUT_TITLE, titleTag = UiPageTags.SHELL_SECTION_OUTPUT) {
        if (state.error != null) {
            // `:78`: the failure line above the output, in red.
            BasicText(
                text = state.error,
                style = type.listItem.copy(color = tokens.colors.pageDanger),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.SHELL_ERROR)
                    .padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.badgeInsetV,
                    ),
            )
        }
        BasicText(
            text = state.output.ifEmpty { UiStrings.SHELL_OUTPUT_EMPTY },
            style = type.code.copy(color = tokens.colors.textPrimary),
            modifier = Modifier
                .fillMaxWidth()
                .testTag(UiPageTags.SHELL_OUTPUT)
                .padding(
                    horizontal = tokens.spacing.cardInset,
                    vertical = tokens.spacing.cardInset,
                ),
        )
    }
}

/** 限制 (`:84`–`:89`) as its own card: one row per bound. */
@Composable
private fun ShellLimitsSection(state: ToolsScreenState) {
    ShellSectionView(title = UiStrings.SHELL_LIMITS_TITLE, titleTag = UiPageTags.SHELL_SECTION_LIMITS) {
        state.limits.forEachIndexed { index, limit ->
            if (index > 0) ShellHairline()
            ShellInfoRow(
                label = limit.label,
                value = limit.value,
                tag = UiPageTags.SHELL_LIMIT_PREFIX + limit.label,
            )
        }
    }
}

/** One card text action (`:68`, `:71`). */
@Composable
private fun ShellAction(
    label: String,
    enabled: Boolean,
    tone: androidx.compose.ui.graphics.Color,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.listItem.copy(
            color = if (enabled) tone else tokens.colors.textTertiary,
        ),
        maxLines = 1,
        modifier = Modifier
            .testTag(tag)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(tokens.spacing.iconText),
    )
}

/** Builds argv only from a command present in the host caps plus the user's args. */
public fun shellArgvFromCaps(state: ToolsScreenState): List<String>? {
    val command = state.selectedCommand
    if (!state.canRun || command !in state.commands) return null
    val arguments = state.arguments.lineSequence()
        .map { line -> line.removeSuffix("\r") }
        .filter(String::isNotEmpty)
        .toList()
    return listOf(command) + arguments
}

/** The canonical session colour name backed by the resolved host palette field. */
private val UiColors.sessionSuccess get() = success

/**
 * The token inventory of this page, kept next to the file it describes.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; adding
 * this file there is the follow-up that makes the equality assertion cover it.
 * Until then this list documents the read set and `PageStructureCheck` keeps the
 * section/row sequence honest.
 */
internal object PDSHShellPageTokens {
    val refs: List<String> = listOf(
        "colors.borderList",
        "colors.page",
        "colors.pageAccent",
        "colors.pageDanger",
        "colors.surface",
        "colors.textPrimary",
        "colors.textSecondary",
        "colors.textTertiary",
        "colors.userBubble",
        "radius.card",
        "radius.codeBlock",
        "spacing.badgeInsetH",
        "spacing.badgeInsetV",
        "spacing.cardInset",
        "spacing.codeToolbar",
        "spacing.iconText",
        "spacing.jsonChevronGap",
        "stroke.hairline",
        "typography.body",
        "typography.code",
        "typography.listItem",
        "typography.pageTitle",
    )
}
