// The page family's iOS 26 bar affordances: the floating white capsule and the cube.
// SPDX-License-Identifier: MIT
//
// Why this file exists next to `SettingsChrome.kt`: that file's `SettingsNavAction`
// is the *text* bar action the settings sheet's close/back slots use. The pages this
// lane owns (`FilesPage`, `WorkspaceFoldersPage`) draw the other iOS 26 bar shape
// instead — a **white capsule with a shadow** floating over the page — which is a
// different control, so it lands here once rather than twice in the two pages.
//
// ## What the baseline actually is
//
// Both pills are `ToolbarItem` content; on iOS 26 a plain bar button gets the
// system's floating background. On a white page a white pill is visible only
// through its shadow, so the *measurement* is the halo, not the fill:
//
//   ios-workspace-folders.png  钮+阴影 x 302.67–393.0, y 66.67–123.0
//                              添加 墨迹 x 336.67–367.67, y 77.0–91.67 (#2F5BFF)
//   ios-files.png              钮+阴影 x 333.33–393.0, y 63.33–119.67
//                              cube 墨迹 x 353.0–374.33, y 72.33–96.33 (#1A1919)
//
// The halo is 6.33 pt on each side in both shots, which resolves the pill to
// ~44 pt tall (== `geometry.pageHeaderMinHeight`, the bar's own hit-area floor) and
// its text inset to `geometry.pageBarButtonInsetH`. The two inks differ and are
// measured, not assumed: 添加 is the page accent (`colors.pageAccent`, #2F5BFF) and
// the cube is the system label ink (`colors.systemLabel`, #1A1919 ≈ #000000) — the
// glyph is **not** tinted like the text button.
//
// ## Why the metrics are parameters
//
// `PageGeometryTokenTest` requires every page-layer length to be read by at least
// two pages, and it looks for the read in `ui/page/*.kt`. So the two pages read
// `geometry.pageBarButtonInsetH` / `geometry.pageBarButtonElevation` from their own
// theme snapshot and hand them in; this composable owns the *shape*, the pages own
// the tokens. That keeps one implementation and one honest owner per length.
//
// Token discipline: the only literals here are the capsule's 50 % corner and the
// cube's shape ratios (a glyph is geometry, not a value source). No `N.dp`, no
// `N.sp`, no colour constructor.
package com.phonedsh.ui.surface

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.press.primaryPressed
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.LocalUiTokens
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * One floating bar button: the white pill with its shadow, a label or a glyph.
 *
 * The pill is `geometry.pageHeaderMinHeight` tall and as wide as its content plus
 * [insetH] on each side, which is how the baseline's two shots resolve (a 34 pt
 * 添加 box inside a 77.7 pt pill).
 *
 * [description] comes first and is the control's **name**, not merely a spoken
 * duplicate: the baseline's two bar items are `Label("3D 示例", systemImage: "cube")`
 * and `Button("添加")` — the first one draws its icon and keeps its title for
 * accessibility, the second draws the title. One string therefore carries both
 * cases, and [showsLabel] decides whether it is painted. Declaring it as the first
 * parameter is also what makes `page_structure_check` see the call site as the
 * labelled action it is: the alternative (a text verb drawn *next to* the cube)
 * would put a label on screen that the baseline does not have.
 *
 * @param description the control's name (`Label`'s title / `Button`'s title).
 * @param onClick the button's action.
 * @param insetH the pill's text inset (the page passes
 *   `tokens.geometry.pageBarButtonInsetH`).
 * @param elevation the pill's shadow height (the page passes
 *   `tokens.geometry.pageBarButtonElevation`; unmeasured, see `tokens.json`).
 * @param modifier the caller's placement.
 * @param showsLabel paint [description] as the visible verb; `false` is the
 *   icon-only bar item (`ios-files.png`).
 * @param glyph an optional drawn glyph (the files page's cube).
 * @param enabled `false` dims the pill and drops the click; the control keeps its
 *   place, because the baseline draws its bar items unconditionally.
 * @param tag an optional stable test tag.
 * @param accessibilityLabel the longer spoken name when it differs from the title
 *   (the baseline's `.accessibilityLabel`); `null` speaks [description].
 */
@Composable
public fun PageBarCapsule(
    description: String,
    onClick: () -> Unit,
    insetH: Dp,
    elevation: Dp,
    modifier: Modifier = Modifier,
    showsLabel: Boolean = true,
    glyph: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
    tag: String? = null,
    accessibilityLabel: String? = null,
) {
    val tokens = LocalUiTokens.current
    val shape = RoundedCornerShape(percent = CAPSULE_CORNER_PERCENT)
    val interactionSource = remember { MutableInteractionSource() }
    Row(
        modifier = modifier
            // A white pill on a white page is only visible through this shadow,
            // which is why the baseline's halo is wider than the pill.
            .shadow(elevation = elevation, shape = shape)
            .background(tokens.colors.surface, shape)
            .defaultMinSize(minHeight = tokens.geometry.pageHeaderMinHeight)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            // interaction.md §6 rule 5: a bar item has no Material ripple. Its only
            // feedback is the platform's own pressed chrome, which this control does
            // not paint; the shared §6 table covers the drawer pill/row and the
            // primary action, not this floating bar capsule.
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            // A bar item can carry two different names: the title a person reads
            // (or the icon's spoken name) and a longer action sentence. iOS uses both
            // — `Label("3D 示例", systemImage: "cube")` plus
            // `.accessibilityLabel("打开 3D 示例")` (`FilesPage.swift:79`–`:81`) — so
            // this control keeps them apart instead of flattening one into the other.
            .semantics { contentDescription = accessibilityLabel ?: description }
            // An icon-only bar item is inset half as much as a text one: the shots
            // resolve 添加's pill to 77.7 pt (34 pt text box + 2 × 22) and the cube's
            // to 48 pt (24 pt symbol + 2 × 12), both right-aligned on the same edge.
            // One token, one rule, both measurements.
            .padding(horizontal = if (showsLabel) insetH else insetH / 2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        glyph?.invoke()
        if (showsLabel) {
            BasicText(
                text = description,
                style = settingsLabelStyle().copy(
                    color = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary,
                ),
                maxLines = 1,
            )
        }
    }
}

/**
 * HomeSpec's full-width black capsule for a page's primary action.
 *
 * Pressed/disabled feedback comes from the shared §6 table
 * ([com.phonedsh.ui.press.primaryPressed]): 0.8 whole-content opacity while
 * pressed and a 0.25 fill while disabled. There is no local press constant and
 * no ripple; [interactionSource] is exposed so a host (or a JVM test) can drive
 * the same state machine the real tap drives.
 */
@Composable
public fun HomePrimaryAction(
    label: String,
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    tag: String? = null,
    interactionSource: MutableInteractionSource = remember { MutableInteractionSource() },
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val isEnabled = enabled && onClick != null
    val actionModifier = if (onClick != null) {
        Modifier.clickable(
            interactionSource = interactionSource,
            indication = null,
            enabled = isEnabled,
            role = Role.Button,
            onClick = onClick,
        )
    } else {
        Modifier.semantics {
            role = Role.Button
            disabled()
        }
    }
    val shape = RoundedCornerShape(percent = CAPSULE_CORNER_PERCENT)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(HomeMetrics.homePrimaryButtonHeight)
            .clip(shape)
            // interaction.md §6 rule 3: the shared table owns BOTH ends of this
            // control — 0.8 whole-content opacity while pressed and the 0.25 fill
            // while disabled. The page keeps no local press/disabled alpha.
            .primaryPressed(
                interactionSource = interactionSource,
                enabled = isEnabled,
                shape = shape,
            )
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .then(actionModifier)
            .semantics(mergeDescendants = true) { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(label, style = type.buttonLabel.copy(color = tokens.colors.primaryButtonInk))
    }
}

/**
 * The baseline's `cube` SF Symbol, drawn at `spacing.iconText × 4` (24 pt: the
 * measured 21.33 × 24 pt ink of `ios-files.png`).
 *
 * `:lib` ships no icon assets and no SF Symbols, so this is the isometric cube from
 * first principles: a hexagon plus the three edges from its centre to alternate
 * vertices. The ink is the token the shot measures (`colors.systemLabel`, #1A1919 on
 * white) — **not** the accent the 3D entry's label would get as a text button.
 *
 * @param modifier the glyph's placement.
 */
@Composable
public fun CubeGlyph(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    // UIKit's dynamic label is unresolved in the current Android theme. HomeSpec
    // supplies the page ink for this monochrome icon role.
    val ink = tokens.colors.textPrimary
    Canvas(modifier = modifier.size(tokens.spacing.iconText * CUBE_GLYPH_BOX_RATIO)) {
        val stroke = tokens.stroke.hairline.toPx() * CUBE_STROKE_SCALE
        val radius = size.minDimension / 2f * CUBE_RADIUS_RATIO
        val center = Offset(size.width / 2f, size.height / 2f)
        // Point-up hexagon: SF's cube has a vertex straight up and down.
        val vertices = (0 until CUBE_VERTEX_COUNT).map { index ->
            val angle = -PI / 2.0 + index * 2.0 * PI / CUBE_VERTEX_COUNT
            Offset(
                center.x + (radius * cos(angle)).toFloat(),
                center.y + (radius * sin(angle)).toFloat(),
            )
        }
        val outline = Path().apply {
            moveTo(vertices[0].x, vertices[0].y)
            vertices.drop(1).forEach { lineTo(it.x, it.y) }
            close()
        }
        drawPath(outline, color = ink, style = Stroke(width = stroke, cap = StrokeCap.Round))
        // The three edges that turn the hexagon into a cube: centre → every other
        // vertex.
        listOf(0, 2, 4).forEach { index ->
            drawLine(
                color = ink,
                start = center,
                end = vertices[index],
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
        }
    }
}

/** The glyph's box, as a multiple of the icon-to-text gap (6 pt × 4 = 24 pt). */
private const val CUBE_GLYPH_BOX_RATIO: Int = 4

/** A capsule is a 50 %-cornered rectangle. */
private const val CAPSULE_CORNER_PERCENT: Int = 50

/** The cube's outline stroke, as a multiple of the theme hairline. */
private const val CUBE_STROKE_SCALE: Int = 3

/** The hexagon's radius inside the box, leaving room for the stroke. */
private const val CUBE_RADIUS_RATIO: Float = 0.86f

/** A cube silhouette has six vertices. */
private const val CUBE_VERTEX_COUNT: Int = 6
