// PCLink UI state shared by the pairing page, the connected-computer page and
// the drawer's PC segment (P09/P28, GAP-35).
// SPDX-License-Identifier: MIT
//
// This file is deliberately plain Kotlin: no `:pclink` and no `:app` type crosses
// this API, so the host can map its client state onto it and a Robolectric test
// can drive the mutators without a relay. The Swift sources are provenance for
// the field meanings, never a second copy of the values: labels live in
// `UiStrings`, geometry in the page files.
package com.phonedsh.ui.page

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// ---------------------------------------------------------------------------
// Shared copy / pure presentation helpers
// ---------------------------------------------------------------------------

/**
 * The PCLink presentation strings that are computed rather than fixed labels.
 *
 * Fixed contract labels live in [com.phonedsh.ui.UiStrings]; only the sentences
 * whose wording depends on a value are here. Provenance is the Swift function
 * that builds each string (`PCWorkspaceBackend.swift:454-535`).
 */
public object PcLinkText {
    /** `PCLinkPairingPrompt.fullOwnerWarning` (`PCPairingPage.swift:202`). */
    public const val FULL_OWNER_WARNING: String =
        "连接后，这台手机可以完整使用这台电脑上的 DSH（对话、Shell、文件、审批与设置）。"

    /** `PCLinkWorkspaceText.pairingOldPCConfirm` (`PCPairingPage.swift:234`). */
    public const val PAIRING_OLD_PC_CONFIRM: String =
        "如果这台电脑仍要求确认，请在电脑上完成确认。"

    /** `PCLinkWorkspaceText.pairingInterrupted` (`PCPairingPage.swift:258`). */
    public const val PAIRING_INTERRUPTED: String =
        "连接中断，请保持此页面打开后重试。"

    /** `PCLinkWorkspaceText.resumeConnecting` (`PCDrawerSection.swift:63`). */
    public const val RESUME_CONNECTING: String =
        "这台电脑刚才在后台，正在重新连上。"

    /** `PCLinkWorkspaceText.cachedReconnecting` (`PCWorkspaceBackend.swift:497`). */
    public const val CACHED_RECONNECTING: String =
        "正在连接电脑，下面是上次的列表。"

    /** `PCLinkPresence.LONG_OFFLINE_HINT`; the exact §10 sentence (`PCWorkspaceBackend.swift:523`). */
    public const val LONG_OFFLINE: String =
        "电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。"

    /** `PCDrawerSection.swift:38-41`: the unpaired PC segment's one-line explanation. */
    public const val PAIR_DESCRIPTION: String =
        "连接后，这台手机可以继续电脑上的 DSH 会话。"

    /** `PCDrawerSection.swift:78-84`: the long-offline recovery hint. */
    public const val LONG_OFFLINE_RECOVERY: String =
        "可在 我的 › 已连接的电脑 里手动解除配对。"

    /** `PCWorkspaceBackend.swift:528`: `PCLinkPCUnpairedPrompt.text`. */
    public const val PC_UNPAIRED_PROMPT: String = "电脑已解除与此手机的配对"

    /** `HomeDrawer.swift:492`: the loose PC group's title. */
    public const val UNGROUPED: String = "未分组"

    /** `HomeDrawer.swift:456`: the PC list's honest empty state. */
    public const val NO_PC_SESSIONS: String = "还没有 PC 会话。点上面的「新会话」在电脑上新建一个。"

    /** `HomeDrawer.swift:241`: the PC segment's blocked 新会话 line before pairing. */
    public const val PC_NEW_SESSION_UNPAIRED: String = "连接电脑后可新建会话"

    /** `HomeDrawer.swift:242`: the PC segment's blocked 新会话 line while dialing. */
    public const val PC_NEW_SESSION_CONNECTING: String = "正在连接电脑"

    /** `HomeDrawer.swift:243`: the PC segment's blocked 新会话 line while offline. */
    public const val PC_NEW_SESSION_OFFLINE: String = "电脑离线，无法新建会话"

    /** `HomeDrawer.swift:436`: the PC list's loading row. */
    public const val LOADING_PC_SESSIONS: String = "正在读取 PC 会话…"

    /** `PCDrawerSection.swift:30`: the bounded resume title. */
    public const val CONNECTING_TITLE: String = "正在连接电脑"

    /** `PCDrawerSection.swift:49`: the offline card title. */
    public const val OFFLINE_TITLE: String = "电脑离线"

    /** `PCPairingPage.swift:55`: the toolbar close label. */
    public const val CLOSE: String = "关闭"

    /** `PCPairingPage.swift:87`: the scanner sheet's cancel label. */
    public const val CANCEL_SCANNER: String = "取消"

    /** `PCPairingPage.swift:150`: the permission/denied line. */
    public const val CAMERA_UNAVAILABLE: String =
        "相机不可用或未授权。请允许相机，或使用「其他方式」。"

    /** `PCPairingPage.swift:146`: the one line under the scan action. */
    public const val SCAN_HINT: String = "扫描终端里出现的二维码"

    /** `PCPairingPage.swift:187`: the manual code's lifetime. */
    public const val MANUAL_CODE_HINT: String = "16 位，单次使用，5 分钟内有效。"

    /** `PCPairingPage.swift:166`: the link field's placeholder. */
    public const val PAIRING_LINK_PLACEHOLDER: String = "pclink://pair?…"

    /** `PCPairingPage.swift:179`: the manual code field's placeholder. */
    public const val PAIRING_CODE_PLACEHOLDER: String = "XXXX-XXXX-XXXX-XXXX"

    /** `ConnectedComputerPage.swift:73`: the online status value. */
    public const val ONLINE: String = "在线"

    /** `ConnectedComputerPage.swift:75`: the status fallback. */
    public const val OFFLINE: String = "离线"

    /** `ConnectedComputerPage.swift:147`: a row with no measured value. */
    public const val UNKNOWN_VALUE: String = "—"

    /** `ConnectedComputerPage.swift:167`: the verified DSH version is not known yet. */
    public const val DSH_VERSION_UNKNOWN: String = "未获取（电脑离线）"

    /** `ConnectedComputerPage.swift:167`: an out-of-range but reported version. */
    public const val DSH_VERSION_UNVERIFIED_SUFFIX: String = "（未验证）"

    /** `ConnectedComputerPage.swift:141`: the 电脑 card's online footer. */
    public const val COMPUTER_ONLINE_FOOTER: String =
        "这台手机连接的是电脑上的 DSH 工作区，会话、审批和文件都在电脑上。"

    /** `ConnectedComputerPage.swift:143`: the 电脑 card's offline footer. */
    public const val COMPUTER_OFFLINE_FOOTER: String =
        "电脑离线时停在「PC」分段，不会自动切回手机。"

    /** `ConnectedComputerPage.swift:108`: the 本机 card footer (CCR-1: no fingerprint card). */
    public const val FINGERPRINT_FOOTER: String =
        "本机指纹用于核对这台手机；扫码或手动码本身就是配对确认，电脑不会再要求输入指纹。"

    /** `ConnectedComputerPage.swift:42`: the unpair confirmation's message. */
    public const val UNPAIR_CONFIRM_MESSAGE: String =
        "只会删除这台手机上的配对记录。电脑上的记录仍然有效；请同时在电脑上运行 pclink unpair，或先撤销全部配对再 rotate-identity。"

    /** `ConnectedComputerPage.swift:50`: the already-paired alert's message. */
    public const val ALREADY_PAIRED_MESSAGE: String =
        "同一时间只配对一台电脑。先解除当前电脑，才能配对新电脑。"

    /** `ConnectedComputerPage.swift:114`: the new-pairing action. */
    public const val PAIR_NEW_COMPUTER: String = "配对新电脑"

    /** `ConnectedComputerPage.swift:118`: the unpair action. */
    public const val UNPAIR: String = "解除配对"

    /** `ConnectedComputerPage.swift:134`: the empty state's action. */
    public const val CONNECT_COMPUTER: String = "连接电脑"

    /** `ConnectedComputerPage.swift:128`: the empty state's title. */
    public const val NO_COMPUTER: String = "还没有连接电脑"

    /** `ConnectedComputerPage.swift:130`: the empty state's instruction. */
    public const val NO_COMPUTER_HINT: String =
        "在电脑上运行 pclink pair 打开配对，然后用这台手机扫码或粘贴配对链接。"

    /** `ConnectedComputerPage.swift:37`: the unpair alert title. */
    public const val UNPAIR_CONFIRM_TITLE: String = "解除配对？"

    /** `ConnectedComputerPage.swift:48`: the already-paired alert title. */
    public const val ALREADY_PAIRED_TITLE: String = "这台手机已经配对了一台电脑"

    /** `ConnectedComputerPage.swift:54`: the unpair failure alert title. */
    public const val UNPAIR_FAILED_TITLE: String = "解除没有完成"

    /** `ConnectedComputerPage.swift:49`: acknowledge. */
    public const val KNOW_IT: String = "知道了"

    /** `ConnectedComputerPage.swift:50`: switch the pending unpair confirmation on. */
    public const val UNPAIR_CURRENT: String = "解除当前配对"

    /** `ConnectedComputerPage.swift:38`: the alert's cancel button. */
    public const val CANCEL: String = "取消"

    /** `PCLinkWorkspaceText.pairingConnecting(_:)` (`PCPairingPage.swift:227`). */
    public fun pairingConnecting(pcName: String): String = "正在连接 $pcName…"

    /** `PCLinkWorkspaceText.pairingMode(_:)` (`ConnectedComputerPage.swift:102`). */
    public fun pairingMode(mode: PcLinkPairingMode?): String = when (mode) {
        PcLinkPairingMode.QR -> "扫码"
        PcLinkPairingMode.MANUAL -> "手动码"
        PcLinkPairingMode.LEGACY_UNKNOWN, null -> "旧版配对（未记录方式）"
    }

    /**
     * `PCLinkWorkspaceText.pairedAtDisplay(_:)` (`ConnectedComputerPage.swift:103`).
     * The raw value is RFC 3339; an unparsable value is shown unchanged rather than
     * invented. The Chinese display pattern mirrors the baseline's long date/short
     * time in the app's zh copy.
     */
    public fun pairedAtDisplay(
        raw: String,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        if (raw.isBlank()) return UNKNOWN_VALUE
        return try {
            DateTimeFormatter.ofPattern("yyyy年M月d日 HH:mm", Locale.CHINA)
                .withZone(zone)
                .format(Instant.parse(raw))
        } catch (_: Exception) {
            raw
        }
    }

    /**
     * `PCLinkWorkspaceText.cachedOffline(capturedAt:)` (`PCWorkspaceBackend.swift:505-519`).
     * Today shows the time only, this year adds the date, an older year adds the
     * year; no capture time says the list is the last one without dating it.
     */
    public fun cachedOffline(
        capturedAtMilliseconds: Long?,
        nowMilliseconds: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        if (capturedAtMilliseconds == null) {
            return "电脑暂时连不上，下面是上次的列表。"
        }
        val captured = Instant.ofEpochMilli(capturedAtMilliseconds).atZone(zone)
        val now = Instant.ofEpochMilli(nowMilliseconds).atZone(zone)
        val pattern = when {
            captured.toLocalDate() == now.toLocalDate() -> "HH:mm"
            captured.year == now.year -> "M月d日 HH:mm"
            else -> "yyyy年M月d日 HH:mm"
        }
        val stamp = DateTimeFormatter.ofPattern(pattern, Locale.CHINA).withZone(zone)
            .format(Instant.ofEpochMilli(capturedAtMilliseconds))
        return "电脑暂时连不上，下面是 $stamp 的列表。"
    }

    /** `PCLinkWorkspaceText.offlineReason(_:)` (`PCWorkspaceBackend.swift:521-534`). */
    public fun offlineReason(reason: PcLinkOfflineReason?): String = when (reason) {
        null, PcLinkOfflineReason.NOT_STARTED -> "还没有连接电脑。"
        PcLinkOfflineReason.NETWORK -> "网络断开，正在重连。"
        PcLinkOfflineReason.PEER_OFFLINE -> "电脑离线。"
        PcLinkOfflineReason.REPLACED -> "这台电脑的连接被同一身份的新连接替换了。"
        PcLinkOfflineReason.AUTHENTICATION_FAILED -> "连接没有被电脑接受，请重新配对。"
        PcLinkOfflineReason.VERSION_UNSUPPORTED ->
            "这台电脑的 PCLink 版本或能力不受支持，请升级后再连接。"
        PcLinkOfflineReason.UNPAIRED_PROMPT -> PC_UNPAIRED_PROMPT
        is PcLinkOfflineReason.ProtocolError -> "连接协议出错：${reason.message}"
        is PcLinkOfflineReason.Storage -> "读取配对记录失败：${reason.message}"
    }

    /** `WorkspaceModels.swift:111`: the fallback title before a workspace baseline exists. */
    public fun pcWorkspaceTitle(pcName: String?): String {
        val name = pcName?.takeIf { it.isNotBlank() } ?: "电脑"
        return "PC 工作区 · $name"
    }
}

/**
 * `PCLinkManualCodeInput.format(_:)` (`PCPairingPage.swift:306`).
 *
 * Uppercases, drops separators and every non-alphanumeric character, caps the
 * input at the 16 characters the decoder accepts and re-inserts `-` between
 * groups of four. An incomplete tail keeps its partial group so the field never
 * deletes what the person is typing.
 */
public fun pcManualCodeInput(raw: String): String {
    val compact = raw.filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT).take(16)
    return compact.chunked(4).joinToString("-")
}

/** True once [pairingCode] carries the 16 characters `PCLinkManualCodeInput` accepts. */
public fun pcManualCodeComplete(pairingCode: String): Boolean =
    pairingCode.count { it.isLetterOrDigit() } == 16

// ---------------------------------------------------------------------------
// Drawer backend / presence
// ---------------------------------------------------------------------------

/**
 * The 手机 | PC selection, persisted by the host in `phone-dsh.drawer.backend`
 * (P18). `:lib` never writes a preference; it only reports the chosen value.
 */
@Immutable
public enum class PcDrawerBackend(
    /** The P18 value (`HomeDrawer.swift:725-726`). */
    public val preferenceValue: String,
) {
    /** `手机`: the phone workspace (`HomeDrawer.swift:725`). */
    PHONE("phone"),

    /** `PC`: the paired PC workspace (`HomeDrawer.swift:726`). */
    PC("pc"),
    ;

    public companion object {
        /** Reads the P18 value; an unknown or absent value starts on `phone` (§5.3). */
        public fun fromPreference(value: String?): PcDrawerBackend =
            if (value == PC.preferenceValue) PC else PHONE
    }
}

/**
 * The three presence values the drawer and the settings row report.
 *
 * `PcLinkPresenceState.settingsValue` is exactly `未配对` / `离线` / the online
 * name (`SettingsPage.swift:330-334`); the drawer's phase policy is
 * `PCLinkDrawerPolicy.phase` (`PCWorkspaceBackend.swift:657-671`).
 */
@Immutable
public enum class PcLinkPresence {
    /** No pairing record; the settings row says `未配对`. */
    UNPAIRED,

    /** A record exists and the PC is not reachable; the settings row says `离线`. */
    OFFLINE,

    /** Dialing/handshaking or the bounded resume; the settings row still says `离线`. */
    RECONNECTING,

    /** An established E2E session exists; the settings row shows the PC name. */
    ONLINE,
}

/**
 * Presence plus the PC name needed by the settings value and the fallback drawer
 * title (`WorkspaceModels.swift:76-114`).
 *
 * @property presence the three-value projection (`PCWorkspaceBackend.swift:657`).
 * @property pcName the verified `peer.hello` name, or `null` before pairing (`WorkspaceModels.swift:111`).
 */
@Immutable
public data class PcLinkPresenceState(
    public val presence: PcLinkPresence = PcLinkPresence.UNPAIRED,
    public val pcName: String? = null,
) {
    /** `已连接的电脑`'s trailing value: `未配对` / `离线` / `<name>` (`SettingsPage.swift:330-334`). */
    public val settingsValue: String
        get() = when (presence) {
            PcLinkPresence.UNPAIRED -> com.phonedsh.ui.UiStrings.PC_SETTINGS_VALUE_UNPAIRED
            PcLinkPresence.OFFLINE, PcLinkPresence.RECONNECTING ->
                com.phonedsh.ui.UiStrings.PC_SETTINGS_VALUE_OFFLINE
            PcLinkPresence.ONLINE -> pcName?.takeIf { it.isNotBlank() } ?: "电脑"
        }

    public companion object {
        /** No record. */
        public fun unpaired(): PcLinkPresenceState = PcLinkPresenceState()

        /** A record exists but the PC is unreachable. */
        public fun offline(pcName: String? = null): PcLinkPresenceState =
            PcLinkPresenceState(PcLinkPresence.OFFLINE, pcName)

        /** The verified `peer.hello` name is online. */
        public fun online(name: String): PcLinkPresenceState =
            PcLinkPresenceState(PcLinkPresence.ONLINE, name)

        /** Dialing/handshaking, including the bounded resume; never `电脑离线`. */
        public fun reconnecting(pcName: String? = null): PcLinkPresenceState =
            PcLinkPresenceState(PcLinkPresence.RECONNECTING, pcName)
    }
}

/** The §10 offline causes; a UI mirror, not a `:pclink` type (`PclinkClient.kt:54-63`). */
@Immutable
public sealed interface PcLinkOfflineReason {
    public data object NOT_STARTED : PcLinkOfflineReason
    public data object NETWORK : PcLinkOfflineReason
    public data object PEER_OFFLINE : PcLinkOfflineReason
    public data object REPLACED : PcLinkOfflineReason
    public data object AUTHENTICATION_FAILED : PcLinkOfflineReason
    public data object VERSION_UNSUPPORTED : PcLinkOfflineReason
    public data object UNPAIRED_PROMPT : PcLinkOfflineReason

    /** `offline.reason = protocolError` keeps the DSH message (`PclinkClient.kt:62`). */
    public data class ProtocolError(public val message: String) : PcLinkOfflineReason

    /** `offline.reason = storage` keeps the read failure (`PclinkClient.kt:63`). */
    public data class Storage(public val message: String) : PcLinkOfflineReason
}

/** The pairing modes shown by 配对方式 (`PclinkQr.kt:12-18`; nil is the legacy record). */
@Immutable
public enum class PcLinkPairingMode {
    QR,
    MANUAL,

    /** A record written before the mode was stored (`PCLinkWorkspaceText.pairingMode`). */
    LEGACY_UNKNOWN,
}

// ---------------------------------------------------------------------------
// Pairing page
// ---------------------------------------------------------------------------

/**
 * The pairing page's flow stages (`PCPairingPage.swift:32-70`).
 *
 * `OTHER_WAYS`, `PAIRING_LINK` and `PAIRING_CODE` are not stages in Swift; they
 * are the expanded `otherSection` and its two fields. They are named here so the
 * state-machine test can render the contract's each state without inventing an
 * extra screen.
 */
@Immutable
public enum class PCPairingStage {
    /** `case .idle, .joining` before any prompt (`PCPairingPage.swift:34`). */
    IDLE,

    /** The scanner sheet is presented (`PCPairingPage.swift:79-94`). */
    SCANNING,

    /** `cameraDenied` is on (`PCPairingPage.swift:150`). */
    CAMERA_UNAVAILABLE,

    /** `showOther` is on (`PCPairingPage.swift:159-192`). */
    OTHER_WAYS,

    /** The 配对链接 field is being edited (`PCPairingPage.swift:166`). */
    PAIRING_LINK,

    /** The 配对码 field is being edited (`PCPairingPage.swift:179`). */
    PAIRING_CODE,

    /** 手动连接 submitted the code (`PCPairingPage.swift:190`). */
    MANUAL,

    /** `case .connecting(prompt)` (`PCPairingPage.swift:224-240`). */
    CONNECTING,

    /** `case .paired(record)` (`PCPairingPage.swift:267-272`). */
    CONNECTED,

    /** `case .failed(message)` (`PCPairingPage.swift:278-290`). */
    FAILED,
}

/**
 * One immutable pairing-page snapshot. The host replaces it; the page never keeps
 * a second copy of the flow.
 *
 * @property stage the flow stage above (`PCPairingPage.swift:32-70`).
 * @property pairingLink the 配对链接 draft (`PCPairingPage.swift:20`).
 * @property pairingCode the formatted 配对码 draft (`PCPairingPage.swift:21,179-186`).
 * @property connectingPcName the `prompt.pcName` the connecting line names (`PCPairingPage.swift:227`).
 * @property connectedName the verified `record.peerName` in 已连接 (`PCPairingPage.swift:268`).
 * @property failureMessage `case .failed(message)`'s text (`PCPairingPage.swift:279`).
 * @property interrupted the lock/background or dropped-socket notice (`PCPairingPage.swift:73-77,258`).
 * @property showOldPcHint the pre-v1.6 confirmation line (`PCPairingPage.swift:233-239`).
 */
@Immutable
public data class PCPairingUiState(
    public val stage: PCPairingStage = PCPairingStage.IDLE,
    public val pairingLink: String = "",
    public val pairingCode: String = "",
    public val connectingPcName: String? = null,
    public val connectedName: String? = null,
    public val failureMessage: String? = null,
    public val interrupted: Boolean = false,
    public val showOldPcHint: Boolean = false,
) {
    /** True while the scanner sheet is on; the page underneath remains the idle body. */
    public val scanning: Boolean get() = stage == PCPairingStage.SCANNING

    /** True when the folded 其他方式 group is open (`showOther`). */
    public val otherWaysExpanded: Boolean
        get() = stage in setOf(
            PCPairingStage.OTHER_WAYS,
            PCPairingStage.PAIRING_LINK,
            PCPairingStage.PAIRING_CODE,
            PCPairingStage.MANUAL,
        )

    /** The 用链接配对 control is enabled only for a non-blank link (`PCPairingPage.swift:174`). */
    public val linkReady: Boolean get() = pairingLink.trim().isNotEmpty()

    /** The 手动连接 control is enabled only for 16 entered characters (`PCPairingPage.swift:192`). */
    public val manualCodeReady: Boolean get() = pcManualCodeComplete(pairingCode)

    /** `openScanner()` without camera access (`PCPairingPage.swift:300-310`). */
    public fun cameraUnavailable(): PCPairingUiState = copy(
        stage = PCPairingStage.CAMERA_UNAVAILABLE,
        interrupted = false,
        showOldPcHint = false,
    )

    /** The scanner sheet opened (`PCPairingPage.swift:79`). */
    public fun scannerOpened(): PCPairingUiState = copy(stage = PCPairingStage.SCANNING)

    /** The scanner sheet dismissed by 取消 (`PCPairingPage.swift:90`). */
    public fun scannerDismissed(): PCPairingUiState = copy(stage = PCPairingStage.IDLE)

    /** 其他方式 / 收起其他方式 (`PCPairingPage.swift:160-162`). */
    public fun toggleOtherWays(): PCPairingUiState = copy(
        stage = if (otherWaysExpanded) PCPairingStage.IDLE else PCPairingStage.OTHER_WAYS,
    )

    /** The 配对链接 field changed (`PCPairingPage.swift:166`). */
    public fun withPairingLink(value: String): PCPairingUiState = copy(
        stage = PCPairingStage.PAIRING_LINK,
        pairingLink = value,
    )

    /** The 配对码 field changed; the value is formatted exactly as the field does. */
    public fun withPairingCode(value: String): PCPairingUiState = copy(
        stage = PCPairingStage.PAIRING_CODE,
        pairingCode = pcManualCodeInput(value),
    )

    /** 用链接配对 submitted (`PCPairingPage.swift:172`). */
    public fun pairingWithLink(): PCPairingUiState =
        if (!linkReady) this else copy(stage = PCPairingStage.CONNECTING)

    /** 手动连接 submitted (`PCPairingPage.swift:190`). */
    public fun manualPairing(): PCPairingUiState =
        if (!manualCodeReady) this else copy(stage = PCPairingStage.MANUAL)

    /** The reconnect/approval round trip started (`PCPairingPage.swift:224`). */
    public fun connecting(pcName: String): PCPairingUiState = copy(
        stage = PCPairingStage.CONNECTING,
        connectingPcName = pcName,
        interrupted = false,
        showOldPcHint = false,
    )

    /** The durable record exists; only then may 已连接 render (`PCPairingPage.swift:267`). */
    public fun connected(name: String): PCPairingUiState = copy(
        stage = PCPairingStage.CONNECTED,
        connectedName = name,
        interrupted = false,
        showOldPcHint = false,
    )

    /** `case .failed(message)`; [interrupted] adds the standalone interruption line. */
    public fun failed(message: String, interrupted: Boolean = false): PCPairingUiState = copy(
        stage = PCPairingStage.FAILED,
        failureMessage = message,
        interrupted = interrupted,
        showOldPcHint = false,
    )

    /** 重试 clears the failure and re-opens the scanner (`PCPairingPage.swift:289-293`). */
    public fun retry(): PCPairingUiState = copy(
        stage = PCPairingStage.SCANNING,
        failureMessage = null,
        interrupted = false,
        showOldPcHint = false,
        pairingCode = "",
    )

    /** Lock/background during a hand-off (`PCPairingPage.swift:73-77`). */
    public fun interruptedDuringHandoff(): PCPairingUiState =
        if (stage == PCPairingStage.CONNECTING) copy(interrupted = true) else this

    /** A pre-v1.6 PC may still wait for its own operator (`PCPairingPage.swift:233-239`). */
    public fun oldPcHintVisible(): PCPairingUiState =
        if (stage == PCPairingStage.CONNECTING) copy(showOldPcHint = true) else this

    public companion object {
        /** The page before any prompt (`PCPairingPage.swift:34`). */
        public fun idle(): PCPairingUiState = PCPairingUiState()

        /** 其他方式 expanded (`PCPairingPage.swift:160`). */
        public fun otherWays(): PCPairingUiState = PCPairingUiState(stage = PCPairingStage.OTHER_WAYS)

        /** 配对链接 being edited. */
        public fun pairingLink(value: String = ""): PCPairingUiState =
            PCPairingUiState(stage = PCPairingStage.PAIRING_LINK, pairingLink = value)

        /** 配对码 being edited. */
        public fun pairingCode(value: String = ""): PCPairingUiState =
            PCPairingUiState(stage = PCPairingStage.PAIRING_CODE, pairingCode = pcManualCodeInput(value))

        /** 手动连接 submitted. */
        public fun manual(code: String): PCPairingUiState =
            PCPairingUiState(stage = PCPairingStage.MANUAL, pairingCode = pcManualCodeInput(code))
    }
}

// ---------------------------------------------------------------------------
// Connected computer
// ---------------------------------------------------------------------------

/**
 * One paired PC's display record.
 *
 * @property peerName `record.peerName` (`ConnectedComputerPage.swift:64`).
 * @property dshVersion the verified `peer.hello` version, never read from the record (`ConnectedComputerPage.swift:160-170`, CCR-2).
 * @property versionWarning the in-range warning text; when present the version keeps its 未验证 suffix (`ConnectedComputerPage.swift:90,167`).
 * @property ownFingerprint `models.pcLink.ownFingerprint` (`ConnectedComputerPage.swift:101`).
 * @property pairingMode `record.pairingMode` (`ConnectedComputerPage.swift:102`).
 * @property pairedAt `record.pairedAt`, RFC 3339 (`ConnectedComputerPage.swift:103`).
 * @property relayOrigin `record.relayOrigin` (`ConnectedComputerPage.swift:104`).
 * @property online `models.pcLink.isOnline` (`ConnectedComputerPage.swift:67-73`).
 * @property offlineReason the typed cause behind 离线; `null` renders the plain `离线` (`ConnectedComputerPage.swift:73,163-168`).
 * @property longOffline `models.pcLink.longOffline` (`ConnectedComputerPage.swift:78-84`).
 */
@Immutable
public data class PcLinkComputerRecord(
    public val peerName: String,
    public val dshVersion: String? = null,
    public val versionWarning: String? = null,
    public val ownFingerprint: String = "",
    public val pairingMode: PcLinkPairingMode? = null,
    public val pairedAt: String = "",
    public val relayOrigin: String = "",
    public val online: Boolean = false,
    public val offlineReason: PcLinkOfflineReason? = null,
    public val longOffline: Boolean = false,
) {
    /** `dshVersionText`: exact version, 未获取（电脑离线）, or 未验证 suffix (`ConnectedComputerPage.swift:160-170`). */
    public val dshVersionText: String
        get() {
            val version = dshVersion?.takeIf { it.isNotBlank() } ?: return PcLinkText.DSH_VERSION_UNKNOWN
            return if (versionWarning == null) version
            else version + PcLinkText.DSH_VERSION_UNVERIFIED_SUFFIX
        }

    /** 配对方式's value (`ConnectedComputerPage.swift:102`). */
    public val pairingModeText: String get() = PcLinkText.pairingMode(pairingMode)

    /** 配对时间's value; the raw RFC 3339 string is formatted, never shown as-is. */
    public val pairedAtText: String get() = PcLinkText.pairedAtDisplay(pairedAt)

    /** 在线状态's value: 在线, or the typed offline sentence (`ConnectedComputerPage.swift:73,163-168`). */
    public val connectionText: String
        get() = if (online) {
            PcLinkText.ONLINE
        } else {
            offlineReason?.let(PcLinkText::offlineReason) ?: PcLinkText.OFFLINE
        }

    /** A row's dash when the host has no value (`ConnectedComputerPage.swift:149`). */
    public fun display(value: String?): String =
        value?.takeIf { it.isNotBlank() } ?: PcLinkText.UNKNOWN_VALUE
}

/**
 * One immutable connected-computer snapshot (`ConnectedComputerPage.swift:10-57`).
 *
 * @property record the one pairing record, or `null` for the empty state (`ConnectedComputerPage.swift:20`).
 * @property unpairFailure the host-reported unpair error; non-null opens 解除没有完成 (`ConnectedComputerPage.swift:54-57`).
 */
@Immutable
public data class ConnectedComputerUiState(
    public val record: PcLinkComputerRecord? = null,
    public val unpairFailure: String? = null,
) {
    /** True when the page draws the empty section (`ConnectedComputerPage.swift:119-136`). */
    public val isEmpty: Boolean get() = record == null

    public companion object {
        /** No record: `还没有连接电脑` (`ConnectedComputerPage.swift:128`). */
        public fun empty(): ConnectedComputerUiState = ConnectedComputerUiState()

        /** One paired PC. */
        public fun paired(record: PcLinkComputerRecord): ConnectedComputerUiState =
            ConnectedComputerUiState(record = record)
    }
}

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------

/** The drawer list region's five phases (`PCDrawerPhase`, `PCWorkspaceBackend.swift:645-655`). */
@Immutable
public enum class PcDrawerPhase {
    /** 手机 is selected (`HomeDrawer.swift:178`). */
    PHONE,

    /** PC with no record (`HomeDrawer.swift:238-241`). */
    PAIR,

    /** Dialing/handshaking, including the bounded resume (`HomeDrawer.swift:246`). */
    CONNECTING,

    /** One dial failed or the grace expired (`HomeDrawer.swift:249`). */
    OFFLINE,

    /** PC online (`HomeDrawer.swift:243`). */
    READY,
}

/** The list region's four states once PC is ready (`PCWorkspaceBackend.swift:686-707`). */
@Immutable
public enum class PcDrawerListState {
    LOADING,
    ERROR,
    EMPTY,
    ROWS,
}

/**
 * One PC session row (`HomeDrawer.swift:533-565`).
 *
 * @property id `ManagedSession.id`, the stable switch key.
 * @property title the session title; the contract keeps it as data (`HomeDrawer.swift:533`).
 * @property relativeTime the drawer's trailing time, already localized by the host.
 * @property running whether the session has a turn in flight.
 * @property cwd the host path used for the longest-workspace-prefix fallback (`HomeDrawer.swift:360-370`).
 */
@Immutable
public data class PcDrawerSession(
    public val id: String,
    public val title: String,
    public val relativeTime: String? = null,
    public val running: Boolean = false,
    public val cwd: String? = null,
)

/**
 * One `workspace/follow` group (`PCLinkRosterWorkspace`).
 *
 * @property id the DSH workspace id.
 * @property title the DSH workspace title; the drawer groups by this, never a synthetic PC title (`HomeDrawer.swift:344-370`).
 * @property path the canonical host path used by the longest-prefix fallback (`PCWorkspaceBackend.swift:735-748`).
 * @property sessionIds the explicit membership, which wins over the cwd guess (`PCWorkspaceIndex.swift:182-185`).
 */
@Immutable
public data class PcDrawerWorkspace(
    public val id: String,
    public val title: String,
    public val path: String,
    public val sessionIds: List<String> = emptyList(),
)

/**
 * One rendered group: the DSH workspace title and its rows (`HomeDrawer.swift:480-500`).
 *
 * @property id the workspace id, or the loose group's synthetic id.
 * @property title the DSH workspace title (or 未分组 / the no-baseline fallback).
 * @property sessions the group's rows in host order.
 */
@Immutable
public data class PcDrawerGroup(
    public val id: String,
    public val title: String,
    public val sessions: List<PcDrawerSession>,
)

/**
 * Everything the 手机 | PC segment and the PC list region need. `:lib` only
 * reports the selection; the host persists it in `phone-dsh.drawer.backend`
 * (P18) and supplies the next snapshot.
 *
 * @property selected the persisted backend selection (`HomeDrawer.swift:725-726`).
 * @property presence the three-value PC reachability (`PCWorkspaceBackend.swift:657`).
 * @property sessions the **PC scope's** rows only, never the phone fallback (`WorkspaceModels.swift:86-93`).
 * @property workspaces the `workspace/follow` baseline for grouping (`HomeDrawer.swift:344-370`).
 * @property cachedListNote the one-line stale-list note, or `null` when the list speaks for itself.
 * @property loading whether a PC `session/list` is in flight (`HomeDrawer.swift:419-433`).
 * @property error the failed PC read; an error is never the "no sessions" empty state.
 * @property listState an explicit projection, or `null` to derive it from [loading]/[error]/[sessions].
 * @property offlineReason the typed cause shown by the offline card (`ConnectedComputerPage.swift:163-168`).
 * @property longOffline whether the 10-minute / connection-screen latch is on (`PCDrawerSection.swift:50-55`).
 */
@Immutable
public data class PcDrawerUiState(
    public val selected: PcDrawerBackend = PcDrawerBackend.PHONE,
    public val presence: PcLinkPresenceState = PcLinkPresenceState(),
    public val sessions: List<PcDrawerSession> = emptyList(),
    public val workspaces: List<PcDrawerWorkspace> = emptyList(),
    public val cachedListNote: String? = null,
    public val loading: Boolean = false,
    public val error: String? = null,
    public val listState: PcDrawerListState? = null,
    public val offlineReason: PcLinkOfflineReason? = null,
    public val longOffline: Boolean = false,
) {
    /** `PCLinkDrawerPolicy.phase(selected:hasRecord:presence:)` (`PCWorkspaceBackend.swift:657`). */
    public val phase: PcDrawerPhase
        get() = PcLinkDrawerPolicy.phase(selected, presence)

    /** The PC scope's row count; the state card decision uses only this (`PCWorkspaceBackend.swift:677`). */
    public val pcRowCount: Int get() = sessions.size

    /** Whether the list region is replaced by the empty/offline card (`PCWorkspaceBackend.swift:675`). */
    public val showsStateCard: Boolean
        get() = PcLinkDrawerPolicy.showsStateCard(phase, pcRowCount)

    /** The derived list state, unless the host already projected one (`PCWorkspaceBackend.swift:697`). */
    public val resolvedListState: PcDrawerListState
        get() = listState ?: PcLinkDrawerPolicy.listState(loading, error, sessions.size)

    /**
     * `HomeDrawer.swift:236-256`: why 新会话 is unavailable on the PC segment,
     * or `null` when the PC can create. The phone segment keeps the host's
     * existing engine/turn gate (`HomeDrawerFacts.newSessionBlockedReason`);
     * this property answers only for the PC backend, so a stopped phone engine
     * never disables a PC create and an offline PC never falls back to 手机.
     */
    public val newSessionBlockedReason: String?
        get() = if (selected != PcDrawerBackend.PC) {
            null
        } else {
            when (phase) {
                PcDrawerPhase.PAIR -> PcLinkText.PC_NEW_SESSION_UNPAIRED
                PcDrawerPhase.CONNECTING -> PcLinkText.PC_NEW_SESSION_CONNECTING
                PcDrawerPhase.OFFLINE -> PcLinkText.PC_NEW_SESSION_OFFLINE
                PcDrawerPhase.READY, PcDrawerPhase.PHONE -> null
            }
        }

    /** The grouped PC rows; empty on the 手机 segment (`HomeDrawer.swift:480-500`). */
    public val groups: List<PcDrawerGroup>
        get() = if (selected == PcDrawerBackend.PC) {
            PcLinkDrawerPolicy.groups(sessions, workspaces, presence.pcName)
        } else {
            emptyList()
        }
}

/**
 * The pure drawer policy (`PCLinkDrawerPolicy`, `PCWorkspaceBackend.swift:656-750`).
 *
 * The host owns the live list; this object only decides presentation, so the
 * unpaired/offline/long-offline paths are testable on a JVM without a relay.
 */
public object PcLinkDrawerPolicy {
    /** `phase(selected:hasRecord:presence:)` (`PCWorkspaceBackend.swift:657-671`). */
    public fun phase(
        selected: PcDrawerBackend,
        hasRecord: Boolean,
        presence: PcLinkPresence,
    ): PcDrawerPhase {
        if (selected != PcDrawerBackend.PC) return PcDrawerPhase.PHONE
        if (!hasRecord) return PcDrawerPhase.PAIR
        return when (presence) {
            PcLinkPresence.ONLINE -> PcDrawerPhase.READY
            PcLinkPresence.RECONNECTING -> PcDrawerPhase.CONNECTING
            PcLinkPresence.OFFLINE -> PcDrawerPhase.OFFLINE
            PcLinkPresence.UNPAIRED -> PcDrawerPhase.PAIR
        }
    }

    /** [phase] over the UI presence value; `UNPAIRED` means no record. */
    public fun phase(selected: PcDrawerBackend, presence: PcLinkPresenceState): PcDrawerPhase =
        phase(selected, presence.presence != PcLinkPresence.UNPAIRED, presence.presence)

    /**
     * `showsStateCard(phase:pcRowCount:)` (`PCWorkspaceBackend.swift:675-683`).
     *
     * [pcRowCount] must be the PC scope's rows: falling back to the phone list
     * would hide the 连接电脑 card behind phone sessions.
     */
    public fun showsStateCard(phase: PcDrawerPhase, pcRowCount: Int): Boolean = when (phase) {
        PcDrawerPhase.PHONE, PcDrawerPhase.READY -> false
        PcDrawerPhase.PAIR, PcDrawerPhase.CONNECTING, PcDrawerPhase.OFFLINE -> pcRowCount == 0
    }

    /** `cachedListNote(presence:capturedAt:hasRows:)` (`PCWorkspaceBackend.swift:689-702`). */
    public fun cachedListNote(
        presence: PcLinkPresence,
        capturedAtMilliseconds: Long?,
        hasRows: Boolean,
        nowMilliseconds: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String? {
        if (!hasRows) return null
        return when (presence) {
            PcLinkPresence.ONLINE, PcLinkPresence.UNPAIRED -> null
            PcLinkPresence.RECONNECTING -> PcLinkText.CACHED_RECONNECTING
            PcLinkPresence.OFFLINE -> PcLinkText.cachedOffline(capturedAtMilliseconds, nowMilliseconds, zone)
        }
    }

    /** `listState(isLoading:error:sessionCount:)` (`PCWorkspaceBackend.swift:697-707`). */
    public fun listState(isLoading: Boolean, error: String?, sessionCount: Int): PcDrawerListState {
        if (isLoading && sessionCount == 0) return PcDrawerListState.LOADING
        if (error != null && sessionCount == 0) return PcDrawerListState.ERROR
        if (sessionCount == 0) return PcDrawerListState.EMPTY
        return PcDrawerListState.ROWS
    }

    /**
     * The grouping rule (§5.4, `PCWorkspaceIndex.swift:15-19`): explicit
     * `workspace/follow` membership first, then the longest matching workspace
     * path at a component boundary; everything else is one 未分组 group.
     */
    public fun groups(
        sessions: List<PcDrawerSession>,
        workspaces: List<PcDrawerWorkspace>,
        pcName: String? = null,
    ): List<PcDrawerGroup> {
        val workspaceBySession = sessions.associate { session ->
            session.id to workspaceIdFor(session, workspaces)
        }
        val loose = sessions.filter { workspaceBySession[it.id] == null }
        val groups = workspaces.map { workspace ->
            PcDrawerGroup(
                id = workspace.id,
                title = workspace.title.trim().ifEmpty { PcLinkText.UNGROUPED },
                sessions = sessions.filter { workspaceBySession[it.id] == workspace.id },
            )
        }
        if (loose.isEmpty()) return groups
        val looseTitle = if (workspaces.isEmpty()) PcLinkText.pcWorkspaceTitle(pcName) else PcLinkText.UNGROUPED
        return groups + PcDrawerGroup("__ungrouped__", looseTitle, loose)
    }

    /** Membership first, then longest cwd prefix (`PCWorkspaceBackend.swift:735-748`). */
    public fun workspaceIdFor(session: PcDrawerSession, workspaces: List<PcDrawerWorkspace>): String? {
        workspaces.firstOrNull { session.id in it.sessionIds }?.let { return it.id }
        val cwd = session.cwd?.takeIf { it.isNotEmpty() } ?: return null
        val matches = workspaces.filter { workspace ->
            val path = workspace.path
            path.isNotEmpty() &&
                (path == cwd || cwd.startsWith(if (path.endsWith("/")) path else "$path/"))
        }
        return matches.maxByOrNull { it.path.length }?.id
    }
}
