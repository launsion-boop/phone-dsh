// phone-dsh — :dsh unit test: the durable journal store.
// SPDX-License-Identifier: MIT
//
// These tests use real files in a temporary directory. The quota tests lower the
// limit (as `WalQuota` allows for its 512 MiB) so they reach pruning and the
// fail-loud branch without writing 64 MiB; the default constant itself is
// asserted against budgets.md §5. The durability sequence is observed through
// `RecordingDurability`, never through a sleep or a mock clock.

package com.phonedsh.dsh.journal

import java.nio.file.Files
import java.nio.file.StandardOpenOption
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalStoreTest {
    @Test
    fun aRecordSurvivesAReopenAndRecoveryReportsItsJseq() {
        withJournalRoot { root ->
            val first = newJournalStore(RecordingDurability(mutableListOf()), root)
            val record = journalRecord(type = "dispatched", stepId = "1")
            runBlocking {
                assertTrue(first.recover().highestJseq.isEmpty())
                first.append("sess_01", 1L, record)
                first.append("sess_01", 2L, journalRecord(type = "completed", stepId = "1"))
            }

            // A different store over the same directory: the only way the record
            // can come back is the disk bytes, not an in-memory counter.
            val reopened = newJournalStore(RecordingDurability(mutableListOf()), root)
            runBlocking {
                val recovery = reopened.recover()
                assertEquals(2L, recovery.highestJseq["sess_01"])
                assertTrue(recovery.truncatedTails.isEmpty())
                val records = reopened.records("sess_01")
                assertEquals(listOf(1L, 2L), records.map { it.jseq })
                assertArrayEquals(record, records[0].record)
            }
        }
    }

    @Test
    fun theDefaultQuotaIsTheSixtyFourMiBJournalRow() {
        assertEquals(64L * 1024L * 1024L, JournalStore.DEFAULT_LIMIT_BYTES)
    }

    @Test
    fun aTornTailIsTruncatedAndTheDurableRecordsRemain() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val store = newJournalStore(durability, root)
            val record = journalRecord()
            runBlocking {
                store.recover()
                store.append("sess_01", 1L, record)
            }

            // A kill mid-append leaves fewer than a record prefix. It was never
            // acknowledged, so recovery drops it and keeps record 1.
            val file = JournalPaths(root).sessionFile("sess_01")
            Files.write(
                file,
                byteArrayOf(0, 0, 0, 99, 1, 2, 3),
                StandardOpenOption.APPEND,
            )
            val reopened = newJournalStore(durability, root)
            runBlocking {
                val recovery = reopened.recover()
                assertEquals(1, recovery.truncatedTails.size)
                assertEquals(1L, recovery.highestJseq["sess_01"])
                assertEquals(listOf(1L), reopened.records("sess_01").map { it.jseq })
            }
            // Header (8 + session id + 8) plus one complete record, nothing else.
            val headerBytes = 8L + "sess_01".toByteArray(Charsets.UTF_8).size + 8L
            assertEquals(headerBytes + 16L + record.size, Files.size(file))
        }
    }

    @Test
    fun aCorruptRecordInTheMiddleIsRefusedInsteadOfTruncated() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val store = newJournalStore(durability, root)
            runBlocking {
                store.recover()
                store.append("sess_01", 1L, journalRecord())
                store.append("sess_01", 2L, journalRecord(type = "completed"))
            }

            // Flip one byte of the first record's payload. It is followed by a
            // second, complete record, so this is corruption, not a torn tail:
            // fail loud and keep every byte.
            val file = JournalPaths(root).sessionFile("sess_01")
            val bytes = Files.readAllBytes(file)
            val firstPayload = (8 + "sess_01".toByteArray(Charsets.UTF_8).size + 8) + 16
            bytes[firstPayload] = (bytes[firstPayload].toInt() xor 0xFF).toByte()
            Files.write(file, bytes, StandardOpenOption.TRUNCATE_EXISTING)

            val reopened = newJournalStore(durability, root)
            val error = runBlocking {
                try {
                    reopened.recover()
                    null
                } catch (failure: JournalException) {
                    failure
                }
            }
            assertNotNull(error)
            assertEquals("JOURNAL_CORRUPT", error!!.failure.code)
            assertNull(error.wireCode)
        }
    }

    @Test
    fun theQuotaPrunesOnlyJournaledAndDurableSteps() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val setup = newJournalStore(durability, root)
            runBlocking {
                setup.recover()
                // One complete step (dispatched + completed): journaled.
                setup.append("sess_01", 1L, journalRecord(type = "dispatched", stepId = "1"))
                setup.append("sess_01", 2L, journalRecord(type = "completed", stepId = "1"))
                // One dangling step (dispatched, never completed): NOT prunable.
                setup.append("sess_02", 1L, journalRecord(type = "dispatched", stepId = "2"))
            }
            val used = setup.usedBytes()

            // The next record alone does not fit; set the quota one byte below
            // "used + the record", so pruning must free at least that byte.
            val big = journalRecord(type = "dispatched", stepId = "3", padding = 400)
            val reserve = 16L + big.size
            val limited = newJournalStore(durability, root, limit = used + reserve - 1L)
            runBlocking {
                limited.recover()
                limited.append("sess_02", 2L, big)
            }

            val retained = runBlocking {
                limited.records("sess_01").map { it.jseq } to limited.records("sess_02").map { it.jseq }
            }
            assertEquals("the journaled step is gone", emptyList<Long>(), retained.first)
            assertEquals(
                "the dangling step and the new record are retained",
                listOf(1L, 2L),
                retained.second,
            )
            assertTrue(
                "the store is back within the quota",
                limited.usedBytes() <= used + reserve - 1L,
            )

            // pruned_upto keeps the session's sequence acknowledged: after a
            // reboot the store still knows jseq 2 was accepted, so a reconnect
            // re-send is a duplicate and never a forward gap.
            val reopened = newJournalStore(RecordingDurability(mutableListOf()), root)
            runBlocking {
                val recovery = reopened.recover()
                assertEquals(2L, recovery.highestJseq["sess_01"])
                assertEquals(2L, recovery.highestJseq["sess_02"])
            }
        }
    }

    @Test
    fun theQuotaFailsLoudWhenNothingIsJournaled() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val setup = newJournalStore(durability, root)
            runBlocking {
                setup.recover()
                // Only dangling dispatched records: no step is journaled, so the
                // budgets.md §5 prune has no legal candidate.
                setup.append("sess_01", 1L, journalRecord(type = "dispatched", stepId = "1"))
            }
            val used = setup.usedBytes()
            val extra = journalRecord(type = "dispatched", stepId = "2", padding = 200)
            val reserve = 16L + extra.size
            val limited = newJournalStore(durability, root, limit = used + reserve - 1L)
            val failure = runBlocking {
                limited.recover()
                try {
                    limited.append("sess_01", 2L, extra)
                    null
                } catch (error: JournalException) {
                    error
                }
            }

            assertNotNull("an over-quota write must fail loud", failure)
            assertEquals("JOURNAL_QUOTA_EXCEEDED", failure!!.failure.code)
            assertNull("a host quota failure has no channel.md §10 code", failure.wireCode)
            runBlocking {
                assertEquals("the refused record is not written", 1, limited.records("sess_01").size)
            }
            assertEquals("nothing was written or dropped", used, limited.usedBytes())
        }
    }
}
