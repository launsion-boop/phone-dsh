// The four dead chat/navigation entrances from the Android 14 device sweep.
// SPDX-License-Identifier: MIT
//
// Each case mounts the real `PdshNavHost` over the real page and drives the same
// control a person tapped. The assertions are the host's typed commands and the
// page's own visible state, not a mock counter: before the fix the switch, the
// menu row and the creator row closed or ignored the gesture.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.AgentPresetActions
import com.phonedsh.ui.page.NativeAgentPreset
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityStatus
import com.phonedsh.ui.page.PhoneGrantRoute
import com.phonedsh.ui.page.PhonePermissionsFacts
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class ChatNavigationWiringTest {

    @get:Rule
    val compose = createComposeRule()

    private fun chatState(): ChatScreenState = ChatScreenState.from(
        nodes = listOf(
            UiStateNode(
                kind = UiStateKind.SESSION,
                nodeID = "session/chat-1",
                parentID = "session/chat-1",
                sessionID = "chat-1",
                turnID = "-",
                seq = 0,
            ),
        ),
        local = ChatLocalState(),
        host = ChatHostFacts(engineStarted = true, canSend = true),
    )

    private fun mount(
        route: PdshRoute,
        facts: PdshNavFacts = PdshNavFacts(),
        chat: ChatScreenState? = null,
        onPhonePermissionRequest: (PhoneCapability) -> Unit = {},
        onPhonePermissionSettings: (PhoneCapability) -> Unit = {},
        agentPresets: NativeAgentPresetsFacts = NativeAgentPresetsFacts(),
        agentPresetActions: AgentPresetActions = AgentPresetActions(),
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = facts,
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    chat = chat,
                    onPhonePermissionRequest = onPhonePermissionRequest,
                    onPhonePermissionSettings = onPhonePermissionSettings,
                    agentPresets = agentPresets,
                    agentPresetActions = agentPresetActions,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun healthyPresets(): NativeAgentPresetsFacts = NativeAgentPresetsFacts(
        presets = listOf(NativeAgentPreset(id = "cordis", title = "Cordis")),
    )

    @Test
    fun `the chat menu exports through the host action`() {
        val dispatched = mutableListOf<PdshUiHostCommand>()
        val facts = PdshNavFacts(
            actionAvailability = PdshActionAvailabilities(
                mapOf(
                    PdshActionKey.EXPORT_TRANSCRIPT to PdshActionAvailability.Available { dispatched += it },
                ),
            ),
        )
        mount(PdshRoute.Chat, facts = facts, chat = chatState())

        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_EXPORT).performClick()

        val export = dispatched.single()
        assertTrue("the export row must dispatch ExportTranscript", export is PdshUiHostCommand.ExportTranscript)
        assertEquals("chat-1", (export as PdshUiHostCommand.ExportTranscript).sessionId)
    }

    @Test
    fun `a request switch confirms before asking the system`() {
        val requested = mutableListOf<PhoneCapability>()
        val facts = PdshNavFacts(
            phonePermissions = PhonePermissionsFacts(
                statuses = mapOf(PhoneCapability.NOTIFICATIONS to PhoneCapabilityStatus.NotDetermined),
                grantRoutes = mapOf(PhoneCapability.NOTIFICATIONS to PhoneGrantRoute.REQUEST),
            ),
        )
        mount(PdshRoute.PhonePermissions, facts, onPhonePermissionRequest = { requested += it })

        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.NOTIFICATIONS.id))
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.NOTIFICATIONS.id)
            .performSemanticsAction(SemanticsActions.OnClick)

        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_CONFIRM_TITLE).assertIsDisplayed()
        assertTrue("the system request waits for the confirmation", requested.isEmpty())

        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_CONFIRM_CONTINUE).performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(listOf(PhoneCapability.NOTIFICATIONS), requested)
    }

    @Test
    fun `an open-settings switch opens the settings page immediately`() {
        val opened = mutableListOf<PhoneCapability>()
        val facts = PdshNavFacts(
            phonePermissions = PhonePermissionsFacts(
                statuses = mapOf(PhoneCapability.FOCUS to PhoneCapabilityStatus.NotDetermined),
                grantRoutes = mapOf(PhoneCapability.FOCUS to PhoneGrantRoute.SYSTEM_SETTINGS),
            ),
        )
        mount(PdshRoute.PhonePermissions, facts, onPhonePermissionSettings = { opened += it })

        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.FOCUS.id))
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.FOCUS.id)
            .performSemanticsAction(SemanticsActions.OnClick)

        assertEquals(listOf(PhoneCapability.FOCUS), opened)
    }

    @Test
    fun `an already permitted switch is disarmed with a visible reason`() {
        val requested = mutableListOf<PhoneCapability>()
        val opened = mutableListOf<PhoneCapability>()
        val facts = PdshNavFacts(
            phonePermissions = PhonePermissionsFacts(
                statuses = mapOf(
                    PhoneCapability.NOTIFICATIONS to PhoneCapabilityStatus.Authorized,
                ),
                enabled = setOf(PhoneCapability.NOTIFICATIONS),
                grantRoutes = mapOf(PhoneCapability.NOTIFICATIONS to PhoneGrantRoute.REQUEST),
            ),
        )
        mount(
            PdshRoute.PhonePermissions,
            facts,
            onPhonePermissionRequest = { requested += it },
            onPhonePermissionSettings = { opened += it },
        )

        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.NOTIFICATIONS.id))

        // ENABLE used to fall through the shared activate() and do nothing. Android
        // has no capability-enable store or tool gate, so this host states that the
        // system grant is the whole decision and disables both controls.
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_APP_SWITCH_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(PhoneCapability.NOTIFICATIONS.title).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.NOTIFICATIONS.id)
            .assertIsNotEnabled()
            .performSemanticsAction(SemanticsActions.OnClick)

        assertTrue("a disarmed ENABLE row must not request a permission", requested.isEmpty())
        assertTrue("a disarmed ENABLE row must not open settings", opened.isEmpty())
    }

    @Test
    fun `a biometric switch is disarmed with a visible reason`() {
        val facts = PdshNavFacts(
            phonePermissions = PhonePermissionsFacts(
                statuses = mapOf(
                    PhoneCapability.BIOMETRICS to PhoneCapabilityStatus.NotDetermined,
                ),
            ),
        )
        mount(PdshRoute.PhonePermissions, facts)

        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.BIOMETRICS.id))

        // CONFIRM_BIOMETRIC used to fall through the shared activate() and do
        // nothing. This host has no biometric prompt to run, so the honest control
        // is a disabled switch with the reason in the row, not a dead tap.
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_BIOMETRIC_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + PhoneCapability.BIOMETRICS.id)
            .assertIsNotEnabled()
    }

    @Test
    fun `the creator row dispatches new-session`() {
        val dispatched = mutableListOf<PdshUiHostCommand>()
        val facts = PdshNavFacts(
            actionAvailability = PdshActionAvailabilities(
                mapOf(
                    PdshActionKey.NEW_SESSION to PdshActionAvailability.Available { dispatched += it },
                ),
            ),
        )
        mount(PdshRoute.AgentPresets, facts, agentPresets = healthyPresets())

        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE).performSemanticsAction(SemanticsActions.OnClick)

        assertTrue(dispatched.single() is PdshUiHostCommand.NewSession)
    }

    @Test
    fun `an unavailable new-session action leaves a visible reason`() {
        mount(PdshRoute.AgentPresets, agentPresets = healthyPresets())

        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE).performSemanticsAction(SemanticsActions.OnClick)

        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE_UNAVAILABLE).assertIsDisplayed()
    }

    @Test
    fun `the creator row is disabled with a reason when cordis is absent`() {
        var dispatched = 0
        val facts = PdshNavFacts(
            actionAvailability = PdshActionAvailabilities(
                mapOf(
                    PdshActionKey.NEW_SESSION to PdshActionAvailability.Available { dispatched++ },
                ),
            ),
        )
        mount(
            PdshRoute.AgentPresets,
            facts,
            agentPresets = NativeAgentPresetsFacts(
                presets = listOf(NativeAgentPreset(id = "standard", title = "Standard")),
            ),
        )

        compose.onNodeWithText(
            UiStrings.AGENT_PRESETS_CREATOR_UNAVAILABLE_PREFIX + UiStrings.AGENT_PRESETS_CREATOR_MISSING,
        ).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_CREATE)
            .performSemanticsAction(SemanticsActions.OnClick)

        assertEquals("a disabled creator must not dispatch NEW_SESSION", 0, dispatched)
    }
}
