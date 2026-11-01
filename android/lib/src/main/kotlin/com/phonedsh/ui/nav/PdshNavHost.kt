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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import com.phonedsh.ui.page.AutomationLocalState
import com.phonedsh.ui.page.AutomationScreenState
import com.phonedsh.ui.page.AutomationUiEvent
import com.phonedsh.ui.page.ConfigurationLocalState
import com.phonedsh.ui.page.ConfigurationScreenState
import com.phonedsh.ui.page.ConfigurationUiEvent
import com.phonedsh.ui.page.EgressAllowListLocalState
import com.phonedsh.ui.page.EgressAllowListPage
import com.phonedsh.ui.page.EgressAllowListScreenState
import com.phonedsh.ui.page.EgressAllowListUiEvent
import com.phonedsh.ui.page.ExportFacts
import com.phonedsh.ui.page.ExportPage
import com.phonedsh.ui.page.ExportScreenState
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
import com.phonedsh.ui.page.NativeAutomationPage
import com.phonedsh.ui.page.NativeConfigurationPage
import com.phonedsh.ui.page.NativeWorkbenchPage
import com.phonedsh.ui.page.PermissionDefaultsPage
import com.phonedsh.ui.page.PermissionDefaultsState
import com.phonedsh.ui.page.RuntimeDetailsPage
import com.phonedsh.ui.page.RuntimeDetailsScreenState
import com.phonedsh.ui.page.RuntimeLocalState
import com.phonedsh.ui.page.RuntimeUiEvent
import com.phonedsh.ui.page.SettingsDestination
import com.phonedsh.ui.page.ShellLocalState
import com.phonedsh.ui.page.ShellSnapshot
import com.phonedsh.ui.page.ShellUiEvent
import com.phonedsh.ui.page.SettingsPage
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.ToolsPage
import com.phonedsh.ui.page.ToolsScreenState
import com.phonedsh.ui.page.apply
import com.phonedsh.ui.page.WebSearchLocalState
import com.phonedsh.ui.page.WebSearchScreenState
import com.phonedsh.ui.page.WebSearchSettingsPage
import com.phonedsh.ui.page.WebSearchUiEvent
import com.phonedsh.ui.page.WebSurfaceLocalState
import com.phonedsh.ui.page.WebSurfacePage
import com.phonedsh.ui.page.WebSurfaceScreenState
import com.phonedsh.ui.page.WebSurfaceUiEvent
import com.phonedsh.ui.page.WorkbenchLocalState
import com.phonedsh.ui.page.WorkbenchScreenState
import com.phonedsh.ui.page.WorkbenchSection
import com.phonedsh.ui.page.WorkbenchUiEvent
import com.phonedsh.ui.page.WorkspaceFoldersLocalState
import com.phonedsh.ui.page.WorkspaceFoldersPage
import com.phonedsh.ui.page.WorkspaceFoldersScreenState
import com.phonedsh.ui.page.WorkspaceFoldersUiEvent
import com.phonedsh.ui.theme.LocalUiTokens

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
    onSettingsWrite: (SettingsWrite) -> Unit = {},
) {
    val route = nav.current
    if (route == PdshRoute.Home) {
        home()
        return
    }
    RouteSurface(route.presentation) {
        when (route) {
            PdshRoute.Home -> Unit // rendered above; kept for the exhaustive when
            PdshRoute.WorkspaceFolders -> WorkspaceFoldersRoute(facts, onBack, onHostAction)
            PdshRoute.Automation -> AutomationRoute(facts, onBack)
            PdshRoute.Configuration -> ConfigurationRoute(facts, onBack, onNavigate)
            PdshRoute.Settings -> SettingsRoute(facts, onBack, onNavigate, onSettingsWrite)
            PdshRoute.ModelProvider -> ModelProviderRoute(facts, onBack, onHostAction)
            PdshRoute.WebSearch -> WebSearchRoute(facts, onBack, onHostAction)
            PdshRoute.Mcp -> McpRoute(facts, onBack, onNavigate)
            is PdshRoute.McpEditor -> McpEditorRoute(route, facts, onBack, onHostAction)
            PdshRoute.Runtime -> RuntimeRoute(facts, onBack, onHostAction)
            PdshRoute.Egress -> EgressRoute(facts, onBack)
            PdshRoute.Tools -> ToolsRoute(onBack)
            PdshRoute.Export -> ExportRoute(onBack)
            is PdshRoute.Workbench -> WorkbenchRoute(route, facts, onBack, onHostAction)
            PdshRoute.WebSurface -> WebSurfaceRoute(facts, onNavigate, onHome, onHostAction, webSurface)
        }
    }
}

/**
 * The modal frame around a non-home route.
 *
 * PUSH and FULLSCREEN pages cover the screen. A SHEET keeps a strip of the page
 * below visible and rounds its own top edge, so the modal form §1 names is
 * visible rather than only behavioural. No sheet geometry token exists, so the
 * strip reuses `geometry.cardOuterMarginV` and the radius reuses `radius.card`;
 * both are marked unverified at this call site.
 */
@Composable
private fun RouteSurface(presentation: PdshPresentation, content: @Composable () -> Unit) {
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

@Composable
private fun WorkspaceFoldersRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    var local by remember { mutableStateOf(WorkspaceFoldersLocalState()) }
    WorkspaceFoldersPage(
        state = WorkspaceFoldersScreenState.from(facts.workspaceFolders, local),
        onBack = onBack,
        // §1: every row opens the files page; this host has no file-read command
        // yet, so the gesture is handed to the composition root instead of being
        // silently dropped.
        onOpenFiles = { folder -> onHostAction(PdshHostAction.OpenWorkspaceFiles(folder.id)) },
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
    )
}

@Composable
private fun AutomationRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
) {
    var local by remember { mutableStateOf(AutomationLocalState()) }
    NativeAutomationPage(
        state = AutomationScreenState.from(facts.automation, local),
        onBack = onBack,
        onOpenDetail = { id -> local = local.apply(AutomationUiEvent.OpenDetail(id)) },
        onOpenHistory = { id -> local = local.apply(AutomationUiEvent.OpenHistory(id)) },
        onBackToCatalog = { local = local.apply(AutomationUiEvent.Back) },
    )
}

@Composable
private fun ConfigurationRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
) {
    var local by remember { mutableStateOf(ConfigurationLocalState()) }
    NativeConfigurationPage(
        state = ConfigurationScreenState.from(facts.configuration, local),
        onDone = onBack,
        onToggleSection = { id -> local = local.apply(ConfigurationUiEvent.ToggleSection(id)) },
        onOpenWebSearch = { onNavigate(PdshRoute.WebSearch) },
    )
}

/**
 * 命令: the read-only accelerator shell.
 *
 * The host has no shell snapshot yet (`ShellSnapshot()` is empty), so the page shows
 * its 还没接上命令 body rather than an invented command list. The run form is local
 * UI state; running a command needs a host command this build does not have, so the
 * two run gestures are handed to an empty receiver and the page's own guard keeps
 * the button disabled while nothing is linked.
 */
@Composable
private fun ToolsRoute(onBack: () -> Unit) {
    var local by remember { mutableStateOf(ShellLocalState()) }
    ToolsPage(
        state = ToolsScreenState.from(ShellSnapshot(), local),
        onSelectCommand = { name -> local = local.apply(ShellUiEvent.SelectCommand(name)) },
        onWorkingDirectoryChange = { value ->
            local = local.apply(ShellUiEvent.SetWorkingDirectory(value))
        },
        onArgumentsChange = { value -> local = local.apply(ShellUiEvent.SetArguments(value)) },
        onRun = {},
        onCancel = {},
        onBack = onBack,
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
    ExportPage(
        state = ExportScreenState.from(ExportFacts()),
        onBack = onBack,
        onWrite = {},
    )
}

@Composable
private fun SettingsRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    onSettingsWrite: (SettingsWrite) -> Unit,
) {
    // 新会话默认权限 is the settings sheet's own child page in the baseline, so it
    // is a local page swap here, not a route the stack owns.
    var permissionDefaults by remember { mutableStateOf(false) }
    // The mirrored index reads `settings`, appendix included: the facts are one
    // value, and the host fills the platform rows where it measures them.
    val settings = facts.settings
    if (permissionDefaults) {
        PermissionDefaultsPage(
            state = PermissionDefaultsState.from(settings.defaultPermissionTier),
            onSelect = { tier -> onSettingsWrite(SettingsWrite.DefaultPermissionTier(tier)) },
            onBack = { permissionDefaults = false },
        )
    } else {
        SettingsPage(
            state = SettingsScreenState.from(settings),
            onNavigate = { destination ->
                if (destination == SettingsDestination.PERMISSION_DEFAULTS) {
                    permissionDefaults = true
                } else {
                    PdshSettingsRows.targetOf(destination)?.let(onNavigate)
                }
            },
            onToggleBackgroundKeepAlive = { value ->
                onSettingsWrite(SettingsWrite.BackgroundKeepAlive(value))
            },
            onSelectBusyEnterMode = { mode -> onSettingsWrite(SettingsWrite.BusyEnter(mode)) },
            onBack = onBack,
        )
    }
}

@Composable
private fun ModelProviderRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    var local by remember { mutableStateOf(ModelProviderLocalState()) }
    ModelProviderSettingsPage(
        state = ModelProviderScreenState.from(facts.modelProvider, local),
        onAdd = { onHostAction(PdshHostAction.OpenProviderEditor(null)) },
        onEdit = { id -> onHostAction(PdshHostAction.OpenProviderEditor(id)) },
        onToggleSection = { id -> local = local.apply(ModelProviderUiEvent.ToggleSection(id)) },
        onBack = onBack,
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
    )
}

@Composable
private fun McpRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
) {
    var local by remember { mutableStateOf(MCPLocalState()) }
    MCPSettingsPage(
        state = MCPScreenState.from(facts.mcp, local),
        onAdd = { onNavigate(PdshRoute.McpEditor(null)) },
        onEdit = { id -> onNavigate(PdshRoute.McpEditor(id)) },
        onToggleServers = { local = local.apply(MCPUiEvent.ToggleServers) },
        onBack = onBack,
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
    var local by remember(route) { mutableStateOf(MCPEditorLocalState()) }
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

@Composable
private fun RuntimeRoute(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    onHostAction: (PdshHostAction) -> Unit,
) {
    var local by remember { mutableStateOf(RuntimeLocalState()) }
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
) {
    var local by remember(route) {
        mutableStateOf(
            WorkbenchLocalState(
                section = route.section ?: WorkbenchSection.FILES,
                previewPath = route.previewPath,
            ),
        )
    }
    NativeWorkbenchPage(
        state = WorkbenchScreenState.from(facts.workbench, local),
        onSelectSection = { section -> local = local.apply(WorkbenchUiEvent.SelectSection(section)) },
        onOpenFile = { file ->
            local = local.apply(WorkbenchUiEvent.OpenFile(file.path))
            onHostAction(PdshHostAction.OpenWorkbenchFile(file.path))
        },
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

/** The one scrim opacity the sheet frame uses; no token publishes one. */
private const val SHEET_SCRIM_ALPHA: Float = 0.32f
