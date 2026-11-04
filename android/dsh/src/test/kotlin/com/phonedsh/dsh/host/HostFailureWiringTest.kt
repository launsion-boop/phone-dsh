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
import org.junit.Assert.assertFalse

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
import com.phonedsh.log.BootId as LogBootId
import com.phonedsh.log.LogException
import com.phonedsh.log.LogFailure
import com.phonedsh.log.MutationBody
import com.phonedsh.log.RecoveryOutcome
import com.phonedsh.log.VfsOp
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
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
                    "cannot close epoch 1: the base mismatch at /dsh/workspace/held.txt " +
                        "(mseq 7) is unrepaired",
                ),
            )
            val logSink = RecordingHostLog()
            val host = newHost(platform, wal = wal, log = logSink)
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
                // The device log only had the code, so the held path and mseq
                // were invisible. They are now in both the D14 reason and the
                // host log line.
                assertTrue(
                    "lastFailureDetail must name the path: ${host.controller.lastFailureDetail}",
                    host.controller.lastFailureDetail?.contains("/dsh/workspace/held.txt") == true,
                )
                assertTrue(
                    "lastFailureDetail must name the mseq: ${host.controller.lastFailureDetail}",
                    host.controller.lastFailureDetail?.contains("mseq 7") == true,
                )
                assertTrue(
                    "logcat must carry the same path and mseq: ${logSink.messages}",
                    logSink.messages.any {
                        it.contains("/dsh/workspace/held.txt") && it.contains("mseq 7")
                    },
                )
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

    @Test
    fun resetFailureStartsTheHostBeforeFeedingUserResetAndRestartsTheWorker() {
        FakePlatform().use { platform ->
            val controller = ControllerStateMachine.boot(
                persistedState = HostState.FAILED,
                persistedFailure = ControllerFailure.HOST_DEFECT,
                persistedFailureDetail = "a prior engine failure",
            )
            val host = newHost(platform, controller = controller)
            try {
                assertEquals(HostState.FAILED, host.state.value)
                assertEquals(0, platform.engine.startCount)

                assertTrue("the failed host accepts an explicit user reset", host.resetFailure())
                assertEquals(
                    "start preparation runs before the controller sees UserReset; " +
                        "a fresh Worker start follows that transition",
                    2,
                    platform.engine.startCount,
                )
                assertEquals("user reset uses the host's serialized D14 handle path", "userReset", controller.transitions.single().signal)
                assertEquals(HostState.RECOVERING, host.state.value)
                assertEquals(Admission.CLOSED, controller.admission)
                assertTrue("the host remains ready to receive the replacement Worker's HELLO", host.ready.value)
                assertFalse("a second reset is rejected once Failed has been left", host.resetFailure())

                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
                runBlocking {
                    withTimeout(5_000) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals(Admission.OPEN, controller.admission)
                assertNull(controller.lastFailure)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun resetFailureIsRejectedOutsideFailedWithoutStartingTheHost() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            try {
                assertEquals(HostState.RECOVERING, host.state.value)
                assertFalse(host.resetFailure())
                assertEquals(0, platform.engine.startCount)
                assertEquals(HostState.RECOVERING, host.state.value)
            } finally {
                host.stop()
            }
        }
    }

    /**
     * The cold-start deadlock, at the facade: `Failed -> Recovering` is a real
     * recovery, not a planned restart, so it must not close the epoch before
     * the Worker exists. The real `WorkspaceLog` leaves a genuine resync
     * outstanding; a close first would set the sticky fatal and D14 would go
     * back to `Failed` before any Worker could answer.
     */
    @Test
    fun userResetRerunsRealRecoveryWithoutClosingBeforeTheWorkerStarts() {
        FakePlatform().use { platform ->
            runBlocking {
                val fixture = WorkspaceLog(
                    paths = WalPaths(platform.tempDir),
                    durability = platform,
                    clock = platform,
                    bootId = LogBootId.random(),
                )
                assertTrue(fixture.recover() is RecoveryOutcome.Recovered)
                fixture.appendMutation(
                    MutationBody(
                        op = VfsOp.WRITE,
                        mode = 420,
                        path = "/dsh/workspace/held.txt",
                        data = "abc".toByteArray(Charsets.UTF_8),
                        entryChanged = true,
                    ),
                )
                fixture.closeEpoch()
                fixture.appendMutation(
                    MutationBody(
                        op = VfsOp.WRITE,
                        mode = 420,
                        path = "/dsh/workspace/held.txt",
                        data = "ghi".toByteArray(Charsets.UTF_8),
                        appended = true,
                        appendFrom = 6L,
                    ),
                )
            }

            val log = WorkspaceLog(
                paths = WalPaths(platform.tempDir),
                durability = platform,
                clock = platform,
                bootId = LogBootId.random(),
            )
            val controller = ControllerStateMachine.boot(
                persistedState = HostState.FAILED,
                persistedFailure = ControllerFailure.UNREPAIRED_BASE_MISMATCH,
                persistedFailureDetail = "a prior close held the resync",
            )
            val host = DefaultPhoneDshHost(
                engine = platform.engine,
                controller = controller,
                clock = platform,
                signals = platform,
                notifier = platform,
                wal = log.asHostWal(),
                scope = CoroutineScope(Dispatchers.Unconfined),
                logger = HostLog.None,
            )
            try {
                host.start()
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                assertEquals("the first boot started the Worker", 1, platform.engine.startCount)

                assertTrue(host.resetFailure())
                runBlocking {
                    withTimeout(5_000) {
                        while (platform.engine.startCount < 2 || !host.ready.value) {
                            kotlinx.coroutines.delay(5)
                        }
                    }
                }

                // No epoch close ran before the replacement Worker: the reset
                // is a real recovery, and the log still exposes the resync.
                assertEquals(HostState.RECOVERING, controller.state)
                assertNull("a successful reset clears the old failure", controller.lastFailure)
                assertNotNull("recovery ran again and left the resync for the Worker", log.recovery)

                val connection = connect(host)
                assertTrue(
                    "the recovered resync is re-requested after HELLO",
                    connection.sent.any { HostFrame.typeOf(it) == HostFrame.VFS_RESYNC },
                )
                // The Worker's complete write at the next mseq is the repair.
                runBlocking {
                    host.channel.onBinary(
                        connection,
                        writeFrame(
                            mseq = 3,
                            path = "/dsh/workspace/held.txt",
                            text = "abcdefghi",
                            seq = 2,
                        ),
                    )
                }
                assertEquals(3L, log.materializedUptoMseq)
                assertEquals(3L, runBlocking { host.closeEpoch() })

                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
                runBlocking { withTimeout(5_000) { host.state.first { it == HostState.RUNNING } } }
                assertEquals(Admission.OPEN, controller.admission)
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
        controller: ControllerStateMachine = ControllerStateMachine.boot(persistedState = null),
        wal: HostWal? = null,
        journal: JournalStore? = null,
        log: HostLog = HostLog.None,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = controller,
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        journal = journal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = log,
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

    /** A complete write with a caller-chosen path and bytes. */
    private fun writeFrame(mseq: Long, path: String, text: String, seq: Long): ByteArray {
        val data = text.toByteArray(Charsets.UTF_8)
        val fields = """{"type":"VFS_MUT","fields":{""" +
            """"append_from":0,"data_hex":"${hex(data)}","data_len":${data.size},""" +
            """"mflags":1,"mode":420,"mseq":$mseq,"op":1,"path":"$path"}}"""
        return WireCodec.encode(fields, seq = seq)
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
