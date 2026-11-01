// The in-memory connector: the round trip, the refusals and the reconnect.
// SPDX-License-Identifier: MIT
//
// The cases are ordered the way a page meets them: discover, connect, read the
// manifest, lose the link, reconnect, then the refusals (an unknown endpoint, a
// second connect while connected, a retry whose endpoint vanished).
//
// The round trip asserts instance identity on the manifest, not just equality. That
// is what proves the seam carries a decoded DeviceManifest rather than raw JSON
// that someone would have to parse again: the object the registry declared is the
// object the caller and the state stream both see.
//
// The last case implements the SPI in twenty lines outside this module's fake. It
// exists because a seam with one implementation is not a seam: it pins that
// DeviceConnector needs nothing that only InMemoryConnector has.

package com.phonedsh.domain.connector

import com.phonedsh.domain.connector.ConnectorFixtures.ENDPOINT
import com.phonedsh.domain.connector.ConnectorFixtures.SECOND_ENDPOINT
import com.phonedsh.domain.connector.ConnectorFixtures.UNKNOWN_ENDPOINT
import com.phonedsh.domain.connector.ConnectorFixtures.manifest
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemoryConnectorTest {
    @Test
    fun aRoundTripConnectsCarriesTheManifestDisconnectsAndReconnects() = runBlocking {
        val declared = manifest()
        val connector = InMemoryConnector().apply { addDevice(ENDPOINT, declared) }

        assertEquals(listOf(ENDPOINT), connector.discover())

        val first = connector.connect(ENDPOINT)
        assertSame(declared, first.manifest)
        assertSame(ENDPOINT, first.endpoint)
        assertEquals("esp32-8c4f01", first.deviceId)

        val live = connector.state.value
        assertTrue(live is ConnectorState.Connected)
        assertSame(first, (live as ConnectorState.Connected).device)
        // The state stream carries the same decoded manifest, with no second parse.
        assertSame(declared, live.manifest)
        assertEquals(ConnectorStatus.READY, live.status)

        connector.disconnect()
        assertEquals(ConnectorState.Idle, connector.state.value)
        assertEquals(ConnectorStatus.UNKNOWN, connector.state.value.status)

        val second = connector.connect(ENDPOINT)
        assertSame(declared, second.manifest)
        assertTrue(connector.state.value is ConnectorState.Connected)
        assertEquals(ConnectorStatus.READY, connector.state.value.status)
    }

    @Test
    fun aConnectionToAnUnknownEndpointFailsAndIsNotIdle() = runBlocking {
        val connector = InMemoryConnector()

        val thrown = connectorFailure { connector.connect(UNKNOWN_ENDPOINT) }

        assertEquals(ConnectorFailure.Unreachable.CODE, thrown.failure.code)
        assertTrue(thrown.failure is ConnectorFailure.Unreachable)
        assertSame(UNKNOWN_ENDPOINT, (thrown.failure as ConnectorFailure.Unreachable).endpoint)

        val state = connector.state.value
        assertTrue(
            "a failed connect must not fall back to Idle, was $state",
            state is ConnectorState.Failed,
        )
        assertSame(thrown.failure, (state as ConnectorState.Failed).failure)
        assertEquals(ConnectorStatus.FAILED, state.status)
        assertFalse(state == ConnectorState.Idle)
        assertTrue(thrown.message!!.startsWith(ConnectorFailure.Unreachable.CODE))
    }

    @Test
    fun discoveryFollowsTheRegistry() = runBlocking {
        val connector = InMemoryConnector(linkedMapOf(ENDPOINT to manifest("a")))
        assertEquals(listOf(ENDPOINT), connector.discover())

        connector.addDevice(SECOND_ENDPOINT, manifest("b"))
        assertEquals(listOf(ENDPOINT, SECOND_ENDPOINT), connector.discover())

        assertTrue(connector.removeDevice(ENDPOINT))
        assertFalse(connector.removeDevice(ENDPOINT))
        assertEquals(listOf(SECOND_ENDPOINT), connector.discover())
    }

    @Test
    fun aLostTransportIsRetriedBackToConnected() = runBlocking {
        val declared = manifest()
        val connector = InMemoryConnector().apply { addDevice(ENDPOINT, declared) }
        connector.connect(ENDPOINT)

        val lost = connector.loseTransport("socket closed")
        assertTrue(lost is ConnectorState.Reconnecting)
        assertEquals(1, (lost as ConnectorState.Reconnecting).attempt)
        assertEquals(ConnectorFailure.TransportLost.CODE, lost.lastFailure.code)
        assertEquals(ConnectorStatus.FAILED, lost.status)

        val recovered = connector.retry()
        assertSame(declared, recovered.manifest)
        assertTrue(connector.state.value is ConnectorState.Connected)
        assertEquals(ConnectorStatus.READY, connector.state.value.status)
    }

    @Test
    fun aRetryWhoseEndpointVanishedEndsInFailed() = runBlocking {
        val connector = InMemoryConnector().apply { addDevice(ENDPOINT, manifest()) }
        connector.connect(ENDPOINT)
        connector.loseTransport()
        connector.removeDevice(ENDPOINT)

        val thrown = connectorFailure { connector.retry() }

        assertEquals(ConnectorFailure.Unreachable.CODE, thrown.failure.code)
        val state = connector.state.value
        assertTrue(state is ConnectorState.Failed)
        assertEquals(ConnectorStatus.FAILED, state.status)
    }

    @Test
    fun aSecondConnectWhileConnectedIsRefusedAndKeepsTheLink() = runBlocking {
        val declared = manifest()
        val connector = InMemoryConnector().apply { addDevice(ENDPOINT, declared) }
        connector.connect(ENDPOINT)

        val refused = runCatching { connector.connect(SECOND_ENDPOINT) }.exceptionOrNull()

        assertTrue("a second connect must be refused, was $refused", refused is IllegalStateException)
        val state = connector.state.value
        assertTrue(state is ConnectorState.Connected)
        assertSame(declared, (state as ConnectorState.Connected).device.manifest)
    }

    @Test
    fun disconnectingWithoutAConnectionIsHarmless() = runBlocking {
        val connector = InMemoryConnector()

        connector.disconnect()
        connector.disconnect()

        assertEquals(ConnectorState.Idle, connector.state.value)
    }

    @Test
    fun aSecondImplementationNeedsNothingFromTheFake() = runBlocking {
        val connector = RejectingConnector()

        val thrown = connectorFailure { connector.connect(ENDPOINT) }

        assertEquals("CONNECTOR_REJECTED_NOT_PAIRED", thrown.failure.code)
        assertEquals(ConnectorStatus.FAILED, connector.state.value.status)

        connector.disconnect()
        assertEquals(ConnectorState.Idle, connector.state.value)
    }

    /** Runs [block] and returns the [ConnectorException] it must throw. */
    private suspend fun connectorFailure(block: suspend () -> Unit): ConnectorException {
        val thrown = runCatching { block() }.exceptionOrNull()
        return thrown as? ConnectorException
            ?: throw AssertionError("expected a ConnectorException, was $thrown")
    }

    /** A `DeviceConnector` written outside the fake, to prove the SPI is implementable. */
    private class RejectingConnector : DeviceConnector {
        private val machine = ConnectorStateMachine()

        override val state: StateFlow<ConnectorState>
            get() = machine.state

        override suspend fun connect(endpoint: Endpoint): ConnectedDevice {
            machine.advance(ConnectorState.Connecting)
            val failure = ConnectorFailure.Rejected(
                RejectionReason.NOT_PAIRED,
                "this device has no pairing record",
            )
            machine.advance(ConnectorState.Failed(failure))
            throw ConnectorException(failure)
        }

        override suspend fun disconnect() {
            machine.advance(ConnectorState.Idle)
        }
    }
}
