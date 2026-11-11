// SPDX-License-Identifier: MIT
// Drives the production QR/manual parsers, pairing MACs, transcript hash,
// record/audit validator and approval vocabulary with the shared `pairing`
// section plus the C2 invalid row kinds.
package com.phonedsh.pclink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GoldenVectorPairingTest {
    @Test
    fun pairingSection() {
        val vectors = TestSupport.vectors()
        val pairing = TestSupport.at(vectors, "pairing") ?: throw AssertionError("missing pairing")
        val origin = TestSupport.requireString(pairing, "origin")

        val qr = TestSupport.at(pairing, "qr") ?: throw AssertionError("missing qr")
        val parsed = PclinkQrCode.parse(TestSupport.requireString(qr, "uri"))
        val expected = TestSupport.at(qr, "parsed") ?: throw AssertionError("missing parsed QR")
        assertEquals(TestSupport.requireString(expected, "origin"), parsed.relayOrigin)
        assertEquals(TestSupport.requireString(expected, "machineId"), parsed.pcMachineId)
        assertEquals(TestSupport.requireString(expected, "publicKey"), PclinkBase64Url.encode(parsed.pcPublicKey!!))
        assertEquals(TestSupport.requireString(expected, "secret"), PclinkBase64Url.encode(parsed.secret))
        assertEquals(TestSupport.requireString(expected, "name"), parsed.pcName)
        assertEquals(TestSupport.requireString(expected, "ws_url"), parsed.websocketUrl)
        assertEquals(
            TestSupport.requireString(qr, "uri"),
            PclinkQrCode.makeUri(
                relayOrigin = origin,
                pcMachineId = parsed.pcMachineId!!,
                pcPublicKey = parsed.pcPublicKey!!,
                secret = parsed.secret,
                pcName = parsed.pcName!!,
            ),
        )

        val manual = TestSupport.at(pairing, "manual") ?: throw AssertionError("missing manual")
        assertEquals(
            TestSupport.requireString(manual, "normalized"),
            PclinkCrockford.normalize(TestSupport.requireString(manual, "input")),
        )
        for (equivalent in TestSupport.objects(manual, "equivalent_inputs")) {
            assertEquals(
                TestSupport.requireString(manual, "normalized"),
                PclinkCrockford.normalize(equivalent.stringValue!!),
            )
        }
        val manualSecret = PclinkCrockford.decode(TestSupport.requireString(manual, "display"))
        assertEquals(TestSupport.requireString(manual, "secret_hex"), PclinkHex.encode(manualSecret))
        assertEquals(
            TestSupport.requireString(manual, "display"),
            PclinkCrockford.display(PclinkCrockford.encode(manualSecret)),
        )
        assertEquals(
            TestSupport.requireString(manual, "rendezvous"),
            PclinkCrypto.rendezvous(manualSecret, origin),
        )
        assertEquals(
            TestSupport.requireString(manual, "pair_key"),
            PclinkBase64Url.encode(PclinkCrypto.pairKey(manualSecret)),
        )
        assertEquals(
            TestSupport.requireString(manual, "normalized"),
            PclinkCrockford.normalize(PclinkManualCode.display(manualSecret)),
        )

        val secretS = TestSupport.b64(pairing, "secret_s") ?: throw AssertionError("missing secret S")
        assertEquals(TestSupport.requireString(pairing, "rendezvous_s"), PclinkCrypto.rendezvous(secretS, origin))
        assertEquals(
            TestSupport.requireString(pairing, "rendezvous_s_other_origin"),
            PclinkCrypto.rendezvous(secretS, "https://other.example"),
        )
        assertEquals(
            TestSupport.requireString(pairing, "pair_key_s"),
            PclinkBase64Url.encode(PclinkCrypto.pairKey(secretS)),
        )

        for ((keyName, secret) in listOf("s" to secretS, "manual" to manualSecret)) {
            val pairKey = PclinkCrypto.pairKey(secret)
            val source = if (keyName == "s") pairing else manual
            val expectedKey = if (keyName == "s") {
                TestSupport.requireString(pairing, "pair_key_s")
            } else {
                TestSupport.requireString(manual, "pair_key")
            }
            assertEquals(keyName, expectedKey, PclinkBase64Url.encode(pairKey))
            val hello = PclinkPairingMessage.decode(TestSupport.at(source, "hello")!!)
            val auth = PclinkPairingMessage.decode(TestSupport.at(source, "auth")!!)
            val confirm = PclinkPairingMessage.decode(TestSupport.at(source, "confirm")!!)
            val final = PclinkPairingMessage.decode(TestSupport.at(source, "final")!!)
            for (message in listOf(hello, auth, confirm, final)) {
                message.verifyMac(pairKey)
                assertEquals(message.type, message.raw.requiredString("type"))
            }
            val helloMessage = hello as PclinkPairingMessage.Hello
            val authMessage = auth as PclinkPairingMessage.Auth
            assertArrayEquals(helloMessage.nonce, authMessage.peerNonce)
            assertEquals(
                TestSupport.requireString(source, "transcript_hash"),
                PclinkBase64Url.encode(PclinkPairingTranscript.hash(helloMessage, authMessage)),
            )
            assertEquals(
                TestSupport.requireString(source, "transcript_hash"),
                PclinkBase64Url.encode(confirm.let { (it as PclinkPairingMessage.Confirm).transcriptHash }),
            )
            // The QR-parsed offer pins exactly the key/machineId carried by the
            // MACed hello and the manual offer derives them from the same bytes.
            val offer = if (keyName == "s") {
                PclinkPairingOffer(
                    PclinkPairingMode.QR,
                    origin,
                    secret,
                    pcMachineId = helloMessage.machineId,
                    pcPublicKey = helloMessage.publicKey,
                    pcName = helloMessage.name,
                )
            } else {
                PclinkPairingOffer(PclinkPairingMode.MANUAL, origin, secret)
            }
            offer.verifyHello(helloMessage)
        }

        val records = TestSupport.at(pairing, "records") ?: throw AssertionError("missing records")
        val phoneRecord = PclinkPairingRecord.fromJson(TestSupport.at(records, "phone")!!)
        assertEquals("My PC", phoneRecord.peerName)
        assertEquals(origin, phoneRecord.relayOrigin)
        assertEquals(PclinkPairingMode.QR, phoneRecord.pairingMode)
        PclinkPairingRecord.validatePcRecordJson(TestSupport.at(records, "pc")!!)

        val audit = TestSupport.at(pairing, "audit") ?: throw AssertionError("missing audit")
        val usable = TestSupport.at(audit, "approved_usable")!!
        assertEquals(
            PclinkRecordUsability.USABLE,
            PclinkRecordAudit.evaluate(
                TestSupport.at(usable, "record")!!,
                TestSupport.objects(usable, "audit"),
            ),
        )
        assertEquals(
            TestSupport.requireString(audit, "record_sha256"),
            PclinkHex.encode(
                PclinkCrypto.sha256(
                    PclinkJsonEncoder.canonical(TestSupport.at(usable, "record")!!),
                ),
            ),
        )

        val approval = TestSupport.at(pairing, "approval") ?: throw AssertionError("missing approval")
        val phoneMachineId = TestSupport.requireString(approval, "peerMachineId")
        assertEquals(TestSupport.requireString(approval, "fingerprint"), PclinkValidation.fingerprint(phoneMachineId))
        for (input in TestSupport.objects(approval, "accepted_inputs")) {
            assertTrue(input.stringValue, PclinkValidation.fingerprintMatches(input.stringValue!!, phoneMachineId))
        }
        assertFalse(
            PclinkValidation.fingerprintMatches(
                TestSupport.requireString(approval, "rejected_input"),
                phoneMachineId,
            ),
        )
        assertEquals(
            TestSupport.requireString(approval, "pcFingerprint"),
            PclinkValidation.fingerprint(TestSupport.requireString(expected, "machineId")),
        )
        for (mode in listOf("qr", "manual")) {
            assertEquals(
                "confirm_sent",
                PclinkApproval.decide(mode, approved = true),
            )
        }
        assertEquals("confirm_sent", PclinkApproval.decide("qr", approved = true))
        assertEquals("bad_frame", runCatching { PclinkApproval.decide("future", true) }
            .exceptionOrNull()?.let { (it as PclinkError).code })
    }


    @Test
    fun schemaSamplesRelevantToC2() {
        val samples = TestSupport.schemaSamples()
        val relevant = setOf(
            "pairing-record.schema.json",
            "phone-pairing-record.schema.json",
            "pairing-message.schema.json",
            "e2e-handshake.schema.json",
        )
        var validSeen = 0
        for (sample in TestSupport.objects(samples, "valid")) {
            val schema = sample.requiredString("schema")
            if (schema !in relevant) continue
            validSeen++
            val value = TestSupport.at(sample, "value") ?: throw AssertionError("missing sample value")
            when (schema) {
                "pairing-message.schema.json" -> PclinkPairingMessage.decode(value)
                "pairing-record.schema.json" -> PclinkPairingRecord.validatePcRecordJson(value)
                "phone-pairing-record.schema.json" -> PclinkPairingRecord.validatePhoneRecordJson(value)
                "e2e-handshake.schema.json" -> PclinkWire.validateE2EHandshake(value)
            }
        }
        assertEquals(6, validSeen)

        var invalidSeen = 0
        for (sample in TestSupport.objects(samples, "invalid")) {
            val schema = sample.requiredString("schema")
            if (schema !in relevant) continue
            invalidSeen++
            val value = TestSupport.at(sample, "value") ?: throw AssertionError("missing sample value")
            assertPclinkCode("bad_frame", "$schema/${sample.requiredString("name")}") {
                when (schema) {
                    "pairing-message.schema.json" -> PclinkPairingMessage.decode(value)
                    "pairing-record.schema.json" -> PclinkPairingRecord.validatePcRecordJson(value)
                    "phone-pairing-record.schema.json" -> PclinkPairingRecord.validatePhoneRecordJson(value)
                    "e2e-handshake.schema.json" -> PclinkWire.validateE2EHandshake(value)
                }
            }
        }
        assertEquals(9, invalidSeen)
    }

    @Test
    fun pairingNegatives() {
        val vectors = TestSupport.vectors()
        val invalid = TestSupport.objects(vectors, "invalid")
        val covered = setOf("qr", "manual", "pair_mac")
        val seen = HashSet<String>()
        for (row in invalid) {
            val kind = TestSupport.requireString(row, "kind")
            if (kind !in covered) continue
            seen.add(kind)
            val name = TestSupport.requireString(row, "case")
            val expected = TestSupport.requireString(row, "expected")
            when (kind) {
                "qr" -> when (name) {
                    "qr-key-swap" -> {
                        val offer = PclinkQrCode.parse(TestSupport.requireString(row, "uri"))
                        assertNotEquals(
                            TestSupport.requireString(row, "expected_public_key"),
                            PclinkBase64Url.encode(offer.pcPublicKey!!),
                        )
                        assertEquals("auth_failed", expected)
                    }
                    "qr-machineid-mismatch" -> {
                        assertPclinkCode("auth_failed", name) {
                            PclinkQrCode.parse(TestSupport.requireString(row, "uri"))
                        }
                        assertEquals("auth_failed", expected)
                    }
                    else -> {
                        assertPclinkCode("bad_frame", name) {
                            PclinkQrCode.parse(TestSupport.requireString(row, "uri"))
                        }
                        assertEquals("bad_frame", expected)
                    }
                }
                "manual" -> {
                    assertPclinkCode("bad_frame", name) {
                        PclinkCrockford.decode(TestSupport.requireString(row, "input"))
                    }
                    assertEquals("bad_frame", expected)
                }
                "pair_mac" -> {
                    val pairKey = TestSupport.b64(row, "pair_key_b64")
                        ?: throw AssertionError("$name pair key")
                    val domain = TestSupport.requireString(row, "domain")
                    val objectValue = TestSupport.at(row, "object") ?: throw AssertionError("$name object")
                    val message = PclinkPairingMessage.decode(objectValue)
                    assertEquals(domain, message.domain())
                    assertPclinkCode("auth_failed", name) {
                        message.verifyMac(pairKey)
                    }
                    assertEquals("auth_failed", expected)
                }
            }
        }
        assertEquals(covered, seen)
    }
}
