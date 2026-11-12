// SPDX-License-Identifier: MIT
// One PC turn submission over the C4 DSH-facing transport (design §6 C4/C5).
//
// The runner owns the exact `session/prompt` argument shape DSH expects and the
// one rule that matters for correctness: `request.requestId` is new for every
// submission. DSH deduplicates by that id, and a reused id answers
// `{accepted:true}` without ever starting a turn — the P0 failure the iOS lane
// fixed. This class never talks to the relay, never reads a key and never logs
// the prompt text.
package com.phonedsh.probe.pc

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.pclink.PclinkDshTransport
import java.util.UUID

/**
 * The unary subset of `PclinkDshTransport` the App needs. The adapter below is
 * the only production implementation; tests pass a scripted fake so a turn can
 * be proven without a relay.
 */
internal fun interface PcDshCall {
    suspend fun call(endpoint: String, args: JsonValue): JsonValue
}

/** Production adapter: the C4 transport, unchanged. */
internal class PclinkDshTransportCall(
    private val transport: PclinkDshTransport,
) : PcDshCall {
    override suspend fun call(endpoint: String, args: JsonValue): JsonValue =
        transport.call(endpoint, args)
}

/** What DSH answered for one accepted prompt. */
internal sealed interface PcTurnOutcome {
    data class Accepted(val requestId: String) : PcTurnOutcome

    /** A well-formed `{accepted:false}`; the turn did not start. */
    data class Rejected(val requestId: String) : PcTurnOutcome
}

/**
 * Submits one `session/prompt` in `queue` mode.
 *
 * @param call the C4 transport adapter.
 * @param newRequestId injectable only so a test can prove a fresh id per
 *   submission; production uses a random UUID.
 */
internal class PcChatTurnRunner(
    private val call: PcDshCall,
    private val newRequestId: () -> String = { UUID.randomUUID().toString() },
) {
    /**
     * @throws IllegalArgumentException when the prompt is empty; the App should
     *   not turn an empty composer into a DSH request.
     * @throws com.phonedsh.pclink.PclinkError/PclinkRpcError on transport failure.
     */
    suspend fun submit(sessionId: String, text: String): PcTurnOutcome {
        require(sessionId.isNotBlank()) { "sessionId must not be blank" }
        require(text.isNotEmpty()) { "prompt text must not be empty" }
        val requestId = newRequestId()
        val request = JsonObject(
            linkedMapOf(
                "requestId" to JsonString(requestId),
                "sessionId" to JsonString(sessionId),
                "mode" to JsonString(MODE_QUEUE),
                "content" to JsonArray(
                    listOf(
                        JsonObject(
                            linkedMapOf(
                                "type" to JsonString("text"),
                                "text" to JsonString(text),
                            ),
                        ),
                    ),
                ),
            ),
        )
        val result = call.call(
            ENDPOINT,
            JsonObject(linkedMapOf("request" to request)),
        )
        val accepted = (result as? JsonObject)?.get("accepted")
        if (accepted is JsonBool && !accepted.value) {
            return PcTurnOutcome.Rejected(requestId)
        }
        return PcTurnOutcome.Accepted(requestId)
    }

    companion object {
        const val ENDPOINT: String = "session/prompt"
        const val MODE_QUEUE: String = "queue"
    }
}
