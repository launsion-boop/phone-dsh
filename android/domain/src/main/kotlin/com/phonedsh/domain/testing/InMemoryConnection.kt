// The host-side test double for the domain store seam.
// SPDX-License-Identifier: MIT
//
// This class is in src/main on purpose, mirroring
// `com.phonedsh.platform.testing.FakePlatform`: upper layers (`:dsh`, `:app`,
// future P6 consumers) must be able to test domain-store behaviour without a
// device, and the module has no test-fixtures source set. It is a test double,
// not a production backend: the device path is `SqliteConnectionFactory`, and
// the instrumented suite runs the same behavioural contract against it.
//
// The fake implements the seam the way SQLite does, not more: a transaction is
// copy-on-write so a throw discards every write; values are copied in and out so
// callers cannot mutate stored bytes; scans apply the half-open [KeyRange] and
// order by UTF-8 bytes, which is SQLite's BINARY collation.

package com.phonedsh.domain.testing

import com.phonedsh.domain.Connection
import com.phonedsh.domain.ConnectionFactory
import com.phonedsh.domain.KeyRange
import com.phonedsh.domain.StoredEntry
import com.phonedsh.domain.Transaction

/**
 * A [ConnectionFactory] over one in-memory database.
 *
 * Closing a store closes its [Connection], but the fake keeps the data: opening
 * again through the same factory models a process restart over the same file,
 * which is what the `updated_at`-survives-reopen case needs.
 */
class InMemoryConnectionFactory : ConnectionFactory {
    private val connection = InMemoryConnection()

    override fun open(): Connection = connection
}

/** An in-memory [Connection] with copy-on-write transactions. */
class InMemoryConnection : Connection {
    private var data: Map<String, Map<String, StoredEntry>> = emptyMap()

    override fun <T> transaction(body: (Transaction) -> T): T {
        val working = copyOf(data)
        val result = body(InMemoryTransaction(working))
        data = working
        return result
    }

    /** No resources to release; the data survives a close so reopen is testable. */
    override fun close() = Unit

    private fun copyOf(
        source: Map<String, Map<String, StoredEntry>>,
    ): MutableMap<String, MutableMap<String, StoredEntry>> {
        val copy = LinkedHashMap<String, MutableMap<String, StoredEntry>>(source.size)
        source.forEach { (domain, entries) ->
            val domainCopy = LinkedHashMap<String, StoredEntry>(entries.size)
            entries.forEach { (key, entry) ->
                domainCopy[key] = StoredEntry(key, entry.value.copyOf(), entry.updatedAt)
            }
            copy[domain] = domainCopy
        }
        return copy
    }

    private class InMemoryTransaction(
        private val data: MutableMap<String, MutableMap<String, StoredEntry>>,
    ) : Transaction {
        override fun read(domain: String, key: String): StoredEntry? {
            val entry = data[domain]?.get(key) ?: return null
            return StoredEntry(entry.key, entry.value.copyOf(), entry.updatedAt)
        }

        override fun write(domain: String, key: String, value: ByteArray, updatedAt: Long) {
            val entries = data.getOrPut(domain) { LinkedHashMap() }
            entries[key] = StoredEntry(key, value.copyOf(), updatedAt)
        }

        override fun delete(domain: String, key: String): Boolean {
            val entries = data[domain] ?: return false
            val removed = entries.remove(key) != null
            if (entries.isEmpty()) data.remove(domain)
            return removed
        }

        override fun scan(domain: String, keyRange: KeyRange, limit: Int): List<StoredEntry> {
            val entries = data[domain] ?: return emptyList()
            val upper = keyRange.upper
            return entries.values
                .asSequence()
                .filter { entry ->
                    compareUtf8(entry.key, keyRange.lower) >= 0 &&
                        (upper == null || compareUtf8(entry.key, upper) < 0)
                }
                .sortedWith { left, right -> compareUtf8(left.key, right.key) }
                .take(limit)
                .map { entry -> StoredEntry(entry.key, entry.value.copyOf(), entry.updatedAt) }
                .toList()
        }

        override fun usageBytes(domain: String): Long =
            data[domain]?.values?.sumOf { it.value.size.toLong() } ?: 0L

        override fun latestUpdatedAt(): Long =
            data.values.asSequence()
                .flatMap { it.values.asSequence() }
                .maxOfOrNull { it.updatedAt }
                ?: 0L
    }

    private companion object {
        /** Lexicographic UTF-8 byte order, the collation SQLite's BINARY uses. */
        fun compareUtf8(left: String, right: String): Int {
            val a = left.toByteArray(Charsets.UTF_8)
            val b = right.toByteArray(Charsets.UTF_8)
            val common = minOf(a.size, b.size)
            for (index in 0 until common) {
                val difference = (a[index].toInt() and 0xFF) - (b[index].toInt() and 0xFF)
                if (difference != 0) return difference
            }
            return a.size - b.size
        }
    }
}
