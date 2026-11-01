// P6 — `runs_while_app_suspended` is computed from platform facts, not assumed.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The capability bit used to be hard-coded `true` twice: in the constructor
 * default and in a test that asserted the default. Both were wrong for Android:
 * a turn can only keep running (and be *seen* to keep running) with a startable
 * foreground service, a user-initiated data-transfer grant and a granted
 * POST_NOTIFICATIONS (plan §7.10; P6 acceptance "能力位诚实").
 *
 * The wire value is still honoured verbatim — a backend that says `true` is
 * telling the truth about itself. What changed is that this host no longer
 * repeats the claim without checking whether it can honour it.
 */
class BackgroundExecutionTest {
    private fun facts(
        backendOutlivesApp: Boolean = true,
        foregroundServiceUsable: Boolean = true,
        userInitiatedDataTransferGranted: Boolean = true,
        notificationsGranted: Boolean = true,
    ) = BackgroundExecutionFacts(
        backendOutlivesApp = backendOutlivesApp,
        foregroundServiceUsable = foregroundServiceUsable,
        userInitiatedDataTransferGranted = userInitiatedDataTransferGranted,
        notificationsGranted = notificationsGranted,
    )

    @Test
    fun theConstructorDefaultDoesNotClaimBackgroundExecution() {
        // Regression guard: this used to be `= true`. A default is not evidence.
        assertFalse(HarnessCapabilities().runsWhileAppSuspended)
    }

    @Test
    fun aDecodedWireValueIsHonouredVerbatim() {
        // The decoder reports what the backend said; the platform narrowing is a
        // separate step. `true` on the wire therefore stays `true` here.
        val claimed = HarnessJson.decodeCapabilities(
            """{"cancel":true,"steer":true,"resume":"native","permission":"native",
               "client_tools":"none","tool_visibility":true,"runs_while_app_suspended":true}""",
        )
        assertTrue(claimed.runsWhileAppSuspended)

        val declined = HarnessJson.decodeCapabilities(
            """{"cancel":true,"steer":false,"resume":"replay","permission":"relay",
               "client_tools":"bridge","tool_visibility":false,"runs_while_app_suspended":false}""",
        )
        assertFalse(declined.runsWhileAppSuspended)
    }

    @Test
    fun everySignalMetKeepsTheClaim() {
        val facts = facts()
        assertTrue(facts.runsWhileAppSuspended)
        assertTrue(facts.missingSignals.isEmpty())
        assertTrue(facts.explain().startsWith("runs_while_app_suspended=true:"))

        val narrowed = HarnessCapabilities(runsWhileAppSuspended = true).narrowedTo(facts)
        assertTrue(narrowed.runsWhileAppSuspended)
    }

    @Test
    fun eachMissingSignalWithdrawsTheClaimAndSaysWhich() {
        val cases = listOf(
            "foreground service" to facts(foregroundServiceUsable = false),
            "user-initiated data transfer" to facts(userInitiatedDataTransferGranted = false),
            "POST_NOTIFICATIONS" to facts(notificationsGranted = false),
        )
        for ((label, facts) in cases) {
            assertFalse("$label must withdraw the claim", facts.runsWhileAppSuspended)
            assertEquals(
                "$label must be named as the missing signal",
                listOf(label),
                facts.missingSignals.map { it.label },
            )
            val narrowed = HarnessCapabilities(runsWhileAppSuspended = true).narrowedTo(facts)
            assertFalse("$label must narrow the capability", narrowed.runsWhileAppSuspended)
            assertTrue(
                "the explanation must name $label",
                facts.explain().contains(label),
            )
        }
    }

    @Test
    fun anEmbeddedBackendNeverClaimsBackgroundExecution() {
        val facts = facts(backendOutlivesApp = false)
        assertFalse(facts.runsWhileAppSuspended)
        assertTrue(facts.explain().contains("embedded"))

        val narrowed = HarnessCapabilities(runsWhileAppSuspended = true).narrowedTo(facts)
        assertFalse(narrowed.runsWhileAppSuspended)
    }

    @Test
    fun narrowingCannotWidenARefusal() {
        val narrowed = HarnessCapabilities(runsWhileAppSuspended = false).narrowedTo(facts())
        assertFalse(narrowed.runsWhileAppSuspended)
    }

    @Test
    fun narrowingLeavesTheOtherMembersAlone() {
        val capabilities = HarnessCapabilities(
            cancel = false,
            steer = true,
            resume = HarnessCapabilities.Resume.REPLAY,
            permission = HarnessCapabilities.Permission.RELAY,
            clientTools = HarnessCapabilities.ClientTools.BRIDGE,
            toolVisibility = false,
            runsWhileAppSuspended = true,
        )
        val narrowed = capabilities.narrowedTo(facts(notificationsGranted = false))
        assertEquals(capabilities.copy(runsWhileAppSuspended = false), narrowed)
    }
}
