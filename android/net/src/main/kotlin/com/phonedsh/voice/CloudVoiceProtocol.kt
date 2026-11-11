// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.voice: cloud speech for a TonoLink voice turn
// (spec/v1/cloud-voice.md; shared cases spec/v1/golden/cloud-voice/cases.json).
//
// Consumer subset of the cloud's pdsh-asr.v1 and /v1/tts/speech
// (TonoTeam/phone-dsh-cloud@64a3d2098ca2). This file holds the pure pieces —
// constants, request builders, message classification, transcript, speakable,
// chunks and credential resolution — so the shared cases judge them directly.
// The transports and state machines live in CloudASRSession.kt /
// CloudTTSClient.kt / KtorCloudVoice.kt.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.net.URI

/** The consumer-side constants of cloud-voice.md §2/§3. */
object CloudVoice {
    const val ASR_URL = "wss://pdsh.tonoai.cn/v1/asr/stream"
    const val ASR_SUBPROTOCOL = "pdsh-asr.v1"
    const val TTS_URL = "https://pdsh.tonoai.cn/v1/tts/speech"
    const val TTS_VOICE = "zh-female-vv"
    const val TTS_SAMPLE_RATE = 16_000
    const val TTS_INPUT_MAX_SCALARS = 1000
    const val PRE_START_QUEUE_MAX = 100
    const val CONNECT_TIMEOUT_MS = 10_000L
    const val STARTED_TIMEOUT_MS = 5_000L
    const val FINISH_TIMEOUT_DEFAULT_MS = 15_000L
    const val FINISH_GRACE_MS = 5_000L

    /** The `start` text message (§2): interactive Chinese, raw 20 ms Opus, one utterance. */
    fun startMessage(turnId: UInt): ByteArray = GatewayJson.canonicalBytes(
        JsonValue.obj(
            "type" to JsonValue.Str("start"),
            "mode" to JsonValue.Str("interactive"),
            "language" to JsonValue.Str("zh"),
            "format" to JsonValue.obj(
                "codec" to JsonValue.Str("opus"),
                "sample_rate" to JsonValue.num(16_000),
                "channels" to JsonValue.num(1),
                "frame_ms" to JsonValue.num(20),
            ),
            "single_utterance" to JsonValue.bool(true),
            "hotwords" to JsonValue.Arr(listOf(JsonValue.Str("小智"), JsonValue.Str("托诺"))),
            "client_ref" to JsonValue.Str("tonolink-$turnId"),
        ),
    )

    /** `{"type":"finish"}` — the board's audio ended (§2). */
    val finishMessage: ByteArray = "{\"type\":\"finish\"}".toByteArray(Charsets.UTF_8)

    /** `{"type":"cancel"}` — a user cancel or a new wake (§2). */
    val cancelMessage: ByteArray = "{\"type\":\"cancel\"}".toByteArray(Charsets.UTF_8)

    /** TTS request body (§3). */
    fun speechRequest(text: String): ByteArray = GatewayJson.canonicalBytes(
        JsonValue.obj(
            "input" to JsonValue.Str(text),
            "voice" to JsonValue.Str(TTS_VOICE),
            "response_format" to JsonValue.Str("pcm"),
        ),
    )
}

/**
 * The contract's timing values, injectable so a test can exercise every
 * deadline without waiting the production interval. Defaults are the golden
 * constants; production must not pass anything else.
 */
data class CloudVoiceTiming(
    val connectTimeoutMs: Long = CloudVoice.CONNECT_TIMEOUT_MS,
    val startedTimeoutMs: Long = CloudVoice.STARTED_TIMEOUT_MS,
    val finishTimeoutDefaultMs: Long = CloudVoice.FINISH_TIMEOUT_DEFAULT_MS,
    val finishGraceMs: Long = CloudVoice.FINISH_GRACE_MS,
)

/** One server text message, classified (§2). */
sealed interface CloudASRMessage {
    data class Started(val finishTimeoutMs: Long) : CloudASRMessage
    data class Partial(val text: String) : CloudASRMessage
    data class Final(val segmentId: Int, val text: String) : CloudASRMessage
    data class Completed(val endReason: String) : CloudASRMessage
    data object Cancelled : CloudASRMessage
    data class Error(val code: String) : CloudASRMessage

    /** A known non-terminal the phone does not use, or an unknown non-terminal type. */
    data object Ignored : CloudASRMessage

    /** Not JSON, no type, or a known type with a missing or mistyped member. */
    data object Invalid : CloudASRMessage

    val isTerminal: Boolean
        get() = when (this) {
            is Completed, Cancelled, is Error, Invalid -> true
            is Started, is Partial, is Final, Ignored -> false
        }

    companion object {
        fun decode(text: String): CloudASRMessage {
            val message = GatewayJson.parseOrNull(text) as? JsonValue.Obj ?: return Invalid
            val type = message.string("type") ?: return Invalid
            return when (type) {
                "started" -> {
                    message.string("session_id") ?: return Invalid
                    val timeout = (message.obj("limits")?.get("finish_timeout_ms") as? JsonValue.Num)
                        ?.literal?.toLongOrNull()?.takeIf { it > 0 }
                    Started(timeout ?: CloudVoice.FINISH_TIMEOUT_DEFAULT_MS)
                }

                "partial" -> Partial(message.string("text") ?: return Invalid)

                "final" -> {
                    val text = message.string("text") ?: return Invalid
                    val segment = (message.get("segment_id") as? JsonValue.Num)
                        ?.literal?.toIntOrNull() ?: return Invalid
                    Final(segmentId = segment, text = text)
                }

                "completed" -> {
                    val reason = message.string("end_reason") ?: return Invalid
                    if (message.bool("final") != true) return Invalid
                    Completed(reason)
                }

                "cancelled" -> Cancelled

                "error" -> Error(message.string("code") ?: return Invalid)

                else -> Ignored
            }
        }
    }
}

/** Collects one session's finals; yields text only after `completed` (§2). */
class CloudASRTranscript {
    sealed interface Outcome {
        data object Pending : Outcome

        data class Text(val text: String) : Outcome

        /** `no_speech`, or nothing recognisable: end the turn silently. */
        data object Silent : Outcome

        data class Failed(val reason: String) : Outcome
    }

    private val finals = LinkedHashMap<Int, String>()

    var outcome: Outcome = Outcome.Pending
        private set

    fun apply(message: CloudASRMessage) {
        if (outcome != Outcome.Pending) return
        when (message) {
            is CloudASRMessage.Final -> finals.putIfAbsent(message.segmentId, message.text)

            is CloudASRMessage.Completed -> {
                val text = finals.keys.sorted().joinToString("") { finals.getValue(it) }.trim()
                outcome = if (message.endReason == "no_speech" || text.isEmpty()) {
                    Outcome.Silent
                } else {
                    Outcome.Text(text)
                }
            }

            is CloudASRMessage.Cancelled -> outcome = Outcome.Failed("cancelled")
            is CloudASRMessage.Error -> outcome = Outcome.Failed(message.code)
            is CloudASRMessage.Invalid -> outcome = Outcome.Failed("invalid server message")
            is CloudASRMessage.Started, is CloudASRMessage.Partial, is CloudASRMessage.Ignored -> Unit
        }
    }

    /** Ended on the phone (cancel, missed deadline): no text is used. */
    fun fail(reason: String) {
        if (outcome == Outcome.Pending) outcome = Outcome.Failed(reason)
    }

    /** The connection closed without a terminal message: incomplete, never used. */
    fun closed() {
        if (outcome == Outcome.Pending) outcome = Outcome.Failed("closed without a result")
    }
}

/** Reply text → what TTS reads (§3). */
object CloudVoiceSpeech {
    private val LINK = Regex("\\[([^]]*)]\\([^)]*\\)")
    private val BULLETS = listOf("- ", "* ", "+ ", "> ")
    private val ENDERS = setOf("。", "！", "？", "；", ".", "!", "?", ";", "\n")

    fun speakable(text: String): String {
        val lines = ArrayList<String>()
        var inFence = false
        for (raw in text.split("\n")) {
            val trimmed = raw.trim()
            if (trimmed.startsWith("```")) {
                inFence = !inFence
                continue
            }
            if (inFence) continue
            var line = trimmed
            while (line.startsWith("#")) line = line.removePrefix("#")
            for (bullet in BULLETS) if (line.startsWith(bullet)) line = line.removePrefix(bullet)
            lines.add(line)
        }
        var out = lines.joinToString(" ")
        out = LINK.replace(out, "$1")
        for (mark in listOf("**", "__", "`")) out = out.replace(mark, "")
        return collapseWhitespace(out)
    }

    /**
     * Splits at the last sentence end at or before [max] scalars, else cuts at
     * [max] (§3). Concatenating the result gives the input back.
     */
    fun chunks(text: String, max: Int = CloudVoice.TTS_INPUT_MAX_SCALARS): List<String> {
        require(max > 0) { "chunk max must be positive" }
        val scalars = scalars(text)
        val result = ArrayList<String>()
        var start = 0
        while (start < scalars.size) {
            val remaining = scalars.size - start
            if (remaining <= max) {
                result.add(scalars.subList(start, scalars.size).joinToString(""))
                break
            }
            var cut = max
            for (index in max - 1 downTo 0) {
                if (scalars[start + index] in ENDERS) {
                    cut = index + 1
                    break
                }
            }
            result.add(scalars.subList(start, start + cut).joinToString(""))
            start += cut
        }
        return result.filter { it.isNotBlank() }
    }

    private fun scalars(text: String): List<String> {
        val result = ArrayList<String>(text.length)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val width = Character.charCount(codePoint)
            result.add(text.substring(index, index + width))
            index += width
        }
        return result
    }

    private fun collapseWhitespace(text: String): String {
        val result = StringBuilder(text.length)
        var pendingSpace = false
        for (character in text) {
            if (character.isWhitespace()) {
                pendingSpace = result.isNotEmpty()
            } else {
                if (pendingSpace) result.append(' ')
                pendingSpace = false
                result.append(character)
            }
        }
        return result.toString()
    }
}

/** Which credential a voice turn uses (§1). Pure, so the shared cases judge it. */
object CloudVoiceCredential {
    sealed interface Account {
        data object SignedOut : Account
        data class Token(val value: String) : Account

        /** Signed in but no token could be obtained: fail closed. */
        data object Unavailable : Account
    }

    fun resolve(account: Account, profileBaseUrl: String?, profileKey: String?): String? = when (account) {
        is Account.Token -> account.value.ifEmpty { null }
        Account.Unavailable -> null
        Account.SignedOut -> {
            if (profileBaseUrl == null || !isCloudOrigin(profileBaseUrl)) {
                null
            } else {
                profileKey?.ifEmpty { null }
            }
        }
    }

    fun isCloudOrigin(raw: String): Boolean {
        val uri = try {
            URI(raw.trim())
        } catch (_: Exception) {
            return false
        }
        if (!uri.scheme.equals("https", ignoreCase = true)) return false
        if (!uri.host.equals("pdsh.tonoai.cn", ignoreCase = true)) return false
        if (uri.userInfo != null || uri.rawUserInfo != null) return false
        return uri.port == -1 || uri.port == 443
    }
}

/** A cloud speech failure, carrying the HTTP status and the service error code when present. */
class CloudVoiceException(
    val status: Int?,
    val code: String?,
    message: String,
) : Exception(message) {
    /** The tono-account §5 rule: only a 401 is worth one credential re-resolve. */
    val isCredentialExpired: Boolean
        get() = status == 401
}
