// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.cloudtasks: task sealing (cloud-tasks.md §3).
//
// HPKE (RFC 9180) base mode, single shot, DHKEM(P-256, HKDF-SHA256) /
// HKDF-SHA256 / AES-128-GCM, built from the platform JCA only: EC secp256r1
// ECDH, HmacSHA256 and AES/GCM/NoPadding. No provider is added. The
// construction is the one in spec/v1/tools/test_cloud_tasks.py
// (`_key_and_nonce`, `seal`, `open_sealed`) and the `sealing` cases pin its
// bytes. The phone only opens; `seal` exists for the vectors and for tests.

package com.phonedsh.cloudtasks

import com.phonedsh.gateway.GatewayJson
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import java.security.AlgorithmParameters
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The sealed value does not open with this key and AAD. Carries no detail by design. */
class CloudTaskOpenException : Exception("the sealed task does not open")

/** A P-256 key pair in the contract's encodings. `toString` never prints the scalar. */
class CloudTaskKeyPair internal constructor(
    /** 32-byte big-endian private scalar. */
    val privateScalar: ByteArray,
    /** Uncompressed point `0x04 ‖ X ‖ Y`, 65 bytes. */
    val publicKey: ByteArray,
) {
    override fun toString(): String = "CloudTaskKeyPair(public ${publicKey.size} bytes)"
}

object CloudTaskCrypto {
    private const val FIELD_BYTES = 32
    private const val POINT_BYTES = 65
    private const val KEY_BYTES = 16
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128

    private val INFO = CloudTaskWire.INFO.toByteArray(StandardCharsets.US_ASCII)
    private val VERSION = "HPKE-v1".toByteArray(StandardCharsets.US_ASCII)

    // suite_id: "KEM" ‖ kem_id 0x0010, and "HPKE" ‖ kem_id 0x0010 ‖ kdf_id 0x0001 ‖ aead_id 0x0001.
    private val KEM_SUITE = "KEM".toByteArray(StandardCharsets.US_ASCII) + byteArrayOf(0x00, 0x10)
    private val HPKE_SUITE =
        "HPKE".toByteArray(StandardCharsets.US_ASCII) + byteArrayOf(0x00, 0x10, 0x00, 0x01, 0x00, 0x01)

    private val curve: ECParameterSpec by lazy {
        val parameters = AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        parameters.getParameterSpec(ECParameterSpec::class.java)
    }
    private val fieldPrime: BigInteger by lazy {
        (curve.curve.field as java.security.spec.ECFieldFp).p
    }

    // ---- §3 associated data

    /** The seven lines of §3 joined by single `\n`, no trailing newline, UTF-8. */
    fun aad(deviceId: String, keyId: String, requestId: String, target: CloudTaskTarget, expiresAtMs: Long): ByteArray =
        aadText(deviceId, keyId, requestId, target.kind.wire, target.id, expiresAtMs)
            .toByteArray(StandardCharsets.UTF_8)

    fun aadText(
        deviceId: String,
        keyId: String,
        requestId: String,
        targetKind: String,
        targetId: String,
        expiresAtMs: Long,
    ): String = listOf(CloudTaskWire.INFO, deviceId, keyId, requestId, targetKind, targetId, expiresAtMs.toString())
        .joinToString("\n")

    // ---- keys

    /** A fresh key pair from the platform generator. */
    fun generateKeyPair(random: SecureRandom = SecureRandom()): CloudTaskKeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = generator.generateKeyPair()
        return CloudTaskKeyPair(
            fixed((pair.private as ECPrivateKey).s),
            encodePoint((pair.public as ECPublicKey).w),
        )
    }

    /**
     * The key pair of a given private scalar (32 bytes, big-endian). Used by the
     * vectors (fixed ephemeral scalar) and by tests. The point is computed with
     * plain BigInteger arithmetic, which is not constant time: do not call it
     * with a long-lived device key — [generateKeyPair] returns both halves.
     */
    @Throws(IllegalArgumentException::class)
    fun keyPairFromScalar(scalar: ByteArray): CloudTaskKeyPair {
        require(scalar.size == FIELD_BYTES) { "scalar must be 32 bytes" }
        val value = BigInteger(1, scalar)
        require(value.signum() > 0 && value < curve.order) { "scalar out of range" }
        return CloudTaskKeyPair(scalar.copyOf(), encodePoint(multiply(curve.generator, value)))
    }

    /** True when [point] is an uncompressed P-256 point on the curve. */
    fun isPublicKey(point: ByteArray): Boolean = decodePoint(point) != null

    // ---- seal / open

    /** Single-shot base-mode seal to [recipientPublicKey] with the §3 `info`. */
    @Throws(IllegalArgumentException::class)
    fun seal(
        recipientPublicKey: ByteArray,
        plaintext: ByteArray,
        aad: ByteArray,
        ephemeral: CloudTaskKeyPair = generateKeyPair(),
    ): CloudTaskSealed {
        require(plaintext.size in 1..CloudTaskWire.MAX_TEXT_BYTES) { "plaintext must be 1–16384 bytes" }
        val recipient = requireNotNull(decodePoint(recipientPublicKey)) { "recipient key is not a P-256 point" }
        val dh = try {
            exchange(ephemeral.privateScalar, recipient)
        } catch (failure: GeneralSecurityException) {
            throw IllegalArgumentException("key agreement failed", failure)
        }
        val (key, nonce) = keyAndNonce(dh, ephemeral.publicKey, recipientPublicKey)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return CloudTaskSealed(ephemeral.publicKey.copyOf(), cipher.doFinal(plaintext))
    }

    /**
     * Opens [sealed] with the recipient key and the §3 AAD. Any failure — a
     * malformed `enc`, a point off the curve, a wrong key, AAD or tag — is the
     * same [CloudTaskOpenException].
     */
    @Throws(CloudTaskOpenException::class)
    fun open(recipient: CloudTaskKeyPair, sealed: CloudTaskSealed, aad: ByteArray): ByteArray {
        try {
            if (sealed.ct.size < CloudTaskWire.TAG_BYTES) throw CloudTaskOpenException()
            val peer = decodePoint(sealed.enc) ?: throw CloudTaskOpenException()
            val dh = exchange(recipient.privateScalar, peer)
            val (key, nonce) = keyAndNonce(dh, sealed.enc, recipient.publicKey)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            cipher.updateAAD(aad)
            return cipher.doFinal(sealed.ct)
        } catch (_: GeneralSecurityException) {
            throw CloudTaskOpenException()
        } catch (_: IllegalArgumentException) {
            throw CloudTaskOpenException()
        }
    }

    /**
     * §7 step 3: opens [sealed] to the task text. Bytes that open (the tag is
     * valid) but are not 1–16384 bytes of valid UTF-8 are not a task text and
     * fail the same way as bytes that do not open (`rejected/decrypt_failed`).
     */
    @Throws(CloudTaskOpenException::class)
    fun openText(recipient: CloudTaskKeyPair, sealed: CloudTaskSealed, aad: ByteArray): String {
        val opened = open(recipient, sealed, aad)
        if (opened.size !in 1..CloudTaskWire.MAX_TEXT_BYTES) throw CloudTaskOpenException()
        return GatewayJson.decodeUtf8(opened) ?: throw CloudTaskOpenException()
    }

    // ---- RFC 9180 key schedule (base mode, sequence number 0)

    private fun keyAndNonce(dh: ByteArray, enc: ByteArray, recipientPublicKey: ByteArray): Pair<ByteArray, ByteArray> {
        val empty = ByteArray(0)
        val eaePrk = labeledExtract(KEM_SUITE, empty, "eae_prk", dh)
        val shared = labeledExpand(KEM_SUITE, eaePrk, "shared_secret", enc + recipientPublicKey, 32)
        val pskIdHash = labeledExtract(HPKE_SUITE, empty, "psk_id_hash", empty)
        val infoHash = labeledExtract(HPKE_SUITE, empty, "info_hash", INFO)
        val context = byteArrayOf(0) + pskIdHash + infoHash
        val secret = labeledExtract(HPKE_SUITE, shared, "secret", empty)
        return labeledExpand(HPKE_SUITE, secret, "key", context, KEY_BYTES) to
            labeledExpand(HPKE_SUITE, secret, "base_nonce", context, NONCE_BYTES)
    }

    private fun labeledExtract(suite: ByteArray, salt: ByteArray, label: String, ikm: ByteArray): ByteArray =
        hmac(if (salt.isEmpty()) ByteArray(32) else salt, VERSION + suite + ascii(label) + ikm)

    private fun labeledExpand(suite: ByteArray, prk: ByteArray, label: String, info: ByteArray, length: Int): ByteArray {
        val labeled = byteArrayOf((length ushr 8).toByte(), length.toByte()) + VERSION + suite + ascii(label) + info
        var out = ByteArray(0)
        var block = ByteArray(0)
        var counter = 1
        while (out.size < length) {
            block = hmac(prk, block + labeled + byteArrayOf(counter.toByte()))
            out += block
            counter++
        }
        return out.copyOf(length)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun ascii(text: String): ByteArray = text.toByteArray(StandardCharsets.US_ASCII)

    // ---- P-256 through the JCA

    /** ECDH: the 32-byte x coordinate of `scalar · peer`. */
    private fun exchange(scalar: ByteArray, peer: ECPoint): ByteArray {
        val factory = KeyFactory.getInstance("EC")
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(factory.generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), curve)))
        agreement.doPhase(factory.generatePublic(ECPublicKeySpec(peer, curve)), true)
        val secret = agreement.generateSecret()
        return when {
            secret.size == FIELD_BYTES -> secret
            secret.size < FIELD_BYTES -> ByteArray(FIELD_BYTES - secret.size) + secret
            else -> throw GeneralSecurityException("unexpected shared secret length")
        }
    }

    /** `0x04 ‖ X ‖ Y` on the curve, else null. */
    private fun decodePoint(bytes: ByteArray): ECPoint? {
        if (bytes.size != POINT_BYTES || bytes[0] != 4.toByte()) return null
        val x = BigInteger(1, bytes.copyOfRange(1, 1 + FIELD_BYTES))
        val y = BigInteger(1, bytes.copyOfRange(1 + FIELD_BYTES, POINT_BYTES))
        val p = fieldPrime
        if (x >= p || y >= p) return null
        val right = x.pow(3).add(curve.curve.a.multiply(x)).add(curve.curve.b).mod(p)
        if (y.multiply(y).mod(p) != right) return null
        return ECPoint(x, y)
    }

    private fun encodePoint(point: ECPoint): ByteArray =
        byteArrayOf(4) + fixed(point.affineX) + fixed(point.affineY)

    private fun fixed(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        val start = if (raw.size > FIELD_BYTES) raw.size - FIELD_BYTES else 0
        val out = ByteArray(FIELD_BYTES)
        System.arraycopy(raw, start, out, FIELD_BYTES - (raw.size - start), raw.size - start)
        return out
    }

    // ---- affine scalar multiplication, for [keyPairFromScalar] only

    private fun multiply(point: ECPoint, scalar: BigInteger): ECPoint {
        var result: ECPoint? = null
        var addend: ECPoint? = point
        for (bit in 0 until scalar.bitLength()) {
            if (scalar.testBit(bit)) result = add(result, addend)
            addend = add(addend, addend)
        }
        return requireNotNull(result) { "scalar must not be zero" }
    }

    /** Affine addition; null is the point at infinity. */
    private fun add(left: ECPoint?, right: ECPoint?): ECPoint? {
        if (left == null) return right
        if (right == null) return left
        val p = fieldPrime
        val slope = if (left.affineX == right.affineX) {
            if (left.affineY.add(right.affineY).mod(p).signum() == 0) return null
            left.affineX.pow(2).multiply(BigInteger.valueOf(3)).add(curve.curve.a)
                .multiply(left.affineY.shiftLeft(1).modInverse(p))
        } else {
            right.affineY.subtract(left.affineY).multiply(right.affineX.subtract(left.affineX).modInverse(p))
        }.mod(p)
        val x = slope.pow(2).subtract(left.affineX).subtract(right.affineX).mod(p)
        val y = slope.multiply(left.affineX.subtract(x)).subtract(left.affineY).mod(p)
        return ECPoint(x, y)
    }
}
