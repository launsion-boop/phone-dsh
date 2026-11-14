// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.bot.state.BotSettlementGlyph
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The four semantic tones a card tag or status uses (`BotCardKit.swift:138-150`). */
internal enum class BotCardTone { NEUTRAL, SUCCESS, DANGER, WARNING, CHOICE, DOCUMENT, WORK, APPROVAL }

@Composable
internal fun botToneInk(tone: BotCardTone): Color {
    val tokens = LocalUiTokens.current
    return when (tone) {
        BotCardTone.NEUTRAL -> tokens.colors.textPrimary
        BotCardTone.SUCCESS -> tokens.colors.homeSuccess
        BotCardTone.DANGER -> tokens.colors.pageDanger
        BotCardTone.WARNING -> tokens.colors.pageWarning
        BotCardTone.CHOICE -> if (tokens.dark) Color(0xFF95B8FF) else Color(0xFF275FCE)
        BotCardTone.DOCUMENT -> if (tokens.dark) Color(0xFFC9A9FA) else Color(0xFF7950BD)
        BotCardTone.WORK -> if (tokens.dark) Color(0xFF8BD7BB) else Color(0xFF237B64)
        BotCardTone.APPROVAL -> if (tokens.dark) Color(0xFFF0C27B) else Color(0xFF946017)
    }
}

@Composable
internal fun botToneWash(tone: BotCardTone): Color {
    val tokens = LocalUiTokens.current
    return when (tone) {
        BotCardTone.CHOICE -> if (tokens.dark) Color(0xFF222E47) else Color(0xFFEDF3FF)
        BotCardTone.DOCUMENT -> if (tokens.dark) Color(0xFF32283E) else Color(0xFFF4EFFC)
        BotCardTone.WORK -> if (tokens.dark) Color(0xFF213B32) else Color(0xFFEAF6F0)
        BotCardTone.APPROVAL -> if (tokens.dark) Color(0xFF3E3222) else Color(0xFFFFF5E4)
        else -> botToneInk(tone).copy(alpha = BotChatMetrics.TAG_TINT_ALPHA)
    }
}

/** 12/18 medium eyebrow (`BotCardKit.swift:50-53`). */
@Composable
internal fun botEyebrowStyle(): TextStyle = LocalUiType.current.caption.copy(
    fontSize = BotChatMetrics.META_SIZE_PT.sp,
    lineHeight = BotChatMetrics.META_LINE_PT.sp,
    fontWeight = FontWeight.Medium,
)

/** 15/22 semibold card title (`BotCardKit.swift:55-60`). */
@Composable
internal fun botTitleStyle(): TextStyle = LocalUiType.current.body.copy(
    fontSize = BotChatMetrics.TITLE_SIZE_PT.sp,
    lineHeight = BotChatMetrics.TITLE_LINE_PT.sp,
    fontWeight = FontWeight.SemiBold,
)

/** 14/20 regular card body (`BotCardKit.swift:62-67`). */
@Composable
internal fun botBodyStyle(): TextStyle = LocalUiType.current.body.copy(
    fontSize = BotChatMetrics.BODY_SIZE_PT.sp,
    lineHeight = BotChatMetrics.BODY_LINE_PT.sp,
)

/** 14/20 row label; [weight] is medium only for an emphasised value. */
@Composable
internal fun botRowStyle(weight: FontWeight = FontWeight.Normal): TextStyle =
    LocalUiType.current.body.copy(
        fontSize = BotChatMetrics.BODY_SIZE_PT.sp,
        lineHeight = BotChatMetrics.BODY_LINE_PT.sp,
        fontWeight = weight,
    )

/** 12/18 regular meta (`BotCardKit.swift:76-81`). */
@Composable
internal fun botMetaStyle(): TextStyle = LocalUiType.current.caption.copy(
    fontSize = BotChatMetrics.META_SIZE_PT.sp,
    lineHeight = BotChatMetrics.META_LINE_PT.sp,
)

/** 13/18 medium activity line (`BotActivityLine.swift:52-55`). */
@Composable
internal fun botActivityStyle(): TextStyle = LocalUiType.current.caption.copy(
    fontSize = BotChatMetrics.ACTIVITY_SIZE_PT.sp,
    lineHeight = BotChatMetrics.ACTIVITY_LINE_PT.sp,
    fontWeight = FontWeight.Medium,
)

/** 13 monospaced command text (`BotWorkCardView.swift:394-401`). */
@Composable
internal fun botCommandStyle(): TextStyle = LocalUiType.current.code.copy(
    fontSize = BotChatMetrics.COMMAND_SIZE_PT.sp,
    lineHeight = BotChatMetrics.COMMAND_LINE_PT.sp,
    fontFamily = FontFamily.Monospace,
)

/** A 44pt text button in the secondary ink (`BotCardKit.swift:455-461`). */
@Composable
internal fun BotPlainTextButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    enabled: Boolean = true,
    content: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val ink = if (enabled) tokens.colors.textPrimary else tokens.colors.textPlaceholder
    val tagged = if (tag != null) modifier.testTag(tag) else modifier
    Row(
        modifier = tagged
            .defaultMinSize(minWidth = BotChatMetrics.BUTTON_HEIGHT_PT.dp)
            .height(BotChatMetrics.BUTTON_HEIGHT_PT.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (content != null) {
            content()
        } else {
            BasicText(label, style = botRowStyle(FontWeight.Medium).copy(color = ink))
        }
    }
}

/** One failure line with the warning glyph (`BotUIComponents.swift:126-151`). */
@Composable
internal fun BotFailureRow(
    message: String,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(tokens.colors.surface, RoundedCornerShape(BotChatMetrics.GAP_12_PT.dp))
            .padding(BotChatMetrics.GAP_14_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PdshIconView(PdshIcon.WARNING, BotChatMetrics.GAP_16_PT.dp, tokens.colors.pageWarning, null)
        Spacer(Modifier.width(BotChatMetrics.GAP_12_PT.dp))
        BasicText(
            text = message,
            style = LocalUiType.current.secondary.copy(color = tokens.colors.textSecondary),
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            BotPlainTextButton("重试", onRetry, tag = "bot.retry")
        }
    }
}

/**
 * The semantic settlement glyph (`BotCardKit.swift:371-404`). The reference
 * maps the semantic id to an SF Symbol; Android draws the same four marks as
 * vector geometry so no icon font is involved.
 */
@Composable
internal fun BotSettlementIcon(
    glyph: BotSettlementGlyph,
    tint: Color,
    modifier: Modifier = Modifier,
    size: androidx.compose.ui.unit.Dp = BotChatMetrics.SETTLEMENT_ICON_PT.dp,
) {
    Canvas(modifier.size(size)) {
        val stroke = this.size.minDimension * 0.08f
        val radius = this.size.minDimension * 0.40f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        drawCircle(color = tint, radius = radius, center = center, style = Stroke(width = stroke))
        when (glyph) {
            BotSettlementGlyph.CHECKMARK_CIRCLE,
            BotSettlementGlyph.CHECKMARK_CIRCLE_FILL,
            -> {
                if (glyph == BotSettlementGlyph.CHECKMARK_CIRCLE_FILL) {
                    drawCircle(color = tint.copy(alpha = 0.16f), radius = radius, center = center)
                }
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(center.x - radius * 0.42f, center.y)
                    lineTo(center.x - radius * 0.10f, center.y + radius * 0.32f)
                    lineTo(center.x + radius * 0.46f, center.y - radius * 0.30f)
                }
                drawPath(path, tint, style = Stroke(width = stroke * 1.25f, cap = StrokeCap.Round))
            }
            BotSettlementGlyph.XMARK_CIRCLE -> {
                val a = radius * 0.38f
                drawLine(
                    tint,
                    Offset(center.x - a, center.y - a),
                    Offset(center.x + a, center.y + a),
                    strokeWidth = stroke * 1.25f,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    tint,
                    Offset(center.x + a, center.y - a),
                    Offset(center.x - a, center.y + a),
                    strokeWidth = stroke * 1.25f,
                    cap = StrokeCap.Round,
                )
            }
            BotSettlementGlyph.MINUS_CIRCLE -> {
                drawLine(
                    tint,
                    Offset(center.x - radius * 0.42f, center.y),
                    Offset(center.x + radius * 0.42f, center.y),
                    strokeWidth = stroke * 1.25f,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}

/** The 20pt gray capsule tag (`BotCardKit.swift:152-166`). */
@Composable
internal fun BotCardTag(
    text: String,
    tone: BotCardTone = BotCardTone.NEUTRAL,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val ink = botToneInk(tone)
    Box(
        modifier = modifier
            .height(BotChatMetrics.TAG_HEIGHT_PT.dp)
            .background(
                if (tone == BotCardTone.NEUTRAL) tokens.colors.userBubble else botToneWash(tone),
                RoundedCornerShape(percent = 50),
            )
            .padding(horizontal = BotChatMetrics.TAG_PAD_H_PT.dp),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = text,
            style = LocalUiType.current.tagLabel.copy(
                fontSize = BotChatMetrics.TAG_SIZE_PT.sp,
                fontWeight = FontWeight.Medium,
                color = ink,
            ),
            maxLines = 1,
        )
    }
}
