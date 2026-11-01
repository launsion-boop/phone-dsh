// The durability claim is the SPI's value, never a promotion by this layer.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.platform.supportsLevel2Claim
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DurabilityClaimTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun claimIsTheSpiValueVerbatim() {
        for (level in DurabilityLevel.entries) {
            val root = temporary.newFolder("level-${level.ordinal}").toPath()
            val log = newLog(root, RecordingDurability(root, level))
            assertEquals(level, log.durabilityClaim())
        }
    }

    @Test
    fun anUnmeasuredLevelTwoIsNeverPromoted() = runBlocking {
        val root = temporary.newFolder("unverified").toPath()
        val durability = RecordingDurability(root, DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED)
        val log = newLog(root, durability)
        assertTrue(log.recover() is RecoveryOutcome.Recovered)
        assertEquals(1L, log.appendMutation(writeMutation("/dsh/workspace/a.txt", "a")).mseq)
        assertEquals(AckLevel.LEVEL_2, log.closeEpoch().level)

        // The epoch close ran the level-2 *mechanism*; the bench is absent, so
        // the claim stays UNVERIFIED and a caller must treat it like level 1.
        assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED, log.durabilityClaim())
        assertFalse(log.durabilityClaim().supportsLevel2Claim())
    }

    @Test
    fun aMeasuredSpiIsReportedUnchanged() {
        val root = temporary.newFolder("measured").toPath()
        val log = newLog(root, RecordingDurability(root, DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED))
        assertEquals(DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED, log.durabilityClaim())
        assertTrue(log.durabilityClaim().supportsLevel2Claim())
    }
}
