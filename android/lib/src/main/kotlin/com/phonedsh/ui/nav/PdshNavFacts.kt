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
// [PdshHostAction] is the other direction. This file only names the gestures; a
// host performs the ones it owns and answers the rest with that fact. The Android
// host, for instance, performs the engine stop/start, the Web-surface retry and
// the model-service save (into its own device store), and says so on the routes
// whose writes it cannot perform. A page is never told a write succeeded: the
// facts only change when a real read reports a new value.
package com.phonedsh.ui.nav

import androidx.compose.runtime.Immutable
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.AutomationScheduleDraft
import com.phonedsh.ui.page.BackgroundFacts
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.EgressAllowListFacts
import com.phonedsh.ui.page.MCPEditorFacts
import com.phonedsh.ui.page.MCPRegistryFacts
import com.phonedsh.ui.page.MCPServerDraft
import com.phonedsh.ui.page.ModelProviderFacts
import com.phonedsh.ui.page.PermissionTier
import com.phonedsh.ui.page.PhonePermissionsFacts
import com.phonedsh.ui.page.ProviderDraft
import com.phonedsh.ui.page.RuntimeFacts
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.ShellSnapshot
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
 * @param shell the command surface the host really carries: the accelerators it
 *   advertises, their read-only limits and the run being shown. The default is
 *   the empty snapshot, which the page renders as 还没接上命令 — never as "no
 *   commands exist".
 * @param phonePermissions the phone-capability matrix's read-only input: what this
 *   host read about its own permissions, and the use audit it has (or has not). The
 *   default reports no read at all, so a host that never wired the matrix renders
 *   未知 on every row instead of borrowing a status.
 * @param background 后台保活的诊断读数. It was missing until the L55 lane wired
 *   `BackgroundPage`: without a field the page could only be handed
 *   `BackgroundFacts()` inline, which made "the host never reads this" and "this
 *   router does not accept the read" look the same. The default still reports no
 *   snapshot — an unread host renders 未知, never 0 seconds.
 */
@Immutable
public data class PdshNavFacts(
    public val workspaceFolders: WorkspaceFoldersSnapshot = WorkspaceFoldersSnapshot(),
    public val workbench: WorkbenchSnapshot = WorkbenchSnapshot(),
    public val modelProvider: ModelProviderFacts = ModelProviderFacts(),
    public val webSearch: WebSearchFacts = WebSearchFacts(),
    public val mcp: MCPRegistryFacts = MCPRegistryFacts(),
    public val mcpEditor: MCPEditorFacts = MCPEditorFacts(),
    public val bluetooth: com.phonedsh.ui.page.BluetoothFacts = com.phonedsh.ui.page.BluetoothFacts(),
    public val ssh: com.phonedsh.ui.page.SSHFacts = com.phonedsh.ui.page.SSHFacts(),
    public val runtime: RuntimeFacts = RuntimeFacts(),
    public val egress: EgressAllowListFacts = EgressAllowListFacts(),
    public val automation: AutomationFacts = AutomationFacts(),
    public val configuration: ConfigurationFacts = ConfigurationFacts(),
    public val webSurface: WebSurfaceFacts = WebSurfaceFacts(),
    public val settings: SettingsFacts = SettingsFacts(),
    public val shell: ShellSnapshot = ShellSnapshot(),
    public val phonePermissions: PhonePermissionsFacts = PhonePermissionsFacts(),
    public val background: BackgroundFacts = BackgroundFacts(),
    /** Per-operation host availability; omitted actions remain unavailable. */
    public val actionAvailability: PdshActionAvailabilities = PdshActionAvailabilities(),
    /** Current chat/session identity; null means the host has not read it. */
    public val sessionIdentity: PdshSessionIdentity? = null,
    /** Session list; null means unread, while an empty list means read and empty. */
    public val sessions: List<PdshSessionRecord>? = null,
    /** Workspace target, preserving 日常 default, explicit unassigned, and unknown. */
    public val workspaceSelection: PdshWorkspaceSelection? = null,
    /** Device and connection facts; null means the host supplied no device read. */
    public val device: PdshDeviceFacts? = null,
    /** Permission summary; null means the host did not measure it. */
    public val permissionSummary: PdshPermissionSummary? = null,
    /** Artifact catalog; null means unread, empty means read with no artifacts. */
    public val artifacts: List<PdshArtifactFact>? = null,
    /** Durable context-loss fact; null means none was reported to this snapshot. */
    public val contextLost: PdshContextLostFact? = null,
    /** License catalog; null means the host has not read or does not expose one. */
    public val licenses: List<PdshLicenseFact>? = null,
    /** Request-bound provider result receipts; null means no result read was supplied. */
    public val providerOperations: List<PdshProviderOperationFact>? = null,
    /** Archived-session scan state; unknown is distinct from an empty archive. */
    public val sessionsWaiting: Boolean = true,
    /** Host-reported session scan failure, if present. */
    public val sessionsFailure: String? = null,
)

/** Session identity facts kept distinct from route and local draft state. */
public data class PdshSessionIdentity(
    /** Host session id; null when a current session is not known. */
    public val sessionId: String?,
    /** Host-reported title; null when unread or untitled. */
    public val title: String?,
    /** Host-reported workspace id; null when unassigned or unknown. */
    public val workspaceId: String?,
)

/** One host-read session row, including archive status. */
public data class PdshSessionRecord(
    /** Stable session id from the host. */
    public val id: String,
    /** Host-reported title; null remains unknown. */
    public val title: String?,
    /** Host-reported archive state; null remains unknown. */
    public val archived: Boolean?,
    /** Host-reported workspace id; null remains unassigned or unknown. */
    public val workspaceId: String?,
    /** Host-reported update timestamp; null means it was not measured. */
    public val updatedAt: String?,
)

/** Workspace selection without conflating default, unassigned, and unread. */
public sealed interface PdshWorkspaceSelection {
    /** The host selected its built-in 日常 default group. */
    public data object DailyDefault : PdshWorkspaceSelection
    /** The host selected this identified workspace. */
    public data class Assigned(public val workspaceId: String) : PdshWorkspaceSelection
    /** The host explicitly reported no workspace assignment. */
    public data object Unassigned : PdshWorkspaceSelection
    /** The host did not report a selection. */
    public data object Unknown : PdshWorkspaceSelection
}

/** Device facts retain unknown collection and capability states. */
public data class PdshDeviceFacts(
    /** Host-read devices; null means catalog unread and empty means none found. */
    public val devices: List<PdshDeviceRecord>?,
    /** Whether this host can connect; null means unknown. */
    public val canConnect: Boolean?,
)

/** One device row returned by a host read. */
public data class PdshDeviceRecord(
    /** Stable host/device identity. */
    public val id: String,
    /** Host-reported display name; null remains unknown. */
    public val name: String?,
    /** Host-reported connected state; null remains unknown. */
    public val connected: Boolean?,
)

/** Compact permission read without inferred grants. */
public data class PdshPermissionSummary(
    /** Permissions measured by the host; null means unread. */
    public val permissions: Map<String, Boolean>?,
    /** Host-reported read failure, if any. */
    public val failure: String?,
)

/** Host-reported artifact facts preserve attribution uncertainty. */
public data class PdshArtifactFact(
    /** Stable artifact id. */
    public val id: String,
    /** Host-reported display name; null remains unknown. */
    public val name: String?,
    /** Original resource URI when the host read one. */
    public val originalUri: String?,
    /** Session attribution; null means the host did not establish one. */
    public val sessionId: String?,
)

/** Durable context-loss report associated with the request and session that produced it. */
public data class PdshContextLostFact(
    /** Correlation id of the operation that reported the loss. */
    public val requestId: String,
    /** Session whose context was lost. */
    public val sessionId: String,
    /** Host-reported explanation. */
    public val reason: String,
)

/** One license row read from the host's actual catalog. */
public data class PdshLicenseFact(
    /** Stable catalog identity. */
    public val id: String,
    /** Host-reported display name. */
    public val name: String?,
    /** Host-reported license text or URI, if available. */
    public val source: String?,
)

/**
 * One gesture this host cannot complete itself, handed to the composition root.
 *
 * Every action's [wire] label is token-free, and a host logs only that label: no
 * log line quotes a prompt, a credential, a URL or a command line. A payload may
 * still carry what the person just typed (a draft's key, a shell argument) —
 * that is the gesture's data, handed to the host once, never a fact the page
 * reads back.
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

    /** Read one schedule's history page, carrying its opaque cursor when present. */
    public data class LoadAutomationHistory(
        public val id: String,
        public val before: String? = null,
    ) : PdshHostAction {
        override val wire: String = "automation.history"
    }

    /** Open the host's schedule editor; `null` means a new schedule. */
    public data class OpenAutomationEditor(public val id: String?) : PdshHostAction {
        override val wire: String = "automation.editor"
    }

    /** Save one validated schedule draft; the host reports a reread receipt. */
    public data class SaveAutomationSchedule(
        public val draft: AutomationScheduleDraft,
        public val submissionID: String,
    ) : PdshHostAction {
        override val wire: String = "automation.save"
    }

    /** Delete one schedule after the confirmation the page displayed. */
    public data class DeleteAutomationSchedule(public val id: String) : PdshHostAction {
        override val wire: String = "automation.delete"
    }

    /** Re-read the session configuration. */
    public data object RefreshConfiguration : PdshHostAction {
        override val wire: String = "configuration.refresh"
    }

    /** Save one staged namespace patch with the host's revision CAS. */
    public data class SaveConfigurationGroup(
        public val namespace: String,
        public val patch: Map<String, String>,
        public val requestId: String = "",
    ) : PdshHostAction {
        override val wire: String = "configuration.save"
    }

    /** Reset one overridden field to the DSH default. */
    public data class ResetConfigurationField(
        public val namespace: String,
        public val field: String,
        public val requestId: String = "",
    ) : PdshHostAction {
        override val wire: String = "configuration.reset"
    }

    /** Save the new-session permission preset with the permission CAS. */
    public data class SaveDefaultPermission(
        public val modeId: String,
        public val requestId: String = "",
    ) : PdshHostAction {
        override val wire: String = "configuration.permission"
    }

    /** Open the model-service editor; `null` means a new service. */
    public data class OpenProviderEditor(public val id: String?) : PdshHostAction {
        override val wire: String = "provider.editor"
    }

    /** Re-read the model-service list. */
    public data object RefreshModelProvider : PdshHostAction {
        override val wire: String = "provider.refresh"
    }

    /**
     * Persist one model-service draft that the person finished editing.
     *
     * The draft is the page's own view state, so it may carry the key the person
     * just typed. [wire] never does, and no host logs a payload: the host hands
     * the key to its device store and keeps nothing else. A host that cannot
     * persist the draft reports that instead of moving the facts.
     */
    public data class SaveProvider(
        public val draft: ProviderDraft,
        /** Non-secret UI correlation id; never included in the action wire/log. */
        public val requestId: String = "",
    ) : PdshHostAction {
        override val wire: String = "provider.save"
    }

    /** Persist the removal of one service, by id. */
    public data class DeleteProvider(public val id: String) : PdshHostAction {
        override val wire: String = "provider.delete"
    }

    /** Make one stored service the default for the next host start. */
    public data class SelectProvider(public val id: String) : PdshHostAction {
        override val wire: String = "provider.select"
    }

    /** Read the real `/models` catalog for one draft, bound to this request id. */
    public data class GetProviderModels(
        public val draft: ProviderDraft,
        public val requestId: String = "",
    ) : PdshHostAction {
        override val wire: String = "provider.models"
    }

    /**
     * Drop the approval this session already gave the local Ubuntu environment.
     *
     * Design §3 promises the person can revoke "at any time within this session";
     * until this action existed the only way was to stop the whole local engine,
     * which ends the session the approval belonged to. The host clears its gate
     * for the current session and the next `ubuntu run` asks again. A host that
     * granted nothing answers that nothing was revoked rather than claiming a
     * change it did not make.
     */
    public data object RevokeUbuntuApproval : PdshHostAction {
        override val wire: String = "ubuntu.approval.revoke"
    }

    /**
     * Ask the host to test one draft against its endpoint.
     *
     * A host with no test command answers with that fact; the page never claims a
     * test ran.
     */
    public data class TestProvider(public val draft: ProviderDraft) : PdshHostAction {
        override val wire: String = "provider.test"
    }

    /** Re-read the web-search configuration. */
    public data object RefreshWebSearch : PdshHostAction {
        override val wire: String = "websearch.refresh"
    }

    /** Re-read the MCP registry. */
    public data object RefreshMcp : PdshHostAction {
        override val wire: String = "mcp.refresh"
    }

    /**
     * 保存 one SSH connection. The draft may carry a freshly typed secret, so
     * this action is not a data class and [toString] never prints it.
     */
    public class SshSaveConnection(
        public val requestId: String,
        public val draft: com.phonedsh.ui.page.SSHConnectionDraft,
    ) : PdshHostAction {
        override val wire: String = "ssh.save"

        override fun toString(): String = "SshSaveConnection(redacted)"
    }

    /** 删除连接: the profile and its Keystore credential. */
    public data class SshDeleteConnection(public val requestId: String, public val id: String) : PdshHostAction {
        override val wire: String = "ssh.delete"
    }

    /** 读取并核对指纹: observe the server key for (host, port); nothing is trusted yet. */
    public data class SshInspectHostKey(
        public val requestId: String,
        public val host: String,
        public val port: Int,
    ) : PdshHostAction {
        override val wire: String = "ssh.inspect"
    }

    /** 蓝牙设备 page shown (`true`) or disposed (`false`); disposal stops scan and connections. */
    public data class BluetoothPageVisible(public val visible: Boolean) : PdshHostAction {
        override val wire: String = "bluetooth.page"
    }

    /** 扫描附近 BLE 设备 / 停止扫描. */
    public data class BluetoothScan(public val start: Boolean) : PdshHostAction {
        override val wire: String = "bluetooth.scan"
    }

    /** 连接并发现设备能力 for one scan candidate (opaque id, never an address). */
    public data class BluetoothConnect(public val id: String) : PdshHostAction {
        override val wire: String = "bluetooth.connect"
    }

    /** 断开连接. */
    public data class BluetoothDisconnect(public val id: String) : PdshHostAction {
        override val wire: String = "bluetooth.disconnect"
    }

    /** The per-connection read / alert grant toggles; `null` leaves that grant as is. */
    public data class BluetoothGrant(
        public val id: String,
        public val read: Boolean? = null,
        public val alert: Boolean? = null,
    ) : PdshHostAction {
        override val wire: String = "bluetooth.grant"
    }

    /** 读取 <profile>: one standard characteristic read. */
    public data class BluetoothRead(public val id: String, public val profile: String) : PdshHostAction {
        override val wire: String = "bluetooth.read"
    }

    /** Immediate Alert level 0–2 (write without response, unconfirmed). */
    public data class BluetoothAlert(public val id: String, public val level: Int) : PdshHostAction {
        override val wire: String = "bluetooth.alert"
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

    /**
     * Run one command from the commands page's form.
     *
     * The form is local view state; this action is the person's 运行 gesture with
     * the command, the working directory and the arguments they typed. A host
     * with no exec entry point answers with that fact (and the page keeps the
     * form), instead of handing a live-looking button to nothing.
     */
    public data class RunShellCommand(
        public val command: String,
        public val workingDirectory: String,
        public val arguments: String,
    ) : PdshHostAction {
        override val wire: String = "shell.run"
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

    /**
     * Re-read this session's activity: its background jobs and its schedules.
     *
     * One action, not two, because the baseline reads both with one call: both
     * chat sheets pass `management.refreshActivity(sessionID:)`
     * (`ChatPage.swift:441` and `:449`), which fills `jobs` and `scheduleRecords`
     * together. A host that owns that read fills `ChatSubpageFacts.jobs`/
     * `.schedules` after performing it; a host that does not reports the handoff
     * back as one honest line instead of moving the facts.
     */
    public data object RefreshSessionActivity : PdshHostAction {
        override val wire: String = "activity.refresh"
    }
}
