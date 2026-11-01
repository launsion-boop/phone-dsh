// phone-dsh Android — :controller cross-checks against spec/v1/budgets.md.
// SPDX-License-Identifier: MIT
//
// `BudgetTierTest` used to carry a second copy of the §4 table as Kotlin
// constants, so changing the code and the test together never failed. These
// tests read the normative markdown in place and compare it with
// `ControllerBudgets`; the values are never copied into the repository again.

package com.phonedsh.controller

import com.phonedsh.controller.ControllerBudgets.Companion.GIB
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BudgetsSpecTest {

    private val budgetsMd = RepoRoot.file(BUDGETS_MD)
    private val markdown: String = budgetsMd.readText(Charsets.UTF_8)

    @Test
    fun `the section 4 table agrees with ControllerBudgets tier for tier`() {
        val table = BudgetsTable.parse(markdown, budgetsMd)
        val mismatches = table.mismatches()
        assertTrue(
            "spec/v1/budgets.md §4 and ControllerBudgets disagree:\n" +
                mismatches.joinToString("\n"),
            mismatches.isEmpty(),
        )
        assertEquals("the table has five tier columns", 5, table.tiers.size)
        assertEquals("the table has twelve resource rows", 12, table.resources.size)
    }

    @Test
    fun `the drain and restart deadlines in the prose are the constants`() {
        val deadline = secondsIn(
            "## 1. States",
            "(\\d+)\\s*s\\s+deadline",
            "the Draining 20 s deadline",
        )
        val timer = secondsIn(
            "## 2. Transition table (D14)",
            "(\\d+)\\s*s\\s+timer",
            "the Running -> Draining 20 s timer",
        )
        val boundary = secondsIn(
            "## 4. Budgets",
            "within\\s+(\\d+)\\s*s",
            "the 60 s restart boundary",
        )
        assertEquals("Draining deadline", ControllerBudgets.DRAIN_DEADLINE_MILLIS, deadline * 1_000L)
        assertEquals("drain timer", ControllerBudgets.DRAIN_DEADLINE_MILLIS, timer * 1_000L)
        assertEquals(
            "restart boundary deadline",
            ControllerBudgets.RESTART_BOUNDARY_DEADLINE_MILLIS,
            boundary * 1_000L,
        )
    }

    @Test
    fun `the default tier is the row the spec names`() {
        val defaultGiB = secondsIn(
            "## 4. Budgets",
            "The\\s+(\\d+)\\s+GB\\s+row\\s+is\\s+the\\s+default",
            "the default row",
        )
        assertEquals(
            "the default tier must be the 8 GiB row",
            MemoryTier.forTotalMemory(defaultGiB * GIB),
            ControllerBudgets.DEFAULT_TIER,
        )
    }

    @Test
    fun `section 4 has no durable epoch bytes or drain column today`() {
        val table = BudgetsTable.parse(markdown, budgetsMd)
        assertFalse(
            "§4 gained a durable-epoch column; extend BudgetsTable and the cross-check",
            table.tiers.any { it.contains("durable", ignoreCase = true) },
        )
        assertFalse(
            "§4 gained a drain column; extend BudgetsTable and the cross-check",
            table.tiers.any { it.contains("drain", ignoreCase = true) },
        )
        assertFalse(
            "§4 gained a durable-epoch row; extend BudgetsTable and the cross-check",
            table.resources.any { it.contains("durable", ignoreCase = true) },
        )
        assertFalse(
            "§4 gained a drain row; extend BudgetsTable and the cross-check",
            table.resources.any { it.contains("drain", ignoreCase = true) },
        )
    }

    @Test
    fun `a changed cell is caught by the cross-check`() {
        val table = BudgetsTable.parse(markdown, budgetsMd)
        assertTrue("the unmodified table must agree", table.mismatches().isEmpty())

        val heapMutated = table.replaceCell(
            markdown,
            resource = "Engine heap",
            tierIndex = 0,
            newCell = "≤ 833 MB",
        )
        assertNotEquals("the in-memory mutation must change the table", markdown, heapMutated)
        val heapMismatches = BudgetsTable.parse(heapMutated, budgetsMd).mismatches()
        assertEquals("one mutated cell, one mismatch: $heapMismatches", 1, heapMismatches.size)
        assertTrue(
            "the mismatch must name the row and tier: ${heapMismatches.single()}",
            heapMismatches.single().contains("Engine heap") &&
                heapMismatches.single().contains("12 GiB"),
        )

        val splitMutated = table.replaceCell(
            markdown,
            resource = "VFS split: workspace / sessions / tmp",
            tierIndex = 2,
            newCell = "121 / 40 / 40 MB",
        )
        val splitMismatches = BudgetsTable.parse(splitMutated, budgetsMd).mismatches()
        assertEquals("one mutated split cell, one mismatch: $splitMismatches", 1, splitMismatches.size)
        assertTrue(
            "the mismatch must name the split: ${splitMismatches.single()}",
            splitMismatches.single().contains("workspace") &&
                splitMismatches.single().contains("6 GiB"),
        )
    }

    @Test
    fun `a changed header or row set fails the parser instead of being skipped`() {
        val changedHeader = markdown.replaceFirst("| Resource | 12 GiB |", "| Resource | 13 GiB |")
        assertNotEquals("the mutation must change the header", markdown, changedHeader)
        assertThrows(AssertionError::class.java) {
            BudgetsTable.parse(changedHeader, budgetsMd)
        }

        val renamedRow = markdown.replaceFirst("| App process |", "| App process bytes |")
        assertNotEquals("the mutation must change a row", markdown, renamedRow)
        assertThrows(AssertionError::class.java) {
            BudgetsTable.parse(renamedRow, budgetsMd)
        }
    }

    private fun secondsIn(heading: String, pattern: String, what: String): Long {
        val match = Regex(pattern).find(section(heading))
            ?: throw AssertionError(
                "budgets.md no longer states $what (pattern /$pattern/); the cross-check cannot run",
            )
        return match.groupValues[1].toLong()
    }

    private fun section(heading: String): String {
        val lines = markdown.lines()
        val start = lines.indexOfFirst { it.trim() == heading }
        if (start < 0) {
            throw AssertionError("budgets.md has no '$heading' heading; the cross-check cannot run")
        }
        val end = lines.withIndex()
            .drop(start + 1)
            .firstOrNull { it.value.startsWith("## ") }
            ?.index
            ?: lines.size
        return lines.subList(start, end).joinToString("\n")
    }

    private companion object {
        const val BUDGETS_MD: String = "spec/v1/budgets.md"
    }
}
