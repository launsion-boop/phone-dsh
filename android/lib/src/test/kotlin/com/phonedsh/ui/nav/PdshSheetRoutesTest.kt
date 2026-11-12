// Sheet-presented routes and the host sheet seam, interaction.md §2 / §4 rule 5.
// SPDX-License-Identifier: MIT
//
// Two claims are tested against the real router:
//   * every route iOS presents with `.sheet` maps to a page id declared by the
//     generated `interaction.sheet.pageDetents` table; the seven R1 sites own
//     their ids and resolve the default set, and no product route uses the
//     debug-only `chatSessions` id (PC-20261112-ui-round3 R1/R2);
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
import org.junit.Assert.assertNotEquals
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

    /**
     * The seven `homeSheetChrome()` sites R1 of `PC-20261112-ui-round3` enumerates:
     * each owns a page id now instead of sharing the contract's default id. Every
     * one of them writes no `.presentationDetents`, so its row is the default set.
     */
    private val r1DefaultSetRoutes: List<Pair<PdshRoute, String>> = listOf(
        PdshRoute.Automation to "automation",
        PdshRoute.Configuration to "configuration",
        PdshRoute.Settings to "settings",
        PdshRoute.ModelProvider to "modelProvider",
        PdshRoute.Runtime to "runtime",
        PdshRoute.DeviceConnection to "deviceConnection",
        PdshRoute.CommandResult to "commandResult",
    )

    /**
     * Every route the router can present, so the no-`chatSessions` assertion covers
     * the product vocabulary rather than only the audited sheet list. Data-class
     * routes carry a harmless sample payload; only their page id is read.
     */
    private val allRoutes: List<PdshRoute> = listOf(
        PdshRoute.Home,
        PdshRoute.Chat,
        PdshRoute.WorkspaceFolders,
        PdshRoute.Files(),
        PdshRoute.Automation,
        PdshRoute.Configuration,
        PdshRoute.Settings,
        PdshRoute.MeTab,
        PdshRoute.SettingsMore,
        PdshRoute.Discover,
        PdshRoute.ModelProvider,
        PdshRoute.WebSearch,
        PdshRoute.Mcp,
        PdshRoute.Ssh,
        PdshRoute.SshEditor(),
        PdshRoute.Bluetooth,
        PdshRoute.AndroidAdb,
        PdshRoute.TonoAccount,
        PdshRoute.McpEditor(),
        PdshRoute.Runtime,
        PdshRoute.Egress,
        PdshRoute.Workbench(),
        PdshRoute.Tools,
        PdshRoute.Export,
        PdshRoute.WebSurface,
        PdshRoute.Sessions,
        PdshRoute.DeviceConnection,
        PdshRoute.DeviceSession("device-1"),
        PdshRoute.SessionArtifacts("session-1"),
        PdshRoute.AgentPresets,
        PdshRoute.PluginInventory,
        PdshRoute.PhonePermissions,
        PdshRoute.ChatPreferences,
        PdshRoute.SettingsDocument,
        PdshRoute.Shortcuts,
        PdshRoute.CommandResult,
        PdshRoute.SessionJobs,
        PdshRoute.SessionSchedules,
        PdshRoute.Preview("notes.md"),
        PdshRoute.PcPairing,
        PdshRoute.ConnectedComputer,
    )

    @Test
    fun `every sheet route maps to a page id generated from tokens`() {
        val generatedIds = UiTokenData.sheet.pageDetents.map { it.id }.toSet()
        sheetRoutes.forEach { route ->
            val pageId = sheetPageIdOf(route)
            assertNotNull("$route must render through PdshSheet", pageId)
            val id = requireNotNull(pageId)
            assertTrue(
                "$route maps to '$id', which interaction.sheet.pageDetents does not declare",
                id in generatedIds,
            )
            assertEquals(
                "$route: SheetDetents resolves the generated row for '$id'",
                UiTokenData.sheet.pageDetents.single { it.id == id }.detents,
                SheetDetents.forPage(id),
            )
        }
    }

    @Test
    fun `the seven R1 sites use their own ids and the default detent set`() {
        val generatedIds = UiTokenData.sheet.pageDetents.map { it.id }.toSet()
        r1DefaultSetRoutes.forEach { (route, expectedId) ->
            assertEquals("R1: $route has its own frozen page id", expectedId, sheetPageIdOf(route))
            assertTrue(
                "R1: '$expectedId' must be declared by interaction.sheet.pageDetents",
                expectedId in generatedIds,
            )
            assertEquals(
                "R1: $expectedId writes no .presentationDetents, so it is the default set",
                UiTokenData.sheet.defaultDetents,
                UiTokenData.sheet.pageDetents.single { it.id == expectedId }.detents,
            )
            assertEquals(
                "R1: SheetDetents.forPage('$expectedId') is the default set",
                UiTokenData.sheet.defaultDetents,
                SheetDetents.forPage(expectedId),
            )
        }
    }

    @Test
    fun `no product route maps to the debug-only chatSessions id`() {
        allRoutes.forEach { route ->
            assertNotEquals(
                "$route must not use iOS's debug-only `chatSessions` sheet (R2)",
                "chatSessions",
                sheetPageIdOf(route),
            )
        }
        // The drawer-pushed sessions list is a push, not the preview-only sheet.
        assertEquals(PdshPresentation.PUSH, PdshRoute.Sessions.presentation)
        assertNull(sheetPageIdOf(PdshRoute.Sessions))
    }

    @Test
    fun `the four explicit detent sites keep their frozen ids and sets`() {
        val pages = golden.array("pages").values.associate { raw ->
            val page = raw as JsonObject
            page.text("id") to page.text("detents")
        }
        val explicit = mapOf(
            PdshRoute.SessionJobs to "chatJobs",
            PdshRoute.SessionSchedules to "chatSchedules",
            PdshRoute.SessionArtifacts("session-1") to "chatArtifacts",
            PdshRoute.Workbench() to "workbench",
        )
        explicit.forEach { (route, pageId) ->
            assertEquals("$route: the baseline pins '$pageId'", pageId, sheetPageIdOf(route))
            assertEquals("$route: golden detent row for '$pageId'", pages[pageId], SheetDetents.forPage(pageId).spec)
            assertEquals(
                "$pageId: the generated page table carries the golden detent set",
                pages[pageId],
                UiTokenData.sheet.pageDetents.single { it.id == pageId }.detents.spec,
            )
        }
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
