// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Pure check boundaries and the upstream five-finding vector. */
class BotWatchdogChecksTest {
    @Test
    fun upstreamGoldenProducesAllFiveFindingsInOrder() {
        val expected = fixture("watchdog").requireObject("valid")
            .getValue("flagged").arrayOrNull()!!.map { it.asUnitsJson() }
        val unit = BotWatchdogUnit(
            kind = BotWatchdogUnitKind.TURN,
            id = "unit",
            startedAt = 1,
            lastEventAt = 1,
            deadlineAt = 1,
            repeatedToolSignatureCount = 5,
            lastToolSignature = "tool:digest",
            repeatedToolErrorCount = 3,
            lastToolErrorSignature = "tool:error",
            tokens = 200_001,
            costUsd = 0.0,
        )
        val findings = BotWatchdogChecks.run(unit, now = 1_760_000_000_000)
        assertEquals(
            expected.map { it.members.getValue("check").requiredString() },
            findings.map { it.check.wireValue },
        )
        for ((index, finding) in findings.withIndex()) {
            assertCanonicalEquals(
                expected[index].members.getValue("evidence"),
                JsonObject(LinkedHashMap(finding.evidence)),
                "finding ${finding.check.wireValue}",
            )
        }
    }

    @Test
    fun strictThresholdsAndPendingApprovalSuppressHeartbeat() {
        assertNull(
            BotWatchdogChecks.deadline(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", startedAt = 0, deadlineAt = 10),
                now = 10,
            ),
        )
        assertNotNull(
            BotWatchdogChecks.deadline(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", startedAt = 0, deadlineAt = 10),
                now = 11,
            ),
        )
        val heartbeat = BotWatchdogConfig(heartbeatTimeoutMs = 10)
        assertNull(
            BotWatchdogChecks.heartbeat(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", startedAt = 0, lastEventAt = 0),
                now = 10,
                config = heartbeat,
            ),
        )
        assertNotNull(
            BotWatchdogChecks.heartbeat(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", startedAt = 0, lastEventAt = 0),
                now = 11,
                config = heartbeat,
            ),
        )
        assertNull(
            BotWatchdogChecks.heartbeat(
                BotWatchdogUnit(
                    BotWatchdogUnitKind.TURN, "u", startedAt = 0, lastEventAt = 0,
                    pendingApproval = 1,
                ),
                now = 100,
                config = heartbeat,
            ),
        )
        assertEquals(
            BotWatchdogCheck.REPEATED_TOOL_SIGNATURE,
            BotWatchdogChecks.repeatedToolSignature(
                BotWatchdogUnit(
                    BotWatchdogUnitKind.TASK, "u",
                    repeatedToolSignatureCount = 5, lastToolSignature = "read|d",
                ),
                BotWatchdogConfig(repeatedToolCalls = 5),
            )?.check,
        )
        assertNull(
            BotWatchdogChecks.repeatedToolSignature(
                BotWatchdogUnit(
                    BotWatchdogUnitKind.TASK, "u",
                    repeatedToolSignatureCount = 100, lastToolSignature = "read|d",
                ),
                BotWatchdogConfig(repeatedToolCalls = 0),
            ),
        )
        assertEquals(
            BotWatchdogCheck.REPEATED_TOOL_ERROR,
            BotWatchdogChecks.repeatedToolError(
                BotWatchdogUnit(
                    BotWatchdogUnitKind.TASK, "u",
                    repeatedToolErrorCount = 3, lastToolErrorSignature = "read|sha256:x",
                ),
                BotWatchdogConfig(repeatedToolErrors = 3),
            )?.check,
        )
    }

    @Test
    fun quotaIsStrictAndNamesItsReason() {
        val config = BotWatchdogConfig(maxUnitTokens = 10, maxUnitCostUsd = 1.0)
        assertNull(
            BotWatchdogChecks.quota(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", tokens = 10, costUsd = 1.0),
                config,
            ),
        )
        assertEquals(
            "tokens",
            quotaReason(BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", tokens = 11)),
        )
        assertEquals(
            "cost",
            quotaReason(BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", costUsd = 1.5)),
        )
        assertEquals(
            "tokens_and_cost",
            quotaReason(BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", tokens = 11, costUsd = 1.5)),
        )
        assertNull(
            BotWatchdogChecks.quota(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", tokens = -5, costUsd = -1.0),
                config,
            ),
        )
        assertNull(
            BotWatchdogChecks.quota(
                BotWatchdogUnit(BotWatchdogUnitKind.TURN, "u", tokens = 100, costUsd = 100.0),
                BotWatchdogConfig(maxUnitTokens = 0, maxUnitCostUsd = 0.0),
            ),
        )
    }

    @Test
    fun zeroConfigDisablesEveryActiveThreshold() {
        val unit = BotWatchdogUnit(
            BotWatchdogUnitKind.TURN,
            "u",
            startedAt = 0,
            lastEventAt = 0,
            repeatedToolSignatureCount = 100,
            lastToolSignature = "read|d",
            repeatedToolErrorCount = 100,
            lastToolErrorSignature = "read|sha256:x",
            tokens = 1_000,
            costUsd = 1_000.0,
        )
        val config = BotWatchdogConfig(
            heartbeatTimeoutMs = 0,
            turnDeadlineMs = 0,
            taskDeadlineMs = 0,
            routineDeadlineMs = 0,
            repeatedToolCalls = 0,
            repeatedToolErrors = 0,
            maxUnitTokens = 0,
            maxUnitCostUsd = 0.0,
        )
        assertEquals(emptyList<BotWatchdogFinding>(), BotWatchdogChecks.run(unit, 1_000_000, config))
    }

    @Test
    fun mobileSignalsCannotCarryAFabricatedEmptyReading() {
        assertTrue(
            BotMobileWatchdogSignal(
                BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                emptyMap(),
            ).evidence.isEmpty(),
        )
        for (event in listOf(
            BotMobileWatchdogEvent.THERMAL_PRESSURE,
            BotMobileWatchdogEvent.BATTERY_PRESSURE,
        )) {
            try {
                BotMobileWatchdogSignal(event, emptyMap())
                fail("${event.wireValue} accepted an empty reading")
            } catch (_: IllegalArgumentException) {
                // Expected: availability is a null port result, not a fake value.
            }
        }
    }

    private fun quotaReason(unit: BotWatchdogUnit): String {
        val finding = BotWatchdogChecks.quota(
            unit,
            BotWatchdogConfig(maxUnitTokens = 10, maxUnitCostUsd = 1.0),
        ) ?: error("expected quota finding")
        return (finding.evidence["reason"] as com.phonedsh.agentcore.JsonString).value
    }
}
