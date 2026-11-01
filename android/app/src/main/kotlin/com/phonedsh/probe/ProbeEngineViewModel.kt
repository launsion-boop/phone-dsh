// The composition root: the one place :app names both the engine and the host.
// SPDX-License-Identifier: MIT
// It constructs DefaultPhoneDshHost, hands its channelHandler to createDemoEngine
// and forwards start/stop. The screen stays a pure function of the engine's flows.
package com.phonedsh.probe

import android.app.Application
import android.os.PowerManager
import android.util.Log
import android.view.View
import android.webkit.WebView
import androidx.lifecycle.AndroidViewModel
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.FileRequestLedger
import com.phonedsh.dsh.host.DefaultPhoneDshHost
import com.phonedsh.dsh.host.HostApiException
import com.phonedsh.dsh.host.HostBudgetTier
import com.phonedsh.dsh.host.HostExec
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.HostStateStore
import com.phonedsh.dsh.host.ModelRoute
import com.phonedsh.dsh.host.ModelRouteFact
import com.phonedsh.dsh.host.PhoneDshHost
import com.phonedsh.dsh.host.asHostWal
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalPaths
import com.phonedsh.dsh.journal.JournalStore
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.engine.AndroidEngineLogger
import com.phonedsh.engine.ApkWorkerAssetSource
import com.phonedsh.engine.BootOverlaySource
import com.phonedsh.engine.ChannelStatus
import com.phonedsh.engine.DemoEngine
import com.phonedsh.engine.EngineLogger
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.engine.MaterializedBootOverlaySource
import com.phonedsh.engine.WorkerAssets
import com.phonedsh.engine.WebViewKernelReport
import com.phonedsh.engine.createDemoEngine
import com.phonedsh.engine.info
import com.phonedsh.gateway.AllowListEgressPolicy
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.HttpUrlConnectionGatewayTransport
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackModelProxy
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.NotificationAction
import com.phonedsh.platform.Notifier
import com.phonedsh.platform.NotifierAvailability
import com.phonedsh.platform.android.AndroidClock
import com.phonedsh.platform.android.AndroidDurability
import com.phonedsh.platform.android.AndroidLifecycleSignals
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.page.FactState
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

/**
 * Owns the one engine **and** the one host across configuration changes.
 *
 * Before K5 this view model constructed the engine with a do-nothing channel
 * handler, so the page's HELLO was never answered and the screen showed
 * `hostCaps=[]`. It now builds the real [DefaultPhoneDshHost] and passes
 * `host.channelHandler` to the engine: the host HELLO, its caps and its
 * watermark are produced by `:dsh` from the recovered workspace log and the real
 * `phone` accelerator, not by this file.
 *
 * [start] is the host's asynchronous `start()`: it returns immediately, runs
 * recovery on the host's own scope and starts the engine only after the HELLO
 * is final. Nothing here blocks the UI thread.
 *
 * [runTurn] is the App's own `/api` path: the real [DshTurnClient] sends
 * `session/create`, `session/follow` and `session/prompt` over the channel the
 * Worker opened. The model behind the Worker is scripted by the acceptance
 * runner; this class makes no claim about inference.
 */
class ProbeEngineViewModel(application: Application) : AndroidViewModel(application) {
    private val logger: EngineLogger = AndroidEngineLogger()

    /** The launch values read before this view model was constructed. */
    private val launchConfig: ProbeLaunchConfig = ProbeLaunchConfig.active()

    /**
     * budgets.md §4's device tier for this boot, selected from the physical
     * memory ceiling.
     *
     * This is the one place the App reads `ActivityManager.MemoryInfo.totalMem`
     * (`HostBudgetTier.forDevice`); §4 says the tier is selected **once per
     * boot**, so the value is a `val` and a later memory-pressure reading cannot
     * re-tier the host. The same object feeds the two surfaces the limit needs:
     * the Worker environment (so its write surfaces refuse with `EFBIG` before
     * publishing) and [DefaultPhoneDshHost] (so the host VFS sink answers
     * `VFS_REFUSED` as the backstop).
     *
     * Before this existed the App never measured anything: a 2 GiB device kept
     * the Worker's 8 GiB default of 128 MiB and accepted a file its §4 row caps
     * at 16 MiB.
     */
    private val deviceBudgets: ControllerBudgets = HostBudgetTier.forDevice(application)

    /**
     * The host credential provider for this launch, or `null` when there is no
     * model endpoint or no installed key store.
     *
     * One object serves both the `/v1/http` gateway and the model edge: a second
     * provider would mean a second `ModelEndpoint` and a second writer of the
     * same invariant (`gateway-security.md` §2 — the Worker never holds the key).
     */
    private val modelCredential: GatewayCredentialProvider? = launchConfig.modelCredentialProvider()

    /**
     * The model-protocol edge, or `null` when this launch cannot host one.
     *
     * It is built from the **real** upstream base (`launchConfig.deepseekBaseUrl`)
     * and the key-store provider, and handed to the engine; the engine binds it
     * to the loopback origin and rewrites the Worker's `DEEPSEEK_BASE_URL` to
     * that origin. When this is non-null the launch has declared **real model
     * traffic**: the Worker's model requests are answered only by the host edge,
     * and a stored key that is absent or unreadable is a fail-closed
     * `502 credential_unavailable` from that edge — never a silent fallback to an
     * anonymous or scripted upstream. "Credential broken" must look like a
     * broken credential, not like a model that answers strangely.
     *
     * `null` has three causes, and all three keep the pre-M2 path where the
     * Worker's env is passed through unchanged:
     *   * no base URL in the launch;
     *   * no installed key store ([ProbeLaunchConfig.modelCredentialProvider]);
     *   * the launch itself asked for no edge (`pdsh.model.proxy=false`), which
     *     is how a scripted upstream run keeps a real device key away from the
     *     test fixture.
     *
     * The base URL is not re-parsed here: [ProbeLaunchConfig.modelCredentialProvider]
     * already returned non-null only for a base URL that `ModelEndpoint.parse`
     * accepted, so this string is exactly the one the credential scope uses.
     */
    private val modelProxy: LoopbackModelProxy? = run {
        val base = launchConfig.deepseekBaseUrl
        val provider = modelCredential
        // Three ways to have no edge: no base, no credential, or a launch that asked for
        // none. The third one is what keeps a scripted upstream from ever receiving a real
        // key — see ProbeLaunchConfig.EXTRA_MODEL_PROXY.
        if (base == null || provider == null || !launchConfig.modelProxy) {
            if (!launchConfig.modelProxy) {
                // The one line a scripted run needs: no edge was mounted, so the
                // Worker env keeps its base URL and no host credential can reach
                // that upstream. No key and no real base appears here.
                logger.info("model edge disabled by launch (pdsh.model.proxy=false); the Worker env keeps its base URL")
            }
            null
        } else {
            LoopbackModelProxy(baseUrl = base, credentialProvider = provider)
        }
    }

    /**
     * The one upstream session, or `null` when the launch named no egress grant.
     *
     * The transport is the production `HttpURLConnection` hop. The credential comes
     * from the launch's model endpoint when it names one — the same object the model
     * proxy uses — and falls back to anonymous otherwise. Anonymous is not a silent
     * downgrade: [ProbeLaunchConfig.modelCredentialProvider] only returns non-null by
     * the time this runs, and its own resolve is fail-closed for the model origin.
     */
    private val gateway: GatewaySession? = launchConfig.egressGrant()?.let { grant ->
        GatewaySession(
            transport = HttpUrlConnectionGatewayTransport(),
            credentialProvider = modelCredential ?: AnonymousCredentialProvider,
            egress = AllowListEgressPolicy(listOf(grant)),
        )
    }

    /** The `/v1/http` policy the engine serves; `null` keeps the route at 503. */
    private val httpEgress: LoopbackHttpEgress? = gateway?.let { GatewayHttpEgress(it) }

    /**
     * What this launch can honestly say about model traffic (P27).
     *
     * The Worker env publishes the key's *state* and a non-secret placeholder
     * credential even when the launch named no endpoint (P25), which is correct:
     * those are facts about the device. It did **not** publish whether a model
     * route exists, and that absence was not neutral — with no
     * `DEEPSEEK_BASE_URL` the Worker's pinned `llm-deepseek` resolver falls back
     * to its public base (`packages/llm/llm-deepseek/src/config.ts:300`), so a
     * launch that mounted no edge sent the placeholder to
     * `https://api.deepseek.com/anthropic` and produced a real 401 (measured
     * 2026-11-01). This fact is published through
     * [ModelRouteFact.workerEnvironment] and the Worker refuses a model request
     * on `none` (`plugins/worker-entry/src/model-route.ts`), so the
     * misconfiguration produces no external traffic and names the missing input.
     *
     * It is computed once and read by the env, the start log and the sentence a
     * failed turn carries. One fact, one answer.
     */
    private val modelRoute: ModelRouteFact = ModelRouteFact.forLaunch(
        baseUrl = launchConfig.deepseekBaseUrl,
        proxyRequested = launchConfig.modelProxy,
        credentialAvailable = modelCredential != null,
    )

    /**
     * The `pageParams` this launch hands the engine (the engine's own parameter
     * is `pageParams`; this property is the value it is given).
     *
     * The route members are added **after** `ProbeLaunchConfig.workerEnvironment()`
     * (which P25 owns) so this lane does not reopen that method's contract: the
     * key members stay exactly where P25 put them, and the route is one more
     * fact of the same env object. The engine re-parses this JSON and adds
     * `PDSH_DSH_LAUNCH_TOKEN` (`WorkerEnvironment.pageParam`).
     *
     * No value here is a credential or an endpoint: `host-edge` / `direct` /
     * `none` plus a missing-input code. Nothing is logged.
     */
    private val workerPageParams: Map<String, String> = run {
        val hostEnv = launchConfig.workerEnvironment(
            modelProxyMounted = modelProxy != null,
            // The selected tier's `single_file_limit`, published where the Worker
            // reads it (channel.md §4.1 has no HELLO member for it). This is what
            // makes an over-limit write an `EFBIG` from the write surface instead
            // of a WAL record that only recovery can refuse.
            singleFileLimitBytes = deviceBudgets.singleFileBytes,
        )
        val env = if (hostEnv == null) JSONObject() else JSONObject(hostEnv)
        for ((name, value) in modelRoute.workerEnvironment()) env.put(name, value)
        mapOf("env" to env.toString())
    }

    /** The per-start token source; also authenticates the App's egress probe. */
    private val launchToken = SecureLaunchToken()

    // ---- construction order: engine first, then the host --------------------
    // The host needs the engine, and the engine needs the host's frame consumer.
    // [HostChannelSeam] breaks that cycle; it is attached in `init` before
    // `host.start()`, so no frame can ever reach an unattached seam.
    private val channelSeam = HostChannelSeam()

    private val engine: DemoEngine = createDemoEngine(
        context = application,
        channelHandler = channelSeam,
        logger = logger,
        // `workerAssets` is named on purpose: the factory's `logger` has a default
        // value before it, so a positional call would not compile.
        workerAssets = WorkerAssets(
            source = ApkWorkerAssetSource(application),
            filesDir = application.filesDir,
            logger = logger,
        ),
        // One fresh 32-byte secret per start: the loopback gate/cookie token and
        // the worker's PDSH_DSH_LAUNCH_TOKEN. Never logged or persisted; the
        // resident phone surface refuses to provide `connection` without it.
        launchToken = launchToken,
        // The base URL travels through the same `env` object as the launch
        // token; it is not a page query parameter of its own and is not logged.
        // With a mounted edge the env omits `DEEPSEEK_BASE_URL` entirely: the
        // engine fills in the loopback origin once the port is known, so the real
        // upstream base never enters the page parameter. The model route travels
        // in the same object (see [workerPageParams]).
        pageParams = workerPageParams,
        // The Worker's only outbound path; null when no exact grant was supplied.
        httpEgress = httpEgress,
        // M2: the model edge. It holds the real upstream base and the key-store
        // provider; the engine mounts it on the loopback origin and points the
        // Worker's DEEPSEEK_BASE_URL there. Null keeps the scripted-upstream path.
        modelProxy = modelProxy,
        // P22: the channel-reopen lane reloads the page only while D14's admission
        // is open. `controller` is initialized after this engine on purpose (the
        // host takes the engine), and the lambda is read at reload time, never
        // during construction.
        writesAllowed = { controller.admission == Admission.OPEN },
        // P28 / wal.md §8: the Worker is seeded from the recovered materialized
        // tree. The delegate reads the log when `pack()` runs — always after
        // `host.start()` finished recovery and tail replay — because the engine is
        // built before the WAL here, exactly like `writesAllowed` above reads
        // `controller` later. `null` (the diagnostic launch) reproduces the
        // pre-P28 shape: no `?overlay=`, an empty Worker view.
        bootOverlaySource = if (launchConfig.bootOverlay) {
            BootOverlaySource { bootOverlayProducer.pack() }
        } else {
            null
        },
    )

    private val clock = AndroidClock()
    private val durability = AndroidDurability()
    private val signals = AndroidLifecycleSignals(application)

    /**
     * The `wal.md` §8 boot overlay producer (P28).
     *
     * `wal.md` §8 says the overlay is packed from the materialized tree "after
     * recovery, reconcile and tail replay" and is rebuilt for each boot; the engine
     * therefore calls [MaterializedBootOverlaySource.pack] before **every** page
     * load. This property is `by lazy` on purpose: it reads [walPaths] and
     * [workspaceLog], which are constructed after the engine.
     *
     * The cap is the tier's `vfsLogicalBytes` (budgets.md §4). That is the memory
     * this tree becomes in the Worker's `MemoryVfs`, so a tree above it cannot be
     * booted by this device at all; the producer then refuses loudly instead of
     * truncating (see BootOverlay.kt).
     */
    private val bootOverlayProducer: MaterializedBootOverlaySource by lazy {
        MaterializedBootOverlaySource(
            materializedDirectory = walPaths.materializedDirectory,
            outputDirectory = walPaths.root.resolve(BOOT_OVERLAY_DIRECTORY),
            maxArchiveBytes = deviceBudgets.vfsLogicalBytes,
            logger = logger,
            // `materializedUptoMseq` is the watermark the snapshot must be taken
            // at: a pack that straddles a materialization is discarded and retried,
            // so the Worker always mounts one consistent mseq.
            watermark = { workspaceLog.materializedUptoMseq },
        )
    }

    // wal.md §1 places the workspace under `Library/xl/`; on Android the app's
    // private filesDir is the equivalent root. This one path is the root every
    // durable store is built over — the WAL's `wal/`, the journal's `journal/`
    // and the exec dedup table's `exec/` — so no store carries an absolute path
    // of its own and none of them can drift to a second directory.
    private val workspaceRoot: Path = File(application.filesDir, WORKSPACE_DIRECTORY).toPath()

    /**
     * `host-state.json`, the file `PERSIST_HOST_STATE` writes (P15).
     *
     * Until this existed the boot below passed a literal `persistedState = null`
     * and every start was `COLD_START`: budgets.md §3's boot mapping (persisted
     * `Parked` -> `Parked`, persisted `Backoff` -> `Backoff`, persisted
     * `HandingOff` -> `Failed`) had no file to read, so a host killed while
     * `Parked` came back cold and `PARKED_RESUME` was unreachable.
     */
    private val hostStateStore = HostStateStore(
        file = workspaceRoot.resolve(HostStateStore.FILE_NAME),
        durability = durability,
        clock = clock,
        logger = LogcatHostLog,
    )

    /**
     * The state this boot restores, or `null` when there is none to trust.
     *
     * Read once, before the machine is built: the D14 boot mapping is a pure
     * function of the persisted state, and a second read later could see a
     * record this process itself wrote.
     */
    private val persistedHostState = hostStateStore.load()

    // The boot mapping of budgets.md §3: a persisted `Parked` host resumes as
    // `Parked` (its resume waits for an active scene), a persisted `Running`,
    // `Draining` or `Recovering` host boots back into `Recovering`, a persisted
    // `HandingOff` is `Failed`, and no record at all is the empty workspace.
    // `workspaceHasState` stays false: whether the WAL holds history is the
    // WAL's answer, not this file's.
    private val controller = ControllerStateMachine.boot(persistedState = persistedHostState?.state)

    // One path object for every consumer of the workspace layout: the WAL, the
    // journal and the exec accelerators' mounts all derive from it, so no store
    // can drift to a second directory.
    private val walPaths = WalPaths(workspaceRoot)

    // The directory is relative to filesDir (no absolute path is committed or
    // logged) and `recover()` is run by the host's asynchronous boot, never here.
    private val workspaceLog = WorkspaceLog(
        paths = walPaths,
        durability = durability,
        clock = clock,
        // wal.md section 10 step 2 requires a torn-tail truncation to be logged.
        // The library default drops every event, so the composition root supplies
        // the sink that both logs it and raises the banner.
        sink = ProbeRecovery.walSink,
    )

    /** The one WAL seam, shared by the HELLO and the exec bridge. */
    private val hostWal = workspaceLog.asHostWal()

    /**
     * The journal lane's directory layout, shared by the store and the session
     * read, so a row's file is named by the same object that wrote it.
     */
    private val journalPaths = JournalPaths(workspaceRoot)

    /**
     * The journal lane behind `JOURNAL` (`0x30`).
     *
     * The store is recovered inside `host.start()`, before the HELLO is final:
     * only a store that recovered leaves the sink open, and only an open sink
     * acks a record. Constructing it here does no I/O. Without it the host logs
     * `journal: off` and the Worker's level-1 durability wait expires after
     * 30 s, which reopens the connection in the middle of a turn.
     */
    private val journalStore = JournalStore(
        paths = journalPaths,
        durability = durability,
        logger = LogcatHostLog,
    )

    /**
     * exec.md §2's durable dedup table (`exec/` under the workspace root).
     *
     * One file per `idem_key`, written through the same `Durability` SPI as the
     * WAL and the journal. A repeated key replays the recorded events after a
     * process restart instead of running the accelerator twice.
     *
     * Constructing it creates `exec/` and scans the retained entries: a
     * one-time, small IO at composition time, bounded by the ledger's
     * `DEFAULT_MAX_ENTRIES`. If a future workload makes that scan visible at
     * startup, the fix is a lazy-load seam in the ledger, not a larger default.
     */
    private val execLedger = FileRequestLedger(
        workspaceRoot = workspaceRoot,
        durability = durability,
        clock = clock,
    )

    private val host: PhoneDshHost = DefaultPhoneDshHost(
        engine = engine,
        controller = controller,
        clock = clock,
        signals = signals,
        // :dsh ships no production Notifier and :app has no notification channel
        // or POST_NOTIFICATIONS flow, so the honest value is DISABLED: on a
        // crash-recovery boot the host logs "not user-visible" instead of
        // pretending a notification reached the user.
        notifier = DisabledNotifier,
        // `wal/1` is advertised only when this log's recovery succeeds inside
        // `host.start()`; the HELLO's caps and watermark are built from that
        // outcome, never from a value written in this file.
        wal = hostWal,
        // The journal store is recovered in `host.start()` too, so `0x30` is
        // dispatched and acknowledged (durably) for the whole boot instead of
        // being logged and ignored.
        journal = journalStore,
        // `exec/1` and every `accelerator:*` entry come from the bridge's
        // capability set, never a capability string in this file. The durable
        // ledger and the mounts are injected here: this is the composition root
        // that owns the workspace root and the durability SPI.
        //
        // The mounts point at the WAL's *materialized* copies, exactly the tree
        // the accelerators are promised (exec.md §2.1): `rg`/`jaq` must never
        // read the journal or an unmaterialized mutation. `WalPaths` only joins
        // names; `WorkspaceLog.recover()` creates the directories inside
        // `host.start()`, before admission opens, so a dispatched EXEC_REQ always
        // finds them. With no workspace the list would be empty and :shell would
        // advertise no accelerator at all.
        exec = HostExec.defaultTools(
            clock = clock,
            controller = controller,
            wal = hostWal,
            logger = LogcatHostLog,
            ledger = execLedger,
            shellMounts = listOf(
                AcceleratorMount(
                    AcceleratorMount.WORKSPACE,
                    walPaths.materializedWorkspace.toString(),
                ),
                AcceleratorMount(
                    AcceleratorMount.HOME,
                    walPaths.materializedHome.toString(),
                ),
            ),
        ),
        logger = LogcatHostLog,
        // The one upstream session; no longer a null placeholder.
        gateway = gateway,
        // The Worker's `XL_DSH_READY` announcement arrives on CONSOLE.
        onWorkerConsole = ::onWorkerConsole,
        // P15: `PERSIST_HOST_STATE` and the `Backoff` retry schedule have an
        // owner. The store is the same file this boot read, so a `Parked` host
        // survives a kill and a `Backoff` host restores the rest of its window.
        stateStore = hostStateStore,
        // budgets.md §4: the one measured row for this boot. The host's VFS sink
        // answers a mutation that would grow a file past this row's
        // `single_file_limit` with `VFS_REFUSED` (channel.md §4.8/§8); the same
        // value went into the Worker env above, so the two surfaces cannot
        // disagree.
        deviceBudgets = deviceBudgets,
        // gateway/loopback/lease/sessionEpoch/scope keep their documented
        // defaults: :engine binds the origin, the lease is LocalOnly, and no
        // persisted session counter exists (0 = none).
    )

    val state: StateFlow<EngineState> = engine.state

    /**
     * The D14 host state, which is what actually decides whether this app is
     * usable right now: admission is open only in `Running`.
     *
     * The screen needs both facts. The engine can be `Running` while the host is
     * `Draining`/`Parked`/`Recovering`, and rendering that as 「运行中 / 已连接」
     * is the lie P10 measured (12:01:19, API 35: every write refused while the
     * panel said 运行中).
     */
    val hostState: StateFlow<com.phonedsh.controller.HostState> = host.state
    val channel: StateFlow<ChannelStatus> = engine.channel
    val handshake: StateFlow<HandshakeSummary?> = engine.handshake

    /**
     * The installed WebView provider, read once at construction.
     *
     * `null` when the framework could not answer; the runtime page then renders
     * 未知 instead of a package name the host never saw.
     */
    private val webViewPackage: android.content.pm.PackageInfo? =
        runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()

    /**
     * Whether the app is exempt from battery optimisation, read once.
     *
     * The settings page owns the wording; this file only reports the platform
     * answer, and 未知 when the service refused to answer.
     */
    private val batteryExemption: FactState = runCatching {
        val app = getApplication<Application>()
        val manager = app.getSystemService(PowerManager::class.java)
        when (manager?.isIgnoringBatteryOptimizations(app.packageName)) {
            true -> FactState.YES
            false -> FactState.NO
            null -> FactState.UNKNOWN
        }
    }.getOrDefault(FactState.UNKNOWN)

    /** Monotonic start of the current Running spell; `null` when not running. */
    @Volatile
    private var runningSinceMillis: Long? = null

    /**
     * The engine's one view, or `null`.
     *
     * UI thread only: the Web surface attaches this exact instance and never
     * creates a second one (the single-WebView invariant).
     */
    fun currentWebView(): View? = engine.view()

    /**
     * The engine's last WebView kernel measurement (provider, real Chromium
     * version, runtime features), or `null` before the first page finished.
     *
     * Read synchronously like [currentWebView]: both are host facts of the one
     * engine, not UI state of their own. `null` means "not measured".
     */
    fun kernelReport(): WebViewKernelReport? = engine.kernelReport()

    /** True when the launch asked the Web surface to be the engine-ready face. */
    fun webFaceOnLaunch(): Boolean = launchConfig.webFace

    /**
     * One walk over every value the navigation facts are built from.
     *
     * Measured: the engine's view, the running duration (monotonic), the WebView
     * provider/version, the launch egress grant and the battery-exemption fact.
     * Everything not measured stays `null`; no field defaults to a fake value.
     */
    internal fun hostReadings(): HostReadings = HostReadings(
        webView = engine.view(),
        uptimeMs = runningSinceMillis?.let { since ->
            (clock.monotonicMillis() - since).coerceAtLeast(0L)
        },
        webViewProvider = webViewPackage?.packageName,
        webViewVersion = webViewPackage?.versionName,
        // The engine's own measurement, taken when the page finished: provider
        // identity plus the real Chromium version and the runtime features. It
        // is null until then, and the page renders 未知 — never "supported".
        webViewKernel = engine.kernelReport(),
        egressGrant = launchConfig.egressGrant(),
        batteryExemption = batteryExemption,
    )

    /** The facts every routed page reads, rebuilt from one host walk. */
    internal fun navFacts(
        state: EngineState,
        handshake: HandshakeSummary?,
        turn: AppTurnState,
    ): PdshNavFacts {
        // The first snapshot after the transition may beat the state collector;
        // starting the spell here keeps the uptime from reading 未知 for it.
        if (state is EngineHostState.Running && runningSinceMillis == null) {
            runningSinceMillis = clock.monotonicMillis()
        }
        return buildNavFacts(hostReadings(), state, handshake, turn)
    }

    /** The host's wall reading for the sessions page's relative-time labels. */
    internal fun nowMillis(): Long = clock.nowMillis()

    /**
     * Re-reads the sessions the journal lane stored.
     *
     * The journal is this host's only durable per-session store, so it is the
     * only honest source for a session list.
     *
     * **Known cost, and the fix.** This is a second `recover()` scan of the
     * journal (the host already ran one during `start()`). It is correct today:
     * [JournalStore.recover] is documented as idempotent, and the store's mutex
     * serialises this scan with the host's own recovery and with any in-flight
     * append, so no torn read or lost record can result. It is **not the
     * designed end state**: the right fix is for `:dsh` to expose a read-only
     * journal-watermarks accessor, and this method should then read that API
     * instead of scanning the store a second time.
     *
     * The scan runs off the main thread, and the rows change only when it
     * returns, never on the gesture that asked for it.
     */
    internal fun refreshSessions() {
        if (!sessionScanInFlight.compareAndSet(false, true)) return
        mutableSessions.update { it.copy(scanInFlight = true) }
        turnScope.launch {
            try {
                val scan = withContext(Dispatchers.IO) { readJournalSessions() }
                mutableSessions.update { snapshot ->
                    snapshot.copy(
                        waiting = false,
                        failure = scan.failure,
                        sessions = mergeSessions(scan.sessions, snapshot.sessions),
                    )
                }
            } finally {
                sessionScanInFlight.set(false)
                mutableSessions.update { it.copy(scanInFlight = false) }
            }
        }
    }

    /** Hides the last read failure; the rows from the last good read stay. */
    internal fun clearSessionsFailure() {
        mutableSessions.update { it.copy(failure = null) }
    }

    private val turnRunning = AtomicBoolean(false)
    private val mutableTurn = MutableStateFlow<AppTurnState>(AppTurnState.Idle)

    /** The one turn's UI state; [runTurn] is the only writer. */
    internal val turn: StateFlow<AppTurnState> = mutableTurn.asStateFlow()

    private val mutableSessions = MutableStateFlow(HostSessionSnapshot())

    /** The host's session read; [refreshSessions] and a completed turn write it. */
    internal val sessions: StateFlow<HostSessionSnapshot> = mutableSessions.asStateFlow()

    /** One journal scan at a time; a second request while one runs is ignored. */
    private val sessionScanInFlight = AtomicBoolean(false)

    private val turnScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    init {
        // budgets.md §4 evidence: the raw ceiling and the row it selects. The
        // host prints the row it was given (its `budget tier:` line); this one
        // names the measurement the row came from, so a device that reports
        // 2 GiB cannot be mistaken for one that reported 8 GiB.
        HostBudgetTier.readTotalMemoryBytes(application)?.let { totalMem ->
            LogcatHostLog.info(
                "device memory: totalMem=$totalMem bytes; budget tier: " +
                    "${deviceBudgets.tier.displayName}; single_file_limit: " +
                    "${deviceBudgets.singleFileBytes} bytes " +
                    "(${deviceBudgets.singleFileBytes / ControllerBudgets.MIB} MiB); " +
                    "Worker env ${HostBudgetTier.SINGLE_FILE_LIMIT_ENV}=" +
                    "${deviceBudgets.singleFileBytes}",
            )
        } ?: LogcatHostLog.warn(
            "device memory: totalMem unavailable; budget tier " +
                "${deviceBudgets.tier.displayName} (the smallest row) applies",
        )
        // P27 evidence: the route this launch published to the Worker, printed
        // before the first turn so a reader can tell "the model was refused
        // because this launch had no route" from "the model refused the
        // credential". No endpoint and no key appears here.
        LogcatHostLog.info(modelRouteLine())
        channelSeam.attach(host.channelHandler)
        // Asynchronous by contract: recovery, the final HELLO and engine.start()
        // run on the host's scope. Observe engine.state for the outcome.
        host.start()
        // The runtime page's uptime is the length of the current Running spell,
        // measured on the monotonic clock so a wall-clock change cannot move it.
        // A host that could not recover its WAL advertises no `wal/1`; the worker
        // then refuses to boot and the screen would otherwise keep saying
        // 「运行中」. Raising it here is the only surface that reaches the user.
        turnScope.launch {
            engine.handshake.collect { summary ->
                val caps = summary?.hostCapabilities ?: return@collect
                // The engine publishes a worker-only summary with empty host caps
                // before the host caps merge. Only a non-empty list can prove the
                // host omission; reading the empty one as "wal/1 missing" raises a
                // false banner on every healthy boot (measured 2026-11-01).
                if (caps.isEmpty()) return@collect
                if ("wal/1" in caps) {
                    ProbeRecovery.clearWalUnavailable()
                } else {
                    ProbeRecovery.raiseWalUnavailable(caps)
                }
            }
        }
        turnScope.launch {
            engine.state.collect { next ->
                when (next) {
                    is EngineHostState.Running -> if (runningSinceMillis == null) {
                        runningSinceMillis = clock.monotonicMillis()
                    }

                    EngineHostState.Stopped, is EngineHostState.Failed ->
                        runningSinceMillis = null

                    EngineHostState.Starting, EngineHostState.Recovering -> Unit
                }
            }
        }
        if (launchConfig.egressProbe) {
            turnScope.launch { runEgressProbe() }
        }
    }

    fun start() = host.start()

    fun stop() = host.stop()

    /**
     * The one line that records this launch's model route.
     *
     * Its counterpart is the Worker's refusal (`plugins/worker-entry/src/model-route.ts`):
     * the host publishes `PDSH_MODEL_ROUTE`, the Worker refuses on `none`, and
     * this line is what makes the two halves verifiable in one logcat capture.
     */
    private fun modelRouteLine(): String = buildString {
        append("model route: ").append(modelRoute.route.wire)
        append(" (Worker env ").append(ModelRouteFact.ENV).append('=')
        append(modelRoute.route.wire)
        modelRoute.missing?.let {
            append(", ").append(ModelRouteFact.MISSING_ENV).append('=').append(it.wire)
        }
        append("); ")
        when (modelRoute.route) {
            ModelRoute.HOST_EDGE -> append("model requests are answered by the host edge")
            ModelRoute.DIRECT -> append("the Worker talks to the launch's base URL directly")
            ModelRoute.NONE -> append(modelRoute.missing!!.sentence)
                .append(": the Worker refuses model requests locally instead of ")
                .append("falling back to the public DeepSeek API")
        }
    }

    /**
     * The turn-failure text, with this launch's route fact appended when it has none.
     *
     * The appended sentence states a fact about the **launch**, not a claim about
     * the cause: on a routeless launch the Worker refused the model request
     * locally, which is why the turn's end reason is `error`, and the reader must
     * not be sent to look for a wrong key.
     */
    private fun failureText(reason: String): String {
        val diagnosis = modelRoute.diagnosis() ?: return reason
        return "$reason; $diagnosis"
    }

    /**
     * Starts one turn through the App's own `/api` path.
     *
     * Idempotent while a turn is in flight. The prompt is the launch-configured
     * text, not a model call: the acceptance upstream is scripted.
     *
     * A launch with no model route still runs the turn: the refusal belongs to
     * the Worker (the only layer that can keep `llm-deepseek` from falling back
     * to its public base), and running it is what proves the refusal happens
     * before any request leaves the device. [failureText] then names the missing
     * input in the App's own line.
     */
    fun runTurn() {
        if (!turnRunning.compareAndSet(false, true)) {
            Log.i(TAG_TURN, "turn ignored: one is already running")
            return
        }
        Log.i(TAG_TURN, "APP_TURN_BUTTON prompt=${launchConfig.prompt.length} chars")
        // Durable tombstone before the first await: a process killed during the
        // turn leaves it behind, and the next launch reports "interrupted at step
        // N" instead of silently showing a half session.
        ProbeRecovery.beginTurn(getApplication<Application>())
        mutableTurn.value = AppTurnState.Running
        turnScope.launch {
            try {
                withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
                withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                    engine.state.first { it is EngineHostState.Running }
                }
                val client = DshTurnClient(host.channel, ::logTurn)
                val result = client.runTurn(launchConfig.prompt)
                for (event in result.events) logTurn("host event: ${event.describe()}")
                // Completion is the Worker's own edge, not the shape of its tool
                // use: a turn that answered without calling a tool is still a
                // completed turn. Gating on the tool edges reported a plain Q&A
                // turn as `incomplete` while its `turn/end` said `completed`
                // (measured 2026-11-01), which is the one thing this screen may
                // not do. `sawTheFourEdges` is kept as a separate observation of
                // the tool lane and logged next to the OK line.
                val answered = result.events.any { it.kind == HostEventKind.ASSISTANT_MESSAGE }
                val complete = result.turnEndReason == "completed" && answered
                if (complete) {
                    logTurn(
                        "APP_TURN_OK session=${result.sessionId} " +
                            "kinds=${result.kinds.joinToString(",")} reason=completed " +
                            "tool_edges=${result.sawTheFourEdges}",
                    )
                    ProbeRecovery.endTurn(getApplication<Application>())
                    mutableTurn.value = AppTurnState.Completed(
                        sessionId = result.sessionId,
                        kinds = result.kinds,
                        commands = toolCommands(result.events),
                        writes = toolWrites(result.events),
                    )
                    recordCompletedTurn(result.sessionId)
                } else {
                    failTurn(
                        failureText(
                            "incomplete: kinds=${result.kinds.joinToString(",")} " +
                                "reason=${result.turnEndReason ?: "-"}",
                        ),
                    )
                }
            } catch (timeout: TimeoutCancellationException) {
                failTurn(failureText("timeout"))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                failTurn(failureText(reasonOf(failure)))
            } finally {
                turnRunning.set(false)
            }
        }
    }

    /**
     * The commands the turn's `tool_call` events named.
     *
     * `tool_call.arguments` is the contract's one arbitrary-JSON member, and the
     * worker encodes it as a JSON *string* (the trajectory goldens carry
     * `"arguments":"{\"cmd\":\"ls\"}"`), so both a string and an object are
     * accepted. Non-JSON or argument-less calls yield no row: a tool name alone is
     * never rendered as a command.
     */
    private fun toolCommands(events: List<HostEvent>): List<TurnToolCommand> =
        events.mapNotNull { event ->
            if (event.kind != HostEventKind.TOOL_CALL) return@mapNotNull null
            val data = event.data ?: return@mapNotNull null
            val arguments = argumentsOf(data) ?: return@mapNotNull null
            val command = (arguments["command"] as? JsonString)?.value
                ?: (arguments["cmd"] as? JsonString)?.value
                ?: return@mapNotNull null
            val id = (data["callId"] as? JsonString)?.value
                ?: (data["call_id"] as? JsonString)?.value
                ?: command
            TurnToolCommand(id = id, command = command)
        }

    /**
     * The paths the turn's write tools named.
     *
     * Only the three tool names §2 folds into the changed-files card are
     * recognised; any other tool yields no row, because this host has not
     * measured whether it wrote a file.
     */
    private fun toolWrites(events: List<HostEvent>): List<TurnWrite> =
        events.mapNotNull { event ->
            if (event.kind != HostEventKind.TOOL_CALL) return@mapNotNull null
            val data = event.data ?: return@mapNotNull null
            val toolName = (data["name"] as? JsonString)?.value ?: return@mapNotNull null
            if (toolName !in WRITE_TOOLS) return@mapNotNull null
            val arguments = argumentsOf(data)
            val path = (arguments?.get("path") as? JsonString)?.value
                ?: (arguments?.get("file_path") as? JsonString)?.value
                ?: (arguments?.get("filePath") as? JsonString)?.value
                ?: (data["path"] as? JsonString)?.value
                ?: return@mapNotNull null
            TurnWrite(path = path, toolName = toolName)
        }

    /**
     * The `arguments` object of a `tool_call`, decoded from either encoding.
     *
     * Returns `null` when the member is absent, is not JSON, or does not decode to
     * an object: the caller then renders no row rather than a guessed one.
     */
    private fun argumentsOf(data: JsonObject): JsonObject? =
        when (val raw = data["arguments"] ?: data["input"]) {
            is JsonObject -> raw
            is JsonString -> runCatching { JsonValue.parse(raw.value) as? JsonObject }.getOrNull()
            else -> null
        }

    /**
     * Exercises the App's own `/v1/http` route with two requests: one to the
     * exact launch origin (must be 200) and one to an unlisted origin (must be
     * 403 without upstream contact). Diagnostic only; it is started when the
     * launch asked for it, and it logs status codes and stable codes only.
     */    private suspend fun runEgressProbe() {
        try {
            withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
            withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                engine.state.first { it is EngineHostState.Running }
            }
            val running = engine.state.value as? EngineHostState.Running ?: return
            val base = launchConfig.deepseekBaseUrl ?: return
            val token = launchToken.current() ?: return
            val allowed = probeEgress(running.origin, token, base.trimEnd('/') + "/health")
            if (allowed == 200) {
                Log.i(TAG_TURN, "APP_EGRESS_OK status=$allowed")
            } else {
                Log.e(TAG_TURN, "APP_EGRESS_FAILED status=$allowed")
            }
            val denied = probeEgress(running.origin, token, "https://unlisted.example/")
            if (denied == 403) {
                Log.i(TAG_TURN, "APP_EGRESS_DENIED status=$denied")
            } else {
                Log.e(TAG_TURN, "APP_EGRESS_NOT_DENIED status=$denied")
            }
        } catch (timeout: TimeoutCancellationException) {
            Log.e(TAG_TURN, "APP_EGRESS_FAILED reason=timeout")
        } catch (failure: Exception) {
            Log.e(TAG_TURN, "APP_EGRESS_FAILED reason=${failure.javaClass.simpleName}")
        }
    }

    /** One POST to the App's own `/v1/http`; returns the status, never a body. */
    private suspend fun probeEgress(origin: String, token: String, target: String): Int =
        withContext(Dispatchers.IO) {
            val connection = URI("$origin/v1/http").toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 5_000
                connection.readTimeout = 15_000
                connection.setRequestProperty("Authorization", "Bearer $token")
                connection.setRequestProperty("X-PDSH-Target-URL", target)
                connection.setRequestProperty("X-PDSH-Target-Method", "GET")
                connection.doOutput = true
                connection.outputStream.use { it.write(ByteArray(0)) }
                val status = connection.responseCode
                runCatching { connection.errorStream?.use { stream -> stream.readBytes() } }
                runCatching { connection.inputStream?.use { stream -> stream.readBytes() } }
                status
            } finally {
                runCatching { connection.disconnect() }
            }
        }

    override fun onCleared() {
        turnScope.cancel()
        host.stop()
        super.onCleared()
    }

    private fun failTurn(reason: String) {
        val safe = reason.substringBefore('\n').take(240)
        Log.e(TAG_TURN, "APP_TURN_FAILED reason=$safe")
        // A failure is an explicit end: the marker is removed so the next launch
        // does not report this turn as a process death too.
        ProbeRecovery.endTurn(getApplication<Application>())
        mutableTurn.value = AppTurnState.Failed(safe)
    }

    /**
     * One cold scan of the journal lane, with the failure kept as a page label.
     *
     * The session ids are the store's own recovery watermarks; the timestamp is
     * the file's last write, which is the last moment the host durably touched
     * that session. Nothing is inferred from a file name.
     */
    private suspend fun readJournalSessions(): SessionScan = try {
        val recovery = journalStore.recover()
        SessionScan(
            sessions = recovery.highestJseq.keys
                .map { sessionId -> HostSessionRecord(sessionId, journalLastWriteMs(sessionId)) }
                .sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE },
        )
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        SessionScan(failure = sessionFailureLabel(failure))
    }

    /**
     * The session file's last write, or `null` when it disappeared.
     *
     * A row whose file vanished between recovery and this read keeps its id and
     * shows no time, rather than a time the host did not read.
     */
    private fun journalLastWriteMs(sessionId: String): Long? = runCatching {
        Files.getLastModifiedTime(journalPaths.sessionFile(sessionId)).toMillis()
    }.getOrNull()

    /**
     * Records the session a completed turn opened.
     *
     * This is the one session the host knows without a store scan: the client
     * returned it with the completed turn. It becomes the current session (the
     * page's check mark) and a row, with the host's own completion reading as
     * its last activity.
     */
    private fun recordCompletedTurn(sessionId: String) {
        val at = clock.nowMillis()
        mutableSessions.update { snapshot ->
            snapshot.copy(
                currentSessionID = sessionId,
                sessions = mergeSessions(
                    emptyList(),
                    snapshot.sessions + HostSessionRecord(sessionId, at),
                ),
            )
        }
    }

    /**
     * Merges two session reads without losing the newer timestamp of either.
     *
     * The store scan and the turn observation can name the same session; the
     * merged row carries the max of the two readings and the list stays ordered
     * by that reading (newest first). Host order is the sessions page's input
     * order, so this is the order the rows appear in.
     *
     * Ordering caveat: newest-first by the host's one measured time. The iOS
     * baseline orders by its management model, not by a per-session timestamp,
     * and the UI contract does not specify a session order, so the two platforms
     * can list the same sessions in different orders. This is a known difference,
     * not a hidden choice; a contract-level order would replace this rule.
     */
    private fun mergeSessions(
        fromStore: List<HostSessionRecord>,
        observed: List<HostSessionRecord>,
    ): List<HostSessionRecord> {
        val merged = LinkedHashMap<String, HostSessionRecord>()
        for (record in fromStore + observed) {
            val previous = merged[record.id]
            merged[record.id] = if (previous == null) {
                record
            } else {
                HostSessionRecord(record.id, newer(previous.lastActivityMs, record.lastActivityMs))
            }
        }
        return merged.values.sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE }
    }

    private fun newer(previous: Long?, next: Long?): Long? = when {
        previous == null -> next
        next == null -> previous
        else -> maxOf(previous, next)
    }

    /**
     * The page's failure line, with a stable store code and no path.
     *
     * The journal's own codes name why the read failed; anything else is a class
     * name, which is still token-free.
     */
    private fun sessionFailureLabel(failure: Exception): String = when (failure) {
        is JournalException -> "会话记录读取失败（${failure.failure.code}）"
        else -> "会话记录读取失败（${failure.javaClass.simpleName}）"
    }

    private fun logTurn(message: String) {
        Log.i(TAG_TURN, message)
    }

    private fun reasonOf(failure: Exception): String = when (failure) {
        is DshTurnException -> failure.code
        is HostApiException -> failure.code
        else -> failure.javaClass.simpleName
    }

    /**
     * The Worker's CONSOLE text: only the announce marker is logged, never the
     * line itself (a Worker console line can quote user content).
     */
    private fun onWorkerConsole(text: String) {
        if (text.contains("XL_DSH_READY")) {
            Log.i(TAG_TURN, "APP_WORKER_READY")
        }
    }

    private companion object {
        /** Subdirectory of filesDir that owns the WAL (wal.md §1's `xl`). */
        const val WORKSPACE_DIRECTORY = "xl"

        /**
         * Per-boot overlay members beside the WAL (`files/xl/boot-overlay/`).
         *
         * Not part of the VFS, the WAL or §8's own entry set: it is the host's
         * scratch for the bytes it serves the Worker, exactly like iOS's
         * `overlay-<boot_id>.tar` under its workspace root. Recovery ignores it.
         */
        const val BOOT_OVERLAY_DIRECTORY = "boot-overlay"

        /** The App turn's own logcat tag; the acceptance script greps it. */
        const val TAG_TURN = "PDSHAppTurn"

        /** The tool names §2 folds into the changed-files card (write/edit/str_replace_editor). */
        val WRITE_TOOLS: Set<String> = setOf("write", "edit", "str_replace_editor")

        const val HOST_READY_TIMEOUT_MILLIS = 180_000L
        const val ENGINE_READY_TIMEOUT_MILLIS = 180_000L
    }
}

/**
 * One journal scan's outcome.
 *
 * @param sessions the session rows the store recovered.
 * @param failure the token-free page label when the scan failed; non-null means
 *   [sessions] is empty because nothing was read, not because nothing exists.
 */
private data class SessionScan(
    val sessions: List<HostSessionRecord> = emptyList(),
    val failure: String? = null,
)

/**
 * The engine's frame consumer, forwarded to the host once it exists.
 *
 * The engine is constructed before the host because the host takes the engine;
 * this seam is the other half of that cycle. [attach] happens in the view
 * model's `init` before `host.start()`, and `@Volatile` publishes the target to
 * the origin's threads.
 */
private class HostChannelSeam : LoopbackChannelHandler {
    @Volatile
    private var delegate: LoopbackChannelHandler? = null

    fun attach(delegate: LoopbackChannelHandler) {
        this.delegate = delegate
    }

    private fun target(): LoopbackChannelHandler =
        delegate ?: error("the host channel handler was not attached before the engine started")

    override suspend fun onOpen(connection: LoopbackConnection) {
        target().onOpen(connection)
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        target().onBinary(connection, payload)
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        target().onClosed(connection, cause)
    }
}

/**
 * The `:net` anonymous credential for the demo's scripted upstream.
 *
 * No key is stored in this build; the gateway still strips the Worker's
 * authorization and applies "nothing", which is the honest value for an
 * anonymous exact-origin grant. A production host replaces this provider.
 */
private object AnonymousCredentialProvider : GatewayCredentialProvider {
    override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.None
}

/**
 * The facade's tokens-free log, routed to logcat under its own tag.
 *
 * `:dsh` defaults to `HostLog.Println`; a tagged adapter keeps the host's
 * `host boot`, `wal/1` and `host HELLO sent` provenance greppable next to the
 * engine's `PDSHEngine` lines.
 */
private object LogcatHostLog : HostLog {
    private const val TAG = "PDSHHost"

    override fun debug(message: String) {
        Log.d(TAG, message)
    }

    override fun info(message: String) {
        Log.i(TAG, message)
    }

    override fun warn(message: String) {
        Log.w(TAG, message)
    }

    override fun error(message: String) {
        Log.e(TAG, message)
    }
}

/**
 * The `:platform` empty Notifier for a build with no notification surface.
 *
 * `:dsh` has no production `Notifier` implementation (its background lane owns
 * the foreground-service notifications, not this facade's recovery notice), and
 * :app never creates a notification channel or asks for POST_NOTIFICATIONS.
 * Reporting [NotifierAvailability.DISABLED] is what makes that visible: the host
 * logs the degraded presentation path instead of silently dropping a notice.
 */
private object DisabledNotifier : Notifier {
    override val availability: NotifierAvailability = NotifierAvailability.DISABLED

    override fun notify(
        id: Int,
        title: String,
        body: String,
        ongoing: Boolean,
        action: NotificationAction?,
    ) = Unit

    override fun cancel(id: Int) = Unit
}
