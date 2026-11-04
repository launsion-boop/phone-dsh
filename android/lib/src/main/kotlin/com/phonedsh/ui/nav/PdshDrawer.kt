// The shell's drawer: the one map of the app a user can actually tap.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1's 入口 column. On the iOS baseline the drawer
// is the session list with two furniture rows at the bottom
// (`NativeShell.swift:276`–`:316`: `SessionsDrawer` = `SessionsPage` +
// 定时任务 + 设置). That shape is the baseline, so it is this file's default:
//
//     [ 会话列表（主体，占满剩余高度） ]
//     ──────────────────────────────  Divider
//     定时任务
//     设置
//
// The [body] slot is that session list. A host with no session-list body of its
// own (a demo that only routes pages) passes [entries] instead and gets a plain
// navigation list; the two shapes are exclusive and the `require` below keeps a
// caller from drawing half of each.
//
// Geometry is the iOS drawer's, not an Android invention:
//
//   * panel 320 pt (`NativeShell.swift:97` `private let width: CGFloat = 320`);
//   * row content 288 pt = 320 - 16 - 16: the drawer row insets 16 on both sides
//     (`NativeShell.swift:41` `horizontalInset` / `:432`; the 288 is written out
//     at `SessionsPage.swift:593`);
//   * furniture row 48 pt tall (`NativeShell.swift:433`) and a 22 pt icon slot
//     (`:422`);
//   * icon/title gap 10 pt (`:419`), chevron reference 12 pt (`:428`–`:429`).
//
// Legacy geometry is frozen in [LegacyDrawerMetrics]; the PR22 product drawer uses HomeDrawer.
// This compatibility file carries no second
// copy of them. The only unmeasured value is the 22 pt corner on the panel's
// trailing edge (`NativeShell.swift:254`): the token table publishes no
// drawer-radius token, so the literal is marked here.
//
// The drawer is shell wiring, not a page: it takes labelled [PdshDrawerEntry]
// values and hands the selected route back. It never reads the engine, a clock
// or the filesystem, so a JVM test can tap every row and assert the route.

package com.phonedsh.ui.nav

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/**
 * One row's glyph.
 *
 * The baseline uses SF Symbols (`clock`, `gearshape`); the shared registry maps
 * them to vector paths in the same 22 x 22 box. The shape names the destination,
 * never states.
 */
public enum class PdshDrawerIcon {
    /** 对话: a chat bubble. */
    CHAT,

    /** 会话: a list of sessions. */
    SESSIONS,

    /** 工作文件夹: a folder. */
    FOLDER,

    /** 命令: a terminal window. */
    TERMINAL,

    /** 设备连接: a device. */
    DEVICE,

    /** DSH 页面: a globe. */
    WEB,

    /** 定时任务: a clock. */
    CLOCK,

    /** 设置: a gear. */
    SETTINGS,
}

/**
 * One tappable drawer row.
 *
 * @param label the visible text; it is also the row's accessibility name.
 * @param icon the glyph in the 22 pt slot.
 * @param route the route the row pushes.
 */
public data class PdshDrawerEntry(
    public val label: String,
    public val icon: PdshDrawerIcon,
    public val route: PdshRoute,
)

/** Stable test tags, so a reachability test names the row it taps. */
public object PdshDrawerTags {
    /** The whole drawer overlay (panel + scrim strip). */
    public const val ROOT: String = "pdsh.drawer"

    /** The 320 pt panel itself. */
    public const val PANEL: String = "pdsh.drawer.panel"

    /** The dimmed page strip on the right; tapping it closes the drawer. */
    public const val SCRIM: String = "pdsh.drawer.scrim"

    /** One row, suffixed with the row's label. */
    public const val ROW_PREFIX: String = "pdsh.drawer.row."

    /** One glyph slot, suffixed with the row's label. */
    public const val ICON_PREFIX: String = "pdsh.drawer.icon."
}

/**
 * The drawer overlay.
 *
 * @param entries the app-map rows, top to bottom; empty when [body] supplies the
 *   drawer's own content (the baseline shape).
 * @param footerEntries the furniture rows pinned to the bottom (定时任务, 设置
 *   in the baseline); an empty list drops the divider and the bottom group.
 * @param onSelect the route whose row was tapped.
 * @param onDismiss close without navigating (the scrim strip).
 * @param body the session list, filling the panel above the divider exactly like
 *   `SessionsPage` does inside `SessionsDrawer` (`NativeShell.swift:288`). The
 *   shell's safe-drawing insets are already consumed by the panel, so the page
 *   must not add them a second time — a `windowInsetsPadding` on this panel
 *   consumes what it applies.
 */
@Composable
public fun PdshDrawer(
    entries: List<PdshDrawerEntry>,
    footerEntries: List<PdshDrawerEntry>,
    onSelect: (PdshRoute) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    body: (@Composable () -> Unit)? = null,
) {
    require(body == null || entries.isEmpty()) {
        "the drawer is either the app-map list or the session-list body, never both"
    }
    val tokens = LocalUiTokens.current
    BoxWithConstraints(modifier = modifier.fillMaxSize().testTag(PdshDrawerTags.ROOT)) {
        // iOS is 320 on every phone it ships on; a narrower window (a split
        // screen, a small device) keeps a strip of the page visible instead of
        // letting the drawer cover the whole frame.
        val panelWidth: Dp = minOf(LegacyDrawerMetrics.drawerWidth, maxWidth - MIN_PAGE_STRIP)
        Row(Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .width(panelWidth)
                    .fillMaxHeight()
                    // The baseline rounds the two trailing corners 22 pt. The
                    // background shape draws that edge; the panel is not
                    // `clip`ped, because a rounded clip layer swallows injected
                    // touches in the JVM renderer and the rows must stay tappable
                    // in the tests that prove this drawer's reachability.
                    .background(tokens.colors.input, DRAWER_PANEL_SHAPE)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .testTag(PdshDrawerTags.PANEL),
            ) {
                if (body != null) {
                    // The baseline's drawer body starts at the safe-area top and
                    // owns every point down to the divider; the rows below it are
                    // the app's furniture, not a list item.
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            // The body is a page laid out for a 320 panel; on a
                            // narrower window its fixed 320 column must not bleed
                            // over the scrim strip.
                            .clipToBounds(),
                    ) {
                        body()
                    }
                } else {
                    Spacer(Modifier.height(PANEL_TOP_INSET))
                    entries.forEach { entry ->
                        PdshDrawerRow(entry = entry, onClick = { onSelect(entry.route) })
                    }
                    Spacer(Modifier.weight(1f))
                }
                if (footerEntries.isNotEmpty()) {
                    DrawerDivider()
                    footerEntries.forEach { entry ->
                        PdshDrawerRow(entry = entry, onClick = { onSelect(entry.route) })
                    }
                    Spacer(Modifier.height(PANEL_BOTTOM_INSET))
                }
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    // unverified token: no scrim-opacity token exists; the page
                    // ink at a fixed opacity is the only non-invented dimming
                    // the token table has (the same choice the sheet frame makes).
                    .background(tokens.colors.primary.copy(alpha = SCRIM_ALPHA))
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .semantics { contentDescription = DISMISS_LABEL }
                    .testTag(PdshDrawerTags.SCRIM),
            )
        }
    }
}

/** One 48 pt row: 22 pt glyph, 10 pt gap, title, 12 pt chevron. */
@Composable
private fun PdshDrawerRow(entry: PdshDrawerEntry, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(LegacyDrawerMetrics.drawerRowHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = entry.label }
            .testTag(PdshDrawerTags.ROW_PREFIX + entry.label)
            // 320 - 16 - 16 = 288: the measured drawer content width.
            .padding(horizontal = LegacyDrawerMetrics.rowInset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(LegacyDrawerMetrics.drawerRowSpacing),
    ) {
        DrawerGlyph(
            icon = entry.icon,
            color = tokens.colors.primary,
            modifier = Modifier.testTag(PdshDrawerTags.ICON_PREFIX + entry.label),
        )
        BasicText(
            text = entry.label,
            // iOS draws this row at 17 pt regular; the token table's closest
            // regular style is subheadline (15 pt). The row height, not the text
            // size, is the measured number this lane aligns.
            style = type.subheadline.copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        DrawerChevron(color = tokens.colors.tertiary)
    }
}

/** The 22 pt glyph slot delegates to the shared, source-backed registry. */
@Composable
private fun DrawerGlyph(icon: PdshDrawerIcon, color: Color, modifier: Modifier = Modifier) {
    val registered = when (icon) {
        PdshDrawerIcon.CHAT -> PdshIcon.CHAT_BUBBLE
        PdshDrawerIcon.SESSIONS -> PdshIcon.SESSIONS
        PdshDrawerIcon.FOLDER -> PdshIcon.FOLDER
        PdshDrawerIcon.TERMINAL -> PdshIcon.TERMINAL
        PdshDrawerIcon.DEVICE -> PdshIcon.DEVICE
        PdshDrawerIcon.WEB -> PdshIcon.GLOBE
        PdshDrawerIcon.CLOCK -> PdshIcon.CLOCK
        PdshDrawerIcon.SETTINGS -> PdshIcon.GEAR
    }
    PdshIconView(
        icon = registered,
        size = LegacyDrawerMetrics.drawerRowIconSlot,
        tint = color,
        contentDescription = null,
        modifier = modifier,
    )
}

/** The 12 pt chevron at the row's trailing edge (`NativeShell.swift:428`). */
@Composable
private fun DrawerChevron(color: Color) {
    Canvas(Modifier.size(LegacyDrawerMetrics.drawerRowChevron)) {
        val unit = size.minDimension / 12f
        val path = Path().apply {
            moveTo(4.5f * unit, 2.5f * unit)
            lineTo(8f * unit, 6f * unit)
            lineTo(4.5f * unit, 9.5f * unit)
        }
        drawPath(
            path = path,
            color = color,
            style = Stroke(width = 1.5f * unit, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

/** The hairline above the furniture group (`NativeShell.swift:293` Divider). */
@Composable
private fun DrawerDivider() {
    val tokens = LocalUiTokens.current
    Box(
        Modifier
            .fillMaxWidth()
            .height(LegacyDrawerMetrics.separatorHeight)
            .background(tokens.colors.borderLight),
    )
}

/** How far left of a narrow window the drawer's page strip starts. */
private val MIN_PAGE_STRIP: Dp = 40.dp

/** unverified geometry: no drawer-radius token; the baseline rounds 22 pt on the right (`NativeShell.swift:254`). */
private val DRAWER_PANEL_SHAPE = RoundedCornerShape(topEnd = 22.dp, bottomEnd = 22.dp)

/** iOS's panel starts just under the safe-area top; 8 pt keeps the first row off the bar. */
private val PANEL_TOP_INSET: Dp = 8.dp

/** iOS pads the bottom furniture group by `bottomInset + 16` (`NativeShell.swift:306`). */
private val PANEL_BOTTOM_INSET: Dp = 16.dp

/** unverified token: no scrim-opacity token exists; the sheet frame uses the same value. */
private const val SCRIM_ALPHA: Float = 0.32f

/** The scrim strip's spoken name. */
private const val DISMISS_LABEL: String = "关闭抽屉"

/**
 * Frozen geometry of the public pre-PR22 app-map drawer (PR14 8c2eeab7).
 * The product root now uses HomeDrawer. Sharing SessionsMetrics would silently
 * resize this compatibility API whenever the live session page changes.
 */
internal object LegacyDrawerMetrics {
    const val DRAWER_WIDTH_PT: Int = 320
    const val DRAWER_CONTENT_WIDTH_PT: Int = 288
    const val ROW_INSET_PT: Int = 16
    val drawerWidth: Dp get() = DRAWER_WIDTH_PT.dp
    val rowInset: Dp get() = ROW_INSET_PT.dp
    val drawerRowHeight: Dp get() = 48.dp
    val drawerRowSpacing: Dp get() = 10.dp
    val drawerRowIconSlot: Dp get() = 22.dp
    val drawerRowChevron: Dp get() = 12.dp
    val separatorHeight: Dp get() = 0.5.dp
}
