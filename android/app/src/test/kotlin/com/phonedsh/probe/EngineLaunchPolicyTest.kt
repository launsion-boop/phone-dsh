// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.probe.outbox.HostSpec
import com.phonedsh.probe.outbox.bool
import com.phonedsh.probe.outbox.child
import com.phonedsh.probe.outbox.long
import com.phonedsh.probe.outbox.objects
import com.phonedsh.probe.outbox.string
import org.junit.Assert.assertEquals
import org.junit.Test

class EngineLaunchPolicyTest {
    @Test
    fun decisionsMatchSharedHostVectors() {
        val fixture = HostSpec.goldenInstance("engine-launch.json")
        val constants = fixture.child("constants")
        assertEquals(constants.long("minLeaseForColdBootMs"), EngineLaunchPolicy.MIN_COLD_BOOT_MS)
        assertEquals(constants.long("minLeaseForResumeMs"), EngineLaunchPolicy.MIN_RESUME_MS)
        val vectors = fixture.objects("decisionVectors")
        check(vectors.isNotEmpty())
        for (vector in vectors) {
            val input = vector.child("input")
            val decision = EngineLaunchPolicy.decide(
                foreground = input.bool("foreground"),
                residentAudio = input.bool("residentAudio"),
                hostState = LaunchHostState.valueOf(input.string("hostState")),
                leaseRemainingMs = (input["leaseRemainingMs"] as? JsonNumber)?.asLongOrNull(),
                userStopped = input.bool("userStopped"),
                needsReset = input.bool("needsReset"),
            )
            assertEquals(vector.string("id"), vector.string("expected"), decision.wireValue)
        }
    }
}
