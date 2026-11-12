// SPDX-License-Identifier: MIT
// The one mapping from the App-side PC workspace state to the plain `:lib` page
// state (design §6 C5). The controller (and `:pclink` below it) never leaks into
// the published AAR: this file is the host half that turns a `PcWorkspaceState`
// snapshot into `PCPairingUiState`, `ConnectedComputerUiState`, `PcDrawerUiState`
// and the 已连接的电脑 row value.
//
// Every function here is pure (a snapshot in, an immutable page state out). The
// host owns the draft fields that are page-local (the 配对链接 / 配对码 text and
// the scanner sheet); they are passed in as [PCPairingUiState] and preserved
// unless the controller has a stronger fact. Callbacks to controller intents are
// the small helpers at the bottom, so the composition root does not re-derive a
// transition the page already owns.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkOfflineReason
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ConnectedComputerUiState
import com.phonedsh.ui.page.PCPairingStage
import com.phonedsh.ui.page.PCPairingUiState
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerSession
import com.phonedsh.ui.page.PcDrawerUiState
import com.phonedsh.ui.page.PcDrawerWorkspace
import com.phonedsh.ui.page.PcLinkComputerRecord
import com.phonedsh.ui.page.PcLinkDrawerPolicy
import com.phonedsh.ui.page.PcLinkOfflineReason
import com.phonedsh.ui.page.PcLinkPairingMode
import com.phonedsh.ui.page.PcLinkPresence
import com.phonedsh.ui.page.PcLinkPresenceState
import com.phonedsh.ui.page.PcLinkText
import java.time.Instant
import java.time.ZoneId

// ---------------------------------------------------------------------------
// Presence and the settings row
// ---------------------------------------------------------------------------

/**
 * The three-value projection shared by the drawer and the settings row.
 *
 * `UNPAIRED` comes from no record, not from a reachability value; an existing
 * record that is not online keeps its name in the page state (the row's copy
 * rule lives in [PcLinkPresenceState.settingsValue], matching
 * `SettingsPage.swift:362-365`). `RECONNECTING` stays [PcLinkPresence.RECONNECTING]
 * because it is not a claim that the PC is offline.
 */
internal fun PcWorkspaceState.toPcLinkPresenceState(): PcLinkPresenceState {
    val name = presence.computerName
    if (presence.isUnpaired || name == null) return PcLinkPresenceState.unpaired()
    return when (presence.reachability) {
        PcReachability.ONLINE -> PcLinkPresenceState.online(name)
        PcReachability.RECONNECTING -> PcLinkPresenceState.reconnecting(name)
        PcReachability.OFFLINE -> PcLinkPresenceState.offline(name)
    }
}

/**
 * 已连接的电脑's trailing value: `未配对` / `离线` / the verified `peer.hello`
 * name (`SettingsPage.swift:362-365`). `null` only when this host has no PC
 * workspace seam at all; the settings row then keeps its honest 未知.
 */
internal fun PcWorkspaceState.toPcSettingsValue(): String =
    toPcLinkPresenceState().settingsValue

// ---------------------------------------------------------------------------
// Pairing page
// ---------------------------------------------------------------------------

/**
 * Maps the controller's serialized pairing flow onto the page's immutable state
 * (`PCPairingPage.swift:32-70`).
 *
 * [ui] carries the page-local draft and the expanded scanner/other-ways stage.
 * A controller fact always wins over a draft: a durable record becomes
 * [PCPairingStage.CONNECTED], a failed phase becomes [PCPairingStage.FAILED],
 * and any busy phase becomes [PCPairingStage.CONNECTING]. When the scanner is
 * open but the camera is denied/absent the page falls back to
 * [PCPairingStage.CAMERA_UNAVAILABLE] instead of showing a fake preview.
 *
 * The DSH version is deliberately absent here: the pairing page names the
 * record only after a durable write.
 */
internal fun PcWorkspaceState.toPcPairingUiState(
    ui: PCPairingUiState = PCPairingUiState(),
): PCPairingUiState {
    val connectedName = record?.name
        ?: pairing.prompt?.pcName
        ?: presence.computerName
    if (record != null || pairing.phase == PcPairingPhase.COMPLETED) {
        return ui.connected(connectedName ?: PcLinkText.UNKNOWN_VALUE)
    }
    val promptName = pairing.prompt?.pcName ?: presence.computerName
    when (pairing.phase) {
        PcPairingPhase.FAILED -> {
            val error = pairing.error ?: lastError
            val message = error?.message?.takeIf { it.isNotBlank() }
                ?: PcLinkText.PAIRING_INTERRUPTED
            val interrupted = error?.code in INTERRUPTED_PAIRING_CODES
            return ui.failed(message, interrupted = interrupted)
        }

        PcPairingPhase.JOINING,
        PcPairingPhase.WAITING_FOR_PC,
        PcPairingPhase.READY_TO_CONFIRM,
        PcPairingPhase.AUTHENTICATING,
        PcPairingPhase.AWAITING_CONFIRMATION,
        -> {
            val connecting = ui.connecting(promptName.orEmpty())
            return if (pairingUpgradeHint != null) connecting.oldPcHintVisible() else connecting
        }

        PcPairingPhase.IDLE,
        PcPairingPhase.COMPLETED,
        -> Unit
    }
    if (ui.stage == PCPairingStage.SCANNING && camera != PcCameraAvailability.AVAILABLE) {
        return ui.cameraUnavailable()
    }
    return ui
}

/** The client's transient drop/retry codes; the page says 连接中断 for these. */
private val INTERRUPTED_PAIRING_CODES: Set<String> = setOf(
    "peer_offline",
    "unavailable",
    "connection",
)

// ---------------------------------------------------------------------------
// Connected-computer page
// ---------------------------------------------------------------------------

/**
 * Maps the one paired record onto 已连接的电脑 (`ConnectedComputerPage.swift:10-57`).
 *
 * The version is [PcWorkspaceState.peerDshVersion], which the controller only
 * fills from the verified `peer.hello`/version warning — never from the pairing
 * record (CCR-2). [unpairFailure] is the host's attempt result, not any other
 * workspace error, so the alert cannot appear for a failed roster read.
 */
internal fun PcWorkspaceState.toConnectedComputerUiState(
    unpairFailure: String? = null,
): ConnectedComputerUiState {
    val paired = record
        ?: return ConnectedComputerUiState(unpairFailure = unpairFailure)
    val mode = when (paired.pairingMode) {
        "qr" -> PcLinkPairingMode.QR
        "manual" -> PcLinkPairingMode.MANUAL
        else -> PcLinkPairingMode.LEGACY_UNKNOWN
    }
    return ConnectedComputerUiState(
        record = PcLinkComputerRecord(
            peerName = paired.name,
            dshVersion = peerDshVersion,
            versionWarning = null,
            ownFingerprint = ownFingerprint.orEmpty(),
            pairingMode = mode,
            pairedAt = paired.pairedAt,
            relayOrigin = paired.relayOrigin,
            online = presence.isOnline,
            offlineReason = presence.offlineReason?.toPcLinkOfflineReason(),
            longOffline = presence.longOffline,
        ),
        unpairFailure = unpairFailure,
    )
}

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------

/**
 * Maps the persisted backend, presence and the PC-scope roster onto the drawer's
 * `PcDrawerUiState` (`PCWorkspaceBackend.swift:656-750`).
 *
 * The rows are the PC scope only: this never falls back to the phone's session
 * list. Grouping is the shared [PcLinkDrawerPolicy] rule (explicit membership →
 * longest cwd prefix → 未分组), and the groups keep the DSH `workspaceOrder` so
 * the drawer lists workspaces in the order the PC reported.
 */
internal fun PcWorkspaceState.toPcDrawerUiState(
    nowMilliseconds: Long = System.currentTimeMillis(),
    zone: ZoneId = ZoneId.systemDefault(),
): PcDrawerUiState {
    val presenceState = toPcLinkPresenceState()
    val sessions = roster.sessions.map { row ->
        PcDrawerSession(
            id = row.id,
            title = row.title,
            relativeTime = relativePcTime(row.updatedAtMilliseconds, nowMilliseconds, zone),
            running = row.running,
            cwd = row.cwd,
        )
    }
    return PcDrawerUiState(
        selected = backend.toPcDrawerBackend(),
        presence = presenceState,
        sessions = sessions,
        workspaces = orderedWorkspaces().map { workspace ->
            PcDrawerWorkspace(
                id = workspace.id,
                title = workspace.title,
                path = workspace.path,
                sessionIds = workspace.sessionIds,
            )
        },
        cachedListNote = PcLinkDrawerPolicy.cachedListNote(
            presence = presenceState.presence,
            capturedAtMilliseconds = rosterCapturedAtMilliseconds,
            hasRows = sessions.isNotEmpty(),
            nowMilliseconds = nowMilliseconds,
            zone = zone,
        ),
        loading = rosterLoading,
        error = rosterError?.let { it.message.ifBlank { it.code } },
        offlineReason = presence.offlineReason?.toPcLinkOfflineReason(),
        longOffline = presence.longOffline,
    )
}

/** DSH's workspace order first, then any workspace the order did not name. */
private fun PcWorkspaceState.orderedWorkspaces(): List<PcWorkspaceRow> {
    if (roster.workspaceOrder.isEmpty()) return roster.workspaces
    val byId = roster.workspaces.associateBy { it.id }
    val ordered = roster.workspaceOrder.distinct().mapNotNull(byId::get)
    val listed = ordered.mapTo(HashSet()) { it.id }
    return ordered + roster.workspaces.filterNot { it.id in listed }
}

/**
 * The drawer's one relative timestamp. `0`/unset becomes no time at all rather
 * than 刚刚: a row that never reported an update is not "updated now".
 */
private fun relativePcTime(
    updatedAtMilliseconds: Double,
    nowMilliseconds: Long,
    zone: ZoneId,
): String? {
    if (updatedAtMilliseconds <= 0.0) return null
    val updated = updatedAtMilliseconds.toLong()
    val delta = nowMilliseconds - updated
    return when {
        delta < MINUTE_MILLIS -> UiStrings.JUST_NOW
        delta < HOUR_MILLIS -> UiStrings.MINUTES_AGO.format(delta / MINUTE_MILLIS)
        delta < DAY_MILLIS -> UiStrings.HOURS_AGO.format(delta / HOUR_MILLIS)
        else -> {
            val date = Instant.ofEpochMilli(updated).atZone(zone)
            UiStrings.MONTH_DAY.format(date.monthValue, date.dayOfMonth)
        }
    }
}

private const val MINUTE_MILLIS: Long = 60_000
private const val HOUR_MILLIS: Long = 3_600_000
private const val DAY_MILLIS: Long = 86_400_000

// ---------------------------------------------------------------------------
// Value conversions and controller intents
// ---------------------------------------------------------------------------

/** `:lib`'s segment value → the P18 `PcBackend`. */
internal fun PcDrawerBackend.toPcBackend(): PcBackend = when (this) {
    PcDrawerBackend.PHONE -> PcBackend.PHONE
    PcDrawerBackend.PC -> PcBackend.PC
}

/** The persisted P18 value → the drawer's segment. */
internal fun PcBackend.toPcDrawerBackend(): PcDrawerBackend = when (this) {
    PcBackend.PHONE -> PcDrawerBackend.PHONE
    PcBackend.PC -> PcDrawerBackend.PC
}

/** `:pclink`'s offline cause → the page's typed mirror. */
internal fun PclinkOfflineReason.toPcLinkOfflineReason(): PcLinkOfflineReason = when (this) {
    PclinkOfflineReason.NotStarted -> PcLinkOfflineReason.NOT_STARTED
    PclinkOfflineReason.Network -> PcLinkOfflineReason.NETWORK
    PclinkOfflineReason.PeerOffline -> PcLinkOfflineReason.PEER_OFFLINE
    PclinkOfflineReason.Replaced -> PcLinkOfflineReason.REPLACED
    PclinkOfflineReason.AuthenticationFailed -> PcLinkOfflineReason.AUTHENTICATION_FAILED
    PclinkOfflineReason.VersionUnsupported -> PcLinkOfflineReason.VERSION_UNSUPPORTED
    PclinkOfflineReason.UnpairedPrompt -> PcLinkOfflineReason.UNPAIRED_PROMPT
    is PclinkOfflineReason.ProtocolError -> PcLinkOfflineReason.ProtocolError(message)
    is PclinkOfflineReason.Storage -> PcLinkOfflineReason.Storage(message)
}

/**
 * 扫码连接's one intent: ask the controller whether the camera can be used and
 * report the page stage it implies. A denied/absent camera is a page state, not
 * a silent no-op; the caller raises the one runtime prompt when the answer is
 * [PcCameraAvailability.DENIED].
 */
internal fun PcWorkspaceController.startPcScan(
    ui: PCPairingUiState = PCPairingUiState(),
): PCPairingUiState = if (checkCameraForScanning()) {
    ui.scannerOpened()
} else {
    ui.cameraUnavailable()
}

/** 用链接配对: report the connecting stage and hand the link to the client. */
internal fun PcWorkspaceController.pairWithPcLink(ui: PCPairingUiState): PCPairingUiState {
    if (!ui.linkReady) return ui
    startPairing(ui.pairingLink)
    return ui.pairingWithLink()
}

/** 手动连接: format the 16 characters and hand them to the client. */
internal fun PcWorkspaceController.pairWithPcCode(ui: PCPairingUiState): PCPairingUiState {
    if (!ui.manualCodeReady) return ui
    startPairingCode(ui.pairingCode.filter { it.isLetterOrDigit() })
    return ui.manualPairing()
}

/** The scanner decoded a QR payload; it still has to parse as `pclink://pair?`. */
internal fun PcWorkspaceController.pairWithPcQr(payload: String): PCPairingUiState {
    startPairingQr(payload)
    return PCPairingUiState().scannerDismissed()
}

/** 取消配对, including the page's own draft reset. */
internal fun PcWorkspaceController.cancelPcPairing(): PCPairingUiState {
    cancelPairing()
    return PCPairingUiState()
}

/** 重试: return the controller to idle, then re-open the scanner honestly. */
internal fun PcWorkspaceController.retryPcPairing(ui: PCPairingUiState): PCPairingUiState {
    cancelPairing()
    clearError()
    return startPcScan(ui.retry())
}

/** The durable completion is dismissed; the controller keeps the record. */
internal fun PcWorkspaceController.finishPcPairing(): PCPairingUiState = PCPairingUiState()

/** 手机 | PC: the controller persists the P18 value before publishing it. */
internal fun PcWorkspaceController.selectPcBackend(backend: PcDrawerBackend) {
    selectBackend(backend.toPcBackend())
}

/** The drawer's 重试: one PC `session/list` read, never the phone list. */
internal fun PcWorkspaceController.retryPcRoster() {
    refreshRoster()
}

/** 解除配对 after the page's confirmation alert. */
internal fun PcWorkspaceController.unpairPc() {
    clearError()
    unpair()
}

/** The settings/connection-screen latch (`ConnectedComputerPage.swift:32`). */
internal fun PcWorkspaceController.connectionScreenOpened() {
    markConnectionScreenOpened()
}
