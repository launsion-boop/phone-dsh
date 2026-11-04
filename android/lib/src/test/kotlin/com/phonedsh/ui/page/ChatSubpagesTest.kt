// The chat family's three embedded subpages: their facts and their honest bodies.
// SPDX-License-Identifier: MIT
//
// README §1 line 86 makes CommandExecutionResultPage / SessionJobs / SessionSchedules
// part of ChatPage, so this JVM test asserts the half of each surface that is a pure
// function of the host's read — the same split the rest of the page layer uses
// (§3.1 rule 3): the composable is asserted on a device, the state here.
//
// The rule under test is "not reported" vs "reported, and it is empty":
//   * `null`  → UNREAD  → the sheet says 读取不到…
//   * `[]`    → EMPTY   → the baseline's 没有… / 这个会话暂时没有…。
// A host that made no read must never be shown as an empty session, and the two
// branches must never collapse into one.
package com.phonedsh.ui.page

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatSubpagesTest {

    private val job = ChatJobRow(id = "job-1", title = "npm test", detail = "running 00:31")
    private val schedule = ChatScheduleRow(
        id = "sched-1",
        title = "每日摘要",
        detail = "cron · 09:00",
        status = "已排期",
        prompt = "总结今天的会话",
    )
    private val execution = ChatCommandExecution(
        id = "cmd-1",
        name = "compact",
        line = "/compact keep 20",
        kind = "success",
        text = "上下文已压缩（保留 20 轮）",
    )

    @Test
    fun `a host that read nothing reports no list, not an empty one`() {
        val facts = ChatSubpageFacts()
        assertNull("no execution ran on this host", facts.commandExecution)
        assertNull("the host made no read", facts.jobs)
        assertNull("the host made no read", facts.schedules)

        assertEquals(ChatSubpageBody.UNREAD, ChatJobsSheetState.from(facts.jobs).body)
        assertEquals(ChatSubpageBody.UNREAD, ChatSchedulesSheetState.from(facts.schedules).body)
        assertTrue(ChatJobsSheetState.from(facts.jobs).rows.isEmpty())
        assertTrue(ChatSchedulesSheetState.from(facts.schedules).rows.isEmpty())
    }

    @Test
    fun `a read that found nothing is the baseline's empty state`() {
        val jobs = ChatJobsSheetState.from(emptyList())
        assertEquals(ChatSubpageBody.EMPTY, jobs.body)
        assertTrue(jobs.rows.isEmpty())

        val schedules = ChatSchedulesSheetState.from(emptyList())
        assertEquals(ChatSubpageBody.EMPTY, schedules.body)
        assertTrue(schedules.rows.isEmpty())
    }

    @Test
    fun `a reported list keeps every row in the host's order`() {
        val second = ChatJobRow(id = "job-2", title = "gradle test", detail = "queued")
        val jobs = ChatJobsSheetState.from(listOf(job, second))
        assertEquals(ChatSubpageBody.ROWS, jobs.body)
        assertEquals(listOf("job-1", "job-2"), jobs.rows.map { it.id })

        val schedules = ChatSchedulesSheetState.from(listOf(schedule))
        assertEquals(ChatSubpageBody.ROWS, schedules.body)
        assertEquals(listOf("sched-1"), schedules.rows.map { it.id })
        assertEquals("已排期", schedules.rows.single().status)
        assertEquals("总结今天的会话", schedules.rows.single().prompt)
    }

    @Test
    fun `a row without a status keeps the field absent instead of inventing one`() {
        // The baseline draws the status only `if let status`; the row model must be
        // able to say "the host did not report one" (null), not "".
        assertNull(job.status)
        assertNull(ChatScheduleRow(id = "s", title = "t", detail = "d").status)
        assertNull(ChatScheduleRow(id = "s", title = "t", detail = "d").prompt)
    }

    @Test
    fun `a settlement reports its kind and its body`() {
        val state = ChatCommandResultState(execution)
        assertTrue(state.succeeded)
        assertEquals("上下文已压缩（保留 20 轮）", state.output)
    }

    @Test
    fun `a failed settlement is not a success`() {
        val failed = ChatCommandExecution(
            id = "cmd-2",
            name = "compact",
            line = "/compact",
            kind = "error",
            text = "The DSH command Remote returned no execution result.",
        )
        val state = ChatCommandResultState(failed)
        assertFalse(state.succeeded)
        assertEquals("The DSH command Remote returned no execution result.", state.output)
    }

    @Test
    fun `no output is a branch, not an empty string`() {
        // iOS: `if let text, !text.isEmpty { … } else { 这次没有更多输出。 }`.
        assertNull(ChatCommandResultState(execution.copy(text = null)).output)
        assertNull(ChatCommandResultState(execution.copy(text = "")).output)
        // A settlement without text is still a success: the status line is the
        // kind's, and only the body falls back to the empty-output sentence.
        assertTrue(ChatCommandResultState(execution.copy(text = null)).succeeded)
    }

    @Test
    fun `no execution means the result page has nothing to claim`() {
        val state = ChatCommandResultState()
        assertNull(state.execution)
        assertNull(state.output)
        // `succeeded` is false because nothing succeeded — the page renders the
        // unread line, never the failure label.
        assertFalse(state.succeeded)
    }
}
