// SPDX-License-Identifier: MIT
// phone-dsh — :net tests: spec/v1/golden/cloud-voice/cases.json on Android.
//
// Every row of the golden's five case sections and its two singletons
// (constants, start) is executed against the real Kotlin builders/classifier/
// transcript/chunker. Nothing here contacts pdsh.tonoai.cn; the session and TTS
// transports are faked in the sibling tests.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudVoiceGoldenTest {
    private val fixture: JsonValue.Obj by lazy {
        val path = Path.of(
            System.getProperty("pdsh.repo.root")
                ?: error("pdsh.repo.root is not set; the :net test task supplies it"),
        ).resolve("spec/v1/golden/cloud-voice/cases.json")
        assertTrue("shared cases must exist at $path", Files.isRegularFile(path))
        GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
    }

    private fun rows(name: String): List<JsonValue.Obj> =
        requireNotNull(fixture.array(name)) { "$name is missing" }.map { it as JsonValue.Obj }

    private fun textOf(value: JsonValue): String =
        String(GatewayJson.canonicalBytes(value), StandardCharsets.UTF_8)

    @Test
    fun constantsMatchTheContract() {
        val constants = requireNotNull(fixture.obj("constants"))
        assertEquals(CloudVoice.ASR_URL, constants.string("asr_url"))
        assertEquals(CloudVoice.ASR_SUBPROTOCOL, constants.string("asr_subprotocol"))
        assertEquals(CloudVoice.TTS_URL, constants.string("tts_url"))
        assertEquals(CloudVoice.TTS_VOICE, constants.string("tts_voice"))
        assertEquals(CloudVoice.TTS_SAMPLE_RATE, constants.int("tts_sample_rate"))
        assertEquals(CloudVoice.TTS_INPUT_MAX_SCALARS, constants.int("tts_input_max_scalars"))
        assertEquals(CloudVoice.PRE_START_QUEUE_MAX, constants.int("pre_start_queue_max"))
        assertEquals(CloudVoice.CONNECT_TIMEOUT_MS, constants.int("connect_timeout_ms")!!.toLong())
        assertEquals(CloudVoice.STARTED_TIMEOUT_MS, constants.int("started_timeout_ms")!!.toLong())
        assertEquals(CloudVoice.FINISH_TIMEOUT_DEFAULT_MS, constants.int("finish_timeout_default_ms")!!.toLong())
        assertEquals(CloudVoice.FINISH_GRACE_MS, constants.int("finish_grace_ms")!!.toLong())
    }

    @Test
    fun theStartMessageIsTheGoldenObject() {
        val start = requireNotNull(fixture.obj("start"))
        val built = requireNotNull(
            GatewayJson.parseOrNull(CloudVoice.startMessage(start.int("turn_id")!!.toUInt())) as? JsonValue.Obj,
        ) { "startMessage must be a JSON object" }
        assertTrue(
            "start message differs from the golden",
            GatewayJson.structuralEquals(requireNotNull(start.get("message")), built),
        )
        assertEquals("tonolink-${start.int("turn_id")}", built.string("client_ref"))
    }

    @Test
    fun everyCredentialRow() {
        val credentials = rows("credentials")
        assertEquals("the golden's credentials section", 9, credentials.size)
        for (row in credentials) {
            val account = if (row.bool("signed_in") == true) {
                row.string("token")?.let { CloudVoiceCredential.Account.Token(it) }
                    ?: CloudVoiceCredential.Account.Unavailable
            } else {
                CloudVoiceCredential.Account.SignedOut
            }
            assertEquals(
                row.string("name"),
                row.string("expect"),
                CloudVoiceCredential.resolve(
                    account = account,
                    profileBaseUrl = row.string("profile_base_url"),
                    profileKey = row.string("profile_key"),
                ),
            )
        }
    }

    @Test
    fun everyServerMessageRow() {
        val messages = rows("server_messages")
        assertEquals("the golden's server_messages section", 16, messages.size)
        for (row in messages) {
            val body = row.string("raw") ?: textOf(requireNotNull(row.get("json")))
            val expect = requireNotNull(row.obj("expect"))
            val want = when (expect.string("kind")) {
                "started" -> CloudASRMessage.Started(expect.int("finish_timeout_ms")!!.toLong())
                "partial" -> CloudASRMessage.Partial(expect.string("text")!!)
                "final" -> CloudASRMessage.Final(
                    segmentId = expect.int("segment_id")!!,
                    text = expect.string("text")!!,
                )

                "completed" -> CloudASRMessage.Completed(expect.string("end_reason")!!)
                "cancelled" -> CloudASRMessage.Cancelled
                "error" -> CloudASRMessage.Error(expect.string("code")!!)
                "ignored" -> CloudASRMessage.Ignored
                else -> CloudASRMessage.Invalid
            }
            assertEquals(body, want, CloudASRMessage.decode(body))
        }
    }

    @Test
    fun aZeroFinishLimitUsesTheDefault() {
        assertEquals(
            CloudASRMessage.Started(CloudVoice.FINISH_TIMEOUT_DEFAULT_MS),
            CloudASRMessage.decode("""{"type":"started","session_id":"s","limits":{"finish_timeout_ms":0}}"""),
        )
    }

    @Test
    fun aLocalEndIsFinal() {
        val transcript = CloudASRTranscript()
        transcript.fail("cancelled")
        transcript.apply(CloudASRMessage.Completed("finish"))
        assertEquals(CloudASRTranscript.Outcome.Failed("cancelled"), transcript.outcome)
    }

    @Test
    fun everyTranscriptRow() {
        val transcripts = rows("transcripts")
        assertEquals("the golden's transcripts section", 7, transcripts.size)
        for (row in transcripts) {
            val transcript = CloudASRTranscript()
            for (step in requireNotNull(row.array("messages")).map { (it as JsonValue.Str).value }) {
                val parts = step.split(":", limit = 3)
                when (parts[0]) {
                    "final" -> transcript.apply(
                        CloudASRMessage.Final(segmentId = parts[1].toInt(), text = parts[2]),
                    )

                    "partial" -> transcript.apply(CloudASRMessage.Partial(parts[1]))
                    "completed" -> transcript.apply(CloudASRMessage.Completed(parts[1]))
                    "error" -> transcript.apply(CloudASRMessage.Error(parts[1]))
                    "cancelled" -> transcript.apply(CloudASRMessage.Cancelled)
                    "close" -> transcript.closed()
                    else -> error("unknown transcript step $step")
                }
            }
            val expected = row.string("expect")
            if (expected != null) {
                assertEquals("$row", expected, (transcript.outcome as? CloudASRTranscript.Outcome.Text)?.text)
            } else {
                assertNotEquals("$row must end", CloudASRTranscript.Outcome.Pending, transcript.outcome)
                assertFalse("$row must not yield text", transcript.outcome is CloudASRTranscript.Outcome.Text)
            }
        }
    }

    @Test
    fun everySpeakableRow() {
        val speakable = rows("speakable")
        assertEquals("the golden's speakable section", 5, speakable.size)
        for (row in speakable) {
            assertEquals(row.string("input"), row.string("expect"), CloudVoiceSpeech.speakable(row.string("input")!!))
        }
    }

    @Test
    fun everyChunksRow() {
        val chunks = rows("chunks")
        assertEquals("the golden's chunks section", 4, chunks.size)
        for (row in chunks) {
            val input = row.obj("input_repeat")?.let { repeat ->
                (repeat.string("unit")!!).repeat(repeat.int("count")!!)
            } ?: row.string("input")!!
            val max = row.int("max")!!
            val result = CloudVoiceSpeech.chunks(input, max)
            val lengths = row.array("expect_lengths")
            if (lengths != null) {
                assertEquals(row.toString(), lengths.map { (it as JsonValue.Num).literal.toInt() }, result.map { it.codePointCount(0, it.length) })
            } else {
                assertEquals(
                    row.toString(),
                    requireNotNull(row.array("expect")).map { (it as JsonValue.Str).value },
                    result,
                )
            }
            assertEquals("chunks must concatenate to the input: $row", input, result.joinToString(""))
        }
    }
}
