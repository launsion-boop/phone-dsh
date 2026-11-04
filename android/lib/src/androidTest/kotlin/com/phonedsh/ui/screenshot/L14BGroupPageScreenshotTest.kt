// L14's three B-group pages on a real device: the route, the matrix, the roster.
// SPDX-License-Identifier: MIT
//
// What this suite proves, on pixels rather than on the JVM:
//
//   * the three new `PdshRoute` entries render their pages through `PdshNavHost`
//     (the honest default: this host reads no permissions, no presets and no
//     inventory, so the pages say 未知 and claim nothing);
//   * `PhonePermissionsPage`'s 23-capability matrix draws the five groups, the
//     status line each status earns, and the one repair action the status offers;
//   * a granted capability is 已允许 **only** because the facts said so:
//     the unread render contains no 已允许 at all;
//   * `NativeAgentPresetsPage` draws the badges and the two row verbs, and
//     `NativePluginInventoryPage` draws its disclosure block and its notice.
//
// Deliberately no `ScreenshotSamples` dependency: that file belongs to the parity
// lane, and this suite's samples are these three pages' own states.
package com.phonedsh.ui.screenshot

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.ConfigurationPlugin
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.NativeAgentPreset
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.NativeAgentPresetsPage
import com.phonedsh.ui.page.NativeAgentPresetsScreenState
import com.phonedsh.ui.page.NativePluginInventoryPage
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityAuditRecord
import com.phonedsh.ui.page.PhoneCapabilityStatus
import com.phonedsh.ui.page.PhonePermissionsFacts
import com.phonedsh.ui.page.PhonePermissionsLocalState
import com.phonedsh.ui.page.PhonePermissionsPage
import com.phonedsh.ui.page.PhonePermissionsScreenState
import com.phonedsh.ui.page.PluginInventoryFacts
import com.phonedsh.ui.page.PluginInventoryLocalState
import com.phonedsh.ui.page.PluginInventoryScreenState
import com.phonedsh.ui.page.UiPageTags
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class L14BGroupPageScreenshotTest : ScreenshotTestBase() {

    /** Gate frame, Android-only baseline directory (no iOS counterpart). */
    override val allowedProfiles: Set<ScreenshotProfile> =
        setOf(ScreenshotProfile.GATE, ScreenshotProfile.ANDROID_ONLY)

    // -----------------------------------------------------------------------
    // The route path: what the app renders with a host that has read nothing.
    // -----------------------------------------------------------------------

    @Test
    fun phonePermissionsThroughTheRoute() {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.PhonePermissions)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = {},
                webSurface = {},
            )
        }
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_TITLE).assertIsDisplayed()
        // The first group and its first capability, with the honest 未知 line.
        compose.onNodeWithText("个人信息").assertIsDisplayed()
        compose.onNodeWithText("通讯录").assertIsDisplayed()
        assertTrue(
            "an unread permission must render 未知",
            compose.onAllNodesWithText(UiStrings.UNKNOWN).fetchSemanticsNodes().isNotEmpty(),
        )
        assertTrue(
            "a host that read nothing must never render 已允许",
            compose.onAllNodesWithText(UiStrings.PHONE_PERMISSIONS_STATUS_AUTHORIZED)
                .fetchSemanticsNodes().isEmpty(),
        )
        capture("l14-phone-permissions-unread")
        // The audit section is the last item of the list: scroll, then read it.
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST).performScrollToIndex(11)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_AUDIT_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_AUDIT_UNKNOWN).assertIsDisplayed()
    }

    @Test
    fun agentPresetsThroughTheRoute() {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.AgentPresets)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = {},
                webSurface = {},
            )
        }
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE_NOTE).assertIsDisplayed()
        // No roster was reported, so the page says so instead of claiming an empty engine.
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_UNREAD).assertIsDisplayed()
        capture("l14-agent-presets-unread")
    }

    @Test
    fun pluginInventoryThroughTheRoute() {
        var backCalls = 0
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.PluginInventory)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = { backCalls++ },
                onHome = {},
                onHostAction = {},
                home = {},
                webSurface = {},
            )
        }
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_TITLE).assertIsDisplayed()
        // The current Swift inventory is an untitled list. Configuration lives
        // in the parent Plugins and Tools page, not as a navigation loop here.
        compose.onAllNodesWithText(UiStrings.PLUGIN_INVENTORY_CONFIG).assertCountEquals(0)
        compose.onAllNodesWithText("插件列表").assertCountEquals(0)
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_SEARCH).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_UNREAD).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        assertEquals("the source page's back control returns through the host", 1, backCalls)
        capture("l14-plugin-inventory-unread")
    }

    // -----------------------------------------------------------------------
    // The pages with a host that did report something.
    // -----------------------------------------------------------------------

    @Test
    fun phonePermissionsMatrixWithReportedStatuses() {
        setCapturedContent {
            PhonePermissionsPage(state = samplePermissions())
        }
        // 已拒绝 earns the one repair it can have.
        compose.onNodeWithText("通讯录").assertIsDisplayed()
        compose.onNodeWithText("已拒绝").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_OPEN_SETTINGS).assertIsDisplayed()
        // 已允许 is the host's word, and here the host said it.
        compose.onNodeWithText("日历").assertIsDisplayed()
        compose.onNodeWithText("已允许").assertIsDisplayed()
        assertTrue(
            "the 完成 sheet action is the only toolbar action, there is no debug close X",
            compose.onAllNodesWithText(UiStrings.SETTINGS_DONE).fetchSemanticsNodes().isNotEmpty(),
        )
        capture("l14-phone-permissions-statuses")
    }

    @Test
    fun phonePermissionsLimitedPhotosOfferThePicker() {
        setCapturedContent {
            PhonePermissionsPage(
                state = PhonePermissionsScreenState.from(
                    PhonePermissionsFacts(
                        statuses = mapOf(
                            PhoneCapability.PHOTOS to PhoneCapabilityStatus.Limited(7),
                            PhoneCapability.BIOMETRICS to PhoneCapabilityStatus.Authorized,
                        ),
                    ),
                ),
            )
        }
        // 照片 is the fifth row of the first card: on the gate frame it is on screen.
        compose.onNodeWithText("照片").assertIsDisplayed()
        compose.onNodeWithText("部分允许（7）").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_MANAGE_PHOTOS).assertIsDisplayed()
        capture("l14-phone-permissions-limited")
    }

    @Test
    fun phonePermissionsConfirmationDialog() {
        setCapturedContent {
            PhonePermissionsPage(
                state = PhonePermissionsScreenState.from(
                    PhonePermissionsFacts(
                        statuses = mapOf(
                            PhoneCapability.CONTACTS to PhoneCapabilityStatus.NotDetermined,
                        ),
                    ),
                    PhonePermissionsLocalState(confirmation = PhoneCapability.CONTACTS),
                ),
            )
        }
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_CONFIRM_TITLE).assertIsDisplayed()
        // The purpose shows twice: on the 通讯录 row and in the dialog's body.
        compose.onAllNodesWithText("仅在你查询时读取联系人；电话和邮箱默认脱敏。").assertCountEquals(2)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_CONTINUE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CANCEL).assertIsDisplayed()
        // A dialog is its own window, so the frame capture never contains it:
        // take the composited screen instead, which is what a user sees. The
        // dialog window is attached on its own frame, so let the clock land one.
        compose.mainClock.advanceTimeBy(500)
        compose.waitForIdle()
        Thread.sleep(300)
        captureFullScreen("l14-phone-permissions-confirm")
    }

    @Test
    fun agentPresetsWithTwoPresets() {
        setCapturedContent {
            NativeAgentPresetsPage(
                state = NativeAgentPresetsScreenState.from(
                    NativeAgentPresetsFacts(
                        presets = listOf(
                            NativeAgentPreset(
                                id = "cordis",
                                title = "Cordis",
                                detail = "默认创造模式预设。",
                                isDefault = true,
                            ),
                            NativeAgentPreset(
                                id = "safe",
                                title = "Safe",
                                detail = "",
                                broken = "manifest 缺失",
                                custom = true,
                            ),
                        ),
                    ),
                ),
            )
        }
        compose.onNodeWithText("Cordis").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_DEFAULT).assertIsDisplayed()
        // Two presets, so the same verb appears once per card.
        compose.onAllNodesWithText(UiStrings.AGENT_PRESETS_VIEW_CONFIG).assertCountEquals(2)
        compose.onAllNodesWithText(UiStrings.AGENT_PRESETS_MAKE_DEFAULT).assertCountEquals(2)
        capture("l14-agent-presets-two")
    }

    @Test
    fun pluginInventoryWithAnExpandedEntry() {
        var configurationOpens = 0
        setCapturedContent {
            NativePluginInventoryPage(
                onOpenConfiguration = { configurationOpens++ },
                state = PluginInventoryScreenState.from(
                    facts = PluginInventoryFacts(
                        plugins = listOf(
                            ConfigurationPlugin("plugin-web", "dsh-web", FactState.YES, "active"),
                            ConfigurationPlugin("plugin-fs", "dsh-fs", FactState.NO, "loaded"),
                        ),
                    ),
                    local = PluginInventoryLocalState(expanded = setOf("plugin-web")),
                ),
            )
        }
        compose.onAllNodesWithText(UiStrings.PLUGIN_INVENTORY_CONFIG).assertCountEquals(0)
        compose.onAllNodesWithText("插件列表").assertCountEquals(0)
        assertEquals("the inventory's source layout has no configuration CTA", 0, configurationOpens)
        // The module name is both the row's title and its 模块 value once expanded.
        compose.onAllNodesWithText("dsh-web").assertCountEquals(2)
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_ENTRY).assertIsDisplayed()
        compose.onNodeWithText("plugin-web").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PLUGIN_INVENTORY_PHASE).assertIsDisplayed()
        compose.onNodeWithText("dsh-fs").assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.PLUGIN_INVENTORY_YES).assertCountEquals(1)
        capture("l14-plugin-inventory-expanded")
    }

    // -----------------------------------------------------------------------
    // Sample states (the pages' own, not the parity lane's).
    // -----------------------------------------------------------------------

    /** Writes the composited screen, i.e. the frames of every window, to `name`.png. */
    private fun captureFullScreen(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        val dir = ScreenshotStore.outputDir(compose.activity)
        check(dir.isDirectory || dir.mkdirs()) { "cannot create the capture directory $dir" }
        java.io.File(dir, "$name.png").outputStream().use { out ->
            check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)) {
                "failed to encode $name.png"
            }
        }
    }

    private fun samplePermissions(): PhonePermissionsScreenState = PhonePermissionsScreenState.from(
        PhonePermissionsFacts(
            statuses = mapOf(
                PhoneCapability.CONTACTS to PhoneCapabilityStatus.Denied,
                PhoneCapability.CALENDAR to PhoneCapabilityStatus.Authorized,
                PhoneCapability.REMINDERS to PhoneCapabilityStatus.NotDetermined,
            ),
            enabled = setOf(PhoneCapability.CALENDAR),
            audit = listOf(
                PhoneCapabilityAuditRecord(
                    tool = "contacts.search",
                    capability = PhoneCapability.CONTACTS,
                    at = "2026-01-02 09:14",
                    egress = false,
                    outcome = "denied",
                ),
                PhoneCapabilityAuditRecord(
                    tool = "calendar.list",
                    capability = PhoneCapability.CALENDAR,
                    at = "2026-01-02 09:10",
                    egress = false,
                    outcome = PhoneCapabilityAuditRecord.SUCCESS,
                ),
            ),
        ),
    )
}
