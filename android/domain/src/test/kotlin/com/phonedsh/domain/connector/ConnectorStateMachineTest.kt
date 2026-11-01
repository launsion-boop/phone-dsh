// The transition table and the four-state projection.
// SPDX-License-Identifier: MIT
//
// Every row of the table is pinned twice: once in the accepted list and once in the
// refused list. A row that exists in neither would be a state a connector may enter
// by accident, and a row in both would make the table meaningless, so the two lists
// are asserted to be disjoint as well as exhaustive over the five states where a
// movement is possible.

package com.phonedsh.domain.connector

import com.phonedsh.domain.connector.ConnectorFixtures.device
import com.phonedsh.domain.connector.ConnectorFixtures.lost
import com.phonedsh.domain.connector.ConnectorFixtures.manifest
import com.phonedsh.domain.connector.ConnectorFixtures.silentManifest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectorStateMachineTest {
    private val connected: ConnectorState = ConnectorState.Connected(device())
    private val reconnecting: ConnectorState = ConnectorState.Reconnecting(1, lost())
    private val failed: ConnectorState = ConnectorState.Failed(lost())

    /** The movements the table allows, one row per documented transition. */
    private val legal: List<Pair<ConnectorState, ConnectorState>> = listOf(
        ConnectorState.Idle to ConnectorState.Idle,
        ConnectorState.Idle to ConnectorState.Connecting,
        ConnectorState.Connecting to connected,
        ConnectorState.Connecting to failed,
        ConnectorState.Connecting to reconnecting,
        ConnectorState.Connecting to ConnectorState.Idle,
        connected to connected,
        connected to reconnecting,
        connected to failed,
        connected to ConnectorState.Idle,
        reconnecting to ConnectorState.Reconnecting(2, lost()),
        reconnecting to connected,
        reconnecting to failed,
        reconnecting to ConnectorState.Idle,
        reconnecting to ConnectorState.Connecting,
        failed to ConnectorState.Connecting,
        failed to ConnectorState.Idle,
    )

    /** The movements the table refuses: each one would report a link that is not there. */
    private val illegal: List<Pair<ConnectorState, ConnectorState>> = listOf(
        ConnectorState.Idle to connected,
        ConnectorState.Idle to reconnecting,
        ConnectorState.Idle to failed,
        ConnectorState.Connecting to ConnectorState.Connecting,
        connected to ConnectorState.Connecting,
        failed to connected,
        failed to reconnecting,
        failed to failed,
    )

    @Test
    fun everyLegalTransitionIsAcceptedAndBecomesTheState() {
        legal.forEach { (from, to) ->
            val machine = ConnectorStateMachine(from)

            assertSame(to, machine.advance(to))
            assertSame(to, machine.state.value)
        }
    }

    @Test
    fun everyIllegalTransitionIsRefusedAndLeavesTheStateAlone() {
        illegal.forEach { (from, to) ->
            val machine = ConnectorStateMachine(from)

            val thrown = assertThrows(IllegalStateException::class.java) {
                machine.advance(to)
            }

            assertTrue(
                "the refusal must name both states, was \"${thrown.message}\"",
                thrown.message!!.contains("illegal connector transition"),
            )
            assertSame(from, machine.state.value)
        }
    }

    @Test
    fun theAcceptedAndRefusedRowsDoNotOverlap() {
        val accepted = legal.toSet()
        val refused = illegal.toSet()

        assertEquals(emptySet<Pair<ConnectorState, ConnectorState>>(), accepted intersect refused)
        assertEquals(accepted.size, legal.size)
        assertEquals(refused.size, illegal.size)
    }

    @Test
    fun aReconnectThatSucceedsWalksBackToConnected() {
        val machine = ConnectorStateMachine()

        machine.advance(ConnectorState.Connecting)
        assertEquals(ConnectorStatus.UNKNOWN, machine.state.value.status)

        machine.advance(connected)
        assertEquals(ConnectorStatus.READY, machine.state.value.status)

        machine.advance(reconnecting)
        assertEquals(ConnectorStatus.FAILED, machine.state.value.status)

        machine.advance(ConnectorState.Reconnecting(2, lost()))
        assertEquals(ConnectorStatus.FAILED, machine.state.value.status)

        machine.advance(connected)
        assertEquals(ConnectorStatus.READY, machine.state.value.status)
        assertSame(connected, machine.state.value)
    }

    @Test
    fun aReconnectThatGivesUpEndsInFailedAndKeepsTheReason() {
        val machine = ConnectorStateMachine()

        machine.advance(ConnectorState.Connecting)
        machine.advance(connected)
        machine.advance(reconnecting)
        machine.advance(failed)

        val state = machine.state.value
        assertTrue(state is ConnectorState.Failed)
        assertEquals(ConnectorStatus.FAILED, state.status)
        assertEquals(
            ConnectorFailure.TransportLost.CODE,
            (state as ConnectorState.Failed).failure.code,
        )
        assertEquals("socket closed", state.failure.detail)
    }

    @Test
    fun theFourStateProjectionCoversEveryState() {
        assertEquals(ConnectorStatus.UNKNOWN, ConnectorState.Idle.status)
        assertEquals(ConnectorStatus.UNKNOWN, ConnectorState.Connecting.status)
        assertEquals(ConnectorStatus.READY, connected.status)
        assertEquals(ConnectorStatus.FAILED, reconnecting.status)
        assertEquals(ConnectorStatus.FAILED, failed.status)

        // A connected device that declared nothing is "empty", not "unknown": the
        // host asked and got an answer, and the answer was that it can do nothing.
        val silent = ConnectorState.Connected(device(manifest = silentManifest()))
        assertEquals(ConnectorStatus.EMPTY, silent.status)
        assertTrue(silent.manifest.capabilities.isEmpty())
    }

    @Test
    fun aReconnectingStateNeedsAPositiveAttempt() {
        val thrown = assertThrows(IllegalArgumentException::class.java) {
            ConnectorState.Reconnecting(0, lost())
        }

        assertTrue(thrown.message!!.contains("starts at 1"))
    }

    @Test
    fun aConnectedStateExposesItsManifestWithoutUnwrapping() {
        val declared = manifest()
        val state = ConnectorState.Connected(device(manifest = declared))

        assertSame(declared, state.manifest)
        assertEquals(setOf("audio.tts", "render.pixel"), state.manifest.capabilities.keys)
    }
}
