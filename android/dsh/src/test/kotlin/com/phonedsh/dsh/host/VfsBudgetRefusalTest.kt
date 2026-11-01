// phone-dsh — :dsh unit test: the host `single_file_limit` refusal (channel.md §8).
// SPDX-License-Identifier: MIT
//
// budgets.md:104/120-123 make `single_file_limit` a per-tier constant enforced at
// write time; channel.md:236/§4.8/§8 fix *how* the host refuses: one
// `ERROR VFS_REFUSED` carrying `path`, `limit`, `reason`, the refused `mseq` and
// its accepted prefix `accepted_bytes`, consuming no mseq, leaving
// `expected_mseq` unchanged and keeping the channel open. `EFBIG` is the
// Worker-side code for the same condition before it publishes a mutation
// (channel.md:268); it is not the host's wire answer and appears nowhere here.
//
// Two levels are covered:
//   * the whole chain — `DefaultPhoneDshHost` → `HostChannel` → `VfsSink` → the
//     Rust codec — with the `≤ 3 GiB` row's 16 MiB limit, which is the row a
//     2 GiB device selects;
//   * the sink alone with a tiny limit, for the exact boundary (a file of exactly
//     `limit` bytes is legal; one byte more is not) and for a complete write's
//     `accepted_bytes = 0`.

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.MemoryTier
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VfsBudgetRefusalTest {

    // ---- 1. the whole chain, at the ≤ 3 GiB row's 16 MiB ---------------------

    /**
     * A 2 GiB device's row refuses a file that would cross 16 MiB.
     *
     * The mutation is an append of one byte at `append_from = 16 MiB`, i.e. a
     * worker that already holds a 16 MiB prefix and wants one byte more. The
     * frame is structurally valid (channel.md §6 makes `append_from` the accepted
     * logical length), so the refusal must be a `VFS_REFUSED` diagnostic and not
     * a closing protocol error.
     */
    @Test
    fun anAppendPastTheTierLimitIsRefusedWithVfsRefused() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal()
            val host = newHost(platform, wal, ControllerBudgets.forTier(MemoryTier.AT_MOST_3))
            startHost(platform, host)
            try {
                val connection = connect(host)
                val limit = 16L * 1024L * 1024L
                send(
                    host,
                    connection,
                    mutFrame(
                        mseq = 42L,
                        path = "/dsh/workspace/two-gib.bin",
                        appendFrom = limit,
                        data = byteArrayOf(0x41),
                        seq = 2L,
                    ),
                )

                assertTrue(
                    "a refused mutation must not be acknowledged",
                    fieldsOf(connection, HostFrame.VFS_ACK).isEmpty(),
                )
                assertTrue("nothing may reach the WAL", wal.appendedBodies.isEmpty())

                val errors = fieldsOf(connection, ERROR_TYPE)
                assertEquals(1, errors.size)
                val refused = errors.single()
                assertEquals("VFS_REFUSED", refused.getString("code"))
                assertEquals("/dsh/workspace/two-gib.bin", refused.getString("path"))
                assertEquals(limit, refused.getLong("limit"))
                assertEquals("file-too-large", refused.getString("reason"))
                // A host reply names the refused frame and the refused mutation,
                // and states the prefix it already holds (channel.md §4.8).
                assertEquals(2L, refused.getLong("ref_seq"))
                assertEquals(42L, refused.getLong("mseq"))
                assertEquals(limit, refused.getLong("accepted_bytes"))
                assertTrue(
                    "the message must be actionable: ${refused.getString("message")}",
                    refused.getString("message").contains("single-file limit"),
                )

                // §8: the refusal is not a connection error.
                assertTrue("VFS_REFUSED must not close: ${connection.closes}", connection.closes.isEmpty())
                assertEquals("admission stays open", Admission.OPEN, host.controller.admission)

                // The refused mseq was not consumed: the same mseq with a legal
                // size (the Worker's shrink-and-resend of §4.8) is accepted.
                send(
                    host,
                    connection,
                    mutFrame(
                        mseq = 42L,
                        path = "/dsh/workspace/two-gib.bin",
                        appendFrom = limit,
                        data = ByteArray(0),
                        seq = 3L,
                    ),
                )
                val acks = fieldsOf(connection, HostFrame.VFS_ACK)
                assertEquals(1, acks.size)
                assertEquals(1, acks.single().getInt("level"))
                assertEquals(42L, acks.single().getLong("upto_mseq"))
                assertEquals(1, wal.appendedBodies.size)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. a host that never measured still refuses at 16 MiB --------------

    /**
     * A `DefaultPhoneDshHost` built **without** `deviceBudgets` enforces the
     * smallest row (16 MiB), not the 8 GiB row (128 MiB).
     *
     * budgets.md:95-97 only maps a *known* memory ceiling and never states the
     * unknown case, so "no measurement" and "a reading of 0" must agree — and
     * they agree on the side that cannot widen a quota. The default is reachable
     * from every caller that forgets to measure; a default of the 8 GiB row
     * would let exactly those callers hand a `≤ 3 GiB` device an 8× quota, which
     * is this lane's own bug.
     *
     * Reverse verification: change `HostBudgetTier.UNMEASURED` back to the 8 GiB
     * row and the second mutation below (16 MiB + 1 byte) is accepted, so the
     * `VFS_REFUSED` assertion fails.
     */
    @Test
    fun aHostWithNoMeasuredTierRefusesAtTheSmallestRow() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal()
            // No `deviceBudgets` argument: this is the unmeasured default.
            val host = newDefaultHost(platform, wal)
            startHost(platform, host)
            try {
                val connection = connect(host)
                val limit = 16L * 1024L * 1024L

                // Exactly at the smallest row's limit: legal, and appended.
                send(
                    host,
                    connection,
                    mutFrame(
                        mseq = 42L,
                        path = "/dsh/workspace/unmeasured.bin",
                        appendFrom = limit,
                        data = ByteArray(0),
                        seq = 2L,
                    ),
                )
                assertEquals(1, wal.appendedBodies.size)

                // One byte past it: refused. With the 8 GiB row (128 MiB) this
                // would have been an ordinary accepted write.
                send(
                    host,
                    connection,
                    mutFrame(
                        mseq = 43L,
                        path = "/dsh/workspace/unmeasured.bin",
                        appendFrom = limit,
                        data = byteArrayOf(0x41),
                        seq = 3L,
                    ),
                )
                assertTrue(
                    "only the legal write may reach the WAL",
                    wal.appendedBodies.size == 1,
                )
                val refused = fieldsOf(connection, ERROR_TYPE).single()
                assertEquals("VFS_REFUSED", refused.getString("code"))
                assertEquals(limit, refused.getLong("limit"))
                assertEquals(43L, refused.getLong("mseq"))
                assertEquals(limit, refused.getLong("accepted_bytes"))
                assertEquals("file-too-large", refused.getString("reason"))
                assertTrue("the refusal must not close", connection.closes.isEmpty())
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. the sink alone: the exact boundary and a complete write ----------

    /**
     * A file of exactly `limit` bytes is legal; one byte more is refused.
     *
     * `budgets.md:120-123` says the host may set `single_file_limit` in
     * 16 MiB…256 MiB and channel.md §6 says "one file is at most" that value, so
     * the bound is inclusive. The sink is driven directly here (a 1 KiB limit)
     * because the boundary is the point and the tier table's own floor is 16 MiB.
     */
    @Test
    fun theLimitIsInclusiveAndACompleteWriteReportsZeroAcceptedBytes() {
        // The log must answer the same mseq the sink seeds from `open`: the sink
        // treats a mismatch as a broken WAL, so the fake's recovery is the sink's.
        val wal = FakeHostWal(
            recovery = WalRecovery.Recovered(nextMseq = 1L, ackedMseq = 0L, durableMseq = 0L),
        )
        val frames = mutableListOf<VfsFrame>()
        val sink = VfsSink(
            wal = wal,
            singleFileLimitBytes = 1024L,
        )
        runBlocking { sink.open(WalRecovery.Recovered(nextMseq = 1L, ackedMseq = 0L, durableMseq = 0L)) }
        sink.attach(
            object : VfsSender {
                override suspend fun send(frame: VfsFrame) {
                    frames += frame
                }
            },
        )

        // Exactly at the limit: accepted, and the WAL gets the body.
        runBlocking {
            sink.onMut(
                mutFrame(
                    mseq = 1L,
                    path = "/dsh/workspace/exact.bin",
                    appendFrom = 0L,
                    data = ByteArray(1024) { 0x42 },
                    seq = 2L,
                ),
                refSeq = 2L,
            )
        }
        assertEquals(1, wal.appendedBodies.size)
        assertEquals(listOf(VfsFrame.Ack(level = 1, uptoMseq = 1L)), frames)
        frames.clear()

        // One byte more: refused, with accepted_bytes = 0 (a complete write) and
        // the refused mseq echoed so the Worker can shrink the same mutation.
        // The accepted write above consumed mseq 1, so this one is mseq 2.
        runBlocking {
            sink.onMut(
                mutFrame(
                    mseq = 2L,
                    path = "/dsh/workspace/one-over.bin",
                    appendFrom = 0L,
                    data = ByteArray(1025) { 0x43 },
                    seq = 3L,
                ),
                refSeq = 3L,
            )
        }
        assertEquals("only the legal write reached the WAL", 1, wal.appendedBodies.size)
        val refusal = frames.single() as VfsFrame.Error
        assertEquals("VFS_REFUSED", refusal.code)
        assertEquals("/dsh/workspace/one-over.bin", refusal.path)
        assertEquals(1024L, refusal.limit)
        assertEquals("file-too-large", refusal.reason)
        assertEquals(2L, refusal.mseq)
        assertEquals(0L, refusal.acceptedBytes)
        assertEquals(3L, refusal.refSeq)
        assertFalse("VFS_REFUSED must not close the connection", refusal.closeConnection)
        assertTrue(
            "the message must name the limit and what is still legal: ${refusal.message}",
            refusal.message.contains("single-file limit of 1024 bytes") &&
                refusal.message.contains("1024 bytes"),
        )
    }

    // ---- helpers ------------------------------------------------------------

    /**
     * One host facade over the fake WAL **without** `deviceBudgets`, so the
     * constructor default is what the test exercises.
     *
     * The argument is deliberately absent rather than passed as
     * `HostBudgetTier.UNMEASURED`: a test that passes the constant cannot see a
     * constructor default that drifts back to the 8 GiB row, which is exactly
     * the regression this helper exists to catch.
     */
    private fun newDefaultHost(
        platform: FakePlatform,
        wal: HostWal,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = HostLog.None,
    )

    /** One host facade with an explicit tier. */
    private fun newHost(
        platform: FakePlatform,
        wal: HostWal,
        budgets: ControllerBudgets,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = HostLog.None,
        deviceBudgets = budgets,
    )

    private fun startHost(platform: FakePlatform, host: DefaultPhoneDshHost) {
        host.start()
        runBlocking { withTimeout(5_000) { host.ready.first { it } } }
        platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
        assertEquals(Admission.OPEN, host.controller.admission)
    }

    private fun connect(host: DefaultPhoneDshHost): RecordingLoopbackConnection {
        val connection = RecordingLoopbackConnection("vfs-budget")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        return connection
    }

    private fun send(
        host: DefaultPhoneDshHost,
        connection: RecordingLoopbackConnection,
        frame: ByteArray,
    ) {
        runBlocking { host.channel.onBinary(connection, frame) }
    }

    private fun fieldsOf(connection: RecordingLoopbackConnection, type: Int): List<JSONObject> =
        connection.sent
            .filter { HostFrame.typeOf(it) == type }
            .map { JSONObject(WireCodec.decode(it)) }

    /**
     * One `VFS_MUT` (§3.1), as canonical JSON for the Rust codec.
     *
     * `appendFrom = 0` with `mflags = 1` is a complete write (entry-changed);
     * a non-zero `appendFrom` sets `mflags = 2` (appended) so the codec and
     * `MutationBody.validate` agree on the op.
     */
    private fun mutFrame(
        mseq: Long,
        path: String,
        appendFrom: Long,
        data: ByteArray,
        seq: Long,
    ): ByteArray {
        val mflags = if (appendFrom == 0L) 1 else 2
        val fields = """{"type":"VFS_MUT","fields":{""" +
            """"append_from":$appendFrom,"data_hex":"${hex(data)}","data_len":${data.size},""" +
            """"mflags":$mflags,"mode":420,"mseq":$mseq,"op":1,"path":"$path"}}"""
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

        /** channel.md §2: ERROR (`0x7F`). */
        const val ERROR_TYPE = 0x7F
    }
}
