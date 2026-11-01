// Secret storage with an honest security level.
// SPDX-License-Identifier: MIT
//
// The iOS baseline stores credentials and the handoff reclaim token through
// Keychain (spec/v1/handoff.md §5). Android has no SecItem; the Keystore-backed
// implementation lives in the Android adapter, while this SPI keeps the rule
// that the token never reaches the Worker and never hits a plaintext file
// (plan §15-6). The security level is reported, not assumed: StrongBox is
// optional hardware and lock-screen changes can invalidate a Keystore key
// (plan §7.3, §15-5, §11-R11).

package com.phonedsh.platform

/**
 * The result of a [SecureStore.get] lookup.
 *
 * [Absent] and [Unreadable] are different outcomes on purpose: a missing key may
 * be created, while a key that exists but can no longer be read (for example
 * after a lock-screen change invalidated the Keystore entry) must fail closed
 * and must never be treated as "no token" (plan §11-R11, P3 reclaim-token
 * availability matrix).
 */
sealed interface SecureLookup {
    /** The key exists and its bytes were read. */
    data class Found(val value: ByteArray) : SecureLookup

    /** The key does not exist. */
    data object Absent : SecureLookup

    /**
     * The key exists but cannot be read.
     *
     * [reason] is safe to show and to log (for example `"key-invalidated"`); it
     * must never contain key material, ciphertext or an exception stack. The
     * constructor rejects blank and multi-line values so a stack trace cannot be
     * smuggled into a user-visible string.
     */
    data class Unreadable(val reason: String) : SecureLookup {
        init {
            require(reason.isNotBlank()) { "reason must be a non-empty display-safe label" }
            require(reason.none { it.isISOControl() }) {
                "reason must be a single display-safe line"
            }
        }
    }
}

/**
 * Key/value storage for host-side secrets.
 *
 * Values are opaque bytes: the SPI does not know whether they are a raw token,
 * a JWK or an encrypted envelope. Implementations must not persist plaintext,
 * and [delete] is idempotent.
 */
interface SecureStore {
    /** The strongest protection this device currently provides. */
    val level: SecurityLevel

    /**
     * Stores [value] under [key], replacing any previous value.
     *
     * @throws java.io.IOException when the backing store cannot be written.
     */
    suspend fun put(key: String, value: ByteArray)

    /**
     * Looks [key] up.
     *
     * [SecureLookup.Unreadable] is a fail-closed signal: the caller must not
     * treat it as [SecureLookup.Absent] and must not silently re-create a
     * token. A `null`-style "not found" answer was deliberately replaced by
     * this three-state result.
     */
    suspend fun get(key: String): SecureLookup

    /** Removes [key]; succeeds when the key is already absent. */
    suspend fun delete(key: String)
}

/**
 * The three-level downgrade chain of plan §7.3 / §15-5.
 *
 * Ordered strongest to weakest. The level is a fact to display in the UI, not
 * a promise that the chain will always reach the strongest level.
 */
enum class SecurityLevel {
    /** Hardware-isolated secure element backing the key. */
    STRONGBOX,

    /** Trusted execution environment backing the key. */
    TEE,

    /** No hardware-backed key; software protection only. */
    SOFTWARE,
}
