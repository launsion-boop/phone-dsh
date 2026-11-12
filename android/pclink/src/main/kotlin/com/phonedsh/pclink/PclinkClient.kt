// SPDX-License-Identifier: MIT
// App-facing PCLink client: identity/record lifecycle, QR/manual pairing and
// the phone side of the E2E handshake (§2.2, §4, §5, §10). RPC is C4: this file
// freezes `PclinkRpcHost` (plus C4's optional relay-event seam) and routes
// authenticated inner messages and `relay.offline` correlation to an optional
// host. There is no Android import; C5 supplies the stores and links.
package com.phonedsh.pclink

import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

// ---- Public state -------------------------------------------------------

data class PclinkVersionWarning(
    val dshVersion: String,
    val testedRange: String = PclinkEndpoints.DSH_TESTED_RANGE,
    val message: String = "版本未验证：电脑 DSH $dshVersion 不在测试范围 $testedRange 内",
)

sealed interface PclinkUnpairedReason {
    data object NoRecord : PclinkUnpairedReason
    data object IdentityMissing : PclinkUnpairedReason
    data object StaleRecord : PclinkUnpairedReason
    data class Unsupported(val reason: String) : PclinkUnpairedReason
}

sealed interface PclinkPairingPhase {
    data object Idle : PclinkPairingPhase
    data object Joining : PclinkPairingPhase
    data object WaitingForPC : PclinkPairingPhase
    data object ReadyToConfirm : PclinkPairingPhase
    data object Authenticating : PclinkPairingPhase
    data object AwaitingConfirmation : PclinkPairingPhase
    data object Completed : PclinkPairingPhase
    data class Failed(val error: PclinkError) : PclinkPairingPhase
}

sealed interface PclinkOfflineReason {
    data object NotStarted : PclinkOfflineReason
    data object Network : PclinkOfflineReason
    data object PeerOffline : PclinkOfflineReason
    data object Replaced : PclinkOfflineReason
    data object AuthenticationFailed : PclinkOfflineReason
    data object VersionUnsupported : PclinkOfflineReason
    data object UnpairedPrompt : PclinkOfflineReason
    data class ProtocolError(val message: String) : PclinkOfflineReason
    data class Storage(val message: String) : PclinkOfflineReason
}

sealed interface PclinkClientState {
    data class Unpaired(val reason: PclinkUnpairedReason) : PclinkClientState
    data class Pairing(val phase: PclinkPairingPhase) : PclinkClientState
    data object Connecting : PclinkClientState
    data object Online : PclinkClientState
    data class Offline(val reason: PclinkOfflineReason) : PclinkClientState
    data class VersionWarning(val warning: PclinkVersionWarning) : PclinkClientState

    val isOnline: Boolean
        get() = this is Online || this is VersionWarning
}

data class PclinkClientStatus(
    val state: PclinkClientState = PclinkClientState.Offline(PclinkOfflineReason.NotStarted),
    val machineId: String? = null,
    val fingerprint: String? = null,
    val record: PclinkPairingRecord? = null,
    val versionWarning: PclinkVersionWarning? = null,
    val peerDshVersion: String? = null,
    val peerAppName: String? = null,
    val peerAppVersion: String? = null,
    val lastNotice: PclinkNotice? = null,
    val lastError: PclinkError? = null,
    val pairingPrompt: PclinkPairingPrompt? = null,
    val pcUnpairedPrompt: PclinkPCUnpairedPrompt? = null,
    /** Set when a pre-v1.6 PC never sends `pair.confirm` (CCR-1). */
    val pairingUpgradeHint: String? = null,
)

data class PclinkPairingPrompt(
    val id: String,
    val mode: PclinkPairingMode,
    val relayOrigin: String,
    val pcName: String,
    val pcMachineId: String,
    val ownFingerprint: String,
    val warningText: String,
    val expiresAt: Instant,
) {
    companion object {
        /** P09 one-line full-owner permission line; there is no fingerprint card. */
        const val FULL_OWNER_WARNING =
            "连接后，这台手机可以完整使用这台电脑上的 DSH（对话、Shell、文件、审批与设置）。"
    }
}

data class PclinkPairingResult(
    val record: PclinkPairingRecord,
    val prompt: PclinkPairingPrompt,
)

/** Client-driven pairing progress; `.Completed` only after a durable write. */
sealed interface PclinkPairingUpdate {
    data class Completed(val record: PclinkPairingRecord) : PclinkPairingUpdate
    data class Failed(val error: PclinkError) : PclinkPairingUpdate
}

data class PclinkPCUnpairedPrompt(
    val code: String,
    val message: String,
    val record: PclinkPairingRecord,
) {
    companion object {
        const val TEXT = "电脑已解除与此手机的配对"
    }
}

data class PclinkNotice(
    val kind: String,
    val name: String,
    val fingerprint: String,
    val at: String,
) {
    companion object {
        const val WARNING =
            "收到新的配对通知。如果不是你本人刚配对的新手机，请立即在电脑上「撤销全部配对」并运行 rotate-identity。"
    }
}

/**
 * C2's frozen RPC seam for C4. C4 implements this interface and passes it to
 * the [PclinkClient] constructor; C2 calls [sendInner] once for every
 * authenticated post-handshake inner message that C4 owns (`rpc.*` and DSH
 * events). `peer.hello`, `pclink.notice` and `session.close` are consumed by
 * C2 before this host is called.
 *
 * [activeSession] is the host's view of the bound session (normally
 * `client.activeSession()`); C4 uses it for its own correlation and C2 does
 * not require it to be non-null. Outbound messages are sent with
 * [PclinkClient.sendInner], not through this host. C2 tests pass `null`, so
 * there is no C2→C4 compile edge.
 */
interface PclinkRpcHost {
    suspend fun sendInner(inner: PclinkJson)
    fun activeSession(): PclinkE2eSession?
}

/**
 * C4's optional extension of the frozen [PclinkRpcHost] seam for relay-plane
 * correlation. `relay.offline` is not an inner message, so C2 hands it to C4
 * through this interface before it decides whether the frame identifies the
 * current E2E session (§3.3/§10). Kept separate so C2's two-method host seam is
 * unchanged.
 */
interface PclinkRelayEventHost {
    /**
     * Settles only the calls/streams that [offline] identifies (§10): a frame
     * carrying `id`/`streamId` settles exactly that frame; a `sid`-only frame
     * settles that session per §7. Returns true when a pending call/stream
     * matched, so [PclinkClient] can tell a live frame from a stale one.
     */
    fun onRelayOffline(offline: PclinkRelayOffline): Boolean
}

data class PclinkClientConfiguration(
    val phoneName: String = "Android phone",
    val appName: String = "phoneDSH",
    val appVersion: String = "0.1.0",
    val phoneDshVersion: String = "0.2.2-rc.1",
    val phoneDshCommit: String? = null,
    val pairingTimeout: Duration = PclinkLimits.PAIRING_APPROVAL_TIMEOUT,
    /** §4.4/CCR-1: the client waits 120 s for `pair.confirm`, then reports the upgrade hint. */
    val pairingApprovalTimeout: Duration = PclinkLimits.PAIRING_APPROVAL_TIMEOUT,
    val handshakeStepTimeout: Duration = PclinkLimits.HANDSHAKE_STEP_TIMEOUT,
    val sessionThresholds: PclinkSessionThresholds = PclinkSessionThresholds.v1,
    val autoConnectAfterPairing: Boolean = true,
)

/** The CCR-1 upgrade copy shown when an old PC never sends `pair.confirm`. */
const val PCLINK_PRE_V16_UPGRADE_HINT: String =
    "电脑端 PCLink 版本过旧，无法完成配对。请在电脑上升级 dsh web / pclink 插件后重试。"

/**
 * State/lifecycle/pairing client. It drives the real [PclinkE2eSession] over an
 * already-authenticated [PclinkRelayLink] (C3's seam); C3 remains responsible
 * for relay auth, heartbeats, pacing and reconnect backoff.
 */
class PclinkClient(
    private val identityStore: PclinkIdentityStore,
    private val pairingStore: PclinkPairingStore,
    private val relayLinkFactory: PclinkRelayLinkFactory,
    private val configuration: PclinkClientConfiguration = PclinkClientConfiguration(),
    private val rpcHost: PclinkRpcHost? = null,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val sendMutex = Mutex()

    private val mutableStatus = MutableStateFlow(PclinkClientStatus())
    val status: StateFlow<PclinkClientStatus> = mutableStatus.asStateFlow()

    private val mutableNotices = MutableSharedFlow<PclinkNotice>(extraBufferCapacity = 16)
    val notices: SharedFlow<PclinkNotice> = mutableNotices.asSharedFlow()

    private val mutablePairingUpdates = MutableSharedFlow<PclinkPairingUpdate>(extraBufferCapacity = 16)
    val pairingUpdates: SharedFlow<PclinkPairingUpdate> = mutablePairingUpdates.asSharedFlow()

    @Volatile
    private var identity: PclinkIdentity? = null

    @Volatile
    private var record: PclinkPairingRecord? = null

    @Volatile
    private var staleRecord: PclinkPairingRecord? = null

    @Volatile
    private var link: PclinkRelayLink? = null

    @Volatile
    private var readerJob: Job? = null

    @Volatile
    private var session: PclinkE2eSession? = null

    @Volatile
    private var handshake: PclinkHandshake? = null

    @Volatile
    private var rekeyHandshake: PclinkHandshake? = null

    @Volatile
    private var connectionJob: Job? = null

    @Volatile
    private var connectionWaiter: CompletableDeferred<Unit>? = null

    @Volatile
    private var stopped = false

    @Volatile
    private var pairingContext: PairingContext? = null

    fun status(): PclinkClientStatus = mutableStatus.value

    fun activeSession(): PclinkE2eSession? =
        session?.takeIf { it.phase == PclinkSessionPhase.ESTABLISHED }

    /**
     * Loads the identity and the one durable record. A usable record starts the
     * normal connection; a stale record is preserved for inspection and never
     * used (§4.6). A missing seed while a record file exists is fail-closed.
     */
    suspend fun start() {
        stopped = false
        loadIdentityAndRecord()
        if (record != null && session == null) {
            startConnectionIfNeeded()
        } else if (record == null && mutableStatus.value.state !is PclinkClientState.Pairing) {
            setState(
                PclinkClientState.Unpaired(
                    if (staleRecord == null) PclinkUnpairedReason.NoRecord else PclinkUnpairedReason.StaleRecord,
                ),
            )
        }
    }

    suspend fun connectAndWait() {
        start()
        if (session?.phase == PclinkSessionPhase.ESTABLISHED) return
        if (record == null) throw PclinkError.NotPaired()
        startConnectionIfNeeded()
        val waiter = connectionWaiter ?: throw PclinkError.NotPaired()
        waiter.await()
    }

    suspend fun stop() {
        stopped = true
        pairingContext?.let { context -> closePairingContext(context, null) }
        closeConnection(null)
        connectionJob?.cancel()
        connectionJob = null
        connectionWaiter?.cancel()
        connectionWaiter = null
        session = null
        setState(
            if (record == null) {
                PclinkClientState.Unpaired(
                    if (staleRecord == null) PclinkUnpairedReason.NoRecord else PclinkUnpairedReason.StaleRecord,
                )
            } else {
                PclinkClientState.Offline(PclinkOfflineReason.NotStarted)
            },
        )
    }

    suspend fun disconnect() = stop()

    /** Best effort to replace a suspended/closed socket; C3 owns the backoff policy. */
    suspend fun foregroundResumed() {
        if (stopped || record == null) return
        if (session?.phase != PclinkSessionPhase.ESTABLISHED) {
            startConnectionIfNeeded()
        }
    }

    // ---- Pairing --------------------------------------------------------

    suspend fun beginPairing(qrUri: String): PclinkPairingPrompt =
        beginPairing(PclinkQrCode.parse(qrUri))

    suspend fun beginManualPairing(code: String, relayOrigin: String): PclinkPairingPrompt =
        beginPairing(PclinkManualCode.parse(code, relayOrigin))

    suspend fun beginPairing(offer: PclinkPairingOffer): PclinkPairingPrompt {
        stopped = false
        if (pairingContext != null) throw PclinkError.Unavailable("pairing already in progress")
        loadIdentityAndRecord()
        // The durable record must be checked before a new pairing can overwrite
        // it; a stale record is not usable but is still preserved for the user.
        if (record != null) throw PclinkError.AlreadyPaired()
        val activeIdentity = identity ?: run {
            val generated = PclinkIdentity.generate()
            identityStore.saveSeed(generated.seed)
            identity = generated
            generated
        }
        PclinkValidation.origin(offer.relayOrigin)
        offer.pcMachineId?.let { PclinkValidation.requireMachineId(it) }

        val context = PairingContext(offer)
        pairingContext = context
        setState(PclinkClientState.Pairing(PclinkPairingPhase.Joining))
        try {
            val pairingLink = relayLinkFactory.connect(offer.websocketUrl)
            context.link = pairingLink
            context.reader = scope.launch {
                try {
                    pairingLink.incoming.collect { frame -> handlePairingFrame(context, frame) }
                } catch (error: Exception) {
                    failPairing(context, (error as? PclinkError) ?: PclinkError.PeerOffline())
                }
            }
            pairingLink.send(
                pclinkObject(
                    "v" to PclinkJson.Integer(1),
                    "type" to PclinkJson.Text("relay.pair.join"),
                    "rendezvous" to PclinkJson.Text(offer.rendezvous),
                ),
            )
            setState(PclinkClientState.Pairing(PclinkPairingPhase.WaitingForPC))
            val hello = waitForPairing(context, configuration.pairingTimeout) { context.hello.await() }
            context.helloMessage = hello
            val prompt = PclinkPairingPrompt(
                id = context.id,
                mode = offer.mode,
                relayOrigin = offer.relayOrigin,
                pcName = hello.name,
                pcMachineId = hello.machineId,
                ownFingerprint = activeIdentity.fingerprint,
                warningText = PclinkPairingPrompt.FULL_OWNER_WARNING,
                expiresAt = Instant.now().plus(configuration.pairingApprovalTimeout),
            )
            if (context.failure != null) throw context.failure!!
            context.prompt = prompt
            mutableStatus.value = mutableStatus.value.copy(
                pairingPrompt = prompt,
                pairingUpgradeHint = null,
            )
            setState(PclinkClientState.Pairing(PclinkPairingPhase.ReadyToConfirm))
            return prompt
        } catch (error: Exception) {
            // The reader may already have classified a protocol failure; a
            // transport close racing that failure must not replace it.
            val mapped = context.failure ?: mapPairingError(error)
            failPairing(context, mapped)
            throw mapped
        }
    }

    suspend fun confirmPairing(id: String): PclinkPairingResult {
        val context = pairingContext
            ?: throw PclinkError.Unavailable("no matching pairing")
        if (context.id != id) throw PclinkError.Unavailable("no matching pairing")
        context.failure?.let { throw it }
        val hello = context.helloMessage ?: throw PclinkError.BadFrame("pair.hello is not available")
        val prompt = context.prompt ?: throw PclinkError.BadFrame("pairing prompt is not available")
        val activeIdentity = identity ?: throw PclinkError.NoIdentity()
        if (context.authNonce != null) throw PclinkError.Unavailable("pairing already confirmed")
        val authNonce = PclinkRandom.bytes(32)
        val auth = PclinkPairingMessage.makeAuth(
            machineId = activeIdentity.machineId,
            publicKey = activeIdentity.publicKey,
            name = configuration.phoneName,
            relayOrigin = context.offer.relayOrigin,
            nonce = authNonce,
            peerNonce = hello.nonce,
            pairKey = context.offer.pairKey,
        )
        context.authNonce = authNonce
        setState(PclinkClientState.Pairing(PclinkPairingPhase.Authenticating))
        try {
            context.link?.send(pairingMessageFrame(context, auth.raw))
                ?: throw PclinkError.PeerOffline()
            setState(PclinkClientState.Pairing(PclinkPairingPhase.AwaitingConfirmation))
            val confirm = waitForPairing(context, configuration.pairingApprovalTimeout) {
                context.confirm.await()
            }
            if (!confirm.nonce.contentEquals(hello.nonce) ||
                !confirm.peerNonce.contentEquals(authNonce)
            ) {
                throw PclinkError.AuthFailed("pair.confirm nonces do not match")
            }
            val expectedTranscript = PclinkPairingTranscript.hash(hello, auth)
            if (!PclinkCrypto.constantTimeEquals(expectedTranscript, confirm.transcriptHash)) {
                throw PclinkError.AuthFailed("pair.confirm transcript hash mismatch")
            }
            confirm.verifyMac(context.offer.pairKey)
            val paired = PclinkPairingRecord(
                peerMachineId = hello.machineId,
                peerPublicKey = hello.publicKey,
                peerName = hello.name,
                pairedAt = PclinkValidation.nowTimestamp(),
                relayOrigin = context.offer.relayOrigin,
                connectionMode = PclinkConnectionMode.RELAY,
                pairingMode = context.offer.mode,
            )
            try {
                pairingStore.save(paired, activeIdentity.machineId)
            } catch (error: Exception) {
                context.link?.send(pairingCloseFrame(context, "storage"))
                throw PclinkError.Storage("cannot write the pairing record: ${error.message}")
            }
            // `pair.final` is sent only after the durable local write (§4.4).
            val final = PclinkPairingMessage.makeFinal(
                authNonce = authNonce,
                helloNonce = hello.nonce,
                transcriptHash = expectedTranscript,
                pairKey = context.offer.pairKey,
            )
            context.finalSent = true
            context.link?.send(pairingMessageFrame(context, final.raw))
            context.link?.send(pairingCloseFrame(context, "paired"))
            context.completed = true
            closePairingContext(context, null)
            record = paired
            staleRecord = null
            mutableStatus.value = mutableStatus.value.copy(
                record = paired,
                pairingPrompt = null,
                lastError = null,
                versionWarning = null,
                peerDshVersion = null,
                peerAppName = null,
                peerAppVersion = null,
                pcUnpairedPrompt = null,
            )
            setState(PclinkClientState.Pairing(PclinkPairingPhase.Completed))
            mutablePairingUpdates.emit(PclinkPairingUpdate.Completed(paired))
            if (configuration.autoConnectAfterPairing) {
                startConnectionIfNeeded()
            }
            return PclinkPairingResult(paired, prompt)
        } catch (error: Exception) {
            val mapped = context.failure ?: mapPairingError(error)
            failPairing(context, mapped)
            throw mapped
        }
    }

    suspend fun cancelPairing() {
        val context = pairingContext ?: return
        context.link?.send(pairingCloseFrame(context, "cancelled"))
        failPairing(context, PclinkError.PairingCancelled())
    }

    // ---- Outbound / session --------------------------------------------

    /**
     * Seals and sends one inner message on the active session. C4 calls this
     * for `rpc.*`; one mutex keeps seq allocation and the single writer ordered.
     */
    suspend fun sendInner(inner: PclinkJson) {
        val active = session?.takeIf { it.phase == PclinkSessionPhase.ESTABLISHED }
            ?: throw PclinkError.SessionExpired("no established session")
        sendMutex.withLock {
            val current = session?.takeIf { it.phase == PclinkSessionPhase.ESTABLISHED }
                ?: throw PclinkError.SessionExpired("no established session")
            val frame = current.seal(inner)
            val activeLink = link ?: throw PclinkError.PeerOffline()
            activeLink.send(frame)
        }
        if (active.needsRekey) startRekeyIfNeeded()
    }

    // ---- Unpair ---------------------------------------------------------

    suspend fun unpair() {
        val active = activeSession()
        if (active != null) {
            try {
                val close = active.closeFrame("unpaired")
                sendMutex.withLock {
                    val activeLink = link
                    active.markClosed()
                    activeLink?.send(close)
                }
            } catch (_: Exception) {
                active.markClosed()
            }
        }
        closeConnection(null)
        pairingStore.delete()
        record = null
        staleRecord = null
        mutableStatus.value = PclinkClientStatus(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            machineId = identity?.machineId,
            fingerprint = identity?.fingerprint,
        )
    }

    /** The user confirmed the PC's authenticated `unpaired` prompt (§5.5). */
    suspend fun acknowledgePCUnpair() {
        if (mutableStatus.value.pcUnpairedPrompt == null) return
        closeConnection(null)
        pairingStore.delete()
        record = null
        staleRecord = null
        mutableStatus.value = PclinkClientStatus(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            machineId = identity?.machineId,
            fingerprint = identity?.fingerprint,
        )
    }

    /** Remove a stale/one-sided record without a live PC. */
    suspend fun removeLocalRecord() {
        closeConnection(null)
        pairingStore.delete()
        record = null
        staleRecord = null
        mutableStatus.value = PclinkClientStatus(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            machineId = identity?.machineId,
            fingerprint = identity?.fingerprint,
        )
    }

    fun clearLastError() {
        mutableStatus.value = mutableStatus.value.copy(lastError = null)
    }

    // ---- Identity / record ---------------------------------------------

    private suspend fun loadIdentityAndRecord() {
        if (identity == null) {
            val stored = identityStore.loadSeed()
            if (stored != null) {
                identity = PclinkIdentity(stored)
            } else if (pairingStore.hasStoredFile()) {
                record = null
                setState(PclinkClientState.Unpaired(PclinkUnpairedReason.IdentityMissing))
                throw PclinkError.NoIdentity()
            } else {
                val generated = PclinkIdentity.generate()
                identityStore.saveSeed(generated.seed)
                identity = generated
            }
        }
        val activeIdentity = identity ?: throw PclinkError.NoIdentity()
        val loaded = try {
            pairingStore.load(activeIdentity.machineId)
        } catch (error: PclinkError.VersionUnsupported) {
            record = null
            staleRecord = null
            setState(PclinkClientState.Unpaired(PclinkUnpairedReason.Unsupported(error.message ?: "")))
            throw error
        }
        when (loaded) {
            PclinkPairingStoreState.None -> {
                record = null
                staleRecord = null
                mutableStatus.value = mutableStatus.value.copy(
                    machineId = activeIdentity.machineId,
                    fingerprint = activeIdentity.fingerprint,
                    record = null,
                )
            }
            is PclinkPairingStoreState.Usable -> {
                record = loaded.record
                staleRecord = null
                mutableStatus.value = mutableStatus.value.copy(
                    machineId = activeIdentity.machineId,
                    fingerprint = activeIdentity.fingerprint,
                    record = loaded.record,
                )
            }
            is PclinkPairingStoreState.Stale -> {
                record = null
                staleRecord = loaded.record
                mutableStatus.value = mutableStatus.value.copy(
                    machineId = activeIdentity.machineId,
                    fingerprint = activeIdentity.fingerprint,
                    record = null,
                )
                setState(PclinkClientState.Unpaired(PclinkUnpairedReason.StaleRecord))
            }
        }
    }

    // ---- Normal connection ---------------------------------------------

    private fun startConnectionIfNeeded() {
        if (stopped || connectionJob != null) return
        val currentRecord = record ?: return
        val activeIdentity = identity ?: return
        if (session?.phase == PclinkSessionPhase.ESTABLISHED) return
        val waiter = CompletableDeferred<Unit>()
        connectionWaiter = waiter
        connectionJob = scope.launch {
            try {
                runConnection(activeIdentity, currentRecord, waiter)
            } catch (error: Exception) {
                waiter.completeExceptionally(error)
            } finally {
                connectionJob = null
                if (connectionWaiter === waiter) connectionWaiter = null
            }
        }
    }

    private suspend fun runConnection(
        activeIdentity: PclinkIdentity,
        currentRecord: PclinkPairingRecord,
        waiter: CompletableDeferred<Unit>,
    ) {
        setState(PclinkClientState.Connecting)
        val currentLink = try {
            relayLinkFactory.connect(PclinkValidation.websocketUrl(currentRecord.relayOrigin))
        } catch (error: Exception) {
            setState(PclinkClientState.Offline(PclinkOfflineReason.Network))
            throw (error as? PclinkError) ?: PclinkError.PeerOffline()
        }
        link = currentLink
        readerJob = scope.launch {
            try {
                currentLink.incoming.collect { frame -> handleRelayFrame(frame) }
            } catch (_: Exception) {
                // The source flow completing/failing is a connection loss.
            } finally {
                if (link === currentLink) handleConnectionLost()
            }
        }
        val fresh = PclinkE2eSession(activeIdentity, currentRecord, configuration.sessionThresholds)
        val activeHandshake = PclinkHandshake(fresh, makePhoneHello()) { frame -> currentLink.send(frame) }
        handshake = activeHandshake
        val outcome = activeHandshake.run(configuration.handshakeStepTimeout)
        when (outcome) {
            is PclinkHandshakeOutcome.Established -> {
                handshake = null
                install(outcome.session, outcome.hello)
                waiter.complete(Unit)
            }
            is PclinkHandshakeOutcome.Closed -> {
                handshake = null
                val error = PclinkError.fromCode(outcome.code, outcome.message)
                if (outcome.code == "unpaired") {
                    promptPCUnpaired(activeHandshake.session.peer, outcome.code, outcome.message)
                } else {
                    setState(PclinkClientState.Offline(PclinkOfflineReason.ProtocolError(outcome.code)))
                }
                closeConnection(error)
                throw error
            }
            is PclinkHandshakeOutcome.Rejected -> {
                handshake = null
                val error = when (val verification = outcome.verification) {
                    is PclinkRejectVerification.Verified -> {
                        if (verification.code == "unpaired") {
                            promptPCUnpaired(activeHandshake.session.peer, verification.code, verification.message)
                        }
                        PclinkError.fromCode(verification.code, verification.message)
                    }
                    is PclinkRejectVerification.Unauthenticated ->
                        PclinkError.AuthFailed("unauthenticated session.reject: ${verification.message}")
                }
                closeConnection(error)
                throw error
            }
            is PclinkHandshakeOutcome.Failed -> {
                handshake = null
                closeConnection(outcome.error)
                throw outcome.error
            }
        }
    }

    private fun install(installed: PclinkE2eSession, hello: PclinkPeerHello) {
        session = installed
        val warning = if (hello.versionWarning) PclinkVersionWarning(hello.dshVersionText) else null
        mutableStatus.value = mutableStatus.value.copy(
            state = if (warning == null) {
                PclinkClientState.Online
            } else {
                PclinkClientState.VersionWarning(warning)
            },
            record = record,
            versionWarning = warning,
            peerDshVersion = hello.dshVersionText,
            peerAppName = hello.appName,
            peerAppVersion = hello.appVersion,
            lastError = null,
            pcUnpairedPrompt = null,
        )
        if (installed.needsRekey) startRekeyIfNeeded()
    }

    private fun makePhoneHello(): PclinkPeerHello {
        val caps = LinkedHashSet<String>()
        caps.add(PclinkEndpoints.SUITE)
        caps.add("workspace/1")
        caps.add(PclinkCrypto.SUITE)
        return PclinkPeerHello.make(
            role = "phone",
            caps = caps.toList(),
            dshVersion = configuration.phoneDshVersion,
            dshCommit = configuration.phoneDshCommit,
            appName = configuration.appName,
            appVersion = configuration.appVersion,
            name = configuration.phoneName,
        )
    }

    private suspend fun handleRelayFrame(frame: PclinkJson) {
        pairingContext?.let { context -> handlePairingFrame(context, frame) }
        when (frame["type"]?.stringValue) {
            "e2e.handshake", "e2e" -> {
                val activeHandshake = handshake
                if (activeHandshake != null && activeHandshake.handle(frame)) return
                val rekey = rekeyHandshake
                if (rekey != null && rekey.handle(frame)) return
                handleEstablishedFrame(frame)
            }
            "relay.offline" -> handleRelayOfflineFrame(frame)
            "relay.error" -> {
                try {
                    PclinkWire.validateRelayError(frame)
                } catch (error: PclinkError) {
                    handleProtocolError(error)
                    return
                }
                val code = frame["code"]?.stringValue ?: "unavailable"
                val message = frame["message"]?.stringValue ?: ""
                handleProtocolError(PclinkError.fromCode(code, message))
            }
            else -> Unit
        }
    }

    /**
     * §10 `relay.offline` correlation. The relay echoes `id`/`streamId`/`sid`
     * only when the undelivered source frame carried them. An `id`/`streamId`
     * identifies one frame and must not settle any other in-flight call; a
     * `sid`-only frame names the whole session (unsafe work becomes
     * `unknown_outcome`, read/idempotent follows §7). A frame for another
     * peer/session is stale and leaves this session untouched.
     */
    private suspend fun handleRelayOfflineFrame(frame: PclinkJson) {
        try {
            PclinkWire.validateRelayOffline(frame)
        } catch (error: PclinkError) {
            handleProtocolError(error)
            return
        }
        val offline = PclinkRelayOffline(
            to = frame.requiredString("to"),
            id = frame["id"]?.stringValue,
            streamId = frame["streamId"]?.stringValue,
            sid = frame["sid"]?.stringValue,
            frame = frame,
        )
        // One phone has one paired PC; an offline for any other target cannot
        // describe a frame this client sent.
        val peerMachineId = record?.peerMachineId
        if (peerMachineId != null && offline.to != peerMachineId) return
        val correlated = (rpcHost as? PclinkRelayEventHost)?.onRelayOffline(offline) ?: false
        val identifiesFrame = offline.id != null || offline.streamId != null
        val activeSids = setOfNotNull(
            session?.sid,
            handshake?.session?.sid,
            rekeyHandshake?.sid,
        )
        val settlesThisSession = when {
            // A sid that is not current names a stale session even when an id
            // happens to collide with one of this session's correlation ids.
            offline.sid != null -> offline.sid in activeSids && (!identifiesFrame || correlated)
            identifiesFrame -> correlated
            else -> true
        }
        if (!settlesThisSession) return
        // Clear the session before publishing Offline: a caller that observes
        // the state must not still find an ESTABLISHED session to reuse.
        closeConnection(PclinkError.PeerOffline())
        setState(PclinkClientState.Offline(PclinkOfflineReason.PeerOffline))
    }

    private suspend fun handleEstablishedFrame(frame: PclinkJson) {
        val active = session ?: return
        if (frame["sid"]?.stringValue == active.sid) {
            try {
                val decoded = active.open(frame)
                if (!active.peerHelloReceived) {
                    if (decoded.inner["type"]?.stringValue == "session.close") {
                        handleSessionClose(decoded.inner, active)
                    } else {
                        active.acceptFirstInner(decoded.inner)
                    }
                } else {
                    handleInner(decoded.inner, active)
                }
                if (active.needsRekey) startRekeyIfNeeded()
            } catch (error: PclinkError) {
                handleProtocolError(error)
            } catch (error: Exception) {
                handleProtocolError(PclinkError.BadFrame("E2E frame handling failed: ${error.message}"))
            }
            return
        }
        val rekey = rekeyHandshake ?: return
        if (frame["sid"]?.stringValue != rekey.sid) return
        try {
            val decoded = rekey.session.open(frame)
            if (!rekey.session.peerHelloReceived) {
                if (decoded.inner["type"]?.stringValue == "session.close") {
                    rekey.fail(PclinkError.SessionExpired("rekey handshake closed"))
                    return
                }
                val hello = rekey.session.acceptFirstInner(decoded.inner)
                completeRekey(rekey.session, hello)
            }
        } catch (error: PclinkError) {
            rekey.fail(error)
        }
    }

    private suspend fun handleInner(inner: PclinkJson, active: PclinkE2eSession) {
        val type = inner["type"]?.stringValue ?: run {
            handleProtocolError(PclinkError.BadFrame("inner message has no type"))
            return
        }
        when (type) {
            "peer.hello" -> handleProtocolError(PclinkError.BadFrame("duplicate peer.hello"))
            "pclink.notice" -> {
                try {
                    val notice = decodeNotice(inner)
                    mutableStatus.value = mutableStatus.value.copy(lastNotice = notice)
                    mutableNotices.emit(notice)
                } catch (_: PclinkError) {
                    handleProtocolError(PclinkError.BadFrame("invalid pclink.notice"))
                }
            }
            "session.close" -> handleSessionClose(inner, active)
            else -> {
                try {
                    PclinkWire.validateInnerMessage(inner)
                } catch (error: PclinkError) {
                    handleProtocolError(error)
                    return
                }
                if (type.startsWith("task.") || type.startsWith("call.")) {
                    if (!type.endsWith(".error")) replyUnavailableReserved(inner)
                    return
                }
                rpcHost?.sendInner(inner)
            }
        }
    }

    private fun decodeNotice(inner: PclinkJson): PclinkNotice {
        PclinkWire.validateInnerMessage(inner)
        return PclinkNotice(
            kind = inner.requiredString("kind"),
            name = inner.requiredString("name"),
            fingerprint = inner.requiredString("fingerprint"),
            at = inner.requiredString("at"),
        )
    }

    private suspend fun replyUnavailableReserved(inner: PclinkJson) {
        val type = inner["type"]?.stringValue ?: return
        val prefix = type.substringBefore('.')
        val reply = pclinkObject(
            "type" to PclinkJson.Text("$prefix.reserved.error"),
            "code" to PclinkJson.Text("unavailable"),
        )
        try {
            sendInner(reply)
        } catch (_: PclinkError) {
            handleProtocolError(PclinkError.SessionExpired("reserved reply could not be sent"))
        }
    }

    private suspend fun handleSessionClose(inner: PclinkJson, active: PclinkE2eSession) {
        val objectValue = try {
            inner.closedObject(required = setOf("type", "code"), optional = setOf("message"))
        } catch (error: PclinkError) {
            handleProtocolError(error)
            return
        }
        val code = objectValue["code"]?.stringValue ?: run {
            handleProtocolError(PclinkError.BadFrame("session.close code"))
            return
        }
        val message = objectValue["message"]?.stringValue ?: ""
        try {
            PclinkWire.validateInnerMessage(inner)
        } catch (error: PclinkError) {
            handleProtocolError(error)
            return
        }
        if (code == "unpaired") {
            promptPCUnpaired(active.peer, code, message)
            val error = PclinkError.Unpaired(message)
            closeConnection(error)
            setState(PclinkClientState.Offline(PclinkOfflineReason.UnpairedPrompt))
            return
        }
        val error = PclinkError.fromCode(code, message)
        val reason = when (code) {
            "version_unsupported" -> PclinkOfflineReason.VersionUnsupported
            "auth_failed" -> PclinkOfflineReason.AuthenticationFailed
            "replaced" -> PclinkOfflineReason.Replaced
            else -> PclinkOfflineReason.ProtocolError(code)
        }
        closeConnection(error)
        setState(PclinkClientState.Offline(reason))
    }

    private fun promptPCUnpaired(peer: PclinkPairingRecord, code: String, message: String) {
        mutableStatus.value = mutableStatus.value.copy(
            pcUnpairedPrompt = PclinkPCUnpairedPrompt(code, message, peer),
            lastError = PclinkError.Unpaired(message),
        )
        setState(PclinkClientState.Offline(PclinkOfflineReason.UnpairedPrompt))
    }

    private fun handleProtocolError(error: PclinkError) {
        mutableStatus.value = mutableStatus.value.copy(lastError = error)
        val reason = when (error) {
            is PclinkError.VersionUnsupported -> PclinkOfflineReason.VersionUnsupported
            is PclinkError.AuthFailed -> PclinkOfflineReason.AuthenticationFailed
            else -> PclinkOfflineReason.ProtocolError(error.code)
        }
        closeConnection(error)
        setState(PclinkClientState.Offline(reason))
    }

    private fun handleConnectionLost() {
        if (stopped) return
        if (session != null || handshake != null) {
            closeConnection(PclinkError.PeerOffline())
            if (mutableStatus.value.state !is PclinkClientState.Offline) {
                setState(PclinkClientState.Offline(PclinkOfflineReason.PeerOffline))
            }
        }
    }

    private fun closeConnection(error: PclinkError?) {
        val currentLink = link
        link = null
        readerJob?.cancel()
        readerJob = null
        handshake?.session?.markClosed()
        handshake = null
        rekeyHandshake?.session?.markClosed()
        rekeyHandshake = null
        session?.markClosed()
        session = null
        error?.let { mutableStatus.value = mutableStatus.value.copy(lastError = it) }
        if (currentLink != null) {
            scope.launch { try { currentLink.close(1000, "closed") } catch (_: Exception) { } }
        }
    }

    // ---- Rekey -----------------------------------------------------------

    private fun startRekeyIfNeeded() {
        val old = session ?: return
        if (!old.needsRekey || rekeyHandshake != null || handshake != null) return
        val activeIdentity = identity ?: return
        val currentRecord = record ?: return
        val currentLink = link ?: return
        val replacement = PclinkE2eSession(activeIdentity, currentRecord, configuration.sessionThresholds)
        val rekey = PclinkHandshake(replacement, makePhoneHello()) { frame -> currentLink.send(frame) }
        rekeyHandshake = rekey
        scope.launch {
            val outcome = rekey.run(configuration.handshakeStepTimeout)
            if (outcome is PclinkHandshakeOutcome.Established) {
                try {
                    currentLink.send(old.closeFrame("rekey"))
                } catch (_: Exception) {
                    // Best effort: the old session is destroyed either way.
                }
                old.markClosed()
                session = replacement
                rekeyHandshake = null
                install(replacement, outcome.hello)
            } else {
                replacement.markClosed()
                rekeyHandshake = null
                val error = when (outcome) {
                    is PclinkHandshakeOutcome.Failed -> outcome.error
                    is PclinkHandshakeOutcome.Rejected ->
                        PclinkError.fromCode(outcome.code, outcome.message)
                    is PclinkHandshakeOutcome.Closed ->
                        PclinkError.SessionExpired(outcome.code)
                    is PclinkHandshakeOutcome.Established -> PclinkError.Unavailable("rekey")
                }
                mutableStatus.value = mutableStatus.value.copy(lastError = error)
            }
        }
    }

    private fun completeRekey(replacement: PclinkE2eSession, hello: PclinkPeerHello) {
        val old = session
        if (old != null) {
            try {
                val currentLink = link
                currentLink?.let { scope.launch { runCatching { it.send(old.closeFrame("rekey")) } } }
            } catch (_: Exception) {
                // Best effort.
            }
            old.markClosed()
        }
        session = replacement
        rekeyHandshake = null
        install(replacement, hello)
    }

    // ---- Pairing internals ----------------------------------------------

    private suspend fun handlePairingFrame(context: PairingContext, frame: PclinkJson) {
        if (pairingContext !== context || context.completed) return
        val type = frame["type"]?.stringValue ?: return
        when (type) {
            "relay.pair.joined" -> {
                try {
                    PclinkPairingWire.validatePairFrame(frame)
                } catch (error: PclinkError) {
                    failPairing(context, error)
                    return
                }
                if (frame.requiredString("rendezvous") != context.offer.rendezvous ||
                    frame.requiredString("role") != "phone"
                ) {
                    failPairing(context, PclinkError.BadFrame("relay.pair.joined shape"))
                    return
                }
                val peer = frame.requiredString("peerMachineId")
                context.offer.pcMachineId?.let { pinned ->
                    if (peer != pinned) {
                        failPairing(context, PclinkError.AuthFailed("the joined PC does not match the QR pin"))
                        return
                    }
                }
                context.joined = true
            }
            "relay.pair.message" -> {
                try {
                    PclinkPairingWire.validatePairFrame(frame)
                } catch (error: PclinkError) {
                    failPairing(context, error)
                    return
                }
                if (frame.requiredString("rendezvous") != context.offer.rendezvous) {
                    failPairing(context, PclinkError.BadFrame("pair message rendezvous mismatch"))
                    return
                }
                val payload = frame["payload"] ?: run {
                    failPairing(context, PclinkError.BadFrame("pair message has no payload"))
                    return
                }
                val message = try {
                    PclinkPairingMessage.decode(payload)
                } catch (error: PclinkError) {
                    failPairing(context, error)
                    return
                }
                if (context.helloMessage == null) {
                    if (!context.joined) {
                        failPairing(context, PclinkError.BadFrame("pair.hello before relay.pair.joined"))
                        return
                    }
                    if (message !is PclinkPairingMessage.Hello) {
                        failPairing(context, PclinkError.BadFrame("expected pair.hello"))
                        return
                    }
                    try {
                        context.offer.verifyHello(message)
                    } catch (error: PclinkError) {
                        failPairing(context, error)
                        return
                    }
                    context.hello.complete(message)
                } else if (context.authNonce != null) {
                    if (message !is PclinkPairingMessage.Confirm) {
                        failPairing(context, PclinkError.BadFrame("expected pair.confirm"))
                        return
                    }
                    context.confirm.complete(message)
                } else {
                    failPairing(context, PclinkError.BadFrame("unexpected pairing message"))
                }
            }
            "relay.pair.close" -> {
                try {
                    PclinkPairingWire.validatePairFrame(frame)
                } catch (error: PclinkError) {
                    failPairing(context, error)
                    return
                }
                if (frame.requiredString("rendezvous") != context.offer.rendezvous) return
                val reason = frame.requiredString("reason")
                if (reason == "paired" && (context.completed || context.finalSent)) return
                failPairing(context, pairingCloseError(reason))
            }
            "relay.error" -> {
                try {
                    PclinkWire.validateRelayError(frame)
                } catch (error: PclinkError) {
                    failPairing(context, error)
                    return
                }
                val code = frame["code"]?.stringValue ?: "unavailable"
                val message = frame["message"]?.stringValue ?: ""
                failPairing(context, PclinkError.fromCode(code, message))
            }
            else -> Unit
        }
    }

    private fun pairingCloseError(reason: String): PclinkError = when (reason) {
        "paired" -> PclinkError.Unavailable("pairing completed without pair.confirm")
        "cancelled" -> PclinkError.PairingCancelled()
        "rejected" -> PclinkError.PairingRejected()
        "peer_offline" -> PclinkError.PeerOffline()
        "rendezvous_expired" -> PclinkError.RendezvousExpired()
        "rendezvous_exhausted" -> PclinkError.RendezvousExhausted()
        "auth_failed" -> PclinkError.AuthFailed("the PC rejected the pairing authentication")
        "storage" -> PclinkError.Storage("the PC could not store the pairing")
        "timeout" -> PclinkError.PairingTimedOut()
        else -> PclinkError.BadFrame("unknown pairing close reason")
    }

    private fun pairingMessageFrame(context: PairingContext, payload: PclinkJson): PclinkJson =
        pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.pair.message"),
            "rendezvous" to PclinkJson.Text(context.offer.rendezvous),
            "payload" to payload,
        )

    private fun pairingCloseFrame(context: PairingContext, reason: String): PclinkJson =
        pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.pair.close"),
            "rendezvous" to PclinkJson.Text(context.offer.rendezvous),
            "reason" to PclinkJson.Text(reason),
        )

    private fun failPairing(context: PairingContext, error: PclinkError) {
        if (context.completed || context.failure != null) return
        context.failure = error
        context.hello.completeExceptionally(error)
        context.confirm.completeExceptionally(error)
        mutableStatus.value = mutableStatus.value.copy(lastError = error, pairingPrompt = null)
        if (!context.completed) {
            val reason = if (staleRecord == null) PclinkUnpairedReason.NoRecord else PclinkUnpairedReason.StaleRecord
            setState(PclinkClientState.Unpaired(reason))
        }
        scope.launch {
            mutablePairingUpdates.emit(PclinkPairingUpdate.Failed(error))
            closePairingContext(context, error)
        }
    }

    private suspend fun closePairingContext(context: PairingContext, error: PclinkError?) {
        context.reader?.cancel()
        context.link?.let { pairingLink ->
            try {
                pairingLink.close(1000, if (error == null) "paired" else "pairing failed")
            } catch (_: Exception) {
                // Already closed.
            }
        }
        if (pairingContext === context) pairingContext = null
    }

    private suspend fun <T> waitForPairing(
        context: PairingContext,
        timeout: Duration,
        block: suspend () -> T,
    ): T = try {
        withTimeout(timeout.toMillis()) {
            val value = block()
            context.failure?.let { throw it }
            value
        }
    } catch (error: TimeoutCancellationException) {
        val timedOut = PclinkError.PairingTimedOut()
        mutableStatus.value = mutableStatus.value.copy(
            pairingUpgradeHint = PCLINK_PRE_V16_UPGRADE_HINT,
            lastError = timedOut,
        )
        failPairing(context, timedOut)
        throw timedOut
    }

    private fun mapPairingError(error: Exception): PclinkError = when (error) {
        is PclinkError -> error
        is TimeoutCancellationException -> PclinkError.PairingTimedOut()
        else -> PclinkError.Unavailable("pairing failed: ${error.message}")
    }

    private fun setState(state: PclinkClientState) {
        mutableStatus.value = mutableStatus.value.copy(state = state)
    }

    private class PairingContext(val offer: PclinkPairingOffer) {
        val id: String = UUID.randomUUID().toString()
        @Volatile var link: PclinkRelayLink? = null
        @Volatile var reader: Job? = null
        val hello = CompletableDeferred<PclinkPairingMessage.Hello>()
        val confirm = CompletableDeferred<PclinkPairingMessage.Confirm>()
        @Volatile var helloMessage: PclinkPairingMessage.Hello? = null
        @Volatile var authNonce: ByteArray? = null
        @Volatile var prompt: PclinkPairingPrompt? = null
        @Volatile var joined: Boolean = false
        @Volatile var completed: Boolean = false
        @Volatile var finalSent: Boolean = false
        @Volatile var failure: PclinkError? = null
    }
}
