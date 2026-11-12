// The Settings family's iOS-measured list chrome.
// SPDX-License-Identifier: MIT
//
// Why this file exists: `PageScaffold.kt` (the generic page frame + `InfoRow`)
// is another lane's file and is shared with chat/sessions/files, so it cannot
// grow Settings-only geometry. The Settings pages therefore own their chrome
// here, in the surface package, once — instead of each page re-typing a row.
//
// **Which baseline.** The Settings page was rewritten in iOS PR #13
// (`SettingsPage.swift`, 255 lines) into a five-tab `Picker(.segmented)` over an
// inset-grouped `List`. The chrome in the first half of this file is that
// *current* page: 52.33 pt rows, 1.0 pt separators, 17 pt labels **and values**,
// 26 pt cards, a 32 pt segmented track. Every one of those numbers is read from
// `com.phonedsh.ui.SettingsMetrics`, which carries the measurement and its PNG
// coordinate; this file must not re-type one.
//
// What is **gone** from the old flat list (and therefore from this file): the
// 44 pt row, the 0.33 pt hairline, the 15 pt value, the 20 pt chevron slot
// pinned to a 350 pt value edge, and the `x 32.7 / 24 above / 8 below` group
// header. Those were measured on `ios-settings.png`, a pre-#13 screenshot of a
// layout the Swift source no longer renders. `SettingsMetrics`' header records
// the same removal; keeping them here would have made a stale baseline look
// authoritative.
//
// The six sub-pages (`AboutPage`, `ModelProviderSettingsPage`,
// `WebSearchSettingsPage`, `EgressAllowListPage`, `RuntimeDetailsPage`,
// `NativeConfigurationPage`, `MCPSettingsPage`) were **not** rewritten by
// PR #13: their Swift sources still render the plain `List` they always did, so
// their geometry comes from the six `docs/receipts/ios-baseline-screens/
// ios-settings-*.png` and not from `SettingsMetrics`. Those measurements live in
// the second half of this file, each with the PNG coordinate it came from.
//
// Token discipline: colours and the system type roles (17/600, 17/400, 13/400)
// come from `LocalUiTokens`/`LocalUiType`. Only values no token declares (the
// measured insets, the chevron glyph, the switch) are page-layer constants, each
// marked `unverified geometry` with the measurement it reproduces. The token
// table's own deltas against the baseline (#E4E4E8 vs #E8E8E8 separator,
// #3964FE vs #2F5BFF accent, #111114 vs #000000 primary ink) are *not* papered
// over here: they are spec-level and reported as a gap, not re-typed as
// literals.
package com.phonedsh.ui.surface

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.page.PageTone
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Current grouped-list geometry: read from SettingsMetrics, never re-typed
// ---------------------------------------------------------------------------

/** HomeSpec's source-backed minimum row height, shared by grouped page controls. */
public val SettingsGroupedRowHeight: Dp get() = HomeMetrics.defaultMinListRowHeight

/** The 1.0 pt separator (3 px @3x), measured at y=760/1179/… in `settings-chat.png`. */
public val SettingsSeparatorThickness: Dp get() = SettingsMetrics.SEPARATOR_HEIGHT_PT.dp

/** The separator's 16 pt inset inside a card (card x 48 px → line x 96 px). */
public val SettingsSeparatorInset: Dp get() = SettingsMetrics.separatorInset

/** The card's 16 pt side margin (card x 48..1157 px on a 402 pt screen). */
public val SettingsCardMargin: Dp get() = SettingsMetrics.cardMargin

/** The card's 26 pt continuous corner, measured by fitting the top-left arc. */
public val SettingsCardRadius: Dp get() = SettingsMetrics.cardRadius

/** The 38.67 pt gap between two cards (116 px at y=914→1030). */
public val SettingsCardGap: Dp get() = SettingsMetrics.SECTION_GAP_PT.dp

/** The 34.67 pt from the list's top edge to the first card (y=502→606 px). */
public val SettingsListTopInset: Dp get() = SettingsMetrics.FIRST_CARD_TOP_INSET_PT.dp

/**
 * The 45.0 pt from a grouped *sub-page's* bar bottom to its first card.
 *
 * `ios-settings-about.png`: bar ends 106 pt, card top 151 pt. A pushed page's
 * `List` starts under the bar and keeps the whole navigation content inset,
 * unlike the general tab whose list starts below the picker.
 */
public val SettingsSubPageGroupedTopInset: Dp get() = SettingsMetrics.SUB_PAGE_GROUPED_TOP_INSET_PT.dp

/** The 39.33 pt from a card's trailing edge to a row value's right edge. */
public val SettingsValueTrailingInset: Dp get() = SettingsMetrics.VALUE_TRAILING_INSET_PT.dp

/** The 14 pt from a card's trailing edge to the switch (switch right 1115 px). */
public val SettingsSwitchTrailingInset: Dp get() = SettingsMetrics.SWITCH_TRAILING_INSET_PT.dp

/** The 20.67 pt slot between a value's right edge and the chevron's right edge. */
public val SettingsChevronSlotWidth: Dp get() = SettingsMetrics.VALUE_CHEVRON_SLOT_PT.dp

/**
 * A *menu* row's trailing insets, measured separately from a navigation row's.
 *
 * `ios-settings.png` 语言: the value's ink ends at 351.7 pt and the
 * `chevron.up.chevron.down` at 367.7 pt, i.e. 17.6 pt from the card's trailing
 * edge (385.3) with a 16.0 pt glyph slot. A navigation row (`权限`) instead puts
 * the value at 346.3 and a 6.33 pt `chevron.right` at 367 — the 20.67 + 39.33
 * pair this file already had. Using the navigation geometry for both left every
 * menu value 20 pt short of its baseline position.
 */
public val SettingsMenuTrailingInset: Dp get() = SettingsMetrics.MENU_TRAILING_INSET_PT.dp
public val SettingsMenuChevronSlot: Dp get() = SettingsMetrics.MENU_CHEVRON_SLOT_PT.dp

/** The segmented track: 32 pt tall, 16 pt inset, capsule (r = height / 2). */
public val SettingsSegmentHeight: Dp get() = SettingsMetrics.segmentedHeight
public val SettingsSegmentInset: Dp get() = SettingsMetrics.segmentedInset
public val SettingsSegmentRadius: Dp get() = SettingsMetrics.SEGMENTED_RADIUS_PT.dp

/** The 20 pt from the 44 pt bar's bottom edge to the segmented track's top. */
public val SettingsSegmentTopGap: Dp get() = SettingsMetrics.SEGMENTED_TOP_GAP_PT.dp

/**
 * The 15 pt vertical padding iOS's segmented control puts around its 32 pt
 * track: the page declares 10 (`SettingsPage.swift:70`) and the bar-to-track gap
 * is measured at 20, so 10 of it is the page's own padding and the other 10 is
 * the navigation content inset `SettingsMetrics.SEGMENTED_TOP_GAP_PT` splits.
 */
public val SettingsSegmentPaddingV: Dp get() = SettingsMetrics.SEGMENTED_PADDING_V_PT.dp

// ---------------------------------------------------------------------------
// Ink: system .label / .secondary / the footnote's measured grey
// ---------------------------------------------------------------------------

/**
 * The ink a grouped page's rows draw, when the page has the iOS system inks.
 *
 * iOS's settings rows are `List` rows, so their text is the *system* inks
 * (`UIColor.label` #000000, `secondaryLabel` #8A8A8E) while the app's own theme
 * paints `colors.primary` (#111114) and `colors.secondary` (#66666B). The
 * footnote is a third colour again: `.foregroundStyle(.secondary)` on a
 * `.footnote` renders #7F7F7F, not #8A8A8E (`colors.settingsFootnoteInk`).
 *
 * The two L79 pages provide this; every other settings page keeps the theme
 * inks it was measured with, so the default (null) is the previous behaviour.
 *
 * @param label the row title ink (`colors.systemLabel`).
 * @param value the row value / caption ink (`colors.systemSecondary`).
 * @param footnote the 13 pt footnote ink (`colors.settingsFootnoteInk`).
 */
@Immutable
public data class SettingsRowInk(
    public val label: Color,
    public val value: Color,
    public val footnote: Color,
)

/** `null` = draw with the theme tokens (the pre-L79 behaviour). */
public val LocalSettingsRowInk: androidx.compose.runtime.ProvidableCompositionLocal<SettingsRowInk?> =
    compositionLocalOf { null }

/** The row-label ink: the page's override, else the theme's primary. */
@Composable
public fun settingsLabelInk(): Color =
    LocalSettingsRowInk.current?.label ?: LocalUiTokens.current.colors.textPrimary

/** The row-value ink: the page's override, else the HomeSpec placeholder role. */
@Composable
public fun settingsValueInk(): Color =
    LocalSettingsRowInk.current?.value ?: LocalUiTokens.current.colors.textPlaceholder

/** The footnote ink: the page's override, else HomeSpec secondary text. */
@Composable
public fun settingsFootnoteInk(): Color =
    LocalSettingsRowInk.current?.footnote ?: LocalUiTokens.current.colors.textSecondary

/**
 * The 17 pt row text's 1 pt optical lift ([SettingsMetrics.ROW_TEXT_OPTICAL_OFFSET_PT]).
 *
 * Applied to labels and values only: it is a draw offset, so the row's height and
 * its trailing controls do not move.
 */
@Composable
public fun settingsRowTextLift(): Modifier =
    Modifier.offset(y = SettingsMetrics.ROW_TEXT_OPTICAL_OFFSET_PT.dp)

/**
 * The HomeSpec page inks used where iOS delegates to adaptive system labels.
 * Android currently uses the reviewed HomeSpec text roles; this is a resolved
 * palette approximation, not an implementation of UIKit dynamic label colors.
 */
@Composable
public fun settingsSystemInk(): SettingsRowInk = LocalUiTokens.current.let { tokens ->
    SettingsRowInk(
        label = tokens.colors.textPrimary,
        value = tokens.colors.textSecondary,
        footnote = tokens.colors.textSecondary,
    )
}

// ---------------------------------------------------------------------------
// Sub-page geometry: measured on the six `ios-settings-*.png` sub-page shots
// ---------------------------------------------------------------------------

/**
 * unverified geometry: the large title's 17 pt leading inset.
 *
 * `ios-settings-model.png` / `-plugins` / `-runtime` / `-search`: the 34 pt CJK
 * title's ink starts at x=51 px, 51..55 px across the four shots → 17 pt, which
 * is iOS's large-title inset. `tokens.json` has no such length.
 */
public val SettingsLargeTitleInset: Dp = 17.dp

/**
 * unverified geometry: the large title's 14 pt gap below the 44 pt bar.
 *
 * The four large-title shots put the ink box at y=376..465 px = 125.67..155 pt.
 * The bar ends at 62 + 44 = 106 pt, so the ink starts 19.67 pt below it; a 34 pt
 * line box puts ~5.5 pt of ascent above the CJK ink, so the *block* starts 14 pt
 * below the bar. Derived, not measured: the ink box is the measurement, the
 * block offset is arithmetic on it.
 */
public val SettingsLargeTitleTopGap: Dp = 14.dp

/**
 * unverified geometry: the section label's 33 pt indent on the sub-pages.
 *
 * `ios-settings-model.png` `服务` ink x=99 px → 33 pt; `-search`'s
 * `用哪一份搜索` and `-plugins`' `内置插件设置` sit on the same 33 pt line.
 * `-network`'s `地址` sits at 32.7 pt, inside the measurement's rounding.
 */
public val SettingsSectionLabelIndent: Dp = 33.dp

/**
 * unverified geometry: the sub-page row content's 33 pt indent for an
 * icon-bearing row (model / plugins), and 17 pt for a plain row (network).
 *
 * `ios-settings-model.png`: the action rows' labels start at x=216 px = 72 pt
 * after a 33 pt icon; `-network`'s host labels start at x=51 px = 17 pt.
 */
public val SettingsIconRowLabelIndent: Dp = 72.dp

/**
 * unverified geometry: the sub-page separator's leading inset.
 *
 * `-network` hairlines run x=48..1109 px → 16..369.67 pt; `-model` / `-plugins`
 * run x=216..1109 px → 72..369.67 pt (they begin where the label does, i.e.
 * after the 33 pt icon column); `-runtime` runs x=48..1157 px → 16..385.67 pt.
 * The trailing inset is therefore 32.33 pt on four of the six and 16 pt on
 * `-runtime`.
 */
public val SettingsSubPageSeparatorTrailingInset: Dp = 32.33f.dp

/** unverified geometry: `-runtime` runs its hairlines to a 16 pt trailing inset. */
public val SettingsSubPageSeparatorTrailingInsetWide: Dp = 16.dp

/** unverified geometry: the 6.33 x 11.33 pt `chevron.right` glyph (x 1083..1101 px). */
private val ChevronWidth: Dp = SettingsMetrics.CHEVRON_WIDTH_PT.dp
private val ChevronHeight: Dp = SettingsMetrics.CHEVRON_HEIGHT_PT.dp
private val ChevronStroke: Dp = 2.dp

/** unverified geometry: the 16 pt `chevron.up.chevron.down` on a menu row. */
private val MenuChevronWidth: Dp = 10.dp
private val MenuChevronHeight: Dp = 16.dp
private val MenuChevronStroke: Dp = 2.dp

/** unverified geometry: the iOS 26 switch, 63 x 29.67 pt with a 26 pt thumb. */
public val SettingsSwitchWidth: Dp get() = SettingsMetrics.switchWidth
public val SettingsSwitchHeight: Dp get() = SettingsMetrics.switchHeight
private val SettingsSwitchThumb: Dp = 26.dp
private val SettingsSwitchTrackRadius: Dp = 14.5.dp

// ---------------------------------------------------------------------------
// Type roles
// ---------------------------------------------------------------------------

/**
 * HomeSpec list copy uses the canonical 16/24 body role.
 */
@Composable
public fun settingsLabelStyle(): TextStyle =
    LocalUiType.current.homeBody

/**
 * The row value uses the HomeSpec 16/24 body role; the caller supplies its ink.
 */
@Composable
public fun settingsValueStyle(): TextStyle =
    LocalUiType.current.homeBody

/**
 * The settings footer uses the HomeSpec 13 pt secondary role.
 */
@Composable
public fun settingsFootnoteStyle(): TextStyle =
    LocalUiType.current.secondary

/**
 * A page-section label uses the HomeSpec 13 pt secondary role.
 */
@Composable
public fun settingsSectionLabelStyle(): TextStyle =
    LocalUiType.current.secondary

/**
 * The HomeSpec large-title role from generated typography tokens.
 */
@Composable
public fun settingsLargeTitleStyle(): TextStyle =
    LocalUiType.current.largeTitle

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

/**
 * The 44 pt nav bar: optional leading action, centred 17 pt semibold title,
 * optional trailing action (the baseline centres 通用设置 between nothing and
 * 完成).
 *
 * @param title the inline title; `null` on a page whose title is a large title
 *   drawn in the content instead.
 * @param onBack when set, draws the baseline's leading back chevron.
 * @param backTag an optional stable test tag for the back control.
 * @param leading an optional leading slot that replaces the back chevron.
 * @param trailing an optional trailing slot.
 */
@Composable
public fun SettingsNavBar(
    title: String?,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    backTag: String? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
    ) {
        Box(modifier = Modifier.align(Alignment.CenterStart)) {
            when {
                leading != null -> leading()
                onBack != null -> {
                    val tag = if (backTag != null) Modifier.testTag(backTag) else Modifier
                    BasicText(
                        text = BACK_GLYPH,
                        style = settingsLabelStyle().copy(color = tokens.colors.textPrimary),
                        modifier = tag
                            .clickable(role = Role.Button, onClick = onBack)
                            .semantics { contentDescription = UiStrings.BACK }
                            .padding(vertical = tokens.spacing.iconText, horizontal = tokens.spacing.iconText),
                    )
                }
            }
        }
        if (title != null) {
            BasicText(
                text = title,
                // An inline navigation title is UIKit's .label, i.e. #000000; the
                // theme's #111114 leaves a 17/255 delta on every glyph core. Measured
                // on `ios-settings.png` 通用设置 (2,101 px of #000000).
                style = type.pageTitle.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .align(Alignment.Center)
                    .semantics { heading() },
            )
        }
        Box(modifier = Modifier.align(Alignment.CenterEnd)) {
            trailing?.invoke()
        }
    }
}

/**
 * A bar affordance: the baseline's 完成, a ✕, or the `‹` back chevron.
 *
 * @param description the spoken label; defaults to the glyph. A ✕ on a pushed
 *   page is still a *back* action to a screen reader, so the sub-page frame
 *   passes `返回` here while the glyph stays the baseline's.
 */
@Composable
public fun SettingsNavAction(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    description: String = text,
    enabled: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = LocalUiType.current.pageTitle.copy(
            color = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary,
        ),
        modifier = modifier
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(vertical = tokens.spacing.iconText, horizontal = tokens.spacing.iconText),
    )
}

/**
 * The five-segment picker: a 32 pt capsule track, 16 pt side inset, the selected
 * segment drawn as a white pill (measured track y=378..473 px, x=48..1157 px).
 *
 * Labels are caller-supplied fixed copy, in the baseline's order.
 *
 * @param selected the index the host reported; an out-of-range index renders no
 *   selected pill instead of guessing one.
 * @param onSelect a segment was tapped.
 * @param tag an optional stable test tag for the track.
 */
@Composable
public fun SettingsSegmentedPicker(
    labels: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = SettingsSegmentInset)
            .height(SettingsSegmentHeight)
            .clip(RoundedCornerShape(SettingsSegmentRadius))
            // HomeSpec uses a white track and a black selected segment. The
            // old system segmentTrack token is unresolved and belongs to no
            // current iOS owner.
            .background(tokens.colors.surface)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .semantics(mergeDescendants = false) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        labels.forEachIndexed { index, label ->
            val isSelected = index == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .padding(SETTINGS_SEGMENT_INSET_INNER)
                    .then(
                        if (isSelected) {
                            Modifier
                                .clip(RoundedCornerShape(SettingsSegmentRadius))
                                .background(tokens.colors.primaryButton)
                        } else {
                            Modifier
                        },
                    )
                    .clickable(role = Role.Button) { onSelect(index) }
                    .then(if (tag != null) Modifier.testTag("$tag-segment-$index") else Modifier)
                    .semantics {
                        stateDescription = if (isSelected) UiStrings.EXPANDED else UiStrings.COLLAPSED
                    },
                contentAlignment = Alignment.Center,
            ) {
                BasicText(
                    text = label,
                    // UISegmentedControl's label is 13 pt, not the 17 pt row label:
                    // the baseline's 通用 ink box is 11.33 pt tall (13 pt CJK), and
                    // a 17 pt label measures 15.3-16.0 pt in the same track.
                    style = settingsFootnoteStyle().copy(
                        // UISegmentedControl draws *every* label in .label, selected
                        // or not: the baseline's 模型/插件/手机权限/预设 are black, not
                        // the secondary grey the previous mapping used.
                        color = if (isSelected) tokens.colors.primaryButtonInk else tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** unverified geometry: the 2 pt white pill's inset inside a 32 pt track. */
private val SETTINGS_SEGMENT_INSET_INNER: Dp = 2.dp

/**
 * One inset-grouped card: white, 26 pt corner, 16 pt side margins, its last row
 * carrying no separator.
 *
 * @param content the card's rows; each row is a [SettingsGroupedRow] or a
 *   [SettingsFootnoteRow], in the baseline's order.
 */
@Composable
public fun SettingsGroupCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = SettingsCardMargin)
            .clip(RoundedCornerShape(SettingsCardRadius))
            .background(tokens.colors.surface),
    ) {
        content()
    }
}

/**
 * One 52.33 pt row inside a card: 16 pt content inset, optional chevron slot,
 * optional 1 pt separator below.
 *
 * The separator is drawn as a sibling `Box` so it never adds height: the
 * baseline's row pitch is exactly 52.33 pt (157 px @3x) while a Column child
 * separator would make it 53.33.
 *
 * @param value the trailing value; `null` for a row with no value.
 * @param valueInk the value's ink; `null` uses the secondary token.
 * @param chevron draw the trailing chevron (and reserve its slot).
 * @param dividerBelow draw the 1 pt separator under this row.
 * @param onClick the row's tap action; `null` keeps the row read-only.
 */
@Composable
public fun SettingsGroupedRow(
    title: String,
    modifier: Modifier = Modifier,
    value: String? = null,
    valueInk: Color? = null,
    accentTitle: Boolean = false,
    chevron: Boolean = false,
    dividerBelow: Boolean = true,
    subtitle: String? = null,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val clickable = if (onClick != null) {
        Modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
    } else {
        Modifier
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(clickable)
            .semantics(mergeDescendants = true) {},
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight)
                .padding(
                    start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    end = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                ),
            verticalArrangement = Arrangement.Center,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = title,
                    style = settingsLabelStyle().copy(
                        color = when {
                            !enabled -> tokens.colors.textTertiary
                            accentTitle -> tokens.colors.textPrimary
                            else -> settingsLabelInk()
                        },
                    ),
                    modifier = Modifier.weight(1f).then(settingsRowTextLift()),
                )
                if (value != null) {
                    BasicText(
                        text = value,
                        style = settingsValueStyle().copy(color = valueInk ?: settingsValueInk()),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = settingsRowTextLift(),
                    )
                }
                if (trailing != null) {
                    trailing()
                } else if (chevron) {
                    SettingsChevronSlot(withChevron = true)
                }
            }
            if (subtitle != null) {
                BasicText(
                    text = subtitle,
                    style = settingsFootnoteStyle().copy(color = settingsFootnoteInk()),
                )
            }
        }
        if (dividerBelow) {
            SettingsHairline(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = SettingsSeparatorInset),
            )
        }
    }
}

/**
 * One body-copy row inside a card: 17 pt secondary ink, same 52.33 pt pitch.
 *
 * SwiftUI's bare `Text("…")` in a `List` row is `.body` = 17 pt, while
 * `.font(.footnote)` is 13 pt; both appear in the settings sub-pages and they
 * are not interchangeable. `ios-settings-search.png` measures the three
 * under-还要知道 paragraphs at 630.7-647.0 pt and 653.0-669.3 pt (ink 16.7 pt,
 * line pitch 22.3 pt), i.e. the 17 pt role, and measures the explicitly-sized
 * 13 pt lines (现在这个模型服务自带搜索…) at ink 13.0 pt.
 */
@Composable
public fun SettingsBodyRow(
    text: String,
    modifier: Modifier = Modifier,
    dividerBelow: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    Box(modifier = modifier.fillMaxWidth()) {
        BasicText(
            text = text,
            style = settingsLabelStyle().copy(color = tokens.colors.textSecondary),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight)
                .padding(
                    start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    end = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                ),
        )
        if (dividerBelow) {
            SettingsHairline(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = SettingsSeparatorInset),
            )
        }
    }
}

/**
 * One footnote row inside a card: 13 pt secondary ink, same 52.33 pt pitch.
 *
 * @param centre centre the line inside the row. The grouped pages' footnotes are
 *   centred in the baseline (`ios-settings.png` 权限 footnote ink 274.67..286.0 in
 *   a row that spans 254.33..306.67); the default keeps the previous top-aligned
 *   box, which the settings sub-pages' wrapped footnotes rely on (their tests pin
 *   that layout), so the centring is opt-in.
 */
@Composable
public fun SettingsFootnoteRow(
    text: String,
    modifier: Modifier = Modifier,
    dividerBelow: Boolean = false,
    centre: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val body: @Composable () -> Unit = {
        BasicText(
            text = text,
            style = settingsFootnoteStyle().copy(color = settingsFootnoteInk()),
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    end = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                ),
        )
    }
    Box(modifier = modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight),
            contentAlignment = if (centre) Alignment.CenterStart else Alignment.TopStart,
        ) {
            body()
        }
        if (dividerBelow) {
            SettingsHairline(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = SettingsSeparatorInset),
            )
        }
    }
}

/**
 * The sub-pages' section label: 17 pt secondary ink at x 33 pt, optional
 * right-aligned trailing value (the baseline's `15 个地址`).
 *
 * @param trailing an optional right-aligned value in 13 pt secondary ink
 *   (`-network`'s `15 个地址` measures 35 px = 11.7 pt of ink, i.e. 13 pt).
 * @param indent the leading inset; the network page's `地址` sits at 32.7 pt and
 *   the plain-row pages at 33 pt, so the default is the measured 33.
 * @param tag an optional stable test tag.
 */
@Composable
public fun SettingsSectionLabel(
    title: String,
    modifier: Modifier = Modifier,
    trailing: String? = null,
    indent: Dp = SettingsSectionLabelIndent,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .padding(
                start = indent,
                end = tokens.geometry.pageOuterMarginH,
                top = tokens.spacing.cardInset,
                bottom = tokens.spacing.codeToolbar,
            )
            .semantics { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = title,
            style = settingsSectionLabelStyle().copy(color = tokens.colors.textSecondary),
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) {
            BasicText(
                text = trailing,
                style = settingsFootnoteStyle().copy(color = tokens.colors.textSecondary),
            )
        }
    }
}

/**
 * One row of a sub-page's plain list: 52.33 pt, 17 pt label, 17 pt value, an
 * optional chevron slot, and a 1 pt separator below at the measured inset.
 *
 * This is the sub-pages' replacement for `PageScaffold.InfoRow` (14 pt label,
 * 13 pt value, no separator). It takes the same shape so a page swaps the call
 * and nothing else.
 *
 * @param leadingInset the label's leading inset: 17 pt for a plain row
 *   (`-network`), 72 pt for a row with a 33 pt icon column (`-model`).
 * @param dividerLeadingInset the separator's leading inset: 16 pt (`-network`,
 *   `-runtime`), 72 pt (`-model`, `-plugins`), 32 pt (`-search`).
 * @param dividerTrailingInset the separator's trailing inset: 32.33 pt on four
 *   of the six sub-pages, 16 pt on `-runtime`.
 */
@Composable
public fun SettingsFormRow(
    title: String,
    modifier: Modifier = Modifier,
    value: String? = null,
    tone: PageTone = PageTone.NORMAL,
    valueInk: Color? = null,
    accentTitle: Boolean = false,
    chevron: Boolean = false,
    dividerBelow: Boolean = true,
    subtitle: String? = null,
    enabled: Boolean = true,
    leadingInset: Dp = SettingsLargeTitleInset,
    dividerLeadingInset: Dp = SettingsSeparatorInset,
    dividerTrailingInset: Dp = SettingsSubPageSeparatorTrailingInset,
    trailing: (@Composable () -> Unit)? = null,
    subtitleContent: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val clickable = if (onClick != null) {
        Modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
    } else {
        Modifier
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(clickable)
            .semantics(mergeDescendants = true) {},
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight)
                .padding(
                    start = leadingInset,
                    end = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                ),
            verticalArrangement = Arrangement.Center,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = title,
                    style = settingsLabelStyle().copy(
                        color = when {
                            !enabled -> tokens.colors.textTertiary
                            accentTitle -> tokens.colors.textPrimary
                            else -> settingsLabelInk()
                        },
                    ),
                    modifier = Modifier.weight(1f).then(settingsRowTextLift()),
                )
                if (value != null) {
                    BasicText(
                        text = value,
                        style = settingsValueStyle().copy(
                            color = valueInk ?: tone.settingsInk(tokens),
                        ),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = settingsRowTextLift(),
                    )
                }
                if (trailing != null) {
                    trailing()
                } else if (chevron) {
                    SettingsChevronSlot(withChevron = true)
                }
            }
            if (subtitle != null) {
                BasicText(
                    text = subtitle,
                    style = settingsFootnoteStyle().copy(color = settingsFootnoteInk()),
                )
            }
            subtitleContent?.invoke()
        }
        if (dividerBelow) {
            SettingsHairline(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(start = dividerLeadingInset, end = dividerTrailingInset),
            )
        }
    }
}

/** One paragraph of small print on a sub-page: 13 pt secondary ink. */
@Composable
public fun SettingsSubPageFootnote(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = settingsFootnoteStyle().copy(color = settingsFootnoteInk()),
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = SettingsSectionLabelIndent,
                end = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                top = tokens.spacing.codeToolbar,
                bottom = tokens.spacing.codeToolbar,
            ),
    )
}

/**
 * A sub-page's full frame: the 44 pt bar (✕ / ‹ leading, optional centred title,
 * optional trailing action), an optional 34 pt large title, then the scrolling
 * content.
 *
 * Two background modes, both measured:
 *  * [grouped] = `false` — a plain white list. `-model`, `-network`, `-plugins`,
 *    `-runtime`, `-search` all render rows straight on the page background.
 *  * [grouped] = `true` — iOS's inset-grouped list: a grey page with white
 *    cards. `-about` and the general tab are this mode.
 *
 * A third mode came with L75's files/workspace-folders pages: [pageFill] paints the
 * frame with `colors.page` (`NativePagePalette.page`, #FFFFFF light / #000000 dark),
 * which is the fill those two baselines set explicitly with
 * `.background(NativePagePalette.page)` (`FilesPage.swift:55`,
 * `NativeShell.swift:...`). It is not `grouped` (there are no cards) and not the
 * default either (that resolves to `colors.input`, #242426 in dark, i.e. a lighter
 * page than the baseline's black).
 *
 * @param title the inline (centred) title; the six sub-pages set it on the two
 *   that live behind a modal sheet without a large title (`关于`, `网络访问`).
 * @param largeTitle the 34 pt heading drawn in the content instead of the bar.
 * @param pageFill retained compatibility flag; both modes use HomeSpec page fill.
 * @param onBack the leading affordance (the baseline's ✕ on a sheet, ‹ on a
 *   pushed page).
 * @param rootTag an optional stable test tag for the page root.
 * @param showSheetHandle retained compatibility flag: it only selects the ✕'s
 *   spoken label (`取消` on a sheet, `返回` on a pushed page). Page content never
 *   draws a grabber — `interaction.md` §2 rule 4 gives that to the sheet chrome
 *   (`SheetChrome.HomeSheet` / `Connectors`); the settings sub-pages are content
 *   inside that sheet and used to draw a second, non-contract handle here.
 */
@Composable
public fun SettingsSubPageFrame(
    modifier: Modifier = Modifier,
    title: String? = null,
    largeTitle: String? = null,
    onBack: (() -> Unit)? = null,
    backGlyph: String = SETTINGS_CLOSE_GLYPH,
    backTag: String? = null,
    grouped: Boolean = false,
    pageFill: Boolean = false,
    rootTag: String? = null,
    embedded: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    showSheetHandle: Boolean = backGlyph == SETTINGS_CLOSE_GLYPH && onBack != null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    // HomeSpec is the owner of the page behind inset white rows in every
    // appearance. `groupedBackground`/`background` are unresolved system slots.
    val background = tokens.colors.page
    val tagged = if (rootTag != null) modifier.testTag(rootTag) else modifier
    Column(
        modifier = tagged
            .fillMaxSize()
            .background(background)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        // `embedded` = this page is a tab body: the settings shell already drew
        // the 44 pt bar and the segmented picker, so drawing another bar here
        // would stack two. The large title stays — it belongs to the page.
        if (!embedded) {
            SettingsNavBar(
                title = title,
                leading = if (onBack != null) {
                    {
                        SettingsNavAction(
                            text = backGlyph,
                            onClick = onBack,
                            tag = backTag,
                            description = if (showSheetHandle) UiStrings.CANCEL else UiStrings.BACK,
                        )
                    }
                } else {
                    null
                },
                trailing = trailing,
            )
        }
        if (largeTitle != null) {
            BasicText(
                text = largeTitle,
                style = settingsLargeTitleStyle().copy(color = tokens.colors.textPrimary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = SettingsLargeTitleInset,
                        end = tokens.geometry.pageOuterMarginH,
                        top = SettingsLargeTitleTopGap,
                    )
                    .semantics { heading() },
            )
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .navigationBarsPadding(),
        ) {
            content()
        }
    }
}

/**
 * The baseline's ✕ (a sheet's close affordance) drawn as a 22 pt accent ring
 * with a cross, matching `ios-settings-model.png`'s y=187 px control.
 */
@Composable
public fun SettingsCloseGlyph(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    Canvas(modifier = modifier.size(SettingsCloseGlyphSize)) {
        val ink = tokens.colors.textPrimary
        drawCircle(
            color = ink.copy(alpha = SETTINGS_CLOSE_RING_ALPHA),
            radius = size.minDimension / 2f,
        )
        val arm = size.minDimension * SETTINGS_CLOSE_ARM_RATIO
        val center = Offset(size.width / 2f, size.height / 2f)
        val stroke = SettingsCloseArmStroke.toPx()
        drawLine(ink, center - Offset(arm, arm), center + Offset(arm, arm), stroke, StrokeCap.Round)
        drawLine(ink, center - Offset(arm, -arm), center + Offset(-arm, arm), stroke, StrokeCap.Round)
    }
}

/** unverified geometry: the ✕ control's 22 pt ring (`-model` y=176..209 px). */
public val SettingsCloseGlyphSize: Dp = 22.dp
private val SettingsCloseArmStroke: Dp = 2.dp
private const val SETTINGS_CLOSE_RING_ALPHA: Float = 0.12f
private const val SETTINGS_CLOSE_ARM_RATIO: Float = 0.19f

/** The sheet's close glyph. */
public const val SETTINGS_CLOSE_GLYPH: String = "✕"

/**
 * unverified geometry: the 16 x 4 pt three-dot affordance a sub-page row can carry
 * (the network page's delete control). iOS's network page has no such control —
 * deletion lives in its own actions — so the size is this app's; it is a *shape*
 * rather than a text glyph because a text glyph contributes its font's line box
 * and pushed the measured 52.33 pt row to 58.3 pt.
 */
public val SettingsDotsWidth: Dp = 16.dp
public val SettingsDotsHeight: Dp = 4.dp

/**
 * A glass capsule action (`-plugins`'s 插件说明 / 刷新 / 添加插件): a 40 pt tall
 * pill on the selector ink with an optional leading glyph.
 *
 * unverified geometry: the shots put the pills at y=626..716 px = 30 pt tall and
 * 16 pt apart, so the pill is 30 pt with `spacing.iconText` between them.
 */
@Composable
public fun SettingsGlassPill(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    glyph: String? = null,
    enabled: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .heightIn(min = SETTINGS_PILL_HEIGHT)
            .clip(RoundedCornerShape(SETTINGS_PILL_HEIGHT / 2))
            .background(tokens.colors.selector)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = tokens.spacing.cardInset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        if (glyph != null) {
            BasicText(text = glyph, style = settingsLabelStyle().copy(color = tokens.colors.textPrimary))
        }
        BasicText(
            text = label,
            style = settingsLabelStyle().copy(color = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary),
        )
    }
}

/** unverified geometry: `-plugins` pill height y=626..716 px = 30 pt. */
private val SETTINGS_PILL_HEIGHT: Dp = 30.dp

/**
 * The baseline's 34 pt large title, drawn as a block.
 *
 * See [settingsLargeTitleStyle] for the missing `typography.largeTitle` token.
 * @param text the page's title, fixed copy owned by the page.
 */
@Composable
public fun SettingsLargeTitle(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = settingsLargeTitleStyle().copy(color = tokens.colors.textPrimary),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = SettingsLargeTitleInset,
                end = tokens.geometry.pageOuterMarginH,
                top = SettingsLargeTitleTopGap,
            )
            .semantics { heading() },
    )
}

/**
 * One 52.33 pt row of the card list, as a bare row (no card, no separator).
 *
 * Kept for callers that lay a row out outside [SettingsGroupCard]; the general
 * tab uses [SettingsGroupedRow].
 *
 * @param trailingInset the row's trailing inset inside the card. The baseline
 *   puts a row's *value* 39.33 pt from the card edge (that slot holds the
 *   20.67 pt chevron column) but puts the *switch* 14 pt from it
 *   (`SettingsMetrics.SWITCH_TRAILING_INSET_PT`; `ios-settings.png` switch right
 *   edge x=1115 px, card right edge 1157 px). A caller whose last child is not
 *   text must say so, or the control inherits the text slot.
 */
@Composable
public fun SettingsRowFrame(
    dividerBelow: Boolean = true,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    role: Role = Role.Button,
    onClick: (() -> Unit)? = null,
    stateValue: String? = null,
    trailingInset: Dp = SettingsValueTrailingInset,
    content: @Composable RowScope.() -> Unit,
) {
    val tokens = LocalUiTokens.current
    val clickable = if (onClick != null) {
        Modifier.clickable(enabled = enabled, role = role, onClick = onClick)
    } else {
        Modifier
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(clickable)
            .semantics(mergeDescendants = true) {
                if (stateValue != null) stateDescription = stateValue
            },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SettingsGroupedRowHeight)
                .padding(
                    start = SettingsMetrics.ROW_CONTENT_INSET_PT.dp,
                    end = trailingInset,
                    top = tokens.spacing.iconText,
                    bottom = tokens.spacing.iconText,
                ),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
        if (dividerBelow) {
            SettingsHairline(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = SettingsSeparatorInset),
            )
        }
    }
}

/** The baseline's row label (17 pt regular); the caller supplies the colour. */
@Composable
public fun SettingsRowLabel(text: String, enabled: Boolean = true, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = settingsLabelStyle().copy(
            color = if (enabled) settingsLabelInk() else tokens.colors.textTertiary,
        ),
        modifier = modifier.then(settingsRowTextLift()),
    )
}

/** The baseline's row value (17 pt regular), end-aligned inside its slot. */
@Composable
public fun SettingsRowValue(
    text: String,
    modifier: Modifier = Modifier,
    ink: Color? = null,
    style: TextStyle? = null,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = (style ?: settingsValueStyle()).copy(color = ink ?: settingsValueInk()),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier.then(settingsRowTextLift()),
    )
}

/**
 * The baseline's trailing 20.67 pt slot: the chevron when the row opens
 * something, empty otherwise. Reserving it on every row is what puts all values'
 * right edge on one line, matching the measured value/chevron edges.
 */
@Composable
public fun SettingsChevronSlot(withChevron: Boolean) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier.width(SettingsChevronSlotWidth),
        contentAlignment = Alignment.CenterEnd,
    ) {
        if (withChevron) {
            val ink = chevronInk
            Canvas(
                modifier = Modifier
                    .padding(end = tokens.spacing.copyGap)
                    .size(width = ChevronWidth, height = ChevronHeight),
            ) {
                drawLine(
                    color = ink,
                    start = Offset(0f, 0f),
                    end = Offset(size.width, size.height / 2f),
                    strokeWidth = ChevronStroke.toPx(),
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = ink,
                    start = Offset(size.width, size.height / 2f),
                    end = Offset(0f, size.height),
                    strokeWidth = ChevronStroke.toPx(),
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}

private val chevronInk: Color
    @Composable get() = LocalUiTokens.current.colors.caption

/**
 * The same slot, hosting a different glyph (a menu row's
 * `chevron.up.chevron.down`). Reserving the slot keeps a row with a custom
 * trailing glyph aligned with the rows above it.
 */
@Composable
public fun SettingsTrailingSlot(
    width: Dp = SettingsChevronSlotWidth,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier.width(width),
        contentAlignment = Alignment.CenterEnd,
    ) {
        content()
    }
}

/** The menu row's `chevron.up.chevron.down` (16 pt in the baseline). */
@Composable
public fun SettingsMenuChevron(ink: Color) {
    Canvas(modifier = Modifier.size(width = MenuChevronWidth, height = MenuChevronHeight)) {
        val stroke = MenuChevronStroke.toPx()
        val upperEnds = size.height * 0.375f
        val upperApex = size.height * 0.0625f
        val lowerEnds = size.height * 0.625f
        val lowerApex = size.height * 0.9375f
        drawLine(ink, Offset(0f, upperEnds), Offset(size.width / 2f, upperApex), stroke, StrokeCap.Round)
        drawLine(ink, Offset(size.width / 2f, upperApex), Offset(size.width, upperEnds), stroke, StrokeCap.Round)
        drawLine(ink, Offset(0f, lowerEnds), Offset(size.width / 2f, lowerApex), stroke, StrokeCap.Round)
        drawLine(ink, Offset(size.width / 2f, lowerApex), Offset(size.width, lowerEnds), stroke, StrokeCap.Round)
    }
}

/** HomeSpec list separator, using the reviewed border-list color role. */
@Composable
public fun SettingsHairline(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(SettingsSeparatorThickness)
            .background(tokens.colors.borderList),
    )
}

/**
 * The baseline's 63 x 29.67 pt switch.
 *
 * Drawn rather than delegated to Material's `Switch`: that control is 52 x 32 dp
 * with a 20 dp thumb and a Material thumb halo, which is a different shape at
 * the same place. The row owns the tap target, so this draws only the control.
 *
 * @param checked the position the host reported.
 * @param enabled `false` dims the track.
 */
@Composable
public fun SettingsSwitch(checked: Boolean, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val tokens = LocalUiTokens.current
    val track = when {
        !enabled -> tokens.colors.borderList
        // iOS draws its default `systemGreen` on-tint here: the baseline's
        // Toggle has no `.tint()`, so the theme accent was never involved.
        // Nearest reviewed HomeSpec green. The current Android theme does not
        // resolve UIKit's adaptive `systemGreen` value.
        checked -> tokens.colors.homeSuccess
        else -> tokens.colors.borderList
    }
    Canvas(modifier = modifier.size(width = SettingsSwitchWidth, height = SettingsSwitchHeight)) {
        val radius = SettingsSwitchTrackRadius.toPx().coerceAtMost(size.height / 2f)
        drawRoundRect(
            color = track,
            cornerRadius = CornerRadius(radius, radius),
        )
        val thumbRadius = SettingsSwitchThumb.toPx() / 2f
        val inset = (size.height - SettingsSwitchThumb.toPx()) / 2f
        val x = if (checked) {
            size.width - inset - thumbRadius
        } else {
            inset + thumbRadius
        }
        drawCircle(color = Color.White, radius = thumbRadius, center = Offset(x, size.height / 2f))
    }
}

/** The 44 pt bar's leading glyph on a pushed page (the baseline's `‹`). */
public const val BACK_GLYPH: String = "‹"

/**
 * The sub-pages' foldable group header: a 17 pt secondary label at the measured
 * 33 pt indent, the disclosure chevron, the row count, and a 44 pt floor.
 *
 * The baseline's six sub-pages do not fold; Android's pages do, because the fold
 * is a ScreenState event those pages already own (§3.1). Keeping the fold and
 * restyling the header is the honest mirror: the label, its ink, its indent and
 * the row pitch match, the affordance stays.
 *
 * @param trailing an optional right-aligned count, read from the state.
 * @param tag an optional stable test tag.
 */
@Composable
public fun SettingsSectionHeader(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: String? = null,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = SettingsGroupedRowHeight)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .clickable(role = Role.Button, onClick = onToggle)
            .semantics(mergeDescendants = true) {
                stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                contentDescription = "$title · ${if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED}"
            }
            .padding(
                start = SettingsSectionLabelIndent,
                end = tokens.geometry.pageOuterMarginH,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        PdshChevron(
            expanded = expanded,
            tint = tokens.colors.textTertiary,
            tag = tag?.let { PdshDisclosureTags.chevron(it) },
        )
        BasicText(
            text = title,
            style = settingsSectionLabelStyle().copy(color = tokens.colors.textSecondary),
            modifier = Modifier
                .weight(1f)
                .semantics { heading() },
        )
        if (trailing != null) {
            BasicText(
                text = trailing,
                style = settingsFootnoteStyle().copy(color = tokens.colors.textSecondary),
            )
        }
    }
}


/**
 * The ink for a row value: secondary for a plain value, a tone for a fact.
 *
 * Lives here (not in the page) because the row primitive needs it; the page only
 * passes the tone.
 */
@Composable
public fun PageTone.settingsInk(tokens: com.phonedsh.ui.theme.UiTokens): Color = when (this) {
    PageTone.NORMAL -> tokens.colors.textSecondary
    PageTone.ON -> tokens.colors.homeSuccess
    PageTone.DEGRADED -> tokens.colors.pageWarning
    PageTone.UNKNOWN -> tokens.colors.textSecondary
}
