// SPDX-License-Identifier: MIT
// C4 presence tests: the three §10 values, the 8 s reconnect grace, "foreground
// resume never reads as offline", the long-offline latch and the exact §10
// sentence. Values follow PC-20261110-pclink-workspace-cache §2 and
// PC-20261110-pclink-foreground-resume-presence; the clock is injected.
package com.phonedsh.pclink

import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkPresenceTest {
    private var now = 0L
    private val presence = PclinkPresence(nowMillis = { now })
    private val record = C2TestSupport.peerRecord()

    private fun status(state: PclinkClientState, paired: Boolean = true): PclinkClientStatus =
        PclinkClientStatus(
            state = state,
            machineId = record.peerMachineId,
            record = if (paired) record else null,
        )

    private fun online() = presence.apply(status(PclinkClientState.Online))

    private fun drop(reason: PclinkOfflineReason = PclinkOfflineReason.Network) =
        presence.apply(status(PclinkClientState.Offline(reason)))

    @Test
    fun neverStartedIsReconnectingNotOffline() {
        val snapshot = presence.snapshot()
        assertEquals(PclinkReachability.RECONNECTING, snapshot.reachability)
        assertFalse(snapshot.showsOfflineCopy)
        assertFalse(snapshot.longOffline)
    }

    @Test
    fun onlineAndVersionWarningAreOnline() {
        now = 1_000
        online()
        var snapshot = presence.snapshot()
        assertEquals(PclinkReachability.ONLINE, snapshot.reachability)
        assertEquals(1_000L, snapshot.lastSeenAtMilliseconds)
        assertTrue(snapshot.isOnline)

        presence.apply(
            PclinkClientStatus(
                state = PclinkClientState.VersionWarning(
                    PclinkVersionWarning(dshVersion = "0.3.0"),
                ),
                record = record,
            ),
        )
        snapshot = presence.snapshot()
        assertEquals(PclinkReachability.ONLINE, snapshot.reachability)
    }

    @Test
    fun droppedSocketStaysReconnectingForTheEightSecondGrace() {
        online()
        now = 10_000
        drop()
        var snapshot = presence.snapshot()
        assertEquals(PclinkReachability.RECONNECTING, snapshot.reachability)
        assertFalse("reconnecting must not render 电脑离线", snapshot.showsOfflineCopy)
        assertNull("the offline reason is hidden during the grace", snapshot.offlineReason)

        now = 10_000 + 7_999
        assertEquals(PclinkReachability.RECONNECTING, presence.snapshot().reachability)
        now = 10_000 + 8_000
        snapshot = presence.snapshot()
        assertEquals(PclinkReachability.OFFLINE, snapshot.reachability)
        assertTrue(snapshot.showsOfflineCopy)
        assertEquals(PclinkOfflineReason.Network, snapshot.offlineReason)
        assertTrue(snapshot.graceExpired)
    }

    @Test
    fun foregroundResumeFromExpiredOfflineIsNeverOffline() {
        online()
        now = 1_000
        drop()
        now = 30_000
        assertEquals(PclinkReachability.OFFLINE, presence.snapshot().reachability)

        presence.onForegroundResume()
        var snapshot = presence.snapshot()
        assertEquals(PclinkReachability.RECONNECTING, snapshot.reachability)
        assertFalse(snapshot.showsOfflineCopy)

        // The next failed dial is a real failure and reads offline again.
        drop()
        snapshot = presence.snapshot()
        assertEquals(PclinkReachability.OFFLINE, snapshot.reachability)
    }

    @Test
    fun pairingAndConnectingAreReconnecting() {
        presence.apply(status(PclinkClientState.Pairing(PclinkPairingPhase.Joining)))
        assertEquals(PclinkReachability.RECONNECTING, presence.snapshot().reachability)
        presence.apply(status(PclinkClientState.Connecting))
        assertEquals(PclinkReachability.RECONNECTING, presence.snapshot().reachability)
    }

    @Test
    fun longOfflineAfterTenMinutesOfFailedReconnects() {
        online()
        now = 1_000
        drop()
        now = 1_000 + Duration.ofMinutes(10).toMillis() - 1
        assertFalse(presence.snapshot().longOffline)
        now = 1_000 + Duration.ofMinutes(10).toMillis()
        val snapshot = presence.snapshot()
        assertTrue(snapshot.longOffline)
        assertEquals(PclinkPresence.LONG_OFFLINE_HINT, snapshot.longOfflineHint)
        assertEquals(
            "电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。",
            snapshot.longOfflineHint,
        )
        assertEquals(PclinkReachability.OFFLINE, snapshot.reachability)
    }

    @Test
    fun connectionScreenOpenedWhileOfflineLatchesTheLongOfflineSentence() {
        online()
        now = 1_000
        drop()
        presence.onConnectionScreenOpened()
        val snapshot = presence.snapshot()
        assertTrue(snapshot.longOffline)
        assertEquals(PclinkPresence.LONG_OFFLINE_HINT, snapshot.longOfflineHint)
    }

    @Test
    fun unpairedIsOfflineAndClearsLongOffline() {
        online()
        now = 1_000
        drop()
        presence.onConnectionScreenOpened()
        assertTrue(presence.snapshot().longOffline)

        presence.apply(
            status(PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord), paired = false),
        )
        val snapshot = presence.snapshot()
        assertEquals(PclinkReachability.OFFLINE, snapshot.reachability)
        assertFalse("an unpaired phone has no long-offline warning", snapshot.longOffline)
        assertNull(snapshot.offlineReason)
    }

    @Test
    fun nextTransitionTracksTheGraceThenTheLongOfflineTimer() {
        online()
        now = 2_000
        drop()
        assertEquals(10_000L, presence.nextTransitionAtMilliseconds())
        now = 10_000
        assertEquals(
            2_000L + Duration.ofMinutes(10).toMillis(),
            presence.nextTransitionAtMilliseconds(),
        )
        now = 2_000 + Duration.ofMinutes(10).toMillis()
        assertNull(presence.nextTransitionAtMilliseconds())
    }

    @Test
    fun customGraceCanBeInjected() {
        val fast = PclinkPresence(
            reconnectGrace = Duration.ofMillis(100),
            nowMillis = { now },
        )
        fast.apply(PclinkClientStatus(state = PclinkClientState.Online, record = record))
        now = 5_000
        fast.apply(PclinkClientStatus(state = PclinkClientState.Offline(PclinkOfflineReason.Network), record = record))
        assertEquals(PclinkReachability.RECONNECTING, fast.snapshot().reachability)
        now = 5_100
        assertEquals(PclinkReachability.OFFLINE, fast.snapshot().reachability)
    }
}
