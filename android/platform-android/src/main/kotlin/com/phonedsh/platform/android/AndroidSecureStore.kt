// Keystore-backed secret storage with an honest hardware level.
// SPDX-License-Identifier: MIT
//
// plan §7.3 / §15-5 / §15-6 and spec/v1/handoff.md §5: the reclaim token and
// model credentials never reach the Worker and never hit a plaintext file. The
// chain is StrongBox -> TEE -> application-managed key, and the level that the
// chain actually reached is reported, not the level it wanted (security
// checklist S6).
//
// Ciphertext lives in `Context.noBackupFilesDir`, which Auto Backup and device
// transfer skip (plan R11): a restored ciphertext without its Keystore key must
// fail closed instead of decrypting on another device.
//
// `get` is three-state on purpose. A key that exists but can no longer be read
// (the Keystore entry is gone or unusable, or the GCM tag no longer verifies)
// is `Unreadable`, never `Absent`: `Absent` invites the caller to mint a new
// token, which is exactly the wrong move after a restore or a key eviction.
// The keys are deliberately not auth-bound (see the class KDoc), so a
// lock-screen credential change on its own does not produce this state.

package com.phonedsh.platform.android

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Log
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException
import java.security.SecureRandom
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "PhdShPlatform"
private const val ANDROID_KEYSTORE = "AndroidKeyStore"
private const val TRANSFORMATION = "AES/GCM/NoPadding"
private const val GCM_TAG_BITS = 128
private const val GCM_IV_BYTES = 12
private const val KEY_BYTES = 32
private const val PROBE_ALIAS = "pdsh.secure.probe"
private const val ALIAS_PREFIX = "pdsh.secure."
private const val STORE_DIR = "secure-store"
private const val SOFTWARE_KEY_FILE = "software.key"
private const val VERSION_BYTE: Byte = 1
private const val FORMAT_KEYSTORE: Byte = 1
private const val FORMAT_SOFTWARE: Byte = 2

/** `[version][format][12-byte IV][GCM ciphertext incl. tag]`. */
private const val HEADER_BYTES = 2 + GCM_IV_BYTES

/**
 * [SecureStore] over `AndroidKeyStore` AES-GCM.
 *
 * **Deliberate limitation — a lock-screen credential change does not invalidate
 * this store's keys.** The keys are created *without*
 * `setUserAuthenticationRequired`, because the host must read the reclaim token
 * from a background turn and while the device is locked; an auth-bound key would
 * fail every such read until the user unlocks. The consequence is explicit:
 * [SecureLookup.Unreadable] appears when the Keystore entry is gone or unusable
 * (app-data restore, keystore reset/eviction, key deleted) or when the GCM tag
 * no longer verifies — **not** merely because the credential changed. Callers
 * must not assume a credential change is observable here. A product that
 * requires that semantics must create the key with
 * `setUserAuthenticationRequired(true)` and accept read failures while locked
 * (P3 reclaim-token availability matrix).
 *
 * @param context any context; only `noBackupFilesDir` and the system services
 *   are used, and the application context is retained.
 * @param log diagnostic sink; never receives key material or ciphertext. The
 *   default writes to logcat under [TAG].
 */
class AndroidSecureStore(
    context: Context,
    private val log: (String) -> Unit = { message -> Log.d(TAG, message) },
) : SecureStore {

    private val directory: File = File(context.applicationContext.noBackupFilesDir, STORE_DIR)
    private val keyStore: KeyStore? = openKeyStore()

    @Volatile
    private var reportedLevel: SecurityLevel = SecurityLevel.SOFTWARE

    init {
        // The probe runs once: it creates a real key so the level below is a
        // measurement of this device, not a guess from Build.MODEL.
        reportedLevel = probeLevel()
    }

    /**
     * The strongest protection a key on this device actually got.
     *
     * [SecurityLevel.STRONGBOX] only after a StrongBox-backed key was created;
     * [SecurityLevel.TEE] only when `KeyInfo.isInsideSecureHardware` is true;
     * [SecurityLevel.SOFTWARE] otherwise. A later downgrade during `put` (for
     * example a StrongBox key that no longer fits) lowers this value too: the
     * report follows the weakest key in use, never the intended one.
     */
    override val level: SecurityLevel
        get() = reportedLevel

    override suspend fun put(key: String, value: ByteArray): Unit = withContext(Dispatchers.IO) {
        require(key.isNotBlank()) { "key must not be blank" }
        val alias = aliasFor(key)
        val secret = ensureKey(alias)
        val payload = if (secret != null) {
            encrypt(FORMAT_KEYSTORE, secret, alias, value)
        } else {
            // AndroidKeyStore itself is unusable on this device. An
            // application-managed key in the app sandbox is the last rung of
            // the chain; it protects against a backup leak, not against code
            // running as this app, so the level stays SOFTWARE.
            reportedLevel = SecurityLevel.SOFTWARE
            encrypt(FORMAT_SOFTWARE, ensureSoftwareKey(), alias, value)
        }
        writeAtomically(entryFile(alias), payload)
    }

    override suspend fun get(key: String): SecureLookup = withContext(Dispatchers.IO) {
        val alias = aliasFor(key)
        val file = entryFile(alias)
        if (!file.isFile) return@withContext SecureLookup.Absent

        val payload = try {
            file.readBytes()
        } catch (failure: IOException) {
            log("secure-store: ciphertext read failed")
            return@withContext SecureLookup.Unreadable("ciphertext-unreadable")
        }
        if (payload.size <= HEADER_BYTES || payload[0] != VERSION_BYTE) {
            log("secure-store: ciphertext envelope is malformed")
            return@withContext SecureLookup.Unreadable("ciphertext-corrupt")
        }

        val secret = when (payload[1]) {
            FORMAT_KEYSTORE -> loadKey(alias)
                ?: return@withContext SecureLookup.Unreadable("key-invalidated")

            FORMAT_SOFTWARE -> loadSoftwareKey()
                ?: return@withContext SecureLookup.Unreadable("key-invalidated")

            else -> return@withContext SecureLookup.Unreadable("ciphertext-corrupt")
        }

        try {
            SecureLookup.Found(decrypt(secret, alias, payload))
        } catch (failure: KeyPermanentlyInvalidatedException) {
            // The user changed or removed the lock screen: the Keystore refuses
            // the key for good. Fail closed; do not mint a new token.
            log("secure-store: keystore key invalidated by a credential change")
            SecureLookup.Unreadable("key-invalidated")
        } catch (failure: AEADBadTagException) {
            log("secure-store: GCM tag did not verify")
            SecureLookup.Unreadable("key-invalidated")
        } catch (failure: GeneralSecurityException) {
            log("secure-store: ciphertext could not be decoded")
            SecureLookup.Unreadable("decode-failed")
        }
    }

    override suspend fun delete(key: String): Unit = withContext(Dispatchers.IO) {
        val alias = aliasFor(key)
        Files.deleteIfExists(entryFile(alias).toPath())
        try {
            keyStore?.deleteEntry(alias)
        } catch (failure: KeyStoreException) {
            log("secure-store: keystore entry could not be deleted")
        }
    }

    // ---- key management ---------------------------------------------------

    private fun openKeyStore(): KeyStore? = try {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    } catch (failure: Exception) {
        log("secure-store: AndroidKeyStore is unavailable")
        null
    }

    private fun probeLevel(): SecurityLevel {
        val store = keyStore ?: return SecurityLevel.SOFTWARE
        if (createProbeKey(store, strongBox = true)) {
            log("secure-store: StrongBox-backed key created")
            return SecurityLevel.STRONGBOX
        }
        log("secure-store: StrongBox unavailable; trying TEE")
        if (createProbeKey(store, strongBox = false)) {
            val hardware = isHardwareBacked(store, PROBE_ALIAS)
            log(
                if (hardware) {
                    "secure-store: TEE-backed key created"
                } else {
                    "secure-store: keystore key is not inside secure hardware"
                },
            )
            return if (hardware) SecurityLevel.TEE else SecurityLevel.SOFTWARE
        }
        log("secure-store: keystore cannot create keys; using an app-managed key")
        return SecurityLevel.SOFTWARE
    }

    private fun createProbeKey(store: KeyStore, strongBox: Boolean): Boolean = try {
        if (store.containsAlias(PROBE_ALIAS)) store.deleteEntry(PROBE_ALIAS)
        generateKey(PROBE_ALIAS, strongBox)
        true
    } catch (failure: Exception) {
        // StrongBoxUnavailableException, ProviderException, ... all mean the
        // same thing here: this rung of the chain is not available.
        false
    }

    private fun generateKey(alias: String, strongBox: Boolean): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(KEY_BYTES * 8)
            .setRandomizedEncryptionRequired(true)
            .apply { if (strongBox) setIsStrongBoxBacked(true) }
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun isHardwareBacked(store: KeyStore, alias: String): Boolean {
        return try {
            val key = store.getKey(alias, null) as? SecretKey
            if (key == null) {
                false
            } else {
                val factory = SecretKeyFactory.getInstance(key.algorithm, ANDROID_KEYSTORE)
                val info = factory.getKeySpec(key, KeyInfo::class.java) as KeyInfo
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // API 31 replaced the boolean with a three-value level; the
                    // boolean is deprecated there and reports the same fact.
                    info.securityLevel >= KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT
                } else {
                    @Suppress("DEPRECATION")
                    info.isInsideSecureHardware
                }
            }
        } catch (failure: Exception) {
            false
        }
    }

    /** The key for [alias], creating it if the entry is gone. */
    private fun ensureKey(alias: String): SecretKey? {
        val store = keyStore ?: return null
        loadKey(alias)?.let { return it }

        val preferStrongBox = reportedLevel == SecurityLevel.STRONGBOX
        return try {
            generateKey(alias, preferStrongBox)
        } catch (failure: Exception) {
            if (!preferStrongBox) {
                log("secure-store: keystore key creation failed; using an app-managed key")
                return null
            }
            log("secure-store: StrongBox key creation failed; retrying on TEE")
            try {
                val fallback = generateKey(alias, strongBox = false)
                reportedLevel =
                    if (isHardwareBacked(store, alias)) SecurityLevel.TEE else SecurityLevel.SOFTWARE
                fallback
            } catch (second: Exception) {
                log("secure-store: keystore key creation failed; using an app-managed key")
                null
            }
        }
    }

    private fun loadKey(alias: String): SecretKey? {
        val store = keyStore ?: return null
        return try {
            store.getKey(alias, null) as? SecretKey
        } catch (failure: UnrecoverableKeyException) {
            log("secure-store: keystore cannot unwrap the key")
            null
        } catch (failure: KeyStoreException) {
            log("secure-store: keystore read failed")
            null
        } catch (failure: NoSuchAlgorithmException) {
            log("secure-store: keystore algorithm is unavailable")
            null
        }
    }

    // ---- application-managed key (last rung) ------------------------------

    private fun softwareKeyFile(): File = File(directory, SOFTWARE_KEY_FILE)

    private fun loadSoftwareKey(): SecretKey? {
        val file = softwareKeyFile()
        if (!file.isFile) return null
        return try {
            val bytes = file.readBytes()
            if (bytes.size != KEY_BYTES) null else SecretKeySpec(bytes, "AES")
        } catch (failure: IOException) {
            log("secure-store: app-managed key is unreadable")
            null
        }
    }

    private fun ensureSoftwareKey(): SecretKey {
        loadSoftwareKey()?.let { return it }
        val bytes = ByteArray(KEY_BYTES).also { SecureRandom().nextBytes(it) }
        directory.mkdirs()
        val file = softwareKeyFile()
        FileOutputStream(file).use { out ->
            out.write(bytes)
            out.flush()
            out.fd.sync()
        }
        // Owner-only; the app sandbox is the real boundary.
        file.setReadable(false, false)
        file.setWritable(false, false)
        file.setReadable(true, true)
        file.setWritable(true, true)
        return SecretKeySpec(bytes, "AES")
    }

    // ---- envelope and file IO --------------------------------------------

    private fun encrypt(
        format: Byte,
        secret: SecretKey,
        alias: String,
        plaintext: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secret)
        // The alias is bound as AAD: a ciphertext moved to another key's file
        // no longer authenticates.
        cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        return ByteArray(2 + iv.size + ciphertext.size).also { payload ->
            payload[0] = VERSION_BYTE
            payload[1] = format
            iv.copyInto(payload, destinationOffset = 2)
            ciphertext.copyInto(payload, destinationOffset = 2 + iv.size)
        }
    }

    private fun decrypt(secret: SecretKey, alias: String, payload: ByteArray): ByteArray {
        val iv = payload.copyOfRange(2, 2 + GCM_IV_BYTES)
        val ciphertext = payload.copyOfRange(2 + GCM_IV_BYTES, payload.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(ciphertext)
    }

    private fun entryFile(alias: String): File = File(directory, "$alias.bin")

    private fun writeAtomically(file: File, payload: ByteArray) {
        directory.mkdirs()
        val temp = File(directory, "${file.name}.tmp")
        try {
            FileOutputStream(temp).use { out ->
                out.write(payload)
                out.flush()
                out.fd.sync()
            }
            Files.move(
                temp.toPath(),
                file.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (failure: IOException) {
            temp.delete()
            throw failure
        }
    }

    /**
     * The Keystore alias for a logical [key].
     *
     * Hashed so the Keystore alias list does not become a directory of the
     * names the host stores, and so an arbitrary key string is always a valid
     * alias.
     */
    private fun aliasFor(key: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(key.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString(separator = "") { value ->
            ((value.toInt() and 0xFF) + 0x100).toString(16).substring(1)
        }
        return ALIAS_PREFIX + hex
    }
}
