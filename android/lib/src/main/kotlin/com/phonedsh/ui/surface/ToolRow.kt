// Signature surface 2/6 - the tool row.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "工具行" + §4 + `tokens.json`
// `signatureSurfaces.toolRow`. The row is the *fold target*: the screen state
// merges consecutive call/result rows into one row (`ChatScreenState`), while
// every UiState node stays event-anchored.
package com.phonedsh.ui.surface

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.state.ToolVariant
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** The four states the state machine can put a tool row in. */
public enum class ToolRowState {
    RUNNING,
    OK,
    ERROR,
    STOPPED,
    ;

    /** The state description announced to accessibility services. */
    public val label: String
        get() = when (this) {
            RUNNING -> UiStrings.TOOL_RUNNING
            OK -> UiStrings.TOOL_OK
            ERROR -> UiStrings.TOOL_ERROR
            STOPPED -> UiStrings.TOOL_STOPPED
        }
}

/** Active component tokens used alongside the HomeSpec process-row contract. */
public object ToolRowTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.COLORS_TEXT_TERTIARY,
        UiTokenNames.COLORS_TEXT_PLACEHOLDER,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_CODE,
        UiTokenNames.COLORS_CODE_BANNER,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_PROCESS,
        UiTokenNames.TYPOGRAPHY_LIST_ITEM,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_CODE_LABEL,
        UiTokenNames.RADIUS_CODE_BLOCK,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.MOTION_DISCLOSURE,
        UiTokenNames.MOTION_SHIMMER,
        UiTokenNames.GEOMETRY_DISCLOSURE_ICON_GAP,
        UiTokenNames.GEOMETRY_PROCESS_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_PROCESS_ICON,
        UiTokenNames.GEOMETRY_LIST_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_INDENT,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_VERTICAL,
        UiTokenNames.GEOMETRY_TOOL_CARD_INSET,
        UiTokenNames.GEOMETRY_TERMINAL_CARD_MAX_HEIGHT,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_DISCLOSURE_GAP,
    )
}

/**
 * One folded tool run.
 *
 * @param title tool name (the row's title).
 * @param summary one-line result summary.
 * @param state running / ok / error / stopped.
 * @param expanded whether the detail is open; only the screen state flips it.
 * @param onToggle expand/collapse; disabled when [detail] is `null`.
 * @param detail the expanded body; `null` means "nothing to show", which makes
 *   the toggle disabled instead of opening an empty card.
 * @param inListCard use the compact disclosure metrics for rows inside the
 *   native white list card.
 * @param categoryIcon the tool category artwork shown while collapsed.
 */
@Composable
public fun ToolRow(
    title: String,
    summary: String,
    state: ToolRowState,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    showsSummaryWhenExpanded: Boolean = false,
    detail: (@Composable () -> Unit)? = null,
    inListCard: Boolean = false,
    categoryIcon: PdshIcon = PdshIcon.SPARKLE,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canExpand = detail != null
    val showsSummary = summary.isNotEmpty() && (showsSummaryWhenExpanded || !expanded)
    val ink = if (state == ToolRowState.RUNNING || !inListCard) {
        tokens.colors.textSecondary
    } else {
        tokens.colors.textTertiary
    }
    val rowFont = if (inListCard) type.listItem else type.processBody
    val iconBoxSize = if (inListCard) ChatMetrics.DISCLOSURE_LIST_ICON_BOX_PT.dp else HomeMetrics.processIcon
    val rowHeight = if (inListCard) HomeMetrics.listRowHeight else HomeMetrics.processRowHeight
    val iconTitleGap = if (inListCard) ChatMetrics.DISCLOSURE_LIST_ICON_GAP_PT.dp
    else ChatMetrics.DISCLOSURE_ICON_GAP_PT.dp

    // PR22's NativeDisclosureRow has two source variants: 15/24 with an 18pt
    // icon box outside a list card, 14/22 with a 16pt box inside one.
    //
    // The tag sits on the merged, clickable row: a semantics assertion on
    // `TOOL_ROW` must see the title, the summary, the state and the click action.
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(rowHeight)
                .clickable(
                    enabled = canExpand,
                    role = Role.Button,
                    onClickLabel = if (expanded) UiStrings.COLLAPSED else UiStrings.EXPANDED,
                    onClick = onToggle,
                )
                .semantics(mergeDescendants = true) {
                    stateDescription = state.label
                    contentDescription = listOf(title, summary.takeIf { showsSummary }.orEmpty(), state.label)
                        .filter(String::isNotBlank)
                        .joinToString(" · ")
                }
                .testTag(UiTags.TOOL_ROW),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .size(iconBoxSize)
                    .testTag(if (canExpand && expanded) TOOL_ROW_CHEVRON_TAG else TOOL_ROW_CATEGORY_ICON_TAG),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    icon = if (canExpand && expanded) PdshIcon.CHEVRON_UP else categoryIcon,
                    size = if (canExpand && expanded) {
                        ChatMetrics.DISCLOSURE_CHEVRON_ICON_PT.dp
                    } else if (inListCard) {
                        ChatMetrics.DISCLOSURE_LIST_CATEGORY_ICON_PT.dp
                    } else {
                        ChatMetrics.DISCLOSURE_CATEGORY_ICON_PT.dp
                    },
                    tint = ink,
                    contentDescription = null,
                    modifier = Modifier.testTag(
                        if (canExpand && expanded) TOOL_ROW_CHEVRON_ART_TAG
                        else "$TOOL_ROW_CATEGORY_ICON_TAG.${categoryIcon.name.lowercase()}",
                    ),
                )
            }
            Spacer(modifier = Modifier.width(iconTitleGap))
            BasicText(
                text = title,
                style = rowFont.copy(color = ink),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (showsSummary) {
                Box(
                    modifier = Modifier
                        .padding(horizontal = 6.dp)
                        .size(2.dp)
                        .clip(CircleShape)
                        .background(tokens.colors.textPlaceholder),
                )
                if (state == ToolRowState.RUNNING) {
                    ShimmerLine(
                        text = summary,
                        style = rowFont,
                        base = ink,
                        sweep = tokens.colors.textTertiary,
                        durationMs = tokens.motion.shimmerMs,
                        easing = tokens.motion.shimmerEasing,
                        repeat = tokens.motion.shimmerRepeat,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    BasicText(
                        text = summary,
                        style = rowFont.copy(color = ink),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
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
                        start = tokens.geometry.toolDetailIndent,
                        top = tokens.geometry.toolDetailVertical,
                        bottom = tokens.geometry.toolDetailVertical,
                    )
                    .testTag(UiTags.TOOL_ROW_DETAIL),
            ) {
                detail?.invoke()
            }
        }
    }
}

/**
 * The expanded body of a tool row: a banner line plus a height-bounded,
 * vertically scrollable monospace card (`geometry.terminalCardMaxHeight`).
 */
@Composable
public fun ToolDetailCard(
    banner: String,
    body: String,
    modifier: Modifier = Modifier,
    variant: ToolVariant = ToolVariant.GENERIC,
    arguments: JsonObject? = null,
    metadata: JsonObject? = null,
    isError: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(tokens.radius.codeBlock))
            .background(tokens.colors.code)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.codeBlock),
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.colors.codeBanner)
                .padding(horizontal = tokens.geometry.toolCardInset, vertical = tokens.geometry.toolDetailVertical),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
        ) {
            BasicText(
                text = toolDisplayTitle(banner),
                style = type.codeLabel.copy(color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        val command = arguments.text("command") ?: arguments.text("script")
        val plan = arguments.text("plan")
        val oldText = arguments.text("old_string") ?: arguments.text("old_str")
        val newText = arguments.text("new_string") ?: arguments.text("new_str")
            ?: arguments.text("content") ?: arguments.text("file_text")
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = tokens.geometry.terminalCardMaxHeight)
                .verticalScroll(rememberScrollState())
                .padding(tokens.geometry.toolCardInset),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            when (variant) {
                ToolVariant.BASH -> if (!command.isNullOrEmpty()) {
                    BasicText(text = "\$ $command", style = type.code.copy(color = tokens.colors.primary))
                }

                ToolVariant.EDIT, ToolVariant.WRITE -> if (newText != null) {
                    if (oldText != null) {
                        DiffLine(text = oldText, added = false)
                    }
                    DiffLine(text = newText, added = true)
                }

                ToolVariant.PLAN -> if (!plan.isNullOrBlank()) {
                    MarkdownBody(markdown = plan)
                }

                ToolVariant.TODO -> ToolTodoDetails(arguments = arguments)

                ToolVariant.QUESTION -> ToolQuestionDetails(arguments = arguments)

                ToolVariant.SEARCH, ToolVariant.WEB_SEARCH, ToolVariant.WEB_FETCH -> {
                    val query = arguments.text("query") ?: arguments.text("pattern") ?: arguments.text("url")
                    if (!query.isNullOrBlank()) {
                        BasicText(text = query, style = type.secondary.copy(color = tokens.colors.primary))
                    }
                }

                ToolVariant.READ, ToolVariant.GENERIC -> Unit
            }
            if (body.isNotEmpty()) {
                BasicText(
                    text = body,
                    style = type.code.copy(color = if (isError) tokens.colors.danger else tokens.colors.secondary),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            metadata?.let { meta ->
                val fields = meta.members.entries.mapNotNull { (key, value) ->
                    if (key !in TOOL_METADATA_FIELDS) return@mapNotNull null
                    val rendered = when (value) {
                        is JsonString -> value.value
                        is JsonNumber -> value.raw
                        is JsonBool -> value.value.toString()
                        else -> null
                    }
                    rendered?.takeIf { it.isNotEmpty() }?.let { key to it }
                }
                fields.forEach { (key, value) ->
                    Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                        BasicText(text = "$key:", style = type.caption.copy(color = tokens.colors.secondary))
                        BasicText(text = value, style = type.caption.copy(color = tokens.colors.primary))
                    }
                }
            }
        }
    }
}

@Composable
private fun DiffLine(text: String, added: Boolean) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = (if (added) "+ " else "− ") + text,
        style = type.code.copy(color = if (added) tokens.colors.success else tokens.colors.danger),
    )
}

@Composable
private fun ToolTodoDetails(arguments: JsonObject?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val todos = (arguments?.get("todos") as? JsonArray)?.values.orEmpty()
    todos.forEach { raw ->
        val todo = raw as? JsonObject ?: return@forEach
        val content = todo.text("content") ?: return@forEach
        val status = todo.text("status")
        Row(
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = content,
                style = type.listItem.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            val label = when (status) {
                "completed" -> "已完成"
                "in_progress" -> "进行中"
                "pending" -> "待处理"
                else -> null
            }
            if (label != null) {
                BasicText(text = label, style = type.caption.copy(color = tokens.colors.textSecondary))
            }
        }
    }
}

@Composable
private fun ToolQuestionDetails(arguments: JsonObject?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val questions = (arguments?.get("questions") as? JsonArray)?.values.orEmpty()
    questions.forEach { raw ->
        val question = raw as? JsonObject ?: return@forEach
        val prompt = question.text("question") ?: question.text("prompt") ?: return@forEach
        BasicText(text = prompt, style = type.secondary.copy(color = tokens.colors.primary))
        val options = (question["options"] as? JsonArray)?.values.orEmpty()
        options.forEach { optionRaw ->
            val option = optionRaw as? JsonObject
            val label = option?.text("label") ?: (optionRaw as? JsonString)?.value ?: return@forEach
            val description = option?.text("description")
            BasicText(
                text = "• $label" + (description?.let { " — $it" } ?: ""),
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
    }
}

private fun toolDisplayTitle(raw: String): String = when (raw) {
    "bash", "pwsh", "exec_command", "write_stdin" -> "运行命令"
    "read" -> "读取"
    "read_image" -> "读取图片"
    "grep" -> "搜索文件内容"
    "glob" -> "查找文件"
    "web_search" -> "网页搜索"
    "web_fetch" -> "网页获取"
    "edit", "apply_patch", "str_replace_editor" -> "编辑"
    "write" -> "写入"
    "todo_write" -> "更新任务清单"
    "ask_user_question", "request_user_input" -> "提问"
    "exit_plan_mode" -> "提交计划"
    else -> raw
}

private fun JsonObject?.text(key: String): String? = (this?.get(key) as? JsonString)?.value

private val TOOL_METADATA_FIELDS = setOf(
    "path", "url", "query", "exitCode", "exit_code", "durationMs", "duration_ms", "bytes", "resultCount",
)

internal const val TOOL_ROW_CATEGORY_ICON_TAG: String = "pdsh.surface.tool-row.category-icon"
internal const val TOOL_ROW_CHEVRON_TAG: String = "pdsh.surface.tool-row.chevron"
internal const val TOOL_ROW_CHEVRON_ART_TAG: String = "pdsh.surface.tool-row.chevron-art"
