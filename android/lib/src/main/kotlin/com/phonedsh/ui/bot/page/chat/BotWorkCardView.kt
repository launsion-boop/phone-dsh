// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.rows.BotApprovalDecision
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.ui.bot.driver.BotChatSnapshot
import com.phonedsh.ui.bot.state.BotActionKeys
import com.phonedsh.ui.bot.state.BotActionState
import com.phonedsh.ui.bot.state.BotChecklistProgress
import com.phonedsh.ui.bot.state.BotUICardContent
import com.phonedsh.ui.bot.state.BotUICardKind
import com.phonedsh.ui.bot.state.BotUIChecklistItem
import com.phonedsh.ui.bot.state.BotUILink
import com.phonedsh.ui.bot.state.BotUIProgressStep
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.bot.state.JsonSupport
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.PdshContextMenu
import com.phonedsh.ui.theme.LocalUiTokens
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/**
 * Progress, checklist, link, approval, automation and notice cards
 * (`BotWorkCardView.swift:6-23`). Notices are kept for fail-closed parsing and
 * are never drawn in the Bot transcript (`bot-chat.md` §3); a host error notice
 * becomes the header problem line instead.
 */
@Composable
internal fun BotWorkCardView(
    row: BotRow,
    card: BotUICardContent,
    state: BotChatSnapshot,
    onChecklistProgress: (String, Int, Int) -> Unit,
    onChecklistSend: (String, Int, Int, String) -> Unit,
    onApproval: (String, BotApprovalDecision) -> Unit,
    onOpenUrl: (String) -> Unit,
    onInteraction: () -> Unit,
) {
    when (card.kind) {
        BotUICardKind.PROGRESS -> BotProgressCardView(row)
        BotUICardKind.CHECKLIST -> BotChecklistCardView(
            row, state, onChecklistProgress, onChecklistSend, onInteraction,
        )
        BotUICardKind.LINK -> BotLinkCardView(row, onOpenUrl)
        BotUICardKind.APPROVAL -> BotApprovalCardView(row, state, onApproval, onInteraction)
        BotUICardKind.AUTOMATION -> BotAutomationCardView(row)
        BotUICardKind.NOTICE -> Unit
        else -> Unit
    }
}

// MARK: - Progress

@Composable
private fun BotProgressCardView(row: BotRow) {
    val tokens = LocalUiTokens.current
    var expanded by remember(row.id, row.updatedSeq) { mutableStateOf(false) }
    val title = firstString(row.body, "title", "name") ?: ""
    val state = JsonSupport.string(row.body["state"])
        ?.takeIf { it in setOf("running", "done", "paused", "failed", "cancelled") }
        ?: "running"
    val steps = BotUIProgressStep.parseList(row.body["steps"])
    val percent = when {
        state == "done" -> 100
        JsonSupport.long(row.body["percent"]) != null ->
            JsonSupport.long(row.body["percent"])!!.coerceIn(0, 100).toInt()
        steps.isNotEmpty() -> (
            steps.count { BotCardStepState.from(it.state) == BotCardStepState.DONE }.toDouble() /
                steps.size * 100
            ).roundToInt()
        else -> null
    }
    val stateTag = when (state) {
        "done" -> "已完成" to BotCardTone.SUCCESS
        "paused" -> "已暂停" to BotCardTone.NEUTRAL
        "failed" -> "失败" to BotCardTone.DANGER
        "cancelled" -> "已取消" to BotCardTone.NEUTRAL
        else -> "进行中" to BotCardTone.NEUTRAL
    }
    BotCardSurface(modifier = Modifier.alpha(if (state == "cancelled") 0.72f else 1f)) {
        Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.BLOCK_GAP_PT.dp)) {
            BotCardHeading(
                icon = PdshIcon.GAUGE,
                eyebrow = "进度",
                title = title,
                detail = firstString(row.body, "summary", "description"),
                trailing = { BotCardTag(stateTag.first, stateTag.second) },
            )
            if (percent != null) {
                BotCardProgressBar(
                    percent = percent,
                    ink = if (state == "failed") tokens.colors.pageDanger else tokens.colors.textPrimary,
                )
            }
            if (steps.isNotEmpty()) {
                Column {
                    val visible = if (expanded) steps else steps.take(4)
                    visible.forEachIndexed { index, step ->
                        if (index > 0) {
                            BotCardDivider(inset = BotChatMetrics.GLYPH_COLUMN_PT + 12f)
                        }
                        val stepState = BotCardStepState.from(step.state)
                        BotCardRow(
                            label = step.label,
                            labelInk = if (stepState == BotCardStepState.PENDING) {
                                tokens.colors.textSecondary
                            } else {
                                tokens.colors.textPrimary
                            },
                            strikethrough = stepState == BotCardStepState.SKIPPED,
                            leading = { BotCardGlyph(stepState.icon, stepInk(stepState)) },
                            trailing = {
                                if (step.detail != null) {
                                    BasicText(
                                        text = step.detail,
                                        style = botMetaStyle().copy(
                                            color = tokens.colors.textPlaceholder),
                                        maxLines = 1,
                                    )
                                }
                            },
                        )
                    }
                }
                if (steps.size > 4) {
                    BotPlainTextButton(
                        label = if (expanded) BotChatCopy.COLLAPSE
                        else BotChatCopy.PROGRESS_MORE.replace("{count}", "${steps.size}"),
                        onClick = { expanded = !expanded },
                        tag = BotChatTags.PROGRESS_MORE,
                        content = {
                            BasicText(
                                text = if (expanded) BotChatCopy.COLLAPSE
                                else BotChatCopy.PROGRESS_MORE.replace("{count}", "${steps.size}"),
                                style = botRowStyle(FontWeight.Medium).copy(
                                    color = tokens.colors.textPrimary),
                            )
                        },
                    )
                }
            }
            JsonSupport.string(row.body["eta"])?.let { eta ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
                ) {
                    PdshIconView(PdshIcon.CLOCK, BotChatMetrics.GAP_12_PT.dp, tokens.colors.textPlaceholder, null)
                    BasicText(
                        text = eta,
                        style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                    )
                }
            }
        }
    }
}

// MARK: - Checklist

@Composable
private fun BotChecklistCardView(
    row: BotRow,
    state: BotChatSnapshot,
    onChecklistProgress: (String, Int, Int) -> Unit,
    onChecklistSend: (String, Int, Int, String) -> Unit,
    onInteraction: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val initial = BotUIChecklistItem.parseList(row.body["items"])
    var items by remember(row.id, row.updatedSeq) { mutableStateOf(initial) }
    var dirty by remember(row.id, row.updatedSeq) { mutableStateOf(false) }
    val interactive = JsonSupport.bool(row.body["interactive"]) != false
    val title = JsonSupport.string(row.body["title"]) ?: ""
    val doneCount = items.count { it.done }
    val progress: BotChecklistProgress? = state.checklistProgress[row.id]
    val sending = progress?.sending == true
    val sent = progress?.sent == true

    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = PdshIcon.CHECK,
                eyebrow = "检查清单",
                title = title,
                detail = JsonSupport.string(row.body["summary"]),
                trailing = {
                    BasicText(
                        text = "$doneCount/${items.size}",
                        style = botMetaStyle().copy(
                            color = if (doneCount == items.size) {
                                tokens.colors.homeSuccess
                            } else {
                                tokens.colors.textPlaceholder
                            },
                        ),
                    )
                },
            )
            Spacer(Modifier.height(BotChatMetrics.GAP_4_PT.dp))
            items.forEachIndexed { index, item ->
                if (index > 0) {
                    BotCardDivider(inset = BotChatMetrics.GLYPH_COLUMN_PT + 12f)
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = BotChatMetrics.ROW_MIN_HEIGHT_PT.dp)
                        .clickable(
                            enabled = interactive && !item.synthetic && !sending,
                            role = Role.Checkbox,
                        ) {
                            items = items.toMutableList().also { list ->
                                list[index] = item.copy(done = !item.done)
                            }
                            dirty = true
                            onChecklistProgress(row.id, items.count { it.done }, items.size)
                            onInteraction()
                        }
                        .semantics {
                            contentDescription = item.text
                            stateDescription = if (item.done) "已完成" else "未完成"
                        }
                        .testTag(BotChatTags.checklistItem(item.id)),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
                ) {
                    Box(
                        Modifier.width(BotChatMetrics.GLYPH_COLUMN_PT.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        PdshIconView(
                            if (item.done) PdshIcon.CHECK else PdshIcon.READ,
                            BotChatMetrics.ICON_17_PT.dp,
                            if (item.done) tokens.colors.textPrimary else tokens.colors.iconMuted,
                            null,
                        )
                    }
                    BasicText(
                        text = item.text,
                        style = botRowStyle().copy(
                            color = if (item.done) tokens.colors.textPlaceholder
                            else tokens.colors.textPrimary,
                            textDecoration = if (item.done) {
                                androidx.compose.ui.text.style.TextDecoration.LineThrough
                            } else {
                                null
                            },
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    if (item.note != null) {
                        BasicText(
                            text = item.note,
                            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                            maxLines = 1,
                        )
                    }
                }
            }
            if (interactive && dirty) {
                Spacer(Modifier.height(BotChatMetrics.BLOCK_GAP_PT.dp))
                BotCardButton(
                    label = if (sent || sending) BotChatCopy.CHECKLIST_SENT
                    else BotChatCopy.CHECKLIST_SEND,
                    kind = BotCardButtonKind.SECONDARY,
                    enabled = !sent && !sending,
                    tag = BotChatTags.CHECKLIST_SEND,
                    onClick = {
                        if (sent || sending) return@BotCardButton
                        onChecklistSend(row.id, doneCount, items.size, checklistMessage(title, items))
                    },
                )
            }
        }
    }
}

private fun checklistMessage(title: String, items: List<BotUIChecklistItem>): String {
    val pending = items.filter { !it.done && !it.synthetic }.map { it.text }
    val head = "$title：已完成 ${items.count { it.done }}／${items.size}。"
    return if (pending.isEmpty()) "${head}全部完成。" else "${head}未完成：${pending.joinToString("、")}"
}

// MARK: - Links

@Composable
private fun BotLinkCardView(row: BotRow, onOpenUrl: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val clipboard = LocalClipboardManager.current
    val links = BotUILink.parseList(row.body["links"])
    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            BotCardHeading(
                icon = PdshIcon.GLOBE,
                eyebrow = "参考链接",
                title = JsonSupport.string(row.body["title"]),
            )
            Spacer(Modifier.height(BotChatMetrics.GAP_4_PT.dp))
            links.forEachIndexed { index, link ->
                if (index > 0) {
                    BotCardDivider(inset = BotChatMetrics.TILE_PT + 12f)
                }
                PdshContextMenu(
                    surfaceId = "botLink",
                    state = ContextMenuRowState.unconditional,
                    onClick = { onOpenUrl(link.url) },
                    onAction = { item ->
                        when (item.label) {
                            "打开链接" -> onOpenUrl(link.url)
                            "复制链接" -> clipboard.setText(AnnotatedString(link.url))
                        }
                    },
                    modifier = Modifier.testTag(BotChatTags.linkOpen(link.id)),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .defaultMinSize(minHeight = BotChatMetrics.LINK_ROW_MIN_PT.dp)
                            .padding(vertical = BotChatMetrics.GAP_10_PT.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
                    ) {
                        BotCardTile(linkIcon(link.kind))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_2_PT.dp)) {
                            BasicText(
                                text = link.title,
                                style = botRowStyle(FontWeight.Medium).copy(
                                    color = tokens.colors.textPrimary),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            BasicText(
                                text = listOfNotNull(link.site, link.description)
                                    .joinToString(" · "),
                                style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        PdshIconView(
                            PdshIcon.CHEVRON_RIGHT, BotChatMetrics.LINK_ICON_PT.dp,
                            tokens.colors.iconMuted, null,
                        )
                    }
                }
            }
        }
    }
}

private fun linkIcon(kind: String): PdshIcon = when (kind) {
    "doc" -> PdshIcon.DOCUMENT
    "repo" -> PdshIcon.TERMINAL
    "article" -> PdshIcon.TEXT_ALIGN_LEFT
    "video" -> PdshIcon.CHAT_BUBBLE
    "tool" -> PdshIcon.GAUGE
    else -> PdshIcon.GLOBE
}

// MARK: - Approval

@Composable
private fun BotApprovalCardView(
    row: BotRow,
    state: BotChatSnapshot,
    onApproval: (String, BotApprovalDecision) -> Unit,
    onInteraction: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val clipboard = LocalClipboardManager.current
    var expanded by remember(row.id) { mutableStateOf(false) }
    var copied by remember(row.id) { mutableStateOf(false) }
    val ask = (row.body["ask"] as? JsonObject)?.members ?: emptyMap()
    val status = JsonSupport.string(row.body["status"])
        ?: JsonSupport.string(ask["status"])
        ?: "pending"
    val action = firstString(row.body, "action", "title", "text")
        ?: JsonSupport.string(ask["action"])
        ?: BotChatCopy.APPROVAL_FALLBACK_ACTION
    val command = firstString(row.body, "command", "target")
        ?: JsonSupport.string(ask["target"])
        ?: ""
    val detail = JsonSupport.string(row.body["detail"])
    val scope = firstString(row.body, "alwaysScope")
        ?: JsonSupport.string(ask["alwaysScope"])
        ?: "until"
    val key = BotActionKeys.approval(row.id)
    val busy = state.actionStates[key] is BotActionState.Pending
    val failed = state.actionStates[key] as? BotActionState.Failed
    val risk = (row.body["risk"] as? JsonObject)?.members
    val highRisk = JsonSupport.string(risk?.get("level")) == "high" ||
        (risk?.get("tags") as? JsonArray)?.values?.any {
            JsonSupport.string(it) == "irreversible"
        } == true
    val longCommand = command.length > BotChatMetrics.COMMAND_LONG_CHARS ||
        command.count { it == '\n' } > BotChatMetrics.COMMAND_LONG_LINES

    if (status != "pending") {
        // A decided approval is a settlement line (`BotSettlementRules`); this
        // branch is only reached if the row does not parse as a settled card.
        BotCardSurface {
            BotCardRow(
                label = status,
                detail = if (command.isEmpty()) action else command,
                leading = {
                    BotCardGlyph(
                        if (status == "allowed" || status == "always") PdshIcon.CHECK
                        else PdshIcon.CLOSE,
                        if (status == "allowed" || status == "always") {
                            tokens.colors.homeSuccess
                        } else {
                            tokens.colors.textPlaceholder
                        },
                    )
                },
            )
        }
        return
    }

    BotCardSurface {
        Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.BLOCK_GAP_PT.dp)) {
            BotCardHeading(
                icon = PdshIcon.LOCK_SHIELD,
                eyebrow = "需要你确认",
                title = JsonSupport.string(row.body["title"]) ?: BotChatCopy.APPROVAL_TITLE,
                detail = action,
                trailing = {
                    if (highRisk) BotCardTag(BotChatCopy.APPROVAL_HIGH_RISK, BotCardTone.DANGER)
                },
            )
            if (command.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            tokens.colors.page,
                            RoundedCornerShape(BotChatMetrics.COMMAND_RADIUS_PT.dp),
                        )
                        .padding(BotChatMetrics.COMMAND_PAD_PT.dp),
                    verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_6_PT.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BasicText(
                            text = BotChatCopy.APPROVAL_COMMAND,
                            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                        )
                        Spacer(Modifier.weight(1f))
                        BotPlainTextButton(
                            label = if (copied) BotChatCopy.APPROVAL_COPIED
                            else BotChatCopy.APPROVAL_COPY,
                            onClick = {
                                clipboard.setText(AnnotatedString(command))
                                copied = true
                            },
                            tag = BotChatTags.APPROVAL_COPY,
                            content = {
                                BasicText(
                                    text = if (copied) BotChatCopy.APPROVAL_COPIED
                                    else BotChatCopy.APPROVAL_COPY,
                                    style = botRowStyle(FontWeight.Medium).copy(
                                        fontSize = BotChatMetrics.COMMAND_SIZE_PT.sp,
                                        color = tokens.colors.textPrimary,
                                    ),
                                )
                            },
                        )
                    }
                    if (expanded && longCommand) {
                        Box(
                            Modifier
                                .heightIn(max = BotChatMetrics.COMMAND_MAX_HEIGHT_PT.dp)
                                .verticalScroll(rememberScrollState()),
                        ) {
                            Text(
                                text = command,
                                style = botCommandStyle().copy(color = tokens.colors.textPrimary),
                            )
                        }
                    } else {
                        Text(
                            text = command,
                            style = botCommandStyle().copy(color = tokens.colors.textPrimary),
                            maxLines = if (longCommand) BotChatMetrics.COMMAND_LONG_LINES
                            else Int.MAX_VALUE,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (longCommand) {
                        BotPlainTextButton(
                            label = if (expanded) BotChatCopy.COLLAPSE
                            else BotChatCopy.APPROVAL_EXPAND_ALL,
                            onClick = { expanded = !expanded },
                            tag = BotChatTags.APPROVAL_EXPAND,
                            content = {
                                BasicText(
                                    text = if (expanded) BotChatCopy.COLLAPSE
                                    else BotChatCopy.APPROVAL_EXPAND_ALL,
                                    style = botRowStyle(FontWeight.Medium).copy(
                                        fontSize = BotChatMetrics.COMMAND_SIZE_PT.sp,
                                        color = tokens.colors.textPrimary,
                                    ),
                                )
                            },
                        )
                    }
                }
            }
            if (!detail.isNullOrEmpty()) {
                BasicText(
                    text = detail,
                    style = botBodyStyle().copy(color = tokens.colors.textSecondary),
                )
            }
            if (JsonSupport.bool(row.body["persistent"]) == true) {
                BasicText(
                    text = BotChatCopy.APPROVAL_PERSISTENT,
                    style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                    modifier = Modifier.testTag(BotChatTags.APPROVAL_PERSISTENT),
                )
            }
            if (failed != null) {
                BasicText(
                    text = BotChatCopy.ACTION_FAILED.replace("{reason}", failed.reason),
                    style = botMetaStyle().copy(color = tokens.colors.pageDanger),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_8_PT.dp)) {
                BotCardButton(
                    label = BotChatCopy.APPROVAL_ONCE,
                    kind = BotCardButtonKind.PRIMARY,
                    enabled = !busy,
                    tag = BotChatTags.APPROVAL_ONCE,
                    onClick = {
                        onInteraction()
                        onApproval(row.id, BotApprovalDecision.ALLOW_ONCE)
                    },
                )
                if (scope != "none") {
                    BotCardButton(
                        label = if (scope == "session") BotChatCopy.APPROVAL_SESSION
                        else BotChatCopy.APPROVAL_ALWAYS,
                        kind = BotCardButtonKind.SECONDARY,
                        enabled = !busy,
                        tag = BotChatTags.APPROVAL_ALWAYS,
                        onClick = {
                            onInteraction()
                            onApproval(row.id, BotApprovalDecision.ALWAYS)
                        },
                    )
                }
                BotCardButton(
                    label = BotChatCopy.APPROVAL_DENY,
                    kind = BotCardButtonKind.PLAIN,
                    enabled = !busy,
                    tag = BotChatTags.APPROVAL_DENY,
                    onClick = {
                        onInteraction()
                        onApproval(row.id, BotApprovalDecision.DENY)
                    },
                )
            }
        }
    }
}

// MARK: - Routine

@Composable
private fun BotAutomationCardView(row: BotRow) {
    val tokens = LocalUiTokens.current
    val automation = (row.body["automation"] as? JsonObject)?.members ?: emptyMap()
    val status = firstString(row.body, "status")
        ?: JsonSupport.string(automation["status"])
        ?: "sent"
    val stateTag = when (status) {
        "running" -> "执行中" to BotCardTone.NEUTRAL
        "confirming" -> "待确认" to BotCardTone.NEUTRAL
        "failed" -> "失败" to BotCardTone.DANGER
        "idle" -> "待执行" to BotCardTone.NEUTRAL
        else -> "已完成" to BotCardTone.SUCCESS
    }
    val name = firstString(row.body, "title", "name", "automationId")
        ?: firstString(automation, "name", "automationId")
        ?: ""
    val schedule = firstString(row.body, "schedule") ?: JsonSupport.string(automation["schedule"])
    val timezone = firstString(row.body, "timezone") ?: JsonSupport.string(automation["timezone"])
    val context = firstString(row.body, "context") ?: JsonSupport.string(automation["context"])
    val quiet = JsonSupport.bool(row.body["quiet"])
        ?: JsonSupport.bool(automation["quiet"])
        ?: false
    val urgent = JsonSupport.bool(row.body["urgent"])
        ?: JsonSupport.bool(automation["urgent"])
        ?: false
    val meta = listOfNotNull(
        schedule?.takeIf { it.isNotEmpty() },
        timezone?.takeIf { it.isNotEmpty() }?.let(::routineTimeZone),
    ).joinToString(" · ").ifEmpty { null }
    val contextText = context?.let(::routineAutomationContext)
    val result = firstString(row.body, "text", "result") ?: JsonSupport.string(automation["message"])
    val durationMs = JsonSupport.long(row.body["durationMs"])
        ?: JsonSupport.long(automation["durationMs"])
    val duration = durationMs?.takeIf { it > 0 }?.let {
        val seconds = it / 1000.0
        BotChatCopy.AUTOMATION_DURATION.replace(
            "{seconds}",
            if (it < 10_000) String.format("%.1f", seconds) else String.format("%.0f", seconds),
        )
    }

    BotCardSurface(modifier = Modifier.testTag(BotChatTags.CARD_AUTOMATION)) {
        Column(verticalArrangement = Arrangement.spacedBy(BotChatMetrics.BLOCK_GAP_PT.dp)) {
            BotCardHeading(
                icon = PdshIcon.REFRESH,
                eyebrow = "例行任务",
                title = name,
                detail = meta,
                trailing = {
                    Row(horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_4_PT.dp)) {
                        if (urgent) BotCardTag(BotChatCopy.AUTOMATION_URGENT, BotCardTone.WARNING)
                        if (quiet) BotCardTag(BotChatCopy.AUTOMATION_QUIET)
                        BotCardTag(stateTag.first, stateTag.second)
                    }
                },
            )
            if (!contextText.isNullOrEmpty()) {
                BasicText(
                    text = contextText,
                    style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                )
            }
            if (result != null || duration != null) {
                BotCardDivider()
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(BotChatMetrics.GAP_12_PT.dp),
                ) {
                    BasicText(
                        text = result ?: stateTag.first,
                        style = botRowStyle().copy(
                            color = if (status == "failed") tokens.colors.pageDanger
                            else tokens.colors.textPrimary,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    if (duration != null) {
                        BasicText(
                            text = duration,
                            style = botMetaStyle().copy(color = tokens.colors.textPlaceholder),
                        )
                    }
                }
            }
        }
    }
}

/** `BotUIFormat.routineTimeZone` (`BotUIFormat.swift:371-400`). */
internal fun routineTimeZone(rawValue: String): String {
    val identifier = rawValue.trim()
    if (identifier.isEmpty()) return "未知"
    val zone = runCatching { ZoneId.of(identifier) }.getOrNull() ?: return "未知"
    val city = when (identifier.lowercase()) {
        "asia/shanghai", "prc", "asia/chongqing", "asia/harbin" -> "上海时间"
        "asia/tokyo", "japan" -> "东京时间"
        "asia/seoul", "rok" -> "首尔时间"
        "asia/singapore" -> "新加坡时间"
        "asia/hong_kong", "hongkong" -> "香港时间"
        "asia/taipei" -> "台北时间"
        "asia/macau" -> "澳门时间"
        "asia/bangkok" -> "曼谷时间"
        "asia/jakarta" -> "雅加达时间"
        "asia/kolkata", "asia/calcutta" -> "印度时间"
        "asia/dubai" -> "迪拜时间"
        "europe/london", "gb" -> "伦敦时间"
        "europe/paris" -> "巴黎时间"
        "europe/berlin" -> "柏林时间"
        "america/new_york" -> "纽约时间"
        "america/los_angeles" -> "洛杉矶时间"
        "australia/sydney" -> "悉尼时间"
        "utc", "gmt", "etc/utc", "etc/gmt" -> "协调世界时"
        else -> if (identifier == ZoneId.systemDefault().id) "当前时区" else ""
    }
    val offsetSeconds = zone.rules.getOffset(ZonedDateTime.now(zone).toInstant()).totalSeconds
    val sign = if (offsetSeconds < 0) "-" else "+"
    val magnitude = kotlin.math.abs(offsetSeconds)
    val hours = magnitude / 3_600
    val minutes = (magnitude % 3_600) / 60
    val offset = if (minutes == 0) "UTC$sign$hours"
    else "UTC$sign$hours:${minutes.toString().padStart(2, '0')}"
    return if (city.isEmpty()) "$offset 时区" else "$city（$offset）"
}

/** `BotUIFormat.routineAutomationContext` (`BotUIFormat.swift:519-530`). */
internal fun routineAutomationContext(rawValue: String): String? {
    val value = rawValue.trim()
    if (value.isEmpty()) return null
    val rawDeliveryTokens = setOf(
        "held", "interrupt", "queued", "存入待处理", "立即打断", "立即提醒", "下次聊天时送达",
    )
    val parts = value.split('·')
        .map { it.trim() }
        .filter { it.isNotEmpty() && it.lowercase() !in rawDeliveryTokens }
    return if (parts.isEmpty()) null else parts.joinToString("；")
}
