// MCP list: four states, the fold sequence, and an unmeasured tool count that
// stays 未知 instead of becoming a zero.
// SPDX-License-Identifier: MIT
//
// The unmeasured-value test is deliberately lazy: it first proves the target row
// is not composed, then uses `performScrollToNode` to compose it, and only then
// asserts. That ordering is the round's lesson: asserting an absent node without
// scrolling is a false green.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class MCPSettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val files = MCPServer(id = "files", name = "文件服务", connection = MCPConnection.CONNECTED, toolCount = 3)
    private val docs = MCPServer(id = "docs", name = "文档服务", connection = MCPConnection.CONNECTING, toolCount = null)

    private fun show(
        facts: MCPRegistryFacts,
        onAdd: () -> Unit = {},
        onEdit: (String) -> Unit = {},
        onRefresh: (() -> Unit)? = null,
    ) {
        val state = MCPScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                MCPSettingsPage(
                    state = state,
                    onAdd = onAdd,
                    onEdit = onEdit,
                    onToggleServers = {},
                    onBack = {},
                    onRefresh = onRefresh,
                )
            }
        }
    }

    private fun showLive(facts: MCPRegistryFacts) {
        compose.setContent {
            var local by remember { mutableStateOf(MCPLocalState()) }
            PdshTheme {
                MCPSettingsPage(
                    state = MCPScreenState.from(facts, local),
                    onAdd = {},
                    onEdit = {},
                    onToggleServers = { local = local.apply(MCPUiEvent.ToggleServers) },
                    onBack = {},
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty registry shows the empty state, not a blank list`() {
        show(MCPRegistryFacts(servers = emptyList()))
        compose.onNodeWithTag(UiPageTags.MCP_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_LIST).assertDoesNotExist()
        // The add action is still reachable from the empty state.
        compose.onNodeWithTag(UiPageTags.MCP_ADD).assertIsDisplayed()
    }

    @Test
    fun `servers render their connection and tool count and open the editor`() {
        var added = 0
        var edited: String? = null
        show(MCPRegistryFacts(servers = listOf(files, docs)), onAdd = { added += 1 }, onEdit = { edited = it })
        compose.onNodeWithTag(UiPageTags.MCP_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.MCP_ROW_PREFIX + "docs"))
        compose.onNodeWithText("文件服务").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_CONNECTED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_TOOLS.format(3)).assertIsDisplayed()
        compose.onNodeWithText("文档服务").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_CONNECTING).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_ROW_PREFIX + "files").performClick()
        assertEquals("files", edited)
        compose.onNodeWithTag(UiPageTags.MCP_ADD).performClick()
        assertEquals(1, added)
    }

    @Test
    fun `a host that is not running shows its own failure line and refreshes from 操作`() {
        var retried = 0
        show(
            MCPRegistryFacts(failure = MCPFailureReason.HOST_NOT_RUNNING),
            onRefresh = { retried += 1 },
        )
        compose.onNodeWithTag(UiPageTags.MCP_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_FAILURE_HOST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EMPTY).assertDoesNotExist()
        // The baseline has one re-read verb (`MCPSettingsPage.swift:87`), so the
        // failure line carries no second 重试: 刷新注册表 in 操作 is the recovery.
        compose.onAllNodesWithText(UiStrings.RETRY).assertCountEquals(0)
        compose.onNodeWithTag(UiPageTags.MCP_ACTION_REFRESH).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `the 操作 group carries 刷新注册表 and 添加 MCP 服务器 in every state`() {
        var added = 0
        var refreshed = 0
        show(MCPRegistryFacts(servers = emptyList()), onAdd = { added += 1 }, onRefresh = { refreshed += 1 })
        // The group is outside the list, so the empty state still reaches it.
        compose.onNodeWithTag(UiPageTags.MCP_ACTIONS_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_ACTION_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_ACTION_REFRESH).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_ACTION_ADD_SERVER).performClick()
        assertEquals(1, added)
        compose.onNodeWithTag(UiPageTags.MCP_ACTION_REFRESH).performClick()
        assertEquals(1, refreshed)
    }

    @Test
    fun `a host without a re-read renders 刷新注册表 disabled instead of hiding it`() {
        show(MCPRegistryFacts(servers = emptyList()))
        // The action the baseline declares is visible; what it cannot do, it says
        // by being disabled rather than by disappearing from the page.
        compose.onNodeWithText(UiStrings.MCP_ACTION_REFRESH).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_ACTION_REFRESH).assertIsNotEnabled()
    }

    @Test
    fun `局域网设备 shows a disabled 扫描局域网设备 and says Android cannot discover`() {
        show(MCPRegistryFacts(servers = emptyList()), onRefresh = {})
        compose.onNodeWithTag(UiPageTags.MCP_LAN_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_LAN_SECTION).assertIsDisplayed()
        // Android has no LAN discovery: the verb is visible but never enabled, and
        // there is no 停止扫描 state because no scan ever starts.
        compose.onNodeWithText(UiStrings.MCP_LAN_SCAN).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_LAN_SCAN).assertIsNotEnabled()
        compose.onAllNodesWithText("停止扫描").assertCountEquals(0)
        compose.onNodeWithTag(UiPageTags.MCP_LAN_UNSUPPORTED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_LAN_UNSUPPORTED).assertIsDisplayed()
    }

    @Test
    fun `the server group is the baseline's Streamable HTTP MCP group`() {
        show(MCPRegistryFacts(servers = listOf(files)))
        compose.onNodeWithText(UiStrings.MCP_LIST_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_LIST)
            .performScrollToNode(hasText(UiStrings.MCP_LIST_FOOTER))
        compose.onNodeWithText(UiStrings.MCP_LIST_FOOTER).assertIsDisplayed()
    }

    @Test
    fun `no snapshot is unknown, never an empty registry`() {
        show(MCPRegistryFacts(servers = null))
        compose.onNodeWithTag(UiPageTags.MCP_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_LIST).assertDoesNotExist()
    }

    // --------------------------------------------------------- unmeasured value

    /**
     * The special unmeasured-value test: the tool count is absent for the last
     * server, the row is below the fold, and the assertion only happens after a
     * real scroll composes it. A zero must not appear anywhere.
     */
    @Test
    fun `an unmeasured tool count renders 未知 only after the row is scrolled into view`() {
        val servers = (0 until 20).map { index ->
            MCPServer(
                id = "bulk-$index",
                name = "服务 $index",
                connection = MCPConnection.CONNECTED,
                toolCount = index + 1,
            )
        } + MCPServer(id = "late", name = "最后服务", connection = MCPConnection.UNKNOWN, toolCount = null)
        val facts = MCPRegistryFacts(servers = servers)
        val state = MCPScreenState.from(facts)
        val lateRow = state.rows.single { it.id == "late" }
        assertEquals(UiStrings.MCP_TOOLS_UNKNOWN, lateRow.tools)
        assertEquals(UiStrings.UNKNOWN, lateRow.connection)
        val zeroLabel = UiStrings.MCP_TOOLS.format(0)
        assertTrue("no row may claim a zero it did not measure", state.rows.none { it.tools == zeroLabel })

        show(facts)
        val rowTag = UiPageTags.MCP_ROW_PREFIX + "late"
        // Lazy proof: the target row has not been composed yet.
        compose.onAllNodesWithTag(rowTag).assertCountEquals(0)
        compose.onAllNodesWithText(UiStrings.MCP_TOOLS_UNKNOWN).assertCountEquals(0)
        compose.onNodeWithTag(UiPageTags.MCP_LIST).performScrollToNode(hasTestTag(rowTag))
        compose.onNodeWithTag(rowTag).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.MCP_TOOLS_UNKNOWN).assertCountEquals(1)
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(1)
        compose.onNodeWithText(zeroLabel).assertDoesNotExist()
    }

    @Test
    fun `a negative tool count is not a measurement and renders 未知`() {
        val state = MCPScreenState.from(
            MCPRegistryFacts(servers = listOf(MCPServer(id = "x", name = "服务", toolCount = -3))),
        )
        assertEquals(UiStrings.MCP_TOOLS_UNKNOWN, state.rows.single().tools)
    }

    // --------------------------------------------------------------- sequence

    @Test
    fun `the server fold sequence is a pure function of the script`() {
        val facts = MCPRegistryFacts(servers = listOf(files, docs))
        val script = listOf(
            MCPUiEvent.ToggleServers,
            MCPUiEvent.ToggleServers,
            MCPUiEvent.ToggleServers,
        )
        var local = MCPLocalState()
        val states = buildList {
            add(MCPScreenState.from(facts, local))
            script.forEach { event ->
                local = local.apply(event)
                add(MCPScreenState.from(facts, local))
            }
        }
        assertEquals(listOf(true, false, true, false), states.map { it.serversExpanded })
        // A fold only changes visibility: the measured rows are identical.
        assertEquals(1, states.map { it.rows }.distinct().size)
        assertEquals(SettingsDataPhase.READY, states.first().phase)

        var replay = MCPLocalState()
        val replayed = buildList {
            add(MCPScreenState.from(facts, replay))
            script.forEach { event ->
                replay = replay.apply(event)
                add(MCPScreenState.from(facts, replay))
            }
        }
        assertEquals(states, replayed)
    }

    @Test
    fun `the live fold hides the server rows`() {
        showLive(MCPRegistryFacts(servers = listOf(files)))
        compose.onNodeWithText("文件服务").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_SERVERS_SECTION).performClick()
        compose.onNodeWithText("文件服务").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_SERVERS_SECTION).performClick()
        compose.onNodeWithText("文件服务").assertIsDisplayed()
    }
}
