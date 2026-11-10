// phone-dsh — :net / com.phonedsh.gateway: the golden-vector runner.
// SPDX-License-Identifier: MIT
//
// This is the acceptance harness of the gateway lane: it reads
// spec/v1/golden/gateway/*.json, executes each vector against the real
// implementation through an injectable transport, and asserts `expect`. A
// vector is the defect when it disagrees with the prose spec, and it is the
// judge when it disagrees with the implementation, so nothing here may edit or
// reinterpret a vector.
//
// The transport is scripted: no vector needs a socket, and "no upstream
// contact" becomes an assertion over the requests the scripted transport saw.

package com.phonedsh.gateway

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

/** One JSON document from the gateway vector directory. */
data class GatewayVector(
    val id: String,
    val rule: String,
    val kind: String,
    val source: String,
    val note: String?,
    val input: JsonValue.Obj,
    val expect: JsonValue.Obj,
    /** File name inside the vector directory. */
    val path: String,
)

/** The verdict for one vector, with every mismatch in plain text. */
data class VectorResult(
    val id: String,
    val rule: String,
    val kind: String,
    val passed: Boolean,
    val mismatches: List<String>,
) {
    /** Throws with the full mismatch list; useful in tests and diagnostics. */
    fun requirePassed() {
        if (!passed) throw AssertionError("$id failed: ${mismatches.joinToString("; ")}")
    }

    override fun toString(): String =
        if (passed) "$id ok (${rule}, ${kind})"
        else "$id FAILED (${rule}, ${kind}): ${mismatches.joinToString("; ")}"
}

/** Test-only policy substitutions: each one removes one real rule. */
data class GatewayOverrides(
    val egress: EgressPolicy? = null,
    val requestHeaders: RequestHeaderSanitizer? = null,
    val redirects: RedirectAuthorizer? = null,
    val sensitiveCalls: SensitiveCallClassifier? = null,
    val redactor: CanonicalSensitiveBodyRedactor? = null,
    val responseHeaders: ResponseHeaderSanitizer? = null,
)

/** One scripted redirect hop: the origin answers with [status] + `Location`. */
data class ScriptedRedirect(val status: Int, val location: String)

/** Records every hop it was asked to send and replays a fixed script. */
class ScriptedTransport(
    private val redirects: List<ScriptedRedirect> = emptyList(),
    private val finalResponse: GatewayTransportResponse = GatewayTransportResponse(status = 200),
    /** When set, the transport throws this reason instead of answering (gw-fail-004). */
    private val failureReason: String? = null,
) : GatewayTransport {
    val requests: MutableList<GatewayTransportRequest> = ArrayList()

    override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
        requests.add(request)
        failureReason?.let { throw GatewayTransportException(it) }
        val index = requests.size - 1
        if (index < redirects.size) {
            val hop = redirects[index]
            return GatewayTransportResponse(
                status = hop.status,
                headers = linkedMapOf(GatewaySession.LOCATION to hop.location),
            )
        }
        return GatewayTransportResponse(
            status = finalResponse.status,
            headers = finalResponse.headers.toMap(),
            body = finalResponse.body.copyOf(),
        )
    }
}

/** Records the credential scopes the session asked about. */
class RecordingCredentialProvider(
    private val responder: (CredentialScope) -> GatewayCredential,
) : GatewayCredentialProvider {
    val scopes: MutableList<CredentialScope> = ArrayList()

    override fun resolve(scope: CredentialScope): GatewayCredential {
        scopes.add(scope)
        return responder(scope)
    }
}

/** A built session plus the instrumentation the invariants need. */
class GatewayHarness(
    val vector: GatewayVector,
    val session: GatewaySession,
    val transport: ScriptedTransport,
    val credentials: RecordingCredentialProvider,
) {
    val outcome: GatewayOutcome by lazy {
        val method = vector.input.string("method") ?: ""
        val url = vector.input.string("url") ?: ""
        val headers = vector.input.stringMap("headers") ?: emptyMap()
        session.exchange(GatewayRequest(method = method, url = url, headers = headers))
    }

    fun result(): VectorResult {
        val mismatches = ArrayList<String>()
        val actual = actualValues()
        GatewayVectorRunner.checkExpectations(vector, actual, mismatches)
        GatewayVectorRunner.checkInvariants(this, mismatches)
        return VectorResult(
            id = vector.id,
            rule = vector.rule,
            kind = vector.kind,
            passed = mismatches.isEmpty(),
            mismatches = mismatches,
        )
    }

    fun actualValues(): Map<String, JsonValue> {
        val outcome = this.outcome
        val values = LinkedHashMap<String, JsonValue>()
        values["dispatch"] = JsonValue.Str(outcome.dispatch.wire)
        // `outbound_headers` is the request map for request/redirect-chain
        // vectors and the response map handed to the Worker for response ones.
        val headerMap =
            if (vector.kind == KIND_RESPONSE) outcome.responseHeaders else outcome.lastRequestHeaders
        values["outbound_headers"] = JsonValue.objOfStrings(headerMap)
        values["stripped"] = JsonValue.Arr(outcome.stripped.map { JsonValue.Str(it) })
        values["outbound_url"] = JsonValue.Str(outcome.outboundUrl)
        values["final_url"] = JsonValue.Str(outcome.finalUrl)
        values["redirects_followed"] = JsonValue.num(outcome.redirectsFollowed)
        // The status handed to the Worker: on a refused redirect this is the
        // refused hop's own 3xx, not a failure status.
        outcome.responseStatus?.let { values["status"] = JsonValue.num(it) }
        values["response_headers"] = JsonValue.objOfStrings(outcome.responseHeaders)
        values["upstream_contacts"] = JsonValue.num(outcome.upstreamContacts)
        if (outcome.denyReason != null) values["deny_reason"] = JsonValue.Str(outcome.denyReason)
        GatewayJson.decodeUtf8(outcome.responseBody)?.let { values["body"] = JsonValue.Str(it) }
        GatewayJson.parseOrNull(outcome.responseBody)?.let { values["body_json"] = it }
        values["body_bytes"] = JsonValue.num(outcome.responseBody.size)
        values["body_sha256"] = JsonValue.Str(GatewayJson.sha256Hex(outcome.responseBody))
        values["body_withheld"] = JsonValue.bool(outcome.bodyWithheld)
        outcome.log?.let { log ->
            values["log"] = JsonValue.Obj(log.fields().map { JsonValue.Member(it.key, it.value) })
        }
        outcome.failure?.let { failure ->
            values["failure"] =
                JsonValue.Obj(failure.fields().map { JsonValue.Member(it.key, it.value) })
        }
        return values
    }

    companion object {
        const val KIND_RESPONSE: String = "response"
    }
}

object GatewayVectorRunner {
    const val VECTOR_DIRECTORY: String = "spec/v1/golden/gateway"
    const val EXPECTED_VECTOR_COUNT: Int = 31
    const val KIND_REQUEST: String = "request"
    const val KIND_RESPONSE: String = "response"
    const val KIND_REDIRECT_CHAIN: String = "redirect-chain"

    /** The caller-supplied credential value no vector may leak. */
    const val CALLER_SENTINEL: String = "sk-SENTINEL-DO-NOT-USE"

    /** Prefix of the scripted provider failure; it must never reach a caller. */
    const val PROVIDER_ERROR_MARKER: String = "provider-vault-unavailable"

    val RULE_CLASSES: List<String> = listOf(
        "credential-injection",
        "header-strip",
        "redirect-scope",
        "egress-classification",
        "response-redaction",
        "failure-surface",
    )

    val EXPECTED_VECTOR_IDS: Set<String> = linkedSetOf(
        "gw-cred-001", "gw-cred-002", "gw-cred-003",
        "gw-hop-001", "gw-hop-002", "gw-hop-003", "gw-hop-004",
        "gw-redir-001", "gw-redir-002", "gw-redir-003",
        "gw-redir-004", "gw-redir-005", "gw-redir-006",
        "gw-redir-007", "gw-redir-008",
        "gw-egress-001", "gw-egress-002", "gw-egress-003",
        "gw-egress-004", "gw-egress-005",
        "gw-resp-001", "gw-resp-002", "gw-resp-003",
        "gw-resp-004", "gw-resp-005", "gw-resp-006",
        "gw-fail-001", "gw-fail-002", "gw-fail-003", "gw-fail-004",
        "gw-log-001",
    )

    /** Every expect key this runner knows how to judge. */
    private val SUPPORTED_EXPECT_KEYS: Set<String> = setOf(
        "dispatch", "outbound_headers", "stripped", "outbound_url", "final_url",
        "redirects_followed", "deny_reason", "body", "body_json", "body_bytes",
        "body_sha256", "body_withheld", "log", "failure",
        "status", "response_headers", "upstream_contacts",
    )

    /** Walks up from [start] until the vector directory is found. */
    fun findRepositoryRoot(start: Path = Path.of("").toAbsolutePath()): Path {
        val override = System.getProperty("pdsh.specRoot")
        if (!override.isNullOrBlank()) return Path.of(override).toAbsolutePath().normalize()
        var directory: Path? = start.toAbsolutePath().normalize()
        while (directory != null) {
            if (Files.isDirectory(directory.resolve(VECTOR_DIRECTORY))) return directory
            directory = directory.parent
        }
        throw IllegalStateException("cannot find $VECTOR_DIRECTORY in any parent of $start")
    }

    fun loadVectors(root: Path = findRepositoryRoot()): List<GatewayVector> {
        val directory = root.resolve(VECTOR_DIRECTORY)
        val paths = Files.list(directory).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".json") }.sorted().toList()
        }
        return paths.map { path ->
            val document = GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8))
            val objectDocument = document as? JsonValue.Obj
                ?: throw IllegalStateException("$path: a vector must be a JSON object")
            GatewayVector(
                id = objectDocument.string("id")
                    ?: throw IllegalStateException("$path: missing id"),
                rule = objectDocument.string("rule")
                    ?: throw IllegalStateException("$path: missing rule"),
                kind = objectDocument.string("kind")
                    ?: throw IllegalStateException("$path: missing kind"),
                source = objectDocument.string("source")
                    ?: throw IllegalStateException("$path: missing source"),
                note = objectDocument.string("note"),
                input = objectDocument.obj("input")
                    ?: throw IllegalStateException("$path: missing input"),
                expect = objectDocument.obj("expect")
                    ?: throw IllegalStateException("$path: missing expect"),
                path = directory.relativize(path).toString(),
            )
        }.sortedBy { it.id }
    }

    fun vectorById(id: String, root: Path = findRepositoryRoot()): GatewayVector =
        loadVectors(root).firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("no vector with id $id under $root")

    /**
     * Builds the real implementation for one vector. [overrides] replaces a
     * real rule with a deliberately broken one; production never passes any.
     */
    fun harness(vector: GatewayVector, overrides: GatewayOverrides = GatewayOverrides()): GatewayHarness {
        val urlText = vector.input.string("url")
            ?: throw IllegalStateException("${vector.id}: missing input.url")
        val rules = parseAllowList(vector)
        val parsedUrl = GatewayUrls.parse(urlText)
        val grant = if (vector.input.bool("mcp") == true && parsedUrl != null) {
            CredentialOriginScope.of(parsedUrl)
        } else {
            null
        }
        val egress = overrides.egress ?: AllowListEgressPolicy(rules, grant)
        val credentialSpec = vector.input.obj("credential")
            ?: throw IllegalStateException("${vector.id}: missing input.credential")
        val credentials = RecordingCredentialProvider { credentialFor(vector.id, credentialSpec) }
        val redirects = (vector.input.array("redirects") ?: emptyList()).map { entry ->
            val hop = entry as? JsonValue.Obj
                ?: throw IllegalStateException("${vector.id}: a redirect hop must be an object")
            ScriptedRedirect(
                status = hop.int("status")
                    ?: throw IllegalStateException("${vector.id}: redirect hop needs status"),
                location = hop.string("location")
                    ?: throw IllegalStateException("${vector.id}: redirect hop needs location"),
            )
        }
        val transport = ScriptedTransport(
            redirects = redirects,
            finalResponse = responseFor(vector),
            failureReason = vector.input.string("transport_failure"),
        )
        val session = GatewaySession(
            transport = transport,
            credentialProvider = credentials,
            egress = egress,
            quotaBytes = vector.input.int("quota_bytes") ?: GatewaySession.DEFAULT_QUOTA_BYTES,
            requestHeaders = overrides.requestHeaders ?: DenylistRequestHeaderSanitizer(),
            redirects = overrides.redirects ?: ScopePinningRedirectAuthorizer(),
            sensitiveCalls = overrides.sensitiveCalls ?: McpCallClassifier(),
            redactor = overrides.redactor ?: CanonicalSensitiveBodyRedactor(),
            responseHeaders = overrides.responseHeaders ?: DenylistResponseHeaderSanitizer(),
        )
        return GatewayHarness(vector, session, transport, credentials)
    }

    fun run(vector: GatewayVector, overrides: GatewayOverrides = GatewayOverrides()): VectorResult =
        harness(vector, overrides).result()

    fun runAll(
        root: Path = findRepositoryRoot(),
        overrides: GatewayOverrides = GatewayOverrides(),
    ): List<VectorResult> = loadVectors(root).map { run(it, overrides) }

    // ------------------------------------------------------------------ script

    private fun parseAllowList(vector: GatewayVector): List<GatewayHostRule> {
        val entries = vector.input.array("allowlist") ?: emptyList()
        return entries.mapIndexed { index, entry ->
            val text = (entry as? JsonValue.Str)?.value
                ?: throw IllegalStateException("${vector.id}: allowlist[$index] must be a string")
            if (text.isBlank()) {
                throw IllegalStateException("${vector.id}: allowlist[$index] is blank")
            }
            GatewayHostRule.parse(text)
                ?: throw IllegalStateException("${vector.id}: allowlist[$index] '$text' does not parse")
        }
    }

    private fun credentialFor(id: String, spec: JsonValue.Obj): GatewayCredential =
        when (val kind = spec.string("kind")) {
            "none" -> GatewayCredential.None
            "unavailable" -> throw CredentialUnavailableException("$PROVIDER_ERROR_MARKER: $id")
            "bearer" -> GatewayCredential.Bearer(
                spec.string("value") ?: throw IllegalStateException("$id: bearer needs a value"),
            )
            "api-key" -> GatewayCredential.ApiKey(
                header = spec.string("header")
                    ?: throw IllegalStateException("$id: api-key needs a header"),
                value = spec.string("value")
                    ?: throw IllegalStateException("$id: api-key needs a value"),
            )
            "headers" -> GatewayCredential.Headers(
                spec.stringMap("headers")
                    ?: throw IllegalStateException("$id: headers needs a string map"),
            )
            else -> throw IllegalStateException("$id: unknown credential kind $kind")
        }

    private fun responseFor(vector: GatewayVector): GatewayTransportResponse {
        val response = vector.input.obj("response") ?: return GatewayTransportResponse(status = 200)
        val status = response.int("status")
            ?: throw IllegalStateException("${vector.id}: input.response needs a status")
        val headers = (response.stringMap("headers") ?: emptyMap())
            .mapKeys { it.key.lowercase() }
        val body = response.string("body")?.toByteArray(StandardCharsets.UTF_8)
            ?: response.int("body_bytes")?.let { size -> ByteArray(size) { 'x'.code.toByte() } }
            ?: ByteArray(0)
        return GatewayTransportResponse(status = status, headers = headers, body = body)
    }

    // ------------------------------------------------------------- expectations

    fun checkExpectations(
        vector: GatewayVector,
        actual: Map<String, JsonValue>,
        mismatches: MutableList<String>,
    ) {
        for (member in vector.expect.members) {
            if (member.name !in SUPPORTED_EXPECT_KEYS) {
                mismatches.add("expect.${member.name}: the runner cannot judge this key")
                continue
            }
            val actualValue = actual[member.name]
            if (actualValue == null) {
                mismatches.add("expect.${member.name}: the outcome produced no such value")
                continue
            }
            when (member.name) {
                "outbound_headers" -> compareExactObject(
                    path = "expect.outbound_headers",
                    expected = member.value as? JsonValue.Obj
                        ?: throw IllegalStateException("${vector.id}: outbound_headers must be an object"),
                    actual = actualValue as? JsonValue.Obj
                        ?: throw IllegalStateException("${vector.id}: actual outbound_headers must be an object"),
                    mismatches = mismatches,
                )
                "log", "failure", "response_headers" -> compareSubset(
                    path = "expect.${member.name}",
                    expected = member.value,
                    actual = actualValue,
                    mismatches = mismatches,
                )
                "body_json" -> if (!GatewayJson.structuralEquals(member.value, actualValue)) {
                    mismatches.add(
                        "expect.body_json: expected ${render(member.value)} but was ${render(actualValue)}",
                    )
                }
                else -> if (member.value != actualValue) {
                    mismatches.add(
                        "expect.${member.name}: expected ${render(member.value)} but was ${render(actualValue)}",
                    )
                }
            }
        }
    }

    private fun compareExactObject(
        path: String,
        expected: JsonValue.Obj,
        actual: JsonValue.Obj,
        mismatches: MutableList<String>,
    ) {
        val expectedNames = expected.members.map { it.name }.toSet()
        val actualNames = actual.members.map { it.name }.toSet()
        val missing = expectedNames - actualNames
        val unexpected = actualNames - expectedNames
        if (missing.isNotEmpty()) mismatches.add("$path: missing ${missing.sorted()}")
        if (unexpected.isNotEmpty()) mismatches.add("$path: unexpected ${unexpected.sorted()}")
        for (name in expectedNames.intersect(actualNames)) {
            val want = expected.get(name)
            val got = actual.get(name)
            if (want != got) {
                mismatches.add("$path.$name: expected ${render(want)} but was ${render(got)}")
            }
        }
    }

    private fun compareSubset(
        path: String,
        expected: JsonValue,
        actual: JsonValue,
        mismatches: MutableList<String>,
    ) {
        if (expected is JsonValue.Obj && actual is JsonValue.Obj) {
            for (member in expected.members) {
                val actualMember = actual.get(member.name)
                if (actualMember == null) {
                    mismatches.add("$path.${member.name}: the outcome has no such member")
                } else {
                    compareSubset("$path.${member.name}", member.value, actualMember, mismatches)
                }
            }
            return
        }
        if (expected != actual) {
            mismatches.add("$path: expected ${render(expected)} but was ${render(actual)}")
        }
    }

    private fun render(value: JsonValue?): String {
        if (value == null) return "<absent>"
        val text = GatewayJson.canonicalText(value)
        return if (text.length <= 300) text else text.substring(0, 300) + "…"
    }

    // --------------------------------------------------------------- invariants

    /**
     * Rules the vectors imply but do not always spell out. They are checked for
     * every vector so a future vector cannot pass by omission.
     */
    fun checkInvariants(harness: GatewayHarness, mismatches: MutableList<String>) {
        val vector = harness.vector
        val outcome = harness.outcome
        val placeholder = GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER

        // Empty bodies are not failures: HEAD and 1xx/204/205/304 never carry
        // one, and the suppression must not masquerade as a withheld body.
        val responseStatus = vector.input.obj("response")?.int("status")
        val forbidsBody = vector.kind == KIND_RESPONSE && (
            vector.input.string("method")?.equals("HEAD", ignoreCase = true) == true ||
                (
                    responseStatus != null &&
                        (responseStatus in 100..199 ||
                            responseStatus == 204 || responseStatus == 205 || responseStatus == 304)
                    )
            )
        if (forbidsBody) {
            if (outcome.responseBody.isNotEmpty()) {
                mismatches.add("invariant: a body-forbidden response forwarded bytes")
            }
            if (outcome.bodyWithheld) {
                mismatches.add("invariant: an empty response is not a withheld body")
            }
        }

        vector.input.string("transport_failure")?.let { raw ->
            val failure = outcome.failure
            if (failure?.code != GatewayFailureCode.TRANSPORT_FAILURE) {
                mismatches.add(
                    "invariant: input.transport_failure must surface transport_failure",
                )
            } else {
                val reason = failure.reasonText()
                if (reason.contains('\n') || reason.contains('\r')) {
                    mismatches.add("invariant: a transport reason must be newline-free")
                }
                if (reason.length > GatewayFailure.MAX_REASON_LENGTH) {
                    mismatches.add("invariant: a transport reason exceeds 256 characters")
                }
                val expected = GatewayFailure.boundedReason(
                    GatewayFailure.TRANSPORT_REASON_PREFIX + GatewayFailure.boundedReason(raw),
                )
                if (reason != expected) {
                    mismatches.add(
                        "invariant: transport reason is not the bounded scripted cause",
                    )
                }
            }
        }

        val lastHeaderText = outcome.lastRequestHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" }
        if (lastHeaderText.contains(CALLER_SENTINEL)) {
            mismatches.add("invariant: the caller credential reached the outbound request")
        }
        if (lastHeaderText.contains(placeholder)) {
            mismatches.add("invariant: the Worker placeholder reached the outbound request")
        }
        val responseHeaderText = outcome.responseHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" }
        if (responseHeaderText.contains(CALLER_SENTINEL)) {
            mismatches.add("invariant: the caller credential reached the response headers")
        }
        val bodyText = GatewayJson.decodeUtf8(outcome.responseBody).orEmpty()
        if (bodyText.contains(CALLER_SENTINEL)) {
            mismatches.add("invariant: the caller credential reached the response body")
        }

        for (name in outcome.stripped) {
            if (outcome.lastRequestHeaders.keys.any { it.equals(name, ignoreCase = true) }) {
                mismatches.add("invariant: stripped header '$name' is still in the outbound request")
            }
        }

        val preflight = outcome.outboundUrl.isEmpty()
        val unavailableCredential = vector.input.obj("credential")?.string("kind") == "unavailable"
        if (preflight) {
            if (outcome.upstreamContacts != 0) {
                mismatches.add("invariant: a pre-flight deny contacted the upstream")
            }
            if (outcome.lastRequestHeaders.isNotEmpty()) {
                mismatches.add("invariant: a pre-flight deny built request headers")
            }
            if (harness.transport.requests.isNotEmpty()) {
                mismatches.add("invariant: a pre-flight deny sent a request")
            }
            // Only credential_unavailable reaches the provider: it is the
            // lookup that failed, and nothing was contacted.
            val expectedLookups = if (unavailableCredential) 1 else 0
            if (harness.credentials.scopes.size != expectedLookups) {
                mismatches.add(
                    "invariant: expected $expectedLookups credential lookup(s) before the deny, " +
                        "saw ${harness.credentials.scopes.size}",
                )
            } else if (expectedLookups == 1) {
                val expectedScope = vector.input.string("url")?.let(GatewayUrls::parse)
                    ?.let(CredentialScope::of)
                if (expectedScope != null && harness.credentials.scopes[0] != expectedScope) {
                    mismatches.add(
                        "invariant: credential scope ${harness.credentials.scopes[0]} != $expectedScope",
                    )
                }
            }
        } else {
            val requestUrl = vector.input.string("url")?.let(GatewayUrls::parse)
            val expectedScope = requestUrl?.let(CredentialScope::of)
            if (harness.credentials.scopes.size != 1) {
                mismatches.add(
                    "invariant: expected one credential lookup, saw ${harness.credentials.scopes.size}",
                )
            } else if (expectedScope != null && harness.credentials.scopes[0] != expectedScope) {
                mismatches.add(
                    "invariant: credential scope ${harness.credentials.scopes[0]} != $expectedScope",
                )
            }
            if (outcome.upstreamContacts != harness.transport.requests.size) {
                mismatches.add(
                    "invariant: ${outcome.upstreamContacts} contact(s) reported, " +
                        "${harness.transport.requests.size} sent",
                )
            }
        }

        outcome.failure?.let { failure ->
            if (failure.code.wire != outcome.denyReason) {
                mismatches.add("invariant: failure.code '${failure.code.wire}' != deny_reason '${outcome.denyReason}'")
            }
            val envelope = failure.envelopeJson()
            if (envelope.contains(CALLER_SENTINEL) || envelope.contains(placeholder)) {
                mismatches.add("invariant: the failure envelope carries a credential value")
            }
            if (envelope.contains(PROVIDER_ERROR_MARKER)) {
                mismatches.add("invariant: the failure envelope forwards the provider error text")
            }
        }

        val workerCredentialSent = vector.input.stringMap("headers")?.keys
            ?.any { it.lowercase() in GatewayRequestHeaders.WORKER_CREDENTIAL_HEADERS } == true
        if (workerCredentialSent && outcome.dispatch == GatewayDispatch.ALLOW &&
            outcome.workerCredentialsDropped != 1
        ) {
            mismatches.add("invariant: the dropped Worker credential was not counted")
        }

        val redirects = vector.input.array("redirects") ?: emptyList()
        if (redirects.isNotEmpty()) {
            val locations = redirects.map { (it as JsonValue.Obj).string("location") }
            val requestUrl = vector.input.string("url").orEmpty()
            if (outcome.dispatch == GatewayDispatch.ALLOW) {
                if (outcome.redirectsFollowed != redirects.size) {
                    mismatches.add(
                        "invariant: an allowed chain must follow every hop " +
                            "(${outcome.redirectsFollowed}/${redirects.size})",
                    )
                }
                val last = locations.lastOrNull()
                if (outcome.outboundUrl != last) {
                    mismatches.add("invariant: outbound_url must be the last followed URL")
                }
            } else {
                if (outcome.redirectsFollowed >= redirects.size) {
                    mismatches.add("invariant: a denied chain must refuse a hop before the end")
                } else {
                    val refused = locations[outcome.redirectsFollowed]
                    if (outcome.finalUrl != refused) {
                        mismatches.add("invariant: final_url must be the refused target")
                    }
                    val lastSent =
                        if (outcome.redirectsFollowed == 0) requestUrl
                        else locations[outcome.redirectsFollowed - 1]
                    if (outcome.outboundUrl != lastSent) {
                        mismatches.add("invariant: outbound_url must be the last contacted URL")
                    }
                }
                if (outcome.failure != null) {
                    mismatches.add("invariant: a refused redirect returns the 3xx, not an error envelope")
                }
            }
        }

        // A sensitive call may never hand an injected value to the Worker.
        val credentialSpec = vector.input.obj("credential")
        val sensitive = vector.input.bool("mcp") == true ||
            credentialSpec?.string("kind") == "headers"
        if (sensitive && credentialSpec != null) {
            val secrets = credentialFor(vector.id, credentialSpec).secretValues()
            val leakedHeader = outcome.responseHeaders.entries.any { entry ->
                secrets.any { it.isNotEmpty() && entry.value.contains(it) }
            }
            if (leakedHeader) {
                mismatches.add("invariant: a response header still carries an injected credential")
            }
            if (secrets.any { it.isNotEmpty() && bodyText.contains(it) }) {
                mismatches.add("invariant: the response body still carries an injected credential")
            }
        }
    }
}
