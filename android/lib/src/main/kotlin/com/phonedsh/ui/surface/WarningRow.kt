// The baseline's orange warning line: an `exclamationmark.triangle.fill` and a sentence.
// SPDX-License-Identifier: MIT
//
// Why it is not `SessionFailureLine`: that component is the session family's red
// failure line (a read that failed). The baseline draws this one in **orange** and
// keeps the page readable underneath it — it is a warning about what the host
// could not do, not a failure of the page.
//
// ## What the baseline actually is
//
//   NativeConfigurationPage.swift:15-20
//     if let error = model.error {
//         Section {
//             Label(nativeConfigurationError(error), systemImage: "exclamationmark.triangle.fill")
//                 .foregroundStyle(.orange)
//         }
//     }
//
// The `page-settings-plugins` pair's iOS side measures it at x 32.67–50.0,
// y 345.0–382.33 pt (the glyph is 18.0 × 20.33 pt), over a `secondarySystemGroupedBackground`
// card. The ink is SwiftUI `Color.orange`, not the theme's `colors.warning`; it is
// the `colors.systemOrange` token (#FF8D28 / #FF9230), measured in both appearances.
//
// The Android page has no cards (its rows sit on the page fill with separators),
// so the line is drawn flat at the page margin instead of inside a rounded card.
// That is the same structural difference every other row of this page carries.
//
// Token discipline: ink from `LocalUiTokens`, the mark's colour from `colors.page`
// (the surface the mark is punched out of), the glyph box from `spacing.iconText`,
// and the stroke from `stroke.hairline`. No `N.dp`, no `N.sp`, no colour literal.
package com.phonedsh.ui.surface

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.theme.LocalUiTokens

/**
 * One orange warning line: the triangle glyph, then the host's own sentence.
 *
 * @param text the sentence to print (the host's message, never a rewrite of it).
 * @param modifier the caller's placement.
 * @param tag an optional stable test tag.
 */
@Composable
public fun WarningLine(
    text: String,
    modifier: Modifier = Modifier,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    // UIKit systemOrange is unresolved in the Android theme. Use the current
    // NativePagePalette warning role as a deliberate fallback; the system-orange
    // hue remains a theme-resolver limitation.
    val ink = tokens.colors.pageWarning
    Row(
        modifier = modifier
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        WarningTriangleGlyph(
            tint = ink,
            modifier = Modifier.size(tokens.spacing.iconText * TRIANGLE_BOX_RATIO),
        )
        BasicText(
            text = text,
            style = settingsLabelStyle().copy(color = ink),
        )
    }
}

/**
 * `exclamationmark.triangle.fill`: a filled triangle with the mark punched out.
 *
 * @param tint the triangle's fill.
 * @param modifier the glyph's box; the triangle is inset inside it.
 */
@Composable
public fun WarningTriangleGlyph(tint: Color, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val mark = tokens.colors.page
    Canvas(modifier = modifier) {
        val stroke = tokens.stroke.hairline.toPx() * TRIANGLE_STROKE_SCALE
        val inset = stroke
        val left = inset
        val right = size.width - inset
        val top = inset
        val bottom = size.height - inset
        val triangle = Path().apply {
            moveTo(size.width / 2f, top)
            lineTo(right, bottom)
            lineTo(left, bottom)
            close()
        }
        drawPath(triangle, color = tint)
        // The mark: a stem and a dot, both in the surface colour the triangle
        // sits on, so the exclamation reads as a hole in the fill.
        val stemTop = top + (bottom - top) * MARK_TOP_RATIO
        val stemBottom = top + (bottom - top) * MARK_STEM_BOTTOM_RATIO
        drawLine(
            color = mark,
            start = Offset(size.width / 2f, stemTop),
            end = Offset(size.width / 2f, stemBottom),
            strokeWidth = stroke * MARK_STROKE_RATIO,
            cap = StrokeCap.Round,
        )
        drawCircle(
            color = mark,
            radius = stroke * MARK_DOT_RADIUS_RATIO,
            center = Offset(size.width / 2f, top + (bottom - top) * MARK_DOT_RATIO),
        )
    }
}

/** The triangle's box, as a multiple of the icon-to-text gap (6 pt × 3 = 18 pt). */
private const val TRIANGLE_BOX_RATIO: Int = 3

/** A symbol stroke is three hairlines (0.5 × 3 = 1.5 pt), the pill glyph's weight. */
private const val TRIANGLE_STROKE_SCALE: Int = 3

/** The mark's stroke, as a multiple of that stroke (1.5 × 2 = 3 pt). */
private const val MARK_STROKE_RATIO: Int = 2

/** The mark's dot radius, as a multiple of the symbol stroke. */
private const val MARK_DOT_RADIUS_RATIO: Float = 1.2f

/** The stem's top, as a fraction of the triangle's height. */
private const val MARK_TOP_RATIO: Float = 0.3f

/** The stem's bottom, as a fraction of the triangle's height. */
private const val MARK_STEM_BOTTOM_RATIO: Float = 0.66f

/** The dot's centre, as a fraction of the triangle's height. */
private const val MARK_DOT_RATIO: Float = 0.82f
