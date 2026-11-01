// phone-dsh — :dsh unit test: the VFS sink that makes wal/1 true.
// SPDX-License-Identifier: MIT
//
// These tests drive whole `VFS_MUT`/`VFS_BARRIER` frames through the real
// `HostChannel` and the real Rust codec. Tests 1–3 use a real `WorkspaceLog` on
// a temporary directory, so the level-1 ACK is evidence about an actual WAL
// record, not about a fake counter. Test 4 builds a hand-made frame whose
// `data_len` is above the 15 MiB bound the Rust decoder rejects; it must leave
// the WAL untouched and answer with a stable ERROR code, never a success ACK.
// Tests 5 and 6 are P26: admission closing must not stop the flush of in-flight
// work (channel.md §7 item 6), and `admission closed -> open` must leave the
// Worker's mseq exactly where the host's `expected_mseq` is. Test 6 is the
// device's 105 -> 585 defect, reproduced at the seam that produced it.
//
// The JNI library is required (as for every `:dsh` HELLO test):
//   cd shell && cargo build -p pdsh-jni
// `:dsh/build.gradle.kts` fails the test task with that instruction when it is
// missing.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.log.BootId as LogBootId
import com.phonedsh.log.RecoveryOutcome
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WalRecord
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import java.nio.ByteBuffer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VfsSinkTest {
    // ---- 1. real VFS_MUT → real WAL → level-1 ACK ---------------------------

    @Test
    fun aRealVfsMutBecomesOneWalRecordAndOneLevelOneAck() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)
                send(host, connection, mutFrame(mseq = 1, path = "/dsh/workspace/notes.txt", text = "hello"))

                val acks = ackFields(connection)
                assertEquals(1, acks.size)
                assertEquals(1, acks.single().getInt("level"))
                assertEquals(1L, acks.single().getLong("upto_mseq"))

                // The WAL allocated exactly one mseq, and the record survives a
                // cold reopen (the real proof that append happened).
                assertEquals(2L, log.nextMseq)
                val close = runBlocking { log.closeEpoch() }
                assertEquals(1L, close.durableUpto)
                val reopened = newLog(platform)
                val recovered = runBlocking { reopened.recover() } as RecoveryOutcome.Recovered
                assertEquals(1L, recovered.effectiveTail)
                assertEquals(1, recovered.records.filterIsInstance<WalRecord.Mutation>().size)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. a duplicate mseq is a D9 replay, not a second record ------------

    @Test
    fun aDuplicateMseqIsAckedWithoutASecondAppend() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)
                // A D9 replay keeps the mseq and takes a *fresh* seq: the seq
                // space is per connection (§7.4) and this is the same one.
                send(
                    host,
                    connection,
                    mutFrame(mseq = 1, path = "/dsh/workspace/notes.txt", text = "once", seq = 2),
                )
                send(
                    host,
                    connection,
                    mutFrame(mseq = 1, path = "/dsh/workspace/notes.txt", text = "once", seq = 3),
                )

                val acks = ackFields(connection)
                assertEquals(2, acks.size)
                assertTrue(acks.all { it.getInt("level") == 1 && it.getLong("upto_mseq") == 1L })
                // One record, not two: next_mseq is still 2.
                assertEquals(2L, log.nextMseq)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. level 2 only from an epoch close -------------------------------

    @Test
    fun aLevelTwoBarrierWaitsForTheEpochClose() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)
                send(host, connection, mutFrame(mseq = 1, path = "/dsh/workspace/a.txt", text = "a"))
                send(host, connection, barrierFrame(wantLevel = 2, uptoMseq = 1))

                // Before the close there is the mutation's level-1 ACK only; the
                // barrier is queued and does not block anything.
                val before = ackFields(connection)
                assertEquals(1, before.size)
                assertTrue(before.none { it.getInt("level") == 2 })

                assertEquals(1L, runBlocking { host.closeEpoch() })

                val after = ackFields(connection)
                assertEquals(2, after.size)
                assertEquals(1, after[0].getInt("level"))
                assertEquals(1L, after[0].getLong("upto_mseq"))
                assertEquals(2, after[1].getInt("level"))
                assertEquals(1L, after[1].getLong("upto_mseq"))
            } finally {
                host.stop()
            }
        }
    }

    // ---- 4. a data_len above 15 MiB is refused, not appended ----------------

    @Test
    fun anOversizedMutationIsRefusedWithoutTouchingTheWal() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)
                send(host, connection, oversizedMutFrame())

                assertTrue("no success ACK for a refused mutation", ackFields(connection).isEmpty())
                assertEquals("the WAL still has no record", 1L, log.nextMseq)

                val errors = errorFields(connection)
                assertEquals(1, errors.size)
                assertEquals("BAD_PAYLOAD", errors.single().getString("code"))
                assertEquals(2L, errors.single().getLong("ref_seq"))

                assertEquals(1, connection.closes.size)
                assertEquals("BAD_PAYLOAD", connection.closes.single().second)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 5. P26: admission closed still flushes (channel.md §7 item 6) ------

    @Test
    fun aMutationThatArrivesWhileAdmissionIsClosedIsStillAppendedAndAcked() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)

                // D14: `Running -> Backoff` on an unsatisfied network path closes
                // admission. The turn is not aborted and the Worker keeps
                // flushing what it already admitted — channel.md §7 item 6:
                // "flushing and in-flight work continue".
                platform.emit(NetworkPath(available = false, expensive = false))
                assertEquals(HostState.BACKOFF, host.controller.state)
                assertEquals(Admission.CLOSED, host.controller.admission)

                send(
                    host,
                    connection,
                    mutFrame(mseq = 1, path = "/dsh/workspace/in-flight.txt", text = "kept"),
                )

                assertEquals(
                    "the in-flight mutation is level-1 acknowledged while admission is closed",
                    listOf(1L),
                    ackFields(connection)
                        .filter { it.getInt("level") == 1 }
                        .map { it.getLong("upto_mseq") },
                )
                assertEquals("the WAL must receive the in-flight mutation", 2L, log.nextMseq)

                // P26: `VFS_RESYNC` is a materialization repair for an *accepted*
                // record (channel.md §3.4, wal.md §5.1), never a refusal. The
                // Worker answers it at the NEXT mseq, so sending it here is what
                // burned 480 mseq on the device.
                assertTrue(
                    "no VFS_RESYNC may answer a mutation the host did append",
                    fieldsOf(connection, HostFrame.VFS_RESYNC).isEmpty(),
                )
                assertTrue(
                    "no ERROR: the mutation was legal",
                    errorFields(connection).isEmpty(),
                )
            } finally {
                host.stop()
            }
        }
    }

    // ---- 6. P26: admission closed -> open keeps the Worker's mseq contiguous

    /**
     * The device defect, at the seam that produced it.
     *
     * On an AVD, `Running -> Backoff` closed admission, 480 mutations from the
     * in-flight tool arrived (mseq 105..584) and were answered with `VFS_RESYNC`
     * plus no ACK. Three seconds later admission reopened and the next frame the
     * Worker sent — mseq 585, the next slot in its own counter — was
     * `BAD_MSEQ: expected mseq 105, got 585`; the Worker closed the ordered
     * channel and the turn failed.
     *
     * Here the 480 mutations are real VFS_MUT frames through the real
     * `HostChannel` and the real Rust codec, they are appended to a real WAL,
     * and the reopened host accepts the next mseq. Reverse validation: restoring
     * the `AdmissionGate` check in `VfsSink.onMut` turns this red at the first
     * assertion after the closed window (no ACK, 480 VFS_RESYNC frames, then
     * `BAD_MSEQ`).
     */
    @Test
    fun admissionClosedAndReopenedKeepsTheWorkersMseqContiguous() {
        FakePlatform().use { platform ->
            val log = newLog(platform)
            val host = newHost(platform, log)
            startHost(platform, host)
            try {
                val connection = connect(host)

                // The device's baseline: 104 accepted mutations, so the Worker's
                // next mseq is 105.
                for (mseq in 1L..BASELINE_MSEQS) {
                    send(host, connection, mutFrame(mseq, "/dsh/workspace/p26/$mseq.txt", "v$mseq", seq = mseq + 1))
                }
                assertEquals(BASELINE_MSEQS + 1, log.nextMseq)

                // Admission closes; the in-flight tool keeps writing.
                platform.emit(NetworkPath(available = false, expensive = false))
                assertEquals(HostState.BACKOFF, host.controller.state)
                assertEquals(Admission.CLOSED, host.controller.admission)

                val firstStalled = BASELINE_MSEQS + 1
                val lastStalled = BASELINE_MSEQS + STALLED_MSEQS
                for (mseq in firstStalled..lastStalled) {
                    send(host, connection, mutFrame(mseq, "/dsh/workspace/p26/$mseq.txt", "v$mseq", seq = mseq + 1))
                }

                // Admission reopens (P15's retry lane exits Backoff).
                platform.emit(NetworkPath(available = true, expensive = false))
                runBlocking {
                    withTimeout(5_000) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals(Admission.OPEN, host.controller.admission)

                // The Worker's counter is 585 (the device's exact number), which
                // is also the host's next expected mseq. Before P26 this frame was
                // answered `BAD_MSEQ: expected mseq 105, got 585` and the channel
                // closed. Asserted first: it is the criterion of the lane.
                val next = lastStalled + 1
                send(host, connection, mutFrame(next, "/dsh/workspace/p26/open.txt", "open", seq = next + 1))
                assertTrue(
                    "no BAD_MSEQ after admission reopened; errors=${errorFields(connection)}",
                    errorFields(connection).isEmpty(),
                )

                assertEquals(
                    "every in-flight mutation is a WAL record",
                    lastStalled + 1,
                    ackFields(connection)
                        .filter { it.getInt("level") == 1 }
                        .maxOf { it.getLong("upto_mseq") },
                )
                assertEquals(next + 1, log.nextMseq)
                assertTrue("the channel was never closed", connection.closes.isEmpty())
                assertEquals(
                    "the last level-1 ACK covers the reopened frame",
                    next,
                    ackFields(connection)
                        .filter { it.getInt("level") == 1 }
                        .maxOf { it.getLong("upto_mseq") },
                )
                assertTrue(
                    "a closed admission may not answer with a resync",
                    fieldsOf(connection, HostFrame.VFS_RESYNC).isEmpty(),
                )
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    private fun newLog(platform: FakePlatform): WorkspaceLog = WorkspaceLog(
        paths = WalPaths(platform.tempDir),
        durability = platform,
        clock = platform,
        bootId = LogBootId.random(),
    )

    private fun newHost(platform: FakePlatform, log: WorkspaceLog): DefaultPhoneDshHost =
        DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            wal = log.asHostWal(),
            scope = CoroutineScope(Dispatchers.Unconfined),
            logger = HostLog.None,
            // 1 ms retry windows: a test asserts the D14 row and the mseq
            // continuity, not the schedule's rhythm.
            retryPolicy = RetryPolicy(
                initialDelayMillis = 1L,
                multiplier = 2,
                maximumDelayMillis = 4L,
                jitterFraction = 0.0,
            ),
        )

    private fun startHost(platform: FakePlatform, host: DefaultPhoneDshHost) {
        host.start()
        runBlocking { withTimeout(5_000) { host.ready.first { it } } }
        // Drive the D14 machine to Running so admission is OPEN for the
        // level-1/level-2 tests; the admission test closes it explicitly.
        platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
        assertEquals(Admission.OPEN, host.controller.admission)
    }

    private fun connect(host: DefaultPhoneDshHost): RecordingLoopbackConnection {
        val connection = RecordingLoopbackConnection("vfs-test")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        return connection
    }

    private fun send(host: DefaultPhoneDshHost, connection: RecordingLoopbackConnection, frame: ByteArray) {
        runBlocking { host.channel.onBinary(connection, frame) }
    }

    private fun ackFields(connection: RecordingLoopbackConnection): List<JSONObject> =
        fieldsOf(connection, HostFrame.VFS_ACK)

    private fun errorFields(connection: RecordingLoopbackConnection): List<JSONObject> =
        fieldsOf(connection, 0x7F)

    private fun fieldsOf(connection: RecordingLoopbackConnection, type: Int): List<JSONObject> =
        connection.sent
            .filter { HostFrame.typeOf(it) == type }
            .map { JSONObject(WireCodec.decode(it)) }

    private fun mutFrame(mseq: Long, path: String, text: String, seq: Long = 2L): ByteArray {
        val data = text.toByteArray(Charsets.UTF_8)
        val fields = """{"type":"VFS_MUT","fields":{""" +
            """"append_from":0,"data_hex":"${hex(data)}","data_len":${data.size},""" +
            """"mflags":1,"mode":420,"mseq":$mseq,"op":1,"path":"$path"}}"""
        return WireCodec.encode(fields, seq = seq)
    }

    private fun barrierFrame(wantLevel: Int, uptoMseq: Long): ByteArray = WireCodec.encode(
        """{"type":"VFS_BARRIER","fields":{"upto_mseq":$uptoMseq,"want_level":$wantLevel}}""",
        seq = 3,
    )

    /**
     * A hand-made VFS_MUT whose `data_len` is 15 MiB + 1.
     *
     * `WireCodec.encode` (correctly) refuses to produce it, so the raw §3.1
     * bytes are built here: the host must reject the frame on the way in.
     */
    private fun oversizedMutFrame(): ByteArray {
        val pathBytes = "/dsh/workspace/big.bin".toByteArray(Charsets.UTF_8)
        val dataLen = VfsMutFrame.MAX_DATA_BYTES + 1
        val payload = ByteBuffer.allocate(28 + pathBytes.size + dataLen)
        payload.putLong(1L)
        payload.put(1.toByte())
        payload.putInt(420)
        payload.put(0.toByte())
        payload.putLong(0L)
        payload.putShort(pathBytes.size.toShort())
        payload.put(pathBytes)
        payload.putInt(dataLen)
        payload.put(ByteArray(dataLen))
        return ByteBuffer.allocate(HostFrame.HEADER_BYTES + payload.capacity())
            .putShort(HostFrame.MAGIC.toShort())
            .put(HostFrame.VFS_MUT.toByte())
            .put(0.toByte())
            .putLong(2L)
            .putInt(payload.capacity())
            .put(payload.array())
            .array()
    }

    private fun hex(bytes: ByteArray): String = buildString {
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    private companion object {
        const val HEX = "0123456789abcdef"

        /** The device's mseq just before admission closed (`expected 105`). */
        const val BASELINE_MSEQS: Long = 104L

        /** The 480 mutation window the P22/P26 device log recorded. */
        const val STALLED_MSEQS: Long = 480L
    }
}
