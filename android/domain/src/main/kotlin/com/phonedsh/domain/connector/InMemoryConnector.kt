// The in-memory implementation of the connector seam.
// SPDX-License-Identifier: MIT
//
// This class is in src/main on purpose, mirroring
// `com.phonedsh.domain.testing.InMemoryConnectionFactory` and
// `com.phonedsh.platform.testing.FakePlatform`: callers above `:domain` (a page, the
// app, a future grant check) must be able to test "what happens when a device
// connects" without a socket, and the module has no test-fixtures source set.
//
// It is a test double, not a backend: the device path is a real adapter, and this
// class never opens a transport. What it does give is a scriptable link — a registry
// of which endpoints exist, and two hooks ([loseTransport], [retry]) that move the
// connection through the states a real link reaches on its own. Those hooks are
// methods of this class, never members of `DeviceConnector`: the SPI carries nothing
// that only a fake needs, which is what keeps a second implementation honest.
//
// Everything is deterministic and single-threaded, so a test reads `state.value`
// after each call instead of collecting a stream with a timeout.

package com.phonedsh.domain.connector

import com.phonedsh.domain.device.DeviceManifest
import kotlinx.coroutines.flow.StateFlow

/**
 * A [DeviceConnector] over a fixed registry of endpoints.
 *
 * A registered endpoint always connects and always answers with the manifest it was
 * registered with; an unregistered one always fails with
 * [ConnectorFailure.Unreachable]. Re-registering an endpoint replaces its manifest,
 * which is how a test scripts "the device reconnected with new capabilities".
 *
 * Use one instance from one coroutine at a time. The state stream itself is safe to
 * collect from anywhere.
 *
 * @param devices the endpoints that answer, in the order they should be discovered.
 */
class InMemoryConnector(
    devices: Map<Endpoint, DeviceManifest> = emptyMap(),
) : DeviceConnector, Discoverer {
    private val registry = LinkedHashMap<Endpoint, DeviceManifest>(devices)
    private val machine = ConnectorStateMachine()
    private var live: ConnectedDevice? = null

    override val state: StateFlow<ConnectorState>
        get() = machine.state

    /** The endpoints that answer, in registration order. */
    override suspend fun discover(): List<Endpoint> = registry.keys.toList()

    /** Registers [endpoint], replacing any manifest it had. */
    fun addDevice(endpoint: Endpoint, manifest: DeviceManifest) {
        registry[endpoint] = manifest
    }

    /**
     * Stops [endpoint] from answering.
     *
     * @return whether it was registered.
     */
    fun removeDevice(endpoint: Endpoint): Boolean = registry.remove(endpoint) != null

    override suspend fun connect(endpoint: Endpoint): ConnectedDevice {
        machine.advance(ConnectorState.Connecting)
        return establish(endpoint)
    }

    override suspend fun disconnect() {
        live = null
        machine.advance(ConnectorState.Idle)
    }

    /**
     * Simulates the transport dying under a live link.
     *
     * This is the hook a real adapter gets from its socket; here it is a call. The
     * resulting state is [ConnectorState.Reconnecting] with attempt 1.
     *
     * @param detail the single-line cause, recorded on the failure.
     * @return the state the connector moved to.
     */
    fun loseTransport(detail: String = DEFAULT_LOSS_DETAIL): ConnectorState {
        val current = machine.state.value
        check(current is ConnectorState.Connected) {
            "loseTransport needs a live link; the state is $current"
        }
        return machine.advance(
            ConnectorState.Reconnecting(1, ConnectorFailure.TransportLost(detail)),
        )
    }

    /**
     * Runs one reconnect attempt, the way a real adapter's retry loop would.
     *
     * The attempt number goes up before the re-dial, so a collector sees
     * `Reconnecting(n)` and then either [ConnectorState.Connected] or
     * [ConnectorState.Failed]. The re-dial uses the endpoint that was lost; if it
     * stopped answering, this ends in [ConnectorState.Failed] with
     * [ConnectorFailure.Unreachable].
     *
     * @return the device, once the link is back.
     * @throws ConnectorException when the attempt failed.
     * @throws IllegalStateException when there is no lost link to retry.
     */
    suspend fun retry(): ConnectedDevice {
        val current = machine.state.value
        check(current is ConnectorState.Reconnecting) {
            "retry needs a lost link; the state is $current"
        }
        val endpoint = checkNotNull(live) {
            "retry needs the endpoint of the lost link"
        }.endpoint
        machine.advance(ConnectorState.Reconnecting(current.attempt + 1, current.lastFailure))
        return establish(endpoint)
    }

    private fun establish(endpoint: Endpoint): ConnectedDevice {
        val manifest = registry[endpoint]
        if (manifest == null) {
            val failure = ConnectorFailure.Unreachable(endpoint)
            live = null
            machine.advance(ConnectorState.Failed(failure))
            throw ConnectorException(failure)
        }
        val device = ConnectedDevice(endpoint, manifest)
        live = device
        machine.advance(ConnectorState.Connected(device))
        return device
    }

    private companion object {
        const val DEFAULT_LOSS_DETAIL = "in-memory link closed"
    }
}
