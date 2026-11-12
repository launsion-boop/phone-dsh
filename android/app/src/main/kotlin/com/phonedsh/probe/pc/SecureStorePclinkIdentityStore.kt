// SPDX-License-Identifier: MIT
// The Android implementation of `PclinkIdentityStore` (design §5.1).
//
// The raw 32-byte Ed25519 seed is not written as a file of its own: it goes
// through the existing `:platform` `SecureStore`, which wraps it with an
// AndroidKeyStore AES-GCM key under `noBackupFilesDir` (the same envelope the
// model key and reclaim token use). minSdk 26 has no Ed25519 KeyStore type, so
// the seed itself is software key material and the measured `SecurityLevel` is
// the honest strength, not an Ed25519 hardware claim.
//
// Unreadable is not absent. `PclinkClient` must not generate a new seed when a
// record exists, so a locked/invalidated Keystore entry raises
// `PclinkError.Storage("identityUnreadable")` and the pair record stays
// inspectable. A KeyStore failure that leaves no entry is `Absent`, which lets
// a first-run install create its identity.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkIdentityStore
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import kotlinx.coroutines.runBlocking

/**
 * `pclink.identity-v1` over a [SecureStore].
 *
 * The three [PclinkIdentityStore] methods are synchronous because C2's
 * interface is; each one blocks on the small encrypted read/write exactly as
 * `ApiKeyStore` does. No method logs and [loadSeed] never echoes bytes.
 */
internal class SecureStorePclinkIdentityStore(
    private val store: SecureStore,
) : PclinkIdentityStore {

    /** `null` means the store was read and holds no seed. */
    override fun loadSeed(): ByteArray? {
        val lookup = try {
            runBlocking { store.get(KEY) }
        } catch (failure: Exception) {
            throw PclinkError.Storage(IDENTITY_UNREADABLE)
        }
        return when (lookup) {
            is SecureLookup.Found -> {
                if (lookup.value.size != SEED_BYTES) {
                    // A truncated/oversized value is an unreadable identity, not
                    // a fresh install: generating over it would pair again.
                    throw PclinkError.Storage(IDENTITY_UNREADABLE)
                }
                lookup.value.copyOf()
            }
            SecureLookup.Absent -> null
            is SecureLookup.Unreadable -> throw PclinkError.Storage(IDENTITY_UNREADABLE)
        }
    }

    override fun saveSeed(seed: ByteArray) {
        require(seed.size == SEED_BYTES) { "identity seed must be $SEED_BYTES bytes" }
        try {
            runBlocking { store.put(KEY, seed.copyOf()) }
        } catch (failure: Exception) {
            throw PclinkError.Storage("cannot store the phone identity")
        }
    }

    override fun deleteSeed() {
        try {
            runBlocking { store.delete(KEY) }
        } catch (failure: Exception) {
            throw PclinkError.Storage("cannot delete the phone identity")
        }
    }

    companion object {
        /** The design's frozen account name under `SecureStore`. */
        const val KEY: String = "pclink.identity-v1"

        /** The display-safe label C5 reports for an unreadable seed (PC-ANDROID §2.1.2). */
        const val IDENTITY_UNREADABLE: String = "identityUnreadable"

        const val SEED_BYTES: Int = 32
    }
}
