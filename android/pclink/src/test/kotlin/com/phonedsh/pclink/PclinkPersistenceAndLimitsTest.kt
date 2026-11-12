// SPDX-License-Identifier: MIT
// C2 persistence/limits: atomic phone store, stale-identity rule, one-record
// cap, PC audit usability, soft/hard rekey and replay/AEAD/reject state.
package com.phonedsh.pclink

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkPersistenceAndLimitsTest {
    private fun record(
        pc: PclinkIdentity,
        origin: String = "https://relay.example",
        pairingMode: PclinkPairingMode? = PclinkPairingMode.QR,
    ): PclinkPairingRecord = PclinkPairingRecord(
        peerMachineId = pc.machineId,
        peerPublicKey = pc.publicKey,
        peerName = "My PC",
        pairedAt = "2026-11-09T00:00:00Z",
        relayOrigin = origin,
        pairingMode = pairingMode,
    )

    @Test
    fun fileStoreRoundTripStaleRuleAndOneRecordCap() {
        val directory = Files.createTempDirectory("pclink-store")
        try {
            val phone = PclinkIdentity.generate()
            val other = PclinkIdentity.generate()
            val pc = PclinkIdentity.generate()
            val store = PclinkFilePairingStore.inDirectory(directory)
            assertEquals(PclinkPairingStoreState.None, store.load(phone.machineId))
            assertFalse(store.hasStoredFile())

            val saved = record(pc)
            store.save(saved, phone.machineId)
            assertEquals(PclinkPairingStoreState.Usable(saved), store.load(phone.machineId))
            assertEquals(PclinkPairingStoreState.Stale(saved), store.load(other.machineId))
            assertTrue(store.hasStoredFile())
            // No temporary file survives a successful atomic replace.
            Files.list(directory).use { paths ->
                assertEquals(
                    listOf("pairs.json"),
                    paths.map { it.fileName.toString() }.sorted().toList(),
                )
            }

            store.delete()
            assertEquals(PclinkPairingStoreState.None, store.load(phone.machineId))
            assertFalse(store.hasStoredFile())
        } finally {
            deleteRecursively(directory)
        }
    }

    @Test
    fun storeRejectsTwoRecordsAndPhoneApprovalFields() {
        val directory = Files.createTempDirectory("pclink-store")
        try {
            val phone = PclinkIdentity.generate()
            val pc = PclinkIdentity.generate()
            val other = PclinkIdentity.generate()
            val store = PclinkFilePairingStore.inDirectory(directory)
            val file = directory.resolve(PclinkFilePairingStore.DEFAULT_FILE_NAME)

            writeEnvelope(
                file,
                phone.machineId,
                listOf(record(pc).toJson(), record(other).toJson()),
            )
            assertPclinkCode("storage") { store.load(phone.machineId) }

            val members = LinkedHashMap(record(pc).toJson().objectValue!!)
            members["approvedAt"] = PclinkJson.Text("2026-11-09T00:00:05Z")
            members["approvedVia"] = PclinkJson.Text("qr")
            writeEnvelope(file, phone.machineId, listOf(PclinkJson.Object(members)))
            assertPclinkCode("storage") { store.load(phone.machineId) }

            // The PC record is a different schema and remains valid.
            PclinkPairingRecord.validatePcRecordJson(
                PclinkJson.Object(
                    LinkedHashMap<String, PclinkJson>(
                        record(pc, pairingMode = null).toJson().objectValue!!,
                    ).apply {
                        put("approvedAt", PclinkJson.Text("2026-11-09T00:00:05Z"))
                        put("approvedVia", PclinkJson.Text("qr"))
                    },
                ),
            )
        } finally {
            deleteRecursively(directory)
        }
    }

    @Test
    fun auditRecordRowsAndConfirmRecheck() {
        val vectors = TestSupport.vectors()
        val pairing = TestSupport.at(vectors, "pairing") ?: throw AssertionError("missing pairing")
        val audit = TestSupport.at(pairing, "audit") ?: throw AssertionError("missing audit")
        val usable = TestSupport.at(audit, "approved_usable")!!
        assertEquals(
            PclinkRecordUsability.USABLE,
            PclinkRecordAudit.evaluate(
                TestSupport.at(usable, "record")!!,
                TestSupport.objects(usable, "audit"),
            ),
        )
        val pcRecord = TestSupport.at(pairing, "records", "pc")!!
        assertEquals(PclinkRecordUsability.UNAPPROVED, PclinkRecordAudit.evaluate(pcRecord, emptyList()))
        assertEquals(
            PclinkRecordUsability.REVOKED,
            PclinkRecordAudit.evaluate(
                pcRecord,
                listOf(
                    TestSupport.at(audit, "pair_entry")!!,
                    TestSupport.at(audit, "unpair_entry")!!,
                ),
            ),
        )

        val recheck = TestSupport.at(TestSupport.at(vectors, "resources")!!, "confirm_recheck")!!
        for (name in listOf("approved", "revoked")) {
            val entry = TestSupport.at(recheck, name) ?: throw AssertionError("missing $name")
            val usability = PclinkRecordAudit.evaluate(
                TestSupport.at(entry, "record")!!,
                TestSupport.objects(entry, "audit"),
            )
            assertEquals(
                name,
                TestSupport.requireString(entry, "expected"),
                if (usability == PclinkRecordUsability.USABLE) "establish" else "abort",
            )
        }
    }

    @Test
    fun sessionSoftRekeyAndHardCaps() {
        val hello = PclinkPeerHello.make(
            role = "phone",
            caps = listOf("workspace/1", PclinkCrypto.SUITE),
            dshVersion = "0.2.2-rc.1",
            dshCommit = null,
            appName = "phoneDSH",
            appVersion = "0.1.0",
            name = "Android phone",
        )
        val soft = C2TestSupport.goldenSession(
            PclinkSessionThresholds(softFrames = 2, hardFrames = 10),
        )
        soft.makePeerHelloFrame(hello)
        soft.seal(pclinkObject("type" to PclinkJson.Text("peer.hello")))
        assertTrue("soft frame threshold starts a rekey", soft.needsRekey)
        assertEquals(2L, soft.sentFrames)

        val hard = C2TestSupport.goldenSession(
            PclinkSessionThresholds(softFrames = 100, hardFrames = 2),
        )
        hard.makePeerHelloFrame(hello)
        hard.seal(pclinkObject("type" to PclinkJson.Text("peer.hello")))
        assertEquals(2L, hard.sentFrames)
        assertPclinkCode("session_expired") {
            hard.seal(pclinkObject("type" to PclinkJson.Text("peer.hello")))
        }

        val byteHard = C2TestSupport.goldenSession(
            PclinkSessionThresholds(hardBytes = 1),
        )
        val pcHello = C2TestSupport.frameCase("pc-peer-hello-seq0")
        assertPclinkCode("session_expired") {
            byteHard.open(C2TestSupport.outerFrame(pcHello))
        }
    }

    @Test
    fun receiveReplayGapHardCapAndAeadFailure() {
        val helloSession = C2TestSupport.goldenSession()
        val helloFrame = C2TestSupport.outerFrame(C2TestSupport.frameCase("pc-peer-hello-seq0"))
        helloSession.open(helloFrame)
        assertPclinkCode("replay") { helloSession.open(helloFrame) }

        val gapSession = C2TestSupport.goldenSession()
        gapSession.open(C2TestSupport.outerFrame(C2TestSupport.frameCase("pc-peer-hello-seq0")))
        assertPclinkCode("bad_frame") {
            gapSession.open(C2TestSupport.outerFrame(C2TestSupport.frameCase("pc-stream-item-seq2")))
        }

        val hardSession = C2TestSupport.goldenSession(
            PclinkSessionThresholds(hardFrames = 1),
        )
        assertPclinkCode("session_expired") {
            hardSession.open(C2TestSupport.outerFrame(C2TestSupport.frameCase("pc-rpc-result-seq1")))
        }

        val corrupt = C2TestSupport.frameCase("pc-peer-hello-seq0")
        val body = TestSupport.b64(corrupt, "body")!!.copyOf()
        body[body.lastIndex] = (body[body.lastIndex].toInt() xor 0xFF).toByte()
        val corruptFrame = pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("e2e"),
            "sid" to PclinkJson.Text(TestSupport.requireString(corrupt, "sid")),
            "seq" to PclinkJson.Integer(TestSupport.requireInt(corrupt, "seq")),
            "from" to PclinkJson.Text(TestSupport.requireString(corrupt, "from")),
            "to" to PclinkJson.Text(TestSupport.requireString(corrupt, "to")),
            "body" to PclinkJson.Text(PclinkBase64Url.encode(body)),
        )
        val corruptSession = C2TestSupport.goldenSession()
        assertPclinkCode("auth_failed") { corruptSession.open(corruptFrame) }
    }

    @Test
    fun rejectVerificationAndPolicy() {
        val session = C2TestSupport.goldenSession()
        val reject = TestSupport.at(TestSupport.vectors(), "handshake", "reject")!!
        val verified = session.verifyReject(reject)
        assertTrue(verified is PclinkRejectVerification.Verified)
        assertEquals(
            PclinkRejectHandling.PROMPT,
            PclinkRejectPolicy.decide(
                verified = true,
                code = "unpaired",
                th1Matches = true,
                hasRecord = true,
            ),
        )

        val badSignature = TestSupport.b64(reject, "sig")!!.copyOf()
        badSignature[0] = (badSignature[0].toInt() xor 1).toByte()
        val badBody = LinkedHashMap(reject.objectValue!!)
        badBody["sig"] = PclinkJson.Text(PclinkBase64Url.encode(badSignature))
        val unauthenticated = session.verifyReject(PclinkJson.Object(badBody))
        assertTrue(unauthenticated is PclinkRejectVerification.Unauthenticated)
        assertEquals(
            PclinkRejectHandling.KEEP_RECORD,
            PclinkRejectPolicy.decide(
                verified = false,
                code = "unpaired",
                th1Matches = true,
                hasRecord = true,
            ),
        )

        val wrongSid = LinkedHashMap(reject.objectValue!!)
        wrongSid["sid"] = PclinkJson.Text("AAAAAAAAAAAAAAAAAAAAAA")
        val wrong = session.verifyReject(PclinkJson.Object(wrongSid))
        assertTrue(wrong is PclinkRejectVerification.Unauthenticated)
        assertEquals("bad_frame", (wrong as PclinkRejectVerification.Unauthenticated).code)
    }

    @Test
    fun freshEphemeralAndSidPerHandshake() {
        val phone = C2TestSupport.phoneIdentity()
        val peer = C2TestSupport.peerRecord()
        val first = PclinkE2eSession(phone, peer)
        val second = PclinkE2eSession(phone, peer)
        assertNotEquals(first.sid, second.sid)
        assertNotEquals(
            PclinkBase64Url.encode(first.ephemeralPublicKey),
            PclinkBase64Url.encode(second.ephemeralPublicKey),
        )
        assertNotEquals(
            PclinkBase64Url.encode(first.phoneNonce),
            PclinkBase64Url.encode(second.phoneNonce),
        )
        first.markClosed()
        second.markClosed()
        assertFalse(first.ephemeralPrivateRetained)
    }

    @Test
    fun resourceRowsAndSlotLimits() {
        val vectors = TestSupport.vectors()
        val resources = TestSupport.at(vectors, "resources") ?: throw AssertionError("missing resources")
        assertEquals(
            PclinkLimits.PC_SID_CACHE_LIMIT.toLong(),
            TestSupport.requireInt(TestSupport.at(resources, "sid_cache")!!, "limit"),
        )
        assertEquals(
            PclinkLimits.PAIRING_SLOTS_PER_CONNECTION.toLong(),
            TestSupport.requireInt(TestSupport.at(resources, "pairing_slots")!!, "limit"),
        )
        assertEquals(
            PclinkLimits.PC_E2E_IDLE_TIMEOUT.toMillis(),
            TestSupport.requireInt(TestSupport.at(resources, "e2e_idle")!!, "limit_ms"),
        )
        assertEquals(300L, PclinkLimits.PAIRING_SLOT_LIFETIME.seconds)
        assertEquals(10, PclinkLimits.PAIRING_JOIN_LIMIT)

        val approval = TestSupport.at(resources, "approval")!!
        for (entry in approval.objectValue!!.values) {
            val mode = entry["mode"]?.stringValue ?: continue
            val approved = entry["approved"]?.boolValue ?: false
            val decision = if (mode == "qr" || mode == "manual") {
                if (approved) "confirm_sent" else "blocked"
            } else {
                "bad_frame"
            }
            assertEquals(decision, entry["expected"]?.stringValue)
        }
        val unpairAbort = TestSupport.at(resources, "unpair_abort")!!
        assertEquals(
            "abort",
            if (unpairAbort["handshake_in_progress"]?.boolValue == true &&
                unpairAbort["unpair"]?.boolValue == true
            ) {
                "abort"
            } else {
                "continue"
            },
        )

        for (row in TestSupport.objects(vectors, "invalid")) {
            if (TestSupport.string(row, "kind") != "slot") continue
            val elapsed = TestSupport.requireInt(row, "now_ms") - TestSupport.requireInt(row, "opened_ms")
            val ttl = TestSupport.requireInt(row, "ttl_ms")
            val joins = TestSupport.requireInt(row, "joins")
            val limit = TestSupport.requireInt(row, "limit")
            val matched = TestSupport.requireBool(row, "matched")
            val decision = when {
                joins >= limit || matched -> "exhausted"
                elapsed > ttl -> "expired"
                else -> "accept"
            }
            assertEquals(TestSupport.requireString(row, "case"), TestSupport.requireString(row, "expected"), decision)
        }
    }

    private fun writeEnvelope(file: Path, phoneMachineId: String, records: List<PclinkJson>) {
        val document = pclinkObject(
            "v" to PclinkJson.Integer(1),
            "phoneMachineId" to PclinkJson.Text(phoneMachineId),
            "records" to PclinkJson.Array(records),
        )
        Files.write(file, PclinkJsonEncoder.encode(document))
    }

    private fun deleteRecursively(directory: Path) {
        if (!Files.exists(directory)) return
        Files.walk(directory).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }
}
