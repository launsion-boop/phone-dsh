// The domain store: byte-valued domains, atomic transactions, absolute quotas.
// SPDX-License-Identifier: MIT
//
// P6 owns the persistence behind the PRD's "one local DomainStore"
// (docs/design/phone-dsh-app/PRD.md:169): session state, memory records, task
// references and their revisions outlive a process start, while the DSH
// workspace stays an execution scratch area and is never used as the long-term
// memory database.
//
// This store is deliberately NOT the host WAL. Domain data never enters the WAL,
// never gets an ack level and carries no power-loss promise: `wal.md` §5.2 and
// the D18 fsync order do not apply here. SQLite's own transaction supplies
// atomicity and crash recovery of the file; the host promises nothing above that
// (the K3 brief: "不做 DomainStore 的 WAL/掉电语义").
//
// Quotas follow spec/v1/budgets.md §5 as a *rule*, not as a number: a quota is
// absolute, data is never silently dropped, and a write that would cross it
// fails. §5 has no DomainStore row (it budgets WAL segments, the response log,
// the journal and `video/`), so the byte value is injected policy
// ([QuotaPolicy]) and not a spec constant.

package com.phonedsh.domain

import java.io.Closeable

/**
 * The domain-data contract of the PDSH platform layer.
 *
 * A domain is an isolated key space (`session`, `memory`, `task`, ...). The same
 * key may exist once per domain and deleting it in one domain never touches
 * another. Values are opaque bytes: the store does not decode them, know their
 * schema, or migrate them.
 *
 * ### Threading
 *
 * Every call is synchronous and may touch disk. Callers must not run them on the
 * Android main thread. Implementations are safe for concurrent callers; this
 * module's implementation serialises all work on one connection instead of
 * hoping SQLite's per-statement locking composes into transaction isolation.
 *
 * ### Failure model
 *
 * A write either lands completely or not at all. A quota violation is an
 * explicit [QuotaExceededException] and leaves the store unchanged; it is never
 * reported as success and never silently truncates or evicts older data.
 */
interface DomainStore : Closeable {
    /**
     * Returns the value stored under [key] in [domain], or `null` when absent.
     *
     * @throws IllegalArgumentException when [domain] or [key] is blank, contains
     *   NUL, or is not well-formed UTF-16.
     * @throws IllegalStateException when the store is closed.
     */
    fun get(domain: String, key: String): ByteArray?

    /**
     * Stores [value] under [key] in [domain], replacing any previous value.
     *
     * A single put is its own transaction. When the write would push the domain
     * past [quotaBytes], [QuotaExceededException] is thrown and the write is not
     * applied (the implicit transaction rolls back).
     */
    fun put(domain: String, key: String, value: ByteArray)

    /**
     * Removes [key] from [domain].
     *
     * @return `true` when a row existed, `false` when the key was already absent.
     */
    fun delete(domain: String, key: String): Boolean

    /**
     * Runs [block] as one atomic transaction and returns its result.
     *
     * Writes made through the receiver are visible to its reads and list calls
     * immediately. Returning commits; throwing (including
     * [QuotaExceededException]) rolls back every write of the block, in every
     * domain, and rethrows.
     *
     * Transactions are not re-entrant: calling this method again while one is
     * active throws [IllegalStateException] and the outer transaction rolls
     * back.
     */
    fun <T> transaction(block: DomainTransaction.() -> T): T

    /**
     * Lists the entries of [domain] whose key starts with [prefix].
     *
     * The order is the key order of the backing store — SQLite's BINARY
     * collation, that is UTF-8 byte order, which equals code-point order for
     * well-formed strings — so paging with [limit] is stable as long as the
     * domain is not written concurrently.
     *
     * @param limit the maximum number of entries; must be greater than zero.
     *   There is no implicit default: a silent cap would look like "the domain
     *   has fewer rows".
     */
    fun list(domain: String, prefix: String, limit: Int): List<DomainEntry>

    /**
     * The sum of the stored value lengths of [domain], in bytes.
     *
     * Keys and row overhead are not counted: the quota budgets the opaque value
     * bytes the product actually stores.
     */
    fun usageBytes(domain: String): Long

    /** The absolute byte quota of [domain], as configured by [QuotaPolicy]. */
    fun quotaBytes(domain: String): Long

    /**
     * Releases the connection. Idempotent; further operations throw
     * [IllegalStateException].
     */
    override fun close()
}

/**
 * The write/read surface of one [DomainStore.transaction].
 *
 * The receiver is domain-aware, so one transaction may atomically update a
 * session row and a task row. It is not a [DomainStore]: it has no quota policy
 * of its own and no transaction method.
 */
interface DomainTransaction {
    /** See [DomainStore.get]. Reads include writes made earlier in this transaction. */
    fun get(domain: String, key: String): ByteArray?

    /** See [DomainStore.put]. The quota check happens at this call. */
    fun put(domain: String, key: String, value: ByteArray)

    /** See [DomainStore.delete]. */
    fun delete(domain: String, key: String): Boolean

    /** See [DomainStore.list]; includes writes made earlier in this transaction. */
    fun list(domain: String, prefix: String, limit: Int): List<DomainEntry>

    /** See [DomainStore.usageBytes]; includes writes made earlier in this transaction. */
    fun usageBytes(domain: String): Long
}

/**
 * One listed row.
 *
 * [value] is a fresh copy on every read; mutating it never changes the store.
 * Equality compares the bytes by content, so assertions and callers are not
 * tripped up by [ByteArray]'s reference equality.
 *
 * [updatedAt] is the write's monotonic stamp in milliseconds (see
 * [DomainStoreCore]); it orders writes and is not a calendar reading.
 */
class DomainEntry(
    val key: String,
    val value: ByteArray,
    val updatedAt: Long,
) {
    override fun equals(other: Any?): Boolean =
        other is DomainEntry &&
            key == other.key &&
            updatedAt == other.updatedAt &&
            value.contentEquals(other.value)

    override fun hashCode(): Int {
        var result = key.hashCode()
        result = 31 * result + value.contentHashCode()
        result = 31 * result + updatedAt.hashCode()
        return result
    }

    override fun toString(): String =
        "DomainEntry(key=$key, bytes=${value.size}, updatedAt=$updatedAt)"
}

/**
 * The domain names the product uses today.
 *
 * The set is open on purpose: a domain is just a namespace string, and the store
 * does not enumerate or validate against this list. These constants exist so
 * call sites do not scatter string literals.
 */
object DomainNames {
    /** Conversation/session state that must survive a process start. */
    const val SESSION = "session"

    /** Memory records and their candidate/active/rejected revisions. */
    const val MEMORY = "memory"

    /** Task references and their user-visible state. */
    const val TASK = "task"
}
