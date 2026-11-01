// phone-dsh — :dsh unit test: a failed durable write lands in D14 `Failed`.
// SPDX-License-Identifier: MIT
//
// The two sinks used to log an append failure, close the transport and rethrow
// without telling the controller. These tests drive real frames through the
// real `HostChannel` and the production facade, and assert the three facts the
// fix is about:
//
//   1. a WAL quota failure becomes `FailureRaised(QUOTA_EXCEEDED)`, the state is
//      `Failed` and admission is closed (the store exception is still rethrown);
//   2. a journal quota failure does the same with its own code;
//   3. a WAL epoch-close failure takes the same route (unrepaired base mismatch);
//   4. a plain `IOException` from the seam is *not* attributed: the host stays
//      `Running` with admission open and the exception is still rethrown.
//
// The mapping table itself is pinned separately, because the WAL/journal codes
// are a closed vocabulary that must not drift silently.
//
// JNI prerequisite, as for every `:dsh` wire test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerFailure
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalFailure
import com.phonedsh.dsh.journal.JournalPaths
import com.phonedsh.dsh.journal.JournalStore
import com.phonedsh.dsh.journal.journalFrame
import com.phonedsh.dsh.journal.journalRecord
import com.phonedsh.log.LogException
import com.phonedsh.log.LogFailure
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WalException
import com.phonedsh.wire.WireCodec
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostFailureWiringTest {
    // ---- 1. WAL quota -> Failed, admission closed, exception still thrown ----

    @Test
    fun aWalQuotaFailureBecomesFailedAndClosesAdmission() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                appendFailure = LogException(
                    LogFailure.QUOTA_EXCEEDED,
                    "the WAL quota is still exceeded after compaction",
                ),
            )
            val host = newHost(platform, wal = wal)
            startHost(platform, host)
            try {
                val connection = connect(host)

                val thrown = runBlocking { appendFailure(host, connection, mseq = 42) }
                assertTrue("the store failure must still reach the transport", thrown is LogException)
                assertEquals(
                    "the exception keeps the store's own code",
                    "WAL_QUOTA_EXCEEDED",
                    (thrown as LogException).failure.code,
                )

                assertEquals(ControllerFailure.QUOTA_EXCEEDED, host.controller.lastFailure)
                assertEquals(HostState.FAILED, host.controller.state)
                assertEquals(HostState.FAILED, host.state.value)
                assertEquals("Failed closes admission", Admission.CLOSED, host.controller.admission)
                assertTrue("no record was appended", wal.appendedBodies.isEmpty())
                assertTrue(
                    "a failed append must never produce a success ACK",
                    connection.sent.none { HostFrame.typeOf(it) == HostFrame.VFS_ACK },
                )
                assertEquals(1, platform.notifications.count { it.id == HOST_FAILURE_ID })
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. journal quota -> Failed, admission closed ----------------------

    @Test
    fun aJournalQuotaFailureBecomesFailedAndClosesAdmission() {
        FakePlatform().use { platform ->
            // A one-byte quota: recovery is empty and the first record cannot
            // fit, so `ensureQuota` has nothing to prune and refuses loud.
            val store = JournalStore(
                paths = JournalPaths(platform.tempDir),
                durability = platform,
                logger = HostLog.None,
                limitBytes = 1L,
            )
            val host = newHost(platform, journal = store)
            startHost(platform, host)
            try {
                val connection = connect(host)

                val thrown = runBlocking {
                    try {
                        host.channel.onBinary(
                            connection,
                            journalFrame("sess_01", 1L, journalRecord(), seq = 2L),
                        )
                        null
                    } catch (failure: JournalException) {
                        failure
                    }
                }
                assertNotNull("the store failure must still reach the transport", thrown)
                assertEquals("JOURNAL_QUOTA_EXCEEDED", thrown!!.failure.code)
                assertNull("a host quota failure has no §10 wire code", thrown.wireCode)

                assertEquals(ControllerFailure.QUOTA_EXCEEDED, host.controller.lastFailure)
                assertEquals(HostState.FAILED, host.controller.state)
                assertEquals(HostState.FAILED, host.state.value)
                assertEquals(Admission.CLOSED, host.controller.admission)
                assertTrue(
                    "a refused journal record is never acknowledged",
                    connection.sent.none { HostFrame.typeOf(it) == JOURNAL_ACK },
                )
                assertEquals(0L, store.usedBytes())
                assertEquals(1, platform.notifications.count { it.id == HOST_FAILURE_ID })
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. a WAL epoch-close failure takes the same route -------------------

    @Test
    fun aWalEpochCloseFailureBecomesFailed() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                closeFailure = LogException(
                    LogFailure.RESYNC_UNREPAIRED,
                    "the epoch close found an unrepaired base mismatch",
                ),
            )
            val host = newHost(platform, wal = wal)
            startHost(platform, host)
            try {
                val thrown = runBlocking {
                    try {
                        host.closeEpoch()
                        null
                    } catch (failure: LogException) {
                        failure
                    }
                }
                assertNotNull("the close failure must still reach the caller", thrown)
                assertEquals(ControllerFailure.UNREPAIRED_BASE_MISMATCH, host.controller.lastFailure)
                assertEquals(HostState.FAILED, host.controller.state)
                assertEquals(Admission.CLOSED, host.controller.admission)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 4. an unattributable failure is not a host failure -----------------

    @Test
    fun anUnattributableAppendFailureIsRethrownWithoutFailingTheHost() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(appendFailure = IOException("disk went away"))
            val host = newHost(platform, wal = wal)
            startHost(platform, host)
            try {
                val connection = connect(host)

                val thrown = runBlocking { appendFailure(host, connection, mseq = 42) }
                assertTrue("the exception must still reach the transport", thrown is IOException)

                assertEquals(
                    "a plain IOException is not attributable to a store code",
                    HostState.RUNNING,
                    host.controller.state,
                )
                assertEquals(HostState.RUNNING, host.state.value)
                assertEquals(Admission.OPEN, host.controller.admission)
                assertNull(host.controller.lastFailure)
                assertEquals(
                    "no failure notification for an unattributable exception",
                    0,
                    platform.notifications.count { it.id == HOST_FAILURE_ID },
                )
            } finally {
                host.stop()
            }
        }
    }

    // ---- the closed mapping itself -----------------------------------------

    @Test
    fun theFailureMappingIsClosedAndExplicit() {
        assertEquals(
            ControllerFailure.QUOTA_EXCEEDED,
            HostFailureRules.wal(LogException(LogFailure.QUOTA_EXCEEDED, "quota"))?.reason,
        )
        assertEquals(
            ControllerFailure.WAL_CORRUPT,
            HostFailureRules.wal(WalException("WAL_CORRUPT", "crc at offset 12"))?.reason,
        )
        assertEquals(
            ControllerFailure.MATERIALIZATION_IO,
            HostFailureRules.wal(LogException(LogFailure.MATERIALIZATION_FAILED, "copy"))?.reason,
        )
        assertEquals(
            ControllerFailure.UNREPAIRED_BASE_MISMATCH,
            HostFailureRules.wal(LogException(LogFailure.RESYNC_UNREPAIRED, "base"))?.reason,
        )
        assertEquals(
            ControllerFailure.QUOTA_EXCEEDED,
            HostFailureRules.journal(
                JournalException(JournalFailure.QUOTA_EXCEEDED, "quota"),
            )?.reason,
        )
        assertEquals(
            ControllerFailure.HOST_DEFECT,
            HostFailureRules.journal(JournalException(JournalFailure.IO, "fsync"))?.reason,
        )
        assertNull(
            "a protocol refusal keeps the §10 ERROR path, not Failed",
            HostFailureRules.journal(
                JournalException(JournalFailure.PROTOCOL, "bad frame", wireCode = "BAD_PAYLOAD"),
            ),
        )
        assertNull(
            "an unknown exception is not attributed",
            HostFailureRules.wal(IOException("unknown")),
        )
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(
        platform: FakePlatform,
        wal: HostWal? = null,
        journal: JournalStore? = null,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        journal = journal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = HostLog.None,
    )

    /** `start()`, wait for the final HELLO, then drive D14 to `Running`. */
    private fun startHost(platform: FakePlatform, host: DefaultPhoneDshHost) {
        host.start()
        runBlocking { withTimeout(5_000) { host.ready.first { it } } }
        platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
        assertEquals(Admission.OPEN, host.controller.admission)
    }

    private fun connect(host: DefaultPhoneDshHost): RecordingLoopbackConnection {
        val connection = RecordingLoopbackConnection("failure-test")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        return connection
    }

    /** Sends one VFS_MUT and returns whatever the append path threw, if anything. */
    private fun appendFailure(
        host: DefaultPhoneDshHost,
        connection: RecordingLoopbackConnection,
        mseq: Long,
    ): Exception? = runBlocking {
        try {
            host.channel.onBinary(connection, mutFrame(mseq, seq = 2L))
            null
        } catch (failure: Exception) {
            failure
        }
    }

    private fun mutFrame(mseq: Long, seq: Long): ByteArray {
        val data = "hello".toByteArray(Charsets.UTF_8)
        val fields = """{"type":"VFS_MUT","fields":{""" +
            """"append_from":0,"data_hex":"${hex(data)}","data_len":${data.size},""" +
            """"mflags":1,"mode":420,"mseq":$mseq,"op":1,"path":"/dsh/workspace/failure.txt"}}"""
        return WireCodec.encode(fields, seq)
    }

    private fun hex(bytes: ByteArray): String = buildString {
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    private companion object {
        const val HEX = "0123456789abcdef"

        /** `JOURNAL_ACK` (`0x31`), channel.md §2. */
        const val JOURNAL_ACK = 0x31

        /** `ControllerEffects.HOST_FAILURE_NOTIFICATION_ID`. */
        val HOST_FAILURE_ID = ControllerEffects.HOST_FAILURE_NOTIFICATION_ID
    }
}
