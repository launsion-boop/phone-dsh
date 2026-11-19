// SPDX-License-Identifier: MIT
//
// Shared fixture loader and fakes for the GitHub connector tests. The fixture
// is spec/v1/golden/github-oauth/github-oauth-cases.json, read from disk
// through `pdsh.repo.root` as the other :net golden tests do.

package com.phonedsh.connectors.github

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

object GitHubFixture {
    private val root: JsonValue.Obj by lazy {
        val repo = System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; the :net test task supplies it")
        val file = File(repo, "spec/v1/golden/github-oauth/github-oauth-cases.json")
        GatewayJson.parse(file.readText()) as JsonValue.Obj
    }

    private fun string(name: String): String = root.string(name) ?: error("fixture has no $name")

    val state: String get() = string("state")
    val wrongState: String get() = string("wrong_state")
    val code: String get() = string("code")
    val codeVerifier: String get() = string("code_verifier")
    val accessToken: String get() = string("access_token")
    val expiresIn: Int get() = root.int("expires_in") ?: error("fixture has no expires_in")
    val invalidVerifier: String get() = string("invalid_verifier")
    val invalidToken: String get() = string("invalid_token")
}

class FakeTransport(
    private val handler: suspend (ConnectorHttpRequest) -> ConnectorHttpResponse,
) : GitHubHttpTransport {
    val requests = mutableListOf<ConnectorHttpRequest>()

    override suspend fun send(request: ConnectorHttpRequest): ConnectorHttpResponse {
        requests += request
        return handler(request)
    }
}

fun response(status: Int, body: String = "", headers: Map<String, String> = emptyMap()) =
    ConnectorHttpResponse(status, headers, body.toByteArray(Charsets.UTF_8))

fun testConfiguration(): GitHubOAuthConfiguration =
    GitHubOAuthConfiguration.create("https://broker.example.com", "Iv1.client", "phone-dsh-app")!!

/** Query parameters of [url], percent-decoded (test-side helper only). */
fun queryOf(url: String): Map<String, String> {
    val query = url.substringAfter('?', "")
    if (query.isEmpty()) return emptyMap()
    return query.split('&').associate {
        val (name, value) = it.split('=', limit = 2)
        java.net.URLDecoder.decode(name, "UTF-8") to java.net.URLDecoder.decode(value, "UTF-8")
    }
}

/**
 * Runs [block] on runBlocking's single-threaded event loop with a supervisor
 * scope for the model; leftover coroutines are cancelled at the end.
 */
fun singleThreadTest(block: suspend (CoroutineScope) -> Unit) = runBlocking {
    val job = SupervisorJob()
    val scope = CoroutineScope(coroutineContext + job)
    try {
        block(scope)
    } finally {
        job.cancel()
    }
}

/** Lets every queued coroutine on the event loop run to its next real suspension. */
suspend fun settle() {
    repeat(200) { yield() }
}
