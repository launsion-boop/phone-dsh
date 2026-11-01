// phone-dsh Android — :controller D14 transition matrix tests (budgets.md §2).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

import com.phonedsh.controller.ControllerEffect.ARM_DRAIN_DEADLINE
import com.phonedsh.controller.ControllerEffect.CANCEL_IN_FLIGHT_REQUESTS
import com.phonedsh.controller.ControllerEffect.CLOSE_ADMISSION
import com.phonedsh.controller.ControllerEffect.CLOSE_EPOCH
import com.phonedsh.controller.ControllerEffect.FORCE_DRAIN_DEADLINE
import com.phonedsh.controller.ControllerEffect.FREEZE_WAL_SEQ
import com.phonedsh.controller.ControllerEffect.FSYNC_MATERIALIZED
import com.phonedsh.controller.ControllerEffect.KEEP_DURABLE_BYTES
import com.phonedsh.controller.ControllerEffect.KEEP_WAL_READ_ONLY
import com.phonedsh.controller.ControllerEffect.LIMIT_SUB_AGENTS
import com.phonedsh.controller.ControllerEffect.NO_NEW_SUB_AGENTS
import com.phonedsh.controller.ControllerEffect.NO_OPTIONAL_ACCELERATORS
import com.phonedsh.controller.ControllerEffect.OPEN_ADMISSION
import com.phonedsh.controller.ControllerEffect.PAUSE_ACCELERATORS
import com.phonedsh.controller.ControllerEffect.POST_RECLAIM_TOKEN
import com.phonedsh.controller.ControllerEffect.RECORD_FAILURE
import com.phonedsh.controller.ControllerEffect.REMOTE_HOLDS_AUTHORITY
import com.phonedsh.controller.ControllerEffect.RESTART_WORKER
import com.phonedsh.controller.ControllerEffect.SEND_FENCE
import com.phonedsh.controller.ControllerEffect.SEND_LIFECYCLE_OPEN
import com.phonedsh.controller.ControllerEffect.START_BACKGROUND_TASK
import com.phonedsh.controller.ControllerEffect.START_RETRY_SCHEDULE
import com.phonedsh.controller.ControllerEffect.START_WORKER
import com.phonedsh.controller.ControllerEffect.STOP_WORKER
import com.phonedsh.controller.ControllerEffect.VERIFY_LEASE
import com.phonedsh.controller.ControllerSignal.BackgroundTaskExpired
import com.phonedsh.controller.ControllerSignal.BatteryChanged
import com.phonedsh.controller.ControllerSignal.DrainCompleted
import com.phonedsh.controller.ControllerSignal.DrainDeadlineElapsed
import com.phonedsh.controller.ControllerSignal.EngineStateChanged
import com.phonedsh.controller.ControllerSignal.FailureRaised
import com.phonedsh.controller.ControllerSignal.HandoffCompleted
import com.phonedsh.controller.ControllerSignal.HandoffFailed
import com.phonedsh.controller.ControllerSignal.HandoffFenceInstalled
import com.phonedsh.controller.ControllerSignal.HandoffRequested
import com.phonedsh.controller.ControllerSignal.LeaseCheckResult
import com.phonedsh.controller.ControllerSignal.NetworkPathChanged
import com.phonedsh.controller.ControllerSignal.PlannedRestartRequested
import com.phonedsh.controller.ControllerSignal.ReclaimCompleted
import com.phonedsh.controller.ControllerSignal.ReclaimRequested
import com.phonedsh.controller.ControllerSignal.ReclaimResponseApplied
import com.phonedsh.controller.ControllerSignal.RetryAfterElapsed
import com.phonedsh.controller.ControllerSignal.RetryProbeSucceeded
import com.phonedsh.controller.ControllerSignal.ScenePhaseChanged
import com.phonedsh.controller.ControllerSignal.ThermalStateChanged
import com.phonedsh.controller.ControllerSignal.UpstreamUnavailable
import com.phonedsh.controller.ControllerSignal.UserReset
import com.phonedsh.controller.HostState.BACKOFF
import com.phonedsh.controller.HostState.DRAINING
import com.phonedsh.controller.HostState.FAILED
import com.phonedsh.controller.HostState.HANDING_OFF
import com.phonedsh.controller.HostState.PARKED
import com.phonedsh.controller.HostState.RECLAIMING
import com.phonedsh.controller.HostState.RECOVERING
import com.phonedsh.controller.HostState.REMOTE
import com.phonedsh.controller.HostState.RUNNING
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransitionMatrixTest {

    // ---- boot ---------------------------------------------------------------------

    @Test
    fun `boot of a persisted Running Draining or Recovering host enters Recovering`() {
        listOf(RUNNING, DRAINING, RECOVERING).forEach { persisted ->
            val machine = ControllerStateMachine.boot(persisted)
            assertEquals("state", RECOVERING, machine.state)
            assertEquals("admission", Admission.CLOSED, machine.admission)
            assertEquals("disposition", BootDisposition.CRASH_RECOVERY, machine.bootDisposition)
            assertEquals("reason", "persisted_${persisted.wireName.lowercase()}", machine.bootReason)
            assertTrue("boot is not a transition", machine.transitions.isEmpty())
        }
    }

    @Test
    fun `boot without a persisted state is a cold recovery`() {
        val machine = ControllerStateMachine.boot(persistedState = null)
        assertEquals(RECOVERING, machine.state)
        assertEquals(Admission.CLOSED, machine.admission)
        assertEquals(BootDisposition.COLD_START, machine.bootDisposition)
        assertEquals("empty_workspace", machine.bootReason)
        assertTrue(machine.initialBoot.effects.contains(VERIFY_LEASE))
        assertTrue(machine.transitions.isEmpty())
    }

    @Test
    fun `boot with workspace history but no host state is a crash recovery`() {
        val machine = ControllerStateMachine.boot(
            persistedState = null,
            workspaceHasState = true,
        )
        assertEquals(RECOVERING, machine.state)
        assertEquals(BootDisposition.CRASH_RECOVERY, machine.bootDisposition)
        assertEquals("workspace_without_host_state", machine.bootReason)
    }

    @Test
    fun `boot of a persisted Failed host stays Failed`() {
        val machine = ControllerStateMachine.boot(FAILED)
        assertEquals(FAILED, machine.state)
        assertEquals(Admission.CLOSED, machine.admission)
        assertTrue(machine.initialBoot.effects.contains(RECORD_FAILURE))
        assertTrue(machine.initialBoot.effects.contains(KEEP_DURABLE_BYTES))

        val withCondition = ControllerStateMachine.boot(
            persistedState = FAILED,
            persistedFailure = ControllerFailure.WAL_CORRUPT,
            persistedFailureDetail = "crc at offset 12",
        )
        assertEquals(FAILED, withCondition.state)
        assertEquals(ControllerFailure.WAL_CORRUPT, withCondition.lastFailure)
        assertEquals("crc at offset 12", withCondition.lastFailureDetail)
    }

    @Test
    fun `boot of a persisted Parked Backoff or Remote host keeps the state`() {
        val parked = ControllerStateMachine.boot(PARKED)
        assertEquals(PARKED, parked.state)
        assertEquals(BootDisposition.PARKED_RESUME, parked.bootDisposition)
        assertEquals("persisted_parked", parked.bootReason)

        val backoff = ControllerStateMachine.boot(BACKOFF)
        assertEquals(BACKOFF, backoff.state)
        assertEquals(BootDisposition.CRASH_RECOVERY, backoff.bootDisposition)

        val remote = ControllerStateMachine.boot(REMOTE)
        assertEquals(REMOTE, remote.state)
        assertTrue(remote.initialBoot.effects.contains(KEEP_WAL_READ_ONLY))
    }

    @Test
    fun `boot of a persisted Reclaiming host re-enters Recovering`() {
        val machine = ControllerStateMachine.boot(RECLAIMING)
        assertEquals(RECOVERING, machine.state)
        assertEquals(BootDisposition.CRASH_RECOVERY, machine.bootDisposition)
    }

    @Test
    fun `boot of a persisted HandingOff host fails loud`() {
        val machine = ControllerStateMachine.boot(HANDING_OFF)
        assertEquals(FAILED, machine.state)
        assertEquals(Admission.CLOSED, machine.admission)
        assertEquals(BootDisposition.CRASH_RECOVERY, machine.bootDisposition)
    }

    // ---- scene phase and drain ----------------------------------------------------

    @Test
    fun `Running to Draining on background closes admission and arms the 20 s deadline`() {
        val machine = TestMachines.running()
        val record = TestMachines.assertTransition(
            machine,
            ScenePhaseChanged(ScenePhase.BACKGROUND),
            atMillis = 1_000,
            expectedTo = DRAINING,
        )
        assertEquals(Admission.CLOSED, record.admission)
        assertTrue(record.effects.contains(CLOSE_ADMISSION))
        assertTrue(record.effects.contains(ARM_DRAIN_DEADLINE))
        assertTrue(record.effects.contains(START_BACKGROUND_TASK))
        assertEquals(1_000L, machine.drainStartedAtMillis)
        assertEquals(21_000L, machine.drainDeadlineAtMillis)
        assertFalse(machine.drainDeadlineForced)
    }

    @Test
    fun `Draining to Parked on drain completion closes the epoch exactly once`() {
        val machine = TestMachines.at(DRAINING)
        val record = TestMachines.assertTransition(
            machine,
            DrainCompleted,
            atMillis = 500,
            expectedTo = PARKED,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertTrue(record.effects.contains(FSYNC_MATERIALIZED))
        assertTrue(record.effects.contains(STOP_WORKER))
        assertEquals(Admission.CLOSED, machine.admission)
        assertNull(machine.drainDeadlineAtMillis)
    }

    @Test
    fun `Draining to Recovering on a planned restart`() {
        val machine = TestMachines.at(DRAINING)
        val record = TestMachines.assertTransition(
            machine,
            PlannedRestartRequested,
            atMillis = 100,
            expectedTo = RECOVERING,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertTrue(record.effects.contains(RESTART_WORKER))
        assertEquals(Admission.CLOSED, machine.admission)
    }

    @Test
    fun `Draining to Recovering on an engine termination`() {
        val machine = TestMachines.at(DRAINING)
        val record = TestMachines.assertTransition(
            machine,
            EngineStateChanged(EngineHostState.TERMINATED, wasForeground = false),
            atMillis = 100,
            expectedTo = RECOVERING,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
    }

    @Test
    fun `Parked to Recovering on scenePhase active keeps admission closed`() {
        val machine = ControllerStateMachine.boot(PARKED)
        val record = TestMachines.assertTransition(
            machine,
            ScenePhaseChanged(ScenePhase.ACTIVE),
            atMillis = 100,
            expectedTo = RECOVERING,
        )
        assertEquals(Admission.CLOSED, record.admission)
        assertTrue(record.effects.contains(START_WORKER))
        assertTrue(record.effects.contains(VERIFY_LEASE))
        assertEquals("parked_resume", record.reason)
    }

    @Test
    fun `Running to Recovering on a planned restart closes the epoch`() {
        val machine = TestMachines.running()
        val record = TestMachines.assertTransition(
            machine,
            PlannedRestartRequested,
            atMillis = 100,
            expectedTo = RECOVERING,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertTrue(record.effects.contains(CLOSE_ADMISSION))
        assertTrue(record.effects.contains(RESTART_WORKER))
    }

    @Test
    fun `Running to Recovering on a foreground engine termination`() {
        val machine = TestMachines.running()
        val record = TestMachines.assertTransition(
            machine,
            EngineStateChanged(EngineHostState.TERMINATED, wasForeground = true),
            atMillis = 100,
            expectedTo = RECOVERING,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertEquals(Admission.CLOSED, machine.admission)
    }

    @Test
    fun `Recovering to Running on a verified lease opens admission`() {
        val machine = ControllerStateMachine.boot(persistedState = null)
        val record = TestMachines.assertTransition(
            machine,
            LeaseCheckResult(verified = true),
            atMillis = 100,
            expectedTo = RUNNING,
        )
        assertEquals(Admission.OPEN, record.admission)
        assertTrue(record.effects.contains(OPEN_ADMISSION))
        assertTrue(record.effects.contains(SEND_FENCE))
        assertTrue(record.effects.contains(SEND_LIFECYCLE_OPEN))
    }

    @Test
    fun `drain deadline before twenty seconds is rejected and leaves Draining`() {
        val machine = TestMachines.at(DRAINING)
        TestMachines.assertRejected(
            machine,
            DrainDeadlineElapsed,
            atMillis = 19_999,
            expectedReason = RejectionReason.DEADLINE_NOT_REACHED,
        )
        assertEquals(DRAINING, machine.state)
        assertFalse(machine.drainDeadlineForced)
    }

    @Test
    fun `drain deadline forces the close but parks only when the epoch close completes`() {
        val machine = TestMachines.at(DRAINING)
        val observed = TestMachines.observed(
            machine.handle(DrainDeadlineElapsed, atMillis = 20_000),
            "drain deadline",
        )
        assertTrue(observed.effects.contains(FORCE_DRAIN_DEADLINE))
        assertTrue(observed.effects.contains(CANCEL_IN_FLIGHT_REQUESTS))
        assertEquals("the deadline itself is not a transition", DRAINING, machine.state)
        assertTrue(machine.drainDeadlineForced)

        // FORCE is emitted once per Draining entry: a repeated deadline is a
        // no-op, not a second cancel for the facade to de-duplicate.
        val duplicate = TestMachines.observed(
            machine.handle(DrainDeadlineElapsed, atMillis = 20_001),
            "duplicate deadline",
        )
        assertTrue("a duplicate deadline must not re-emit FORCE", duplicate.effects.isEmpty())
        assertEquals(DRAINING, machine.state)

        val record = TestMachines.assertTransition(
            machine,
            DrainCompleted,
            atMillis = 20_010,
            expectedTo = PARKED,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertEquals(1, TestMachines.allEffects(machine).count { it == CLOSE_EPOCH })
    }

    @Test
    fun `background task expiry forces the deadline without closing the epoch`() {
        val machine = TestMachines.at(DRAINING)
        val observed = TestMachines.observed(
            machine.handle(BackgroundTaskExpired, atMillis = 1_200),
            "background task expiry",
        )
        assertTrue(observed.effects.contains(FORCE_DRAIN_DEADLINE))
        assertTrue(observed.effects.contains(CANCEL_IN_FLIGHT_REQUESTS))
        assertEquals(DRAINING, machine.state)
        assertTrue(machine.drainDeadlineForced)

        // The drain emits FORCE/CANCEL once: the expiry already forced it, so a
        // duplicate force signal is a no-op instead of a second cancel for the
        // facade to de-duplicate.
        val earlyDeadline = TestMachines.observed(
            machine.handle(DrainDeadlineElapsed, atMillis = 1_205),
            "duplicate deadline",
        )
        assertTrue("a duplicate deadline must not re-emit FORCE", earlyDeadline.effects.isEmpty())
        assertEquals(DRAINING, machine.state)

        val secondExpiry = TestMachines.observed(
            machine.handle(BackgroundTaskExpired, atMillis = 1_206),
            "duplicate expiry",
        )
        assertTrue("a duplicate expiry must not re-emit FORCE", secondExpiry.effects.isEmpty())
        assertEquals(DRAINING, machine.state)

        val record = TestMachines.assertTransition(
            machine,
            DrainCompleted,
            atMillis = 1_210,
            expectedTo = PARKED,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertEquals(1, TestMachines.allEffects(machine).count { it == CLOSE_EPOCH })
    }

    // ---- backoff ------------------------------------------------------------------

    @Test
    fun `Running to Backoff on an unsatisfied network path`() {
        val machine = TestMachines.running()
        val record = TestMachines.assertTransition(
            machine,
            NetworkPathChanged(NetworkPathStatus.UNSATISFIED),
            atMillis = 100,
            expectedTo = BACKOFF,
        )
        assertTrue(record.effects.contains(START_RETRY_SCHEDULE))
        assertEquals(Admission.CLOSED, machine.admission)
    }

    @Test
    fun `a satisfied network path while Running is an observation`() {
        val machine = TestMachines.running()
        val sizeBefore = machine.transitions.size
        val observed = TestMachines.observed(
            machine.handle(NetworkPathChanged(NetworkPathStatus.SATISFIED), 100),
        )
        assertTrue(observed.effects.isEmpty())
        assertEquals(RUNNING, machine.state)
        assertEquals(sizeBefore, machine.transitions.size)
    }

    @Test
    fun `Running to Backoff on 429 and 5xx only`() {
        listOf(429, 500, 503, 599).forEach { status ->
            val machine = TestMachines.running()
            TestMachines.assertTransition(
                machine,
                UpstreamUnavailable(status),
                atMillis = 100,
                expectedTo = BACKOFF,
            )
        }
        listOf(400, 404, 600).forEach { status ->
            val machine = TestMachines.running()
            val rejection = TestMachines.assertRejected(
                machine,
                UpstreamUnavailable(status),
                atMillis = 100,
                expectedReason = RejectionReason.GUARD_FAILED,
            )
            assertTrue(rejection.detail.contains(status.toString()))
        }
    }

    @Test
    fun `Backoff to Running requires Retry-After a satisfied path and a probe`() {
        val machine = TestMachines.at(BACKOFF)

        TestMachines.assertRejected(
            machine,
            RetryProbeSucceeded(leaseVerified = true),
            atMillis = 100,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.observed(
            machine.handle(NetworkPathChanged(NetworkPathStatus.SATISFIED), 200),
            "satisfied path",
        )
        TestMachines.assertRejected(
            machine,
            RetryProbeSucceeded(leaseVerified = true),
            atMillis = 300,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.observed(machine.handle(RetryAfterElapsed, 400), "Retry-After")
        TestMachines.assertRejected(
            machine,
            RetryProbeSucceeded(leaseVerified = false),
            atMillis = 500,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        assertEquals("every guard failure keeps Backoff", BACKOFF, machine.state)
        assertEquals("every guard failure keeps admission closed", Admission.CLOSED, machine.admission)

        val record = TestMachines.assertTransition(
            machine,
            RetryProbeSucceeded(leaseVerified = true),
            atMillis = 600,
            expectedTo = RUNNING,
        )
        assertEquals(Admission.OPEN, record.admission)
        assertTrue(record.effects.contains(OPEN_ADMISSION))
    }

    // ---- handoff and reclaim ------------------------------------------------------

    @Test
    fun `Running to HandingOff closes the epoch and freezes wal_seq`() {
        val machine = TestMachines.running()
        val record = TestMachines.assertTransition(
            machine,
            HandoffRequested,
            atMillis = 100,
            expectedTo = HANDING_OFF,
        )
        assertTrue(record.effects.contains(CLOSE_EPOCH))
        assertTrue(record.effects.contains(FREEZE_WAL_SEQ))
        assertEquals(Admission.CLOSED, machine.admission)
        assertFalse(machine.isFenceInstalled)
    }

    @Test
    fun `Draining to HandingOff finishes the epoch close`() {
        val machine = TestMachines.at(DRAINING)
        val record = TestMachines.assertTransition(
            machine,
            HandoffRequested,
            atMillis = 100,
            expectedTo = HANDING_OFF,
        )
        assertEquals(1, record.effects.count { it == CLOSE_EPOCH })
        assertTrue(record.effects.contains(FREEZE_WAL_SEQ))
    }

    @Test
    fun `HandingOff to Remote needs the fence and an open remote admission`() {
        val machine = TestMachines.at(HANDING_OFF)

        TestMachines.assertRejected(
            machine,
            HandoffCompleted(remoteAdmissionOpen = true),
            atMillis = 100,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.observed(machine.handle(HandoffFenceInstalled, 200), "fence installed")
        TestMachines.assertRejected(
            machine,
            HandoffCompleted(remoteAdmissionOpen = false),
            atMillis = 300,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        val record = TestMachines.assertTransition(
            machine,
            HandoffCompleted(remoteAdmissionOpen = true),
            atMillis = 400,
            expectedTo = REMOTE,
        )
        assertTrue(record.effects.contains(REMOTE_HOLDS_AUTHORITY))
        assertTrue(record.effects.contains(KEEP_WAL_READ_ONLY))
        assertEquals(Admission.CLOSED, machine.admission)
    }

    @Test
    fun `HandingOff to Reclaiming only after a successful fence`() {
        val machine = TestMachines.at(HANDING_OFF)
        TestMachines.assertRejected(
            machine,
            HandoffFailed,
            atMillis = 100,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.observed(machine.handle(HandoffFenceInstalled, 200), "fence installed")
        val record = TestMachines.assertTransition(
            machine,
            HandoffFailed,
            atMillis = 300,
            expectedTo = RECLAIMING,
        )
        assertTrue(record.effects.contains(POST_RECLAIM_TOKEN))
    }

    @Test
    fun `Remote to Reclaiming keeps the WAL read-only`() {
        val machine = TestMachines.at(REMOTE)
        val record = TestMachines.assertTransition(
            machine,
            ReclaimRequested,
            atMillis = 100,
            expectedTo = RECLAIMING,
        )
        assertTrue(record.effects.contains(POST_RECLAIM_TOKEN))
        assertEquals(Admission.CLOSED, machine.admission)
    }

    @Test
    fun `Reclaiming to Recovering requires response fence and epoch`() {
        val machine = TestMachines.at(RECLAIMING)
        TestMachines.assertRejected(
            machine,
            ReclaimCompleted(fencePersisted = true, epochClosed = true),
            atMillis = 100,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.observed(machine.handle(ReclaimResponseApplied, 200), "response applied")
        TestMachines.assertRejected(
            machine,
            ReclaimCompleted(fencePersisted = false, epochClosed = true),
            atMillis = 300,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        TestMachines.assertRejected(
            machine,
            ReclaimCompleted(fencePersisted = true, epochClosed = false),
            atMillis = 400,
            expectedReason = RejectionReason.GUARD_FAILED,
        )
        val record = TestMachines.assertTransition(
            machine,
            ReclaimCompleted(fencePersisted = true, epochClosed = true),
            atMillis = 500,
            expectedTo = RECOVERING,
        )
        assertEquals(Admission.CLOSED, record.admission)
        assertTrue(record.effects.contains(VERIFY_LEASE))
        assertEquals("Recovering keeps admission closed", Admission.CLOSED, machine.admission)

        TestMachines.assertTransition(
            machine,
            LeaseCheckResult(verified = true),
            atMillis = 600,
            expectedTo = RUNNING,
        )
        assertEquals(Admission.OPEN, machine.admission)
    }

    // ---- failure and reset --------------------------------------------------------

    @Test
    fun `any state to Failed fails loud and keeps admission closed`() {
        HostState.entries.filter { it != FAILED }.forEach { from ->
            val machine = TestMachines.at(from)
            val record = TestMachines.assertTransition(
                machine,
                FailureRaised(ControllerFailure.WAL_CORRUPT, "crc at offset 12"),
                atMillis = 100,
                expectedTo = FAILED,
            )
            assertEquals("admission from $from", Admission.CLOSED, record.admission)
            assertTrue(record.effects.contains(RECORD_FAILURE))
            assertTrue(record.effects.contains(KEEP_DURABLE_BYTES))
            assertEquals(ControllerFailure.WAL_CORRUPT, machine.lastFailure)
            assertEquals("crc at offset 12", machine.lastFailureDetail)
        }
    }

    @Test
    fun `a Failed host keeps its first failure and cannot be failed twice`() {
        val machine = TestMachines.at(FAILED)
        val sizeBefore = machine.transitions.size
        val observed = TestMachines.observed(
            machine.handle(FailureRaised(ControllerFailure.QUOTA_EXCEEDED), 100),
            "second failure",
        )
        assertTrue(observed.effects.isEmpty())
        assertEquals(FAILED, machine.state)
        assertEquals(ControllerFailure.HOST_DEFECT, machine.lastFailure)
        assertEquals(sizeBefore, machine.transitions.size)
    }

    @Test
    fun `Failed to Recovering only on an explicit user reset`() {
        val machine = TestMachines.at(FAILED)
        TestMachines.assertRejected(
            machine,
            LeaseCheckResult(verified = true),
            atMillis = 100,
            expectedReason = RejectionReason.ILLEGAL_TRANSITION,
        )
        TestMachines.assertRejected(
            machine,
            DrainCompleted,
            atMillis = 110,
            expectedReason = RejectionReason.ILLEGAL_TRANSITION,
        )
        val record = TestMachines.assertTransition(
            machine,
            UserReset,
            atMillis = 200,
            expectedTo = RECOVERING,
        )
        assertNull(machine.lastFailure)
        assertEquals(BootDisposition.USER_RESET, machine.bootDisposition)
        assertEquals("explicit_user_reset", machine.bootReason)
        assertEquals("user_reset", record.reason)
        assertEquals(Admission.CLOSED, machine.admission)

        TestMachines.assertTransition(
            machine,
            LeaseCheckResult(verified = true),
            atMillis = 300,
            expectedTo = RUNNING,
        )
    }

    // ---- policy observations ------------------------------------------------------

    @Test
    fun `thermal and battery observations never transition`() {
        val machine = TestMachines.running()
        val sizeBefore = machine.transitions.size

        val fair = TestMachines.observed(machine.handle(ThermalStateChanged(ThermalPressure.FAIR), 100))
        assertEquals(listOf(LIMIT_SUB_AGENTS), fair.effects)
        assertEquals(ThermalPressure.FAIR, machine.thermalPressure)

        val serious = TestMachines.observed(machine.handle(ThermalStateChanged(ThermalPressure.SERIOUS), 200))
        assertEquals(listOf(NO_NEW_SUB_AGENTS, PAUSE_ACCELERATORS), serious.effects)

        val lowBattery = TestMachines.observed(
            machine.handle(
                BatteryChanged(BatterySnapshot(levelPercent = 15, charging = false, lowPowerMode = false)),
                300,
            ),
        )
        assertEquals(listOf(LIMIT_SUB_AGENTS, NO_OPTIONAL_ACCELERATORS), lowBattery.effects)

        val charging = TestMachines.observed(
            machine.handle(
                BatteryChanged(BatterySnapshot(levelPercent = 15, charging = true, lowPowerMode = false)),
                400,
            ),
        )
        assertTrue(charging.effects.isEmpty())

        val nominal = TestMachines.observed(machine.handle(ThermalStateChanged(ThermalPressure.NOMINAL), 500))
        assertTrue(nominal.effects.isEmpty())

        assertEquals(RUNNING, machine.state)
        assertEquals(Admission.OPEN, machine.admission)
        assertEquals(sizeBefore, machine.transitions.size)
    }

    @Test
    fun `a non-terminal engine state is an observation`() {
        val machine = TestMachines.running()
        val sizeBefore = machine.transitions.size
        val observed = TestMachines.observed(
            machine.handle(EngineStateChanged(EngineHostState.READY, wasForeground = true), 100),
        )
        assertTrue(observed.effects.isEmpty())
        assertEquals(RUNNING, machine.state)
        assertEquals(sizeBefore, machine.transitions.size)
    }

    // ---- the closed set: unlisted transitions are rejected ------------------------

    @Test
    fun `unlisted transitions are rejected without changing state or admission`() {
        val cases = listOf(
            RejectedCase("Running + drain complete", RUNNING, DrainCompleted),
            RejectedCase("Running + background expiry", RUNNING, BackgroundTaskExpired),
            RejectedCase("Running + lease check", RUNNING, LeaseCheckResult(true)),
            RejectedCase("Running + reclaim request", RUNNING, ReclaimRequested),
            RejectedCase("Running + user reset", RUNNING, UserReset),
            RejectedCase("Running + handoff completion", RUNNING, HandoffCompleted(true)),
            RejectedCase("Running + reclaim completion", RUNNING, ReclaimCompleted(true, true)),
            RejectedCase("Running + retry probe", RUNNING, RetryProbeSucceeded(true)),
            RejectedCase(
                "Running + 400",
                RUNNING,
                UpstreamUnavailable(400),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase(
                "Running + 404",
                RUNNING,
                UpstreamUnavailable(404),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase(
                "Running + background engine termination",
                RUNNING,
                EngineStateChanged(EngineHostState.TERMINATED, wasForeground = false),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase(
                "Running + requiresConnection",
                RUNNING,
                NetworkPathChanged(NetworkPathStatus.REQUIRES_CONNECTION),
            ),
            RejectedCase("Draining + active", DRAINING, ScenePhaseChanged(ScenePhase.ACTIVE)),
            RejectedCase("Draining + lease check", DRAINING, LeaseCheckResult(true)),
            RejectedCase(
                "Draining + early deadline",
                DRAINING,
                DrainDeadlineElapsed,
                RejectionReason.DEADLINE_NOT_REACHED,
                atMillis = 100,
            ),
            RejectedCase("Draining + handoff completion", DRAINING, HandoffCompleted(true)),
            RejectedCase("Draining + reclaim request", DRAINING, ReclaimRequested),
            RejectedCase("Draining + user reset", DRAINING, UserReset),
            RejectedCase("Parked + background", PARKED, ScenePhaseChanged(ScenePhase.BACKGROUND)),
            RejectedCase("Parked never opens admission directly", PARKED, LeaseCheckResult(true)),
            RejectedCase("Parked + drain complete", PARKED, DrainCompleted),
            RejectedCase("Parked + planned restart", PARKED, PlannedRestartRequested),
            RejectedCase("Recovering + background", RECOVERING, ScenePhaseChanged(ScenePhase.BACKGROUND)),
            RejectedCase("Recovering + drain complete", RECOVERING, DrainCompleted),
            RejectedCase("Recovering + reclaim request", RECOVERING, ReclaimRequested),
            RejectedCase("Recovering + user reset", RECOVERING, UserReset),
            RejectedCase(
                "Recovering + failed lease keeps admission closed",
                RECOVERING,
                LeaseCheckResult(false),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase("Backoff + drain complete", BACKOFF, DrainCompleted),
            RejectedCase("Backoff + handoff request", BACKOFF, HandoffRequested),
            RejectedCase("Backoff + lease check", BACKOFF, LeaseCheckResult(true)),
            RejectedCase(
                "Backoff + probe without guards",
                BACKOFF,
                RetryProbeSucceeded(true),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase("Backoff + 503", BACKOFF, UpstreamUnavailable(503)),
            RejectedCase(
                "HandingOff + completion without fence",
                HANDING_OFF,
                HandoffCompleted(true),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase(
                "HandingOff + failure without fence",
                HANDING_OFF,
                HandoffFailed,
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase("HandingOff + reclaim request", HANDING_OFF, ReclaimRequested),
            RejectedCase("HandingOff + handoff request", HANDING_OFF, HandoffRequested),
            RejectedCase("HandingOff + drain complete", HANDING_OFF, DrainCompleted),
            RejectedCase("Remote + handoff request", REMOTE, HandoffRequested),
            RejectedCase("Remote + active", REMOTE, ScenePhaseChanged(ScenePhase.ACTIVE)),
            RejectedCase("Remote + lease check", REMOTE, LeaseCheckResult(true)),
            RejectedCase("Remote + handoff completion", REMOTE, HandoffCompleted(true)),
            RejectedCase("Remote + drain complete", REMOTE, DrainCompleted),
            RejectedCase("Reclaiming + drain complete", RECLAIMING, DrainCompleted),
            RejectedCase(
                "Reclaiming + completion before response",
                RECLAIMING,
                ReclaimCompleted(true, true),
                RejectionReason.GUARD_FAILED,
            ),
            RejectedCase("Reclaiming + reclaim request", RECLAIMING, ReclaimRequested),
            RejectedCase("Failed + lease check", FAILED, LeaseCheckResult(true)),
            RejectedCase("Failed + drain complete", FAILED, DrainCompleted),
            RejectedCase("Failed + handoff request", FAILED, HandoffRequested),
        )

        assertTrue("the rejection matrix must exercise many rows", cases.size >= 6)
        cases.forEach { case ->
            val machine = TestMachines.at(case.from)
            val stateBefore = machine.state
            val admissionBefore = machine.admission
            val sizeBefore = machine.transitions.size
            val outcome = machine.handle(case.signal, case.atMillis)
            assertTrue(
                "${case.label}: expected a rejection, was $outcome",
                outcome is SignalOutcome.Rejected,
            )
            outcome as SignalOutcome.Rejected
            assertEquals("${case.label}: reason", case.reason, outcome.reason)
            assertEquals("${case.label}: state", stateBefore, machine.state)
            assertEquals("${case.label}: admission", admissionBefore, machine.admission)
            assertEquals("${case.label}: log", sizeBefore, machine.transitions.size)
            assertEquals("${case.label}: rejected from", stateBefore, outcome.from)
        }
    }

    private data class RejectedCase(
        val label: String,
        val from: HostState,
        val signal: ControllerSignal,
        val reason: RejectionReason = RejectionReason.ILLEGAL_TRANSITION,
        val atMillis: Long = 100,
    )
}
