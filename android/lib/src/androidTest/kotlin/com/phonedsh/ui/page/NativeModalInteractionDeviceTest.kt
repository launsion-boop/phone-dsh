// Modal input behavior that uses Android's real IME/dialog window.
// SPDX-License-Identifier: MIT

package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeModalInteractionDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun workspaceCreateAlertValidatesInputAndCommitsOnlyAValidName() {
        var created = 0
        compose.setContent {
            var local by remember { mutableStateOf(WorkspaceFoldersLocalState()) }
            val snapshot = WorkspaceFoldersSnapshot(folders = emptyList(), writable = FactState.YES)
            PdshTheme {
                WorkspaceFoldersPage(
                    state = WorkspaceFoldersScreenState.from(snapshot, local),
                    onBack = {},
                    onOpenFiles = {},
                    onSwitch = {},
                    onBeginCreate = { local = local.apply(WorkspaceFoldersUiEvent.BeginCreate) },
                    onDraftChange = { value -> local = local.apply(WorkspaceFoldersUiEvent.DraftChange(value)) },
                    onCancelCreate = { local = local.apply(WorkspaceFoldersUiEvent.CancelCreate) },
                    onCreate = {
                        created += 1
                        local = local.apply(WorkspaceFoldersUiEvent.CancelCreate)
                    },
                    onDeleteRequest = {},
                    onDeleteConfirm = {},
                    onDeleteCancel = {},
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.WORKSPACE_NEW).performClick()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE_ROW).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_NAME_FIELD).performTextInput("a/b")
        compose.onNodeWithText(UiStrings.WORKSPACE_NAME_SEPARATOR).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE).assertIsNotEnabled()
        assertEquals(0, created)

        compose.onNodeWithTag(UiPageTags.WORKSPACE_NAME_FIELD).performTextClearance()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_NAME_FIELD).performTextInput("Project B")
        compose.onNodeWithTag(UiPageTags.WORKSPACE_NAME_ERROR).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE).assertIsEnabled().performClick()
        compose.waitForIdle()
        assertEquals(1, created)
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE_ROW).assertDoesNotExist()

        compose.onNodeWithTag(UiPageTags.WORKSPACE_NEW).performClick()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE_ROW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CANCEL).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_CREATE_ROW).assertDoesNotExist()
        assertEquals(1, created)
    }

    @Test
    fun scheduleSheetPreservesInputAndClosesOnlyAfterMatchingRereadReceipt() {
        var savedDraft: AutomationScheduleDraft? = null
        var savedRequestID: String? = null
        var publishReceipt: (() -> Unit)? = null
        compose.setContent {
            var local by remember { mutableStateOf(AutomationLocalState()) }
            var facts by remember {
                mutableStateOf(
                    AutomationFacts(
                        snapshot = AutomationSnapshot(schedules = emptyList()),
                        currentSessionID = "worker-session-1",
                        writable = FactState.YES,
                    ),
                )
            }
            PdshTheme {
                NativeAutomationPage(
                    state = AutomationScreenState.from(facts, local),
                    onBack = {},
                    onOpenDetail = { id -> local = local.apply(AutomationUiEvent.OpenDetail(id)) },
                    onOpenHistory = { id -> local = local.apply(AutomationUiEvent.OpenHistory(id)) },
                    onBackToCatalog = { local = local.apply(AutomationUiEvent.Back) },
                    onRefresh = {},
                    onNewSchedule = {
                        local = local.apply(
                            AutomationUiEvent.OpenEditor(
                                AutomationScheduleDraft.from(null, "Asia/Taipei"),
                            ),
                        )
                    },
                    onDraftChange = { draft -> local = local.apply(AutomationUiEvent.EditDraft(draft)) },
                    onSubmitDraft = { draft, requestID ->
                        savedDraft = draft
                        savedRequestID = requestID
                        local = local.apply(AutomationUiEvent.SubmitDraft(requestID))
                        val saved = AutomationSchedule(
                            id = "schedule-1",
                            title = draft.title,
                            prompt = draft.prompt,
                            status = ScheduleStatus.ACTIVE,
                            rule = draft.rule.wire,
                            nextRun = "2026-11-02T09:00:00Z",
                            sessionTitle = "当前会话",
                        )
                        publishReceipt = {
                            facts = facts.copy(
                                snapshot = AutomationSnapshot(schedules = listOf(saved)),
                                writeReceipt = AutomationWriteReceipt(
                                    requestID = requestID,
                                    savedSchedule = saved,
                                ),
                            )
                        }
                    },
                    onCancelEditor = { local = local.apply(AutomationUiEvent.CancelEditor) },
                    onEditorSaved = { local = local.apply(AutomationUiEvent.CancelEditor) },
                )
            }

        }

        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_NAME).performTextInput("周报")
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_PROMPT).performTextInput("总结这一周")
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE_DIALOG).assertIsDisplayed()
        listOf("after", "at", "every", "daily", "weekly", "cron").forEach { rule ->
            compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + rule).assertIsDisplayed()
        }
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + "weekly").performClick()
        val weekdaysTag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + "weekdays"
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_LIST)
            .performScrollToNode(androidx.compose.ui.test.hasTestTag(weekdaysTag))
        compose.onNodeWithTag(weekdaysTag).performTextClearance()
        compose.onNodeWithTag(weekdaysTag).performTextInput("1,2,3")
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_SAVE).performClick()
        compose.waitForIdle()

        assertEquals("周报", savedDraft?.title)
        assertEquals("总结这一周", savedDraft?.prompt)
        assertEquals("1,2,3", savedDraft?.weekdays)
        assertNotNull(savedRequestID)
        // The editor remains present until a matching host response supplies the
        // reread schedule record.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.runOnIdle { publishReceipt?.invoke() }
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "schedule-1").assertIsDisplayed()

        // Reopening the form and cancelling returns to its parent without saving.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CANCEL).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertDoesNotExist()
    }
}
