// phone-dsh — :loopback / com.phonedsh.loopback: the `/v1/http` egress seam.
// SPDX-License-Identifier: MIT
//
// `spec/v1/README.md` §1 gives the App exactly one outbound path: a request from
// the Worker arrives on the loopback origin, and the host decides whether it may
// leave the device. This file is the seam, not the policy: `:net`'s
// `GatewayHttpEgress` owns the allow-list, credential and redaction rules, and
// `:loopback` only moves the bytes between Ktor and that policy.
//
// Two rules live here because they are transport rules rather than gateway
// rules: the request line's method is the loopback method, while the upstream
// method comes from `X-PDSH-Target-Method`; and the target URL comes from
// `X-PDSH-Target-URL`, never from the loopback path. That is the shape the
// packaged Worker's `curl` and `git` egress already send
// (`examples/probe-app/Bundle/worker/worker-entry.js`), and it keeps `/v1/http`
// a proxy route instead of a second URL scheme.

package com.phonedsh.loopback

/** One request the Worker asked the host to issue. */
data class LoopbackHttpRequest(
    /** The method of the loopback request itself (`GET`, `HEAD` or `POST`). */
    val method: String,
    /** The absolute http(s) URL taken from `X-PDSH-Target-URL`. */
    val targetUrl: String,
    /** The upstream method taken from `X-PDSH-Target-Method`, else [method]. */
    val targetMethod: String,
    /** Every caller header, lowercased; the gateway decides what survives. */
    val headers: Map<String, String>,
    /** The request body, copied off the Ktor call. */
    val body: ByteArray,
)

/** One answer the host hands back to the Worker. */
data class LoopbackHttpResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
) {
    init {
        require(status in 100..599) { "status must be 100...599, was $status" }
    }

    /** The body as UTF-8 text; the DSH and gateway bodies are JSON. */
    fun bodyText(): String = body.toString(Charsets.UTF_8)
}

/**
 * The host's one outbound decision point, as `/v1/http` sees it.
 *
 * An implementation is synchronous because the Ktor call already runs on a
 * worker thread and the gateway transport is a blocking HTTP client; the route
 * never blocks the channel's WebSocket pump.
 */
fun interface LoopbackHttpEgress {
    /** Handles one request; throws only on an internal failure, never to deny. */
    fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse
}
