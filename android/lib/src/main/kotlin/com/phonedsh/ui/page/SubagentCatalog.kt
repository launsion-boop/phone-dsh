// The chat header's subagent catalog: rows come only from the current Worker projection.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialSheetColors
import com.phonedsh.ui.theme.LocalUiType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Values from `session/projections.values.subagentCatalog` plus session/list facts. */
@Immutable
public data class ChatSubagentEntry(
    public val workerSessionId: String,
    public val label: String?,
    public val mode: String?,
    public val parentSessionId: String? = null,
    /** Null means session/list did not report this session's running fact. */
    public val running: Boolean? = null,
    /** Null means session/list was unavailable; false means it was read and missed this id. */
    public val workerSessionKnown: Boolean? = null,
    /** Worker session/list projection title, if reported. */
    public val sessionTitle: String? = null,
    /** Worker session/list update time in epoch milliseconds, if reported. */
    public val updatedAtMs: Long? = null,
) {
    public val title: String get() = label?.takeIf(String::isNotBlank) ?: workerSessionId
    public val isExternal: Boolean get() = mode == MODE_EXTERNAL
    public val canOpen: Boolean get() = !isExternal && workerSessionKnown == true && running == false

    public companion object {
        public const val MODE_ONE_SHOT: String = "one-shot"
        public const val MODE_CONTINUABLE: String = "continuable"
        public const val MODE_EXTERNAL: String = "external"
    }
}

internal const val SUBAGENT_CATALOG_CARD_TAG = "subagent_catalog_card"
internal const val SUBAGENT_CATALOG_SHEET_TAG = "subagent_catalog_sheet"

private fun ChatSubagentEntry.modeLabel(): String = when (mode) {
    ChatSubagentEntry.MODE_ONE_SHOT -> "一次性"
    ChatSubagentEntry.MODE_CONTINUABLE -> "可继续"
    ChatSubagentEntry.MODE_EXTERNAL -> "外部任务"
    else -> "模式未知"
}

/** Phone presentation of the source's large opaque sheet and floating catalog card. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SubagentCatalogDialog(
    entries: List<ChatSubagentEntry>,
    currentWorkerSessionId: String?,
    onDismiss: () -> Unit,
    onOpen: suspend (ChatSubagentEntry) -> String?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var openingId by remember { mutableStateOf<String?>(null) }
    var openFailure by remember { mutableStateOf<String?>(null) }
    var openJob by remember { mutableStateOf<Job?>(null) }
    val close: () -> Unit = {
        openJob?.cancel()
        openJob = null
        openingId = null
        onDismiss()
    }
    val screenHeight = LocalConfiguration.current.screenHeightDp.dp
    val cardMaxHeight = minOf(
        ChatMetrics.SUBAGENT_MENU_MAX_HEIGHT_PT.dp,
        (screenHeight - ChatMetrics.SUBAGENT_SHEET_HEIGHT_REDUCTION_PT.dp)
            .coerceAtLeast(ChatMetrics.SUBAGENT_MENU_MIN_HEIGHT_PT.dp),
    )
    val noticeHeight = if (openFailure != null) ChatMetrics.SUBAGENT_ERROR_ROW_HEIGHT_PT.dp else ChatMetrics.SUBAGENT_NO_NOTICE_HEIGHT_PT.dp
    val cardHeight = minOf(
        maxOf(
            ChatMetrics.SUBAGENT_CARD_MIN_HEIGHT_PT.dp,
            ChatMetrics.SUBAGENT_CARD_BASE_PADDING_PT.dp + noticeHeight +
                ChatMetrics.SUBAGENT_ROW_CARD_HEIGHT_PT.dp * entries.size,
        ),
        cardMaxHeight,
    )

    val palette = materialSheetColors(tokens)
    LaunchedEffect(sheetState) { sheetState.show() }
    ModalBottomSheet(
        onDismissRequest = close,
        sheetState = sheetState,
        containerColor = palette.container,
        contentColor = palette.content,
        modifier = Modifier.testTag(SUBAGENT_CATALOG_SHEET_TAG).semantics { paneTitle = "子智能体会话" },
    ) {
        Column(modifier = Modifier.fillMaxWidth().fillMaxHeight()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = HomeMetrics.chromeInset)
                    .padding(top = ChatMetrics.SUBAGENT_SHEET_TOP_INSET_PT.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Column(
                    modifier = Modifier
                        .widthIn(max = ChatMetrics.SUBAGENT_MENU_WIDTH_PT.dp)
                        .fillMaxWidth()
                        .height(cardHeight)
                        .testTag(SUBAGENT_CATALOG_CARD_TAG)
                        .background(tokens.colors.surface, RoundedCornerShape(HomeMetrics.listCardRadius))
                        .border(tokens.stroke.hairline, tokens.colors.borderList, RoundedCornerShape(HomeMetrics.listCardRadius))
                        .padding(ChatMetrics.SUBAGENT_MENU_CARD_PADDING_PT.dp),
                ) {
                    openFailure?.let { message ->
                        BasicText(
                            text = message,
                            style = type.caption.copy(color = tokens.colors.danger),
                            modifier = Modifier.fillMaxWidth()
                                .padding(ChatMetrics.SUBAGENT_ERROR_MESSAGE_PADDING_PT.dp),
                        )
                    }
                    LazyColumn(modifier = Modifier.fillMaxWidth()) {
                        items(entries, key = { it.workerSessionId }) { entry ->
                            val isCurrent = entry.workerSessionId == currentWorkerSessionId
                            val isOpening = openingId == entry.workerSessionId
                            SubagentCatalogRow(
                                entry = entry,
                                isCurrent = isCurrent,
                                isOpening = isOpening,
                                openInFlight = openingId != null,
                                onOpen = {
                                    if (!entry.canOpen || openingId != null) return@SubagentCatalogRow
                                    openFailure = null
                                    openingId = entry.workerSessionId
                                    openJob = scope.launch(start = CoroutineStart.UNDISPATCHED) {
                                        try {
                                            val failure = onOpen(entry)
                                            if (failure == null) close()
                                            else {
                                                openingId = null
                                                openJob = null
                                                openFailure = failure
                                            }
                                        } catch (cancelled: CancellationException) {
                                            throw cancelled
                                        } catch (failure: Exception) {
                                            openingId = null
                                            openJob = null
                                            openFailure = failure.message ?: "子会话未打开"
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun SubagentCatalogRow(
    entry: ChatSubagentEntry,
    isCurrent: Boolean,
    isOpening: Boolean,
    openInFlight: Boolean,
    onOpen: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val status = when {
        entry.isExternal -> "外部任务"
        entry.workerSessionKnown != true -> "未确认会话"
        isOpening -> "正在打开"
        entry.running == true -> "正在运行"
        entry.running == false -> "当前未运行"
        else -> null
    }
    val openEnabled = entry.canOpen && !openInFlight
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = ChatMetrics.SUBAGENT_ROW_INSET_LEADING_PT.dp,
                end = ChatMetrics.SUBAGENT_ROW_INSET_TRAILING_PT.dp,
                top = ChatMetrics.SUBAGENT_ROW_INSET_V_PT.dp,
                bottom = ChatMetrics.SUBAGENT_ROW_INSET_V_PT.dp,
            )
            .defaultMinSize(minHeight = ChatMetrics.SUBAGENT_ROW_MIN_HEIGHT_PT.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.SUBAGENT_ROW_GAP_PT.dp),
    ) {
        // SwiftUI leaves this 14×17 slot empty for the flat catalog caller.
        Spacer(Modifier.width(ChatMetrics.SUBAGENT_DISCLOSURE_SLOT_PT.dp).height(ChatMetrics.SUBAGENT_DISCLOSURE_HEIGHT_PT.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .clickable(enabled = openEnabled, role = Role.Button, onClick = onOpen)
                .semantics(mergeDescendants = true) {
                    contentDescription = listOfNotNull(entry.title, entry.modeLabel(), status).joinToString(" · ")
                },
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.SUBAGENT_ROW_GAP_PT.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(width = ChatMetrics.SUBAGENT_ACTIVITY_SLOT_PT.dp, height = ChatMetrics.SUBAGENT_DISCLOSURE_HEIGHT_PT.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (!entry.isExternal && (entry.running == true || isOpening)) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(ChatMetrics.SUBAGENT_ACTIVITY_SLOT_PT.dp),
                        color = tokens.colors.tertiary,
                        strokeWidth = tokens.stroke.hairline,
                    )
                } else if (!entry.isExternal && entry.running == false) {
                    Box(
                        Modifier.size(ChatMetrics.SUBAGENT_ACTIVITY_DOT_PT.dp)
                            .background(tokens.colors.textPlaceholder, CircleShape),
                    )
                }
            }
            Column(
                verticalArrangement = Arrangement.spacedBy(ChatMetrics.SUBAGENT_TITLE_STACK_GAP_PT.dp),
            ) {
                BasicText(
                    text = entry.title,
                    style = type.body.copy(
                        fontSize = ChatMetrics.SUBAGENT_TITLE_REF_PT.sp,
                        fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                        color = tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    modifier = Modifier.height(ChatMetrics.SUBAGENT_TITLE_LINE_HEIGHT_PT.dp),
                )
                Row(
                    modifier = Modifier.height(ChatMetrics.SUBAGENT_SECONDARY_HEIGHT_PT.dp),
                    horizontalArrangement = Arrangement.spacedBy(ChatMetrics.SUBAGENT_SECONDARY_GAP_PT.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(
                        text = entry.modeLabel(),
                        style = type.caption.copy(
                            color = tokens.colors.tertiary,
                            fontSize = ChatMetrics.SUBAGENT_SECONDARY_REF_PT.sp,
                            lineHeight = ChatMetrics.SUBAGENT_SECONDARY_HEIGHT_PT.sp,
                        ),
                        maxLines = 1,
                        modifier = Modifier
                            .background(tokens.colors.selector, RoundedCornerShape(ChatMetrics.SUBAGENT_MODE_CHIP_RADIUS_PT.dp))
                            .padding(horizontal = ChatMetrics.SUBAGENT_MODE_CHIP_INSET_H_PT.dp),
                    )
                    status?.let {
                        BasicText("·", style = type.caption.copy(color = tokens.colors.tertiary))
                        BasicText(
                            text = it,
                            style = type.caption.copy(
                                fontSize = ChatMetrics.SUBAGENT_SECONDARY_REF_PT.sp,
                                lineHeight = ChatMetrics.SUBAGENT_SECONDARY_HEIGHT_PT.sp,
                                color = tokens.colors.tertiary,
                            ),
                            maxLines = 1,
                        )
                    }
                }
            }
        }

    }
}
