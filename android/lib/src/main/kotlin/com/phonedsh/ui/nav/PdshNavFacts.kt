// The host's read-only snapshot of every routed page, plus the write handoffs.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §3.1 rule 3 — a page with no harness event anchor
// takes the host's read-only snapshot as its UiState-side input, and the page
// itself never reads the clock, the network or the engine. This file is that
// snapshot: one field per page, every field defaulting to "not reported".
//
// The default value of each field is the honest one for a host that cannot read
// it. `null` or an empty facts object makes the page render its 未知 / EMPTY
// state; it never becomes `0`, `emptyList()` or a fabricated success. A host
// fills a field only from a measurement it actually made.
//
// [PdshHostAction] is the other direction. This host implements no settings
// write, no folder mutation and no MCP save (§1 names no such command), so the
// router hands those gestures back as an action. The Android host logs the
// handoff and performs only the three actions it really owns (engine stop,
// engine start/restart, Web-surface retry). A page is never told a write
// succeeded: the facts only change when a real read reports a new value.
package com.phonedsh.ui.nav

import androidx.compose.runtime.Immutable
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.EgressAllowListFacts
import com.phonedsh.ui.page.MCPEditorFacts
import com.phonedsh.ui.page.MCPRegistryFacts
import com.phonedsh.ui.page.MCPServerDraft
import com.phonedsh.ui.page.ModelProviderFacts
import com.phonedsh.ui.page.PermissionTier
import com.phonedsh.ui.page.RuntimeFacts
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.WebSearchFacts
import com.phonedsh.ui.page.WebSurfaceFacts
import com.phonedsh.ui.page.WorkbenchSnapshot
import com.phonedsh.ui.page.WorkspaceFoldersSnapshot

/**
 * One gesture a settings page made that this host cannot persist.
 *
 * The mirrored settings index (`spec/ui/v1/README.md` §1 `SettingsPage`) owns three
 * write gestures: the 后台运行 switch, the 发送消息时 menu and the 新会话默认权限
 * preset. This host implements no settings write, so the router hands each one
 * back through [PdshNavHost]'s `onSettingsWrite` seam instead of pretending the
 * facts changed. Every write is token-free: a boolean, a mode id or a preset.
 */
public sealed interface SettingsWrite {
    /** The stable, token-free label a host may log. */
    public val wire: String

    /** 后台运行: keep running while the screen is locked or the app is in the background. */
    public data class BackgroundKeepAlive(public val value: Boolean) : SettingsWrite {
        override val wire: String = "settings.background"
    }

    /** 发送消息时: queue the message or steer the running task. */
    public data class BusyEnter(public val mode: BusyEnterMode) : SettingsWrite {
        override val wire: String = "settings.busy-enter"
    }

    /** 新会话默认权限: the preset new sessions start with. */
    public data class DefaultPermissionTier(public val tier: PermissionTier) : SettingsWrite {
        override val wire: String = "settings.permission-tier"
    }
}

/**
 * Every page's read-only input, in one value.
 *
 * @param workspaceFolders the folder list; the default reports no list (未知).
 * @param workbench the current turn's tool output; the default reports nothing.
 * @param modelProvider the configured services; the default reports no read.
 * @param webSearch the search switch and backends; the default is all 未知.
 * @param mcp the MCP registry; the default reports no list.
 * @param mcpEditor the stored server the editor opens on; the default is a new
 *   server form (nothing is stored).
 * @param runtime the engine/runtime snapshot; the default reports no read.
 * @param egress the effective allow list; the default reports no list.
 * @param automation the schedules; the default reports no list.
 * @param configuration the session/plugin configuration; no read by default.
 * @param webSurface the engine/WebView/page facts; no read by default.
 * @param settings the mirrored settings index's row values, one field per row,
 *   including the platform appendix.
 */
@Immutable
public data class PdshNavFacts(
    public val workspaceFolders: WorkspaceFoldersSnapshot = WorkspaceFoldersSnapshot(),
    public val workbench: WorkbenchSnapshot = WorkbenchSnapshot(),
    public val modelProvider: ModelProviderFacts = ModelProviderFacts(),
    public val webSearch: WebSearchFacts = WebSearchFacts(),
    public val mcp: MCPRegistryFacts = MCPRegistryFacts(),
    public val mcpEditor: MCPEditorFacts = MCPEditorFacts(),
    public val runtime: RuntimeFacts = RuntimeFacts(),
    public val egress: EgressAllowListFacts = EgressAllowListFacts(),
    public val automation: AutomationFacts = AutomationFacts(),
    public val configuration: ConfigurationFacts = ConfigurationFacts(),
    public val webSurface: WebSurfaceFacts = WebSurfaceFacts(),
    public val settings: SettingsFacts = SettingsFacts(),
)

/**
 * One gesture this host cannot complete itself, handed to the composition root.
 *
 * Every action is token-free: no action carries a prompt, a credential or a
 * command line the host did not already own. [wire] is the stable label the host
 * logs, so an acceptance run can prove the handoff happened without quoting user
 * content.
 */
public sealed interface PdshHostAction {
    /** The stable, token-free label a host may log. */
    public val wire: String

    /** Create a workspace folder from the typed name (not logged). */
    public data class WorkspaceCreate(public val name: String) : PdshHostAction {
        override val wire: String = "workspace.create"
    }

    /** Make a folder current. */
    public data class WorkspaceSwitch(public val id: String) : PdshHostAction {
        override val wire: String = "workspace.switch"
    }

    /** Delete a folder after its confirmation. */
    public data class WorkspaceDelete(public val id: String) : PdshHostAction {
        override val wire: String = "workspace.delete"
    }

    /** A folder row asked for its file listing (the files page). */
    public data class OpenWorkspaceFiles(public val id: String) : PdshHostAction {
        override val wire: String = "workspace.files"
    }

    /** Re-read the folder list. */
    public data object RefreshWorkspace : PdshHostAction {
        override val wire: String = "workspace.refresh"
    }

    /** Re-read the schedules. */
    public data object RefreshAutomation : PdshHostAction {
        override val wire: String = "automation.refresh"
    }

    /** Ask for older delivery rows. */
    public data object LoadMoreAutomationHistory : PdshHostAction {
        override val wire: String = "automation.history.more"
    }

    /** Open the host's schedule editor; `null` means a new schedule. */
    public data class OpenAutomationEditor(public val id: String?) : PdshHostAction {
        override val wire: String = "automation.editor"
    }

    /** Re-read the session configuration. */
    public data object RefreshConfiguration : PdshHostAction {
        override val wire: String = "configuration.refresh"
    }

    /** Open the model-service editor; `null` means a new service. */
    public data class OpenProviderEditor(public val id: String?) : PdshHostAction {
        override val wire: String = "provider.editor"
    }

    /** Re-read the model-service list. */
    public data object RefreshModelProvider : PdshHostAction {
        override val wire: String = "provider.refresh"
    }

    /** Re-read the web-search configuration. */
    public data object RefreshWebSearch : PdshHostAction {
        override val wire: String = "websearch.refresh"
    }

    /** Re-read the MCP registry. */
    public data object RefreshMcp : PdshHostAction {
        override val wire: String = "mcp.refresh"
    }

    /** Persist the web-search switch position. */
    public data class SetWebSearchEnabled(public val enabled: Boolean) : PdshHostAction {
        override val wire: String = "websearch.toggle"
    }

    /** Persist the selected web-search backend. */
    public data class SelectWebSearchBackend(public val id: String) : PdshHostAction {
        override val wire: String = "websearch.backend"
    }

    /** Persist one MCP server draft. */
    public data class SaveMcpServer(public val draft: MCPServerDraft) : PdshHostAction {
        override val wire: String = "mcp.save"
    }

    /** Stop the local engine after the inline confirmation. */
    public data object StopRuntime : PdshHostAction {
        override val wire: String = "runtime.stop"
    }

    /** Start a stopped engine. */
    public data object RestartRuntime : PdshHostAction {
        override val wire: String = "runtime.restart"
    }

    /** Re-read the runtime snapshot. */
    public data object RefreshRuntime : PdshHostAction {
        override val wire: String = "runtime.refresh"
    }

    /** Re-read the allow list. */
    public data object RefreshEgress : PdshHostAction {
        override val wire: String = "egress.refresh"
    }

    /** Read one tool-written file for the workbench preview. */
    public data class OpenWorkbenchFile(public val path: String) : PdshHostAction {
        override val wire: String = "workbench.read"
    }

    /** Retry the engine start from the Web surface's failure panel. */
    public data object RetryWebSurface : PdshHostAction {
        override val wire: String = "websurface.retry"
    }
}
