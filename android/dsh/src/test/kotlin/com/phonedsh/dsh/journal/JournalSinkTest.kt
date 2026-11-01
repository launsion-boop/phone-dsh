// phone-dsh — :dsh unit test: the JOURNAL → fsync → ACK sink.
// SPDX-License-Identifier: MIT
//
// The tests drive whole `JOURNAL` frames (encoded by the real Rust codec) into a
// `JournalSink` over a real store in a temporary directory, and observe three
// things a test seam cannot fake:
//
//   1. the acknowledgement's watermark comes back from a *reopened* store, i.e.
//      from disk bytes;
//   2. the injected `Durability` sees the fsync **before** the sender sees the
//      ACK, and a throwing fsync produces no ACK at all;
//   3. the watermark a durability wait polls is already advanced when the frame
//      call returns (the N1 30 s failure was the opposite of this).

package com.phonedsh.dsh.journal

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalSinkTest {
    @Test
    fun anAckNamesAWatermarkThatSurvivesAReopen() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val store = newJournalStore(durability, root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            val record = journalRecord(type = "dispatched", stepId = "1")
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
                sink.onJournal(journalFrame("sess_01", 1L, record))
            }

            val ack = sender.acks.single()
            assertEquals("the record is fsynced, so the honest level is 2", 2, ack.level)
            assertEquals("sess_01", ack.sessionId)
            assertEquals(1L, ack.uptoJseq)
            assertEquals(1L, sink.durableUpto("sess_01"))

            // The ACK is evidence about bytes only if another store can read
            // them back; the in-memory watermark alone is what the N1 seam had.
            val reopened = newJournalStore(RecordingDurability(mutableListOf()), root)
            val recovery = runBlocking { reopened.recover() }
            assertEquals(1L, recovery.highestJseq["sess_01"])
            assertArrayEquals(record, runBlocking { reopened.records("sess_01") }.single().record)

            // A reopened *sink* seeds its watermark from that disk record, so a
            // worker reconnect that re-sends jseq 1 is a duplicate: one ACK, no
            // second copy.
            val reopenedSink = JournalSink(reopened)
            val secondSender = RecordingSender()
            runBlocking {
                reopenedSink.open(recovery)
                reopenedSink.attach(secondSender)
                reopenedSink.onJournal(journalFrame("sess_01", 1L, record))
            }
            assertEquals(1L, reopenedSink.durableUpto("sess_01"))
            assertEquals(1, secondSender.acks.size)
            assertEquals(1L, secondSender.acks.single().uptoJseq)
            assertEquals(1, runBlocking { reopened.records("sess_01") }.size)
        }
    }

    @Test
    fun theFsyncCompletesBeforeTheAckIsSent() {
        withJournalRoot { root ->
            val events = mutableListOf<String>()
            val durability = RecordingDurability(events)
            val store = newJournalStore(durability, root)
            val sink = JournalSink(store)
            val sender = RecordingSender(events)
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
                sink.onJournal(journalFrame("sess_01", 1L, journalRecord()))
            }

            val ackAt = events.indexOfFirst { it.startsWith("ack:") }
            val lastFsyncAt = events.indexOfLast { it.startsWith("fsync:") }
            assertTrue("the ACK must exist", ackAt >= 0)
            assertTrue("the fsync must exist", lastFsyncAt >= 0)
            assertTrue(
                "fsync must precede the ACK, was $events",
                ackAt > lastFsyncAt,
            )
            // A new session file needs both its bytes and its directory entry
            // durable, so the store fsyncs the file and `journal/`.
            assertEquals(2, events.count { it.startsWith("fsync:") })
        }
    }

    @Test
    fun aFailedFsyncSendsNoAckAndLeavesNoRecord() {
        withJournalRoot { root ->
            val durability = RecordingDurability(mutableListOf())
            val store = newJournalStore(durability, root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
            }
            durability.failFsync = true

            val failure = runBlocking {
                try {
                    sink.onJournal(journalFrame("sess_01", 1L, journalRecord()))
                    null
                } catch (error: JournalException) {
                    error
                }
            }
            assertNotNull("a failed fsync must fail the append", failure)
            assertEquals("JOURNAL_IO", failure!!.failure.code)
            assertNull("a host I/O failure has no channel.md §10 code", failure.wireCode)
            assertTrue("no ACK may be sent for an unfsynced record", sender.acks.isEmpty())

            // The rollback removed the new session file, and a clean store over
            // the same directory can accept the same jseq again.
            durability.failFsync = false
            val reopened = newJournalStore(RecordingDurability(mutableListOf()), root)
            val recovery = runBlocking { reopened.recover() }
            assertTrue("the torn append is not recovered as a record", recovery.highestJseq.isEmpty())

            val retrySink = JournalSink(reopened)
            val retrySender = RecordingSender()
            runBlocking {
                retrySink.open(recovery)
                retrySink.attach(retrySender)
                retrySink.onJournal(journalFrame("sess_01", 1L, journalRecord()))
            }
            assertEquals(1, retrySender.acks.size)
            assertEquals(1L, retrySender.acks.single().uptoJseq)
            assertEquals(1, runBlocking { reopened.records("sess_01") }.size)
        }
    }

    @Test
    fun aRepeatedJseqIsAckedWithoutASecondRecord() {
        withJournalRoot { root ->
            val store = newJournalStore(RecordingDurability(mutableListOf()), root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            val frame = journalFrame("sess_01", 1L, journalRecord())
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
                sink.onJournal(frame)
                // A reconnect re-send of the same `(session_id, jseq)` (§9.3).
                sink.onJournal(frame)
            }

            assertEquals(2, sender.acks.size)
            assertTrue(sender.acks.all { it.level == 2 && it.uptoJseq == 1L })
            assertEquals(1, runBlocking { store.records("sess_01") }.size)
        }
    }

    @Test
    fun aForwardGapIsRefusedAndWritesNothing() {
        withJournalRoot { root ->
            val store = newJournalStore(RecordingDurability(mutableListOf()), root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
            }

            val failure = runBlocking {
                try {
                    sink.onJournal(journalFrame("sess_01", 2L, journalRecord()))
                    null
                } catch (error: JournalException) {
                    error
                }
            }
            assertNotNull("a first jseq of 2 is a forward gap", failure)
            assertEquals("JOURNAL_PROTOCOL", failure!!.failure.code)
            assertEquals("channel.md §3.5 makes a forward gap BAD_PAYLOAD", "BAD_PAYLOAD", failure.wireCode)
            assertTrue(sender.acks.isEmpty())
            assertTrue(runBlocking { store.records("sess_01") }.isEmpty())
        }
    }

    @Test
    fun theWatermarkAdvancesOnTheCallThatFsyncsSoADurabilityWaitResolves() {
        withJournalRoot { root ->
            val store = newJournalStore(RecordingDurability(mutableListOf()), root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
            }

            // The worker's durability wait is bounded at 30 s and polls the
            // acknowledgement tracker. If the host acknowledged before fsync, the
            // wait would resolve on a lie; if it acknowledged late (or never), the
            // wait would expire and the worker would reconnect into a 409. Here
            // each call must leave the level-2 watermark at the record's jseq
            // before it returns, with exactly one ACK in the same call.
            for (jseq in 1L..3L) {
                runBlocking {
                    sink.onJournal(
                        journalFrame("sess_01", jseq, journalRecord(stepId = jseq.toString())),
                    )
                }
                assertEquals(
                    "level-2 durability for jseq $jseq must be visible when the frame call returns",
                    jseq,
                    sink.durableUpto("sess_01"),
                )
                val ack = sender.acks.last()
                assertEquals(2, ack.level)
                assertEquals(jseq, ack.uptoJseq)
                assertEquals("exactly one ACK per accepted frame", jseq.toInt(), sender.acks.size)
            }

            // And the watermarks are not a session-only counter: a reopened store
            // reports the same high-water mark, so a worker restart cannot reuse
            // jseq 1..3 and a reconnect has nothing to resend.
            val reopened = newJournalStore(RecordingDurability(mutableListOf()), root)
            val recovery = runBlocking { reopened.recover() }
            assertEquals(3L, recovery.highestJseq["sess_01"])
            assertEquals(
                listOf(1L, 2L, 3L),
                runBlocking { reopened.records("sess_01") }.map { it.jseq },
            )
        }
    }

    @Test
    fun theGoldenJournalAndAckVectorsRoundTripThroughTheSink() {
        // spec/v1/golden/frames/journal-1.json (seq 14, jseq 1, session sess_01)
        // and journal-ack-1.json (seq 5, level 1). The JOURNAL frame is decoded by
        // the real codec and persisted; an ACK built from those fields at the
        // golden seq must reproduce the vector byte-for-byte.
        val journalFrame = hexBytes(
            "5a4c3000000000000000000e0000006b00000000000000010007736573735f3031" +
                "7b22737465705f6964223a22786c312d3066316532643363346235613639373838" +
                "373936613562346333643265316630222c227475726e5f6964223a227475726e5f" +
                "3031222c2274797065223a2264697370617463686564227d",
        )
        val goldenRecord = hexBytes(
            "7b22737465705f6964223a22786c312d306631653264336334623561363937383837" +
                "3936613562346333643265316630222c227475726e5f6964223a227475726e5f3031" +
                "222c2274797065223a2264697370617463686564227d",
        )
        val goldenAck = "5a4c3100000000000000000500000012010007736573735f30310000000000000001"

        withJournalRoot { root ->
            val store = newJournalStore(RecordingDurability(mutableListOf()), root)
            val sink = JournalSink(store)
            val sender = RecordingSender()
            runBlocking {
                sink.open(store.recover())
                sink.attach(sender)
                sink.onJournal(journalFrame)
            }

            val ack = sender.acks.single()
            assertEquals("sess_01", ack.sessionId)
            assertEquals(1L, ack.uptoJseq)
            assertArrayEquals(goldenRecord, runBlocking { store.records("sess_01") }.single().record)

            // The encoder's layout is the golden one; the host's level is 2
            // because it fsynced, while the vector pins level 1's bytes.
            assertEquals(
                goldenAck,
                hex(JournalAck(level = JournalAck.LEVEL_WRITE, sessionId = "sess_01", uptoJseq = 1L).encode(5L)),
            )
        }
    }
}
