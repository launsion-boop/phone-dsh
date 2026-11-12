// SPDX-License-Identifier: MIT
// The real `PclinkClient` behind the controller's port: a QR intent reaches the
// client's WaitingForPC phase and a cancel returns the page to idle. The relay
// seam is an in-memory silent link (our fake behind the `:pclink` interface), so
// no network and no second protocol implementation is involved.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkClient
import com.phonedsh.pclink.PclinkClientConfiguration
import com.phonedsh.pclink.PclinkFilePairingStore
import com.phonedsh.pclink.PclinkIdentityStore
import com.phonedsh.pclink.PclinkJson
import com.phonedsh.pclink.PclinkPairingPhase
import com.phonedsh.pclink.PclinkRelayLink
import com.phonedsh.pclink.PclinkRelayLinkFactory
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PcWorkspaceRealClientTest {
    private class SilentLink : PclinkRelayLink {
        val sent = CopyOnWriteArrayList<PclinkJson>()
        private val incomingChannel = Channel<PclinkJson>(Channel.UNLIMITED)
        override val incoming: Flow<PclinkJson> = incomingChannel.receiveAsFlow()

        override suspend fun send(frame: PclinkJson) {
            sent.add(frame)
        }

        override suspend fun close(code: Int, reason: String) {
            incomingChannel.close()
        }
    }

    private fun goldenQrUri(): String {
        val root = java.io.File(System.getProperty("pdsh.repo.root") ?: ".").absoluteFile
        val vectors = java.io.File(root, "spec/pclink/v1/golden/pclink-v1-vectors.json")
        return JSONObject(vectors.readText()).getJSONObject("pairing").getJSONObject("qr").getString("uri")
    }

    @Test
    fun `a real client enters WaitingForPC and cancel returns to idle`() = runBlocking {
        val directory = Files.createTempDirectory("pc-real-client")
        val store = object : PclinkIdentityStore {
            private var seed: ByteArray? = null
            override fun loadSeed(): ByteArray? = seed
            override fun saveSeed(seed: ByteArray) {
                this.seed = seed.copyOf()
            }
            override fun deleteSeed() {
                seed = null
            }
        }
        val link = SilentLink()
        val client = PclinkClient(
            identityStore = store,
            pairingStore = PclinkFilePairingStore(directory.resolve("pairs.json")),
            relayLinkFactory = object : PclinkRelayLinkFactory {
                override suspend fun connect(url: String): PclinkRelayLink = link
            },
            configuration = PclinkClientConfiguration(),
        )
        val transport = ScriptedDshCall()
        val controller = PcWorkspaceController(
            client = PclinkClientAdapter(client),
            transport = transport,
            storage = PcWorkspaceStorage(MapPreferenceFile(), directory.resolve("roster")),
            diagnostics = PcDiagnosticsLog(directory.toFile()),
            turnRunner = PcChatTurnRunner(transport),
            onClose = { runBlocking { client.stop() } },
        )
        try {
            controller.startPairingQr(goldenQrUri())
            val waiting = withTimeout(5_000) {
                controller.state.first { it.pairing.phase == PcPairingPhase.WAITING_FOR_PC }
            }
            assertEquals(PcPairingPhase.WAITING_FOR_PC, waiting.pairing.phase)
            assertTrue(
                "the client sent relay.pair.join through the real client",
                link.sent.any { it["type"]?.stringValue == "relay.pair.join" },
            )
            controller.cancelPairing()?.join()
            val idle = withTimeout(5_000) {
                controller.state.first { it.pairing.phase == PcPairingPhase.IDLE }
            }
            assertEquals(PcPairingPhase.IDLE, idle.pairing.phase)
        } finally {
            controller.close()
        }
    }
}
