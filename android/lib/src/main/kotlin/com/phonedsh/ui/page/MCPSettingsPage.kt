// MCP servers: the list, each server's connection and its measured tool count.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row MCPSettingsPage (MCP 服务器列表与编辑; entry:
// 设置行; navigation: push/sheet, 编辑子页 MCPEditorPage) and §3.1 (the
// ScreenState layer). P5 `must`.
//
// Nothing is invented:
//   * a server the host did not describe is 未知, never "未连接";
//   * a tool count the host did not measure renders 工具数未知 and is never
//     replaced by 0 (an unmeasured number is not a zero);
//   * a server carries only its name, connection state and tool count. Commands,
//     URLs and credentials live in the editor, and the stored ones never leave
//     the host (see `MCPEditorPage.kt`): a list row cannot leak a URL.
//
// ScreenState: `MCPScreenState.from(facts, local)` is pure. The only local event
// is the server group's fold; row taps navigate to the editor and are host
// actions.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.generated.UiTokenNames

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
 * @param onAdd open the editor for a new server.
 * @param onEdit open the editor for an existing server, by id.
 * @param onToggleServers collapse/expand the server group; the host applies
 *   `MCPUiEvent.ToggleServers` and re-projects.
 * @param onRetry retry a failed read.
 * @param onBack leave the page.
 */
@Composable
public fun MCPSettingsPage(
    state: MCPScreenState,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onToggleServers: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.MCP_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.MCP_ROOT,
        modifier = modifier,
        actions = {
            SessionTextAction(
                label = UiStrings.MCP_ADD,
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
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                )
            }
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
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    item(key = "header.servers") {
                        SectionHeader(
                            title = UiStrings.MCP_SERVERS,
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
                            InfoRow(
                                title = row.name,
                                value = row.connection,
                                tone = row.connectionTone,
                                subtitle = row.tools,
                                modifier = Modifier.testTag(UiPageTags.MCP_ROW_PREFIX + row.id),
                                onClick = { onEdit(row.id) },
                            )
                        }
                    }
                }
            }
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
