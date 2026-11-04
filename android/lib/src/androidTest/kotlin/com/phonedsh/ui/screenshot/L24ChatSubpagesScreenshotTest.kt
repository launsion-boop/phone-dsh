// L24's three chat 内嵌子页 on a real device: the sheets, the result page, the verbs.
// SPDX-License-Identifier: MIT
//
// What this suite proves, on pixels rather than on the JVM:
//
//   * `PdshRoute.SessionJobs`, `PdshRoute.SessionSchedules` and
//     `PdshRoute.CommandResult` render their pages through `PdshNavHost`, and the
//     honest default (this host reads no session activity and runs no `/command`)
//     is 读取不到 — not an invented empty list and not a fabricated execution;
//   * a host that *did* report rows renders them: title, status, detail, prompt;
//   * `刷新` really is a control: a tap on the device reaches the router's
//     host-action seam as `PdshHostAction.RefreshSessionActivity`, and `完成`/`关闭`
//     pop the route;
//   * the two states of each surface are visually distinct (unread vs rows).
//
// The page-head menu's two sheet rows are asserted, not captured: a Compose
// `DropdownMenu` lives in its own Popup window, so `captureToImage()` of the page
// frame would not contain it and the PNG would be a lie.
//
// The rows in the "reported" captures are fixtures, not product data: they are the
// shape the baseline's `management.jobs` / `scheduleRecords` produce
// (`ChatPage.swift:3554`/`:3504`), and this host never fabricates them at runtime —
// `ChatSubpageFacts()` stays at its "not reported" default in `:app`.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.ChatCommandExecution
import com.phonedsh.ui.page.ChatJobRow
import com.phonedsh.ui.page.ChatScheduleRow
import com.phonedsh.ui.page.ChatSubpageFacts
import com.phonedsh.ui.page.UiPageTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class L24ChatSubpagesScreenshotTest : ScreenshotTestBase() {

    /** Gate frame, Android-only baseline directory: the subpages have no iOS state. */
    override val allowedProfiles: Set<ScreenshotProfile> =
        setOf(ScreenshotProfile.GATE, ScreenshotProfile.ANDROID_ONLY)

    /** Mounts one chat subpage route on the real router. */
    private fun mountRoute(
        route: PdshRoute,
        subpages: ChatSubpageFacts = ChatSubpageFacts(),
        onHostAction: (PdshHostAction) -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, route)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = onBack,
                onHome = {},
                onHostAction = onHostAction,
                home = { BasicText(text = "home") },
                webSurface = {},
                chatSubpages = subpages,
            )
        }
    }

    // -------------------------------------------------------------- 后台任务

    @Test
    fun jobsSheetUnread() {
        mountRoute(PdshRoute.SessionJobs)
        compose.onNodeWithText(UiStrings.CHAT_JOBS_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_UNREAD).assertExists()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_REFRESH).assertIsDisplayed()
        capture("l24-chat-jobs-unread")
    }

    @Test
    fun jobsSheetWithRows() {
        mountRoute(
            PdshRoute.SessionJobs,
            subpages = ChatSubpageFacts(
                jobs = listOf(
                    ChatJobRow(id = "j1", title = "npm test", detail = "running 00:31", status = "running"),
                    ChatJobRow(id = "j2", title = "gradle test", detail = "queued", status = "queued"),
                    ChatJobRow(id = "j3", title = "xcodebuild", detail = "finished 00:02", status = "done"),
                ),
            ),
        )
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_LIST).assertExists()
        compose.onNodeWithText("npm test").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_UNREAD).assertDoesNotExist()
        capture("l24-chat-jobs-rows")
    }

    @Test
    fun refreshReachesTheHostAndClosePops() {
        val actions = mutableListOf<PdshHostAction>()
        var backs = 0
        mountRoute(PdshRoute.SessionJobs, onHostAction = { actions += it }, onBack = { backs++ })
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_REFRESH).performClick()
        compose.runOnIdle {
            assertEquals(listOf<PdshHostAction>(PdshHostAction.RefreshSessionActivity), actions)
        }
        compose.onNodeWithText(UiStrings.DISMISS).performClick()
        compose.runOnIdle { assertEquals(1, backs) }
    }

    // -------------------------------------------------------------- 定时任务

    @Test
    fun schedulesSheetUnread() {
        mountRoute(PdshRoute.SessionSchedules)
        compose.onNodeWithText(UiStrings.CHAT_SCHEDULES_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_UNREAD).assertExists()
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_REFRESH).assertIsDisplayed()
        capture("l24-chat-schedules-unread")
    }

    @Test
    fun schedulesSheetWithRows() {
        mountRoute(
            PdshRoute.SessionSchedules,
            subpages = ChatSubpageFacts(
                schedules = listOf(
                    ChatScheduleRow(
                        id = "s1",
                        title = "每日摘要",
                        detail = "cron · 09:00",
                        status = "已排期",
                        prompt = "总结今天的会话，列出还没做完的三件事",
                    ),
                    ChatScheduleRow(
                        id = "s2",
                        title = "周报",
                        detail = "cron · 周五 18:00",
                        status = "已暂停",
                        prompt = "把这一周的会话整理成周报",
                    ),
                ),
            ),
        )
        compose.onNodeWithText("每日摘要").assertIsDisplayed()
        compose.onNodeWithText("已排期").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_UNREAD).assertDoesNotExist()
        capture("l24-chat-schedules-rows")
    }

    // -------------------------------------------------------------- 命令结果

    @Test
    fun commandResultUnread() {
        mountRoute(PdshRoute.CommandResult)
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_COMMAND_RESULT_UNREAD).assertExists()
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_DONE).assertIsDisplayed()
        capture("l24-chat-command-result-unread")
    }

    @Test
    fun commandResultSuccess() {
        mountRoute(
            PdshRoute.CommandResult,
            subpages = ChatSubpageFacts(
                commandExecution = ChatCommandExecution(
                    id = "c1",
                    name = "compact",
                    line = "/compact keep 20",
                    kind = "success",
                    text = "上下文已压缩：旧的 18 轮整理成摘要，保留最近 20 轮。",
                ),
            ),
        )
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_SUCCESS).assertIsDisplayed()
        compose.onNodeWithText("/compact keep 20").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_COMMAND_RESULT_LINE).assertExists()
        capture("l24-chat-command-result-success")
    }

    @Test
    fun commandResultFailureWithoutOutput() {
        mountRoute(
            PdshRoute.CommandResult,
            subpages = ChatSubpageFacts(
                commandExecution = ChatCommandExecution(
                    id = "c2",
                    name = "compact",
                    line = "/compact",
                    kind = "error",
                    text = "",
                ),
            ),
        )
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_FAILED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_EMPTY).assertIsDisplayed()
        capture("l24-chat-command-result-failure")
    }

    @Test
    fun donePopsTheResultPage() {
        var backs = 0
        mountRoute(PdshRoute.CommandResult, onBack = { backs++ })
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_DONE).performClick()
        compose.runOnIdle { assertEquals(1, backs) }
    }

    // ------------------------------------------------------------- 页头入口

    @Test
    fun chatMenuOpensBothSheetsWhenTheHostReportedRows() {
        var pushed by mutableStateOf<PdshRoute?>(null)
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.Chat)),
                facts = PdshNavFacts(),
                onNavigate = { pushed = it },
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = { BasicText(text = "home") },
                webSurface = {},
                chatSubpages = ChatSubpageFacts(
                    jobs = listOf(ChatJobRow(id = "j1", title = "npm test", detail = "running")),
                    schedules = listOf(ChatScheduleRow(id = "s1", title = "每日摘要", detail = "cron")),
                ),
            )
        }
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        // This harness freezes the animation clock, and a DropdownMenu composes its
        // rows through an animated popup: advance the virtual clock so the menu
        // exists before it is queried.
        compose.mainClock.advanceTimeBy(500)
        compose.waitForIdle()
        // Both rows are present with their counts, then one of them opens its route.
        // `assertExists`, not `assertIsDisplayed`: the menu lives in its own Popup
        // window, which the displayed-check does not measure against this root.
        compose.onNodeWithText("${UiStrings.CHAT_JOBS_TITLE}（1）").assertExists()
        compose.onNodeWithText("${UiStrings.CHAT_SCHEDULES_TITLE}（1）").performClick()
        compose.runOnIdle { assertEquals(PdshRoute.SessionSchedules, pushed) }
    }

    @Test
    fun chatMenuOffersNoSheetWithoutAHostRead() {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.Chat)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = { BasicText(text = "home") },
                webSurface = {},
            )
        }
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        assertTrue(
            "no host read must not render a 后台任务 row",
            compose.onAllNodesWithText(UiStrings.CHAT_JOBS_TITLE, substring = true)
                .fetchSemanticsNodes().isEmpty(),
        )
        assertTrue(
            "no host read must not render a 定时任务 row",
            compose.onAllNodesWithText(UiStrings.CHAT_SCHEDULES_TITLE, substring = true)
                .fetchSemanticsNodes().isEmpty(),
        )
    }
}
