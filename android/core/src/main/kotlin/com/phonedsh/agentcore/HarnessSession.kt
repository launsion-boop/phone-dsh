// Host contract 1 — open/resume requests and the session value.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * Parameters for opening a new harness session or resuming an existing one.
 *
 * Every member is optional: an empty request opens a default session. A
 * present [sessionId] means *resume*; an absent one means *new*.
 */
public data class HarnessSessionRequest(
    /** Resume this session when set; create a new one when `null`. */
    public val sessionId: String? = null,
    /** Harness-specific profile / preset name. */
    public val preset: String? = null,
    /** Working directory or workspace identifier inside the harness. */
    public val workspace: String? = null,
    /** Extra system instructions for this session. */
    public val instructions: String? = null,
    /** Tool servers the harness can call back into (normally the phone's own tool server). */
    public val clientTools: List<McpServerReference> = emptyList(),
    /** Free-form labels (task origin, device id, locale). Values are strings, as the schema requires. */
    public val metadata: Map<String, String> = emptyMap(),
)

/**
 * One MCP server the harness should be able to call during the session.
 *
 * [allowedTools] empty means "all tools the server lists".
 */
public data class McpServerReference(
    public val name: String,
    public val transport: McpTransport,
    public val allowedTools: List<String> = emptyList(),
)

/** The closed `client_tools[].transport` union of the session-request schema. */
public sealed interface McpTransport {
    /** Wire discriminator (`streamable_http`, `relay`, `in_process`). */
    public val type: String

    /** Streamable HTTP endpoint, for example the phone's loopback tool server. */
    public data class StreamableHttp(
        public val url: String,
        public val headers: Map<String, String> = emptyMap(),
    ) : McpTransport {
        override val type: String get() = "streamable_http"
    }

    /** The phone holds an outbound relay connection; [relayId] names it on the harness side. */
    public data class Relay(public val relayId: String) : McpTransport {
        override val type: String get() = "relay"
    }

    /** A same-process server identified by name (embedded harness). */
    public data class InProcess(public val name: String) : McpTransport {
        override val type: String get() = "in_process"
    }
}

/**
 * The value [AgentHarness.openSession] returns.
 *
 * [lastSeq] is the highest durable event `seq` the backend *reported at open
 * time*, and nothing else. It is optional because a backend may not know it:
 * the DSH remote returns `null` even when it resumes an existing session.
 *
 * **It is not a resume cursor.** The caller must keep the highest durable `seq`
 * it has actually consumed and pass that value to
 * [AgentHarness.events]`(sessionId, afterSeq)` itself. Deriving a cursor from
 * [lastSeq] would either skip events (a stale or too-high report) or replay
 * from the wrong point (a `null` report). See host README §2.5 and
 * `golden/harness-session-resumed.json`.
 *
 * [capabilities] is the session's (possibly narrowed) set; it never widens the
 * backend's static [AgentHarness.capabilities].
 */
public data class HarnessSession(
    public val id: String,
    public val capabilities: HarnessCapabilities,
    /** Highest durable `seq` reported by the backend at open time; `null` means not reported. */
    public val lastSeq: Long? = null,
)
