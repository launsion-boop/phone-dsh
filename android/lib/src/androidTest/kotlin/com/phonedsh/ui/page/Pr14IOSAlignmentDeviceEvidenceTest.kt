// Device-rendered synthetic evidence for deep-chat and connector-empty surfaces.
// SPDX-License-Identifier: MIT

package com.phonedsh.ui.page

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.phonedsh.domain.connector.ConnectorStatus
import com.phonedsh.domain.connector.DeviceConnectionSnapshot
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.PendingQuestionItem
import com.phonedsh.ui.state.PendingQuestionOption
import com.phonedsh.ui.state.PendingQuestionProgress
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import androidx.compose.ui.test.junit4.createAndroidComposeRule

/** These captures use synthetic facts on a real emulator renderer; they are not iOS goldens. */
@RunWith(AndroidJUnit4::class)
class Pr14IOSAlignmentDeviceEvidenceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun syntheticMultiStepQuestionRendersBothStepsAndSubmitsSelectedAnswers() {
        var submitted = ""
        val question = PendingAnswer(
            id = "synthetic-question",
            requestId = "synthetic-question-request",
            kind = "question",
            title = "方案确认",
            subtitle = "请选择偏好",
            questionItems = listOf(
                PendingQuestionItem(
                    id = "target",
                    header = "目标设备",
                    prompt = "先适配哪种设备？",
                    options = listOf(PendingQuestionOption("iPhone"), PendingQuestionOption("Android")),
                ),
                PendingQuestionItem(
                    id = "release",
                    header = "发布方式",
                    prompt = "验证后如何交付？",
                    options = listOf(PendingQuestionOption("仅本地验证"), PendingQuestionOption("准备 PR")),
                ),
            ),
            initialProgress = PendingQuestionProgress(index = 0),
        )
        compose.setContent {
            PdshTheme {
                ChatPage(
                    state = ChatParitySamples.chatDefault().copy(
                        pending = PendingSlot(primary = question),
                        pendingExpanded = true,
                    ),
                    onDraftChange = {}, onSend = {}, onStop = {}, onToggleRow = {},
                    onApprove = {}, onDeny = {}, onDismissBanner = {}, onRetry = {}, onOpenSessions = {},
                    onSubmitAnswer = { _, answer -> submitted = answer },
                )
            }
        }

        compose.onNodeWithText("先适配哪种设备？").assertIsDisplayed()
        saveCapture("question-step-1")
        compose.onNodeWithContentDescription("Android").performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_QUESTION_SUBMIT).performClick()
        compose.onNodeWithText("验证后如何交付？").assertIsDisplayed()
        saveCapture("question-step-2")
        compose.onNodeWithContentDescription("准备 PR").performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_QUESTION_SUBMIT).performClick()
        compose.waitForIdle()
        assertTrue(submitted.contains("\"target\":[\"Android\"]"))
        assertTrue(submitted.contains("\"release\":[\"准备 PR\"]"))
    }

    @Test
    fun syntheticPlanReviewAndTodoGoalStateRendersAndOpensConfirmation() {
        var requested: ActivityGoalAction? = null
        compose.setContent {
            var local by remember { mutableStateOf(SessionActivityLocalState()) }
            PdshTheme {
                SessionActivityPage(
                    state = SessionActivityScreenState.from(
                        SessionActivitySource(
                            plan = ActivityPlan(active = true, pending = false),
                            todos = listOf(ActivityTodo("review", "检查 iOS 对齐截图", "in_progress")),
                            goal = ActivityGoal("完成 Android 页面迁移", "active", roundsStarted = 2, maxGoalRounds = 4),
                        ),
                        local,
                    ),
                    onRefresh = {},
                    onToggleError = {},
                    onConfirm = {},
                    onCancel = { local = SessionActivityLocalState() },
                    onRequestGoal = { action -> requested = action; local = local.apply(SessionActivityUiEvent.RequestGoal(action)) },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN_MODE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_TODO_ROW).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL).assertIsDisplayed()
        saveCapture("plan-review-todo-goal")
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_PAUSE).performClick()
        assertEquals(ActivityGoalAction.PAUSE, requested)
        compose.onNodeWithText(UiStrings.ACTIVITY_CONFIRM_GOAL_PAUSE).assertIsDisplayed()
    }

    @Test
    fun syntheticNilConnectorShowsUnavailableCopyWithoutInventingDevices() {
        val state = DeviceConnectionScreenState.from(
            DeviceConnectionSnapshot(
                connectorAvailable = false,
                connectorProtocol = null,
                status = ConnectorStatus.UNKNOWN,
            ),
        )
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(
                    state = state,
                    onOpen = { error("nil connector must not publish a device row") },
                    onForgetMapping = { error("nil connector has no saved mapping") },
                    onDone = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText("未接入设备连接器").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_EMPTY).assertDoesNotExist()
        saveCapture("device-connector-unavailable")
    }

    private fun saveCapture(name: String) {
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "pr14-ios-alignment-device-evidence")
        check(directory.isDirectory || directory.mkdirs()) { "cannot create $directory" }
        File(directory, "$name.png").outputStream().use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "failed to write $name" }
        }
    }
}
