// The anti-regression guard for the durability product claim.
// SPDX-License-Identifier: MIT
//
// A future edit that "improves" level() to LEVEL_2_POWER_LOSS_MEASURED must fail
// here first: the claim needs a device-class power-cut bench (plan §11-R1, D2a;
// §14.3-4), and no such measurement exists for this adapter.

package com.phonedsh.platform.android

import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.platform.supportsLevel2Claim
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Test

class AndroidDurabilityLevelTest {

    @Test
    fun levelNeverClaimsMeasuredPowerLoss() {
        val durability = AndroidDurability(directorySync = DirectorySync { })

        assertNotEquals(
            "MEASURED may only be returned after a device power-cut bench",
            DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED,
            durability.level(),
        )
        assertFalse(
            "supportsLevel2Claim() must stay false while no bench exists",
            durability.level().supportsLevel2Claim(),
        )
    }

    @Test
    fun levelReportsTheUnverifiedLevelTwoMechanism() {
        assertEquals(
            "the D18 mechanism exists, so level 2 unverified is the honest report",
            DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED,
            AndroidDurability(directorySync = DirectorySync { }).level(),
        )
    }
}
