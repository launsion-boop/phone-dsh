// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
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
            BotUICardKind.ATTACHMENT -> BotAttachmentCardView(row, onOpenPath, onOpenDocument)
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
    val prompt = if (isSteps) null else firstString(card.body, "question", "prompt")
    val help = if (isSteps) null else firstString(card.body, "helpText", "help")
    val muted = row.id in state.mutedCardIDs
    val answered = JsonSupport.string(card.body["status"]) == "answered"
    val actionState = state.actionStates[key]
    val accepted = actionState is BotActionState.Accepted
    val locked = answered || muted || actionState is BotActionState.Pending || accepted
    val canDismiss = !isSteps && JsonSupport.bool(card.body["dismissible"]) != false

    BotCardSurface(accentTone = BotCardTone.CHOICE) {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = if (isSteps) PdshIcon.SPARKLE else PdshIcon.INFO,
                iconTint = botToneInk(BotCardTone.CHOICE),
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
                        if (!isSteps && choice.description != null && choice.description.isNotEmpty()) {
                            BasicText(
                                text = choice.description,
                                style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            )
                        }
                    }
                    if (choice.recommended) BotCardTag(BotChatCopy.RECOMMENDED, BotCardTone.CHOICE)
                    PdshIconView(PdshIcon.CHEVRON_RIGHT, BotChatMetrics.ICON_13_PT.dp, tokens.colors.iconMuted, null)
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

    BotCardSurface(accentTone = BotCardTone.WORK) {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = PdshIcon.LIST,
                iconTint = botToneInk(BotCardTone.WORK),
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
private fun BotAttachmentCardView(
    row: BotRow,
    onOpenPath: (String) -> Unit,
    onOpenDocument: (BotRow) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val path = JsonSupport.string(row.body["path"])
    val name = firstString(row.body, "fileName", "name")
        ?: path?.replace('\\', '/')?.split('/')?.lastOrNull()
        ?: path.orEmpty()
    val caption = firstString(row.body, "caption", "size", "description")
    val mime = JsonSupport.string(row.body["mimeType"])
    if (isDocumentPreviewFile(name, mime)) {
        BotDocumentArtifactCard(
            title = firstString(row.body, "title", "name", "fileName") ?: name,
            fileName = name,
            typeLabel = fileTypeLabel(name, mime),
            summary = firstString(row.body, "summary", "description", "caption"),
            content = firstString(row.body, "content", "markdown"),
            toc = parseDocumentToc(row),
            size = firstString(row.body, "size", "fileSize"),
            icon = BotCardFileIcon.icon(name, mime),
            onOpen = {
                if (!path.isNullOrBlank()) onOpenPath(path) else onOpenDocument(row)
            },
            testTag = BotChatTags.ATTACHMENT_OPEN,
        )
        return
    }
    // Images, audio, video and archives retain the compact attachment row.
    BotCardSurface(accentTone = BotCardTone.WORK, modifier = Modifier
        .clickable(enabled = !path.isNullOrBlank(), role = Role.Button) { path?.let(onOpenPath) }
        .semantics { contentDescription = "打开附件：$name" }
        .testTag(BotChatTags.ATTACHMENT_OPEN)) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp)) {
            BotCardTile(BotCardFileIcon.icon(name, mime))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                BasicText(name, style = botRowStyle(FontWeight.Medium).copy(color = tokens.colors.textPrimary),
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (!caption.isNullOrEmpty() && caption != name) {
                    BasicText(caption, style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            PdshIconView(PdshIcon.CHEVRON_RIGHT, BotChatMetrics.ICON_13_PT.dp, tokens.colors.iconMuted, null)
        }
    }
}

// MARK: - Document

@Composable
private fun BotDocumentCardView(row: BotRow, onOpenDocument: (BotRow) -> Unit) {
    val path = firstString(row.body, "path", "url")
    val title = firstString(row.body, "title", "name", "fileName")
        ?: path?.replace('\\', '/')?.split('/')?.lastOrNull()
        ?: JsonSupport.string(row.body["summary"])
        ?: ""
    val summary = firstString(row.body, "summary", "description", "caption")
    val content = firstString(row.body, "content", "markdown")
    val fileName = JsonSupport.string(row.body["fileName"]) ?: title
    val typeLabel = firstString(row.body, "docTypeLabel", "kindLabel")
        ?: fileTypeLabel(fileName, null, JsonSupport.string(row.body["docKind"]))
    BotDocumentArtifactCard(
        title = title,
        fileName = fileName,
        typeLabel = typeLabel,
        summary = summary,
        content = content,
        toc = parseDocumentToc(row),
        size = JsonSupport.string(row.body["size"]),
        icon = BotCardFileIcon.icon(fileName, null),
        onOpen = { onOpenDocument(row) },
        testTag = BotChatTags.DOCUMENT_OPEN,
    )
}

@Composable
private fun BotDocumentArtifactCard(
    title: String,
    fileName: String,
    typeLabel: String,
    summary: String?,
    content: String?,
    toc: List<String>,
    size: String?,
    icon: PdshIcon,
    onOpen: () -> Unit,
    testTag: String,
) {
    val tokens = LocalUiTokens.current
    BotCardSurface(
        accentTone = BotCardTone.DOCUMENT,
        modifier = Modifier.clickable(role = Role.Button, onClick = onOpen)
            .semantics { contentDescription = "打开文件：$fileName" }.testTag(testTag),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.BLOCK_GAP_PT.dp)) {
            BasicText(title, style = botTitleStyle().copy(color = tokens.colors.textPrimary),
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            summary?.takeIf { it.isNotBlank() }?.let {
                BasicText(it, style = botBodyStyle().copy(color = tokens.colors.textSecondary),
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            content?.takeIf { it.isNotBlank() }?.let { rawPreview ->
                val preview = rawPreview.take(1_800).let {
                    if (rawPreview.length > 1_800) "$it…" else it
                }
                Box {
                    BasicText(preview, style = botBodyStyle().copy(color = tokens.colors.textSecondary),
                        maxLines = 5, overflow = TextOverflow.Ellipsis)
                    Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(14.dp)
                        .background(androidx.compose.ui.graphics.Brush.verticalGradient(
                            listOf(Color.Transparent, tokens.colors.surface))))
                }
            } ?: if (toc.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_4_PT.dp)) {
                    toc.take(4).forEachIndexed { index, line ->
                        Row(verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp)) {
                            BasicText("${index + 1}", style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                                modifier = Modifier.width(BotChatMetrics.GAP_14_PT.dp))
                            BasicText(line, style = botRowStyle().copy(color = tokens.colors.textPrimary),
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            } else {
                BasicText("暂无内容预览", style = botMetaStyle().copy(color = tokens.colors.textPlaceholder))
            }
            BotCardDivider()
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp)) {
                BotCardTile(icon)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                    BasicText(fileName, style = botRowStyle(FontWeight.Medium).copy(color = tokens.colors.textPrimary),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    size?.let {
                        BasicText(it, style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                BotCardTag(typeLabel, BotCardTone.DOCUMENT)
                PdshIconView(PdshIcon.CHEVRON_RIGHT, BotChatMetrics.ICON_13_PT.dp, tokens.colors.iconMuted, null)
            }
        }
    }
}

private fun parseDocumentToc(row: BotRow): List<String> =
    ((row.body["toc"] as? com.phonedsh.agentcore.JsonArray)?.values ?: emptyList())
        .take(6)
        .mapNotNull { item -> JsonSupport.string(item) ?: (item as? JsonObject)?.let {
            firstString(it.members, "title", "label", "text")
        } }

private fun isDocumentPreviewFile(name: String, mime: String?): Boolean {
    val ext = name.substringAfterLast('.', "").lowercase()
    return ext in setOf("pdf", "md", "markdown", "html", "htm", "txt", "doc", "docx", "rtf",
        "json", "csv", "tsv", "xml", "yaml", "yml") ||
        mime?.let { it.contains("pdf") || it.startsWith("text/") || it.contains("wordprocessingml") ||
            it.contains("msword") || it.contains("json") || it.contains("csv") } == true
}

private fun fileTypeLabel(name: String, mime: String?, kind: String? = null): String {
    when (kind?.lowercase()) {
        "markdown" -> return "Markdown"
        "pdf" -> return "PDF"
        "table", "csv" -> return "表格"
        "code" -> return "代码"
        "document" -> return "文档"
        "library" -> return "文件库"
    }
    return when (name.substringAfterLast('.', "").lowercase()) {
        "pdf" -> "PDF"
        "md", "markdown" -> "Markdown"
        "html", "htm" -> "HTML"
        "txt" -> "TXT"
        "doc", "docx" -> "Word"
        "rtf" -> "RTF"
        "json" -> "JSON"
        "csv" -> "CSV"
        "tsv" -> "TSV"
        "xml" -> "XML"
        "yaml", "yml" -> "YAML"
        else -> mime?.substringAfter('/') ?: "文档"
    }
}

/** First non-empty string member of a row body. */
internal fun firstString(body: BotRowBody, vararg keys: String): String? =
    JsonSupport.firstString(body.additionalProperties, *keys)

/** First non-empty string member of a raw JSON object. */
internal fun firstString(members: Map<String, JsonValue>, vararg keys: String): String? =
    JsonSupport.firstString(members, *keys)
