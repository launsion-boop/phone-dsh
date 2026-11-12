// SPDX-License-Identifier: MIT
// The Android composition root for the C5 PC workspace. It is the only place
// that constructs the PCLink client/RPC/transport, the Keystore identity store,
// the P18 store and the diagnostics log, and the only place that closes them.
//
// C4 wiring order (the C4 worker's report): PclinkRpc -> PclinkClient(rpcHost)
// -> rpc.attach(client) -> PclinkDshTransport. Closing the workspace closes the
// RPC first; the client's relay socket is then stopped on its own scope so a
// main-thread `onCleared` never blocks on a close frame.
package com.phonedsh.probe.pc

import android.content.Context
import com.phonedsh.pclink.PclinkClient
import com.phonedsh.pclink.PclinkClientConfiguration
import com.phonedsh.pclink.PclinkClientStatus
import com.phonedsh.pclink.PclinkDshTransport
import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkFilePairingStore
import com.phonedsh.pclink.PclinkIdentity
import com.phonedsh.pclink.PclinkIdentityStore
import com.phonedsh.pclink.PclinkNotice
import com.phonedsh.pclink.PclinkPairingPrompt
import com.phonedsh.pclink.PclinkPairingResult
import com.phonedsh.pclink.PclinkPairingUpdate
import com.phonedsh.pclink.PclinkRelayClientFactory
import com.phonedsh.pclink.PclinkRelayLink
import com.phonedsh.pclink.PclinkRelayLinkFactory
import com.phonedsh.pclink.PclinkRpc
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.probe.SharedPreferenceFile
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Production [PcLinkClientPort]: a thin delegation to the real client. */
internal class PclinkClientAdapter(
    private val client: PclinkClient,
) : PcLinkClientPort {
    override val status: StateFlow<PclinkClientStatus> get() = client.status
    override val notices: SharedFlow<PclinkNotice> get() = client.notices
    override val pairingUpdates: SharedFlow<PclinkPairingUpdate> get() = client.pairingUpdates

    override suspend fun start() = client.start()
    override suspend fun beginPairing(qrUri: String): PclinkPairingPrompt = client.beginPairing(qrUri)
    override suspend fun beginManualPairing(code: String, relayOrigin: String): PclinkPairingPrompt =
        client.beginManualPairing(code, relayOrigin)
    override suspend fun confirmPairing(id: String): PclinkPairingResult = client.confirmPairing(id)
    override suspend fun cancelPairing() = client.cancelPairing()
    override suspend fun unpair() = client.unpair()
    override suspend fun acknowledgePCUnpair() = client.acknowledgePCUnpair()
    override suspend fun removeLocalRecord() = client.removeLocalRecord()
    override suspend fun foregroundResumed() = client.foregroundResumed()
    override suspend fun stop() = client.stop()
    override fun clearLastError() = client.clearLastError()
}

/**
 * Identity source for the real relay dialer. The seed is read when a dial
 * starts, not at construction: `PclinkClient` may generate the first-run seed
 * itself, and a missing/unreadable seed must fail closed at dial time instead
 * of surfacing as a constructor crash before the pairing page can render.
 */
internal class StoredIdentityRelayLinkFactory(
    private val identityStore: PclinkIdentityStore,
) : PclinkRelayLinkFactory, AutoCloseable {
    private var factory: PclinkRelayClientFactory? = null

    override suspend fun connect(url: String): PclinkRelayLink {
        val seed = identityStore.loadSeed() ?: throw PclinkError.NoIdentity()
        val identity = PclinkIdentity(seed)
        val current = synchronized(this) {
            factory ?: PclinkRelayClientFactory(identity).also { factory = it }
        }
        return current.connect(url)
    }

    override fun close() {
        synchronized(this) { factory }?.close()
        synchronized(this) { factory = null }
    }
}

/**
 * One PCLink workspace. The controller is the App's read model; this object
 * owns the resources and closes them exactly once.
 */
internal class PcLinkWorkspace internal constructor(
    private val client: PcLinkClientPort,
    private val transport: PcDshCall,
    private val storage: PcWorkspaceStorage,
    private val diagnostics: PcDiagnosticsLog,
    private val rpc: PclinkRpc?,
    private val closeables: List<AutoCloseable>,
    private val closeScope: CoroutineScope,
    private val cameraAvailability: () -> PcCameraAvailability = { PcCameraAvailability.UNKNOWN },
) : AutoCloseable {
    private var closed = false

    fun controller(
        presence: com.phonedsh.pclink.PclinkPresence = com.phonedsh.pclink.PclinkPresence(),
        cameraAvailability: () -> PcCameraAvailability = this.cameraAvailability,
    ): PcWorkspaceController {
        val runner = PcChatTurnRunner(transport)
        return PcWorkspaceController(
            client = client,
            transport = transport,
            storage = storage,
            diagnostics = diagnostics,
            turnRunner = runner,
            presence = presence,
            cameraAvailability = cameraAvailability,
            onClose = ::close,
        )
    }

    override fun close() {
        synchronized(this) {
            if (closed) return
            closed = true
        }
        // The RPC is the first release: a pending call must fail closed even if
        // the socket close below is slow. The client then sends its close frame,
        // and only after that is the shared WebSocket factory closed.
        rpc?.close()
        closeScope.launch {
            try {
                client.stop()
            } catch (_: Exception) {
                // The socket may already be gone with the process.
            } finally {
                closeables.forEach { closeable ->
                    try {
                        closeable.close()
                    } catch (_: Exception) {
                        // Teardown is best-effort; the RPC above is the ordering guarantee.
                    }
                }
                closeScope.cancel()
            }
        }
    }

    companion object {
        /**
         * The production relay origin used by manual-code pairing. A QR/paste
         * URI carries its own `r=` field and wins; this value is only the
         * missing-relay fallback. It matches the iOS
         * `PCLinkRelayConfiguration.productionOrigin`.
         */
        const val DEFAULT_MANUAL_RELAY_ORIGIN: String = "https://pclink.tonoai.cn"

        /** The P18 identity account (`SecureStorePclinkIdentityStore.KEY`). */
        const val IDENTITY_KEY: String = SecureStorePclinkIdentityStore.KEY

        const val PAIRING_FILE: String = "pclink/pairs.json"

        /**
         * Constructs the real workspace. No network is dialed here: the client
         * only loads/generates the identity and, with a record, starts its own
         * connection job after [PcWorkspaceController.start].
         */
        fun create(context: Context, appVersion: String = "0.1.0"): PcLinkWorkspace {
            val appContext = context.applicationContext
            val identityStore = SecureStorePclinkIdentityStore(AndroidSecureStore(appContext))
            val pairingFile = File(appContext.filesDir, PAIRING_FILE)
            val pairingStore = PclinkFilePairingStore(pairingFile.toPath())
            val relayFactory = StoredIdentityRelayLinkFactory(identityStore)
            val rpc = PclinkRpc()
            val client = PclinkClient(
                identityStore = identityStore,
                pairingStore = pairingStore,
                relayLinkFactory = relayFactory,
                configuration = PclinkClientConfiguration(
                    // A fixed, NFC/≤64-byte name: `Build.MODEL` is OEM input and
                    // is not a valid PCLink `name` on every device (some exceed
                    // the 64-byte bound or are not NFC), which would fail the
                    // handshake before the page can show anything.
                    phoneName = "Android phone",
                    appVersion = appVersion,
                ),
                rpcHost = rpc,
            )
            rpc.attach(client)
            val transport = PclinkDshTransport(rpc)
            val storage = PcWorkspaceStorage(
                preferences = SharedPreferenceFile(appContext),
                rosterDirectory = File(appContext.filesDir, PcWorkspaceStorage.ROSTER_DIRECTORY).toPath(),
            )
            val diagnostics = PcDiagnosticsLog(appContext.filesDir)
            return PcLinkWorkspace(
                client = PclinkClientAdapter(client),
                transport = PclinkDshTransportCall(transport),
                storage = storage,
                diagnostics = diagnostics,
                rpc = rpc,
                closeables = listOf(relayFactory),
                closeScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
                cameraAvailability = { PcQrScanner.availability(appContext) },
            )
        }
    }
}
