// phone-dsh — :dsh unit test: the budgets.md §4 device tier of the host.
// SPDX-License-Identifier: MIT
//
// budgets.md:95-97 ("Device tiers are selected once per boot from the physical
// memory ceiling") and budgets.md:104 (the "Single file" row) are the contract
// these assertions pin. The table itself lives in `:controller`'s
// `ControllerBudgets`/`MemoryTier` (and `:controller`'s `BudgetTierTest` pins its
// thresholds); this file pins that the *host* selects through it and publishes
// the resulting `single_file_limit` where the Worker reads it.
//
// The last test is the anchor for the reverse verification: it fails for any
// implementation that answers a 2 GiB ceiling with a larger row (the pre-fix
// behaviour was "no selection at all", i.e. the Worker's 8 GiB default of
// 128 MiB).

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerBudgets.Companion.GIB
import com.phonedsh.controller.ControllerBudgets.Companion.MIB
import com.phonedsh.controller.MemoryTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostBudgetTierTest {

    /** budgets.md:95-97: 12 GiB only at ≥ 12 GiB, 8 GiB default, lower rows below. */
    @Test
    fun `tier thresholds are the budgets md 4 rows`() {
        assertEquals(MemoryTier.GIB_12, HostBudgetTier.forTotalMemory(12 * GIB).tier)
        assertEquals(MemoryTier.GIB_12, HostBudgetTier.forTotalMemory(16 * GIB).tier)
        assertEquals(MemoryTier.GIB_8, HostBudgetTier.forTotalMemory(12 * GIB - 1).tier)
        assertEquals(MemoryTier.GIB_8, HostBudgetTier.forTotalMemory(8 * GIB).tier)
        assertEquals(MemoryTier.GIB_6, HostBudgetTier.forTotalMemory(8 * GIB - 1).tier)
        assertEquals(MemoryTier.GIB_6, HostBudgetTier.forTotalMemory(6 * GIB).tier)
        assertEquals(MemoryTier.GIB_4, HostBudgetTier.forTotalMemory(6 * GIB - 1).tier)
        assertEquals(MemoryTier.GIB_4, HostBudgetTier.forTotalMemory(4 * GIB).tier)
        assertEquals(MemoryTier.AT_MOST_3, HostBudgetTier.forTotalMemory(4 * GIB - 1).tier)
        assertEquals(MemoryTier.AT_MOST_3, HostBudgetTier.forTotalMemory(3 * GIB).tier)
    }

    /**
     * The ceilings an AVD really reports are *below* the nominal RAM size.
     *
     * A 2 GiB AVD reports ~1.9 GiB, a 6 GiB AVD ~5.8 GiB — the second one is the
     * 4 GiB row, not the 6 GiB row, because budgets.md:95-96 makes a row apply
     * from its own threshold upward. Selecting by "closest row" would be wrong
     * on both devices.
     */
    @Test
    fun `a device just under a threshold takes the row below it`() {
        // GiB, not GB: 1 GiB = 2^30 bytes, so "5.8e9 bytes" is 5.4 GiB.
        assertEquals(MemoryTier.AT_MOST_3, HostBudgetTier.forTotalMemory(2 * GIB - 100L * MIB).tier)
        assertEquals(MemoryTier.GIB_4, HostBudgetTier.forTotalMemory(6 * GIB - 200L * MIB).tier)
        assertEquals(MemoryTier.GIB_6, HostBudgetTier.forTotalMemory(6 * GIB + 100L * MIB).tier)
    }

    /** budgets.md:104 "Single file": 256 / 128 / 48 / 32 / 16 MiB. */
    @Test
    fun `single file limit is the budgets md 4 single file row`() {
        assertEquals(256 * MIB, HostBudgetTier.singleFileLimitBytes(12 * GIB))
        assertEquals(128 * MIB, HostBudgetTier.singleFileLimitBytes(8 * GIB))
        assertEquals(48 * MIB, HostBudgetTier.singleFileLimitBytes(6 * GIB))
        assertEquals(32 * MIB, HostBudgetTier.singleFileLimitBytes(4 * GIB))
        assertEquals(16 * MIB, HostBudgetTier.singleFileLimitBytes(3 * GIB))
        assertEquals(16 * MIB, HostBudgetTier.singleFileLimitBytes(2 * GIB))
    }

    /**
     * A missing reading is not a licence for the default row.
     *
     * `MemoryInfo.totalMem` is 0 only on a failed reading; the smallest row is
     * what an unmeasured device gets. budgets.md:95-97 only maps a *known*
     * ceiling ("The 8 GB row is the default; a lower row applies when the
     * ceiling is below 8 GiB …") and never states the unknown case, so the
     * implementation takes the side that cannot widen a quota.
     */
    @Test
    fun `an unknown ceiling takes the smallest row`() {
        assertEquals(MemoryTier.AT_MOST_3, HostBudgetTier.forTotalMemory(0L).tier)
        assertEquals(16 * MIB, HostBudgetTier.singleFileLimitBytes(0L))
        assertFalse(HostBudgetTier.isMeasured(0L))
        assertTrue(HostBudgetTier.isMeasured(2 * GIB))
    }

    /**
     * One fact, one answer: "unmeasured" (the `UNMEASURED` default) and "a
     * reading of 0" are the same fact and must return the same row.
     *
     * This test repairs an inconsistency the first revision of this lane
     * shipped: `readTotalMemoryBytes` failure produced the `≤ 3 GiB` row
     * (16 MiB) while the `deviceBudgets` default was the 8 GiB row (128 MiB) —
     * the same "no measurement", two opposite answers, and the larger one
     * re-opened this lane's own bug (a `≤ 3 GiB` device carrying an 8× file
     * quota). Reverse verification: set `UNMEASURED` back to the 8 GiB row and
     * this test fails on `16 * MIB`.
     */
    @Test
    fun `the unmeasured default is the smallest row, not the 8 GiB default`() {
        assertEquals(MemoryTier.AT_MOST_3, HostBudgetTier.UNMEASURED.tier)
        assertEquals(16 * MIB, HostBudgetTier.UNMEASURED.singleFileBytes)
        assertEquals(
            "unmeasured and totalMem=0 are the same fact and must agree",
            HostBudgetTier.forTotalMemory(0L),
            HostBudgetTier.UNMEASURED,
        )
        assertFalse(
            "the 8 GiB row (128 MiB) must not be the unmeasured default",
            HostBudgetTier.UNMEASURED.singleFileBytes == 128 * MIB,
        )
    }

    /** The Worker's publication channel is the environment variable of D4. */
    @Test
    fun `the worker environment publishes the selected single file limit`() {
        assertEquals(
            mapOf("PDSH_SINGLE_FILE_LIMIT_BYTES" to (16 * MIB).toString()),
            HostBudgetTier.workerEnvironment(2 * GIB),
        )
        assertEquals(
            mapOf("PDSH_SINGLE_FILE_LIMIT_BYTES" to (48 * MIB).toString()),
            HostBudgetTier.workerEnvironment(6 * GIB),
        )
        assertEquals(
            mapOf("PDSH_SINGLE_FILE_LIMIT_BYTES" to (256 * MIB).toString()),
            HostBudgetTier.workerEnvironment(12 * GIB),
        )
    }

    /**
     * Reverse-verification anchor: a 2 GiB device must NOT be handed the 8 GiB
     * default.
     *
     * Before this lane the host selected nothing and the Worker kept its 8 GiB
     * default of 128 MiB (`plugins/wasi-toolbox/src/limits.ts:46`), so a 2 GiB
     * device accepted a 128 MiB file that its §4 row caps at 16 MiB — the OOM
     * this lane exists to prevent. An implementation that "always returns the
     * highest row" (or no row at all) fails this assertion.
     */
    @Test
    fun `a two GiB device is not handed the 8 GiB default`() {
        val twoGiB = 2 * GIB
        val budgets = HostBudgetTier.forTotalMemory(twoGiB)
        assertEquals(16 * MIB, budgets.singleFileBytes)
        assertFalse(
            "a 2 GiB device must not receive the Worker's 128 MiB default",
            budgets.singleFileBytes == 128 * MIB,
        )
        assertTrue(budgets.singleFileBytes < 128 * MIB)
    }
}
