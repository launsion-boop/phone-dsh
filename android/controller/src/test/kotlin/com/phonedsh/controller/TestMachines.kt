// phone-dsh Android — :controller test helpers for the D14 state machine.
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/** Builds a machine in any of the nine D14 states using only public edges. */
internal object TestMachines {

    fun running(): ControllerStateMachine {
        val machine = ControllerStateMachine.boot(persistedState = null)
        val outcome = machine.handle(
            ControllerSignal.LeaseCheckResult(verified = true),
            atMillis = 0,
        )
        assertTrue("boot -> Recovering -> Running failed: $outcome", outcome is SignalOutcome.Transitioned)
        return machine
    }

    fun at(state: HostState): ControllerStateMachine = when (state) {
        HostState.RUNNING -> running()
        HostState.RECOVERING -> ControllerStateMachine.boot(persistedState = null)
        HostState.PARKED -> ControllerStateMachine.boot(persistedState = HostState.PARKED)
        HostState.DRAINING -> running().also {
            assertTrue(
                it.handle(
                    ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND),
                    atMillis = 0,
                ) is SignalOutcome.Transitioned,
            )
        }

        HostState.BACKOFF -> running().also {
            assertTrue(
                it.handle(
                    ControllerSignal.NetworkPathChanged(NetworkPathStatus.UNSATISFIED),
                    atMillis = 0,
                ) is SignalOutcome.Transitioned,
            )
        }

        HostState.HANDING_OFF -> running().also {
            assertTrue(
                it.handle(ControllerSignal.HandoffRequested, atMillis = 0) is SignalOutcome.Transitioned,
            )
        }

        HostState.REMOTE -> at(HostState.HANDING_OFF).also {
            assertTrue(
                it.handle(ControllerSignal.HandoffFenceInstalled, atMillis = 0) is SignalOutcome.Observed,
            )
            assertTrue(
                it.handle(ControllerSignal.HandoffCompleted(true), atMillis = 0) is SignalOutcome.Transitioned,
            )
        }

        HostState.RECLAIMING -> at(HostState.REMOTE).also {
            assertTrue(
                it.handle(ControllerSignal.ReclaimRequested, atMillis = 0) is SignalOutcome.Transitioned,
            )
        }

        HostState.FAILED -> running().also {
            assertTrue(
                it.handle(
                    ControllerSignal.FailureRaised(ControllerFailure.HOST_DEFECT),
                    atMillis = 0,
                ) is SignalOutcome.Transitioned,
            )
        }
    }

    fun transitioned(outcome: SignalOutcome, context: String = ""): TransitionRecord {
        assertTrue("$context expected a transition, was $outcome", outcome is SignalOutcome.Transitioned)
        return (outcome as SignalOutcome.Transitioned).record
    }

    fun observed(outcome: SignalOutcome, context: String = ""): SignalOutcome.Observed {
        assertTrue("$context expected an observation, was $outcome", outcome is SignalOutcome.Observed)
        return outcome as SignalOutcome.Observed
    }

    fun rejected(outcome: SignalOutcome, context: String = ""): SignalOutcome.Rejected {
        assertTrue("$context expected a rejection, was $outcome", outcome is SignalOutcome.Rejected)
        return outcome as SignalOutcome.Rejected
    }

    fun assertTransition(
        machine: ControllerStateMachine,
        signal: ControllerSignal,
        atMillis: Long,
        expectedTo: HostState,
    ): TransitionRecord {
        val from = machine.state
        val sizeBefore = machine.transitions.size
        val record = transitioned(machine.handle(signal, atMillis), signal.label)
        assertEquals("from", from, record.from)
        assertEquals("to", expectedTo, record.to)
        assertEquals("state", expectedTo, machine.state)
        assertEquals("admission", expectedTo.admission, machine.admission)
        assertEquals("recorded admission", expectedTo.admission, record.admission)
        assertEquals("one transition appended", sizeBefore + 1, machine.transitions.size)
        assertEquals("last transition", record, machine.transitions.last())
        assertTrue(
            "every accepted transition persists host-state.json",
            record.effects.contains(ControllerEffect.PERSIST_HOST_STATE),
        )
        return record
    }

    fun assertRejected(
        machine: ControllerStateMachine,
        signal: ControllerSignal,
        atMillis: Long,
        expectedReason: RejectionReason,
    ): SignalOutcome.Rejected {
        val stateBefore = machine.state
        val admissionBefore = machine.admission
        val sizeBefore = machine.transitions.size
        val rejection = rejected(machine.handle(signal, atMillis), signal.label)
        assertEquals("rejection reason for ${signal.label}", expectedReason, rejection.reason)
        assertEquals("state after rejection", stateBefore, machine.state)
        assertEquals("admission after rejection", admissionBefore, machine.admission)
        assertEquals("transition log after rejection", sizeBefore, machine.transitions.size)
        assertEquals("rejected from", stateBefore, rejection.from)
        return rejection
    }

    fun allEffects(machine: ControllerStateMachine): List<ControllerEffect> =
        machine.transitions.flatMap { it.effects }
}
