// Bot 信息 › 例行任务: the routine rows, their human-readable fields, the one
// reconciliation block and the cancel/pause/retry actions.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift:1282-1647`
// and `spec/ui/v1/bot/ui-state.md` §4.12. Raw ids, the IANA zone, run ids and
// effect records stay in the 详情 disclosure; the main row never prints them.
// Actions only report `BotInfoIntent`; the host re-reads the authority.
package com.phonedsh.ui.bot.page.info

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoLoadState
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotReconciliationDecision
import com.phonedsh.ui.bot.state.BotReconciliationInfo
import com.phonedsh.ui.bot.state.BotRoutineInfo
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.SessionFailureLine
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

@Composable
internal fun BotInfoRoutinesPage(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
    onBack: () -> Unit,
    highlightRoutineID: String?,
    modifier: Modifier,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val listState = rememberLazyListState()
    val routines = state.snapshot?.routines.orEmpty()
    var confirmingCancel by remember { mutableStateOf<BotRoutineInfo?>(null) }

    LaunchedEffect(highlightRoutineID, routines) {
        if (state.routinesState != BotInfoLoadState.Loaded) return@LaunchedEffect
        val id = highlightRoutineID ?: return@LaunchedEffect
        val index = routines.indexOfFirst { it.id == id }
        if (index >= 0) listState.animateScrollToItem(index)
    }

    PageFrame(
        title = BotInfoCopy.ROUTINES_TITLE,
        onBack = onBack,
        rootTag = BOT_ROUTINES_ROOT,
        modifier = modifier,
        actions = {
            BasicText(
                text = BotInfoCopy.REFRESH,
                style = type.secondary.copy(color = tokens.colors.primaryButton),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = { onIntent(BotInfoIntent.Load) })
                    .semantics { contentDescription = BotInfoCopy.REFRESH }
                    .padding(horizontal = BotInfoMetrics.ENTRY_GAP),
            )
        },
    ) {
        when (val load = state.routinesState) {
            BotInfoLoadState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    Modifier.size(BotInfoMetrics.ACTION).testTag(BotInfoTags.ROUTINES_LOADING),
                    color = tokens.colors.textSecondary,
                )
            }

            is BotInfoLoadState.Failed -> SessionFailureLine(
                message = BotUiStrings.format("info.routine.readFailed", "error" to load.reason),
                tag = BotInfoTags.ROUTINES_FAILED,
                retryLabel = UiStrings.RETRY,
                onRetry = { onIntent(BotInfoIntent.Load) },
            )

            BotInfoLoadState.Loaded -> {
                if (routines.isEmpty()) {
                    BasicText(
                        text = BotInfoCopy.ROUTINES_EMPTY,
                        style = type.secondary.copy(color = tokens.colors.textSecondary),
                        modifier = Modifier
                            .padding(horizontal = tokens.geometry.pageOuterMarginH)
                            .testTag(BotInfoTags.ROUTINES_EMPTY),
                    )
                } else {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize().testTag(BotInfoTags.ROUTINES_LIST),
                        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
                    ) {
                        items(routines.size, key = { routines[it].id }) { index ->
                            val routine = routines[index]
                            BotRoutineRow(
                                routine = routine,
                                reconciliation = state.snapshot?.reconciliations
                                    ?.firstOrNull { it.routineID == routine.id },
                                highlighted = highlightRoutineID == routine.id,
                                onIntent = onIntent,
                                onCancel = { confirmingCancel = routine },
                                now = now,
                            )
                        }
                    }
                }
            }
        }
    }

    confirmingCancel?.let { routine ->
        BotInfoConfirmDialog(
            title = BotInfoCopy.ROUTINE_CANCEL_TITLE,
            message = BotInfoCopy.ROUTINE_CANCEL_BODY,
            confirmLabel = BotUiStrings.INFO_ROUTINE_CANCEL,
            confirmTag = BotInfoTags.ROUTINE_CANCEL_CONFIRM,
            cancelTag = BOT_ROUTINE_CANCEL_BACK,
            onDismiss = { confirmingCancel = null },
            onConfirm = {
                confirmingCancel = null
                onIntent(BotInfoIntent.CancelRoutine(routine.id))
            },
        )
    }
}

@Composable
private fun BotRoutineRow(
    routine: BotRoutineInfo,
    reconciliation: BotReconciliationInfo?,
    highlighted: Boolean,
    onIntent: (BotInfoIntent) -> Unit,
    onCancel: () -> Unit,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.card)
    val showsReconciliation = routine.needsReconciliation
    val status = routineStatus(routine)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .background(
                if (highlighted) tokens.colors.userBubble else androidx.compose.ui.graphics.Color.Transparent,
                shape,
            )
            .padding(
                vertical = BotInfoMetrics.ROUTINE_PADDING_V,
                horizontal = tokens.spacing.iconText,
            )
            .testTag(BotInfoTags.routineRow(routine.id)),
        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.RECONCILIATION_PADDING),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            BasicText(
                text = routine.title,
                style = type.headline.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(BotInfoMetrics.PILL_PADDING_H))
            BotStatusPill(text = status.first, tone = status.second)
        }

        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.RECONCILIATION_PADDING),
        ) {
            BotRoutineField(BotInfoCopy.ROUTINE_SCHEDULE, routine.schedule)
            routine.nextDue?.let {
                BotRoutineField(BotInfoCopy.ROUTINE_NEXT_DUE, BotInfoFormat.dateTime(it, now))
            }
            BotRoutineField(
                BotInfoCopy.ROUTINE_TIMEZONE,
                BotInfoFormat.routineTimeZone(routine.timeZone, now),
            )
            BotRoutineField(
                BotInfoCopy.ROUTINE_DELIVERY,
                BotInfoFormat.routineDelivery(routine.delivery),
            )
            if (routine.quietDeferredFrom != null && routine.quietDeferredUntil != null) {
                BotRoutineField(
                    BotInfoCopy.ROUTINE_DEFERRED,
                    BotInfoCopy.format(
                        BotInfoCopy.ROUTINE_DEFERRED_VALUE,
                        "from" to BotInfoFormat.dateTime(routine.quietDeferredFrom, now),
                        "until" to BotInfoFormat.dateTime(routine.quietDeferredUntil, now),
                    ),
                    stacked = true,
                )
            } else if (routine.quiet) {
                BasicText(
                    text = BotInfoCopy.ROUTINE_QUIET,
                    style = type.caption.copy(color = tokens.colors.textSecondary),
                )
            }
            BotInfoFormat.routineCreator(routine.creator)?.let {
                BotRoutineField(BotInfoCopy.ROUTINE_CREATOR, it)
            }
            routine.completionCriteria?.takeIf { it.isNotEmpty() }?.let { criteria ->
                BotRoutineField(
                    BotInfoCopy.ROUTINE_CRITERIA,
                    if (BotInfoFormat.routineFreeTextNeedsDetail(criteria)) {
                        BotInfoCopy.ROUTINE_FREE_TEXT_SUMMARY
                    } else {
                        criteria
                    },
                    stacked = true,
                )
            }
            routine.routineConstraints?.takeIf { it.isNotEmpty() }?.let { constraints ->
                BotRoutineField(
                    BotInfoCopy.ROUTINE_CONSTRAINTS,
                    if (BotInfoFormat.routineFreeTextNeedsDetail(constraints)) {
                        BotInfoCopy.ROUTINE_FREE_TEXT_SUMMARY
                    } else {
                        constraints
                    },
                    stacked = true,
                )
            }
        }

        if (routine.urgent) {
            BasicText(
                text = BotInfoCopy.format(
                    BotInfoCopy.ROUTINE_URGENT,
                    "reason" to (routine.urgentReason ?: BotInfoCopy.ROUTINE_URGENT_NONE),
                ),
                style = type.caption.copy(color = tokens.colors.warning),
            )
        }

        if (showsReconciliation) {
            BotReconciliationBlock(reconciliation)
        } else {
            BasicText(
                text = routine.lastResult,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
        }

        BotRoutineActions(
            routine = routine,
            showsReconciliation = showsReconciliation,
            onCancel = onCancel,
            onToggle = {
                onIntent(BotInfoIntent.SetRoutineEnabled(routine.id, !routine.enabled))
            },
            onAcknowledge = {
                onIntent(
                    BotInfoIntent.ResolveReconciliation(
                        routine.id,
                        BotReconciliationDecision.ACKNOWLEDGE,
                    ),
                )
            },
            onRetry = {
                onIntent(
                    BotInfoIntent.ResolveReconciliation(
                        routine.id,
                        BotReconciliationDecision.RETRY,
                    ),
                )
            },
        )

        BotRoutineDetail(
            routine = routine,
            reconciliation = reconciliation,
        )
    }
}

@Composable
private fun BotRoutineField(
    label: String,
    value: String,
    stacked: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val labelStyle = type.secondary.copy(color = tokens.colors.textSecondary)
    val valueStyle = type.homeBody.copy(
        fontSize = BotInfoMetrics.ROUTINE_VALUE_SIZE,
        color = tokens.colors.textPrimary,
    )
    if (stacked) {
        Column(
            Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP),
        ) {
            BasicText(text = label, style = labelStyle)
            BasicText(text = value, style = valueStyle)
        }
    } else {
        Row(
            Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.Top,
        ) {
            BasicText(
                text = label,
                style = labelStyle,
                modifier = Modifier.width(BotInfoMetrics.ROUTINE_LABEL_WIDTH),
            )
            Spacer(Modifier.width(BotInfoMetrics.RECONCILIATION_PADDING))
            BasicText(
                text = value,
                style = valueStyle,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun BotReconciliationBlock(reconciliation: BotReconciliationInfo?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(
                tokens.colors.warning.copy(alpha = BotInfoMetrics.RECONCILIATION_FILL_ALPHA),
                RoundedCornerShape(BotInfoMetrics.RECONCILIATION_RADIUS),
            )
            .padding(BotInfoMetrics.RECONCILIATION_PADDING),
        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP),
    ) {
        BasicText(
            text = BotInfoCopy.ROUTINE_RECONCILIATION_TITLE,
            style = type.secondary.copy(
                color = tokens.colors.warning,
                fontWeight = FontWeight.Medium,
            ),
        )
        BasicText(
            text = reconciliation?.effectSummary
                ?: BotInfoCopy.ROUTINE_RECONCILIATION_FALLBACK,
            style = type.secondary.copy(color = tokens.colors.textPrimary),
        )
        BotInfoFormat.routineReconciliationReason(reconciliation?.error)?.let { reason ->
            BasicText(
                text = BotInfoCopy.format(
                    BotInfoCopy.ROUTINE_RECONCILIATION_REASON,
                    "reason" to reason,
                ),
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
        }
    }
}

@Composable
private fun BotRoutineActions(
    routine: BotRoutineInfo,
    showsReconciliation: Boolean,
    onCancel: () -> Unit,
    onToggle: () -> Unit,
    onAcknowledge: () -> Unit,
    onRetry: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val canCancel = routine.runStatus == "started" || routine.runStatus == "waiting-approval"
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(BotInfoMetrics.HAIRLINE)
                .background(tokens.colors.borderList),
        )
        if (showsReconciliation) {
            Row(horizontalArrangement = Arrangement.spacedBy(BotInfoMetrics.PILL_PADDING_H)) {
                BotPillButton(
                    label = BotUiStrings.INFO_RECONCILE_ACK,
                    primary = true,
                    tag = BotInfoTags.routineAck(routine.id),
                    onClick = onAcknowledge,
                )
                BotPillButton(
                    label = BotUiStrings.INFO_RECONCILE_RETRY,
                    primary = false,
                    tag = BotInfoTags.routineRetry(routine.id),
                    onClick = onRetry,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (canCancel) {
                BasicText(
                    text = BotUiStrings.INFO_ROUTINE_CANCEL,
                    style = type.secondary.copy(color = tokens.colors.danger),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onCancel)
                        .padding(vertical = tokens.spacing.iconText)
                        .testTag(BotInfoTags.routineCancel(routine.id)),
                )
                Box(
                    Modifier
                        .width(BotInfoMetrics.HAIRLINE)
                        .height(BotInfoMetrics.ENTRY_ICON)
                        .background(tokens.colors.borderList),
                )
            }
            BasicText(
                text = if (routine.enabled) {
                    BotInfoCopy.ROUTINE_PAUSE
                } else {
                    BotInfoCopy.ROUTINE_RESUME
                },
                style = type.secondary.copy(color = tokens.colors.primaryButton),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onToggle)
                    .padding(
                        horizontal = tokens.spacing.iconText,
                        vertical = tokens.spacing.iconText,
                    )
                    .testTag(BotInfoTags.routineToggle(routine.id)),
            )
        }
    }
}

@Composable
private fun BotPillButton(
    label: String,
    primary: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.secondary.copy(
            color = if (primary) tokens.colors.primaryButtonInk else tokens.colors.textPrimary,
            fontWeight = FontWeight.Medium,
        ),
        modifier = Modifier
            .background(
                if (primary) tokens.colors.primaryButton else tokens.colors.surface,
                RoundedCornerShape(tokens.radius.bubble),
            )
            .clickable(role = Role.Button, onClick = onClick)
            .padding(
                horizontal = BotInfoMetrics.RECONCILIATION_PADDING,
                vertical = BotInfoMetrics.PILL_PADDING_V,
            )
            .testTag(tag),
    )
}

@Composable
private fun BotRoutineDetail(
    routine: BotRoutineInfo,
    reconciliation: BotReconciliationInfo?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var expanded by remember(routine.id) { mutableStateOf(false) }
    val fields = routineRawFields(routine, reconciliation)
    if (fields.isEmpty()) return
    Column(Modifier.fillMaxWidth()) {
        BasicText(
            text = if (expanded) BotInfoCopy.ROUTINE_DETAIL_HIDE else BotInfoCopy.ROUTINE_DETAIL_SHOW,
            style = type.secondary.copy(color = tokens.colors.primaryButton),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = { expanded = !expanded })
                .padding(vertical = tokens.spacing.iconText)
                .testTag(BotInfoTags.routineDetail(routine.id)),
        )
        if (expanded) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(
                        tokens.colors.userBubble.copy(alpha = 0.6f),
                        RoundedCornerShape(BotInfoMetrics.DETAIL_RADIUS),
                    )
                    .padding(BotInfoMetrics.DETAIL_PADDING),
                verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.RECONCILIATION_PADDING),
            ) {
                fields.forEach { (label, value) ->
                    Column(verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP)) {
                        BasicText(
                            text = label,
                            style = type.caption.copy(color = tokens.colors.textSecondary),
                        )
                        BasicText(
                            text = value,
                            style = type.code.copy(color = tokens.colors.textPrimary),
                        )
                    }
                }
            }
        }
    }
}

private fun routineRawFields(
    routine: BotRoutineInfo,
    reconciliation: BotReconciliationInfo?,
): List<Pair<String, String>> {
    val fields = mutableListOf<Pair<String, String>>()
    fields += BotInfoCopy.ROUTINE_DETAIL_ID to routine.id
    fields += BotInfoCopy.ROUTINE_DETAIL_TIMEZONE to routine.timeZone
    routine.creatorDetail?.takeIf { it.isNotEmpty() }?.let {
        fields += BotInfoCopy.ROUTINE_DETAIL_CREATOR to it
    }
    routine.routineConstraints?.takeIf {
        it.isNotEmpty() && BotInfoFormat.routineFreeTextNeedsDetail(it)
    }?.let { fields += BotInfoCopy.ROUTINE_DETAIL_CONSTRAINTS to it }
    routine.completionCriteria?.takeIf {
        it.isNotEmpty() && BotInfoFormat.routineFreeTextNeedsDetail(it)
    }?.let { fields += BotInfoCopy.ROUTINE_DETAIL_CRITERIA to it }
    routine.runID?.takeIf { it.isNotEmpty() }?.let {
        fields += BotInfoCopy.ROUTINE_DETAIL_RUN to it
    }
    reconciliation?.effectDetail?.takeIf { it.isNotEmpty() }?.let {
        fields += BotInfoCopy.ROUTINE_DETAIL_EFFECT to it
    }
    reconciliation?.error?.takeIf { it.isNotEmpty() }?.let {
        fields += BotInfoCopy.ROUTINE_DETAIL_REASON to it
    }
    routine.lastResultDetail?.takeIf { it.isNotEmpty() }?.let {
        fields += BotInfoCopy.ROUTINE_DETAIL_LAST_RESULT to it
    }
    return fields
}

private fun routineStatus(routine: BotRoutineInfo): Pair<String, BotStatusTone> =
    when (routine.runStatus) {
        "started" -> BotInfoCopy.ROUTINE_STATUS_STARTED to BotStatusTone.ACCENT
        "waiting-approval" -> BotInfoCopy.ROUTINE_STATUS_WAITING_APPROVAL to BotStatusTone.NEUTRAL
        "needs-reconciliation" ->
            BotInfoCopy.ROUTINE_STATUS_RECONCILIATION to BotStatusTone.WARNING
        "scheduled" -> BotInfoCopy.ROUTINE_STATUS_SCHEDULED to BotStatusTone.NEUTRAL
        else -> (if (routine.enabled) {
            BotInfoCopy.ROUTINE_STATUS_ENABLED
        } else {
            BotInfoCopy.ROUTINE_STATUS_PAUSED
        }) to if (routine.enabled) BotStatusTone.SUCCESS else BotStatusTone.NEUTRAL
    }

private enum class BotStatusTone { ACCENT, WARNING, SUCCESS, NEUTRAL }

@Composable
private fun BotStatusPill(text: String, tone: BotStatusTone) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when (tone) {
        BotStatusTone.ACCENT -> tokens.colors.primaryButton
        BotStatusTone.WARNING -> tokens.colors.warning
        BotStatusTone.SUCCESS -> tokens.colors.homeSuccess
        BotStatusTone.NEUTRAL -> tokens.colors.textSecondary
    }
    BasicText(
        text = text,
        style = type.caption.copy(
            fontSize = BotInfoMetrics.CAPTION_SIZE,
            fontWeight = FontWeight.Medium,
            color = ink,
        ),
        modifier = Modifier
            .background(ink.copy(alpha = BotInfoMetrics.PILL_FILL_ALPHA), RoundedCornerShape(50))
            .padding(
                horizontal = BotInfoMetrics.PILL_PADDING_H,
                vertical = BotInfoMetrics.PILL_PADDING_V,
            ),
    )
}

private const val BOT_ROUTINES_ROOT: String = "bot.routine"
private const val BOT_ROUTINE_CANCEL_BACK: String = "bot.routine.cancel.back"
