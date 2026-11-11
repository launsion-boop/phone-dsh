// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.voice: the `/v1/tts/speech` consumer
// (spec/v1/cloud-voice.md §3). 16 kHz mono s16le, played as it streams; HTTP
// chunk boundaries are not sample boundaries, so this client re-chunks to whole
// samples and drops a trailing half sample rather than emitting it.

package com.phonedsh.voice

import java.io.ByteArrayOutputStream
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow

class CloudTTSClient(
    private val credentials: CloudVoiceCredentialProvider,
    private val transport: CloudTtsTransport = KtorCloudTtsTransport(),
    /** Production is [CloudVoice.TTS_URL]; only a test's local server overrides it. */
    private val url: String = CloudVoice.TTS_URL,
) {
    /**
     * Streams the reply's PCM. The flow throws [CloudVoiceException] for a
     * non-200 answer or an unavailable credential; a stream that fails after
     * audio started is incomplete and stops there (§3).
     */
    fun stream(text: String): Flow<ByteArray> = flow {
        val scalars = text.codePointCount(0, text.length)
        if (scalars !in 1..CloudVoice.TTS_INPUT_MAX_SCALARS) {
            throw CloudVoiceException(null, null, "TTS input must be 1…1000 Unicode scalars")
        }
        val credential = credentials.credential()
            ?: throw CloudVoiceException(null, null, "voice is unavailable without a credential")
        if (credential.isEmpty()) {
            throw CloudVoiceException(null, null, "voice is unavailable without a credential")
        }
        val request = CloudTtsRequest(
            url = url,
            body = CloudVoice.speechRequest(text),
            credential = credential,
        )
        val pending = ByteArrayOutputStream(PCM_CHUNK_BYTES)
        transport.stream(request).collect { bytes ->
            if (bytes.isEmpty()) return@collect
            pending.write(bytes)
            while (pending.size() >= PCM_CHUNK_BYTES) {
                val buffered = pending.toByteArray()
                emit(buffered.copyOfRange(0, PCM_CHUNK_BYTES))
                pending.reset()
                pending.write(buffered, PCM_CHUNK_BYTES, buffered.size - PCM_CHUNK_BYTES)
            }
        }
        val remaining = pending.size()
        if (remaining > 1) {
            // s16le: a final odd byte is half a sample and is not played.
            emit(pending.toByteArray().copyOf(remaining and 1.inv()))
        }
    }

    companion object {
        /** 100 ms of 16 kHz mono s16le: the playback-sized emission. */
        const val PCM_CHUNK_BYTES = 3200
    }
}
