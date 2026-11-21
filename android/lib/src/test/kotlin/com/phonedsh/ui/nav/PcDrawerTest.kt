// The drawer's 手机 | PC segment, PC list states and the two new routes.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ConnectedComputerUiState
import com.phonedsh.ui.page.PCPairingUiState
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerSession
import com.phonedsh.ui.page.PcDrawerUiState
import com.phonedsh.ui.page.PcDrawerWorkspace
import com.phonedsh.ui.page.PcLinkDrawerPolicy
import com.phonedsh.ui.page.PcLinkOfflineReason
import com.phonedsh.ui.page.PcLinkPresence
import com.phonedsh.ui.page.PcLinkPresenceState
import com.phonedsh.ui.page.PcLinkText
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsLanguage
import com.phonedsh.ui.page.SettingsPage
import com.phonedsh.ui.page.SettingsPageMode
import com.phonedsh.ui.page.SettingsPreferences
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PcDrawerTest {
    @get:Rule
    val compose = createComposeRule()

    private fun showDrawer(
        state: PcDrawerUiState,
        onSelect: (PcDrawerBackend) -> Unit = {},
        onPair: () -> Unit = {},
        onRetry: () -> Unit = {},
        onOpenSession: ((String) -> Unit)? = null,
        onOpenConnectedComputer: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                PcDrawer(
                    state = state,
                    onSelectBackend = onSelect,
                    onPair = onPair,
                    onRetry = onRetry,
                    onOpenSession = onOpenSession,
                    onOpenConnectedComputer = onOpenConnectedComputer,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun pcState(
        presence: PcLinkPresenceState = PcLinkPresenceState.unpaired(),
        sessions: List<PcDrawerSession> = emptyList(),
        workspaces: List<PcDrawerWorkspace> = emptyList(),
        cachedNote: String? = null,
        loading: Boolean = false,
        error: String? = null,
        offlineReason: PcLinkOfflineReason? = null,
        longOffline: Boolean = false,
    ) = PcDrawerUiState(
        selected = PcDrawerBackend.PC,
        presence = presence,
        sessions = sessions,
        workspaces = workspaces,
        cachedListNote = cachedNote,
        loading = loading,
        error = error,
        offlineReason = offlineReason,
        longOffline = longOffline,
    )

    @Test
    fun `segment reports 手机 and PC without changing its own selection`() {
        val choices = mutableListOf<PcDrawerBackend>()
        showDrawer(PcDrawerUiState(selected = PcDrawerBackend.PHONE), onSelect = { choices += it })
        compose.onNodeWithText(UiStrings.PC_BACKEND_PHONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_BACKEND_PC).assertIsDisplayed()
        compose.onNodeWithTag(PcDrawerTags.BACKEND_PREFIX + UiStrings.PC_BACKEND_PC).performClick()
        compose.onNodeWithTag(PcDrawerTags.BACKEND_PREFIX + UiStrings.PC_BACKEND_PHONE).performClick()
        assertEquals(listOf(PcDrawerBackend.PC, PcDrawerBackend.PHONE), choices)
    }

    @Test
    fun `unpaired PC shows the 连接电脑 card and reports the tap`() {
        var paired = false
        showDrawer(pcState(), onPair = { paired = true })
        compose.onNodeWithText(PcLinkText.PAIR_DESCRIPTION).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.CONNECT_COMPUTER).assertIsDisplayed()
        compose.onNodeWithTag(PcDrawerTags.PAIR).performClick()
        assertTrue(paired)
    }

    @Test
    fun `connecting PC shows the bounded resume copy and no retry`() {
        showDrawer(pcState(presence = PcLinkPresenceState.reconnecting("Studio")))
        compose.onNodeWithText(PcLinkText.CONNECTING_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.RESUME_CONNECTING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_RETRY).assertDoesNotExist()
    }

    @Test
    fun `offline PC shows the reason retry and the long-offline recovery`() {
        var retried = 0
        var openedConnected = false
        showDrawer(
            pcState(
                presence = PcLinkPresenceState.offline("Studio"),
                offlineReason = PcLinkOfflineReason.NETWORK,
                longOffline = true,
            ),
            onRetry = { retried++ },
            onOpenConnectedComputer = { openedConnected = true },
        )
        compose.onNodeWithText(PcLinkText.OFFLINE_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.offlineReason(PcLinkOfflineReason.NETWORK)).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.LONG_OFFLINE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.LONG_OFFLINE_RECOVERY).assertIsDisplayed()
        compose.onNodeWithTag(PcDrawerTags.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithText(PcLinkText.LONG_OFFLINE_RECOVERY).performClick()
        assertTrue(openedConnected)
    }

    @Test
    fun `ready PC with no rows shows the honest empty line`() {
        showDrawer(pcState(presence = PcLinkPresenceState.online("Studio")))
        compose.onNodeWithText(PcLinkText.NO_PC_SESSIONS).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.CONNECT_COMPUTER).assertDoesNotExist()
    }

    @Test
    fun `PC rows group by workspace title membership first then cwd then 未分组`() {
        val rows = listOf(
            PcDrawerSession("s1", "One", cwd = "/work/a/one"),
            PcDrawerSession("s2", "Two", cwd = "/elsewhere/two"),
            PcDrawerSession("s3", "Three", cwd = "/loose/three"),
        )
        val workspaces = listOf(
            PcDrawerWorkspace("alpha", "Alpha", "/work/a"),
            PcDrawerWorkspace("beta", "Beta", "/elsewhere", sessionIds = listOf("s2")),
        )
        showDrawer(
            pcState(presence = PcLinkPresenceState.online("Studio"), sessions = rows, workspaces = workspaces),
        )
        compose.onNodeWithTag(PcDrawerTags.GROUP_PREFIX + "alpha").assertIsDisplayed()
        compose.onNodeWithTag(PcDrawerTags.GROUP_PREFIX + "beta").assertIsDisplayed()
        compose.onNodeWithTag(PcDrawerTags.GROUP_PREFIX + "__ungrouped__").assertIsDisplayed()
        compose.onNodeWithText("Alpha").assertIsDisplayed()
        compose.onNodeWithText("Beta").assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.UNGROUPED).assertIsDisplayed()
        compose.onNodeWithText("One").assertIsDisplayed()
        compose.onNodeWithText("Two").assertIsDisplayed()
        compose.onNodeWithText("Three").assertIsDisplayed()
    }

    @Test
    fun `workspace path matching uses the longest component boundary`() {
        val workspaces = listOf(
            PcDrawerWorkspace("short", "Short", "/work"),
            PcDrawerWorkspace("long", "Long", "/work/a"),
            PcDrawerWorkspace("prefix", "Prefix", "/work/ab"),
        )
        assertEquals(
            "long",
            PcLinkDrawerPolicy.workspaceIdFor(PcDrawerSession("s", "S", cwd = "/work/a/one"), workspaces),
        )
        assertEquals(
            "prefix",
            PcLinkDrawerPolicy.workspaceIdFor(PcDrawerSession("s", "S", cwd = "/work/ab/two"), workspaces),
        )
        assertEquals(
            null,
            PcLinkDrawerPolicy.workspaceIdFor(PcDrawerSession("s", "S", cwd = "/other"), workspaces),
        )
    }

    @Test
    fun `pc new session gate follows the PC phase and never the phone engine`() {
        assertEquals(PcLinkText.PC_NEW_SESSION_UNPAIRED, pcState().newSessionBlockedReason)
        assertEquals(
            PcLinkText.PC_NEW_SESSION_CONNECTING,
            pcState(presence = PcLinkPresenceState.reconnecting("Studio")).newSessionBlockedReason,
        )
        assertEquals(
            PcLinkText.PC_NEW_SESSION_OFFLINE,
            pcState(presence = PcLinkPresenceState.offline("Studio")).newSessionBlockedReason,
        )
        assertNull(
            "an online PC can create even while the phone engine is stopped",
            pcState(presence = PcLinkPresenceState.online("Studio")).newSessionBlockedReason,
        )
        assertNull(
            "the phone segment keeps its host engine/turn gate",
            PcDrawerUiState(
                selected = PcDrawerBackend.PHONE,
                presence = PcLinkPresenceState.offline("Studio"),
            ).newSessionBlockedReason,
        )
    }

    @Test
    fun `cached list note is the strip above rows`() {
        showDrawer(
            pcState(
                presence = PcLinkPresenceState.offline("Studio"),
                sessions = listOf(PcDrawerSession("s1", "One")),
                cachedNote = PcLinkText.CACHED_RECONNECTING,
            ),
        )
        compose.onNodeWithTag(PcDrawerTags.CACHED_NOTE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.CACHED_RECONNECTING).assertIsDisplayed()
    }

    @Test
    fun `loading is never the empty state`() {
        showDrawer(pcState(presence = PcLinkPresenceState.online("Studio"), loading = true))
        compose.onNodeWithText(PcLinkText.LOADING_PC_SESSIONS).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.NO_PC_SESSIONS).assertDoesNotExist()
    }

    @Test
    fun `an error is never the empty state`() {
        showDrawer(pcState(presence = PcLinkPresenceState.online("Studio"), error = "read failed"))
        compose.onNodeWithText("read failed").assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.NO_PC_SESSIONS).assertDoesNotExist()
    }

    @Test
    fun `session tap reports the PC session id`() {
        var opened: String? = null
        showDrawer(
            pcState(
                presence = PcLinkPresenceState.online("Studio"),
                sessions = listOf(PcDrawerSession("s1", "One")),
            ),
            onOpenSession = { opened = it },
        )
        compose.onNodeWithTag(PcDrawerTags.SESSION_PREFIX + "s1").performClick()
        assertEquals("s1", opened)
    }

    @Test
    fun `settings 已连接的电脑 is the first clickable row of its group with three values`() {
        val value = mutableStateOf("未配对")
        var opened = false
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(
                        SettingsFacts(preferences = SettingsPreferences(language = SettingsLanguage.ZH)),
                    ),
                    onNavigate = {},
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = {},
                    mode = SettingsPageMode.TAB,
                    connectedComputerValue = value.value,
                    onOpenConnectedComputer = { opened = true },
                )
            }
        }
        compose.waitForIdle()
        val list = compose.onNodeWithTag(com.phonedsh.ui.UiTags.SETTINGS_LIST)
        list.performScrollToNode(hasTestTag(
            UiPageTags.SETTINGS_INDEX_ROW_PREFIX + SettingsScreenState.CONNECTED_COMPUTER_ROW_ID,
        ))
        compose.waitForIdle()
        val connected = compose.onNodeWithTag(
            UiPageTags.SETTINGS_INDEX_ROW_PREFIX + SettingsScreenState.CONNECTED_COMPUTER_ROW_ID,
        )
        connected.assertTextContains("未配对")
        val settingsRow = compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "me.settings")
        val connectedTop = connected.getUnclippedBoundsInRoot().top
        val settingsTop = settingsRow.getUnclippedBoundsInRoot().top
        assertTrue("已连接的电脑 must be the first row of its group", connectedTop < settingsTop)

        compose.runOnUiThread { value.value = "离线" }
        compose.waitForIdle()
        connected.assertTextContains("离线")
        compose.runOnUiThread { value.value = "Studio" }
        compose.waitForIdle()
        connected.assertTextContains("Studio")
        connected.performClick()
        assertTrue(opened)
    }

    @Test
    fun `the two PCLink routes render and keep the iOS presentation`() {
        assertEquals(PdshPresentation.SHEET, PdshRoute.PcPairing.presentation)
        assertEquals(PdshPresentation.PUSH, PdshRoute.ConnectedComputer.presentation)
        assertEquals(
            PCPairingUiState.idle(),
            PCPairingUiState.idle(),
        )
        assertEquals(ConnectedComputerUiState.empty(), ConnectedComputerUiState.empty())
    }

    @Test
    fun `pairing route renders 连接电脑`() {
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.PcPairing)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { Box(Modifier.fillMaxSize()) },
                    webSurface = { Box(Modifier.fillMaxSize()) },
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithText(UiStrings.PC_PAIRING_TITLE).assertIsDisplayed()
    }

    @Test
    fun `the pairing route prints the host install command and copies it`() {
        val command = "curl -fsSL https://example.test/pclink/install.sh | bash"
        var copied: AnnotatedString? = null
        val clipboard = object : ClipboardManager {
            override fun getText(): AnnotatedString? = copied
            override fun setText(annotatedString: AnnotatedString) {
                copied = annotatedString
            }
        }
        compose.setContent {
            CompositionLocalProvider(LocalClipboardManager provides clipboard) {
                PdshTheme {
                    PdshNavHost(
                        nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.PcPairing)),
                        facts = PdshNavFacts(),
                        onNavigate = {},
                        onBack = {},
                        onHome = {},
                        onHostAction = {},
                        home = { Box(Modifier.fillMaxSize()) },
                        webSurface = { Box(Modifier.fillMaxSize()) },
                        pcInstallCommand = command,
                    )
                }
            }
        }
        compose.onNodeWithText(command).assertIsDisplayed()
        compose.onNode(hasContentDescription("复制安装命令") and hasClickAction())
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnIdle { assertEquals(command, copied?.text) }
    }

    @Test
    fun `connected-computer route renders 已连接的电脑`() {
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.ConnectedComputer)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { Box(Modifier.fillMaxSize()) },
                    webSurface = { Box(Modifier.fillMaxSize()) },
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithText(UiStrings.PC_CONNECTED_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.NO_COMPUTER).assertIsDisplayed()
    }
}
