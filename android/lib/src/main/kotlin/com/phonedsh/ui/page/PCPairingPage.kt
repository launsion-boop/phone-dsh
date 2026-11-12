// 连接电脑: the PCLink pairing page (P09/P28, GAP-35).
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/PCPairingPage.swift` and
// `spec/ui/v1/pages/pc-pairing.json`. The page is a pure function of
// [PCPairingUiState]; the flow, the relay and the camera all belong to the host.
// The scanner body is a host-supplied slot because `:lib` carries no camera
// dependency (design §6 C5): the page still owns the sheet, its 取消 action and
// the denied-camera line.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.PcMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.page.SessionActionTone
import com.phonedsh.ui.page.SessionTextAction
import com.phonedsh.ui.press.primaryPressed
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** Stable test tags for the pairing page's controls. */
public object PCPairingPageTags {
    public const val ROOT: String = "pdsh.pc.pairing.root"
    public const val SCAN: String = "pdsh.pc.pairing.scan"
    public const val OTHER: String = "pdsh.pc.pairing.other"
    public const val LINK_FIELD: String = "pdsh.pc.pairing.link"
    public const val LINK_ACTION: String = "pdsh.pc.pairing.use-link"
    public const val CODE_FIELD: String = "pdsh.pc.pairing.code"
    public const val MANUAL_ACTION: String = "pdsh.pc.pairing.manual"
    public const val CANCEL_PAIRING: String = "pdsh.pc.pairing.cancel"
    public const val RETRY: String = "pdsh.pc.pairing.retry"
    public const val DONE: String = "pdsh.pc.pairing.done"
    public const val CLOSE: String = "pdsh.pc.pairing.close"
    public const val SCANNER: String = "pdsh.pc.pairing.scanner"
    public const val SCANNER_CANCEL: String = "pdsh.pc.pairing.scanner.cancel"
}

/**
 * 连接电脑.
 *
 * @param state the host's immutable flow snapshot ([PCPairingUiState]).
 * @param onScan 扫码连接; the host opens the camera or switches the state to
 *   [PCPairingStage.CAMERA_UNAVAILABLE].
 * @param onToggleOtherWays 其他方式 / 收起其他方式.
 * @param onPairingLinkChange the 配对链接 draft changed (the host may store the
 *   text it receives; the page only formats the manual code).
 * @param onPairWithLink 用链接配对.
 * @param onPairingCodeChange the 配对码 draft changed; the page has already
 *   formatted it with [pcManualCodeInput].
 * @param onPairManually 手动连接.
 * @param onCancelPairing 取消配对 in either busy section.
 * @param onRetry 重试 in the failed section.
 * @param onDone 完成 after a durable pairing.
 * @param onClose the toolbar 关闭; the host also cancels a busy flow (Swift `:56`).
 * @param onCancelScanner 取消 in the scanner sheet.
 * @param installCommand the one install command card; the host supplies the
 *   reviewed `PCLinkInstallGuide.installCommand` string (`PCPairingPage.swift:122`).
 * @param onCopyInstallCommand the install card's copy action; `null` keeps the
 *   card text selectable only, like a host without a clipboard seam.
 * @param scannerContent the host's camera preview; `null` renders the honest
 *   camera-unavailable line instead of a fake scanner.
 */
@Composable
public fun PCPairingPage(
    state: PCPairingUiState,
    onScan: () -> Unit = {},
    onToggleOtherWays: () -> Unit = {},
    onPairingLinkChange: (String) -> Unit = {},
    onPairWithLink: () -> Unit = {},
    onPairingCodeChange: (String) -> Unit = {},
    onPairManually: () -> Unit = {},
    onCancelPairing: () -> Unit = {},
    onRetry: () -> Unit = {},
    onDone: () -> Unit = {},
    onClose: () -> Unit = {},
    onCancelScanner: () -> Unit = {},
    installCommand: String = "",
    onCopyInstallCommand: (() -> Unit)? = null,
    scannerContent: (@Composable () -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    SettingsSubPageFrame(
        title = UiStrings.PC_PAIRING_TITLE,
        onBack = null,
        rootTag = PCPairingPageTags.ROOT,
        grouped = true,
        modifier = modifier,
        trailing = {
            SessionTextAction(
                label = UiStrings.DISMISS,
                onClick = onClose,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(PCPairingPageTags.CLOSE),
            )
        },
    ) {
        LazyColumn(Modifier.fillMaxSize()) {
            when (state.stage) {
                PCPairingStage.CONNECTED -> item(key = "paired") {
                    PcPairingPairedSection(
                        name = state.connectedName.orEmpty(),
                        onDone = onDone,
                    )
                }

                PCPairingStage.FAILED -> {
                    item(key = "failure") {
                        PcPairingFailureSection(state = state, onRetry = onRetry)
                    }
                    item(key = "permission") { PcPairingPermissionSection() }
                }

                PCPairingStage.CONNECTING -> {
                    item(key = "connecting") {
                        PcPairingConnectingSection(
                            state = state,
                            onCancel = onCancelPairing,
                        )
                    }
                    if (state.interrupted) {
                        item(key = "interrupted") { PcPairingInterruptionNotice() }
                    }
                    item(key = "permission") { PcPairingPermissionSection() }
                }

                PCPairingStage.IDLE,
                PCPairingStage.SCANNING,
                PCPairingStage.CAMERA_UNAVAILABLE,
                PCPairingStage.OTHER_WAYS,
                PCPairingStage.PAIRING_LINK,
                PCPairingStage.PAIRING_CODE,
                PCPairingStage.MANUAL,
                -> {
                    item(key = "install") {
                        PcPairingInstallSection(
                            installCommand = installCommand,
                            onCopyInstallCommand = onCopyInstallCommand,
                        )
                    }
                    item(key = "scan") {
                        PcPairingScanSection(
                            state = state,
                            onScan = onScan,
                        )
                    }
                    item(key = "other") {
                        PcPairingOtherSection(
                            state = state,
                            onToggle = onToggleOtherWays,
                            onLinkChange = onPairingLinkChange,
                            onPairWithLink = onPairWithLink,
                            onCodeChange = onPairingCodeChange,
                            onPairManually = onPairManually,
                        )
                    }
                    // `.joining` in Swift is the same body with one extra section
                    // (`PCPairingPage.swift:36-38`); the host may project it before
                    // the prompt arrives.
                    if (state.stage == PCPairingStage.MANUAL) {
                        item(key = "joining") {
                            PcPairingJoiningSection(onCancel = onCancelPairing)
                        }
                    }
                    item(key = "permission") { PcPairingPermissionSection() }
                }
            }
        }
    }

    if (state.scanning) {
        PdshSheet(
            pageId = "pc-pairing-scanner",
            onDismissRequest = onCancelScanner,
            modifier = Modifier.testTag(PCPairingPageTags.SCANNER),
        ) {
            Column(Modifier.fillMaxWidth()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(
                        text = UiStrings.PC_PAIRING_SCAN,
                        style = LocalUiType.current.headline.copy(color = LocalUiTokens.current.colors.textPrimary),
                        modifier = Modifier.weight(1f).semantics { heading() },
                    )
                    SessionTextAction(
                        label = UiStrings.CANCEL,
                        onClick = onCancelScanner,
                        tone = SessionActionTone.ACCENT,
                        modifier = Modifier.testTag(PCPairingPageTags.SCANNER_CANCEL),
                    )
                }
                if (scannerContent != null) {
                    scannerContent()
                } else {
                    PcPairingHint(PcLinkText.CAMERA_UNAVAILABLE)
                }
            }
        }
    }
}

@Composable
private fun PcPairingInstallSection(
    installCommand: String,
    onCopyInstallCommand: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        BasicText(
            text = UiStrings.PC_PAIRING_INSTALL_LEAD,
            style = type.homeBody.copy(color = tokens.colors.textPrimary),
        )
        Spacer(Modifier.height(PcMetrics.LABEL_GAP))
        Row(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(PcMetrics.CARD_RADIUS))
                .background(tokens.colors.surface)
                .border(PcMetrics.HAIRLINE, tokens.colors.borderList, RoundedCornerShape(PcMetrics.CARD_RADIUS))
                .padding(horizontal = PcMetrics.FIELD_INSET, vertical = PcMetrics.SECTION_GAP),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(PcMetrics.SECTION_GAP),
        ) {
            BasicText(
                text = installCommand.ifBlank { PcLinkText.UNKNOWN_VALUE },
                style = type.secondary.copy(
                    color = tokens.colors.textPrimary,
                    fontFamily = FontFamily.Monospace,
                    fontSize = PcMetrics.COMMAND_TEXT_SIZE,
                ),
                modifier = Modifier.weight(1f),
            )
            if (onCopyInstallCommand != null) {
                // Custom card chrome, not a page-contract action: the icon carries
                // the accessibility name and no text label reaches the action scan.
                Box(
                    Modifier
                        .clickable(role = Role.Button, onClick = onCopyInstallCommand)
                        .semantics { contentDescription = "复制安装命令" }
                        .padding(horizontal = PcMetrics.SECTION_GAP, vertical = PcMetrics.LABEL_GAP),
                ) {
                    PdshIconView(
                        PdshIcon.COPY,
                        PcMetrics.PAGE_INSET,
                        tokens.colors.textSecondary,
                        "复制安装命令",
                    )
                }
            }
        }
    }
}

@Composable
private fun PcPairingScanSection(
    state: PCPairingUiState,
    onScan: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        PcPrimaryButton(
            label = UiStrings.PC_PAIRING_SCAN,
            onClick = onScan,
            modifier = Modifier.testTag(PCPairingPageTags.SCAN),
        )
        Spacer(Modifier.height(PcMetrics.LABEL_GAP))
        PcPairingHint(PcLinkText.SCAN_HINT)
        if (state.stage == PCPairingStage.CAMERA_UNAVAILABLE) {
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            PcPairingHint(PcLinkText.CAMERA_UNAVAILABLE)
        }
    }
}

@Composable
private fun PcPairingOtherSection(
    state: PCPairingUiState,
    onToggle: () -> Unit,
    onLinkChange: (String) -> Unit,
    onPairWithLink: () -> Unit,
    onCodeChange: (String) -> Unit,
    onPairManually: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.TIGHT_GAP)) {
        SessionTextAction(
            label = if (state.otherWaysExpanded) UiStrings.PC_PAIRING_OTHER_COLLAPSE else UiStrings.PC_PAIRING_OTHER,
            onClick = onToggle,
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.testTag(PCPairingPageTags.OTHER),
        )
        if (state.otherWaysExpanded) {
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            BasicText(
                text = UiStrings.PC_PAIRING_LINK,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
            BasicTextField(
                value = state.pairingLink,
                onValueChange = onLinkChange,
                singleLine = true,
                textStyle = type.homeBody.copy(color = tokens.colors.textPrimary, fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(PcMetrics.FIELD_RADIUS))
                    .background(tokens.colors.surface)
                    .border(PcMetrics.HAIRLINE, tokens.colors.borderList, RoundedCornerShape(PcMetrics.FIELD_RADIUS))
                    .padding(horizontal = PcMetrics.FIELD_INSET, vertical = PcMetrics.FIELD_INSET)
                    .testTag(PCPairingPageTags.LINK_FIELD)
                    .semantics { contentDescription = UiStrings.PC_PAIRING_LINK },
                decorationBox = { inner ->
                    if (state.pairingLink.isEmpty()) {
                        BasicText(
                            text = PcLinkText.PAIRING_LINK_PLACEHOLDER,
                            style = type.homeBody.copy(color = tokens.colors.textTertiary, fontFamily = FontFamily.Monospace),
                        )
                    }
                    inner()
                },
            )
            Spacer(Modifier.height(PcMetrics.LABEL_GAP))
            SessionTextAction(
                label = UiStrings.PC_PAIRING_USE_LINK,
                onClick = onPairWithLink,
                tone = SessionActionTone.ACCENT,
                enabled = state.linkReady,
                modifier = Modifier.testTag(PCPairingPageTags.LINK_ACTION),
            )
            Spacer(Modifier.height(PcMetrics.SECTION_GAP))
            BasicText(
                text = UiStrings.PC_PAIRING_CODE,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
            )
            BasicTextField(
                value = state.pairingCode,
                onValueChange = onCodeChange,
                singleLine = true,
                textStyle = type.homeBody.copy(color = tokens.colors.textPrimary, fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(PcMetrics.FIELD_RADIUS))
                    .background(tokens.colors.surface)
                    .border(PcMetrics.HAIRLINE, tokens.colors.borderList, RoundedCornerShape(PcMetrics.FIELD_RADIUS))
                    .padding(horizontal = PcMetrics.FIELD_INSET, vertical = PcMetrics.FIELD_INSET)
                    .testTag(PCPairingPageTags.CODE_FIELD)
                    .semantics { contentDescription = UiStrings.PC_PAIRING_CODE },
                decorationBox = { inner ->
                    if (state.pairingCode.isEmpty()) {
                        BasicText(
                            text = PcLinkText.PAIRING_CODE_PLACEHOLDER,
                            style = type.homeBody.copy(color = tokens.colors.textTertiary, fontFamily = FontFamily.Monospace),
                        )
                    }
                    inner()
                },
            )
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            PcPairingHint(PcLinkText.MANUAL_CODE_HINT)
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            SessionTextAction(
                label = UiStrings.PC_PAIRING_MANUAL,
                onClick = onPairManually,
                tone = SessionActionTone.ACCENT,
                enabled = state.manualCodeReady,
                modifier = Modifier.testTag(PCPairingPageTags.MANUAL_ACTION),
            )
            Spacer(Modifier.height(PcMetrics.SECTION_GAP))
        }
    }
}

@Composable
private fun PcPairingJoiningSection(onCancel: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.width(PcMetrics.PROGRESS_SIZE).height(PcMetrics.PROGRESS_SIZE), strokeWidth = PcMetrics.PROGRESS_STROKE)
            Spacer(Modifier.width(PcMetrics.FIELD_INSET))
            BasicText(
                text = UiStrings.PC_PAIRING_JOINING,
                style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
            )
        }
        SessionTextAction(
            label = UiStrings.PC_PAIRING_CANCEL,
            onClick = onCancel,
            tone = SessionActionTone.DANGER,
            modifier = Modifier.testTag(PCPairingPageTags.CANCEL_PAIRING),
        )
    }
}

@Composable
private fun PcPairingConnectingSection(
    state: PCPairingUiState,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.width(PcMetrics.PROGRESS_SIZE).height(PcMetrics.PROGRESS_SIZE), strokeWidth = PcMetrics.PROGRESS_STROKE)
            Spacer(Modifier.width(PcMetrics.FIELD_INSET))
            BasicText(
                text = PcLinkText.pairingConnecting(state.connectingPcName.orEmpty()),
                style = type.homeBody.copy(
                    color = tokens.colors.textPrimary,
                    fontWeight = FontWeight.SemiBold,
                ),
            )
        }
        if (state.showOldPcHint) {
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            PcPairingHint(PcLinkText.PAIRING_OLD_PC_CONFIRM)
        }
        SessionTextAction(
            label = UiStrings.PC_PAIRING_CANCEL,
            onClick = onCancel,
            tone = SessionActionTone.DANGER,
            modifier = Modifier.testTag(PCPairingPageTags.CANCEL_PAIRING),
        )
    }
}

@Composable
private fun PcPairingInterruptionNotice() {
    PcPairingHint(PcLinkText.PAIRING_INTERRUPTED)
}

@Composable
private fun PcPairingPermissionSection() {
    PcPairingHint(PcLinkText.FULL_OWNER_WARNING)
}

@Composable
private fun PcPairingPairedSection(name: String, onDone: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.width(PcMetrics.PROGRESS_SIZE).height(PcMetrics.PROGRESS_SIZE)
                    .background(tokens.colors.success, CircleShape),
            )
            Spacer(Modifier.width(PcMetrics.SECTION_GAP))
            BasicText(
                text = "已连接 $name",
                style = type.homeBody.copy(
                    color = tokens.colors.success,
                    fontWeight = FontWeight.SemiBold,
                ),
            )
        }
        Spacer(Modifier.height(PcMetrics.SECTION_GAP))
        SessionTextAction(
            label = UiStrings.PC_PAIRING_DONE,
            onClick = onDone,
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.testTag(PCPairingPageTags.DONE),
        )
    }
}

@Composable
private fun PcPairingFailureSection(state: PCPairingUiState, onRetry: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.SECTION_GAP)) {
        BasicText(
            text = state.failureMessage.orEmpty(),
            style = type.homeBody.copy(color = tokens.colors.pageDanger),
        )
        if (state.interrupted && state.failureMessage != PcLinkText.PAIRING_INTERRUPTED) {
            Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
            PcPairingHint(PcLinkText.PAIRING_INTERRUPTED)
        }
        Spacer(Modifier.height(PcMetrics.TIGHT_GAP))
        SessionTextAction(
            label = UiStrings.PC_PAIRING_RETRY,
            onClick = onRetry,
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.testTag(PCPairingPageTags.RETRY),
        )
    }
}

@Composable
private fun PcPairingHint(text: String) {
    BasicText(
        text = text,
        style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textSecondary),
        modifier = Modifier.fillMaxWidth().padding(vertical = PcMetrics.TIGHT_GAP),
    )
}

/**
 * The page's primary capsule. It is a button wrapper (`label` first) so the page
 * structure checker reads the contract label, and it paints the shared pressed
 * token table instead of a Material ripple (`interaction.md` §6 rule 3).
 */
@Composable
internal fun PcPrimaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val interaction = remember { MutableInteractionSource() }
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = PcMetrics.PRIMARY_HEIGHT)
            .clip(shape)
            .primaryPressed(interaction, enabled, shape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = label,
            style = type.homeBody.copy(
                color = tokens.colors.primaryButtonInk,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            ),
            modifier = Modifier.padding(horizontal = PcMetrics.PAGE_INSET, vertical = PcMetrics.PRIMARY_VERTICAL),
        )
    }
}
