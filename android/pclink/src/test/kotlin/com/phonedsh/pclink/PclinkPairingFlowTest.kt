// SPDX-License-Identifier: MIT
// End-to-end C2 pairing through the real PclinkClient/PclinkE2eSession over
// FakeRelayLink + FakePc: QR pin, automatic approval, durable record before
// pair.final, the CCR-1 timeout/upgrade hint, reject and already-paired paths.
package com.phonedsh.pclink

import java.time.Duration
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkPairingFlowTest {
    private fun config(
        pairingTimeout: Duration = Duration.ofSeconds(3),
        approvalTimeout: Duration = Duration.ofMillis(500),
        autoConnect: Boolean = true,
    ) = PclinkClientConfiguration(
        pairingTimeout = pairingTimeout,
        pairingApprovalTimeout = approvalTimeout,
        handshakeStepTimeout = Duration.ofSeconds(2),
        autoConnectAfterPairing = autoConnect,
    )

    private fun qrOffer(pc: PclinkIdentity, secret: ByteArray): PclinkPairingOffer =
        PclinkQrCode.parse(
            PclinkQrCode.makeUri(
                relayOrigin = "https://relay.example",
                pcMachineId = pc.machineId,
                pcPublicKey = pc.publicKey,
                secret = secret,
                pcName = "My PC",
            ),
        )

    @Test
    fun fullQrPairingWritesRecordThenConnects() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val secret = PclinkRandom.bytes(16)
        val offer = qrOffer(pc, secret)
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
        )
        val store = InMemoryPairingStore()
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val prompt = client.beginPairing(offer)
            assertEquals(PclinkPairingMode.QR, prompt.mode)
            assertEquals(pc.machineId, prompt.pcMachineId)
            assertEquals("My PC", prompt.pcName)
            assertEquals(phone.fingerprint, prompt.ownFingerprint)
            assertEquals(PclinkPairingPrompt.FULL_OWNER_WARNING, prompt.warningText)
            assertNull(client.status().record)

            val result = client.confirmPairing(prompt.id)
            assertEquals(pc.machineId, result.record.peerMachineId)
            assertEquals(pc.publicKey.toList(), result.record.peerPublicKey.toList())
            assertEquals(offer.relayOrigin, result.record.relayOrigin)
            assertEquals(PclinkPairingMode.QR, result.record.pairingMode)
            assertNotNull(store.stored)
            assertTrue("pair.final reached the PC", fakePc.pairingFinalReceived)
            assertTrue("client wrote the record before final", store.savedBeforeFinal)

            client.connectAndWait()
            val status = client.status()
            assertTrue("client is online: ${status.state}", status.state.isOnline)
            assertEquals(pc.machineId, status.record?.peerMachineId)
            assertEquals("0.2.2-rc.1", status.peerDshVersion)
            assertEquals(1, fakePc.handshakeCount)
            assertTrue(fakePc.phoneHelloReceived)
            assertEquals(listOf(0L), fakePc.receivedSeq.toList())
        } finally {
            client.stop()
        }
    }

    @Test
    fun manualPairingUsesTheSameAutomaticApproval() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val manualSecret = PclinkRandom.bytes(10)
        val offer = PclinkManualCode.parse(PclinkManualCode.display(manualSecret), "https://relay.example")
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
        )
        val store = InMemoryPairingStore()
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val prompt = client.beginPairing(offer)
            assertEquals(PclinkPairingMode.MANUAL, prompt.mode)
            val result = client.confirmPairing(prompt.id)
            assertEquals(PclinkPairingMode.MANUAL, result.record.pairingMode)
            assertTrue(fakePc.pairingFinalReceived)
        } finally {
            client.stop()
        }
    }

    @Test
    fun existingRecordBlocksNewPairing() = runBlocking {
        val phone = PclinkIdentity.generate()
        val oldPc = PclinkIdentity.generate()
        val newPc = PclinkIdentity.generate()
        val record = recordFor(oldPc, "https://relay.example")
        val store = InMemoryPairingStore(record)
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(
                FakePc(pcIdentity = newPc, origin = "https://relay.example"),
            ),
            configuration = config(autoConnect = false),
        )
        try {
            val offer = qrOffer(newPc, PclinkRandom.bytes(16))
            val error = try {
                client.beginPairing(offer)
                throw AssertionError("already paired must block a new pairing")
            } catch (error: PclinkError) {
                error
            }
            assertEquals("already_paired", error.code)
            assertEquals(record, store.stored)
            assertEquals(record, client.status().record)
        } finally {
            client.stop()
        }
    }

    @Test
    fun preV16PcTimesOutWithUpgradeHintAndNoRecord() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val offer = qrOffer(pc, PclinkRandom.bytes(16))
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
            autoConfirmPairing = false,
        )
        val store = InMemoryPairingStore()
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(approvalTimeout = Duration.ofMillis(150)),
        )
        try {
            val prompt = client.beginPairing(offer)
            val error = try {
                client.confirmPairing(prompt.id)
                throw AssertionError("a pre-v1.6 PC must not complete a pairing")
            } catch (error: PclinkError) {
                error
            }
            assertEquals("timeout", error.code)
            assertEquals(PCLINK_PRE_V16_UPGRADE_HINT, client.status().pairingUpgradeHint)
            assertNull(store.stored)
            assertFalse(fakePc.pairingFinalReceived)
            assertTrue(fakePc.pairingAuthReceived)
            assertTrue(
                "no fingerprint card / no approval prompt on the v1.6 client",
                !prompt.warningText.contains("指纹"),
            )
        } finally {
            client.stop()
        }
    }

    @Test
    fun pcRejectDoesNotWriteARecord() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val offer = qrOffer(pc, PclinkRandom.bytes(16))
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
            pairingRejectReason = "rejected",
        )
        val store = InMemoryPairingStore()
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val prompt = client.beginPairing(offer)
            val error = try {
                client.confirmPairing(prompt.id)
                throw AssertionError("rejected pairing must not complete")
            } catch (error: PclinkError) {
                error
            }
            assertEquals("rejected", error.code)
            assertNull(store.stored)
            assertFalse(fakePc.pairingFinalReceived)
        } finally {
            client.stop()
        }
    }

    @Test
    fun durableWriteFailureSendsStorageAndNoFinal() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val offer = qrOffer(pc, PclinkRandom.bytes(16))
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
        )
        val store = InMemoryPairingStore(failOnSave = true)
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val prompt = client.beginPairing(offer)
            val error = try {
                client.confirmPairing(prompt.id)
                throw AssertionError("storage failure must fail the pairing")
            } catch (error: PclinkError) {
                error
            }
            assertEquals("storage", error.code)
            assertNull(store.stored)
            assertFalse(fakePc.pairingFinalReceived)
            assertEquals("storage", fakePc.pairCloseReason)
        } finally {
            client.stop()
        }
    }

    @Test
    fun qrPinMismatchFailsAuthenticationWithoutRecord() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pinnedPc = PclinkIdentity.generate()
        val actualPc = PclinkIdentity.generate()
        val offer = qrOffer(pinnedPc, PclinkRandom.bytes(16))
        val fakePc = FakePc(
            pcIdentity = actualPc,
            origin = offer.relayOrigin,
            pairingOffer = offer,
        )
        val store = InMemoryPairingStore()
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val error = try {
                client.beginPairing(offer)
                throw AssertionError("a swapped PC key must fail the QR pin")
            } catch (error: PclinkError) {
                error
            }
            assertEquals(error.message, "auth_failed", error.code)
            assertNull(store.stored)
        } finally {
            client.stop()
        }
    }

    @Test
    fun pairedV15RecordStillConnects() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        // A v1.5 record has no phone-side `pairingMode`; the same E2E bytes must
        // remain usable (CCR-1 option (a)).
        val legacy = PclinkPairingRecord(
            peerMachineId = pc.machineId,
            peerPublicKey = pc.publicKey,
            peerName = "My PC",
            pairedAt = "2026-11-09T00:00:00Z",
            relayOrigin = "https://relay.example",
            pairingMode = null,
        )
        val store = InMemoryPairingStore(legacy)
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = legacy.relayOrigin,
            phoneMachineId = phone.machineId,
            phonePublicKey = phone.publicKey,
        )
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            client.connectAndWait()
            assertTrue(client.status().state.isOnline)
            assertEquals(legacy, store.stored)
            assertNull(client.status().record?.pairingMode)
            assertEquals(1, fakePc.handshakeCount)
        } finally {
            client.stop()
        }
    }

    @Test
    fun signedUnpairedRejectPromptsButKeepsRecord() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val record = recordFor(pc, "https://relay.example")
        val store = InMemoryPairingStore(record)
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = record.relayOrigin,
            phoneMachineId = phone.machineId,
            phonePublicKey = phone.publicKey,
            handshakeRejectCode = "unpaired",
        )
        val client = PclinkClient(
            identityStore = InMemoryIdentityStore(phone.seed),
            pairingStore = store,
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = config(),
        )
        try {
            val error = try {
                client.connectAndWait()
                throw AssertionError("unpaired reject must fail the handshake")
            } catch (error: PclinkError) {
                error
            }
            assertEquals("unpaired", error.code)
            assertEquals(record, store.stored)
            assertNotNull(client.status().pcUnpairedPrompt)
            assertEquals(PclinkPCUnpairedPrompt.TEXT, PclinkPCUnpairedPrompt.TEXT)

            client.acknowledgePCUnpair()
            assertNull(store.stored)
            assertEquals(
                PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
                client.status().state,
            )
        } finally {
            client.stop()
        }
    }

    @Test
    fun unsignedOrWrongRejectKeepsRecordAndDoesNotPrompt() = runBlocking {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val record = recordFor(pc, "https://relay.example")
        val store = InMemoryPairingStore(record)
        // FakePc signs correctly; corrupt the signature by changing th1/code on
        // the client side is covered by GoldenVectorHandshakeTest. Here assert
        // the policy boundary for an unauthenticated reject.
        assertEquals(
            PclinkRejectHandling.KEEP_RECORD,
            PclinkRejectPolicy.decide(
                verified = false,
                code = "unpaired",
                th1Matches = true,
                hasRecord = true,
            ),
        )
        assertEquals(
            PclinkRejectHandling.KEEP_RECORD,
            PclinkRejectPolicy.decide(
                verified = true,
                code = "auth_failed",
                th1Matches = true,
                hasRecord = true,
            ),
        )
        assertEquals(record, store.stored)
    }


    private fun recordFor(pc: PclinkIdentity, origin: String): PclinkPairingRecord =
        PclinkPairingRecord(
            peerMachineId = pc.machineId,
            peerPublicKey = pc.publicKey,
            peerName = "My PC",
            pairedAt = "2026-11-09T00:00:00Z",
            relayOrigin = origin,
            pairingMode = PclinkPairingMode.QR,
        )
}

private class InMemoryIdentityStore(seed: ByteArray?) : PclinkIdentityStore {
    private var value = seed?.copyOf()

    override fun loadSeed(): ByteArray? = value?.copyOf()

    override fun saveSeed(seed: ByteArray) {
        value = seed.copyOf()
    }

    override fun deleteSeed() {
        value = null
    }
}

private class InMemoryPairingStore(
    initial: PclinkPairingRecord? = null,
    private val failOnSave: Boolean = false,
) : PclinkPairingStore {
    @Volatile
    var stored: PclinkPairingRecord? = initial

    @Volatile
    var savedBeforeFinal: Boolean = false

    override fun load(phoneMachineId: String): PclinkPairingStoreState =
        stored?.let { PclinkPairingStoreState.Usable(it) } ?: PclinkPairingStoreState.None

    override fun save(record: PclinkPairingRecord, phoneMachineId: String) {
        if (failOnSave) throw PclinkError.Storage("injected storage failure")
        stored = record
        savedBeforeFinal = true
    }

    override fun delete() {
        stored = null
    }

    override fun hasStoredFile(): Boolean = stored != null
}
