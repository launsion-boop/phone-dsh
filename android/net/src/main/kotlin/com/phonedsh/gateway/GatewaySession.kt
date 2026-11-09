// phone-dsh — :net / com.phonedsh.gateway: one upstream exchange.
// SPDX-License-Identifier: MIT
//
// The session is the only place the six rule classes meet, in this order:
//   1. scheme gate + allow-list (egress-classification) — a pre-flight deny
//      opens no socket and resolves no credential;
//   2. credential resolution for the URL scope (credential-injection);
//   3. caller-header strip, then the host credential applied last;
//   4. redirect hops re-authorized one by one (redirect-scope), credential
//      re-applied inside the same origin scope, 3xx handed back on refusal;
//   5. response headers filtered/sanitized; a sensitive body withheld or
//      redacted and never logged (response-redaction);
//   6. a denial carries a stable structured cause and no secret
//      (failure-surface).
//
// The transport is injectable on purpose: no vector needs a real socket, and a
// fake transport makes "no upstream contact" an assertion instead of a hope.

package com.phonedsh.gateway

import java.nio.charset.StandardCharsets

/** An upstream request as the Worker hands it to the gateway. */
data class GatewayRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
)

/** One request the gateway actually issues to the transport. */
data class GatewayTransportRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray,
)

/** One upstream answer, redirects not followed by the transport. */
data class GatewayTransportResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
)

/** Issues exactly one hop; the gateway owns redirect following. */
interface GatewayTransport {
    fun execute(request: GatewayTransportRequest): GatewayTransportResponse
}

/**
 * A transport-level failure (connection refused, timeout, reset), thrown by
 * [GatewayTransport] instead of returning a response. The message is the
 * provider-side diagnostic: the gateway bounds it to 256 newline-free
 * characters before surfacing it, and never forwards it as an unstructured
 * body (gw-fail-004).
 */
class GatewayTransportException(message: String) : Exception(message)

enum class GatewayDispatch(val wire: String) {
    ALLOW("allow"),
    DENY("deny"),
}

/** Everything one exchange produced, including the parts no vector asserts. */
data class GatewayOutcome(
    val dispatch: GatewayDispatch,
    val denyReason: String? = null,
    val failure: GatewayFailure? = null,
    /** Headers of the last request actually issued (empty before any contact). */
    val lastRequestHeaders: Map<String, String> = emptyMap(),
    val responseStatus: Int? = null,
    /** Response headers handed to the Worker (filtered, sanitized). */
    val responseHeaders: Map<String, String> = emptyMap(),
    val responseBody: ByteArray = ByteArray(0),
    val bodyWithheld: Boolean = false,
    /** Last URL actually contacted; "" for a pre-flight deny. */
    val outboundUrl: String = "",
    val finalUrl: String = "",
    val redirectsFollowed: Int = 0,
    val upstreamContacts: Int = 0,
    /** Caller header names removed by name, sorted. */
    val stripped: List<String> = emptyList(),
    val log: ResponseLogOutcome? = null,
    /** Every credential lookup this exchange made, in order. */
    val credentialScopes: List<CredentialScope> = emptyList(),
    /** 1 when the Worker tried to supply a credential, otherwise 0. */
    val workerCredentialsDropped: Int = 0,
)

/** The gateway: pure policy plus one injectable transport. */
class GatewaySession(
    private val transport: GatewayTransport,
    private val credentialProvider: GatewayCredentialProvider,
    private val egress: EgressPolicy,
    quotaBytes: Int = DEFAULT_QUOTA_BYTES,
    private val requestHeaders: RequestHeaderSanitizer = DenylistRequestHeaderSanitizer(),
    private val redirects: RedirectAuthorizer = ScopePinningRedirectAuthorizer(),
    private val sensitiveCalls: SensitiveCallClassifier = McpCallClassifier(),
    private val redactor: CanonicalSensitiveBodyRedactor = CanonicalSensitiveBodyRedactor(),
    private val responseHeaders: ResponseHeaderSanitizer = DenylistResponseHeaderSanitizer(),
    val responseLog: ResponseLog = ResponseLog(quotaBytes),
    private val maxRedirects: Int = DEFAULT_MAX_REDIRECTS,
) {
    fun exchange(request: GatewayRequest): GatewayOutcome {
        val method = request.method.trim().uppercase()
        if (method.isEmpty()) {
            return preflightDeny(GatewayFailure.invalidRequest("empty method"))
        }
        val url = GatewayUrls.parse(request.url)
            ?: return preflightDeny(GatewayFailure.invalidRequest("upstream URL must be an absolute URL"))
        if (!url.isHttp) {
            return preflightDeny(GatewayFailure.invalidRequest("upstream URL must be http(s)"))
        }
        // Default deny, before credential resolution and before any connection.
        if (!egress.permits(url)) {
            return preflightDeny(GatewayFailure.hostNotAllowed(url.host))
        }

        val scopes = ArrayList<CredentialScope>(1)
        val scope = CredentialScope.of(url)
        scopes.add(scope)
        val credential = try {
            credentialProvider.resolve(scope)
        } catch (exception: CredentialUnavailableException) {
            // The provider's text is not forwarded: it can carry the key or an
            // internal path. Only the class survives.
            return preflightDeny(GatewayFailure.credentialUnavailable(), scopes)
        }

        val sanitized = requestHeaders.sanitize(request.headers, url.host)
        val outbound = LinkedHashMap(sanitized.headers)
        credential.applyTo(outbound)
        val secrets = credential.secretValues()
        val credentialScope = if (credential.carriesSecret) url.credentialOriginScope else null
        val sensitive = sensitiveCalls.isSensitive(request.headers, credential, egress.admitsMcpGrant(url))

        var currentUrl = url
        var followed = 0
        var contacts = 0
        while (true) {
            contacts++
            val response = try {
                transport.execute(
                    GatewayTransportRequest(
                        method = method,
                        url = currentUrl.raw,
                        headers = LinkedHashMap(outbound),
                        body = request.body,
                    ),
                )
            } catch (exception: GatewayTransportException) {
                // The credential was resolved and the request was built, so
                // this is a sent failure, not a pre-flight deny; the transport
                // text is bounded into the reason instead of being echoed.
                return sentFailure(
                    failure = GatewayFailure.transportFailure(exception.message),
                    contactedUrl = currentUrl,
                    outbound = outbound,
                    stripped = sanitized.stripped,
                    droppedWorkerCredentials = sanitized.workerCredentialsDropped,
                    contacts = contacts,
                    scopes = scopes,
                    followed = followed,
                )
            }
            val location = headerValue(response.headers, LOCATION)
            if (response.status in REDIRECT_STATUSES && location != null) {
                val targetText = GatewayUrls.resolveLocation(currentUrl, location)
                val target = GatewayUrls.parse(targetText)
                if (target == null || !target.isHttp) {
                    return refusedRedirect(
                        response = response,
                        contactedUrl = currentUrl,
                        refusedUrl = targetText,
                        reason = RedirectReasons.TARGET_NOT_ALLOWED,
                        outbound = outbound,
                        sanitized = sanitized,
                        secrets = secrets,
                        sensitive = sensitive,
                        followed = followed,
                        contacts = contacts,
                        scopes = scopes,
                    )
                }
                when (val decision = redirects.authorize(target, credentialScope, egress)) {
                    is RedirectDecision.Refuse -> return refusedRedirect(
                        response = response,
                        contactedUrl = currentUrl,
                        refusedUrl = target.raw,
                        reason = decision.reason,
                        outbound = outbound,
                        sanitized = sanitized,
                        secrets = secrets,
                        sensitive = sensitive,
                        followed = followed,
                        contacts = contacts,
                        scopes = scopes,
                    )
                    RedirectDecision.Follow -> {
                        followed++
                        if (followed > maxRedirects) {
                            return sentFailure(
                                failure = GatewayFailure.redirectLimitExceeded(maxRedirects),
                                contactedUrl = currentUrl,
                                outbound = outbound,
                                stripped = sanitized.stripped,
                                droppedWorkerCredentials = sanitized.workerCredentialsDropped,
                                contacts = contacts,
                                scopes = scopes,
                            )
                        }
                        currentUrl = target
                    }
                }
            } else {
                return forwarded(
                    response = response,
                    contactedUrl = currentUrl,
                    method = method,
                    outbound = outbound,
                    sanitized = sanitized,
                    secrets = secrets,
                    sensitive = sensitive,
                    followed = followed,
                    contacts = contacts,
                    scopes = scopes,
                )
            }
        }
    }

    private fun forwarded(
        response: GatewayTransportResponse,
        contactedUrl: GatewayUrl,
        method: String,
        outbound: Map<String, String>,
        sanitized: SanitizedRequestHeaders,
        secrets: List<String>,
        sensitive: Boolean,
        followed: Int,
        contacts: Int,
        scopes: List<CredentialScope>,
    ): GatewayOutcome {
        val filtered = LinkedHashMap(responseHeaders.sanitize(response.headers, secrets))
        var body = response.body
        var withheld = false
        // HTTP semantics are not a sensitive-path special case: HEAD and
        // 1xx/204/205/304 never carry a body, and an empty body is not a
        // failure (gw-resp-006).
        if (redactor.statusForbidsBody(response.status, method)) {
            body = ByteArray(0)
        }
        val logOutcome: ResponseLogOutcome
        if (sensitive) {
            // MCP is a property of the call: every MCP response is redacted and
            // excluded from the log, whatever the credential kind.
            when {
                redactor.statusForbidsBody(response.status, method) -> {
                    body = ByteArray(0)
                }
                response.status !in 200..299 -> {
                    // The status is the diagnostic; no upstream byte survives.
                    body = redactor.controlledDiagnostic(response.status)
                    filtered["content-type"] = JSON_WITH_UTF8
                    withheld = true
                }
                body.size > redactor.maxBufferedBodyBytes -> {
                    body = redactor.controlledOversizeDiagnostic()
                    filtered["content-type"] = JSON_WITH_UTF8
                    withheld = true
                }
                else -> body = redactor.sanitizeBufferedBody(body, secrets)
            }
            logOutcome = ResponseLogOutcome(
                recorded = false,
                reason = ResponseLogReasons.SENSITIVE_CREDENTIAL,
                bodyBytes = body.size,
                retainedBytes = 0,
            )
        } else {
            logOutcome = responseLog.record(
                key = ResponseLog.cacheKey(method, contactedUrl.raw),
                status = response.status,
                headers = filtered,
                body = body,
            )
        }
        return GatewayOutcome(
            dispatch = GatewayDispatch.ALLOW,
            denyReason = null,
            failure = null,
            lastRequestHeaders = outbound,
            responseStatus = response.status,
            responseHeaders = filtered,
            responseBody = body,
            bodyWithheld = withheld,
            outboundUrl = contactedUrl.raw,
            finalUrl = contactedUrl.raw,
            redirectsFollowed = followed,
            upstreamContacts = contacts,
            stripped = sanitized.stripped,
            log = logOutcome,
            credentialScopes = scopes,
            workerCredentialsDropped = sanitized.workerCredentialsDropped,
        )
    }

    /**
     * A refused hop is never re-issued and receives no credential: the original
     * 3xx is handed back with the denial reason beside it, not an error
     * envelope (§4). A sensitive exchange still never forwards an upstream byte
     * that echoes an injected value.
     */
    private fun refusedRedirect(
        response: GatewayTransportResponse,
        contactedUrl: GatewayUrl,
        refusedUrl: String,
        reason: String,
        outbound: Map<String, String>,
        sanitized: SanitizedRequestHeaders,
        secrets: List<String>,
        sensitive: Boolean,
        followed: Int,
        contacts: Int,
        scopes: List<CredentialScope>,
    ): GatewayOutcome {
        val filtered = LinkedHashMap(responseHeaders.sanitize(response.headers, secrets))
        val body = if (sensitive) redactor.sanitizeBufferedBody(response.body, secrets) else response.body
        return GatewayOutcome(
            dispatch = GatewayDispatch.DENY,
            denyReason = reason,
            failure = null,
            lastRequestHeaders = outbound,
            responseStatus = response.status,
            responseHeaders = filtered,
            responseBody = body,
            bodyWithheld = false,
            outboundUrl = contactedUrl.raw,
            finalUrl = refusedUrl,
            redirectsFollowed = followed,
            upstreamContacts = contacts,
            stripped = sanitized.stripped,
            log = ResponseLogOutcome(
                recorded = false,
                reason = if (sensitive) ResponseLogReasons.SENSITIVE_CREDENTIAL else LOG_REASON_DENIED,
                bodyBytes = body.size,
                retainedBytes = 0,
            ),
            credentialScopes = scopes,
            workerCredentialsDropped = sanitized.workerCredentialsDropped,
        )
    }

    private fun sentFailure(
        failure: GatewayFailure,
        contactedUrl: GatewayUrl,
        outbound: Map<String, String>,
        stripped: List<String>,
        droppedWorkerCredentials: Int,
        contacts: Int,
        scopes: List<CredentialScope>,
        followed: Int = 0,
    ): GatewayOutcome = GatewayOutcome(
        dispatch = GatewayDispatch.DENY,
        denyReason = failure.code.wire,
        failure = failure.copy(upstreamContacts = contacts),
        lastRequestHeaders = outbound,
        responseStatus = null,
        responseHeaders = emptyMap(),
        responseBody = failure.envelopeJson().toByteArray(StandardCharsets.UTF_8),
        bodyWithheld = false,
        outboundUrl = contactedUrl.raw,
        finalUrl = contactedUrl.raw,
        redirectsFollowed = followed,
        upstreamContacts = contacts,
        stripped = stripped,
        log = null,
        credentialScopes = scopes,
        workerCredentialsDropped = droppedWorkerCredentials,
    )

    private fun preflightDeny(
        failure: GatewayFailure,
        scopes: List<CredentialScope> = emptyList(),
    ): GatewayOutcome = GatewayOutcome(
        dispatch = GatewayDispatch.DENY,
        denyReason = failure.code.wire,
        failure = failure,
        lastRequestHeaders = emptyMap(),
        responseStatus = null,
        responseHeaders = emptyMap(),
        responseBody = failure.envelopeJson().toByteArray(StandardCharsets.UTF_8),
        bodyWithheld = false,
        outboundUrl = "",
        finalUrl = "",
        redirectsFollowed = 0,
        upstreamContacts = 0,
        stripped = emptyList(),
        log = null,
        credentialScopes = scopes,
        workerCredentialsDropped = 0,
    )

    private fun headerValue(headers: Map<String, String>, name: String): String? {
        for ((key, value) in headers) {
            if (key.equals(name, ignoreCase = true)) return value
        }
        return null
    }

    companion object {
        const val DEFAULT_QUOTA_BYTES: Int = 128 * 1024 * 1024
        const val DEFAULT_MAX_REDIRECTS: Int = 10
        const val JSON_WITH_UTF8: String = "application/json; charset=utf-8"
        const val LOCATION: String = "location"
        const val LOG_REASON_DENIED: String = "denied"

        val REDIRECT_STATUSES: Set<Int> = setOf(301, 302, 303, 307, 308)
    }
}
