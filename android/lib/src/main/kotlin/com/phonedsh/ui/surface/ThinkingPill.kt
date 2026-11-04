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
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
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
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Active compatibility tokens used alongside the HomeSpec process-row contract. */
public object ThinkingPillTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.COLORS_TEXT_TERTIARY,
        UiTokenNames.COLORS_TEXT_PLACEHOLDER,
        UiTokenNames.TYPOGRAPHY_PROCESS,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.MOTION_DISCLOSURE,
        UiTokenNames.MOTION_SHIMMER,
        UiTokenNames.GEOMETRY_DISCLOSURE_ICON_GAP,
        UiTokenNames.GEOMETRY_PROCESS_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_PROCESS_ICON,
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
 * @param detail the actual full reasoning source; `null` means the source is
 *   unknown or unavailable. A one-line full source can still be expanded.
 * @param onOpenFile host router for relative workspace links in compact reasoning.
 * @param onOpenResource host router for scoped file/sandbox resource URIs.
 * @param imageSource the host's workspace/session image reader, when available.
 * @param detailTruncated true only when the host reports a bounded source excerpt.
 */
@Composable
public fun ThinkingPill(
    summary: String,
    streaming: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    detail: String? = null,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    imageSource: MarkdownImageSource? = null,
    detailTruncated: Boolean? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canExpand = detail != null
    val showsSummary = summary.isNotEmpty() && !expanded

    // The tag sits on the merged, clickable row (see ToolRow).
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = HomeMetrics.processRowHeight)
                .clickable(
                    enabled = canExpand,
                    role = Role.Button,
                    onClickLabel = if (expanded) UiStrings.COLLAPSED else UiStrings.EXPANDED,
                    onClick = onToggle,
                )
                .semantics(mergeDescendants = true) {
                    stateDescription = if (expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
                    contentDescription = if (showsSummary) "${UiStrings.THINKING} · $summary" else UiStrings.THINKING
                }
                .testTag(UiTags.THINKING_PILL),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
        ) {
            Box(
                modifier = Modifier
                    .size(HomeMetrics.processIcon),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    icon = if (canExpand && expanded) PdshIcon.CHEVRON_UP else PdshIcon.THINK,
                    size = if (canExpand && expanded) {
                        ChatMetrics.DISCLOSURE_CHEVRON_ICON_PT.dp
                    } else {
                        ChatMetrics.DISCLOSURE_CATEGORY_ICON_PT.dp
                    },
                    tint = tokens.colors.textSecondary,
                    contentDescription = null,
                    modifier = Modifier.testTag(
                        if (canExpand && expanded) THINKING_CHEVRON_TAG else THINKING_CATEGORY_ICON_TAG,
                    ),
                )
            }
            BasicText(
                text = UiStrings.THINKING,
                style = type.processBody.copy(color = tokens.colors.textSecondary),
                maxLines = 1,
            )
            if (showsSummary) {
                Box(
                    modifier = Modifier
                        .padding(horizontal = tokens.geometry.summaryDotGap)
                        .size(tokens.geometry.summaryDotDiameter)
                        .clip(CircleShape)
                        .background(tokens.colors.textPlaceholder),
                )
                Box(modifier = Modifier.weight(1f)) {
                    if (streaming) {
                        ShimmerLine(
                            text = summary,
                            style = type.processBody,
                            base = tokens.colors.textSecondary,
                            sweep = tokens.colors.textTertiary,
                            durationMs = tokens.motion.shimmerMs,
                            easing = tokens.motion.shimmerEasing,
                            repeat = tokens.motion.shimmerRepeat,
                        )
                    } else {
                        BasicText(
                            text = summary,
                            style = type.processBody.copy(color = tokens.colors.textSecondary),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = expanded && canExpand,
            enter = expandVertically(
                animationSpec = tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing),
            ) + fadeIn(tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing)),
            exit = shrinkVertically(
                animationSpec = tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing),
            ) + fadeOut(tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing)),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = tokens.geometry.thinkingContentIndent,
                        top = tokens.geometry.thinkingContentVertical,
                        bottom = tokens.geometry.thinkingContentVertical,
                    ),
            ) {
                MarkdownBody(
                    markdown = detail.orEmpty().ifEmpty { "…" },
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    variant = MarkdownVariant.COMPACT,
                    imageSource = imageSource,
                )
                if (detailTruncated == true) {
                    BasicText(
                        text = "仅显示部分思考内容",
                        style = type.caption.copy(color = tokens.colors.textSecondary),
                    )
                }
            }
        }
    }
}

internal const val THINKING_CATEGORY_ICON_TAG: String = "pdsh.surface.thinking.category-icon"
internal const val THINKING_CHEVRON_TAG: String = "pdsh.surface.thinking.chevron"

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
