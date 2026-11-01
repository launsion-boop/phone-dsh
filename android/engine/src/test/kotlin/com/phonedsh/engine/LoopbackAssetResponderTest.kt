// phone-dsh — :engine tests: the asset interceptor must not shadow the model edge.
// SPDX-License-Identifier: MIT
//
// Regression for the M2 wiring: the Worker's model client POSTs to `/v1/messages`
// on the same loopback origin, and `shouldInterceptRequest` sees that request
// before the network stack does. Before this rule the responder answered it with
// its own 405 and the `:net` model proxy was never reached (measured on
// emulator-5554: `bundle: POST /v1/messages -> 405`). The interceptor's own job
// is narrower: only a GET/HEAD that maps to a materialized bundle file.

package com.phonedsh.engine

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LoopbackAssetResponderTest {
    private val responder = LoopbackAssetResponder(
        store = WorkerFileStore(Files.createTempDirectory("pdsh-asset-responder-test")),
        port = 1234,
        logger = RecordingEngineLogger(),
    )

    @Test
    fun onlyFileReadsAreAnsweredByTheInterceptor() {
        assertTrue(responder.isStaticRead("GET"))
        assertTrue(responder.isStaticRead("HEAD"))
    }

    @Test
    fun theModelClientsPostFallsThroughToTheOrigin() {
        // The model edge is a Ktor route; a 405 produced here never reaches it.
        assertFalse(responder.isStaticRead("POST"))
        assertFalse(responder.isStaticRead("PUT"))
        assertFalse(responder.isStaticRead("OPTIONS"))
        assertFalse(responder.isStaticRead("get"))
        assertFalse(responder.isStaticRead(""))
    }
}
