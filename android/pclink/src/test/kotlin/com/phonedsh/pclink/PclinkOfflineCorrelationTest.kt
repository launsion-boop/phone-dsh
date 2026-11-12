// SPDX-License-Identifier: MIT
// C4 `relay.offline` correlation (§9.1/§10). A frame that echoes `id` or
// `streamId` settles exactly that call/stream as `peer_offline` (the frame was
// not delivered); a `sid`-only frame follows §7 (`unsafe` becomes
// `unknown_outcome`, `read`/`idempotent` retry). A stale peer/session/id frame
// must not settle this session's work. The integration cases drive the real
// `PclinkClient` + `PclinkE2eSession` over `FakePc`; the correlation cases drive
// the real `PclinkRpc` state machine. The "other sid/id" values are read from
// the shared `schema-samples.json` golden.
package com.phonedsh.pclink

import com.phonedsh.agentcore.JsonObject
import java.time.Duration
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkOfflineCorrelationTest {
    private class Harness(
        val phone: PclinkIdentity,
        val pc: PclinkIdentity,
        val fakePc: FakePc,
        val relayFactory: FakeRelayFactory,
        val client: PclinkClient,
        val rpc: PclinkRpc,
        val transport: PclinkDshTransport,
    ) : AutoCloseable {
        fun link(): FakeRelayLink = relayFactory.connected.last()

        fun activeSid(): String =
            client.activeSession()?.sid ?: throw AssertionError("no established E2E session")

        override fun close() {
            runBlocking { client.stop() }
            rpc.close()
        }
    }

    private suspend fun connect(): Harness {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = "https://relay.example",
            pcName = "My PC",
            phoneMachineId = phone.machineId,
            phonePublicKey = phone.publicKey,
        )
        // Keep calls pending until the test delivers a result or an offline
        // frame; the default FakePc handler would answer immediately.
        fakePc.rpcCallHandler = { _, _ -> true }
        val factory = FakeRelayFactory(fakePc)
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(
                retryDeadline = Duration.ofSeconds(5),
                retryDelay = Duration.ofMillis(5),
                sessionPollInterval = Duration.ofMillis(5),
            ),
        )
        val client = PclinkClient(
            identityStore = C4IdentityStore(phone.seed),
            pairingStore = C4PairingStore(c4RecordFor(pc)),
            relayLinkFactory = factory,
            configuration = PclinkClientConfiguration(
                handshakeStepTimeout = Duration.ofSeconds(3),
            ),
            rpcHost = rpc,
        )
        rpc.attach(client)
        withTimeout(10_000) { client.connectAndWait() }
        return Harness(phone, pc, fakePc, factory, client, rpc, PclinkDshTransport(rpc))
    }

    private fun emptyArgs(): PclinkJson = pclinkObject("_request" to pclinkObject())

    private fun emptyDshArgs(): JsonObject =
        JsonObject(linkedMapOf("_request" to JsonObject(emptyMap())))

    private fun offline(
        harness: Harness,
        id: String? = null,
        streamId: String? = null,
        sid: String? = null,
    ): PclinkJson = FakeRelay.offline(
        to = harness.pc.machineId,
        id = id,
        streamId = streamId,
        sid = sid,
    )

    /** The shared golden `relay.offline` sample (a real frame from `spec/`). */
    private fun goldenOffline(): PclinkJson {
        val entry = TestSupport.objects(TestSupport.schemaSamples(), "valid")
            .single { TestSupport.string(it, "name") == "offline" }
        return TestSupport.at(entry, "value") ?: throw AssertionError("missing golden relay.offline value")
    }

    @Test
    fun matchingIdSettlesAnInFlightReadCallAsPeerOffline() = runBlocking {
        val harness = connect()
        try {
            supervisorScope {
                val call = async { harness.transport.call("session/list", emptyDshArgs()) }
                c4Await { harness.fakePc.rpcCalls.size == 1 }
                val id = harness.fakePc.rpcCalls[0].requiredString("id")
                harness.link().deliver(offline(harness, id = id, sid = harness.activeSid()))
                val error = try {
                    withTimeout(5_000) { call.await() }
                    null
                } catch (thrown: PclinkRpcError) {
                    thrown
                }
                assertEquals("peer_offline", error?.code)
                assertEquals(
                    PclinkOfflineReason.PeerOffline,
                    (harness.client.status().state as? PclinkClientState.Offline)?.reason,
                )
            }
        } finally {
            harness.close()
        }
    }

    @Test
    fun sidOnlyOfflineMakesAnInFlightUnsafeCallUnknownOutcomeAndDoesNotResend() = runBlocking {
        val harness = connect()
        try {
            supervisorScope {
                val call = async {
                    harness.rpc.call("commands/execute", pclinkObject("command" to PclinkJson.Text("status")))
                }
                c4Await { harness.fakePc.rpcCalls.size == 1 }
                harness.link().deliver(offline(harness, sid = harness.activeSid()))
                val error = try {
                    withTimeout(5_000) { call.await() }
                    null
                } catch (thrown: PclinkError) {
                    thrown
                }
                assertEquals("unknown_outcome", error?.code)
                // §10: an unsafe frame already sent is never resent.
                delay(150)
                assertEquals(1, harness.fakePc.rpcCalls.size)
            }
        } finally {
            harness.close()
        }
    }

    @Test
    fun matchingIdOnUnsafeCallIsPeerOfflineBecauseTheFrameWasNotDelivered() = runBlocking {
        val harness = connect()
        try {
            supervisorScope {
                val call = async {
                    harness.rpc.call("commands/execute", pclinkObject("command" to PclinkJson.Text("status")))
                }
                c4Await { harness.fakePc.rpcCalls.size == 1 }
                val id = harness.fakePc.rpcCalls[0].requiredString("id")
                harness.link().deliver(offline(harness, id = id, sid = harness.activeSid()))
                val error = try {
                    withTimeout(5_000) { call.await() }
                    null
                } catch (thrown: PclinkError) {
                    thrown
                }
                assertEquals("peer_offline", error?.code)
                delay(100)
                assertEquals(1, harness.fakePc.rpcCalls.size)
            }
        } finally {
            harness.close()
        }
    }

    @Test
    fun offlineForAnotherSidOrIdDoesNotSettleThisSessionsCall() = runBlocking {
        val harness = connect()
        try {
            val golden = goldenOffline()
            val otherId = TestSupport.requireString(golden, "id")
            val otherSid = TestSupport.requireString(golden, "sid")
            supervisorScope {
                val call = async { harness.rpc.call("session/list", emptyArgs()) }
                c4Await { harness.fakePc.rpcCalls.size == 1 }
                val liveId = harness.fakePc.rpcCalls[0].requiredString("id")
                val liveSid = harness.activeSid()
                assertNotEquals(otherId, liveId)
                assertNotEquals(otherSid, liveSid)

                // Another sid with our id: a stale session, not this one.
                harness.link().deliver(offline(harness, id = liveId, sid = otherSid))
                delay(150)
                assertFalse("another sid must not settle this call", call.isCompleted)

                // Another id on our sid: that frame was not ours.
                harness.link().deliver(offline(harness, id = otherId, sid = liveSid))
                delay(150)
                assertFalse("another id must not settle this call", call.isCompleted)
                assertEquals(1, harness.fakePc.rpcCalls.size)

                // The session is still usable and the pending call still completes.
                harness.fakePc.sendInner(
                    harness.link(),
                    c4ResultFrame(liveId, pclinkObject("items" to PclinkJson.Array(emptyList()))),
                )
                assertEquals(
                    emptyList<PclinkJson>(),
                    call.await()["items"]?.arrayValue,
                )
                assertTrue(harness.client.status().state.isOnline)
            }
        } finally {
            harness.close()
        }
    }

    @Test
    fun offlineForAnotherPeerIsIgnored() = runBlocking {
        val harness = connect()
        try {
            val golden = goldenOffline()
            supervisorScope {
                val call = async { harness.rpc.call("session/list", emptyArgs()) }
                c4Await { harness.fakePc.rpcCalls.size == 1 }
                val liveId = harness.fakePc.rpcCalls[0].requiredString("id")
                // The golden `to` is a different machineId; deliver it unchanged.
                harness.link().deliver(golden)
                delay(150)
                assertFalse(call.isCompleted)
                assertTrue(harness.client.status().state.isOnline)
                harness.fakePc.sendInner(
                    harness.link(),
                    c4ResultFrame(liveId, pclinkObject("items" to PclinkJson.Array(emptyList()))),
                )
                assertEquals(emptyList<PclinkJson>(), call.await()["items"]?.arrayValue)
            }
        } finally {
            harness.close()
        }
    }

    @Test
    fun offlineWithNoCallsInFlightOfflinesTheSession() = runBlocking {
        val harness = connect()
        try {
            assertTrue(harness.fakePc.rpcCalls.isEmpty())
            harness.link().deliver(offline(harness, sid = harness.activeSid()))
            c4Await {
                (harness.client.status().state as? PclinkClientState.Offline)?.reason ==
                    PclinkOfflineReason.PeerOffline
            }
            assertTrue(harness.fakePc.rpcCalls.isEmpty())
        } finally {
            harness.close()
        }
    }

    @Test
    fun clientReconnectsAfterOfflineAndTheNewSessionWorks() = runBlocking {
        val harness = connect()
        try {
            val firstSid = harness.activeSid()
            harness.link().deliver(offline(harness, sid = firstSid))
            c4Await {
                (harness.client.status().state as? PclinkClientState.Offline)?.reason ==
                    PclinkOfflineReason.PeerOffline
            }
            withTimeout(10_000) { harness.client.connectAndWait() }
            assertTrue(harness.client.status().state.isOnline)
            val secondSid = harness.activeSid()
            assertNotEquals(firstSid, secondSid)
            assertEquals(2, harness.relayFactory.dialCount)

            harness.fakePc.rpcCallHandler = null
            val result = harness.rpc.call("session/list", emptyArgs())
            assertEquals(emptyList<PclinkJson>(), result["items"]?.arrayValue)
            assertEquals(1, harness.fakePc.rpcCalls.size)
        } finally {
            harness.close()
        }
    }

    @Test
    fun invalidOfflineFrameIsAProtocolErrorAndClosesTheConnection() = runBlocking {
        val harness = connect()
        try {
            val invalid = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("relay.offline"),
                "to" to PclinkJson.Text(harness.pc.machineId),
                "sid" to PclinkJson.Text("not a valid sid!"),
            )
            harness.link().deliver(invalid)
            c4Await {
                (harness.client.status().state as? PclinkClientState.Offline)?.reason ==
                    PclinkOfflineReason.ProtocolError("bad_frame")
            }
            assertNotNull(harness.client.status().lastError)
        } finally {
            harness.close()
        }
    }
}

/** Correlation rules at the owner (`PclinkRpc`), including streams. */
class PclinkRpcOfflineCorrelationTest {
    private fun configuration(): PclinkRpcConfiguration = PclinkRpcConfiguration(
        retryDeadline = Duration.ofSeconds(1),
        retryDelay = Duration.ofMillis(5),
        sessionPollInterval = Duration.ofMillis(5),
    )

    private fun offline(
        id: String? = null,
        streamId: String? = null,
        sid: String? = null,
    ): PclinkRelayOffline = PclinkRelayOffline(
        to = "gewra3lzquaxpctdtkvzv2drdp",
        id = id,
        streamId = streamId,
        sid = sid,
        frame = pclinkObject("type" to PclinkJson.Text("relay.offline")),
    )

    @Test
    fun aMatchingStreamIdSettlesTheOpenStreamAsPeerOffline() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(configuration())
        rpc.attach(channel)
        try {
            val stream = rpc.openStream("workspace/follow", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            val sid = channel.session?.sid ?: throw AssertionError("no session")
            assertTrue(rpc.onRelayOffline(offline(streamId = stream.id, sid = sid)))
            val error = try {
                stream.next()
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("peer_offline", error?.code)
        } finally {
            rpc.close()
        }
    }

    @Test
    fun sidOnlyOfflineSettlesAnUnsafeStreamAsUnknownOutcome() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(configuration())
        rpc.attach(channel)
        try {
            val stream = rpc.openStream("custom/stream", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            val sid = channel.session?.sid ?: throw AssertionError("no session")
            assertTrue(rpc.onRelayOffline(offline(sid = sid)))
            val error = try {
                stream.next()
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("unknown_outcome", error?.code)
        } finally {
            rpc.close()
        }
    }

    @Test
    fun staleSidDoesNotSettleACallOnTheLiveSession() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(configuration())
        rpc.attach(channel)
        try {
            supervisorScope {
                val call = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
                c4Await { channel.frames("rpc.call").size == 1 }
                val id = channel.frames("rpc.call")[0].requiredString("id")
                val liveSid = channel.session?.sid ?: throw AssertionError("no session")
                val staleSid = "A".repeat(22)
                assertFalse(rpc.onRelayOffline(offline(id = id, sid = staleSid)))
                delay(100)
                assertFalse(call.isCompleted)
                assertNotEquals(liveSid, staleSid)
                rpc.sendInner(c4ResultFrame(id, pclinkObject("ok" to PclinkJson.Bool(true))))
                assertEquals(PclinkJson.Bool(true), call.await()["ok"])
            }
        } finally {
            rpc.close()
        }
    }
}
