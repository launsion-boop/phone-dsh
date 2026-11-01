// phone-dsh — :net / com.phonedsh.gateway: the `/v1/http` policy adapter.
// SPDX-License-Identifier: MIT
//
// The route lives in `:loopback`; the decision lives in `GatewaySession`. This
// adapter is the only join between them, and it keeps the security ordering the
// spec fixes:
//
//   1. the target URL and upstream method are read from the Worker's headers,
//      never from the loopback path;
//   2. the gateway's egress policy is consulted first, and a refusal returns
//      before any transport is constructed or contacted (gw-egress-002);
//   3. the failure envelope carries only a stable code, a bounded reason and
//      the mapped proxy status - no caller header, body or credential.
//
// A denial is a response, not an exception: the Worker has to see the 403 and
// report the allow-list refusal, and a thrown exception from a Ktor handler
// would become an unhelpful 500.

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse

/** Translates one `/v1/http` request into one [GatewaySession] exchange. */
class GatewayHttpEgress(
    private val gateway: GatewaySession,
) : LoopbackHttpEgress {
    override fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse {
        val target = header(request.headers, TARGET_URL)
        if (target == null || target.isBlank()) {
            return failureResponse(
                GatewayFailure.invalidRequest("missing or invalid $TARGET_URL header"),
            )
        }
        val method = (header(request.headers, TARGET_METHOD) ?: request.targetMethod)
            .trim()
            .uppercase()
        val outcome = gateway.exchange(
            GatewayRequest(
                method = method,
                url = target,
                headers = request.headers,
                body = request.body,
            ),
        )
        val status = outcome.responseStatus
        val failure = outcome.failure
        if (failure != null || status == null) {
            return failureResponse(
                failure ?: GatewayFailure(
                    code = GatewayFailureCode.UPSTREAM_FAILED,
                    message = "the gateway produced no upstream response",
                ),
            )
        }
        // A refused redirect is still the upstream's 3xx: hand it back with the
        // structured cause beside it rather than inventing a second status.
        val headers = LinkedHashMap(outcome.responseHeaders)
        if (outcome.dispatch == GatewayDispatch.DENY && outcome.denyReason != null) {
            headers[DENY_REASON] = outcome.denyReason
            headers[PROXY_ERROR] = GatewayFailureCode.HOST_NOT_ALLOWED.proxyError
        }
        if (headers["content-type"] == null) headers["content-type"] = DEFAULT_CONTENT_TYPE
        return LoopbackHttpResponse(status = status, headers = headers, body = outcome.responseBody)
    }

    private fun failureResponse(failure: GatewayFailure): LoopbackHttpResponse {
        val headers = linkedMapOf(
            "content-type" to JSON_CONTENT_TYPE,
            PROXY_ERROR to failure.code.proxyError,
            DENY_REASON to failure.code.wire,
        )
        return LoopbackHttpResponse(
            status = failure.code.proxyStatus,
            headers = headers,
            body = failure.envelopeJson().toByteArray(Charsets.UTF_8),
        )
    }

    private fun header(headers: Map<String, String>, name: String): String? {
        for ((key, value) in headers) {
            if (key.equals(name, ignoreCase = true)) return value
        }
        return null
    }

    companion object {
        /** The upstream URL of one `/v1/http` request. */
        const val TARGET_URL: String = "x-pdsh-target-url"

        /** The upstream method of one `/v1/http` request. */
        const val TARGET_METHOD: String = "x-pdsh-target-method"

        const val PROXY_ERROR: String = "x-pdsh-proxy-error"
        const val DENY_REASON: String = "x-pdsh-deny-reason"
        const val JSON_CONTENT_TYPE: String = "application/json; charset=utf-8"
        const val DEFAULT_CONTENT_TYPE: String = "application/octet-stream"
    }
}
