// The monitor a device-session page reads: history, live tail, paging window.
// SPDX-License-Identifier: MIT
//
// This is the Android counterpart of `NativeDeviceSessionModel`
// (`examples/probe-app/PhoneDSHProbe/NativeDeviceSessionPage.swift:10-349`), and it
// keeps that model's two-source shape deliberately:
//
//   * [DeviceSessionSnapshot.durable] is the projected history window. It changes
//     only when a page is read, and a re-read replaces it wholesale.
//   * [DeviceSessionSnapshot.live] is the folded live tail. It grows event by
//     event and never moves into the durable half: a live row becomes durable when
//     the device publishes it, not when the phone decides it looks finished.
//   * [DeviceSessionSnapshot.items] is `durable + live` in that order, which is
//     the order the session actually produced.
//
// The transport is [ReadOnlyDeviceSessionTransport], so nothing in this class can
// write. It owns no clock and no dispatcher: `start` takes the scope the caller
// already has, which is what makes a replaying test deterministic.
package com.phonedsh.domain.connector

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Whether a monitored session has a transcript, is waiting for one, or failed to read. */
enum class DeviceSessionStatus {
    /** The first read has not answered yet. */
    WAITING,

    /** The first read answered; the transcript may still be empty. */
    READY,

    /** The first read failed; there is nothing to show but the reason. */
    FAILED,
}

/**
 * Everything the device-session page renders, as one immutable value.
 *
 * @property durable the projected history window, oldest first.
 * @property live the live rows, in arrival order.
 * @property hasMore whether older records exist beyond the window.
 * @property loadingEarlier whether an older page is in flight.
 * @property beforeSeq the oldest record read so far; `null` before the first read.
 */
data class DeviceSessionSnapshot(
    val deviceId: String,
    val sessionId: String,
    val displayName: String,
    val status: DeviceSessionStatus = DeviceSessionStatus.WAITING,
    val failure: DeviceSessionFailure? = null,
    val durable: List<DeviceTranscriptItem> = emptyList(),
    val live: List<DeviceTranscriptItem> = emptyList(),
    val hasMore: Boolean = false,
    val loadingEarlier: Boolean = false,
    val beforeSeq: Long? = null,
    val throughSeq: Long? = null,
) {
    /**
     * The rendered transcript: the durable window first, then what is still live.
     *
     * This is the iOS model's `items` property (`durableItems + liveItems`), and it
     * is a `get()` rather than a field so the two halves cannot drift out of order.
     */
    val items: List<DeviceTranscriptItem>
        get() = durable + live

    /** True when nothing is on screen yet and no failure explains why. */
    val waiting: Boolean
        get() = status == DeviceSessionStatus.WAITING

    /** True when the read succeeded and the session has no rows at all. */
    val empty: Boolean
        get() = status == DeviceSessionStatus.READY && items.isEmpty()
}

/**
 * Monitors one device session over a read-only transport.
 *
 * Use one instance per page visit. [start] is idempotent; [stop] cancels the live
 * pump and leaves the snapshot as it was, so a page that is re-entered can be
 * started again without losing the transcript it already showed.
 *
 * @param deviceId the device whose session is monitored.
 * @param sessionId the fixed session the device is paired with.
 * @param displayName the device's display name (the page title).
 * @param transport the read-only source; the only thing that can produce a row.
 * @param pageSize the history window size, in records.
 */
class DeviceSessionSource(
    private val deviceId: String,
    private val sessionId: String,
    private val displayName: String,
    private val transport: ReadOnlyDeviceSessionTransport,
    private val pageSize: Int = DeviceHistoryRequest.DEFAULT_PAGE_SIZE,
) {
    private val mutable = MutableStateFlow(
        DeviceSessionSnapshot(
            deviceId = deviceId,
            sessionId = sessionId,
            displayName = displayName,
        ),
    )

    /** The page's whole input. Hot, and always has a value. */
    val snapshot: StateFlow<DeviceSessionSnapshot> = mutable.asStateFlow()

    private var history = DeviceSessionHistory()
    private var live = DeviceLiveState()
    private var pump: Job? = null
    private var lastEventSeq: Long? = null
    private var started = false

    /**
     * Reads the first history window, then follows the live stream in [scope].
     *
     * @param scope the scope the pump runs in; `null` reads the history only, which
     *   is what a screenshot or a paged replay wants.
     */
    suspend fun start(scope: CoroutineScope? = null) {
        if (started) return
        started = true
        publish(status = DeviceSessionStatus.WAITING, failure = null)
        try {
            val page = transport.readHistory(sessionId, DeviceHistoryRequest(maxMessages = pageSize))
            history = history.reset(page, throughSeq = page.records.maxOfOrNull { it.seq })
            lastEventSeq = history.throughSeq
            publish(status = DeviceSessionStatus.READY, failure = null)
        } catch (t: Throwable) {
            publish(
                status = DeviceSessionStatus.FAILED,
                failure = DeviceSessionFailure.Read(t.message ?: DEFAULT_READ_FAILURE),
            )
            return
        }
        if (scope != null) startPump(scope)
    }

    /**
     * Reads one older window and prepends it.
     *
     * Does nothing when there is nothing older, when a read is already in flight,
     * or when the window has no cursors yet. A page that does not advance the
     * cursor ends paging and reports [DeviceSessionFailure.Stalled]: repeating the
     * same request would return the same window forever.
     */
    suspend fun loadEarlier() {
        val current = mutable.value
        if (!history.hasMore || current.loadingEarlier) return
        val throughSeq = history.throughSeq ?: return
        val beforeSeq = history.beforeSeq ?: return
        publish(loadingEarlier = true, failure = null)
        try {
            val page = transport.readHistory(
                sessionId,
                DeviceHistoryRequest(
                    throughSeq = throughSeq,
                    beforeSeq = beforeSeq,
                    maxMessages = pageSize,
                ),
            )
            val (next, advance) = history.applyEarlier(page)
            history = next
            if (advance == HistoryAdvance.STALLED) {
                publish(loadingEarlier = false, failure = DeviceSessionFailure.Stalled(beforeSeq))
            } else {
                publish(loadingEarlier = false, failure = null)
            }
        } catch (t: Throwable) {
            publish(
                loadingEarlier = false,
                failure = DeviceSessionFailure.Read(t.message ?: DEFAULT_READ_FAILURE),
            )
        }
    }

    /** Stops following the live stream. The transcript stays on screen. */
    fun stop() {
        pump?.cancel()
        pump = null
    }

    private fun startPump(scope: CoroutineScope) {
        pump?.cancel()
        pump = scope.launch {
            try {
                transport.liveEvents(sessionId, lastEventSeq).collect { event ->
                    val seq = event.seq
                    if (seq != null) lastEventSeq = seq
                    val durable = DeviceTranscriptProjector.items(history.ordered, sessionId)
                    live = live.apply(event, sessionId, durable)
                    publish(failure = null)
                }
            } catch (t: Throwable) {
                publish(failure = DeviceSessionFailure.Read(t.message ?: DEFAULT_READ_FAILURE))
            }
        }
    }

    private fun publish(
        status: DeviceSessionStatus = mutable.value.status,
        failure: DeviceSessionFailure? = mutable.value.failure,
        loadingEarlier: Boolean = mutable.value.loadingEarlier,
    ) {
        val durable = DeviceTranscriptProjector.items(history.ordered, sessionId)
            .applyToolOutputs(live.toolOutputs)
        mutable.value = DeviceSessionSnapshot(
            deviceId = deviceId,
            sessionId = sessionId,
            displayName = displayName,
            status = status,
            failure = failure,
            durable = durable,
            live = live.items,
            hasMore = history.hasMore,
            loadingEarlier = loadingEarlier,
            beforeSeq = history.beforeSeq,
            throughSeq = history.throughSeq,
        )
    }

    private companion object {
        /** The line a transport with no message of its own still produces. */
        const val DEFAULT_READ_FAILURE: String = "device session read failed"
    }
}
