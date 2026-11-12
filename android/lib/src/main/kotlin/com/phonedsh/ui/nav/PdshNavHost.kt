// The route to page host: one composable that turns a route into its page.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (每页的 入口 / 导航关系), §3.1 (the ScreenState
// layer) and §5 (`back-gesture`: the page stack pops one level per gesture).
//
// The host only ever hands this file two things: [PdshNavFacts] (what it measured,
// `null` for what it could not read) and [PdshNavHost]'s callbacks. Every page here
// is a pure function of (facts, local script), so a route can be replayed on the
// JVM without a device; the local scripts (folds, tabs, drafts, stop confirmation)
// live in this file, never in a page.
//
// Write gestures are handed back as [PdshHostAction]. This Android host implements
// no settings write, no workspace mutation and no MCP save (§1 names no command for
// them), so the page's facts do not change on those gestures and the page never
// shows a success it did not observe. The two actions the host really owns (engine
// stop and engine start) are performed by the composition root.
package com.phonedsh.ui.nav

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.window.Dialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.AutomationLocalState
import com.phonedsh.ui.page.AutomationScreenState
import com.phonedsh.ui.page.AutomationUiEvent
import com.phonedsh.ui.page.ChatPage
import com.phonedsh.ui.page.ChatSubagentEntry
import com.phonedsh.ui.surface.MarkdownImageSource
import com.phonedsh.ui.page.ConfigurationLocalState
import com.phonedsh.ui.page.ConfigurationScreenState
import com.phonedsh.ui.page.ConfigurationUiEvent
import com.phonedsh.ui.page.ConfigurationWriteReceipt
import com.phonedsh.ui.page.ConfigurationWriteRequest
import com.phonedsh.ui.page.EgressAllowListLocalState
import com.phonedsh.ui.page.EgressAllowListPage
import com.phonedsh.ui.page.EgressAllowListScreenState
import com.phonedsh.ui.page.EgressAllowListUiEvent
import com.phonedsh.ui.page.ExportFacts
import com.phonedsh.ui.page.ExportPage
import com.phonedsh.ui.page.ExportScreenState
import com.phonedsh.ui.page.GitHubAgentFacts
import com.phonedsh.ui.page.GitHubAgentSettingsPage
import com.phonedsh.ui.page.FilesLocalState
import com.phonedsh.ui.page.FilesPage
import com.phonedsh.ui.page.FilesScreenState
import com.phonedsh.ui.page.FilesSource
import com.phonedsh.ui.page.FilesUiEvent
import com.phonedsh.ui.page.MCPEditorLocalState
import com.phonedsh.ui.page.MCPEditorPage
import com.phonedsh.ui.page.MCPEditorScreenState
import com.phonedsh.ui.page.MCPEditorUiEvent
import com.phonedsh.ui.page.MCPLocalState
import com.phonedsh.ui.page.MCPScreenState
import com.phonedsh.ui.page.MCPSettingsPage
import com.phonedsh.ui.page.MCPUiEvent
import com.phonedsh.ui.page.ModelProviderLocalState
import com.phonedsh.ui.page.ModelProviderScreenState
import com.phonedsh.ui.page.ModelProviderSettingsPage
import com.phonedsh.ui.page.ModelProviderUiEvent
import com.phonedsh.ui.page.AgentPresetActions
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.NativeAgentPresetsLocalState
import com.phonedsh.ui.page.NativeAgentPresetsPage
import com.phonedsh.ui.page.NativeAgentPresetsScreenState
import com.phonedsh.ui.page.NativeAgentPresetsUiEvent
import com.phonedsh.ui.page.NativeAutomationPage
import com.phonedsh.ui.page.NativeConfigurationPage
import com.phonedsh.ui.page.NativePluginInventoryPage
import com.phonedsh.ui.page.NativeWorkbenchPage
import com.phonedsh.ui.page.PDSHShellPage
import com.phonedsh.ui.page.PCPairingPage
import com.phonedsh.ui.page.PCPairingUiState
import com.phonedsh.ui.page.ConnectedComputerPage
import com.phonedsh.ui.page.ConnectedComputerUiState
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityAction
import com.phonedsh.ui.page.PhoneCapabilityRowState
import com.phonedsh.ui.page.PhonePermissionsLocalState
import com.phonedsh.ui.page.PhonePermissionsPage
import com.phonedsh.ui.page.PhonePermissionsScreenState
import com.phonedsh.ui.page.PhonePermissionsUiEvent
import com.phonedsh.ui.page.PluginInventoryFacts
import com.phonedsh.ui.page.PluginInventoryLocalState
import com.phonedsh.ui.page.PluginInventoryScreenState
import com.phonedsh.ui.page.PluginInventoryUiEvent
import com.phonedsh.ui.page.PermissionDefaultsPage
import com.phonedsh.ui.page.PermissionDefaultsState
import com.phonedsh.ui.page.RuntimeDetailsPage
import com.phonedsh.ui.page.RuntimeDetailsScreenState
import com.phonedsh.ui.page.RuntimeLocalState
import com.phonedsh.ui.page.RuntimeUiEvent
import com.phonedsh.ui.page.SettingsDestination
import com.phonedsh.ui.page.SettingsPreferenceChoice
import com.phonedsh.ui.page.SettingsTab
import com.phonedsh.ui.page.SessionListing
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsPage
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.SessionWorkspace
import com.phonedsh.ui.page.SettingsPage
import com.phonedsh.ui.page.SettingsPageMode
import com.phonedsh.ui.page.ArchivedSessionsPage
import com.phonedsh.ui.page.ArchivedSessionsPageState
import com.phonedsh.ui.page.SessionRunStatus
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.ShellLocalState
import com.phonedsh.ui.page.ShellUiEvent
import com.phonedsh.ui.page.ToolsScreenState
import com.phonedsh.ui.page.WebSearchLocalState
import com.phonedsh.ui.page.WebSearchScreenState
import com.phonedsh.ui.page.WebSearchSettingsPage
import com.phonedsh.ui.page.WebSearchUiEvent
import com.phonedsh.ui.page.WebSurfaceLocalState
import com.phonedsh.ui.page.WebSurfacePage
import com.phonedsh.ui.page.WebSurfaceScreenState
import com.phonedsh.ui.page.WebSurfaceUiEvent
import com.phonedsh.ui.page.WorkspaceFile
import com.phonedsh.ui.page.WorkbenchLocalState
import com.phonedsh.ui.page.WorkbenchScreenState
import com.phonedsh.ui.page.WorkbenchSection
import com.phonedsh.ui.page.WorkbenchUiEvent
import com.phonedsh.ui.page.WorkspaceFoldersLocalState
import com.phonedsh.ui.page.WorkspaceFoldersPage
import com.phonedsh.ui.page.WorkspaceFoldersScreenState
import com.phonedsh.ui.page.WorkspaceFoldersUiEvent
import com.phonedsh.ui.page.apply

// Appended by the L13 lane: the three pages it mirrored (chat appearance, the
// redacted settings document, the shortcut reference). Grouped rather than
// alphabetised so this lane's edge is one block another lane can move.
import com.phonedsh.ui.page.ChatPreferencesFacts
import com.phonedsh.ui.page.ChatPreferencesPage
import com.phonedsh.ui.page.ChatPreferencesScreenState
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.NativeSettingsDocumentPage
import com.phonedsh.ui.page.NativeShortcutsFacts
import com.phonedsh.ui.page.NativeShortcutsPage
import com.phonedsh.ui.page.NativeShortcutsScreenState
import com.phonedsh.ui.page.SettingsDocumentFacts
import com.phonedsh.ui.page.SettingsDocumentScreenState
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// Appended by the L24 lane: the chat family's three 内嵌子页 (`ChatPage.swift:3504`,
// `:3554`, `:4243`). Grouped so this lane's edge is one block another lane can move
// without a merge conflict.
import com.phonedsh.ui.page.ChatCommandResultState
import com.phonedsh.ui.page.ChatJobsSheetState
import com.phonedsh.ui.page.ChatSchedulesSheetState
import com.phonedsh.ui.page.ChatSubpageFacts
import com.phonedsh.ui.surface.composer.ComposerAvailability
import com.phonedsh.ui.page.CommandExecutionResultPage
import com.phonedsh.ui.page.NativeJobListSheet
import com.phonedsh.ui.page.NativeScheduleListSheet

// Appended by the L5 lane: the device-connector routes read the `:domain` connector
// seam (its state machine, its read-only session transport and its paging window) and
// the three pages below it. They are grouped rather than alphabetised so this lane's
// edge stays one block another lane can move without a merge conflict.
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberCoroutineScope
import com.phonedsh.domain.connector.DeviceConnectionSource
import com.phonedsh.domain.connector.DeviceConnectionSnapshot
import com.phonedsh.domain.connector.DeviceSessionFailure
import com.phonedsh.domain.connector.DeviceSessionSource
import com.phonedsh.domain.connector.DeviceSessionSnapshot
import com.phonedsh.domain.connector.DeviceSessionStatus
import com.phonedsh.domain.connector.ConnectorStatus
import com.phonedsh.domain.connector.InMemoryDeviceSessionTransport
import com.phonedsh.ui.page.DeviceConnectionLocalState
import com.phonedsh.ui.page.DeviceConnectionScreenState
import com.phonedsh.ui.page.DeviceSessionLocalState
import com.phonedsh.ui.page.DeviceSessionScreenState
import com.phonedsh.ui.page.NativeDeviceConnectionPage
import com.phonedsh.ui.page.NativeDeviceSessionPage
import com.phonedsh.ui.page.SessionArtifactRef
import com.phonedsh.ui.page.SessionArtifactsFacts
import com.phonedsh.ui.page.SessionArtifactsLocalState
import com.phonedsh.ui.page.SessionArtifactsPage
import com.phonedsh.ui.page.SessionArtifactsScreenState
import com.phonedsh.ui.page.WorkspaceSessionArtifactSource
import kotlinx.coroutines.launch

// Appended by the L25 lane: the two embedded subpages it implemented
// (`ScheduleEditorPage` and `SessionArtifactPreviewPage`, README §1
// 「内嵌子页随父页实现」). Grouped rather than alphabetised so this lane's edge
// stays one block another lane can move without a merge conflict.
import com.phonedsh.ui.page.AutomationScheduleDraft
import com.phonedsh.ui.page.SessionArtifactPreview
import java.time.ZoneId
import java.util.UUID

// Appended by the L29 lane: the one preview face (`PdshRoute.Preview`). The surface
// lives in its own package so it can carry the resolver, the pager and the file
// source together; the route is the only thing the router has to know about it.
import android.net.Uri
import androidx.compose.ui.platform.LocalContext
import com.phonedsh.ui.surface.preview.PreviewPage
import com.phonedsh.ui.surface.preview.PreviewShare
import com.phonedsh.ui.surface.preview.PreviewWorkspace
import com.phonedsh.ui.surface.preview.rememberPreviewSource
import java.io.File
import kotlinx.coroutines.launch

// Appended by the L44 lane: the one level of back that lives *inside* a route.
// The system back gesture reaches the host, not the page, so a route that shows an
// inner level (a sheet's child page, a folder drill-down, an embedded preview) has
// nowhere to register it. These two declarations are that place; they are the only
// state the back chain needs beyond the stack itself.
import androidx.compose.runtime.Stable
import androidx.compose.runtime.rememberUpdatedState

// Added by the P09 sheet-host lane: the host-wide sheet back seam and the route
// surface that presents the baseline's `.sheet` routes through the shared sheet
// component (`interaction.md` §2 rules 1-9, §4 rules 5 and 7). Grouped so another
// lane can move this block without touching the lanes above.
import com.phonedsh.ui.sheet.LocalSheetBackHost
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.sheet.SheetChrome
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * One level of back that lives inside the top route.
 *
 * `spec/ui/v1/README.md` §5 `back-gesture` says one gesture pops one level; for the
 * routes that render a child page of their own, "one level" is not the route stack
 * but this. The host owns the single system-back callback, so it holds one of these
 * and asks it before popping:
 *
 * ```
 * drawer open? -> close it
 * [PdshBackLevel.available]? -> consume()
 * else -> pop the route stack
 * ```
 *
 * The rendered route is the only writer, and only while it really shows an inner
 * level ([enabled] in [RouteBackLevel]), so a pushed route never hides the level of
 * the route below it.
 */
@Stable
public class PdshBackLevel {
    private var entry: (() -> Unit)? by mutableStateOf(null)

    /** Whether the rendered route has an inner level to leave. */
    public val available: Boolean get() = entry != null

    /**
     * Leaves one inner level.
     *
     * @return `true` when a level was left, `false` when there was none and the
     *   caller should pop the route stack instead.
     */
    public fun consume(): Boolean {
        val action = entry ?: return false
        action()
        return true
    }

    internal fun register(action: () -> Unit) {
        entry = action
    }

    /**
     * Removes [action] only while it is still the registered one.
     *
     * The identity check matters for the one nesting this router has: the settings
     * sheet's 手机权限 tab renders the permissions page inside the settings route. A
     * blindly-clearing dispose would drop the outer route's level when a page that
     * never registered one left the composition.
     */
    internal fun unregister(action: () -> Unit) {
        if (entry === action) entry = null
    }
}

/**
 * Registers [onBack] as the top route's inner level while [enabled] holds.
 *
 * The registration lives exactly as long as this route is the rendered one: the
 * effect is disposed when the composable leaves the composition (another route
 * replaced it) or when [enabled] turns false (the level closed).
 *
 * @param level the host's chain, or `null` when the host keeps none.
 * @param enabled whether this route currently shows an inner level.
 * @param onBack leaves that level.
 */
@Composable
internal fun RouteBackLevel(
    backLevel: PdshBackLevel?,
    enabled: Boolean,
    onBack: () -> Unit,
) {
    val current by rememberUpdatedState(onBack)
    DisposableEffect(backLevel, enabled) {
        if (backLevel == null || !enabled) {
            return@DisposableEffect onDispose {}
        }
        val action: () -> Unit = { current() }
        backLevel.register(action)
        onDispose { backLevel.unregister(action) }
    }
}

/**
 * Renders the top route of [nav].
 *
 * @param nav the page stack; only [PdshNavState.current] is rendered.
 * @param facts every page's read-only input.
 * @param onNavigate push a route (the drawer and the in-page links call this).
 * @param onBack pop one route.
 * @param onHome drop the stack back to the native home (the Web surface's
 *   原生恢复 path).
 * @param onHostAction a gesture this host cannot complete itself.
 * @param onSettingsWrite a settings write this host cannot persist; the mirrored
 *   index's switch, menu and permission preset hand it back here. The default is
 *   a no-op so a host that has no settings write keeps compiling honestly.
 * @param home the native face ([PdshRoute.Home]).
 * @param webSurface the host-owned WebView container handed to the Web surface.
 * @param sessions the host's real session list, or `null` for this router's
 *   facts-only empty list. The drawer's 会话 row is a route push now, and the
 *   host that owns the session read (the probe app's `HostSessionsScreen`) is
 *   the only place that data lives; passing it here keeps [PdshRoute.Sessions]
 *   the one address of the list instead of a second, emptier page.
 * @param chatSubpages the chat family's three 内嵌子页 input (`ChatSubpageFacts`):
 *   one command settlement, the session's jobs and its schedules. The default
 *   reports no read, so [PdshRoute.CommandResult], [PdshRoute.SessionJobs] and
 *   [PdshRoute.SessionSchedules] render their 读取不到 body instead of an empty
 *   list — "not read" and "read, and it is empty" are different facts.
 * @param workspaceRoot the materialized workspace the files page lists and the
 *   preview resolves against (`<workspace>/materialized/workspace`), or `null` for
 *   the library's default device root — this app's `filesDir/xl/materialized/
 *   workspace`, the tree `:app`'s composition root already builds the WAL stores
 *   over. A host that measures its own root passes it here; a host with no
 *   workspace passes a path that does not exist and the pages say "not reported"
 *   instead of inventing one.
 * @param artifacts the host's measured write fact for the 本 session 产物 page: the
 *   workspace-relative paths this session's own turns wrote. It is the *only*
 *   attribution the workspace listing gets — the default (`null` paths) claims
 *   nothing, so an unmeasured host lists every workspace file as 未归属 rather than
 *   fabricating a provenance. The host that owns the turn lane fills it from its
 *   per-turn workspace diff (see `:app`'s `HostSessionArtifacts`); a host with no
 *   chat lane leaves it alone.
 * @param backLevel the host's one inner-level back chain (see [PdshBackLevel]), or
 *   `null` when the host keeps none. A route whose "one step back" is inside the
 *   page (the settings sheet's 新会话默认权限 child, the files list's folder
 *   drill-down, the artifacts preview, the schedule editor) registers there, so the
 *   system gesture leaves that level instead of closing the whole route. The
 *   default is `null` because a host that renders these pages without a back
 *   gesture is still a valid host.
 * @param sheetBackHost the host's one shared [SheetBackHost], i.e. the sheet layer
 *   of `interaction.md` §4 rule 5. It is provided through [LocalSheetBackHost] so
 *   every page-owned [PdshSheet] inside this host registers on the same chain as
 *   the routes presented as sheets below; one back then closes the top sheet
 *   before the route stack moves (§2 rule 9). The default `null` leaves the local
 *   empty, so a page previewed without a host keeps a sheet-local chain and system
 *   back still closes it.
 * @param onPreferenceWrite a preference picker or stepper reported a choice. The
 *   host owns the store; this router only names the row and the option, exactly
 *   as the phone-permission gestures are handed back. Empty by default, so a host
 *   without a preference store keeps rendering the pages read-only.
 * @param onToggleDeveloperTools 显示代码工作视图 was flipped.
 * @param preferencesWritable whether this host accepts a preference write. It is
 *   separate from `ConfigurationSnapshot.settingsWritable` on purpose: that field
 *   is the session/plugin configuration page's capability, and a host can own a
 *   preference store without owning a session-config write. `UNKNOWN` keeps the
 *   chat-appearance page read-only, which is the honest default.
 */
@Composable
public fun PdshNavHost(
    nav: PdshNavState,
    facts: PdshNavFacts,
    onNavigate: (PdshRoute) -> Unit,
    onBack: () -> Unit,
    onHome: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    home: @Composable () -> Unit,
    webSurface: @Composable () -> Unit,
    sessions: (@Composable () -> Unit)? = null,
    onSettingsWrite: (SettingsWrite) -> Unit = {},
    onPreferenceWrite: (SettingsPreferenceChoice) -> Unit = {},
    onSelectFontFamily: ((rowId: String, family: String) -> Unit)? = null,
    onToggleDeveloperTools: (Boolean) -> Unit = {},
    preferencesWritable: FactState = FactState.UNKNOWN,
    chatSubpages: ChatSubpageFacts = ChatSubpageFacts(),
    workspaceRoot: File? = null,
    // L81: the 本 session 产物 attribution fact. Default `null` paths = this host
    // measured no turn, so the page claims nothing (every workspace file is 未归属).
    artifacts: SessionArtifactsFacts = SessionArtifactsFacts(),
    backLevel: PdshBackLevel? = null,
    /** The host's shared sheet back layer; see the KDoc above. */
    sheetBackHost: SheetBackHost? = null,
    // The phone-permissions page is the one page whose 请求 is not a write this file
    // can perform: a system permission prompt belongs to the Activity, so the gesture
    // is handed back with the row it was made on. Empty by default, so a host that
    // cannot prompt still renders the page — as a read-only surface.
    onPhonePermissionRequest: (PhoneCapability) -> Unit = {},
    onPhonePermissionSettings: (PhoneCapability) -> Unit = {},
    /** Open the host-owned home drawer over the current conversation. */
    onOpenDrawer: (() -> Unit)? = null,
    // L69: the chat page's host half. `chat` is the fully folded screen state the
    // composition root built from the Worker's events (`ChatScreenState.from`), so
    // this file stays a route table and never learns the event vocabulary. `null`
    // keeps the library's honest empty conversation for a host that has no chat.
    chat: ChatScreenState? = null,
    chatTitle: String? = null,
    timelineRetryAvailability: PdshActionAvailability<() -> Unit> =
        PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    permissionApproveAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> =
        PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    permissionDenyAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> =
        PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
    onChatDraftChange: (String) -> Unit = {},
    onChatSend: () -> Unit = {},
    onChatStop: () -> Unit = {},
    onChatRename: (String) -> Unit = {},
    onChatAddFiles: () -> Unit = {},
    onChatAddImages: () -> Unit = {},
    onChatRemoveAttachment: (Int) -> Unit = {},
    onChatDismissNotice: () -> Unit = {},
    chatActions: ChatInteractionActions = ChatInteractionActions(),
    /** A host-supplied connector; `null` renders the honest no-connector state. */
    deviceConnectionSource: DeviceConnectionSource? = null,
    /** Host-supplied fixed session monitors keyed by device id; no demo is implicit. */
    deviceSessionSources: Map<String, DeviceSessionSource> = emptyMap(),
    /** Activity-owned SAF picker for the workspace listing. */
    onFilesImportRequest: ((String) -> Unit)? = null,
    /** Request result from that picker; null means no result was reported. */
    filesImportReceipt: Pair<String, com.phonedsh.ui.page.FilesImportReceipt>? = null,
    /** Device-owned native TTS callback, unavailable when no engine is ready. */
    onSpeakText: ((String) -> Unit)? = null,
    /** Opens one subagent only when its Worker identity and history were verified. */
    onOpenSubagentSession: (suspend (ChatSubagentEntry) -> String?)? = null,
    /** Loads an older page of the open subagent's durable Worker transcript. */
    onLoadEarlierChatTranscript: (() -> Unit)? = null,
    /** Confirmed DSH configuration read/write path; absent hosts keep actions unavailable. */
    onConfigurationWrite: (suspend (ConfigurationWriteRequest) -> ConfigurationWriteReceipt)? = null,
    /** The host's `agentPresets/list` reading; the default reports no roster. */
    agentPresets: NativeAgentPresetsFacts = NativeAgentPresetsFacts(),
    /** The host's preset read/use handoffs; the default leaves them unavailable. */
    agentPresetActions: AgentPresetActions = AgentPresetActions(),
    /**
     * 连接电脑's host snapshot. The default is the honest idle page, so a host
     * without a PCLink seam still renders the contract's install/scan/other body.
     */
    pcPairingState: PCPairingUiState = PCPairingUiState(),
    /** 已连接的电脑's host snapshot; the default is its 还没有连接电脑 empty state. */
    pcConnectedState: ConnectedComputerUiState = ConnectedComputerUiState(),
    /** 已连接的电脑's trailing value (`未配对` / `离线` / the verified name). */
    connectedComputerValue: String? = null,
    /** The host's camera preview for the pairing page's scanner sheet. */
    pcScannerContent: (@Composable () -> Unit)? = null,
    onPcScan: () -> Unit = {},
    onPcToggleOtherWays: () -> Unit = {},
    onPcPairingLinkChange: (String) -> Unit = {},
    onPcPairWithLink: () -> Unit = {},
    onPcPairingCodeChange: (String) -> Unit = {},
    onPcPairManually: () -> Unit = {},
    /** `null` falls back to [onBack], the pre-glue behaviour. */
    onPcCancelPairing: (() -> Unit)? = null,
    onPcRetry: () -> Unit = {},
    /** `null` falls back to [onBack], the pre-glue behaviour. */
    onPcDone: (() -> Unit)? = null,
    /** `null` falls back to [onBack], the pre-glue behaviour. */
    onPcClose: (() -> Unit)? = null,
    onPcCancelScanner: () -> Unit = {},
    onPcUnpair: () -> Unit = {},
    onPcDismissUnpairFailure: () -> Unit = {},
    onPcConnectionScreenOpened: () -> Unit = {},
    /** 设置 › GitHub Agent's facts; default is no token and writes off. */
    githubAgent: GitHubAgentFacts = GitHubAgentFacts(),
    /** Saves the typed token; true only when the host stored it. */
    onGitHubAgentSaveToken: (String) -> Boolean = { false },
    /** Deletes the stored token; true only when the host removed it. */
    onGitHubAgentDeleteToken: () -> Boolean = { false },
    /** Persists the explicit write opt-in. */
    onGitHubAgentAllowWrites: (Boolean) -> Unit = {},
) {
    val route = nav.current
    if (route == PdshRoute.Home) {
        CompositionLocalProvider(LocalSheetBackHost provides sheetBackHost) {
            home()
        }
        return
    }
    RouteSurface(
        presentation = route.presentation,
        sheetPageId = sheetPageIdOf(route),
        onDismissRequest = onBack,
        sheetBackHost = sheetBackHost,
    ) {
        when (route) {
            PdshRoute.Home -> Unit // rendered above; kept for the exhaustive when
            PdshRoute.Sessions ->
                if (sessions != null) sessions() else SessionsRoute(facts, onBack)
            PdshRoute.Chat -> ChatRoute(
                workspaceRoot = workspaceRoot,
                actionAvailability = facts.actionAvailability,
                subpages = chatSubpages,
                onNavigate = onNavigate,
                onOpenDrawer = onOpenDrawer,
                onSpeakText = onSpeakText,
                state = chat,
                title = chatTitle,
                onOpenSubagentSession = onOpenSubagentSession,
                onLoadEarlierTranscript = onLoadEarlierChatTranscript,
                collapseTiming = facts.settings.preferences.collapseTiming,
                onSetCollapseTiming = if (preferencesWritable == FactState.YES) { option ->
                    onPreferenceWrite(SettingsPreferenceChoice(SettingsScreenState.COLLAPSE_TIMING_ROW_ID, option.id))
                } else null,
                timelineRetryAvailability = timelineRetryAvailability,
                permissionApproveAvailability = permissionApproveAvailability,
                permissionDenyAvailability = permissionDenyAvailability,
                onDraftChange = onChatDraftChange,
                onSend = onChatSend,
                onStop = onChatStop,
                onRename = onChatRename,
                onAddFiles = onChatAddFiles,
                onAddImages = onChatAddImages,
                onRemoveAttachment = onChatRemoveAttachment,
                onDismissNotice = onChatDismissNotice,
                actions = chatActions,
            )
            PdshRoute.WorkspaceFolders -> WorkspaceFoldersRoute(facts, onBack, onHostAction, onNavigate)
            is PdshRoute.Files -> FilesRoute(
                onBack, onNavigate, workspaceRoot, backLevel, onFilesImportRequest, filesImportReceipt,
            )
            is PdshRoute.Preview -> PreviewRoute(route, onBack, workspaceRoot)
            PdshRoute.Automation -> AutomationRoute(facts, onBack, onHostAction, backLevel)
            PdshRoute.Configuration -> ConfigurationRoute(
                facts, onBack, onNavigate, onHostAction, onConfigurationWrite,
            )
            PdshRoute.Settings, PdshRoute.MeTab, PdshRoute.SettingsMore -> SettingsRoute(
                mode = when (route) {
                    PdshRoute.MeTab -> SettingsPageMode.TAB
                    PdshRoute.SettingsMore -> SettingsPageMode.MORE
                    else -> SettingsPageMode.SHEET
                },
                facts = facts,
                onBack = onBack,
                onNavigate = onNavigate,
                onHostAction = onHostAction,
                onSettingsWrite = onSettingsWrite,
                onPreferenceWrite = onPreferenceWrite,
                onSelectFontFamily = onSelectFontFamily,
                onToggleDeveloperTools = onToggleDeveloperTools,
                backLevel = backLevel,
                onPhonePermissionRequest = onPhonePermissionRequest,
                onPhonePermissionSettings = onPhonePermissionSettings,
                agentPresets = agentPresets,
                agentPresetActions = agentPresetActions,
                connectedComputerValue = connectedComputerValue,
            )
            PdshRoute.Discover -> com.phonedsh.ui.page.ConnectorsPage(
                onOpen = { connector ->
                    when (connector) {
                        com.phonedsh.ui.page.DiscoverConnector.DEVICES -> onNavigate(PdshRoute.Bluetooth)
                        com.phonedsh.ui.page.DiscoverConnector.WEB_SEARCH -> onNavigate(PdshRoute.WebSearch)
                        com.phonedsh.ui.page.DiscoverConnector.MCP -> onNavigate(PdshRoute.Mcp)
                        // The example connector's sheet action is a disabled 即将支持.
                        com.phonedsh.ui.page.DiscoverConnector.GMAIL -> Unit
                    }
                },
                onOpenPluginsTools = { onNavigate(PdshRoute.Configuration) },
                languageId = facts.settings.preferences.language?.id,
            )
            PdshRoute.ModelProvider -> ModelProviderRoute(facts, onBack, onHostAction, backLevel = backLevel)
            PdshRoute.WebSearch -> WebSearchRoute(facts, onBack, onHostAction)
            PdshRoute.Mcp -> McpRoute(facts, onBack, onHostAction, onNavigate)
            PdshRoute.Ssh -> com.phonedsh.ui.page.SSHSettingsPage(
                facts = facts.ssh,
                onBack = onBack,
                onOpenEditor = { id -> onNavigate(PdshRoute.SshEditor(id)) },
            )
            is PdshRoute.SshEditor -> SshEditorRoute(route, facts, onBack, onHostAction)
            PdshRoute.GitHubAgent -> GitHubAgentSettingsPage(
                facts = githubAgent,
                onBack = onBack,
                onSaveToken = onGitHubAgentSaveToken,
                onDeleteToken = onGitHubAgentDeleteToken,
                onAllowWritesChange = onGitHubAgentAllowWrites,
                onRestartEngine = { onHostAction(PdshHostAction.RestartRuntime) },
            )
            PdshRoute.Bluetooth -> BluetoothRoute(facts, onBack, onHostAction)
            PdshRoute.AndroidAdb -> com.phonedsh.ui.page.AndroidADBSettingsPage(
                facts = facts.androidAdb,
                onBack = onBack,
                onSave = { onHostAction(PdshHostAction.AndroidAdbSave(it)) },
                onCheck = { onHostAction(PdshHostAction.AndroidAdbCheck(it)) },
                onCancel = { onHostAction(PdshHostAction.AndroidAdbCancel) },
            )
            PdshRoute.TonoAccount -> com.phonedsh.ui.page.TonoAccountPage(
                facts = facts.tonoAccount,
                onBack = onBack,
                onRequestCode = { onHostAction(PdshHostAction.TonoAccountRequestCode(it)) },
                onSignIn = { onHostAction(PdshHostAction.TonoAccountSignIn(it)) },
                onSignOut = { onHostAction(PdshHostAction.TonoAccountSignOut) },
            )
            is PdshRoute.McpEditor -> McpEditorRoute(route, facts, onBack, onHostAction)
            PdshRoute.Runtime -> RuntimeRoute(facts, onBack, onHostAction, backLevel)
            PdshRoute.Egress -> EgressRoute(facts, onBack)
            PdshRoute.Tools -> ToolsRoute(facts, onBack)
            PdshRoute.Export -> ExportRoute(onBack)
            is PdshRoute.Workbench ->
                WorkbenchRoute(route, facts, onBack, onHostAction, onNavigate, backLevel)
            PdshRoute.WebSurface -> WebSurfaceRoute(facts, onNavigate, onHome, onHostAction, webSurface)
            PdshRoute.DeviceConnection -> DeviceConnectionRoute(deviceConnectionSource, onNavigate, onBack)
            is PdshRoute.DeviceSession -> DeviceSessionRoute(
                route.deviceId,
                deviceSessionSources[route.deviceId],
                onBack,
            )
            is PdshRoute.SessionArtifacts ->
                SessionArtifactsRoute(route.sessionId, artifacts, workspaceRoot, onBack, backLevel)
            PdshRoute.AgentPresets -> AgentPresetsRoute(
                onBack = onBack,
                facts = agentPresets,
                actions = agentPresetActions,
                actionAvailability = facts.actionAvailability,
            )
            PdshRoute.PluginInventory -> PluginInventoryRoute(
                facts = facts,
                onBack = onBack,
                onNavigate = onNavigate,
                onRefresh = { onHostAction(PdshHostAction.RefreshConfiguration) },
            )
            PdshRoute.PhonePermissions -> PhonePermissionsRoute(
                facts = facts,
                onBack = onBack,
                onRequestPermission = onPhonePermissionRequest,
                onOpenPermissionSettings = onPhonePermissionSettings,
                backLevel = backLevel,
            )
            PdshRoute.ChatPreferences ->
                ChatPreferencesRoute(facts, onBack, preferencesWritable, onPreferenceWrite)
            PdshRoute.SettingsDocument -> SettingsDocumentRoute(onBack)
            PdshRoute.Shortcuts -> ShortcutsRoute(onBack)
            PdshRoute.CommandResult -> CommandResultRoute(chatSubpages, onBack)
            PdshRoute.SessionJobs -> SessionJobsRoute(chatSubpages, onBack, onHostAction)
            PdshRoute.SessionSchedules -> SessionSchedulesRoute(chatSubpages, onBack, onHostAction)
            // C5 PCLink: the host half supplies the flow/record snapshot (the
            // defaults keep this router's standalone preview honest).
            PdshRoute.PcPairing -> PCPairingPage(
                state = pcPairingState,
                onScan = onPcScan,
                onToggleOtherWays = onPcToggleOtherWays,
                onPairingLinkChange = onPcPairingLinkChange,
                onPairWithLink = onPcPairWithLink,
                onPairingCodeChange = onPcPairingCodeChange,
                onPairManually = onPcPairManually,
                onCancelPairing = onPcCancelPairing ?: onBack,
                onRetry = onPcRetry,
                onDone = onPcDone ?: onBack,
                onClose = onPcClose ?: onBack,
                onCancelScanner = onPcCancelScanner,
                scannerContent = pcScannerContent,
            )
            PdshRoute.ConnectedComputer -> ConnectedComputerPage(
                state = pcConnectedState,
                onBack = onBack,
                onOpenPairing = { onNavigate(PdshRoute.PcPairing) },
                onUnpair = onPcUnpair,
                onDismissUnpairFailure = onPcDismissUnpairFailure,
                onConnectionScreenOpened = onPcConnectionScreenOpened,
            )
        }
    }
}

/**
 * The frozen `interaction.sheet.pageDetents` id for a route iOS presents as a
 * modal sheet, or `null` for a route that is not one.
 *
 * The four ids the contract names explicitly (`chatJobs`, `chatSchedules`,
 * `chatArtifacts`, `workbench`) are read from `tokens.json` by `PdshSheet`; the
 * remaining `homeSheetChrome()` sites in the baseline write no
 * `.presentationDetents`, which rule 2 maps to the contract's `default` set. That
 * default is named here by its *generated* id
 * ([UiTokenData.sheet.defaultDetents]), never by a guessed detent, and the
 * contract change request asks the owner to enumerate those sites as page ids.
 *
 * The routes that are `SHEET`-presented but have no iOS `.sheet` call site
 * ([PdshRoute.AgentPresets], [PdshRoute.PhonePermissions], [PdshRoute.ChatPreferences],
 * [PdshRoute.SettingsDocument]) deliberately return `null`: they keep the older
 * page frame until the contract says which sheet they are.
 */
internal fun sheetPageIdOf(route: PdshRoute): String? = when (route) {
    PdshRoute.Automation -> DEFAULT_SHEET_PAGE_ID
    PdshRoute.Configuration -> DEFAULT_SHEET_PAGE_ID
    PdshRoute.Settings -> DEFAULT_SHEET_PAGE_ID
    PdshRoute.ModelProvider -> DEFAULT_SHEET_PAGE_ID
    PdshRoute.Runtime -> DEFAULT_SHEET_PAGE_ID
    is PdshRoute.Workbench -> "workbench"
    PdshRoute.DeviceConnection -> DEFAULT_SHEET_PAGE_ID
    is PdshRoute.SessionArtifacts -> "chatArtifacts"
    PdshRoute.CommandResult -> DEFAULT_SHEET_PAGE_ID
    PdshRoute.SessionJobs -> "chatJobs"
    PdshRoute.SessionSchedules -> "chatSchedules"
    else -> null
}

/**
 * The contract's id for "no explicit `.presentationDetents`": the generated
 * `defaultDetents` value (rule 2), never a hand-written set.
 */
private val DEFAULT_SHEET_PAGE_ID: String = UiTokenData.sheet.defaultDetents.spec

/**
 * The frame around a non-home route.
 *
 * When [sheetPageId] is non-null the route is one of the baseline's modal sheets
 * (`interaction.md` §2): it renders through [PdshSheet], so the platform sheet
 * owns the detents, scrim, drag and present/dismiss motion, and a dismissed sheet
 * pops its route. The chrome is [SheetChrome.HomeSheet] for every such site
 * because the baseline wraps all of them in `homeSheetChrome()`; page content must
 * not draw a second grabber (round 1 removed those).
 *
 * The remaining PUSH and FULLSCREEN pages cover the screen. A [PdshPresentation.SHEET]
 * route with no contract page id (see [sheetPageIdOf]) keeps the older frame: it
 * reuses `geometry.cardOuterMarginV` for the strip and `radius.card` for the top
 * edge, both marked unverified at this call site, until the contract names its
 * page id.
 *
 * @param presentation the route's contract presentation form.
 * @param sheetPageId the frozen sheet page id, or `null` for the page frame.
 * @param onDismissRequest closes the route after the platform sheet hides.
 * @param sheetBackHost the host's shared chain, provided to this route's content
 *   and to the sheet itself through [LocalSheetBackHost].
 */
@Composable
private fun RouteSurface(
    presentation: PdshPresentation,
    sheetPageId: String?,
    onDismissRequest: () -> Unit,
    sheetBackHost: SheetBackHost?,
    content: @Composable () -> Unit,
) {
    // §2 rule 9 / §4 rule 5: one sheet chain for the whole host, so a page-owned
    // sheet and a sheet-presented route are the same `sheet` layer. The provider
    // stays here (not at the sheet call) because a FULLSCREEN route's content
    // mounts its own sheets too — the chat page's subagent catalogue is one.
    CompositionLocalProvider(LocalSheetBackHost provides sheetBackHost) {
        if (sheetPageId != null) {
            // §2 rule 1: no path is disabled (scrim, drag and back all keep their
            // platform implementations); rule 9: the sheet's dismissal is one
            // route pop, asked for only after the hide animation `PdshSheet`
            // reports. `backHost` is left to [LocalSheetBackHost], i.e. the very
            // chain this provider installs.
            PdshSheet(
                pageId = sheetPageId,
                chrome = SheetChrome.HomeSheet,
                onDismissRequest = onDismissRequest,
            ) {
                content()
            }
        } else {
            RoutePageFrame(presentation, content)
        }
    }
}

/**
 * The page frame for a route the contract does not name as a sheet.
 *
 * A [PdshPresentation.SHEET] route here is one whose page id the contract does not
 * publish (see [sheetPageIdOf]); it keeps the modal look the older frame gave it
 * (`geometry.cardOuterMarginV` strip, `radius.card` top edge, both unverified at
 * this call site) instead of inventing detents.
 */
@Composable
private fun RoutePageFrame(presentation: PdshPresentation, content: @Composable () -> Unit) {
    val tokens = LocalUiTokens.current
    val sheet = presentation == PdshPresentation.SHEET
    Box(modifier = Modifier.fillMaxSize().background(tokens.colors.selector)) {
        if (sheet) {
            // unverified token: no scrim colour token exists; the page ink at a
            // fixed opacity is the only non-invented dimming the token table has.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(tokens.colors.primary.copy(alpha = SHEET_SCRIM_ALPHA)),
            )
        }
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (sheet) {
                        // unverified geometry: no sheet token; the page margin is the
                        // smallest published inset that keeps the page visible behind.
                        Modifier.padding(top = tokens.geometry.cardOuterMarginV)
                    } else {
                        Modifier
                    },
                )
                .then(
                    if (sheet) {
                        Modifier.clip(
                            RoundedCornerShape(
                                topStart = tokens.radius.card,
                                topEnd = tokens.radius.card,
                            ),
                        )
                    } else {
                        Modifier
                    },
                )
                .background(tokens.colors.selector),
        ) {
            content()
        }
    }
}

// ---------------------------------------------------------------------- pages

/**
 * 对话: §1's root native face.
 *
 * The page is a pure function of the folded screen state, so this route takes the
 * state **already built by the composition root** and forwards the page's
 * gestures. Before L69 the caller had nothing to hand it: `ChatScreenState.from`
 * was called here with an empty node sequence, the dock's `onSend`/`onStop` were
 * literal no-ops, and the composer could not even be enabled (an empty projection
 * is `ChatPhase.WAITING` → `ComposerLock.WAITING_ENGINE`). The five `onChat*`
 * callbacks below are the host's own commands (send, stop, rename, the two file
 * pickers, remove, dismiss); this file only forwards them.
 *
 * @param onNavigate push the sessions list: the page head's leading control is
 *   the baseline's session-drawer control (`ChatPage.swift`), and this host's
 *   drawer body is the sessions page, so the control opens that route.
 * @param state the host's folded chat state, or `null` for a host that has none.
 * @param title the conversation's name; empty falls back to 新会话 in the page.
 * @param onOpenFile a row's file chip: the host routes it to its preview.
 */
@Composable
private fun ChatRoute(
    workspaceRoot: File?,
    actionAvailability: PdshActionAvailabilities,
    subpages: ChatSubpageFacts,
    onNavigate: (PdshRoute) -> Unit,
    onOpenDrawer: (() -> Unit)?,
    onSpeakText: ((String) -> Unit)?,
    state: ChatScreenState?,
    title: String?,
    onOpenSubagentSession: (suspend (ChatSubagentEntry) -> String?)?,
    onLoadEarlierTranscript: (() -> Unit)?,
    collapseTiming: com.phonedsh.ui.page.CollapseTiming?,
    onSetCollapseTiming: ((com.phonedsh.ui.page.CollapseTiming) -> Unit)?,
    timelineRetryAvailability: PdshActionAvailability<() -> Unit>,
    permissionApproveAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    permissionDenyAvailability: PdshActionAvailability<(PendingAnswer) -> Unit>,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onRename: (String) -> Unit,
    onAddFiles: () -> Unit,
    onAddImages: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onDismissNotice: () -> Unit,
    actions: ChatInteractionActions,
) {
    fun available(action: PdshActionKey): Boolean =
        actionAvailability.forAction(action) is PdshActionAvailability.Available
    val sessionId = state?.sessionID?.takeIf(String::isNotBlank)
    // Markdown dsh-resource identities name the backend Worker session. The local
    // ChatScreenState session id is a different namespace; only ChatSurface's
    // explicit workerSessionID (including its persisted legacy alias) may match.
    val workerSessionId = state?.workerSessionID?.takeIf(String::isNotBlank)
    val latestLocalSessionId = rememberUpdatedState(sessionId)
    val latestWorkerSessionId = rememberUpdatedState(workerSessionId)
    val latestWorkspaceRoot = rememberUpdatedState(workspaceRoot)
    val previewSource = rememberPreviewSource(workspaceRoot)
    val imageSource = remember(workspaceRoot, workerSessionId, previewSource) {
        MarkdownImageSource(
            workspaceFiles = previewSource,
            sessionFilesById = if (workspaceRoot != null && workerSessionId != null) {
                mapOf(workerSessionId to previewSource)
            } else {
                emptyMap()
            },
        )
    }
    val scope = rememberCoroutineScope()
    var unavailableResource by remember { mutableStateOf<MarkdownResourcePreviewTarget.Refused?>(null) }
    val latestAssistantReply = state?.rows?.asReversed()?.firstNotNullOfOrNull { row ->
        (row as? com.phonedsh.ui.state.ChatRow.Assistant)
            ?.takeIf { !it.streaming && it.text.isNotBlank() }
            ?.text
    }
    val speakRecentReply: (() -> Unit)? = when (
        val capability = actionAvailability.forAction(PdshActionKey.SPEAK_RECENT_REPLY)
    ) {
        is PdshActionAvailability.Unavailable -> null
        is PdshActionAvailability.Available -> if (sessionId == null || latestAssistantReply == null || onSpeakText == null) {
            null
        } else {
            {
                capability.callback(
                    PdshUiHostCommand.SpeakRecentReply(
                        sessionId,
                        StateRequestId(UUID.randomUUID().toString()),
                        latestAssistantReply,
                    ),
                )
            }
        }
    }
    val exportTranscript: (() -> Unit)? =
        when (val export = actionAvailability.forAction(PdshActionKey.EXPORT_TRANSCRIPT)) {
            is PdshActionAvailability.Unavailable -> null
            is PdshActionAvailability.Available -> if (sessionId == null) {
                null
            } else {
                {
                    export.callback(
                        PdshUiHostCommand.ExportTranscript(
                            sessionId,
                            StateRequestId(UUID.randomUUID().toString()),
                        ),
                    )
                }
            }
        }
    val retryFromTable: PdshActionAvailability<() -> Unit> = when (val retry = actionAvailability.forAction(PdshActionKey.RETRY)) {
        is PdshActionAvailability.Unavailable -> retry
        is PdshActionAvailability.Available -> if (sessionId == null) {
            PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
        } else PdshActionAvailability.Available {
            retry.callback(
                PdshUiHostCommand.Retry(sessionId, StateRequestId(UUID.randomUUID().toString())),
            )
        }
    }
    val planApproveFromTable: PdshActionAvailability<(PendingAnswer, String) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.APPROVE_PLAN)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> if (sessionId == null) {
                PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
            } else PdshActionAvailability.Available { pending, answer ->
                action.callback(
                    PdshUiHostCommand.ApprovePlan(
                        sessionId,
                        pending.typedRequestId,
                        StateRequestId(UUID.randomUUID().toString()),
                        answer,
                    ),
                )
            }
        }
    val planChangesFromTable: PdshActionAvailability<(PendingAnswer) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.REJECT_PLAN)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> if (sessionId == null) {
                PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
            } else PdshActionAvailability.Available { pending ->
                action.callback(
                    PdshUiHostCommand.RejectPlan(
                        sessionId,
                        pending.typedRequestId,
                        StateRequestId(UUID.randomUUID().toString()),
                    ),
                )
            }
        }
    val queueSubmissionFromTable: PdshActionAvailability<(String, StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.QUEUE)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> if (workerSessionId == null) {
                PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
            } else PdshActionAvailability.Available { text, requestId ->
                action.callback(PdshUiHostCommand.Queue(workerSessionId, requestId, text))
            }
        }
    val steerSubmissionFromTable: PdshActionAvailability<(String, StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.STEER)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> if (workerSessionId == null) {
                PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
            } else PdshActionAvailability.Available { text, requestId ->
                action.callback(PdshUiHostCommand.Steer(workerSessionId, requestId, text))
            }
        }
    val stopFromTable: PdshActionAvailability<(StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.STOP)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> if (workerSessionId == null) {
                PdshActionAvailability.Unavailable(PdshUnavailableReason.REQUIRED_FACT_UNKNOWN)
            } else PdshActionAvailability.Available { requestId ->
                action.callback(PdshUiHostCommand.Stop(workerSessionId, requestId))
            }
        }
    val queueEditFromTable: PdshActionAvailability<(com.phonedsh.ui.state.ManagedQueueItemState, String, StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.QUEUE_EDIT)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> PdshActionAvailability.Available { item, text, requestId ->
                val itemId = (item.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value
                val workerSessionId = item.sessionId
                if (itemId != null && workerSessionId != null && item.canEdit == true) {
                    action.callback(PdshUiHostCommand.EditQueueItem(workerSessionId, itemId, requestId, text))
                }
            }
        }
    val queueRemoveFromTable: PdshActionAvailability<(com.phonedsh.ui.state.ManagedQueueItemState, StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.QUEUE_REMOVE)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> PdshActionAvailability.Available { item, requestId ->
                val itemId = (item.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value
                val workerSessionId = item.sessionId
                if (itemId != null && workerSessionId != null && item.canRemove == true) {
                    action.callback(PdshUiHostCommand.RemoveQueueItem(workerSessionId, itemId, requestId))
                }
            }
        }
    val queueSteerFromTable: PdshActionAvailability<(com.phonedsh.ui.state.ManagedQueueItemState, StateRequestId) -> Unit> =
        when (val action = actionAvailability.forAction(PdshActionKey.QUEUE_STEER)) {
            is PdshActionAvailability.Unavailable -> action
            is PdshActionAvailability.Available -> PdshActionAvailability.Available { item, requestId ->
                val itemId = (item.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value
                val workerSessionId = item.sessionId
                if (itemId != null && workerSessionId != null && item.canSteer == true) {
                    action.callback(PdshUiHostCommand.SteerQueueItem(workerSessionId, itemId, requestId))
                }
            }
        }
    ChatPage(
        state = state ?: ChatScreenState.from(nodes = emptyList(), local = ChatLocalState()),
        onDraftChange = onDraftChange,
        onSend = onSend,
        onStop = onStop,
        onToggleRow = actions.toggleRow,
        onApprove = actions.approve,
        onDeny = actions.deny,
        onSubmitAnswer = actions.answer,
        onDismissQuestion = actions.dismissQuestion,
        onGoalPause = actions.goalCommand?.let { command -> { command("pause") } },
        onGoalResume = actions.goalCommand?.let { command -> { command("resume") } },
        onGoalClear = actions.goalCommand?.let { command -> { command("clear") } },
        onSelectAccessMode = actions.selectAccessMode,
        onRetryAccessModes = actions.refreshCatalogs,
        onReloadCommands = actions.refreshCatalogs,
        onExecuteCommand = actions.executeCommand,
        onSelectModel = actions.selectModel,
        onOpenDeviceConnections = { onNavigate(PdshRoute.DeviceConnection) },
        onImeVisibleChange = actions.imeChanged,
        onExpandPendingSlot = actions.expandPending,
        onStartEngine = actions.startEngine,
        onRestartEngine = actions.restartEngine,
        onConfigureProvider = { onNavigate(PdshRoute.ModelProvider) },
        // One host line serves both the failure banner's 关闭 and the import notice:
        // both are the App's own sentence about what just happened.
        onDismissBanner = { _: String -> onDismissNotice() },
        onRetry = onSend,
        onOpenSessions = { if (onOpenDrawer != null) onOpenDrawer() else onNavigate(PdshRoute.Sessions) },
        title = title ?: UiStrings.SESSION_TITLE_NEW,
        collapseTiming = collapseTiming,
        onSetCollapseTiming = onSetCollapseTiming,
        // The page-head menu's 后台任务（N）/定时任务（N） rows exist only while the
        // host reported rows (`ChatPage.swift:247`/`:252`); with no read they are
        // absent instead of opening a sheet that can only say 读取不到.
        jobs = subpages.jobs,
        schedules = subpages.schedules,
        onOpenJobs = { onNavigate(PdshRoute.SessionJobs) },
        onOpenSchedules = { onNavigate(PdshRoute.SessionSchedules) },
        subagents = subpages.subagents,
        onOpenSubagentSession = onOpenSubagentSession,
        onLoadEarlier = onLoadEarlierTranscript,
        // The page-head menu's 产物 row (`ChatPage.swift:256`), which opens the
        // artifacts page. The apps' artifact transport is still the demo one (the
        // real produced files are the workspace, reached by the 文件 route), so the
        // row keeps naming the session that transport knows.
        onOpenArtifacts = {
            onNavigate(PdshRoute.SessionArtifacts(state?.sessionID.orEmpty()))
        },
        // The menu's 运行状态 and 本会话设置 rows were drawn with the page's default
        // empty callbacks, so they closed the menu and did nothing. Both pages are
        // already routes, so the wiring is the two edges.
        onOpenRunStatus = { onNavigate(PdshRoute.Runtime) },
        onOpenSessionSettings = { onNavigate(PdshRoute.Configuration) },
        // L72/L73: the baseline's 文件/命令 path is 对话 ⋯ → 右侧边栏
        // (`ChatPage.swift:243-291` → `:263-266` → `NativeWorkbenchPage`). The route
        // already exists; the row was hidden because this callback was null.
        onOpenWorkbench = { onNavigate(PdshRoute.Workbench()) },
        // L69: the rename alert writes through the host's session store.
        onRenameSession = onRename,
        // The composer's two pickers open the platform document UI (the Activity
        // owns it), and the preview of a row's file is a route push.
        onAddFiles = onAddFiles,
        onAddImages = onAddImages,
        onExportTranscript = exportTranscript ?: {},
        onRemoveAttachment = onRemoveAttachment,
        onDismissComposerNotice = onDismissNotice,
        onOpenFile = { path -> onNavigate(PdshRoute.Preview(path)) },
        onOpenResource = { resource ->
            when (val target = markdownResourcePreviewTarget(
                source = resource,
                currentWorkerSessionId = workerSessionId,
                hasVerifiedWorkspaceRoot = workspaceRoot != null,
            )) {
                is MarkdownResourcePreviewTarget.Refused -> unavailableResource = target
                is MarkdownResourcePreviewTarget.WorkspacePath -> scope.launch {
                    val requestedContext = MarkdownResourceContext(
                        localSessionId = sessionId,
                        workerSessionId = workerSessionId,
                        workspaceRoot = workspaceRoot?.toPath()?.toAbsolutePath()?.normalize(),
                    )
                    when (val resolved = resolveMarkdownPreviewPath(previewSource, target, requestedContext) {
                        MarkdownResourceContext(
                            localSessionId = latestLocalSessionId.value,
                            workerSessionId = latestWorkerSessionId.value,
                            workspaceRoot = latestWorkspaceRoot.value?.toPath()?.toAbsolutePath()?.normalize(),
                        )
                    }) {
                        is MarkdownResourcePreviewTarget.WorkspacePath -> onNavigate(PdshRoute.Preview(resolved.previewPath))
                        is MarkdownResourcePreviewTarget.Refused -> unavailableResource = resolved
                    }
                }
            }
        },
        imageSource = imageSource,
        timelineRetryAvailability = retryFromTable,
        permissionApproveAvailability = permissionApproveAvailability,
        permissionDenyAvailability = permissionDenyAvailability,
        planApproveAvailability = planApproveFromTable,
        planRequestChangesAvailability = planChangesFromTable,
        queueEditAvailability = queueEditFromTable,
        queueRemoveAvailability = queueRemoveFromTable,
        queueSteerAvailability = queueSteerFromTable,
        queueSubmissionAvailability = queueSubmissionFromTable,
        steerSubmissionAvailability = steerSubmissionFromTable,
        stopAvailability = stopFromTable,
        startEngineAvailability = actions.startEngineAvailability,
        onSpeakRecentReply = speakRecentReply,
        composerAvailability = ComposerAvailability(
            addImages = available(PdshActionKey.IMAGE_IMPORT),
            addFiles = available(PdshActionKey.FILE_IMPORT),
            speakRecentReply = speakRecentReply != null,
            selectAccessMode = available(PdshActionKey.SELECT_PERMISSION_MODE),
            selectModel = available(PdshActionKey.SELECT_MODEL),
            answerQuestions = available(PdshActionKey.ANSWER_QUESTION),
            dismissQuestions = available(PdshActionKey.DISCARD_QUESTION),
            approvePlans = available(PdshActionKey.APPROVE_PLAN),
            requestPlanChanges = available(PdshActionKey.REJECT_PLAN),
        ),
    )
    unavailableResource?.let { refused ->
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        val explanation = when (refused.reason) {
            MarkdownResourceRefusal.NO_CURRENT_SESSION -> UiStrings.FILES_PREVIEW_NO_SESSION
            MarkdownResourceRefusal.NO_VERIFIED_WORKSPACE -> UiStrings.FILES_PREVIEW_NO_SESSION
            MarkdownResourceRefusal.MISSING_PATH -> UiStrings.FILES_PREVIEW_MISSING
            MarkdownResourceRefusal.ABSOLUTE_RESOURCE,
            MarkdownResourceRefusal.DIFFERENT_SESSION,
            MarkdownResourceRefusal.UNSAFE_PATH,
            MarkdownResourceRefusal.INVALID -> UiStrings.FILES_PREVIEW_UNSAFE
        }
        Dialog(onDismissRequest = { unavailableResource = null }) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(tokens.colors.surface, RoundedCornerShape(tokens.radius.card))
                    .padding(tokens.spacing.cardInset),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                BasicText(
                    text = UiStrings.PREVIEW_UNAVAILABLE,
                    style = type.subheadline.copy(color = tokens.colors.textPrimary),
                )
                BasicText(
                    text = explanation,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                )
                BasicText(
                    text = refused.sourceIdentity,
                    style = type.caption.copy(color = tokens.colors.textTertiary),
                )
                BasicText(
                    text = UiStrings.FILES_PREVIEW_DONE,
                    style = type.secondary.copy(color = tokens.colors.accent),
                    modifier = Modifier.clickable { unavailableResource = null },
                )
            }
        }
    }
}

/**
 * 命令结果: the chat page's own subpage, reached by the shell's route rather than
 * by an in-page row (the baseline opens it from `executeCommand`, `:2516`).
 *
 * `完成` pops; there is no write here, so the only host interaction a page of this
 * family has is the two sheets' 刷新.
 */
@Composable
private fun CommandResultRoute(subpages: ChatSubpageFacts, onBack: () -> Unit) {
    CommandExecutionResultPage(
        state = ChatCommandResultState(subpages.commandExecution),
        onDone = onBack,
    )
}

/**
 * 后台任务: `刷新` re-reads the session activity through the host seam.
 *
 * The baseline's sheet takes one `onRefresh` (`ChatPage.swift:441`) and calls
 * `management.refreshActivity(sessionID:)` — the same read the 定时任务 sheet uses,
 * because one call fills `jobs` and `scheduleRecords` together. This host owns
 * neither, so the gesture is a [PdshHostAction] handoff: it reaches the composition
 * root, is logged, and comes back as one honest line; the facts only change if a
 * real read reports them.
 */
@Composable
private fun SessionJobsRoute(
    subpages: ChatSubpageFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    NativeJobListSheet(
        state = ChatJobsSheetState.from(subpages.jobs),
        onRefresh = { onHostAction(PdshHostAction.RefreshSessionActivity) },
        onClose = onBack,
    )
}

/** 定时任务: the same one read as [SessionJobsRoute], sharing its handoff. */
@Composable
private fun SessionSchedulesRoute(
    subpages: ChatSubpageFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    NativeScheduleListSheet(
        state = ChatSchedulesSheetState.from(subpages.schedules),
        onRefresh = { onHostAction(PdshHostAction.RefreshSessionActivity) },
        onClose = onBack,
    )
}

@Composable
private fun WorkspaceFoldersRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    onNavigate: (PdshRoute) -> Unit,
) {
    var local by remember { mutableStateOf(WorkspaceFoldersLocalState()) }
    WorkspaceFoldersPage(
        state = WorkspaceFoldersScreenState.from(facts.workspaceFolders, local),
        onBack = onBack,
        // §1: every row opens the files page (`NativeShell.swift:326`–`:336`), so
        // this is a route push, not a host handoff.
        onOpenFiles = { folder -> onNavigate(PdshRoute.Files(folder.id)) },
        onSwitch = { folder -> onHostAction(PdshHostAction.WorkspaceSwitch(folder.id)) },
        onBeginCreate = { local = local.apply(WorkspaceFoldersUiEvent.BeginCreate) },
        onDraftChange = { text -> local = local.apply(WorkspaceFoldersUiEvent.DraftChange(text)) },
        onCancelCreate = { local = local.apply(WorkspaceFoldersUiEvent.CancelCreate) },
        onCreate = {
            onHostAction(PdshHostAction.WorkspaceCreate(local.draft))
            // No write command exists: the create row stays open with the typed
            // name instead of claiming a folder that was never created.
        },
        onDeleteRequest = { folder ->
            local = local.apply(WorkspaceFoldersUiEvent.RequestDelete(folder.id))
        },
        onDeleteConfirm = { folder ->
            onHostAction(PdshHostAction.WorkspaceDelete(folder.id))
            local = local.apply(WorkspaceFoldersUiEvent.CancelDelete)
        },
        onDeleteCancel = { local = local.apply(WorkspaceFoldersUiEvent.CancelDelete) },
        // 重试 on a failed folder read: the host re-reads the one workspace fact it
        // owns and the page re-projects it (the L75 gap this closes — the page had
        // the verb, no caller passed it).
        onRetry = { onHostAction(PdshHostAction.RefreshWorkspace) },
    )
}

/**
 * 定时任务: the schedule catalog and its embedded editor.
 *
 * Two of the four gestures are host reads (`刷新`, `加载更早记录`) and reach
 * [PdshHostAction]; the other two (`新建`, `编辑`) present the page's own
 * `ScheduleEditorPage` (`NativeAutomationPage.swift:212`, README §1: an embedded
 * subpage ships with its parent). The form's `保存` is the write handoff: the route
 * records the attempt, re-projects the form, and only a validated draft reaches
 * the host.
 *
 * A page whose bar renders but does nothing is worse than a page that never renders
 * it, because the user reads it as broken — which is why every one of the four
 * controls is wired to something real.
 *
 * The bar controls only exist when their callback is non-null
 * (`NativeAutomationPage.kt:598`/`:607`), which is exactly why leaving them
 * null made the collected screenshots disagree with the app.
 *
 * @param onHostAction the handoff seam for the four schedule gestures.
 */
@Composable
private fun AutomationRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    backLevel: PdshBackLevel?,
) {
    var local by remember { mutableStateOf(AutomationLocalState()) }
    // The page's three child levels (detail, history, the embedded editor) and its
    // delete confirmation are local state, so the gesture used to skip straight from
    // the editor back to the previous route. It now leaves them one at a time, in
    // the same order the page's own ✕/取消 controls do.
    RouteBackLevel(
        backLevel = backLevel,
        enabled = local.editor != null ||
            local.route != com.phonedsh.ui.page.AutomationRoute.CATALOG ||
            local.deleteConfirmId != null,
        onBack = {
            local = when {
                local.editor != null -> local.apply(AutomationUiEvent.CancelEditor)
                local.route != com.phonedsh.ui.page.AutomationRoute.CATALOG ->
                    local.apply(AutomationUiEvent.Back)
                else -> local.apply(AutomationUiEvent.CancelDelete)
            }
        },
    )
    val automationFacts = facts.automation
    // The draft the editor opens on: the reported schedule's own values, or the
    // baseline's defaults for a new one. The platform zone is measured here and
    // handed in, because the state function must not read the platform (§3.1).
    fun draftFor(id: String?): AutomationScheduleDraft = AutomationScheduleDraft.from(
        schedule = id?.let { wanted -> automationFacts.snapshot?.schedules?.firstOrNull { it.id == wanted } },
        timeZone = ZoneId.systemDefault().id,
    )

    NativeAutomationPage(
        state = AutomationScreenState.from(automationFacts, local),
        onBack = onBack,
        onOpenDetail = { id -> local = local.apply(AutomationUiEvent.OpenDetail(id)) },
        onOpenHistory = { id ->
            local = local.apply(AutomationUiEvent.OpenHistory(id))
            onHostAction(PdshHostAction.LoadAutomationHistory(id))
        },
        onBackToCatalog = { local = local.apply(AutomationUiEvent.Back) },
        // §1's 定时任务 bar: ✕ (back, above), 刷新, 新建. The history tail is still a
        // host read.
        onRefresh = { onHostAction(PdshHostAction.RefreshAutomation) },
        // 新建 / 编辑 present the page's own `ScheduleEditorPage` (README §1: an
        // embedded subpage ships with its parent). Before this lane they were a
        // handoff to a host editor that does not exist, so this form is the first
        // implementation of the two gestures.
        onNewSchedule = { local = local.apply(AutomationUiEvent.OpenEditor(draftFor(null))) },
        onEditSchedule = { id -> local = local.apply(AutomationUiEvent.OpenEditor(draftFor(id))) },
        onLoadMoreHistory = { id, before ->
            onHostAction(PdshHostAction.LoadAutomationHistory(id, before))
        },
        onRequestDelete = { id -> local = local.apply(AutomationUiEvent.RequestDelete(id)) },
        onConfirmDelete = { id ->
            local = local.apply(AutomationUiEvent.CancelDelete)
            onHostAction(PdshHostAction.DeleteAutomationSchedule(id))
        },
        onCancelDelete = { local = local.apply(AutomationUiEvent.CancelDelete) },
        onDraftChange = { draft -> local = local.apply(AutomationUiEvent.EditDraft(draft)) },
        onCancelEditor = { local = local.apply(AutomationUiEvent.CancelEditor) },
        onEditorSaved = { local = local.apply(AutomationUiEvent.CancelEditor) },
        onSubmitDraft = { draft, submissionID ->
            // The page's contract: record the attempt first, then hand the draft
            // over only when the re-projected form validates. The host replies by
            // returning the reread schedule in `AutomationFacts.writeReceipt`.
            local = local.apply(AutomationUiEvent.SubmitDraft(submissionID))
            if (draft.canSubmit && draft.timingError() == null) {
                onHostAction(PdshHostAction.SaveAutomationSchedule(draft, submissionID))
            }
        },
    )
}

@Composable
private fun ConfigurationRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    onConfigurationWrite: (suspend (ConfigurationWriteRequest) -> ConfigurationWriteReceipt)?,
) {
    var local by remember { mutableStateOf(ConfigurationLocalState()) }
    NativeConfigurationPage(
        state = ConfigurationScreenState.from(facts.configuration, local),
        onDone = onBack,
        onToggleSection = { id -> local = local.apply(ConfigurationUiEvent.ToggleSection(id)) },
        onOpenWebSearch = { onNavigate(PdshRoute.WebSearch) },
        onRefresh = { onHostAction(PdshHostAction.RefreshConfiguration) },
        onRetry = { onHostAction(PdshHostAction.RefreshConfiguration) },
        onSaveGroupDrafts = { namespace, patch ->
            onHostAction(PdshHostAction.SaveConfigurationGroup(namespace, patch))
        },
        onResetField = { namespace, field ->
            onHostAction(PdshHostAction.ResetConfigurationField(namespace, field))
        },
        onApplyDefaultPermission = { id ->
            onHostAction(PdshHostAction.SaveDefaultPermission(id))
        },
        onConfigurationWrite = onConfigurationWrite,
        onOpenPluginInventory = { onNavigate(PdshRoute.PluginInventory) },
    )
}

/**
 * 命令: the accelerator shell over the host's measured command surface.
 *
 * The facts carry what the host really advertises (`PdshNavFacts.shell`): the
 * accelerators its HELLO named and the limits the bridge enforces. A host that
 * advertises none leaves the snapshot at its empty default, and the page shows
 * its 还没接上命令 body rather than an invented command list.
 *
 * The run form is local UI state; 运行 is the host's gesture, so it is handed
 * over as one [PdshHostAction.RunShellCommand] instead of an empty receiver. A
 * host with no exec entry point answers with that fact, which is the same
 * "never a dead tap" rule every other host-owned action follows.
 *
 * The body is `PDSHShellPage`, the inset-grouped card layout of
 * `PDSHShellPage.swift`; `ToolsScreenState` stays the reducer the JVM tests drive.
 *
 * @param facts the host snapshot; only `shell` is read here.
 * Uses the host's measured action table; unavailable run/cancel actions stay disabled.
 */
@Composable
private fun ToolsRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
) {
    var local by remember { mutableStateOf(ShellLocalState()) }
    val state = ToolsScreenState.from(facts.shell, local)
    val runAvailability = facts.actionAvailability.forAction(PdshActionKey.EXECUTE_COMMAND)
    val cancelAvailability = facts.actionAvailability.forAction(PdshActionKey.SHELL_CANCEL)
    PDSHShellPage(
        state = state,
        onSelectCommand = { name -> local = local.apply(ShellUiEvent.SelectCommand(name)) },
        onWorkingDirectoryChange = { value ->
            local = local.apply(ShellUiEvent.SetWorkingDirectory(value))
        },
        onArgumentsChange = { value -> local = local.apply(ShellUiEvent.SetArguments(value)) },
        onRun = when (runAvailability) {
            is PdshActionAvailability.Unavailable -> null
            is PdshActionAvailability.Available -> {
                {
                    runAvailability.callback(
                        PdshUiHostCommand.ExecuteCommand(
                            command = state.selectedCommand,
                            workingDirectory = state.workingDirectory,
                            arguments = state.arguments,
                            requestId = StateRequestId("ui.exec." + UUID.randomUUID().toString()),
                        ),
                    )
                }
            }
        },
        onCancel = when (cancelAvailability) {
            is PdshActionAvailability.Unavailable -> null
            is PdshActionAvailability.Available -> facts.shell.run.runningExecId?.let { execId ->
                {
                    cancelAvailability.callback(
                        PdshUiHostCommand.ShellCancel(
                            execId,
                            StateRequestId("ui.exec.cancel." + UUID.randomUUID().toString()),
                        ),
                    )
                }
            }
        },
        onBack = onBack,
    )
}

/**
 * 工作区文件树 (`FilesPage`) — with a real listing, at last.
 *
 * The L28 audit's finding was that this route handed the page `files = null` while
 * the bytes were already on disk (`:app`'s `filesDir/xl/materialized/workspace`), so
 * no renderer could ever show anything. The route now reads through
 * [PreviewFileSource]: one `files()` call on an IO dispatcher, from the same
 * materialized tree the preview resolves against, so the listing and the preview can
 * never disagree about what exists.
 *
 * `null` keeps its old meaning — the host reported no listing — and the page keeps
 * rendering 等待引擎连接… for it, never 「还没有文件」 (`FilesPage.swift:102`). A root
 * that exists and is empty really is an empty workspace, and the page's own card
 * says exactly that.
 *
 * @param onNavigate the file row's edge: PR #15 replaced the in-page preview sheet
 *   with a pushed surface (`FilesPage.swift:59`), so a row opens
 *   [PdshRoute.Preview] and one back returns to this listing.
 * @param workspaceRoot the host's materialized workspace, or `null` for the
 *   library's default device root (see [PdshNavHost]).
 */
@Composable
private fun FilesRoute(
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    workspaceRoot: File?,
    backLevel: PdshBackLevel?,
    onImportRequest: ((String) -> Unit)?,
    importReceipt: Pair<String, com.phonedsh.ui.page.FilesImportReceipt>?,
) {
    var local by remember { mutableStateOf(FilesLocalState()) }
    var importRequestId by remember { mutableStateOf<String?>(null) }
    // §5's "one gesture pops one level" applies inside the listing too: in a folder
    // that level is the folder. Without this the gesture closed the whole listing
    // and left the person at the folder page — one level higher than they were.
    RouteBackLevel(backLevel, local.directory.isNotEmpty()) {
        local = local.apply(FilesUiEvent.NavigateUp)
    }
    val source = rememberPreviewSource(workspaceRoot)
    // `null` until the read answers: the page's waiting state, not an empty list.
    var listing by remember(source) { mutableStateOf<List<WorkspaceFile>?>(null) }
    val matchingImportReceipt = importReceipt?.takeIf { it.first == importRequestId }?.second
    LaunchedEffect(source, matchingImportReceipt) { listing = source.files() }
    FilesPage(
        state = FilesScreenState.from(FilesSource(files = listing), local, matchingImportReceipt),
        onOpenFolder = { folder -> local = local.apply(FilesUiEvent.OpenFolder(folder)) },
        onOpenFile = { file -> onNavigate(PdshRoute.Preview(file.relativePath)) },
        onQueryChange = { query -> local = local.apply(FilesUiEvent.SetQuery(query)) },
        onNavigateUp = { local = local.apply(FilesUiEvent.NavigateUp) },
        onBack = onBack,
        onImportRequest = if (onImportRequest == null) null else {
            {
                val requestId = java.util.UUID.randomUUID().toString()
                importRequestId = requestId
                onImportRequest(requestId)
            }
        },
    )
}

/**
 * 文件预览: the single preview face for one workspace path.
 *
 * PR #15's `PreviewSurface` is presented as a push from the files list and as a
 * full-screen cover from the chat page; on Android a pushed route is both, because
 * the surface is one composable and the back gesture is the stack's.
 *
 * The share action is the route's, not the page's: `FileProvider` needs a `Context`
 * and the page must stay a pure function of its state. A `false` answer is handed
 * back to the surface, which says 「没有可以接收这个文件的 App。」 instead of
 * claiming it shared.
 */
@Composable
private fun PreviewRoute(
    route: PdshRoute.Preview,
    onBack: () -> Unit,
    workspaceRoot: File?,
) {
    val context = LocalContext.current
    val source = rememberPreviewSource(workspaceRoot)
    PreviewPage(
        relativePath = route.path,
        source = source,
        onBack = onBack,
        onShare = { file -> PreviewShare.share(context, file) },
    )
}

/**
 * 导出诊断: the diagnostics export page.
 *
 * The host has no export command, so the page opens on its no-snapshot state and
 * the write gesture has no effect; the page never claims a file it did not write.
 */
@Composable
private fun ExportRoute(onBack: () -> Unit) {
    // 写入诊断包 is a host command this build does not carry: there is no diagnostic
    // bundle format, no writer and no provider root to share it from. The page is a
    // real settings row, so it stays reachable and its 写入 verb answers instead of
    // doing nothing: the attempt is recorded and the page prints its failure line.
    // The route note (`hostRouteNote`) already says the command is missing before
    // the button is pressed, so this line is the second half of the same fact.
    var refused by remember { mutableStateOf(false) }
    ExportPage(
        state = ExportScreenState.from(
            ExportFacts(failure = UiStrings.EXPORT_UNAVAILABLE.takeIf { refused }),
        ),
        onBack = onBack,
        onWrite = { refused = true },
        // The baseline writes on appear. Nothing is written here, so the page must
        // not run a write on entry: the answer comes from the gesture, not from
        // opening the page (a failure line that appears before a tap would look like
        // a read error).
        onOpen = null,
        // No written file exists, so there is nothing to share and nothing to retry.
        onShare = null,
        onRetry = null,
    )
}

@Composable
private fun SettingsRoute(
    mode: SettingsPageMode,
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    onSettingsWrite: (SettingsWrite) -> Unit,
    onPreferenceWrite: (SettingsPreferenceChoice) -> Unit,
    onSelectFontFamily: ((rowId: String, family: String) -> Unit)?,
    onToggleDeveloperTools: (Boolean) -> Unit,
    backLevel: PdshBackLevel?,
    // 手机权限 is a *tab* of this sheet as well as a route (§1 names both entry
    // points), so the two hosted gestures reach it here too — a tab whose 请求 did
    // nothing would be the same fake control the pushed page no longer has.
    onPhonePermissionRequest: (PhoneCapability) -> Unit = {},
    onPhonePermissionSettings: (PhoneCapability) -> Unit = {},
    agentPresets: NativeAgentPresetsFacts = NativeAgentPresetsFacts(),
    agentPresetActions: AgentPresetActions = AgentPresetActions(),
    /** 已连接的电脑's trailing value; `null` keeps the row's honest 未知. */
    connectedComputerValue: String? = null,
) {
    // 新会话默认权限 is the settings sheet's own child page in the baseline, so it
    // is a local page swap here, not a route the stack owns.
    var permissionDefaults by remember { mutableStateOf(false) }
    var archivedSessions by remember { mutableStateOf(false) }
    // …which means the gesture had nothing to pop but the sheet: back from the child
    // page closed the whole settings sheet. One level means the child page.
    RouteBackLevel(backLevel, permissionDefaults || archivedSessions) {
        permissionDefaults = false
        archivedSessions = false
    }
    // L55: 关于 and 开发者工具 are the sheet's other two sub-surfaces. They are page
    // swaps for the same reason as 新会话默认权限 — the baseline renders both inside
    // the settings sheet, and neither is a route. Each surface registers its own back
    // level (see `SettingsSurfaces.kt`), so this frame only decides what the body is.
    var surface by remember { mutableStateOf(SettingsSurface.NONE) }
    val settingsIndexListState = androidx.compose.foundation.lazy.rememberLazyListState()
    // The sheet's five tabs are host state (§1: 通用 / 模型 / 插件 / 手机权限 / 预设).
    // Before this lane the tab was never set and the picker's callback was empty, so
    // the four non-通用 bodies were unreachable even though each page already ships
    // its `embedded: true` form and `SettingsPage` declares the `tabContent` slot —
    // the L31 "code exists, not wired" finding. The slot is the page's own seam, so
    // this is wiring only: no page file changes.
    var tab by remember { mutableStateOf(SettingsTab.GENERAL) }
    // The mirrored index reads `settings`, appendix included: the facts are one
    // value, and the host fills the platform rows where it measures them.
    val settings = facts.settings
    if (archivedSessions) {
        val archivedRows = facts.sessions?.filter { it.archived == true }?.map { session ->
            SessionListing(
                id = session.id,
                title = session.title ?: "",
                updatedAtMs = session.updatedAt?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() },
                status = SessionRunStatus.IDLE,
            )
        }
        val restoreAvailability = facts.actionAvailability.forAction(PdshActionKey.SESSION_RESTORE)
        ArchivedSessionsPage(
            state = ArchivedSessionsPageState.from(
                sessions = archivedRows,
                nowMs = System.currentTimeMillis(),
                zone = java.time.ZoneId.systemDefault(),
                waiting = facts.sessionsWaiting,
                failure = facts.sessionsFailure,
            ),
            onBack = { archivedSessions = false },
            onRestore = if (restoreAvailability is PdshActionAvailability.Available) { row ->
                facts.actionAvailability.dispatch(
                    PdshActionKey.SESSION_RESTORE,
                    PdshUiHostCommand.SessionRestore(row.id, StateRequestId("ui.settings.restore.${java.util.UUID.randomUUID()}")),
                )
            } else null,
        )
    } else if (surface == SettingsSurface.ABOUT) {
        AboutSurface(facts = facts, onBack = { surface = SettingsSurface.NONE }, backLevel = backLevel)
    } else if (surface == SettingsSurface.DEV_TOOLS) {
        DeveloperToolsSurface(
            facts = facts,
            onBack = { surface = SettingsSurface.NONE },
            backLevel = backLevel,
            onAction = onHostAction,
            actionAvailability = facts.actionAvailability,
        )
    } else if (permissionDefaults) {
        PermissionDefaultsPage(
            state = PermissionDefaultsState.from(
                selected = settings.defaultPermissionTier,
                languageId = settings.preferences.language?.id,
                availableTiers = settings.defaultPermissionAvailableTiers,
                writable = settings.defaultPermissionWritable,
                busy = settings.defaultPermissionBusy,
                failure = settings.defaultPermissionFailure,
                readOnlyReason = settings.defaultPermissionReadOnlyReason,
                startupLocked = settings.defaultPermissionStartupLocked,
            ),
            // A locked row must not reach the host write seam at all: the
            // disabled semantics are the first guard, this null callback the
            // second, and the view model refuses a stale call as the third.
            onSelect = if (settings.defaultPermissionWritable) {
                { tier -> onSettingsWrite(SettingsWrite.DefaultPermissionTier(tier)) }
            } else {
                null
            },
            onBack = { permissionDefaults = false },
        )
    } else {
        SettingsPage(
            state = SettingsScreenState.from(settings)
                .copy(scheduleCount = facts.automation.snapshot?.schedules?.size, tonoAccount = facts.tonoAccount),
            mode = mode,
            backLevel = backLevel,
            licenseEntries = facts.licenses?.map { license ->
                com.phonedsh.ui.page.AndroidLicenseNotice(
                    name = license.name ?: license.id,
                    license = license.source ?: UiStrings.UNAVAILABLE,
                )
            },
            onRestartEngine = { onHostAction(PdshHostAction.RestartRuntime) },
            onNavigate = { destination ->
                when (destination) {
                    SettingsDestination.PERMISSION_DEFAULTS -> permissionDefaults = true
                    SettingsDestination.ABOUT -> surface = SettingsSurface.ABOUT
                    SettingsDestination.DEV_TOOLS -> surface = SettingsSurface.DEV_TOOLS
                    else -> PdshSettingsRows.targetOf(destination)?.let(onNavigate)
                }
            },
            onToggleBackgroundKeepAlive = { value ->
                onSettingsWrite(SettingsWrite.BackgroundKeepAlive(value))
            },
            onSelectBusyEnterMode = { mode -> onSettingsWrite(SettingsWrite.BusyEnter(mode)) },
            onSelectPreference = onPreferenceWrite,
            onSelectFontFamily = onSelectFontFamily,
            onOpenAgentPresets = { onNavigate(PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.AGENT_PRESETS)) },
            onOpenPhonePermissions = { onNavigate(PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.PHONE_PERMISSIONS)) },
            onOpenPluginsTools = { onNavigate(PdshRoute.Configuration) },
            onOpenFolders = { onNavigate(PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.FOLDERS)) },
            onOpenArchivedSessions = { archivedSessions = true },
            onOpenConnectedComputer = { onNavigate(PdshRoute.ConnectedComputer) },
            connectedComputerValue = connectedComputerValue,
            onSelectDefaultPermission = { tier -> onSettingsWrite(SettingsWrite.DefaultPermissionTier(tier)) },
            onToggleDeveloperTools = onToggleDeveloperTools,
            onBack = onBack,
            tab = tab,
            indexListState = settingsIndexListState,
            onSelectTab = { selected -> tab = selected },
            tabContent = { selected ->
                when (selected) {
                    // 通用 is the sheet's own body (permission defaults above is its
                    // one child page), so the slot is never asked to draw it.
                    SettingsTab.GENERAL -> Unit
                    // 模型: the page the app already routes as a standalone sheet.
                    SettingsTab.MODELS -> ModelProviderRoute(
                        facts = facts,
                        onBack = onBack,
                        onHostAction = onHostAction,
                        embedded = true,
                        backLevel = backLevel,
                    )
                    // 插件: 插件配置 inside the body pushes the configuration page.
                    SettingsTab.PLUGINS -> PluginInventoryRoute(
                        facts = facts,
                        onBack = onBack,
                        onNavigate = onNavigate,
                        onRefresh = { onHostAction(PdshHostAction.RefreshConfiguration) },
                        embedded = true,
                    )
                    SettingsTab.PERMISSIONS ->
                        PhonePermissionsRoute(
                            facts,
                            onBack = onBack,
                            embedded = true,
                            backLevel = backLevel,
                            onRequestPermission = onPhonePermissionRequest,
                            onOpenPermissionSettings = onPhonePermissionSettings,
                        )
                    SettingsTab.PRESETS -> AgentPresetsRoute(
                        onBack = onBack,
                        facts = agentPresets,
                        actions = agentPresetActions,
                        actionAvailability = facts.actionAvailability,
                        embedded = true,
                    )
                }
            },
        )
    }
}

@Composable
private fun ModelProviderRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    embedded: Boolean = false,
    backLevel: PdshBackLevel? = null,
) {
    var local by remember { mutableStateOf(ModelProviderLocalState()) }
    ModelProviderSettingsPage(
        state = ModelProviderScreenState.from(facts.modelProvider, local),
        onAdd = { onHostAction(PdshHostAction.OpenProviderEditor(null)) },
        onEdit = { id -> onHostAction(PdshHostAction.OpenProviderEditor(id)) },
        onSelect = { id -> onHostAction(PdshHostAction.SelectProvider(id)) },
        onToggleSection = { id -> local = local.apply(ModelProviderUiEvent.ToggleSection(id)) },
        onBack = onBack,
        // The settings sheet's 模型 tab draws the same page without its own header.
        embedded = embedded,
        backLevel = backLevel,
        // The page's editor is its own inline form; these four are the writes it
        // cannot perform itself. Each is handed over as one host action and the
        // page still never mutates its facts: the host re-reads them after a save,
        // so a row can only change because the device store changed.
        onStartEngine = { onHostAction(PdshHostAction.RestartRuntime) },
        onSave = { draft, requestId -> onHostAction(PdshHostAction.SaveProvider(draft, requestId)) },
        onTest = { draft -> onHostAction(PdshHostAction.TestProvider(draft)) },
        onDelete = { id -> onHostAction(PdshHostAction.DeleteProvider(id)) },
        onGetModels = { draft, requestId -> onHostAction(PdshHostAction.GetProviderModels(draft, requestId)) },
    )
}

@Composable
private fun WebSearchRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    var local by remember { mutableStateOf(WebSearchLocalState()) }
    WebSearchSettingsPage(
        state = WebSearchScreenState.from(facts.webSearch, local),
        onToggle = { enabled -> onHostAction(PdshHostAction.SetWebSearchEnabled(enabled)) },
        onSelectBackend = { id -> onHostAction(PdshHostAction.SelectWebSearchBackend(id)) },
        onToggleBackends = { local = local.apply(WebSearchUiEvent.ToggleBackends) },
        onBack = onBack,
        // The five writes are host commands; the page arms each control only while the
        // host reports `writable = YES`, and the host answers with new facts.
        onModeChange = { mode -> onHostAction(PdshHostAction.SetWebSearchMode(mode)) },
        onCommitAddress = { address -> onHostAction(PdshHostAction.CommitWebSearchAddress(address)) },
        onCommitKey = { key -> onHostAction(PdshHostAction.CommitWebSearchKey(key)) },
        onClearKey = { onHostAction(PdshHostAction.ClearWebSearchKey) },
        onRemoveConfiguration = { onHostAction(PdshHostAction.RemoveWebSearchConfiguration) },
        // 什么时候生效's two engine verbs are real host commands.
        onStartEngine = { onHostAction(PdshHostAction.RestartRuntime) },
        onStopEngine = { onHostAction(PdshHostAction.StopRuntime) },
    )
}

@Composable
private fun McpRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    onNavigate: (PdshRoute) -> Unit,
) {
    var local by remember { mutableStateOf(MCPLocalState()) }
    // Discovery is foreground-only (lan-mcp.md: explicitly started by the user):
    // leaving the page stops a running scan; found candidates expire on their own.
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { onHostAction(PdshHostAction.LanScan(false)) }
    }
    MCPSettingsPage(
        state = MCPScreenState.from(facts.mcp, local),
        onAdd = { onNavigate(PdshRoute.McpEditor(null)) },
        onEdit = { id -> onNavigate(PdshRoute.McpEditor(id)) },
        onToggleServers = { local = local.apply(MCPUiEvent.ToggleServers) },
        onBack = onBack,
        // 操作's 刷新注册表 (`MCPSettingsPage.swift:87`). This host has no MCP read
        // yet, so the handoff is what it can do and the page keeps the row visible.
        onRefresh = { onHostAction(PdshHostAction.RefreshMcp) },
        // 局域网设备 (`MCPSettingsPage.swift:101`): scan/stop are host actions; a
        // candidate opens the ordinary editor pre-filled with its URL, like iOS
        // `MCPEditorPage(candidate:)`. Nothing is saved or granted by selecting it.
        lan = facts.lan,
        onLanScan = { start -> onHostAction(PdshHostAction.LanScan(start)) },
        onLanCandidate = { candidate ->
            onNavigate(PdshRoute.McpEditor(serverId = null, discoveredUrl = candidate.url))
        },
    )
}

@Composable
private fun SshEditorRoute(
    route: PdshRoute.SshEditor,
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    val connection = route.connectionId?.let { id -> facts.ssh.connections.firstOrNull { it.id == id } }
    // `key` keeps one editor state per connection: a different row never
    // inherits the previous row's typed secret.
    androidx.compose.runtime.key(route.connectionId) {
        com.phonedsh.ui.page.SSHConnectionEditor(
            connection = connection,
            facts = facts.ssh,
            onBack = onBack,
            onInspect = { id, host, port -> onHostAction(PdshHostAction.SshInspectHostKey(id, host, port)) },
            onSave = { id, draft -> onHostAction(PdshHostAction.SshSaveConnection(id, draft)) },
            onDelete = { id, connectionId -> onHostAction(PdshHostAction.SshDeleteConnection(id, connectionId)) },
        )
    }
}

@Composable
private fun BluetoothRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    androidx.compose.runtime.DisposableEffect(Unit) {
        onHostAction(PdshHostAction.BluetoothPageVisible(true))
        onDispose { onHostAction(PdshHostAction.BluetoothPageVisible(false)) }
    }
    com.phonedsh.ui.page.BluetoothDevicesPage(
        facts = facts.bluetooth,
        onBack = onBack,
        onScan = { onHostAction(PdshHostAction.BluetoothScan(it)) },
        onConnect = { onHostAction(PdshHostAction.BluetoothConnect(it)) },
        onDisconnect = { onHostAction(PdshHostAction.BluetoothDisconnect(it)) },
        onGrantRead = { id, on -> onHostAction(PdshHostAction.BluetoothGrant(id, read = on)) },
        onGrantAlert = { id, on -> onHostAction(PdshHostAction.BluetoothGrant(id, alert = on)) },
        onRead = { id, profile -> onHostAction(PdshHostAction.BluetoothRead(id, profile)) },
        onAlert = { id, level -> onHostAction(PdshHostAction.BluetoothAlert(id, level)) },
    )
}

@Composable
private fun McpEditorRoute(
    route: PdshRoute.McpEditor,
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    // A stored server this host cannot read is 未知, never an empty new-server
    // form: the editor's targetUnreadable flag is the honest statement, and the
    // page owns the wording for it.
    val editorFacts = if (route.serverId != null && facts.mcpEditor.server?.id != route.serverId) {
        facts.mcpEditor.copy(server = null, targetUnreadable = true)
    } else {
        facts.mcpEditor
    }
    var local by remember(route) { mutableStateOf(discoveredDraft(route.discoveredUrl)) }
    val state = MCPEditorScreenState.from(editorFacts, local)
    MCPEditorPage(
        state = state,
        onEditName = { value -> local = local.apply(MCPEditorUiEvent.EditName(value), editorFacts) },
        onEditCommand = { value -> local = local.apply(MCPEditorUiEvent.EditCommand(value), editorFacts) },
        onEditUrl = { value -> local = local.apply(MCPEditorUiEvent.EditUrl(value), editorFacts) },
        onSelectTransport = { transport ->
            local = local.apply(MCPEditorUiEvent.SelectTransport(transport), editorFacts)
        },
        onToggleEnabled = { enabled ->
            local = local.apply(MCPEditorUiEvent.ToggleEnabled(enabled), editorFacts)
        },
        onEditTimeout = { value ->
            local = local.apply(MCPEditorUiEvent.EditTimeout(value), editorFacts)
        },
        // 认证头与设备密钥 (`MCPSettingsPage.swift:203`): the rows are local draft
        // state, so the host applies one event per edit like every other field.
        onAddHeader = { local = local.apply(MCPEditorUiEvent.AddHeader, editorFacts) },
        onRemoveHeader = { index ->
            local = local.apply(MCPEditorUiEvent.RemoveHeader(index), editorFacts)
        },
        onEditHeaderName = { index, value ->
            local = local.apply(MCPEditorUiEvent.EditHeaderName(index, value), editorFacts)
        },
        onEditHeaderEnv = { index, value ->
            local = local.apply(MCPEditorUiEvent.EditHeaderEnv(index, value), editorFacts)
        },
        onEditHeaderValue = { index, value ->
            local = local.apply(MCPEditorUiEvent.EditHeaderValue(index, value), editorFacts)
        },
        onSubmit = { draft ->
            // The page's contract: apply Submit first, then persist only when the
            // re-projected state has no errors. This host has no save command, so
            // a valid draft is handed off; the form keeps its values either way.
            val submitted = local.apply(MCPEditorUiEvent.Submit, editorFacts)
            local = submitted
            if (MCPEditorScreenState.from(editorFacts, submitted).errors.isEmpty()) {
                onHostAction(PdshHostAction.SaveMcpServer(draft))
            }
        },
        onBack = onBack,
    )
}

/**
 * The editor's starting point for a selected LAN candidate, mirroring the iOS
 * `MCPEditorPage(candidate:)` draft: a fresh `device_<12 hex>` name, the
 * candidate's HTTPS URL, a 60 s tool timeout and an empty `Authorization` row for
 * the device credential (lan-mcp.md: the bearer credential is entered by the
 * person, never taken from discovery). `null` is the ordinary blank form.
 */
internal fun discoveredDraft(url: String?): MCPEditorLocalState {
    if (url == null) return MCPEditorLocalState()
    val suffix = java.util.UUID.randomUUID().toString().replace("-", "").take(12).lowercase()
    return MCPEditorLocalState(
        draft = com.phonedsh.ui.page.MCPServerDraft(
            name = "device_$suffix",
            transport = com.phonedsh.ui.page.MCPTransport.HTTP,
            url = url,
            toolCallTimeoutMs = "60000",
            headers = listOf(com.phonedsh.ui.page.MCPHeaderDraft(name = "Authorization")),
        ),
    )
}

@Composable
private fun RuntimeRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    backLevel: PdshBackLevel?,
) {
    var local by remember { mutableStateOf(RuntimeLocalState()) }
    // 停止引擎's confirmation is this page's own modal, and the page's 取消 already
    // dismisses it: the gesture must dismiss the same thing, not the page.
    RouteBackLevel(backLevel, local.stopConfirmationOpen) {
        local = local.apply(RuntimeUiEvent.CancelStop)
    }
    RuntimeDetailsPage(
        state = RuntimeDetailsScreenState.from(facts.runtime, local),
        onBack = onBack,
        onToggleSection = { id -> local = local.apply(RuntimeUiEvent.ToggleSection(id)) },
        onRequestStop = { local = local.apply(RuntimeUiEvent.RequestStop) },
        onCancelStop = { local = local.apply(RuntimeUiEvent.CancelStop) },
        onConfirmStop = {
            local = local.apply(RuntimeUiEvent.ConfirmStop)
            onHostAction(PdshHostAction.StopRuntime)
        },
        onRestart = { onHostAction(PdshHostAction.RestartRuntime) },
    )
}

@Composable
private fun EgressRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
) {
    var local by remember { mutableStateOf(EgressAllowListLocalState()) }
    EgressAllowListPage(
        state = EgressAllowListScreenState.from(facts.egress, local),
        onBack = onBack,
        onToggleSection = { id -> local = local.apply(EgressAllowListUiEvent.ToggleSection(id)) },
    )
}

@Composable
private fun WorkbenchRoute(
    route: PdshRoute.Workbench,
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    backLevel: PdshBackLevel?,
) {
    var local by remember(route) {
        mutableStateOf(
            WorkbenchLocalState(
                section = route.section ?: WorkbenchSection.FILES,
                previewPath = route.previewPath,
            ),
        )
    }
    // A workbench entered with a preview already on top (the home screen's write
    // row) has one level inside the sheet: closing that preview, not the sheet.
    RouteBackLevel(backLevel, local.previewPath != null) {
        local = local.apply(WorkbenchUiEvent.ClosePreview)
    }
    NativeWorkbenchPage(
        state = WorkbenchScreenState.from(facts.workbench, local),
        onSelectSection = { section -> local = local.apply(WorkbenchUiEvent.SelectSection(section)) },
        // PR #15 turned "workbench row → in-page preview" into "row → the one
        // preview face" (`ChatPage.swift:389`, `FilesPage.swift:59`), so the row
        // pushes [PdshRoute.Preview] and nothing else. The page's own
        // `WorkbenchPreview` body stays for its contract and its tests, but the app
        // no longer reaches it: one file, one surface, one back.
        //
        // This used to also apply `WorkbenchUiEvent.OpenFile` here. That made the
        // workbench project a preview *behind* the pushed one, so one tap opened two
        // previews and the back gesture landed on the inline copy instead of the
        // list. The route push is the whole edge; `onClosePreview` below still
        // serves a route that was entered with `previewPath` (the home screen's
        // write row), which is a different entry and not a second apply of this tap.
        onOpenFile = { file -> onNavigate(PdshRoute.Preview(file.path)) },
        onClosePreview = { local = local.apply(WorkbenchUiEvent.ClosePreview) },
        onDone = onBack,
    )
}

@Composable
private fun WebSurfaceRoute(
    facts: PdshNavFacts,
    onNavigate: (PdshRoute) -> Unit,
    onHome: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
    webSurface: @Composable () -> Unit,
) {
    var local by remember { mutableStateOf(WebSurfaceLocalState()) }
    WebSurfacePage(
        state = WebSurfaceScreenState.from(facts.webSurface, local),
        surface = webSurface,
        onRetry = { onHostAction(PdshHostAction.RetryWebSurface) },
        onOpenModelSettings = { onNavigate(PdshRoute.ModelProvider) },
        onNativeRecovery = onHome,
        onToggleDetails = { local = local.apply(WebSurfaceUiEvent.ToggleDetails) },
    )
}

// ------------------------------------------------------- device connector (L5)

/**
 * 设备连接: a host-supplied connector's published devices, if one exists.
 *
 * There is no Android OS discovery/connector implementation in this repository;
 * `:domain` supplies the connector/discoverer contracts and in-memory test doubles
 * only. The production default is therefore `null`, which the page renders as
 * 未接入设备连接器. A test or explicit demo must inject its source as a parameter.
 * This route never scans, pairs or fabricates an online device.
 */
@Composable
private fun DeviceConnectionRoute(
    source: DeviceConnectionSource?,
    onNavigate: (PdshRoute) -> Unit,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var local by remember { mutableStateOf(DeviceConnectionLocalState()) }
    LaunchedEffect(source) { source?.start(scope) }
    DisposableEffect(source) { onDispose { source?.stop() } }
    val snapshot = source?.snapshot?.collectAsState()?.value ?: DeviceConnectionSnapshot(
        connectorAvailable = false,
        connectorProtocol = null,
        status = ConnectorStatus.UNKNOWN,
    )
    NativeDeviceConnectionPage(
        state = DeviceConnectionScreenState.from(snapshot, local),
        onOpen = { device ->
            if (source != null) {
                local = DeviceConnectionLocalState(openingDeviceId = device.deviceId)
                scope.launch {
                    val selection = source.open(device.deviceId)
                    local = DeviceConnectionLocalState()
                    if (selection != null) onNavigate(PdshRoute.DeviceSession(selection.deviceId))
                }
            }
        },
        onForgetMapping = { deviceId -> source?.forgetMapping(deviceId) },
        onDone = onBack,
    )
}

/**
 * 设备会话: a host-supplied device's fixed session, read-only.
 *
 * When the host supplies a monitor, it reads one history window and follows the
 * live stream in this page scope; leaving cancels the follow. A route without a
 * source shows a read failure instead of a fixture transcript. Paging forwards
 * [DeviceSessionSource.loadEarlier], which owns the `beforeSeq` window and stall
 * guard.
 */
@Composable
private fun DeviceSessionRoute(
    deviceId: String,
    source: DeviceSessionSource?,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var local by remember(deviceId) { mutableStateOf(DeviceSessionLocalState()) }
    LaunchedEffect(source) { source?.start(scope) }
    DisposableEffect(source) { onDispose { source?.stop() } }
    val snapshot = source?.snapshot?.collectAsState()?.value ?: DeviceSessionSnapshot(
        deviceId = deviceId,
        sessionId = "",
        displayName = UiStrings.UNKNOWN,
        status = DeviceSessionStatus.FAILED,
        failure = DeviceSessionFailure.Read(UiStrings.DEVICE_CONNECTOR_UNAVAILABLE),
    )
    NativeDeviceSessionPage(
        state = DeviceSessionScreenState.from(snapshot, local),
        onLoadEarlier = { source?.let { session -> scope.launch { session.loadEarlier() } } },
        onToggleRow = { rowId -> local = local.toggle(rowId) },
        onBack = onBack,
    )
}

/**
 * 本 session 产物: the workspace files this session's turns wrote, plus the rest.
 *
 * The store is this host's materialized workspace
 * ([WorkspaceSessionArtifactSource]), and the attribution is the host's measured
 * fact ([SessionArtifactsFacts.writtenPaths]) — not a transcript parse and not a
 * bare directory scan (see the fact's own doc for why both fail this page's
 * subject). Read page by page until the store stops offering a cursor, exactly as
 * the baseline's `loadArtifacts` loop does.
 *
 * The open gesture resolves the path inside the workspace root, reads the first
 * text page through the same [PreviewFileSource] the preview surface uses, and asks
 * `PreviewShare` for the `content://` uri the file is shared at. A path the store
 * no longer holds reports the baseline's 文件已不在本机产物存储中 (`:168`); a
 * workspace that is not on disk yet reports the no-workspace line with a retry.
 */
@Composable
private fun SessionArtifactsRoute(
    sessionId: String,
    facts: SessionArtifactsFacts,
    workspaceRoot: File?,
    onBack: () -> Unit,
    backLevel: PdshBackLevel?,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current.applicationContext
    // The same tree the files page and the preview surface read; a host with no
    // workspace passes a path that does not exist, and the page says so.
    val root = remember(context, workspaceRoot) {
        workspaceRoot?.toPath() ?: PreviewWorkspace.defaultRoot(context.filesDir)
    }
    val source = remember(root) { WorkspaceSessionArtifactSource(root) }
    var artifacts by remember { mutableStateOf(emptyList<SessionArtifactRef>()) }
    var waiting by remember { mutableStateOf(true) }
    var failure by remember { mutableStateOf<String?>(null) }
    var openFailure by remember { mutableStateOf<String?>(null) }
    var local by remember { mutableStateOf(SessionArtifactsLocalState()) }
    // 产物预览 is a subpage of this route (`SessionArtifactsPage.swift:101`): one
    // gesture closes the preview, the next one leaves the list.
    RouteBackLevel(backLevel, local.preview != null) {
        local = SessionArtifactsLocalState()
    }

    suspend fun load() {
        waiting = true
        try {
            val loaded = mutableListOf<SessionArtifactRef>()
            var cursor = 0
            while (true) {
                val page = source.list(cursor, ARTIFACT_PAGE_SIZE)
                loaded += page.items
                val next = page.nextCursor ?: break
                cursor = next
            }
            artifacts = loaded
            failure = null
        } catch (t: Throwable) {
            // A workspace that is not there yet is not a store failure: the store
            // said exactly that, and the page's own line names it.
            failure = if (t is java.io.IOException &&
                t.message == WorkspaceSessionArtifactSource.NO_WORKSPACE_REASON
            ) {
                UiStrings.ARTIFACTS_NO_WORKSPACE
            } else {
                UiStrings.ARTIFACTS_LOAD_FAILED.format(t.message ?: "")
            }
        } finally {
            waiting = false
        }
    }

    LaunchedEffect(sessionId, source, facts) { load() }
    val state = SessionArtifactsScreenState.fromWorkspace(
        artifacts = artifacts,
        facts = facts,
        local = local,
        waiting = waiting,
        failure = failure,
    )
    SessionArtifactsPage(
        state = SessionArtifactsScreenState.withOpenFailure(state, openFailure),
        onOpen = { artifact ->
            local = SessionArtifactsLocalState(openingId = artifact.artifactId)
            scope.launch {
                val file = runCatching { source.fileFor(artifact.artifactId) }.getOrNull()
                val content = runCatching { source.content(artifact.artifactId) }.getOrNull()
                // A file the store still holds opens the preview subpage
                // (`SessionArtifactsPage.swift:101`, `:296`); one it does not is the
                // baseline's 文件已不在本机产物存储中 alert (`:168`).
                local = if (file != null) {
                    SessionArtifactsLocalState(
                        preview = SessionArtifactPreview(
                            artifact = artifact,
                            contentUri = PreviewShare.uriFor(context, file)?.toString(),
                            text = content?.text,
                            loadedBytes = content?.loadedBytes,
                            totalBytes = content?.totalBytes ?: artifact.byteCount,
                        ),
                    )
                } else {
                    SessionArtifactsLocalState()
                }
                openFailure = if (file != null) null else UiStrings.ARTIFACTS_MISSING_FILE
            }
        },
        onDone = onBack,
        onRetry = { scope.launch { load() } },
        onDismissOpenFailure = { openFailure = null },
        onClosePreview = { local = SessionArtifactsLocalState() },
        // The real share: the provider grants the receiving app read access to the
        // one file through the uri the preview already carries, so the workspace
        // stays app-private and no `file://` uri is ever exposed.
        onShare = { preview ->
            val uri = preview.contentUri?.let(Uri::parse)
            if (uri == null) {
                false
            } else {
                PreviewShare.start(
                    context,
                    PreviewShare.intentFor(
                        uri = uri,
                        mime = PreviewShare.mimeOf(preview.artifact.name),
                        title = UiStrings.ARTIFACTS_PREVIEW_SHARE_CHOOSER,
                    ),
                )
            }
        },
    )
}

/** The artifact read's page size; the store double caps it as well. */
private const val ARTIFACT_PAGE_SIZE: Int = 50

/** The one scrim opacity the sheet frame uses; no token publishes one. */
private const val SHEET_SCRIM_ALPHA: Float = 0.32f

// ------------------------------------------------------------- sessions route

/**
 * 会话: the sessions family's list face (`SessionsPage`).
 *
 * It is [PdshRoute]'s one subtype declared outside `PdshRoute.kt`. A sealed
 * interface requires its subtypes to share the *package*, not the file, and that
 * file belongs to the shell lane while this page lands; moving this declaration
 * into `PdshRoute.kt` is a cut-and-paste once the shell lane's edits settle.
 */
/**
 * The sessions list.
 *
 * The router has no session-list field in [PdshNavFacts] yet (the probe app reads
 * its rows through `HostSessionsScreen`), so the only host fact this route can
 * hand the page is the folder list; the session list is therefore reported as
 * empty rather than invented. A host that reports folders then renders one section
 * per folder with the baseline's 还没有会话 copy; a host that reports an empty
 * folder list renders the big empty block; a host that reports no folder list at
 * all renders 工作文件夹状态未知, which is the honest reading of an unmeasured list
 * and the state the default `PdshNavFacts()` produces.
 *
 * No clock is read here: with no row there is no timestamp to render, and a clock
 * in the router would make the route unreplayable (`spec/ui/v1/README.md` §3.1).
 * The two write gestures the host cannot perform (create a session, create a
 * folder) are dropped on purpose instead of being reported as success.
 */
@Composable
private fun SessionsRoute(facts: PdshNavFacts, onBack: () -> Unit) {
    var local by remember { mutableStateOf(SessionsLocalState()) }
    val folders = facts.workspaceFolders.folders
    SessionsPage(
        state = SessionsScreenState.from(
            sessions = emptyList<SessionListing>(),
            local = local,
            nowMs = 0L,
            zone = java.time.ZoneOffset.UTC,
            failure = facts.workspaceFolders.failure,
            workspaces = folders?.map { folder ->
                // The host reports a folder's own count, not its membership: the
                // page's group count is the filtered row count, so it stays 0 here.
                SessionWorkspace(id = folder.id, title = folder.name)
            },
            archivedSessions = null,
            newSessionBlock = null,
            languageId = facts.settings.preferences.language?.id,
        ),
        onSelect = {},
        onQueryChange = { query -> local = local.copy(query = query) },
        onRenameStart = {},
        onRenameDraftChange = {},
        onRenameCommit = {},
        onRenameCancel = {},
        onNewSession = {},
        onBack = onBack,
        onToggleWorkspace = { workspace ->
            local = local.copy(
                collapsedWorkspaceIDs = if (workspace.id in local.collapsedWorkspaceIDs) {
                    local.collapsedWorkspaceIDs - workspace.id
                } else {
                    local.collapsedWorkspaceIDs + workspace.id
                },
            )
        },
        onWorkspaceMenuToggle = { workspace ->
            local = local.copy(
                workspaceMenuID = if (local.workspaceMenuID == workspace.id) null else workspace.id,
            )
        },
        onAddWorkspace = {},
        onToggleArchived = { local = local.copy(showArchived = !local.showArchived) },
    )
}

// ------------------------------------------------------ L14: the B-group pages
//
// The settings sheet's 插件 / 手机权限 / 预设 tabs are these same three pages, and
// `SettingsPage` already takes a `tabContent` slot for them
// (`SettingsPage.swift:82-90`). Passing it belongs to the shell lane: the five-tab
// `SettingsPage` is that lane's file, so this lane declares the routes and the
// pages' `embedded` form and leaves the slot wiring to whoever owns the shell.

/**
 * Agent 预设: the preset roster, its read-only document panel and the two host
 * handoffs (create a session with one preset, read one preset's YAML).
 *
 * The roster is `null` until `agentPresets/list` answers — the page's 未知 line,
 * never an invented empty engine. The route starts that one read when it enters
 * and again on 重新读取; the read itself is the host's (IO, in `:app`), so a
 * composition never touches the channel.
 *
 * 使用预设 creates a new session through `session/create` with
 * `request.agentPreset`; the host closes the settings sheet on success, so this
 * route only leaves the failure text behind on the page. 查看配置 replaces the
 * old static failure: the host's `agentPresets/read` content opens the panel and
 * its `code: message` stays in the error line on failure.
 *
 * 让 Agent 创建预设 keeps the existing NEW_SESSION dispatch (the in-flight
 * creator fix owns the creator semantics); this route only disables it and states
 * the reason when the roster says the `cordis` preset is absent or broken.
 *
 * @param onBack close the sheet, or the 完成 of the document panel.
 * @param facts the host's `agentPresets/list` reading.
 * @param actions the host's refresh/read/use handoffs.
 * @param embedded render as the settings sheet's 预设 tab body.
 */
@Composable
private fun AgentPresetsRoute(
    onBack: () -> Unit,
    facts: NativeAgentPresetsFacts = NativeAgentPresetsFacts(),
    actions: AgentPresetActions = AgentPresetActions(),
    actionAvailability: PdshActionAvailabilities = PdshActionAvailabilities(),
    embedded: Boolean = false,
) {
    var local by remember { mutableStateOf(NativeAgentPresetsLocalState()) }
    // The page keeps one error line for both the roster read and a row verb
    // (`NativeAgentPresetsPage.swift:20`). This local value is the verb's answer;
    // the list's own failure lives in [facts].
    var verbError by remember { mutableStateOf<String?>(null) }
    var openingPresetId by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { actions.refresh() }
    val createAvailability = actionAvailability.forAction(PdshActionKey.NEW_SESSION)
    val creator = facts.presets?.firstOrNull { it.id == "cordis" }
    val creatorUnavailableReason = when {
        // While the first read is in flight the creator is disabled by `loading`,
        // not by an invented "no preset" judgement.
        facts.isLoading && facts.presets == null -> null
        creator == null -> UiStrings.AGENT_PRESETS_CREATOR_MISSING
        creator.broken != null -> creator.broken
        else -> null
    }
    NativeAgentPresetsPage(
        state = NativeAgentPresetsScreenState.from(
            facts = facts.copy(error = verbError ?: facts.error),
            local = local,
        ),
        onBack = onBack,
        // iOS `startCreator` opens a new chat and sends nothing. This route owns
        // no session store, so it dispatches the same typed NEW_SESSION action the
        // drawer uses; the host creates the conversation and lands on the chat
        // page with the existing draft untouched.
        onCreate = {
            if (creatorUnavailableReason == null) {
                when (createAvailability) {
                    is PdshActionAvailability.Unavailable ->
                        verbError = UiStrings.AGENT_PRESETS_CREATE_UNAVAILABLE
                    is PdshActionAvailability.Available -> {
                        verbError = null
                        val dispatched = actionAvailability.dispatch(
                            PdshActionKey.NEW_SESSION,
                            PdshUiHostCommand.NewSession(StateRequestId("ui.presets.create.${UUID.randomUUID()}")),
                        )
                        if (!dispatched) verbError = UiStrings.AGENT_PRESETS_CREATE_UNAVAILABLE
                    }
                }
            }
        },
        onViewConfiguration = { id ->
            val read = actions.read
            if (read == null) {
                verbError = NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE
            } else {
                scope.launch {
                    val outcome = read(id)
                    val document = outcome.document
                    if (document == null) {
                        verbError = outcome.failure
                            ?: NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE
                    } else {
                        verbError = null
                        local = local.apply(NativeAgentPresetsUiEvent.OpenDocument(document))
                    }
                }
            }
        },
        onUsePreset = { id ->
            val use = actions.use
            if (use == null) {
                verbError = NativeAgentPresetsScreenState.NO_WRITABLE_DEFAULT_FAILURE
            } else if (openingPresetId == null) {
                openingPresetId = id
                scope.launch {
                    val failure = try {
                        use(id)
                    } finally {
                        openingPresetId = null
                    }
                    verbError = failure
                }
            }
        },
        onReload = {
            verbError = null
            actions.refresh()
        },
        onCloseDocument = { local = local.apply(NativeAgentPresetsUiEvent.CloseDocument) },
        creatorUnavailableReason = creatorUnavailableReason,
        openingPresetId = openingPresetId,
        embedded = embedded,
    )
}

/**
 * 内置插件: the read-only loader inventory.
 *
 * The rows come from the host's one plugin read — `ConfigurationFacts`, the same
 * snapshot the 插件配置 page renders — so the inventory and the page it links to
 * can never disagree. A host that reported no snapshot leaves `plugins == null`
 * and the page says 未知.
 *
 * @param facts the host snapshot.
 * @param onBack pop the page.
 * @param onNavigate 插件配置 pushes the configuration page, the baseline's own
 *   `NavigationLink { NativeConfigurationPage() }` (`NativePluginInventoryPage.swift:19`).
 * @param embedded render as the settings sheet's 插件 tab body.
 */
@Composable
private fun PluginInventoryRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    onRefresh: (() -> Unit)? = null,
    embedded: Boolean = false,
) {
    var local by remember { mutableStateOf(PluginInventoryLocalState()) }
    val snapshot = facts.configuration.snapshot
    NativePluginInventoryPage(
        state = PluginInventoryScreenState.from(
            facts = PluginInventoryFacts(
                plugins = snapshot?.plugins,
                isLoading = facts.configuration.loading,
                failure = snapshot?.inventoryFailure ?: facts.configuration.failure,
                managementNotice = snapshot?.pluginManagementMessage,
            ),
            local = local,
        ),
        onOpenConfiguration = { onNavigate(PdshRoute.Configuration) },
        onQueryChange = { query -> local = local.apply(PluginInventoryUiEvent.SetQuery(query)) },
        onToggleRow = { id -> local = local.apply(PluginInventoryUiEvent.ToggleRow(id)) },
        onBack = onBack,
        onRefresh = onRefresh,
        embedded = embedded,
    )
}

@Composable
private fun PhonePermissionsRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    embedded: Boolean = false,
    backLevel: PdshBackLevel? = null,
    onRequestPermission: (PhoneCapability) -> Unit = {},
    onOpenPermissionSettings: (PhoneCapability) -> Unit = {},
) {
    var local by remember { mutableStateOf(PhonePermissionsLocalState()) }
    // The request confirmation and the disable notice are this page's own modals:
    // back dismisses the modal, exactly like the page's 取消 / 知道了, instead of
    // closing the page under it.
    RouteBackLevel(
        backLevel = backLevel,
        enabled = local.confirmation != null || local.disableNotice != null,
        onBack = {
            local = if (local.confirmation != null) {
                local.apply(PhonePermissionsUiEvent.CancelConfirmation)
            } else {
                local.apply(PhonePermissionsUiEvent.AcknowledgeDisable)
            }
        },
    )
    // The read is the host's, not this route's: the composition root walks its own
    // permissions into `PdshNavFacts.phonePermissions` (`:domain`'s
    // `AndroidHostPermissions` + `AndroidDeviceCapabilities.platformFacts`), and this
    // route only projects. A host that read nothing keeps the default facts
    // (`statuses == null`): every row says 未知 and no control is armed, which is the
    // honest face of an unread permission. The one thing this route must never do is
    // fill that gap with 已允许.
    val projected = PhonePermissionsScreenState.from(facts.phonePermissions, local)
    // Two actions are disarmed here with the reason visible in the row's status
    // line, because this host cannot give them a real effect:
    //
    //  * CONFIRM_BIOMETRIC: the baseline gesture runs a system biometric prompt
    //    (iOS `confirmBiometricWrite`); this AAR has no such prompt wired into the
    //    route, and the row's switch would stay off even after an acknowledgement.
    //  * ENABLE: iOS writes `PhonePermissionStore.isEnabled`, which
    //    `PhoneCapabilityGate` checks before tool use. This host has no
    //    capability-enable store and no gate (`HostPhonePermissions.kt`: "This host
    //    has no capability-enable store"), so an armed switch would not change what
    //    the Agent may do. The system grant is the whole decision here.
    //
    // The page already disables a BLOCKED row's tap and switch, so this is one
    // projection, not a second control path.
    val state = projected.copy(
        groups = projected.groups.map { group ->
            group.copy(
                rows = group.rows.map { row ->
                    when (row.action) {
                        PhoneCapabilityAction.CONFIRM_BIOMETRIC -> row.copy(
                            action = PhoneCapabilityAction.BLOCKED,
                            statusLabel = UiStrings.PHONE_PERMISSIONS_BIOMETRIC_UNAVAILABLE,
                            tone = com.phonedsh.ui.page.PhoneStatusTone.SECONDARY,
                        )
                        PhoneCapabilityAction.ENABLE -> row.copy(
                            action = PhoneCapabilityAction.BLOCKED,
                            statusLabel = UiStrings.PHONE_PERMISSIONS_APP_SWITCH_UNAVAILABLE,
                            tone = com.phonedsh.ui.page.PhoneStatusTone.SECONDARY,
                        )
                        else -> row
                    }
                },
            )
        },
    )
    fun rowFor(capability: PhoneCapability): PhoneCapabilityRowState? =
        state.groups.asSequence().flatMap { it.rows }.firstOrNull { it.capability == capability }
    // One activation path for the row tap and the switch's on position. 请求
    // confirms the purpose first, and a row whose only repair is the settings page
    // opens it (the baseline's `activate()` does the same for `.denied`). ENABLE is
    // not handled: nothing on this host toggles capability use, so the projection
    // above has already disarmed it. BLOCKED / ALWAYS_ON rows are neither tappable
    // nor switchable, and the page disables both controls for them.
    fun activate(capability: PhoneCapability) {
        when (rowFor(capability)?.action) {
            PhoneCapabilityAction.REQUEST ->
                local = local.apply(PhonePermissionsUiEvent.Confirm(capability))
            PhoneCapabilityAction.OPEN_SETTINGS -> onOpenPermissionSettings(capability)
            else -> Unit
        }
    }
    PhonePermissionsPage(
        state = state,
        onDone = onBack,
        onTapCapability = ::activate,
        // The projection above disarms every ENABLE row on this host, so a checked
        // switch cannot currently reach the off branch. It stays because the page's
        // toggle contract still defines the off position as its disable notice.
        onToggleCapability = { capability, value ->
            if (value) activate(capability)
            else local = local.apply(PhonePermissionsUiEvent.NotifyDisabled(capability))
        },
        // 去系统设置 opens the page that holds this capability's grant: the same host
        // gesture as a 继续 on a row that has no prompt to raise.
        onOpenSettings = onOpenPermissionSettings,
        // 继续 is a real request, not a dismissal: the purpose has been shown, and
        // the host raises the system prompt (or the settings page when no prompt
        // exists). The confirmation closes first so the platform's own dialog is
        // the only thing on screen; the row's new state comes from the host's next
        // read, never from this callback.
        onConfirmRequest = {
            val capability = local.confirmation
            local = local.apply(PhonePermissionsUiEvent.CancelConfirmation)
            if (capability != null) onRequestPermission(capability)
        },
        onCancelConfirmation = { local = local.apply(PhonePermissionsUiEvent.CancelConfirmation) },
        onAcknowledgeDisable = { local = local.apply(PhonePermissionsUiEvent.AcknowledgeDisable) },
        onDismissDisable = { local = local.apply(PhonePermissionsUiEvent.AcknowledgeDisable) },
        embedded = embedded,
    )
}

// ------------------------------------------------- L13: the three page routes

/**
 * 聊天外观: the appearance / font-size / process-collapse sheet.
 *
 * The values are the host's one preference read — `PdshNavFacts.settings.preferences`,
 * the same snapshot the settings index's 通用 tab draws — and the write capability
 * is [preferencesWritable], the host's own preference-store capability. It used to
 * read `ConfigurationSnapshot.settingsWritable`, which is the session-config page's
 * fact: a host that owns a preference store but no session-config write would have
 * had its appearance controls disabled for the wrong reason. The two capabilities
 * are separate on purpose.
 *
 * Every control hands its row id and the chosen value back through
 * [onPreferenceWrite]; the host writes and re-reads, so the page still never
 * mutates its facts. The steppers report the *new* size as decimal text, with the
 * same `preference.fontSize.*` row ids the index's 字号大小 row owns.
 */
@Composable
private fun ChatPreferencesRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    preferencesWritable: FactState,
    onPreferenceWrite: (SettingsPreferenceChoice) -> Unit,
) {
    ChatPreferencesPage(
        state = ChatPreferencesScreenState.from(
            ChatPreferencesFacts.from(
                preferences = facts.settings.preferences,
                writable = preferencesWritable,
            ),
        ),
        onSelectAppearance = { appearance ->
            onPreferenceWrite(
                SettingsPreferenceChoice(
                    rowId = SettingsScreenState.APPEARANCE_ROW_ID,
                    optionId = appearance.id,
                ),
            )
        },
        onSelectCollapseTiming = { timing ->
            onPreferenceWrite(
                SettingsPreferenceChoice(
                    rowId = SettingsScreenState.COLLAPSE_TIMING_ROW_ID,
                    optionId = timing.id,
                ),
            )
        },
        onSelectTranscriptView = { view ->
            onPreferenceWrite(
                SettingsPreferenceChoice(
                    rowId = SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID,
                    optionId = view.id,
                ),
            )
        },
        onSetTextFontSize = { size ->
            onPreferenceWrite(
                SettingsPreferenceChoice(
                    rowId = SettingsScreenState.TEXT_FONT_SIZE_ROW_ID,
                    optionId = size.toString(),
                ),
            )
        },
        onSetCodeFontSize = { size ->
            onPreferenceWrite(
                SettingsPreferenceChoice(
                    rowId = SettingsScreenState.CODE_FONT_SIZE_ROW_ID,
                    optionId = size.toString(),
                ),
            )
        },
        onDone = onBack,
    )
}

/**
 * 配置文件: the redacted settings document, read-only.
 *
 * `PdshNavFacts` carries no settings document and this host has no share command,
 * so the page renders its 读取不到脱敏配置 state and keeps the share glyph
 * disabled. No document text is invented and no share is claimed.
 */
@Composable
private fun SettingsDocumentRoute(onBack: () -> Unit) {
    NativeSettingsDocumentPage(
        state = SettingsDocumentScreenState.from(SettingsDocumentFacts()),
        onShare = null,
        onDone = onBack,
    )
}

/**
 * 快捷键: the shortcut reference.
 *
 * This host has no shortcut store, so `NativeShortcutsFacts()` reports
 * `overrides == null`: every value renders 未知 instead of the baseline's
 * defaults, and 恢复全部默认 stays disabled. The page's own footnote says the
 * host owns the bindings — the route adds no second claim.
 */
@Composable
private fun ShortcutsRoute(onBack: () -> Unit) {
    NativeShortcutsPage(
        state = NativeShortcutsScreenState.from(NativeShortcutsFacts()),
        onResetAll = {},
        onBack = onBack,
    )
}
