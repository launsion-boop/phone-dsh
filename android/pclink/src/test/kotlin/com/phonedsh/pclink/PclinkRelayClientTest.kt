// SPDX-License-Identifier: MIT
// C3 relay transport tests. The production PclinkRelayClient is driven through
// the in-memory PclinkWebSocket seam and the shared golden document read from
// disk: relay_auth (origin/nonce/transcript/signatures), frames outer grammar,
// and the invalid rows (origin, replay, unknown_code, frame, size). No relay is
// contacted.
package com.phonedsh.pclink

import kotlin.random.Random
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkRelayClientTest {
    private val phone = TestSupport.identity("pclink-v1/test/identity/phone")
    private val pc = TestSupport.identity("pclink-v1/test/identity/pc")
    private val origin = "https://relay.example"

    private fun relayAuth() = TestSupport.at(TestSupport.vectors(), "relay_auth")
        ?: throw AssertionError("missing relay_auth")

    private fun relayNonce(): ByteArray =
        TestSupport.b64(relayAuth(), "nonce") ?: throw AssertionError("missing relay nonce")

    private fun invalidRows(kind: String): List<PclinkJson> =
        TestSupport.objects(TestSupport.vectors(), "invalid")
            .filter { TestSupport.string(it, "kind") == kind }

    private fun invalidRow(caseName: String): PclinkJson =
        TestSupport.objects(TestSupport.vectors(), "invalid")
            .single { TestSupport.string(it, "case") == caseName }

    private fun handshakeSid(): String = TestSupport.requireString(
        TestSupport.at(TestSupport.vectors(), "handshake"),
        "sid",
    )

    private fun client(
        socketFactory: PclinkWebSocketFactory,
        role: String = "phone",
        identity: PclinkIdentity = phone,
        heartbeat: Boolean = false,
        heartbeatRangeMillis: LongRange = 20L..20L,
        challengeTimeoutMillis: Long = 2_000,
        readyTimeoutMillis: Long = 2_000,
        frameLimitBytes: Int = PclinkLimits.MAX_RELAY_FRAME_BYTES,
        pacer: PclinkPacer = PclinkPacer(),
    ): PclinkRelayClient = PclinkRelayClient(
        configuration = PclinkRelayClient.Configuration(
            origin = origin,
            identity = identity,
            role = role,
            challengeTimeoutMillis = challengeTimeoutMillis,
            readyTimeoutMillis = readyTimeoutMillis,
            heartbeatRangeMillis = heartbeatRangeMillis,
            heartbeatEnabled = heartbeat,
            frameLimitBytes = frameLimitBytes,
        ),
        socketFactory = socketFactory,
        pacer = pacer,
        random = Random(11),
    )

    /** Connects a client whose scripted relay performs the normal handshake. */
    private suspend fun connected(
        scope: CoroutineScope,
        nonce: ByteArray = relayNonce(),
        machineId: String = phone.machineId,
        role: String = "phone",
        identity: PclinkIdentity = phone,
        heartbeat: Boolean = false,
        heartbeatRangeMillis: LongRange = 20L..20L,
        challengeTimeoutMillis: Long = 2_000,
        readyTimeoutMillis: Long = 2_000,
        frameLimitBytes: Int = PclinkLimits.MAX_RELAY_FRAME_BYTES,
        pacer: PclinkPacer = PclinkPacer(),
    ): Pair<PclinkRelayClient, FakeWebSocket> {
        val factory = FakeWebSocketFactory(scope) { socket, _ ->
            FakeRelay.handshake(socket, origin, nonce, machineId, role)
        }
        val relay = client(
            factory,
            role = role,
            identity = identity,
            heartbeat = heartbeat,
            heartbeatRangeMillis = heartbeatRangeMillis,
            challengeTimeoutMillis = challengeTimeoutMillis,
            readyTimeoutMillis = readyTimeoutMillis,
            frameLimitBytes = frameLimitBytes,
            pacer = pacer,
        )
        relay.connect()
        return relay to factory.last
    }

    /** Drains [PclinkRelayClient.incoming] until it completes; returns the terminal error. */
    private suspend fun awaitIncomingFailure(relay: PclinkRelayClient): PclinkError =
        withTimeout(5_000) {
            try {
                relay.incoming.collect { /* drain frames until the terminal error */ }
                throw AssertionError("incoming completed without the expected PclinkError")
            } catch (error: PclinkError) {
                error
            }
        }

    private suspend fun awaitClose(relay: PclinkRelayClient) {
        withTimeout(5_000) {
            while (relay.closeCode == null) delay(5)
        }
    }

    // ---- frames / invalid rows ------------------------------------------

    @Test
    fun goldenFramesReachTheUpperLayerUnchanged() = runBlocking {
        val rows = TestSupport.objects(TestSupport.vectors(), "frames")
        assertEquals(9, rows.size)
        val (relay, socket) = connected(this)
        val received = async {
            withTimeout(5_000) { relay.incoming.take(rows.size).toList() }
        }
        for (row in rows) socket.deliver(outerFrame(row))
        val frames = received.await()
        for (index in rows.indices) {
            val row = rows[index]
            val frame = frames[index]
            val case = TestSupport.requireString(row, "case")
            PclinkWire.validateE2EFrame(frame)
            assertEquals("$case sid", row["sid"], frame["sid"])
            assertEquals("$case seq", row["seq"], frame["seq"])
            assertEquals("$case from", row["from"], frame["from"])
            assertEquals("$case to", row["to"], frame["to"])
            assertEquals("$case body", row["body"], frame["body"])
        }
        relay.close(1000, "")
    }

    private fun outerFrame(row: PclinkJson): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("e2e"),
        "sid" to PclinkJson.Text(TestSupport.requireString(row, "sid")),
        "seq" to PclinkJson.Integer(TestSupport.requireInt(row, "seq")),
        "from" to PclinkJson.Text(TestSupport.requireString(row, "from")),
        "to" to PclinkJson.Text(TestSupport.requireString(row, "to")),
        "body" to PclinkJson.Text(TestSupport.requireString(row, "body")),
    )

    // ---- relay_auth ------------------------------------------------------

    @Test
    fun relayAuthGoldenTranscriptAndSignatureAreExact() = runBlocking {
        val nonce = relayNonce()
        val goldenPhone = TestSupport.at(relayAuth(), "phone")
            ?: throw AssertionError("missing phone auth")
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.challenge(origin, nonce))
            socket.awaitSent("peer.auth")
            socket.deliver(FakeRelay.ready(phone.machineId, "phone"))
        }
        val relay = client(factory)
        try {
            relay.connect()
            val auth = factory.last.awaitSent("peer.auth")
            assertEquals(goldenPhone["machine_id"]?.stringValue, auth["machineId"]?.stringValue)
            assertEquals(goldenPhone["public_key"]?.stringValue, auth["publicKey"]?.stringValue)
            assertEquals("phone", auth["role"]?.stringValue)
            val signature = PclinkBase64Url.decode(
                auth.requiredString("sig"),
                expectedLength = 64,
            )
            val transcript = PclinkCrypto.relayAuthTranscript(origin, nonce)
            assertEquals(
                "relay_auth transcript_hex",
                TestSupport.requireString(relayAuth(), "transcript_hex"),
                PclinkHex.encode(transcript),
            )
            assertTrue(
                "golden phone signature",
                PclinkCrypto.ed25519Verify(phone.publicKey, transcript, signature),
            )
            // Ed25519 signing is deterministic, so the wires bytes equal the
            // golden row exactly; this is the golden `relay_auth.phone` case.
            assertEquals(
                goldenPhone["signature"]?.stringValue,
                PclinkBase64Url.encode(signature),
            )
            assertEquals(PclinkRelayClient.State.READY, relay.state)
            assertTrue(factory.urls.single().startsWith("wss://relay.example/"))
        } finally {
            relay.close(1000, "")
        }
    }

    @Test
    fun relayAuthGoldenPcSignatureIsExact() = runBlocking {
        // The relay client is role-generic; the Android client is the phone but
        // the frozen relay_auth row is required for both roles.
        val nonce = relayNonce()
        val goldenPc = TestSupport.at(relayAuth(), "pc")
            ?: throw AssertionError("missing pc auth")
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.challenge(origin, nonce))
            socket.awaitSent("peer.auth")
            socket.deliver(FakeRelay.ready(pc.machineId, "pc"))
        }
        val relay = client(factory, role = "pc", identity = pc)
        try {
            relay.connect()
            val auth = factory.last.awaitSent("peer.auth")
            assertEquals(goldenPc["machine_id"]?.stringValue, auth["machineId"]?.stringValue)
            assertEquals(goldenPc["public_key"]?.stringValue, auth["publicKey"]?.stringValue)
            assertEquals("pc", auth["role"]?.stringValue)
            val signature = PclinkBase64Url.decode(
                auth.requiredString("sig"),
                expectedLength = 64,
            )
            val transcript = PclinkCrypto.relayAuthTranscript(origin, nonce)
            assertTrue(
                "golden pc signature",
                PclinkCrypto.ed25519Verify(pc.publicKey, transcript, signature),
            )
            assertEquals(
                goldenPc["signature"]?.stringValue,
                PclinkBase64Url.encode(signature),
            )
        } finally {
            relay.close(1000, "")
        }
    }

    @Test
    fun everyFreshChallengeIsSignedAgainstItsOwnNonce() = runBlocking {
        val signatures = mutableListOf<String>()
        val transcripts = mutableListOf<String>()
        for (index in 0 until 2) {
            val nonce = PclinkRandom.bytes(32)
            val factory = FakeWebSocketFactory(this) { socket, _ ->
                FakeRelay.handshake(socket, origin, nonce, phone.machineId)
            }
            val relay = client(factory)
            relay.connect()
            val auth = factory.last.awaitSent("peer.auth")
            val signature = PclinkBase64Url.decode(auth.requiredString("sig"), expectedLength = 64)
            val transcript = PclinkCrypto.relayAuthTranscript(origin, nonce)
            assertTrue(
                "connection $index signature verifies against its challenge nonce",
                PclinkCrypto.ed25519Verify(phone.publicKey, transcript, signature),
            )
            signatures += PclinkBase64Url.encode(signature)
            transcripts += PclinkHex.encode(transcript)
            relay.close(1000, "")
        }
        assertNotEquals("a replayed challenge must not reuse a signature", signatures[0], signatures[1])
        assertNotEquals(transcripts[0], transcripts[1])
    }

    // ---- invalid: origin -------------------------------------------------

    @Test
    fun goldenOriginRowsFailAuthWithoutSigning() = runBlocking {
        val rows = invalidRows("origin")
        assertEquals(2, rows.size)
        for (row in rows) {
            val case = TestSupport.requireString(row, "case")
            val actual = TestSupport.requireString(row, "actual")
            val expectedOrigin = TestSupport.requireString(row, "expected_origin")
            assertNotEquals(expectedOrigin, actual)
            val factory = FakeWebSocketFactory(this) { socket, _ ->
                socket.deliver(FakeRelay.challenge(actual, relayNonce()))
            }
            val relay = client(factory)
            val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
            assertTrue("$case: expected AuthFailed, got $failure", failure is PclinkError.AuthFailed)
            assertEquals("auth_failed", (failure as PclinkError).code)
            assertEquals("$case close code", 4002, relay.closeCode)
            assertTrue("$case must not sign", factory.last.frames("peer.auth").isEmpty())
            assertEquals(PclinkRelayClient.State.CLOSED, relay.state)
        }
    }

    // ---- invalid: replay (duplicate handshake frames) --------------------

    @Test
    fun replayedChallengeAfterReadyIsBadFrame() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val nonce = relayNonce()
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            FakeRelay.handshake(socket, origin, nonce, phone.machineId)
            release.await()
            socket.deliver(FakeRelay.challenge(origin, nonce))
        }
        val relay = client(factory)
        relay.connect()
        release.complete(Unit)
        val error = awaitIncomingFailure(relay)
        assertTrue("expected BadFrame, got $error", error is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun replayedReadyAfterReadyIsBadFrame() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            FakeRelay.handshake(socket, origin, relayNonce(), phone.machineId)
            release.await()
            socket.deliver(FakeRelay.ready(phone.machineId, "phone"))
        }
        val relay = client(factory)
        relay.connect()
        release.complete(Unit)
        val error = awaitIncomingFailure(relay)
        assertTrue("expected BadFrame, got $error", error is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun peerAuthFromTheRelayIsBadFrame() = runBlocking {
        val (relay, socket) = connected(this)
        socket.deliver(
            pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("peer.auth"),
                "machineId" to PclinkJson.Text(phone.machineId),
                "publicKey" to PclinkJson.Text(PclinkBase64Url.encode(phone.publicKey)),
                "role" to PclinkJson.Text("phone"),
                "sig" to PclinkJson.Text(PclinkBase64Url.encode(ByteArray(64))),
            ),
        )
        val error = awaitIncomingFailure(relay)
        assertTrue("expected BadFrame, got $error", error is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    // ---- invalid: unknown_code / frame / size ----------------------------

    @Test
    fun goldenUnknownPclinkCodeIsBadFrame() = runBlocking {
        val row = invalidRow("unknown-pclink-code")
        val code = TestSupport.requireString(row, "code")
        val (relay, socket) = connected(this)
        socket.deliver(FakeRelay.error(code))
        val error = awaitIncomingFailure(relay)
        assertTrue("unknown $code must be bad_frame, got $error", error is PclinkError.BadFrame)
        assertEquals("bad_frame", error.code)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun goldenFrameMissingToIsBadFrame() = runBlocking {
        val row = invalidRow("frame-missing-to")
        val frame = TestSupport.at(row, "frame") ?: throw AssertionError("frame row")
        val (relay, socket) = connected(this)
        socket.deliver(frame)
        val error = awaitIncomingFailure(relay)
        assertTrue("missing to must be bad_frame, got $error", error is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun goldenOversizedFrameIsFrameTooLarge() = runBlocking {
        val row = invalidRow("frame-too-large")
        val bytes = TestSupport.requireInt(row, "bytes")
        val limit = TestSupport.requireInt(row, "limit")
        assertEquals(PclinkLimits.MAX_RELAY_FRAME_BYTES.toLong(), limit)
        assertTrue(bytes > limit)
        val (relay, socket) = connected(this)
        socket.deliverText("x".repeat(bytes.toInt()))
        val error = awaitIncomingFailure(relay)
        assertTrue("expected frame_too_large, got $error", error is PclinkError.FrameTooLarge)
        assertEquals("frame_too_large", error.code)
        assertEquals(1009, relay.closeCode)
    }

    @Test
    fun binaryRelayFrameCloses1003() = runBlocking {
        val (relay, socket) = connected(this)
        socket.deliverBinary(byteArrayOf(1, 2, 3))
        val error = awaitIncomingFailure(relay)
        assertTrue("expected BadFrame, got $error", error is PclinkError.BadFrame)
        assertEquals(1003, relay.closeCode)
    }

    // ---- relay.ready / 10 s auth window ----------------------------------

    @Test
    fun readyMachineIdOrRoleMismatchFailsAuth() = runBlocking {
        val cases = listOf(
            Triple("machineId", pc.machineId, "phone"),
            Triple("role", phone.machineId, "pc"),
        )
        for ((label, machineId, role) in cases) {
            val factory = FakeWebSocketFactory(this) { socket, _ ->
                FakeRelay.handshake(socket, origin, relayNonce(), machineId, role)
            }
            val relay = client(factory)
            val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
            assertTrue("$label: expected AuthFailed, got $failure", failure is PclinkError.AuthFailed)
            assertEquals(4002, relay.closeCode)
        }
    }

    @Test
    fun readyBeforeChallengeIsBadFrame() = runBlocking {
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.ready(phone.machineId, "phone"))
        }
        val relay = client(factory)
        val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
        assertTrue("expected BadFrame, got $failure", failure is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun frameBeforeReadyIsBadFrame() = runBlocking {
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.challenge(origin, relayNonce()))
            socket.awaitSent("peer.auth")
            socket.deliver(FakeRelay.e2e(handshakeSid(), 0, phone.machineId, pc.machineId))
        }
        val relay = client(factory)
        val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
        assertTrue("expected BadFrame, got $failure", failure is PclinkError.BadFrame)
        assertEquals(1008, relay.closeCode)
    }

    @Test
    fun challengeTimeoutCloses4002AndIsRetryable() = runBlocking {
        val factory = FakeWebSocketFactory(this) { _, _ -> }
        val relay = client(factory, challengeTimeoutMillis = 50)
        val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
        assertTrue("expected Unavailable, got $failure", failure is PclinkError.Unavailable)
        assertEquals(4002, relay.closeCode)
    }

    @Test
    fun readyTimeoutFailsAuthAndCloses4002() = runBlocking {
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.challenge(origin, relayNonce()))
            socket.awaitSent("peer.auth")
        }
        val relay = client(factory, readyTimeoutMillis = 50)
        val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
        assertTrue("expected AuthFailed, got $failure", failure is PclinkError.AuthFailed)
        assertEquals(4002, relay.closeCode)
    }

    @Test
    fun relayAuthFailureBeforeReadyFailsAuth() = runBlocking {
        val factory = FakeWebSocketFactory(this) { socket, _ ->
            socket.deliver(FakeRelay.challenge(origin, relayNonce()))
            socket.awaitSent("peer.auth")
            socket.deliver(FakeRelay.error("auth_failed", message = "bad signature"))
        }
        val relay = client(factory)
        val failure = runCatching { withTimeout(2_000) { relay.connect() } }.exceptionOrNull()
        assertTrue("expected AuthFailed, got $failure", failure is PclinkError.AuthFailed)
        assertEquals("auth_failed", (failure as PclinkError).code)
        assertEquals(4002, relay.closeCode)
    }

    // ---- heartbeats ------------------------------------------------------

    @Test
    fun heartbeatTimeoutCloses1001AfterAMissedPong() = runBlocking {
        val (relay, socket) = connected(this, heartbeat = true, heartbeatRangeMillis = 20L..20L)
        awaitClose(relay)
        assertEquals(1001, relay.closeCode)
        assertTrue("at least one ping", socket.frames("relay.ping").isNotEmpty())
        assertTrue("the client closes 1001", socket.closeCalled.get())
        assertEquals(1001, socket.closedCode)
    }

    @Test
    fun clientAnswersRelayPingWithTheSameNonce() = runBlocking {
        val (relay, socket) = connected(this)
        val nonce = PclinkRandom.bytes(16)
        socket.deliver(FakeRelay.ping(nonce))
        val pong = socket.awaitSent("relay.pong")
        assertEquals(PclinkBase64Url.encode(nonce), pong["nonce"]?.stringValue)
        assertEquals(PclinkRelayClient.State.READY, relay.state)
        relay.close(1000, "")
    }

    @Test
    fun pongForAnOldNonceIsIgnoredAndDoesNotKeepTheConnectionAlive() = runBlocking {
        val (relay, socket) = connected(this, heartbeat = true, heartbeatRangeMillis = 100L..100L)
        socket.awaitSent("relay.ping")
        socket.deliver(FakeRelay.pong(PclinkRandom.bytes(16)))
        awaitClose(relay)
        assertEquals(1001, relay.closeCode)
        // If the stale pong had cleared the outstanding ping, a second ping
        // would have been written before the timeout.
        assertEquals("stale pong must be ignored", 1, socket.frames("relay.ping").size)
    }

    // ---- relay.allow / relay.offline / relay.error -----------------------

    @Test
    fun onlyPcRoleMaySendRelayAllow() = runBlocking {
        val (phoneRelay, _) = connected(this)
        val phoneFailure = runCatching {
            phoneRelay.send(FakeRelay.allow(listOf(pc.machineId)))
        }.exceptionOrNull()
        assertTrue("phone must not send relay.allow", phoneFailure is PclinkError.BadFrame)
        phoneRelay.close(1000, "")

        val (pcRelay, pcSocket) = connected(
            this,
            machineId = pc.machineId,
            role = "pc",
            identity = pc,
        )
        pcRelay.send(FakeRelay.allow(listOf(phone.machineId)))
        val allow = pcSocket.awaitSent("relay.allow")
        assertEquals(
            listOf(phone.machineId),
            allow["peers"]?.arrayValue?.mapNotNull { it.stringValue },
        )
        pcRelay.close(1000, "")
    }

    @Test
    fun relayOfflineKeepsTheIdOrSidCorrelation() = runBlocking {
        val (relay, socket) = connected(this)
        val sid = handshakeSid()
        val received = async {
            withTimeout(3_000) { relay.incoming.take(2).toList() }
        }
        socket.deliver(
            FakeRelay.offline(phone.machineId, id = "call-1", streamId = "stream-1", sid = sid),
        )
        socket.deliver(FakeRelay.offline(phone.machineId, sid = sid))
        val (withId, withoutId) = received.await()
        assertEquals("relay.offline", withId["type"]?.stringValue)
        assertEquals("call-1", withId["id"]?.stringValue)
        assertEquals("stream-1", withId["streamId"]?.stringValue)
        assertEquals(sid, withId["sid"]?.stringValue)
        assertEquals("relay.offline", withoutId["type"]?.stringValue)
        assertNull("a sid-only offline says nothing about one frame", withoutId["id"]?.stringValue)
        assertEquals(sid, withoutId["sid"]?.stringValue)
        relay.close(1000, "")
    }

    @Test
    fun replacedErrorCloses4001AndThePolicyWaitsAtLeast30s() = runBlocking {
        val (relay, socket) = connected(this)
        socket.deliver(FakeRelay.error("replaced", message = "newer connection"))
        val error = awaitIncomingFailure(relay)
        assertTrue("expected Replaced, got $error", error is PclinkError.Replaced)
        assertEquals(4001, relay.closeCode)
        assertTrue(socket.closeCalled.get())
        assertEquals(4001, socket.closedCode)
        assertTrue(
            "replaced must wait at least 30 s",
            PclinkReconnectPolicy.V1.replacedDelaySeconds(1, 0.0) >= 30.0,
        )
    }

    @Test
    fun rateLimitedCarriesRetryAfterAndKeepsTheSocketOpen() = runBlocking {
        val (relay, socket) = connected(this)
        val sid = handshakeSid()
        val event = async {
            withTimeout(3_000) {
                relay.events.first { it is PclinkRelayEvent.Error }
            }
        }
        socket.deliver(
            FakeRelay.error("rate_limited", message = "slow down", retryAfterMs = 1_500, sid = sid),
        )
        val raised = event.await() as PclinkRelayEvent.Error
        assertTrue("expected RateLimited, got ${raised.error}", raised.error is PclinkError.RateLimited)
        assertEquals(1_500, (raised.error as PclinkError.RateLimited).retryAfterMs)
        assertEquals(1_500, raised.context.retryAfterMs)
        assertEquals(sid, raised.context.sid)
        assertEquals(PclinkRelayClient.State.READY, relay.state)
        assertFalse("rate_limited does not close the socket", socket.closeCalled.get())
        relay.close(1000, "")
    }

    @Test
    fun closeCodesWithoutAnErrorFrameAreClassified() = runBlocking {
        val cases = listOf(
            4001 to "replaced",
            4002 to "auth_failed",
            4003 to "rate_limited",
            4004 to "session_expired",
        )
        for ((code, expected) in cases) {
            val (relay, socket) = connected(this)
            socket.deliverClose(code, "relay said $code")
            val error = awaitIncomingFailure(relay)
            assertEquals("close $code", expected, error.code)
            assertEquals("close $code observed", code, relay.closeCode)
        }
    }

    @Test
    fun relayRedirectIsLoggedAndIgnored() = runBlocking {
        val (relay, socket) = connected(this)
        socket.deliver(
            pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("relay.redirect"),
                "url" to PclinkJson.Text("https://redirect.example"),
            ),
        )
        val next = async { withTimeout(3_000) { relay.incoming.first() } }
        socket.deliver(FakeRelay.e2e(handshakeSid(), 0, phone.machineId, pc.machineId))
        assertEquals("e2e", next.await()["type"]?.stringValue)
        assertEquals("redirect must not change the origin or state", PclinkRelayClient.State.READY, relay.state)
        relay.close(1000, "")
    }

    // ---- §3.8 pacing through the single writer ---------------------------

    @Test
    fun pacedFramesKeepSeqOrderAndAreNeverDropped() = runBlocking {
        val pacer = PclinkPacer(rateBytesPerSecond = 2_000.0, burstBytes = 1_000.0)
        val (relay, socket) = connected(this, pacer = pacer)
        val sid = handshakeSid()
        for (seq in 0 until 8L) {
            relay.send(FakeRelay.e2e(sid, seq, phone.machineId, pc.machineId, ByteArray(100)))
        }
        val frames = socket.frames("e2e")
        assertEquals("no frame may be dropped or coalesced", 8, frames.size)
        assertEquals(
            "pacing must preserve seal order",
            (0 until 8L).toList(),
            frames.mapNotNull { it["seq"]?.longValue },
        )
        val paced = socket.sent.filter { it.frame["type"]?.stringValue == "e2e" }
        assertEquals(8, paced.size)
        val span = paced.last().nanos - paced.first().nanos
        assertTrue("the writer waited for local tokens (span=${span / 1_000_000} ms)", span >= 150_000_000L)
        relay.close(1000, "")
    }

    // ---- reconnect policy (§10) ------------------------------------------

    @Test
    fun reconnectPolicyMatchesTheFrozenSteps() {
        val policy = PclinkReconnectPolicy.V1
        assertEquals(
            listOf(0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0),
            (1..8).map { policy.baseDelaySeconds(it) },
        )
        assertEquals("past the list repeats 30 s", 30.0, policy.baseDelaySeconds(99), 0.0)
        assertEquals("60 s reset", 60.0, policy.resetAfterSeconds, 0.0)
        // ±20 % jitter around the base.
        assertEquals(0.4, policy.delaySeconds(1, 0.0), 1e-9)
        assertEquals(0.5, policy.delaySeconds(1, 0.5), 1e-9)
        assertEquals(0.6, policy.delaySeconds(1, 1.0), 1e-9)
        assertEquals(36.0, policy.delaySeconds(8, 1.0), 1e-9)
        // Foreground resume caps the next attempt at the second step (≤1 s ±20 %).
        assertEquals(1.2, policy.resumeDelaySeconds(8, 1.0), 1e-9)
        assertEquals(0.4, policy.resumeDelaySeconds(1, 0.0), 1e-9)
        // Replaced never shortens the 30 s minimum.
        assertEquals(30.0, policy.replacedDelaySeconds(1, 0.0), 1e-9)
        assertEquals(30.0, policy.replacedDelaySeconds(8, 0.0), 1e-9)
        assertEquals(36.0, policy.replacedDelaySeconds(8, 1.0), 1e-9)
        // §3.8: a missing retryAfterMs still means at least 1 000 ms.
        assertEquals(1.0, policy.rateLimitedDelaySeconds(null), 0.0)
        assertEquals(1.0, policy.rateLimitedDelaySeconds(0), 0.0)
        assertEquals(1.5, policy.rateLimitedDelaySeconds(1_500), 1e-9)
    }

    @Test
    fun relayUrlMapsToTheCanonicalOrigin() {
        assertEquals(
            "https://relay.example",
            PclinkRelayClientFactory.originForWebSocketUrl("wss://relay.example/"),
        )
        assertEquals(
            "http://127.0.0.1:8080",
            PclinkRelayClientFactory.originForWebSocketUrl("ws://127.0.0.1:8080/"),
        )
        for (bad in listOf(
            "https://relay.example/",
            "wss://relay.example/path",
            "wss://relay.example",
            "wss://Relay.Example/",
            "ws://example.com/",
        )) {
            val failure = runCatching {
                PclinkRelayClientFactory.originForWebSocketUrl(bad)
            }.exceptionOrNull()
            assertTrue("$bad must be rejected, got $failure", failure is PclinkError.BadFrame)
        }
    }

    @Test
    fun factoryReturnsAnAuthenticatedC1Link() = runBlocking {
        val nonce = relayNonce()
        val socketFactory = FakeWebSocketFactory(this) { socket, _ ->
            FakeRelay.handshake(socket, origin, nonce, phone.machineId)
        }
        val factory = PclinkRelayClientFactory(
            identity = phone,
            heartbeatEnabled = false,
            socketFactory = socketFactory,
        )
        val link: PclinkRelayLink = factory.connect("wss://relay.example/")
        assertTrue(link is PclinkRelayClient)
        assertEquals(PclinkRelayClient.State.READY, (link as PclinkRelayClient).state)
        assertEquals("wss://relay.example/", socketFactory.urls.single())
        link.close(1000, "")
    }
}
