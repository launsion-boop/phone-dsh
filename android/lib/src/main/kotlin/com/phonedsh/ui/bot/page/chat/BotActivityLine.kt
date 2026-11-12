// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.LocalUiTokens

/**
 * The one live-status line under the Bot header (`BotActivityLine.swift:8-55`).
 *
 * The timing machine lives in `BotChatModel`/K3 ([BotActivityLineState]);
 * this view only draws the text: one 13/18 medium secondary line, centered,
 * never capturing touches. Waiting and problem lines stay still; only an
 * active line breathes.
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
    val ink = if (problem) tokens.colors.pageDanger else tokens.colors.textSecondary
    val ambient = pageActive && !quiet
    val transition = rememberInfiniteTransition(label = "bot-activity-line")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = BotChatMetrics.ACTIVITY_BREATH_MIN_ALPHA,
        animationSpec = infiniteRepeatable(
            animation = tween(BotChatMetrics.ACTIVITY_BREATH_MS),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "bot-activity-breath",
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(BotChatMetrics.ACTIVITY_LINE_PT.dp)
            .padding(horizontal = BotChatMetrics.ACTIVITY_HORIZONTAL_PAD_PT.dp)
            .testTag(BotChatTags.ACTIVITY_LINE)
            .semantics { contentDescription = text },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = text,
            style = botActivityStyle().copy(color = ink, textAlign = TextAlign.Center),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .alpha(if (ambient) alpha else 1f),
        )
    }
}
