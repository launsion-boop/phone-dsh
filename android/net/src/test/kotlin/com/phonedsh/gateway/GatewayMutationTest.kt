// phone-dsh — :net tests: mutation checks for the six gateway rules.
// SPDX-License-Identifier: MIT
//
// A conformance suite that passes says nothing about its own teeth. Each case
// here keeps the real implementation, replaces exactly one rule with a
// deliberately wrong one, and proves the named golden vector fails for the
// reason the rule exists. The baseline run first makes the mutation, not the
// environment, the cause of the failure.

package com.phonedsh.gateway

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class GatewayMutationTest {

    @Test
    fun removingSortedKeyEncodingBreaksThePinnedBodyBytes() {
        assertBaselinePasses("gw-resp-005")
        val mutated = run(
            "gw-resp-005",
            GatewayOverrides(
                redactor = CanonicalSensitiveBodyRedactor(InsertionOrderCanonicalizer),
            ),
        )
        assertFailed(mutated)
        assertMentions(mutated, "body_sha256")
    }

    @Test
    fun lettingACredentialFollowAnyAllowListedRedirectBreaksScopePinning() {
        assertBaselinePasses("gw-redir-003")
        assertBaselinePasses("gw-redir-004")
        val samePath = run("gw-redir-003", GatewayOverrides(redirects = AllowListOnlyRedirectAuthorizer))
        assertFailed(samePath)
        assertMentions(samePath, "dispatch")
        val crossHost = run("gw-redir-004", GatewayOverrides(redirects = AllowListOnlyRedirectAuthorizer))
        assertFailed(crossHost)
        assertMentions(crossHost, "dispatch")
    }

    @Test
    fun forwardingTheCallerHeadersBreaksHeaderStripping() {
        assertBaselinePasses("gw-hop-001")
        val mutated = run("gw-hop-001", GatewayOverrides(requestHeaders = PassthroughRequestHeaderSanitizer))
        assertFailed(mutated)
        assertMentions(mutated, "outbound_headers")
    }

    @Test
    fun removingTheDefaultDenyBreaksEgressClassification() {
        assertBaselinePasses("gw-egress-002")
        val mutated = run("gw-egress-002", GatewayOverrides(egress = PermissiveEgressPolicy))
        assertFailed(mutated)
        assertMentions(mutated, "dispatch")
    }

    @Test
    fun decidingSensitivityByCredentialKindBreaksTheScalarMcpLog() {
        assertBaselinePasses("gw-resp-004")
        val mutated = run(
            "gw-resp-004",
            GatewayOverrides(sensitiveCalls = HeadersMapOnlyClassifier),
        )
        assertFailed(mutated)
        assertMentions(mutated, "expect.log")
    }

    @Test
    fun skippingCacheControlNoStoreBreaksTheResponseHeaderMap() {
        assertBaselinePasses("gw-resp-003")
        val mutated = run(
            "gw-resp-003",
            GatewayOverrides(responseHeaders = NoCacheControlResponseHeaderSanitizer()),
        )
        assertFailed(mutated)
        assertMentions(mutated, "outbound_headers")
    }

    // --------------------------------------------------------------- helpers

    private fun run(id: String, overrides: GatewayOverrides): VectorResult =
        GatewayVectorRunner.run(GatewayVectorRunner.vectorById(id), overrides)

    private fun assertBaselinePasses(id: String) {
        val baseline = GatewayVectorRunner.run(GatewayVectorRunner.vectorById(id))
        assertTrue("the unmutated $id must pass first: $baseline", baseline.passed)
    }

    private fun assertFailed(result: VectorResult) {
        assertFalse("the mutation must make ${result.id} fail, but it passed", result.passed)
    }

    private fun assertMentions(result: VectorResult, needle: String) {
        assertTrue(
            "${result.id} failed, but no mismatch names '$needle': ${result.mismatches}",
            result.mismatches.any { it.contains(needle) },
        )
    }

    /** Encodes object members in input order — what the vectors must catch. */
    private object InsertionOrderCanonicalizer : JsonCanonicalizer {
        override fun encode(value: JsonValue): ByteArray =
            build(value).toByteArray(StandardCharsets.UTF_8)

        private fun build(value: JsonValue): String = when (value) {
            JsonValue.Null -> "null"
            is JsonValue.Bool -> if (value.value) "true" else "false"
            is JsonValue.Num -> value.literal
            is JsonValue.Str -> "\"" + value.value + "\""
            is JsonValue.Arr -> value.items.joinToString(",", "[", "]") { build(it) }
            is JsonValue.Obj -> value.members.joinToString(",", "{", "}") {
                "\"" + it.name + "\":" + build(it.value)
            }
        }
    }

    /** Follows any allow-listed hop: the credential travels out of scope. */
    private object AllowListOnlyRedirectAuthorizer : RedirectAuthorizer {
        override fun authorize(
            target: GatewayUrl,
            credentialScope: CredentialOriginScope?,
            egress: EgressPolicy,
        ): RedirectDecision =
            if (target.isHttp && egress.permits(target)) {
                RedirectDecision.Follow
            } else {
                RedirectDecision.Refuse(RedirectReasons.TARGET_NOT_ALLOWED)
            }
    }

    /** Copies every caller header and strips nothing. */
    private object PassthroughRequestHeaderSanitizer : RequestHeaderSanitizer {
        override fun sanitize(callerHeaders: Map<String, String>, targetHost: String?): SanitizedRequestHeaders =
            SanitizedRequestHeaders(
                headers = callerHeaders.mapKeys { it.key.lowercase() },
                stripped = emptyList(),
                workerCredentialsDropped = 0,
                placeholderSeen = false,
            )
    }

    /** Admits every host, loopback and private literals included. */
    private object PermissiveEgressPolicy : EgressPolicy {
        override fun permits(url: GatewayUrl): Boolean = true

        override fun admitsMcpGrant(url: GatewayUrl): Boolean = false
    }

    /** The pre-fix rule: only a header-map credential is sensitive. */
    private object HeadersMapOnlyClassifier : SensitiveCallClassifier {
        override fun isSensitive(
            workerHeaders: Map<String, String>,
            credential: GatewayCredential,
            mcpAdmitted: Boolean,
        ): Boolean = credential is GatewayCredential.Headers && credential.headers.isNotEmpty()
    }

    /** Forwards response headers but never sets `cache-control: no-store`. */
    private class NoCacheControlResponseHeaderSanitizer : ResponseHeaderSanitizer {
        private val delegate = DenylistResponseHeaderSanitizer()

        override fun sanitize(
            upstreamHeaders: Map<String, String>,
            secrets: List<String>,
        ): Map<String, String> = delegate.sanitize(upstreamHeaders, secrets) - "cache-control"
    }
}
