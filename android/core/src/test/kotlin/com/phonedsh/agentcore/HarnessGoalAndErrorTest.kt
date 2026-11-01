// D1-c tests — the goal projection and the eight error classes.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HarnessGoalAndErrorTest {
    @Test
    fun blockedGoalRequiresAReasonAndOnlyBlockedCarriesOne() {
        val blocked = HarnessJson.decodeGoal(
            """
            {
              "objective": "Ship the Android demo",
              "phase": "blocked",
              "blocked_reason": "missing emulator system image",
              "rounds_started": 2,
              "max_goal_rounds": 6
            }
            """.trimIndent(),
        )

        assertEquals(HarnessGoal.Phase.BLOCKED, blocked.phase)
        assertEquals("missing emulator system image", blocked.blockedReason)
        assertEquals(2L, blocked.roundsStarted)
        assertEquals(6L, blocked.maxGoalRounds)

        val active = HarnessJson.decodeGoal(
            """{"objective":"go","phase":"active","rounds_started":0,"max_goal_rounds":3}""",
        )
        assertEquals(HarnessGoal.Phase.ACTIVE, active.phase)
        assertNull(active.blockedReason)

        assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeGoal(
                """{"objective":"go","phase":"blocked","rounds_started":0,"max_goal_rounds":3}""",
            )
        }
        assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeGoal(
                """{"objective":"go","phase":"active","blocked_reason":"why","rounds_started":0,"max_goal_rounds":3}""",
            )
        }
    }

    @Test
    fun goalConstructorRejectsTheSameInvariantViolation() {
        assertThrows(IllegalArgumentException::class.java) {
            HarnessGoal(
                objective = "go",
                phase = HarnessGoal.Phase.BLOCKED,
                roundsStarted = 0,
                maxGoalRounds = 1,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            HarnessGoal(
                objective = "go",
                phase = HarnessGoal.Phase.ACTIVE,
                roundsStarted = 0,
                maxGoalRounds = 1,
                blockedReason = "not allowed",
            )
        }
    }

    @Test
    fun errorClassesAndRetrySplitMatchTheSchema() {
        assertEquals(8, HarnessErrorCode.entries.size)
        assertEquals(
            setOf("unavailable", "rate_limited"),
            HarnessErrorCode.entries.filter { it.retryable }.map { it.wire }.toSet(),
        )

        val unavailable = HarnessJson.decodeError(
            """{"code":"unavailable","message":"event stream retry budget exhausted","retry_after_ms":1000}""",
        )
        assertEquals(HarnessErrorCode.UNAVAILABLE, unavailable.code)
        assertTrue(unavailable.retryable)
        assertEquals(1000L, unavailable.retryAfterMs)
        assertEquals("event stream retry budget exhausted", unavailable.message)

        val invalid = HarnessJson.decodeError("""{"code":"invalid_request"}""")
        assertFalse(invalid.retryable)
        assertNull(invalid.message)
    }

    @Test
    fun unavailableExceptionIsRetryableAndCarriesTheHint() {
        val failure = HarnessUnavailable(message = "transport lost", retryAfterMs = 250)

        assertEquals(HarnessErrorCode.UNAVAILABLE, failure.code)
        assertTrue(failure.retryable)
        assertEquals(250L, failure.retryAfterMs)
        assertEquals("transport lost", failure.message)
    }

    @Test
    fun unknownErrorCodeIsRejected() {
        val failure = assertThrows(HarnessDecodingException::class.java) {
            HarnessJson.decodeError("""{"code":"gateway_timeout"}""")
        }
        assertEquals("error", failure.path)
        assertEquals(HarnessErrorCode.INVALID_RESPONSE, failure.code)
    }
}
