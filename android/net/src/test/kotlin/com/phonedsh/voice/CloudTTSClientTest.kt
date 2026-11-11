// SPDX-License-Identifier: MIT
// phone-dsh — :net voice tests: CloudTTSClient's request and PCM streaming
// (spec/v1/cloud-voice.md §3). The transport is a fake flow; no host is
// contacted.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CloudTTSClientTest {
    private class FakeTransport(
        private val chunks: List<ByteArray>,
        private val failure: Throwable? = null,
    ) : CloudTtsTransport {
        var request: CloudTtsRequest? = null
            private set

        override fun stream(request: CloudTtsRequest): Flow<ByteArray> = flow {
            this@FakeTransport.request = request
            for (chunk in chunks) emit(chunk)
            failure?.let { throw it }
        }
    }

    @Test
    fun streamsWholeSamplesAndSendsTheContractRequest() = runBlocking {
        val transport = FakeTransport(
            listOf(
                ByteArray(4096) { 1 },
                ByteArray(2905) { 2 },
            ),
        )
        val client = CloudTTSClient(credentials = { "tok" }, transport = transport)
        val audio = client.stream("你好").toList()

        assertEquals(7000, audio.sumOf { it.size })
        assertTrue("every emission must be a whole s16le sample", audio.all { it.size % 2 == 0 })
        assertEquals(7000, audio.fold(0) { total, bytes -> total + bytes.size })
        assertEquals(CloudTTSClient.PCM_CHUNK_BYTES, audio.first().size)
        assertTrue(audio.all { it.size <= CloudTTSClient.PCM_CHUNK_BYTES })

        val request = requireNotNull(transport.request)
        assertEquals(CloudVoice.TTS_URL, request.url)
        assertEquals("tok", request.credential)
        val body = GatewayJson.parse(String(request.body, StandardCharsets.UTF_8)) as JsonValue.Obj
        assertEquals("你好", body.string("input"))
        assertEquals(CloudVoice.TTS_VOICE, body.string("voice"))
        assertEquals("pcm", body.string("response_format"))
        assertEquals(3, body.members.size)
    }

    @Test
    fun dropsATrailingHalfSample() = runBlocking {
        val transport = FakeTransport(listOf(ByteArray(3201) { 3 }))
        val client = CloudTTSClient(credentials = { "tok" }, transport = transport)
        val audio = client.stream("短句").toList()
        assertEquals(3200, audio.sumOf { it.size })
        assertEquals(listOf(CloudTTSClient.PCM_CHUNK_BYTES), audio.map { it.size })
        assertArrayEquals(ByteArray(3200) { 3 }, audio.single())
    }

    @Test
    fun aNon200AnswerCarriesStatusAndCode() = runBlocking {
        val transport = FakeTransport(
            chunks = listOf(ByteArray(0)),
            failure = CloudVoiceException(401, "credential_expired", "expired"),
        )
        val client = CloudTTSClient(credentials = { "old" }, transport = transport)
        try {
            client.stream("你好").toList()
            fail("expected a CloudVoiceException")
        } catch (error: CloudVoiceException) {
            assertEquals(401, error.status)
            assertEquals("credential_expired", error.code)
            assertTrue(error.isCredentialExpired)
        }
    }

    @Test
    fun aStreamFailureAfterAudioStopsThereAndIsNotRetried() = runBlocking {
        val transport = FakeTransport(
            chunks = listOf(ByteArray(4000) { 4 }),
            failure = CloudVoiceException(null, null, "stream broke"),
        )
        val client = CloudTTSClient(credentials = { "tok" }, transport = transport)
        val received = ArrayList<ByteArray>()
        try {
            client.stream("你好").collect { received.add(it) }
            fail("expected the stream failure")
        } catch (error: CloudVoiceException) {
            assertEquals("stream broke", error.message)
        }
        // The first 3200 bytes were already playable; the remaining 800 are lost.
        assertEquals(1, received.size)
        assertEquals(3200, received.single().size)
        assertNotNull(transport.request)
    }

    @Test
    fun inputMustBeOneToOneThousandScalars() = runBlocking {
        val transport = FakeTransport(listOf(ByteArray(2)))
        val client = CloudTTSClient(credentials = { "tok" }, transport = transport)
        for (invalid in listOf("", "a".repeat(CloudVoice.TTS_INPUT_MAX_SCALARS + 1))) {
            try {
                client.stream(invalid).toList()
                fail("expected the TTS input bound to reject ${invalid.length} units")
            } catch (_: CloudVoiceException) {
                // Expected before any request is built.
            }
        }
        val audio = client.stream("a".repeat(CloudVoice.TTS_INPUT_MAX_SCALARS)).toList()
        assertEquals(2, audio.sumOf { it.size })
        assertNotNull(transport.request)
    }

    @Test
    fun aMissingCredentialFailsBeforeTheRequest() = runBlocking {
        val transport = FakeTransport(listOf(ByteArray(2)))
        val client = CloudTTSClient(credentials = { null }, transport = transport)
        try {
            client.stream("你好").toList()
            fail("expected voice unavailable")
        } catch (error: CloudVoiceException) {
            assertNull(error.status)
            assertNull(error.code)
        }
    }
}
