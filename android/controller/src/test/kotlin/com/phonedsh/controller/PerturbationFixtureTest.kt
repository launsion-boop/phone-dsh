// phone-dsh Android — :controller golden perturbation fixtures (kill-replay matrix).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

import com.phonedsh.agentcore.JsonString
import com.phonedsh.controller.ControllerEffect.SEND_FENCE
import com.phonedsh.controller.ControllerEffect.SEND_LIFECYCLE_OPEN
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives the pure D14 state machine with the 16 normative fixtures under
 * `spec/v1/golden/perturbations/`.
 *
 * The fixture README's runner contract has five steps. This lane owns steps 1
 * (build the preconditions), 3 (record every transition, assert `state_path`
 * and the terminal state) and the controller-observable part of step 4
 * (`admission`, `boot_disposition`, `no_drain_before_kill`,
 * `fence_and_lifecycle_resent`). The durability and journal members
 * (`durability_level`, `wal_tail`, `journal_gap`, `acked_prefix_preserved`,
 * `materialized_equals_replay`, `steps_*`, ...) describe stores this module does
 * not own; they are deliberately not asserted here and are covered by the
 * WAL/journal lanes. `unmeasured` members are never asserted, and the fixture
 * law that they carry no `field_evidence` is checked.
 */
class PerturbationFixtureTest {

    @Test
    fun `all sixteen fixtures are present and all eleven verbs are covered`() {
        val fixtures = Fixtures.loadAll()
        assertEquals(Fixtures.EXPECTED_COUNT, fixtures.size)
        assertEquals("fixture ids are unique", fixtures.size, fixtures.map { it.id }.toSet().size)
        assertEquals(
            "ids equal file names",
            fixtures.map { it.file.nameWithoutExtension }.sorted(),
            fixtures.map { it.id }.sorted(),
        )
        assertEquals(
            "every perturbation verb of the README is represented",
            setOf(
                "kill_9",
                "sigterm",
                "drain_timeout",
                "system_reclaim",
                "power_loss_torn_tail",
                "renderer_terminate",
                "force_stop_zero_callback",
                "planned_restart",
                "cold_start_after_reboot",
                "write_without_ack",
                "stop_seal_failure",
            ),
            fixtures.map { it.verb }.toSet(),
        )
    }

    // ---- the 16 fixtures, one test each ------------------------------------------

    @Test
    fun `cold-start-after-reboot`() = runFixture("cold-start-after-reboot")

    @Test
    fun `drain-background-task-expiry`() = runFixture("drain-background-task-expiry")

    @Test
    fun `drain-deadline-20s`() = runFixture("drain-deadline-20s")

    @Test
    fun `force-stop-zero-callback`() = runFixture("force-stop-zero-callback")

    @Test
    fun `kill-9-after-write`() = runFixture("kill-9-after-write")

    @Test
    fun `kill-9-during-checkpoint`() = runFixture("kill-9-during-checkpoint")

    @Test
    fun `planned-restart-helper-failure`() = runFixture("planned-restart-helper-failure")

    @Test
    fun `planned-restart-reconciles-pending-step`() = runFixture("planned-restart-reconciles-pending-step")

    @Test
    fun `power-loss-torn-tail`() = runFixture("power-loss-torn-tail")

    @Test
    fun `renderer-terminated-during-exec`() = runFixture("renderer-terminated-during-exec")

    @Test
    fun `renderer-terminated-orphan-abandoned`() = runFixture("renderer-terminated-orphan-abandoned")

    @Test
    fun `renderer-terminated-reconciled-on-write-open`() =
        runFixture("renderer-terminated-reconciled-on-write-open")

    @Test
    fun `sigterm-runner-guard`() = runFixture("sigterm-runner-guard")

    @Test
    fun `stop-seal-failure`() = runFixture("stop-seal-failure")

    @Test
    fun `system-reclaim-host-killed`() = runFixture("system-reclaim-host-killed")

    @Test
    fun `write-without-ack`() = runFixture("write-without-ack")

    // ---- driver -------------------------------------------------------------------

    private sealed interface Action {
        data object Noop : Action
        data object ProcessDeath : Action
        data object ProcessStart : Action
        data class Apply(val signal: ControllerSignal) : Action
    }

    private fun runFixture(id: String) {
        val fixture = Fixtures.load(id)
        val preconditions = fixture.preconditions
        val initialState = HostState.requireWireName(preconditions.str("host_state"))
        assertEquals(
            "$id: precondition admission must follow the state",
            initialState.admission.wireName,
            preconditions.str("admission"),
        )

        var machine = preconditionMachine(initialState)
        val persisted: HostState? = preconditions.optStr("persisted_state")?.let {
            if (it == "absent") null else HostState.requireWireName(it)
        }

        val observed = mutableListOf(machine.state)
        var lastBootDisposition: BootDisposition? = null
        var failedAt: Int? = null
        var openFramesAfterFailure = 0
        var sawDraining = machine.state == HostState.DRAINING

        val actions = actionsFor(fixture)
        val times = fixture.timeline.map { it.int("at") }
        assertEquals("$id: every timeline step needs a driver action", times.toSet(), actions.keys)
        assertEquals("$id: timeline at values are non-decreasing", times.sorted(), times)

        fixture.timeline.forEach { event ->
            val at = event.int("at")
            when (val action = actions.getValue(at)) {
                Action.Noop -> Unit

                Action.ProcessDeath -> {
                    assertEquals(
                        "$id at $at: the state persisted at the perturbation point",
                        persisted,
                        machine.state,
                    )
                }

                Action.ProcessStart -> {
                    machine = ControllerStateMachine.boot(persisted)
                    observed += machine.state
                    lastBootDisposition = machine.bootDisposition
                    assertEquals(
                        "$id at $at: admission after process start",
                        Admission.CLOSED,
                        machine.admission,
                    )
                    if (machine.state == HostState.FAILED && failedAt == null) failedAt = at
                }

                is Action.Apply -> {
                    val wasFailed = failedAt != null
                    val outcome = machine.handle(action.signal, at.toLong())
                    when (outcome) {
                        is SignalOutcome.Transitioned -> {
                            observed += outcome.record.to
                            if (outcome.record.to == HostState.DRAINING) sawDraining = true
                            if (wasFailed &&
                                (outcome.record.effects.contains(SEND_FENCE) ||
                                    outcome.record.effects.contains(SEND_LIFECYCLE_OPEN))
                            ) {
                                openFramesAfterFailure++
                            }
                            if (outcome.record.to == HostState.FAILED && failedAt == null) failedAt = at
                        }

                        is SignalOutcome.Observed -> Unit

                        is SignalOutcome.Rejected -> fail(
                            "$id at $at (${event.str("event")}): " +
                                "${outcome.signal} was rejected: ${outcome.detail}",
                        )
                    }
                }
            }

            event.optStr("expect_state")?.let { expected ->
                assertEquals(
                    "$id at $at (${event.str("event")}): observed state",
                    expected,
                    machine.state.wireName,
                )
            }
        }

        val expected = fixture.expected
        val expectedState = expected.str("state")
        assertEquals("$id: terminal state", expectedState, machine.state.wireName)

        val statePath = expected.arr("state_path").map { it.asStr("$id state_path entry") }
        assertTrue("$id: state_path must not be empty", statePath.isNotEmpty())
        assertEquals("$id: state_path must end in state", expectedState, statePath.last())
        statePath.forEach { HostState.requireWireName(it) }
        assertSubsequence("$id: state_path", statePath, observed.map { it.wireName })

        expected.optStr("admission")?.let { admission ->
            if (admission != "unmeasured") {
                assertEquals("$id: admission", admission, machine.admission.wireName)
            }
        }
        expected.optStr("boot_disposition")?.let { disposition ->
            if (disposition != "unmeasured") {
                assertEquals(
                    "$id: boot_disposition",
                    disposition,
                    lastBootDisposition?.wireName,
                )
            }
        }
        if (expected.optBool("no_drain_before_kill") == true) {
            assertFalse("$id: no Draining edge may be observed before the kill", sawDraining)
        }
        if (expected.optBool("fence_and_lifecycle_resent") == false) {
            assertEquals("$id: no post-Failed FENCE/LIFECYCLE open pair", 0, openFramesAfterFailure)
            assertEquals("$id: admission after Failed", Admission.CLOSED, machine.admission)
        }

        // Every member this runner asserts must carry evidence (README §4).
        val assertedHere = listOf(
            "state",
            "state_path",
            "admission",
            "boot_disposition",
            "no_drain_before_kill",
            "fence_and_lifecycle_resent",
        )
        assertedHere.filter { expected.members.containsKey(it) }.forEach { member ->
            assertTrue(
                "$id: asserted member '$member' has no field_evidence",
                fixture.fieldEvidence.containsKey(member),
            )
        }

        // `unmeasured` is an absence of evidence, never a value (README §3–§4).
        val unmeasured = expected.members
            .filterValues { it is JsonString && it.value == "unmeasured" }
            .keys
        unmeasured.forEach { key ->
            assertFalse(
                "$id: '$key' is unmeasured but field_evidence asserts it",
                fixture.fieldEvidence.containsKey(key),
            )
        }
        assertTrue(
            "$id: field_evidence names only expected members",
            fixture.fieldEvidence.keys.all { expected.members.containsKey(it) },
        )
    }

    private fun preconditionMachine(state: HostState): ControllerStateMachine = when (state) {
        HostState.RUNNING -> TestMachines.running()
        HostState.PARKED -> ControllerStateMachine.boot(HostState.PARKED)
        else -> error("the 16 fixtures only use Running and Parked preconditions, got $state")
    }

    private fun actionsFor(fixture: Fixture): Map<Int, Action> = when (fixture.id) {
        "cold-start-after-reboot" -> mapOf(
            0 to Action.Noop,
            3_000 to Action.ProcessDeath,
            4_000 to Action.ProcessStart,
            4_010 to Action.Apply(
                ControllerSignal.ScenePhaseChanged(ScenePhase.ACTIVE),
            ),
            4_020 to Action.Noop,
            4_030 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
        )

        "drain-background-task-expiry" -> mapOf(
            0 to Action.Apply(
                ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND),
            ),
            1_200 to Action.Apply(ControllerSignal.BackgroundTaskExpired),
            1_210 to Action.Apply(ControllerSignal.DrainCompleted),
            1_220 to Action.Noop,
        )

        "drain-deadline-20s" -> mapOf(
            0 to Action.Noop,
            5 to Action.Apply(
                ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND),
            ),
            20_005 to Action.Apply(ControllerSignal.DrainDeadlineElapsed),
            20_010 to Action.Apply(ControllerSignal.DrainCompleted),
            20_020 to Action.Noop,
        )

        "force-stop-zero-callback" -> mapOf(
            0 to Action.Noop,
            5 to Action.ProcessDeath,
            10 to Action.Noop,
            20 to Action.ProcessStart,
            30 to Action.Noop,
            40 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            50 to Action.Noop,
        )

        "kill-9-after-write" -> mapOf(
            0 to Action.Noop,
            10 to Action.ProcessDeath,
            20 to Action.ProcessStart,
            30 to Action.Noop,
            40 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            50 to Action.Noop,
        )

        "kill-9-during-checkpoint" -> mapOf(
            0 to Action.Noop,
            5 to Action.ProcessDeath,
            15 to Action.ProcessStart,
            25 to Action.Noop,
            35 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            45 to Action.Noop,
        )

        "planned-restart-helper-failure" -> mapOf(
            0 to Action.Noop,
            5 to Action.Noop,
            15 to Action.Apply(ControllerSignal.PlannedRestartRequested),
            25 to Action.Apply(
                ControllerSignal.FailureRaised(
                    ControllerFailure.HOST_DEFECT,
                    "the terminal settlement line could not be persisted",
                ),
            ),
            35 to Action.Noop,
            45 to Action.Noop,
        )

        "planned-restart-reconciles-pending-step" -> mapOf(
            0 to Action.Noop,
            5 to Action.Apply(ControllerSignal.PlannedRestartRequested),
            15 to Action.Noop,
            25 to Action.Noop,
            35 to Action.Noop,
            45 to Action.Noop,
            55 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
        )

        "power-loss-torn-tail" -> mapOf(
            0 to Action.Noop,
            5 to Action.ProcessDeath,
            15 to Action.ProcessStart,
            25 to Action.Noop,
            35 to Action.Noop,
            45 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            55 to Action.Noop,
        )

        "renderer-terminated-during-exec",
        "renderer-terminated-orphan-abandoned",
        "renderer-terminated-reconciled-on-write-open",
        -> mapOf(
            0 to Action.Noop,
            10 to Action.Apply(
                ControllerSignal.EngineStateChanged(
                    EngineHostState.TERMINATED,
                    wasForeground = true,
                ),
            ),
            20 to Action.Noop,
            30 to Action.Noop,
            40 to Action.Noop,
            50 to Action.Noop,
            60 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
        )

        "sigterm-runner-guard" -> mapOf(
            0 to Action.Noop,
            5 to Action.Noop,
            10 to Action.Noop,
            15 to Action.Noop,
        )

        "stop-seal-failure" -> mapOf(
            0 to Action.Noop,
            5 to Action.Apply(
                ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND),
            ),
            10 to Action.Noop,
            15 to Action.Noop,
            25 to Action.Noop,
            35 to Action.Noop,
        )

        "system-reclaim-host-killed" -> mapOf(
            0 to Action.Noop,
            10 to Action.ProcessDeath,
            20 to Action.ProcessStart,
            30 to Action.Noop,
            40 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            50 to Action.Noop,
        )

        "write-without-ack" -> mapOf(
            0 to Action.Noop,
            5 to Action.Noop,
            15 to Action.ProcessStart,
            25 to Action.Noop,
            35 to Action.Apply(ControllerSignal.LeaseCheckResult(verified = true)),
            45 to Action.Noop,
        )

        else -> error("no driver action table for fixture ${fixture.id}")
    }

    private fun assertSubsequence(
        context: String,
        needle: List<String>,
        haystack: List<String>,
    ) {
        var matched = 0
        haystack.forEach { value ->
            if (matched < needle.size && needle[matched] == value) matched++
        }
        assertEquals(
            "$context $needle is not a subsequence of $haystack",
            needle.size,
            matched,
        )
    }
}
