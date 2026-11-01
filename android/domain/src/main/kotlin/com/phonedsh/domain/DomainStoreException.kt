// The explicit failures of the domain store: quota overflow and storage errors.
// SPDX-License-Identifier: MIT
//
// spec/v1/budgets.md §5 states the rule this file implements: "data is never
// silently dropped" and an over-quota store fails instead of evicting. The
// numbers in that table belong to other stores (WAL, response log, journal,
// video/); the DomainStore quota is injected policy, so the exception carries
// the numbers it actually used instead of pointing at a spec row that does not
// exist.

package com.phonedsh.domain

/**
 * Base class for the failures the store itself declares.
 *
 * Today the only subclass is [QuotaExceededException]. This is deliberately not
 * a wrapper for backend failures: the user block's own exceptions and the
 * backend's exceptions propagate unchanged, because a transaction may throw
 * anything and rewriting it would hide the cause. A caller that must stay
 * backend-agnostic catches this type for declared failures and treats any other
 * throwable as a storage fault.
 */
open class DomainStoreException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * A write that would cross the domain's absolute byte quota.
 *
 * The offending write is not applied. A transaction that does not catch the
 * exception rolls back every earlier write of the block; a caller that catches
 * it inside the block may still commit the writes made before it, because that
 * is ordinary transaction semantics — the store refuses the write, it does not
 * abort a transaction behind the caller's back.
 *
 * The numbers are the state at the moment of the check:
 *
 * @property domain the domain whose quota was hit.
 * @property quotaBytes the absolute quota ([DomainStore.quotaBytes]).
 * @property usageBytes the bytes already stored in [domain] (including earlier
 *   writes of the same transaction — they are rolled back with it when the
 *   exception escapes the block).
 * @property incomingBytes the length of the value that was being written.
 * @property replacedBytes the length of the value it would have replaced, or 0
 *   for a new key. The attempted total is
 *   `usageBytes - replacedBytes + incomingBytes`.
 */
class QuotaExceededException(
    val domain: String,
    val quotaBytes: Long,
    val usageBytes: Long,
    val incomingBytes: Long,
    val replacedBytes: Long,
) : DomainStoreException(
    "domain \"$domain\" would exceed its $quotaBytes-byte quota: " +
        "$usageBytes bytes stored, writing $incomingBytes bytes " +
        "(replacing $replacedBytes); the write was refused",
)
