// SPDX-License-Identifier: MIT
//
// GitHub REST reads on Android: request shape, paging, repository link check
// and error mapping. iOS baseline: ProbeKit/GitHubConnectorAPI.swift.

package com.phonedsh.connectors.github

import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GitHubConnectorApiTest {
    private val token = GitHubFixture.accessToken

    private fun repoJson(id: Long, fullName: String, url: String = "https://github.com/$fullName") =
        """{"id":$id,"name":"${fullName.substringAfter('/')}","full_name":"$fullName","html_url":"$url","private":true}"""

    @Test
    fun accountSendsVersionedBearerRequest() = runBlocking {
        val transport = FakeTransport { response(200, """{"login":"octocat","id":1}""") }
        assertEquals(GitHubAccount("octocat"), GitHubConnectorApi(transport).account(token))
        val request = transport.requests.single()
        assertEquals("GET", request.method)
        assertEquals("https://api.github.com/user", request.url)
        assertNull(request.body)
        assertEquals("Bearer $token", request.headers["Authorization"])
        assertEquals("application/vnd.github+json", request.headers["Accept"])
        assertEquals("2022-11-28", request.headers["X-GitHub-Api-Version"])
        assertEquals("phone-dsh", request.headers["User-Agent"])

        for (body in listOf("""{"login":""}""", """{"id":1}""", "[]", "nope")) {
            expectConnector(GitHubConnectorError.INVALID_RESPONSE) {
                GitHubConnectorApi(FakeTransport { response(200, body) }).account(token)
            }
        }
    }

    @Test
    fun repositoriesPageAndNextRelation() = runBlocking {
        val link = """<https://api.github.com/user/repos?page=3>; rel="next", <https://api.github.com/user/repos?page=9>; rel="last""""
        val transport = FakeTransport {
            response(200, "[${repoJson(1, "octo/one")},${repoJson(2, "octo/two", "https://github.com/octo/two/")}]", mapOf("link" to link))
        }
        val page = GitHubConnectorApi(transport).repositories(2, token)
        assertEquals("https://api.github.com/user/repos?per_page=30&sort=updated&page=2", transport.requests.single().url)
        assertEquals(listOf(1L, 2L), page.repositories.map { it.id })
        assertEquals(GitHubRepository(1, "one", "octo/one", "https://github.com/octo/one"), page.repositories[0])
        assertEquals(3, page.nextPage)

        val last = GitHubConnectorApi(FakeTransport { response(200, "[]") }).repositories(token = token)
        assertTrue(last.repositories.isEmpty())
        assertNull(last.nextPage)

        expectConnector(GitHubConnectorError.INVALID_RESPONSE) {
            GitHubConnectorApi(FakeTransport { error("must not send") }).repositories(0, token)
        }
    }

    @Test
    fun linkRelationParsing() {
        assertTrue(GitHubConnectorApi.hasNextPage("""<x>; rel="next""""))
        assertTrue(GitHubConnectorApi.hasNextPage("""<x>; REL = "prev NEXT""""))
        assertTrue(GitHubConnectorApi.hasNextPage("""<a>; rel="last", <x>;rel=next"""))
        assertFalse(GitHubConnectorApi.hasNextPage(null))
        assertFalse(GitHubConnectorApi.hasNextPage(""))
        assertFalse(GitHubConnectorApi.hasNextPage("""<x>; rel="prev", <y>; rel="last""""))
        assertFalse(GitHubConnectorApi.hasNextPage("""<x?rel=next>"""))
        assertFalse(GitHubConnectorApi.hasNextPage("""<x>; title="next""""))
    }

    @Test
    fun badRepositoryUrlIsInvalidResponse() = runBlocking {
        val bad = listOf(
            "http://github.com/octo/one",
            "https://www.github.com/octo/one",
            "https://github.com:443/octo/one",
            "https://user@github.com/octo/one",
            "https://github.com/octo/one?x=1",
            "https://github.com/octo/one#readme",
            "https://github.com/octo",
            "https://github.com/octo/one/tree",
            "https://github.com//one",
            "javascript:alert(1)",
        )
        for (url in bad) {
            assertFalse(url, GitHubConnectorApi.isRepositoryUrl(url))
            expectConnector(GitHubConnectorError.INVALID_RESPONSE) {
                GitHubConnectorApi(FakeTransport { response(200, "[${repoJson(1, "octo/one", url)}]") }).repositories(1, token)
            }
        }
        for (body in listOf("""[{"id":1,"name":"","full_name":"a/b","html_url":"https://github.com/a/b"}]""", """{"id":1}""", """[{"id":"1"}]""")) {
            expectConnector(GitHubConnectorError.INVALID_RESPONSE) {
                GitHubConnectorApi(FakeTransport { response(200, body) }).repositories(1, token)
            }
        }
    }

    @Test
    fun statusMapping() = runBlocking {
        val cases = listOf(
            response(401) to GitHubConnectorError.UNAUTHORIZED,
            response(403, headers = mapOf("x-ratelimit-remaining" to "0")) to GitHubConnectorError.RATE_LIMITED,
            response(403, headers = mapOf("x-ratelimit-remaining" to "12")) to GitHubConnectorError.FORBIDDEN,
            response(403) to GitHubConnectorError.FORBIDDEN,
            response(429) to GitHubConnectorError.RATE_LIMITED,
            response(500) to GitHubConnectorError.SERVICE_UNAVAILABLE,
            response(301) to GitHubConnectorError.SERVICE_UNAVAILABLE,
        )
        for ((answer, expected) in cases) {
            expectConnector(expected) { GitHubConnectorApi(FakeTransport { answer }).repositories(1, token) }
            expectConnector(expected) { GitHubConnectorApi(FakeTransport { answer }).account(token) }
        }
        expectConnector(GitHubConnectorError.SERVICE_UNAVAILABLE) {
            GitHubConnectorApi(FakeTransport { throw IOException("offline") }).account(token)
        }
        val untouched = FakeTransport { error("must not send") }
        expectConnector(GitHubConnectorError.INVALID_RESPONSE) {
            GitHubConnectorApi(untouched).account(GitHubFixture.invalidToken)
        }
        assertTrue(untouched.requests.isEmpty())
    }

    private suspend fun expectConnector(expected: GitHubConnectorError, block: suspend () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (e: GitHubConnectorException) {
            assertEquals(expected, e.error)
        }
    }
}
