// Physical drawer interactions on the owned device after the cutout layout fix.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.nav.HomeDrawerArchiveResult.Archived
import com.phonedsh.ui.nav.HomeDrawerArchiveResult.Failed
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.state.StateRevision
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HomeDrawerCutoutDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun drawerPanelMeasures320DpAndFooterSettingsIsVisibleAndTouchReachable() {
        val settingsOpened = AtomicInteger()
        mount(
            facts = HomeDrawerFacts(
                folders = listOf(HomeDrawerFolder("folder-a", "Research")),
                unassignedSessions = emptyList(),
                engine = HomeDrawerEngineState.READY,
            ),
            onOpenSettings = { settingsOpened.incrementAndGet() },
        )
        val panel = compose.onNodeWithTag(HomeDrawerTags.PANEL)
        panel.assertIsDisplayed()
        compose.onNodeWithTag(HomeDrawerTags.SETTINGS).assertIsDisplayed()
        compose.onNodeWithText("设置").assertIsDisplayed()

        val density = compose.activity.resources.displayMetrics.density
        val screen = compose.activity.resources.displayMetrics
        val panelBounds = panel.fetchSemanticsNode().boundsInRoot
        val settingsBounds = compose.onNodeWithTag(HomeDrawerTags.SETTINGS).fetchSemanticsNode().boundsInRoot
        assertEquals("drawer panel must be the source's 320pt width", 320f, panelBounds.width / density, 1f)
        assertTrue("footer settings must fit inside the panel", settingsBounds.bottom <= panelBounds.bottom)
        savePanelEvidence(panelBounds, settingsBounds, screen.widthPixels, screen.heightPixels, density)

        // Route through the actual touch target, not a semantics click.
        compose.onNodeWithTag(HomeDrawerTags.SETTINGS).performTouchInput { click() }
        compose.runOnIdle { assertEquals(1, settingsOpened.get()) }
    }

    @Test
    fun newSessionStaysOpenUntilTheHostConfirmsTrue() {
        val response = CompletableDeferred<Boolean>()
        val calls = AtomicInteger()
        val closed = AtomicBoolean(false)
        mount(
            onClose = { closed.set(true) },
            onCreateSession = {
                if (calls.incrementAndGet() == 1) response.await() else true
            },
        )

        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION).performTouchInput { click() }
        compose.waitUntil(5_000) { calls.get() == 1 }
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertIsDisplayed()
        assertFalse("pending create must not close the drawer", closed.get())

        response.complete(false)
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertIsDisplayed()
        assertFalse("a negative host result must keep the drawer open", closed.get())

        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION).performTouchInput { click() }
        compose.waitUntil(5_000) { closed.get() }
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(HomeDrawerTags.PANEL).fetchSemanticsNodes().isEmpty()
        }
        assertEquals("only the second, confirmed true result closes the drawer", 2, calls.get())
    }

    @Test
    fun folderFoldAndFolderCreateUseTouchAndCorrelatedReceipts() {
        val commands = CopyOnWriteArrayList<PdshUiHostCommand>()
        val creates = AtomicInteger()
        val retries = AtomicInteger()
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder(
                id = "folder-stable-9",
                title = "Research",
                sessions = listOf(HomeDrawerSession("session-1", "Alpha")),
            )),
            unassignedSessions = emptyList(),
        )
        mount(
            facts = facts,
            onMutation = { command ->
                commands += command
                val create = command as PdshUiHostCommand.WorkspaceFolderCreate
                val outcome = if (creates.getAndIncrement() == 0) PdshActionOutcome.FAILED else PdshActionOutcome.SUCCEEDED
                PdshActionReceipt(create.requestId, null, StateRevision(1), outcome)
            },
            onRetry = { retries.incrementAndGet() },
        )

        val folderTag = HomeDrawerTags.FOLDER_PREFIX + "folder-stable-9"
        val sessionTag = HomeDrawerTags.SESSION_PREFIX + "session-1"
        compose.onNodeWithTag(folderTag).performTouchInput { click() }
        assertTrue(compose.onAllNodesWithTag(sessionTag).fetchSemanticsNodes().isEmpty())
        compose.onNodeWithTag(folderTag).performTouchInput { click() }
        compose.onNodeWithTag(sessionTag).assertIsDisplayed()

        compose.onNodeWithTag(HomeDrawerTags.CREATE_FOLDER).performTouchInput { click() }
        compose.onNodeWithText("新建文件夹").performTouchInput { click() }
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextInput("Research & Notes")
        compose.onNodeWithText("创建").performTouchInput { click() }
        compose.waitUntil(5_000) { creates.get() == 1 }
        val failedCreate = commands.first() as PdshUiHostCommand.WorkspaceFolderCreate
        assertEquals("Research & Notes", failedCreate.name)
        assertTrue(failedCreate.requestId.value.isNotBlank())
        compose.onNodeWithTag(HomeDrawerTags.FAILURE).assertIsDisplayed()
        compose.onNodeWithTag(HomeDrawerTags.RETRY).performTouchInput { click() }
        compose.runOnIdle { assertEquals(1, retries.get()) }

        compose.onNodeWithTag(HomeDrawerTags.CREATE_FOLDER).performTouchInput { click() }
        compose.onNodeWithText("新建文件夹").performTouchInput { click() }
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextInput("Writing")
        compose.onNodeWithText("创建").performTouchInput { click() }
        compose.waitUntil(5_000) { creates.get() == 2 }
        val successfulCreate = commands.last() as PdshUiHostCommand.WorkspaceFolderCreate
        assertEquals("Writing", successfulCreate.name)
        assertTrue(successfulCreate.requestId.value.isNotBlank())
        assertTrue("each create requires its own correlated request", failedCreate.requestId != successfulCreate.requestId)
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(HomeDrawerTags.FAILURE).fetchSemanticsNodes().isEmpty()
        }
    }

    @Test
    fun sessionAndFolderLongPressMenusUseRealRenameArchiveAndExactFolderCallbacks() {
        val mutations = CopyOnWriteArrayList<PdshUiHostCommand>()
        val archiveRequests = CopyOnWriteArrayList<HomeDrawerArchiveRequest>()
        val archiveCalls = AtomicInteger()
        val createdFolder = AtomicReference<String?>(null)
        val closed = AtomicBoolean(false)
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder(
                id = "folder-stable-exact",
                title = "Research",
                sessions = listOf(HomeDrawerSession("session-9", "Before")),
            )),
            unassignedSessions = emptyList(),
        )
        mount(
            facts = facts,
            onClose = { closed.set(true) },
            onMutation = { command ->
                mutations += command
                val rename = command as PdshUiHostCommand.SessionRename
                PdshActionReceipt(rename.requestId, rename.sessionId, StateRevision(2), PdshActionOutcome.SUCCEEDED)
            },
            onArchiveSession = { request ->
                archiveRequests += request
                if (archiveCalls.getAndIncrement() == 0) {
                    Failed(request.requestId, request.sessionId, "fixture archive failed")
                } else {
                    Archived(request.requestId, request.sessionId)
                }
            },
            onCreateSessionInFolder = { folderId -> createdFolder.set(folderId); true },
        )

        val sessionTag = HomeDrawerTags.SESSION_PREFIX + "session-9"
        compose.onNodeWithTag(sessionTag).performTouchInput { longClick() }
        compose.onNodeWithText("编辑名称").performTouchInput { click() }
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextClearance()
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextInput("After")
        compose.onNodeWithText("保存").performTouchInput { click() }
        compose.waitUntil(5_000) { mutations.isNotEmpty() }
        val rename = mutations.single() as PdshUiHostCommand.SessionRename
        assertEquals("session-9", rename.sessionId)
        assertEquals("After", rename.title)
        assertTrue(rename.requestId.value.isNotBlank())

        compose.onNodeWithTag(sessionTag).performTouchInput { longClick() }
        compose.onNodeWithText("归档").performTouchInput { click() }
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(HomeDrawerTags.ARCHIVE_FAILURE_PREFIX + "session-9").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(sessionTag).assertIsDisplayed()

        compose.onNodeWithTag(sessionTag).performTouchInput { longClick() }
        compose.onNodeWithText("归档").performTouchInput { click() }
        compose.waitUntil(5_000) {
            compose.onAllNodesWithText("已归档，可在 设置 › 已归档会话 里找回").fetchSemanticsNodes().isNotEmpty()
        }
        assertEquals(2, archiveRequests.size)
        assertEquals("session-9", archiveRequests.last().sessionId)
        assertTrue(archiveRequests[0].requestId != archiveRequests[1].requestId)

        val folderTag = HomeDrawerTags.FOLDER_PREFIX + "folder-stable-exact"
        compose.onNodeWithTag(folderTag).performTouchInput { longClick() }
        compose.onNodeWithText("在这里新建会话").performTouchInput { click() }
        compose.waitUntil(5_000) { createdFolder.get() != null }
        assertEquals("folder-stable-exact", createdFolder.get())
        compose.waitUntil(5_000) { closed.get() }
    }

    private fun mount(
        facts: HomeDrawerFacts = HomeDrawerFacts(),
        onClose: () -> Unit = {},
        onCreateSession: (suspend () -> Boolean)? = null,
        onMutation: HomeDrawerMutationAction? = null,
        onArchiveSession: HomeDrawerArchiveAction? = null,
        onCreateSessionInFolder: (suspend (String) -> Boolean)? = null,
        onRetry: (() -> Unit)? = null,
        onOpenSettings: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = true) {
                Box(Modifier.fillMaxSize()) {
                    HomeDrawer(
                        facts = facts,
                        onClose = onClose,
                        onCreateSession = onCreateSession,
                        onMutation = onMutation,
                        onArchiveSession = onArchiveSession,
                        onCreateSessionInFolder = onCreateSessionInFolder,
                        onRetry = onRetry,
                        onOpenSettings = onOpenSettings,
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun savePanelEvidence(
        panelBounds: androidx.compose.ui.geometry.Rect,
        settingsBounds: androidx.compose.ui.geometry.Rect,
        widthPx: Int,
        heightPx: Int,
        density: Float,
    ) {
        val context = InstrumentationRegistry.getInstrumentation().context
        val directory = File(requireNotNull(context.getExternalFilesDir(null)), "drawer-cutout-evidence")
        check(directory.mkdirs() || directory.isDirectory)
        File(directory, "panel.txt").writeText(
            """screen=${widthPx}x$heightPx density=$density
panelBoundsPx=$panelBounds
panelWidthDp=${panelBounds.width / density}
settingsBoundsPx=$settingsBounds
""",
        )
        val bitmap: Bitmap = compose.onNodeWithTag(HomeDrawerTags.PANEL).captureToImage().asAndroidBitmap()
        FileOutputStream(File(directory, "drawer-panel.png")).use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        }
    }
}
