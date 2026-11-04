// phone-dsh — :dsh unit test: the real WorkspaceLog behind the host HELLO.
// SPDX-License-Identifier: MIT
//
// This file is the J1 evidence that `wal/1` is a real capability, not a string:
//  * one integration test recovers a real `:core` `WorkspaceLog` on a temporary
//    directory, appends two mutations, reopens it and compares the HELLO's
//    three mseq members with what the log reports;
//  * the other tests inject fake HostWal values to prove the failure path (no
//    `wal/1`, not-wired, no crash), the verbatim durability passthrough, the
//    §4.1-illegal watermark refusal, and a real Rust-codec decode of the frame.
//
// The real log and the HELLO codec both run through `libpdsh_jni`, so the test
// task needs the host build of the JNI crate:
//   cd shell && cargo build -p pdsh-jni
// `:dsh/build.gradle.kts` fails the test task with that instruction when the
// library is missing.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.log.BootId as LogBootId
import com.phonedsh.log.MutationBody
import com.phonedsh.log.RecoveryOutcome
import com.phonedsh.log.VfsOp
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostWalWiringTest {
    // ---- 1. the watermark comes from real recovery --------------------------

    @Test
    fun theHelloWatermarkComesFromARealWorkspaceLogRecovery() {
        FakePlatform().use { platform ->
            val root = platform.tempDir
            val firstBoot = WorkspaceLog(
                paths = WalPaths(root),
                durability = platform,
                clock = platform,
                bootId = LogBootId.random(),
            )
            val close = runBlocking {
                val recovered = firstBoot.recover()
                assertTrue("recover() failed: $recovered", recovered is RecoveryOutcome.Recovered)
                firstBoot.appendMutation(write("/dsh/workspace/notes.txt", "first"))
                firstBoot.appendMutation(write("/dsh/workspace/notes.txt", "second"))
                firstBoot.closeEpoch()
            }
            assertEquals(2L, close.durableUpto)

            // A new process start: cold recovery of the same parent directory.
            val reopened = WorkspaceLog(
                paths = WalPaths(root),
                durability = platform,
                clock = platform,
                bootId = LogBootId.random(),
            )
            val host = newHost(platform, wal = reopened.asHostWal())
            startHost(host)
            try {
                val recovered = reopened.recovery as RecoveryOutcome.Recovered
                val watermark = host.hello.watermark

                assertEquals(recovered.nextMseq, watermark.nextMseq)
                assertEquals(recovered.effectiveTail, watermark.ackedMseq)
                assertEquals(close.durableUpto, watermark.durableMseq)
                // Two mutations at mseq 1 and 2: D17 puts the next one at 3.
                assertEquals(3L, watermark.nextMseq)
                assertEquals(2L, watermark.ackedMseq)
                assertEquals(2L, watermark.durableMseq)

                assertTrue(watermark is MseqWatermark.Observed)
                assertEquals("mseq-watermark: observed (wal recovery)", watermark.provenance)
                assertFalse(watermark.provenance.contains("not-wired"))
                assertTrue(host.hello.capabilities.values.contains(HostCapabilities.WAL))
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. caps and watermark have one source, including the failure path ---

    @Test
    fun aThrowingRecoveryLeavesWalOneOffAndDoesNotCrashStart() {
        FakePlatform().use { platform ->
            val logger = RecordingHostLog()
            val pathFromTheFailure = "secret-workspace/wal"
            val wal = FakeHostWal(
                failure = IllegalStateException("cannot read $pathFromTheFailure"),
            )
            val host = newHost(platform, wal = wal, logger = logger)

            startHost(host)
            try {
                assertEquals(1, platform.engine.startCount)
                assertEquals(1, wal.recoverCalls)

                val uplink = host.hello.wal
                assertTrue("a failed recovery must not claim wal/1", uplink is WalUplink.Down)
                assertFalse(host.hello.capabilities.values.contains(HostCapabilities.WAL))
                assertEquals(
                    listOf(
                        HostCapabilities.CHANNEL,
                        HostCapabilities.EXEC,
                        "accelerator:phone",
                    ),
                    host.hello.caps,
                )

                // No capability and no watermark, from the same Down value.
                assertEquals(MseqWatermark.NotWired, host.hello.watermark)
                assertEquals(0L, host.hello.watermark.nextMseq)
                assertEquals(0L, host.hello.watermark.ackedMseq)
                assertEquals(0L, host.hello.watermark.durableMseq)
                assertTrue(host.hello.watermark.provenance.contains("not-wired"))

                val down = uplink as WalUplink.Down
                assertTrue(down.reason.contains("IllegalStateException"))
                assertTrue(logger.messages.any { it.contains("wal/1") })
                assertTrue(logger.messages.any { it.contains("IllegalStateException") })
                // The reason is a class name, never the exception message/path.
                assertFalse(logger.messages.any { it.contains("secret-workspace") })
                assertFalse(logger.messages.any { it.contains(pathFromTheFailure) })
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aFailedRecoveryOutcomeAlsoLeavesWalOneOff() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                recovery = WalRecovery.Failed("WAL_CORRUPT", "manifest and WAL disagree"),
            )
            val host = newHost(platform, wal = wal)
            startHost(host)
            try {
                assertTrue(host.hello.wal is WalUplink.Down)
                assertFalse(host.hello.capabilities.values.contains(HostCapabilities.WAL))
                assertEquals(MseqWatermark.NotWired, host.hello.watermark)
                assertEquals(1, platform.engine.startCount)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun anIllegalRecoveredWatermarkKeepsWalOneOff() {
        FakePlatform().use { platform ->
            // A log that "recovered" but cannot produce a legal §4.1 HELLO.
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 0, ackedMseq = 0, durableMseq = 0),
            )
            val host = newHost(platform, wal = wal)
            startHost(host)
            try {
                assertTrue(host.hello.wal is WalUplink.Down)
                assertFalse(host.hello.capabilities.values.contains(HostCapabilities.WAL))
                assertEquals(MseqWatermark.NotWired, host.hello.watermark)
            } finally {
                host.stop()
            }
        }
    }

    /**
     * An incomplete WAL cannot be rebuilt from mseq 1, so recovery stays
     * `Failed` and the host must record the held path and mseq. This is the
     * diagnostic that the device evidence lost (`UNRECORDED`).
     */
    @Test
    fun anIncompleteWalHeldResyncFailsTheHostWithPathAndMseq() {
        FakePlatform().use { platform ->
            runBlocking {
                val fixture = WorkspaceLog(
                    paths = WalPaths(platform.tempDir),
                    durability = platform,
                    clock = platform,
                    bootId = LogBootId.random(),
                )
                assertTrue(fixture.recover() is RecoveryOutcome.Recovered)
                fixture.appendMutation(write("/dsh/workspace/held.txt", "abcdefghij"))
                fixture.closeEpoch()
                fixture.appendMutation(
                    MutationBody(
                        op = VfsOp.WRITE,
                        mode = 420,
                        path = "/dsh/workspace/held.txt",
                        data = "klmnop".toByteArray(Charsets.UTF_8),
                        appended = true,
                        appendFrom = 10L,
                    ),
                )
                fixture.appendMutation(write("/dsh/workspace/held.txt", "zz"))
            }
            // The retained WAL must start above mseq 1: drop epoch 1's segment
            // after the manifest watermark already covers its only mutation.
            val paths = WalPaths(platform.tempDir)
            val segments = Files.list(paths.walDirectory).use { stream ->
                stream.sorted().toList()
            }
            Files.delete(segments.first())

            val log = WorkspaceLog(
                paths = paths,
                durability = platform,
                clock = platform,
                bootId = LogBootId.random(),
            )
            val host = newHost(platform, wal = log.asHostWal())
            host.start()
            try {
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                assertEquals(
                    "an incomplete WAL with a held resync is Failed",
                    com.phonedsh.controller.HostState.FAILED,
                    host.controller.state,
                )
                assertEquals(
                    com.phonedsh.controller.ControllerFailure.UNREPAIRED_BASE_MISMATCH,
                    host.controller.lastFailure,
                )
                assertTrue(
                    "the reason names the path: ${host.controller.lastFailureDetail}",
                    host.controller.lastFailureDetail?.contains("/dsh/workspace/held.txt") == true,
                )
                assertTrue(
                    "the reason names the mseq: ${host.controller.lastFailureDetail}",
                    host.controller.lastFailureDetail?.contains("mseq 2") == true,
                )
                assertTrue("wal/1 stays off", host.hello.wal is WalUplink.Down)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. durability is passed through, never promoted --------------------

    @Test
    fun theDurabilityClaimIsPassedThroughWithoutPromotion() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                level = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED,
            )
            val host = newHost(platform, wal = wal)
            startHost(host)
            try {
                assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED, host.durability)
                assertNotEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED, host.durability)
                // `wal/1` is on in this test; it still buys no level-2 claim.
                assertTrue(host.hello.capabilities.values.contains(HostCapabilities.WAL))
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun noInjectedWalMeansNoDurabilityClaim() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            startHost(host)
            try {
                assertEquals(null, host.durability)
                assertEquals(MseqWatermark.NotWired, host.hello.watermark)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 4. the encoded HELLO decodes through the real Rust codec -----------

    @Test
    fun theWalHelloDecodesWithTheRealCodec() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 9, ackedMseq = 8, durableMseq = 8),
            )
            val host = newHost(platform, wal = wal)
            startHost(host)
            try {
                val connection = RecordingLoopbackConnection("channel-wal")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }

                assertEquals(1, connection.sent.size)
                val fields = JSONObject(WireCodec.decode(connection.sent.single()))
                val caps = (0 until fields.getJSONArray("caps").length())
                    .map { fields.getJSONArray("caps").getString(it) }

                assertTrue("caps must contain wal/1: $caps", caps.contains(HostCapabilities.WAL))
                assertTrue("caps must contain channel/1: $caps", caps.contains(HostCapabilities.CHANNEL))
                assertEquals(
                    listOf(
                        HostCapabilities.CHANNEL,
                        HostCapabilities.WAL,
                        HostCapabilities.EXEC,
                        "accelerator:phone",
                    ),
                    caps,
                )

                val next = fields.getLong("next_mseq")
                val acked = fields.getLong("acked_mseq")
                assertEquals(9L, next)
                assertEquals(8L, acked)
                assertEquals(8L, fields.getLong("durable_mseq"))
                assertTrue("next_mseq >= 1", next >= 1L)
                assertTrue("next_mseq > acked_mseq", next > acked)
                assertEquals(1L, host.channel.framesToWorker)
                assertEquals(host.hello, host.channel.lastSentHello.value)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 6. start() is asynchronous and gates the HELLO ---------------------

    @Test
    fun startReturnsImmediatelyAndTheHelloWaitsForRecovery() {
        FakePlatform().use { platform ->
            val gate = CompletableDeferred<Unit>()
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 5, ackedMseq = 4, durableMseq = 4),
                gate = gate,
            )
            val host = newHost(platform, wal = wal)

            host.start()
            try {
                // start() returned while recover() is still suspended: no engine,
                // no ready, and no HELLO answer yet.
                assertFalse(host.ready.value)
                assertEquals(0, platform.engine.startCount)

                val connection = RecordingLoopbackConnection("early")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }
                assertTrue(
                    "a HELLO must not be answered before recovery produced the final watermark",
                    connection.sent.isEmpty(),
                )

                gate.complete(Unit)
                awaitReady(host)

                assertEquals(1, platform.engine.startCount)
                assertEquals(5L, host.hello.watermark.nextMseq)
                assertTrue(host.hello.capabilities.values.contains(HostCapabilities.WAL))

                // The worker's earlier HELLO was not consumed; a post-ready one
                // is answered with the final HELLO.
                runBlocking { host.channel.onBinary(connection, workerHelloFrame()) }
                assertEquals(1, connection.sent.size)
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    /** `start()` is asynchronous; every assertion below needs the final HELLO. */
    private fun startHost(host: DefaultPhoneDshHost) {
        host.start()
        awaitReady(host)
    }

    private fun awaitReady(host: DefaultPhoneDshHost) = runBlocking {
        withTimeout(5_000) { host.ready.first { it } }
    }

    private fun newHost(
        platform: FakePlatform,
        wal: HostWal? = null,
        logger: HostLog = HostLog.None,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = logger,
    )

    private companion object {
        fun write(path: String, text: String): MutationBody = MutationBody(
            op = VfsOp.WRITE,
            mode = 420,
            path = path,
            data = text.toByteArray(Charsets.UTF_8),
            entryChanged = true,
        )
    }
}
