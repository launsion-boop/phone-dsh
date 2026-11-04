// The connection page's data source: which devices a connector publishes, and
// which fixed session each one opens.
// SPDX-License-Identifier: MIT
//
// The Android counterpart of iOS's `DeviceSessionCoordinator` plus
// `ChatDeviceSessionProvider` (`NativeDeviceConnectionPage.swift:75-161`,
// `NativeDeviceDependencies.swift:13-28`). The rules it keeps from that side:
//
//  * The page shows what a connector **published**. It never scans, never pairs
//    and never fabricates a device; an injected connector with nothing to show
//    renders the iOS page's 未接入设备连接器 wording.
//  * The link's own state is [DeviceConnector.state] — the existing
//    [ConnectorStateMachine] — projected through [ConnectorStatus]. This class does
//    not own a second life cycle and never calls `advance`.
//  * A saved device-to-session mapping is kept when opening fails, and there is an
//    explicit [forgetMapping] to drop it. Rebinding silently would move a
//    transcript under the user without a word.
package com.phonedsh.domain.connector

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * One device a connector publishes as available to open.
 *
 * @property endpoint the address the connector reports; its syntax belongs to the
 *   endpoint's protocol and is never parsed here.
 * @property capabilityCount how many capabilities the device's manifest declares;
 *   the row does not render capabilities, the count is what a caller logs.
 */
data class DeviceConnectionEntry(
    val deviceId: String,
    val displayName: String,
    val endpoint: Endpoint,
    val capabilityCount: Int = 0,
)

/** The two transports the connection page reports on, in the iOS page's order. */
enum class DeviceTransmission {
    /** A Bluetooth-based device link. */
    BLUETOOTH,

    /** A LAN-based device link. */
    LOCAL_NETWORK,
}

/**
 * One transport-capability row.
 *
 * @property available whether this host really has that transport. Both rows are
 *   `false` on this build: no real device transport exists, and the page says so
 *   rather than implying one is around the corner.
 */
data class DeviceTransmissionRow(
    val transmission: DeviceTransmission,
    val available: Boolean,
)

/** Why opening a device's session did not happen. */
sealed interface DeviceOpenFailure {
    /** The provider produced a different session than the saved one. */
    data class Mismatch(val expected: String, val actual: String) : DeviceOpenFailure

    /** No provider could be reached for this device. */
    data class Unavailable(val deviceId: String) : DeviceOpenFailure

    /** The provider threw something this seam does not classify. */
    data class Failed(val detail: String) : DeviceOpenFailure
}

/**
 * The device and session a successful open resolved.
 *
 * @property sessionId the fixed session the device is paired with; the session
 *   page is opened for it.
 */
data class DeviceSessionSelection(
    val deviceId: String,
    val sessionId: String,
    val displayName: String,
)

/**
 * Everything the connection page renders, as one immutable value.
 *
 * @property connectorAvailable whether a connector was injected at all. `false`
 *   is the truthful state of this build and the iOS build alike.
 * @property connectorProtocol the injected connector's protocol id, `null` when
 *   there is none. The page prints it so a reader can tell an injected
 *   double from a real transport.
 * @property status the link's four-state projection ([ConnectorState.status]).
 * @property connectorFailure why the link is not up, when the connector says so.
 * @property openFailure why the last open attempt failed, if it did.
 * @property failedDeviceId the device the last failed open was for; `null` after a
 *   success or an explicit forget.
 * @property forgettableDeviceIds the devices that have a saved mapping.
 */
data class DeviceConnectionSnapshot(
    val connectorAvailable: Boolean,
    val connectorProtocol: String?,
    val status: ConnectorStatus,
    val devices: List<DeviceConnectionEntry> = emptyList(),
    val connectorFailure: ConnectorFailure? = null,
    val openFailure: DeviceOpenFailure? = null,
    val failedDeviceId: String? = null,
    val forgettableDeviceIds: Set<String> = emptySet(),
    val transmissions: List<DeviceTransmissionRow> = DEFAULT_TRANSMISSIONS,
) {
    /** True when a saved mapping exists for [deviceId]; the page offers to forget it. */
    fun canForget(deviceId: String?): Boolean = deviceId != null && deviceId in forgettableDeviceIds

    companion object {
        /** Both transports unavailable: this build has no real device transport. */
        val DEFAULT_TRANSMISSIONS: List<DeviceTransmissionRow> = listOf(
            DeviceTransmissionRow(DeviceTransmission.BLUETOOTH, available = false),
            DeviceTransmissionRow(DeviceTransmission.LOCAL_NETWORK, available = false),
        )
    }
}

/**
 * The connection page's data source.
 *
 * @param connector the injected connector, or `null` for "this host has none",
 *   which is the iOS default and the page's 未接入设备连接器 state.
 * @param publishedDevices the devices the connector published, in its own order.
 * @param provider opens a device's fixed session; `null` makes every open fail
 *   with [DeviceOpenFailure.Unavailable] instead of pretending.
 * @param transmissions the transport-capability rows this host really has.
 */
class DeviceConnectionSource(
    private val connector: DeviceConnector? = null,
    publishedDevices: List<DeviceConnectionEntry> = emptyList(),
    private val provider: DeviceSessionProvider? = null,
    transmissions: List<DeviceTransmissionRow> = DeviceConnectionSnapshot.DEFAULT_TRANSMISSIONS,
) {
    private val published = publishedDevices.toList()
    private val rows = transmissions.toList()
    private val mappings = LinkedHashMap<String, String>()

    private var openFailure: DeviceOpenFailure? = null
    private var failedDeviceId: String? = null

    private val mutable = MutableStateFlow(snapshot())
    private var watcher: Job? = null

    /** The page's whole input. Hot, and always has a value. */
    val snapshot: StateFlow<DeviceConnectionSnapshot> = mutable.asStateFlow()

    /**
     * Follows the injected connector's own state so the page reflects the link the
     * connector reports, not a copy of it.
     */
    fun start(scope: CoroutineScope) {
        val connector = connector ?: return
        watcher?.cancel()
        watcher = scope.launch {
            connector.state.collect { refresh() }
        }
    }

    /** Stops following the connector's state. */
    fun stop() {
        watcher?.cancel()
        watcher = null
    }

    /** Recomputes the snapshot from the connector's current state. */
    fun refresh() {
        mutable.value = snapshot()
    }

    /**
     * Resolves (or reopens) the fixed session for [deviceId].
     *
     * @return the resolved selection, or `null` when the open failed; the reason is
     *   then in [DeviceConnectionSnapshot.openFailure] and the saved mapping is kept.
     */
    suspend fun open(deviceId: String): DeviceSessionSelection? {
        val entry = currentDevices().firstOrNull { it.deviceId == deviceId }
        if (entry == null) {
            openFailure = DeviceOpenFailure.Failed("no published device $deviceId")
            failedDeviceId = deviceId
            refresh()
            return null
        }
        val saved = mappings[deviceId]
        val session = try {
            val resolved = provider?.openSession(deviceId, entry.displayName, saved)
                ?: throw DeviceSessionMappingException(
                    DeviceSessionMappingException.Kind.UNAVAILABLE,
                    deviceId,
                )
            if (saved != null && resolved != saved) {
                throw DeviceSessionMappingException(
                    DeviceSessionMappingException.Kind.SESSION_IDENTITY_MISMATCH,
                    deviceId,
                    expected = saved,
                    actual = resolved,
                )
            }
            resolved
        } catch (mapping: DeviceSessionMappingException) {
            openFailure = when (mapping.kind) {
                DeviceSessionMappingException.Kind.SESSION_IDENTITY_MISMATCH -> {
                    DeviceOpenFailure.Mismatch(
                        expected = mapping.expected.orEmpty(),
                        actual = mapping.actual.orEmpty(),
                    )
                }

                DeviceSessionMappingException.Kind.UNAVAILABLE -> DeviceOpenFailure.Unavailable(deviceId)
            }
            failedDeviceId = deviceId
            refresh()
            return null
        } catch (t: Throwable) {
            openFailure = DeviceOpenFailure.Failed(t.message ?: DEFAULT_OPEN_FAILURE)
            failedDeviceId = deviceId
            refresh()
            return null
        }
        mappings[deviceId] = session
        openFailure = null
        failedDeviceId = null
        refresh()
        return DeviceSessionSelection(deviceId, session, entry.displayName)
    }

    /**
     * Drops the saved mapping for [deviceId].
     *
     * @return whether a mapping existed. The device stays published; only the
     *   session binding is forgotten.
     */
    fun forgetMapping(deviceId: String): Boolean {
        val removed = mappings.remove(deviceId) != null
        if (failedDeviceId == deviceId) {
            failedDeviceId = null
            openFailure = null
        }
        refresh()
        return removed
    }

    /** The saved session for [deviceId], if any. */
    fun mappingFor(deviceId: String): String? = mappings[deviceId]

    private fun currentDevices(): List<DeviceConnectionEntry> {
        val connected = (connector?.state?.value as? ConnectorState.Connected)?.device
        if (connected == null) return published
        val known = published.map { it.deviceId }.toSet()
        if (connected.deviceId in known) {
            return published.map { entry ->
                if (entry.deviceId == connected.deviceId) {
                    entry.copy(capabilityCount = connected.manifest.capabilities.size)
                } else {
                    entry
                }
            }
        }
        return published + DeviceConnectionEntry(
            deviceId = connected.deviceId,
            displayName = connected.deviceId,
            endpoint = connected.endpoint,
            capabilityCount = connected.manifest.capabilities.size,
        )
    }

    private fun snapshot(): DeviceConnectionSnapshot {
        val state = connector?.state?.value
        val devices = currentDevices()
        return DeviceConnectionSnapshot(
            connectorAvailable = connector != null,
            connectorProtocol = devices.firstOrNull()?.endpoint?.protocolId,
            status = state?.status ?: ConnectorStatus.UNKNOWN,
            devices = devices,
            connectorFailure = when (state) {
                is ConnectorState.Failed -> state.failure
                is ConnectorState.Reconnecting -> state.lastFailure
                else -> null
            },
            openFailure = openFailure,
            failedDeviceId = failedDeviceId,
            forgettableDeviceIds = mappings.keys.toSet(),
            transmissions = rows,
        )
    }

    private companion object {
        const val DEFAULT_OPEN_FAILURE: String = "device session could not be opened"
    }
}

/**
 * A [DeviceSessionProvider] over a fixed device-to-session assignment.
 *
 * The double opens no DSH session: this host has no management transport, so the
 * provider is where that missing edge is named. It keeps the one behaviour that
 * matters to the page's contract — an assignment never drifts once saved — and lets
 * a caller script a drift so the refusal path is testable.
 *
 * @param assignments device id to session id; a device without one gets
 *   `"$sessionPrefix<deviceId>"`.
 * @param drift a scripted "the reopened session is not the saved one" answer, used
 *   to exercise [DeviceSessionMappingException.Kind.SESSION_IDENTITY_MISMATCH].
 */
class InMemoryDeviceSessionProvider(
    private val assignments: Map<String, String> = emptyMap(),
    private val sessionPrefix: String = "device-session-",
    private val drift: String? = null,
) : DeviceSessionProvider {
    override suspend fun openSession(
        deviceId: String,
        displayName: String,
        existingSessionId: String?,
    ): String {
        if (drift != null) return drift
        return assignments[deviceId] ?: (sessionPrefix + deviceId)
    }
}
