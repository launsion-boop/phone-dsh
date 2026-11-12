// Bot 信息 › 审批记录: the human parameter summary and the actual decision.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift:1807-1849`.
// The record is already human-readable by contract (`ui-state.md` §2.5); the
// page prints no raw id, digest or secret value.
package com.phonedsh.ui.bot.page.info

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoLoadState
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.SessionFailureLine
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

@Composable
internal fun BotInfoApprovalsPage(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val approvals = state.snapshot?.approvals.orEmpty()

    PageFrame(
        title = BotInfoCopy.APPROVALS_TITLE,
        onBack = onBack,
        rootTag = BOT_APPROVALS_ROOT,
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
        when (val load = state.approvalsState) {
            BotInfoLoadState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    Modifier.size(BotInfoMetrics.ACTION).testTag(BotInfoTags.APPROVALS_LOADING),
                    color = tokens.colors.textSecondary,
                )
            }

            is BotInfoLoadState.Failed -> SessionFailureLine(
                message = BotUiStrings.format("info.approvals.readFailed", "error" to load.reason),
                tag = BotInfoTags.APPROVALS_FAILED,
                retryLabel = UiStrings.RETRY,
                onRetry = { onIntent(BotInfoIntent.Load) },
            )

            BotInfoLoadState.Loaded -> {
                if (approvals.isEmpty()) {
                    BasicText(
                        text = BotInfoCopy.APPROVALS_EMPTY,
                        style = type.secondary.copy(color = tokens.colors.textSecondary),
                        modifier = Modifier
                            .padding(horizontal = tokens.geometry.pageOuterMarginH)
                            .testTag(BotInfoTags.APPROVALS_EMPTY),
                    )
                } else {
                    LazyColumn(
                        Modifier.fillMaxSize().testTag(BotInfoTags.APPROVALS_LIST),
                        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
                    ) {
                        items(approvals.size, key = { approvals[it].id }) { index ->
                            val record = approvals[index]
                            Column(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = tokens.geometry.pageOuterMarginH)
                                    .padding(vertical = BotInfoMetrics.GRANT_PADDING_V)
                                    .testTag(BOT_APPROVAL_ROW_PREFIX + record.id),
                                verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP),
                            ) {
                                BasicText(
                                    text = record.parameterSummary,
                                    style = type.homeBody.copy(color = tokens.colors.textPrimary),
                                )
                                Row(Modifier.fillMaxWidth()) {
                                    BasicText(
                                        text = BotInfoFormat.approvalDecision(record.decision),
                                        style = type.secondary.copy(
                                            color = tokens.colors.textSecondary,
                                            fontWeight = FontWeight.Medium,
                                        ),
                                        modifier = Modifier.weight(1f),
                                    )
                                    BasicText(
                                        text = BotInfoFormat.dateTime(record.decidedAt, now),
                                        style = type.caption.copy(
                                            fontSize = BotInfoMetrics.CAPTION_SIZE,
                                            color = tokens.colors.textTertiary,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private const val BOT_APPROVALS_ROOT: String = "bot.approvals"
private const val BOT_APPROVAL_ROW_PREFIX: String = "bot.approval.row."
