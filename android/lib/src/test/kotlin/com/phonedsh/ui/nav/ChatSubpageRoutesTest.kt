// The chat family's three embedded subpages, mounted through the real router.
// SPDX-License-Identifier: MIT
//
// README §1 line 86: CommandExecutionResultPage, NativeJobListSheet and
// NativeScheduleListSheet are 内嵌子页 of ChatPage, so their entry points, their
// verbs and their handoffs are part of that page's contract (three of them are in
// `spec/ui/v1/pages/chat.json`).
//
// What this suite proves, on the JVM, without a device:
//   * `刷新` is not a dead button: a tap reaches `PdshNavHost`'s host-action seam as
//     `PdshHostAction.RefreshSessionActivity` — the one read the baseline's two
//     sheets share (`ChatPage.swift:441`/`:449` both call `refreshActivity`);
//   * `完成` / `关闭` really close: each calls the router's `onBack`, i.e. pops the
//     sheet's route, which is what the baseline's `dismiss()` does;
//   * a host that reported nothing renders 读取不到…, and a host that reported rows
//     renders them (the page never claims an empty session it did not read);
//   * the page-head menu's 后台任务（N）/定时任务（N） rows open those routes, and
//     they are absent when the host reported nothing.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ChatCommandExecution
import com.phonedsh.ui.page.ChatJobRow
import com.phonedsh.ui.page.ChatScheduleRow
import com.phonedsh.ui.page.ChatSubpageFacts
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ChatSubpageRoutesTest {

    /**
     * Clicks one of the sheet's text verbs through its `OnClick` semantics action.
     *
     * Why not `performClick()` here: these sheets render inside `PdshNavHost`'s
     * `RouteSurface`, which clips the modal's top edge with
     * `Modifier.clip(RoundedCornerShape(...))`. Under Robolectric a gesture injected
     * into a clipped container never reaches the child (measured: the same
     * `SessionTextAction` fires from a plain `Box` and stays silent inside the
     * clip), while the semantics action — the same `onClick` a tap invokes — does.
     * The *real tap* is asserted on a device instead
     * (`L24ChatSubpagesScreenshotTest.refreshReachesTheHostAndClosePops`), so this
     * class proves the wiring and the device suite proves the touch path.
     */
    private fun clickVerb(label: String) {
        compose.onNodeWithText(label).performSemanticsAction(SemanticsActions.OnClick)
    }

    @get:Rule
    val compose = createComposeRule()

    /** Mounts the real router on one route; every callback is recorded. */
    private fun mount(
        route: PdshRoute,
        subpages: ChatSubpageFacts = ChatSubpageFacts(),
        onNavigate: (PdshRoute) -> Unit = {},
        onHostAction: (PdshHostAction) -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = onNavigate,
                    onBack = onBack,
                    onHome = {},
                    onHostAction = onHostAction,
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    chatSubpages = subpages,
                )
            }
        }
        compose.waitForIdle()
    }

    // ------------------------------------------------------------------ jobs

    @Test
    fun `the jobs sheet reports a host that read nothing`() {
        mount(PdshRoute.SessionJobs)
        compose.onNodeWithText(UiStrings.CHAT_JOBS_TITLE).assertIsDisplayed()
        // The unread branch is the one that rendered, and the baseline's empty
        // sentence (which claims a read) did not.
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_UNREAD).assertExists()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CHAT_SUBPAGE_REFRESH).assertIsDisplayed()
    }

    @Test
    fun `refresh on the jobs sheet reaches the host as one activity read`() {
        val actions = mutableListOf<PdshHostAction>()
        mount(PdshRoute.SessionJobs, onHostAction = { actions += it })
        clickVerb(UiStrings.CHAT_SUBPAGE_REFRESH)
        compose.runOnIdle {
            assertEquals(listOf<PdshHostAction>(PdshHostAction.RefreshSessionActivity), actions)
        }
    }

    @Test
    fun `close on the jobs sheet pops the route`() {
        var backs = 0
        mount(PdshRoute.SessionJobs, onBack = { backs++ })
        clickVerb(UiStrings.DISMISS)
        compose.runOnIdle { assertEquals(1, backs) }
    }

    @Test
    fun `a reported jobs list renders its rows and no unread line`() {
        mount(
            PdshRoute.SessionJobs,
            subpages = ChatSubpageFacts(
                jobs = listOf(
                    ChatJobRow(id = "j1", title = "npm test", detail = "running 00:31", status = "running"),
                    ChatJobRow(id = "j2", title = "gradle test", detail = "queued", status = "queued"),
                ),
            ),
        )
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_LIST).assertExists()
        compose.onNodeWithText("npm test").assertIsDisplayed()
        compose.onNodeWithText("gradle test").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_UNREAD).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_JOBS_SHEET_EMPTY).assertDoesNotExist()
    }

    // ------------------------------------------------------------- schedules

    @Test
    fun `refresh on the schedules sheet reaches the same host read`() {
        val actions = mutableListOf<PdshHostAction>()
        mount(PdshRoute.SessionSchedules, onHostAction = { actions += it })
        clickVerb(UiStrings.CHAT_SUBPAGE_REFRESH)
        compose.runOnIdle {
            assertEquals(listOf<PdshHostAction>(PdshHostAction.RefreshSessionActivity), actions)
        }
    }

    @Test
    fun `a reported schedule renders title, status, detail and prompt`() {
        mount(
            PdshRoute.SessionSchedules,
            subpages = ChatSubpageFacts(
                schedules = listOf(
                    ChatScheduleRow(
                        id = "s1",
                        title = "每日摘要",
                        detail = "cron · 09:00",
                        status = "已排期",
                        prompt = "总结今天的会话",
                    ),
                ),
            ),
        )
        compose.onNodeWithText("每日摘要").assertIsDisplayed()
        compose.onNodeWithText("已排期").assertIsDisplayed()
        compose.onNodeWithText("cron · 09:00").assertIsDisplayed()
        compose.onNodeWithText("总结今天的会话").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_UNREAD).assertDoesNotExist()
    }

    @Test
    fun `the schedules sheet's empty read is the baseline's empty state`() {
        mount(PdshRoute.SessionSchedules, subpages = ChatSubpageFacts(schedules = emptyList()))
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_EMPTY).assertExists()
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_UNREAD).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_SCHEDULES_SHEET_LIST).assertDoesNotExist()
    }

    // -------------------------------------------------------- command result

    @Test
    fun `done on the command result page pops it`() {
        var backs = 0
        mount(PdshRoute.CommandResult, onBack = { backs++ })
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_COMMAND_RESULT_UNREAD).assertExists()
        clickVerb(UiStrings.CHAT_SUBPAGE_DONE)
        compose.runOnIdle { assertEquals(1, backs) }
    }

    @Test
    fun `a settlement shows its status, its line and its output`() {
        mount(
            PdshRoute.CommandResult,
            subpages = ChatSubpageFacts(
                commandExecution = ChatCommandExecution(
                    id = "c1",
                    name = "compact",
                    line = "/compact keep 20",
                    kind = "success",
                    text = "上下文已压缩（保留 20 轮）",
                ),
            ),
        )
        compose.onNodeWithTag(UiPageTags.CHAT_COMMAND_RESULT_STATUS).assertExists()
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_SUCCESS).assertIsDisplayed()
        compose.onNodeWithText("/compact keep 20").assertIsDisplayed()
        compose.onNodeWithText("上下文已压缩（保留 20 轮）").assertIsDisplayed()
    }

    @Test
    fun `a failed settlement says so and a bodyless one falls back to the empty sentence`() {
        mount(
            PdshRoute.CommandResult,
            subpages = ChatSubpageFacts(
                commandExecution = ChatCommandExecution(
                    id = "c2",
                    name = "compact",
                    line = "/compact",
                    kind = "error",
                    text = null,
                ),
            ),
        )
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_FAILED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CHAT_COMMAND_RESULT_EMPTY).assertIsDisplayed()
    }

    // ------------------------------------------------------------ the entrance

    @Test
    fun `the chat menu opens both sheets only while the host reported rows`() {
        val pushed = mutableListOf<PdshRoute>()
        mount(
            PdshRoute.Chat,
            subpages = ChatSubpageFacts(
                jobs = listOf(ChatJobRow(id = "j1", title = "npm test", detail = "running")),
                schedules = listOf(ChatScheduleRow(id = "s1", title = "每日摘要", detail = "cron")),
            ),
            onNavigate = { pushed += it },
        )
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        // iOS `ChatPage.swift:247`/`:252`: the label carries the count.
        compose.onNodeWithText("${UiStrings.CHAT_JOBS_TITLE}（1）").performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText("${UiStrings.CHAT_SCHEDULES_TITLE}（1）").performClick()
        compose.runOnIdle {
            assertEquals(listOf(PdshRoute.SessionJobs, PdshRoute.SessionSchedules), pushed)
        }
    }

    @Test
    fun `with no host read the chat menu offers neither sheet`() {
        mount(PdshRoute.Chat)
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.CHAT_JOBS_TITLE, substring = true).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CHAT_SCHEDULES_TITLE, substring = true).assertDoesNotExist()
    }
}
