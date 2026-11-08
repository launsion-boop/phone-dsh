// phone-dsh — :net / com.phonedsh.adb: this phone's ADB RSA identity.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBIdentity.swift`. The iOS key lives in the
// Keychain; Android has no SecItem, so the private key is kept the way every other
// host secret is kept here: the `SecureStore` SPI (`AndroidSecureStore` wraps it
// with an AndroidKeyStore AES-GCM key in `noBackupFilesDir`). The private key is
// never written in plaintext and never enters the Worker.
//
// Fail-closed rule (same as the Keychain read): a stored key that cannot be read
// (`SecureLookup.Unreadable`, e.g. the Keystore wrapping key was invalidated) is
// an error, never "absent". Minting a new key would silently change the identity
// the Android device authorized.
//
// Honest difference from iOS: SecKeyCreateSignature uses an opaque SecKey; here the
// PKCS#8 bytes are decrypted into process memory when the identity is loaded.

package com.phonedsh.adb

import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAKeyGenParameterSpec
import java.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

public class AdbIdentity internal constructor(private val privateKey: RSAPrivateCrtKey) {
    /** Signs the 20-byte AUTH token as a precomputed SHA-1 digest (PKCS#1 v1.5). */
    public fun sign(token: ByteArray): ByteArray {
        if (token.size != 20) throw AdbFailure("Invalid ADB authentication challenge")
        return try {
            Signature.getInstance("NONEwithRSA").run {
                initSign(privateKey as PrivateKey)
                update(SHA1_DIGEST_INFO + token)
                sign()
            }
        } catch (failure: java.security.GeneralSecurityException) {
            throw AdbFailure("Cannot sign ADB authentication challenge")
        }
    }

    /** `base64(android key) + " phone-dsh@android\0"`, the AUTH RSAPUBLICKEY payload. */
    public fun publicKey(): ByteArray {
        val encoded = androidPublicKey(privateKey.modulus, privateKey.publicExponent)
        return (Base64.getEncoder().encodeToString(encoded) + " phone-dsh@android\u0000").toByteArray(Charsets.UTF_8)
    }

    public companion object {
        /** SecureStore key; the Keychain tag on iOS is `phone-dsh.android-adb.rsa.v1`. */
        public const val STORE_KEY: String = "phone-dsh.android-adb.rsa.v1"
        private val lock = Mutex()
        private val SHA1_DIGEST_INFO = byteArrayOf(
            0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
        )

        /** Loads the stored key or creates and stores a new 2048-bit key; Unreadable fails closed. */
        public suspend fun loadOrCreate(store: SecureStore): AdbIdentity = lock.withLock {
            when (val found = store.get(STORE_KEY)) {
                is SecureLookup.Found -> decode(found.value)
                is SecureLookup.Unreadable ->
                    throw AdbFailure("Cannot read ADB identity (${found.reason}); refusing to create a new key")
                SecureLookup.Absent -> {
                    val generator = KeyPairGenerator.getInstance("RSA")
                    generator.initialize(RSAKeyGenParameterSpec(2048, RSAKeyGenParameterSpec.F4))
                    val pair = generator.generateKeyPair()
                    val key = pair.private as RSAPrivateCrtKey
                    try {
                        store.put(STORE_KEY, key.encoded)
                    } catch (failure: java.io.IOException) {
                        throw AdbFailure("Cannot store ADB identity")
                    }
                    AdbIdentity(key)
                }
            }
        }

        internal fun decode(pkcs8: ByteArray): AdbIdentity {
            val key = try {
                KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(pkcs8)) as? RSAPrivateCrtKey
            } catch (failure: java.security.GeneralSecurityException) {
                null
            } ?: throw AdbFailure("Stored ADB identity is not an RSA key; refusing to create a new key")
            return AdbIdentity(key)
        }

        /**
         * Android's 524-byte little-endian `RSAPublicKey`: word count, -1/n[0] mod
         * 2^32, n, R² mod n and the exponent. Same checks as the Swift encoder.
         */
        public fun androidPublicKey(modulus: BigInteger, exponent: BigInteger): ByteArray {
            if (modulus.bitLength() != 2048 || !modulus.testBit(0) || exponent != BigInteger.valueOf(65537)) {
                throw AdbFailure("ADB requires a 2048-bit RSA key with exponent 65537")
            }
            val two32 = BigInteger.ONE.shiftLeft(32)
            val n0inv = two32.subtract(modulus.mod(two32).modInverse(two32)).mod(two32).toLong()
            val rr = BigInteger.ONE.shiftLeft(4096).mod(modulus)
            val out = ByteArrayOutputStream(524)
            out.appendLe(64)
            out.appendLe(n0inv)
            out.write(littleEndian(modulus))
            out.write(littleEndian(rr))
            out.appendLe(65537)
            return out.toByteArray()
        }

        private fun littleEndian(value: BigInteger): ByteArray {
            val big = value.toByteArray()
            val out = ByteArray(256)
            for (i in 0 until 256) {
                val index = big.size - 1 - i
                out[i] = if (index >= 0) big[index] else 0
            }
            return out
        }
    }
}
