// The restored-turn wording: what the card may claim about a turn the previous
// process completed.
// SPDX-License-Identifier: MIT
//
// L65 restored the archived turn at launch, but the card could only say 完成 —
// true ("the Worker completed it"), and yet a reader could not tell this
// process's completion from the last one's. The baseline says it with a status
// line (`ChatModel.swift:2576`: `显示上次对话，引擎在后台启动…`); this suite pins
// the Android half: the flag, the label, the sentence, and the archived-turn
// mapping that sets the flag.
package com.phonedsh.probe

import com.phonedsh.domain.session.ArchivedCommand
import com.phonedsh.domain.session.ArchivedTurn
import com.phonedsh.domain.session.ArchivedWrite
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppTurnStateTest {

    @Test
    fun aTurnThisProcessRanIsLabelledPlainly() {
        val completed = AppTurnState.Completed(sessionId = "ses-1", kinds = listOf("assistant"))

        assertFalse(completed.restored)
        assertEquals("完成", completed.label())
    }

    @Test
    fun aRestoredTurnSaysItWasThePreviousProcess() {
        val restored = AppTurnState.Completed(sessionId = "ses-1", kinds = listOf("assistant"), restored = true)

        assertEquals(AppTurnState.RESTORED_LABEL, restored.label())
        assertTrue(restored.label().contains("上次进程"))
    }

    @Test
    fun theRestoredSentenceKeepsTheBaselinesOpening() {
        // The baseline's line is `显示上次对话，引擎在后台启动…`
        // (`ChatModel.swift:2576`). Android keeps the opening claim and states the
        // provenance; see the constant's own doc for why the transient
        // 「引擎在后台启动…」 clause is not copied.
        assertTrue(AppTurnState.RESTORED_LINE.startsWith("显示上次对话"))
        assertTrue(AppTurnState.RESTORED_LINE.contains("上次进程的回合"))
    }

    @Test
    fun anArchivedTurnBecomesARestoredCompletionWithItsToolRows() {
        val archived = ArchivedTurn(
            sessionId = "ses-archive",
            completedAtMs = 1_760_000_000_000,
            kinds = listOf("assistant_message", "tool_call"),
            commands = listOf(ArchivedCommand("call-1", "ls -la")),
            writes = listOf(ArchivedWrite("/workspace/a.txt", "write")),
        )

        val completed = archived.toRestoredCompleted()

        assertTrue(completed.restored)
        assertEquals("ses-archive", completed.sessionId)
        assertEquals(listOf("assistant_message", "tool_call"), completed.kinds)
        assertEquals(listOf(TurnToolCommand("call-1", "ls -la")), completed.commands)
        assertEquals(listOf(TurnWrite("/workspace/a.txt", "write")), completed.writes)
        assertEquals(AppTurnState.RESTORED_LABEL, completed.label())
    }

    @Test
    fun theOtherStatesAreUnchanged() {
        assertEquals("未开始", AppTurnState.Idle.label())
        assertEquals("进行中", AppTurnState.Running.label())
        assertEquals("失败", AppTurnState.Failed("timeout").label())
    }
}
