// Stable test tags for the session pages.
// SPDX-License-Identifier: MIT
//
// `com.phonedsh.ui.UiTags` carries the tags of the components that existed before
// this lane (chat scaffold, the six signature surfaces, files/settings). The
// session pages keep their own table next to them so adding a page never rewrites
// the shared table another lane is editing; the naming scheme is identical.
package com.phonedsh.ui.page

/** One constant per addressable node of the session pages. */
public object UiPageTags {
    // SessionsPage (`spec/ui/v1/README.md` §1)
    public const val SESSIONS_ROOT: String = "pdsh.sessions.root"
    public const val SESSIONS_LIST: String = "pdsh.sessions.list"
    public const val SESSIONS_EMPTY: String = "pdsh.sessions.empty"
    public const val SESSIONS_FAILURE: String = "pdsh.sessions.failure"
    public const val SESSIONS_SEARCH: String = "pdsh.sessions.search"
    public const val SESSION_NEW: String = "pdsh.sessions.new"
    public const val SESSION_ROW: String = "pdsh.sessions.row"
    public const val SESSION_RENAME_FIELD: String = "pdsh.sessions.rename.field"
    public const val SESSION_RENAME_SAVE: String = "pdsh.sessions.rename.save"
    public const val SESSION_RENAME_CANCEL: String = "pdsh.sessions.rename.cancel"
    public const val SESSION_DELETE_YES: String = "pdsh.sessions.delete.confirm"
    public const val SESSION_DELETE_NO: String = "pdsh.sessions.delete.cancel"

    // Session history / one turn's detail (ScreenState layer)
    public const val HISTORY_ROOT: String = "pdsh.history.root"
    public const val HISTORY_LIST: String = "pdsh.history.list"
    public const val HISTORY_EMPTY: String = "pdsh.history.empty"
    public const val HISTORY_FAILURE: String = "pdsh.history.failure"
    public const val HISTORY_TURN: String = "pdsh.history.turn"
    public const val HISTORY_DETAIL: String = "pdsh.history.detail"
    public const val HISTORY_DETAIL_EMPTY: String = "pdsh.history.detail.empty"
    public const val HISTORY_ROWS: String = "pdsh.history.rows"
    public const val HISTORY_BACK: String = "pdsh.history.back"

    // SessionActivityPage (§1, P5 `later`)
    public const val ACTIVITY_ROOT: String = "pdsh.activity.root"
    public const val ACTIVITY_LIST: String = "pdsh.activity.list"
    public const val ACTIVITY_EMPTY: String = "pdsh.activity.empty"
    public const val ACTIVITY_FAILURE: String = "pdsh.activity.failure"
    public const val ACTIVITY_STEPS: String = "pdsh.activity.steps"
    public const val ACTIVITY_USAGE: String = "pdsh.activity.usage"
    public const val ACTIVITY_CONTEXT: String = "pdsh.activity.context"

    // Goal bar (§3) and the goal detail sheet
    public const val GOAL_ROOT: String = "pdsh.goal.root"
    public const val GOAL_EMPTY: String = "pdsh.goal.empty"
    public const val GOAL_FAILURE: String = "pdsh.goal.failure"
    public const val GOAL_OBJECTIVE: String = "pdsh.goal.objective"
    public const val GOAL_PHASE: String = "pdsh.goal.phase"
    public const val GOAL_ROUNDS: String = "pdsh.goal.rounds"
    public const val GOAL_REASON: String = "pdsh.goal.reason"
    public const val GOAL_PAUSE: String = "pdsh.goal.pause"
    public const val GOAL_RESUME: String = "pdsh.goal.resume"
    public const val GOAL_CLEAR: String = "pdsh.goal.clear"
    public const val GOAL_BAR_DETAIL: String = "pdsh.goal.bar.detail"

    // NativeWorkbenchPage (§1 must; a sheet whose 完成 closes it)
    public const val WORKBENCH_ROOT: String = "pdsh.workbench.root"
    public const val WORKBENCH_DONE: String = "pdsh.workbench.done"
    public const val WORKBENCH_FILES_TAB: String = "pdsh.workbench.tab.files"
    public const val WORKBENCH_COMMANDS_TAB: String = "pdsh.workbench.tab.commands"
    public const val WORKBENCH_FILES_LIST: String = "pdsh.workbench.files.list"
    public const val WORKBENCH_COMMANDS_LIST: String = "pdsh.workbench.commands.list"
    public const val WORKBENCH_FILE_ROW: String = "pdsh.workbench.files.row"
    public const val WORKBENCH_COMMAND_ROW: String = "pdsh.workbench.commands.row"
    public const val WORKBENCH_FILES_EMPTY: String = "pdsh.workbench.files.empty"
    public const val WORKBENCH_COMMANDS_EMPTY: String = "pdsh.workbench.commands.empty"
    public const val WORKBENCH_FILES_UNKNOWN: String = "pdsh.workbench.files.unknown"
    public const val WORKBENCH_COMMANDS_UNKNOWN: String = "pdsh.workbench.commands.unknown"
    public const val WORKBENCH_FAILURE: String = "pdsh.workbench.failure"
    public const val WORKBENCH_PREVIEW: String = "pdsh.workbench.preview"
    public const val WORKBENCH_PREVIEW_PENDING: String = "pdsh.workbench.preview.pending"

    // WorkspaceFoldersPage (§1 must; the drawer's 工作文件夹 row pushes it)
    public const val WORKSPACE_ROOT: String = "pdsh.workspace.root"
    public const val WORKSPACE_LIST: String = "pdsh.workspace.list"
    public const val WORKSPACE_EMPTY: String = "pdsh.workspace.empty"
    public const val WORKSPACE_UNKNOWN: String = "pdsh.workspace.unknown"
    public const val WORKSPACE_FAILURE: String = "pdsh.workspace.failure"
    public const val WORKSPACE_NEW: String = "pdsh.workspace.new"
    public const val WORKSPACE_CREATE_ROW: String = "pdsh.workspace.create"
    public const val WORKSPACE_NAME_FIELD: String = "pdsh.workspace.name.field"
    public const val WORKSPACE_NAME_ERROR: String = "pdsh.workspace.name.error"
    public const val WORKSPACE_CREATE: String = "pdsh.workspace.create.confirm"
    public const val WORKSPACE_ROW: String = "pdsh.workspace.row"
    public const val WORKSPACE_CURRENT: String = "pdsh.workspace.current"
    public const val WORKSPACE_SWITCH: String = "pdsh.workspace.switch"
    public const val WORKSPACE_DELETE: String = "pdsh.workspace.delete"
    public const val WORKSPACE_LOCKED: String = "pdsh.workspace.locked"
    public const val WORKSPACE_DELETE_YES: String = "pdsh.workspace.delete.confirm"
    public const val WORKSPACE_DELETE_NO: String = "pdsh.workspace.delete.cancel"

    // P5 settings family (Q3 lane): model provider, web search, MCP list/editor.
    // Appended only; the session and workspace tags above are other lanes' rows.
    public const val PROVIDER_ROOT: String = "pdsh.provider.root"
    public const val PROVIDER_LIST: String = "pdsh.provider.list"
    public const val PROVIDER_ADD: String = "pdsh.provider.add"
    public const val PROVIDER_EMPTY: String = "pdsh.provider.empty"
    public const val PROVIDER_UNKNOWN: String = "pdsh.provider.unknown"
    public const val PROVIDER_FAILURE: String = "pdsh.provider.failure"
    public const val PROVIDER_SERVICES_SECTION: String = "pdsh.provider.services"
    public const val PROVIDER_HELP_SECTION: String = "pdsh.provider.help"
    public const val PROVIDER_ROW_PREFIX: String = "pdsh.provider.row."

    // BluetoothDevicesPage
    public const val BLUETOOTH_ROOT: String = "pdsh.bluetooth.root"
    public const val BLUETOOTH_LIST: String = "pdsh.bluetooth.list"
    public const val BLUETOOTH_SCAN: String = "pdsh.bluetooth.scan"
    public const val BLUETOOTH_CONNECT: String = "pdsh.bluetooth.connect"
    public const val BLUETOOTH_DISCONNECT: String = "pdsh.bluetooth.disconnect"
    public const val BLUETOOTH_GRANT_READ: String = "pdsh.bluetooth.grant.read"
    public const val BLUETOOTH_GRANT_ALERT: String = "pdsh.bluetooth.grant.alert"
    public const val BLUETOOTH_READ: String = "pdsh.bluetooth.read"

    // AndroidADBSettingsPage
    public const val ANDROID_ADB_ROOT: String = "pdsh.androidadb.root"
    public const val ANDROID_ADB_LIST: String = "pdsh.androidadb.list"
    public const val ANDROID_ADB_TOGGLE: String = "pdsh.androidadb.toggle"
    public const val ANDROID_ADB_HOST: String = "pdsh.androidadb.host"
    public const val ANDROID_ADB_PORT: String = "pdsh.androidadb.port"
    public const val ANDROID_ADB_SAVE: String = "pdsh.androidadb.save"
    public const val ANDROID_ADB_CHECK: String = "pdsh.androidadb.check"
    public const val ANDROID_ADB_CANCEL: String = "pdsh.androidadb.cancel"
    public const val ANDROID_ADB_STATUS: String = "pdsh.androidadb.status"

    // TonoAccountPage
    public const val TONO_ACCOUNT_ROOT: String = "pdsh.tonoaccount.root"
    public const val TONO_ACCOUNT_LIST: String = "pdsh.tonoaccount.list"
    public const val TONO_ACCOUNT_PHONE: String = "pdsh.tonoaccount.phone"
    public const val TONO_ACCOUNT_CODE: String = "pdsh.tonoaccount.code"
    public const val TONO_ACCOUNT_REQUEST_CODE: String = "pdsh.tonoaccount.requestcode"
    public const val TONO_ACCOUNT_SIGN_IN: String = "pdsh.tonoaccount.signin"
    public const val TONO_ACCOUNT_SIGN_OUT: String = "pdsh.tonoaccount.signout"
    public const val TONO_ACCOUNT_STATUS: String = "pdsh.tonoaccount.status"

    public const val WEB_SEARCH_ROOT: String = "pdsh.websearch.root"
    public const val WEB_SEARCH_LIST: String = "pdsh.websearch.list"
    public const val WEB_SEARCH_TOGGLE: String = "pdsh.websearch.toggle"
    public const val WEB_SEARCH_REASON: String = "pdsh.websearch.reason"
    public const val WEB_SEARCH_BACKENDS_SECTION: String = "pdsh.websearch.backends"
    public const val WEB_SEARCH_BACKEND_ROW_PREFIX: String = "pdsh.websearch.backend."
    public const val WEB_SEARCH_EMPTY: String = "pdsh.websearch.empty"
    public const val WEB_SEARCH_UNKNOWN: String = "pdsh.websearch.unknown"
    public const val WEB_SEARCH_FAILURE: String = "pdsh.websearch.failure"

    // L15 lane: the contract refresh (86a39aac) gave the web-search page its own
    // address and key fields, so the page needs a handle on each. Appended only.
    public const val WEB_SEARCH_ADDRESS_FIELD: String = "pdsh.websearch.address"
    public const val WEB_SEARCH_KEY_FIELD: String = "pdsh.websearch.key"

    public const val MCP_ROOT: String = "pdsh.mcp.root"
    public const val MCP_LIST: String = "pdsh.mcp.list"
    public const val MCP_ADD: String = "pdsh.mcp.add"
    public const val MCP_SERVERS_SECTION: String = "pdsh.mcp.servers"
    public const val MCP_ROW_PREFIX: String = "pdsh.mcp.row."
    public const val MCP_EMPTY: String = "pdsh.mcp.empty"
    public const val MCP_UNKNOWN: String = "pdsh.mcp.unknown"
    public const val MCP_FAILURE: String = "pdsh.mcp.failure"

    public const val MCP_EDITOR_ROOT: String = "pdsh.mcp.editor.root"
    public const val MCP_EDITOR_LIST: String = "pdsh.mcp.editor.list"
    public const val MCP_EDITOR_FAILURE: String = "pdsh.mcp.editor.failure"
    public const val MCP_EDITOR_UNKNOWN: String = "pdsh.mcp.editor.unknown"
    public const val MCP_EDITOR_TRANSPORT_STDIO: String = "pdsh.mcp.editor.transport.stdio"
    public const val MCP_EDITOR_TRANSPORT_HTTP: String = "pdsh.mcp.editor.transport.http"
    public const val MCP_EDITOR_NAME: String = "pdsh.mcp.editor.name"
    public const val MCP_EDITOR_NAME_ERROR: String = "pdsh.mcp.editor.name.error"
    public const val MCP_EDITOR_COMMAND: String = "pdsh.mcp.editor.command"
    public const val MCP_EDITOR_COMMAND_ERROR: String = "pdsh.mcp.editor.command.error"
    public const val MCP_EDITOR_URL: String = "pdsh.mcp.editor.url"
    public const val MCP_EDITOR_URL_ERROR: String = "pdsh.mcp.editor.url.error"
    public const val MCP_EDITOR_ENABLED: String = "pdsh.mcp.editor.enabled"
    public const val MCP_EDITOR_ERRORS: String = "pdsh.mcp.editor.errors"
    public const val MCP_EDITOR_SAVE: String = "pdsh.mcp.editor.save"

    // P5 R2 lane: RuntimeDetailsPage (§1 must) and EgressAllowListPage (§1 must).
    // Appended only; the settings-family tags above belong to the Q3 lane.
    public const val RUNTIME_ROOT: String = "pdsh.runtime.root"
    public const val RUNTIME_LIST: String = "pdsh.runtime.list"
    public const val RUNTIME_FAILURE: String = "pdsh.runtime.failure"
    public const val RUNTIME_RETRY: String = "pdsh.runtime.retry"
    public const val RUNTIME_DISMISS: String = "pdsh.runtime.dismiss"
    public const val RUNTIME_EMPTY: String = "pdsh.runtime.empty"
    public const val RUNTIME_UNKNOWN: String = "pdsh.runtime.unknown"
    public const val RUNTIME_UNMEASURED: String = "pdsh.runtime.unmeasured"
    public const val RUNTIME_SECTION_PREFIX: String = "pdsh.runtime.section."
    public const val RUNTIME_STOP: String = "pdsh.runtime.stop"
    public const val RUNTIME_START: String = "pdsh.runtime.start"
    public const val RUNTIME_STOP_CONFIRM: String = "pdsh.runtime.stop.confirm"
    public const val RUNTIME_STOP_CONFIRM_ACTION: String = "pdsh.runtime.stop.confirmed"
    public const val RUNTIME_STOP_CANCEL: String = "pdsh.runtime.stop.cancel"

    public const val EGRESS_ROOT: String = "pdsh.egress.root"
    public const val EGRESS_LIST: String = "pdsh.egress.list"
    public const val EGRESS_FAILURE: String = "pdsh.egress.failure"
    public const val EGRESS_RETRY: String = "pdsh.egress.retry"
    public const val EGRESS_DISMISS: String = "pdsh.egress.dismiss"
    public const val EGRESS_UNKNOWN: String = "pdsh.egress.unknown"

    /**
     * The tag an ordinary empty-list state would carry.
     *
     * No code path renders it: an empty rule table is the deny-all policy, which
     * `EGRESS_DENY_ALL` states explicitly, so this tag is the negative oracle a
     * test asserts absent rather than a second rendering of the same screen.
     */
    public const val EGRESS_EMPTY: String = "pdsh.egress.empty"
    public const val EGRESS_DENY_ALL: String = "pdsh.egress.deny-all"
    public const val EGRESS_ALLOW_ALL: String = "pdsh.egress.allow-all"
    public const val EGRESS_RULES_SECTION: String = "pdsh.egress.rules"
    public const val EGRESS_GRAMMAR_SECTION: String = "pdsh.egress.grammar"
    public const val EGRESS_RULE: String = "pdsh.egress.rule"
    public const val EGRESS_GRAMMAR: String = "pdsh.egress.grammar.row"
    public const val EGRESS_READ_ONLY: String = "pdsh.egress.read-only"

    // P5 S1 lane: NativeAutomationPage, NativeConfigurationPage and
    // WebSurfacePage (§1 `must`). Appended only: the tags above belong to other
    // lanes and are never rewritten.
    public const val AUTOMATION_ROOT: String = "pdsh.automation.root"
    public const val AUTOMATION_LIST: String = "pdsh.automation.list"
    public const val AUTOMATION_EMPTY: String = "pdsh.automation.empty"
    public const val AUTOMATION_UNKNOWN: String = "pdsh.automation.unknown"
    public const val AUTOMATION_UNKNOWN_DETAIL: String = "pdsh.automation.unknown.detail"
    public const val AUTOMATION_FAILURE: String = "pdsh.automation.failure"
    // Retired by L11: the iOS page has no in-content retry or dismiss (its 刷新
    // control is the retry), so the aligned page renders neither. Kept rather than
    // deleted because this block is appended-only across lanes.
    public const val AUTOMATION_RETRY: String = "pdsh.automation.retry"
    public const val AUTOMATION_DISMISS: String = "pdsh.automation.dismiss"
    public const val AUTOMATION_NEW: String = "pdsh.automation.new"
    public const val AUTOMATION_EDIT: String = "pdsh.automation.edit"
    public const val AUTOMATION_REFRESH: String = "pdsh.automation.refresh"
    public const val AUTOMATION_ROW_PREFIX: String = "pdsh.automation.row."
    public const val AUTOMATION_UNMEASURED: String = "pdsh.automation.unmeasured"
    public const val AUTOMATION_DETAIL: String = "pdsh.automation.detail"
    public const val AUTOMATION_HISTORY_OPEN: String = "pdsh.automation.history.open"
    public const val AUTOMATION_HISTORY_LIST: String = "pdsh.automation.history.list"
    public const val AUTOMATION_HISTORY_EMPTY: String = "pdsh.automation.history.empty"
    public const val AUTOMATION_HISTORY_UNKNOWN: String = "pdsh.automation.history.unknown"
    public const val AUTOMATION_HISTORY_UNKNOWN_DETAIL: String = "pdsh.automation.history.unknown.detail"
    public const val AUTOMATION_HISTORY_FAILURE: String = "pdsh.automation.history.failure"
    public const val AUTOMATION_HISTORY_MORE: String = "pdsh.automation.history.more"
    public const val AUTOMATION_HISTORY_ROW: String = "pdsh.automation.history.row"

    // L11 lane: the three controls the iOS baseline draws that this page did not
    // have before it was aligned to `NativeAutomationPage.swift`. Appended only.
    /** The 44 pt bar's ✕ / back control. */
    public const val AUTOMATION_BACK: String = "pdsh.automation.back"
    /** The empty block's 50 pt full-width 新建任务 CTA (`NativeAutomationPage.swift:27-38`). */
    public const val AUTOMATION_CTA: String = "pdsh.automation.cta"
    /** The 需要处理 / 错误 section header (`NativeAutomationPage.swift:70,150,203`). */
    public const val AUTOMATION_ATTENTION: String = "pdsh.automation.attention"

    // L17 lane: the row's 删除 verb and its confirmation
    // (`NativeAutomationPage.swift:64`, `:102`–`:109`). Appended only.
    /** The detail page's 删除 row. */
    public const val AUTOMATION_DELETE: String = "pdsh.automation.delete"
    /** `删除此自动化任务？` and its two buttons. */
    public const val AUTOMATION_DELETE_DIALOG: String = "pdsh.automation.delete.dialog"
    public const val AUTOMATION_DELETE_CONFIRM: String = "pdsh.automation.delete.confirm"
    public const val AUTOMATION_DELETE_CANCEL: String = "pdsh.automation.delete.cancel"

    public const val CONFIGURATION_ROOT: String = "pdsh.configuration.root"
    public const val CONFIGURATION_LIST: String = "pdsh.configuration.list"
    public const val CONFIGURATION_EMPTY: String = "pdsh.configuration.empty"
    public const val CONFIGURATION_UNKNOWN: String = "pdsh.configuration.unknown"
    public const val CONFIGURATION_UNKNOWN_DETAIL: String = "pdsh.configuration.unknown.detail"
    public const val CONFIGURATION_FAILURE: String = "pdsh.configuration.failure"
    public const val CONFIGURATION_RETRY: String = "pdsh.configuration.retry"
    public const val CONFIGURATION_DISMISS: String = "pdsh.configuration.dismiss"
    public const val CONFIGURATION_DONE: String = "pdsh.configuration.done"
    public const val CONFIGURATION_REFRESH: String = "pdsh.configuration.refresh"
    public const val CONFIGURATION_INTRO: String = "pdsh.configuration.intro"
    public const val CONFIGURATION_SESSION: String = "pdsh.configuration.session"
    public const val CONFIGURATION_WRITABLE: String = "pdsh.configuration.writable"
    public const val CONFIGURATION_SECTION_PREFIX: String = "pdsh.configuration.section."
    public const val CONFIGURATION_WEB_SEARCH: String = "pdsh.configuration.websearch"
    public const val CONFIGURATION_PERMISSION_SECTION: String = "pdsh.configuration.section.permission"
    public const val CONFIGURATION_PLUGIN_INFO: String = "pdsh.configuration.section.info"
    public const val CONFIGURATION_EXPERIMENTAL: String = "pdsh.configuration.section.experimental"
    public const val CONFIGURATION_INSTALLED: String = "pdsh.configuration.section.installed"
    public const val CONFIGURATION_PLUGIN_ROW_PREFIX: String = "pdsh.configuration.plugin."
    public const val CONFIGURATION_ADD_DISABLED: String = "pdsh.configuration.add.disabled"
    public const val CONFIGURATION_UNMEASURED: String = "pdsh.configuration.unmeasured"
    public const val CONFIGURATION_NOTE_PREFIX: String = "pdsh.configuration.note."
    public const val CONFIGURATION_READ_ONLY: String = "pdsh.configuration.read-only"

    public const val WEB_SURFACE_ROOT: String = "pdsh.websurface.root"
    public const val WEB_SURFACE_LIST: String = "pdsh.websurface.list"
    public const val WEB_SURFACE_SURFACE: String = "pdsh.websurface.surface"
    public const val WEB_SURFACE_EMPTY: String = "pdsh.websurface.empty"
    public const val WEB_SURFACE_UNKNOWN: String = "pdsh.websurface.unknown"
    public const val WEB_SURFACE_UNKNOWN_DETAIL: String = "pdsh.websurface.unknown.detail"
    public const val WEB_SURFACE_FAILURE: String = "pdsh.websurface.failure"
    public const val WEB_SURFACE_RETRY: String = "pdsh.websurface.retry"
    public const val WEB_SURFACE_MODEL_SETTINGS: String = "pdsh.websurface.model"
    public const val WEB_SURFACE_NATIVE_RECOVERY: String = "pdsh.websurface.recovery"
    public const val WEB_SURFACE_PANEL: String = "pdsh.websurface.panel"
    public const val WEB_SURFACE_PREPARING: String = "pdsh.websurface.preparing"
    public const val WEB_SURFACE_DETAILS_TOGGLE: String = "pdsh.websurface.details"
    public const val WEB_SURFACE_ROW_PREFIX: String = "pdsh.websurface.row."
    public const val WEB_SURFACE_UNMEASURED: String = "pdsh.websurface.unmeasured"

    // N4 lane: the settings index and the Memory probe. Appended only; the tags
    // above belong to other lanes and are never rewritten. The list/empty tags of
    // the pre-lane pages stay in `com.phonedsh.ui.UiTags`; these are the new nodes.
    public const val SETTINGS_ROW_PREFIX: String = "pdsh.settings.row."
    public const val SETTINGS_SECTION_PREFIX: String = "pdsh.settings.section."
    public const val SETTINGS_FOOTER_PREFIX: String = "pdsh.settings.footer."
    public const val SETTINGS_ROW_TOGGLE: String = "pdsh.settings.row.toggle"
    public const val SETTINGS_ROW_OPTION_PREFIX: String = "pdsh.settings.row.option."
    public const val SETTINGS_DONE: String = "pdsh.settings.done"

    /** The pushed 设置 page's back (`SettingsPageMode.MORE`). */
    public const val SETTINGS_MORE_BACK: String = "pdsh.settings.more.back"
    public const val PERMISSION_DEFAULTS_LIST: String = "pdsh.permissions.list"
    public const val PERMISSION_DEFAULTS_NOTE: String = "pdsh.permissions.note"
    public const val PERMISSION_DEFAULTS_OPTION_PREFIX: String = "pdsh.permissions.option."
    public const val MEMORY_LIST: String = "pdsh.memory.list"
    public const val MEMORY_SECTION_PREFIX: String = "pdsh.memory.section."
    public const val MEMORY_BUNDLE: String = "pdsh.memory.bundle"
    public const val MEMORY_BUNDLE_STATE: String = "pdsh.memory.bundle.state"
    public const val MEMORY_LOCKDOWN: String = "pdsh.memory.lockdown"
    public const val MEMORY_RUN_PREFIX: String = "pdsh.memory.run."
    public const val MEMORY_RUN_LONG: String = "pdsh.memory.run.long"
    public const val MEMORY_RUNNING: String = "pdsh.memory.running"
    public const val MEMORY_PHASE: String = "pdsh.memory.phase"
    public const val MEMORY_STATUS: String = "pdsh.memory.status"
    public const val MEMORY_LIVE: String = "pdsh.memory.live"
    public const val MEMORY_LIVE_EMPTY: String = "pdsh.memory.live.empty"
    public const val MEMORY_LEVEL_PREFIX: String = "pdsh.memory.level."
    public const val MEMORY_SESSION: String = "pdsh.memory.session"
    public const val MEMORY_CANCEL_TAG: String = "pdsh.memory.cancel"
    public const val MEMORY_UNKNOWN: String = "pdsh.memory.unknown"

    // P5 X2 lane: the five `later` probe pages. Appended only; the tags above
    // belong to other lanes and are never rewritten.
    public const val PROBES_ROOT: String = "pdsh.probes.root"
    public const val PROBES_LIST: String = "pdsh.probes.list"
    public const val PROBES_ENVIRONMENT: String = "pdsh.probes.environment"
    public const val PROBES_OS: String = "pdsh.probes.os"
    public const val PROBES_BUNDLE: String = "pdsh.probes.bundle"
    public const val PROBES_RUN_ALL: String = "pdsh.probes.run.all"
    public const val PROBES_RESET: String = "pdsh.probes.reset"
    public const val PROBES_GROUP_PREFIX: String = "pdsh.probes.group."
    public const val PROBES_STATUS_TEXT: String = "pdsh.probes.status"
    public const val PROBES_COUNTS: String = "pdsh.probes.counts"
    public const val PROBES_G0: String = "pdsh.probes.g0"
    public const val PROBES_G0_FAILED: String = "pdsh.probes.g0.failed"
    public const val PROBES_ROWS: String = "pdsh.probes.rows"
    public const val PROBES_ROW_PREFIX: String = "pdsh.probes.row."
    public const val PROBES_METRIC_PREFIX: String = "pdsh.probes.metric."
    public const val PROBES_THRESHOLDS: String = "pdsh.probes.thresholds"
    public const val PROBES_THRESHOLD_PREFIX: String = "pdsh.probes.threshold."
    public const val PROBES_THRESHOLD_TABLE_PREFIX: String = "pdsh.probes.threshold.table."
    public const val PROBES_EMPTY: String = "pdsh.probes.empty"
    public const val PROBES_UNKNOWN: String = "pdsh.probes.unknown"
    public const val PROBES_FAILURE: String = "pdsh.probes.failure"
    public const val PROBES_UNMEASURED: String = "pdsh.probes.unmeasured"

    public const val BACKGROUND_ROOT: String = "pdsh.background.root"
    public const val BACKGROUND_LIST: String = "pdsh.background.list"
    public const val BACKGROUND_SCENARIO: String = "pdsh.background.scenario"
    public const val BACKGROUND_PHASE: String = "pdsh.background.phase"
    public const val BACKGROUND_RUNNING: String = "pdsh.background.running"
    public const val BACKGROUND_STATUS: String = "pdsh.background.status"
    public const val BACKGROUND_START: String = "pdsh.background.start"
    public const val BACKGROUND_CANCEL: String = "pdsh.background.cancel"
    public const val BACKGROUND_LAST_ERROR: String = "pdsh.background.error"
    public const val BACKGROUND_OBSERVATION: String = "pdsh.background.observation"
    public const val BACKGROUND_WINDOW: String = "pdsh.background.window"
    public const val BACKGROUND_LOCK: String = "pdsh.background.lock"
    public const val BACKGROUND_INTERVAL: String = "pdsh.background.interval"
    public const val BACKGROUND_RECOVERED: String = "pdsh.background.recovered"
    public const val BACKGROUND_RECOVERY: String = "pdsh.background.recovery"
    public const val BACKGROUND_HOST: String = "pdsh.background.host"
    public const val BACKGROUND_CELLS: String = "pdsh.background.cells"
    public const val BACKGROUND_CELL_PREFIX: String = "pdsh.background.cell."
    public const val BACKGROUND_CELLS_EMPTY: String = "pdsh.background.cells.empty"
    public const val BACKGROUND_CELLS_UNKNOWN: String = "pdsh.background.cells.unknown"
    public const val BACKGROUND_TRANSITIONS: String = "pdsh.background.transitions"
    public const val BACKGROUND_TRANSITION_PREFIX: String = "pdsh.background.transition."
    public const val BACKGROUND_TRANSITIONS_EMPTY: String = "pdsh.background.transitions.empty"
    public const val BACKGROUND_TRANSITIONS_UNKNOWN: String = "pdsh.background.transitions.unknown"
    public const val BACKGROUND_EMPTY: String = "pdsh.background.empty"
    public const val BACKGROUND_UNKNOWN: String = "pdsh.background.unknown"
    public const val BACKGROUND_FAILURE: String = "pdsh.background.failure"
    public const val BACKGROUND_UNMEASURED: String = "pdsh.background.unmeasured"

    public const val EXPORT_ROOT: String = "pdsh.export.root"
    public const val EXPORT_LIST: String = "pdsh.export.list"
    public const val EXPORT_STATUS: String = "pdsh.export.status"
    public const val EXPORT_ENVIRONMENT: String = "pdsh.export.environment"
    public const val EXPORT_DEVICE: String = "pdsh.export.device"
    public const val EXPORT_FORMAT_VERSION: String = "pdsh.export.format"
    public const val EXPORT_FILE: String = "pdsh.export.file"
    public const val EXPORT_WRITE: String = "pdsh.export.write"
    public const val EXPORT_SHARE: String = "pdsh.export.share"
    public const val EXPORT_WRITE_FAILED: String = "pdsh.export.write.failed"
    public const val EXPORT_PREVIEW: String = "pdsh.export.preview"
    public const val EXPORT_PREVIEW_TEXT: String = "pdsh.export.preview.text"
    public const val EXPORT_PREVIEW_MORE: String = "pdsh.export.preview.more"
    public const val EXPORT_EMPTY: String = "pdsh.export.empty"
    public const val EXPORT_UNKNOWN: String = "pdsh.export.unknown"
    public const val EXPORT_FAILURE: String = "pdsh.export.failure"
    public const val EXPORT_UNMEASURED: String = "pdsh.export.unmeasured"

    public const val BRIEF_ROOT: String = "pdsh.brief.root"
    public const val BRIEF_LIST: String = "pdsh.brief.list"
    public const val BRIEF_HEADLINE: String = "pdsh.brief.headline"
    public const val BRIEF_LAST_SUCCESS: String = "pdsh.brief.success"
    public const val BRIEF_LAST_ATTEMPT: String = "pdsh.brief.attempt"
    public const val BRIEF_ERROR: String = "pdsh.brief.error"
    public const val BRIEF_REFRESH: String = "pdsh.brief.refresh"
    public const val BRIEF_SHARE: String = "pdsh.brief.share"
    public const val BRIEF_ITEMS: String = "pdsh.brief.items"
    public const val BRIEF_ITEM_PREFIX: String = "pdsh.brief.item."
    public const val BRIEF_ITEMS_EMPTY: String = "pdsh.brief.items.empty"
    public const val BRIEF_SOURCES: String = "pdsh.brief.sources"
    public const val BRIEF_SOURCE_PREFIX: String = "pdsh.brief.source."
    public const val BRIEF_SOURCE_TOGGLE_PREFIX: String = "pdsh.brief.source.toggle."
    public const val BRIEF_SOURCE_REMOVE_PREFIX: String = "pdsh.brief.source.remove."
    public const val BRIEF_SOURCES_EMPTY: String = "pdsh.brief.sources.empty"
    public const val BRIEF_SOURCES_UNKNOWN: String = "pdsh.brief.sources.unknown"
    public const val BRIEF_ADD_SOURCE: String = "pdsh.brief.source.add"
    public const val BRIEF_REPORT: String = "pdsh.brief.report"
    public const val BRIEF_ISSUES: String = "pdsh.brief.issues"
    public const val BRIEF_ISSUE_PREFIX: String = "pdsh.brief.issue."
    public const val BRIEF_ISSUES_EMPTY: String = "pdsh.brief.issues.empty"
    public const val BRIEF_ISSUES_UNKNOWN: String = "pdsh.brief.issues.unknown"
    public const val BRIEF_EMPTY: String = "pdsh.brief.empty"
    public const val BRIEF_UNKNOWN: String = "pdsh.brief.unknown"
    public const val BRIEF_FAILURE: String = "pdsh.brief.failure"
    public const val BRIEF_UNMEASURED: String = "pdsh.brief.unmeasured"

    public const val TASK_SCREEN_ROOT: String = "pdsh.taskscreen.root"
    public const val TASK_SCREEN_LIST: String = "pdsh.taskscreen.list"
    public const val TASK_SCREEN_DESCRIPTION: String = "pdsh.taskscreen.description"
    public const val TASK_SCREEN_STATUS_FIELD: String = "pdsh.taskscreen.status.field"
    public const val TASK_SCREEN_SHOW: String = "pdsh.taskscreen.show"
    public const val TASK_SCREEN_CLOSE: String = "pdsh.taskscreen.close"
    public const val TASK_SCREEN_REPORT: String = "pdsh.taskscreen.report"
    public const val TASK_SCREEN_PRESENTED: String = "pdsh.taskscreen.presented"
    public const val TASK_SCREEN_BRIGHTNESS: String = "pdsh.taskscreen.brightness"
    public const val TASK_SCREEN_EMPTY: String = "pdsh.taskscreen.empty"
    public const val TASK_SCREEN_UNKNOWN: String = "pdsh.taskscreen.unknown"
    public const val TASK_SCREEN_FAILURE: String = "pdsh.taskscreen.failure"
    public const val TASK_SCREEN_UNMEASURED: String = "pdsh.taskscreen.unmeasured"

    // N5 lane: FilesPage (`FilesPage.swift`), SessionActivityPage
    // (`SessionActivityPage.swift`) and PDSHShellPage (`PDSHShellPage.swift`).
    // Appended only; the tags above belong to other lanes and are never rewritten.
    // One tag per section/row the mirror renders, so a test can assert a section's
    // existence (and its absence) without matching a localised string.
    public const val FILES_ROOT: String = "pdsh.files.root"
    public const val FILES_SEARCH: String = "pdsh.files.search"
    public const val FILES_SECTION: String = "pdsh.files.section"
    public const val FILES_FOLDER_ROW: String = "pdsh.files.folder"
    public const val FILES_FILE_ROW: String = "pdsh.files.row"
    public const val FILES_NONE: String = "pdsh.files.none"
    public const val FILES_DEMO: String = "pdsh.files.demo"

    /** The 3D 示例 sheet's 完成 key (the page owns the sheet's own destination). */
    public const val FILES_DEMO_DONE: String = "pdsh.files.demo.done"
    public const val FILES_PREVIEW_TEXT: String = "pdsh.files.preview.text"
    public const val FILES_PREVIEW_CARD: String = "pdsh.files.preview.card"
    public const val FILES_PREVIEW_SURFACE: String = "pdsh.files.preview.surface"
    public const val FILES_PREVIEW_NOTICE: String = "pdsh.files.preview.notice"
    public const val FILES_PREVIEW_MISSING: String = "pdsh.files.preview.missing"
    public const val FILES_PREVIEW_DONE: String = "pdsh.files.preview.done"
    public const val FILES_PREVIEW_SHARE: String = "pdsh.files.preview.share"

    public const val ACTIVITY_PLAN: String = "pdsh.activity.plan"
    public const val ACTIVITY_PLAN_MODE: String = "pdsh.activity.plan.mode"
    public const val ACTIVITY_PLAN_PENDING: String = "pdsh.activity.plan.pending"
    public const val ACTIVITY_PLAN_NONE: String = "pdsh.activity.plan.none"
    public const val ACTIVITY_TODOS: String = "pdsh.activity.todos"
    public const val ACTIVITY_TODO_ROW: String = "pdsh.activity.todos.row"
    public const val ACTIVITY_TODOS_EMPTY: String = "pdsh.activity.todos.empty"
    public const val ACTIVITY_GOAL: String = "pdsh.activity.goal"
    public const val ACTIVITY_GOAL_PHASE: String = "pdsh.activity.goal.phase"
    public const val ACTIVITY_GOAL_ROUNDS: String = "pdsh.activity.goal.rounds"
    public const val ACTIVITY_GOAL_PAUSE: String = "pdsh.activity.goal.pause"
    public const val ACTIVITY_GOAL_RESUME: String = "pdsh.activity.goal.resume"
    public const val ACTIVITY_GOAL_COMPLETE: String = "pdsh.activity.goal.complete"
    public const val ACTIVITY_GOAL_NONE: String = "pdsh.activity.goal.none"
    public const val ACTIVITY_SUBAGENTS: String = "pdsh.activity.subagents"
    public const val ACTIVITY_SUBAGENT_ROW: String = "pdsh.activity.subagents.row"
    public const val ACTIVITY_SUBAGENTS_EMPTY: String = "pdsh.activity.subagents.empty"
    public const val ACTIVITY_SUBAGENT_INTERRUPT: String = "pdsh.activity.subagents.interrupt"
    public const val ACTIVITY_SCHEDULES: String = "pdsh.activity.schedules"
    public const val ACTIVITY_SCHEDULE_ROW: String = "pdsh.activity.schedules.row"
    public const val ACTIVITY_SCHEDULES_EMPTY: String = "pdsh.activity.schedules.empty"
    public const val ACTIVITY_SCHEDULE_DELETE: String = "pdsh.activity.schedules.delete"
    public const val ACTIVITY_JOBS: String = "pdsh.activity.jobs"
    public const val ACTIVITY_JOB_ROW: String = "pdsh.activity.jobs.row"
    public const val ACTIVITY_JOBS_EMPTY: String = "pdsh.activity.jobs.empty"
    public const val ACTIVITY_JOB_STOP: String = "pdsh.activity.jobs.stop"
    public const val ACTIVITY_SKILLS: String = "pdsh.activity.skills"
    public const val ACTIVITY_SKILL_ROW: String = "pdsh.activity.skills.row"
    public const val ACTIVITY_SKILLS_EMPTY: String = "pdsh.activity.skills.empty"
    public const val ACTIVITY_ERRORS: String = "pdsh.activity.errors"
    public const val ACTIVITY_ERROR_ROW_PREFIX: String = "pdsh.activity.errors."
    public const val ACTIVITY_ERROR_SECTION_PREFIX: String = "pdsh.activity.errors.section."
    public const val ACTIVITY_SESSION_SECTION: String = "pdsh.activity.session"
    public const val ACTIVITY_INTRO: String = "pdsh.activity.intro"
    public const val ACTIVITY_REFRESH: String = "pdsh.activity.refresh"
    public const val ACTIVITY_CONFIRM: String = "pdsh.activity.confirm"
    public const val ACTIVITY_CONFIRM_ACTION: String = "pdsh.activity.confirm.action"
    public const val ACTIVITY_CONFIRM_CANCEL: String = "pdsh.activity.confirm.cancel"
    public const val ACTIVITY_CONFIRM_MESSAGE: String = "pdsh.activity.confirm.message"
    public const val ACTIVITY_UNKNOWN_ROW_PREFIX: String = "pdsh.activity.unknown."

    public const val SHELL_ROOT: String = "pdsh.shell.root"
    public const val SHELL_LIST: String = "pdsh.shell.list"
    public const val SHELL_SECTION_DEVICE: String = "pdsh.shell.section.device"
    public const val SHELL_STATUS: String = "pdsh.shell.status"
    public const val SHELL_NETWORK: String = "pdsh.shell.network"
    public const val SHELL_WORKSPACE: String = "pdsh.shell.workspace"
    public const val SHELL_READ_ONLY: String = "pdsh.shell.readonly"
    public const val SHELL_EMPTY: String = "pdsh.shell.empty"
    public const val SHELL_SECTION_RUN: String = "pdsh.shell.section.run"
    public const val SHELL_COMMAND: String = "pdsh.shell.command"
    public const val SHELL_COMMAND_ROW_PREFIX: String = "pdsh.shell.command."
    public const val SHELL_NEEDS_APP: String = "pdsh.shell.needsapp"
    public const val SHELL_WORKING_DIR: String = "pdsh.shell.workdir"
    public const val SHELL_ARGUMENTS: String = "pdsh.shell.arguments"
    public const val SHELL_RUN: String = "pdsh.shell.run"
    public const val SHELL_CANCEL: String = "pdsh.shell.cancel"
    public const val SHELL_SECTION_OUTPUT: String = "pdsh.shell.section.output"
    public const val SHELL_OUTPUT: String = "pdsh.shell.output"
    public const val SHELL_ERROR: String = "pdsh.shell.error"
    public const val SHELL_SECTION_LIMITS: String = "pdsh.shell.section.limits"
    public const val SHELL_LIMIT_PREFIX: String = "pdsh.shell.limit."

    // N2 lane: SessionsPage's eight baseline sections (drawer + the embedded
    // `SessionQueuePage`). Appended only; the tags above belong to other lanes.
    // One tag per section and per action, so a test can prove a section exists
    // and disappears without matching a localised string.
    public const val SESSIONS_SECTION_EMPTY: String = "pdsh.sessions.section.empty"
    public const val SESSIONS_SESSION_CURRENT: String = "pdsh.sessions.row.current"
    public const val SESSIONS_SESSION_MENU: String = "pdsh.sessions.row.menu"
    public const val SESSIONS_SESSION_RENAME: String = "pdsh.sessions.row.rename"
    public const val SESSIONS_SESSION_ARCHIVE: String = "pdsh.sessions.row.archive"
    public const val SESSIONS_NEW_SESSION_ROW: String = "pdsh.sessions.new.row"
    public const val SESSIONS_NEW_SESSION_BLOCKED: String = "pdsh.sessions.new.blocked"

    public const val SESSIONS_WORKSPACE_ROW: String = "pdsh.sessions.workspace"
    public const val SESSIONS_WORKSPACE_MENU: String = "pdsh.sessions.workspace.menu"
    public const val SESSIONS_WORKSPACE_MENU_ACTIONS: String = "pdsh.sessions.workspace.menu.actions"
    public const val SESSIONS_WORKSPACE_NEW_SESSION: String = "pdsh.sessions.workspace.new"
    public const val SESSIONS_WORKSPACE_RENAME: String = "pdsh.sessions.workspace.rename"
    public const val SESSIONS_WORKSPACE_DELETE: String = "pdsh.sessions.workspace.delete"
    public const val SESSIONS_WORKSPACE_SESSIONS_EMPTY: String = "pdsh.sessions.workspace.empty"
    public const val SESSIONS_WORKSPACE_UNKNOWN: String = "pdsh.sessions.workspace.unknown"
    public const val SESSIONS_WORKSPACE_RENAME_FIELD: String = "pdsh.sessions.workspace.rename.field"
    public const val SESSIONS_WORKSPACE_RENAME_SAVE: String = "pdsh.sessions.workspace.rename.save"
    public const val SESSIONS_WORKSPACE_RENAME_CANCEL: String = "pdsh.sessions.workspace.rename.cancel"
    public const val SESSIONS_WORKSPACE_DELETE_YES: String = "pdsh.sessions.workspace.delete.confirm"
    public const val SESSIONS_WORKSPACE_DELETE_NO: String = "pdsh.sessions.workspace.delete.cancel"

    public const val SESSIONS_ADD_WORKSPACE: String = "pdsh.sessions.add.workspace"
    public const val SESSIONS_NEW_WORKSPACE: String = "pdsh.sessions.new.workspace"
    public const val SESSIONS_NEW_WORKSPACE_FIELD: String = "pdsh.sessions.new.workspace.field"
    public const val SESSIONS_NEW_WORKSPACE_CREATE: String = "pdsh.sessions.new.workspace.create"
    public const val SESSIONS_NEW_WORKSPACE_CANCEL: String = "pdsh.sessions.new.workspace.cancel"

    public const val SESSIONS_ARCHIVED_SECTION: String = "pdsh.sessions.archived.section"
    public const val SESSIONS_ARCHIVED_EMPTY: String = "pdsh.sessions.archived.empty"
    public const val SESSIONS_ARCHIVED_UNKNOWN: String = "pdsh.sessions.archived.unknown"
    public const val SESSIONS_ARCHIVED_ROW: String = "pdsh.sessions.archived.row"
    public const val SESSIONS_ARCHIVED_RESTORE: String = "pdsh.sessions.archived.restore"

    public const val SESSIONS_REFRESH: String = "pdsh.sessions.refresh"
    public const val SESSION_QUEUE_REFRESH: String = "pdsh.sessions.queue.refresh"

    public const val SESSION_QUEUE_ROOT: String = "pdsh.sessions.queue.root"
    public const val SESSION_QUEUE_LIST: String = "pdsh.sessions.queue.list"
    public const val SESSION_QUEUE_LOADING: String = "pdsh.sessions.queue.loading"
    public const val SESSION_QUEUE_EMPTY: String = "pdsh.sessions.queue.empty"
    public const val SESSION_QUEUE_SECTION: String = "pdsh.sessions.queue.section"
    public const val SESSION_QUEUE_ROW: String = "pdsh.sessions.queue.row"
    public const val SESSION_QUEUE_EDIT: String = "pdsh.sessions.queue.edit"
    public const val SESSION_QUEUE_STEER: String = "pdsh.sessions.queue.steer"
    public const val SESSION_QUEUE_REMOVE: String = "pdsh.sessions.queue.remove"
    public const val SESSION_QUEUE_EDIT_FIELD: String = "pdsh.sessions.queue.edit.field"
    public const val SESSION_QUEUE_SAVE: String = "pdsh.sessions.queue.save"
    public const val SESSION_QUEUE_CANCEL: String = "pdsh.sessions.queue.cancel"
    public const val SESSION_QUEUE_ERROR: String = "pdsh.sessions.queue.error"

    // N6 probe family: tags appended for the restored baseline controls.
    public const val PROBES_MENU: String = "pdsh.probes.menu"
    public const val PROBES_MENU_LIST: String = "pdsh.probes.menu.list"
    public const val PROBES_PROGRESS: String = "pdsh.probes.progress"
    public const val PROBES_LOCKDOWN: String = "pdsh.probes.lockdown"
    public const val PROBES_ANCHOR: String = "pdsh.probes.anchor"
    public const val PROBES_ENVIRONMENT_NOTE: String = "pdsh.probes.environment.note"

    public const val BACKGROUND_MATRIX_CELL: String = "pdsh.background.matrix.cell"
    public const val BACKGROUND_LOCKDOWN: String = "pdsh.background.lockdown"
    public const val BACKGROUND_ANCHOR: String = "pdsh.background.anchor"
    public const val BACKGROUND_CONTINUED_SWITCH: String = "pdsh.background.continued"
    public const val BACKGROUND_REQUIRED_PICKER: String = "pdsh.background.required"
    public const val BACKGROUND_INSTRUCTION: String = "pdsh.background.instruction"
    public const val BACKGROUND_BUNDLE_HINT: String = "pdsh.background.bundle"
    public const val BACKGROUND_NOTE: String = "pdsh.background.note"

    public const val BRIEF_HEADER: String = "pdsh.brief.header"
    public const val BRIEF_SOURCE_SWIPE_PREFIX: String = "pdsh.brief.source.swipe."
    public const val BRIEF_SOURCE_SWITCH_PREFIX: String = "pdsh.brief.source.switch."
    public const val BRIEF_EMPTY_ICON: String = "pdsh.brief.empty.icon"

    public const val TASK_SCREEN_SLIDER: String = "pdsh.taskscreen.slider"
    public const val BRIEF_SOURCE_EDITOR: String = "pdsh.brief.source.editor"
    public const val BRIEF_SOURCE_NAME_FIELD: String = "pdsh.brief.source.name"
    public const val BRIEF_SOURCE_URL_FIELD: String = "pdsh.brief.source.url"
    public const val BRIEF_SOURCE_ADD_CONFIRM: String = "pdsh.brief.source.add.confirm"
    public const val BRIEF_SOURCE_ADD_CANCEL: String = "pdsh.brief.source.add.cancel"

    // N3 lane: the chat page head, the transcript chrome, the composer dock and
    // the message rows. Appended only; the tags above belong to other lanes.
    public const val CHAT_HEADER_DRAWER: String = "pdsh.chat.header.drawer"
    public const val CHAT_HEADER_TITLE: String = "pdsh.chat.header.title"
    public const val CHAT_HEADER_RUN_STATUS: String = "pdsh.chat.header.run-status"
    public const val CHAT_HEADER_MENU: String = "pdsh.chat.header.menu"
    public const val CHAT_RENAME_FIELD: String = "pdsh.chat.rename.field"
    public const val CHAT_RENAME_OVERLAY: String = "pdsh.chat.rename.overlay"
    public const val CHAT_RENAME_SAVE: String = "pdsh.chat.rename.save"
    public const val CHAT_RENAME_CANCEL: String = "pdsh.chat.rename.cancel"

    public const val CHAT_BANNER_ACCESS_MODE: String = "pdsh.chat.banner.access-mode"
    public const val CHAT_BANNER_COMMANDS: String = "pdsh.chat.banner.commands"
    public const val CHAT_FAILURE_LINE: String = "pdsh.chat.failure-line"

    public const val CHAT_PENDING_FOLD: String = "pdsh.chat.pending.fold"
    public const val CHAT_PENDING_MORE: String = "pdsh.chat.pending.more"
    public const val CHAT_QUESTION_ANSWER: String = "pdsh.chat.question.answer"
    public const val CHAT_QUESTION_SUBMIT: String = "pdsh.chat.question.submit"

    public const val CHAT_LOAD_EARLIER: String = "pdsh.chat.load-earlier"
    public const val CHAT_TRANSCRIPT_ERROR: String = "pdsh.chat.transcript.error"
    public const val CHAT_CACHED_NOTICE: String = "pdsh.chat.transcript.cached"
    public const val CHAT_BACK_TO_LATEST: String = "pdsh.chat.back-to-latest"
    public const val CHAT_EMPTY_ENGINE: String = "pdsh.chat.empty.engine"
    public const val CHAT_EMPTY_PROVIDER: String = "pdsh.chat.empty.provider"
    public const val CHAT_EMPTY_READY: String = "pdsh.chat.empty.ready"
    public const val CHAT_START_ENGINE: String = "pdsh.chat.empty.start"
    public const val CHAT_PROVIDER_SETUP: String = "pdsh.chat.empty.provider-action"

    public const val CHAT_ROW_USER: String = "pdsh.chat.row.user"
    public const val CHAT_ROW_ASSISTANT: String = "pdsh.chat.row.assistant"
    public const val CHAT_ROW_THINKING: String = "pdsh.chat.row.thinking"
    public const val CHAT_ROW_TOOL: String = "pdsh.chat.row.tool"
    public const val CHAT_ROW_TOOL_FILE: String = "pdsh.chat.row.tool.file"
    public const val CHAT_ROW_CONTEXT: String = "pdsh.chat.row.context"
    public const val CHAT_ROW_SYSTEM: String = "pdsh.chat.row.system"
    public const val CHAT_MESSAGE_COPY: String = "pdsh.chat.row.copy"

    public const val COMPOSER_ATTACHMENTS: String = "pdsh.composer.attachments"
    public const val COMPOSER_SLASH_MENU: String = "pdsh.composer.slash-menu"
    public const val COMPOSER_REFERENCE_MENU: String = "pdsh.composer.reference-menu"
    public const val COMPOSER_ADD: String = "pdsh.composer.add"
    public const val COMPOSER_ACCESS_MODE: String = "pdsh.composer.access-mode"
    public const val COMPOSER_MODEL_MENU: String = "pdsh.composer.model-menu"
    public const val CHAT_COMPOSER_NOTICE: String = "pdsh.composer.notice"

    // -----------------------------------------------------------------------
    // Appended by the C2 lane: the egress editor's controls and the workspace
    // empty state's call to action. One tag per baseline control so the tests
    // address the same affordance the contract names.
    // -----------------------------------------------------------------------

    // Egress allow list (`NativeShell.swift:466`-`:670`).
    public const val EGRESS_ALLOW_ALL_TOGGLE: String = "pdsh.egress.allow-all.toggle"
    public const val EGRESS_ALLOW_ALL_FOOTER: String = "pdsh.egress.allow-all.footer"
    public const val EGRESS_HOST_NOTICE: String = "pdsh.egress.host-notice"
    public const val EGRESS_RESTORE: String = "pdsh.egress.restore"
    public const val EGRESS_ADD: String = "pdsh.egress.add"
    public const val EGRESS_ADD_OVERLAY: String = "pdsh.egress.add.overlay"
    public const val EGRESS_ADD_FIELD: String = "pdsh.egress.add.field"
    public const val EGRESS_ADD_PROBLEM: String = "pdsh.egress.add.problem"
    public const val EGRESS_ADD_CONFIRM: String = "pdsh.egress.add.confirm"
    public const val EGRESS_ADD_CANCEL: String = "pdsh.egress.add.cancel"
    public const val EGRESS_RULE_DELETE: String = "pdsh.egress.rule.delete"
    public const val EGRESS_DELETE_DIALOG: String = "pdsh.egress.delete.dialog"
    public const val EGRESS_DELETE_CONFIRM: String = "pdsh.egress.delete.confirm"
    public const val EGRESS_DELETE_CANCEL: String = "pdsh.egress.delete.cancel"

    // Workspace folders (`NativeShell.swift:356`).
    public const val WORKSPACE_ADD_FOLDER: String = "pdsh.workspace.add-folder"

    // -----------------------------------------------------------------------
    // Appended by the L5 lane: the three device-connector pages. One tag per node
    // the device evidence and the JVM tests address, named exactly like the rows
    // of the iOS pages they mirror.
    // -----------------------------------------------------------------------

    // 设备连接 (`NativeDeviceConnectionPage.swift:25-172`).
    public const val DEVICE_ROOT: String = "pdsh.device.root"
    public const val DEVICE_SOURCE: String = "pdsh.device.source"
    public const val DEVICE_FAILURE: String = "pdsh.device.failure"
    public const val DEVICE_FORGET: String = "pdsh.device.forget"
    public const val DEVICE_UNAVAILABLE: String = "pdsh.device.unavailable"
    public const val DEVICE_LIST: String = "pdsh.device.list"
    public const val DEVICE_EMPTY: String = "pdsh.device.empty"
    public const val DEVICE_ROW: String = "pdsh.device.row"
    public const val DEVICE_SECTION_TRANSPORT: String = "pdsh.device.transport"
    public const val DEVICE_TRANSPORT_ROW: String = "pdsh.device.transport.row"
    public const val DEVICE_TRANSPORT_FOOTER: String = "pdsh.device.transport.footer"
    public const val DEVICE_DONE: String = "pdsh.device.done"

    // 设备会话 (`NativeDeviceSessionPage.swift:362-441`).
    public const val DEVICE_SESSION_ROOT: String = "pdsh.device.session.root"
    public const val DEVICE_SESSION_STRIP: String = "pdsh.device.session.strip"
    public const val DEVICE_SESSION_FAILURE: String = "pdsh.device.session.failure"
    public const val DEVICE_SESSION_LIST: String = "pdsh.device.session.list"
    public const val DEVICE_SESSION_EMPTY: String = "pdsh.device.session.empty"
    public const val DEVICE_SESSION_READ_EARLIER: String = "pdsh.device.session.read-earlier"
    public const val DEVICE_SESSION_ROW: String = "pdsh.device.session.row"
    public const val DEVICE_SESSION_READ_ONLY: String = "pdsh.device.session.read-only"

    // 本 session 产物 (`SessionArtifactsPage.swift:31-188`).
    public const val ARTIFACTS_ROOT: String = "pdsh.artifacts.root"
    public const val ARTIFACTS_LIST: String = "pdsh.artifacts.list"
    public const val ARTIFACTS_EMPTY: String = "pdsh.artifacts.empty"
    public const val ARTIFACTS_LOADING: String = "pdsh.artifacts.loading"
    public const val ARTIFACTS_FAILURE: String = "pdsh.artifacts.failure"
    public const val ARTIFACTS_SESSION_SECTION: String = "pdsh.artifacts.session"
    public const val ARTIFACTS_UNASSIGNED_SECTION: String = "pdsh.artifacts.unassigned"
    // The 无法打开产物 alert (`SessionArtifactsPage.swift:104`–`:111`).
    public const val ARTIFACTS_OPEN_ALERT: String = "pdsh.artifacts.open.alert"
    public const val ARTIFACTS_OPEN_ALERT_ACTION: String = "pdsh.artifacts.open.alert.action"
    public const val ARTIFACTS_ROW: String = "pdsh.artifacts.row"
    public const val ARTIFACTS_UNASSIGNED_FOOTER: String = "pdsh.artifacts.unassigned.footer"
    // -----------------------------------------------------------------------
    // L14 lane: the three B-group pages (appended, never reordered).
    // -----------------------------------------------------------------------

    // Agent 预设.
    public const val AGENT_PRESETS_LIST: String = "pdsh.agent.presets.list"
    public const val AGENT_PRESETS_CREATOR: String = "pdsh.agent.presets.creator"
    public const val AGENT_PRESETS_LOADING: String = "pdsh.agent.presets.loading"
    public const val AGENT_PRESETS_UNREAD: String = "pdsh.agent.presets.unread"
    public const val AGENT_PRESETS_ERROR: String = "pdsh.agent.presets.error"
    public const val AGENT_PRESETS_DOCUMENT: String = "pdsh.agent.presets.document"
    public const val AGENT_PRESETS_ROW_PREFIX: String = "pdsh.agent.presets.row."

    // 内置插件.
    public const val PLUGIN_INVENTORY_LIST: String = "pdsh.plugin.inventory.list"
    public const val PLUGIN_INVENTORY_READ_ONLY: String = "pdsh.plugin.inventory.read-only"
    public const val PLUGIN_INVENTORY_SEARCH: String = "pdsh.plugin.inventory.search"
    public const val PLUGIN_INVENTORY_LOADING: String = "pdsh.plugin.inventory.loading"
    public const val PLUGIN_INVENTORY_EMPTY: String = "pdsh.plugin.inventory.empty"
    public const val PLUGIN_INVENTORY_UNREAD: String = "pdsh.plugin.inventory.unread"
    public const val PLUGIN_INVENTORY_FAILURE: String = "pdsh.plugin.inventory.failure"
    public const val PLUGIN_INVENTORY_RETRY: String = "pdsh.plugin.inventory.retry"
    public const val PLUGIN_INVENTORY_NOTICE: String = "pdsh.plugin.inventory.notice"
    public const val PLUGIN_INVENTORY_ROW_PREFIX: String = "pdsh.plugin.inventory.row."
    public const val PLUGIN_INVENTORY_ROW_HEADER: String = "pdsh.plugin.inventory.header."

    // 手机权限.
    public const val PHONE_PERMISSIONS_LIST: String = "pdsh.phone.permissions.list"
    public const val PHONE_PERMISSIONS_AUDIT: String = "pdsh.phone.permissions.audit"
    public const val PHONE_PERMISSIONS_AUDIT_EMPTY: String = "pdsh.phone.permissions.audit.empty"
    public const val PHONE_PERMISSIONS_ROW_PREFIX: String = "pdsh.phone.permissions.row."
    public const val PHONE_PERMISSIONS_TOGGLE_PREFIX: String = "pdsh.phone.permissions.toggle."
    public const val PHONE_PERMISSIONS_CONFIRM_CONTINUE: String = "pdsh.phone.permissions.confirm"
    public const val PHONE_PERMISSIONS_CONFIRM_CANCEL: String = "pdsh.phone.permissions.cancel"
    public const val PHONE_PERMISSIONS_DISABLE_ACK: String = "pdsh.phone.permissions.disable.ack"
    public const val PHONE_PERMISSIONS_DISABLE_SETTINGS: String = "pdsh.phone.permissions.disable.settings"

    // -----------------------------------------------------------------------
    // Appended by the L13 lane: the three pages this lane added. One tag per
    // node the device evidence and the JVM tests address.
    // -----------------------------------------------------------------------

    // 聊天外观 (`ChatPreferencesPage.swift`).
    public const val CHAT_PREFERENCES_ROOT: String = "pdsh.chat-preferences.root"
    public const val CHAT_PREFERENCES_LIST: String = "pdsh.chat-preferences.list"
    public const val CHAT_PREFERENCES_DONE: String = "pdsh.chat-preferences.done"
    public const val CHAT_PREFERENCES_SECTION_PREFIX: String = "pdsh.chat-preferences.section."
    public const val CHAT_PREFERENCES_ROW_PREFIX: String = "pdsh.chat-preferences.row."
    public const val CHAT_PREFERENCES_OPTION_PREFIX: String = "pdsh.chat-preferences.option."
    public const val CHAT_PREFERENCES_STEPPER_PREFIX: String = "pdsh.chat-preferences.stepper."

    // 配置文件 (`NativeSettingsDocumentPage.swift`).
    public const val SETTINGS_DOCUMENT_ROOT: String = "pdsh.settings-document.root"
    public const val SETTINGS_DOCUMENT_NOTE: String = "pdsh.settings-document.note"
    public const val SETTINGS_DOCUMENT_STATUS: String = "pdsh.settings-document.status"
    public const val SETTINGS_DOCUMENT_BODY: String = "pdsh.settings-document.body"
    public const val SETTINGS_DOCUMENT_READ_ONLY: String = "pdsh.settings-document.read-only"
    public const val SETTINGS_DOCUMENT_SHARE: String = "pdsh.settings-document.share"
    public const val SETTINGS_DOCUMENT_DONE: String = "pdsh.settings-document.done"

    // 快捷键 (`NativeShortcutsPage.swift`).
    public const val SHORTCUTS_ROOT: String = "pdsh.shortcuts.root"
    public const val SHORTCUTS_LIST: String = "pdsh.shortcuts.list"
    public const val SHORTCUTS_BACK: String = "pdsh.shortcuts.back"
    public const val SHORTCUTS_COMMAND_PREFIX: String = "pdsh.shortcuts.command."
    public const val SHORTCUTS_FIXED_PREFIX: String = "pdsh.shortcuts.fixed."
    public const val SHORTCUTS_RESET: String = "pdsh.shortcuts.reset"
    public const val SHORTCUTS_HINT: String = "pdsh.shortcuts.hint"

    // L18 lane: the two MCP pages' contract groups and verbs
    // (`spec/ui/v1/pages/mcp-settings.json`, `mcp-editor.json`). Appended only;
    // the settings-family tags above belong to the Q3 lane.
    public const val MCP_ACTIONS_SECTION: String = "pdsh.mcp.actions"
    public const val MCP_ACTION_REFRESH: String = "pdsh.mcp.action.refresh"
    public const val MCP_ACTION_ADD_SERVER: String = "pdsh.mcp.action.add-server"
    public const val MCP_LAN_SECTION: String = "pdsh.mcp.lan"
    public const val MCP_LAN_SCAN: String = "pdsh.mcp.lan.scan"
    public const val MCP_LAN_STATUS: String = "pdsh.mcp.lan.status"
    public const val MCP_LAN_CANDIDATES: String = "pdsh.mcp.lan.candidates"
    public const val MCP_LAN_CANDIDATE_PREFIX: String = "pdsh.mcp.lan.candidate."
    public const val MCP_LAN_NOTE: String = "pdsh.mcp.lan.note"
    public const val MCP_EDITOR_SERVER_SECTION: String = "pdsh.mcp.editor.server-section"
    public const val MCP_EDITOR_AUTH_SECTION: String = "pdsh.mcp.editor.auth-section"
    public const val MCP_EDITOR_TIMEOUT: String = "pdsh.mcp.editor.timeout"
    public const val MCP_EDITOR_ADD_HEADER: String = "pdsh.mcp.editor.add-header"
    public const val MCP_EDITOR_DELETE: String = "pdsh.mcp.editor.delete"
    public const val MCP_EDITOR_HEADER_PREFIX: String = "pdsh.mcp.editor.header."
    public const val MCP_EDITOR_HEADER_NAME_SUFFIX: String = ".name"
    public const val MCP_EDITOR_HEADER_ENV_SUFFIX: String = ".env"
    public const val MCP_EDITOR_HEADER_VALUE_SUFFIX: String = ".value"
    public const val MCP_EDITOR_HEADER_REMOVE_SUFFIX: String = ".remove"

    // L16 lane: `NativeConfigurationPage`'s contract controls. Appended only.
    /** The 内置插件设置 master fold above the host's built-in setting groups. */
    public const val CONFIGURATION_BUILT_IN: String = "pdsh.configuration.built-in"
    /** The 插件说明 verb that opens the about area (the baseline's sheet). */
    public const val CONFIGURATION_PLUGIN_INFO_ACTION: String = "pdsh.configuration.action.plugin-info"
    /** The 添加插件 verb that opens its two-item menu. */
    public const val CONFIGURATION_ADD_PLUGIN: String = "pdsh.configuration.action.add-plugin"
    /** The measured sentence the two add-plugin items print (they cannot run here). */
    public const val CONFIGURATION_ADD_NOTICE: String = "pdsh.configuration.add.notice"
    /** The permission block that replaced the old 新会话默认权限 section. */
    public const val CONFIGURATION_PERMISSION: String = "pdsh.configuration.permission"
    public const val CONFIGURATION_PERMISSION_ROW: String = "pdsh.configuration.permission.row"
    /** The startup-lock explanation shown when the per-field write is disabled. */
    public const val CONFIGURATION_PERMISSION_READ_ONLY: String = "pdsh.configuration.permission.read-only"
    public const val CONFIGURATION_PERMISSION_SAVE: String = "pdsh.configuration.permission.save"
    public const val CONFIGURATION_PERMISSION_DISCARD: String = "pdsh.configuration.permission.discard"
    public const val CONFIGURATION_GROUP_SAVE_PREFIX: String = "pdsh.configuration.group.save."
    public const val CONFIGURATION_GROUP_DISCARD_PREFIX: String = "pdsh.configuration.group.discard."
    public const val CONFIGURATION_ROW_RESET_PREFIX: String = "pdsh.configuration.reset."

    // L25 lane: the two embedded subpages (README §1 「内嵌子页随父页实现」).
    // Appended only: the tags above belong to other lanes and are never rewritten.

    // ScheduleEditorPage: the form's sections, its fields and its two verbs.
    public const val AUTOMATION_EDITOR_ROOT: String = "pdsh.automation.editor.root"
    public const val AUTOMATION_EDITOR_LIST: String = "pdsh.automation.editor.list"
    public const val AUTOMATION_EDITOR_CONTENT_SECTION: String = "pdsh.automation.editor.content"
    public const val AUTOMATION_EDITOR_TIMING_SECTION: String = "pdsh.automation.editor.timing"
    public const val AUTOMATION_EDITOR_NAME: String = "pdsh.automation.editor.name"
    public const val AUTOMATION_EDITOR_PROMPT: String = "pdsh.automation.editor.prompt"
    public const val AUTOMATION_EDITOR_CHANGE_TIMING: String = "pdsh.automation.editor.change-timing"
    public const val AUTOMATION_EDITOR_CURRENT_RULE: String = "pdsh.automation.editor.current-rule"
    public const val AUTOMATION_EDITOR_RULE: String = "pdsh.automation.editor.rule"
    public const val AUTOMATION_EDITOR_RULE_DIALOG: String = "pdsh.automation.editor.rule.dialog"
    /** The rule chooser's option tag; the rule's `wire` word is appended. */
    public const val AUTOMATION_EDITOR_RULE_OPTION_PREFIX: String = "pdsh.automation.editor.rule.option."
    /** The rule-field tag; the field's own suffix is appended. */
    public const val AUTOMATION_EDITOR_FIELD_PREFIX: String = "pdsh.automation.editor.field."
    public const val AUTOMATION_EDITOR_ERROR: String = "pdsh.automation.editor.error"
    public const val AUTOMATION_EDITOR_SAVE: String = "pdsh.automation.editor.save"
    public const val AUTOMATION_EDITOR_CANCEL: String = "pdsh.automation.editor.cancel"
    public const val AUTOMATION_EDITOR_HANDOFF: String = "pdsh.automation.editor.handoff"

    // SessionArtifactPreviewPage: the preview body and its one verb.
    public const val ARTIFACTS_PREVIEW_ROOT: String = "pdsh.artifacts.preview.root"
    public const val ARTIFACTS_PREVIEW_NAME: String = "pdsh.artifacts.preview.name"
    public const val ARTIFACTS_PREVIEW_FALLBACK: String = "pdsh.artifacts.preview.fallback"
    public const val ARTIFACTS_PREVIEW_SHARE: String = "pdsh.artifacts.preview.share"

    // L24 lane: the chat family's three embedded subpages (`ChatPage.swift:3504`,
    // `:3554`, `:4243`). Appended only; the `pdsh.chat.*` tags above belong to the
    // parent page, these three name the surfaces the page presents on top of it.
    // The empty and unread hints merge their descendants into one spoken node, so
    // each gets its own tag: a test asserts which of the two states rendered, not
    // the words, exactly as `SESSIONS_WORKSPACE_UNKNOWN` does.
    public const val CHAT_COMMAND_RESULT_ROOT: String = "pdsh.chat.command-result.root"
    public const val CHAT_COMMAND_RESULT_STATUS: String = "pdsh.chat.command-result.status"
    public const val CHAT_COMMAND_RESULT_LINE: String = "pdsh.chat.command-result.line"
    public const val CHAT_COMMAND_RESULT_OUTPUT: String = "pdsh.chat.command-result.output"
    public const val CHAT_COMMAND_RESULT_BODY: String = "pdsh.chat.command-result.body"
    public const val CHAT_COMMAND_RESULT_UNREAD: String = "pdsh.chat.command-result.unread"

    public const val CHAT_JOBS_SHEET_ROOT: String = "pdsh.chat.jobs.root"
    public const val CHAT_JOBS_SHEET_LIST: String = "pdsh.chat.jobs.list"
    public const val CHAT_JOBS_SHEET_EMPTY: String = "pdsh.chat.jobs.empty"
    public const val CHAT_JOBS_SHEET_UNREAD: String = "pdsh.chat.jobs.unread"
    public const val CHAT_JOBS_SHEET_ROW_PREFIX: String = "pdsh.chat.jobs.row."

    public const val CHAT_SCHEDULES_SHEET_ROOT: String = "pdsh.chat.schedules.root"
    public const val CHAT_SCHEDULES_SHEET_LIST: String = "pdsh.chat.schedules.list"
    public const val CHAT_SCHEDULES_SHEET_EMPTY: String = "pdsh.chat.schedules.empty"
    public const val CHAT_SCHEDULES_SHEET_UNREAD: String = "pdsh.chat.schedules.unread"
    public const val CHAT_SCHEDULES_SHEET_ROW_PREFIX: String = "pdsh.chat.schedules.row."

    // L29 lane: the one preview face (`PreviewSurface.swift` of the iOS PR #15).
    // Appended only; the `pdsh.files.preview.*` tags above belong to the files
    // page's in-page preview body, these name the surface a pushed route renders.
    // A test asserts *which* honest state rendered, never the words, so the four
    // states get four tags rather than one card tag with a text lookup.
    public const val PREVIEW_ROOT: String = "pdsh.preview.root"
    public const val PREVIEW_TITLE: String = "pdsh.preview.title"
    public const val PREVIEW_LOADING: String = "pdsh.preview.loading"
    public const val PREVIEW_FAILED: String = "pdsh.preview.failed"
    public const val PREVIEW_RETRY: String = "pdsh.preview.retry"
    public const val PREVIEW_UNSUPPORTED: String = "pdsh.preview.unsupported"
    public const val PREVIEW_SHARE: String = "pdsh.preview.share"
    public const val PREVIEW_SHARE_FILE: String = "pdsh.preview.share.file"
    public const val PREVIEW_TEXT: String = "pdsh.preview.text"
    public const val PREVIEW_MARKDOWN: String = "pdsh.preview.markdown"
    public const val PREVIEW_IMAGE: String = "pdsh.preview.image"
    public const val PREVIEW_PDF: String = "pdsh.preview.pdf"
    public const val PREVIEW_LOAD_MORE: String = "pdsh.preview.load.more"
    public const val PREVIEW_LOADING_MORE: String = "pdsh.preview.loading.more"
    public const val PREVIEW_NOTICE: String = "pdsh.preview.notice"
    public const val PREVIEW_PROGRESS: String = "pdsh.preview.progress"

    // Appended by the L32 lane: the two media bodies and the transport they share.
    // `pdsh.preview.video` marks the video body (and its `TextureView` surface),
    // `pdsh.preview.audio` the card; the three transport tags are deliberately
    // body-agnostic, because 播放 / 暂停 / the clock mean the same thing in both.
    public const val PREVIEW_VIDEO: String = "pdsh.preview.video"
    public const val PREVIEW_AUDIO: String = "pdsh.preview.audio"
    public const val PREVIEW_MEDIA_NAME: String = "pdsh.preview.media.name"
    public const val PREVIEW_MEDIA_DURATION: String = "pdsh.preview.media.duration"
    public const val PREVIEW_MEDIA_TIME: String = "pdsh.preview.media.time"
    public const val PREVIEW_PLAY: String = "pdsh.preview.play"

    // -----------------------------------------------------------------------
    // Appended by the PR14/PR22 alignment lane: the stable nodes the PR22
    // home, drawer, grouped settings, provider editor, composer and docks
    // address in tests. Appended only; no tag above is renamed. Values are
    // semantic ids, never localised copy.
    // -----------------------------------------------------------------------

    // Home page and drawer (PR22 `ChatPage.swift` chatHeader, `HomeDrawer.swift`)
    public const val HOME_ROOT: String = "pdsh.home.root"
    public const val HOME_HEADER: String = "pdsh.home.header"
    public const val HOME_TITLE: String = "pdsh.home.title"
    public const val HOME_FOLDER_SUBTITLE: String = "pdsh.home.folder"
    public const val HOME_DEVICE: String = "pdsh.home.device"
    public const val HOME_MORE: String = "pdsh.home.more"
    public const val HOME_MENU: String = "pdsh.home.menu"
    public const val DRAWER_ROOT: String = "pdsh.drawer.root"
    public const val DRAWER_SCRIM: String = "pdsh.drawer.scrim"
    public const val DRAWER_NEW_SESSION: String = "pdsh.drawer.new-session"
    public const val DRAWER_SCHEDULES: String = "pdsh.drawer.schedules"
    public const val DRAWER_SETTINGS: String = "pdsh.drawer.settings"
    public const val DRAWER_FOLDER_SECTION: String = "pdsh.drawer.folders"
    public const val DRAWER_FOLDER_ADD: String = "pdsh.drawer.folder.add"
    public const val DRAWER_FOLDER_ROW_PREFIX: String = "pdsh.drawer.folder.row."
    public const val DRAWER_FOLDER_MENU_PREFIX: String = "pdsh.drawer.folder.menu."
    public const val DRAWER_SESSION_ROW_PREFIX: String = "pdsh.drawer.session.row."
    public const val DRAWER_SESSION_MENU_PREFIX: String = "pdsh.drawer.session.menu."
    public const val DRAWER_ARCHIVED_TOAST: String = "pdsh.drawer.archived-toast"
    public const val DRAWER_ENGINE_STATE: String = "pdsh.drawer.engine"
    public const val DRAWER_NEW_FOLDER_DIALOG: String = "pdsh.drawer.new-folder.dialog"
    public const val DRAWER_NEW_FOLDER_FIELD: String = "pdsh.drawer.new-folder.field"
    public const val DRAWER_NEW_FOLDER_CREATE: String = "pdsh.drawer.new-folder.create"
    public const val DRAWER_NEW_FOLDER_CANCEL: String = "pdsh.drawer.new-folder.cancel"
    public const val DRAWER_RENAME_SESSION_DIALOG: String = "pdsh.drawer.rename-session.dialog"
    public const val DRAWER_RENAME_SESSION_FIELD: String = "pdsh.drawer.rename-session.field"
    public const val DRAWER_RENAME_SESSION_SAVE: String = "pdsh.drawer.rename-session.save"
    public const val DRAWER_RENAME_SESSION_CANCEL: String = "pdsh.drawer.rename-session.cancel"
    public const val DRAWER_RENAME_FOLDER_DIALOG: String = "pdsh.drawer.rename-folder.dialog"
    public const val DRAWER_RENAME_FOLDER_FIELD: String = "pdsh.drawer.rename-folder.field"
    public const val DRAWER_DELETE_FOLDER_DIALOG: String = "pdsh.drawer.delete-folder.dialog"
    public const val DRAWER_DELETE_FOLDER_CONFIRM: String = "pdsh.drawer.delete-folder.confirm"
    public const val DRAWER_DELETE_FOLDER_CANCEL: String = "pdsh.drawer.delete-folder.cancel"

    // Grouped settings index and its sub-pages (PR22 `SettingsPage.swift`)
    public const val SETTINGS_INDEX: String = "pdsh.settings.index"
    public const val SETTINGS_INDEX_GROUP_PREFIX: String = "pdsh.settings.index.group."
    public const val SETTINGS_INDEX_ROW_PREFIX: String = "pdsh.settings.index.row."
    public const val SETTINGS_INDEX_VALUE_PREFIX: String = "pdsh.settings.index.value."
    public const val SETTINGS_ENGINE_RESET: String = "pdsh.settings.engine-reset"
    public const val SETTINGS_ARCHIVED_ROOT: String = "pdsh.settings.archived.root"
    public const val SETTINGS_ARCHIVED_EMPTY: String = "pdsh.settings.archived.empty"
    public const val SETTINGS_ARCHIVED_ROW: String = "pdsh.settings.archived.row"
    public const val SETTINGS_ARCHIVED_RESTORE: String = "pdsh.settings.archived.restore"
    public const val SETTINGS_WORK_DETAILS_ROOT: String = "pdsh.settings.work-details.root"
    public const val SETTINGS_WORK_DETAILS_ROW_PREFIX: String = "pdsh.settings.work-details.row."
    public const val SETTINGS_FONT_SIZE_ROOT: String = "pdsh.settings.font-size.root"
    public const val SETTINGS_FONT_SIZE_ROW_PREFIX: String = "pdsh.settings.font-size.row."

    // Provider editor (PR22 `ModelProviderSettingsPage.swift`)
    public const val PROVIDER_EDITOR_ROOT: String = "pdsh.provider.editor.root"
    public const val PROVIDER_EDITOR_NAME: String = "pdsh.provider.editor.name"
    public const val PROVIDER_EDITOR_KEY: String = "pdsh.provider.editor.key"
    public const val PROVIDER_EDITOR_URL: String = "pdsh.provider.editor.url"
    public const val PROVIDER_EDITOR_PASTE: String = "pdsh.provider.editor.paste"
    public const val PROVIDER_EDITOR_FETCH: String = "pdsh.provider.editor.fetch"
    public const val PROVIDER_EDITOR_MODEL: String = "pdsh.provider.editor.model"
    public const val PROVIDER_EDITOR_ADVANCED: String = "pdsh.provider.editor.advanced"
    public const val PROVIDER_EDITOR_TEST: String = "pdsh.provider.editor.test"
    public const val PROVIDER_EDITOR_SAVE: String = "pdsh.provider.editor.save"
    public const val PROVIDER_EDITOR_CANCEL: String = "pdsh.provider.editor.cancel"
    public const val PROVIDER_EDITOR_ERROR: String = "pdsh.provider.editor.error"
    public const val PROVIDER_EDITOR_CATALOG: String = "pdsh.provider.editor.catalog"
    public const val PROVIDER_EDITOR_KEY_STATE: String = "pdsh.provider.editor.key-state"
    public const val PROVIDER_EDITOR_ADD_MODEL: String = "pdsh.provider.editor.add-model"
    public const val PROVIDER_EDITOR_ROW_PREFIX: String = "pdsh.provider.editor.row."

    // Composer row, queue editor and docks (PR22 `ChatPage.swift`, `NativeQuestionComposer.swift`, `NativeTodoDock.swift`, `NativePlan*.swift`)
    public const val COMPOSER_ROW: String = "pdsh.composer.row"
    public const val COMPOSER_QUEUE_ACTION: String = "pdsh.composer.queue-action"
    public const val COMPOSER_RETRY: String = "pdsh.composer.retry"
    public const val COMPOSER_QUEUE_EDIT_DIALOG: String = "pdsh.composer.queue.edit.dialog"
    public const val COMPOSER_QUEUE_EDIT_FIELD: String = "pdsh.composer.queue.edit.field"
    public const val COMPOSER_QUEUE_EDIT_SAVE: String = "pdsh.composer.queue.edit.save"
    public const val COMPOSER_QUEUE_EDIT_CANCEL: String = "pdsh.composer.queue.edit.cancel"
    public const val DOCK_QUESTION: String = "pdsh.dock.question"
    public const val DOCK_QUESTION_PREV: String = "pdsh.dock.question.prev"
    public const val DOCK_QUESTION_NEXT: String = "pdsh.dock.question.next"
    public const val DOCK_QUESTION_MINIMIZE: String = "pdsh.dock.question.minimize"
    public const val DOCK_QUESTION_SKIP: String = "pdsh.dock.question.skip"
    public const val DOCK_QUESTION_SUBMIT: String = "pdsh.dock.question.submit"
    public const val DOCK_QUESTION_ERROR: String = "pdsh.dock.question.error"
    public const val DOCK_PLAN_CHIP: String = "pdsh.dock.plan.chip"
    public const val DOCK_PLAN_REVIEW: String = "pdsh.dock.plan.review"
    public const val DOCK_PLAN_REVIEW_APPROVE: String = "pdsh.dock.plan.review.approve"
    public const val DOCK_PLAN_REVIEW_CHANGES: String = "pdsh.dock.plan.review.changes"
    public const val DOCK_TODO: String = "pdsh.dock.todo"
    public const val DOCK_TODO_TOGGLE: String = "pdsh.dock.todo.toggle"
    public const val DOCK_TODO_ROW_PREFIX: String = "pdsh.dock.todo.row."
    public const val DOCK_GOAL: String = "pdsh.dock.goal"

    // Schedules, device and preview (PR22 `NativeAutomationPage.swift`, `NativeDeviceConnectionPage.swift`, `PreviewSurface.swift`)
    public const val AUTOMATION_SAVING: String = "pdsh.automation.editor.saving"
    public const val AUTOMATION_REFRESH_A11Y: String = "pdsh.automation.refresh.a11y"
    public const val DEVICE_CONNECT: String = "pdsh.device.connect"
    public const val DEVICE_CONNECT_ONLINE: String = "pdsh.device.connect.online"
    public const val PREVIEW_NETWORK: String = "pdsh.preview.network"
    public const val PREVIEW_NETWORK_ALLOW: String = "pdsh.preview.network.allow"
    public const val PREVIEW_RELOAD: String = "pdsh.preview.reload"
    public const val PREVIEW_OUTSIDE: String = "pdsh.preview.outside"

    // Runtime and about (PR22 `ChatPage.swift`, `SettingsPage.swift`)
    public const val RUNTIME_MODEL_REQUESTS: String = "pdsh.runtime.model-requests"
    public const val ABOUT_APP: String = "pdsh.about.app"
    public const val ABOUT_LICENSES_ROW: String = "pdsh.about.licenses"

    // GitHub Agent credential (`spec/ui/v1/pages/git-hub-agent-settings.json`)
    public const val GITHUB_AGENT_ROOT: String = "pdsh.github-agent.root"
    public const val GITHUB_AGENT_LIST: String = "pdsh.github-agent.list"
    public const val GITHUB_AGENT_TOKEN_FIELD: String = "pdsh.github-agent.token"
    public const val GITHUB_AGENT_SAVE: String = "pdsh.github-agent.save"
    public const val GITHUB_AGENT_DELETE: String = "pdsh.github-agent.delete"
    public const val GITHUB_AGENT_ALLOW_WRITES: String = "pdsh.github-agent.allow-writes"
    public const val GITHUB_AGENT_RESTART: String = "pdsh.github-agent.restart"
    public const val GITHUB_AGENT_MESSAGE: String = "pdsh.github-agent.message"
    public const val GITHUB_AGENT_ERROR: String = "pdsh.github-agent.error"
}
