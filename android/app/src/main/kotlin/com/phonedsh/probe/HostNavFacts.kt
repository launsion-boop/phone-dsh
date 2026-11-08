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
// background lane's readings (the merged manifest's components, the notification
// link and the API level, which together decide whether a background window can
// open), the battery-exemption fact, the launch's exact egress grant, whether the
// app's one workspace directory exists, the sessions the journal lane stored, the
// model service's device record and key state, the command surface the HELLO
// advertised, and the phone-permission matrix's device reads (the app's own
// declared/granted permissions, device-admin denials, the notification app-op,
// DND access and hardware presence).
//
// Not measured (so `null`): archived sessions, pinned order, the session queue,
// schedules, session configuration, MCP servers, memory budget and power. The
// workspace *catalog* is not measured either: this host has no
// `workspace/list` read, so the one folder row below is the single workspace
// root this app itself owns, not a catalog entry.
package com.phonedsh.probe

import android.view.View
import com.phonedsh.domain.device.HostPermissionReadings
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.platform.EngineHostState
import com.phonedsh.shell.AcceleratorLimits
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
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.ProviderFailureReason
import com.phonedsh.ui.page.ProviderKeyStatus
import com.phonedsh.ui.page.ProviderModelDraft
import com.phonedsh.ui.page.ProviderProfile
import com.phonedsh.ui.page.ModelProviderFacts
import com.phonedsh.ui.page.RuntimeLastError
import com.phonedsh.ui.page.RuntimeFacts
import com.phonedsh.ui.page.RuntimeSnapshot
import com.phonedsh.ui.page.SessionListing
import com.phonedsh.ui.page.SessionRunStatus
import com.phonedsh.ui.page.SessionWorkspace
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.page.ShellLimits
import com.phonedsh.ui.page.ShellSnapshot
import com.phonedsh.ui.page.WebSurfaceFacts
import com.phonedsh.ui.page.WebSurfaceSnapshot
import com.phonedsh.ui.page.WebViewRuntime
import com.phonedsh.ui.page.WorkbenchCommand
import com.phonedsh.ui.page.WorkbenchFile
import com.phonedsh.ui.page.WorkbenchSnapshot
import com.phonedsh.ui.page.WorkspaceFolder
import com.phonedsh.ui.page.WorkspaceFoldersSnapshot
import com.phonedsh.ui.surface.preview.PreviewWorkspace
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
 * @param background the background lane's readings: what the merged APK declares,
 *   what the notification link can do right now, and the API level. The
 *   `foregroundService` and `notifications` facts are derived from these, never
 *   from a constant.
 * @param workspacePresent whether `<filesDir>/xl/materialized/workspace` is a
 *   directory: the measured existence of the tree the files page lists. `false`
 *   means the host measured no workspace on disk, not an empty one.
 * @param permissions this app's own permission/hardware reading, taken from
 *   `:domain`'s `AndroidHostPermissions` over the platform snapshot
 *   `AndroidDeviceCapabilities.platformFacts`. It is one walk of the platform's
 *   permission state; the phone-permissions page is its only consumer today.
 * @param permissionAsks the permissions this app has already sent to the platform
 *   (`PhonePermissionAsks`). It is a host fact, not a value of the snapshot: Android
 *   cannot tell 未请求 from 已拒绝 by itself, so the ask log is what the 已拒绝 branch
 *   of the permission mapping reads.
 * @param permissionInFlight the capability whose system permission prompt is on
 *   screen, or `null`; the page disarms that one row while it is up.
 * @param officialWebSearchEnabled whether this launch mounted the automatic
 *   official Search/Fetch grant (selected official model + readable saved key).
 *   It is measured in the composition root, not re-derived by the page.
 * @param independentWebSearchEnabled whether this launch mounted the independent
 *   Search/Fetch grant instead (`spec/v1/gateway-independent-search.md`).
 */
internal data class HostReadings(
    val webView: View?,
    val uptimeMs: Long?,
    val webViewProvider: String?,
    val webViewVersion: String?,
    val webViewKernel: WebViewKernelReport?,
    val egressGrant: GatewayHostRule?,
    val officialWebSearchEnabled: Boolean = false,
    val independentWebSearchEnabled: Boolean = false,
    val batteryExemption: FactState,
    val background: HostBackgroundReadings,
    val workspacePresent: Boolean,
    val permissions: HostPermissionReadings,
    val permissionAsks: Set<String> = emptySet(),
    val permissionInFlight: PhoneCapability? = null,
    /**
     * The D14 failure the controller is holding, when the host booted or ended
     * in `Failed`. The runtime page's 最近出錯 reads this before the turn
     * state: a host that cannot admit writes is the newer, stronger failure
     * even when the last chat turn completed.
     */
    val hostFailure: HostFailureReading? = null,
)

/**
 * One D14 failure, projected for the runtime page.
 *
 * [code] is the closed `ControllerFailure` vocabulary; [detail] is the
 * workspace-relative reason the store recorded (`LogException.detail`, never a
 * record body). A cold boot restores the code from `host-state.json`; a live
 * failure normally carries both.
 */
internal data class HostFailureReading(
    val code: String,
    val detail: String? = null,
) {
    /** The text the runtime page shows; a code alone is still a real reason. */
    val message: String
        get() = detail?.takeIf { it.isNotBlank() } ?: code
}

/**
 * Projects the host's readings into every page's facts.
 *
 * @param readings the measured values.
 * @param state the engine lifecycle state.
 * @param handshake the merged HELLO, or `null` before the page handshook.
 * @param turn the one turn's UI state (the workbench's tool output comes from it).
 * @param preferences the values the host stores for the settings index and the
 *   chat-appearance page (`PreferenceStore`). They are the one non-measured input
 *   this function takes, and they are still a *read*: the store load, not a
 *   default invented here.
 */
internal fun buildNavFacts(
    readings: HostReadings,
    state: EngineState,
    handshake: HandshakeSummary?,
    turn: AppTurnState,
    preferences: Preferences,
): PdshNavFacts {
    val running = state is EngineHostState.Running
    // The background window is not a host opinion: it is the conjunction of what
    // the merged manifest declares and what the notification link can do right
    // now. `HostBackground` reads both, so this file only projects the verdict —
    // YES when every precondition was measured true, NO with the one that failed.
    val backgroundWindow = readings.background.window
    val foregroundService = backgroundWindow.state
    val notifications = notificationFact(readings.background.capability)
    val providerKey = ProbeLaunchConfig.active().keyFact()
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

    val phonePermissions = phonePermissionsFacts(
        readings = readings.permissions,
        asked = readings.permissionAsks,
        inFlight = readings.permissionInFlight,
    )
    val phonePermissionSummary = phonePermissions.statuses?.takeIf { it.isNotEmpty() }?.let { statuses ->
        val usable = statuses.values.count { it.permitsUse }
        val measuredCount = statuses.size
        com.phonedsh.ui.UiStrings.settingsNativeText(
            preferences.language?.id,
            "$usable / $measuredCount 项权限可用",
            "$usable of $measuredCount measured permissions available",
        )
    }

    return PdshNavFacts(
        workspaceFolders = workspaceFoldersFact(readings.workspacePresent),
        workbench = workbench,
        // The model service is the one setting this host *can* write: the device
        // record holds the non-secret row (name/model/endpoint) and the key lives in
        // [ApiKeyStore]'s Keystore envelope. `writable` is YES only when that record
        // is installed — a host without it has no save command, and saying NO is the
        // difference between "the page is read-only" and "this build cannot save".
        modelProvider = modelProviderFacts(engineFact),
        // 网页搜索 is writable: the independent Search/Fetch document and its own key
        // account (`WebSearchSettingsStore`), projected by `webSearchFacts`. 什么时候生效
        // offers the one engine verb that matches this state.
        webSearch = webSearchFacts(
            store = WebSearchSettingsStore.active(),
            officialEnabled = readings.officialWebSearchEnabled,
            modelConfigured = ProbeLaunchConfig.active().deepseekBaseUrl != null,
            proxyRequested = ProbeLaunchConfig.active().modelProxy,
            engineStarted = engineFact,
        ),
        mcp = MCPRegistryFacts(),
        // Adding a server starts from an empty form: nothing is stored under a
        // new id. Editing an existing id is 未知 and the router says so.
        mcpEditor = MCPEditorFacts(writable = FactState.NO),
        // The command surface is the accelerators this host really advertises: the
        // HELLO's host caps are the one measurement that says which of them the
        // engine was told it can run. No HELLO means no snapshot, and the page keeps
        // its 还没接上命令 body.
        shell = shellSnapshot(handshake),
        runtime = RuntimeFacts(
            snapshot = RuntimeSnapshot(
                engine = engineFact,
                uptimeMs = if (running) readings.uptimeMs else null,
                webView = webViewProviderOrNull(readings),
                memory = null,
                power = null,
                // The measured verdict from `HostBackground`: the components the
                // merged APK declares, plus the notification link, plus the API
                // level. A NO carries the precondition that failed.
                foregroundService = foregroundService,
                foregroundServiceReason = backgroundWindow.detail,
                // `null` means "this host has not read it" and the page prints
                // 读取不到; a `RuntimeLastError(null)` means "it read it and there was
                // no error". Conflating the two would let an idle app claim it had
                // no failures, which is a claim it has not earned.
                lastError = runtimeLastError(turn, readings.hostFailure),
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
        // `settingsWritable` is about the **session/plugin configuration** page,
        // not the preference pages: this host still has no session-config write
        // command, so NO stays the measured answer. The preference pages carry
        // their own capability (`PdshNavHost`'s `preferencesWritable`), which this
        // app now reports YES because it owns a preference store.
        configuration = ConfigurationFacts(
            snapshot = ConfigurationSnapshot(settingsWritable = FactState.NO),
        ),
        webSurface = webSurface,
        // One field per mirrored settings row; 未知 wherever this host read nothing.
        // The permission matrix is the one page whose whole input is a device read:
        // the host reports only the rows something on this device actually answered
        // and leaves the rest to the page's unread state, and it reports no audit
        // because it has none. See `HostPhonePermissions.kt` for the row-by-row rule.
        phonePermissions = phonePermissions,
        settings = SettingsFacts(
            // HostShell overlays this with the DSH permission namespace readback;
            // this pure device-reading projection has not read that namespace.
            defaultPermissionTier = null,
            // The one service this host can speak about is its own row: the saved
            // device record names it, or — when nothing is saved — the launch's
            // service does. A stored key (even one the service rejected) is a
            // configured provider; the store saying "none" is 未配置.
            modelProviderName = activeProviderName(ProbeLaunchConfig.active())
                ?: when (providerKey.status) {
                    ProviderKeyStatus.CONFIGURED, ProviderKeyStatus.INVALID -> LOCAL_PROVIDER_NAME
                    ProviderKeyStatus.NOT_CONFIGURED, ProviderKeyStatus.UNKNOWN -> null
                },
            providerSetupRequired = when (providerKey.status) {
                ProviderKeyStatus.NOT_CONFIGURED -> true
                ProviderKeyStatus.CONFIGURED, ProviderKeyStatus.INVALID -> false
                ProviderKeyStatus.UNKNOWN -> null
            },
            phonePermissionSummary = phonePermissionSummary,
            // The five 通用-tab pickers plus the three font sizes are the values
            // this host now stores (`PreferenceStore`): every field is a real read,
            // so the page shows the stored choice instead of 未设置.
            preferences = preferences.toSettingsPreferences(),
            // No MCP registry, web-search setting or composer preference is read.
            mcpServerCount = null,
            // 后台运行 is the stored preference, not the platform's capability: the
            // switch position is the user's choice, and the runtime page keeps
            // reporting whether the mechanism can actually open a window
            // (`foregroundService` + its measured reason below).
            backgroundKeepAlive = if (preferences.backgroundKeepAlive) {
                FactState.YES
            } else {
                FactState.NO
            },
            webSearch = null,
            // The launch grant is this App's own /v1/http rule, not the engine's
            // effective allow list, so the address count stays unread, not 1.
            egressAddressCount = null,
            busyEnterMode = preferences.busyEnterMode,
            // The index keeps its signing-qualified APK label. About receives
            // the raw version and build code as separate package facts.
            versionName = BuildConfig.VERSION_NAME + " · " + BuildConfig.SIGNING_NOTICE,
            buildNumber = BuildConfig.VERSION_CODE.toString(),
            rawVersionName = BuildConfig.VERSION_NAME,
            engineStarted = engineFact,
            // The platform appendix reads are the same three this file always had.
            platform = SettingsPlatformFacts(
                // Measured, not 未知: the app asks for POST_NOTIFICATIONS before the
                // first turn and the probe reads the answer back, so this row is
                // the same predicate the background channel uses.
                notifications = notifications,
                batteryExemption = readings.batteryExemption,
                // Measured in `BackNavigation.kt`: the manifest opts in
                // (`android:enableOnBackInvokedCallback`), the platform must have the
                // invoker (API 33+), and on API 34+ this process must have seen the
                // gesture arrive through it. A declaration alone is not a device
                // answer, so the row says 未知 until the platform has said yes.
                predictiveBack = predictiveBackFact(),
            ),
        ),
    )
}

// ---------------------------------------------------------------------------
// The one workspace folder
// ---------------------------------------------------------------------------

/**
 * The folder row the 工作文件夹 page shows, from the one workspace fact this host
 * actually measured.
 *
 * This host has no DSH workspace *catalog* (`workspace/list` is not read), so it
 * cannot report a list of workspaces. What it does own is exactly one workspace on
 * disk — `<filesDir>/xl`, the root every durable store is built over
 * (`ProbeEngineViewModel.WORKSPACE_DIRECTORY`) — and the files page lists that
 * workspace's materialized tree (`<workspace>/materialized/workspace`,
 * `WalPaths.materializedWorkspace`). [present] is that tree's existence, measured
 * by the composition root.
 *
 * The row is reported only when the directory exists: one real folder that opens a
 * real listing. When it does not (an install whose engine never recovered), the
 * snapshot keeps `folders = null` — 未知, because "no workspace directory was
 * measured" is a different claim from "the host has no folders".
 *
 * The name and id are the materialized directory's own name (`workspace`, the
 * mirror of the Worker's `/dsh/workspace`), which the page's own display rule
 * renders 默认文件夹 — the baseline's name for its built-in folder. No catalog id,
 * display name or session count is invented: [WorkspaceFolder.sessionCount] stays
 * `null` (未知), because this host has no per-folder session index.
 *
 * @param present whether the materialized workspace directory exists.
 */
private fun workspaceFoldersFact(present: Boolean): WorkspaceFoldersSnapshot =
    if (!present) {
        WorkspaceFoldersSnapshot(writable = FactState.NO)
    } else {
        WorkspaceFoldersSnapshot(
            folders = listOf(
                WorkspaceFolder(
                    id = LOCAL_WORKSPACE_NAME,
                    name = LOCAL_WORKSPACE_NAME,
                    sessionCount = null,
                ),
            ),
            // The host cannot create, switch or delete a folder (§1 names no such
            // command), so the page stays read-only. Opening a folder's files is a
            // read, not a write: that edge is the route's, never this flag's.
            writable = FactState.NO,
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
 * @param title the conversation's name from the chat records (`ChatSessionStore`),
 *   or empty for a journal row this App never opened — the page's own untitled
 *   policy then applies. The journal itself has no title member.
 */
internal data class HostSessionRecord(
    val id: String,
    val lastActivityMs: Long?,
    val title: String = "",
    /** Non-null only for app-owned chats whose cwd the host recorded. */
    val workspaceID: String? = null,
    /** True only when the host's persistent chat record reports a pin. */
    val pinned: Boolean = false,
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
    /** Archived rows measured by the app's persistent chat store. */
    val archivedSessions: List<HostSessionRecord> = emptyList(),
    /** IDs explicitly marked pinned by the persistent chat store. */
    val pinnedSessionIDs: Set<String> = emptySet(),
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
 * Every field here is either measured or `null`. [workspaces] is reported only
 * when the one materialized `/dsh/workspace` directory exists; it is not a
 * fabricated workspace catalog. [archivedSessions] comes from persisted App
 * chat metadata. The session list is empty only after a successful scan, never
 * before one. Pin and folder order reflect the fields the host actually stores.
 *
 * @param sessions the host's session rows in host order.
 * @param waiting true before the first completed scan.
 * @param failure the last scan's token-free failure, or `null`.
 * @param workspaces the one measured workspace, or `null` when its existence
 *   was not established.
 * @param archivedSessions the archived App chats, or `null` if not measured.
 * @param currentSessionID the session this app opened, or `null`.
 * @param newSessionBlock why 新建会话 is blocked, or `null` when it is not.
 * @param pinnedSessionIDs the stored pinned chat IDs in display order.
 * @param workspaceOrder the host's one-folder order when its materialized root
 *   exists, or `null` when it does not.
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
/**
 * The runtime page's 最近出錯.
 *
 * D14 `Failed` wins over the turn state: the host is the layer that owns
 * durability, and a host that cannot open admission is the failure a user can
 * act on even when the last turn finished normally. `null` still means "this
 * host has not read it", and `RuntimeLastError(null)` means "it read it and
 * there was no error" — the distinction the runtime page renders as
 * 读取不到 versus 无错误.
 */
internal fun runtimeLastError(
    turn: AppTurnState,
    hostFailure: HostFailureReading?,
): RuntimeLastError? {
    if (hostFailure != null) return RuntimeLastError(message = hostFailure.message)
    return when (turn) {
        AppTurnState.Idle, AppTurnState.Running -> null
        is AppTurnState.Completed -> RuntimeLastError(message = null)
        is AppTurnState.Failed -> RuntimeLastError(message = turn.reason)
    }
}

internal fun buildSessionsFacts(
    state: EngineState,
    turn: AppTurnState,
    snapshot: HostSessionSnapshot,
    workspacePresent: Boolean? = null,
    workspacePath: String? = null,
): HostSessionsFacts = HostSessionsFacts(
    // This host has no title store: an empty title is the page's own untitled
    // policy (新会话), not a name this file invented. The row still carries the
    // real session id and the real last-write reading.
    sessions = snapshot.sessions.map { record ->
        SessionListing(
            id = record.id,
            title = record.title,
            updatedAtMs = record.lastActivityMs,
            status = SessionRunStatus.IDLE,
        )
    },
    waiting = snapshot.waiting,
    failure = snapshot.failure,
    // The only folder exposed here is one the host actually measured on disk.
    // App-created chats carry their real cwd; older journal-only rows have no
    // folder association and stay in the ungrouped section.
    workspaces = if (workspacePresent == true && !workspacePath.isNullOrBlank()) {
        listOf(
            SessionWorkspace(
                id = DEFAULT_WORKSPACE_ID,
                title = workspacePath,
                sessionIDs = snapshot.sessions
                    .filter { it.workspaceID == DEFAULT_WORKSPACE_ID }
                    .map { it.id },
            ),
        )
    } else {
        null
    },
    archivedSessions = snapshot.archivedSessions.map { record ->
        SessionListing(
            id = record.id,
            title = record.title,
            updatedAtMs = record.lastActivityMs,
            status = SessionRunStatus.IDLE,
        )
    },
    currentSessionID = snapshot.currentSessionID,
    newSessionBlock = when {
        state !is EngineHostState.Running -> NewSessionBlock.ENGINE_NOT_STARTED
        turn is AppTurnState.Running -> NewSessionBlock.TURN_RUNNING
        else -> null
    },
    pinnedSessionIDs = snapshot.pinnedSessionIDs.toList(),
    workspaceOrder = if (workspacePresent == true && !workspacePath.isNullOrBlank()) {
        listOf(DEFAULT_WORKSPACE_ID)
    } else {
        null
    },
)

/** Stable id of the one host-owned DSH workspace (`/dsh/workspace`). */
internal const val DEFAULT_WORKSPACE_ID: String = "/dsh/workspace"

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

/**
 * The materialized workspace's own directory name.
 *
 * Taken from the preview root's last segment (`PreviewWorkspace.WORKSPACE`) instead
 * of being spelled again here: the folder row and the files page then name the same
 * tree by construction, so the two cannot drift.
 */
private const val LOCAL_WORKSPACE_NAME: String = PreviewWorkspace.WORKSPACE

/** Stable id of the single rule the launch installed. */
private const val EGRESS_GRANT_ID: String = "pdsh.launch.grant"

/**
 * The single provider profile this host can speak about: its own model key.
 *
 * The endpoint and model name are the launch's values when it named them, and `null`
 * otherwise — a page that cannot read them must say 未知 rather than show a default.
 * The key fact carries only the masked suffix; the store never hands out the key.
 */
private fun activeProviderName(launch: ProbeLaunchConfig): String? {
    val profiles = ProviderConfigStore.active()?.snapshot()?.profiles.orEmpty()
    return launch.providerProfileId?.let { activeId -> profiles.firstOrNull { it.id == activeId }?.name }
        ?: if (launch.providerProfileId == null && launch.deepseekBaseUrl != null) LOCAL_PROVIDER_NAME else null
}

private fun localProviderProfile(launch: ProbeLaunchConfig, engineStarted: FactState): ProviderProfile {
    val fact = launch.keyFact()
    return ProviderProfile(
        id = "local",
        name = LOCAL_PROVIDER_NAME,
        model = launch.modelName,
        endpoint = launch.deepseekBaseUrl,
        key = fact,
        selected = false,
        active = if (engineStarted == FactState.YES) launch.deepseekBaseUrl != null else null,
    )
}

/**
 * The model-service page's facts, from the device record when there is one.
 *
 * Three honest states, and only the middle one is a save:
 *   * the store is not installed (a preview, a Robolectric host, an `:app` build
 *     without a files dir) → `writable = NO`, because there is no save command;
 *   * a record exists or the store is empty → `writable = YES`; an empty store
 *     shows the launch-derived service, which is the one the engine really uses;
 *   * the record cannot be read → `profiles = null` and CONFIG_UNREADABLE: 未知,
 *     never "no service" (which would invite an overwrite).
 *
 * @param engineStarted whether the local engine runs, so the page can say whether
 *   a saved change is already in effect.
 */
private fun modelProviderFacts(engineStarted: FactState): ModelProviderFacts {
    val store = ProviderConfigStore.active()
        ?: return ModelProviderFacts(writable = FactState.NO)
    return modelProviderFactsFrom(store.read(), ProbeLaunchConfig.active(), engineStarted)
}

/** Pure provider facts projection, including persisted-next and process-active identity. */
internal fun modelProviderFactsFrom(
    read: ProviderStoreRead,
    launch: ProbeLaunchConfig,
    engineStarted: FactState,
): ModelProviderFacts = when (read) {
    is ProviderStoreRead.Stored -> ModelProviderFacts(
        profiles = read.snapshot.profiles.map { record ->
            profileOf(
                record,
                selected = record.id == read.snapshot.selectedId,
                active = if (engineStarted == FactState.YES) record.id == launch.providerProfileId else null,
            )
        },
        writable = FactState.YES,
        engineStarted = engineStarted,
    )
    ProviderStoreRead.Empty -> ModelProviderFacts(
        // The ephemeral local row is meaningful only when this process has a
        // concrete launch endpoint. With no route there is no provider to
        // manufacture; the page shows its authoritative empty state.
        profiles = if (launch.deepseekBaseUrl != null) {
            listOf(localProviderProfile(launch, engineStarted))
        } else {
            emptyList()
        },
        writable = FactState.YES,
        engineStarted = engineStarted,
    )
    ProviderStoreRead.Unreadable -> ModelProviderFacts(
        profiles = null,
        failure = ProviderFailureReason.CONFIG_UNREADABLE,
        writable = FactState.YES,
        engineStarted = engineStarted,
    )
}

/** One stored record as the page's row, with its own key account read from the Keystore. */
private fun profileOf(record: ProviderRecord, selected: Boolean, active: Boolean?): ProviderProfile = ProviderProfile(
    id = record.id,
    name = record.name,
    model = record.model.takeIf { it.isNotBlank() },
    endpoint = record.endpoint,
    key = ApiKeyStore.activeFact(record.credentialAccount()),
    selected = selected,
    reasoningEffort = record.reasoningEffort,
    models = record.models.map { model ->
        ProviderModelDraft(
            id = model.id,
            name = model.name,
            contextWindow = model.contextWindow,
            maxTokens = model.maxTokens,
            textInput = model.textInput,
            imageInput = model.imageInput,
            reasoningEffort = model.reasoningEffort,
        )
    },
    credentialRef = record.credentialAccount(),
    active = active,
)

/**
 * The command surface the HELLO says this host advertised.
 *
 * The measurement is `hostCapabilities`: the host builds those strings from the
 * exec bridge it really registered (`HostExec.defaultTools`), so filtering the
 * `accelerator:` prefix yields exactly the executables the engine was told it can
 * run — `phone`, `rg`, `jaq` on a boot whose accelerators mounted. No HELLO (the
 * engine is stopped, or has not handshaken) means no snapshot, and the page keeps
 * its 还没接上命令 body rather than a list that nothing backs.
 *
 * `environment` and `mounts` stay `null`: the caps carry neither, and they are not
 * this host's two accelerator mounts (the page would print 2 个工作文件夹 for two
 * directories). The limits are the bridge's own enforced constants, read from the
 * same `AcceleratorLimits` the Rust side uses, not typed here.
 *
 * @param handshake the merged HELLO, or `null` before the page handshook.
 */
private fun shellSnapshot(handshake: HandshakeSummary?): ShellSnapshot {
    val accelerators = handshake?.hostCapabilities.orEmpty()
        .filter { it.startsWith(ACCELERATOR_CAPABILITY_PREFIX) }
        .map { it.removePrefix(ACCELERATOR_CAPABILITY_PREFIX) }
        .filter { it.isNotEmpty() }
    if (accelerators.isEmpty()) return ShellSnapshot()
    val limits = AcceleratorLimits()
    return ShellSnapshot(
        commands = accelerators,
        limits = ShellLimits(
            timeoutMilliseconds = limits.timeoutMs,
            maxOutputBytes = limits.maxOutputBytes,
            maxFiles = limits.maxFiles.toInt(),
            maxFileBytes = limits.maxFileBytes,
        ),
    )
}

/** The HELLO capability prefix one executable accelerator is advertised under. */
private const val ACCELERATOR_CAPABILITY_PREFIX: String = "accelerator:"
