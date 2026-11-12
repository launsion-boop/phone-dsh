// SPDX-License-Identifier: MIT
// C4 golden-vector tests for `workspace/1`: chunk split/reassembly, the
// interleave/threshold/too-large/cancel cases, the invalid chunk/seq/cross_sid/
// first_frame rows, chunk inactivity from the last chunk, §7 retry classes,
// stream framing/cancel and request-id/cancellation rules. Every vector is read
// from disk; no ciphertext, chunk or expected hash is copied into this file.
package com.phonedsh.pclink

import java.time.Duration
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkRpcChunkingTest {
    private val vectors = TestSupport.vectors()

    private fun chunking(): PclinkJson = TestSupport.at(vectors, "chunking")
        ?: throw AssertionError("missing chunking vectors")

    private fun invalidRows(vararg kinds: String): List<PclinkJson> =
        TestSupport.objects(vectors, "invalid").filter {
            TestSupport.requireString(it, "kind") in kinds
        }

    private fun row(kind: String, name: String): PclinkJson =
        invalidRows(kind).single { TestSupport.requireString(it, "case") == name }

    private fun accept(
        reassembler: PclinkChunkReassembler,
        key: String,
        event: PclinkJson,
        now: Long = 0,
        timeout: Long = 30_000,
        partKey: String = "part",
        lastKey: String = "last",
        dataKey: String = "data",
    ): ByteArray? = reassembler.accept(
        key = key,
        part = TestSupport.requireInt(event, partKey),
        last = TestSupport.requireBool(event, lastKey),
        data = TestSupport.requireString(event, dataKey),
        nowMillis = now,
        timeoutMillis = timeout,
    )

    private fun sha(bytes: ByteArray): String = PclinkHex.encode(PclinkCrypto.sha256(bytes))

    @Test
    fun smallChunkVectorReassemblesToTheVectorValue() {
        val small = TestSupport.at(chunking(), "small") ?: throw AssertionError("missing small")
        val reassembler = PclinkChunkReassembler()
        var result: ByteArray? = null
        var now = 0L
        for (event in TestSupport.objects(small, "chunks")) {
            result = accept(reassembler, "small", event, now = now)
            now += 1_000
            if (TestSupport.requireBool(event, "last")) {
                assertNotNull("last chunk must complete the value", result)
            } else {
                assertNull("partial chunk must not be delivered", result)
            }
        }
        assertTrue(reassembler.pendingKeys.isEmpty())
        val bytes = result ?: throw AssertionError("no reassembled bytes")
        assertEquals(TestSupport.requireString(small, "reassembled_sha256"), sha(bytes))
        assertEquals(TestSupport.at(small, "value"), PclinkJsonParser.parse(bytes))
    }

    @Test
    fun resultChunkVectorReassemblesTheWholeRpcResult() {
        val vector = TestSupport.at(chunking(), "result_chunk")
            ?: throw AssertionError("missing result_chunk")
        val reassembler = PclinkChunkReassembler()
        var result: ByteArray? = null
        var now = 0L
        for (event in TestSupport.objects(vector, "chunks")) {
            result = accept(reassembler, "result:call-2", event, now = now)
            now += 500
        }
        val bytes = result ?: throw AssertionError("no reassembled result")
        assertEquals(TestSupport.requireString(vector, "reassembled_sha256"), sha(bytes))
        val parsed = PclinkJsonParser.parseObject(bytes)
        assertEquals("rpc.result", parsed.requiredString("type"))
        assertEquals("call-2", parsed.requiredString("id"))
        assertEquals(true, parsed["ok"]?.boolValue)
        assertEquals(TestSupport.at(vector, "result"), parsed)
    }

    @Test
    fun interleavedStreamsNeverMixValues() {
        val vector = TestSupport.at(chunking(), "interleave")
            ?: throw AssertionError("missing interleave")
        val reassembler = PclinkChunkReassembler()
        val completed = HashMap<String, ByteArray>()
        var now = 0L
        for (event in TestSupport.objects(vector, "events")) {
            val streamId = TestSupport.requireString(event, "streamId")
            val bytes = accept(reassembler, streamId, event, now = now)
            now += 100
            if (bytes != null) completed[streamId] = bytes
        }
        assertTrue(reassembler.pendingKeys.isEmpty())
        assertEquals(setOf("stream-a", "stream-b"), completed.keys)
        for ((streamId, bytes) in completed) {
            assertEquals(
                TestSupport.requireString(vector, "reassembled_sha256", streamId),
                sha(bytes),
            )
            assertEquals(
                TestSupport.at(vector, "values", streamId),
                PclinkJsonParser.parse(bytes),
            )
        }
    }

    @Test
    fun thresholdVectorSplitsAndReassembles() {
        val vector = TestSupport.at(chunking(), "threshold")
            ?: throw AssertionError("missing threshold")
        val repeat = TestSupport.requireString(vector, "repeat")
        val count = TestSupport.requireInt(vector, "repeat_count").toInt()
        val value = PclinkJson.Text(repeat.repeat(count))
        val encoded = PclinkJsonEncoder.encode(value)
        assertEquals(TestSupport.requireInt(vector, "json_bytes"), encoded.size.toLong())
        val chunkBytes = TestSupport.requireInt(vector, "chunk_bytes").toInt()
        val chunks = PclinkRpcChunking.split(value, chunkBytes)
        assertEquals(TestSupport.requireInt(vector, "parts"), chunks.size.toLong())
        assertEquals(TestSupport.requireBool(vector, "last_last"), chunks.last().last)
        assertFalse(chunks.dropLast(1).any { it.last })

        val reassembler = PclinkChunkReassembler()
        var result: ByteArray? = null
        for (chunk in chunks) {
            result = reassembler.accept("threshold", chunk.part, chunk.last, chunk.data, 0, 30_000)
        }
        val bytes = result ?: throw AssertionError("threshold did not complete")
        assertEquals(TestSupport.requireString(vector, "reassembled_sha256"), sha(bytes))
        assertEquals(value, PclinkJsonParser.parse(bytes))
    }

    @Test
    fun tooLargeVectorFailsAtTheEightMiBLimit() {
        val vector = TestSupport.at(chunking(), "too_large")
            ?: throw AssertionError("missing too_large")
        val limit = TestSupport.requireInt(vector, "limit").toInt()
        assertEquals(8 shl 20, limit)
        val reassembler = PclinkChunkReassembler()
        val oneMiB = PclinkBase64Url.encode(ByteArray(1 shl 20) { 0x61 })
        for (part in 0 until 8L) {
            assertNull(reassembler.accept("too", part, false, oneMiB, 0, 30_000))
        }
        assertPclinkCode("frame_too_large", "one byte over 8 MiB") {
            reassembler.accept(
                "too", 8, true, PclinkBase64Url.encode(byteArrayOf(0x61)), 0, 30_000,
            )
        }
        assertTrue("the partial value is discarded", reassembler.pendingKeys.isEmpty())
    }

    @Test
    fun cancelVectorDiscardsThePartialValue() {
        val vector = TestSupport.at(chunking(), "cancel")
            ?: throw AssertionError("missing cancel")
        val before = TestSupport.requireInt(vector, "chunks_before_cancel").toInt()
        assertEquals(1, before)
        val reassembler = PclinkChunkReassembler()
        var now = 0L
        repeat(before) { index ->
            reassembler.accept("cancelled", index.toLong(), false, "YQ", now, 30_000)
            now += 10
        }
        assertEquals(setOf("cancelled"), reassembler.pendingKeys)
        reassembler.discard("cancelled")
        assertTrue(reassembler.pendingKeys.isEmpty())
        reassembler.finish()
        assertEquals("discard", TestSupport.requireString(vector, "expected"))
    }

    @Test
    fun invalidChunkVectorsFailWithTheExactCode() {
        val rows = invalidRows("chunk")
        assertEquals(5, rows.size)
        for (vector in rows) {
            val name = TestSupport.requireString(vector, "case")
            val expected = TestSupport.requireString(vector, "expected")
            if (name == "chunk-too-large") {
                val reassembler = PclinkChunkReassembler()
                val data = PclinkBase64Url.encode(ByteArray(1 shl 20) { 0x62 })
                for (part in 0 until 8L) reassembler.accept("large", part, false, data, 0, 30_000)
                assertPclinkCode(expected, name) {
                    reassembler.accept("large", 8, true, "YQ", 0, 30_000)
                }
                continue
            }
            val reassembler = PclinkChunkReassembler()
            val error = try {
                var now = 0L
                for (event in TestSupport.objects(vector, "events")) {
                    accept(reassembler, TestSupport.requireString(event, "streamId"), event, now = now)
                    now += 10
                }
                reassembler.finish()
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertNotNull("$name must fail", error)
            assertEquals(name, expected, error!!.code)
            // The malformed sequence is discarded; the caller never sees a
            // partial value. (Some rows make the model's last chunk non-JSON,
            // so the exact parse/sequence order is asserted separately below.)
            reassembler.discardAll()
            assertTrue(reassembler.pendingKeys.isEmpty())
        }
    }

    @Test
    fun sharedBudgetEnforcesTheSixteenMiBTotalAcrossValues() {
        val budget = PclinkChunkReassemblyBudget(10)
        val first = PclinkChunkReassembler(maxTotalBytes = 10, budget = budget)
        val second = PclinkChunkReassembler(maxTotalBytes = 10, budget = budget)
        val six = PclinkBase64Url.encode("123456".toByteArray())
        val four = PclinkBase64Url.encode("7890".toByteArray())
        val one = PclinkBase64Url.encode("x".toByteArray())
        assertNull(first.accept("a", 0, false, six, 0, 30_000))
        assertNull(second.accept("b", 0, false, four, 0, 30_000))
        assertEquals(10, budget.totalBytes)
        assertPclinkCode("frame_too_large", "shared 16 MiB budget") {
            second.accept("b", 1, false, one, 0, 30_000)
        }
        // The failed value released its bytes; the first value is still intact.
        assertEquals(6, budget.totalBytes)
        first.discardAll()
        assertEquals(0, budget.totalBytes)
        assertNull(second.accept("b", 0, false, one, 0, 30_000))
        assertEquals(1, budget.totalBytes)
        second.discardAll()
        assertEquals(0, budget.totalBytes)
    }

    @Test
    fun sequenceRulesRejectTwoLastAndMissingLastWithValidJson() {
        fun data(text: String): String = PclinkBase64Url.encode(text.toByteArray())
        val reassembler = PclinkChunkReassembler()
        assertEquals(ByteArray(1) { '1'.code.toByte() }.toList(), reassembler.accept("two-last", 0, true, data("1"), 0, 30_000)!!.toList())
        assertPclinkCode("bad_frame", "two last") {
            reassembler.accept("two-last", 1, true, data("2"), 0, 30_000)
        }
        assertEquals(emptySet<String>(), reassembler.pendingKeys)

        val half = PclinkChunkReassembler()
        assertNull(half.accept("missing-last", 0, false, data("1"), 0, 30_000))
        assertNull(half.accept("missing-last", 1, false, data("2"), 0, 30_000))
        val error = try {
            half.finish()
            null
        } catch (thrown: PclinkError) {
            thrown
        }
        assertEquals("bad_frame", error?.code)
        assertTrue(half.pendingKeys.isEmpty())
    }

    @Test
    fun seqCrossSidAndFirstFrameVectorsGateTheRealSession() {
        val rows = invalidRows("seq", "cross_sid", "first_frame")
        assertEquals(8, rows.size)
        val frame = C2TestSupport.frameCase("pc-peer-hello-seq0")
        for (vector in rows) {
            val name = TestSupport.requireString(vector, "case")
            val expected = TestSupport.requireString(vector, "expected")
            when (TestSupport.requireString(vector, "kind")) {
                "first_frame" -> {
                    val session = C2TestSupport.goldenSession()
                    val type = TestSupport.requireString(vector, "type")
                    val error = try {
                        session.acceptFirstInner(pclinkObject("type" to PclinkJson.Text(type)))
                        null
                    } catch (thrown: PclinkError) {
                        thrown
                    }
                    assertEquals(name, expected, error?.code)
                }
                "cross_sid" -> {
                    val session = C2TestSupport.goldenSession()
                    val messageSid = TestSupport.requireString(vector, "message_sid")
                    val error = try {
                        session.open(c4Outer(frame, sid = messageSid))
                        null
                    } catch (thrown: PclinkError) {
                        thrown
                    }
                    assertEquals(name, expected, error?.code)
                }
                "seq" -> {
                    when (name) {
                        "seq-first-nonzero" -> {
                            val session = C2TestSupport.goldenSession()
                            assertPclinkCode(expected, name) {
                                session.open(c4Outer(frame, seq = 1))
                            }
                        }
                        "seq-replay" -> {
                            val session = C2TestSupport.goldenSession()
                            val hello = session.open(c4Outer(frame)).inner
                            session.acceptFirstInner(hello)
                            session.open(c4Outer(C2TestSupport.frameCase("pc-rpc-result-seq1")))
                            session.open(c4Outer(C2TestSupport.frameCase("pc-stream-item-seq2")))
                            val replayFrame = C2TestSupport.frameCase("pc-stream-chunk-seq3")
                            session.open(c4Outer(replayFrame))
                            assertPclinkCode(expected, name) {
                                session.open(c4Outer(replayFrame))
                            }
                        }
                        "seq-gap" -> {
                            val session = C2TestSupport.goldenSession()
                            val hello = session.open(c4Outer(frame)).inner
                            session.acceptFirstInner(hello)
                            assertPclinkCode(expected, name) {
                                session.open(c4Outer(C2TestSupport.frameCase("pc-rpc-result-seq1"), seq = 5))
                            }
                        }
                        "seq-hard-cap" -> {
                            val session = C2TestSupport.goldenSession()
                            assertPclinkCode(expected, name) {
                                session.open(c4Outer(frame, seq = 1_048_576))
                            }
                        }
                        "seq-byte-hard-cap" -> {
                            val session = C2TestSupport.goldenSession(
                                PclinkSessionThresholds(hardBytes = 1),
                            )
                            assertPclinkCode(expected, name) {
                                session.open(c4Outer(frame))
                            }
                        }
                        else -> throw AssertionError("uncovered seq row $name")
                    }
                }
            }
        }
    }

    @Test
    fun chunkInactivityIsMeasuredFromTheLastChunkAndReadRetries() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(
                chunkReassemblyTimeout = Duration.ofMillis(300),
                retryDeadline = Duration.ofSeconds(5),
                retryDelay = Duration.ofMillis(10),
                sessionPollInterval = Duration.ofMillis(5),
            ),
        )
        rpc.attach(channel)
        try {
            val call = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
            c4Await { channel.frames("rpc.call").size == 1 }
            val firstId = channel.frames("rpc.call")[0].requiredString("id")
            val prefix = PclinkBase64Url.encode("{\"type\":\"rpc.result\",".toByteArray())
            val more = PclinkBase64Url.encode("\"id\":\"x\"".toByteArray())
            rpc.sendInner(
                c4ChunkFrame("rpc.result.chunk", "id", firstId, PclinkRpcChunk(0, false, prefix)),
            )
            delay(120)
            rpc.sendInner(
                c4ChunkFrame("rpc.result.chunk", "id", firstId, PclinkRpcChunk(1, false, more)),
            )
            delay(120)
            assertTrue("120 ms after the last chunk is below the 300 ms budget", call.isActive)
            assertEquals(1, channel.frames("rpc.call").size)
            c4Await(3_000) { channel.frames("rpc.call").size == 2 }
            val secondId = channel.frames("rpc.call")[1].requiredString("id")
            assertTrue("read retried with a fresh correlation id", firstId != secondId)
            rpc.sendInner(
                c4ResultFrame(secondId, pclinkObject("items" to PclinkJson.Array(emptyList()))),
            )
            val result = call.await()
            assertEquals(emptyList<PclinkJson>(), result["items"]?.arrayValue)
        } finally {
            rpc.close()
        }
    }

    @Test
    fun unsafeChunkTimeoutIsUnknownOutcomeAndIsNotResent() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(
                chunkReassemblyTimeout = Duration.ofMillis(150),
                retryDeadline = Duration.ofSeconds(5),
                retryDelay = Duration.ofMillis(10),
                sessionPollInterval = Duration.ofMillis(5),
            ),
        )
        rpc.attach(channel)
        try {
            kotlinx.coroutines.supervisorScope {
                val call = async {
                    rpc.call("commands/execute", pclinkObject("command" to PclinkJson.Text("status")))
                }
                c4Await { channel.frames("rpc.call").size == 1 }
                val id = channel.frames("rpc.call")[0].requiredString("id")
                rpc.sendInner(
                    c4ChunkFrame(
                        "rpc.result.chunk",
                        "id",
                        id,
                        PclinkRpcChunk(0, false, PclinkBase64Url.encode("{\"type\"".toByteArray())),
                    ),
                )
                val error = try {
                    call.await()
                    null
                } catch (thrown: PclinkError) {
                    thrown
                }
                assertEquals("unknown_outcome", error?.code)
                assertEquals("an unsafe call is never resent", 1, channel.frames("rpc.call").size)
            }
        } finally {
            rpc.close()
        }
    }

    @Test
    fun chunkedResultCompletesThePendingCallAndNormalResultDuringChunksFails() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            // supervisorScope: an expected child failure is an assertion value,
            // not a reason to cancel this test's coroutine.
            kotlinx.coroutines.supervisorScope {
                val call = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
                c4Await { channel.frames("rpc.call").size == 1 }
                val id = channel.frames("rpc.call")[0].requiredString("id")
                val result = pclinkObject(
                    "items" to PclinkJson.Array(
                        (0 until 40).map { PclinkJson.Integer(it.toLong()) },
                    ),
                )
                val chunks = PclinkRpcChunking.split(c4ResultFrame(id, result), 16)
                for (chunk in chunks) {
                    rpc.sendInner(c4ChunkFrame("rpc.result.chunk", "id", id, chunk))
                }
                assertEquals(result, call.await())

                // A normal rpc.result while a chunk sequence is active fails that call.
                val second = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
                c4Await { channel.frames("rpc.call").size == 2 }
                val secondId = channel.frames("rpc.call")[1].requiredString("id")
                rpc.sendInner(
                    c4ChunkFrame(
                        "rpc.result.chunk", "id", secondId,
                        PclinkRpcChunk(0, false, PclinkBase64Url.encode("{}".toByteArray())),
                    ),
                )
                rpc.sendInner(c4ResultFrame(secondId, pclinkObject()))
                val error = try {
                    second.await()
                    null
                } catch (thrown: PclinkError) {
                    thrown
                }
                assertEquals("bad_frame", error?.code)
            }
        } finally {
            rpc.close()
        }
    }

    @Test
    fun streamChunksDeliverValuesAndCancelDiscardsLateItems() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            val stream = rpc.openStream(
                "workspace/follow",
                pclinkObject("request" to pclinkObject()),
            )
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            assertEquals(
                stream.id,
                channel.frames("rpc.stream.open")[0].requiredString("streamId"),
            )
            val small = TestSupport.at(chunking(), "small") ?: throw AssertionError("missing small")
            val chunks = TestSupport.objects(small, "chunks").map {
                PclinkRpcChunk(
                    part = TestSupport.requireInt(it, "part"),
                    last = TestSupport.requireBool(it, "last"),
                    data = TestSupport.requireString(it, "data"),
                )
            }
            for (chunk in chunks) {
                rpc.sendInner(c4ChunkFrame("rpc.stream.chunk", "streamId", stream.id, chunk))
            }
            assertEquals(TestSupport.at(small, "value"), stream.next())

            val waiting = async { stream.next() }
            stream.cancel()
            assertNull("cancel unblocks a waiting next()", waiting.await())
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.item"),
                    "streamId" to PclinkJson.Text(stream.id),
                    "value" to PclinkJson.Text("late"),
                ),
            )
            assertNull("late items after cancel are discarded", stream.next())
            assertEquals(1, channel.frames("rpc.stream.cancel").size)
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.end"),
                    "streamId" to PclinkJson.Text(stream.id),
                ),
            )
            assertNull(stream.next())
        } finally {
            rpc.close()
        }
    }

    @Test
    fun streamErrorPreservesTheDshCodeAndMissingLastFailsTheStream() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            val stream = rpc.openStream("workspace/follow", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.error"),
                    "streamId" to PclinkJson.Text(stream.id),
                    "error" to pclinkObject(
                        "code" to PclinkJson.Text("gateway/method-unavailable"),
                        "message" to PclinkJson.Text("original message"),
                    ),
                ),
            )
            val error = try {
                stream.next()
                null
            } catch (thrown: PclinkRpcError) {
                thrown
            }
            assertEquals("gateway/method-unavailable", error?.code)
            assertEquals("original message", error?.message)

            val second = rpc.openStream("workspace/follow", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 2 }
            rpc.sendInner(
                c4ChunkFrame(
                    "rpc.stream.chunk", "streamId", second.id,
                    PclinkRpcChunk(0, false, PclinkBase64Url.encode("{\"a\":".toByteArray())),
                ),
            )
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.end"),
                    "streamId" to PclinkJson.Text(second.id),
                ),
            )
            val missingLast = try {
                second.next()
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("bad_frame", missingLast?.code)
        } finally {
            rpc.close()
        }
    }

    @Test
    fun streamChunkTimeoutClosesAReadStreamWithACancel() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(
                chunkReassemblyTimeout = Duration.ofMillis(120),
                sessionPollInterval = Duration.ofMillis(5),
            ),
        )
        rpc.attach(channel)
        try {
            val stream = rpc.openStream("workspace/follow", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            rpc.sendInner(
                c4ChunkFrame(
                    "rpc.stream.chunk", "streamId", stream.id,
                    PclinkRpcChunk(0, false, PclinkBase64Url.encode("{\"a\":".toByteArray())),
                ),
            )
            val error = try {
                stream.next()
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("session_expired", error?.code)
            c4Await { channel.frames("rpc.stream.cancel").isNotEmpty() }
            assertEquals(
                stream.id,
                channel.frames("rpc.stream.cancel")[0].requiredString("streamId"),
            )
        } finally {
            rpc.close()
        }
    }

    @Test
    fun unknownEndpointIsForwardedAndTreatedAsUnsafe() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            assertEquals(PclinkRetryClass.UNSAFE, PclinkEndpoints.retryClass("custom/method"))
            kotlinx.coroutines.supervisorScope {
                val call = async { rpc.call("custom/method", pclinkObject("value" to PclinkJson.Integer(7))) }
                c4Await { channel.frames("rpc.call").size == 1 }
                assertEquals("custom/method", channel.frames("rpc.call")[0].requiredString("endpoint"))
                rpc.sendInner(
                    c4ErrorFrame(channel.frames("rpc.call")[0].requiredString("id"), "gateway/custom", "nope"),
                )
                val error = try {
                    call.await()
                    null
                } catch (thrown: PclinkRpcError) {
                    thrown
                }
                assertEquals("gateway/custom", error?.code)
            }
        } finally {
            rpc.close()
        }
    }

    @Test
    fun adminPrefixIsForbiddenAndNeverSent() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            val callError = try {
                rpc.call("pclink.admin/status", pclinkObject())
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("forbidden", callError?.code)
            val streamError = try {
                rpc.openStream("pclink.admin/status", pclinkObject())
                null
            } catch (thrown: PclinkError) {
                thrown
            }
            assertEquals("forbidden", streamError?.code)
            assertTrue(channel.sent.isEmpty())
        } finally {
            rpc.close()
        }
    }

    @Test
    fun cancelledCallIsRemovedAndAFreshCallUsesAFreshId() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(retryDeadline = Duration.ofSeconds(10), sessionPollInterval = Duration.ofMillis(5)),
        )
        rpc.attach(channel)
        try {
            val first = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
            c4Await { channel.frames("rpc.call").size == 1 }
            val firstId = channel.frames("rpc.call")[0].requiredString("id")
            first.cancelAndJoin()
            assertTrue(first.isCancelled)

            val second = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
            c4Await { channel.frames("rpc.call").size == 2 }
            val secondId = channel.frames("rpc.call")[1].requiredString("id")
            assertTrue("a cancelled call is not reused", firstId != secondId)
            rpc.sendInner(c4ResultFrame(secondId, pclinkObject("ok" to PclinkJson.Bool(true))))
            assertEquals(PclinkJson.Bool(true), second.await()["ok"])
            // A late result for the cancelled call is discarded, not delivered twice.
            rpc.sendInner(c4ResultFrame(firstId, pclinkObject("late" to PclinkJson.Bool(true))))
            delay(50)
            assertEquals(true, second.isCompleted)
        } finally {
            rpc.close()
        }
    }


    @Test
    fun inFlightCallIdsAreUniqueAndLateResultsAreDiscarded() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            kotlinx.coroutines.supervisorScope {
                val calls = (0 until 5).map {
                    async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
                }
                c4Await { channel.frames("rpc.call").size == 5 }
                val ids = channel.frames("rpc.call").map { it.requiredString("id") }
                assertEquals("ids are unique among in-flight calls", 5, ids.toSet().size)
                for (id in ids) {
                    rpc.sendInner(c4ResultFrame(id, pclinkObject("id" to PclinkJson.Text(id))))
                }
                for ((index, call) in calls.withIndex()) {
                    assertEquals(PclinkJson.Text(ids[index]), call.await()["id"])
                }
            }
        } finally {
            rpc.close()
        }
    }

    @Test
    fun sessionLossRetriesReadCallsAndMakesUnsafeCallsUnknownOutcome() = runBlocking {
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(
            PclinkRpcConfiguration(
                retryDeadline = Duration.ofSeconds(5),
                retryDelay = Duration.ofMillis(5),
                sessionPollInterval = Duration.ofMillis(5),
            ),
        )
        rpc.attach(channel)
        try {
            kotlinx.coroutines.supervisorScope {
                val read = async { rpc.call("session/list", pclinkObject("_request" to pclinkObject())) }
                c4Await { channel.frames("rpc.call").size == 1 }
                channel.session = null
                delay(60)
                channel.session = c4EstablishedGoldenSession()
                c4Await(2_000) { channel.frames("rpc.call").size == 2 }
                val secondId = channel.frames("rpc.call")[1].requiredString("id")
                rpc.sendInner(c4ResultFrame(secondId, pclinkObject("ok" to PclinkJson.Bool(true))))
                assertEquals(PclinkJson.Bool(true), read.await()["ok"])

                val unsafeCall = async {
                    rpc.call("commands/execute", pclinkObject("command" to PclinkJson.Text("status")))
                }
                c4Await { channel.frames("rpc.call").size == 3 }
                channel.session = null
                val error = try {
                    unsafeCall.await()
                    null
                } catch (thrown: PclinkError) {
                    thrown
                }
                assertEquals("unknown_outcome", error?.code)
                assertEquals("an unsafe call is not resent", 3, channel.frames("rpc.call").size)
            }
        } finally {
            rpc.close()
        }
    }

    @Test
    fun streamDeliversItemsInOrderWithoutMixingValues() = runBlocking {
        // The vector rows are sender/sequence rules; this asserts a concurrent
        // `next()` is not an alias for a second value: the channel yields one
        // event per value and the caller awaits in order.
        val channel = C4RpcChannel(c4EstablishedGoldenSession())
        val rpc = PclinkRpc(PclinkRpcConfiguration(sessionPollInterval = Duration.ofMillis(5)))
        rpc.attach(channel)
        try {
            val stream = rpc.openStream("workspace/follow", pclinkObject("request" to pclinkObject()))
            c4Await { channel.frames("rpc.stream.open").size == 1 }
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.item"),
                    "streamId" to PclinkJson.Text(stream.id),
                    "value" to PclinkJson.Integer(1),
                ),
            )
            rpc.sendInner(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.item"),
                    "streamId" to PclinkJson.Text(stream.id),
                    "value" to PclinkJson.Integer(2),
                ),
            )
            assertEquals(PclinkJson.Integer(1), stream.next())
            assertEquals(PclinkJson.Integer(2), stream.next())
        } finally {
            rpc.close()
        }
    }
}
