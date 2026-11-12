// SPDX-License-Identifier: MIT
// The App-side PC workspace engine (design §6 C5). It owns the PCLink client's
// state projection, the drawer/menu intents and the P18 writes; it does not own
// any Compose page and does not depend on a `:lib` UI type. The integrator maps
// [PcWorkspaceState] to `PcLinkUiState` afterwards.
//
// The controller is deliberately Android-free (no Context/Log/Keystore): its
// inputs are a `PcLinkClientPort`, the C4 transport adapter, the P18 store and
// the diagnostics log, so the JVM suite drives the real state machine with
// fakes. `PcLinkWorkspace` is the Android composition root that supplies the
// real `PclinkClient`, `PclinkRpc` and `PclinkDshTransport`.
package com.phonedsh.probe.pc

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.pclink.PclinkClientState
import com.phonedsh.pclink.PclinkClientStatus
import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkOfflineReason
import com.phonedsh.pclink.PclinkPairingPhase
import com.phonedsh.pclink.PclinkPairingPrompt
import com.phonedsh.pclink.PclinkPairingResult
import com.phonedsh.pclink.PclinkPairingUpdate
import com.phonedsh.pclink.PclinkPresence
import com.phonedsh.pclink.PclinkPresenceSnapshot
import com.phonedsh.pclink.PclinkReachability
import com.phonedsh.pclink.PclinkPairingRecord
import com.phonedsh.pclink.PclinkRpcError
import com.phonedsh.pclink.PclinkNotice
import com.phonedsh.pclink.PclinkRosterCacheEntry
import com.phonedsh.pclink.PclinkRosterSession
import com.phonedsh.pclink.PclinkRosterSnapshot
import com.phonedsh.pclink.PclinkRosterWorkspace
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

// ---- Plain App-side state (mapped to `PcLinkUiState` by the integrator) ----

/** The three reachability values; there is no fourth UI value (§10). */
internal enum class PcReachability { ONLINE, RECONNECTING, OFFLINE }

/** One display-safe error value; never a title, prompt or key. */
internal data class PcWorkspaceError(
    val code: String,
    val message: String,
    val retryable: Boolean = false,
)

/**
 * The phone's projection of the paired PC. `settingsValue` is the settings row's
 * exact value rule: `未配对` / `离线` / `<name>` (design §6 C5 settings).
 * `reconnecting` keeps the name (it is not a claim that the PC is offline).
 */
internal data class PcPresence(
    val reachability: PcReachability = PcReachability.OFFLINE,
    val settingsValue: String = UNPAIRED_LABEL,
    val computerName: String? = null,
    val longOffline: Boolean = false,
    val longOfflineHint: String? = null,
    val offlineReason: PclinkOfflineReason? = null,
    val lastSeenAtMilliseconds: Long? = null,
) {
    val isUnpaired: Boolean get() = computerName == null
    val isOnline: Boolean get() = reachability == PcReachability.ONLINE
    val isOffline: Boolean get() = reachability == PcReachability.OFFLINE

    companion object {
        const val UNPAIRED_LABEL: String = "未配对"
        const val OFFLINE_LABEL: String = "离线"

        fun unpaired(): PcPresence = PcPresence()

        fun from(status: PclinkClientStatus, snapshot: PclinkPresenceSnapshot): PcPresence {
            val record = status.record
                ?: return PcPresence(
                    reachability = PcReachability.OFFLINE,
                    settingsValue = UNPAIRED_LABEL,
                    longOffline = false,
                    longOfflineHint = null,
                )
            val reachability = when (snapshot.reachability) {
                PclinkReachability.ONLINE -> PcReachability.ONLINE
                PclinkReachability.RECONNECTING -> PcReachability.RECONNECTING
                PclinkReachability.OFFLINE -> PcReachability.OFFLINE
            }
            return PcPresence(
                reachability = reachability,
                settingsValue = if (reachability == PcReachability.OFFLINE) {
                    OFFLINE_LABEL
                } else {
                    record.peerName
                },
                computerName = record.peerName,
                longOffline = snapshot.longOffline,
                longOfflineHint = snapshot.longOfflineHint,
                offlineReason = snapshot.offlineReason,
                lastSeenAtMilliseconds = snapshot.lastSeenAtMilliseconds,
            )
        }
    }
}

internal data class PcPairedComputer(
    val name: String,
    val machineId: String,
    val fingerprint: String,
    val pairedAt: String,
    val relayOrigin: String,
    val pairingMode: String?,
)

internal data class PcPairingPromptInfo(
    val id: String,
    val mode: String,
    val relayOrigin: String,
    val pcName: String,
    val pcMachineId: String,
    val ownFingerprint: String,
    val warningText: String,
    val expiresAtMilliseconds: Long,
)

internal enum class PcPairingPhase {
    IDLE,
    JOINING,
    WAITING_FOR_PC,
    READY_TO_CONFIRM,
    AUTHENTICATING,
    AWAITING_CONFIRMATION,
    COMPLETED,
    FAILED,
}

internal data class PcPairingState(
    val phase: PcPairingPhase = PcPairingPhase.IDLE,
    val prompt: PcPairingPromptInfo? = null,
    val error: PcWorkspaceError? = null,
) {
    val isBusy: Boolean
        get() = phase in setOf(
            PcPairingPhase.JOINING,
            PcPairingPhase.WAITING_FOR_PC,
            PcPairingPhase.READY_TO_CONFIRM,
            PcPairingPhase.AUTHENTICATING,
            PcPairingPhase.AWAITING_CONFIRMATION,
        )
}

/** What the pairing entry accepts; all four UI entries share one transition. */
internal sealed interface PcPairingInput {
    /** A pasted `pclink://pair?...` URI. */
    data class Link(val uri: String) : PcPairingInput

    /** The bytes a scanner decoded; must still be a `pclink://pair?` URI. */
    data class Qr(val payload: String) : PcPairingInput

    /** A 16-character Crockford code; the relay origin is not carried by it. */
    data class ManualCode(
        val code: String,
        val relayOrigin: String = PcLinkWorkspace.DEFAULT_MANUAL_RELAY_ORIGIN,
    ) : PcPairingInput
}

internal data class PcNoticeView(
    val kind: String,
    val name: String,
    val fingerprint: String,
    val at: String,
    val warning: String,
)

internal data class PcUnpairedPromptView(
    val code: String,
    val message: String,
)

internal data class PcSessionRow(
    val id: String,
    val title: String,
    val updatedAtMilliseconds: Double,
    val running: Boolean,
    val blank: Boolean,
    val cwd: String?,
    val parentSessionId: String?,
    val searchSnippet: String?,
)

internal data class PcWorkspaceRow(
    val id: String,
    val title: String,
    val path: String,
    val sessionIds: List<String>,
)

internal data class PcRoster(
    val sessions: List<PcSessionRow> = emptyList(),
    val workspaces: List<PcWorkspaceRow> = emptyList(),
    val workspaceOrder: List<String> = emptyList(),
    val pinnedSessionIds: List<String> = emptyList(),
    val archivedIds: List<String> = emptyList(),
) {
    val isEmpty: Boolean get() = sessions.isEmpty() && workspaces.isEmpty()

    fun toPclink(): PclinkRosterSnapshot = PclinkRosterSnapshot(
        sessions = sessions.map {
            PclinkRosterSession(
                id = it.id,
                title = it.title,
                updatedAtMilliseconds = it.updatedAtMilliseconds,
                running = it.running,
                blank = it.blank,
                cwd = it.cwd,
                parentSessionId = it.parentSessionId,
                searchSnippet = it.searchSnippet,
            )
        },
        workspaces = workspaces.map {
            PclinkRosterWorkspace(
                id = it.id,
                title = it.title,
                path = it.path,
                sessionIds = it.sessionIds,
            )
        },
        workspaceOrder = workspaceOrder,
        pinnedSessionIds = pinnedSessionIds,
        archivedIds = archivedIds,
    )

    companion object {
        fun from(snapshot: PclinkRosterSnapshot): PcRoster = PcRoster(
            sessions = snapshot.sessions.map {
                PcSessionRow(
                    id = it.id,
                    title = it.title,
                    updatedAtMilliseconds = it.updatedAtMilliseconds,
                    running = it.running,
                    blank = it.blank,
                    cwd = it.cwd,
                    parentSessionId = it.parentSessionId,
                    searchSnippet = it.searchSnippet,
                )
            },
            workspaces = snapshot.workspaces.map {
                PcWorkspaceRow(
                    id = it.id,
                    title = it.title,
                    path = it.path,
                    sessionIds = it.sessionIds,
                )
            },
            workspaceOrder = snapshot.workspaceOrder,
            pinnedSessionIds = snapshot.pinnedSessionIds,
            archivedIds = snapshot.archivedIds,
        )
    }
}

internal sealed interface PcTurnState {
    data object Idle : PcTurnState
    data class Submitting(val sessionId: String) : PcTurnState
    data class Queued(val sessionId: String, val requestId: String) : PcTurnState
    data class Failed(val error: PcWorkspaceError) : PcTurnState
}

/** The whole App-side state the page integrator maps. */
internal data class PcWorkspaceState(
    val backend: PcBackend = PcBackend.PHONE,
    val pairing: PcPairingState = PcPairingState(),
    val presence: PcPresence = PcPresence.unpaired(),
    val record: PcPairedComputer? = null,
    val ownFingerprint: String? = null,
    val ownMachineId: String? = null,
    val peerDshVersion: String? = null,
    val peerAppName: String? = null,
    val peerAppVersion: String? = null,
    val roster: PcRoster = PcRoster(),
    val rosterCapturedAtMilliseconds: Long? = null,
    val rosterLoading: Boolean = false,
    val rosterError: PcWorkspaceError? = null,
    val lastWorkspaceId: String? = null,
    val camera: PcCameraAvailability = PcCameraAvailability.UNKNOWN,
    val lastError: PcWorkspaceError? = null,
    val notice: PcNoticeView? = null,
    val pcUnpairedPrompt: PcUnpairedPromptView? = null,
    val pairingUpgradeHint: String? = null,
    val turn: PcTurnState = PcTurnState.Idle,
)

/**
 * The subset of `PclinkClient` the controller drives. Production is
 * [PclinkClientAdapter]; tests use a fake so the controller's own transitions
 * are provable without a relay.
 */
internal interface PcLinkClientPort {
    val status: StateFlow<PclinkClientStatus>
    val notices: SharedFlow<PclinkNotice>
    val pairingUpdates: SharedFlow<PclinkPairingUpdate>

    suspend fun start()
    suspend fun beginPairing(qrUri: String): PclinkPairingPrompt
    suspend fun beginManualPairing(code: String, relayOrigin: String): PclinkPairingPrompt
    suspend fun confirmPairing(id: String): PclinkPairingResult
    suspend fun cancelPairing()
    suspend fun unpair()
    suspend fun acknowledgePCUnpair()
    suspend fun removeLocalRecord()
    suspend fun foregroundResumed()
    suspend fun stop()
    fun clearLastError()
}

/**
 * The App's one PC workspace controller.
 *
 * All intents are non-blocking except the two `suspend` internals used by
 * `PcLinkWorkspace`; each returns the [Job] that performs the work so a caller
 * (and the test suite) can await the terminal state.
 */
internal class PcWorkspaceController(
    private val client: PcLinkClientPort,
    private val transport: PcDshCall,
    private val storage: PcWorkspaceStorage,
    private val diagnostics: PcDiagnosticsLog,
    private val turnRunner: PcChatTurnRunner,
    private val presence: PclinkPresence = PclinkPresence(),
    private val cameraAvailability: () -> PcCameraAvailability = { PcCameraAvailability.AVAILABLE },
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val onClose: () -> Unit = {},
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) : AutoCloseable {
    private val mutableState = MutableStateFlow(
        PcWorkspaceState(backend = storage.readBackend()),
    )

    /** The page's read model; a new value after every client/intent change. */
    val state: StateFlow<PcWorkspaceState> = mutableState.asStateFlow()

    private var started = false
    private var closed = false
    private var pairingJob: Job? = null
    private var pairingCancelJob: Job? = null
    /**
     * The client state the last [applyStatus] saw. Unpaired only ends a busy
     * pairing when the client moved out of Pairing: the collector also replays the
     * client's initial Unpaired value, which can arrive after [startPairing] has
     * already published JOINING and must not mark that attempt FAILED.
     */
    private var lastClientState: com.phonedsh.pclink.PclinkClientState? = null
    private var pairingCancelled = false
    private var hydratedMachineId: String? = null
    private var loggedPresenceKey: String? = null
    private var offlineSinceMillis: Long? = null

    init {
        observeClient()
    }

    // ---- Lifecycle ------------------------------------------------------

    /** Starts the client exactly once; a second call is a no-op. */
    fun start() {
        if (started || closed) return
        started = true
        scope.launch {
            try {
                client.start()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
            }
        }
    }

    /** Re-dials after a foreground resume; never presented as 电脑离线 (§10). */
    fun foregroundResumed() {
        if (closed) return
        presence.onForegroundResume()
        publishPresence()
        scope.launch {
            try {
                client.foregroundResumed()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
            }
        }
    }

    /** The connection screen opened while not online: arm the long-offline latch. */
    fun markConnectionScreenOpened() {
        presence.onConnectionScreenOpened()
        publishPresence()
    }

    override fun close() {
        if (closed) return
        closed = true
        pairingJob?.cancel()
        pairingJob = null
        scope.cancel()
        onClose()
    }

    // ---- Pairing --------------------------------------------------------

    fun startPairing(link: String) = startPairing(PcPairingInput.Link(link))

    fun startPairingQr(payload: String) = startPairing(PcPairingInput.Qr(payload))

    fun startManualPairing(
        code: String,
        relayOrigin: String = PcLinkWorkspace.DEFAULT_MANUAL_RELAY_ORIGIN,
    ) = startPairing(PcPairingInput.ManualCode(code, relayOrigin))

    /** Alias for the pairing page's 配对码 entry. */
    fun startPairingCode(
        code: String,
        relayOrigin: String = PcLinkWorkspace.DEFAULT_MANUAL_RELAY_ORIGIN,
    ) = startManualPairing(code, relayOrigin)

    /**
     * One pairing intent. The serialized phases are the iOS `PCPairingFlow`
     * set: idle -> joining -> connecting(prompt) -> paired/failed. v1.6 has no
     * operator-approval wait: a verified `pair.auth` is the approval, so the
     * controller submits it automatically after the prompt arrives.
     */
    fun startPairing(input: PcPairingInput) {
        if (closed) return
        if (pairingJob?.isActive == true || pairingCancelJob?.isActive == true) return
        if (mutableState.value.record != null) {
            mutableState.update {
                it.copy(
                    pairing = PcPairingState(
                        phase = PcPairingPhase.FAILED,
                        error = PcWorkspaceError(
                            code = "already_paired",
                            message = "a computer is already paired; unpair it first",
                        ),
                    ),
                    lastError = PcWorkspaceError(
                        code = "already_paired",
                        message = "a computer is already paired; unpair it first",
                    ),
                )
            }
            return
        }
        pairingCancelled = false
        mutableState.update {
            it.copy(
                pairing = PcPairingState(phase = PcPairingPhase.JOINING),
                lastError = null,
            )
        }
        pairingJob = scope.launch {
            try {
                val prompt = when (input) {
                    is PcPairingInput.Link -> client.beginPairing(input.uri.trim())
                    is PcPairingInput.Qr -> client.beginPairing(input.payload.trim())
                    is PcPairingInput.ManualCode -> client.beginManualPairing(
                        input.code.trim(),
                        input.relayOrigin,
                    )
                }
                val info = prompt.toPromptInfo()
                mutableState.update {
                    it.copy(
                        pairing = PcPairingState(
                            phase = PcPairingPhase.READY_TO_CONFIRM,
                            prompt = info,
                        ),
                        lastError = null,
                    )
                }
                // The scan/code is the consent. Submit the auth exactly once; the
                // client's pairingUpdates/status streams still own completion.
                mutableState.update {
                    it.copy(pairing = it.pairing.copy(phase = PcPairingPhase.AUTHENTICATING))
                }
                val result = client.confirmPairing(prompt.id)
                applyPairedRecord(result)
            } catch (cancelled: CancellationException) {
                if (!pairingCancelled) {
                    mutableState.update {
                        it.copy(pairing = it.pairing.copy(phase = PcPairingPhase.IDLE))
                    }
                }
                throw cancelled
            } catch (error: Exception) {
                if (pairingCancelled) {
                    mutableState.update { it.copy(pairing = PcPairingState()) }
                } else {
                    val mapped = error.toWorkspaceError()
                    mutableState.update {
                        it.copy(
                            pairing = PcPairingState(
                                phase = PcPairingPhase.FAILED,
                                prompt = it.pairing.prompt,
                                error = mapped,
                            ),
                            lastError = mapped,
                        )
                    }
                }
            } finally {
                pairingJob = null
            }
        }
    }

    fun confirmPairing(id: String? = mutableState.value.pairing.prompt?.id) {
        if (closed || id == null) return
        scope.launch {
            mutableState.update {
                it.copy(pairing = it.pairing.copy(phase = PcPairingPhase.AUTHENTICATING, error = null))
            }
            try {
                applyPairedRecord(client.confirmPairing(id))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val mapped = error.toWorkspaceError()
                mutableState.update {
                    it.copy(
                        pairing = it.pairing.copy(phase = PcPairingPhase.FAILED, error = mapped),
                        lastError = mapped,
                    )
                }
            }
        }
    }

    /** Returns the cancellation job so a caller (or a test) can await teardown. */
    fun cancelPairing(): Job? {
        pairingCancelled = true
        val inFlight = pairingJob
        pairingJob = null
        mutableState.update {
            it.copy(pairing = PcPairingState(), lastError = null)
        }
        if (closed) return null
        pairingCancelJob = scope.launch {
            try {
                client.cancelPairing()
            } catch (_: Exception) {
                // The page is already back to idle; a close race is harmless.
            } finally {
                // A client whose connect call has not returned yet must not keep
                // a second beginPairing alive behind the page's back.
                inFlight?.cancel()
                pairingCancelJob = null
            }
        }
        return pairingCancelJob
    }

    // ---- Unpair ---------------------------------------------------------

    fun unpair(): Job = scope.launch {
        val machineId = mutableState.value.record?.machineId
        try {
            client.unpair()
            machineId?.let { storage.removePcScope(it) }
            applyUnpairedState()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
        }
    }

    fun acknowledgePCUnpair(): Job = scope.launch {
        val machineId = mutableState.value.record?.machineId
        try {
            client.acknowledgePCUnpair()
            machineId?.let { storage.removePcScope(it) }
            applyUnpairedState()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
        }
    }

    fun removeLocalRecord(): Job = scope.launch {
        val machineId = mutableState.value.record?.machineId
        try {
            client.removeLocalRecord()
            machineId?.let { storage.removePcScope(it) }
            applyUnpairedState()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
        }
    }

    // ---- Drawer backend / P18 ------------------------------------------

    /**
     * Persists the segment first, then publishes it. A failed commit is visible
     * as a storage error instead of a selection that silently resets on kill.
     */
    fun selectBackend(backend: PcBackend) {
        val persisted = storage.writeBackend(backend)
        mutableState.update {
            it.copy(
                backend = backend,
                lastError = if (persisted) {
                    it.lastError
                } else {
                    PcWorkspaceError("storage", "the drawer backend could not be stored")
                },
            )
        }
    }

    fun selectBackend(segment: String) {
        val backend = PcBackend.entries.firstOrNull { it.wire == segment } ?: return
        selectBackend(backend)
    }

    fun lastWorkspaceId(machineId: String): String? = storage.readLastWorkspace(machineId)

    /** Stores the workspace picker choice; stale ids are resolved by the page. */
    fun selectWorkspace(machineId: String, workspaceId: String) {
        val persisted = storage.writeLastWorkspace(machineId, workspaceId)
        mutableState.update {
            it.copy(
                lastWorkspaceId = if (persisted) workspaceId else it.lastWorkspaceId,
                lastError = if (persisted) {
                    it.lastError
                } else {
                    PcWorkspaceError("storage", "the last workspace could not be stored")
                },
            )
        }
    }

    // ---- Roster ---------------------------------------------------------

    /**
     * One `session/list` read, then a C4 cache write. A failed read keeps the
     * previously painted rows and exposes [PcWorkspaceState.rosterError] instead
     * of an empty "no sessions" list (§P18).
     */
    fun refreshRoster(): Job = scope.launch {
        val record = mutableState.value.record ?: return@launch
        if (!mutableState.value.presence.isOnline && !client.status.value.state.isOnline) {
            mutableState.update {
                it.copy(rosterError = PcWorkspaceError("peer_offline", "the paired PC is offline", retryable = true))
            }
            return@launch
        }
        mutableState.update { it.copy(rosterLoading = true, rosterError = null) }
        try {
            val result = transport.call(
                SESSION_LIST_ENDPOINT,
                JsonObject(linkedMapOf("_request" to JsonObject(emptyMap()))),
            )
            val sessions = decodeSessionRows(result)
            val current = mutableState.value.roster
            val snapshot = PcRoster(
                sessions = sessions,
                workspaces = current.workspaces,
                workspaceOrder = current.workspaceOrder,
                pinnedSessionIds = current.pinnedSessionIds,
                archivedIds = current.archivedIds,
            )
            val capturedAt = nowMillis()
            if (!snapshot.isEmpty) {
                try {
                    storage.writeRoster(record.machineId, snapshot.toPclink(), capturedAt)
                } catch (error: Exception) {
                    // Keep the live rows; a cache failure is not a failed read.
                    mutableState.update { it.copy(lastError = error.toWorkspaceError()) }
                }
            }
            mutableState.update {
                it.copy(
                    roster = snapshot,
                    rosterCapturedAtMilliseconds = if (snapshot.isEmpty) null else capturedAt,
                    rosterLoading = false,
                    rosterError = null,
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            mutableState.update {
                it.copy(rosterLoading = false, rosterError = error.toWorkspaceError())
            }
        }
    }

    // ---- Turn -----------------------------------------------------------

    /** Runs one prompt; null when the intent is empty, otherwise the work's Job. */
    fun sendTurn(sessionId: String, text: String): Job? {
        if (closed || text.isEmpty() || sessionId.isBlank()) return null
        if (!mutableState.value.presence.isOnline && !client.status.value.state.isOnline) {
            mutableState.update {
                it.copy(turn = PcTurnState.Failed(PcWorkspaceError("peer_offline", "the paired PC is offline", true)))
            }
            return null
        }
        return scope.launch {
            mutableState.update { it.copy(turn = PcTurnState.Submitting(sessionId)) }
            try {
                when (val outcome = turnRunner.submit(sessionId, text)) {
                    is PcTurnOutcome.Accepted -> mutableState.update {
                        it.copy(turn = PcTurnState.Queued(sessionId, outcome.requestId))
                    }
                    is PcTurnOutcome.Rejected -> mutableState.update {
                        it.copy(turn = PcTurnState.Failed(PcWorkspaceError("rejected", "the PC did not start the turn")))
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                mutableState.update { it.copy(turn = PcTurnState.Failed(error.toWorkspaceError())) }
            }
        }
    }

    // ---- Camera ---------------------------------------------------------

    /** MainActivity's CAMERA answer; a denial keeps the page on 相机不可用. */
    fun onCameraPermissionResult(granted: Boolean) {
        mutableState.update {
            it.copy(camera = if (granted) PcCameraAvailability.AVAILABLE else PcCameraAvailability.DENIED)
        }
    }

    /**
     * Called when the page opens the scanner. Returns false when the camera is
     * absent or denied; the state carries the reason for the page's copy.
     */
    fun checkCameraForScanning(): Boolean {
        val availability = cameraAvailability()
        mutableState.update { it.copy(camera = availability) }
        return availability == PcCameraAvailability.AVAILABLE
    }

    fun clearError() {
        client.clearLastError()
        mutableState.update { it.copy(lastError = null) }
    }

    fun dismissNotice() {
        mutableState.update { it.copy(notice = null) }
    }

    // ---- Observation ----------------------------------------------------

    private fun observeClient() {
        scope.launch {
            client.status.collect { status ->
                applyStatus(status)
            }
        }
        scope.launch {
            client.notices.collect { notice ->
                mutableState.update {
                    it.copy(
                        notice = PcNoticeView(
                            kind = notice.kind,
                            name = notice.name,
                            fingerprint = notice.fingerprint,
                            at = notice.at,
                            warning = PclinkNotice.WARNING,
                        ),
                    )
                }
            }
        }
        scope.launch {
            client.pairingUpdates.collect { update ->
                when (update) {
                    is PclinkPairingUpdate.Completed -> applyCompletedRecord(update.record)
                    is PclinkPairingUpdate.Failed -> {
                        if (!pairingCancelled) {
                            val mapped = update.error.toWorkspaceError()
                            mutableState.update {
                                it.copy(
                                    pairing = it.pairing.copy(
                                        phase = PcPairingPhase.FAILED,
                                        error = mapped,
                                    ),
                                    lastError = mapped,
                                )
                            }
                        }
                    }
                }
            }
        }
        // PclinkPresence's 8 s grace and 10 min latch are timer transitions that
        // no client event announces; a small ticker is the only way the drawer
        // sees them without the UI owning a second clock.
        scope.launch {
            while (isActive) {
                delay(PRESENCE_TICK_MILLIS)
                if (mutableState.value.record != null) publishPresence()
            }
        }
    }

    private fun applyStatus(status: PclinkClientStatus) {
        // A status emitted before the client's first load (or a stale initial
        // value) can carry no record after this controller has already observed
        // a durable pairing completion. It is not an unpair: every unpair path
        // goes through `unpair`/`acknowledgePCUnpair`/`removeLocalRecord`, which
        // clear the state explicitly. Do not let the stale value erase a record.
        if (
            status.record == null &&
            mutableState.value.record != null &&
            status.state is PclinkClientState.Unpaired &&
            mutableState.value.pairing.phase == PcPairingPhase.COMPLETED
        ) {
            return
        }
        presence.apply(status)
        val snapshot = presence.snapshot()
        val projected = PcPresence.from(status, snapshot)
        logPresence(projected)
        val record = status.record?.let { paired ->
            PcPairedComputer(
                name = paired.peerName,
                machineId = paired.peerMachineId,
                fingerprint = paired.fingerprint,
                pairedAt = paired.pairedAt,
                relayOrigin = paired.relayOrigin,
                pairingMode = paired.pairingMode?.wire,
            )
        }
        if (record == null) hydratedMachineId = null
        val stored = record?.let { hydrate(it.machineId) }
        val clientState = status.state
        val previousClientState = lastClientState
        lastClientState = clientState
        mutableState.update { current ->
            var next = current.copy(
                presence = projected,
                record = record,
                ownFingerprint = status.fingerprint,
                ownMachineId = status.machineId,
                peerDshVersion = status.peerDshVersion ?: status.versionWarning?.dshVersion,
                peerAppName = status.peerAppName,
                peerAppVersion = status.peerAppVersion,
                pcUnpairedPrompt = status.pcUnpairedPrompt?.let {
                    PcUnpairedPromptView(it.code, it.message)
                },
                pairingUpgradeHint = status.pairingUpgradeHint,
                lastError = status.lastError?.toWorkspaceError() ?: current.lastError,
            )
            if (stored != null) {
                next = next.copy(
                    roster = stored.roster,
                    rosterCapturedAtMilliseconds = stored.capturedAt,
                    lastWorkspaceId = stored.lastWorkspaceId,
                    rosterError = null,
                )
            }
            if (record == null) {
                next = next.copy(
                    roster = PcRoster(),
                    rosterCapturedAtMilliseconds = null,
                    lastWorkspaceId = null,
                )
            }
            next = when (clientState) {
                is com.phonedsh.pclink.PclinkClientState.Pairing -> {
                    val mappedPhase = when (clientState.phase) {
                        PclinkPairingPhase.Idle -> PcPairingPhase.IDLE
                        PclinkPairingPhase.Joining -> PcPairingPhase.JOINING
                        PclinkPairingPhase.WaitingForPC -> PcPairingPhase.WAITING_FOR_PC
                        PclinkPairingPhase.ReadyToConfirm -> PcPairingPhase.READY_TO_CONFIRM
                        PclinkPairingPhase.Authenticating -> PcPairingPhase.AUTHENTICATING
                        PclinkPairingPhase.AwaitingConfirmation -> PcPairingPhase.AWAITING_CONFIRMATION
                        PclinkPairingPhase.Completed -> PcPairingPhase.COMPLETED
                        is PclinkPairingPhase.Failed -> PcPairingPhase.FAILED
                    }
                    // The client can publish ReadyToConfirm after this controller
                    // already submitted pair.auth; never step that phase backwards.
                    val phase = if (
                        next.pairing.phase == PcPairingPhase.AUTHENTICATING &&
                        mappedPhase == PcPairingPhase.READY_TO_CONFIRM
                    ) {
                        PcPairingPhase.AUTHENTICATING
                    } else {
                        mappedPhase
                    }
                    next.copy(
                        pairing = next.pairing.copy(
                            phase = phase,
                            prompt = status.pairingPrompt?.toPromptInfo() ?: next.pairing.prompt,
                            error = (clientState.phase as? PclinkPairingPhase.Failed)
                                ?.error?.toWorkspaceError() ?: next.pairing.error,
                        ),
                    )
                }
                is com.phonedsh.pclink.PclinkClientState.Unpaired -> {
                    if (
                        next.pairing.isBusy && !pairingCancelled &&
                        previousClientState is com.phonedsh.pclink.PclinkClientState.Pairing
                    ) {
                        val mapped = status.lastError?.toWorkspaceError()
                            ?: PcWorkspaceError("unpaired", "pairing did not complete")
                        next.copy(pairing = next.pairing.copy(phase = PcPairingPhase.FAILED, error = mapped))
                    } else {
                        next
                    }
                }
                is com.phonedsh.pclink.PclinkClientState.Online,
                is com.phonedsh.pclink.PclinkClientState.VersionWarning,
                -> {
                    if (next.pairing.isBusy) {
                        next.copy(pairing = next.pairing.copy(phase = PcPairingPhase.COMPLETED, error = null))
                    } else {
                        next
                    }
                }
                else -> next
            }
            next
        }
    }

    private fun applyPairedRecord(result: PclinkPairingResult) {
        if (pairingCancelled) return
        val paired = result.record
        mutableState.update {
            it.copy(
                record = PcPairedComputer(
                    name = paired.peerName,
                    machineId = paired.peerMachineId,
                    fingerprint = paired.fingerprint,
                    pairedAt = paired.pairedAt,
                    relayOrigin = paired.relayOrigin,
                    pairingMode = paired.pairingMode?.wire,
                ),
                pairing = it.pairing.copy(
                    phase = PcPairingPhase.COMPLETED,
                    prompt = it.pairing.prompt ?: result.prompt.toPromptInfo(),
                    error = null,
                ),
                lastError = null,
            )
        }
        hydrate(paired.peerMachineId)?.let { stored ->
            mutableState.update {
                it.copy(
                    roster = stored.roster,
                    rosterCapturedAtMilliseconds = stored.capturedAt,
                    lastWorkspaceId = stored.lastWorkspaceId,
                    rosterError = null,
                )
            }
        }
    }

    private fun applyUnpairedState() {
        mutableState.update {
            it.copy(
                record = null,
                presence = PcPresence.unpaired(),
                pairing = PcPairingState(),
                roster = PcRoster(),
                rosterCapturedAtMilliseconds = null,
                rosterError = null,
                lastWorkspaceId = null,
                pcUnpairedPrompt = null,
                turn = PcTurnState.Idle,
                lastError = null,
            )
        }
        hydratedMachineId = null
    }

    private fun publishPresence() {
        val snapshot = presence.snapshot()
        val current = mutableState.value
        val status = client.status.value
        val projected = PcPresence.from(status, snapshot)
        logPresence(projected)
        mutableState.update { it.copy(presence = projected) }
    }

    private fun logPresence(projected: PcPresence) {
        if (projected.isUnpaired) {
            offlineSinceMillis = null
            return
        }
        val now = nowMillis()
        if (projected.isOnline) {
            val gap = offlineSinceMillis?.let { (now - it).coerceAtLeast(0L) / 1000.0 }
            offlineSinceMillis = null
            val key = PcReachability.ONLINE.name + "/-"
            if (key == loggedPresenceKey) return
            loggedPresenceKey = key
            diagnostics.append(PcDiagnosticEvent("online", gapSeconds = gap))
            return
        }
        if (offlineSinceMillis == null) offlineSinceMillis = now
        val reason = PcDiagnosticsLog.reasonName(projected.offlineReason)
        val key = projected.reachability.name + "/" + (reason ?: "-")
        if (key == loggedPresenceKey) return
        loggedPresenceKey = key
        diagnostics.append(
            PcDiagnosticEvent(
                state = projected.reachability.name.lowercase(),
                reason = reason,
            ),
        )
    }

    private fun hydrate(machineId: String): HydratedWorkspace? {
        if (hydratedMachineId == machineId) return null
        val stored = try {
            storage.readWorkspace(machineId)
        } catch (_: Exception) {
            // Leave the marker unset so a later status retries the read.
            return null
        }
        hydratedMachineId = machineId
        val roster = when (val entry = stored.roster) {
            is PclinkRosterCacheEntry.Stored -> PcRoster.from(entry.snapshot)
            else -> PcRoster()
        }
        val capturedAt = (stored.roster as? PclinkRosterCacheEntry.Stored)?.capturedAtMilliseconds
        return HydratedWorkspace(
            roster = roster,
            capturedAt = capturedAt,
            lastWorkspaceId = stored.lastWorkspaceId,
        )
    }

    private data class HydratedWorkspace(
        val roster: PcRoster,
        val capturedAt: Long?,
        val lastWorkspaceId: String?,
    )

    private fun PclinkPairingPrompt.toPromptInfo(): PcPairingPromptInfo = PcPairingPromptInfo(
        id = id,
        mode = mode.wire,
        relayOrigin = relayOrigin,
        pcName = pcName,
        pcMachineId = pcMachineId,
        ownFingerprint = ownFingerprint,
        warningText = warningText,
        expiresAtMilliseconds = expiresAt.toEpochMilli(),
    )

    private fun applyCompletedRecord(record: PclinkPairingRecord) {
        if (pairingCancelled) return
        mutableState.update {
            it.copy(
                record = PcPairedComputer(
                    name = record.peerName,
                    machineId = record.peerMachineId,
                    fingerprint = record.fingerprint,
                    pairedAt = record.pairedAt,
                    relayOrigin = record.relayOrigin,
                    pairingMode = record.pairingMode?.wire,
                ),
                pairing = it.pairing.copy(phase = PcPairingPhase.COMPLETED, error = null),
                lastError = null,
            )
        }
        hydrate(record.peerMachineId)?.let { stored ->
            mutableState.update {
                it.copy(
                    roster = stored.roster,
                    rosterCapturedAtMilliseconds = stored.capturedAt,
                    lastWorkspaceId = stored.lastWorkspaceId,
                    rosterError = null,
                )
            }
        }
    }

    private fun Exception.toWorkspaceError(): PcWorkspaceError = when (this) {
        is PclinkRpcError -> PcWorkspaceError(
            code = code,
            message = message,
            retryable = code in setOf("peer_offline", "unavailable", "rate_limited", "session_expired"),
        )
        is PclinkError -> PcWorkspaceError(code = code, message = message ?: code, retryable = isRetryable)
        else -> PcWorkspaceError(
            code = "unavailable",
            message = message ?: javaClass.simpleName,
        )
    }

    companion object {
        const val SESSION_LIST_ENDPOINT: String = "session/list"
        private const val PRESENCE_TICK_MILLIS: Long = 500

        /**
         * Decodes `session/list` rows. The shapes are DSH's, not PCLink's:
         * `sessionId`, `updatedAt` ms, `running`, `blank`, `cwd`,
         * `parentSessionId`, and the projected title at
         * `projections.values.title` (`ManagementModels.swift:60-86`). A row
         * without an id is skipped rather than failing the whole list.
         */
        fun decodeSessionRows(value: JsonValue): List<PcSessionRow> {
            val items = (value as? JsonObject)?.get("items") as? JsonArray ?: return emptyList()
            return items.values.mapNotNull { item ->
                val objectValue = item as? JsonObject ?: return@mapNotNull null
                val id = objectValue.string("sessionId") ?: return@mapNotNull null
                if (id.isBlank()) return@mapNotNull null
                val projections = objectValue["projections"] as? JsonObject
                val values = projections?.get("values") as? JsonObject
                PcSessionRow(
                    id = id,
                    title = values?.string("title").orEmpty().trim(),
                    updatedAtMilliseconds = objectValue.number("updatedAt") ?: 0.0,
                    running = objectValue.bool("running") ?: false,
                    blank = objectValue.bool("blank") ?: false,
                    cwd = objectValue.string("cwd"),
                    parentSessionId = objectValue.string("parentSessionId"),
                    searchSnippet = null,
                )
            }.sortedWith(compareByDescending<PcSessionRow> { it.updatedAtMilliseconds }.thenBy { it.id })
        }

        private fun JsonObject.string(name: String): String? = when (val value = this[name]) {
            is JsonString -> value.value
            else -> null
        }

        private fun JsonObject.bool(name: String): Boolean? = when (val value = this[name]) {
            is JsonBool -> value.value
            else -> null
        }

        private fun JsonObject.number(name: String): Double? = when (val value = this[name]) {
            is JsonNumber -> value.raw.toDoubleOrNull()
            else -> null
        }
    }
}
