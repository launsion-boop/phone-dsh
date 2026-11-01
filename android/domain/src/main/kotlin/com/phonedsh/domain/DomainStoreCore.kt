// The backend-agnostic domain store: isolation, atomicity, quotas, timestamps.
// SPDX-License-Identifier: MIT
//
// Everything that makes the store a *contract* lives here and runs on a plain
// JVM: domain isolation, single-writer transactions, the quota accounting, the
// strict monotonic `updated_at` stamp and the prefix-range mapping. The only
// thing it does not decide is how bytes reach disk; that is the [Connection]
// seam, implemented by `SqliteConnection` on device and by
// `com.phonedsh.domain.testing.InMemoryConnection` on the host.
//
// `updated_at` is a *logical* stamp, not a calendar reading: `max(clock.now(),
// last + 1)`. A wall clock that jumps backwards (NTP, a user changing the date)
// must not produce two writes with the same or a decreasing stamp, or "the
// newest row" becomes ambiguous. The value is loaded from the store on first use
// so a restart continues above every row written before it.

package com.phonedsh.domain

import com.phonedsh.platform.Clock
import kotlin.math.max

/**
 * The [DomainStore] implementation above one [Connection].
 *
 * Construction is cheap and opens nothing: the connection is opened on first
 * use, so a composition root can create the store in `Application.onCreate`
 * without touching disk there.
 *
 * ### Serialisation
 *
 * One mutex (a monitor) serialises every operation, including the whole
 * [transaction] block. A SQLite connection has no nested-transaction story and
 * two interleaved transactions on one connection would silently mix their
 * writes; serialising at this layer makes the guarantee independent of the
 * backend. This is a single-writer store by design — the domain data is written
 * by the host, not by concurrent workers.
 *
 * @param connections the backing store seam.
 * @param quotas the absolute per-domain byte budget.
 * @param clock the wall clock used as the base of `updated_at`. Injecting it is
 *   what lets the host suite test clock jumps and restarts.
 */
class DomainStoreCore(
    private val connections: ConnectionFactory,
    private val quotas: QuotaPolicy,
    private val clock: Clock,
) : DomainStore {
    private val lock = Any()

    private var connection: Connection? = null
    private var closed = false
    private var transactionActive = false

    private var stampLoaded = false
    private var lastStamp = 0L

    override fun get(domain: String, key: String): ByteArray? = synchronized(lock) {
        requireDomain(domain)
        requireKey(key)
        inTransaction { sql -> sql.read(domain, key)?.value }
    }

    override fun put(domain: String, key: String, value: ByteArray) {
        transaction { this.put(domain, key, value) }
    }

    override fun delete(domain: String, key: String): Boolean {
        var existed = false
        transaction { existed = this.delete(domain, key) }
        return existed
    }

    override fun <T> transaction(block: DomainTransaction.() -> T): T = synchronized(lock) {
        inTransaction { sql -> TransactionView(sql).block() }
    }

    override fun list(domain: String, prefix: String, limit: Int): List<DomainEntry> = synchronized(lock) {
        requireDomain(domain)
        requirePrefix(prefix)
        requireLimit(limit)
        inTransaction { sql -> scanEntries(sql, domain, prefix, limit) }
    }

    override fun usageBytes(domain: String): Long = synchronized(lock) {
        requireDomain(domain)
        inTransaction { sql -> sql.usageBytes(domain) }
    }

    override fun quotaBytes(domain: String): Long = synchronized(lock) {
        check(!closed) { "domain store is closed" }
        requireDomain(domain)
        quotas.quotaBytes(domain)
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            connection?.close()
            connection = null
        }
    }

    /**
     * The transaction body shared by every public entry point.
     *
     * A failed transaction may consume a stamp, and the next committed write
     * simply jumps past it. Deliberately not "restored": if the backend commits
     * and then reports the failure (an error while ending the transaction), a
     * restore could hand the same stamp to the row that already exists. The gap
     * is invisible to callers, which compare `updated_at` for order only.
     */
    private fun <T> inTransaction(body: (Transaction) -> T): T {
        check(!closed) { "domain store is closed" }
        check(!transactionActive) { "nested transactions are not supported" }

        val connection = connection ?: connections.open().also { connection = it }
        transactionActive = true
        try {
            return connection.transaction(body)
        } finally {
            transactionActive = false
        }
    }

    private fun scanEntries(
        sql: Transaction,
        domain: String,
        prefix: String,
        limit: Int,
    ): List<DomainEntry> =
        sql.scan(domain, keyRangeForPrefix(prefix), limit).map { entry ->
            DomainEntry(entry.key, entry.value, entry.updatedAt)
        }

    /**
     * Allocates the stamp of the next write.
     *
     * Loaded lazily from the store so the first write after a restart already
     * exceeds every row written before it, even if the wall clock went back.
     */
    private fun nextStamp(sql: Transaction): Long {
        if (!stampLoaded) {
            lastStamp = sql.latestUpdatedAt()
            stampLoaded = true
        }
        val wallClock = clock.nowMillis()
        val next = if (lastStamp == Long.MAX_VALUE) Long.MAX_VALUE else max(wallClock, lastStamp + 1L)
        lastStamp = next
        return next
    }

    /**
     * The receiver bound to one backend transaction.
     *
     * Every write checks the *whole* resulting domain usage before it reaches the
     * backend, so an over-quota transaction fails on the offending write and the
     * connection rolls back all previous writes of the block.
     */
    private inner class TransactionView(
        private val sql: Transaction,
    ) : DomainTransaction {
        override fun get(domain: String, key: String): ByteArray? {
            requireDomain(domain)
            requireKey(key)
            return sql.read(domain, key)?.value
        }

        override fun put(domain: String, key: String, value: ByteArray) {
            requireDomain(domain)
            requireKey(key)

            val quota = quotas.quotaBytes(domain)
            require(quota > 0L) { "the quota of domain \"$domain\" must be positive, was $quota" }

            val existing = sql.read(domain, key)
            val replaced = existing?.value?.size?.toLong() ?: 0L
            val usage = sql.usageBytes(domain)
            val incoming = value.size.toLong()
            val attempted = usage - replaced + incoming
            if (attempted > quota) {
                throw QuotaExceededException(
                    domain = domain,
                    quotaBytes = quota,
                    usageBytes = usage,
                    incomingBytes = incoming,
                    replacedBytes = replaced,
                )
            }
            sql.write(domain, key, value, nextStamp(sql))
        }

        override fun delete(domain: String, key: String): Boolean {
            requireDomain(domain)
            requireKey(key)
            return sql.delete(domain, key)
        }

        override fun list(domain: String, prefix: String, limit: Int): List<DomainEntry> {
            requireDomain(domain)
            requirePrefix(prefix)
            requireLimit(limit)
            return scanEntries(sql, domain, prefix, limit)
        }

        override fun usageBytes(domain: String): Long {
            requireDomain(domain)
            return sql.usageBytes(domain)
        }
    }
}
