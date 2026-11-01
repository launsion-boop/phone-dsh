// The one seam between the store's typed logic and a SQLite-shaped backend.
// SPDX-License-Identifier: MIT
//
// Why not expose `prepare(sql)` / `step()` like SupportSQLiteDatabase? A fake at
// that level would have to re-implement SQLite (transaction visibility, PRIMARY
// KEY conflicts, prefix ranges, SUM) for the JVM suite to mean anything, and a
// test that runs against a hand-written SQL engine proves the fake, not the
// store. The seam is therefore the *typed statement set* the store actually
// issues; SQL and `android.database.*` stay in `SqliteConnection.kt`. The JVM
// suite pins the contract of this interface with an in-memory implementation;
// the instrumented suite runs the same behavioural cases on real SQLite, which
// is what proves the SQL and the seam agree.
//
// `ConnectionFactory` is the module's injectable seam: production passes
// `SqliteConnectionFactory`, host tests pass `InMemoryConnectionFactory`.

package com.phonedsh.domain

import java.io.Closeable

/**
 * Opens the backing store.
 *
 * A functional interface so a host test can write
 * `ConnectionFactory { connection }`. Opening is allowed to be lazy; the store
 * calls it on first use and closes the result exactly once.
 */
fun interface ConnectionFactory {
    fun open(): Connection
}

/**
 * One backend connection and its transaction primitive.
 *
 * Implementations must make [transaction] atomic: either every write issued
 * through the supplied [Transaction] is committed, or none is. A throw from the
 * body rolls back and is rethrown unchanged.
 */
interface Connection : Closeable {
    /**
     * Runs [body] in one backend transaction.
     *
     * Reads issued through [Transaction] inside the body see the writes of the
     * same transaction, matching the store's documented transaction semantics.
     */
    fun <T> transaction(body: (Transaction) -> T): T

    /** Releases the connection and any statements it prepared. Idempotent. */
    override fun close()
}

/**
 * The typed statements a [Connection] must provide inside a transaction.
 *
 * Every method is scoped to [DomainStore]'s semantics, so no SQL leaks through
 * this interface. Implementations must not commit, roll back or nest
 * transactions: the surrounding [Connection.transaction] owns that.
 */
interface Transaction {
    /** The row stored under ([domain], [key]), or `null`. */
    fun read(domain: String, key: String): StoredEntry?

    /** Inserts or replaces ([domain], [key]) with [value] and [updatedAt]. */
    fun write(domain: String, key: String, value: ByteArray, updatedAt: Long)

    /** Removes ([domain], [key]); returns whether a row existed. */
    fun delete(domain: String, key: String): Boolean

    /**
     * Rows of [domain] whose key lies in [keyRange], at most [limit], ordered by
     * key in UTF-8 byte order (SQLite's BINARY collation).
     *
     * [keyRange] is already the exact half-open prefix range; implementations
     * apply it as a range predicate and do not re-derive the prefix.
     */
    fun scan(domain: String, keyRange: KeyRange, limit: Int): List<StoredEntry>

    /** `SUM(LENGTH(value))` of [domain], or 0 when the domain is empty. */
    fun usageBytes(domain: String): Long

    /** The highest `updated_at` in the whole store, or 0 when it is empty. */
    fun latestUpdatedAt(): Long
}

/**
 * One row as the backend sees it.
 *
 * [value] is a defensive copy owned by the caller; implementations must not hand
 * out a buffer that a later write can mutate.
 */
class StoredEntry(
    val key: String,
    val value: ByteArray,
    val updatedAt: Long,
)
