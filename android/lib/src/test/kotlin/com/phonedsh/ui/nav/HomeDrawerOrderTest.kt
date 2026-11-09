// SPDX-License-Identifier: MIT
// The drawer holds its first-seen session order until it closes.
package com.phonedsh.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Test

class HomeDrawerOrderTest {
    @Test fun firstSeenOrderIsAdopted() {
        val (stable, held) = homeDrawerStableSessionOrder(
            held = emptyList(),
            current = listOf("a", "b", "c"),
        )
        assertEquals(listOf("a", "b", "c"), stable)
        assertEquals(listOf("a", "b", "c"), held)
    }

    @Test fun hostReorderDoesNotMoveRowsWhileOpen() {
        val (stable, held) = homeDrawerStableSessionOrder(
            held = listOf("a", "b", "c"),
            current = listOf("c", "a", "b"),
        )
        assertEquals("the held order wins until the drawer closes", listOf("a", "b", "c"), stable)
        assertEquals(listOf("a", "b", "c"), held)
    }

    @Test fun unseenSessionsAreAppendedInsteadOfInserted() {
        val (stable, held) = homeDrawerStableSessionOrder(
            held = listOf("a", "b"),
            current = listOf("new", "b", "a"),
        )
        assertEquals(listOf("a", "b", "new"), stable)
        assertEquals(listOf("a", "b", "new"), held)
    }

    @Test fun rowRankFallsBackToTheHostTailForUnknownIds() {
        val rows = listOf(
            HomeDrawerSession("new", "New"),
            HomeDrawerSession("b", "B"),
            HomeDrawerSession("a", "A"),
        )
        val rank = mapOf("a" to 0, "b" to 1)
        assertEquals(
            listOf("a", "b", "new"),
            homeDrawerSessionsInHeldOrder(rows, rank).map { it.id },
        )
    }
}
