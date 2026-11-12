// 已连接的电脑: one paired PC, its DSH version, liveness and unpairing.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/ConnectedComputerPage.swift` and
// `spec/ui/v1/pages/connected-computer.json`. The page is a pure function of
// [ConnectedComputerUiState]; the three alerts are local UI (the baseline's
// `@State`), while the unpair write itself is the host's callback. There is no
// fingerprint card (CCR-1): the fingerprint is one row of 本机.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.PcMetrics
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** Stable test tags for the connected-computer page. */
public object ConnectedComputerPageTags {
    public const val ROOT: String = "pdsh.pc.connected.root"
    public const val LIST: String = "pdsh.pc.connected.list"
    public const val PAIR_NEW: String = "pdsh.pc.connected.pair-new"
    public const val UNPAIR: String = "pdsh.pc.connected.unpair"
    public const val UNPAIR_CONFIRM: String = "pdsh.pc.connected.unpair-confirm"
    public const val CONNECT: String = "pdsh.pc.connected.connect"
    public const val ALREADY_PAIRED_ALERT: String = "pdsh.pc.connected.alert.already-paired"
    public const val UNPAIR_CONFIRM_ALERT: String = "pdsh.pc.connected.alert.unpair-confirm"
    public const val UNPAIR_FAILED_ALERT: String = "pdsh.pc.connected.alert.unpair-failed"
}

/**
 * 已连接的电脑.
 *
 * @param state the host's immutable record/unpair-failure snapshot.
 * @param onBack the page header's back.
 * @param onOpenPairing the empty state's 连接电脑 (the baseline's `showPairing`).
 * @param onUnpair the confirmed 解除配对 write; only called after the alert.
 * @param onDismissUnpairFailure 知道了 on 解除没有完成.
 * @param onConnectionScreenOpened `models.pcLink.markConnectionScreenOpened()`
 *   (`ConnectedComputerPage.swift:32`); the host latches long-offline here.
 */
@Composable
public fun ConnectedComputerPage(
    state: ConnectedComputerUiState,
    onBack: () -> Unit,
    onOpenPairing: () -> Unit = {},
    onUnpair: () -> Unit = {},
    onDismissUnpairFailure: () -> Unit = {},
    onConnectionScreenOpened: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var confirmUnpair by remember { mutableStateOf(false) }
    var showAlreadyPaired by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { onConnectionScreenOpened() }

    SettingsSubPageFrame(
        title = UiStrings.PC_CONNECTED_TITLE,
        onBack = onBack,
        rootTag = ConnectedComputerPageTags.ROOT,
        grouped = true,
        modifier = modifier,
    ) {
        LazyColumn(Modifier.fillMaxSize().testTag(ConnectedComputerPageTags.LIST)) {
            val record = state.record
            if (record == null) {
                item(key = "empty") {
                    ConnectedComputerEmptySection(onOpenPairing = onOpenPairing)
                }
            } else {
                item(key = "computer") {
                    ConnectedComputerSection(record)
                }
                item(key = "security") {
                    ConnectedPhoneSection(record)
                }
                item(key = "actions") {
                    ConnectedComputerActions(
                        onPairNew = { showAlreadyPaired = true },
                        onUnpair = { confirmUnpair = true },
                    )
                }
            }
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            modifier = Modifier.testTag(ConnectedComputerPageTags.UNPAIR_CONFIRM_ALERT),
            title = {
                BasicText(
                    text = PcLinkText.UNPAIR_CONFIRM_TITLE,
                    style = LocalUiType.current.headline.copy(color = LocalUiTokens.current.colors.textPrimary),
                )
            },
            text = {
                BasicText(
                    text = PcLinkText.UNPAIR_CONFIRM_MESSAGE,
                    style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
                )
            },
            confirmButton = {
                SessionTextAction(
                    label = UiStrings.PC_UNPAIR,
                    onClick = {
                        confirmUnpair = false
                        onUnpair()
                    },
                    tone = SessionActionTone.DANGER,
                    modifier = Modifier.testTag(ConnectedComputerPageTags.UNPAIR_CONFIRM),
                )
            },
            dismissButton = {
                SessionTextAction(
                    label = UiStrings.CANCEL,
                    onClick = { confirmUnpair = false },
                    tone = SessionActionTone.ACCENT,
                )
            },
        )
    }

    if (showAlreadyPaired) {
        AlertDialog(
            onDismissRequest = { showAlreadyPaired = false },
            modifier = Modifier.testTag(ConnectedComputerPageTags.ALREADY_PAIRED_ALERT),
            title = {
                BasicText(
                    text = PcLinkText.ALREADY_PAIRED_TITLE,
                    style = LocalUiType.current.headline.copy(color = LocalUiTokens.current.colors.textPrimary),
                )
            },
            text = {
                BasicText(
                    text = PcLinkText.ALREADY_PAIRED_MESSAGE,
                    style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
                )
            },
            confirmButton = {
                SessionTextAction(
                    label = UiStrings.PC_KNOW_IT,
                    onClick = { showAlreadyPaired = false },
                    tone = SessionActionTone.ACCENT,
                )
            },
            dismissButton = {
                SessionTextAction(
                    label = UiStrings.PC_UNPAIR_CURRENT,
                    onClick = {
                        showAlreadyPaired = false
                        confirmUnpair = true
                    },
                    tone = SessionActionTone.DANGER,
                )
            },
        )
    }

    val failure = state.unpairFailure
    if (failure != null) {
        AlertDialog(
            onDismissRequest = onDismissUnpairFailure,
            modifier = Modifier.testTag(ConnectedComputerPageTags.UNPAIR_FAILED_ALERT),
            title = {
                BasicText(
                    text = PcLinkText.UNPAIR_FAILED_TITLE,
                    style = LocalUiType.current.headline.copy(color = LocalUiTokens.current.colors.textPrimary),
                )
            },
            text = {
                BasicText(
                    text = failure,
                    style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
                )
            },
            confirmButton = {
                SessionTextAction(
                    label = UiStrings.PC_KNOW_IT,
                    onClick = onDismissUnpairFailure,
                    tone = SessionActionTone.ACCENT,
                )
            },
        )
    }
}

@Composable
private fun ConnectedComputerSection(record: PcLinkComputerRecord) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth()) {
        SettingsSectionLabel(UiStrings.PC_COMPUTER_SECTION)
        InfoRow(UiStrings.PC_COMPUTER_NAME, record.peerName)
        InfoRow(UiStrings.PC_DSH_VERSION, record.dshVersionText)
        Row(
            Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.ROW_VERTICAL),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = UiStrings.PC_ONLINE_STATUS,
                style = type.homeBody.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(PcMetrics.STATUS_GAP)) {
                Box(
                    Modifier.size(PcMetrics.STATUS_DOT).background(
                        if (record.online) tokens.colors.success else tokens.colors.textPlaceholder,
                        CircleShape,
                    ),
                )
                BasicText(
                    text = record.connectionText,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                )
            }
        }
        if (record.longOffline) {
            PcConnectedHint(PcLinkText.LONG_OFFLINE)
        }
        val footer = when {
            record.versionWarning != null -> record.versionWarning.orEmpty()
            record.online -> PcLinkText.COMPUTER_ONLINE_FOOTER
            else -> PcLinkText.COMPUTER_OFFLINE_FOOTER
        }
        PcConnectedHint(footer)
    }
}

@Composable
private fun ConnectedPhoneSection(record: PcLinkComputerRecord) {
    Column(Modifier.fillMaxWidth()) {
        SettingsSectionLabel(UiStrings.PC_THIS_PHONE_SECTION)
        InfoRow(UiStrings.PC_OWN_FINGERPRINT, record.display(record.ownFingerprint))
        InfoRow(UiStrings.PC_PAIRING_MODE, record.pairingModeText)
        InfoRow(UiStrings.PC_PAIRED_AT, record.pairedAtText)
        InfoRow(UiStrings.PC_RELAY, record.display(record.relayOrigin))
        PcConnectedHint(PcLinkText.FINGERPRINT_FOOTER)
    }
}

@Composable
private fun ConnectedComputerActions(
    onPairNew: () -> Unit,
    onUnpair: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        SessionTextAction(
            label = UiStrings.PC_PAIR_NEW,
            onClick = onPairNew,
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.testTag(ConnectedComputerPageTags.PAIR_NEW),
        )
        SessionTextAction(
            label = UiStrings.PC_UNPAIR,
            onClick = onUnpair,
            tone = SessionActionTone.DANGER,
            modifier = Modifier.testTag(ConnectedComputerPageTags.UNPAIR),
        )
    }
}

@Composable
private fun ConnectedComputerEmptySection(onOpenPairing: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.ROW_VERTICAL),
        verticalArrangement = Arrangement.spacedBy(PcMetrics.FIELD_INSET),
    ) {
        BasicText(
            text = PcLinkText.NO_COMPUTER,
            style = type.headline.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.semantics { heading() },
        )
        BasicText(
            text = PcLinkText.NO_COMPUTER_HINT,
            style = type.secondary.copy(color = tokens.colors.textSecondary),
        )
        PcPrimaryButton(
            label = UiStrings.PC_CONNECT_COMPUTER,
            onClick = onOpenPairing,
            modifier = Modifier.testTag(ConnectedComputerPageTags.CONNECT),
        )
    }
}

@Composable
private fun PcConnectedHint(text: String) {
    BasicText(
        text = text,
        style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
        modifier = Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.LABEL_GAP),
    )
    Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
}
