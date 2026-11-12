// Shared chrome and vocabulary for the settings/tools/files/memory/about pages.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (the page list) and §5 rows `insets` and
// `back-gesture`. None of these pages is one of the six signature surfaces
// (§4), so they are accepted semantically: the ScreenState sequence and the
// visible copy, never a screenshot.
//
// Insets: targetSdk 35 forces edge-to-edge. This frame consumes the status bar
// above the header, the navigation bar below the content, and the horizontal
// insets on the root; a page never draws under a system bar.
//
// Geometry: `spec/ui/v1/tokens.json` declares the page-level tokens this frame
// reads (`geometry.pageOuterMarginH`, `geometry.pageHeaderMinHeight`,
// `geometry.pageRowMinHeight`, `geometry.pageListRowMinHeight`). The chevron gap
// and the list gap still reuse the tool row's `disclosureIconGap`, and each such
// reuse is marked `unverified geometry` at its call site. Nothing here invents a
// dp value.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/**
 * A platform fact the page either read (`YES`/`NO`) or could not read
 * (`UNKNOWN`).
 *
 * There is deliberately no default-to-`NO`: "we could not read it" and "it is
 * off" are different statements, and the UI must say which one it knows. See
 * `spec/ui/v1/README.md` §5 (the platform-divergence rows this page reports).
 */
public enum class FactState {
    YES,
    NO,
    UNKNOWN,
}

/** How a value is inked; never a second source of colour, only a token choice. */
public enum class PageTone {
    /** A plain measured value. */
    NORMAL,

    /** A fact that is on / available. */
    ON,

    /** A fact that is off in a way the user should notice (降级 / 未豁免). */
    DEGRADED,

    /** A fact or value that could not be read. */
    UNKNOWN,
}

/** One line above a page's content that reports a degraded platform fact. */
public data class PageNote(
    public val id: String,
    public val text: String,
    public val tone: PageTone = PageTone.DEGRADED,
)

/**
 * Which groups the user collapsed.
 *
 * Pure data: the fold lives in ScreenState (§3.1 — a fold is not an event-
 * anchored node), so the same `(facts, fold script)` always renders the same
 * group sequence and a JVM test can replay it.
 */
public data class FoldState(public val collapsedIds: Set<String> = emptySet()) {
    /** A group id is expanded until the user collapses it. */
    public fun isExpanded(id: String): Boolean = id !in collapsedIds

    /** Flips one group; the only local event the collapsible sections have. */
    public fun toggle(id: String): FoldState = copy(
        collapsedIds = if (id in collapsedIds) collapsedIds - id else collapsedIds + id,
    )
}

/**
 * The frame every non-chat page hangs off.
 *
 * @param title the page title (a heading).
 * @param onBack the page back action; `null` on a root page.
 * @param subtitle a one-line location (the files page's current directory).
 * @param rootTag an optional stable test tag for the page root.
 * @param actions trailing header actions (for example the files page's import).
 * @param content the page body; it is placed in the remaining height above the
 *   navigation bar.
 *
 * Geometry: the header floor and the page margin are page-level tokens
 * (`geometry.pageHeaderMinHeight`, `geometry.pageOuterMarginH`), not a reuse of
 * a signature surface's sizes.
 */
@Composable
internal fun PageFrame(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    subtitle: String? = null,
    rootTag: String? = null,
    actions: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    // PR22 secondary pages inherit HomeSpec.page; the old dynamic background
    // slot is unresolved on Android and is not the current iOS owner.
    val tagged = if (rootTag != null) modifier.testTag(rootTag) else modifier

    Column(
        modifier = tagged
            .fillMaxSize()
            .background(tokens.colors.page)
            // Edge-to-edge: the horizontal system bars are page-wide; the vertical
            // ones are consumed by the header and by the content box below.
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = tokens.geometry.pageHeaderMinHeight)
                    .semantics(mergeDescendants = true) {},
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                BasicText(
                    text = title,
                    style = LocalUiType.current.pageTitle.copy(color = tokens.colors.textPrimary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() },
                )
                if (subtitle != null) {
                    BasicText(
                        text = subtitle,
                    style = LocalUiType.current.navSubtitle.copy(color = tokens.colors.textSubtle),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (onBack != null) {
                    BasicText(
                        text = PAGE_BACK_GLYPH,
                        style = LocalUiType.current.pageTitle.copy(color = tokens.colors.textPrimary),
                        modifier = Modifier
                            .clickable(role = Role.Button, onClick = onBack)
                            .semantics { contentDescription = UiStrings.BACK }
                            .padding(tokens.spacing.iconText),
                    )
                }
                Spacer(Modifier.weight(1f))
                actions?.invoke()
            }
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                // The last row can always scroll clear of the navigation bar.
                .navigationBarsPadding(),
        ) {
            content()
        }
    }
}

/**
 * A collapsible group header: the one local event the settings, memory and about
 * pages own.
 *
 * R4 of `PC-20261112-ui-round3` leaves this row's hand-built semantics in place:
 * it is a plain `Row` around [PdshChevron], not a `PdshDisclosure` call, so it
 * cannot inherit the component's default expanded/collapsed announcement and
 * keeps supplying `stateDescription` (and its copy) itself.
 *
 * @param title the group's title.
 * @param expanded whether the rows below are visible.
 * @param onToggle flip the fold.
 * @param trailing an optional count, read from the state (never invented).
 * @param tag an optional stable test tag.
 * @param onChevronRotationChanged an optional observer of the chevron's animated
 *   degrees; the header itself never depends on it. It is the same seam
 *   [PdshChevron] offers and exists so a host (or a JVM test) can synchronize a
 *   second mark without reading layout internals.
 */
@Composable
internal fun SectionHeader(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: String? = null,
    tag: String? = null,
    onChevronRotationChanged: ((Float) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val state = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
    Row(
        modifier = modifier
            .fillMaxWidth()
            // Page-level geometry: a collapsible group header is a compact list row.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .clip(RoundedCornerShape(tokens.radius.codeBlock))
            .clickable(
                role = Role.Button,
                onClickLabel = if (expanded) UiStrings.COLLAPSED else UiStrings.EXPANDED,
                onClick = onToggle,
            )
            .semantics(mergeDescendants = true) {
                stateDescription = state
                contentDescription = "$title · $state"
            }
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        // unverified geometry: reuse of the disclosure icon gap as the chevron gap.
        horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
    ) {
        // interaction.md §7 rule 3: the disclosure chevron uses motion.chevron
        // (120 ms easeInOut). It rotates in place, so the row keeps its height.
        PdshChevron(
            expanded = expanded,
            tint = tokens.colors.textTertiary,
            onRotationChanged = onChevronRotationChanged,
        )
        BasicText(
            text = title,
            style = type.secondary.copy(color = tokens.colors.textSecondary),
            modifier = Modifier
                .weight(1f)
                .semantics { heading() },
        )
        if (trailing != null) {
            BasicText(
                text = trailing,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
        }
    }
}

/**
 * One label/value row. A `null` [value] means the row has no trailing value; a
 * page that could not read a fact passes [UiStrings.UNKNOWN] instead, so "no
 * value" and "unreadable value" never look the same.
 *
 * @param title the row label.
 * @param value the trailing value; `null` for a navigation-only row.
 * @param tone the value's ink.
 * @param subtitle an optional explanatory second line.
 * @param enabled `false` dims the row and removes its click.
 * @param onClick a navigation action; `null` makes the row read-only.
 */
@Composable
internal fun InfoRow(
    title: String,
    value: String?,
    modifier: Modifier = Modifier,
    tone: PageTone = PageTone.NORMAL,
    subtitle: String? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (onClick != null) {
                    Modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                } else {
                    Modifier
                },
            )
            // Page-level geometry: a settings row is a page row and uses the page
            // margin; its floor is the page's own row minimum, not a button size.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = title,
                style = type.homeBody.copy(
                    color = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary,
                ),
                modifier = Modifier.weight(1f),
            )
            if (value != null) {
                BasicText(
                    text = value,
                    style = type.homeBody.copy(color = tone.ink(tokens)),
                )
            }
        }
        if (subtitle != null) {
            BasicText(
                text = subtitle,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
        }
    }
}

/**
 * The vertical gap between rows on the non-chat pages.
 *
 * unverified geometry: the spec declares no page-level list spacing, so the
 * tool row's `geometry.disclosureIconGap` is reused as the gap between page rows.
 */
internal val pageListGap: androidx.compose.ui.unit.Dp
    @Composable @androidx.compose.runtime.ReadOnlyComposable
    get() = LocalUiTokens.current.geometry.disclosureIconGap

/** A centered empty/waiting hint; the page root tag carries the a11y description. */
@Composable
internal fun EmptyHint(
    title: String,
    hint: String?,
    tag: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag(tag)
            .semantics(mergeDescendants = true) {
                contentDescription = listOfNotNull(title, hint).joinToString(". ")
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(text = title, style = type.homeBody.copy(color = tokens.colors.textPrimary))
            if (hint != null) {
                BasicText(text = hint, style = type.secondary.copy(color = tokens.colors.textSecondary))
            }
        }
    }
}

/** The ink for a tone; every branch is a token, never a literal colour. */
internal fun PageTone.ink(tokens: com.phonedsh.ui.theme.UiTokens): androidx.compose.ui.graphics.Color =
    when (this) {
        PageTone.NORMAL -> tokens.colors.textSecondary
        PageTone.ON -> tokens.colors.homeSuccess
        PageTone.DEGRADED -> tokens.colors.pageWarning
        PageTone.UNKNOWN -> tokens.colors.textSecondary
    }

/**
 * Formats a byte count for display, in binary units (`KiB`/`MiB`/`GiB`/`TiB`).
 *
 * `spec/v1/budgets.md` §4 fixes the base: "`MB`/`MiB` are 1 048 576 bytes", so a
 * budget number is a binary quantity. The UI prints `KiB`/`MiB` anyway, because a
 * reader who sees `MB` would assume the decimal base — the label has to match the
 * base the number was computed with, or the screen states a value it does not
 * mean.
 *
 * Pure and locale-free on purpose: the number is a measured value, so the
 * rendering must be identical on every host (a locale-formatted string would
 * vary the decimal separator and therefore the snapshot a test compares).
 * Callers pass [UiStrings.UNKNOWN] when the count itself is unmeasured.
 *
 * A *file size* is not a budget: the files page and the shell page's caps render
 * one with [formatFileSize] (decimal `KB`/`MB`, Foundation's `.file` style), so
 * the same file reads the same on both phones. This function stays binary and is
 * never the one a file row calls. Seeing both unit systems on one device is
 * deliberate; a page that mixes them is a bug.
 */
public fun formatByteSize(bytes: Long): String {
    require(bytes >= 0) { "a byte count is never negative" }
    if (bytes < KIB) return "$bytes B"
    var divisor = KIB
    var unit = 1
    while (bytes / divisor >= KIB && unit < SIZE_UNITS.lastIndex) {
        divisor *= KIB
        unit += 1
    }
    val whole = bytes / divisor
    val tenth = (bytes % divisor) * 10 / divisor
    return "$whole.$tenth ${SIZE_UNITS[unit]}"
}

/** The back affordance; the same glyph the chat page uses. */
internal const val PAGE_BACK_GLYPH: String = "‹"

private const val KIB: Long = 1024
private val SIZE_UNITS: List<String> = listOf("B", "KiB", "MiB", "GiB", "TiB")
