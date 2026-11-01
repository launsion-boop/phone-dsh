// A reverse test: level-2 power-loss safety may never be the default claim.
// SPDX-License-Identifier: MIT
//
// plan §11-R1 / D2a: the power-loss bench is not part of this round, so an
// implementation that has level-1 or an unverified level-2 mechanism must answer
// false. If this test ever fails because UNVERIFIED became true, the product is
// silently promising something no device measured.

package com.phonedsh.platform

import com.phonedsh.platform.testing.FakePlatform
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DurabilityLevelTest {
    @Test
    fun onlyAMeasuredLevelTwoSupportsThePowerLossClaim() {
        assertFalse(DurabilityLevel.LEVEL_1_PROCESS_KILL.supportsLevel2Claim())
        assertFalse(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED.supportsLevel2Claim())
        assertTrue(DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED.supportsLevel2Claim())
    }

    @Test
    fun theFakeReportsItsConfiguredLevelInsteadOfAssumingTheStrongest() {
        val fake = FakePlatform(initialDurabilityLevel = DurabilityLevel.LEVEL_1_PROCESS_KILL)
        try {
            assertEquals(DurabilityLevel.LEVEL_1_PROCESS_KILL, fake.level())
            assertFalse(fake.level().supportsLevel2Claim())

            fake.durabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED
            assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED, fake.level())
            assertFalse("an unverified level-2 mechanism is not a measured claim", fake.level().supportsLevel2Claim())

            fake.durabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED
            assertTrue(fake.level().supportsLevel2Claim())
        } finally {
            fake.close()
        }
    }

    @Test
    fun theLocalTestBackendAlsoStartsUnverified() {
        val local = LocalDurability()
        assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED, local.level())
        assertFalse(local.level().supportsLevel2Claim())
    }
}
