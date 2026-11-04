// The route edges this lane owns: the drawer's 会话 row and the chat head's
// SPDX-License-Identifier: MIT
// session control both land on [PdshRoute.Sessions], and that route renders the
// host's real session list when the host supplies one.
//
// Why these assertions exist: the pages were routing-reachable but no tap led to
// them (L1: "还缺一行入口"; L2: "抽屉里没有会话入口"; L5: "app 内无可点入口").
// A route that compiles is not a destination a user can reach, so the tests here
// mount the real [PdshNavHost] and tap the real controls.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.runtime.mutableStateOf
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.AutomationSnapshot
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshReachabilityTest {

    @get:Rule
    val compose = createComposeRule()

    /** Mounts the real router on the JVM host; only [sessions] is optional. */
    private fun mount(
        nav: PdshNavState,
        onNavigate: (PdshRoute) -> Unit = {},
        onOpenDrawer: (() -> Unit)? = null,
        onHostAction: (PdshHostAction) -> Unit = {},
        automation: AutomationFacts = AutomationFacts(),
        sessions: (@androidx.compose.runtime.Composable () -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = nav,
                    facts = PdshNavFacts(automation = automation),
                    onNavigate = onNavigate,
                    onBack = {},
                    onHome = {},
                    onHostAction = onHostAction,
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    sessions = sessions,
                    onOpenDrawer = onOpenDrawer,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `the sessions route renders the host's real list`() {
        mount(
            nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Sessions)),
            sessions = { BasicText(text = "host session list") },
        )
        compose.onNodeWithText("host session list").assertIsDisplayed()
    }

    @Test
    fun `without a host list the router still renders a sessions page`() {
        mount(nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Sessions)))
        // The facts-only page reports the folder list as unknown; it never claims
        // an empty workspace (`SessionsRoute`'s documented default state). The
        // line is the block's spoken name, not a text node: the page merges it.
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_UNKNOWN).assertExists()
    }

    @Test
    fun `the chat head opens the host drawer without navigating away`() {
        var pushed: PdshRoute? = null
        var opened = false
        mount(
            nav = PdshNavState(listOf(PdshRoute.Chat)),
            onNavigate = { pushed = it },
            onOpenDrawer = { opened = true },
        )
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_DRAWER).performClick()
        compose.runOnIdle {
            assertEquals(true, opened)
            assertEquals(null, pushed)
        }
    }

    @Test
    fun `product root composes ChatPage with HomeDrawer over it`() {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                val drawerOpen = androidx.compose.runtime.remember { mutableStateOf(false) }
                Box(Modifier.fillMaxSize()) {
                    PdshNavHost(
                        nav = PdshNavState(listOf(PdshRoute.Chat)),
                        facts = PdshNavFacts(),
                        onNavigate = {},
                        onBack = {},
                        onHome = {},
                        onHostAction = {},
                        home = { BasicText("sessions root must not be mounted") },
                        webSurface = {},
                        onOpenDrawer = { drawerOpen.value = true },
                    )
                    if (drawerOpen.value) {
                        HomeDrawer(
                            facts = HomeDrawerFacts(),
                            onClose = { drawerOpen.value = false },
                        )
                    }
                }
            }
        }
        compose.onNodeWithTag(UiTags.CHAT_ROOT).assertIsDisplayed()
        compose.onNodeWithText("sessions root must not be mounted").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_DRAWER).performClick()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.CHAT_ROOT).assertExists()
    }

    @Test
    fun `the automation route is a sheet and exposes the catalog bar`() {
        // L11's page renders the ✕/刷新/新建 bar only when the callbacks are
        // non-null; leaving them out made the collected screenshots disagree
        // with the app. The sheet editor's physical interactions run in the
        // device-side modal test, where IME and Dialog semantics are real.
        val actions = mutableListOf<PdshHostAction>()
        assertEquals(PdshPresentation.SHEET, PdshRoute.Automation.presentation)
        mount(
            nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Automation)),
            onHostAction = { actions += it },
            automation = AutomationFacts(
                snapshot = AutomationSnapshot(schedules = emptyList()),
                currentSessionID = "worker-session-1",
            ),
        )
        compose.onNodeWithTag(UiPageTags.AUTOMATION_REFRESH).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).assertIsDisplayed()
        // Routing ownership is a semantics assertion. Robolectric reports the
        // CJK text as 2px wide, making minimum touch targets overlap; native
        // toolbar gesture coverage uses actual device font metrics.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_REFRESH).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(listOf<PdshHostAction>(PdshHostAction.RefreshAutomation), actions)
        }
    }

    @Test
    fun `the drawer's session row and the route agree on the destination`() {
        // The drawer row and the chat head must not name two different faces for
        // 会话: one route, one address.
        val entries = listOf(
            PdshDrawerEntry("会话", PdshDrawerIcon.SESSIONS, PdshRoute.Sessions),
        )
        var pushed: PdshRoute? = null
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshDrawer(
                    entries = entries,
                    footerEntries = emptyList(),
                    onSelect = { pushed = it },
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + "会话").performClick()
        compose.runOnIdle { assertEquals(PdshRoute.Sessions, pushed) }
    }
}
