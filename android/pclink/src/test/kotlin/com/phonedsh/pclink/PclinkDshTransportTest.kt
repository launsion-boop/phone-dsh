// SPDX-License-Identifier: MIT
// C4 transport tests: a real `PclinkClient` + real `PclinkE2eSession` over the
// in-memory `FakePc`, driving `PclinkRpc` and `PclinkDshTransport`. No network:
// the PC half only uses the production crypto/state helpers, and the phone half
// is the production client. The DSH-facing values are `JsonValue`.
package com.phonedsh.pclink

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkDshTransportTest {
    private class Harness(
        val phone: PclinkIdentity,
        val pc: PclinkIdentity,
        val fakePc: FakePc,
        val client: PclinkClient,
        val rpc: PclinkRpc,
        val transport: PclinkDshTransport,
    ) : AutoCloseable {
        override fun close() {
            runBlocking { client.stop() }
            rpc.close()
        }
    }

    private suspend fun connect(
        rpcConfiguration: PclinkRpcConfiguration = PclinkRpcConfiguration(
            sessionPollInterval = Duration.ofMillis(10),
        ),
        clientConfiguration: PclinkClientConfiguration = PclinkClientConfiguration(
            handshakeStepTimeout = Duration.ofSeconds(3),
        ),
        configure: (FakePc) -> Unit = {},
    ): Harness {
        val phone = PclinkIdentity.generate()
        val pc = PclinkIdentity.generate()
        val fakePc = FakePc(
            pcIdentity = pc,
            origin = "https://relay.example",
            pcName = "My PC",
            phoneMachineId = phone.machineId,
            phonePublicKey = phone.publicKey,
        )
        configure(fakePc)
        val rpc = PclinkRpc(rpcConfiguration)
        val client = PclinkClient(
            identityStore = C4IdentityStore(phone.seed),
            pairingStore = C4PairingStore(c4RecordFor(pc)),
            relayLinkFactory = FakeRelayFactory(fakePc),
            configuration = clientConfiguration,
            rpcHost = rpc,
        )
        rpc.attach(client)
        withTimeout(10_000) { client.connectAndWait() }
        return Harness(phone, pc, fakePc, client, rpc, PclinkDshTransport(rpc))
    }

    private fun emptyArgs(): JsonObject = JsonObject(linkedMapOf("_request" to JsonObject(emptyMap())))

    @Test
    fun unaryCallRoundTripsThroughTheRealE2eSession() = runBlocking {
        val harness = connect()
        try {
            val args = emptyArgs()
            val result = harness.transport.call("session/list", args)
            assertTrue(result is JsonObject)
            val items = (result as JsonObject)["items"]
            assertTrue(items is JsonArray)
            assertTrue((items as JsonArray).values.isEmpty())
            assertEquals(1, harness.fakePc.rpcCalls.size)
            val call = harness.fakePc.rpcCalls[0]
            assertEquals("session/list", call.requiredString("endpoint"))
            assertEquals(args, call["args"]?.let(PclinkDshJson::toJsonValue))
            assertTrue("the client is still online", harness.client.status().state.isOnline)
            assertEquals(PclinkRetryClass.READ, PclinkEndpoints.retryClass("session/list"))
        } finally {
            harness.close()
        }
    }

    @Test
    fun forbiddenAdminEndpointIsRefusedLocally() = runBlocking {
        val harness = connect()
        try {
            val error = try {
                harness.transport.call("pclink.admin/status", JsonObject(emptyMap()))
                null
            } catch (thrown: PclinkRpcError) {
                thrown
            }
            assertEquals("forbidden", error?.code)
            assertTrue(harness.fakePc.rpcCalls.isEmpty())
        } finally {
            harness.close()
        }
    }

    @Test
    fun chunkedResultOverOneMiBIsReassembledByTheTransport() = runBlocking {
        val harness = connect()
        try {
            val blob = "x".repeat(1_200_000)
            harness.fakePc.rpcCallHandler = { link, call ->
                val id = call.requiredString("id")
                val result = pclinkObject(
                    "type" to PclinkJson.Text("rpc.result"),
                    "id" to PclinkJson.Text(id),
                    "ok" to PclinkJson.Bool(true),
                    "result" to pclinkObject("blob" to PclinkJson.Text(blob)),
                )
                assertEquals(true, PclinkJsonEncoder.encode(result).size > PclinkLimits.CHUNK_THRESHOLD_BYTES)
                for (chunk in PclinkRpcChunking.split(result, 128 * 1024)) {
                    harness.fakePc.sendInner(
                        link,
                        c4ChunkFrame("rpc.result.chunk", "id", id, chunk),
                    )
                }
                true
            }
            val result = harness.transport.call("session/list", emptyArgs()) as JsonObject
            assertEquals(blob, (result["blob"] as JsonString).value)
            assertTrue(harness.client.status().state.isOnline)
        } finally {
            harness.close()
        }
    }

    @Test
    fun streamItemsChunksAndEndBecomeJsonValues() = runBlocking {
        val harness = connect()
        try {
            harness.fakePc.streamOpenHandler = { link, open ->
                val streamId = open.requiredString("streamId")
                assertEquals("workspace/follow", open.requiredString("endpoint"))
                harness.fakePc.sendInner(
                    link,
                    pclinkObject(
                        "type" to PclinkJson.Text("rpc.stream.item"),
                        "streamId" to PclinkJson.Text(streamId),
                        "value" to pclinkObject("n" to PclinkJson.Integer(1)),
                    ),
                )
                val value = pclinkObject("n" to PclinkJson.Integer(2))
                for (chunk in PclinkRpcChunking.split(value, 4)) {
                    harness.fakePc.sendInner(
                        link,
                        c4ChunkFrame("rpc.stream.chunk", "streamId", streamId, chunk),
                    )
                }
                harness.fakePc.sendInner(
                    link,
                    pclinkObject(
                        "type" to PclinkJson.Text("rpc.stream.end"),
                        "streamId" to PclinkJson.Text(streamId),
                    ),
                )
                true
            }
            val mux = harness.transport.openMux()
            val stream = mux.open(
                "follow",
                "workspace/follow",
                JsonObject(linkedMapOf("request" to JsonObject(emptyMap()))),
            )
            assertEquals(JsonObject(linkedMapOf("n" to JsonNumber("1"))), stream.receive())
            assertEquals(JsonObject(linkedMapOf("n" to JsonNumber("2"))), stream.receive())
            assertNull(stream.receive())
            assertEquals(1, harness.fakePc.streamOpens.size)
            mux.close()
        } finally {
            harness.close()
        }
    }

    @Test
    fun streamCancelSendsTheCancelAndDiscardsLateItems() = runBlocking {
        val harness = connect()
        try {
            var linkRef: FakeRelayLink? = null
            var streamIdRef: String? = null
            harness.fakePc.streamOpenHandler = { link, open ->
                linkRef = link
                streamIdRef = open.requiredString("streamId")
                harness.fakePc.sendInner(
                    link,
                    pclinkObject(
                        "type" to PclinkJson.Text("rpc.stream.item"),
                        "streamId" to PclinkJson.Text(open.requiredString("streamId")),
                        "value" to PclinkJson.Integer(1),
                    ),
                )
                true
            }
            val mux = harness.transport.openMux()
            val stream = mux.open(
                "follow",
                "workspace/follow",
                JsonObject(linkedMapOf("request" to JsonObject(emptyMap()))),
            )
            assertEquals(JsonNumber("1"), stream.receive())
            stream.cancel()
            c4Await { harness.fakePc.streamCancels.isNotEmpty() }
            assertEquals(
                streamIdRef,
                harness.fakePc.streamCancels[0].requiredString("streamId"),
            )
            harness.fakePc.sendInner(
                linkRef!!,
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.item"),
                    "streamId" to PclinkJson.Text(streamIdRef!!),
                    "value" to PclinkJson.Integer(2),
                ),
            )
            assertNull("late items after cancel are discarded", stream.receive())
            mux.close()
        } finally {
            harness.close()
        }
    }

    @Test
    fun malformedChunkSequenceFailsTheCallWithBadFrameAndNeverDeliversAPartialValue() = runBlocking {
        val harness = connect()
        try {
            harness.fakePc.rpcCallHandler = { link, call ->
                val id = call.requiredString("id")
                val data = PclinkBase64Url.encode("{\"items\"".toByteArray())
                for (part in listOf(0L, 0L)) {
                    harness.fakePc.sendInner(
                        link,
                        c4ChunkFrame(
                            "rpc.result.chunk", "id", id,
                            PclinkRpcChunk(part, false, data),
                        ),
                    )
                }
                harness.fakePc.sendInner(
                    link,
                    c4ChunkFrame(
                        "rpc.result.chunk", "id", id,
                        PclinkRpcChunk(1, true, PclinkBase64Url.encode(":[]}".toByteArray())),
                    ),
                )
                true
            }
            val error = try {
                harness.transport.call("session/list", emptyArgs())
                null
            } catch (thrown: PclinkRpcError) {
                thrown
            }
            assertEquals("bad_frame", error?.code)
            assertTrue("a malformed sequence fails only the call", harness.client.status().state.isOnline)
        } finally {
            harness.close()
        }
    }

    @Test
    fun unknownDshErrorCodeIsPassedThroughAndTheSessionStays() = runBlocking {
        val harness = connect()
        try {
            harness.fakePc.rpcCallHandler = { link, call ->
                harness.fakePc.sendInner(
                    link,
                    c4ErrorFrame(
                        call.requiredString("id"),
                        "gateway/custom-unavailable",
                        "original message",
                    ),
                )
                true
            }
            val error = try {
                harness.transport.call("session/list", emptyArgs())
                null
            } catch (thrown: PclinkRpcError) {
                thrown
            }
            assertEquals("gateway/custom-unavailable", error?.code)
            assertEquals("original message", error?.message)
            assertTrue("a DSH endpoint error does not close the session", harness.client.status().state.isOnline)
        } finally {
            harness.close()
        }
    }

    @Test
    fun eventsResultIsExactlyOneLayer() = runBlocking {
        val harness = connect()
        try {
            val nested = try {
                harness.transport.call(
                    PclinkDshTransport.EVENTS_RESULT_ENDPOINT,
                    JsonObject(linkedMapOf("args" to JsonObject(emptyMap()))),
                )
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("bad_frame", nested?.code)
            assertTrue(harness.fakePc.rpcCalls.isEmpty())

            val outcome = JsonObject(linkedMapOf("approved" to JsonBool(true)))
            harness.transport.answerEvents("client-1", "event-1", outcome)
            assertEquals(1, harness.fakePc.rpcCalls.size)
            val call = harness.fakePc.rpcCalls[0]
            assertEquals(PclinkDshTransport.EVENTS_RESULT_ENDPOINT, call.requiredString("endpoint"))
            val args = call["args"]?.objectValue ?: throw AssertionError("missing args")
            assertEquals(setOf("clientId", "eventId", "outcome"), args.keys)
            assertEquals(JsonString("client-1"), PclinkDshJson.toJsonValue(args.getValue("clientId")))
            assertEquals(JsonString("event-1"), PclinkDshJson.toJsonValue(args.getValue("eventId")))
            assertEquals(outcome, PclinkDshJson.toJsonValue(args.getValue("outcome")))
        } finally {
            harness.close()
        }
    }

    @Test
    fun unsafeChunkTimeoutBecomesUnknownOutcome() = runBlocking {
        val harness = connect(
            rpcConfiguration = PclinkRpcConfiguration(
                chunkReassemblyTimeout = Duration.ofMillis(150),
                retryDeadline = Duration.ofSeconds(3),
                sessionPollInterval = Duration.ofMillis(10),
            ),
        )
        try {
            harness.fakePc.rpcCallHandler = { link, call ->
                harness.fakePc.sendInner(
                    link,
                    c4ChunkFrame(
                        "rpc.result.chunk", "id", call.requiredString("id"),
                        PclinkRpcChunk(0, false, PclinkBase64Url.encode("{\"a\"".toByteArray())),
                    ),
                )
                true
            }
            val error = try {
                harness.transport.call("commands/execute", JsonObject(linkedMapOf("command" to JsonString("status"))))
                null
            } catch (thrown: PclinkRpcError) {
                thrown
            }
            assertEquals("unknown_outcome", error?.code)
            assertEquals("an unsafe call is not resent", 1, harness.fakePc.rpcCalls.size)
            assertTrue(harness.client.status().state.isOnline)
        } finally {
            harness.close()
        }
    }

    @Test
    fun readChunkTimeoutRetriesOnTheSameSession() = runBlocking {
        val harness = connect(
            rpcConfiguration = PclinkRpcConfiguration(
                chunkReassemblyTimeout = Duration.ofMillis(150),
                retryDeadline = Duration.ofSeconds(5),
                retryDelay = Duration.ofMillis(10),
                sessionPollInterval = Duration.ofMillis(10),
            ),
        )
        try {
            val calls = AtomicInteger()
            harness.fakePc.rpcCallHandler = { link, call ->
                val id = call.requiredString("id")
                if (calls.incrementAndGet() == 1) {
                    harness.fakePc.sendInner(
                        link,
                        c4ChunkFrame(
                            "rpc.result.chunk", "id", id,
                            PclinkRpcChunk(0, false, PclinkBase64Url.encode("{\"items\"".toByteArray())),
                        ),
                    )
                } else {
                    harness.fakePc.sendInner(
                        link,
                        c4ResultFrame(id, pclinkObject("items" to PclinkJson.Array(emptyList()))),
                    )
                }
                true
            }
            val result = harness.transport.call("session/list", emptyArgs()) as JsonObject
            assertEquals(emptyList<JsonValue>(), (result["items"] as JsonArray).values)
            assertEquals(2, harness.fakePc.rpcCalls.size)
            assertTrue(harness.client.status().state.isOnline)
        } finally {
            harness.close()
        }
    }

    @Test
    fun duplicateLocalStreamIdIsRejected() = runBlocking {
        val harness = connect()
        try {
            harness.fakePc.streamOpenHandler = { _, _ -> true }
            val mux = harness.transport.openMux()
            val args = JsonObject(linkedMapOf("request" to JsonObject(emptyMap())))
            mux.open("follow", "workspace/follow", args)
            val error = try {
                mux.open("follow", "workspace/follow", args)
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("bad_frame", error?.code)
            mux.close()
        } finally {
            harness.close()
        }
    }

    @Test
    fun jsonConversionRoundTripsDshValues() {
        val values = listOf(
            JsonNull,
            JsonBool(true),
            JsonNumber("-2"),
            JsonString("héllo / \u0000"),
            JsonArray(listOf(JsonNumber("1"), JsonString("x"), JsonNull)),
            JsonObject(
                linkedMapOf(
                    "z" to JsonString("last"),
                    "a" to JsonObject(linkedMapOf("nested" to JsonBool(false))),
                    "decimal" to JsonNumber("1.5"),
                ),
            ),
        )
        for (value in values) {
            assertEquals(value, PclinkDshJson.toJsonValue(PclinkDshJson.toPclink(value)))
        }
    }
}
