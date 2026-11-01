// phone-dsh — :engine / com.phonedsh.engine: the real loopback failure, as text.
// SPDX-License-Identifier: MIT
//
// :net records a failed start/engine death instead of throwing (see
// LoopbackStartException and LoopbackServer.lastFailure). The engine must show
// the cause, and only the cause: these tests pin the reason formatting, including
// the one property the screen depends on — no token and no full URL.

package com.phonedsh.engine

import com.phonedsh.loopback.LoopbackStartException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.SocketException

class OriginFailureTest {
    @Test
    fun aFailedStartReportsTheRealCauseInsteadOfTheWrapper() {
        val failure = LoopbackStartException(
            configuredPort = 0,
            cause = SocketException("Operation not permitted"),
        )

        assertEquals(
            "loopback origin failed: SocketException: Operation not permitted",
            OriginFailure.startReason(failure),
        )
    }

    @Test
    fun aWrapperWithoutCauseFallsBackToWhatTheOriginRecorded() {
        val failure = LoopbackStartException(configuredPort = 41234)

        assertEquals(
            "loopback origin failed: SocketException: bind failed",
            OriginFailure.startReason(failure, SocketException("bind failed")),
        )
    }

    @Test
    fun aNonOriginStartFailureKeepsItsOwnReason() {
        val failure = IllegalStateException("the worker bundle is missing")

        assertEquals(
            "IllegalStateException: the worker bundle is missing",
            OriginFailure.startReason(failure),
        )
        // A stale origin record must not rewrite an unrelated start failure.
        assertEquals(
            OriginFailure.startReason(failure),
            OriginFailure.startReason(failure, SocketException("Operation not permitted")),
        )
    }

    @Test
    fun aRunningOriginDeathReportsTheCauseAndTheFailureCount() {
        assertEquals(
            "loopback origin failed: SocketException: Operation not permitted (engineFailures=2)",
            OriginFailure.runtimeReason(SocketException("Operation not permitted"), engineFailures = 2),
        )
    }

    @Test
    fun aUrlInAFailureLosesItsTokenAndItsAddress() {
        val failure = SocketException(
            "connect to http://127.0.0.1:41234/launch?token=deadbeef failed",
        )

        val reason = OriginFailure.runtimeReason(failure, engineFailures = 1)

        assertFalse(reason, reason.contains("token"))
        assertFalse(reason, reason.contains("deadbeef"))
        assertFalse(reason, reason.contains("127.0.0.1"))
        assertTrue(reason, reason.contains("<url>"))
        assertTrue(reason, reason.startsWith(OriginFailure.PREFIX))
    }
}
