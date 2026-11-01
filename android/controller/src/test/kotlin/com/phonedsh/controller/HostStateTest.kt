// phone-dsh Android — :controller nine-state closed-set tests (budgets.md §1).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HostStateTest {

    @Test
    fun `the D14 state set is closed with exactly nine states`() {
        assertEquals(HostState.COUNT, 9)
        assertEquals(9, HostState.entries.size)
        assertEquals(9, HostState.entries.map { it.wireName }.toSet().size)
    }

    @Test
    fun `wire names are the fixture vocabulary`() {
        assertEquals(
            listOf(
                "Running",
                "Draining",
                "Parked",
                "Recovering",
                "Backoff",
                "HandingOff",
                "Remote",
                "Reclaiming",
                "Failed",
            ),
            HostState.entries.map { it.wireName },
        )
        HostState.entries.forEach { state ->
            assertEquals(state, HostState.fromWireName(state.wireName))
            assertEquals(state, HostState.requireWireName(state.wireName))
        }
        assertNull(HostState.fromWireName("Stopped"))
        assertNull(HostState.fromWireName("running"))
    }

    @Test
    fun `admission is open only in Running`() {
        assertEquals(
            listOf(HostState.RUNNING),
            HostState.entries.filter { it.admission == Admission.OPEN },
        )
        assertEquals(
            HostState.entries.size - 1,
            HostState.entries.count { it.admission == Admission.CLOSED },
        )
    }
}
