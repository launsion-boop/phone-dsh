// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.bot.state.BotCardSettlement
import com.phonedsh.ui.bot.state.BotSettlementTone
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The shared 86%/80% column rule (`BotCardKit.swift:87-120`). */
@Composable
internal fun BotContentWidth(
    ratio: Float = BotChatMetrics.CONTENT_WIDTH_RATIO,
    trailing: Boolean = false,
    content: @Composable () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val cap = maxWidth * ratio
        Box(
            modifier = Modifier.fillMaxWidth(),
            contentAlignment = if (trailing) Alignment.CenterEnd else Alignment.CenterStart,
        ) {
            Box(Modifier.widthIn(max = cap)) { content() }
        }
    }
}

/** The white r16 list card with a 1pt hairline (`BotCardKit.swift:122-136`). */
@Composable
internal fun BotCardSurface(
    modifier: Modifier = Modifier,
    accentTone: BotCardTone? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val shape = RoundedCornerShape(BotChatMetrics.CARD_RADIUS_PT.dp)
    val cardModifier = modifier
        .clip(shape)
        .background(tokens.colors.surface)
        .then(
            if (accentTone == null) Modifier
            else Modifier.background(
                Brush.verticalGradient(listOf(botToneWash(accentTone), tokens.colors.surface)),
            ),
        )
        .border(
            width = BotChatMetrics.GAP_1_PT.dp,
            color = if (accentTone == null) tokens.colors.borderList
            else botToneInk(accentTone).copy(alpha = 0.18f).compositeOver(tokens.colors.borderList),
            shape = shape,
        )
        .padding(BotChatMetrics.CARD_PADDING_PT.dp)
    Box(
        modifier = cardModifier,
    ) {
        content()
    }
}

/**
 * Eyebrow (icon + kind + optional tag), title and detail, clamped to two lines
 * with an explicit expand control when the text actually overflows
 * (`BotCardKit.swift:168-305`).
 */
@Composable
internal fun BotCardHeading(
    icon: PdshIcon,
    eyebrow: String,
    iconTint: Color? = null,
    title: String? = null,
    detail: String? = null,
    titleLineLimit: Int = 2,
    detailLineLimit: Int = 2,
    trailing: @Composable () -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(BotChatMetrics.HEADING_GAP_PT.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = BotChatMetrics.GLYPH_COLUMN_PT.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (iconTint == null) {
                PdshIconView(icon, BotChatMetrics.EYEBROW_ICON_PT.dp, tokens.colors.textPlaceholder, null)
            } else {
                Box(
                    Modifier
                        .size(28.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(iconTint.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center,
                ) {
                    PdshIconView(icon, BotChatMetrics.EYEBROW_ICON_PT.dp, iconTint, null)
                }
            }
            Spacer(Modifier.width(BotChatMetrics.GAP_6_PT.dp))
            BasicText(
                text = eyebrow,
                style = botEyebrowStyle().copy(color = tokens.colors.textPlaceholder),
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(BotChatMetrics.GAP_8_PT.dp))
            trailing()
        }
        if (!title.isNullOrEmpty()) {
            BotExpandableText(
                text = title,
                style = botTitleStyle().copy(color = tokens.colors.textPrimary),
                lineLimit = titleLineLimit,
            )
        }
        if (!detail.isNullOrEmpty()) {
            BotExpandableText(
                text = detail,
                style = botBodyStyle().copy(color = tokens.colors.textSecondary),
                lineLimit = detailLineLimit,
            )
        }
    }
}

/** A clamped title/detail with a real overflow check. */
@Composable
internal fun BotExpandableText(
    text: String,
    style: androidx.compose.ui.text.TextStyle,
    lineLimit: Int,
    modifier: Modifier = Modifier,
) {
    var expanded by remember(text) { mutableStateOf(false) }
    var overflowed by remember(text) { mutableStateOf(false) }
    val tokens = LocalUiTokens.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
        BasicText(
            text = text,
            style = style,
            maxLines = if (expanded) Int.MAX_VALUE else lineLimit,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { result -> overflowed = result.hasVisualOverflow },
        )
        if (overflowed || expanded) {
            Row(
                modifier = Modifier
                    .heightIn(min = BotChatMetrics.SETTLEMENT_MIN_HEIGHT_PT.dp)
                    .clickable(role = Role.Button) { expanded = !expanded }
                    .semantics {
                        stateDescription =
                            if (expanded) BotChatCopy.EXPANDED else BotChatCopy.COLLAPSED
                    }
                    .testTag(BotChatTags.HEADING_EXPAND),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = if (expanded) BotChatCopy.COLLAPSE else BotChatCopy.EXPAND,
                    style = botMetaStyle().copy(
                        color = tokens.colors.textSecondary,
                        fontWeight = FontWeight.Medium,
                    ),
                )
            }
        }
    }
}

/** 0.5pt hairline between rows (`BotCardKit.swift:307-317`). */
@Composable
internal fun BotCardDivider(inset: Float = 0f) {
    val tokens = LocalUiTokens.current
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = inset.dp)
            .height(BotChatMetrics.HAIRLINE_PT.dp)
            .background(tokens.colors.borderList),
    )
}

/** One list row inside a card (`BotCardKit.swift:319-351`). */
@Composable
internal fun BotCardRow(
    label: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    labelInk: Color? = null,
    strikethrough: Boolean = false,
    leading: @Composable () -> Unit = {},
    trailing: @Composable () -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
            .padding(vertical = BotChatMetrics.GAP_10_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
    ) {
        leading()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
            BasicText(
                text = label,
                style = botRowStyle().copy(
                    color = labelInk ?: tokens.colors.textPrimary,
                    textDecoration = if (strikethrough) TextDecoration.LineThrough else null,
                ),
            )
            if (!detail.isNullOrEmpty()) {
                BasicText(
                    text = detail,
                    style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                )
            }
        }
        trailing()
    }
}

/** A 17pt glyph centered in the 20pt row column (`BotCardKit.swift:353-365`). */
@Composable
internal fun BotCardGlyph(icon: PdshIcon, tint: Color) {
    Box(Modifier.width(BotChatMetrics.GLYPH_COLUMN_PT.dp), contentAlignment = Alignment.Center) {
        PdshIconView(icon, BotChatMetrics.ICON_17_PT.dp, tint, null)
    }
}

/** A 32pt gray tile with a 17pt glyph (`BotCardKit.swift:415-428`). */
@Composable
internal fun BotCardTile(icon: PdshIcon) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .size(BotChatMetrics.TILE_PT.dp)
            .background(
                tokens.colors.userBubble.copy(alpha = 0.7f),
                RoundedCornerShape(BotChatMetrics.GAP_10_PT.dp),
            ),
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(icon, BotChatMetrics.ICON_17_PT.dp, tokens.colors.textPrimary, null)
    }
}

/** The one grey line a handled card settles into (`BotCardKit.swift:371-404`). */
@Composable
internal fun BotCardSettledLine(settlement: BotCardSettlement, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val toneInk = when (settlement.tone) {
        BotSettlementTone.NEUTRAL -> tokens.colors.textSecondary
        BotSettlementTone.SUCCESS -> tokens.colors.homeSuccess
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = BotChatMetrics.SETTLEMENT_PAD_H_PT.dp)
            .defaultMinSize(minHeight = BotChatMetrics.SETTLEMENT_MIN_HEIGHT_PT.dp)
            .testTag(BotChatTags.CARD_SETTLED),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
    ) {
        BotSettlementIcon(settlement.glyph, toneInk.copy(alpha = 0.8f))
        val annotated: AnnotatedString = buildAnnotatedString {
            pushStyle(
                SpanStyle(
                    color = tokens.colors.textSecondary,
                    fontSize = BotChatMetrics.SETTLEMENT_TITLE_SIZE_PT.sp,
                    fontWeight = FontWeight.Medium,
                ),
            )
            append(settlement.title)
            pop()
            if (!settlement.detail.isNullOrEmpty()) {
                pushStyle(
                    SpanStyle(
                        color = tokens.colors.textTertiary,
                        fontSize = BotChatMetrics.SETTLEMENT_DETAIL_SIZE_PT.sp,
                    ),
                )
                append(BotChatCopy.SETTLEMENT_DETAIL_SEPARATOR)
                pop()
                pushStyle(
                    SpanStyle(
                        color = tokens.colors.textTertiary,
                        fontSize = if (settlement.monospacedDetail) {
                            BotChatMetrics.SETTLEMENT_MONO_SIZE_PT.sp
                        } else {
                            BotChatMetrics.SETTLEMENT_DETAIL_SIZE_PT.sp
                        },
                        fontFamily = if (settlement.monospacedDetail) FontFamily.Monospace else null,
                    ),
                )
                append(settlement.detail)
                pop()
            }
        }
        Text(
            text = annotated,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

/** The three card button levels (`BotCardKit.swift:430-471`). */
internal enum class BotCardButtonKind { PRIMARY, SECONDARY, PLAIN }

@Composable
internal fun BotCardButton(
    label: String,
    kind: BotCardButtonKind,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    enabled: Boolean = true,
    primaryColor: Color? = null,
    primaryInk: Color? = null,
) {
    val tokens = LocalUiTokens.current
    val tagged = if (tag != null) modifier.testTag(tag) else modifier
    val base = tagged.defaultMinSize(
        minWidth = if (kind == BotCardButtonKind.PLAIN) BotChatMetrics.ROW_MIN_HEIGHT_PT.dp else 0.dp,
        minHeight = BotChatMetrics.BUTTON_HEIGHT_PT.dp,
    )
    when (kind) {
        BotCardButtonKind.PRIMARY -> Row(
            modifier = base
                .fillMaxWidth()
                .height(BotChatMetrics.BUTTON_HEIGHT_PT.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background((primaryColor ?: tokens.colors.primaryButton).copy(alpha = if (enabled) 1f else 0.25f))
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = label },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = label,
                style = botRowStyle(FontWeight.SemiBold).copy(
                    color = primaryInk ?: tokens.colors.primaryButtonInk,
                ),
            )
        }
        BotCardButtonKind.SECONDARY -> Row(
            modifier = base
                .fillMaxWidth()
                .height(BotChatMetrics.BUTTON_HEIGHT_PT.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(tokens.colors.userBubble)
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = label },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = label,
                style = botRowStyle(FontWeight.SemiBold).copy(
                    color = tokens.colors.textPrimary.copy(alpha = if (enabled) 1f else 0.4f),
                ),
            )
        }
        BotCardButtonKind.PLAIN -> Row(
            modifier = base
                .height(BotChatMetrics.BUTTON_HEIGHT_PT.dp)
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = label },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = label,
                style = botRowStyle(FontWeight.Medium).copy(
                    color = tokens.colors.textPrimary.copy(alpha = if (enabled) 1f else 0.4f),
                ),
            )
        }
    }
}

/** A 4pt progress track with the percent on the right (`BotCardKit.swift:473-495`). */
@Composable
internal fun BotCardProgressBar(percent: Int, ink: Color) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = BotChatCopy.PROGRESS_PERCENT.replace("{percent}", "$percent") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.PROGRESS_GAP_PT.dp),
    ) {
        Box(
            Modifier
                .weight(1f)
                .height(BotChatMetrics.PROGRESS_TRACK_PT.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(tokens.colors.userBubble),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(percent.coerceIn(0, 100) / 100f)
                    .height(BotChatMetrics.PROGRESS_TRACK_PT.dp)
                    .clip(RoundedCornerShape(percent = 50))
                    .background(ink),
            )
        }
        BasicText(
            text = "$percent%",
            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
        )
    }
}

/** One status vocabulary for steps and tasks (`BotCardKit.swift:497-528`). */
internal enum class BotCardStepState {
    DONE,
    ACTIVE,
    PENDING,
    FAILED,
    SKIPPED;

    val icon: PdshIcon
        get() = when (this) {
            DONE -> PdshIcon.CHECK
            ACTIVE -> PdshIcon.REFRESH
            PENDING -> PdshIcon.READ
            FAILED -> PdshIcon.WARNING
            SKIPPED -> PdshIcon.CLOSE
        }

    companion object {
        fun from(raw: String): BotCardStepState = when (raw) {
            "done", "completed", "complete", "success", "ok", "sent" -> DONE
            "active", "running", "in_progress", "working" -> ACTIVE
            "failed", "error", "failure", "blocked" -> FAILED
            "skipped" -> SKIPPED
            else -> PENDING
        }
    }
}

@Composable
internal fun stepInk(state: BotCardStepState): Color {
    val tokens = LocalUiTokens.current
    return when (state) {
        BotCardStepState.DONE, BotCardStepState.ACTIVE -> tokens.colors.textPrimary
        BotCardStepState.FAILED -> tokens.colors.pageDanger
        BotCardStepState.PENDING, BotCardStepState.SKIPPED -> tokens.colors.iconMuted
    }
}

/** The file icon vocabulary (`BotCardView.swift:331-343`). */
internal object BotCardFileIcon {
    fun icon(name: String, mime: String?): PdshIcon {
        val mimeType = mime ?: ""
        val extension = name.substringAfterLast('.', "").lowercase()
        return when {
            mimeType.startsWith("image/") ||
                extension in setOf("png", "jpg", "jpeg", "gif", "heic") -> PdshIcon.INFO
            mimeType.contains("pdf") || extension == "pdf" -> PdshIcon.DOCUMENT
            mimeType.startsWith("video/") -> PdshIcon.CHAT_BUBBLE
            mimeType.startsWith("audio/") -> PdshIcon.WAVEFORM
            extension in setOf("zip", "tar", "gz") -> PdshIcon.ARCHIVE
            extension in setOf("md", "markdown", "txt") -> PdshIcon.DOCUMENT
            else -> PdshIcon.DOCUMENT
        }
    }
}
