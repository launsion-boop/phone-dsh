// Bot 信息 › 常设授权: only `scope != once` grants, each with a revoke action.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift:1649-1737`.
// The main row keeps the human operation/resource/scope/source; the raw tool,
// operation id, full path and session id stay folded in 详情. A revoke only
// reports `RevokeGrant`; the page never removes the row locally because the host
// re-reads the authority (`ui-state.md` §3.5/§4.12).
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
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
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.state.BotGrantInfo
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoLoadState
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.SessionFailureLine
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

@Composable
internal fun BotInfoGrantsPage(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // iOS reads `approvalsState` for the grant entry and page
    // (`BotInfoPage.swift:645-649,1654`); the grant list itself is `grants`.
    val grants = BotGrantInfo.standing(state.snapshot?.grants.orEmpty())

    PageFrame(
        title = BotInfoCopy.GRANTS_TITLE,
        onBack = onBack,
        rootTag = BOT_GRANTS_ROOT,
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
                    Modifier.size(BotInfoMetrics.ACTION).testTag(BotInfoTags.GRANTS_LOADING),
                    color = tokens.colors.textSecondary,
                )
            }

            is BotInfoLoadState.Failed -> SessionFailureLine(
                message = BotUiStrings.format("info.grant.readFailed", "error" to load.reason),
                tag = BotInfoTags.GRANTS_FAILED,
                retryLabel = UiStrings.RETRY,
                onRetry = { onIntent(BotInfoIntent.Load) },
            )

            BotInfoLoadState.Loaded -> {
                if (grants.isEmpty()) {
                    BasicText(
                        text = BotInfoCopy.GRANTS_EMPTY,
                        style = type.secondary.copy(color = tokens.colors.textSecondary),
                        modifier = Modifier
                            .padding(horizontal = tokens.geometry.pageOuterMarginH)
                            .testTag(BotInfoTags.GRANTS_EMPTY),
                    )
                } else {
                    LazyColumn(
                        Modifier.fillMaxSize().testTag(BotInfoTags.GRANTS_LIST),
                        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
                    ) {
                        items(grants.size, key = { grants[it].id }) { index ->
                            BotGrantRow(
                                grant = grants[index],
                                onRevoke = {
                                    onIntent(BotInfoIntent.RevokeGrant(grants[index].id))
                                },
                                now = now,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BotGrantRow(
    grant: BotGrantInfo,
    onRevoke: () -> Unit,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var detail by remember(grant.id) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .padding(vertical = BotInfoMetrics.GRANT_PADDING_V)
            .testTag("bot.grant.row.${grant.id}"),
        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            BasicText(
                text = BotInfoFormat.grantOperationTitle(grant.operation),
                style = type.headline.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(BotInfoMetrics.PILL_PADDING_H))
            BasicText(
                text = BotInfoFormat.grantScope(grant.scope),
                style = type.caption.copy(
                    fontSize = BotInfoMetrics.CAPTION_SIZE,
                    fontWeight = FontWeight.Medium,
                    color = tokens.colors.textSecondary,
                ),
                modifier = Modifier
                    .background(
                        tokens.colors.textSecondary.copy(alpha = BotInfoMetrics.PILL_FILL_ALPHA),
                        RoundedCornerShape(50),
                    )
                    .padding(
                        horizontal = BotInfoMetrics.PILL_PADDING_H,
                        vertical = BotInfoMetrics.PILL_PADDING_V,
                    ),
            )
        }
        BasicText(
            text = BotInfoFormat.grantResourceSummary(grant.resource, grant.operation),
            style = type.secondary.copy(color = tokens.colors.textSecondary),
        )
        BasicText(
            text = BotInfoCopy.format(
                BotInfoCopy.GRANT_SOURCE,
                "source" to BotInfoFormat.grantSource(grant.source),
                "time" to BotInfoFormat.dateTime(grant.createdAt, now),
            ),
            style = type.caption.copy(
                fontSize = BotInfoMetrics.CAPTION_SIZE,
                color = tokens.colors.textTertiary,
            ),
        )
        PdshDisclosure(
            expanded = detail,
            onToggle = { detail = !detail },
            tag = BotInfoTags.grantDetail(grant.id),
            header = {
                BasicText(
                    text = BotInfoCopy.GRANT_DETAIL,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier.padding(vertical = tokens.spacing.iconText),
                )
            },
            body = {
                Column(verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.LABEL_GAP)) {
                    GrantDetailRow(BotInfoCopy.GRANT_TOOL, grant.tool)
                    GrantDetailRow(BotInfoCopy.GRANT_OPERATION, grant.operation)
                    GrantDetailRow(BotInfoCopy.GRANT_RESOURCE, grant.resource)
                    grant.sessionID?.takeIf { it.isNotEmpty() }?.let {
                        GrantDetailRow(BotInfoCopy.GRANT_SESSION, it)
                    }
                }
            },
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(BotInfoMetrics.HAIRLINE)
                .background(tokens.colors.borderList),
        )
        BasicText(
            text = BotInfoCopy.GRANT_REVOKE,
            style = type.secondary.copy(color = tokens.colors.danger),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onRevoke)
                .padding(vertical = tokens.spacing.iconText)
                .testTag(BotInfoTags.grantRevoke(grant.id)),
        )
    }
}

@Composable
private fun GrantDetailRow(title: String, value: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth()) {
        BasicText(
            text = title,
            style = type.caption.copy(color = tokens.colors.textTertiary),
        )
        BasicText(
            text = value,
            style = type.code.copy(color = tokens.colors.textSecondary),
        )
    }
}

private const val BOT_GRANTS_ROOT: String = "bot.grant"
