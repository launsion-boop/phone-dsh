// The host's read-only snapshot, projected into the navigation facts.
// SPDX-License-Identifier: MIT
//
// This file is the one place :app answers "what does the host actually know?".
// It reads only what the composition root already measured — the engine's state
// and uptime, the HELLO, the current turn's tool events, the launch egress grant
// and two platform reads — and it leaves every other field at its `null` /
// `UNKNOWN` default so the page renders 未知 instead of an invented value.
//
// Rules this file obeys:
//   * "not measured" is `null` / `Unknown`, never `0`, `emptyList()` or `false`;
//   * an empty list is only passed when the host really observed "none";
//   * no page is told a write happened: the facts are rebuilt from readings, so a
//     gesture without a host command cannot move a value.
//
// Measured here: engine fact, engine uptime, WebView provider/version, help from
// the engine's one view, HELLO presence (the page that sent HELLO is loaded), the
// foreground-service fact (this app declares none), the battery-exemption fact,
// the launch's exact egress grant and the sessions the journal lane stored.
//
// Not measured (so `null`): workspace folders, archived sessions, pinned order,
// the session queue, schedules, session configuration, model profiles,
// web-search settings, MCP servers, memory budget and power.
package com.phonedsh.probe

import android.view.View
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.platform.EngineHostState
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.ConfigurationSnapshot
import com.phonedsh.ui.page.EgressAllowListFacts
import com.phonedsh.ui.page.EgressRule
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.MCPEditorFacts
import com.phonedsh.ui.page.MCPRegistryFacts
import com.phonedsh.engine.KernelVerdict
import com.phonedsh.engine.WebViewKernelReport
import com.phonedsh.ui.page.NewSessionBlock
import com.phonedsh.ui.page.ProviderKeyStatus
import com.phonedsh.ui.page.ProviderProfile
import com.phonedsh.ui.page.ModelProviderFacts
import com.phonedsh.ui.page.RuntimeFacts
import com.phonedsh.ui.page.RuntimeSnapshot
import com.phonedsh.ui.page.SessionListing
import com.phonedsh.ui.page.SessionRunStatus
import com.phonedsh.ui.page.SessionWorkspace
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.page.WebSearchFacts
import com.phonedsh.ui.page.WebSurfaceFacts
import com.phonedsh.ui.page.WebSurfaceSnapshot
import com.phonedsh.ui.page.WebViewRuntime
import com.phonedsh.ui.page.WorkbenchCommand
import com.phonedsh.ui.page.WorkbenchFile
import com.phonedsh.ui.page.WorkbenchSnapshot
import com.phonedsh.ui.page.WorkspaceFoldersSnapshot
import java.time.ZoneId

/**
 * The values the composition root measured once, plus the engine's live view.
 *
 * @param webView the engine's one view, or `null`; its presence is the only
 *   honest source for "the WebView exists".
 * @param uptimeMs how long the engine has been running, measured with the
 *   monotonic clock; `null` when it is not running.
 * @param webViewProvider the installed WebView provider package, or `null`.
 * @param webViewVersion the provider's version name, or `null`.
 * @param egressGrant the exact origin the launch allow-listed, or `null`.
 * @param batteryExemption whether the app is exempt from battery optimisation.
 */
internal data class HostReadings(
    val webView: View?,
    val uptimeMs: Long?,
    val webViewProvider: String?,
    val webViewVersion: String?,
    val webViewKernel: WebViewKernelReport?,
    val egressGrant: GatewayHostRule?,
    val batteryExemption: FactState,
)

/**
 * Projects the host's readings into every page's facts.
 *
 * @param readings the measured values.
 * @param state the engine lifecycle state.
 * @param handshake the merged HELLO, or `null` before the page handshook.
 * @param turn the one turn's UI state (the workbench's tool output comes from it).
 */
internal fun buildNavFacts(
    readings: HostReadings,
    state: EngineState,
    handshake: HandshakeSummary?,
    turn: AppTurnState,
): PdshNavFacts {
    val running = state is EngineHostState.Running
    // This app declares no service in its manifest, so a background turn can never
    // keep a foreground service alive. The runtime page's row and the settings
    // switch read this one fact; it is a measurement, not a default.
    val foregroundService = FactState.NO
    val providerKey = ApiKeyStore.activeFact()
    val engineFact = when (state) {
        EngineHostState.Stopped, is EngineHostState.Failed -> FactState.NO
        is EngineHostState.Running -> FactState.YES
        EngineHostState.Starting, EngineHostState.Recovering -> FactState.UNKNOWN
    }
    val webSurface = WebSurfaceFacts(
        snapshot = WebSurfaceSnapshot(
            engine = engineFact,
            // The engine owns exactly one view and this host is its only
            // container: the view being present is what makes it attachable.
            webViewAttached = when {
                readings.webView != null -> FactState.YES
                running -> FactState.NO
                else -> FactState.UNKNOWN
            },
            // A HELLO can only come from the loaded page's JavaScript, so its
            // presence is the measurement that the page finished loading.
            pageLoaded = when {
                handshake != null -> FactState.YES
                running -> FactState.NO
                else -> FactState.UNKNOWN
            },
            pageUrl = (state as? EngineHostState.Running)?.origin,
            nativeFallback = FactState.YES,
        ),
    )

    val workbench = when (turn) {
        is AppTurnState.Completed -> WorkbenchSnapshot(
            // This host cannot read a file preview, so the file rows are disabled
            // rather than silently inert (the page prints its read-only line).
            writable = FactState.NO,
            // No write tool ran, but a bash command could still write a file the
            // host never saw: the files segment stays 未知 instead of claiming
            // "none". The commands are the tool calls the worker actually made.
            files = turn.writes
                .takeIf { it.isNotEmpty() }
                ?.mapIndexed { index, write ->
                    WorkbenchFile(
                        id = "turn.write.$index",
                        name = write.path.substringAfterLast('/').ifEmpty { write.path },
                        path = write.path,
                        toolName = write.toolName,
                    )
                },
            commands = turn.commands
                .takeIf { it.isNotEmpty() }
                ?.map { command ->
                    WorkbenchCommand(
                        id = command.id,
                        command = command.command,
                        exitCode = null,
                    )
                },
        )

        else -> WorkbenchSnapshot(writable = FactState.NO)
    }

    return PdshNavFacts(
        // No host read exists for a DSH workspace folder; 未知, never "none".
        workspaceFolders = WorkspaceFoldersSnapshot(writable = FactState.NO),
        workbench = workbench,
        // The model key is the one setting this host *can* read: it is stored in the
        // Android Keystore under this App's own account, so the page can show the
        // key's existence and its masked suffix. Everything else about the provider
        // (model name, endpoint) is unknown — the host has no DSH settings store.
        modelProvider = ModelProviderFacts(
            profiles = listOf(localProviderProfile()),
            writable = FactState.NO,
        ),
        webSearch = WebSearchFacts(writable = FactState.NO),
        mcp = MCPRegistryFacts(),
        // Adding a server starts from an empty form: nothing is stored under a
        // new id. Editing an existing id is 未知 and the router says so.
        mcpEditor = MCPEditorFacts(writable = FactState.NO),
        runtime = RuntimeFacts(
            snapshot = RuntimeSnapshot(
                engine = engineFact,
                uptimeMs = if (running) readings.uptimeMs else null,
                webView = webViewProviderOrNull(readings),
                memory = null,
                power = null,
                // This app declares no service at all in its manifest, so a
                // foreground service can never be started for a background turn.
                foregroundService = foregroundService,
                foregroundServiceReason = FOREGROUND_SERVICE_REASON,
            ),
        ),
        // The App's own /v1/http policy is exactly this one exact-origin rule.
        // With no grant the route is closed (503), which is 未知 rather than an
        // empty rule table: "deny all" is a policy, "not configured" is not.
        egress = EgressAllowListFacts(
            rules = readings.egressGrant?.let { grant ->
                listOf(
                    EgressRule(
                        id = EGRESS_GRANT_ID,
                        host = grant.host,
                        scheme = grant.scheme,
                        port = grant.port,
                    ),
                )
            },
        ),
        // No scheduler exists on this host.
        automation = AutomationFacts(),
        // The page's own read-only mechanism: this host knows the settings are
        // not writable (it has no write command) even though it cannot read them,
        // so `settingsWritable = NO` is a measured fact rather than a claim.
        configuration = ConfigurationFacts(
            snapshot = ConfigurationSnapshot(settingsWritable = FactState.NO),
        ),
        webSurface = webSurface,
        // One field per mirrored settings row; 未知 wherever this host read nothing.
        settings = SettingsFacts(
            // No permission editor exists on this host, so no preset is stored.
            defaultPermissionTier = null,
            // The one service this host can speak about is its own key. A stored key
            // — even one the service rejected — is a configured provider; the store
            // saying "none" is 未配置. An unreadable store also renders 未配置,
            // because the baseline's row has no third wording (reported as a gap).
            modelProviderName = when (providerKey.status) {
                ProviderKeyStatus.CONFIGURED, ProviderKeyStatus.INVALID -> LOCAL_PROVIDER_NAME
                ProviderKeyStatus.NOT_CONFIGURED, ProviderKeyStatus.UNKNOWN -> null
            },
            // No MCP registry, web-search setting or composer preference is read.
            mcpServerCount = null,
            backgroundKeepAlive = foregroundService,
            webSearch = null,
            // The launch grant is this App's own /v1/http rule, not the engine's
            // effective allow list, so the address count stays unread, not 1.
            egressAddressCount = null,
            busyEnterMode = null,
            versionName = null,
            engineStarted = engineFact,
            // The platform appendix reads are the same three this file always had.
            platform = SettingsPlatformFacts(
                // Not measured: the app never requests POST_NOTIFICATIONS, so "denied"
                // would be a claim about a prompt that never happened.
                notifications = FactState.UNKNOWN,
                batteryExemption = readings.batteryExemption,
                // Not measured: the manifest declares no enableOnBackInvokedCallback,
                // but the runtime form is the platform's to report, not this file's.
                predictiveBack = FactState.UNKNOWN,
            ),
        ),
    )
}

// ---------------------------------------------------------------------------
// Sessions facts (SessionsPage's host inputs)
// ---------------------------------------------------------------------------

/**
 * One session the host has evidence for.
 *
 * This host has no session index of its own. The two sources it really owns are
 * the journal lane (one durable file per session it persisted) and the session a
 * completed app turn opened. [lastActivityMs] is therefore either the session
 * file's last write (a filesystem reading) or the wall-clock instant the host saw
 * that turn complete; `null` means neither was read.
 *
 * @param id the session id exactly as the store recovered it.
 * @param lastActivityMs the wall-clock reading of the last observed activity, or
 *   `null` when the host has no timestamp for this session.
 */
internal data class HostSessionRecord(
    val id: String,
    val lastActivityMs: Long?,
)

/**
 * What the host has read about its sessions.
 *
 * @param waiting true until the journal lane has been scanned at least once; the
 *   page renders its waiting state for this value, never "no sessions".
 * @param sessions the rows the host really found; a failed re-read keeps them.
 * @param failure the token-free reason the last scan failed, or `null`.
 * @param currentSessionID the session this app itself opened (the last completed
 *   turn), or `null`; never a session inferred from a file.
 */
internal data class HostSessionSnapshot(
    val waiting: Boolean = true,
    val sessions: List<HostSessionRecord> = emptyList(),
    val failure: String? = null,
    val currentSessionID: String? = null,
    /**
     * True while a journal scan is running, so the page's pull-to-refresh can
     * show its own spinner. It is a fact about the host (a read is in flight),
     * not a UI wish: the page never starts a scan itself.
     */
    val scanInFlight: Boolean = false,
)

/**
 * The sessions page's host facts: one field per input of
 * `SessionsScreenState.from`.
 *
 * Every field here is either measured or `null`. [workspaces] and
 * [archivedSessions] are `null` because this host has no workspace registry and
 * no archive store, so the page renders 未知 rather than claiming "none"; the
 * session list is empty only after a successful scan, never before one. The two
 * ordering fields are empty lists because they are not facts about the host: this
 * host has no pinned-order or folder-order store, which is a gap reported with
 * the contract, not a "nothing is pinned" measurement.
 *
 * @param sessions the host's session rows in host order.
 * @param waiting true before the first completed scan.
 * @param failure the last scan's token-free failure, or `null`.
 * @param workspaces the host's folders; always `null` here.
 * @param archivedSessions the host's archived sessions; always `null` here.
 * @param currentSessionID the session this app opened, or `null`.
 * @param newSessionBlock why 新建会话 is blocked, or `null` when it is not.
 * @param pinnedSessionIDs the host's pinned order; `null` here, because this
 *   host has no pin store. `null` means "not reported" (the page keeps the
 *   natural order without claiming nothing is pinned); `emptyList()` would mean
 *   "reported, and nothing is pinned", which is a fact this host cannot assert.
 * @param workspaceOrder the host's folder order; `null` for the same reason.
 */
internal data class HostSessionsFacts(
    val sessions: List<SessionListing> = emptyList(),
    val waiting: Boolean = true,
    val failure: String? = null,
    val workspaces: List<SessionWorkspace>? = null,
    val archivedSessions: List<SessionListing>? = null,
    val currentSessionID: String? = null,
    val newSessionBlock: NewSessionBlock? = null,
    val pinnedSessionIDs: List<String>? = null,
    val workspaceOrder: List<String>? = null,
)

/**
 * Projects the host's session snapshot into the sessions page's facts.
 *
 * The blocked reason for 新建会话 is the engine/turn verdict the page may not
 * compute itself: no engine means the row cannot create anything, and a running
 * turn means the next one has to wait. A turn's session id is only known when the
 * turn ends (the client returns it with the completed turn), so no row is ever
 * marked 运行中 by this host; the blocked reason carries that fact instead.
 *
 * @param state the engine lifecycle state.
 * @param turn the one turn's UI state.
 * @param snapshot what the host read from the journal lane and its own turns.
 */
internal fun buildSessionsFacts(
    state: EngineState,
    turn: AppTurnState,
    snapshot: HostSessionSnapshot,
): HostSessionsFacts = HostSessionsFacts(
    // This host has no title store: an empty title is the page's own untitled
    // policy (新会话), not a name this file invented. The row still carries the
    // real session id and the real last-write reading.
    sessions = snapshot.sessions.map { record ->
        SessionListing(
            id = record.id,
            title = "",
            updatedAtMs = record.lastActivityMs,
            status = SessionRunStatus.IDLE,
        )
    },
    waiting = snapshot.waiting,
    failure = snapshot.failure,
    workspaces = null,
    archivedSessions = null,
    currentSessionID = snapshot.currentSessionID,
    newSessionBlock = when {
        state !is EngineHostState.Running -> NewSessionBlock.ENGINE_NOT_STARTED
        turn is AppTurnState.Running -> NewSessionBlock.TURN_RUNNING
        else -> null
    },
    pinnedSessionIDs = null,
    workspaceOrder = null,
)

/**
 * Folds the host facts and the page's local UI events into the page state.
 *
 * Pure: no clock is read here, the caller supplies [nowMs] and the [zone] the
 * relative labels render in.
 *
 * @param local the drawer's local UI events.
 * @param nowMs the instant the labels are relative to.
 * @param zone the zone the date fallback is rendered in.
 */
internal fun HostSessionsFacts.toScreenState(
    local: SessionsLocalState,
    nowMs: Long,
    zone: ZoneId,
): SessionsScreenState = SessionsScreenState.from(
    sessions = sessions,
    local = local,
    nowMs = nowMs,
    zone = zone,
    waiting = waiting,
    failure = failure,
    workspaces = workspaces,
    archivedSessions = archivedSessions,
    currentSessionID = currentSessionID,
    newSessionBlock = newSessionBlock,
    pinnedSessionIDs = pinnedSessionIDs,
    workspaceOrder = workspaceOrder,
)

/**
 * The WebView rows: provider, engine version and the runtime feature gate.
 *
 * The version shown is the *engine's* (`Chromium NN` from the user agent), with
 * the provider's versionName as a parenthetical, because versionName is not a
 * Chromium version on the providers the plan worries about (R4). The gate is
 * [WebViewRuntime.featureGate], fed from the probe's own measurements: `NO` when
 * a required API is missing, `YES` when every required feature was measured and
 * present, `UNKNOWN` while nothing was measured. A missing measurement is never
 * rendered as support.
 */
private fun webViewProviderOrNull(readings: HostReadings): WebViewRuntime? {
    val kernel = readings.webViewKernel
    if (readings.webViewProvider == null && readings.webViewVersion == null && kernel == null) {
        return null
    }
    val gate = when (kernel?.verdict) {
        KernelVerdict.UNSUPPORTED -> FactState.NO
        KernelVerdict.SUPPORTED, KernelVerdict.DEGRADED -> FactState.YES
        KernelVerdict.UNVERIFIED, null -> FactState.UNKNOWN
    }
    return WebViewRuntime(
        provider = kernel?.providerPackage ?: readings.webViewProvider,
        version = kernel?.versionLabel() ?: readings.webViewVersion,
        featureGate = gate,
        featureGateDetail = kernel?.featureGateDetail(),
    )
}

/** The one model service this host knows, by the name the settings row shows. */
private const val LOCAL_PROVIDER_NAME: String = "DeepSeek（本机）"

/** The host's own words for the missing foreground service. */
private const val FOREGROUND_SERVICE_REASON: String = "App 未声明前台服务"

/** Stable id of the single rule the launch installed. */
private const val EGRESS_GRANT_ID: String = "pdsh.launch.grant"

/**
 * The single provider profile this host can speak about: its own model key.
 *
 * The endpoint and model name are the launch's values when it named them, and `null`
 * otherwise — a page that cannot read them must say 未知 rather than show a default.
 * The key fact carries only the masked suffix; the store never hands out the key.
 */
private fun localProviderProfile(): ProviderProfile {
    val fact = ApiKeyStore.activeFact()
    return ProviderProfile(
        id = "local",
        name = LOCAL_PROVIDER_NAME,
        model = ProbeLaunchConfig.active().modelName,
        endpoint = ProbeLaunchConfig.active().deepseekBaseUrl,
        key = fact,
        selected = true,
    )
}
