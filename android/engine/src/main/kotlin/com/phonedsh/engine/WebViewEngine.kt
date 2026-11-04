// phone-dsh — :engine / com.phonedsh.engine: the one WebView host of the App.
// SPDX-License-Identifier: MIT
//
// ---- single-WebView invariant (plan §6.3-5) --------------------------------
// Why it exists, what it protects in practice (the app-level cookie jar), the
// order to change it in, and the tests a second renderer would need:
//   docs/design/android-single-webview-invariant-2026-11-01.md
//
// Chromium allows one renderer per App; this class is the only place in the tree
// that constructs a WebView, and [liveWebViews] + the assertion in [createWebView]
// make a second one a loud IllegalStateException instead of a silent renderer
// fight. `:app` sees only DemoEngine/EngineState (DemoEngine.kt) and never the
// WebView type; the demo UI may *attach* [currentWebView] to a container for
// visibility, it may not build another one.
//
// ---- threading -------------------------------------------------------------
// All WebView work happens on the App UI thread: `start()` and `stop()` may be
// called from anywhere, both marshal onto Dispatchers.Main. The 65 MB bundle copy
// and the Ktor bind run on Dispatchers.IO between the UI steps. WebView callbacks
// (navigation, interception, renderer death) are already on the UI thread.
//
// ---- renderer death (plan §6.2 renderer ③④⑤, §6.3-1) -----------------------
//   * onRenderProcessGone MUST return true, otherwise the platform finishes the
//     whole App process; the callback rebuilds instead.
//   * didCrash() tells a renderer crash from a low-memory reclaim; both rebuild,
//     the log line differs.
//   * the dead instance is destroyed and never reused (iOS can reload; Android
//     cannot); state goes Running -> Recovering -> Running on the same origin.
//   * setRendererPriorityPolicy(BOUND, false): the second argument must be
//     false. `true` means "waive the priority while not visible", which is how a
//     backgrounded renderer gets reclaimed.
//
// ---- a lost ordered channel (P22) ------------------------------------------
// The page's one WebSocket can die while the renderer is perfectly healthy: a
// network handover, or the worker client's own fatal protocol error. That close
// used to have no owner — the engine stayed `Running`, the screen stayed 「未连接」,
// and every later turn answered `no_channel` for the life of the process. The
// close now enters [ChannelReopenLane]: `Running -> Recovering`, one page reload
// per attempt with exponential backoff, and `Recovering -> Running` only once the
// page has handed back an open channel. See ChannelReopenLane.kt for why the
// reload waits for D14's admission and why a fresh page is the only repair for a
// fatal client error.

package com.phonedsh.engine

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.os.Looper
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewFeature
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LaunchCookie
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConfiguration
import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackEndpoint
import com.phonedsh.loopback.LoopbackModelProxy
import com.phonedsh.loopback.LoopbackServer
import com.phonedsh.platform.EngineHostState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger

/**
 * The demo engine: materialized bundle -> loopback origin -> one WebView -> page.
 *
 * [channelHandler] is the codec seam owned by the host (:app/:controller): every
 * binary frame the page sends arrives there unchanged. :engine does not import
 * :core/wire (A1: one codec, in Rust).
 */
class WebViewEngine(
    context: Context,
    private val channelHandler: LoopbackChannelHandler,
    private val logger: EngineLogger,
    private val workerAssets: WorkerAssets,
    /**
     * Extra boot parameters merged into the launch URL (`boot_id`, `fence`,
     * `env`, ...). An `env` entry is merged with the engine-owned
     * `PDSH_DSH_LAUNCH_TOKEN` (see [WorkerEnvironment.pageParam]).
     */
    private val pageParams: Map<String, String> = emptyMap(),
    /**
     * The per-start launch token. `:app` passes its own source so the generation
     * site is the composition root; the default keeps any other host honest.
     */
    private val launchToken: LaunchTokenSource = LaunchTokenSource.fresh(),
    /**
     * The `/v1/http` policy the origin exposes, or `null` when this start has no
     * outbound path. It is the same `:net` seam a test can inject; the App
     * supplies a gateway adapter, never a second server.
     */
    private val httpEgress: LoopbackHttpEgress? = null,
    /**
     * The model-protocol edge to mount on this origin, or `null` when this start
     * has no configured upstream.
     *
     * It is the M2 seam, and the type is `:net`'s on purpose: `:engine` never
     * parses a provider base URL, never holds a model key and never depends on
     * `:app`. `:app` builds the proxy with the real upstream base and the key
     * store provider, and this class only (a) hands it to [LoopbackServer] and
     * (b) rewrites the Worker's `DEEPSEEK_BASE_URL` to the loopback origin in
     * [launchUrl], because the port is not known before `start()` binds it.
     *
     * `null` keeps the pre-M2 behaviour: the Worker env is passed through
     * unchanged, so a launch against a scripted upstream still works.
     */
    private val modelProxy: LoopbackModelProxy? = null,
    /**
     * Whether the host would accept a write right now (D14's admission), read as a
     * lambda because the engine holds no controller.
     *
     * [ChannelReopenLane] reloads the page only while this is `true`: a page
     * reloaded into a host whose admission is closed gets a fresh worker whose
     * `VFS_MUT`s the sink refuses, which is the very mismatch the reload is meant
     * to repair. `true` keeps the pre-P22 behaviour for a composition that has no
     * controller.
     */
    private val writesAllowed: () -> Boolean = { true },
    /**
     * Produces the `wal.md` §8 boot overlay, or `null` for a composition that has
     * no materialized tree to seed the Worker with.
     *
     * The overlay is what makes a reloaded Worker see the workspace the host
     * recovered from the WAL. Without it the Worker mounts the base image alone:
     * `/dsh/workspace` is empty in its memory VFS, it writes that empty view back
     * through `VFS_MUT`, and the writes overwrite the real materialized tree. This
     * parameter is therefore not an optimisation.
     *
     * [start] and every page reload call [BootOverlaySource.pack] before the page
     * is loaded ("rebuilt for each boot", §8) and hand the result to the page as
     * the one `?overlay=` URL the runtime fetches before boot. A pack refusal is
     * loud: the engine goes `Failed` and no Worker is started, because the
     * alternative — booting with no overlay or a truncated one — is the data loss
     * this exists to prevent.
     */
    private val bootOverlaySource: BootOverlaySource? = null,
) : DemoEngine {
    private val appContext: Context = context.applicationContext ?: context
    private val lifecycle = EngineLifecycle(logger)
    private val channelTelemetry = ChannelTelemetry(logger = logger)

    /**
     * The CoroutineScope of this engine instance; also the lane's.
     *
     * `Dispatchers.Main.immediate` because every WebView touch must end up on the
     * UI thread, and the lane's reload does exactly that.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * The owner of "the ordered channel closed; get one back".
     *
     * Declared before [observedChannel] because that decorator reports the open and
     * the close this lane runs on; both callbacks reach it through methods, so the
     * only ordering that matters is [scope] existing.
     */
    private val reopenLane = ChannelReopenLane(
        scope = scope,
        logger = logger,
        reload = { attempt -> reloadPageForChannelReopen(attempt) },
        engineState = { lifecycle.snapshot() },
        onEpisodeStart = {
            // The baseline for "the origin refused a new upgrade": only rejects after
            // this point belong to this episode.
            channelRejectsAtLoss = server.metrics().channelsRejected
            if (lifecycle.markRecovering()) {
                logger.warn(
                    "ordered channel lost: Running -> Recovering (the page will be reloaded once " +
                        "the host accepts writes)",
                )
            }
        },
        hostAcceptsWrites = writesAllowed,
        originRefusedUpgrades = {
            server.metrics().channelsRejected > channelRejectsAtLoss
        },
        restartWorker = { restartWorkerForChannelReopen() },
    )

    private val observedChannel = ObservedChannelHandler(
        delegate = channelHandler,
        telemetry = channelTelemetry,
        logger = logger,
        onChannelLost = { cause -> onOrderedChannelLost(cause) },
        onChannelOpened = { onOrderedChannelOpened() },
    )

    // The page's WebSocket cannot send an Authorization header. With D22 it
    // authenticates through the launch cookie the engine seeded; the query-token
    // exception stays on so a page that still carries `?token=` (a developer
    // load, the worker's own fallback URL) keeps working: the one :net switch
    // this module owns.
    private val server = LoopbackServer(
        configuration = LoopbackConfiguration(
            // A WebSocket cannot set an Authorization header; the D22 cookie is
            // the page path, and the narrow `?token=` exception is kept for a
            // page that still carries one.
            allowQueryTokenOnChannel = true,
            // §6.2: WebView has no cross-origin isolation (Chromium Won't Fix) and
            // COOP/COEP there is "half-executed, only costs". Worse, COEP on the
            // launch page makes Chromium reject intercepted worker scripts with
            // net::ERR_BLOCKED_BY_RESPONSE (measured on the emulator), and the
            // worker needs no SharedArrayBuffer (WASI is single-threaded).
            crossOriginIsolation = false,
        ),
        handler = observedChannel,
        httpEgress = httpEgress,
        modelProxy = modelProxy,
    )

    private val mainThread: Looper = requireNotNull(Looper.getMainLooper()) {
        "the App UI thread must exist before the engine is constructed"
    }

    // ---- main-thread confined state (start()/stop() marshal onto it) --------
    private var webView: WebView? = null
    private var endpoint: LoopbackEndpoint? = null
    /**
     * The current start's launch token, held in memory only.
     *
     * Renderer recovery reloads the same origin, so the page must get the same
     * `env` value and the cookie must be re-seeded; it is never logged,
     * persisted or surfaced in a state value. Cleared by [shutdown].
     */
    private var liveLaunchToken: String? = null

    // shouldInterceptRequest runs on a WebView network thread, not on the UI
    // thread: the responder must be safely published, hence @Volatile.
    @Volatile
    private var responder: LoopbackAssetResponder? = null
    private var startJob: Job? = null

    /**
     * The overlay the current page load was given, or null when this composition
     * has no [bootOverlaySource] (or that source is disabled for a diagnostic
     * launch).
     *
     * Written before `loadUrl` on the load's thread and read by the asset
     * interceptor on a WebView network thread, hence @Volatile. A reload swaps it
     * first, so the new page's `?overlay=` URL and the bytes the interceptor serves
     * are the same member.
     */
    @Volatile
    private var servedOverlay: ServedAsset? = null

    // Watches the running origin for the death :net records instead of throwing.
    private var originWatchJob: Job? = null
    private var recoveriesThisRun = 0

    /**
     * `LoopbackMetrics.channelsRejected` when the current reopen episode began.
     *
     * A larger reading afterwards means the origin answered **409** to the
     * reloaded page: its single channel slot is still held by the connection that
     * died without a close the origin could see. Measured 2026-11-01: the page then
     * retries the upgrade every few seconds forever, and another reload cannot
     * help (see [restartWorkerForChannelReopen]).
     */
    @Volatile
    private var channelRejectsAtLoss = 0L

    /** The `:net`-facing watch for a channel that died without a close (P22). */
    private var staleChannelWatchJob: Job? = null

    /**
     * `true` between a reopen episode's worker restart and the channel it brought
     * back.
     *
     * The lane's job is cancelled by the restart ([shutdown] cancels it), so
     * `isReopening` is already false when the new page's channel opens; without
     * this flag the one line that says "the restarted worker is back" would be
     * the only recovery line a device log lacks.
     */
    @Volatile
    private var restartRecoveryPending = false

    override val state: StateFlow<EngineState> = lifecycle.state

    override val channel: StateFlow<ChannelStatus> = channelTelemetry.status

    override val handshake: StateFlow<HandshakeSummary?> = channelTelemetry.handshake

    /** The one WebView, or null. UI thread only; for the demo UI to attach. */
    val currentWebView: WebView? get() = webView

    /**
     * The one live page as a [View], so a host can attach it without importing
     * the android.webkit surface. Null before `start()` and once `stop()` has
     * completed; the instance behind a returned view is destroyed by `stop()`
     * and by a renderer death and is never reused.
     */
    override fun view(): View? = webView

    // ------------------------------------------------------------- lifecycle

    override fun start() {
        if (!lifecycle.beginStart()) {
            logger.info("start ignored: engine is ${EngineLogText.describe(lifecycle.snapshot())}")
            return
        }
        startJob = scope.launch {
            try {
                runStart()
            } catch (cancelled: CancellationException) {
                logger.info("start cancelled; releasing the engine")
                withContext(NonCancellable) { shutdown() }
                lifecycle.beginStop()
                throw cancelled
            } catch (failure: Throwable) {
                // A failed bind is a LoopbackStartException whose own message is
                // only host:port; report the real SocketException/bind cause that
                // :net recorded, not the wrapper.
                val reason = OriginFailure.startReason(failure, server.lastFailure())
                logger.error("start failed: $reason")
                withContext(NonCancellable) { shutdown() }
                lifecycle.markFailed(reason)
            }
        }
    }

    override fun stop() {
        val previous = lifecycle.snapshot()
        if (!lifecycle.beginStop()) {
            logger.info("stop ignored: engine is already Stopped")
            return
        }
        logger.info("stop requested from ${EngineLogText.describe(previous)}")
        val running = startJob
        startJob = null
        scope.launch {
            // A start in flight owns the WebView and the origin; let it finish its
            // cancellation path before the last release runs.
            running?.let { job ->
                if (job.isActive) job.cancel()
                job.join()
            }
            shutdown()
        }
    }

    private suspend fun runStart() {
        assertMainThread("start")
        recoveriesThisRun = 0
        channelTelemetry.resetForStart()
        // A start after Failed/Recovering must not inherit a live WebView (the
        // single-instance assertion would fire) or a bound port.
        shutdown()
        if (!isStarting()) {
            logger.info("start aborted after cleanup: engine is ${EngineLogText.describe(lifecycle.snapshot())}")
            return
        }

        logger.info("start: materializing the worker bundle (background thread)")
        val materialization = withContext(Dispatchers.IO) {
            workerAssets.materialize { progress ->
                logger.debug("worker assets: ${progress.describe()}")
            }
        }
        if (!isStarting()) {
            logger.info("start aborted after materialization")
            return
        }
        logger.info("start: bundle ${materialization.describe()}")

        logger.info("start: binding the loopback origin on 127.0.0.1")
        // One secret per start, shared by the origin gate/cookie and the worker's
        // PDSH_DSH_LAUNCH_TOKEN. Never logged, never persisted, never its own URL
        // key: it reaches the page only inside the `env` parameter (boot.js
        // scrubs that parameter from the visible URL immediately).
        val perStartToken = launchToken.nextLaunchToken()
        // Kept in memory only so a renderer rebuild can reload the same origin
        // (same token, same cookie) after a renderer crash.
        liveLaunchToken = perStartToken
        val bound = withContext(Dispatchers.IO) { server.start(materialization.directory, perStartToken) }
        endpoint = bound
        responder = LoopbackAssetResponder(
            store = WorkerFileStore(materialization.directory),
            port = bound.port,
            logger = logger,
            // The boot overlay is rebuilt per page load and lives outside the
            // version-stamped bundle, so the interceptor answers it from here.
            servedAssets = { listOfNotNull(servedOverlay) },
        )
        logger.info("start: origin ${EngineLogText.origin(bound)} (endpoint $bound)")
        val mountedProxy = modelProxy
        if (mountedProxy != null) {
            // The loopback origin is not a secret: the token lives in a cookie and
            // the page query, never in this string. The Worker's model traffic now
            // reaches this origin and the host's credential reaches the upstream
            // only from the proxy, so this line is the one place that can prove the
            // env rewrite happened without printing the real base URL or a key.
            logger.info(
                "start: model edge mounted: ${WorkerEnvironment.MODEL_BASE_URL}=" +
                    "${bound.origin} (the host injects the credential at the edge)",
            )
            // The endpoint is the launch's base, forwarded verbatim. A bare origin
            // is legal here but usually wrong for a Messages provider: the public
            // DeepSeek Messages base carries `/anthropic`, and a bare origin answers
            // 404 for `/v1/messages` (measured 2026-10-31). Warn once, name no host
            // and no key, and let the caller decide; guessing a prefix would embed
            // one provider's convention in the engine.
            if (mountedProxy.endpoint.normalizedBasePath == "/") {
                logger.warn(
                    "start: the mounted model base URL is a bare origin with no path prefix; " +
                        "a provider whose Messages API lives below a prefix (for example " +
                        "/anthropic) will answer 404 there — pass the provider's Messages base, " +
                        "not its origin",
                )
            }
        }
        // From here on the origin can die on a Ktor thread; :net records it and
        // this watcher turns it into Failed/lastError (see watchOriginFailures).
        watchOriginFailures()
        // A channel can also die without the origin noticing (see watchStaleChannel):
        // that one has no close callback at all, so it needs its own watcher.
        watchStaleChannel()

        configureWebContentsDebugging()
        val view = createWebView(bound.port)
        webView = view
        if (!isStarting()) {
            logger.warn("start: stop() won the race before loadUrl; rolling back")
            shutdown()
            return
        }

        // wal.md §8: the Worker is seeded from the freshly packed materialized
        // tree before it boots. `bootOverlaySource` runs only after the host's
        // recovery and tail replay, and this is the last point before the page
        // load at which the tree can be turned into the overlay.
        if (!prepareBootOverlay()) {
            failEngine(
                "boot overlay: the materialized tree could not be packed; the Worker was not started",
            )
            withContext(NonCancellable) { shutdown() }
            return
        }

        // D22: the page reaches the origin with the launch cookie instead of a
        // `?token=` spelling, and the worker receives the same secret through
        // `env`. Seed the cookie before loadUrl so the main frame, its
        // subresources and the page's WebSocket all see it.
        seedLaunchCookie(bound, perStartToken)
        val url = launchUrl(bound, perStartToken)
        logger.info("start: loading ${EngineLogText.baseUrl(url)}")
        view.loadUrl(url)
        if (!lifecycle.markRunning(bound.origin, bound.port)) {
            logger.warn("start: state is ${EngineLogText.describe(lifecycle.snapshot())} after loadUrl; rolling back")
            shutdown()
            return
        }
        logger.info("start: ${EngineLogText.describe(lifecycle.snapshot())}; capabilities ${capabilities().describe()}")
    }

    /** Releases the WebView and the origin. Idempotent, main->IO, never throws. */
    private suspend fun shutdown() {
        // Cancel first: a recorded origin death must not be reported after the
        // stop that is closing the origin, and not while a failed start unwinds.
        originWatchJob?.cancel()
        originWatchJob = null
        // A reopen episode owns the page; every teardown path (stop, a failed
        // start, a renderer rebuild) takes it down before the page it would reload.
        reopenLane.cancel()
        staleChannelWatchJob?.cancel()
        staleChannelWatchJob = null
        val stoppingOrigin = endpoint?.origin
        withContext(Dispatchers.Main.immediate) {
            // The per-start secret must not outlive its origin in the WebView
            // cookie jar: expire it before the page that used it is destroyed.
            clearLaunchCookie(stoppingOrigin)
            destroyWebView(rendererGone = false)
        }
        endpoint = null
        responder = null
        liveLaunchToken = null
        withContext(Dispatchers.IO) {
            runCatching { server.stop() }
                .onFailure { logger.warn("stop: the loopback origin did not stop cleanly: ${OriginFailure.safeReasonOf(it)}") }
        }
        channelTelemetry.onEngineStopped()
    }

    /**
     * Watches the running origin for the death :net records instead of throwing.
     *
     * The failure arrives on a Ktor thread, where `:net` must not stop the engine
     * from inside its own scope; it records the cause in
     * [LoopbackServer.lastFailure] and counts it in `LoopbackMetrics.engineFailures`.
     * Polling is the only seam `:engine` has here — `LoopbackServer` publishes no
     * listener, only those two reads, and it says so on purpose ("the caller
     * decides"). Once a failure is recorded the origin may no longer accept, so
     * its real cause becomes `Failed(reason)` and `channel.lastError` (both
     * through [OriginFailure], token-free), and the watcher stops. A healthy
     * origin records nothing and is never reported.
     */
    /**
     * Watches for the channel that dies *without* a close the origin can see.
     *
     * Measured 2026-11-01 (emulator API 35, P22): after a flap that deferred a few
     * thousand `VFS_MUT`s, the page's client gave up its socket and started
     * reconnecting, but the origin never observed the close. Its single-channel slot
     * stayed held, so every reconnect attempt was answered **HTTP 409** — and this
     * engine still reported `connected=true` while every `/api` request timed out.
     * The App looked alive and answered nothing: the same user-visible defect as the
     * closed channel, through a door [ObservedChannelHandler.onChannelLost] never
     * sees.
     *
     * The signal is `LoopbackMetrics.channelsRejected`: while one channel is live,
     * the only client that can ask for a second upgrade is the page itself, and the
     * page only retries after its socket died. So growth in that counter while
     * `connected` is true means the channel this engine believes in is a zombie.
     *
     * The recovery is the same episode a close starts: `Running -> Recovering`, and
     * the lane's escalation (a worker restart, which stops the origin and drops the
     * stale slot) follows because a reload cannot clear a held slot.
     */
    private fun watchStaleChannel() {
        staleChannelWatchJob?.cancel()
        staleChannelWatchJob = scope.launch(Dispatchers.IO) {
            var seen = server.metrics().channelsRejected
            while (true) {
                delay(STALE_CHANNEL_POLL_MILLIS)
                if (!channelTelemetry.status.value.connected) {
                    // Not connected: a refused upgrade is the reopen's normal state.
                    seen = server.metrics().channelsRejected
                    continue
                }
                val rejected = server.metrics().channelsRejected
                val accepted = server.metrics().channelsAccepted
                if (!StaleChannelRule.isStale(connected = true, rejected, seen, accepted)) {
                    seen = rejected
                    continue
                }
                logger.error(
                    "stale ordered channel: the page asked for a new upgrade and the origin " +
                        "refused it (channelsRejected=$rejected, channelsAccepted=$accepted) " +
                        "while this engine still believes it is connected; the channel died " +
                        "without a close the origin could see",
                )
                withContext(Dispatchers.Main.immediate) {
                    // The close callback that normally flips this never ran, so the
                    // screen would keep saying 「已连接」 through the whole recovery:
                    // record the loss here, with the reason only this path knows.
                    channelTelemetry.onChannelClosed(ChannelCloseCause.TRANSPORT_LOST)
                    channelTelemetry.noteError(
                        "the ordered channel is stale: the page is retrying its upgrade (HTTP 409)",
                    )
                    onOrderedChannelLost(ChannelCloseCause.TRANSPORT_LOST)
                }
                return@launch
            }
        }
    }

    private fun watchOriginFailures() {
        originWatchJob?.cancel()
        originWatchJob = scope.launch(Dispatchers.IO) {
            while (true) {
                delay(ORIGIN_FAILURE_POLL_MILLIS)
                val failure = server.lastFailure() ?: continue
                val engineFailures = server.metrics().engineFailures
                withContext(Dispatchers.Main.immediate) {
                    failEngine(OriginFailure.runtimeReason(failure, engineFailures))
                }
                return@launch
            }
        }
    }

    private fun isStarting(): Boolean = lifecycle.snapshot() == EngineHostState.Starting

    // -------------------------------------------------------------- WebView

    /**
     * Builds and configures the one WebView. UI thread only.
     *
     * Chromium binds a WebView to the thread that owns its single view thread; for
     * an App process that is the UI thread, and constructing one elsewhere throws
     * or corrupts the renderer host. The [liveWebViews] assertion is the single
     * WebView invariant of §6.3-5.
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(port: Int): WebView {
        assertMainThread("WebView construction")
        val live = liveWebViews.incrementAndGet()
        if (live != 1) {
            liveWebViews.decrementAndGet()
            throw IllegalStateException(
                "the App already owns $live live WebViews; §6.3-5 allows exactly one " +
                    "(Chromium runs one renderer per App)",
            )
        }
        val view = try {
            WebView(appContext)
        } catch (failure: Throwable) {
            liveWebViews.decrementAndGet()
            throw failure
        }
        try {
            configure(view, port)
        } catch (failure: Throwable) {
            runCatching { view.destroy() }
            liveWebViews.decrementAndGet()
            throw failure
        }
        logger.info(
            "webview created on the UI thread (live=$live, provider=" +
                (capabilities().providerPackage ?: "unknown") + ")",
        )
        return view
    }

    @Suppress("DEPRECATION")
    private fun configure(view: WebView, port: Int) {
        view.settings.apply {
            javaScriptEnabled = true // the worker page is JavaScript
            domStorageEnabled = true
            databaseEnabled = false
            allowFileAccess = false // §15-3: no file:// surface
            allowContentAccess = false // §15-3: no content:// surface
            allowFileAccessFromFileURLs = false // §15-3
            allowUniversalAccessFromFileURLs = false // §15-3, explicit on purpose
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
            cacheMode = WebSettings.LOAD_DEFAULT // the origin sends no-store per file
        }
        // §6.2 renderer ⑤ / §6.3-2: the SECOND argument is the trap. `true` waives
        // the renderer's priority as soon as the WebView is not visible, which lets
        // the OS reclaim it in the background (the FGS case). The demo keeps the
        // renderer bound and never waives it, so a backgrounded page survives.
        view.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_BOUND, false)

        // D22: the loopback origin authenticates the page with a cookie. WebView
        // accepts cookies by default; stating it here keeps the launch-cookie
        // path independent of a device setting and is required for the page's
        // WebSocket handshake to carry it too.
        CookieManager.getInstance().setAcceptCookie(true)

        view.webViewClient = EngineWebViewClient(port)
        view.webChromeClient = DialogSuppressingChromeClient(logger)
        view.setDownloadListener { url, _, _, _, _ ->
            logger.warn("download blocked (navigation whitelist): ${EngineLogText.baseUrl(url)}")
        }
    }

    private fun destroyWebView(rendererGone: Boolean) {
        val view = webView ?: return
        webView = null
        assertMainThread("WebView destruction")
        if (!rendererGone) runCatching { view.stopLoading() }
        runCatching { view.destroy() }
            .onFailure { logger.warn("webview destroy threw: ${OriginFailure.safeReasonOf(it)}") }
        logger.info("webview destroyed (live=${liveWebViews.decrementAndGet()}, rendererGone=$rendererGone)")
    }

    /** Release-build discipline (§15-3): debug only when the App itself is debuggable. */
    private fun configureWebContentsDebugging() {
        val debuggable =
            (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        WebView.setWebContentsDebuggingEnabled(debuggable)
        logger.info(
            "web contents debugging: " +
                if (debuggable) "enabled (debuggable App)" else "disabled (release App)",
        )
    }

    private fun assertMainThread(operation: String) {
        check(Looper.myLooper() === mainThread) {
            "$operation must run on the App UI thread (Chromium has one view thread); " +
                "was ${Thread.currentThread().name}"
        }
    }

    // ------------------------------------------------------------- page load

    /**
     * The launch URL of `boot.js`'s contract.
     *
     * `?image=` is the base image, `?channel=` the one WebSocket and `?env=`
     * the worker environment (JSON object, see [WorkerEnvironment]). The URL
     * carries no `?token=`: the origin already knows the per-start token and
     * the WebView was given it as the D22 launch cookie by
     * [seedLaunchCookie]. Every query is stripped by [EngineLogText.baseUrl]
     * before a line is logged, and boot.js scrubs `image`/`channel`/`env` from
     * the visible URL immediately.
     *
     * When a [modelProxy] is mounted, `env["DEEPSEEK_BASE_URL"]` is overwritten
     * with [LoopbackEndpoint.origin] here, not in `:app`: the port is assigned
     * when the origin binds, which happens after the host built the env string,
     * and the Worker must address the origin it was actually served from. Every
     * other env member the host supplied is preserved, and with no proxy the
     * host's value is untouched.
     *
     * `?overlay=` is the boot overlay of `wal.md` §8, one URL in the same spelling
     * iOS sends (`Sources/PhoneDSHEngine/WebEngineConfiguration.swift:223`). The
     * runtime applies it after the base image, so `home/` and `workspace/` from the
     * materialized tree win over the image's copies while the Worker's own code and
     * config stay untouched. `overlay` and `overlay[]` are engine-owned names, like
     * `image`/`channel`/`env`, so a host page parameter cannot inject a second
     * overlay.
     */
    private fun launchUrl(endpoint: LoopbackEndpoint, launchTokenValue: String): String {
        val params = LinkedHashMap<String, String>()
        params["image"] = endpoint.urlFor("/$IMAGE_ASSET")
        params["channel"] = endpoint.channelUrl(includeToken = false)
        servedOverlay?.let { overlay -> params["overlay"] = endpoint.urlFor(overlay.urlPath) }
        for ((name, value) in pageParams) {
            // The token is engine-owned: a host cannot move it to `token` or
            // override the `env` object that carries it. `overlay` is the boot
            // overlay this engine packed; a host-supplied one would be a second,
            // unverified tree applied after it.
            if (name == "token" || name == "image" || name == "channel" || name == "env" ||
                name == "overlay" || name == "overlay[]"
            ) {
                continue
            }
            params[name] = value
        }
        params["env"] = WorkerEnvironment.pageParam(
            launchToken = launchTokenValue,
            hostSupplied = pageParams["env"],
            modelBaseUrl = modelProxy?.let { endpoint.origin },
        )
        return endpoint.launchUrl(params, includeToken = false)
    }

    /**
     * Packs the §8 boot overlay for the page load that is about to happen.
     *
     * Called before **every** load — the first boot, a renderer rebuild and a
     * channel-reopen reload — because the overlay is an input, not an authority:
     * one packed at the previous boot would seed the Worker with a tree the host's
     * WAL has already moved past, and the channel has no per-path generation check
     * that would catch it.
     *
     * A failure leaves [servedOverlay] null, so the page would be loaded without an
     * overlay; the callers do not load it. That is deliberate — a Worker on an
     * empty view re-publishes that emptiness as ordinary mutations and overwrites
     * real content (the P28 failure), so no overlay must mean no boot, and the
     * refusal reaches the user as `Failed(...)`, never as a silent empty workspace.
     *
     * @return true when there is an overlay to serve or this composition has none.
     */
    private suspend fun prepareBootOverlay(): Boolean {
        val source = bootOverlaySource ?: run {
            servedOverlay = null
            return true
        }
        return try {
            val snapshot = withContext(Dispatchers.IO) { source.pack() }
            servedOverlay = ServedAsset(
                urlPath = snapshot.urlPath,
                file = snapshot.file,
                contentType = snapshot.contentType,
            )
            logger.info("boot overlay: serving ${snapshot.urlPath} (${snapshot.describe()})")
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            servedOverlay = null
            logger.error("boot overlay: refused: ${OriginFailure.safeReasonOf(failure)}")
            false
        }
    }

    /**
     * Seeds the D22 launch cookie into the one WebView before the page loads.
     *
     * The value is [LaunchCookie.headerValue] — the same name and attributes the
     * origin's own 303 exchange emits (iOS baseline
     * `Sources/PhoneDSHLoopback/LoopbackServer.swift:112,636-641`). The cookie is
     * host-only and `SameSite=Strict`, so it follows the page to every
     * subresource and to the page's WebSocket without ever appearing in a URL.
     *
     * The token is never logged. If the cookie store refused it, the page load
     * fails loud through [EngineWebViewClient.onReceivedHttpError] with a
     * token-free "HTTP 401", which is better than a silent half-authenticated
     * page.
     */
    private fun seedLaunchCookie(endpoint: LoopbackEndpoint, launchTokenValue: String) {
        assertMainThread("launch cookie seeding")
        val cookies = CookieManager.getInstance()
        cookies.setAcceptCookie(true)
        cookies.setCookie(endpoint.origin, LaunchCookie.headerValue(launchTokenValue))
        cookies.flush()
    }

    /** Expires the launch cookie of the origin being torn down. Never throws. */
    private fun clearLaunchCookie(origin: String?) {
        if (origin == null) return
        runCatching {
            val cookies = CookieManager.getInstance()
            cookies.setCookie(origin, LaunchCookie.deletionValue())
            cookies.flush()
        }
    }

    // -------------------------------------------------------------- clients

    private inner class EngineWebViewClient(port: Int) : WebViewClient() {
        private val policy = NavigationPolicy("http://$LOOPBACK_HOST:$port")

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url?.toString()
            if (policy.isAllowed(url)) return false
            // §15-3 navigation whitelist: only the engine origin. `file:`,
            // `content:`, `javascript:`, `data:` and any other host are blocked.
            logger.warn("navigation blocked (not the engine origin): ${EngineLogText.baseUrl(url ?: "<null>")}")
            return true
        }

        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? = responder?.respond(request)

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            logger.info("page started: ${EngineLogText.baseUrl(url ?: "<null>")}")
        }

        override fun onPageFinished(view: WebView, url: String?) {
            logger.info(
                "page finished: ${EngineLogText.baseUrl(url ?: "<null>")} " +
                    "(title=\"${EngineLogText.console(view.title.orEmpty()).take(MAX_TITLE_CHARS)}\")",
            )
            // Measure the engine that just loaded the page. This is the only
            // moment the kernel is both resolvable and actually running our code;
            // a stale report from before a renderer rebuild must not survive.
            probeKernel(view)
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            val detail = "error ${error.errorCode} (${error.description}) for " +
                EngineLogText.baseUrl(request.url?.toString() ?: "<null>")
            if (request.isForMainFrame) {
                logger.error("main frame $detail")
                failEngine("page load failed: ${error.errorCode} ${error.description}")
            } else {
                logger.warn("subresource $detail")
            }
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) {
            val detail = "HTTP ${errorResponse.statusCode} (${errorResponse.reasonPhrase}) for " +
                EngineLogText.baseUrl(request.url?.toString() ?: "<null>")
            if (request.isForMainFrame) {
                logger.error("main frame $detail")
                failEngine("page load failed: HTTP ${errorResponse.statusCode}")
            } else {
                logger.warn("subresource $detail")
            }
        }

        /**
         * Renderer death. MUST return true.
         *
         * Returning false tells the platform this App cannot recover from the
         * renderer loss, and it finishes the App process; the demo's whole point is
         * that a backgrounded engine survives a renderer kill.
         */
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            val crashed = detail.didCrash()
            if (view !== webView) {
                logger.warn("renderer gone for a WebView that is not live; ignored (still returning true)")
                return true
            }
            val cause = if (crashed) {
                "renderer crash (didCrash=true)"
            } else {
                "low-memory reclaim (didCrash=false)"
            }
            logger.error("renderer gone: $cause; destroying and rebuilding the WebView")
            channelTelemetry.noteError("renderer gone")
            if (beginRendererRecovery()) {
                // Rebuild on the next main-loop turn: the callback returns first, so
                // Chromium finishes tearing the dead renderer host down before a new
                // WebView is constructed.
                scope.launch(Dispatchers.Main) { rebuildAfterRendererGone() }
            }
            return true
        }
    }

    /**
     * `Running -> Recovering`, and the dead WebView disposed of.
     *
     * Returns true when a rebuild should follow on the next main-loop turn.
     */
    private fun beginRendererRecovery(): Boolean {
        assertMainThread("renderer recovery")
        // The dead instance is unusable: destroy it, never call loadUrl on it.
        destroyWebView(rendererGone = true)
        if (!lifecycle.markRecovering()) {
            logger.warn(
                "renderer gone while ${EngineLogText.describe(lifecycle.snapshot())}; no rebuild",
            )
            return false
        }
        if (endpoint == null) {
            failEngine("renderer lost before the origin was bound")
            return false
        }
        if (recoveriesThisRun >= MAX_RECOVERIES_PER_RUN) {
            failEngine("renderer lost more than $MAX_RECOVERIES_PER_RUN times in one run")
            return false
        }
        recoveriesThisRun += 1
        logger.info(
            "recovering: rebuilding the WebView and reloading on the same origin " +
                "(attempt $recoveriesThisRun/$MAX_RECOVERIES_PER_RUN)",
        )
        return true
    }

    /**
     * `Recovering -> Running`, on the same origin and token.
     *
     * Suspends while the boot overlay is repacked: the host keeps running across a
     * renderer rebuild, so the tree this reload must seed is the current one, not
     * the one the first page load used.
     */
    private suspend fun rebuildAfterRendererGone() {
        assertMainThread("renderer recovery")
        if (lifecycle.snapshot() != EngineHostState.Recovering) {
            logger.info(
                "recovery cancelled: state is ${EngineLogText.describe(lifecycle.snapshot())}",
            )
            return
        }
        val bound = endpoint
        if (bound == null) {
            failEngine("renderer recovery lost the origin")
            return
        }
        val token = liveLaunchToken
        if (token == null) {
            failEngine("renderer recovery lost the launch token")
            return
        }
        if (!prepareBootOverlay()) {
            failEngine(
                "renderer recovery: the boot overlay could not be repacked; no Worker was started",
            )
            return
        }
        try {
            val view = createWebView(bound.port)
            webView = view
            seedLaunchCookie(bound, token)
            val url = launchUrl(bound, token)
            logger.info("recovering: reloading ${EngineLogText.baseUrl(url)}")
            view.loadUrl(url)
            if (!lifecycle.markRunning(bound.origin, bound.port)) {
                logger.warn(
                    "recovering: state is ${EngineLogText.describe(lifecycle.snapshot())}; " +
                        "destroying the rebuilt WebView",
                )
                destroyWebView(rendererGone = false)
            } else {
                logger.info("recovered: ${EngineLogText.describe(lifecycle.snapshot())}; the page reloads and reopens the channel")
            }
        } catch (failure: Throwable) {
            failEngine("renderer recovery failed: ${OriginFailure.safeReasonOf(failure)}")
        }
    }

    private fun failEngine(reason: String) {
        if (!lifecycle.markFailed(reason)) return
        logger.error("engine failed: $reason")
        channelTelemetry.noteError(reason)
    }

    // ------------------------------------------------- ordered channel exit (P22)

    /**
     * The page's one WebSocket ended while this engine had a usable page.
     *
     * `Running -> Recovering` and hand the episode to [reopenLane]. A close in any
     * other state is somebody else's teardown (a `stop()`, a renderer rebuild, a
     * failed start) and is only recorded: `Recovering` in particular is what the
     * lane itself puts the engine in, and reacting to its own reloads would make
     * the episode restart on every attempt.
     */
    private fun onOrderedChannelLost(cause: ChannelCloseCause) {
        // The lane owns the whole decision — state gate, `Running -> Recovering`,
        // backoff, reload, and the `Recovering -> Running` on the new channel — so
        // that one class's test covers the exit instead of half of it living in an
        // Android-only file. See ChannelReopenLaneTest.
        reopenLane.onChannelLost(cause.name)
    }

    /**
     * The page handed back an open channel: the lane's episode is over.
     *
     * `Recovering -> Running` happens here and not at the reload, because a page
     * that loaded but did not reconnect is not an engine that is back. A channel
     * that opens while the engine is already `Running` (a renderer rebuild, a
     * spontaneous client reconnect after a momentary loss) is only counted.
     */
    private fun onOrderedChannelOpened() {
        val restartPending = restartRecoveryPending
        restartRecoveryPending = false
        reopenLane.onChannelOpened()
        val bound = endpoint
        if (bound == null) return
        if (lifecycle.snapshot() == EngineHostState.Recovering) {
            if (lifecycle.markRunning(bound.origin, bound.port)) {
                logger.info(
                    "recovered: the page reopened the ordered channel on the same origin; " +
                        "${EngineLogText.describe(lifecycle.snapshot())} after " +
                        "${reopenLane.attempts} reload attempt(s)",
                )
                return
            }
        }
        // The restart path lands here with the engine already Running (the restart
        // marked it); the line still has to exist, because it is the only proof the
        // new worker's channel is the one that came back.
        if (restartPending) {
            logger.info(
                "recovered: the restarted worker opened a new ordered channel; " +
                    "${EngineLogText.describe(lifecycle.snapshot())}",
            )
        }
    }

    /**
     * One reload attempt of [ChannelReopenLane]: the same page, the same origin and
     * the same launch cookie, loaded again.
     *
     * The engine thread-marshals it because `loadUrl` is a UI-thread call, and it
     * keeps the one WebView (`createWebView` is never called here): only a dead
     * renderer needs a new instance, and the single-instance assertion would refuse
     * a second one anyway.
     */
    /**
     * The escalation of a reopen episode: `stop()` then `start()` the worker.
     *
     * A reload cannot clear a stale channel slot — the obstacle is the origin, not
     * the page — so this is the one step that can: [LoopbackServer.stop] cancels
     * the live sessions (dropping the slot) and the next `start()` binds a fresh
     * origin, materializes the bundle again and loads the page against it. It is
     * the `RESTART_WORKER` action of the same D14 row the loss already took, not a
     * new state.
     *
     * Runs under [NonCancellable] because [shutdown] cancels this lane (the
     * episode that called it is the one being cancelled): the restart must finish
     * even though its caller is gone. The new channel reports itself through
     * [onOrderedChannelOpened] when the page reconnects.
     */
    private suspend fun restartWorkerForChannelReopen(): Boolean = withContext(NonCancellable) {
        logger.warn("channel reopen: restarting the worker (stop + start) to get a fresh origin and page")
        restartRecoveryPending = true
        reopenLane.cancel()
        if (!lifecycle.beginStop()) {
            logger.warn(
                "channel reopen: restart skipped, the engine is ${EngineLogText.describe(lifecycle.snapshot())}",
            )
            return@withContext false
        }
        shutdown()
        if (!lifecycle.beginStart()) {
            logger.warn("channel reopen: the restart could not start the engine again")
            return@withContext false
        }
        try {
            runStart()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            failEngine("channel reopen restart failed: ${OriginFailure.safeReasonOf(failure)}")
            return@withContext false
        }
        val running = lifecycle.snapshot() is EngineHostState.Running
        logger.info(
            "channel reopen: the worker restarted; engine is " +
                "${EngineLogText.describe(lifecycle.snapshot())}, waiting for the page's new channel",
        )
        running
    }

    private suspend fun reloadPageForChannelReopen(attempt: Int) {
        // Repack before taking the UI thread: a reload mounts a fresh Worker, and
        // the tree it must see is the one the host's WAL has now, not the one the
        // page that just lost its channel was carrying.
        if (endpoint != null && !prepareBootOverlay()) {
            failEngine(
                "channel reopen: the boot overlay could not be repacked; the page was not reloaded",
            )
            return
        }
        withContext(Dispatchers.Main.immediate) {
            val bound = endpoint
            if (bound == null) {
                failEngine("channel reopen lost the origin")
                return@withContext
            }
            val token = liveLaunchToken
            if (token == null) {
                failEngine("channel reopen lost the launch token")
                return@withContext
            }
            val view = webView
            if (view == null) {
                failEngine("channel reopen lost the page")
                return@withContext
            }
            try {
                // The cookie is per-origin and the reload is the same origin; seeding
                // it again costs one call and keeps a cleared jar from failing the
                // reload with a token-free "HTTP 401" instead of a retry.
                seedLaunchCookie(bound, token)
                val url = launchUrl(bound, token)
                logger.info(
                    "channel reopen: reloading ${EngineLogText.baseUrl(url)} " +
                        "(attempt $attempt, same WebView and origin)",
                )
                view.loadUrl(url)
            } catch (failure: Throwable) {
                failEngine("channel reopen failed: ${OriginFailure.safeReasonOf(failure)}")
            }
        }
    }

    // ------------------------------------------------------------- telemetry

    /**
     * Provider identity + androidx feature probes (§6.3-3). Never gates a load.
     *
     * A Huawei WebView reports Chromium ~99 behind a versionName from another
     * numbering scheme, so the version is for bucketing only; callers must branch
     * on [supportsWebMessageListener] and friends. The *runtime* gate is
     * [kernelReport]: it asks the engine itself (`WebViewKernelProbe`), which is
     * the only authority that survives a Play update between two app releases
     * (risk R15).
     */
    fun capabilities(): EngineCapabilities {
        val provider = runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()
        return runCatching {
            EngineCapabilities(
                providerPackage = provider?.packageName,
                providerVersion = provider?.versionName,
                supportsWebMessageListener =
                    WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER),
                supportsDocumentStartScript =
                    WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT),
                supportsWebViewRendererClient =
                    WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_CLIENT_BASIC_USAGE),
            )
        }.getOrDefault(EngineCapabilities.Unknown)
    }

    /**
     * The last measured WebView kernel, or `null` before the probe ran.
     *
     * Written on the UI thread from [EngineWebViewClient.onPageFinished] and read
     * from the host's reads; `@Volatile` because those are not the same call.
     */
    @Volatile
    private var kernel: WebViewKernelReport? = null

    override fun kernelReport(): WebViewKernelReport? = kernel

    /**
     * Asks the running engine which of the worker's required APIs it actually has.
     *
     * Runs on every `onPageFinished`, so a renderer rebuild re-measures instead of
     * trusting a stale report. The JS probe is evaluated *in the page* on purpose:
     * a Java-side `WebViewFeature` check answers a different question ("does this
     * androidx build expose the feature string?") and a version comparison answers
     * an even weaker one.
     *
     * An [KernelVerdict.UNSUPPORTED] result fails the engine loud: the plan
     * requires a WebView that cannot run the worker to be reported, not to show a
     * blank page that looks like a hang. Any other verdict is telemetry and does
     * not gate the load.
     */
    private fun probeKernel(view: WebView) {
        val provider = runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()
        val fallbackUserAgent = runCatching { WebSettings.getDefaultUserAgent(appContext) }.getOrNull()
        view.evaluateJavascript(WebViewKernelProbe.SCRIPT) { raw ->
            val report = WebViewKernelReport.of(
                providerPackage = provider?.packageName,
                providerVersionName = provider?.versionName,
                probe = WebViewKernelProbe.parse(raw),
                fallbackUserAgent = fallbackUserAgent,
            )
            kernel = report
            logger.info("webview kernel: ${report.describe()}")
            if (report.verdict == KernelVerdict.UNSUPPORTED) {
                failEngine(
                    "webview kernel cannot run the worker: missing " +
                        report.missingRequired.joinToString(", ") { it.id } +
                        " (" + report.versionLabel() + ")",
                )
            }
        }
    }

    /** Connections accepted / alive, for the single-channel assertion and logs. */
    fun channelConnectionCounts(): Pair<Long, Int> = observedChannel.channelsOpened to observedChannel.liveChannels

    companion object {
        /** Asset file name the page loads as its base image (`?image=`). */
        const val IMAGE_ASSET: String = "image.tar.gz"

        /** Rebuilds allowed per start; the next renderer death is a `Failed`. */
        const val MAX_RECOVERIES_PER_RUN: Int = 3

        private const val LOOPBACK_HOST = "127.0.0.1"
        private const val MAX_TITLE_CHARS = 80

        /** How often a running origin's recorded failure is checked; :net has no callback. */
        private const val ORIGIN_FAILURE_POLL_MILLIS = 500L

        /**
         * How often a live channel is checked for a refused upgrade.
         *
         * The page's own reconnect backoff tops out at 5 s, so one second detects a
         * zombie channel within one retry of it happening, at the cost of one atomic
         * read per second.
         */
        private const val STALE_CHANNEL_POLL_MILLIS = 1_000L

        /** Every WebView this process ever created. 0 or 1 by the invariant above. */
        private val liveWebViews = AtomicInteger()

        /** Live WebViews; the demo UI and the instrumented test assert 0 or 1. */
        fun liveWebViewCount(): Int = liveWebViews.get()
    }
}

/**
 * The only [WebChromeClient] of the engine: no dialogs, console to logcat.
 *
 * A JS dialog on a WebView without a window token (FGS, no Activity) throws
 * `BadTokenException` and takes the process down; the plan (§6.2 FGS row) and the
 * security checklist both require them to be answered without a window. Console
 * messages are forwarded because they are the best evidence that the page booted.
 */
private class DialogSuppressingChromeClient(private val logger: EngineLogger) : WebChromeClient() {
    override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
        logger.warn("js alert suppressed: ${EngineLogText.console(message.orEmpty()).take(MAX_DIALOG_CHARS)}")
        result.cancel()
        return true
    }

    override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
        logger.warn(
            "js confirm suppressed (answered cancel): " +
                EngineLogText.console(message.orEmpty()).take(MAX_DIALOG_CHARS),
        )
        result.cancel()
        return true
    }

    override fun onJsPrompt(
        view: WebView,
        url: String?,
        message: String?,
        defaultValue: String?,
        result: JsPromptResult,
    ): Boolean {
        logger.warn(
            "js prompt suppressed (answered null): " +
                EngineLogText.console(message.orEmpty()).take(MAX_DIALOG_CHARS),
        )
        result.cancel()
        return true
    }

    override fun onJsBeforeUnload(
        view: WebView,
        url: String?,
        message: String?,
        result: JsResult,
    ): Boolean {
        // Leave the page instead of showing a dialog the engine has no window for.
        result.confirm()
        return true
    }

    override fun onConsoleMessage(message: ConsoleMessage): Boolean {
        // Both halves are page-controlled. The message can be `location.href`
        // verbatim, and `sourceId()` is the document URL for an inline page
        // script — which is the launch URL, whose `env` query carries the worker
        // environment. A full launch URL in logcat is a credential leak; only
        // the query-free shape of each URL survives (EngineLogText.baseUrl).
        logger.debug(
            "console ${message.messageLevel()}: ${EngineLogText.console(message.message().orEmpty())} " +
                "(${EngineLogText.baseUrl(message.sourceId() ?: "<null>")}:${message.lineNumber()})",
        )
        return true
    }

    private companion object {
        const val MAX_DIALOG_CHARS = 120
    }
}
