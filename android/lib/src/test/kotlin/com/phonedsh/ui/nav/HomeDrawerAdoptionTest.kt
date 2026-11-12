// Page adoption of the shared menu, pressed and disclosure components (P09).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.menu.ContextMenuModel
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.ContextMenuTags
import com.phonedsh.ui.press.PressedAlphaSemantics
import com.phonedsh.ui.press.PressedState
import com.phonedsh.ui.press.PressedStyle
import com.phonedsh.ui.press.PressedSurface
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class HomeDrawerAdoptionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val density: Float get() = compose.activity.resources.displayMetrics.density

    @Test
    fun `folder long press shows exactly the drawerFolder contract items`() {
        mount(
            HomeDrawerFacts(
                folders = listOf(
                    HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "One"))),
                ),
                unassignedSessions = emptyList(),
            ),
            onCreateSessionInFolder = { true },
            onMutation = { request -> receipt(request) },
        )

        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "folder-1").performTouchInput { longClick() }
        compose.waitForIdle()

        assertMenuItems(
            surfaceId = "drawerFolder",
            state = ContextMenuRowState.of(TokenContextMenuWhen.FOLDERS_ENABLED to DRAWER_FOLDERS_ENABLED),
        )
    }

    @Test
    fun `session long press shows exactly the drawerSession contract items`() {
        mount(
            HomeDrawerFacts(
                folders = listOf(
                    HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "One"))),
                ),
                unassignedSessions = emptyList(),
            ),
            onMutation = { request -> receipt(request) },
            onArchiveSession = { request ->
                HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
            },
        )

        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "session-1").performTouchInput { longClick() }
        compose.waitForIdle()

        assertMenuItems(surfaceId = "drawerSession", state = ContextMenuRowState.unconditional)
    }

    @Test
    fun `menu is gone before a session action runs`() {
        val gate = CompletableDeferred<Unit>()
        var actionEntered = false
        mount(
            HomeDrawerFacts(
                folders = listOf(
                    HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "One"))),
                ),
                unassignedSessions = emptyList(),
            ),
            onArchiveSession = { request ->
                actionEntered = true
                gate.await()
                HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
            },
        )

        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "session-1").performTouchInput { longClick() }
        compose.waitForIdle()
        val archive = ContextMenuModel.items("drawerSession", ContextMenuRowState.unconditional)
            .single { it.order == 1 }
        compose.onNodeWithTag(ContextMenuTags.itemTag("drawerSession", archive.order))
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertTrue("the action must have started", actionEntered)
        compose.onNodeWithTag(ContextMenuTags.MENU)
            .assertDoesNotExist()
        gate.complete(Unit)
        compose.waitForIdle()
    }

    @Test
    fun `new session pill paints the pressed overlay and returns to rest on release`() {
        mount(HomeDrawerFacts(folders = emptyList(), unassignedSessions = emptyList()), onCreateSession = { false })
        assertPressed(
            tag = HomeDrawerTags.NEW_SESSION,
            pressed = PressedStyle.valuesFor(PressedSurface.DrawerPill, PressedState.Pressed).pressed,
            finishAction = MotionEvent.ACTION_UP,
        )
    }

    @Test
    fun `folder header paints the row fill and returns to rest on cancel`() {
        mount(
            HomeDrawerFacts(
                folders = listOf(HomeDrawerFolder("folder-1", "Research", emptyList())),
                unassignedSessions = emptyList(),
            ),
            onCreateSessionInFolder = { true },
        )
        assertPressed(
            tag = HomeDrawerTags.FOLDER_PREFIX + "folder-1",
            pressed = PressedStyle.valuesFor(PressedSurface.DrawerRow, PressedState.Pressed).pressed,
            finishAction = MotionEvent.ACTION_CANCEL,
        )
    }

    @Test
    fun `session row paints the row fill and returns to rest on release`() {
        mount(
            HomeDrawerFacts(
                folders = listOf(
                    HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "One"))),
                ),
                unassignedSessions = emptyList(),
            ),
            onOpenSession = {},
            onArchiveSession = { request ->
                HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
            },
        )
        assertPressed(
            tag = HomeDrawerTags.SESSION_PREFIX + "session-1",
            pressed = PressedStyle.valuesFor(PressedSurface.DrawerRow, PressedState.Pressed).pressed,
            finishAction = MotionEvent.ACTION_UP,
        )
    }

    @Test
    fun `folder collapse runs the 180 ms folder motion and keeps the header fixed`() {
        mount(
            HomeDrawerFacts(
                folders = listOf(
                    HomeDrawerFolder(
                        "folder-1",
                        "Research",
                        listOf(HomeDrawerSession("session-1", "One"), HomeDrawerSession("session-2", "Two")),
                    ),
                ),
                unassignedSessions = emptyList(),
            ),
            onCreateSessionInFolder = { true },
        )
        val folderTag = HomeDrawerTags.FOLDER_PREFIX + "folder-1"
        val bodyTag = PdshDisclosureTags.body(folderTag)
        val fullHeight = bodyHeightDp(bodyTag)
        assertTrue("the fixture must expand to a non-zero body", fullHeight > 0f)
        val headerTop = compose.onNodeWithTag(folderTag).fetchSemanticsNode().boundsInRoot.top

        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag(folderTag).performSemanticsAction(SemanticsActions.OnClick)
        compose.mainClock.advanceTimeByFrame()

        val folderDuration = DisclosureMotion.specFor(DisclosureKind.FOLDER, reducedMotion = false).durationMs
        assertEquals("the drawer folder group must use motion.folderCollapse", 180, folderDuration)

        compose.mainClock.advanceTimeBy((folderDuration / 2L))
        val midHeight = bodyHeightDp(bodyTag)
        assertTrue("folder body is mid-animation at half of motion.folderCollapse (height=$midHeight)", midHeight > 0f && midHeight < fullHeight)
        assertEquals("rule 6: the folder header stays fixed mid-animation", headerTop, compose.onNodeWithTag(folderTag).fetchSemanticsNode().boundsInRoot.top, 0.5f)

        // A 160 ms body motion would already be gone here; folderCollapse is 180 ms.
        compose.mainClock.advanceTimeBy(folderDuration - folderDuration / 2L - 10L)
        compose.onNodeWithTag(bodyTag).assertExists()

        compose.mainClock.advanceTimeBy(40L)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()
        assertEquals("rule 6: the folder header does not move at the end state", headerTop, compose.onNodeWithTag(folderTag).fetchSemanticsNode().boundsInRoot.top, 0.5f)
    }

    private fun assertMenuItems(surfaceId: String, state: ContextMenuRowState) {
        val expected = ContextMenuModel.items(surfaceId, state)
        assertTrue("the fixture must leave at least one visible row", expected.isNotEmpty())
        expected.forEach { item ->
            compose.onNodeWithTag(ContextMenuTags.itemTag(surfaceId, item.order)).assertIsDisplayed()
            compose.onNodeWithText(item.label).assertIsDisplayed()
        }
        compose.onAllNodesWithTag(ContextMenuTags.MENU).assertCountEquals(1)
        ContextMenuModel.surface(surfaceId).items.forEachIndexed { order, token ->
            if (!state.shows(token.whenCondition)) {
                compose.onNodeWithTag(ContextMenuTags.itemTag(surfaceId, order)).assertDoesNotExist()
            }
        }
    }

    /**
     * Compose's `performTouchInput` disposes its dispatcher at the end of the
     * block, which cancels the press before the test clock can advance. Send the
     * same MotionEvents straight to the dialog's decor view so the down frame
     * can be observed, then release/cancel through the same path.
     */
    private fun assertPressed(tag: String, pressed: Float, finishAction: Int) {
        val center = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.center
        val downTime = SystemClock.uptimeMillis()
        dispatchTouch(downTime, MotionEvent.ACTION_DOWN, center)
        compose.mainClock.advanceTimeBy(200)
        assertEquals("the row must paint the §6 pressed value", pressed, alpha(tag), 0.001f)

        dispatchTouch(downTime, finishAction, center)
        compose.mainClock.advanceTimeByFrame()
        val restMessage = if (finishAction == MotionEvent.ACTION_CANCEL) {
            "a cancelled gesture returns to rest"
        } else {
            "a released gesture returns to rest"
        }
        assertEquals(restMessage, 0f, alpha(tag), 0f)
    }

    private fun dispatchTouch(downTime: Long, action: Int, position: Offset) {
        val dialog = ShadowDialog.getLatestDialog()
        val decor = dialog.window!!.decorView
        val event = MotionEvent.obtain(
            downTime,
            SystemClock.uptimeMillis(),
            action,
            position.x,
            position.y,
            0,
        )
        decor.dispatchTouchEvent(event)
        event.recycle()
    }

    private fun alpha(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().config[PressedAlphaSemantics]

    private fun bodyHeightDp(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height / density

    private fun receipt(request: PdshUiHostCommand): PdshActionReceipt =
        when (request) {
            is PdshUiHostCommand.SessionRename ->
                PdshActionReceipt(request.requestId, request.sessionId, null, PdshActionOutcome.SUCCEEDED)
            else -> PdshActionReceipt(StateRequestId("test"), null, null, PdshActionOutcome.FAILED)
        }

    private fun mount(
        facts: HomeDrawerFacts,
        onCreateSession: (suspend () -> Boolean)? = null,
        onMutation: HomeDrawerMutationAction? = null,
        onArchiveSession: HomeDrawerArchiveAction? = null,
        onCreateSessionInFolder: (suspend (String) -> Boolean)? = null,
        onOpenSession: ((String) -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize()) {
                    HomeDrawer(
                        facts = facts,
                        onClose = {},
                        onCreateSession = onCreateSession,
                        onMutation = onMutation,
                        onArchiveSession = onArchiveSession,
                        onCreateSessionInFolder = onCreateSessionInFolder,
                        onOpenSession = onOpenSession,
                    )
                }
            }
        }
        compose.waitForIdle()
    }
}
