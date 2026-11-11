// SPDX-License-Identifier: MIT
// PCLink v1 cryptography: Ed25519, X25519, HKDF-SHA256, HMAC-SHA256,
// ChaCha20-Poly1305 and the exact §5/§4 transcripts.
//
// Bouncy Castle's lightweight API (`org.bouncycastle.crypto.*`) is used
// directly, with no JCA provider registration: minSdk 26 has no platform
// X25519/Ed25519 guarantee and ChaCha20-Poly1305 only from API 28, so a JCA path
// would need two implementations of the same bytes. See the design §4.1.
package com.phonedsh.pclink

import java.security.SecureRandom
import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.macs.HMac
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.util.Arrays

object PclinkCrypto {
    const val SUITE = "pclink-x25519-ed25519-chacha20poly1305-1"
    const val PROTOCOL_VERSION = "1"

    /** One 0x00 separator byte (the transcripts are domain-separated with it). */
    private val NUL = byteArrayOf(0)

    // ---- Hash / MAC / KDF -------------------------------------------------

    fun sha256(data: ByteArray): ByteArray {
        val digest = SHA256Digest()
        digest.update(data, 0, data.size)
        return ByteArray(digest.digestSize).also { digest.doFinal(it, 0) }
    }

    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = HMac(SHA256Digest())
        mac.init(KeyParameter(key))
        mac.update(data, 0, data.size)
        return ByteArray(mac.macSize).also { mac.doFinal(it, 0) }
    }

    /** HKDF-SHA256 (RFC 5869): extract with [salt], expand with [info]. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val generator = HKDFBytesGenerator(SHA256Digest())
        generator.init(HKDFParameters(ikm, salt, info))
        val out = ByteArray(length)
        generator.generateBytes(out, 0, length)
        return out
    }

    // ---- Ed25519 ---------------------------------------------------------

    fun ed25519PublicKey(seed: ByteArray): ByteArray {
        requireLength(seed, 32, "Ed25519 seed")
        return Ed25519PrivateKeyParameters(seed, 0).generatePublicKey().encoded
    }

    fun ed25519Sign(seed: ByteArray, message: ByteArray): ByteArray {
        requireLength(seed, 32, "Ed25519 seed")
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(seed, 0))
        signer.update(message, 0, message.size)
        return signer.generateSignature()
    }

    fun ed25519Verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        return try {
            val verifier = Ed25519Signer()
            verifier.init(false, Ed25519PublicKeyParameters(publicKey, 0))
            verifier.update(message, 0, message.size)
            verifier.verifySignature(signature)
        } catch (_: RuntimeException) {
            false
        }
    }

    // ---- X25519 ----------------------------------------------------------

    /**
     * One ephemeral X25519 key pair. [privateKey] is never part of `toString`,
     * because a key must not reach a log or a crash report.
     */
    class EphemeralKey(val privateKey: ByteArray, val publicKey: ByteArray) {
        override fun toString(): String =
            "EphemeralKey(publicKey=${PclinkBase64Url.encode(publicKey)})"
    }

    fun generateX25519(): EphemeralKey {
        val key = X25519PrivateKeyParameters(SecureRandom())
        return EphemeralKey(key.encoded, key.generatePublicKey().encoded)
    }

    fun x25519PublicKey(privateKey: ByteArray): ByteArray {
        requireLength(privateKey, 32, "X25519 private key")
        return X25519PrivateKeyParameters(privateKey, 0).generatePublicKey().encoded
    }

    /**
     * X25519 shared secret. An all-zero public key and an all-zero derived
     * secret (the low-order points) are rejected before any key derivation;
     * the contract maps both to `auth_failed` (§5.2).
     */
    fun x25519SharedSecret(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        requireLength(privateKey, 32, "X25519 private key")
        requireLength(publicKey, 32, "X25519 public key")
        if (publicKey.all { it == 0.toByte() }) {
            throw PclinkError.AuthFailed("all-zero X25519 public key")
        }
        val out = ByteArray(32)
        try {
            val agreement = X25519Agreement()
            agreement.init(X25519PrivateKeyParameters(privateKey, 0))
            agreement.calculateAgreement(X25519PublicKeyParameters(publicKey, 0), out, 0)
        } catch (error: RuntimeException) {
            throw PclinkError.AuthFailed("X25519 agreement failed: ${error.message}")
        }
        if (Arrays.constantTimeAreEqual(out, ByteArray(32))) {
            throw PclinkError.AuthFailed("all-zero X25519 shared secret")
        }
        return out
    }

    // ---- AEAD ------------------------------------------------------------

    fun aeadSeal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        requireLength(key, 32, "AEAD key")
        if (nonce.size != 12) throw PclinkError.AuthFailed("invalid AEAD nonce")
        val cipher = ChaCha20Poly1305()
        cipher.init(true, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(cipher.getOutputSize(plaintext.size))
        var length = cipher.processBytes(plaintext, 0, plaintext.size, out, 0)
        length += try {
            cipher.doFinal(out, length)
        } catch (error: InvalidCipherTextException) {
            throw PclinkError.AuthFailed("ChaCha20-Poly1305 seal failed: ${error.message}")
        }
        return out.copyOf(length)
    }

    fun aeadOpen(ciphertext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        requireLength(key, 32, "AEAD key")
        if (nonce.size != 12) throw PclinkError.AuthFailed("invalid AEAD nonce")
        if (ciphertext.size < 16) throw PclinkError.AuthFailed("AEAD tag is missing")
        val cipher = ChaCha20Poly1305()
        cipher.init(false, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(cipher.getOutputSize(ciphertext.size))
        var length = cipher.processBytes(ciphertext, 0, ciphertext.size, out, 0)
        length += try {
            cipher.doFinal(out, length)
        } catch (_: InvalidCipherTextException) {
            throw PclinkError.AuthFailed("ChaCha20-Poly1305 authentication failed")
        }
        return out.copyOf(length)
    }

    /** `00000000 || u64be(seq)` (§5.4). */
    fun aeadNonce(seq: Long): ByteArray {
        require(seq >= 0) { "seq must be non-negative" }
        val nonce = ByteArray(12)
        for (index in 0..7) {
            nonce[11 - index] = ((seq ushr (8 * index)) and 0xFF).toByte()
        }
        return nonce
    }

    // ---- Relay auth (§3.2) ----------------------------------------------

    fun relayAuthTranscript(origin: String, nonce: ByteArray): ByteArray =
        ByteArray(0)
            .plus("pclink-v1/relay-auth".toByteArray(Charsets.UTF_8))
            .plus(NUL)
            .plus(origin.toByteArray(Charsets.UTF_8))
            .plus(NUL)
            .plus(nonce)

    // ---- Session transcripts (§5.2) -------------------------------------

    const val SESSION_INIT_DOMAIN = "pclink-v1/session-init"
    const val SESSION_RESP_DOMAIN = "pclink-v1/session-resp"
    const val SESSION_CONFIRM_DOMAIN = "pclink-v1/session-confirm"
    const val SESSION_REJECT_DOMAIN = "pclink-v1/session-reject"

    fun sessionInitTranscript(
        phoneMachineId: String,
        pcMachineId: String,
        sid: ByteArray,
        ephPhone: ByteArray,
        noncePhone: ByteArray,
    ): ByteArray = ByteArray(0)
        .plus(SESSION_INIT_DOMAIN.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(PROTOCOL_VERSION.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(SUITE.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(phoneMachineId.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(pcMachineId.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(sid)
        .plus(NUL)
        .plus(ephPhone)
        .plus(NUL)
        .plus(noncePhone)

    fun sessionRespTranscript(th1: ByteArray, ephPc: ByteArray, noncePc: ByteArray): ByteArray =
        ByteArray(0)
            .plus(SESSION_RESP_DOMAIN.toByteArray(Charsets.UTF_8))
            .plus(NUL)
            .plus(th1)
            .plus(NUL)
            .plus(ephPc)
            .plus(NUL)
            .plus(noncePc)

    fun sessionConfirmTranscript(
        th2: ByteArray,
        phoneMachineId: String,
        pcMachineId: String,
        sid: ByteArray,
    ): ByteArray = ByteArray(0)
        .plus(SESSION_CONFIRM_DOMAIN.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(th2)
        .plus(NUL)
        .plus(phoneMachineId.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(pcMachineId.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(sid)

    fun sessionRejectTranscript(th1: ByteArray, code: String): ByteArray = ByteArray(0)
        .plus(SESSION_REJECT_DOMAIN.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(th1)
        .plus(NUL)
        .plus(code.toByteArray(Charsets.UTF_8))

    // ---- Session key schedule (§5.3) ------------------------------------

    /** Four separate keys; `toString` never prints key material. */
    class SessionKeys(
        val phoneToPC: ByteArray,
        val pcToPhone: ByteArray,
        val confirmPhone: ByteArray,
        val confirmPC: ByteArray,
    ) {
        override fun toString(): String = "SessionKeys(redacted)"
    }

    fun sessionKeys(dh: ByteArray, th2: ByteArray): SessionKeys = SessionKeys(
        phoneToPC = hkdfSha256(dh, th2, "pclink-v1/key/phone->pc".toByteArray(Charsets.UTF_8), 32),
        pcToPhone = hkdfSha256(dh, th2, "pclink-v1/key/pc->phone".toByteArray(Charsets.UTF_8), 32),
        confirmPhone = hkdfSha256(dh, th2, "pclink-v1/key-confirm/phone->pc".toByteArray(Charsets.UTF_8), 32),
        confirmPC = hkdfSha256(dh, th2, "pclink-v1/key-confirm/pc->phone".toByteArray(Charsets.UTF_8), 32),
    )

    fun confirmation(key: ByteArray, th: ByteArray): ByteArray =
        hmacSha256(key, "pclink-v1/confirm".toByteArray(Charsets.UTF_8).plus(NUL).plus(th))

    // ---- AAD (§5.4) ------------------------------------------------------

    fun aad(sid: String, seq: Long, from: String, to: String): ByteArray = ByteArray(0)
        .plus("pclink-v1/aad".toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(PROTOCOL_VERSION.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus("e2e".toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(sid.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(seq.toString().toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(from.toByteArray(Charsets.UTF_8))
        .plus(NUL)
        .plus(to.toByteArray(Charsets.UTF_8))

    // ---- Pairing (§4.3, §4.4) -------------------------------------------

    const val PAIR_HELLO_DOMAIN = "pclink-v1/pair-hello"
    const val PAIR_AUTH_DOMAIN = "pclink-v1/pair-auth"
    const val PAIR_CONFIRM_DOMAIN = "pclink-v1/pair-confirm"
    const val PAIR_FINAL_DOMAIN = "pclink-v1/pair-final"

    fun pairKey(secret: ByteArray): ByteArray =
        hkdfSha256(secret, ByteArray(32), "pclink-v1/pair-mac".toByteArray(Charsets.UTF_8), 32)

    /** `HMAC-SHA256(pair_key, UTF8(domain) || 0x00 || canonical_json(object))`. */
    fun pairMac(pairKey: ByteArray, domain: String, objectWithoutMac: PclinkJson): ByteArray =
        hmacSha256(
            pairKey,
            domain.toByteArray(Charsets.UTF_8)
                .plus(NUL)
                .plus(PclinkJsonEncoder.canonical(objectWithoutMac)),
        )

    fun pairTranscriptHash(hello: PclinkJson, auth: PclinkJson): ByteArray {
        val th1 = sha256(PclinkJsonEncoder.canonical(hello))
        val th2 = sha256(PclinkJsonEncoder.canonical(auth))
        return sha256(th1.plus(NUL).plus(th2))
    }

    fun rendezvous(secret: ByteArray, relayOrigin: String): String {
        val digest = sha256(
            ByteArray(0)
                .plus("pclink-v1/pair".toByteArray(Charsets.UTF_8))
                .plus(NUL)
                .plus(relayOrigin.toByteArray(Charsets.UTF_8))
                .plus(NUL)
                .plus(secret),
        )
        return PclinkBase64Url.encode(digest).take(22)
    }

    // ---- Misc ------------------------------------------------------------

    fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean {
        if (left.size != right.size) return false
        return Arrays.constantTimeAreEqual(left, right)
    }

    private fun requireLength(value: ByteArray, length: Int, name: String) {
        if (value.size != length) {
            throw PclinkError.BadFrame("$name must be $length bytes, got ${value.size}")
        }
    }
}
