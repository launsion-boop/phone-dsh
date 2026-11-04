// phone-dsh — :dsh unit test: the ingest file limit and its declared raise.
// SPDX-License-Identifier: MIT
//
// C1's decision, pinned: `limits.fileLimitBytes` defaults to 15 MiB (one
// mutation, so the default ingest cannot leave half a file), and an environment
// may raise it only up to the tier's `single_file_limit`, clamped the way
// budgets.md §4 clamps that value. The raise is declared on the JobRef, so the
// number a caller must respect is published before a byte moves.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.MemoryTier
import org.junit.Assert.assertEquals
import org.junit.Test

class UbuntuJobLimitsTest {
    @Test
    fun the_default_file_limit_is_one_mutation() {
        val limits = UbuntuJobLimits.of(ControllerBudgets.forTier(MemoryTier.GIB_8))
        assertEquals(15L * 1_048_576L, limits.fileLimitBytes)
        assertEquals(UbuntuJobLimits.MUTATION_MAX_BYTES, UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES)
        assertEquals(15L * 1_048_576L, UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES)
    }

    @Test
    fun a_configured_value_below_the_default_is_clamped_up_not_refused() {
        val limits = UbuntuJobLimits.of(
            ControllerBudgets.forTier(MemoryTier.GIB_8),
            configuredFileLimitBytes = 1024L * 1024L,
        )
        assertEquals(UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES, limits.fileLimitBytes)
    }

    @Test
    fun a_raise_is_clamped_to_the_tier_single_file_limit() {
        // 20 MiB is a legal raise on the 8 GiB row (128 MiB) and clamps to the
        // 3 GiB row's 16 MiB floor; both are declared, never a start failure.
        assertEquals(
            20L * 1_048_576L,
            UbuntuJobLimits.of(
                ControllerBudgets.forTier(MemoryTier.GIB_8),
                configuredFileLimitBytes = 20L * 1_048_576L,
            ).fileLimitBytes,
        )
        assertEquals(
            16L * 1_048_576L,
            UbuntuJobLimits.of(
                ControllerBudgets.forTier(MemoryTier.AT_MOST_3),
                configuredFileLimitBytes = 20L * 1_048_576L,
            ).fileLimitBytes,
        )
        // And a raise above the tier's own maximum is the maximum, not a failure.
        assertEquals(
            ControllerBudgets.forTier(MemoryTier.GIB_8).singleFileBytes,
            UbuntuJobLimits.of(
                ControllerBudgets.forTier(MemoryTier.GIB_8),
                configuredFileLimitBytes = 512L * 1_048_576L,
            ).fileLimitBytes,
        )
    }
}
