// MCP servers: the list, each server's connection and its measured tool count.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/pages/mcp-settings.json` (extracted from
// `MCPSettingsPage.swift:17` in the probe app) and `spec/ui/v1/README.md` §1 row
// MCPSettingsPage (MCP 服务器列表与编辑; entry: 设置行; navigation: push/sheet,
// 编辑子页 MCPEditorPage), plus §3.1 (the ScreenState layer).
//
// The baseline's three titled groups, in its order:
//   * `Streamable HTTP MCP` (`MCPSettingsPage.swift:46`) — the server rows, with
//     the baseline's own footer (`:69`), and its 主机尚未启动 / 正在读取 MCP 注册表…
//     / 尚未添加 MCP 服务器 states inside it;
//   * `局域网设备` (`:101`) — 扫描局域网设备 / 停止扫描, the host's status line,
//     the discovered candidates (name + URL, marked 未验证) and the iOS
//     unverified note. Discovery is `spec/device/v1/lan-mcp.md`: a candidate only
//     opens the editor pre-filled; it never connects, saves or grants;
//   * `操作` — 刷新注册表 and 添加 MCP 服务器.
// The two untitled blocks at `:73` and `:78` are the error and notice lines; they
// carry runtime text only and are the contract's own unresolved entries, so this
// page keeps its failure line (same copy family) without a group title.
//
// Nothing is invented:
//   * a server the host did not describe is 未知, never "未连接";
//   * a tool count the host did not measure renders 工具数未知 and is never
//     replaced by 0 (an unmeasured number is not a zero);
//   * a server carries only its name, connection state and tool count. Commands,
//     URLs and credentials live in the editor, and the stored ones never leave
//     the host (see `MCPEditorPage.kt`): a list row cannot leak a URL.
//
// 刷新注册表 replaces the old inline 重试: the baseline has exactly one re-read
// verb in 操作, and a failure line with its own second retry would be two names
// for one command. `onRefresh` is the host's hook; a host that offers no re-read
// renders the row disabled rather than hiding it, so the action's absence is
// visible instead of surprising.
//
// ScreenState: `MCPScreenState.from(facts, local)` is pure. The only local event
// is the server group's fold; row taps navigate to the editor and are host
// actions.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap` and the
// 操作 group borrows the shared chrome (`SessionSectionLabel`,
// `SessionTextAction`), so this file still reads no token name directly.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.generated.UiTokenNames
import com.phonedsh.ui.surface.SettingsSubPageFootnote
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSectionHeader
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** What the host says about a server's connection. */
public enum class MCPConnection {
    CONNECTED,
    CONNECTING,
    DISCONNECTED,

    /** The host did not report a connection state; the row says 未知. */
    UNKNOWN,
}

/**
 * One MCP server as the list sees it.
 *
 * @param id the host's stable id (also the row's test tag suffix, and the editor
 *   target the host resolves).
 * @param name the display name.
 * @param connection the three-way connection fact plus the connecting state.
 * @param toolCount the measured number of tools this server exposes; `null`
 *   means unmeasured and renders 未知. A negative count is not a measurement and
 *   is treated as unmeasured.
 */
@Immutable
public data class MCPServer(
    public val id: String,
    public val name: String,
    public val connection: MCPConnection = MCPConnection.UNKNOWN,
    public val toolCount: Int? = null,
)

/** Why the registry could not be read; the wording is page-owned. */
public enum class MCPFailureReason {
    /** The MCP registry could not be read. */
    REGISTRY_UNREADABLE,

    /** The host is not running, so there is no registry to read yet. */
    HOST_NOT_RUNNING,

    /** The host reported a failure without a category the page can name. */
    UNKNOWN,
}

/**
 * The page's read-only input.
 *
 * @param servers the registered servers; `null` means no snapshot was read and
 *   the page renders its unknown state (never "no servers").
 * @param failure the last read failure, as a category.
 */
@Immutable
public data class MCPRegistryFacts(
    public val servers: List<MCPServer>? = null,
    public val failure: MCPFailureReason? = null,
)

/** Where the host's LAN discovery stands; the words are page-owned. */
public enum class LanScanStatus {
    /** The host has no LAN discovery; 扫描局域网设备 renders disabled. */
    UNAVAILABLE,
    IDLE,
    SCANNING,

    /** A scan finished with at least one candidate. */
    FOUND,

    /** A scan finished without a candidate. */
    NONE_FOUND,

    /** Results were cleared after the expiry window. */
    EXPIRED,

    /** No Wi-Fi network to browse on. */
    NO_WIFI,
    FAILED,
}

/**
 * One discovered, **unverified** LAN MCP device: the display-only service name
 * and the HTTPS URL built from the SRV hostname. Not an identity and not a grant.
 */
@Immutable
public data class LanCandidateFact(
    public val id: String,
    public val name: String,
    public val url: String,
)

/**
 * The 局域网设备 group's input.
 *
 * @param status the discovery state; [LanScanStatus.UNAVAILABLE] (the default)
 *   is a host that never wired discovery.
 * @param scanning whether a scan is running (the verb reads 停止扫描).
 * @param candidates validated candidates in display order.
 */
@Immutable
public data class LanDiscoveryFacts(
    public val status: LanScanStatus = LanScanStatus.UNAVAILABLE,
    public val scanning: Boolean = false,
    public val candidates: List<LanCandidateFact> = emptyList(),
) {
    /** Whether the scan verb can do anything on this host. */
    public val available: Boolean get() = status != LanScanStatus.UNAVAILABLE

    /** The page-owned status line. */
    public val statusText: String
        get() = when (status) {
            LanScanStatus.UNAVAILABLE -> UiStrings.MCP_LAN_STATUS_UNAVAILABLE
            LanScanStatus.IDLE -> UiStrings.MCP_LAN_STATUS_IDLE
            LanScanStatus.SCANNING -> UiStrings.MCP_LAN_STATUS_SCANNING
            LanScanStatus.FOUND -> UiStrings.MCP_LAN_STATUS_FOUND
            LanScanStatus.NONE_FOUND -> UiStrings.MCP_LAN_STATUS_NONE
            LanScanStatus.EXPIRED -> UiStrings.MCP_LAN_STATUS_EXPIRED
            LanScanStatus.NO_WIFI -> UiStrings.MCP_LAN_STATUS_NO_WIFI
            LanScanStatus.FAILED -> UiStrings.MCP_LAN_STATUS_FAILED
        }
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One visible server row; every field is measured or explicitly 未知. */
@Immutable
public data class MCPServerRowView(
    public val id: String,
    public val name: String,
    public val connection: String,
    public val connectionTone: PageTone,
    /** "工具 3 个", or the explicit 工具数未知. */
    public val tools: String,
)

/**
 * The complete MCP list state.
 *
 * @param phase the data phase; [READY] with no rows is the empty state.
 * @param rows one row per server, in host order.
 * @param failure the page-owned failure copy, or `null`.
 * @param serversExpanded whether the server group is open.
 */
@Immutable
public data class MCPScreenState(
    public val phase: SettingsDataPhase,
    public val rows: List<MCPServerRowView> = emptyList(),
    public val failure: String? = null,
    public val serversExpanded: Boolean = true,
) {
    /** The empty state: the registry was read and holds no server. */
    public val isEmpty: Boolean get() = phase == SettingsDataPhase.READY && rows.isEmpty()

    /** No readable snapshot: the page says 未知 instead of "no servers". */
    public val isUnknown: Boolean get() = phase == SettingsDataPhase.UNKNOWN

    /** The last read failed; [failure] explains it. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    public companion object {
        /** Fold id of the server group. */
        public const val SERVERS_SECTION_ID: String = "mcp.servers"

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: no clock, no I/O, no engine. The same facts and the same script
         * always yield the same state sequence (§3.1).
         */
        public fun from(
            facts: MCPRegistryFacts,
            local: MCPLocalState = MCPLocalState(),
        ): MCPScreenState {
            val phase = when {
                facts.failure != null -> SettingsDataPhase.FAILED
                facts.servers == null -> SettingsDataPhase.UNKNOWN
                else -> SettingsDataPhase.READY
            }
            return MCPScreenState(
                phase = phase,
                rows = facts.servers.orEmpty().map { server ->
                    MCPServerRowView(
                        id = server.id,
                        name = server.name,
                        connection = server.connection.text(),
                        connectionTone = server.connection.tone(),
                        // A negative count is not a measurement: no row invents one.
                        tools = server.toolCount?.takeIf { it >= 0 }
                            ?.let { UiStrings.MCP_TOOLS.format(it) }
                            ?: UiStrings.MCP_TOOLS_UNKNOWN,
                    )
                },
                failure = facts.failure?.text(),
                serversExpanded = local.fold.isExpanded(SERVERS_SECTION_ID),
            )
        }

        private fun MCPConnection.text(): String = when (this) {
            MCPConnection.CONNECTED -> UiStrings.MCP_CONNECTED
            MCPConnection.CONNECTING -> UiStrings.MCP_CONNECTING
            MCPConnection.DISCONNECTED -> UiStrings.MCP_DISCONNECTED
            MCPConnection.UNKNOWN -> UiStrings.UNKNOWN
        }

        private fun MCPConnection.tone(): PageTone = when (this) {
            MCPConnection.CONNECTED -> PageTone.ON
            MCPConnection.CONNECTING -> PageTone.NORMAL
            MCPConnection.DISCONNECTED -> PageTone.DEGRADED
            MCPConnection.UNKNOWN -> PageTone.UNKNOWN
        }

        private fun MCPFailureReason.text(): String = when (this) {
            MCPFailureReason.REGISTRY_UNREADABLE -> UiStrings.MCP_FAILURE_REGISTRY
            MCPFailureReason.HOST_NOT_RUNNING -> UiStrings.MCP_FAILURE_HOST
            MCPFailureReason.UNKNOWN -> UiStrings.MCP_FAILURE_UNKNOWN
        }
    }
}

/** The local UI events of the MCP list: only the server fold. */
public sealed interface MCPUiEvent {
    /** Collapse or expand the server group. */
    public data object ToggleServers : MCPUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class MCPLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: MCPUiEvent): MCPLocalState = when (event) {
        MCPUiEvent.ToggleServers -> copy(fold = fold.toggle(MCPScreenState.SERVERS_SECTION_ID))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The MCP server list.
 *
 * @param state the pure screen state ([MCPScreenState.from]).
 * @param onAdd open the editor for a new server (the frame's 添加 MCP 服务器 and the
 *   操作 group's second row are the same command, exactly as in the baseline).
 * @param onEdit open the editor for an existing server, by id.
 * @param onToggleServers collapse/expand the server group; the host applies
 *   `MCPUiEvent.ToggleServers` and re-projects.
 * @param onBack leave the page.
 * @param lan the 局域网设备 group's discovery facts.
 * @param onLanScan start (`true`) or stop (`false`) LAN discovery.
 * @param onLanCandidate open the editor pre-filled with a candidate's URL.
 * @param onRefresh re-read the registry (`PdshHostAction.RefreshMcp`); it is also
 *   the retry after a failed read, so the page has one re-read verb instead of
 *   two. `null` renders 刷新注册表 disabled — a host without the command says so
 *   by greying it out rather than by hiding the action the baseline declares.
 */
@Composable
public fun MCPSettingsPage(
    state: MCPScreenState,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onToggleServers: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRefresh: (() -> Unit)? = null,
    lan: LanDiscoveryFacts = LanDiscoveryFacts(),
    onLanScan: (Boolean) -> Unit = {},
    onLanCandidate: (LanCandidateFact) -> Unit = {},
) {
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        // The baseline's heading (`MCPSettingsPage.swift:101`), not the drawer
        // row's word: iOS titles this sheet "MCP 网络与密钥".
        largeTitle = UiStrings.MCP_NETWORK_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.MCP_ROOT,
        modifier = modifier,
        trailing = {
            SessionTextAction(
                label = UiStrings.MCP_ACTION_ADD_SERVER,
                onClick = onAdd,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.MCP_ADD),
            )
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.MCP_FAILURE,
                )
            }
            // The group takes the room above 操作; every state keeps 操作 reachable,
            // so a reader can recover without leaving the page.
            Box(modifier = Modifier.weight(1f)) {
                when {
                    state.isUnknown -> EmptyHint(
                        title = UiStrings.MCP_UNKNOWN_STATE,
                        hint = UiStrings.MCP_UNKNOWN_HINT,
                        tag = UiPageTags.MCP_UNKNOWN,
                    )

                    state.isFailed && state.rows.isEmpty() -> Unit

                    state.isEmpty -> EmptyHint(
                        title = UiStrings.MCP_EMPTY,
                        hint = UiStrings.MCP_EMPTY_HINT,
                        tag = UiPageTags.MCP_EMPTY,
                    )

                    else -> LazyColumn(
                        modifier = Modifier
                            .fillMaxSize()
                            .testTag(UiPageTags.MCP_LIST),
                        verticalArrangement = Arrangement.Top,
                    ) {
                        item(key = "header.servers") {
                            SettingsSectionHeader(
                                title = UiStrings.MCP_LIST_SECTION,
                                expanded = state.serversExpanded,
                                onToggle = onToggleServers,
                                trailing = UiStrings.ROW_COUNT.format(state.rows.size),
                                tag = UiPageTags.MCP_SERVERS_SECTION,
                            )
                        }
                        if (state.serversExpanded) {
                            items(
                                count = state.rows.size,
                                key = { index -> "row.${state.rows[index].id}" },
                            ) { index ->
                                val row = state.rows[index]
                                SettingsFormRow(
                                    title = row.name,
                                    value = row.connection,
                                    tone = row.connectionTone,
                                    subtitle = row.tools,
                                    modifier = Modifier.testTag(UiPageTags.MCP_ROW_PREFIX + row.id),
                                    onClick = { onEdit(row.id) },
                                )
                            }
                            // The baseline's group footer (`MCPSettingsPage.swift:69`):
                            // the exact-origin rule belongs next to the rows it governs.
                            item(key = "footer.servers") {
                                SettingsSubPageFootnote(text = UiStrings.MCP_LIST_FOOTER)
                            }
                        }
                    }
                }
            }
            // 局域网设备 (`MCPSettingsPage.swift:101`), above 操作 as in the baseline.
            // The verb toggles like iOS (`:102`); a host without discovery
            // (status UNAVAILABLE) shows it disabled with its own status line.
            SessionSectionLabel(
                text = UiStrings.MCP_LAN_SECTION,
                modifier = Modifier.testTag(UiPageTags.MCP_LAN_SECTION),
            )
            if (lan.scanning) {
                SessionTextAction(
                    label = UiStrings.MCP_LAN_STOP,
                    onClick = { onLanScan(false) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(UiPageTags.MCP_LAN_SCAN),
                )
            } else {
                SessionTextAction(
                    label = UiStrings.MCP_LAN_SCAN,
                    onClick = { onLanScan(true) },
                    tone = SessionActionTone.ACCENT,
                    enabled = lan.available,
                    modifier = Modifier.testTag(UiPageTags.MCP_LAN_SCAN),
                )
            }
            SettingsSubPageFootnote(
                text = lan.statusText,
                modifier = Modifier.testTag(UiPageTags.MCP_LAN_STATUS),
            )
            if (lan.candidates.isNotEmpty()) {
                // At most the remaining half of the page: the server group keeps
                // its weight and 操作 stays reachable however many devices answer.
                LazyColumn(
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .testTag(UiPageTags.MCP_LAN_CANDIDATES),
                ) {
                    items(count = lan.candidates.size, key = { index -> "lan.${lan.candidates[index].id}" }) { index ->
                        val candidate = lan.candidates[index]
                        SettingsFormRow(
                            title = candidate.name,
                            value = UiStrings.MCP_LAN_UNVERIFIED,
                            tone = PageTone.DEGRADED,
                            subtitle = candidate.url,
                            modifier = Modifier.testTag(UiPageTags.MCP_LAN_CANDIDATE_PREFIX + candidate.id),
                            onClick = { onLanCandidate(candidate) },
                        )
                    }
                }
                // The iOS note (`:117`) qualifies the results, so it is drawn with
                // them; without candidates the page keeps its height for the
                // server group (the status line already says what happened).
                SettingsSubPageFootnote(
                    text = UiStrings.MCP_LAN_NOTE,
                    modifier = Modifier.testTag(UiPageTags.MCP_LAN_NOTE),
                )
            }
            // 操作 (`MCPSettingsPage.swift:83`): the two verbs, in the baseline's order.
            SessionSectionLabel(
                text = UiStrings.MCP_ACTION_SECTION,
                modifier = Modifier.testTag(UiPageTags.MCP_ACTIONS_SECTION),
            )
            SessionTextAction(
                label = UiStrings.MCP_ACTION_REFRESH,
                onClick = { onRefresh?.invoke() },
                tone = SessionActionTone.ACCENT,
                enabled = onRefresh != null,
                modifier = Modifier.testTag(UiPageTags.MCP_ACTION_REFRESH),
            )
            SessionTextAction(
                label = UiStrings.MCP_ACTION_ADD_SERVER,
                onClick = onAdd,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.MCP_ACTION_ADD_SERVER),
            )
        }
    }
}

/**
 * The token inventory of this page: deliberately empty.
 *
 * Every visible value, floor, margin and gap comes from the shared page chrome
 * (`PageFrame`, `InfoRow`, `SectionHeader`, `EmptyHint`, `SessionFailureLine`,
 * `SessionTextAction`, `pageListGap`), so this file reads no token name directly.
 * `PageTokenReferenceTest`'s equality is "declared == what the source reads":
 * zero is a real answer, and the empty list is what keeps it checkable after the
 * page map is extended by the session-pages lane.
 */
internal object MCPSettingsPageTokens {
    val refs: List<String> = emptyList()
}
