// The connector wiring: the existing state machine, projected onto the page.
// SPDX-License-Identifier: MIT
//
// What this suite proves, and what it deliberately does not:
//
//  * It proves `DeviceConnectionSource` **reads** `ConnectorStateMachine`'s state and
//    projects it through `ConnectorStatus` into the page's four-state catalog, so a
//    connector that moves Idle -> Connected -> Failed changes the page without the
//    page owning a second life cycle.
//  * It does NOT re-test the transition table: `ConnectorStateMachineTest` in
//    `:domain` already pins every legal and illegal row, and a copy here would be a
//    second source of the same truth.
//  * It pins the baseline's mapping rules: an open that cannot be resolved fails
//    honestly, a drifted session is refused, and the saved mapping survives the
//    refusal so the page can offer 解除该设备的会话映射.
package com.phonedsh.ui.page

import com.phonedsh.domain.connector.ConnectorException
import com.phonedsh.domain.connector.ConnectorFailure
import com.phonedsh.domain.connector.ConnectorStatus
import com.phonedsh.domain.connector.DeviceConnectionEntry
import com.phonedsh.domain.connector.DeviceConnectionSource
import com.phonedsh.domain.connector.DeviceOpenFailure
import com.phonedsh.domain.connector.DeviceSessionProvider
import com.phonedsh.domain.connector.Endpoint
import com.phonedsh.domain.connector.InMemoryConnector
import com.phonedsh.domain.connector.InMemoryDeviceSessionProvider
import com.phonedsh.domain.connector.ReadOnlyDeviceSessionTransport
import com.phonedsh.domain.device.CapabilityValue
import com.phonedsh.domain.device.DeviceAuth
import com.phonedsh.domain.device.DeviceLimits
import com.phonedsh.domain.device.DeviceManifest
import com.phonedsh.domain.device.DeviceProtocol
import com.phonedsh.ui.UiStrings
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

class DeviceConnectionWiringTest {
    private val endpoint = Endpoint("devicews", "wss://device.invalid:443/channel")
    private val nowhere = Endpoint("devicews", "wss://nowhere.invalid:443/channel")

    private val manifest = DeviceManifest(
        deviceId = DEVICE_ID,
        protocol = DeviceProtocol("devicews", "1.0"),
        capabilities = linkedMapOf(
            "audio.tts" to CapabilityValue.of("codec" to "opus", "rate" to 24_000),
            "render.pixel" to CapabilityValue.of("w" to 64, "h" to 64, "format" to "rgb565"),
        ),
        limits = DeviceLimits(maxFrameBytes = 65_536, audioKbps = 32),
        auth = DeviceAuth(DeviceAuth.Pairing.BLE_PASSKEY),
    )

    private val entry = DeviceConnectionEntry(
        deviceId = DEVICE_ID,
        displayName = DISPLAY_NAME,
        endpoint = endpoint,
        capabilityCount = manifest.capabilities.size,
    )

    @Test
    fun `the connector's own state machine drives the page's status`() = runBlocking {
        val connector = InMemoryConnector(mapOf(endpoint to manifest))
        val source = DeviceConnectionSource(
            connector = connector,
            publishedDevices = listOf(entry),
            provider = InMemoryDeviceSessionProvider(mapOf(DEVICE_ID to SESSION_ID)),
        )

        // Idle: nothing was attempted, so the page says 未知 rather than "no devices".
        assertEquals(ConnectorStatus.UNKNOWN, source.snapshot.value.status)
        assertEquals(DeviceListState.READY, page(source).list)

        connector.connect(endpoint)
        source.refresh()
        assertEquals(ConnectorStatus.READY, page(source).status)
        assertEquals(2, source.snapshot.value.devices.single().capabilityCount)

        // Connected -> Idle is the disconnect row of the table, not a page decision.
        connector.disconnect()
        source.refresh()
        assertEquals(ConnectorStatus.UNKNOWN, page(source).status)
    }

    @Test
    fun `a failed connect is the connector's own failure, worded by the page`() = runBlocking {
        val connector = InMemoryConnector(mapOf(endpoint to manifest))
        val source = DeviceConnectionSource(connector = connector, publishedDevices = listOf(entry))
        val thrown = runCatching { connector.connect(nowhere) }.exceptionOrNull()
        assertTrue(thrown is ConnectorException)

        source.refresh()
        val state = page(source)
        assertEquals(ConnectorStatus.FAILED, state.status)
        val failure = source.snapshot.value.connectorFailure
        assertTrue(failure is ConnectorFailure.Unreachable)
        assertEquals(ConnectorFailure.Unreachable.CODE, failure!!.code)
        assertEquals(UiStrings.DEVICE_CONNECTOR_FAILED.format(failure.detail), state.failure)
    }

    @Test
    fun `no connector is 未接入设备连接器 and never a fabricated device`() {
        val source = DeviceConnectionSource(connector = null)
        val state = page(source)
        assertEquals(DeviceListState.UNAVAILABLE, state.list)
        assertTrue(state.devices.isEmpty())
        assertNull(state.connectorProtocol)
        assertNull(state.failure)
        assertEquals(2, state.transmissions.size)
        assertTrue("no real transport exists on this build", state.transmissions.none { it.available })
    }

    @Test
    fun `an injected connector with no published device is 没有在线设备`() {
        val connector = InMemoryConnector(mapOf(endpoint to manifest))
        val source = DeviceConnectionSource(connector = connector)
        val state = page(source)
        assertEquals(DeviceListState.EMPTY, state.list)
        assertTrue(state.devices.isEmpty())
    }

    @Test
    fun `an open with no provider fails honestly and saves no mapping`() = runBlocking {
        val source = DeviceConnectionSource(
            connector = InMemoryConnector(mapOf(endpoint to manifest)),
            publishedDevices = listOf(entry),
            provider = null,
        )
        assertNull(source.open(DEVICE_ID))
        assertEquals(DeviceOpenFailure.Unavailable(DEVICE_ID), source.snapshot.value.openFailure)
        assertNull(source.mappingFor(DEVICE_ID))
        val state = page(source)
        assertEquals(UiStrings.DEVICE_OPEN_FAILED_UNAVAILABLE, state.failure)
        assertEquals(DEVICE_ID, state.failedDeviceId)
        assertFalse("nothing was saved, so there is nothing to forget", state.canForget)
    }

    @Test
    fun `a drifted session is refused, the mapping is kept and the page offers 解除`() = runBlocking {
        // The provider answers a different session on the second open: exactly the
        // iOS `sessionIdentityMismatch` case.
        var attempt = 0
        val provider = DeviceSessionProvider { _, _, _ ->
            attempt += 1
            if (attempt == 1) SAVED_SESSION else DRIFTED_SESSION
        }
        val source = DeviceConnectionSource(
            connector = InMemoryConnector(mapOf(endpoint to manifest)),
            publishedDevices = listOf(entry),
            provider = provider,
        )

        val first = source.open(DEVICE_ID)
        assertNotNull(first)
        assertEquals(SAVED_SESSION, source.mappingFor(DEVICE_ID))
        assertEquals(SAVED_SESSION, first!!.sessionId)

        assertNull(source.open(DEVICE_ID))
        assertEquals(
            DeviceOpenFailure.Mismatch(expected = SAVED_SESSION, actual = DRIFTED_SESSION),
            source.snapshot.value.openFailure,
        )
        assertEquals("the mapping is kept on failure, by design", SAVED_SESSION, source.mappingFor(DEVICE_ID))

        val state = page(source)
        assertEquals(
            UiStrings.DEVICE_OPEN_FAILED_MISMATCH.format(SAVED_SESSION, DRIFTED_SESSION),
            state.failure,
        )
        assertTrue(state.canForget)

        assertTrue(source.forgetMapping(DEVICE_ID))
        assertNull(source.mappingFor(DEVICE_ID))
        val after = page(source)
        assertFalse(after.canForget)
        assertNull("forgetting the mapping clears the failure it was about", after.failure)
    }

    @Test
    fun `an unpublished device id is refused instead of opened`() = runBlocking {
        val source = DeviceConnectionSource(
            connector = InMemoryConnector(mapOf(endpoint to manifest)),
            publishedDevices = listOf(entry),
            provider = InMemoryDeviceSessionProvider(mapOf(DEVICE_ID to SESSION_ID)),
        )
        assertNull(source.open("device-that-was-never-published"))
        assertTrue(source.snapshot.value.openFailure is DeviceOpenFailure.Failed)
    }

    /**
     * The read-only semantic, as a type rather than a promise: the transport the
     * session page is built from declares reads only.
     */
    @Test
    fun `the session transport declares no write`() {
        val declared = ReadOnlyDeviceSessionTransport::class.java.declaredMethods
        assertTrue("the seam must still declare a read", declared.isNotEmpty())
        val suspicious = declared.filter { method ->
            !Modifier.isStatic(method.modifiers) && WRITE_VERBS.any { verb ->
                method.name.startsWith(verb, ignoreCase = true)
            }
        }
        assertTrue(
            "a read-only transport must not declare $suspicious; input and confirmation happen on " +
                "the device",
            suspicious.isEmpty(),
        )
        val names = declared.map { it.name }
        assertEquals(listOf("liveEvents", "readHistory"), names.sorted())
    }

    private fun page(source: DeviceConnectionSource): DeviceConnectionScreenState =
        DeviceConnectionScreenState.from(source.snapshot.value)

    private companion object {
        const val DEVICE_ID: String = "esp32-8c4f01"
        const val DISPLAY_NAME: String = "客厅网关"
        const val SESSION_ID: String = "device-session-esp32-8c4f01"
        const val SAVED_SESSION: String = "session-saved"
        const val DRIFTED_SESSION: String = "session-drifted"

        /** Every verb a mutating seam would name; a read-only one may declare none. */
        val WRITE_VERBS: List<String> = listOf(
            "send", "write", "post", "reply", "submit", "approve", "deny", "interrupt",
            "cancel", "close", "open", "connect", "disconnect", "delete", "set", "put", "patch",
        )
    }
}
