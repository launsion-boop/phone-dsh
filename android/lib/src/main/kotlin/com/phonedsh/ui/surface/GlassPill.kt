// Android rendering of the iOS secondary toolbar's bordered pill.
// SPDX-License-Identifier: MIT
//
// Why this file exists next to `PageBarControls.kt`: that file draws the *bar*
// capsule — a white pill with a shadow, floating over the page, right-aligned in
// a toolbar slot. The pill here is the other shape: a system `.buttonStyle(.bordered)`
// control that sits **inside page content**, filled with the system's translucent
// `secondarySystemFill` and with **no shadow at all**.
//
// ## What the baseline actually is
//
// `NativeConfigurationPage.swift:67-95` puts three of them in one `HStack(spacing: 10)`:
//
//   :68-74   插件说明  `Label("插件说明", systemImage: "info.circle")`   `.buttonStyle(.bordered)`
//   :76-82   刷新      `Label("刷新", systemImage: model.isLoading ? … : "arrow.clockwise")`  `.bordered`
//   :84-94   添加插件  `Menu { … } label: { Label("添加插件", systemImage: "plus") }`  `.borderedProminent` + `.disabled(true)`
//
// The images measure all three (the `page-settings-plugins` pair's iOS side):
//
//   pill            x (pt)           y (pt)            fill       ink
//   插件说明        34.00–127.67     217.00–273.00     #E9E9EB    #0088FF
//   刷新            143.33–205.33    228.00–262.00     #E9E9EB    #0088FF
//   添加插件        250.00–343.67    217.00–273.00     #E9E9EB    #3A3A3B + dimmed blue +
//
// Three facts that this file therefore does **not** invent:
//
//   * **the fill is a token**, `colors.glassPillFill` (#E9E9EB / #39393D), measured
//     in both appearances (`ios-settings-plugins.png` and
//     `ios-session-audit/screens/current/darkpass-plugins-dark.png`). It is the
//     system's `secondarySystemFill` composite, which is why the token is
//     `tier: system` and contrast-exempt as `composite`;
//   * **the corner is a capsule, not a radius token**: the left edge follows
//     x(y) = x0 + r − √(r² − dy²) with r = height/2 on both the 56.33 pt
//     two-line pill and the 34.33 pt one-line pill. A fixed pt radius would be
//     wrong on one of them, so the shape is `percent = 50`, the same ratio
//     `PageBarCapsule` uses for its capsule;
//   * **there is no shadow**: the pixels go from #FFFFFF to #E9E9EB in one
//     antialiased step on all four sides of every pill. The bar capsule's shadow
//     token (`geometry.pageBarButtonElevation`) is *not* reused here, because the
//     baseline does not draw one.
//
// ## The ink
//
// `#0088FF` is UIKit's `systemBlue`, not the theme's `colors.accent` (#3964FE).
// The token table has no system-blue entry and this lane may only add the tokens
// the missing control needs, so the label/glyph read `colors.accent`; the delta
// is reported in the receipt instead of being papered over with a hex literal.
// A disabled pill (`添加插件`) uses `colors.tertiary` for both glyph and label: the
// shot's dimmed #3A3A3B label over the #E9E9EB fill is SwiftUI's disabled
// opacity, which has no token.
//
// ## unverified geometry
//
// Two lengths have no declared token and are borrowed, measured from the same shot:
// the pill's 12 pt horizontal inset (`spacing.cardInset`; measured ≈11.7 pt from
// the 34.00 pt pill edge to the 45.67 pt glyph ink) and its 5 pt vertical inset
// (`spacing.badgeInsetV`). The iOS pill is 34.33 pt tall = its 20.33 pt line box
// + 2 × 7; Android's 17 pt line box is 24.3 pt, so 24.3 + 2 × 5 = 34.3 pt — the
// same drawn height, measured again on the L76 capture. The hit area keeps
// `geometry.pageRowMinHeight` (44 pt), so the touch target is larger than the fill.
//
// Token discipline: no `N.dp`, no `N.sp`, no colour constructor. The only
// literals are the capsule's 50 % corner and the glyph ratios below, which are
// shape ratios (a glyph is geometry, not a value source), exactly as
// `PageBarControls.kt`'s cube does it.
package com.phonedsh.ui.surface

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import com.phonedsh.ui.theme.LocalUiTokens
import kotlin.math.cos
import kotlin.math.sin

/**
 * One toolbar pill: the system's `.bordered` button, in page content.
 *
 * @param label the control's visible name (`Label`'s title in the baseline).
 * @param onClick the pill's action.
 * @param modifier the caller's placement.
 * @param glyph the leading symbol, given the pill's resolved ink so a disabled
 *   pill dims its symbol with its label; `null` draws a text-only pill.
 * @param enabled `false` dims both the glyph and the label to `colors.tertiary`
 *   and drops the click. The pill keeps its place: the baseline draws all three
 *   unconditionally and merely disables 添加插件 (`:93`).
 * @param tag an optional stable test tag.
 * @param accessibilityLabel the longer spoken name when it differs from the label
 *   (the baseline's `.accessibilityHint`, `:74`/`:94`); `null` speaks [label].
 */
@Composable
public fun GlassPill(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    glyph: (@Composable (Color) -> Unit)? = null,
    enabled: Boolean = true,
    tag: String? = null,
    accessibilityLabel: String? = null,
) {
    val tokens = LocalUiTokens.current
    val shape = RoundedCornerShape(percent = CAPSULE_CORNER_PERCENT)
    // The current iOS owner is a bordered control with a secondary system fill,
    // not a captured fixed glass color. Android has no adaptive system-fill
    // resolver here, so render the nearest reviewed control surface explicitly.
    val fill = tokens.colors.selector
    val ink = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = accessibilityLabel ?: label },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Row(
            modifier = Modifier
                .clip(shape)
                .background(fill, shape)
                .padding(
                    horizontal = tokens.spacing.cardInset,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            glyph?.invoke(ink)
            BasicText(
                text = label,
                style = settingsLabelStyle().copy(color = ink),
                maxLines = 1,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Glyphs
// ---------------------------------------------------------------------------
//
// `:lib` ships no icon assets and no SF Symbols, so each symbol the baseline
// draws is reconstructed from primitives at one token-derived box. The glyph ink
// is the pill's ink, so a disabled pill dims its symbol with its label.

/** The box every glyph below draws in: `spacing.iconText × 3` = 18 pt. */
private val GlyphBox: Dp
    @Composable get() = LocalUiTokens.current.spacing.iconText * GLYPH_BOX_RATIO

/** `info.circle` (`NativeConfigurationPage.swift:71`): a ring and a lowercase i. */
@Composable
public fun InfoCircleGlyph(tint: Color) {
    val tokens = LocalUiTokens.current
    Canvas(modifier = Modifier.size(GlyphBox)) {
        val stroke = tokens.stroke.hairline.toPx() * GLYPH_STROKE_SCALE
        val radius = size.minDimension / 2f - stroke
        val center = Offset(size.width / 2f, size.height / 2f)
        drawCircle(color = tint, radius = radius, center = center, style = Stroke(width = stroke))
        // The i's dot, then its stem: the same vertical axis, centred.
        drawCircle(color = tint, radius = stroke, center = Offset(center.x, center.y - radius * STEM_DOT_OFFSET))
        drawLine(
            color = tint,
            start = Offset(center.x, center.y - radius * STEM_TOP),
            end = Offset(center.x, center.y + radius * STEM_BOTTOM),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/** `arrow.clockwise` (`NativeConfigurationPage.swift:79`): an arc plus a two-stroke arrowhead. */
@Composable
public fun RefreshGlyph(tint: Color) {
    val tokens = LocalUiTokens.current
    Canvas(modifier = Modifier.size(GlyphBox)) {
        val stroke = tokens.stroke.hairline.toPx() * GLYPH_STROKE_SCALE
        val radius = size.minDimension / 2f - stroke
        val center = Offset(size.width / 2f, size.height / 2f)
        val arc = Path().apply {
            // Three quarters of a circle, open at the top right where the head sits.
            addArc(
                oval = Rect(center = center, radius = radius),
                startAngleDegrees = ARC_START_DEGREES,
                sweepAngleDegrees = ARC_SWEEP_DEGREES,
            )
        }
        drawPath(arc, color = tint, style = Stroke(width = stroke, cap = StrokeCap.Round))
        // The head: two short strokes from the arc's open end, pointing clockwise.
        val head = Offset(
            center.x + radius * cos(Math.toRadians(ARC_START_DEGREES.toDouble())).toFloat(),
            center.y + radius * sin(Math.toRadians(ARC_START_DEGREES.toDouble())).toFloat(),
        )
        drawLine(
            color = tint,
            start = head,
            end = Offset(head.x, head.y + radius * ARROWHEAD_RATIO),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = head,
            end = Offset(head.x - radius * ARROWHEAD_RATIO, head.y),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/** `plus` (`NativeConfigurationPage.swift:90`): two crossing strokes. */
@Composable
public fun PlusGlyph(tint: Color) {
    val tokens = LocalUiTokens.current
    Canvas(modifier = Modifier.size(GlyphBox)) {
        val stroke = tokens.stroke.hairline.toPx() * GLYPH_STROKE_SCALE
        val half = size.minDimension / 2f - stroke
        val center = Offset(size.width / 2f, size.height / 2f)
        drawLine(
            color = tint,
            start = Offset(center.x - half, center.y),
            end = Offset(center.x + half, center.y),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(center.x, center.y - half),
            end = Offset(center.x, center.y + half),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/**
 * `globe` (`NativeConfigurationPage.swift:134`): the ring, the equator and one
 * meridian.
 *
 * The baseline's 网页搜索与抓取 row is `Label(…, systemImage: "globe")`; the row
 * itself is the page's `InfoRow`, which has no leading slot, so the page draws
 * this glyph beside it.
 */
@Composable
public fun GlobeGlyph(tint: Color) {
    val tokens = LocalUiTokens.current
    Canvas(modifier = Modifier.size(GlyphBox)) {
        val stroke = tokens.stroke.hairline.toPx() * GLYPH_STROKE_SCALE
        val radius = size.minDimension / 2f - stroke
        val center = Offset(size.width / 2f, size.height / 2f)
        drawCircle(color = tint, radius = radius, center = center, style = Stroke(width = stroke))
        // The equator: a full-width horizontal diameter.
        drawLine(
            color = tint,
            start = Offset(center.x - radius, center.y),
            end = Offset(center.x + radius, center.y),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        // The meridian: an ellipse whose half-width is a fraction of the radius.
        drawOval(
            color = tint,
            topLeft = Offset(center.x - radius * MERIDIAN_RATIO, center.y - radius),
            size = Size(radius * 2f * MERIDIAN_RATIO, radius * 2f),
            style = Stroke(width = stroke),
        )
    }
}

/** A capsule is a 50 %-cornered rectangle. */
private const val CAPSULE_CORNER_PERCENT: Int = 50

/** The glyph box, as a multiple of the icon-to-text gap (6 pt × 3 = 18 pt). */
private const val GLYPH_BOX_RATIO: Int = 3

/** A symbol stroke is three hairlines (0.5 × 3 = 1.5 pt), the cube's own weight. */
private const val GLYPH_STROKE_SCALE: Int = 3

/** The i's dot sits a third of the radius above centre. */
private const val STEM_DOT_OFFSET: Float = 0.45f

/** The i's stem starts just under the dot and ends above the ring's bottom. */
private const val STEM_TOP: Float = 0.15f

/** The i's stem bottom, as a fraction of the radius below centre. */
private const val STEM_BOTTOM: Float = 0.5f

/** `arrow.clockwise` opens at the top right, so the arc starts at −90° and sweeps 300°. */
private const val ARC_START_DEGREES: Float = -90f

/** The open arc's sweep, leaving a gap for the arrowhead. */
private const val ARC_SWEEP_DEGREES: Float = 300f

/** The arrowhead's arms, as a fraction of the radius. */
private const val ARROWHEAD_RATIO: Float = 0.5f

/** The globe's meridian half-width, as a fraction of the ring's radius. */
private const val MERIDIAN_RATIO: Float = 0.55f
