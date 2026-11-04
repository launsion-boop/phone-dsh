// The read-only half of a device session: the only transport a monitor is given.
// SPDX-License-Identifier: MIT
//
// iOS enforces "a device session is watched, never driven" by wrapping the
// management transport in a `ReadOnlyDeviceSessionTransport` that forwards only
// the read commands the monitor needs
// (`examples/probe-app/PhoneDSHProbe/NativeDeviceSessionPage.swift`). The Android
// seam states the same rule as a type instead of a filter: this interface declares
// no write at all, so a monitor cannot send one, and a page that holds one cannot
// render a composer that would.
//
// That is the whole read-only semantic, and it is checkable without a device:
// `DeviceSessionReadOnlyTest` reflects over this interface and fails if a member
// whose name reads like a mutation ever appears.
package com.phonedsh.domain.connector

import kotlinx.coroutines.flow.Flow

/**
 * A device session's transcript, readable and nothing else.
 *
 * Both members are reads. There is deliberately no `send`, `reply`, `approve`,
 * `interrupt` or `close` here: input and confirmation happen on the device, which
 * is the sentence the session page prints above its transcript.
 */
interface ReadOnlyDeviceSessionTransport {
    /**
     * Reads one history window.
     *
     * @param sessionId the fixed session the device is paired with.
     * @param request the window (cursors and size, see [DeviceHistoryRequest]).
     * @throws ConnectorException when the read could not run; the caller shows the
     *   failure instead of an empty transcript, because "nothing was read" and
     *   "there is nothing" are different answers.
     */
    suspend fun readHistory(sessionId: String, request: DeviceHistoryRequest): DeviceHistoryPage

    /**
     * The session's live events, still arriving.
     *
     * The flow is cold: collecting it starts the read, cancelling collection stops
     * it. A transport that cannot stream ends the flow; it never emits a synthetic
     * event to keep a spinner alive.
     *
     * @param sessionId the session to follow.
     * @param afterSeq resume after this sequence number, `null` from the beginning
     *   of the live window.
     */
    fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent>
}

/** Why a monitored session has no transcript to show yet, or stopped growing. */
sealed interface DeviceSessionFailure {
    /** The last read (or the live stream) failed; [detail] is the transport's own line. */
    data class Read(val detail: String) : DeviceSessionFailure

    /**
     * A page "older" read returned nothing older than [beforeSeq], so the window
     * could not advance. Paging stops; the page says so instead of offering the
     * same button forever.
     */
    data class Stalled(val beforeSeq: Long) : DeviceSessionFailure
}

/**
 * Where a device's fixed session comes from.
 *
 * iOS injects `ChatDeviceSessionProvider`, which opens (or reopens) a real DSH
 * session over the management transport and refuses to continue when the reopened
 * session's id is not the one that was saved. The Android seam keeps the contract
 * and not the transport: this host has no management transport, so the provider is
 * an injected function and the shipped one is in memory.
 */
fun interface DeviceSessionProvider {
    /**
     * Opens (or reopens) the fixed session a device is paired with.
     *
     * @param existingSessionId the saved session for this device, or `null` when
     *   the device has none yet.
     * @return the session's id.
     * @throws DeviceSessionMappingException when the session cannot be opened, or
     *   when it is not the session that was saved.
     */
    suspend fun openSession(deviceId: String, displayName: String, existingSessionId: String?): String
}

/**
 * A device-to-session mapping that could not be honoured.
 *
 * The mapping is kept on failure by design (the iOS page keeps it and offers an
 * explicit 解除): silently rebinding a device to a different session would move a
 * transcript under the user without a word.
 */
class DeviceSessionMappingException(
    /** What went wrong. */
    val kind: Kind,
    /** The device the mapping belongs to. */
    val deviceId: String,
    /** The saved session, when the failure is a mismatch. */
    val expected: String? = null,
    /** The session the provider actually produced, when the failure is a mismatch. */
    val actual: String? = null,
    cause: Throwable? = null,
) : Exception(
    when (kind) {
        Kind.SESSION_IDENTITY_MISMATCH -> "session identity mismatch: expected $expected, got $actual"
        Kind.UNAVAILABLE -> "no session provider is available for device $deviceId"
    },
    cause,
) {
    /** The two failures the mapping can report. */
    enum class Kind {
        /** The provider produced a different session than the saved one. */
        SESSION_IDENTITY_MISMATCH,

        /** No provider could be reached at all. */
        UNAVAILABLE,
    }
}
