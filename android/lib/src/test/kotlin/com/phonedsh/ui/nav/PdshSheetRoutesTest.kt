// Sheet-presented routes and the host sheet seam, interaction.md §2 / §4 rule 5.
// SPDX-License-Identifier: MIT
//
// Two claims are tested against the real router:
//   * every route iOS presents with `.sheet` and the contract gives a page id (or
//     the default set) renders through `PdshSheet` with that page's detents and
//     `homeSheetChrome()`;
//   * the sheet registers on the host's shared `SheetBackHost`, so one back closes
//     the sheet and leaves the stack below it untouched. A page-owned sheet in a
//     host slot proves the same seam without a route-level conversion.
//
// The detent expectations come from `spec/ui/v1/golden/sheet-detents.golden.json`
// and the generated token table; no detent is written in this file.
package com.phonedsh.ui.nav

import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.sheet.PdshSheetTags
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.sheet.SheetChrome
import com.phonedsh.ui.sheet.SheetDetents
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshSheetRoutesTest {
    @get:Rule
    val compose = createComposeRule()

    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/sheet-detents.golden.json")
    }

    /** Every route iOS presents with `.sheet` (see the audit in the handoff). */
    private val sheetRoutes: List<PdshRoute> = listOf(
        PdshRoute.Automation,
        PdshRoute.Configuration,
        PdshRoute.Settings,
        PdshRoute.ModelProvider,
        PdshRoute.Runtime,
        PdshRoute.Workbench(),
        PdshRoute.DeviceConnection,
        PdshRoute.SessionArtifacts("session-1"),
        PdshRoute.CommandResult,
        PdshRoute.SessionJobs,
        PdshRoute.SessionSchedules,
    )

    @Test
    fun `every sheet route resolves a frozen page id and its detent set`() {
        val pages = golden.array("pages").values.associate { raw ->
            val page = raw as JsonObject
            page.text("id") to page.text("detents")
        }
        sheetRoutes.forEach { route ->
            val pageId = sheetPageIdOf(route)
            assertNotNull("$route must render through PdshSheet", pageId)
            val explicit = pages[pageId]
            if (explicit == null) {
                assertEquals(
                    "$route has no .presentationDetents site, so the contract default names it",
                    golden.text("defaultDetents"),
                    pageId,
                )
                assertEquals(
                    "$pageId: rule 2 maps an unlisted sheet to the default set",
                    UiTokenData.sheet.defaultDetents.spec,
                    SheetDetents.forPage(pageId).spec,
                )
            } else {
                assertEquals("$route: golden detent row for $pageId", explicit, SheetDetents.forPage(pageId).spec)
                assertEquals(
                    "$pageId: the generated page table carries the same detent set",
                    explicit,
                    UiTokenData.sheet.pageDetents.single { it.id == pageId }.detents.spec,
                )
            }
        }
    }

    @Test
    fun `the explicit page ids are the four the baseline pins`() {
        assertEquals("chatJobs", sheetPageIdOf(PdshRoute.SessionJobs))
        assertEquals("chatSchedules", sheetPageIdOf(PdshRoute.SessionSchedules))
        assertEquals("chatArtifacts", sheetPageIdOf(PdshRoute.SessionArtifacts("session-1")))
        assertEquals("workbench", sheetPageIdOf(PdshRoute.Workbench()))
    }

    @Test
    fun `the audited routes keep the SHEET presentation form`() {
        sheetRoutes.forEach { route ->
            assertEquals("$route stays a modal route", PdshPresentation.SHEET, route.presentation)
        }
        // The iOS `showSessions` sheet is a preview-only path (README §1); the
        // product drawer's 会话 row pushes this face, so it stays a PUSH.
        assertEquals(PdshPresentation.PUSH, PdshRoute.Sessions.presentation)
    }

    @Test
    fun `routes without an iOS sheet call site keep the page frame`() {
        listOf(
            PdshRoute.AgentPresets,
            PdshRoute.PhonePermissions,
            PdshRoute.ChatPreferences,
            PdshRoute.SettingsDocument,
        ).forEach { route ->
            assertNull("$route has no iOS .sheet call site this round", sheetPageIdOf(route))
        }
    }

    @Test
    fun `each sheet route mounts on the host chain and one back pops it`() {
        val host = SheetBackHost()
        val route = mutableStateOf<PdshRoute>(PdshRoute.Home)
        var backs = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Chat, route.value)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = { backs += 1 },
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    sheetBackHost = host,
                )
            }
        }
        compose.waitForIdle()
        sheetRoutes.forEach { audited ->
            compose.runOnIdle { route.value = audited }
            compose.waitForIdle()
            assertTrue("$audited registers on the host sheet chain", host.hasSheet)
            // Every audited site is a `homeSheetChrome()` site: visible grabber.
            compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertExists()

            backs = 0
            assertTrue("$audited is the sheet layer's one step", host.dispatch())
            compose.mainClock.advanceTimeBy(1_000)
            compose.waitForIdle()
            assertEquals("$audited: one back reports one route pop", 1, backs)

            compose.runOnIdle { route.value = PdshRoute.Home }
            compose.waitForIdle()
            assertFalse("$audited left the chain when its route left", host.hasSheet)
        }
    }

    @Test
    fun `back closes the sheet route and leaves the stack under it intact`() {
        val host = SheetBackHost()
        val nav = mutableStateOf(PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Settings)))
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = nav.value,
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = { nav.value = nav.value.pop() },
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    sheetBackHost = host,
                )
            }
        }
        compose.waitForIdle()
        assertTrue(host.hasSheet)

        assertTrue(host.dispatch())
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()

        assertEquals(
            "§4 rule 5: the sheet closes, the page it covered stays",
            listOf(PdshRoute.Chat),
            nav.value.stack,
        )
        assertFalse(host.hasSheet)
    }

    @Test
    fun `a page-owned sheet in a host slot registers on the shared chain`() {
        val host = SheetBackHost()
        val nav = mutableStateOf(PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Sessions)))
        var dismissals = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = nav.value,
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    sessions = {
                        // A page-owned sheet: no explicit `backHost` argument.
                        PdshSheet(
                            pageId = "chatSessions",
                            chrome = SheetChrome.HomeSheet,
                            onDismissRequest = { dismissals += 1 },
                        ) {
                            BasicText("slot sheet", Modifier.testTag("slot_sheet_content"))
                        }
                    },
                    sheetBackHost = host,
                )
            }
        }
        compose.waitForIdle()
        assertTrue("the page-owned sheet uses the host's chain", host.hasSheet)
        compose.onNodeWithText("slot sheet").assertIsDisplayed()

        assertTrue(host.dispatch())
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(1, dismissals)
        assertEquals(
            "the sheet layer never moves the route stack",
            listOf(PdshRoute.Chat, PdshRoute.Sessions),
            nav.value.stack,
        )
    }

    @Test
    fun `without a provider the page-owned sheet still closes on system back`() {
        var dismissals = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Chat, PdshRoute.Sessions)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    sessions = {
                        PdshSheet(
                            pageId = "chatSessions",
                            chrome = SheetChrome.HomeSheet,
                            onDismissRequest = { dismissals += 1 },
                        ) {
                            BasicText("slot sheet", Modifier.testTag("slot_sheet_content"))
                        }
                    },
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithText("slot sheet").assertIsDisplayed()

        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals("the sheet's private chain keeps the back path", 1, dismissals)
    }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.array(key: String): JsonArray = this[key] as JsonArray
}
