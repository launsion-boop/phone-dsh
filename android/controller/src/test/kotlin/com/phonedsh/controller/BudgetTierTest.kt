// phone-dsh Android — :controller budget behaviour tests (budgets.md §4).
// SPDX-License-Identifier: MIT
//
// The §4 table itself is compared with `ControllerBudgets` in
// `BudgetsSpecTest`, which reads the normative markdown. This file keeps the
// boundary behaviour the table cannot express: tier thresholds, clamping and
// the derived recovery target.

package com.phonedsh.controller

import com.phonedsh.controller.ControllerBudgets.Companion.GIB
import com.phonedsh.controller.ControllerBudgets.Companion.MIB
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BudgetTierTest {

    @Test
    fun `tier selection uses exact thresholds`() {
        assertEquals(MemoryTier.GIB_12, MemoryTier.forTotalMemory(12 * GIB))
        assertEquals(MemoryTier.GIB_8, MemoryTier.forTotalMemory(12 * GIB - 1))
        assertEquals(MemoryTier.GIB_8, MemoryTier.forTotalMemory(8 * GIB))
        assertEquals(MemoryTier.GIB_6, MemoryTier.forTotalMemory(8 * GIB - 1))
        assertEquals(MemoryTier.GIB_6, MemoryTier.forTotalMemory(6 * GIB))
        assertEquals(MemoryTier.GIB_4, MemoryTier.forTotalMemory(6 * GIB - 1))
        assertEquals(MemoryTier.GIB_4, MemoryTier.forTotalMemory(4 * GIB))
        assertEquals(MemoryTier.AT_MOST_3, MemoryTier.forTotalMemory(4 * GIB - 1))
        assertEquals(MemoryTier.AT_MOST_3, MemoryTier.forTotalMemory(3 * GIB))
        assertEquals(MemoryTier.GIB_12, MemoryTier.forTotalMemory(16 * GIB))
        assertEquals(MemoryTier.AT_MOST_3, MemoryTier.forTotalMemory(0))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a negative memory ceiling is rejected`() {
        MemoryTier.forTotalMemory(-1)
    }

    @Test
    fun `recovery target is a plus k per MiB rounded up`() {
        val budgets = ControllerBudgets.forTier(MemoryTier.GIB_8)
        assertEquals(3_000L, budgets.recoveryTargetMillis(0))
        assertEquals(3_050L, budgets.recoveryTargetMillis(1))
        assertEquals(3_050L, budgets.recoveryTargetMillis(MIB))
        assertEquals(3_100L, budgets.recoveryTargetMillis(MIB + 1))
        // The three worked examples of budgets.md §4.
        assertEquals(9_400L, budgets.recoveryTargetMillis(128 * MIB))
        assertEquals(22_400L, budgets.recoveryTargetMillis(388 * MIB))
        assertEquals(41_400L, budgets.recoveryTargetMillis(768 * MIB))
    }

    @Test
    fun `single file limit is clamped and raises the buckets in step`() {
        val twelve = ControllerBudgets.forTier(MemoryTier.GIB_12)
        assertEquals(256 * MIB, twelve.singleFileLimitClamped(512 * MIB))
        assertEquals(twelve, twelve.withSingleFileLimit(512 * MIB))

        val eight = ControllerBudgets.forTier(MemoryTier.GIB_8)
        assertEquals(128 * MIB, eight.singleFileLimitClamped(256 * MIB))
        assertEquals(eight, eight.withSingleFileLimit(256 * MIB))
        val eightSmall = eight.withSingleFileLimit(64 * MIB)
        assertEquals(64 * MIB, eightSmall.singleFileBytes)
        assertEquals(eight.workspaceBytes, eightSmall.workspaceBytes)

        val six = ControllerBudgets.forTier(MemoryTier.GIB_6)
        assertEquals(128 * MIB, six.singleFileLimitClamped(128 * MIB))
        val sixLarge = six.withSingleFileLimit(128 * MIB)
        assertEquals(128 * MIB, sixLarge.singleFileBytes)
        // §4 re-derives the aggregates after a raise: 2 * 128 + 24 = 280 MB
        // workspace; 280 + 40 + 40 = 360 MB VFS; heap 360 MB.
        assertEquals(280 * MIB, sixLarge.workspaceBytes)
        assertEquals(360 * MIB, sixLarge.vfsLogicalBytes)
        assertEquals(360 * MIB, sixLarge.engineHeapBytes)

        val four = ControllerBudgets.forTier(MemoryTier.GIB_4)
        assertEquals(32 * MIB, four.singleFileLimitClamped(256 * MIB))
        assertEquals(four, four.withSingleFileLimit(256 * MIB))

        val three = ControllerBudgets.forTier(MemoryTier.AT_MOST_3)
        assertEquals(16 * MIB, three.singleFileLimitClamped(1 * MIB))
        assertEquals(three, three.withSingleFileLimit(1 * MIB))
    }

    @Test
    fun `sub-agent caps follow thermal and battery pressure`() {
        val eight = ControllerBudgets.forTier(MemoryTier.GIB_8)
        assertEquals(2, eight.maxSubAgentsFor(ThermalPressure.NOMINAL))
        assertEquals(1, eight.maxSubAgentsFor(ThermalPressure.FAIR))
        assertEquals(0, eight.maxSubAgentsFor(ThermalPressure.SERIOUS))
        assertEquals(0, eight.maxSubAgentsFor(ThermalPressure.CRITICAL))
        assertEquals(
            1,
            eight.maxSubAgentsFor(
                ThermalPressure.NOMINAL,
                BatterySnapshot(levelPercent = 15, charging = false, lowPowerMode = false),
            ),
        )
        assertEquals(
            1,
            eight.maxSubAgentsFor(
                ThermalPressure.NOMINAL,
                BatterySnapshot(levelPercent = null, charging = false, lowPowerMode = true),
            ),
        )
        assertEquals(
            2,
            eight.maxSubAgentsFor(
                ThermalPressure.NOMINAL,
                BatterySnapshot(levelPercent = 15, charging = true, lowPowerMode = false),
            ),
        )
        val four = ControllerBudgets.forTier(MemoryTier.GIB_4)
        assertEquals(1, four.maxSubAgentsFor(ThermalPressure.NOMINAL))
        val three = ControllerBudgets.forTier(MemoryTier.AT_MOST_3)
        assertEquals(1, three.maxSubAgentsFor(ThermalPressure.NOMINAL))
    }

    @Test
    fun `the cross-tier policy constants are the spec constants`() {
        assertEquals(20_000L, ControllerBudgets.DRAIN_DEADLINE_MILLIS)
        assertEquals(5, ControllerBudgets.LOOPBACK_P95_MILLIS)
        assertEquals(3_000L, ControllerBudgets.RECOVERY_BASE_MAX_MILLIS)
        assertEquals(50L, ControllerBudgets.RECOVERY_MILLIS_PER_MB)
        assertEquals(0.75, ControllerBudgets.ENGINE_HEAP_RESTART_FRACTION, 0.0)
        assertEquals(3, ControllerBudgets.ENGINE_HEAP_RESTART_SAMPLES)
        assertEquals(24L * 60 * 60 * 1_000, ControllerBudgets.CONTINUOUS_RUN_RESTART_MILLIS)
        assertEquals(60_000L, ControllerBudgets.RESTART_BOUNDARY_DEADLINE_MILLIS)
        assertEquals(16 * MIB, ControllerBudgets.MIN_SINGLE_FILE_BYTES)
    }

    @Test
    fun `every tier satisfies the cross-row invariants`() {
        MemoryTier.entries.forEach { tier ->
            val budgets = ControllerBudgets.forTier(tier)
            assertEquals(tier, budgets.tier)
            assertEquals(budgets.nominalCeilingBytes / 2, budgets.peakBytes)
            assertEquals(5, budgets.loopbackP95Millis)
            assertEquals(20_000L, budgets.drainDeadlineMillis)
            assertEquals(3_000L, budgets.recoveryBaseMaxMillis)
            assertEquals(50L, budgets.recoveryMillisPerMb)
            assertEquals(1, budgets.maxSubAgentsThermalFair)
            assertTrue(
                "$tier: VFS must cover workspace + sessions + tmp",
                budgets.vfsLogicalBytes >= budgets.workspaceBytes + budgets.sessionsBytes + budgets.tmpBytes,
            )
            assertTrue(
                "$tier: heap must cover the VFS cap",
                budgets.engineHeapBytes >= budgets.vfsLogicalBytes,
            )
            assertTrue(
                "$tier: workspace must hold two largest files plus headroom",
                budgets.workspaceBytes >= 2 * budgets.singleFileBytes + budgets.workspaceHeadroomBytes,
            )
            assertTrue(
                "$tier: single file limit inside the host range",
                budgets.singleFileBytes in ControllerBudgets.MIN_SINGLE_FILE_BYTES..budgets.singleFileHostMaxBytes,
            )
        }
    }
}
