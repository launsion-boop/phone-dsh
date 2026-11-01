// phone-dsh — :net / com.phonedsh.gateway: the failure surface.
// SPDX-License-Identifier: MIT
//
// A denial fails loud and structured (§7): a stable lower-snake cause that the
// loopback `/v1/http` layer copies into the body and `X-PDSH-Proxy-Error`, the
// mapped status, and no upstream contact. Nothing secret may ride the
// diagnostic: no credential value, no request header, no request body, and no
// provider error text (gw-fail-001..004). A transport reason is capped at 256
// characters and made newline-free before it reaches a body or a log.

package com.phonedsh.gateway

/** Stable failure classes and their `/v1/http` mapping. */
enum class GatewayFailureCode(
    val wire: String,
    val proxyStatus: Int,
    val proxyError: String,
) {
    HOST_NOT_ALLOWED("host_not_allowed", 403, "forbidden"),
    INVALID_REQUEST("invalid_request", 400, "bad_request"),
    CREDENTIAL_UNAVAILABLE("credential_unavailable", 502, "credential_unavailable"),
    SHUTTING_DOWN("shutting_down", 502, "shutting_down"),
    TRANSPORT_FAILURE("transport_failure", 502, "upstream"),
    UPSTREAM_STATUS("upstream_status", 502, "upstream"),
    UPSTREAM_FAILED("upstream_failed", 502, "upstream"),
}

/** One denial, with the fields the vector's `expect.failure` names. */
data class GatewayFailure(
    val code: GatewayFailureCode,
    val message: String,
    val host: String? = null,
    val upstreamContacts: Int = 0,
) {
    /** The structured fields as the vectors and the loopback layer see them. */
    fun fields(): Map<String, JsonValue> {
        val fields = LinkedHashMap<String, JsonValue>()
        fields["code"] = JsonValue.Str(code.wire)
        fields["proxy_status"] = JsonValue.num(code.proxyStatus)
        fields["proxy_error"] = JsonValue.Str(code.proxyError)
        fields["upstream_contacts"] = JsonValue.num(upstreamContacts)
        fields["reason"] = JsonValue.Str(reasonText())
        if (host != null) fields["host"] = JsonValue.Str(host)
        return fields
    }

    /** The bounded, newline-free diagnostic surfaced in the envelope and log. */
    fun reasonText(): String = boundedReason(message)

    /** A bounded, secret-free error envelope for a `/v1/http` body. */
    fun envelopeJson(): String {
        val envelope = JsonValue.obj(
            "error" to JsonValue.obj(
                "code" to JsonValue.Str(code.wire),
                "message" to JsonValue.Str(reasonText()),
            ),
        )
        return GatewayJson.canonicalText(envelope)
    }

    companion object {
        const val MAX_REASON_LENGTH = 256

        /** Stable prefix of a transport-failure reason (gw-fail-004). */
        const val TRANSPORT_REASON_PREFIX = "upstream transport failed: "

        /** Caps at [MAX_REASON_LENGTH] characters and removes CR/LF and CRLF. */
        fun boundedReason(raw: String?): String {
            val text = raw.orEmpty()
                .replace("\r\n", " ")
                .replace('\r', ' ')
                .replace('\n', ' ')
                .trim()
            return if (text.length <= MAX_REASON_LENGTH) text else text.substring(0, MAX_REASON_LENGTH)
        }

        /** No credential, no header, no body, no provider error text. */
        fun hostNotAllowed(host: String): GatewayFailure = GatewayFailure(
            code = GatewayFailureCode.HOST_NOT_ALLOWED,
            message = "upstream host is not allowed: $host",
            host = host,
            upstreamContacts = 0,
        )

        fun invalidRequest(reason: String): GatewayFailure = GatewayFailure(
            code = GatewayFailureCode.INVALID_REQUEST,
            message = "invalid gateway request: ${boundedReason(reason)}",
            upstreamContacts = 0,
        )

        /** The provider's own text is deliberately not forwarded. */
        fun credentialUnavailable(): GatewayFailure = GatewayFailure(
            code = GatewayFailureCode.CREDENTIAL_UNAVAILABLE,
            message = "no credential is configured for the upstream host",
            upstreamContacts = 0,
        )

        fun transportFailure(reason: String?): GatewayFailure = GatewayFailure(
            code = GatewayFailureCode.TRANSPORT_FAILURE,
            message = "$TRANSPORT_REASON_PREFIX${boundedReason(reason)}",
            upstreamContacts = 1,
        )

        fun redirectLimitExceeded(limit: Int): GatewayFailure = GatewayFailure(
            code = GatewayFailureCode.TRANSPORT_FAILURE,
            message = "redirect chain exceeded $limit hops",
            upstreamContacts = 1,
        )
    }
}
