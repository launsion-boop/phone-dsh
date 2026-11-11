// Compose interaction checks for the PR22 home drawer overlay.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.activity.ComponentActivity
import kotlinx.coroutines.CompletableDeferred
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
// These assertions exercise the drawer's business actions through semantics; actual
// pointer placement around the native cutout and footer is verified by the separate
// installed-device gesture suite, which runs against the platform window geometry.
class HomeDrawerStateTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun overlayShowsEntriesAndClosesFromScrim() {
        var closed = false
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize()) {
                    HomeDrawer(HomeDrawerFacts(), onClose = { closed = true }, onCreateSession = { true })
                }
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION).assertIsDisplayed()
        // The drawer no longer owns navigation: the pinned 设置 bar and the
        // 定时任务 row moved to the HomeTabBar's 我的 tab, asserted by
        // SettingsModesAndConnectorsTest. Keep the removed entries gone here.
        compose.onNodeWithText("设置").assertDoesNotExist()
        compose.onNodeWithText("定时任务").assertDoesNotExist()
        compose.onNodeWithTag(HomeDrawerTags.SCRIM).performSemanticsAction(SemanticsActions.OnClick)
        // Rule 8: the host learns about the dismissal only after 220 ms of close.
        compose.mainClock.advanceTimeBy(300)
        compose.runOnIdle { assertEquals(true, closed) }
    }

    @Test fun newSessionKeepsDrawerOpenUntilHostConfirmsCreation() {
        var confirmed = false
        var calls = 0
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(
                    facts = HomeDrawerFacts(),
                    onClose = { confirmed = true },
                    onCreateSession = { calls++; false },
                )
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.PANEL).assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(1, calls)
            assertEquals(false, confirmed)
        }
    }

    @Test fun dialogBackDismissesDrawer() {
        var closed = false
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize()) { HomeDrawer(HomeDrawerFacts(), onClose = { closed = true }) }
            }
        }
        val dialog = ShadowDialog.getLatestDialog()
        assertNotNull(dialog)
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        // Rule 9 uses the same 220 ms close animation; nothing is instant.
        compose.mainClock.advanceTimeBy(300)
        compose.runOnIdle { assertEquals(true, closed) }
    }

    @Test fun rendersDefaultAndUnassignedGroupsAndPreservesFolderFold() {
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder("daily", "日常", emptyList(), isDefault = true)),
            unassignedSessions = listOf(HomeDrawerSession("s1", "会话一")),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {}, onOpenSession = {})
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "daily").assertExists()
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").assertExists()
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "daily").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").assertDoesNotExist()
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "daily").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").assertExists()
    }


    @Test fun defaultFolderUsesPhoneWorkspaceWhenTheAppLanguageIsEnglish() {
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder("daily", "日常", emptyList(), isDefault = true)),
            languageId = "en",
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {})
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "daily")
            .assertContentDescriptionEquals("Phone Workspace，0 个会话")
    }

    @Test fun blockedNewSessionShowsItsReasonBelowTheDisabledCapsule() {
        val facts = HomeDrawerFacts(
            newSessionBlockedReason = UiStrings.DRAWER_NEW_BLOCKED_TURN,
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {}, onCreateSession = { true })
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION).assertIsNotEnabled()
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION_REASON).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DRAWER_NEW_BLOCKED_TURN).assertIsDisplayed()
    }

    @Test fun newSessionReasonAppearsAndDisappearsWithoutMovingTheSessionList() {
        var reason by mutableStateOf<String?>(null)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(
                    facts = HomeDrawerFacts(
                        folders = listOf(
                            HomeDrawerFolder(
                                "daily",
                                "日常",
                                listOf(HomeDrawerSession("s1", "会话一")),
                                isDefault = true,
                            ),
                        ),
                        unassignedSessions = emptyList(),
                        newSessionBlockedReason = reason,
                    ),
                    onClose = {},
                    onCreateSession = { true },
                )
            }
        }
        compose.waitForIdle()
        val session = compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1")
        val topWithoutReason = session.fetchSemanticsNode().boundsInRoot.top

        compose.runOnIdle { reason = UiStrings.DRAWER_NEW_BLOCKED_TURN }
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION_REASON).assertIsDisplayed()
        val topWithReason = session.fetchSemanticsNode().boundsInRoot.top
        assertEquals(
            "the reason line must not push the first session row down",
            topWithoutReason,
            topWithReason,
            0.01f,
        )

        compose.runOnIdle { reason = null }
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.NEW_SESSION_REASON).assertDoesNotExist()
        val topAfterRemoval = session.fetchSemanticsNode().boundsInRoot.top
        assertEquals(
            "removing the reason line must not pull the first session row up",
            topWithoutReason,
            topAfterRemoval,
            0.01f,
        )
    }

    @Test fun title日常DoesNotTurnACustomFolderIntoTheDefaultOrAbsorbLooseSessions() {
        val facts = HomeDrawerFacts(
            folders = listOf(
                HomeDrawerFolder("custom-daily", "日常", emptyList(), isDefault = false),
            ),
            unassignedSessions = listOf(HomeDrawerSession("loose", "未分配会话")),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {}, onOpenSession = {})
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "custom-daily")
            .assertContentDescriptionEquals("日常，0 个会话")
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "__unassigned__")
            .assertContentDescriptionEquals("${UiStrings.DRAWER_DEFAULT_FOLDER}，1 个会话")
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "loose").assertIsDisplayed()
    }

    @Test fun sessionLongPressOffersRealRenameAndArchiveCallbacks() {
        var archived = ""
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder("daily", "日常", listOf(HomeDrawerSession("s1", "会话一")), true)),
            unassignedSessions = emptyList(),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {}, onArchiveSession = { request ->
                    archived = request.sessionId
                    HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
                })
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("归档").performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnIdle { assertEquals("s1", archived) }
        compose.onNodeWithText("已归档，可在 我的 › 已归档会话 里找回").assertExists()
    }

    @Test fun archiveWaitsForCorrelatedHostResultAndFailureCanRetry() {
        val firstResult = CompletableDeferred<HomeDrawerArchiveResult>()
        var firstRequest: HomeDrawerArchiveRequest? = null
        var calls = 0
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder("daily", "日常", listOf(HomeDrawerSession("s1", "会话一")), true)),
            unassignedSessions = emptyList(),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                HomeDrawer(facts, onClose = {}, onArchiveSession = { request ->
                    calls++
                    if (calls == 1) {
                        firstRequest = request
                        firstResult.await()
                    } else {
                        HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
                    }
                })
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("归档").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.ARCHIVE_PENDING_PREFIX + "s1").assertExists()
        compose.onNodeWithText("已归档，可在 我的 › 已归档会话 里找回").assertDoesNotExist()

        val request = requireNotNull(firstRequest)
        firstResult.complete(HomeDrawerArchiveResult.Failed(request.requestId, request.sessionId, "保存未完成"))
        compose.waitForIdle()
        compose.onNodeWithTag(HomeDrawerTags.ARCHIVE_FAILURE_PREFIX + "s1").assertExists()
        compose.onNodeWithText("已归档，可在 我的 › 已归档会话 里找回").assertDoesNotExist()
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").assertExists()

        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("归档").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText("已归档，可在 我的 › 已归档会话 里找回").assertExists()
        compose.runOnIdle { assertEquals(2, calls) }
    }

    @Test fun closingWhileArchiveIsPendingSuppressesLateSuccessToast() {
        val response = CompletableDeferred<HomeDrawerArchiveResult>()
        var request: HomeDrawerArchiveRequest? = null
        compose.setContent {
            PdshTheme(darkTheme = false) {
                val open = androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(true) }
                Box(Modifier.fillMaxSize()) {
                    if (open.value) {
                        HomeDrawer(
                            facts = HomeDrawerFacts(
                                folders = listOf(HomeDrawerFolder("daily", "日常", listOf(HomeDrawerSession("s1", "会话一")), true)),
                                unassignedSessions = emptyList(),
                            ),
                            onClose = { open.value = false },
                            onArchiveSession = { archiveRequest -> request = archiveRequest; response.await() },
                        )
                    }
                }
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "s1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("归档").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithTag(HomeDrawerTags.SCRIM).performSemanticsAction(SemanticsActions.OnClick)
        val archiveRequest = requireNotNull(request)
        response.complete(HomeDrawerArchiveResult.Archived(archiveRequest.requestId, archiveRequest.sessionId))
        compose.waitForIdle()
        compose.onNodeWithText("已归档，可在 我的 › 已归档会话 里找回").assertDoesNotExist()
    }

    @Test fun folderManagementIsNotOfferedWhileGroupsStillShow() {
        // DRAWER_FOLDERS_ENABLED = false (iOS HomeDrawer.foldersEnabled): no 文件夹
        // title, no 新建文件夹, no empty-folder hint, no folder rename/delete; the
        // session group itself and 在这里新建会话 remain.
        assertFalse(DRAWER_FOLDERS_ENABLED)
        compose.setContent {
            PdshTheme {
                HomeDrawer(
                    facts = HomeDrawerFacts(
                        folders = listOf(HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "One")))),
                        unassignedSessions = emptyList(),
                    ),
                    onClose = {},
                    onMutation = { request -> PdshActionReceipt((request as PdshUiHostCommand.SessionRename).requestId, null, null, PdshActionOutcome.FAILED) },
                    onCreateSessionInFolder = { _ -> true },
                )
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.CREATE_FOLDER).assertDoesNotExist()
        compose.onNodeWithText("文件夹").assertDoesNotExist()
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "folder-1").assertIsDisplayed()
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "folder-1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("在这里新建会话").assertIsDisplayed()
        compose.onNodeWithText("重命名").assertDoesNotExist()
        compose.onNodeWithText("删除文件夹").assertDoesNotExist()
    }

    @Test fun emptyDrawerShowsNoFolderCreationHint() {
        compose.setContent {
            PdshTheme {
                HomeDrawer(
                    facts = HomeDrawerFacts(folders = emptyList(), unassignedSessions = emptyList()),
                    onClose = {},
                    onMutation = { request -> PdshActionReceipt((request as PdshUiHostCommand.SessionRename).requestId, null, null, PdshActionOutcome.FAILED) },
                )
            }
        }
        compose.onNodeWithText("还没有文件夹", substring = true).assertDoesNotExist()
        compose.onNodeWithTag(HomeDrawerTags.CREATE_FOLDER).assertDoesNotExist()
    }

    @Test fun renameSessionIsRequestBoundAndDoesNotHideRowAfterFailedReceipt() {
        var command: PdshUiHostCommand? = null
        val facts = HomeDrawerFacts(
            folders = listOf(HomeDrawerFolder("folder-1", "Research", listOf(HomeDrawerSession("session-1", "Before")))),
            unassignedSessions = emptyList(),
        )
        compose.setContent {
            PdshTheme {
                HomeDrawer(
                    facts = facts,
                    onClose = {},
                    onMutation = { request ->
                        command = request
                        val rename = request as PdshUiHostCommand.SessionRename
                        PdshActionReceipt(rename.requestId, rename.sessionId, null, PdshActionOutcome.FAILED)
                    },
                )
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "session-1").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("编辑名称").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextClearance()
        compose.onNodeWithTag(HomeDrawerTags.EDITOR).performTextInput("After")
        compose.onNodeWithText("保存").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        val rename = command as? PdshUiHostCommand.SessionRename
        assertEquals("session-1", rename?.sessionId)
        assertEquals("After", rename?.title)
        compose.onNodeWithTag(HomeDrawerTags.FAILURE).assertIsDisplayed()
        compose.onNodeWithTag(HomeDrawerTags.SESSION_PREFIX + "session-1").assertIsDisplayed()
    }

    @Test fun folderContextMenuCreatesSessionWithExactFolderId() {
        var requestedFolder: String? = null
        var closed = false
        compose.setContent {
            PdshTheme {
                HomeDrawer(
                    facts = HomeDrawerFacts(
                        folders = listOf(HomeDrawerFolder("stable-folder-9", "Research", isDefault = false)),
                        unassignedSessions = emptyList(),
                    ),
                    onClose = { closed = true },
                    onCreateSessionInFolder = { folderId -> requestedFolder = folderId; true },
                )
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.FOLDER_PREFIX + "stable-folder-9").performSemanticsAction(SemanticsActions.OnLongClick)
        compose.onNodeWithText("在这里新建会话").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(300)
        compose.runOnIdle {
            assertEquals("stable-folder-9", requestedFolder)
            assertEquals(true, closed)
        }
    }

    @Test fun drawerRetryCallsHostSnapshotRefreshAndDisplaysReadError() {
        var retries = 0
        compose.setContent {
            PdshTheme {
                HomeDrawer(
                    facts = HomeDrawerFacts(failure = "实际读取失败"),
                    onClose = {},
                    onRetry = { retries++ },
                )
            }
        }
        compose.onNodeWithTag(HomeDrawerTags.FAILURE).assertIsDisplayed()
        compose.onNodeWithTag(HomeDrawerTags.RETRY).performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnIdle { assertEquals(1, retries) }
    }
}
