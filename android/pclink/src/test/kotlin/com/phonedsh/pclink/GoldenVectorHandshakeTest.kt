// SPDX-License-Identifier: MIT
// Drives the production PclinkE2eSession with the shared `handshake` section and
// every C2 invalid row kind that is cryptographic or session-state evidence.
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GoldenVectorHandshakeTest {
    @Test
    fun handshakeSection() {
        val vectors = TestSupport.vectors()
        val handshake = TestSupport.at(vectors, "handshake")
            ?: throw AssertionError("missing handshake")
        val phone = C2TestSupport.phoneIdentity()
        val pc = C2TestSupport.pcIdentity()
        assertEquals(TestSupport.requireString(handshake, "from"), phone.machineId)
        assertEquals(TestSupport.requireString(handshake, "to"), pc.machineId)
        assertEquals(TestSupport.requireString(handshake, "version"), PclinkCrypto.PROTOCOL_VERSION)
        assertEquals(TestSupport.requireString(handshake, "suite"), PclinkCrypto.SUITE)

        val sid = TestSupport.b64(handshake, "sid") ?: throw AssertionError("missing sid")
        val phoneEphSeed = TestSupport.seed(
            TestSupport.requireString(handshake, "phone_eph", "seed_label"),
        )
        assertEquals(
            TestSupport.requireString(handshake, "phone_eph", "public_key"),
            PclinkBase64Url.encode(PclinkCrypto.x25519PublicKey(phoneEphSeed)),
        )
        val phoneNonce = TestSupport.b64(handshake, "phone_nonce")
            ?: throw AssertionError("missing phone nonce")
        val session = PclinkE2eSession(
            identity = phone,
            peer = C2TestSupport.peerRecord(),
            sidBytes = sid,
            ephemeral = PclinkCrypto.EphemeralKey(
                phoneEphSeed,
                PclinkCrypto.x25519PublicKey(phoneEphSeed),
            ),
            phoneNonce = phoneNonce,
        )
        assertEquals(TestSupport.at(handshake, "init"), session.initBody)
        PclinkWire.validateE2EHandshake(session.initFrame)
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "init_hex"),
            PclinkHex.encode(
                PclinkCrypto.sessionInitTranscript(
                    phone.machineId,
                    pc.machineId,
                    sid,
                    session.ephemeralPublicKey,
                    phoneNonce,
                ),
            ),
        )
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "th1_hex"),
            PclinkHex.encode(session.th1),
        )

        val resp = TestSupport.at(handshake, "resp") ?: throw AssertionError("missing resp")
        val respOuter = C2TestSupport.goldenRespOuter()
        PclinkWire.validateE2EHandshake(respOuter)
        session.acceptResp(respOuter)
        assertEquals(PclinkSessionPhase.AWAITING_HELLO, session.phase)

        val pcEphPublic = TestSupport.b64(handshake, "pc_eph", "public_key")
            ?: throw AssertionError("missing pc eph")
        val pcEphSeed = TestSupport.seed(
            TestSupport.requireString(handshake, "pc_eph", "seed_label"),
        )
        assertEquals(
            TestSupport.requireString(handshake, "dh_hex"),
            PclinkHex.encode(PclinkCrypto.x25519SharedSecret(phoneEphSeed, pcEphPublic)),
        )
        val th2 = session.th2 ?: throw AssertionError("missing th2")
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "resp_hex"),
            PclinkHex.encode(
                PclinkCrypto.sessionRespTranscript(
                    session.th1,
                    PclinkBase64Url.decode(resp.requiredString("eph"), 32),
                    PclinkBase64Url.decode(resp.requiredString("nonce"), 32),
                ),
            ),
        )
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "th2_hex"),
            PclinkHex.encode(th2),
        )
        val keys = session.keys ?: throw AssertionError("missing keys")
        assertEquals(TestSupport.requireString(handshake, "keys", "phone_to_pc"), PclinkBase64Url.encode(keys.phoneToPC))
        assertEquals(TestSupport.requireString(handshake, "keys", "pc_to_phone"), PclinkBase64Url.encode(keys.pcToPhone))
        assertEquals(TestSupport.requireString(handshake, "keys", "confirm_phone"), PclinkBase64Url.encode(keys.confirmPhone))
        assertEquals(TestSupport.requireString(handshake, "keys", "confirm_pc"), PclinkBase64Url.encode(keys.confirmPC))
        assertEquals(
            TestSupport.requireString(handshake, "confirmations", "pc"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPC, th2)),
        )

        val confirmFrame = session.confirmFrame()
        val confirmBody = confirmFrame["body"] ?: throw AssertionError("missing confirm body")
        assertEquals(TestSupport.at(handshake, "confirm"), confirmBody)
        val th3 = session.th3 ?: throw AssertionError("missing th3")
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "confirm_hex"),
            PclinkHex.encode(
                PclinkCrypto.sessionConfirmTranscript(th2, phone.machineId, pc.machineId, sid),
            ),
        )
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "th3_hex"),
            PclinkHex.encode(th3),
        )
        assertEquals(
            TestSupport.requireString(handshake, "confirmations", "phone"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPhone, th3)),
        )

        val reject = TestSupport.at(handshake, "reject") ?: throw AssertionError("missing reject")
        val verification = session.verifyReject(reject)
        assertTrue("golden reject verifies", verification is PclinkRejectVerification.Verified)
        assertEquals("unpaired", (verification as PclinkRejectVerification.Verified).code)
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "reject_hex"),
            PclinkHex.encode(
                PclinkCrypto.sessionRejectTranscript(
                    session.th1,
                    reject.requiredString("code"),
                ),
            ),
        )
        val pcPublicKey = TestSupport.b64(vectors, "identities", "pc", "public_key")
            ?: throw AssertionError("missing pc public key")
        assertTrue(
            "golden reject signature",
            PclinkE2eSession.verifyRejectSignature(
                TestSupport.b64(reject, "sig")!!,
                reject.requiredString("code"),
                session.th1,
                pcPublicKey,
            ),
        )
        assertFalse(
            "reject is bound to th1",
            PclinkE2eSession.verifyRejectSignature(
                TestSupport.b64(reject, "sig")!!,
                reject.requiredString("code"),
                ByteArray(32),
                pcPublicKey,
            ),
        )
        assertFalse(
            "reject is bound to the code",
            PclinkE2eSession.verifyRejectSignature(
                TestSupport.b64(reject, "sig")!!,
                "auth_failed",
                session.th1,
                pcPublicKey,
            ),
        )
    }

    @Test
    fun handshakeNegatives() {
        val vectors = TestSupport.vectors()
        val invalid = TestSupport.objects(vectors, "invalid")
        val pcPublicKey = TestSupport.b64(vectors, "identities", "pc", "public_key")
            ?: throw AssertionError("missing pc public key")
        val phonePublicKey = TestSupport.b64(vectors, "identities", "phone", "public_key")
            ?: throw AssertionError("missing phone public key")
        val covered = setOf(
            "handshake_signature", "handshake_transcript", "sid_mismatch", "cross_sid",
            "x25519", "pairing_lookup", "reject", "reject_transcript", "record",
            "approval", "seq", "aead", "first_frame",
        )
        val seen = HashSet<String>()
        for (row in invalid) {
            val kind = TestSupport.requireString(row, "kind")
            if (kind !in covered) continue
            seen.add(kind)
            val name = TestSupport.requireString(row, "case")
            val expected = TestSupport.requireString(row, "expected")
            when (kind) {
                "handshake_signature" -> {
                    val transcript = TestSupport.hex(TestSupport.requireString(row, "transcript_hex"))
                    val publicKey = TestSupport.b64(row, "public_key")
                        ?: throw AssertionError("$name publicKey")
                    val signature = TestSupport.b64(row, "signature")
                        ?: throw AssertionError("$name signature")
                    assertFalse(name, PclinkCrypto.ed25519Verify(publicKey, transcript, signature))
                    assertEquals("auth_failed", expected)
                }
                "handshake_transcript" -> {
                    val init = TestSupport.at(row, "init") ?: throw AssertionError("$name init")
                    val transcript = flexibleInitTranscript(
                        version = TestSupport.requireInt(init, "v"),
                        suite = TestSupport.requireString(init, "suite"),
                        from = TestSupport.requireString(row, "from"),
                        to = TestSupport.requireString(row, "to"),
                        sid = TestSupport.b64(init, "sid")!!,
                        eph = TestSupport.b64(init, "eph")!!,
                        nonce = TestSupport.b64(init, "nonce")!!,
                    )
                    assertNotEquals(
                        name,
                        TestSupport.requireString(row, "reference_hex"),
                        PclinkHex.encode(PclinkCrypto.sha256(transcript)),
                    )
                    assertEquals("auth_failed", expected)
                }
                "sid_mismatch" -> {
                    val outer = TestSupport.requireString(row, "outer_sid")
                    val body = TestSupport.requireString(row, "body_sid")
                    assertPclinkCode("bad_frame", name) {
                        PclinkHandshakeSid.requireMatch("ignored", outer, body)
                    }
                    assertEquals("bad_frame", expected)
                }
                "cross_sid" -> {
                    val expectedSid = TestSupport.requireString(row, "expected_sid")
                    val messageSid = TestSupport.requireString(row, "message_sid")
                    assertPclinkCode("replay", name) {
                        PclinkHandshakeSid.requireMatch(expectedSid, messageSid, messageSid)
                    }
                    assertEquals("replay", expected)
                }
                "x25519" -> {
                    val privateKey = TestSupport.seed(TestSupport.requireString(row, "private_label"))
                    val publicKey = TestSupport.b64(row, "public_key")
                        ?: throw AssertionError("$name public_key")
                    assertPclinkCode("auth_failed", name) {
                        PclinkCrypto.x25519SharedSecret(privateKey, publicKey)
                    }
                    assertEquals("auth_failed", expected)
                }
                "pairing_lookup" -> {
                    val from = TestSupport.requireString(row, "from")
                    val paired = TestSupport.objects(row, "paired_machine_ids")
                        .mapNotNull { it.stringValue }
                    val phone = C2TestSupport.phoneIdentity()
                    val records = if (paired.contains(phone.machineId)) {
                        listOf(
                            PclinkPairingRecord(
                                peerMachineId = phone.machineId,
                                peerPublicKey = phone.publicKey,
                                peerName = "iPhone",
                                pairedAt = "2026-11-09T00:00:00Z",
                                relayOrigin = "https://relay.example",
                            ),
                        )
                    } else {
                        emptyList()
                    }
                    assertEquals(
                        name,
                        PclinkPairingLookupResult.UNPAIRED,
                        PclinkPairingLookup.decide(records, from),
                    )
                    assertFalse(name, TestSupport.requireBool(row, "records_sid"))
                    assertEquals("unpaired", expected)
                }
                "reject" -> {
                    val verified = TestSupport.requireBool(row, "verified")
                    val code = TestSupport.requireString(row, "code")
                    val th1Matches = TestSupport.requireBool(row, "th1_matches")
                    val hasRecord = TestSupport.requireBool(row, "has_record")
                    val decision = PclinkRejectPolicy.decide(verified, code, th1Matches, hasRecord)
                    val text = if (decision == PclinkRejectHandling.PROMPT) "prompt" else "keep_record"
                    assertEquals(name, expected, text)
                }
                "reject_transcript" -> {
                    val signature = TestSupport.b64(row, "signature")
                        ?: throw AssertionError("$name signature")
                    val signedTh1 = TestSupport.hex(TestSupport.requireString(row, "signed_th1_hex"))
                    val verifiedTh1 = TestSupport.hex(TestSupport.requireString(row, "verified_th1_hex"))
                    val signedCode = TestSupport.requireString(row, "signed_code")
                    val verifiedCode = TestSupport.requireString(row, "verified_code")
                    val publicKey = TestSupport.b64(row, "public_key")
                        ?: throw AssertionError("$name public_key")
                    assertTrue(
                        name,
                        PclinkE2eSession.verifyRejectSignature(signature, signedCode, signedTh1, publicKey),
                    )
                    assertFalse(
                        name,
                        PclinkE2eSession.verifyRejectSignature(signature, verifiedCode, verifiedTh1, publicKey),
                    )
                    assertEquals("auth_failed", expected)
                }
                "record" -> {
                    val record = TestSupport.at(row, "record") ?: throw AssertionError("$name record")
                    val audit = TestSupport.objects(row, "audit")
                    assertEquals(name, expected, PclinkRecordAudit.evaluate(record, audit).wire())
                }
                "approval" -> {
                    val mode = TestSupport.requireString(row, "mode")
                    val approved = TestSupport.requireBool(row, "approved")
                    assertEquals(name, expected, PclinkApproval.decide(mode, approved))
                }
                "seq" -> {
                    val decision = PclinkSeqValidator.evaluate(
                        first = TestSupport.requireBool(row, "first"),
                        lastSeq = TestSupport.long(row, "last_seq"),
                        seq = TestSupport.requireInt(row, "seq"),
                        bytes = TestSupport.long(row, "bytes") ?: 0L,
                    )
                    assertEquals(name, expected, decision.wire())
                }
                "aead" -> {
                    // The crypto row is also exercised by C1; here assert the
                    // frozen failure classification on the real AEAD opener.
                    assertEquals("auth_failed", expected)
                    // A mutated outer `v` is rejected by the closed-shape
                    // validator, not by AEAD (v is not in the AAD).
                    if (row["v"] == null) {
                        val keys = C2TestSupport.goldenKeys()
                        val frame = TestSupport.at(row, "frame") ?: throw AssertionError("$name frame")
                        val direction = TestSupport.requireString(row, "direction")
                        val key = TestSupport.b64(row, "key_b64")
                            ?: when (TestSupport.string(row, "key_direction")) {
                                "pc_to_phone" -> keys.pcToPhone
                                "phone_to_pc" -> keys.phoneToPC
                                else -> if (direction == "phone_to_pc") keys.pcToPhone else keys.phoneToPC
                            }
                        val sid = TestSupport.requireString(frame, "sid")
                        val seq = TestSupport.requireInt(frame, "seq")
                        val from = TestSupport.requireString(frame, "from")
                        val to = TestSupport.requireString(frame, "to")
                        val body = TestSupport.b64(frame, "body")!!
                        assertPclinkCode("auth_failed", name) {
                            PclinkCrypto.aeadOpen(
                                body,
                                key,
                                PclinkCrypto.aeadNonce(seq),
                                PclinkCrypto.aad(sid, seq, from, to),
                            )
                        }
                    } else {
                        // `v` is not AAD; the frame-shape gate owns this negative
                        // (asserted by C1's GoldenVectorCryptoTest).
                        assertEquals(2L, TestSupport.requireInt(row, "v"))
                    }
                }
                "first_frame" -> {
                    assertNotEquals(name, "peer.hello", TestSupport.requireString(row, "type"))
                    val session = C2TestSupport.goldenSession()
                    assertPclinkCode("bad_frame", name) {
                        session.acceptFirstInner(
                            pclinkObject(
                                "type" to PclinkJson.Text(TestSupport.requireString(row, "type")),
                            ),
                        )
                    }
                    assertEquals("bad_frame", expected)
                }
            }
        }
        assertEquals(covered, seen)
    }

    private fun flexibleInitTranscript(
        version: Long,
        suite: String,
        from: String,
        to: String,
        sid: ByteArray,
        eph: ByteArray,
        nonce: ByteArray,
    ): ByteArray = ByteArray(0)
        .plus("pclink-v1/session-init".toByteArray(Charsets.UTF_8))
        .plus(0)
        .plus(version.toString().toByteArray(Charsets.UTF_8))
        .plus(0)
        .plus(suite.toByteArray(Charsets.UTF_8))
        .plus(0)
        .plus(from.toByteArray(Charsets.UTF_8))
        .plus(0)
        .plus(to.toByteArray(Charsets.UTF_8))
        .plus(0)
        .plus(sid)
        .plus(0)
        .plus(eph)
        .plus(0)
        .plus(nonce)
}

private fun PclinkSeqDecision.wire(): String = when (this) {
    PclinkSeqDecision.ACCEPT -> "accept"
    PclinkSeqDecision.REPLAY -> "replay"
    PclinkSeqDecision.BAD_FRAME -> "bad_frame"
    PclinkSeqDecision.SESSION_EXPIRED -> "session_expired"
}

private fun PclinkRecordUsability.wire(): String = when (this) {
    PclinkRecordUsability.USABLE -> "usable"
    PclinkRecordUsability.UNAPPROVED -> "unapproved"
    PclinkRecordUsability.REVOKED -> "revoked"
    PclinkRecordUsability.STALE -> "stale"
    PclinkRecordUsability.UNSUPPORTED -> "unsupported"
}
