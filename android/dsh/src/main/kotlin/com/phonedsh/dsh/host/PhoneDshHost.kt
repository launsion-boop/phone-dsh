// phone-dsh — :dsh / com.phonedsh.dsh.host: the facade that connects the layers.
// SPDX-License-Identifier: MIT
//
// ---- what the facade is for -------------------------------------------------
// Every layer below this file is individually finished and individually tested:
// `:platform` owns the SPIs, `:net` owns the loopback origin and the gateway,
// `:controller` owns the D14 table, `:engine` owns the WebView, `:core` owns the
// wire codec. None of them may import another lane's implementation, so somebody
// has to hold the instances, translate between their vocabularies and answer the
// handshake. That somebody is [DefaultPhoneDshHost], and it is exactly two
// things: a serialiser of controller signals and an owner of the host HELLO.
//
// ---- dependency inversion, or this file would be a second :app --------------
// Everything that has an implementation in another module arrives as a
// constructor parameter typed by its `:platform` / `:net` interface: `EngineHost`
// (not `DemoEngine`), `LoopbackServer`, `GatewaySession`, `Clock`,
// `LifecycleSignals`, `Notifier`. That is why :dsh's build file no longer has
// `api(project(":engine"))`: the facade only knows the interface, and the App is
// the one place that can still name `createDemoEngine`.
//
// ---- what it deliberately does not do yet -----------------------------------
// * It does not bind an origin. `:engine`'s `WebViewEngine` binds its own
//   `LoopbackServer` with the `allowQueryTokenOnChannel` configuration the page
//   needs; a second `start()` here would open a port nothing loads. The injected
//   [loopback] is the handle for the step where the facade owns the origin, and
//   for reading `metrics()`/`lastFailure()` when it does.
// * It does not exchange gateway requests: [gateway] is held so the exec/API lane
//   can find the one session, but nothing in this lane calls `exchange`.
// * It owns the WAL seam and the exec seam, not their internals. `start()` runs
//   `WorkspaceLog.recover()` through [HostWal] before the engine starts; only a
//   successful recovery with a §4.1-legal watermark turns `wal/1` on, and
//   [WalUplink] is the only value that can carry that capability-next-to-
//   watermark pair. `exec/1` comes from [HostExec.defaultTools] / an injected
//   [ExecBridge], and its capability set is non-empty by type, so the HELLO
//   cannot advertise it without a real `phone info` accelerator.
//
// ---- the drain's exit (P10) ------------------------------------------------
// `scenePhase(background)` is a real D14 row (`Running -> Draining`), and
// `Draining` is only survivable if its exit is performed: the epoch close, the
// worker stop, and the `DrainCompleted` signal that makes `Draining -> Parked`
// the next row. This facade owns that exit through [DrainLane] and owns the
// `START_WORKER` / `RESTART_WORKER` effects so `Parked -> Recovering` can reach
// an engine that is actually there. A foreground return while draining is never
// handed to the machine as-is (there is no `Draining -> Running` row): the drain
// finishes and the same `scenePhase(active)` is re-fed afterwards, so the round
// trip stays inside budgets.md §2 instead of growing an edge the contract does
// not have.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerEffect
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.HostState
import com.phonedsh.controller.NetworkPathStatus
import com.phonedsh.controller.ScenePhase
import com.phonedsh.controller.SignalOutcome
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalSink
import com.phonedsh.dsh.journal.JournalStore
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackServer
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.Clock
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.platform.EngineHost
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.LifecycleSignal
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.LifecycleSignals
import com.phonedsh.platform.Notifier
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The one host facade the App (or a future Activity/view model) holds.
 *
 * It aggregates the engine, the D14 machine, the one channel and the platform
 * ports, and it is the only object that answers the worker HELLO.
 *
 * [state] is the D14 nine-state value (`:controller`'s `HostState`), not the
 * engine's lifecycle: the engine state is an input, the controller state is the
 * host's truth. [start] and [stop] are idempotent and thread-safe.
 */
interface PhoneDshHost {
    /** The D14 host state, hot, always has a value (the boot mapping's state). */
    val state: StateFlow<HostState>

    /** The one WebView host, seen through the `:platform` interface. */
    val engine: EngineHost

    /** The D14 machine this facade drives; read-only to callers. */
    val controller: ControllerStateMachine

    /** The host side of the channel: the HELLO responder. */
    val channel: HostChannel

    /** The HELLO this boot sends; the same value the channel encodes. */
    val hello: HostHello

    /**
     * Whether `start()`'s preparation has finished: recovery was attempted, the
     * HELLO is final and the engine has been started.
     *
     * `start()` returns immediately and does this work on the facade's scope, so
     * a caller that must wait (a test, a splash screen, a boot gate) observes
     * this flow instead of guessing how long recovery takes. It is `false`
     * before `start()`, during recovery and after `stop()`; it becomes `true`
     * even when recovery failed, because the host is then ready with `wal/1` off
     * (see [hello]).
     */
    val ready: StateFlow<Boolean>

    /**
     * The WAL's durability claim, verbatim from the injected [HostWal], or
     * `null` when no WAL is attached at all.
     *
     * Never promoted: on the bench-absent device this is
     * [DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED], which means the
     * mechanism exists but the power-loss claim is not measured — treat it
     * exactly like level 1. Whether writes are actually accepted is
     * [hello]`.wal`, not this number.
     */
    val durability: DurabilityLevel?

    /**
     * Closes the current WAL epoch in the D18 order and emits the level-2
     * `VFS_ACK`.
     *
     * Level 2 may be produced only here (channel.md §3.2, D18). A caller that
     * needs the durable point waits for this call; a `VFS_BARRIER` that wants
     * level 2 is answered when it returns.
     *
     * @return the close record's `durable_upto`, or `null` when no WAL/VFS sink
     *   is attached or the sink never opened.
     */
    suspend fun closeEpoch(): Long?

    /** The process boot identity behind [hello] (`boot_id` + wall-clock start). */
    val boot: HostBoot

    /** The one upstream exchange, when a transport and a credential provider exist. */
    val gateway: GatewaySession?

    /** The origin handle, when the facade owns the origin; `null` while `:engine` does. */
    val loopback: LoopbackServer?

    /**
     * The frame consumer `:engine` must be constructed with:
     * `createDemoEngine(context, channelHandler = host.channelHandler, ...)`.
     *
     * `:net`'s `LoopbackChannelHandler` is the one seam the engine takes from its
     * host; exposing it here is what makes "the host answers HELLO" testable
     * without a WebView.
     */
    val channelHandler: LoopbackChannelHandler get() = channel

    /**
     * Starts preparation asynchronously; returns immediately.
     *
     * The facade recovers the WAL, finalizes [hello], subscribes to the engine
     * and the OS signals, then starts the engine. Observe [ready] for the point
     * where all of that has happened; a worker HELLO is not answered before it.
     */
    fun start()

    /** Stops the engine and the subscriptions; idempotent. */
    fun stop()
}

/**
 * The production facade.
 *
 * Construction is pure: it mints the boot id, builds the initial HELLO and
 * creates the channel, but starts nothing and runs no I/O. [start] returns
 * immediately and launches one preparation job: recovery first, then the final
 * HELLO, the collectors and `engine.start()`. [ready] flips to `true` at the end
 * of that job, and the channel refuses to answer a worker HELLO before it.
 *
 * @param engine the one WebView host; `DemoEngine` satisfies this through
 *   `:platform.EngineHost` without this module naming `:engine`.
 * @param controller the D14 machine, usually `ControllerStateMachine.boot(...)`.
 * @param clock the only time source; every controller signal is stamped with
 *   `monotonicMillis()` because D14 deadlines are durations.
 * @param signals the flattened scene/thermal/battery/network/app-foreground
 *   stream.
 * @param notifier the user-visible surface for the effects this lane owns.
 * @param gateway held for the exec/API lane; `null` until a transport exists.
 * @param loopback held for the origin-ownership step; `null` while `:engine`
 *   binds its own origin.
 * @param wal the WAL seam; production passes
 *   `WorkspaceLog(paths, durability, clock).asHostWal()`. `null` (no log at all)
 *   is honest for tests and for a build without a workspace: `wal/1` stays off
 *   and the watermark stays not-wired.
 * @param journal the journal store (`journal/` in the same workspace), or
 *   `null` for a build with no workspace. It is recovered in [start] before the
 *   HELLO is final and before the engine starts; only a store that recovered
 *   leaves the sink open, and only an open sink accepts `JOURNAL`. There is no
 *   host journal capability to advertise (`channel.md` §4.1), so the HELLO is
 *   identical whether or not this is present.
 * @param exec the `exec/1` bridge. The default builds the `phone` accelerator
 *   ([HostExec.defaultTools]); pass `null` to advertise no `exec/1` (the type-level
 *   zero-tool case) or a prebuilt bridge for a larger tool set.
 * @param lease the `Recovering -> Running` guard; [LeaseProbe.LocalOnly] is the
 *   current single-process topology.
 * @param sessionEpoch the host session incarnation of §4.1. No persisted session
 *   counter exists yet, so the default 0 means "none established" rather than a
 *   plausible-looking number.
 * @param logger the facade's log seam; [HostLog.Println] by default because the
 *   `mseq-watermark` provenance and the `wal/1` on/off reason must be visible.
 * @param onWorkerConsole optional observer for `CONSOLE` text; the App uses it
 *   for the Worker's `XL_DSH_READY` announcement.
 * @param scope where the boot job and the collectors run. Tests inject
 *   `CoroutineScope(Dispatchers.Unconfined)` for determinism; production uses the
 *   default dispatcher and only ever collects `StateFlow`s and one hot stream.
 * @param retryProbe the "one probe succeeded" seam of `Backoff -> Running`
 *   (budgets.md §2). It defaults to one lease check — the only check that row's
 *   Actions column names — through the same [LeaseProbe] the `Recovering ->
 *   Running` guard uses; see [RetryProbe] for why it is not the NWPath check.
 * @param retryPolicy the retry schedule of one `Backoff` entry.
 * @param stateStore `host-state.json` (`PERSIST_HOST_STATE`). `null` keeps the
 *   pre-P15 behaviour — every boot is a cold start — which is honest for a
 *   build with no workspace; the App passes a store so a `Parked` host survives
 *   a kill and the §3 boot mapping is reachable.
 */
class DefaultPhoneDshHost(
    override val engine: EngineHost,
    override val controller: ControllerStateMachine,
    private val clock: Clock,
    private val signals: LifecycleSignals,
    private val notifier: Notifier,
    override val gateway: GatewaySession? = null,
    override val loopback: LoopbackServer? = null,
    private val wal: HostWal? = null,
    private val journal: JournalStore? = null,
    private val lease: LeaseProbe = LeaseProbe.LocalOnly,
    sessionEpoch: Long = 0L,
    random: SecureRandom = SecureRandom(),
    private val logger: HostLog = HostLog.Println,
    private val exec: ExecBridge? = HostExec.defaultTools(clock, controller, wal, logger),
    private val onWorkerConsole: ((String) -> Unit)? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val retryProbe: RetryProbe = RetryProbe.leaseCheck(lease),
    private val retryPolicy: RetryPolicy = RetryPolicy.DEFAULT,
    private val stateStore: HostStateStore? = null,
    /**
     * This boot's budgets.md §4 row, selected once from the physical memory
     * ceiling by [HostBudgetTier] (the App reads `MemoryInfo.totalMem`).
     *
     * It is a parameter rather than something the facade measures because the
     * facade has no `Context`: the composition root owns the device and this
     * class owns the budget the device may use.
     *
     * The default is the **smallest** row, [HostBudgetTier.UNMEASURED] (`≤ 3 GiB`
     * → 16 MiB), not the §4 8 GiB row. budgets.md:95-97 only maps a *known*
     * ceiling and never states the unknown case, so "no measurement" gets the
     * same answer as a failed reading: the side that can only shrink a quota.
     * A default of 8 GiB here would have re-opened this lane's own bug for every
     * caller that forgot to measure — a `≤ 3 GiB` device with an 8× file quota.
     */
    private val deviceBudgets: ControllerBudgets = HostBudgetTier.UNMEASURED,
) : PhoneDshHost {
    override val boot: HostBoot = HostBoot.generate(clock, random)

    /** The exec lane's contribution to the HELLO; empty when no bridge exists. */
    private val execCapability: ExecCapability =
        exec?.capability ?: ExecCapability.Unavailable

    /**
     * The HELLO value. It starts as the honest "recovery has not run" value and
     * is replaced once, in [start], by one whose [WalUplink] comes from
     * recovery. [HostChannel] reads this property at send time.
     */
    @Volatile
    private var helloState: HostHello = HostHello(
        bootId = boot.bootId,
        sessionEpoch = sessionEpoch,
        fence = HostFence.LOCAL,
        wal = WalUplink.down("recovery has not run; start() not called"),
        exec = execCapability,
    )

    override val hello: HostHello get() = helloState

    private val readyState = MutableStateFlow(false)

    override val ready: StateFlow<Boolean> = readyState.asStateFlow()

    /**
     * The one place a durable write failure becomes a D14 failure.
     *
     * [VfsSink] and [HostChannel] report the attributable store codes here;
     * [handle] turns each report into `ControllerSignal.FailureRaised`, so the
     * transition table closes admission and records the condition instead of
     * only the transport closing. Declared before the sinks because they hold
     * it. It is invoked only after construction (no frame exists before
     * [start] and a channel attachment), so [effects] and [mutableState] are
     * initialized by the time it can run.
     */
    private val writeFailures: WriteFailureSink = WriteFailureSink { reason, detail ->
        handle(ControllerSignal.FailureRaised(reason = reason, detail = detail))
    }

    /**
     * The VFS sink behind `wal/1`; created even when recovery later fails,
     * because the channel needs a place to send a protocol error. It is only
     * [VfsSink.open]ed on a successful recovery, and only then can it mint the
     * proof that allows `wal/1` into the HELLO.
     *
     * It takes no admission gate: channel.md §7 item 6 keeps "flushing and
     * in-flight work" running while admission is closed, so the durability path
     * of a frame the worker already emitted is not a new side effect (P26).
     */
    private val vfsSink: VfsSink? = wal?.let {
        VfsSink(
            wal = it,
            logger = logger,
            failures = writeFailures,
            // budgets.md §4's `single_file_limit` for this device tier; the sink
            // refuses an over-limit mutation with `VFS_REFUSED` (channel.md §8).
            singleFileLimitBytes = deviceBudgets.singleFileBytes,
        )
    }

    /**
     * The journal lane behind `JOURNAL`; `null` when no journal store was
     * injected.
     *
     * Opening it is what lets `HostChannel` persist a record; without it those
     * frames are logged and ignored, never acknowledged. `channel.md` §4.1 has
     * no host journal capability, so this sink's state changes no HELLO member:
     * the open flag is only the dispatch gate, and inventing a capability string
     * for it would be refused by [HostCapabilities] anyway.
     */
    private val journalSink: JournalSink? = journal?.let { JournalSink(it, logger) }

    override val channel: HostChannel = HostChannel(
        hello = { hello },
        logger = logger,
        vfs = vfsSink,
        journal = journalSink,
        exec = exec,
        ready = { readyState.value },
        onConsole = onWorkerConsole,
        failures = writeFailures,
    )

    /** The WAL's own claim, verbatim; `null` when no log was injected. */
    override val durability: DurabilityLevel? = wal?.durabilityClaim()

    private val effects = ControllerEffects(notifier, logger)

    /**
     * The owner of `Draining -> Parked`, i.e. of the drain's exit.
     *
     * budgets.md §2 lists the row's actions (close the epoch, fsync, stop the
     * worker) and returns; before this lane existed no main source set performed
     * them and nothing ever fed `DrainCompleted`, so one `scenePhase(background)`
     * left the host in `Draining` for the life of the process and every return
     * to the foreground was an `ILLEGAL_TRANSITION` (P5/P10). See [DrainLane]
     * for what it performs and for why the deadline is a bound rather than a
     * wait.
     */
    private val drain = DrainLane(
        scope = scope,
        clock = clock,
        closeEpoch = { closeEpoch() },
        stopWorker = { stopWorkerForDrain() },
        awaitWorkerStopped = { awaitWorkerStopped() },
        onDeadlineElapsed = { handle(ControllerSignal.DrainDeadlineElapsed) },
        onDrained = { outcome -> onDrained(outcome) },
        logger = logger,
    )

    /**
     * The owner of `Backoff -> Running`, i.e. of the retry schedule's two
     * signals.
     *
     * budgets.md §2's `Running -> Backoff` Actions column says "start the retry
     * schedule" and the `Backoff -> Running` guard needs "Retry-After elapsed
     * ... one probe succeeded"; before this lane existed neither
     * `RetryAfterElapsed` nor `RetryProbeSucceeded` had a producer in any main
     * source set, so one network loss parked the host in `Backoff` for the life
     * of the process (P15 reproduced it on emulator API 35, 2026-11-01). See
     * [RetryLane] for what it performs and for the contract hole it documents.
     */
    private val retry = RetryLane(
        scope = scope,
        clock = clock,
        probe = retryProbe,
        policy = retryPolicy,
        onRetryAfterElapsed = { attempt ->
            logger.info(
                "retry: window elapsed (${attempt.entry.wireName}, attempt ${attempt.attempt}); " +
                    "feeding RetryAfterElapsed",
            )
            handle(ControllerSignal.RetryAfterElapsed)
        },
        onProbeSucceeded = { attempt ->
            logger.info(
                "retry: probe succeeded (${attempt.entry.wireName}, attempt ${attempt.attempt}); " +
                    "feeding RetryProbeSucceeded(leaseVerified=true)",
            )
            handle(ControllerSignal.RetryProbeSucceeded(leaseVerified = true))
        },
        logger = logger,
    )

    /**
     * `true` when a foreground return arrived while the host was `Draining` and
     * the resume is waiting for the drain to finish.
     *
     * §2 has no `Draining -> Running` row, so the facade must not hand that
     * signal to the machine; it re-feeds the same signal after
     * `Draining -> Parked` has been recorded, which is the one legal path back.
     */
    @Volatile
    private var resumeAfterDrain: Boolean = false

    private val mutableState = MutableStateFlow(controller.state)

    override val state: StateFlow<HostState> = mutableState.asStateFlow()

    private val started = AtomicBoolean(false)

    /**
     * Invalidates a boot job that was launched by a previous [start] when
     * [stop] (or a later start) intervened. `started` alone cannot tell an old
     * job from a new one after stop/start.
     */
    private val bootGeneration = AtomicLong(0L)

    /** Serialises `ControllerStateMachine.handle` (the machine is not thread-safe). */
    private val signalLock = Any()
    private val jobsLock = Any()
    private val jobs = mutableListOf<Job>()

    /**
     * The last `AppForeground`. Starts `true` because a cold start shows an
     * Activity; the first real event overwrites it. Only used to label an engine
     * termination, never to drive a transition on its own.
     */
    @Volatile
    private var foreground: Boolean = true

    override fun start() {
        if (!started.compareAndSet(false, true)) {
            logger.info("start ignored: the host facade is already started")
            return
        }
        readyState.value = false
        val generation = bootGeneration.incrementAndGet()
        // start() returns here; the expensive part (one cold recovery scan) runs
        // on the facade's scope. The HELLO is not final until the job has built
        // it, so HostChannel refuses worker HELLOs while ready is false.
        val bootJob = scope.launch {
            if (!current(generation)) return@launch
            val uplink = recoverWal()
            if (!current(generation)) return@launch
            helloState = helloState.copy(wal = uplink)
            openJournal()
            if (!current(generation)) return@launch
            logBoot()
            effects.onBoot(controller)
            // The boot mapping's own effects: the retry schedule first — its
            // remaining window is read from the record this boot consumed — and
            // then a fresh record so the next boot reads this boot's state.
            // `Backoff` is the one booted state whose only exit needs a producer
            // in this process.
            armRetryAfterBoot()
            persistHostState()
            if (!current(generation)) return@launch
            val engineJob = launch { engine.state.collect { onEngineState(it) } }
            val signalsJob = launch { signals.events.collect { onLifecycleSignal(it) } }
            if (!current(generation)) {
                engineJob.cancel()
                signalsJob.cancel()
                return@launch
            }
            synchronized(jobsLock) {
                jobs += engineJob
                jobs += signalsJob
            }
            engine.start()
            if (!current(generation)) {
                engine.stop()
                return@launch
            }
            readyState.value = true
            logger.info("host ready: recovery done, HELLO final, engine started")
        }
        synchronized(jobsLock) { jobs += bootJob }
    }

    override fun stop() {
        if (!started.compareAndSet(true, false)) {
            logger.info("stop ignored: the host facade is not started")
            return
        }
        bootGeneration.incrementAndGet()
        readyState.value = false
        retry.release()
        val cancelled = synchronized(jobsLock) { jobs.toList().also { jobs.clear() } }
        cancelled.forEach { it.cancel() }
        engine.stop()
        notifier.cancel(ControllerEffects.BOOT_RECOVERY_NOTIFICATION_ID)
        logger.info("host stopped: engine stopped, subscriptions cancelled")
    }

    /** `true` while [generation] is the boot job the facade still wants. */
    private fun current(generation: Long): Boolean =
        started.get() && bootGeneration.get() == generation

    override suspend fun closeEpoch(): Long? = vfsSink?.closeEpoch()

    /**
     * Diagnostic: `true` while the drain of the current `Draining` entry is still
     * performing its row (epoch close / worker stop).
     *
     * Exposed for the JVM tests so "the drain has an exit" is asserted on the
     * facade's own state rather than inferred from a log line.
     */
    internal fun isDrainInFlight(): Boolean = drain.isDraining

    // ---- wiring -----------------------------------------------------------------

    /**
     * One engine lifecycle observation.
     *
     * The engine state is fed to the machine on every change (so D14 records the
     * termination edge and the facade can see `Running`), and a reachable engine
     * is the trigger for the lease probe that lets `Recovering -> Running` fire.
     */
    internal fun onEngineState(state: EngineHostState) {
        logger.info("engine state: ${describe(state)}")
        handle(HostSignalMapping.engine(state, foreground))
        if (state is EngineHostState.Running) maybeVerifyLease()
    }

    /**
     * One OS lifecycle observation, translated and fed to the machine.
     *
     * `LifecycleSignals` promises exactly one `LifecycleSnapshot` as the first
     * frame of a subscription; its members are expanded here, in the adapter's
     * order, before any single change event. A snapshot is a batch, not a state.
     */
    internal fun onLifecycleSignal(signal: LifecycleSignal) {
        if (signal is LifecycleSnapshot) {
            logger.debug("lifecycle snapshot: ${signal.signals.size} signal(s)")
            for (member in signal.signals) applySignal(member)
            maybeVerifyLease()
            return
        }
        applySignal(signal)
        maybeVerifyLease()
    }

    private fun applySignal(signal: LifecycleSignal) {
        if (signal is AppForeground) {
            foreground = signal.foreground
            logger.debug("app foreground: ${signal.foreground}")
            return
        }
        val mapped = HostSignalMapping.from(signal) ?: return
        logger.debug("lifecycle signal: ${mapped.label}")
        handle(mapped)
    }

    /**
     * Feeds one signal at monotonic time and publishes the resulting D14 state.
     *
     * `handle` is synchronised because the machine documents that it is not
     * thread-safe: Ktor closes a channel on one thread, the UI pushes scene
     * phases on another.
     *
     * A foreground return while `Draining` is the one signal this facade never
     * hands to the machine as-is. §2 has no `Draining -> Running` row, so the
     * machine would refuse it (`ILLEGAL_TRANSITION`) and the App would stay
     * unusable until a force-stop — exactly the P5/P10 defect. The facade lets
     * the drain finish and then re-feeds the same `scenePhase(active)`, which
     * *is* a row (`Parked -> Recovering`), so the round trip stays inside the
     * table instead of adding an edge to it.
     *
     * `internal` because it is the facade's one signal entry point and two
     * callers are not `LifecycleSignals`: the retry lane (in this module) and a
     * future model edge, whose `UpstreamUnavailable(429)` is a D14 signal with
     * no OS observation behind it. The machine stays the only place that decides
     * what a signal means.
     */
    internal fun handle(signal: ControllerSignal) {
        if (signal is ControllerSignal.ScenePhaseChanged && signal.phase == ScenePhase.ACTIVE) {
            if (controller.state == HostState.DRAINING) {
                resumeAfterDrain = true
                logger.info("scenePhase(active) in Draining: the drain finishes first, then the resume")
                if (!drain.foregroundReturn()) {
                    // The drain finished between the state check and this call, or
                    // no drain was ever armed (a boot mapping cannot produce this,
                    // but a composition that armed nothing would). Either way the
                    // exit must be taken here instead of waiting for one.
                    when (controller.state) {
                        HostState.DRAINING -> {
                            logger.warn("no drain was in flight in Draining; arming it now to take the exit")
                            drain.arm(controller.drainDeadlineAtMillis)
                            if (drain.isDraining) drain.foregroundReturn()
                        }

                        HostState.PARKED -> {
                            // The completion ran before `resumeAfterDrain` was set,
                            // so its own resume did not see it: take the row here.
                            logger.info("the drain completed just now; the resume runs here (Parked -> Recovering)")
                            resumeAfterDrain = false
                            dispatch(signal)
                        }

                        else -> Unit
                    }
                }
                return
            }
            if (controller.state == HostState.RECOVERING) {
                // `Parked -> Recovering` starts the worker; an already-Recovering
                // host has no such row, so a return here must not stall in a
                // state whose only exit is the lease check.
                startWorker("foreground return in Recovering")
            }
        }
        dispatch(signal)
    }

    private fun dispatch(signal: ControllerSignal) {
        val atMillis = clock.monotonicMillis()
        val outcome = synchronized(signalLock) {
            controller.handle(signal, atMillis).also { mutableState.value = controller.state }
        }
        report(outcome)
        effects.onOutcome(outcome, controller)
        applyHostEffects(outcome, signal)
        // The machine records an NWPath observation in `Backoff` without taking
        // an edge ("network path recorded for the Backoff guard"); the retry
        // lane is what turns that observation into a probe. It only *waits* on
        // this value — the D14 signal was the one fed above.
        if (signal is ControllerSignal.NetworkPathChanged && controller.state == HostState.BACKOFF) {
            retry.onNetworkPath(signal.status == NetworkPathStatus.SATISFIED)
        }
    }

    /**
     * Performs the effects of a row that belong to this facade rather than to the
     * notifier surface.
     *
     * Two groups are owned here:
     * * `ARM_DRAIN_DEADLINE` — the drain's exit ([drain]); `START_BACKGROUND_TASK`
     *   is reported by it as "no background window" (this App declares no
     *   service), never as a silent drop;
     * * `START_WORKER` / `RESTART_WORKER` — the `:engine` seam. Without these the
     *   resume path `Parked -> Recovering` would reach `Recovering` with a
     *   stopped worker, and `Recovering -> Running` waits for an engine that
     *   nobody started. That would be the same dead end one state later.
     *
     * Two more are owned by the lanes this facade holds, added by P15:
     * * `START_RETRY_SCHEDULE` — [retry], armed once per `Backoff` entry. It is
     *   the only producer of the two signals that end that state;
     * * `PERSIST_HOST_STATE` — [stateStore], so the §3 boot mapping has a file
     *   to read.
     *
     * `CLOSE_EPOCH` / `FSYNC_MATERIALIZED` / `STOP_WORKER` on `Draining -> Parked`
     * are *not* performed here: the drain lane performed them before it fed
     * `DrainCompleted`, and a second close would tear the epoch it just closed.
     */
    private fun applyHostEffects(outcome: SignalOutcome, signal: ControllerSignal) {
        when (outcome) {
            is SignalOutcome.Transitioned -> {
                val record = outcome.record
                if (record.to == HostState.DRAINING) resumeAfterDrain = false
                if (ControllerEffect.FORCE_DRAIN_DEADLINE in record.effects) {
                    abortInFlightWork("forced by the drain deadline")
                }
                if (ControllerEffect.ARM_DRAIN_DEADLINE in record.effects) {
                    drain.arm(controller.drainDeadlineAtMillis)
                }
                if (
                    ControllerEffect.START_WORKER in record.effects ||
                    ControllerEffect.RESTART_WORKER in record.effects
                ) {
                    startWorker(record.signal)
                }
                if (record.from == HostState.BACKOFF && record.to != HostState.BACKOFF) {
                    // The exit was taken (or another row took the state): no
                    // window of the old entry may fire in the new state.
                    retry.release()
                }
                if (ControllerEffect.START_RETRY_SCHEDULE in record.effects) {
                    armRetry(record.signal, signal)
                }
                if (ControllerEffect.PERSIST_HOST_STATE in record.effects) persistHostState()
                if (record.from == HostState.DRAINING) {
                    logger.debug(
                        "drain actions already performed by the drain lane (${record.signal}); " +
                            "no second epoch close here",
                    )
                }
            }

            is SignalOutcome.Observed -> {
                // The machine records the force on the drain; the abort itself is
                // the transport teardown below (the worker stop), which is the
                // only "in-flight request" surface this host has per connection.
                if (ControllerEffect.FORCE_DRAIN_DEADLINE in outcome.effects) {
                    abortInFlightWork("forced by the drain deadline signal")
                }
            }

            is SignalOutcome.Rejected -> Unit
        }
    }

    /**
     * Arms the retry schedule of a `Backoff` entry.
     *
     * The entry decides whether a `Retry-After` exists at all: an NWPath
     * unsatisfied row has no HTTP response behind it (the contract hole
     * [RetryLane] documents), an upstream 429/5xx may have one — but nothing in
     * this composition produces `UpstreamUnavailable` yet, so no hint is ever
     * available here and the schedule's own delay is the window. The branch
     * stays explicit so the model edge can pass a hint the day it exists.
     */
    private fun armRetry(label: String, signal: ControllerSignal) {
        val entry = when (signal) {
            is ControllerSignal.NetworkPathChanged -> RetryLane.Entry.NETWORK_PATH
            is ControllerSignal.UpstreamUnavailable -> RetryLane.Entry.UPSTREAM
            // Only those two rows carry the effect; anything else would mean the
            // table grew a third Backoff entry and this switch must learn it.
            else -> null
        }
        if (entry == null) {
            logger.warn("START_RETRY_SCHEDULE on '$label' is not a Backoff entry this facade knows")
            return
        }
        retry.arm(entry)
    }

    /**
     * Arms the retry schedule when the boot mapping itself restored `Backoff`
     * (budgets.md §3: persisted `Backoff` -> `Backoff`).
     *
     * The boot mapping emits `START_RETRY_SCHEDULE` as an initial effect, and
     * that state has no other exit: without this call a host killed in
     * `Backoff` would boot into the same dead end. The remainder of the window
     * comes from `host-state.json`'s `backoff_until_ms` (the Swift reference
     * persists the same field), so a restart does not restart the schedule; a
     * missing or already-past deadline arms the ordinary first window instead
     * of trapping the host.
     */
    private fun armRetryAfterBoot() {
        if (controller.state != HostState.BACKOFF) return
        val remaining = stateStore?.load()?.backoffUntilMillis?.let { deadline ->
            (deadline - clock.nowMillis()).coerceAtLeast(0L)
        }
        logger.info(
            "boot restored Backoff: arming the retry schedule " +
                "(${remaining?.let { "remaining window $it ms" } ?: "the schedule's first delay"})",
        )
        retry.arm(RetryLane.Entry.BOOT, firstWindowMillis = remaining)
    }

    /**
     * Performs `PERSIST_HOST_STATE` (budgets.md §2's Actions column, emitted on
     * every transition and on the boot mapping).
     *
     * A failed write is logged, not raised: §2 has no row for it, the D14 state
     * has already been recorded, and the next transition writes again.
     */
    private fun persistHostState() {
        val store = stateStore
        if (store == null) {
            logger.debug("effect 'persist host-state.json atomically' has no store in this composition")
            return
        }
        store.save(controller, retry.backoffUntilMillis)
    }

    /**
     * Ends the in-flight channel work of a drain: admission is already closed
     * (no new `VFS_MUT` is accepted), and the connection is torn down by the
     * worker stop that follows. Logged so the effect has a visible owner.
     */
    private fun abortInFlightWork(reason: String) {
        logger.warn("drain aborts in-flight channel work ($reason): admission is closed, the worker is stopped")
    }

    /**
     * Starts the engine for a row that asks for a worker (`START_WORKER`,
     * `RESTART_WORKER`, or a foreground return in `Recovering`).
     *
     * `EngineHost.start()` is idempotent and ignores a start while Starting or
     * Running, so this is safe to call on every such row; the log line is what
     * makes a refused start visible instead of a silent no-op.
     */
    private fun startWorker(reason: String) {
        when (val current = engine.state.value) {
            is EngineHostState.Running, EngineHostState.Starting -> logger.info(
                "worker already up (${describe(current)}); no second start for '$reason'",
            )

            EngineHostState.Recovering -> logger.info(
                "engine is recovering on its own; the restart is the engine's, not a second start ('$reason')",
            )

            EngineHostState.Stopped, is EngineHostState.Failed -> {
                logger.info("worker start requested by '$reason' from ${describe(current)}")
                engine.start()
            }
        }
    }

    /** `STOP_WORKER` of the `Draining -> Parked` row: the drain lane's own seam. */
    private fun stopWorkerForDrain() {
        logger.info("drain stops the worker (STOP_WORKER of Draining -> Parked)")
        engine.stop()
    }

    /**
     * Waits for the worker to really be gone: `Parked` means "WebContent stopped"
     * (§1), so the drain must not report the completion before that is true.
     *
     * Bounded: a stop that never reports must not hold the host in `Draining`
     * either, which is the dead end this lane exists to remove.
     */
    private suspend fun awaitWorkerStopped(): Boolean = withTimeoutOrNull(WORKER_STOP_BOUND_MILLIS) {
        engine.state.first { it is EngineHostState.Stopped || it is EngineHostState.Failed }
        true
    } ?: false

    /** The drain lane's one completion: `Draining -> Parked`, then any resume. */
    private fun onDrained(outcome: DrainLane.DrainOutcome) {
        logger.info(
            "drain of this Draining entry is complete (${outcome.reason.wireName}, " +
                "durable_upto=${outcome.durableUpto ?: -1}, worker_stopped=${outcome.workerStopped})",
        )
        dispatch(ControllerSignal.DrainCompleted)
        if (!resumeAfterDrain) return
        resumeAfterDrain = false
        if (controller.state != HostState.PARKED) {
            logger.warn(
                "a foreground return was queued while Draining, but the drain ended in " +
                    "${controller.state.wireName}; the resume is not taken from there",
            )
            return
        }
        logger.info("the drain finished: re-feeding scenePhase(active) as Parked -> Recovering")
        dispatch(ControllerSignal.ScenePhaseChanged(ScenePhase.ACTIVE))
    }

    private fun report(outcome: SignalOutcome) {
        when (outcome) {
            is SignalOutcome.Transitioned -> {
                val record = outcome.record
                logger.info(
                    "D14 ${record.from.wireName} -> ${record.to.wireName} via ${record.signal} " +
                        "at ${record.atMillis} ms (admission=${record.admission.wireName}, " +
                        "effects=${record.effects.size})",
                )
            }

            is SignalOutcome.Observed ->
                logger.debug("D14 observed ${outcome.signal}: ${outcome.note}")

            is SignalOutcome.Rejected ->
                logger.warn(
                    "D14 rejected ${outcome.signal} in ${outcome.from.wireName} " +
                        "(${outcome.reason.name}): ${outcome.detail}",
                )
        }
    }

    /**
     * The `Recovering -> Running` guard (budgets.md §2).
     *
     * Only runs while the machine is in `Recovering` *and* the engine has reached
     * `Running`: a lease check before the worker is up would be a guess dressed as
     * a check. A probe that throws is treated as unverified, not as a pass — the
     * host then stays in `Recovering` and says so.
     */
    private fun maybeVerifyLease() {
        if (controller.state != HostState.RECOVERING) return
        val engineState = engine.state.value
        if (engineState !is EngineHostState.Running) return
        val verified = try {
            lease.verify()
        } catch (failure: Exception) {
            logger.warn("lease probe threw ${failure.javaClass.simpleName}; treating it as unverified")
            false
        }
        logger.info("lease probe: verified=$verified (engine Running on port ${engineState.port})")
        handle(ControllerSignal.LeaseCheckResult(verified))
    }

    /**
     * Recovers the injected WAL and decides whether `wal/1` may be advertised.
     *
     * The capability is on only when [HostWal.recover] returned
     * [WalRecovery.Recovered], its numbers are a §4.1-legal HELLO watermark, and
     * the VFS sink opened on those numbers (which is what mints the
     * `VfsSink.Wired` proof [WalUplink.up] requires). A missing seam, a thrown
     * failure, a [WalRecovery.Failed] and an illegal watermark all produce
     * [WalUplink.Down], so the HELLO keeps the channel-only capability set and
     * the not-wired zero watermark. The reason logged here is a code or a class
     * name — never an exception message, a path or a token.
     */
    private suspend fun recoverWal(): WalUplink {
        val hostWal = wal ?: return WalUplink.down("no HostWal injected")
        val recovered = try {
            hostWal.recover()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            val kind = failure.javaClass.simpleName
            logger.warn("workspace log recovery threw $kind; wal/1 stays off")
            return WalUplink.down("recovery threw $kind")
        }
        return when (recovered) {
            is WalRecovery.Recovered -> recoveredUplink(recovered)

            is WalRecovery.Failed -> {
                logger.warn("workspace log recovery failed (${recovered.code}); wal/1 stays off")
                WalUplink.down("recovery failed (${recovered.code})")
            }
        }
    }

    /**
     * The recovered numbers, if and only if they can legally appear in a HELLO
     * and the VFS sink could be opened on them.
     *
     * `Observed` rejects negatives and [WalUplink.up] re-checks the §4.1
     * relations, but the rule is written out here as well so a bad log is turned
     * into the honest `Down` value (with a log line) rather than an exception
     * thrown out of the boot job.
     */
    private suspend fun recoveredUplink(recovered: WalRecovery.Recovered): WalUplink {
        val next = recovered.nextMseq
        val acked = recovered.ackedMseq
        val durable = recovered.durableMseq
        val legal = next >= MseqWatermark.MIN_NEXT_MSEQ &&
            next > acked &&
            acked >= 0L &&
            durable >= 0L &&
            durable <= acked
        if (!legal) {
            logger.warn(
                "workspace log recovered a watermark outside channel.md §4.1 " +
                    "(next_mseq=$next, acked_mseq=$acked, durable_mseq=$durable); " +
                    "wal/1 stays off",
            )
            return WalUplink.down("recovered watermark violates channel.md §4.1")
        }
        // The sink must be opened before the HELLO claims wal/1: its proof is
        // the only way to construct WalUplink.Up, and opening it seeds the VFS
        // watermarks from the same recovery report.
        val wired = vfsSink?.open(recovered)
        if (wired == null) {
            logger.warn("WAL recovered but there is no VFS sink; wal/1 stays off")
            return WalUplink.down("no VFS sink attached")
        }
        return WalUplink.up(
            MseqWatermark.Observed(nextMseq = next, ackedMseq = acked, durableMseq = durable),
            wired,
        )
    }

    /**
     * Recovers the journal store and opens the sink, or leaves the lane off.
     *
     * `channel.md` §4.1 defines no host journal capability, so there is nothing
     * in the HELLO that could claim this lane either way. What the store's
     * recovery decides is whether `HostChannel` may persist a `JOURNAL` frame:
     * an absent store, a thrown failure or a `JOURNAL_CORRUPT` leaves the sink
     * closed, and the channel then logs and ignores those frames instead of
     * answering them. It never acks a record it did not fsync — that lie was the
     * N1 test seam, and it is exactly what this facade must not reproduce.
     *
     * A failure here does not fail the boot: the rest of the host (WAL, exec,
     * the engine) is independent, and the controller's `Failed` state is driven
     * by a journal *write* failure, not by a recovery that found nothing usable.
     */
    private suspend fun openJournal() {
        val store = journal
        val sink = journalSink
        if (store == null || sink == null) {
            logger.info("journal: off (no JournalStore injected; JOURNAL frames are ignored)")
            return
        }
        // A `start()` after `stop()` re-runs recovery; until this boot's store is
        // open again, no frame may be accepted on the previous boot's state.
        sink.close()
        val recovered = try {
            store.recover()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: JournalException) {
            logger.warn("journal: recovery failed (${failure.failure.code}); the lane stays off")
            return
        } catch (failure: Exception) {
            logger.warn(
                "journal: recovery threw ${failure.javaClass.simpleName}; the lane stays off",
            )
            return
        }
        sink.open(recovered)
    }

    private fun logBoot() {
        logger.info(
            "host boot: boot_id=${boot.bootId}, started_at=${boot.startedAtMillis} ms, " +
                "session_epoch=${hello.sessionEpoch}, caps=${hello.capabilities.describe()}",
        )
        when (val uplink = hello.wal) {
            is WalUplink.Up ->
                logger.info("wal/1: on (workspace log recovered; watermark is observed)")

            is WalUplink.Down -> logger.warn("wal/1: off (${uplink.reason})")
        }
        logger.info(
            "host HELLO watermark: next_mseq=${hello.watermark.nextMseq}, " +
                "acked_mseq=${hello.watermark.ackedMseq}, durable_mseq=${hello.watermark.durableMseq} " +
                "(${hello.watermark.provenance})",
        )
        logger.info("durability claim: ${durability?.name ?: "none (no WAL attached)"}")
        // budgets.md §4: the tier is selected once per boot; print the selected
        // row and the derived single_file_limit so a device whose ceiling landed
        // in a smaller row is visible in the field, not only in a test.
        logger.info(
            "budget tier: ${deviceBudgets.tier.displayName} (budgets.md §4), " +
                "single_file_limit: ${deviceBudgets.singleFileBytes} bytes " +
                "(${deviceBudgets.singleFileBytes / ControllerBudgets.MIB} MiB), " +
                "workspace: ${deviceBudgets.workspaceBytes} bytes, " +
                "VFS logical: ${deviceBudgets.vfsLogicalBytes} bytes, " +
                "engine heap: ${deviceBudgets.engineHeapBytes} bytes",
        )
        val journalLane = journalSink?.takeIf { it.isOpen }
        if (journalLane == null) {
            logger.info("journal: off (no store opened this boot; JOURNAL frames are ignored)")
        } else {
            logger.info(
                "journal: on (${journalLane.watermarks().size} session(s), fsync before every ACK)",
            )
        }
        if (!hello.watermark.satisfiesHelloRules) {
            logger.warn(
                "host HELLO watermark violates channel.md §4.1 (next_mseq >= 1 and " +
                    "next_mseq > acked_mseq): ${hello.watermark.provenance}; " +
                    "the packaged worker answers BAD_PAYLOAD to such a HELLO",
            )
        }
        if (HostCapabilities.EXEC !in hello.capabilities.values) {
            logger.info(
                "exec/1: off (no ExecBridge); the packaged worker requires it too, " +
                    "so the channel's capability gate does not pass this boot",
            )
        }
        if (loopback == null) {
            logger.info("origin: bound by :engine; the facade holds no LoopbackServer this boot")
        } else {
            logger.info("origin: the facade holds its own LoopbackServer")
        }
        if (gateway == null) {
            logger.debug("gateway: not wired into the facade yet")
        }
    }

    private fun describe(state: EngineHostState): String = when (state) {
        EngineHostState.Stopped -> "Stopped"
        EngineHostState.Starting -> "Starting"
        is EngineHostState.Running -> "Running(port=${state.port})"
        EngineHostState.Recovering -> "Recovering"
        is EngineHostState.Failed -> "Failed(${state.reason})"
    }

    companion object {
        /**
         * The notification id the facade cancels on [stop]; mirrors
         * [ControllerEffects.BOOT_RECOVERY_NOTIFICATION_ID] for callers outside
         * the module that need to correlate the notification.
         */
        const val BOOT_RECOVERY_NOTIFICATION_ID: Int = ControllerEffects.BOOT_RECOVERY_NOTIFICATION_ID

        /**
         * How long the drain waits for `EngineHost.stop()` to report `Stopped`
         * before it reports `Parked` anyway.
         *
         * `Parked` claims "WebContent stopped" (§1), so the drain waits; but a
         * stop that never reports must not become the dead end this lane exists
         * to remove, hence the bound and the warning.
         */
        const val WORKER_STOP_BOUND_MILLIS: Long = 5_000L
    }
}
