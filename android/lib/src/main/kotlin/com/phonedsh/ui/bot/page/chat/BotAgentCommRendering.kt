// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.state.BotFishReaction
import com.phonedsh.ui.bot.state.JsonSupport
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens

/** One agent-comm row's minimal presentation (`BotAgentCommRendering.swift:12-24`). */
public data class BotAgentCommPresentation(
    public val tone: BotAgentCommTone,
    public val peerID: String?,
    public val peerName: String?,
    public val text: String,
    public val detail: String?,
)

/** The five tones `BotAgentCommRendering.presentation` derives. */
public enum class BotAgentCommTone { OUTBOUND, INBOUND, INCOMING, REPLY, FAILED }

/**
 * The one-line rendering of an agent-comm row (`BotAgentCommRendering.swift:27-74`).
 * The row semantics are shared with `bot-drawer.md` §5: an outbound/inbound
 * direction and an incoming/reply target all collapse to one sentence plus the
 * peer identity; a failure shows the error and never fakes a success.
 */
public object BotAgentCommRendering {
    public fun presentation(row: BotRow): BotAgentCommPresentation? {
        val comm = (row.body["agentComm"] as? JsonObject)?.members
        val fromAgent = (row.body["fromAgent"] as? JsonObject)?.members
        val toAgent = (row.body["toAgent"] as? JsonObject)?.members
        if (comm == null && fromAgent == null && toAgent == null) return null

        val direction = (comm?.let { JsonSupport.string(it["direction"]) })
            ?: JsonSupport.string(row.body["direction"])
            ?: "outbound"
        val fromID = (comm?.let { JsonSupport.string(it["fromAgentId"]) })
            ?: (fromAgent?.let { JsonSupport.string(it["id"]) })
        val fromName = (comm?.let { JsonSupport.string(it["fromAgentName"]) })
            ?: (fromAgent?.let { JsonSupport.string(it["name"]) })
        val toID = (comm?.let { JsonSupport.string(it["targetId"]) })
            ?: (toAgent?.let { JsonSupport.string(it["id"]) })
        val toName = (comm?.let { JsonSupport.string(it["targetName"]) })
            ?: (toAgent?.let { JsonSupport.string(it["name"]) })
        val message = (comm?.let { JsonSupport.string(it["message"]) })
            ?: JsonSupport.string(row.body["text"])
            ?: ""
        val reply = comm?.let { JsonSupport.string(it["replyText"]) } ?: ""
        val error = (comm?.let { JsonSupport.string(it["error"]) })
            ?: JsonSupport.string(row.body["error"])

        return when (direction) {
            "inbound" -> {
                val name = fromName ?: "队友"
                val body = if (reply.isEmpty()) "已收到回复" else reply
                BotAgentCommPresentation(
                    tone = if (error == null) BotAgentCommTone.INBOUND else BotAgentCommTone.FAILED,
                    peerID = fromID,
                    peerName = name,
                    text = "$name 回复",
                    detail = error ?: clipped(body),
                )
            }
            "incoming" -> {
                val name = fromName ?: "队友"
                BotAgentCommPresentation(
                    tone = BotAgentCommTone.INCOMING,
                    peerID = fromID,
                    peerName = name,
                    text = "$name 传来消息",
                    detail = clipped(message),
                )
            }
            "reply" -> {
                val name = toName ?: "队友"
                BotAgentCommPresentation(
                    tone = BotAgentCommTone.REPLY,
                    peerID = toID,
                    peerName = name,
                    text = "已回复 $name",
                    detail = clipped(message),
                )
            }
            else -> {
                val name = toName ?: "队友"
                BotAgentCommPresentation(
                    tone = if (error == null) BotAgentCommTone.OUTBOUND else BotAgentCommTone.FAILED,
                    peerID = toID,
                    peerName = name,
                    text = "已传消息给 $name",
                    detail = error ?: clipped(message),
                )
            }
        }
    }

    /** The sidebar-friendly summary for a run of rows on one thread. */
    public fun summaryText(count: Int, peerName: String?): String {
        val name = peerName ?: "队友"
        return if (count <= 1) "与 $name 的消息" else "与 $name 的 $count 条消息往来"
    }

    public fun clipped(value: String, limit: Int = BotChatMetrics.COMM_CLIP_CHARS): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length <= limit) return trimmed
        return trimmed.take(limit) + "…"
    }
}

/**
 * The minimal agent-comm line (`BotChatPage.swift:812-872`): a small peer
 * avatar, a direction glyph, one semibold sentence and a two-line detail.
 */
@Composable
internal fun BotAgentCommRow(
    presentation: BotAgentCommPresentation,
    appearance: BotFishAppearance?,
    crowned: Boolean,
    reaction: BotFishReaction?,
    fish: BotFishSlot,
    onSelectBot: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val failed = presentation.tone == BotAgentCommTone.FAILED
    val tint = if (failed) tokens.colors.pageDanger else tokens.colors.textSecondary
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(
                enabled = presentation.peerID != null,
                role = Role.Button,
            ) { presentation.peerID?.let(onSelectBot) }
            .semantics {
                contentDescription =
                    listOfNotNull(presentation.text, presentation.detail).joinToString("，")
            }
            .testTag(BotChatTags.AGENT_COMM_ROW),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.COMM_GAP_PT.dp),
    ) {
        if (appearance != null) {
            fish(
                BotFishLifecycle.IDLE,
                appearance,
                crowned,
                BotChatMetrics.COMM_AVATAR_PT.dp,
                true,
                Modifier.size(BotChatMetrics.COMM_AVATAR_PT.dp),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(BotChatMetrics.COMM_AVATAR_PT.dp)
                    .clip(CircleShape)
                    .background(tokens.colors.userBubble),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(PdshIcon.PEOPLE, BotChatMetrics.GAP_12_PT.dp, tint, null)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_5_PT.dp),
            ) {
                PdshIconView(PdshIcon.CHAT_BUBBLE, BotChatMetrics.COMM_ICON_PT.dp, tint, null)
                BasicText(
                    text = presentation.text,
                    style = botRowStyle(FontWeight.SemiBold).copy(
                        fontSize = BotChatMetrics.COMM_TEXT_SIZE_PT.sp,
                        color = tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (!presentation.detail.isNullOrEmpty()) {
                BasicText(
                    text = presentation.detail,
                    style = botRowStyle().copy(
                        fontSize = BotChatMetrics.COMM_TEXT_SIZE_PT.sp,
                        color = tint,
                    ),
                    maxLines = BotChatMetrics.COMM_LINE_LIMIT,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(0.dp))
    }
}
