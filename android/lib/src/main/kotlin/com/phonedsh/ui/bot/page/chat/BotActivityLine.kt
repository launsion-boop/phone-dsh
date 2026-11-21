// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.background
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.provider.Settings
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalDensity
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiDarkTheme

/**
 * The one live-status line under the Bot header (`BotActivityLine.swift:8-55`).
 *
 * The timing machine lives in `BotChatModel`/K3 ([BotActivityLineState]);
 * this view only draws the text: one 13/18 medium secondary line, centered,
 * never capturing touches. Waiting, problem, inactive and reduced-motion
 * states do not create an infinite animation.
 */
@Composable
internal fun BotActivityLine(
    text: String,
    quiet: Boolean,
    problem: Boolean,
    pageActive: Boolean,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val ink = if (problem) tokens.colors.pageDanger else if (LocalUiDarkTheme.current) Color(0xFFB8BEC7) else Color(0xFF69717C)
    val reducedMotion = systemReducedMotion(pageActive to quiet to problem)
    val ambient = pageActive && !quiet && !problem && !reducedMotion
    val swapOffsetPx = with(LocalDensity.current) { BotChatMetrics.ACTIVITY_SWAP_OFFSET_PT.dp.roundToPx() }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(BotChatMetrics.ACTIVITY_LINE_PT.dp)
            .padding(horizontal = BotChatMetrics.ACTIVITY_HORIZONTAL_PAD_PT.dp)
            .clearAndSetSemantics {
                contentDescription = text
                testTag = BotChatTags.ACTIVITY_LINE
            },
        contentAlignment = Alignment.Center,
    ) {
        var textWidthPx by remember(text) { mutableIntStateOf(0) }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val textMaxWidth = maxWidth - 13.dp
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.size(BotChatMetrics.ACTIVITY_DOT_PT.dp)
                    .background(ink, androidx.compose.foundation.shape.CircleShape))
                Spacer(Modifier.width(BotChatMetrics.ACTIVITY_DOT_GAP_PT.dp))
                Box(Modifier.widthIn(max = textMaxWidth), contentAlignment = Alignment.Center) {
                    AnimatedContent(
                        targetState = text,
                        transitionSpec = {
                            if (reducedMotion || !pageActive || quiet || problem) androidx.compose.animation.ContentTransform(
                                fadeIn(animationSpec = tween(0)), fadeOut(animationSpec = tween(0)))
                            else (slideInVertically(animationSpec = tween(BotChatMetrics.ACTIVITY_CHANGE_MS)) { swapOffsetPx } + fadeIn(tween(BotChatMetrics.ACTIVITY_CHANGE_MS))) togetherWith
                                (slideOutVertically(animationSpec = tween(BotChatMetrics.ACTIVITY_CHANGE_MS)) { -swapOffsetPx } + fadeOut(tween(BotChatMetrics.ACTIVITY_CHANGE_MS)))
                        },
                        label = "bot-activity-change",
                    ) { value ->
                        BasicText(value, style = botActivityStyle().copy(color = ink, textAlign = TextAlign.Center),
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            onTextLayout = { textWidthPx = it.size.width })
                    }
                    if (ambient) ActivitySweep(text = text, ink = ink, textWidthPx = textWidthPx)
                }
            }
        }
    }
}

@Composable
private fun ActivitySweep(text: String, ink: Color, textWidthPx: Int) {
    val transition = rememberInfiniteTransition(label = "bot-activity-sweep")
    val x by transition.animateFloat(-1f, 1f, infiniteRepeatable(tween(BotChatMetrics.ACTIVITY_SHIMMER_MS), RepeatMode.Restart), label = "sweep")
    val distance = textWidthPx.coerceAtLeast(1).toFloat()
    BasicText(text, style = botActivityStyle().copy(
        brush = androidx.compose.ui.graphics.Brush.linearGradient(
            0f to Color.Transparent, 0.4f to ink.copy(alpha = 0f),
            0.5f to Color.White.copy(alpha = 0.65f), 0.6f to ink.copy(alpha = 0f), 1f to Color.Transparent,
            start = Offset(x * distance, 0f), end = Offset((x + 1f) * distance, 0f)),
        textAlign = TextAlign.Center), maxLines = 1, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clearAndSetSemantics {})
}

@Composable
private fun systemReducedMotion(key: Any?): Boolean {
    val context = LocalContext.current
    return remember(key, context) {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}
