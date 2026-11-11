// SPDX-License-Identifier: MIT
// PCLink phone identity (§2.2). Only the interface lives in `:pclink`: the
// Android implementation needs AndroidKeyStore and therefore belongs to `:app`
// (the design's deliberate difference from the Swift Keychain store).
package com.phonedsh.pclink

/** One long-lived Ed25519 identity. `toString` never prints the seed. */
class PclinkIdentity(seed: ByteArray) {
    val seed: ByteArray
    val publicKey: ByteArray
    val machineId: String

    init {
        if (seed.size != 32) {
            throw PclinkError.BadFrame("identity seed must be 32 bytes, got ${seed.size}")
        }
        this.seed = seed.copyOf()
        this.publicKey = PclinkCrypto.ed25519PublicKey(this.seed)
        this.machineId = PclinkBase32.machineId(this.publicKey)
    }

    /** `machineId[0:12]` displayed as `xxxx-xxxx-xxxx`. */
    val fingerprint: String get() = PclinkValidation.fingerprint(machineId)

    fun sign(message: ByteArray): ByteArray = PclinkCrypto.ed25519Sign(seed, message)

    override fun toString(): String = "PclinkIdentity(machineId=$machineId)"

    companion object {
        fun generate(): PclinkIdentity = PclinkIdentity(PclinkRandom.bytes(32))
    }
}

/**
 * Phone identity seed persistence (`pclink.identity-v1`). The Android adapter is
 * `:app`'s `SecureStorePclinkIdentityStore`; an unreadable value must be
 * fail-closed and never treated as absent (PC-ANDROID §2.1.2).
 */
interface PclinkIdentityStore {
    fun loadSeed(): ByteArray?
    fun saveSeed(seed: ByteArray)
    fun deleteSeed()
}
