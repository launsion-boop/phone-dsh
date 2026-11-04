// The seven Sessions-family states, captured at the iOS baseline viewport.
// SPDX-License-Identifier: MIT
//
// Carriage: this class is NOT a second harness. It extends [ScreenshotTestBase]
// (the one capture chain: real PixelCopy of the composition), pins the same
// `ScreenshotProfile.IOS_PARITY` frame every parity capture uses, and takes its
// seven PNG names from [ParityState] — the registry that maps each
// `docs/receipts/ios-baseline-screens/ios-sessions-*.png` to one Android name. So
// the output lands in `pdsh-screenshots/ios-parity/fs-1.0/` next to the registry
// and is visible to the comparison tool.
//
// Why a separate class instead of a `@Test` inside `ParityScreenshotTest`: that
// file is edited by several page lanes at once, and a capture suite that keeps
// losing edits is worse than one extra class. The base class, the profile, the
// store and the state names are all shared; only the state list is here.
//
// The state of each page is the baseline's own state, not a convenient one: the
// drawer samples are built from the iOS probe app's `installPreviewData`
// generator (see [ScreenshotSamples]), so a row's title, relative time, folder
// and count are the ones `ios-sessions-*.png` shows.
//
// Known, deliberate frame difference: the iOS PNGs include the 59 pt status area,
// so every Android y-coordinate sits 59 pt (177 px) above its iOS counterpart,
// and the iOS shots carry the capture harness's ✕ cover button. Compare relative
// geometry (row pitch, insets, x positions), not absolute y.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.NativeAutomationPage
import com.phonedsh.ui.page.SessionsPage
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.UiPageTags
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionsParityScreenshotTest : ScreenshotTestBase() {
    /** The parity frame is the whole point of this suite. */
    override val allowedProfiles: Set<ScreenshotProfile> = setOf(ScreenshotProfile.IOS_PARITY)

    /**
     * Publishes the registry next to the PNGs, like the other parity suite does, so
     * a run limited to this class still leaves the host a complete name mapping.
     */
    @Before
    fun publishRegistry() {
        ScreenshotStore.writeRegistry(
            activity = compose.activity,
            profile = profile,
            lines = captureRegistryLines(),
        )
    }

    /**
     * `ios-sessions-default.png`: the page in the **full 402 pt window**.
     *
     * The iOS baseline's `.sessions` route mounts `SessionsPage` directly in the
     * app window (`NativeShell.swift:842`), so its empty block centres on 201 and
     * its CTA runs 16 → 385.7. Every other sessions state is captured inside
     * `DrawerPreview` (`NativeShell.swift:872-879`, `.frame(width: 320)`), which is
     * why `page-sessions-nothing` is the same page at 320. Until L73 the Android
     * page clamped its own list to 320, so the two states rendered identical PNGs;
     * the page now fills its container and the two captures differ exactly where
     * the two iOS shots do (74,939 px, y 223.7–398.3 pt).
     */
    @Test
    fun pageSessionsDefault() = captureSessions(ParityState.PAGE_SESSIONS_DEFAULT, drawer = false) {
        ScreenshotSamples.sessionsNothing()
    }

    @Test
    fun pageSessionsEmpty() = captureSessions(ParityState.PAGE_SESSIONS_EMPTY) {
        ScreenshotSamples.sessionsEmpty()
    }

    @Test
    fun pageSessionsError() = captureSessions(ParityState.PAGE_SESSIONS_ERROR) {
        ScreenshotSamples.sessionsError()
    }

    @Test
    fun pageSessionsMany() = captureSessions(ParityState.PAGE_SESSIONS_MANY) {
        ScreenshotSamples.sessionsMany()
    }

    @Test
    fun pageSessionsNothing() = captureSessions(ParityState.PAGE_SESSIONS_NOTHING) {
        ScreenshotSamples.sessionsNothing()
    }

    @Test
    fun pageSessionsUngrouped() = captureSessions(ParityState.PAGE_SESSIONS_UNGROUPED) {
        ScreenshotSamples.sessionsUngrouped()
    }

    /**
     * `ios-sessions-schedules.png` renders `NativeAutomationPage`.
     *
     * The page is aligned to that baseline (L11): the frame wires the two bar
     * controls and the empty-state CTA, because iOS renders all three and the page
     * draws each of them from a host callback (`onRefresh`, `onNewSchedule`). The
     * running app reaches them through `PdshHostAction.RefreshAutomation` /
     * `OpenAutomationEditor`; the router call site is another lane's file, and
     * until it passes them this capture shows the page as the *page* draws it.
     * `ScreenshotSamples.automationState()` keeps the baseline's own facts: an
     * empty catalog plus the host's raw read failure.
     */
    @Test
    fun pageSessionsSchedules() {
        check(ParityState.PAGE_SESSIONS_SCHEDULES.status != ParityStatus.PENDING) {
            "PAGE_SESSIONS_SCHEDULES is not registered as captured"
        }
        setCapturedContent {
            NativeAutomationPage(
                state = ScreenshotSamples.automationState(),
                onBack = {},
                onOpenDetail = {},
                onOpenHistory = {},
                onBackToCatalog = {},
                onRefresh = {},
                onNewSchedule = {},
            )
        }
        capture(ParityState.PAGE_SESSIONS_SCHEDULES.androidName)
    }

    /**
     * The route itself, not just the page: mounting `PdshNavHost` on
     * `PdshRoute.Sessions` must render the sessions root.
     *
     * This is the evidence that the page is reachable through the router — a page
     * that compiles and captures is still unreachable if `when (route)` never names
     * it. No PNG is written; the assertion is the deliverable.
     */
    @Test
    fun sessionsRouteRendersThePage() {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.Sessions)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = {},
                webSurface = {},
            )
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_ROOT).assertIsDisplayed()
        // The host reports no folder list through the router, so the page says 未知
        // instead of claiming either "no folders" or an invented one.
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_UNKNOWN).assertIsDisplayed()
        // No session list is reported either: the new-session row is there and the
        // page did not fabricate a 0.
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_ROW).assertIsDisplayed()
    }

    /**
     * Captures one sessions state in the container its iOS baseline used.
     *
     * @param drawer `true` mounts the page in the baseline's 320 pt drawer
     *   (`DrawerPreview`), `false` in the full 402 pt window (the `.sessions`
     *   route). The captured frame stays the profile's 1206 × 2622 either way — the
     *   drawer is a column at the top-leading corner, exactly like iOS's
     *   `.frame(width: 320)` + `.frame(maxWidth: .infinity, alignment: .topLeading)`.
     */
    private fun captureSessions(
        state: ParityState,
        drawer: Boolean = true,
        build: () -> SessionsScreenState,
    ) {
        check(state.status != ParityStatus.PENDING) {
            "${state.androidName} is registered but not captured yet (owner: ${state.owner})"
        }
        val screenState = build()
        setCapturedContent {
            Box(
                modifier = if (drawer) {
                    Modifier.width(DRAWER_WIDTH_DP.dp).fillMaxHeight()
                } else {
                    Modifier.fillMaxSize()
                },
            ) {
                SessionsPage(
                    state = screenState,
                    onSelect = {},
                    onQueryChange = {},
                    onRenameStart = {},
                    onRenameDraftChange = {},
                    onRenameCommit = {},
                    onRenameCancel = {},
                    onDeleteRequest = {},
                    onDeleteConfirm = {},
                    onDeleteCancel = {},
                    onNewSession = {},
                    // The baseline's failed-read state shows 重试; a null receiver would
                    // hide the control and make the capture a different state.
                    onRetry = if (screenState.failure != null) ({}) else null,
                    // The baseline's bar is empty in every one of the seven states
                    // (`SessionsPage.swift:137-322`: no title, no toolbar item), so no
                    // back control is passed: a route would be the only caller that
                    // has one.
                    onBack = null,
                )
            }
        }
        capture(state.androidName)
    }

    private companion object {
        /** `NativeShell.swift:97` / `:875`: the drawer column the baseline preview uses. */
        const val DRAWER_WIDTH_DP: Int = 320
    }
}
