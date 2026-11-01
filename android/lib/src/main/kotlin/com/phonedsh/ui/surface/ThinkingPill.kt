// Signature surface 3/6 - the thinking pill.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "thinking_pill" + §4 + `tokens.json`
// `signatureSurfaces.thinkingPill`.
//
// Collapsed it is one summary line; while the block still streams the summary
// carries the shimmer sweep (`motion.shimmer` + `typography.shimmer`). Streaming
// ends, the sweep stops, the summary stays.
package com.phonedsh.ui.surface

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/**
 * The token inventory of this surface; exactly
 * `signatureSurfaces.thinkingPill.tokens`.
 */
public object ThinkingPillTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_CAPTION,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_SHIMMER,
        UiTokenNames.MOTION_SHIMMER,
        UiTokenNames.GEOMETRY_DISCLOSURE_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_SUMMARY_DOT_DIAMETER,
        UiTokenNames.GEOMETRY_SUMMARY_DOT_GAP,
        UiTokenNames.GEOMETRY_THINKING_CONTENT_INDENT,
        UiTokenNames.GEOMETRY_THINKING_CONTENT_VERTICAL,
    )
}

/**
 * The reasoning row.
 *
 * @param summary the collapsed summary line (already projected: last
 *   double-newline segment's first line, `**` removed).
 * @param streaming true while the reasoning block still streams; this is what
 *   turns the sweep on.
 * @param expanded whether the full reasoning is visible.
 * @param onToggle expand/collapse.
 * @param detail the full reasoning text; `null` disables the toggle because
 *   there is nothing to reveal.
 */
@Composable
public fun ThinkingPill(
    summary: String,
    streaming: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    detail: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canExpand = detail != null

    // The tag sits on the merged, clickable row (see ToolRow).
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.disclosureRowHeight)
                .clickable(
                    enabled = canExpand,
                    role = Role.Button,
                    onClickLabel = if (expanded) UiStrings.COLLAPSED else UiStrings.EXPANDED,
                    onClick = onToggle,
                )
                .semantics(mergeDescendants = true) {
                    stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                    contentDescription = "${UiStrings.THINKING} · $summary"
                }
                .testTag(UiTags.THINKING_PILL),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.summaryDotGap),
        ) {
            Box(
                modifier = Modifier
                    .size(tokens.geometry.summaryDotDiameter)
                    .clip(CircleShape)
                    .background(tokens.colors.caption),
            )
            BasicText(
                text = UiStrings.THINKING,
                style = type.secondary.copy(color = tokens.colors.tertiary),
                maxLines = 1,
            )
            Box(modifier = Modifier.weight(1f)) {
                if (streaming) {
                    ShimmerLine(
                        text = summary,
                        style = type.shimmer,
                        base = tokens.colors.secondary,
                        sweep = tokens.colors.tertiary,
                        durationMs = tokens.motion.shimmerMs,
                        easing = tokens.motion.shimmerEasing,
                        repeat = tokens.motion.shimmerRepeat,
                    )
                } else {
                    BasicText(
                        text = summary,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        if (expanded && canExpand) {
            BasicText(
                text = detail.orEmpty(),
                style = type.secondary.copy(color = tokens.colors.tertiary),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = tokens.geometry.thinkingContentIndent,
                        top = tokens.geometry.thinkingContentVertical,
                        bottom = tokens.geometry.thinkingContentVertical,
                    ),
            )
        }
    }
}

/**
 * A one-line summary with a highlight band sweeping across it.
 *
 * The band is a clipped copy of the same line in the sweep ink, so it needs no
 * gradient token: `motion.shimmer` supplies the period and `colors.caption` /
 * `colors.secondary` / `colors.tertiary` supply the inks.
 */
@Composable
internal fun ShimmerLine(
    text: String,
    style: TextStyle,
    base: Color,
    sweep: Color,
    durationMs: Int,
    easing: androidx.compose.animation.core.Easing,
    repeat: Boolean,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = durationMs, easing = easing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmer-progress",
    )
    val effective = if (repeat) progress else 1f
    Box(modifier = modifier) {
        BasicText(
            text = text,
            style = style.copy(color = base),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        BasicText(
            text = text,
            style = style.copy(color = sweep),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.drawWithContent {
                val band = size.width * BAND_FRACTION
                val left = -band + (size.width + band) * effective
                clipRect(left = left, top = 0f, right = left + band, bottom = size.height) {
                    this@drawWithContent.drawContent()
                }
            },
        )
    }
}

private const val BAND_FRACTION: Float = 0.45f
