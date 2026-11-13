// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.bot.driver.BotLiveChatTurn
import com.phonedsh.ui.bot.driver.BotLiveSegment

/**
 * The running turn in arrival order (`BotChatPage.swift:977-1011`): committed
 * text bubbles, then the attempt still streaming. Tool calls are not rows; the
 * activity line carries their category and phrase.
 */
@Composable
internal fun BotLiveTurnView(turn: BotLiveChatTurn) {
    Column {
        for (segment in turn.segments) {
            if (segment is BotLiveSegment.Text && botAnswerHasContent(segment.text)) {
                BotAnswerBubble(
                    text = segment.text,
                    streaming = false,
                    modifier = Modifier
                        .padding(horizontal = HomeMetrics.contentInset)
                        .padding(vertical = HomeMetrics.BLOCK_GAP_PT.dp / 2),
                )
            }
        }
        if (botAnswerHasContent(turn.buffer)) {
            BotAnswerBubble(
                text = turn.buffer,
                streaming = true,
                modifier = Modifier
                    .padding(horizontal = HomeMetrics.contentInset)
                    .padding(vertical = HomeMetrics.BLOCK_GAP_PT.dp / 2)
                    .testTag(BotChatTags.STREAMING_TEXT),
            )
        }
    }
}
