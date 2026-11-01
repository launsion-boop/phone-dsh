// The behavioural contract of DomainStore, shared by the host and device suites.
// SPDX-License-Identifier: MIT
//
// This file is compiled into both `test` (in-memory fake) and `androidTest`
// (real SQLite), and every case runs on both. That is the point: the JVM suite
// proves the quota/atomicity/timestamp logic, the instrumented suite proves the
// same contract against real SQLite through the same seam, so a fake that
// drifted from SQLite cannot make the host suite lie.

package com.phonedsh.domain

import com.phonedsh.platform.Clock
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cases every [DomainStore] must pass.
 *
 * Subclasses supply the [ConnectionFactory]: an in-memory one on the host, a
 * file-backed SQLite one on device. Opening twice through the same factory must
 * see the same data, and closing a store must not discard it.
 */
abstract class DomainStoreContract {
    /** The backing store; every test instance gets a fresh one. */
    protected abstract fun connectionFactory(): ConnectionFactory

    /** Opens a store over the shared backing store. */
    protected fun open(
        clock: Clock = FakeClock(1_000L),
        quotas: QuotaPolicy = QuotaPolicy.uniform(1L shl 20),
    ): DomainStore = DomainStoreCore(connectionFactory(), quotas, clock)

    @Test
    fun getReturnsNullForAnAbsentKey() {
        open().use { store ->
            assertNull(store.get(DomainNames.SESSION, "missing"))
        }
    }

    @Test
    fun theSameKeyIsIsolatedPerDomain() {
        open().use { store ->
            store.put(DomainNames.SESSION, "cursor", byteArrayOf(1))
            store.put(DomainNames.MEMORY, "cursor", byteArrayOf(2))

            assertArrayEquals(byteArrayOf(1), store.get(DomainNames.SESSION, "cursor"))
            assertArrayEquals(byteArrayOf(2), store.get(DomainNames.MEMORY, "cursor"))

            assertTrue(store.delete(DomainNames.SESSION, "cursor"))
            assertNull(store.get(DomainNames.SESSION, "cursor"))
            assertArrayEquals(byteArrayOf(2), store.get(DomainNames.MEMORY, "cursor"))

            assertEquals(emptyList<DomainEntry>(), store.list(DomainNames.SESSION, "", 10))
            assertEquals(1, store.list(DomainNames.MEMORY, "", 10).size)
        }
    }

    @Test
    fun aCommittedTransactionPublishesEveryWrite() {
        open().use { store ->
            val result = store.transaction {
                put(DomainNames.SESSION, "a", byteArrayOf(1))
                put(DomainNames.MEMORY, "b", byteArrayOf(2))
                "done"
            }

            assertEquals("done", result)
            assertArrayEquals(byteArrayOf(1), store.get(DomainNames.SESSION, "a"))
            assertArrayEquals(byteArrayOf(2), store.get(DomainNames.MEMORY, "b"))
        }
    }

    @Test
    fun aThrowingTransactionRollsBackEveryWrite() {
        open().use { store ->
            store.put(DomainNames.SESSION, "before", byteArrayOf(9))

            val failure = assertThrows(IllegalStateException::class.java) {
                store.transaction {
                    put(DomainNames.SESSION, "a", byteArrayOf(1))
                    put(DomainNames.MEMORY, "b", byteArrayOf(2))
                    delete(DomainNames.SESSION, "before")
                    assertEquals(1, get(DomainNames.SESSION, "a")!!.size)
                    throw IllegalStateException("boom")
                }
            }

            assertEquals("boom", failure.message)
            assertNull(store.get(DomainNames.SESSION, "a"))
            assertNull(store.get(DomainNames.MEMORY, "b"))
            assertArrayEquals(byteArrayOf(9), store.get(DomainNames.SESSION, "before"))
            assertEquals(1, store.usageBytes(DomainNames.SESSION))
            assertEquals(0, store.usageBytes(DomainNames.MEMORY))
        }
    }

    @Test
    fun transactionReadsSeeUncommittedWritesAndDeletes() {
        open().use { store ->
            store.put(DomainNames.TASK, "old", byteArrayOf(1))
            store.transaction {
                put(DomainNames.TASK, "new", byteArrayOf(2))
                delete(DomainNames.TASK, "old")

                assertArrayEquals(byteArrayOf(2), get(DomainNames.TASK, "new"))
                assertNull(get(DomainNames.TASK, "old"))
                assertEquals(listOf("new"), list(DomainNames.TASK, "", 10).map { it.key })
                assertEquals(1, usageBytes(DomainNames.TASK))
            }
        }
    }

    @Test
    fun nestedTransactionsAreRejected() {
        open().use { store ->
            assertThrows(IllegalStateException::class.java) {
                store.transaction {
                    store.transaction {
                        put(DomainNames.SESSION, "nested", byteArrayOf(1))
                    }
                }
            }
            assertNull(store.get(DomainNames.SESSION, "nested"))
        }
    }

    @Test
    fun listAppliesPrefixOrderAndLimit() {
        open().use { store ->
            listOf("alpine", "alpha", "alphabet", "beta").forEach { key ->
                store.put(DomainNames.TASK, key, key.toByteArray())
            }

            assertEquals(
                listOf("alpha", "alphabet", "alpine"),
                store.list(DomainNames.TASK, "alp", 10).map { it.key },
            )
            assertEquals(
                listOf("alpha", "alphabet"),
                store.list(DomainNames.TASK, "alpha", 10).map { it.key },
            )
            assertEquals(emptyList<DomainEntry>(), store.list(DomainNames.TASK, "zzz", 10))
            assertEquals(
                listOf("alpha", "alphabet"),
                store.list(DomainNames.TASK, "", 2).map { it.key },
            )
        }
    }

    @Test
    fun listUsesCodePointOrderNotUtf16Order() {
        open().use { store ->
            listOf("🙂", "🙂x", "🚀", "\uFFFF", "\uD800\uDC00").forEach { key ->
                store.put(DomainNames.TASK, key, byteArrayOf(1))
            }

            assertEquals(
                listOf("🙂", "🙂x"),
                store.list(DomainNames.TASK, "🙂", 10).map { it.key },
            )
            assertEquals(
                listOf("\uFFFF"),
                store.list(DomainNames.TASK, "\uFFFF", 10).map { it.key },
            )
            assertEquals(
                listOf("\uD800\uDC00"),
                store.list(DomainNames.TASK, "\uD800\uDC00", 10).map { it.key },
            )
        }
    }

    @Test
    fun listLimitMustBePositive() {
        open().use { store ->
            assertThrows(IllegalArgumentException::class.java) {
                store.list(DomainNames.TASK, "", 0)
            }
            assertThrows(IllegalArgumentException::class.java) {
                store.list(DomainNames.TASK, "", -1)
            }
        }
    }

    @Test
    fun quotaOverflowIsAnErrorAndWritesNothing() {
        open(quotas = QuotaPolicy.uniform(10L)).use { store ->
            store.put(DomainNames.MEMORY, "a", ByteArray(6))

            val failure = assertThrows(QuotaExceededException::class.java) {
                store.put(DomainNames.MEMORY, "b", ByteArray(6))
            }

            assertEquals(DomainNames.MEMORY, failure.domain)
            assertEquals(10L, failure.quotaBytes)
            assertEquals(6L, failure.usageBytes)
            assertEquals(6L, failure.incomingBytes)
            assertEquals(0L, failure.replacedBytes)
            assertNull(store.get(DomainNames.MEMORY, "b"))
            assertEquals(6L, store.usageBytes(DomainNames.MEMORY))
        }
    }

    @Test
    fun quotaCountsAReplacementByItsNewSizeOnly() {
        open(quotas = QuotaPolicy.uniform(10L)).use { store ->
            store.put(DomainNames.MEMORY, "a", ByteArray(6))

            store.put(DomainNames.MEMORY, "a", ByteArray(10))
            assertEquals(10L, store.usageBytes(DomainNames.MEMORY))

            val failure = assertThrows(QuotaExceededException::class.java) {
                store.put(DomainNames.MEMORY, "a", ByteArray(11))
            }
            assertEquals(10L, failure.usageBytes)
            assertEquals(11L, failure.incomingBytes)
            assertEquals(10L, failure.replacedBytes)
            assertEquals(10, store.get(DomainNames.MEMORY, "a")!!.size)
        }
    }

    @Test
    fun quotaIsAbsolutePerDomain() {
        open(quotas = QuotaPolicy.perDomain(mapOf(DomainNames.SESSION to 4L), defaultBytes = 8L))
            .use { store ->
                store.put(DomainNames.SESSION, "a", ByteArray(4))
                assertThrows(QuotaExceededException::class.java) {
                    store.put(DomainNames.SESSION, "b", ByteArray(1))
                }

                // A full `session` must not consume the `memory` budget.
                store.put(DomainNames.MEMORY, "a", ByteArray(8))
                assertEquals(4L, store.quotaBytes(DomainNames.SESSION))
                assertEquals(8L, store.quotaBytes(DomainNames.MEMORY))
            }
    }

    @Test
    fun aQuotaFailureRollsBackEarlierWritesOfTheSameTransaction() {
        open(quotas = QuotaPolicy.uniform(10L)).use { store ->
            assertThrows(QuotaExceededException::class.java) {
                store.transaction {
                    put(DomainNames.MEMORY, "a", ByteArray(6))
                    put(DomainNames.MEMORY, "b", ByteArray(6))
                }
            }

            assertNull(store.get(DomainNames.MEMORY, "a"))
            assertNull(store.get(DomainNames.MEMORY, "b"))
            assertEquals(0L, store.usageBytes(DomainNames.MEMORY))
        }
    }

    @Test
    fun theStoreStaysUsableAfterAFailedTransaction() {
        open(quotas = QuotaPolicy.uniform(10L)).use { store ->
            store.put(DomainNames.MEMORY, "a", ByteArray(6))
            assertThrows(QuotaExceededException::class.java) {
                store.transaction { put(DomainNames.MEMORY, "b", ByteArray(5)) }
            }

            store.put(DomainNames.MEMORY, "c", ByteArray(4))
            assertEquals(10L, store.usageBytes(DomainNames.MEMORY))
            assertNull(store.get(DomainNames.MEMORY, "b"))
        }
    }

    @Test
    fun usageBytesFollowsWritesAndDeletes() {
        open().use { store ->
            store.put(DomainNames.TASK, "a", ByteArray(3))
            store.put(DomainNames.TASK, "b", ByteArray(4))
            store.put(DomainNames.MEMORY, "a", ByteArray(5))

            assertEquals(7L, store.usageBytes(DomainNames.TASK))
            assertEquals(5L, store.usageBytes(DomainNames.MEMORY))

            store.delete(DomainNames.TASK, "a")
            assertEquals(4L, store.usageBytes(DomainNames.TASK))

            store.put(DomainNames.TASK, "b", ByteArray(1))
            assertEquals(1L, store.usageBytes(DomainNames.TASK))
        }
    }

    @Test
    fun deleteReportsWhetherARowExistedAndIsIdempotent() {
        open().use { store ->
            store.put(DomainNames.SESSION, "k", byteArrayOf(1))

            assertTrue(store.delete(DomainNames.SESSION, "k"))
            assertFalse(store.delete(DomainNames.SESSION, "k"))
        }
    }

    @Test
    fun anEmptyValueIsAStoredValueNotAnAbsentKey() {
        open().use { store ->
            store.put(DomainNames.TASK, "empty", ByteArray(0))

            assertArrayEquals(ByteArray(0), store.get(DomainNames.TASK, "empty"))
            assertEquals(1, store.list(DomainNames.TASK, "", 10).size)
            assertEquals(0L, store.usageBytes(DomainNames.TASK))
        }
    }

    @Test
    fun readsAndWritesCopyTheValueBytes() {
        open().use { store ->
            val written = byteArrayOf(1, 2, 3)
            store.put(DomainNames.TASK, "k", written)
            written[0] = 9

            val firstRead = store.get(DomainNames.TASK, "k")!!
            assertArrayEquals(byteArrayOf(1, 2, 3), firstRead)

            firstRead[1] = 9
            assertArrayEquals(byteArrayOf(1, 2, 3), store.get(DomainNames.TASK, "k"))
        }
    }

    @Test
    fun updatedAtIsStrictlyIncreasingEvenWhenTheClockMovesBackwards() {
        open(clock = FakeClock(1_000L, 500L, 1_000L)).use { store ->
            store.put(DomainNames.SESSION, "a", byteArrayOf(1))
            store.put(DomainNames.SESSION, "b", byteArrayOf(1))
            store.put(DomainNames.SESSION, "c", byteArrayOf(1))

            val stamps = store.list(DomainNames.SESSION, "", 10).associate { it.key to it.updatedAt }
            assertTrue(stamps.getValue("b") > stamps.getValue("a"))
            assertTrue(stamps.getValue("c") > stamps.getValue("b"))
        }
    }

    @Test
    fun updatedAtDoesNotRegressAfterAReopen() {
        open(clock = FakeClock(10_000L)).use { store ->
            store.put(DomainNames.TASK, "before", byteArrayOf(1))
        }

        open(clock = FakeClock(1_000L)).use { store ->
            store.put(DomainNames.TASK, "after", byteArrayOf(1))
            val stamps = store.list(DomainNames.TASK, "", 10).associate { it.key to it.updatedAt }
            assertTrue(stamps.getValue("after") > stamps.getValue("before"))
        }
    }

    @Test
    fun blankOrMalformedTextIsRejected() {
        open().use { store ->
            assertThrows(IllegalArgumentException::class.java) {
                store.put("", "k", byteArrayOf(1))
            }
            assertThrows(IllegalArgumentException::class.java) {
                store.put(DomainNames.SESSION, "", byteArrayOf(1))
            }
            assertThrows(IllegalArgumentException::class.java) {
                store.get(DomainNames.SESSION, "bad\u0000key")
            }
            assertThrows(IllegalArgumentException::class.java) {
                store.list(DomainNames.SESSION, "unpaired\uD800", 10)
            }
            assertThrows(IllegalArgumentException::class.java) {
                store.put("unpaired\uD800", "k", byteArrayOf(1))
            }
        }
    }

    @Test
    fun aClosedStoreRejectsFurtherOperations() {
        val store = open()
        store.close()
        store.close()

        assertThrows(IllegalStateException::class.java) {
            store.get(DomainNames.SESSION, "k")
        }
    }
}
