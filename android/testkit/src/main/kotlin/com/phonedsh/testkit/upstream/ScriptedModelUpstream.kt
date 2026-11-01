// :testkit upstream — a scripted model upstream for turn tests (TEST SURFACE, never published).
// SPDX-License-Identifier: MIT
//
// ---- what this is ----------------------------------------------------------
// A local HTTP server that answers a model request with a PRE-SET script:
//
//   request 1 (no tool result in the transcript)  -> one tool call
//   request 2 (the transcript now has a result)   -> a final assistant text
//
// The model is a script, not a model. There is no inference, no weights and no
// provider credential; the only thing this server does is make the turn's
// non-deterministic half deterministic so the deterministic half (the host's
// exec lane, the WAL, the channel) can be asserted end to end.
//
// ---- why two wire formats ------------------------------------------------
// The DSH worker in `examples/probe-app/Bundle/worker` speaks the Messages wire
// format (`POST <base>/v1/messages`, SSE — `@deepseek-ai/dsh-llm-deepseek`,
// `src/adapter.ts`), so that route is the one a real turn uses. The task for
// this lane also requires an OpenAI-compatible `POST /v1/chat/completions`
// route, so the same script is encoded both ways and the JVM gateway egress
// test drives the OpenAI one. The script itself is format-neutral.
//
// ---- where it may live ---------------------------------------------------
// `:testkit` is a test-support module: not an AAR entry point (`:lib` is), not
// published, and not a transitive dependency of the probe app. A scripted model
// must never be reachable from a release APK, so this file lives here and not
// in `:net`, `:dsh` or `:engine`.

package com.phonedsh.testkit.upstream

import com.phonedsh.testkit.http.HttpRequest
import com.phonedsh.testkit.http.HttpResponse
import com.phonedsh.testkit.http.MiniHttpServer
import java.nio.charset.StandardCharsets

/** One request the scripted upstream received, kept for assertions. */
data class RecordedModelRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val body: String,
) {
    /** `true` when the gateway injected an `authorization` header on the way out. */
    val hasAuthorization: Boolean get() = headers.containsKey("authorization")

    /** `true` when the transcript this request carried already held a tool result. */
    val carriesToolResult: Boolean get() = transcriptHasToolResult(body)

    /** `true` when this is DSH's session-title LLM call, not a turn request. */
    val isTitleRequest: Boolean get() = com.phonedsh.testkit.upstream.isTitleRequest(body)
}

/**
 * The script. Every member is text, so a test can quote the exact strings it
 * asserts in the event stream.
 *
 * @param toolName the tool the scripted assistant calls (`bash` on the phone
 *   worker: it is the tool whose `command` runs the host's `phone` accelerator).
 * @param toolCommand the shell command the tool call carries.
 * @param toolDescription the tool call's one-line description.
 * @param pendingText the text block emitted before the tool call.
 * @param finalText the final assistant text, emitted once the transcript has the
 *   tool result.
 */
data class ScriptedModelScript(
    val toolName: String = "bash",
    val toolCommand: String = "phone info",
    val toolDescription: String = "Ask the host for the phone's facts (exec/1 accelerator)",
    val pendingText: String = "I will ask the host for the phone's facts.",
    val finalText: String = "The host executed `phone info`; done.",
    /** Answer for DSH's session-title LLM call, which must be text-only. */
    val titleText: String = "Phone info",
)

/**
 * The scripted upstream. [start] binds 127.0.0.1:0, [stop] closes it.
 *
 * Thread-safe: model clients may issue their two requests concurrently, and the
 * recorded lists are read from the test thread.
 */
class ScriptedModelUpstream(
    @Volatile var script: ScriptedModelScript = ScriptedModelScript(),
) {
    private val lock = Any()
    private val recorded = mutableListOf<RecordedModelRequest>()

    /** Optional observer for tests; called after a request was recorded. */
    @Volatile
    var onRequest: ((RecordedModelRequest) -> Unit)? = null
    private val bodies = mutableListOf<String>()
    private val server = MiniHttpServer(::answer, name = "scripted-model-upstream")

    /** The bound port; valid after [start]. */
    val port: Int get() = server.port

    /** `http://127.0.0.1:<port>`; the value a worker's `DEEPSEEK_BASE_URL` gets. */
    val baseUrl: String get() = server.baseUrl

    /** Every complete model request this server answered, in order. */
    val requests: List<RecordedModelRequest> get() = synchronized(lock) { recorded.toList() }

    /** Every complete 200 response body, in order (diagnostics). */
    val responseBodies: List<String> get() = synchronized(lock) { bodies.toList() }

    fun start(): ScriptedModelUpstream {
        server.start()
        return this
    }

    fun stop() = server.stop()

    /** The path a Messages-wire client appends to [baseUrl]. */
    val messagesPath: String get() = MESSAGES_PATH

    /** The path an OpenAI-wire client appends to [baseUrl]. */
    val chatCompletionsPath: String get() = CHAT_COMPLETIONS_PATH

    private fun answer(request: HttpRequest): HttpResponse {
        val path = request.path.substringBefore('?')
        val body = request.bodyText()
        if (request.method == "GET" && (path == "/health" || path == "/")) {
            return HttpResponse.json(200, """{"status":"ok"}""")
        }
        if (request.method != "POST") {
            return HttpResponse.error(405, "method_not_allowed", "the scripted upstream answers POST only")
        }
        when (path) {
            MESSAGES_PATH -> {
                record(request)
                val respondWithTool = !isTitleRequest(body) && !transcriptHasToolResult(body)
                val payload = messagesEvents(body, respondWithTool, if (isTitleRequest(body)) script.titleText else null)
                return HttpResponse.json(200, payload, contentType = SSE_CONTENT_TYPE)
            }

            CHAT_COMPLETIONS_PATH -> {
                record(request)
                val respondWithTool = !isTitleRequest(body) && !transcriptHasToolResult(body)
                val streamed = Regex("\"stream\"\\s*:\\s*true").containsMatchIn(body)
                val payload = if (streamed) {
                    chatCompletionStream(body, respondWithTool)
                } else {
                    chatCompletion(body, respondWithTool)
                }
                return HttpResponse.json(200, payload, contentType = if (streamed) SSE_CONTENT_TYPE else JSON_CONTENT_TYPE)
            }

            else -> return HttpResponse.error(404, "not_found", "no scripted route for $path")
        }
    }

    private fun record(request: HttpRequest) {
        val entry = RecordedModelRequest(
            method = request.method,
            path = request.path,
            headers = request.headers,
            body = request.bodyText(),
        )
        synchronized(lock) { recorded += entry }
        onRequest?.invoke(entry)
    }

    // ---------------------------------------------------------------- OpenAI

    /**
     * One non-streamed `chat.completion`.
     *
     * A tool-call reply carries `message.tool_calls` and `finish_reason:
     * "tool_calls"`; the final reply carries `message.content` and
     * `finish_reason: "stop"`.
     */
    private fun chatCompletion(requestBody: String, respondWithTool: Boolean): String {
        val model = modelOf(requestBody)
        val message: String
        val finish: String
        if (respondWithTool) {
            val arguments = toolArgumentsJson()
            message = """{"role":"assistant","content":${quote(script.pendingText)},""" +
                """"tool_calls":[{"id":"call_scripted_1","type":"function","function":""" +
                """{"name":${quote(script.toolName)},"arguments":${quote(arguments)}}}]}"""
            finish = "tool_calls"
        } else {
            message = """{"role":"assistant","content":${quote(script.finalText)}}"""
            finish = "stop"
        }
        return """{"id":"chatcmpl-scripted-1","object":"chat.completion","created":0,""" +
            """"model":${quote(model)},"choices":[{"index":0,"message":$message,""" +
            """"finish_reason":${quote(finish)}}],"usage":{"prompt_tokens":64,""" +
            """"completion_tokens":24,"total_tokens":88}}"""
    }

    /** One streamed `chat.completion.chunk` sequence, ending with `[DONE]`. */
    private fun chatCompletionStream(requestBody: String, respondWithTool: Boolean): String {
        val model = modelOf(requestBody)
        val chunks = StringBuilder()
        fun emit(deltaJson: String, finish: String?) {
            chunks.append("data: ")
            chunks.append(
                """{"id":"chatcmpl-scripted-1","object":"chat.completion.chunk","created":0,""" +
                    """"model":${quote(model)},"choices":[{"index":0,"delta":$deltaJson,""" +
                    """"finish_reason":${finish?.let { quote(it) } ?: "null"}}]}""",
            )
            chunks.append("\n\n")
        }
        emit("""{"role":"assistant","content":${quote(script.pendingText)}}""", null)
        if (respondWithTool) {
            emit(
                """{"tool_calls":[{"index":0,"id":"call_scripted_1","type":"function",""" +
                    """"function":{"name":${quote(script.toolName)},"arguments":${quote(toolArgumentsJson())}}}]}""",
                null,
            )
            emit("{}", "tool_calls")
        } else {
            emit("""{"content":${quote(script.finalText)}}""", null)
            emit("{}", "stop")
        }
        chunks.append("data: [DONE]\n\n")
        return chunks.toString()
    }

    // -------------------------------------------------------------- Messages

    /**
     * The Messages SSE body the DSH DeepSeek adapter parses.
     *
     * Same shape as the Swift reference mock (`MockModelUpstream.events(for:)`):
     * `message_start`, a text block, an optional `tool_use` block, `message_delta`
     * with `stop_reason` `tool_use`/`end_turn`, then `message_stop`.
     */
    private fun messagesEvents(
        requestBody: String,
        respondWithTool: Boolean,
        textOnly: String? = null,
    ): String {
        val model = modelOf(requestBody)
        val text = textOnly ?: if (respondWithTool) script.pendingText else script.finalText
        val out = StringBuilder()
        fun emit(event: String, payload: String) {
            out.append("event: ").append(event).append('\n')
            out.append("data: ").append(payload).append("\n\n")
        }
        emit(
            "message_start",
            """{"type":"message_start","message":{"id":"msg_scripted_1","type":"message",""" +
                """"role":"assistant","model":${quote(model)},"content":[],""" +
                """"usage":{"input_tokens":64,"output_tokens":0}}}""",
        )
        emit(
            "content_block_start",
            """{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}""",
        )
        emit(
            "content_block_delta",
            """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta",""" +
                """"text":${quote(text)}}}""",
        )
        emit("content_block_stop", """{"type":"content_block_stop","index":0}""")
        if (respondWithTool) {
            emit(
                "content_block_start",
                """{"type":"content_block_start","index":1,"content_block":{"type":"tool_use",""" +
                    """"id":"toolu_scripted_1","name":${quote(script.toolName)},"input":{}}}""",
            )
            emit(
                "content_block_delta",
                """{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta",""" +
                    """"partial_json":${quote(toolArgumentsJson())}}}""",
            )
            emit("content_block_stop", """{"type":"content_block_stop","index":1}""")
        }
        val stopReason = if (respondWithTool) "tool_use" else "end_turn"
        emit(
            "message_delta",
            """{"type":"message_delta","delta":{"stop_reason":${quote(stopReason)}},""" +
                """"usage":{"output_tokens":24}}""",
        )
        emit("message_stop", """{"type":"message_stop"}""")
        return out.toString()
    }

    /** The tool call's arguments object, as the JSON text a model would stream. */
    private fun toolArgumentsJson(): String =
        """{"command":${quote(script.toolCommand)},"description":${quote(script.toolDescription)}}"""

    private fun modelOf(body: String): String =
        Regex("\"model\"\\s*:\\s*\"([^\"]+)\"").find(body)?.groupValues?.get(1) ?: "deepseek-flash"

    /** Quotes one string as a JSON string literal without pulling in a JSON writer. */
    private fun quote(value: String): String {
        val out = StringBuilder(value.length + 2)
        out.append('"')
        for (character in value) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (character.code < 0x20) {
                    out.append("\\u").append(String.format("%04x", character.code))
                } else {
                    out.append(character)
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    private companion object {
        const val MESSAGES_PATH = "/v1/messages"
        const val CHAT_COMPLETIONS_PATH = "/v1/chat/completions"
        const val JSON_CONTENT_TYPE = "application/json"
        const val SSE_CONTENT_TYPE = "text/event-stream"
    }
}

/**
 * Whether this request is DSH's session-title LLM call.
 *
 * The title service asks for text and rejects a tool call by name
 * (`session-title-llm: title output must contain text only`), so the script
 * answers it with [ScriptedModelScript.titleText]. This is still the script: no
 * inference happens for it either.
 */
internal fun isTitleRequest(body: String): Boolean =
    body.contains("Generate the session title", ignoreCase = true) ||
        body.contains("dsh-session-title-llm", ignoreCase = true)

/**
 * Whether the transcript already carries a tool result, in either wire format.
 *
 * OpenAI: a `"role":"tool"` message. Messages: a `tool_result` content block.
 * The check is textual on purpose — the fixture must not depend on a JSON parser
 * to decide its own script, and the two formats are distinguishable by these two
 * literals only.
 */
internal fun transcriptHasToolResult(body: String): Boolean {
    if (Regex("\"role\"\\s*:\\s*\"tool\"").containsMatchIn(body)) return true
    return Regex("\"type\"\\s*:\\s*\"tool_result\"").containsMatchIn(body)
}

/** The UTF-8 bytes of [text]; a convenience for callers that build request bodies. */
internal fun utf8(text: String): ByteArray = text.toByteArray(StandardCharsets.UTF_8)
