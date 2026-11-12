// SPDX-License-Identifier: MIT
// Drives the production PclinkCrypto/PclinkEncoding/canonical encoder with the
// shared golden document read from disk (identities, relay_auth, canonical_json,
// frames and every C1 invalid row).
package com.phonedsh.pclink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GoldenVectorCryptoTest {
    private fun isCanonicalMismatch(candidate: String): Boolean {
        val parsed = try {
            PclinkJsonParser.parse(candidate)
        } catch (_: PclinkError) {
            return true
        }
        return PclinkJsonEncoder.canonicalString(parsed) != candidate
    }

    @Test
    fun metaAndIdentities() {
        val vectors = TestSupport.vectors()
        assertEquals("pclink-v1-vectors", TestSupport.requireString(vectors, "format"))
        assertEquals(3L, TestSupport.requireInt(vectors, "format_version"))
        assertEquals("pclink-v1.6", TestSupport.requireString(vectors, "revision"))
        assertEquals(PclinkCrypto.SUITE, TestSupport.requireString(vectors, "suite"))

        var seen = 0
        for (name in listOf("phone", "pc")) {
            val entry = TestSupport.at(vectors, "identities", name)
                ?: throw AssertionError("missing identity $name")
            val identity = TestSupport.identity(TestSupport.requireString(entry, "seed_label"))
            assertEquals("$name public key", TestSupport.requireString(entry, "public_key"),
                PclinkBase64Url.encode(identity.publicKey))
            assertEquals("$name machineId", TestSupport.requireString(entry, "machine_id"),
                identity.machineId)
            assertEquals("$name sha256", TestSupport.requireString(entry, "sha256_hex"),
                PclinkHex.encode(PclinkCrypto.sha256(identity.publicKey)))
            assertEquals("$name public key text length", 43,
                PclinkBase64Url.encode(identity.publicKey).length)
            assertEquals(
                "$name fingerprint",
                identity.machineId.take(12).chunked(4).joinToString("-"),
                identity.fingerprint,
            )
            seen++
        }
        assertEquals(2, seen)
    }

    @Test
    fun relayAuthTranscriptsAndSignatures() {
        val vectors = TestSupport.vectors()
        val auth = TestSupport.at(vectors, "relay_auth")
            ?: throw AssertionError("missing relay_auth")
        val origin = TestSupport.requireString(auth, "origin")
        val nonce = TestSupport.b64(auth, "nonce") ?: throw AssertionError("missing nonce")
        assertEquals(32, nonce.size)

        val transcript = PclinkCrypto.relayAuthTranscript(origin, nonce)
        assertEquals(TestSupport.requireString(auth, "transcript_hex"),
            PclinkHex.encode(transcript))

        for (name in listOf("phone", "pc")) {
            val entry = TestSupport.at(auth, name) ?: throw AssertionError("missing $name auth")
            val identity = TestSupport.identity("pclink-v1/test/identity/$name")
            val publicKey = TestSupport.b64(entry, "public_key")
                ?: throw AssertionError("missing $name publicKey")
            val signature = TestSupport.b64(entry, "signature")
                ?: throw AssertionError("missing $name signature")
            assertEquals(PclinkBase64Url.encode(publicKey), TestSupport.requireString(entry, "public_key"))
            assertTrue("$name golden signature", PclinkCrypto.ed25519Verify(
                publicKey, transcript, signature))
            assertTrue("$name own signature", PclinkCrypto.ed25519Verify(
                publicKey, transcript, identity.sign(transcript)))
            assertEquals("$name machineId", TestSupport.requireString(entry, "machine_id"),
                identity.machineId)
            assertTrue("$name role", TestSupport.requireString(entry, "role") in setOf("phone", "pc"))
        }
    }

    @Test
    fun canonicalJsonSection() {
        val vectors = TestSupport.vectors()
        var seen = 0
        for (name in listOf("scalar_order", "slash_and_nonascii", "nul_escape")) {
            val entry = TestSupport.at(vectors, "canonical_json", name)
                ?: throw AssertionError("missing canonical_json.$name")
            val value = TestSupport.at(entry, "object")
                ?: throw AssertionError("missing canonical_json.$name.object")
            val canonical = PclinkJsonEncoder.canonicalString(value)
            val expected = TestSupport.requireString(entry, "canonical")
            // Compare bytes: Kotlin String equality would hide a normalization
            // difference in the expected text.
            assertTrue("$name canonical bytes",
                canonical.toByteArray(Charsets.UTF_8).contentEquals(expected.toByteArray(Charsets.UTF_8)))
            assertEquals("$name sha256", TestSupport.requireString(entry, "sha256_hex"),
                PclinkHex.encode(PclinkCrypto.sha256(canonical.toByteArray(Charsets.UTF_8))))
            assertEquals("$name round-trip", value, PclinkJsonParser.parse(canonical))
            seen++
        }
        assertEquals(3, seen)

        val nulEscape = TestSupport.at(vectors, "canonical_json", "nul_escape")
            ?: throw AssertionError("missing nul_escape")
        val canonical = TestSupport.requireString(nulEscape, "canonical")
        assertTrue("U+0000 uses the six-character escape", canonical.contains("\\u0000"))
        val reparsed = PclinkJsonParser.parseObject(canonical)
        assertEquals("key", reparsed["a\u0000b"]?.stringValue)

        val canonicalRows = TestSupport.objects(vectors, "invalid")
            .filter { TestSupport.string(it, "kind") == "canonical" }
        assertEquals(4, canonicalRows.size)
        for (row in canonicalRows) {
            val case = TestSupport.requireString(row, "case")
            val candidate = TestSupport.requireString(row, "candidate")
            assertTrue("$case must not be canonical", isCanonicalMismatch(candidate))
            assertEquals("bad_frame", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun aeadFrames() {
        val vectors = TestSupport.vectors()
        val handshake = TestSupport.at(vectors, "handshake")
            ?: throw AssertionError("missing handshake")
        val keys = PclinkCrypto.SessionKeys(
            phoneToPC = TestSupport.b64(handshake, "keys", "phone_to_pc")!!,
            pcToPhone = TestSupport.b64(handshake, "keys", "pc_to_phone")!!,
            confirmPhone = TestSupport.b64(handshake, "keys", "confirm_phone")!!,
            confirmPC = TestSupport.b64(handshake, "keys", "confirm_pc")!!,
        )
        val frames = TestSupport.objects(vectors, "frames")
        assertEquals(9, frames.size)
        for (frame in frames) {
            val case = TestSupport.requireString(frame, "case")
            val direction = TestSupport.requireString(frame, "direction")
            val key = if (direction == "phone_to_pc") keys.phoneToPC else keys.pcToPhone
            val sid = TestSupport.requireString(frame, "sid")
            val seq = TestSupport.requireInt(frame, "seq")
            val from = TestSupport.requireString(frame, "from")
            val to = TestSupport.requireString(frame, "to")
            val nonce = PclinkCrypto.aeadNonce(seq)
            val aad = PclinkCrypto.aad(sid, seq, from, to)
            assertEquals("$case aad", TestSupport.requireString(frame, "aad_hex"),
                PclinkHex.encode(aad))
            assertEquals("$case nonce", TestSupport.requireString(frame, "nonce_hex"),
                PclinkHex.encode(nonce))
            val body = TestSupport.b64(frame, "body") ?: throw AssertionError("$case body")
            val plaintext = TestSupport.requireString(frame, "plaintext")
                .toByteArray(Charsets.UTF_8)
            assertArrayEquals("$case open", plaintext,
                PclinkCrypto.aeadOpen(body, key, nonce, aad))
            assertTrue("$case seal",
                PclinkCrypto.aeadSeal(plaintext, key, nonce, aad).contentEquals(body))
            val inner = PclinkJsonParser.parseObject(plaintext)
            assertEquals("$case inner type", TestSupport.requireString(frame, "inner_type"),
                inner.requiredString("type"))
            // The outer frame is a closed shape; the same production validator
            // the receive path uses must accept every golden frame.
            PclinkWire.validateE2EFrame(outerFrame(frame))
        }
    }

    @Test
    fun aeadNegatives() {
        val vectors = TestSupport.vectors()
        val handshake = TestSupport.at(vectors, "handshake")
            ?: throw AssertionError("missing handshake")
        val keys = PclinkCrypto.SessionKeys(
            phoneToPC = TestSupport.b64(handshake, "keys", "phone_to_pc")!!,
            pcToPhone = TestSupport.b64(handshake, "keys", "pc_to_phone")!!,
            confirmPhone = TestSupport.b64(handshake, "keys", "confirm_phone")!!,
            confirmPC = TestSupport.b64(handshake, "keys", "confirm_pc")!!,
        )
        val rows = TestSupport.objects(vectors, "invalid")
            .filter { TestSupport.string(it, "kind") == "aead" }
        assertEquals(5, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val frame = TestSupport.at(row, "frame") ?: throw AssertionError("$case frame")
            if (TestSupport.long(frame, "v") != null) {
                // `v` is not part of the AAD; the closed outer validator rejects
                // a mutated version before AEAD open.
                assertPclinkCode("bad_frame", case) { PclinkWire.validateE2EFrame(outerFrame(frame)) }
                continue
            }
            val direction = TestSupport.requireString(frame, "direction")
            var key = if (direction == "phone_to_pc") keys.phoneToPC else keys.pcToPhone
            TestSupport.string(row, "key_direction")?.let { keyDirection ->
                key = if (keyDirection == "phone_to_pc") keys.phoneToPC else keys.pcToPhone
            }
            TestSupport.b64(row, "key_b64")?.let { key = it }
            val sid = TestSupport.requireString(frame, "sid")
            val seq = TestSupport.requireInt(frame, "seq")
            val from = TestSupport.requireString(frame, "from")
            val to = TestSupport.requireString(frame, "to")
            val aad = PclinkCrypto.aad(sid, seq, from, to)
            val body = TestSupport.b64(frame, "body") ?: throw AssertionError("$case body")
            assertPclinkCode("auth_failed", case) {
                PclinkCrypto.aeadOpen(body, key, PclinkCrypto.aeadNonce(seq), aad)
            }
        }
    }

    @Test
    fun x25519Negatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "x25519" }
        assertEquals(2, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val seed = TestSupport.seed(TestSupport.requireString(row, "private_label"))
            val publicKey = TestSupport.b64(row, "public_key")
                ?: throw AssertionError("$case public key")
            assertPclinkCode("auth_failed", case) {
                PclinkCrypto.x25519SharedSecret(seed, publicKey)
            }
        }
    }

    @Test
    fun handshakeSignatureNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "handshake_signature" }
        assertEquals(3, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val transcript = TestSupport.hex(TestSupport.requireString(row, "transcript_hex"))
            val publicKey = TestSupport.b64(row, "public_key")
                ?: throw AssertionError("$case public key")
            val signature = TestSupport.b64(row, "signature")
                ?: throw AssertionError("$case signature")
            assertFalse(case, PclinkCrypto.ed25519Verify(publicKey, transcript, signature))
            assertEquals("auth_failed", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun handshakeTranscriptNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "handshake_transcript" }
        assertEquals(3, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val transcript = flexibleInitTranscript(row)
            assertNotEquals(case, TestSupport.requireString(row, "reference_hex"),
                PclinkHex.encode(PclinkCrypto.sha256(transcript)))
            assertEquals("auth_failed", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun encodingNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "encoding" }
        assertEquals(2, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            assertPclinkCode("bad_frame", case) {
                PclinkBase64Url.decode(TestSupport.requireString(row, "text"))
            }
            assertEquals("bad_frame", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun nameNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "name" }
        assertEquals(4, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            assertPclinkCode("bad_frame", case) {
                PclinkValidation.name(TestSupport.requireString(row, "name"))
            }
            assertEquals("bad_frame", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun originNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "origin" }
        assertEquals(2, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val actual = TestSupport.requireString(row, "actual")
            val expectedOrigin = TestSupport.requireString(row, "expected_origin")
            assertNotEquals(case, expectedOrigin, actual)
            // The client accepts a challenge only when the received origin is a
            // valid origin AND equal to the origin it dialed/paired with.
            val accepted = try {
                PclinkValidation.origin(actual)
                actual == expectedOrigin
            } catch (_: PclinkError) {
                false
            }
            assertFalse(case, accepted)
            assertEquals("auth_failed", TestSupport.requireString(row, "expected"))
        }
    }

    @Test
    fun frameNegative() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "frame" }
        assertEquals(1, rows.size)
        val row = rows.single()
        val frame = TestSupport.at(row, "frame") ?: throw AssertionError("frame row")
        assertPclinkCode("bad_frame") { PclinkWire.validateE2EFrame(outerFrame(frame)) }
        assertEquals("bad_frame", TestSupport.requireString(row, "expected"))
    }

    @Test
    fun suiteAndCapsNegatives() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
        val suite = rows.single { TestSupport.string(it, "kind") == "suite" }
        assertNotEquals(PclinkCrypto.SUITE, TestSupport.requireString(suite, "suite"))
        assertPclinkCode("version_unsupported") {
            PclinkWire.requireSupportedSuite(TestSupport.requireString(suite, "suite"))
        }
        assertEquals("version_unsupported", TestSupport.requireString(suite, "expected"))

        val capsRow = rows.single { TestSupport.string(it, "kind") == "caps" }
        val caps = TestSupport.objects(capsRow, "caps").mapNotNull { it.stringValue }.toSet()
        val required = TestSupport.objects(capsRow, "required").mapNotNull { it.stringValue }.toSet()
        assertFalse("caps must not intersect", caps.containsAll(required))
        assertPclinkCode("version_unsupported") { PclinkWire.requirePeerHelloCaps(caps) }
        assertEquals("version_unsupported", TestSupport.requireString(capsRow, "expected"))
    }

    @Test
    fun fingerprintNegative() {
        val rows = TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == "fingerprint" }
        assertEquals(1, rows.size)
        val row = rows.single()
        val publicKey = TestSupport.b64(row, "public_key")
            ?: throw AssertionError("fingerprint public key")
        val machineId = PclinkBase32.machineId(publicKey)
        assertTrue(PclinkValidation.isMachineId(machineId))
        assertFalse(
            PclinkValidation.fingerprintMatches(
                TestSupport.requireString(row, "entered"),
                machineId,
            ),
        )
        assertEquals("blocked", TestSupport.requireString(row, "expected"))
    }

    @Test
    fun handshakeCryptoPrimitives() {
        val vectors = TestSupport.vectors()
        val handshake = TestSupport.at(vectors, "handshake")
            ?: throw AssertionError("missing handshake")
        val phone = TestSupport.identity("pclink-v1/test/identity/phone")
        val pc = TestSupport.identity("pclink-v1/test/identity/pc")
        val phoneEphSeed = TestSupport.seed(
            TestSupport.requireString(handshake, "phone_eph", "seed_label"),
        )
        val pcEphSeed = TestSupport.seed(TestSupport.requireString(handshake, "pc_eph", "seed_label"))
        val phoneEph = PclinkCrypto.x25519PublicKey(phoneEphSeed)
        val pcEph = PclinkCrypto.x25519PublicKey(pcEphSeed)
        assertEquals(
            TestSupport.requireString(handshake, "phone_eph", "public_key"),
            PclinkBase64Url.encode(phoneEph),
        )
        assertEquals(
            TestSupport.requireString(handshake, "pc_eph", "public_key"),
            PclinkBase64Url.encode(pcEph),
        )

        val from = TestSupport.requireString(handshake, "from")
        val to = TestSupport.requireString(handshake, "to")
        assertEquals(phone.machineId, from)
        assertEquals(pc.machineId, to)
        val sid = TestSupport.b64(handshake, "sid")!!
        val phoneNonce = TestSupport.b64(handshake, "phone_nonce")!!
        val pcNonce = TestSupport.b64(handshake, "pc_nonce")!!
        val initTranscript = PclinkCrypto.sessionInitTranscript(from, to, sid, phoneEph, phoneNonce)
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "init_hex"),
            PclinkHex.encode(initTranscript),
        )
        val th1 = PclinkCrypto.sha256(initTranscript)
        assertEquals(TestSupport.requireString(handshake, "transcripts", "th1_hex"), PclinkHex.encode(th1))

        val respTranscript = PclinkCrypto.sessionRespTranscript(th1, pcEph, pcNonce)
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "resp_hex"),
            PclinkHex.encode(respTranscript),
        )
        val th2 = PclinkCrypto.sha256(respTranscript)
        assertEquals(TestSupport.requireString(handshake, "transcripts", "th2_hex"), PclinkHex.encode(th2))
        assertTrue(
            "resp signature",
            PclinkCrypto.ed25519Verify(
                pc.publicKey,
                respTranscript,
                TestSupport.b64(handshake, "resp", "sig")!!,
            ),
        )

        val dh = PclinkCrypto.x25519SharedSecret(phoneEphSeed, pcEph)
        assertEquals(TestSupport.requireString(handshake, "dh_hex"), PclinkHex.encode(dh))
        assertTrue(
            "X25519 agreement is symmetric",
            dh.contentEquals(PclinkCrypto.x25519SharedSecret(pcEphSeed, phoneEph)),
        )
        val keys = PclinkCrypto.sessionKeys(dh, th2)
        assertEquals(
            TestSupport.requireString(handshake, "keys", "phone_to_pc"),
            PclinkBase64Url.encode(keys.phoneToPC),
        )
        assertEquals(
            TestSupport.requireString(handshake, "keys", "pc_to_phone"),
            PclinkBase64Url.encode(keys.pcToPhone),
        )
        assertEquals(
            TestSupport.requireString(handshake, "keys", "confirm_phone"),
            PclinkBase64Url.encode(keys.confirmPhone),
        )
        assertEquals(
            TestSupport.requireString(handshake, "keys", "confirm_pc"),
            PclinkBase64Url.encode(keys.confirmPC),
        )
        assertEquals(
            TestSupport.requireString(handshake, "confirmations", "pc"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPC, th2)),
        )
        assertEquals(
            TestSupport.requireString(handshake, "resp", "confirm"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPC, th2)),
        )

        val confirmTranscript = PclinkCrypto.sessionConfirmTranscript(th2, from, to, sid)
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "confirm_hex"),
            PclinkHex.encode(confirmTranscript),
        )
        val th3 = PclinkCrypto.sha256(confirmTranscript)
        assertEquals(TestSupport.requireString(handshake, "transcripts", "th3_hex"), PclinkHex.encode(th3))
        assertTrue(
            "confirm signature",
            PclinkCrypto.ed25519Verify(
                phone.publicKey,
                confirmTranscript,
                TestSupport.b64(handshake, "confirm", "sig")!!,
            ),
        )
        assertEquals(
            TestSupport.requireString(handshake, "confirmations", "phone"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPhone, th3)),
        )
        assertEquals(
            TestSupport.requireString(handshake, "confirm", "confirm"),
            PclinkBase64Url.encode(PclinkCrypto.confirmation(keys.confirmPhone, th3)),
        )

        val rejectTranscript = PclinkCrypto.sessionRejectTranscript(th1, "unpaired")
        assertEquals(
            TestSupport.requireString(handshake, "transcripts", "reject_hex"),
            PclinkHex.encode(rejectTranscript),
        )
        assertTrue(
            "reject signature",
            PclinkCrypto.ed25519Verify(
                pc.publicKey,
                rejectTranscript,
                TestSupport.b64(handshake, "reject", "sig")!!,
            ),
        )
    }

    @Test
    fun pairingCryptoPrimitives() {
        val vectors = TestSupport.vectors()
        val pairing = TestSupport.at(vectors, "pairing")
            ?: throw AssertionError("missing pairing")
        val origin = pairing.requiredString("origin")
        val secretS = TestSupport.b64(pairing, "secret_s")
            ?: throw AssertionError("missing secret_s")
        assertEquals(16, secretS.size)
        val pairKeyS = TestSupport.b64(pairing, "pair_key_s")
            ?: throw AssertionError("missing pair_key_s")
        assertEquals(
            "pair_key_s",
            pairing.requiredString("pair_key_s"),
            PclinkBase64Url.encode(PclinkCrypto.pairKey(secretS)),
        )
        assertEquals(
            "rendezvous_s",
            pairing.requiredString("rendezvous_s"),
            PclinkCrypto.rendezvous(secretS, origin),
        )
        assertEquals(
            "rendezvous_s_other_origin",
            pairing.requiredString("rendezvous_s_other_origin"),
            PclinkCrypto.rendezvous(secretS, "https://other.example"),
        )
        assertPairMacs(pairing, pairKeyS)

        val manual = TestSupport.at(vectors, "pairing", "manual")
            ?: throw AssertionError("missing pairing.manual")
        val secretC = TestSupport.hex(manual.requiredString("secret_hex"))
        assertEquals(10, secretC.size)
        val pairKeyC = TestSupport.b64(manual, "pair_key")
            ?: throw AssertionError("missing manual pair_key")
        assertEquals(
            "manual pair_key",
            manual.requiredString("pair_key"),
            PclinkBase64Url.encode(PclinkCrypto.pairKey(secretC)),
        )
        assertEquals(
            "manual rendezvous",
            manual.requiredString("rendezvous"),
            PclinkCrypto.rendezvous(secretC, origin),
        )
        assertPairMacs(manual, pairKeyC)

        assertTrue(PclinkCrypto.constantTimeEquals(secretC, secretC.copyOf()))
        assertFalse(PclinkCrypto.constantTimeEquals(secretC, secretS))
    }

    private fun assertPairMacs(
        payload: PclinkJson,
        pairKey: ByteArray,
    ) {
        for ((name, domain) in listOf(
            "hello" to PclinkCrypto.PAIR_HELLO_DOMAIN,
            "auth" to PclinkCrypto.PAIR_AUTH_DOMAIN,
            "confirm" to PclinkCrypto.PAIR_CONFIRM_DOMAIN,
            "final" to PclinkCrypto.PAIR_FINAL_DOMAIN,
        )) {
            val value = payload[name] ?: throw AssertionError("missing pairing.$name")
            val members = LinkedHashMap(value.objectValue!!)
            val claimed = members.remove("mac")?.stringValue
                ?: throw AssertionError("pairing.$name has no mac")
            assertEquals(
                "pairing.$name mac",
                claimed,
                PclinkBase64Url.encode(
                    PclinkCrypto.pairMac(pairKey, domain, PclinkJson.Object(members)),
                ),
            )
        }
        val helloWithoutMac = withoutMac(payload["hello"]!!)
        val authWithoutMac = withoutMac(payload["auth"]!!)
        assertEquals(
            "transcript hash",
            payload.requiredString("transcript_hash"),
            PclinkBase64Url.encode(
                PclinkCrypto.pairTranscriptHash(helloWithoutMac, authWithoutMac),
            ),
        )
    }

    private fun withoutMac(value: PclinkJson): PclinkJson {
        val members = LinkedHashMap(value.objectValue!!)
        members.remove("mac")
        return PclinkJson.Object(members)
    }

    @Test
    fun generatedEphemeralKeyPairsAgree() {
        // Fresh ephemerals are random by contract (§5.2); the property under
        // test is that the production generator and agreement accept each other.
        val first = PclinkCrypto.generateX25519()
        val second = PclinkCrypto.generateX25519()
        assertEquals(32, first.privateKey.size)
        assertEquals(32, first.publicKey.size)
        assertEquals(32, second.privateKey.size)
        assertEquals(32, second.publicKey.size)
        assertFalse(first.privateKey.contentEquals(second.privateKey))
        assertArrayEquals(
            PclinkCrypto.x25519SharedSecret(first.privateKey, second.publicKey),
            PclinkCrypto.x25519SharedSecret(second.privateKey, first.publicKey),
        )
        // `toString` must not expose private key material.
        assertFalse(first.toString().contains(PclinkBase64Url.encode(first.privateKey)))
        assertTrue(first.toString().contains(PclinkBase64Url.encode(first.publicKey)))
    }

    @Test
    fun c1InvalidRowsAreExactlyTheCryptoKinds() {
        val invalid = TestSupport.objects(TestSupport.vectors(), "invalid")
        assertEquals(82, invalid.size)
        val crypto = invalid.filter { TestSupport.string(it, "evidence") == "crypto" }
        assertEquals(56, crypto.size)
        val c1Kinds = setOf(
            "aead", "canonical", "encoding", "name", "origin", "frame",
            "handshake_signature", "handshake_transcript", "x25519", "suite", "caps",
            "fingerprint",
        )
        val rows = invalid.filter {
            val kind = TestSupport.string(it, "kind")
            kind != null && kind in c1Kinds
        }
        assertEquals(29, rows.size)
        // Every C1 row is crypto evidence, not a C2/C4 state-machine sample.
        assertTrue(rows.all { TestSupport.string(it, "evidence") == "crypto" })
    }

    private fun outerFrame(frame: PclinkJson): PclinkJson {
        val members = LinkedHashMap<String, PclinkJson>()
        members["v"] = PclinkJson.Integer(TestSupport.long(frame, "v") ?: 1L)
        members["type"] = PclinkJson.Text("e2e")
        for (key in listOf("sid", "seq", "from", "to", "body")) {
            frame[key]?.let { members[key] = it }
        }
        return PclinkJson.Object(members)
    }

    /**
     * The production transcript builder always binds the frozen version and
     * suite. These rows mutate one of them, so the test re-derives the exact
     * §5.2 bytes with the mutated value to prove the golden `reference_hex`
     * (the hash of the unmutated init) cannot match.
     */
    private fun flexibleInitTranscript(row: PclinkJson): ByteArray {
        val init = TestSupport.at(row, "init") ?: throw AssertionError("missing init")
        val version = TestSupport.long(init, "v") ?: 1L
        return ByteArray(0)
            .plus("pclink-v1/session-init".toByteArray(Charsets.UTF_8))
            .plus(byteArrayOf(0))
            .plus(version.toString().toByteArray(Charsets.UTF_8))
            .plus(byteArrayOf(0))
            .plus(TestSupport.requireString(init, "suite").toByteArray(Charsets.UTF_8))
            .plus(byteArrayOf(0))
            .plus(TestSupport.requireString(row, "from").toByteArray(Charsets.UTF_8))
            .plus(byteArrayOf(0))
            .plus(TestSupport.requireString(row, "to").toByteArray(Charsets.UTF_8))
            .plus(byteArrayOf(0))
            .plus(TestSupport.b64(init, "sid")!!)
            .plus(byteArrayOf(0))
            .plus(TestSupport.b64(init, "eph")!!)
            .plus(byteArrayOf(0))
            .plus(TestSupport.b64(init, "nonce")!!)
    }
}
