// SPDX-License-Identifier: MIT
// The phone's three-value PC reachability projection (§10, PC-ANDROID §2.1.5;
// value fixtures from PC-20261110-pclink-workspace-cache §2 and
// PC-20261110-pclink-foreground-resume-presence).
//
// `online`      an established E2E session exists.
// `reconnecting` dialing/handshaking, a user-initiated foreground resume, or a
//                bounded grace (8 s) after a dropped socket while a retry is in
//                flight. This value MUST NOT render `电脑离线`.
// `offline`      one dial already failed or the grace expired.
//
// `longOffline` is a separate latch, not a fourth reachability value: after ten
// minutes without a connection, or when the user opens the connection screen
// while offline, the contract's exact sentence is shown. The model is pure (an
// injected monotonic clock), so the grace/expiry rules are testable without UI
// or sleeping.
package com.phonedsh.pclink

import java.time.Duration

/** The three §10 values; there is no fourth UI state. */
enum class PclinkReachability { ONLINE, RECONNECTING, OFFLINE }

/** One immutable presence reading for a status refresh. */
data class PclinkPresenceSnapshot(
    val reachability: PclinkReachability,
    val longOffline: Boolean,
    val lastSeenAtMilliseconds: Long?,
    val offlineSinceMilliseconds: Long?,
    /** Only meaningful for [PclinkReachability.OFFLINE] (null while reconnecting). */
    val offlineReason: PclinkOfflineReason?,
    val graceExpired: Boolean,
) {
    val isOnline: Boolean get() = reachability == PclinkReachability.ONLINE
    val isReconnecting: Boolean get() = reachability == PclinkReachability.RECONNECTING
    val isOffline: Boolean get() = reachability == PclinkReachability.OFFLINE

    /**
     * `电脑离线` may be presented only for [PclinkReachability.OFFLINE]. While
     * reconnecting the phone presents its connecting copy instead (§10).
     */
    val showsOfflineCopy: Boolean get() = reachability == PclinkReachability.OFFLINE

    /** The exact §10 sentence, only once [longOffline] is true. */
    val longOfflineHint: String?
        get() = if (longOffline) PclinkPresence.LONG_OFFLINE_HINT else null
}

/**
 * Pure reachability state machine over [PclinkClientState] values. Feed it the
 * same status the client exposes; [snapshot] is safe to call on every recompose.
 */
class PclinkPresence(
    private val reconnectGrace: Duration = Duration.ofSeconds(8),
    private val longOfflineAfter: Duration = Duration.ofMinutes(10),
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    init {
        require(!reconnectGrace.isNegative && !reconnectGrace.isZero) { "reconnectGrace must be positive" }
        require(!longOfflineAfter.isNegative && !longOfflineAfter.isZero) {
            "longOfflineAfter must be positive"
        }
    }

    private enum class Connection { NEVER_STARTED, PAIRING, DIALING, ONLINE, OFFLINE, UNPAIRED }

    private val lock = Any()
    private var connection: Connection = Connection.NEVER_STARTED
    private var offlineReason: PclinkOfflineReason? = null
    private var hasRecord: Boolean = true
    private var lastSeenAt: Long? = null
    private var offlineSince: Long? = null
    private var graceDeadline: Long? = null
    private var screenOpenedWhileOffline: Boolean = false

    /** Projects one client status (the record flag decides unpaired/pair). */
    fun apply(status: PclinkClientStatus) {
        apply(status.state, status.record != null)
    }

    /** Projects one client state; [paired] is `status.record != null`. */
    fun apply(state: PclinkClientState, paired: Boolean = true) {
        synchronized(lock) {
            val now = nowMillis()
            hasRecord = paired && state !is PclinkClientState.Unpaired
            when (state) {
                is PclinkClientState.Unpaired -> {
                    connection = Connection.UNPAIRED
                    offlineReason = null
                    offlineSince = null
                    graceDeadline = null
                    screenOpenedWhileOffline = false
                }
                is PclinkClientState.Online, is PclinkClientState.VersionWarning -> {
                    connection = Connection.ONLINE
                    offlineReason = null
                    offlineSince = null
                    graceDeadline = null
                    screenOpenedWhileOffline = false
                    lastSeenAt = now
                }
                is PclinkClientState.Pairing -> {
                    connection = Connection.PAIRING
                    startGraceIfNeeded(now)
                }
                PclinkClientState.Connecting -> {
                    connection = Connection.DIALING
                    startGraceIfNeeded(now)
                }
                is PclinkClientState.Offline -> {
                    connection = Connection.OFFLINE
                    offlineReason = state.reason
                    if (offlineSince == null) offlineSince = now
                    startGraceIfNeeded(now)
                }
            }
        }
    }

    /**
     * A foreground return / explicit retry is not a failed dial: it must never
     * read as offline, even if the grace had already expired. The next failed
     * dial then projects offline normally.
     */
    fun onForegroundResume() {
        synchronized(lock) {
            if (!hasRecord || connection == Connection.UNPAIRED) return
            connection = Connection.DIALING
        }
    }

    /**
     * The user opened the connection screen while not online; the long-offline
     * sentence is now required even if the ten-minute timer has not elapsed
     * (iOS `markConnectionScreenOpened`, §10).
     */
    fun onConnectionScreenOpened() {
        synchronized(lock) {
            if (!hasRecord || connection == Connection.ONLINE) return
            screenOpenedWhileOffline = true
        }
    }

    /** Current projection; pure in the injected clock. */
    fun snapshot(): PclinkPresenceSnapshot = synchronized(lock) {
        val now = nowMillis()
        val graceExpired = graceDeadline?.let { now >= it } ?: false
        val reachability = when (connection) {
            Connection.NEVER_STARTED, Connection.DIALING, Connection.PAIRING ->
                PclinkReachability.RECONNECTING
            Connection.ONLINE -> PclinkReachability.ONLINE
            Connection.OFFLINE ->
                if (graceExpired) PclinkReachability.OFFLINE else PclinkReachability.RECONNECTING
            Connection.UNPAIRED -> PclinkReachability.OFFLINE
        }
        val timedOut = connection == Connection.OFFLINE &&
            offlineSince?.let { now - it >= longOfflineAfter.toMillis() } == true
        val longOffline = hasRecord && connection != Connection.ONLINE &&
            (timedOut || screenOpenedWhileOffline)
        PclinkPresenceSnapshot(
            reachability = reachability,
            longOffline = longOffline,
            lastSeenAtMilliseconds = lastSeenAt,
            offlineSinceMilliseconds = offlineSince,
            offlineReason = if (reachability == PclinkReachability.OFFLINE) offlineReason else null,
            graceExpired = graceExpired,
        )
    }

    /**
     * The next instant the projection can change without another client event
     * (grace expiry or the long-offline timer), for the caller's ticker. `null`
     * when no timer can change the current value.
     */
    fun nextTransitionAtMilliseconds(): Long? = synchronized(lock) {
        val now = nowMillis()
        val candidates = ArrayList<Long>(2)
        graceDeadline?.let { if (it > now) candidates.add(it) }
        if (connection == Connection.OFFLINE && hasRecord && !screenOpenedWhileOffline) {
            offlineSince?.let {
                val threshold = it + longOfflineAfter.toMillis()
                if (threshold > now) candidates.add(threshold)
            }
        }
        candidates.minOrNull()
    }

    private fun startGraceIfNeeded(now: Long) {
        if (graceDeadline != null || !hasRecord) return
        graceDeadline = now + reconnectGrace.toMillis()
    }

    companion object {
        /** §10 / review Low-2; the only copy this model owns. */
        const val LONG_OFFLINE_HINT: String =
            "电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。"
    }
}
