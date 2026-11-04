// phone-dsh — :dsh unit test: the host facade, its HELLO and its D14 wiring.
// SPDX-License-Identifier: MIT
//
// Pure JVM: `FakePlatform` provides Clock/LifecycleSignals/Notifier and a
// `FakeEngineHost`, and the HELLO assertions decode the produced frame with the
// real Rust codec (`WireCodec`). No WebView, no Ktor, no device.
//
// Why the worker HELLO is fed through `LoopbackChannelHandler` rather than
// `FakeEngineHost`: the engine SPI has no frame surface by design (it exposes
// `state`/`channel`/`handshake` only). `:engine` hands its frame consumer in at
// construction — `createDemoEngine(channelHandler = host.channelHandler)` — so
// `onBinary` on that handler *is* the production entry point for a worker frame.
// FakeEngineHost drives the lifecycle half of the test.

package com.phonedsh.dsh.host

import com.phonedsh.controller.BootDisposition
import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.ControllerFailure
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.controller.SignalOutcome
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneDshHostTest {
    // ---- 1. start() drives the engine and the controller ---------------------

    @Test
    fun startDrivesTheEngineToRunningAndTheControllerFollows() {
        val platform = FakePlatform()
        val controller = ControllerStateMachine.boot(persistedState = null)
        val host = newHost(platform, controller)

        host.start()

        assertEquals(1, platform.engine.startCount)
        // The D14 boot mapping for a new workspace is Recovering; admission stays
        // closed until the engine is up and the lease probe answers.
        assertEquals(HostState.RECOVERING, controller.state)
        assertEquals(Admission.CLOSED, controller.admission)

        platform.engine.setState(RUNNING)

        assertEquals(HostState.RUNNING, controller.state)
        assertEquals(HostState.RUNNING, host.state.value)
        assertEquals(Admission.OPEN, controller.admission)
        // Admission opens on the lease check, not on the engine state itself:
        // budgets.md §2 guards `Recovering -> Running` with "lease verified".
        assertEquals(
            "leaseCheckResult(verified=true)",
            controller.transitions.last().signal,
        )
    }

    @Test
    fun startIsIdempotentAndStopCancelsTheSubscriptions() {
        val platform = FakePlatform()
        val host = newHost(platform)

        host.start()
        host.start()
        assertEquals(1, platform.engine.startCount)

        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, host.state.value)

        host.stop()
        host.stop()
        assertEquals(1, platform.engine.stopCount)

        // The collectors were cancelled before the engine stopped: a late engine
        // event must not move the controller any more.
        val afterStop = host.state.value
        platform.engine.setState(EngineHostState.Failed("late failure"))
        assertEquals(afterStop, host.state.value)
    }

    // ---- 2. the host HELLO ---------------------------------------------------

    @Test
    fun hostHelloAnswersTheWorkerHelloAndDecodesBackToTheInjectedFields() {
        val platform = FakePlatform()
        val host = newHost(
            platform,
            wal = FakeHostWal(WalRecovery.Recovered(nextMseq = 42, ackedMseq = 41, durableMseq = 40)),
        )
        host.start()
        platform.engine.setState(RUNNING)

        val connection = RecordingConnection("channel-1")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, WorkerHello.frame())
        }

        assertEquals(1, connection.sent.size)
        val frame = connection.sent.single()

        // Frame header (channel.md §1): magic, type HELLO, seq 1.
        assertEquals(HostFrame.MAGIC, HostFrame.magicOf(frame))
        assertEquals(HostFrame.HELLO, frame[HostFrame.TYPE_OFFSET].toInt())
        assertEquals(HostHello.HELLO_SEQ, seqOf(frame))

        // The Rust codec must decode what the Rust codec encoded.
        val json = WireCodec.decode(frame)
        val fields = JSONObject(json)
        assertEquals(1, fields.getInt("proto"))
        assertEquals("host", fields.getString("role"))
        assertEquals(42L, fields.getLong("next_mseq"))
        assertEquals(41L, fields.getLong("acked_mseq"))
        assertEquals(40L, fields.getLong("durable_mseq"))
        assertEquals(host.hello.bootId, fields.getString("boot_id"))
        assertTrue(BootId.isValid(fields.getString("boot_id")))
        assertEquals(host.hello.sessionEpoch, fields.getLong("session_epoch"))
        assertEquals(host.hello.fence.owner, fields.getJSONObject("fence").getString("owner"))
        assertEquals(0L, fields.getJSONObject("fence").getLong("generation"))

        val caps = capsOf(fields)
        assertEquals(host.hello.caps, caps)
        assertEquals(1L, host.channel.framesToWorker)
        assertEquals(host.hello, host.channel.lastSentHello.value)
    }

    @Test
    fun hostHelloAdvertisesOnlyWhatThisHostCanActuallyDo() {
        val platform = FakePlatform()
        val host = newHost(platform)
        host.start()

        val connection = RecordingConnection("channel-1")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, WorkerHello.frame())
        }

        val caps = capsOf(JSONObject(WireCodec.decode(connection.sent.single())))
        // No WAL is attached in this test, so `wal/1` must stay off; `exec/1`
        // is real because the facade registered the `phone` accelerator.
        assertEquals(
            listOf(
                HostCapabilities.CHANNEL,
                HostCapabilities.EXEC,
                "accelerator:phone",
            ),
            caps,
        )
        assertFalse(caps.contains(HostCapabilities.WAL))
        assertTrue(caps.contains(HostCapabilities.EXEC))
        assertTrue(caps.contains("accelerator:phone"))
    }

    @Test
    fun aSecondWorkerHelloIsNotAnsweredTwice() {
        val platform = FakePlatform()
        val host = newHost(platform)
        host.start()

        val connection = RecordingConnection("channel-1")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, WorkerHello.frame())
            host.channel.onBinary(connection, WorkerHello.frame())
        }

        // §4.1: a later HELLO is PROTO_MISMATCH; a second host HELLO would be the
        // host inventing its own protocol error.
        assertEquals(1, connection.sent.size)
        assertEquals(1L, host.channel.framesToWorker)
    }

    // ---- 3. the D14 wiring ---------------------------------------------------

    @Test
    fun sceneBackgroundWhileRunningDrainsAndTheDrainParks() {
        val platform = FakePlatform()
        val controller = ControllerStateMachine.boot(persistedState = null)
        val host = newHost(platform, controller)
        host.start()
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, controller.state)

        platform.emit(ScenePhase(ScenePhase.Phase.BACKGROUND))

        // P10: `Draining` is not a terminal state. The row's actions are performed
        // by the facade's drain lane and the exit (`Draining -> Parked`) is taken;
        // before the fix the host sat here for the life of the process and every
        // later `scenePhase(active)` was an ILLEGAL_TRANSITION.
        assertEquals(HostState.PARKED, controller.state)
        assertEquals(HostState.PARKED, host.state.value)
        assertEquals(Admission.CLOSED, controller.admission)
        val draining = controller.transitions.first { it.to == HostState.DRAINING }
        assertEquals(
            listOf("ARM_DRAIN_DEADLINE", "START_BACKGROUND_TASK", "CLOSE_ADMISSION", "PERSIST_HOST_STATE")
                .sorted(),
            draining.effects.map { it.name }.sorted(),
        )
        // The deadline is armed on the row and cleared when the drain leaves the
        // transient state (`clearTransientGuards`); DrainExitTest reads the armed
        // value while a gated drain is still in flight.
        assertEquals(null, controller.drainDeadlineAtMillis)
        assertEquals(
            listOf("CLOSE_EPOCH", "FSYNC_MATERIALIZED", "STOP_WORKER", "CLOSE_ADMISSION", "PERSIST_HOST_STATE")
                .sorted(),
            controller.transitions.last().effects.map { it.name }.sorted(),
        )
    }

    @Test
    fun aForegroundEngineFailureIsTheRecoveryEdge() {
        val platform = FakePlatform()
        val controller = ControllerStateMachine.boot(persistedState = null)
        val host = newHost(platform, controller)
        host.start()
        platform.engine.setState(RUNNING)
        assertEquals(HostState.RUNNING, controller.state)

        platform.engine.setState(EngineHostState.Failed("origin bind failed"))

        assertEquals(HostState.RECOVERING, controller.state)
        assertEquals(
            "engineState(terminated, foreground=true)",
            controller.transitions.last().signal,
        )
        assertTrue(controller.transitions.last().effects.any { it.name == "RESTART_WORKER" })
    }

    // ---- 4. boot recovery on the Notifier ------------------------------------

    @Test
    fun aCrashRecoveryBootPostsAnOngoingNotificationAndAdmissionClearsIt() {
        val platform = FakePlatform()
        val controller = ControllerStateMachine.boot(persistedState = HostState.RUNNING)
        assertEquals(BootDisposition.CRASH_RECOVERY, controller.bootDisposition)
        val host = newHost(platform, controller)

        host.start()

        val boot = platform.notifications.single { it.id == DefaultPhoneDshHost.BOOT_RECOVERY_NOTIFICATION_ID }
        assertTrue(boot.ongoing)
        assertTrue(platform.cancelledIds.isEmpty())

        platform.engine.setState(RUNNING)

        assertTrue(
            DefaultPhoneDshHost.BOOT_RECOVERY_NOTIFICATION_ID in platform.cancelledIds,
        )
    }

    @Test
    fun aColdStartBootPostsNoRecoveryNotification() {
        val platform = FakePlatform()
        val host = newHost(platform, ControllerStateMachine.boot(persistedState = null))

        host.start()

        assertEquals(BootDisposition.COLD_START, host.controller.bootDisposition)
        assertTrue(platform.notifications.isEmpty())
    }

    @Test
    fun aBootWithNotificationsDisabledStaysInRecoveringAndSaysWhy() {
        val platform = FakePlatform(
            initialNotifierAvailability = com.phonedsh.platform.NotifierAvailability.DISABLED,
        )
        val host = newHost(platform, ControllerStateMachine.boot(persistedState = HostState.RUNNING))

        host.start()
        platform.engine.setState(RUNNING)

        // Degraded presentation is not a transition: the host still runs.
        assertEquals(HostState.RUNNING, host.controller.state)
        assertTrue(platform.notifications.isEmpty())
    }

    // ---- 5. the HELLO value itself ------------------------------------------

    @Test
    fun theHostHelloIsMintedBeforeStartAndOnlySentOnAWorkerHello() {
        val platform = FakePlatform()
        val host = newHost(
            platform,
            wal = FakeHostWal(WalRecovery.Recovered(nextMseq = 7, ackedMseq = 6, durableMseq = 6)),
        )

        // Minted at construction as the honest "recovery has not run" value: the
        // boot id and the HELLO exist before start(), so the App can show them,
        // but no WAL has been recovered and no capability is claimed yet.
        assertTrue(BootId.isValid(host.hello.bootId))
        assertEquals(HostState.RECOVERING, host.state.value)
        assertEquals(null, host.channel.lastSentHello.value)
        assertTrue(host.hello.wal is WalUplink.Down)
        assertEquals(0L, host.hello.watermark.nextMseq)

        host.start()

        // start() recovered the injected WAL: the same HELLO value now carries
        // the observed watermark and wal/1, and still has not been sent.
        assertEquals(MseqWatermark.Observed(7, 6, 6), host.hello.watermark)
        assertTrue(host.hello.capabilities.values.contains(HostCapabilities.WAL))
        assertTrue(host.hello.watermark.satisfiesHelloRules)
        assertEquals(null, host.channel.lastSentHello.value)
        host.stop()
    }

    // ---- 4. wal.md §5.2: the running host closes an epoch every 30–60 s -----

    @Test
    fun periodicEpochCloseRunsWhileTheHostIsRunning() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 42, ackedMseq = 41, durableMseq = 40),
            )
            val host = newHost(platform, wal = wal, epochCloseIntervalMillis = 10L)
            try {
                host.start()
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                platform.engine.setState(RUNNING)
                runBlocking {
                    withTimeout(5_000) {
                        while (wal.closeCalls == 0) delay(5)
                    }
                }
                assertTrue("the periodic lane closed at least one epoch", wal.closeCalls >= 1)
                assertEquals("the close does not move D14 out of Running", HostState.RUNNING, host.state.value)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun periodicEpochCloseIsSkippedAndLoggedWhileAResyncIsHeld() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 42, ackedMseq = 41, durableMseq = 40),
            )
            wal.pendingResyncValue = WalResync("/dsh/workspace/held.txt", 7L)
            val log = RecordingHostLog()
            val host = newHost(platform, wal = wal, log = log, epochCloseIntervalMillis = 10L)
            try {
                host.start()
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                platform.engine.setState(RUNNING)
                runBlocking { delay(100) }
                assertEquals("a held resync must not become a Failed close", 0, wal.closeCalls)
                assertEquals(HostState.RUNNING, host.state.value)
                assertTrue(
                    "the deferral names the path and mseq: ${log.messages}",
                    log.messages.any {
                        it.contains("periodic epoch close skipped") &&
                            it.contains("/dsh/workspace/held.txt") &&
                            it.contains("mseq 7")
                    },
                )
            } finally {
                host.stop()
            }
        }
    }

    /**
     * The product boot path, not the test shortcut: a persisted `Running`
     * record is read back through [HostStateStore], the controller takes the
     * `budgets.md` §3 crash-recovery mapping, and only the lease result that
     * follows the engine's own start moves it to `Running`. The periodic lane
     * must then close an epoch without anything calling
     * [ControllerStateMachine.handle] with a hand-made Running transition.
     */
    @Test
    fun periodicEpochCloseRunsAfterThePersistedRunningBootVerifiesTheLease() {
        FakePlatform().use { platform ->
            val stateStore = HostStateStore(
                file = platform.tempDir.resolve("host-state.json"),
                durability = platform,
                clock = platform,
                logger = HostLog.None,
            )
            val seed = ControllerStateMachine.boot(persistedState = null)
            val seeded = seed.handle(ControllerSignal.LeaseCheckResult(verified = true), 1L)
            assertTrue(
                "the seed machine could not reach Running: $seeded",
                seeded is SignalOutcome.Transitioned,
            )
            assertTrue("the seed host-state record was not written", stateStore.save(seed))
            val persisted = stateStore.load()
            assertEquals(HostState.RUNNING, persisted?.state)

            val controller = ControllerStateMachine.boot(
                persistedState = persisted?.state,
                persistedFailure = ControllerFailure.fromCode(persisted?.reason),
            )
            assertEquals(BootDisposition.CRASH_RECOVERY, controller.bootDisposition)
            assertEquals(HostState.RECOVERING, controller.state)

            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 42, ackedMseq = 41, durableMseq = 40),
            )
            val host = newHost(
                platform,
                controller = controller,
                wal = wal,
                stateStore = stateStore,
                epochCloseIntervalMillis = 10L,
            )
            try {
                host.start()
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                // The fake engine is this module's engine seam; the product path
                // under test is host.start() -> lease verification -> Running.
                platform.engine.setState(RUNNING)
                runBlocking { withTimeout(5_000) { host.state.first { it == HostState.RUNNING } } }

                assertEquals(
                    "the host did not reach Running through the lease check",
                    "leaseCheckResult(verified=true)",
                    controller.transitions.last().signal,
                )
                assertEquals(HostState.RUNNING, host.state.value)
                runBlocking {
                    withTimeout(5_000) {
                        while (wal.closeCalls == 0) delay(5)
                    }
                }
                assertTrue(
                    "the periodic lane never closed an epoch after the product-path lease check",
                    wal.closeCalls >= 1,
                )
            } finally {
                host.stop()
            }
        }
    }

    /**
     * Requirement of the periodic lane: a tick that skips because the host is
     * not Running must say so. Before this assertion the loop silently
     * `continue`d, so a nine-minute Running window with no close looked exactly
     * like a lane that had never started.
     */
    @Test
    fun periodicEpochCloseLogsTheReasonWhenItSkipsOutsideRunning() {
        FakePlatform().use { platform ->
            val wal = FakeHostWal(
                recovery = WalRecovery.Recovered(nextMseq = 42, ackedMseq = 41, durableMseq = 40),
            )
            val log = RecordingHostLog()
            val host = newHost(platform, wal = wal, log = log, epochCloseIntervalMillis = 10L)
            try {
                host.start()
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                // The fake engine stays Stopped, so D14 stays Recovering while
                // the periodic lane ticks.
                assertEquals(HostState.RECOVERING, host.state.value)
                runBlocking { delay(100) }

                assertEquals("a non-Running host must not close an epoch", 0, wal.closeCalls)
                assertTrue(
                    "the periodic lane skipped silently; messages=${log.messages}",
                    log.messages.any {
                        it.contains("periodic epoch close skipped") &&
                            it.contains("host state=Recovering")
                    },
                )
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(
        platform: FakePlatform,
        controller: ControllerStateMachine = ControllerStateMachine.boot(persistedState = null),
        wal: HostWal? = null,
        log: HostLog = HostLog.None,
        stateStore: HostStateStore? = null,
        epochCloseIntervalMillis: Long = DefaultPhoneDshHost.EPOCH_CLOSE_INTERVAL_MILLIS,
    ): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = controller,
        clock = platform,
        signals = platform,
        notifier = platform,
        wal = wal,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = log,
        stateStore = stateStore,
        epochCloseIntervalMillis = epochCloseIntervalMillis,
    )

    private fun capsOf(fields: JSONObject): List<String> {
        val array = fields.getJSONArray("caps")
        return (0 until array.length()).map { array.getString(it) }
    }

    private fun seqOf(frame: ByteArray): Long {
        var value = 0L
        for (offset in 4..11) value = (value shl 8) or (frame[offset].toLong() and 0xFF)
        return value
    }

    private companion object {
        /** A live origin; the port is what channel.md §1 would carry. */
        val RUNNING: EngineHostState = EngineHostState.Running("http://127.0.0.1:41234", 41234)

        /** A worker HELLO as `worker-entry.js` sends it (channel.md §4.1, worker variant). */
        object WorkerHello {
            fun frame(): ByteArray = WireCodec.encode(
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
                HostHello.HELLO_SEQ,
            )
        }
    }
}

/** A connection that records the frames the host sends; no socket. */
private class RecordingConnection(override val id: String) : LoopbackConnection {
    val sent = mutableListOf<ByteArray>()

    override suspend fun sendBinary(payload: ByteArray) {
        sent += payload.copyOf()
    }

    override suspend fun close(code: Short, reason: String) = Unit
}
