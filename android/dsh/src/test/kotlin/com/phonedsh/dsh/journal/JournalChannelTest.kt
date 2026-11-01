// phone-dsh — :dsh unit test: `HostChannel` routes JOURNAL to the real store.
// SPDX-License-Identifier: MIT
//
// The sink tests prove the fsync/ACK order in isolation. This test proves the
// facade wiring: `DefaultPhoneDshHost(journal = store)` recovers the store in
// `start()`, the channel dispatches `0x30` after the host HELLO, and the
// `0x31` that comes back names a record a second store can read from disk. The
// negative cases are as important: no store means the frame is ignored (never
// acked), and a frame before the host HELLO is ignored too.
//
// `channel.md` §4.1 defines no host journal capability, so this test also pins
// that the HELLO was not changed to claim one.

package com.phonedsh.dsh.journal

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.host.DefaultPhoneDshHost
import com.phonedsh.dsh.host.HostFrame
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalChannelTest {
    @Test
    fun aJournalFrameBecomesADurableRecordAndOneLevelTwoAck() {
        FakePlatform().use { platform ->
            val store = JournalStore(
                paths = JournalPaths(platform.tempDir),
                durability = platform,
                logger = HostLog.None,
            )
            val host = newHost(platform, store)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                // channel.md §4.1: host caps are channel/1, wal/1, exec/1 and
                // accelerator:*. There is no host `journal/1`, and this lane
                // must not invent one.
                assertTrue(
                    "no host journal capability exists, so none may be advertised",
                    host.hello.caps.none { it.startsWith("journal") },
                )

                val connection = RecordingLoopbackConnection("journal-test")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }
                val record = journalRecord(type = "dispatched", stepId = "1")
                runBlocking {
                    host.channel.onBinary(
                        connection,
                        journalFrame("sess_01", 1L, record, seq = 2L),
                    )
                }

                val acks = connection.sent
                    .filter { HostFrame.typeOf(it) == 0x31 }
                    .map { JSONObject(WireCodec.decode(it)) }
                val ack = acks.single()
                assertEquals(2, ack.getInt("level"))
                assertEquals("sess_01", ack.getString("session_id"))
                assertEquals(1L, ack.getLong("upto_jseq"))
                // The ACK is the second host frame of the connection (the HELLO
                // was seq 1), so it shares the one host-to-worker seq space.
                assertEquals(
                    2L,
                    HostFrame.seqOf(connection.sent.last()),
                )

                // The durable evidence: a fresh store over the same workspace.
                val reopened = JournalStore(
                    paths = JournalPaths(platform.tempDir),
                    durability = platform,
                    logger = HostLog.None,
                )
                val recovery = runBlocking { reopened.recover() }
                assertEquals(1L, recovery.highestJseq["sess_01"])
                assertArrayEquals(record, runBlocking { reopened.records("sess_01") }.single().record)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun withoutAJournalStoreTheFrameIsIgnoredAndNeverAcked() {
        FakePlatform().use { platform ->
            val host = newHost(platform, journal = null)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("journal-test")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }
                runBlocking {
                    host.channel.onBinary(
                        connection,
                        journalFrame("sess_01", 1L, journalRecord(), seq = 2L),
                    )
                }
                assertTrue(
                    "a host with no store must not acknowledge a record",
                    connection.sent.none { HostFrame.typeOf(it) == 0x31 },
                )
                assertTrue(
                    "the missing lane is not a protocol error",
                    connection.sent.none { HostFrame.typeOf(it) == 0x7F },
                )
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aJournalFrameBeforeTheHostHelloIsIgnored() {
        FakePlatform().use { platform ->
            val store = JournalStore(
                paths = JournalPaths(platform.tempDir),
                durability = platform,
                logger = HostLog.None,
            )
            val host = newHost(platform, store)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("journal-test")
                runBlocking { host.channel.onOpen(connection) }
                runBlocking {
                    host.channel.onBinary(
                        connection,
                        journalFrame("sess_01", 1L, journalRecord(), seq = 2L),
                    )
                }
                assertTrue(
                    "no ACK may precede the host HELLO's seq 1",
                    connection.sent.none { HostFrame.typeOf(it) == 0x31 },
                )
                assertTrue(runBlocking { store.records("sess_01") }.isEmpty())
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aJournalFrameWithANonD6SessionIdIsRefusedWithOneClosingError() {
        FakePlatform().use { platform ->
            val store = JournalStore(
                paths = JournalPaths(platform.tempDir),
                durability = platform,
                logger = HostLog.None,
            )
            val host = newHost(platform, store)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("journal-test")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }
                // The codec accepts any string as `session_id`; §6 validation is
                // the host's job, and a violation is a §10 BAD_PAYLOAD.
                val malformed = WireCodec.encode(
                    """{"type":"JOURNAL","fields":{"jseq":1,"record_hex":"00","session_id":"bad id"}}""",
                    2L,
                )
                runBlocking { host.channel.onBinary(connection, malformed) }

                val errors = connection.sent
                    .filter { HostFrame.typeOf(it) == 0x7F }
                    .map { JSONObject(WireCodec.decode(it)) }
                val error = errors.single()
                assertEquals("BAD_PAYLOAD", error.getString("code"))
                assertEquals(2L, error.getLong("ref_seq"))
                assertTrue(
                    "a refused frame is never acknowledged",
                    connection.sent.none { HostFrame.typeOf(it) == 0x31 },
                )
                assertEquals(1, connection.closes.size)
                assertEquals("BAD_PAYLOAD", connection.closes.single().second)
                assertEquals("the refused frame wrote nothing", 0L, store.usedBytes())
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(platform: FakePlatform, journal: JournalStore?): DefaultPhoneDshHost =
        DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            journal = journal,
            scope = CoroutineScope(Dispatchers.Unconfined),
            logger = HostLog.None,
        )

    /** A connection that records what the host sends; no socket. */
    private class RecordingLoopbackConnection(override val id: String) : LoopbackConnection {
        val sent = mutableListOf<ByteArray>()

        /** `(code, reason)` of every close the host asked for. */
        val closes = mutableListOf<Pair<Short, String>>()

        override suspend fun sendBinary(payload: ByteArray) {
            sent += payload.copyOf()
        }

        override suspend fun close(code: Short, reason: String) {
            closes += code to reason
        }
    }

    private companion object {
        /**
         * The worker HELLO `worker-entry.js` sends (channel.md §4.1, worker
         * variant). The host answers it, which is the gate for JOURNAL.
         */
        fun workerHelloFrame(): ByteArray = WireCodec.encode(
            """
            {"type":"HELLO","fields":{
              "boot_id":"ffeeddccbbaa99887766554433221100",
              "caps":["channel/1","vfs-sink/1","journal/1","api/1"],
              "fence":{"generation":3,"owner":"phone","wal_seq":41},
              "last_mseq":41,
              "proto":1,
              "role":"worker",
              "session_epoch":7
            }}
            """.trimIndent(),
            1L,
        )
    }
}
