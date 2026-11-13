// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBody
import com.phonedsh.ui.bot.driver.BotChatSnapshot
import com.phonedsh.ui.bot.state.BotActionKeys
import com.phonedsh.ui.bot.state.BotActionState
import com.phonedsh.ui.bot.state.BotCardSettlement
import com.phonedsh.ui.bot.state.BotUIChoice
import com.phonedsh.ui.bot.state.BotUICardContent
import com.phonedsh.ui.bot.state.BotUICardKind
import com.phonedsh.ui.bot.state.BotUIProgressStep
import com.phonedsh.ui.bot.state.JsonSupport
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens

/**
 * One transcript card (`BotCardView.swift:12-51`). Interactive cards collapse
 * to their model-owned settlement line once a decision exists; the card itself
 * never decides what "handled" means.
 */
@Composable
internal fun BotCardView(
    row: BotRow,
    card: BotUICardContent,
    state: BotChatSnapshot,
    onAnswer: (rowID: String, optionID: String) -> Unit,
    onDismiss: (rowID: String) -> Unit,
    onChecklistProgress: (rowID: String, done: Int, total: Int) -> Unit,
    onChecklistSend: (rowID: String, done: Int, total: Int, message: String) -> Unit,
    onApproval: (rowID: String, decision: com.phonedsh.bot.rows.BotApprovalDecision) -> Unit,
    onOpenDocument: (BotRow) -> Unit,
    onOpenPath: (String) -> Unit,
    onOpenUrl: (String) -> Unit,
    onInteraction: () -> Unit,
) {
    val settlement = state.settlements[row.id]
    if (settlement != null) {
        BotContentWidth {
            BotCardSettledLine(settlement)
        }
        return
    }
    BotContentWidth {
        when (card.kind) {
            BotUICardKind.QUESTION, BotUICardKind.STEPS -> BotChoiceCardView(
                row, card, state, onAnswer, onDismiss,
            )
            BotUICardKind.TASK -> BotTaskCardView(row)
            BotUICardKind.ATTACHMENT -> BotAttachmentCardView(row, onOpenPath)
            BotUICardKind.DOCUMENT -> BotDocumentCardView(row, onOpenDocument)
            else -> BotWorkCardView(
                row, card, state, onChecklistProgress, onChecklistSend, onApproval, onOpenUrl,
                onInteraction,
            )
        }
    }
}

// MARK: - Choice (question · steps)

@Composable
private fun BotChoiceCardView(
    row: BotRow,
    card: BotUICardContent,
    state: BotChatSnapshot,
    onAnswer: (String, String) -> Unit,
    onDismiss: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val isSteps = card.kind == BotUICardKind.STEPS
    val key = BotActionKeys.card(row.id)
    val choices = card.choices
    val prompt = firstString(card.body, "question", "prompt")
    val help = firstString(card.body, "helpText", "help")
    val muted = row.id in state.mutedCardIDs
    val answered = JsonSupport.string(card.body["status"]) == "answered"
    val actionState = state.actionStates[key]
    val accepted = actionState is BotActionState.Accepted
    val locked = answered || muted || actionState is BotActionState.Pending || accepted
    val canDismiss = !isSteps && JsonSupport.bool(card.body["dismissible"]) != false

    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = if (isSteps) PdshIcon.SPARKLE else PdshIcon.INFO,
                eyebrow = if (isSteps) "建议下一步" else "需要你选择",
                title = prompt,
                detail = help,
                trailing = {
                    if (canDismiss) {
                        Box(
                            modifier = Modifier
                                .defaultMinSize(minWidth = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp, minHeight = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
                                .clickable(enabled = !locked, role = Role.Button) {
                                    onDismiss(row.id)
                                }
                                .semantics { contentDescription = BotChatCopy.DISMISS_CARD }
                                .testTag(BotChatTags.CHOICE_DISMISS),
                            contentAlignment = Alignment.Center,
                        ) {
                            PdshIconView(PdshIcon.CLOSE, BotChatMetrics.ICON_11_PT.dp, tokens.colors.textSecondary, null)
                        }
                    }
                },
            )
            if (choices.isNotEmpty()) Spacer(Modifier.height(BotChatMetrics.GAP_4_PT.dp))
            choices.forEachIndexed { index, choice ->
                if (index > 0) BotCardDivider()
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
                        .alpha(if (muted) 0.45f else 1f)
                        .clickable(enabled = !locked, role = Role.Button) {
                            onAnswer(row.id, choice.id)
                        }
                        .semantics {
                            contentDescription =
                                if (choice.recommended) "${choice.label}，建议" else choice.label
                        }
                        .testTag(BotChatTags.choiceOption(choice.id)),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                        BasicText(
                            text = choice.label,
                            style = botRowStyle().copy(
                                color = if (choice.danger) tokens.colors.pageDanger
                                else tokens.colors.textPrimary,
                            ),
                        )
                        if (choice.description != null && choice.description.isNotEmpty()) {
                            BasicText(
                                text = choice.description,
                                style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            )
                        }
                    }
                    if (choice.recommended) {
                        BotCardTag(BotChatCopy.RECOMMENDED)
                    } else {
                        PdshIconView(PdshIcon.CHEVRON_RIGHT, BotChatMetrics.ICON_13_PT.dp, tokens.colors.iconMuted, null)
                    }
                }
            }
            statusLine(actionState, accepted, answered, muted)?.let { line ->
                Spacer(Modifier.height(BotChatMetrics.GAP_8_PT.dp))
                BasicText(
                    text = line.first,
                    style = botMetaStyle().copy(color = line.second ?: tokens.colors.textPlaceholder),
                )
            }
        }
    }
}

@Composable
private fun statusLine(
    actionState: BotActionState?,
    accepted: Boolean,
    answered: Boolean,
    muted: Boolean,
): Pair<String, Color?>? {
    val tokens = LocalUiTokens.current
    return when {
        accepted || answered -> BotUiStrings.SETTLEMENT_SENT to null
        muted -> BotUiStrings.SETTLEMENT_SKIPPED to null
        actionState is BotActionState.Failed -> BotChatCopy.ACTION_FAILED.replace(
            "{reason}", actionState.reason) to tokens.colors.pageDanger
        else -> null
    }
}

// MARK: - Task

@Composable
private fun BotTaskCardView(row: BotRow) {
    val tokens = LocalUiTokens.current
    var expanded by remember(row.id, row.updatedSeq) { mutableStateOf(false) }
    val steps = BotUIProgressStep.parseList(row.body["tasks"] ?: row.body["steps"])
    val title = firstString(row.body, "title", "text", "question") ?: BotChatCopy.TASK_TITLE_FALLBACK
    val doneCount = steps.count { BotCardStepState.from(it.state) == BotCardStepState.DONE }
    val failed = steps.any { BotCardStepState.from(it.state) == BotCardStepState.FAILED }
    val task = (row.body["task"] as? JsonObject)?.members ?: emptyMap()
    val taskStatus = JsonSupport.string(row.body["status"]) ?: JsonSupport.string(task["status"])
    val running = taskStatus == "running" ||
        steps.any { BotCardStepState.from(it.state) == BotCardStepState.ACTIVE }
    val stateTag: Pair<String, BotCardTone> = when (taskStatus) {
        "waiting_approval" -> "等待审批" to BotCardTone.WARNING
        "denied" -> "已拒绝" to BotCardTone.DANGER
        "stopped" -> "已停止" to BotCardTone.NEUTRAL
        "interrupted" -> "已中断" to BotCardTone.DANGER
        else -> when {
            failed -> "失败" to BotCardTone.DANGER
            running -> "进行中" to BotCardTone.NEUTRAL
            else -> "已完成" to BotCardTone.SUCCESS
        }
    }
    val verification = (row.body["verification"] as? JsonObject)?.members
    val verdict = JsonSupport.string(verification?.get("verdict"))
        ?.takeIf { it in setOf("passed", "failed", "uncertain") }
    val verificationTone = when (verdict) {
        "passed" -> BotCardTone.SUCCESS
        "failed" -> BotCardTone.DANGER
        else -> BotCardTone.WARNING
    }
    val verificationLabel = when (verdict) {
        "passed" -> "验证通过"
        "failed" -> "验证未通过"
        else -> "验证不确定"
    }
    val verificationSummary = JsonSupport.string(verification?.get("summary"))
    val verificationRefs = (verification?.get("refs") as? com.phonedsh.agentcore.JsonArray)?.values?.size ?: 0

    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = PdshIcon.LIST,
                eyebrow = "后台任务",
                title = title,
                trailing = { BotCardTag(stateTag.first, stateTag.second) },
            )
            if (verdict != null) {
                Column(
                    modifier = Modifier
                        .padding(top = BotChatMetrics.GAP_8_PT.dp)
                        .testTag(BotChatTags.TASK_VERIFICATION),
                    verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_3_PT.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
                    ) {
                        PdshIconView(
                            when (verdict) {
                                "passed" -> PdshIcon.CHECK
                                "failed" -> PdshIcon.CLOSE
                                else -> PdshIcon.INFO
                            },
                            BotChatMetrics.GAP_12_PT.dp,
                            botToneInk(verificationTone),
                            null,
                        )
                        BasicText(
                            text = verificationLabel,
                            style = botMetaStyle().copy(
                                color = botToneInk(verificationTone),
                                fontWeight = FontWeight.SemiBold,
                            ),
                        )
                        if (verificationRefs > 0) {
                            BasicText(
                                text = "依据 $verificationRefs 条记录",
                                style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            )
                        }
                    }
                    if (!verificationSummary.isNullOrEmpty()) {
                        BasicText(
                            text = verificationSummary,
                            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            if (steps.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .padding(top = BotChatMetrics.GAP_4_PT.dp)
                        .fillMaxWidth()
                        .height(BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
                        .clickable(role = Role.Button) { expanded = !expanded }
                        .semantics {
                            stateDescription =
                                if (expanded) BotChatCopy.EXPANDED else BotChatCopy.COLLAPSED
                        }
                        .testTag(BotChatTags.TASK_TOGGLE),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_4_PT.dp),
                ) {
                    BasicText(
                        text = if (expanded) BotChatCopy.HIDE_STEPS else BotChatCopy.SHOW_STEPS,
                        style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                    )
                    BasicText(
                        text = "$doneCount/${steps.size}",
                        style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                    )
                    PdshIconView(
                        if (expanded) PdshIcon.CHEVRON_UP else PdshIcon.CHEVRON_DOWN,
                        BotChatMetrics.ICON_11_PT.dp,
                        tokens.colors.textPlaceholder,
                        null,
                    )
                }
                if (expanded) {
                    Column(Modifier.testTag(BotChatTags.TASK_STEPS)) {
                        steps.forEachIndexed { index, step ->
                            if (index > 0) {
                                BotCardDivider(
                                    inset = BotChatMetrics.GLYPH_COLUMN_PT + 12f,
                                )
                            }
                            val stepState = BotCardStepState.from(step.state)
                            BotCardRow(
                                label = step.label,
                                detail = step.detail,
                                labelInk = if (stepState == BotCardStepState.PENDING) {
                                    tokens.colors.textSecondary
                                } else {
                                    tokens.colors.textPrimary
                                },
                                leading = { BotCardGlyph(stepState.icon, stepInk(stepState)) },
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Attachment

@Composable
private fun BotAttachmentCardView(row: BotRow, onOpenPath: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val path = JsonSupport.string(row.body["path"])
    val name = firstString(row.body, "fileName", "name")
        ?: path?.replace('\\', '/')?.split('/')?.lastOrNull()
        ?: path.orEmpty()
    val caption = firstString(row.body, "caption", "size", "description")
    BotCardSurface {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
        ) {
            BotCardTile(BotCardFileIcon.icon(name, JsonSupport.string(row.body["mimeType"])))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                BasicText(
                    text = name,
                    style = botRowStyle(FontWeight.Medium).copy(color = tokens.colors.textPrimary),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!caption.isNullOrEmpty()) {
                    BasicText(
                        text = caption,
                        style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (!path.isNullOrEmpty()) {
                BotPlainTextButton(
                    label = BotChatCopy.OPEN,
                    onClick = { onOpenPath(path) },
                    tag = BotChatTags.ATTACHMENT_OPEN,
                )
            }
        }
    }
}

// MARK: - Document

@Composable
private fun BotDocumentCardView(row: BotRow, onOpenDocument: (BotRow) -> Unit) {
    val tokens = LocalUiTokens.current
    var expanded by remember(row.id, row.updatedSeq) { mutableStateOf(false) }
    val path = firstString(row.body, "path", "url")
    val title = firstString(row.body, "title", "name", "fileName")
        ?: path?.replace('\\', '/')?.split('/')?.lastOrNull()
        ?: JsonSupport.string(row.body["summary"])
        ?: ""
    val summary = firstString(row.body, "summary", "description", "caption")
    val toc = ((row.body["toc"] as? com.phonedsh.agentcore.JsonArray)?.values ?: emptyList())
        .take(6)
        .mapNotNull { item ->
            JsonSupport.string(item)
                ?: (item as? JsonObject)?.let { firstString(it.members, "title", "label", "text") }
        }
    val typeLabel = firstString(row.body, "docTypeLabel", "kindLabel") ?: when (
        JsonSupport.string(row.body["docKind"])
    ) {
        "markdown" -> "Markdown"
        "pdf" -> "PDF"
        "code" -> "代码"
        "table" -> "表格"
        else -> "页面"
    }
    val fileName = JsonSupport.string(row.body["fileName"]) ?: title

    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.BLOCK_GAP_PT.dp)) {
            BotCardHeading(
                icon = PdshIcon.DOCUMENT,
                eyebrow = "文档 · $typeLabel",
                title = title,
                titleLineLimit = 2,
                detailLineLimit = 0,
            )
            if (!summary.isNullOrEmpty()) {
                Column(
                    modifier = Modifier.clickable(role = Role.Button) { expanded = !expanded },
                ) {
                    BasicText(
                        text = summary,
                        style = botBodyStyle().copy(color = tokens.colors.textSecondary),
                        maxLines = if (expanded) Int.MAX_VALUE else 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (!expanded) {
                        BasicText(
                            text = BotChatCopy.EXPAND,
                            style = botMetaStyle().copy(
                                color = tokens.colors.textSecondary,
                                fontWeight = FontWeight.Medium,
                            ),
                            modifier = Modifier.padding(top = BotChatMetrics.GAP_2_PT.dp),
                        )
                    }
                }
            }
            if (toc.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp)) {
                    BasicText(
                        text = BotChatCopy.DOCUMENT_CONTENTS,
                        style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                    )
                    toc.forEachIndexed { index, item ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp),
                        ) {
                            BasicText(
                                text = "${index + 1}",
                                style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                                modifier = Modifier.width(BotChatMetrics.GAP_14_PT.dp),
                            )
                            BasicText(
                                text = item,
                                style = botRowStyle().copy(color = tokens.colors.textPrimary),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
            BotCardDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
            ) {
                BotCardTile(BotCardFileIcon.icon(fileName, null))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                    BasicText(
                        text = fileName,
                        style = botRowStyle(FontWeight.Medium).copy(color = tokens.colors.textPrimary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    JsonSupport.string(row.body["size"])?.let { size ->
                        BasicText(
                            text = size,
                            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                        )
                    }
                }
                BotPlainTextButton(
                    label = BotChatCopy.OPEN,
                    onClick = { onOpenDocument(row) },
                    tag = BotChatTags.DOCUMENT_OPEN,
                )
            }
        }
    }
}

/** First non-empty string member of a row body. */
internal fun firstString(body: BotRowBody, vararg keys: String): String? =
    JsonSupport.firstString(body.additionalProperties, *keys)

/** First non-empty string member of a raw JSON object. */
internal fun firstString(members: Map<String, JsonValue>, vararg keys: String): String? =
    JsonSupport.firstString(members, *keys)
