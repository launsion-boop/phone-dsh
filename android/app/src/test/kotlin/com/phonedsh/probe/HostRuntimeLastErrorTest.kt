// The runtime page's 最近出錯 reads D14 Failed, not only the chat turn state.
// SPDX-License-Identifier: MIT
//
// Device evidence 22:03:13: the host was Failed with
// UNREPAIRED_BASE_MISMATCH, the turn state was Idle after the cold start, and
// the runtime page said 读取不到最近一次出错 even though the reason was in
// logcat. These tests pin the projection, including the persisted-code-only
// case a cold boot restores from host-state.json.

package com.phonedsh.probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostRuntimeLastErrorTest {
    @Test
    fun aHostFailureWinsOverAnIdleTurn() {
        val failure = HostFailureReading(
            code = "UNREPAIRED_BASE_MISMATCH",
            detail = "WAL epoch close failed (WAL_RESYNC_UNREPAIRED): the base mismatch " +
                "at /dsh/workspace/held.txt (mseq 7) is unrepaired",
        )
        val lastError = runtimeLastError(AppTurnState.Idle, failure)
        assertNotNull("a Failed host is a recorded error", lastError)
        assertTrue(
            "the real path reaches the page: ${lastError?.message}",
            lastError?.message?.contains("/dsh/workspace/held.txt") == true,
        )
        assertTrue(lastError?.message?.contains("mseq 7") == true)
    }

    @Test
    fun aColdBootCodeWithoutDetailStillCarriesAReason() {
        val lastError = runtimeLastError(
            AppTurnState.Idle,
            HostFailureReading(code = "UNREPAIRED_BASE_MISMATCH"),
        )
        assertEquals("UNREPAIRED_BASE_MISMATCH", lastError?.message)
    }

    @Test
    fun withoutAHostFailureTheTurnStateStillAnswers() {
        assertNull(runtimeLastError(AppTurnState.Idle, null))
        assertNull(runtimeLastError(AppTurnState.Running, null))
        val completed = AppTurnState.Completed(sessionId = "ses-1", kinds = listOf("assistant"))
        assertEquals(null, runtimeLastError(completed, null)?.message)
        assertEquals(
            "turn timeout",
            runtimeLastError(AppTurnState.Failed("turn timeout"), null)?.message,
        )
    }
}
