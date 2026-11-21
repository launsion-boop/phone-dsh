// phone-dsh — :net / com.phonedsh.connectors.github: GitHub REST reads.
// SPDX-License-Identifier: MIT
//
// Ported from `examples/probe-app/ProbeKit/GitHubConnectorAPI.swift`
// (PC-20261119-android-connectors): the same `/user` and `/user/repos` reads,
// 2022-11-28 API version, 30-row pages, next-page relation, repository link
// check and error mapping. The token is only ever put in the Authorization
// header and never logged.

package com.phonedsh.connectors.github

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.net.URI
import kotlinx.coroutines.CancellationException

enum class GitHubConnectorError {
    UNAUTHORIZED,
    FORBIDDEN,
    RATE_LIMITED,
    INVALID_RESPONSE,
    SERVICE_UNAVAILABLE,
}

class GitHubConnectorException(val error: GitHubConnectorError) : Exception(error.name)

data class GitHubAccount(val login: String)

data class GitHubRepository(val id: Long, val name: String, val fullName: String, val htmlUrl: String)

data class GitHubRepositoryPage(val repositories: List<GitHubRepository>, val nextPage: Int?)

class GitHubConnectorApi(
    private val transport: GitHubHttpTransport = HttpUrlConnectionGitHubTransport(TIMEOUT_MILLIS),
) {
    suspend fun account(token: String): GitHubAccount {
        val response = get("user", emptyList(), token)
        val root = GatewayJson.parseOrNull(response.body) as? JsonValue.Obj ?: throw invalidResponse()
        val login = (root.get("login") as? JsonValue.Str)?.value ?: throw invalidResponse()
        if (login.isEmpty()) throw invalidResponse()
        return GitHubAccount(login)
    }

    suspend fun repositories(page: Int = 1, token: String): GitHubRepositoryPage {
        if (page <= 0 || page == Int.MAX_VALUE) throw invalidResponse()
        val query = listOf("per_page" to "30", "sort" to "updated", "page" to page.toString())
        val response = get("user/repos", query, token)
        val items = (GatewayJson.parseOrNull(response.body) as? JsonValue.Arr)?.items ?: throw invalidResponse()
        val repositories = items.map { repository(it) ?: throw invalidResponse() }
        return GitHubRepositoryPage(
            repositories = repositories,
            nextPage = if (hasNextPage(response.headers["link"])) page + 1 else null,
        )
    }

    private suspend fun get(path: String, query: List<Pair<String, String>>, token: String): ConnectorHttpResponse {
        if (!isValidToken(token)) throw invalidResponse()
        val url = buildString {
            append("https://api.github.com/").append(path)
            if (query.isNotEmpty()) append('?').append(query.joinToString("&") { (name, value) -> "$name=$value" })
        }
        val request = ConnectorHttpRequest(
            method = "GET",
            url = url,
            headers = mapOf(
                "Authorization" to "Bearer $token",
                "Accept" to "application/vnd.github+json",
                "X-GitHub-Api-Version" to "2022-11-28",
                "User-Agent" to "phone-dsh",
            ),
            body = null,
        )
        val response = try {
            transport.send(request)
        } catch (error: CancellationException) {
            throw error
        } catch (error: GitHubConnectorException) {
            throw error
        } catch (_: Exception) {
            throw GitHubConnectorException(GitHubConnectorError.SERVICE_UNAVAILABLE)
        }
        when (response.status) {
            200 -> return response
            401 -> throw GitHubConnectorException(GitHubConnectorError.UNAUTHORIZED)
            403 -> throw GitHubConnectorException(
                if (response.headers["x-ratelimit-remaining"] == "0") {
                    GitHubConnectorError.RATE_LIMITED
                } else {
                    GitHubConnectorError.FORBIDDEN
                },
            )
            429 -> throw GitHubConnectorException(GitHubConnectorError.RATE_LIMITED)
            else -> throw GitHubConnectorException(GitHubConnectorError.SERVICE_UNAVAILABLE)
        }
    }

    companion object {
        const val TIMEOUT_MILLIS: Int = 30_000

        private val REPOSITORY_PATH = Regex("^/[^/]+/[^/]+/?$")

        /**
         * GitHub App user access tokens issued by the broker: `ghu_` plus 1 to
         * 251 ASCII letters, digits or underscores. A legacy PAT is rejected.
         */
        fun isValidToken(token: String): Boolean {
            val bytes = token.toByteArray(Charsets.UTF_8)
            if (bytes.size !in 5..255 || !token.startsWith("ghu_")) return false
            return bytes.drop(4).all { isAsciiAlphaNumeric(it) || it == '_'.code.toByte() }
        }

        /**
         * Only the relation is used; the next request is rebuilt from the fixed
         * endpoint and the current page, never from the response URL.
         */
        internal fun hasNextPage(link: String?): Boolean {
            if (link == null) return false
            return link.split(',').filter { it.isNotEmpty() }.any { entry ->
                entry.split(';').filter { it.isNotEmpty() }.drop(1).any { parameter ->
                    val pair = parameter.split("=", limit = 2)
                    if (pair.size != 2 || pair[0].trim { it == ' ' || it == '\t' }.lowercase() != "rel") return@any false
                    pair[1].trim { it == ' ' || it == '\t' }.trim('"').split(' ').filter { it.isNotEmpty() }
                        .any { it.lowercase() == "next" }
                }
            }
        }

        private fun repository(value: JsonValue): GitHubRepository? {
            val obj = value as? JsonValue.Obj ?: return null
            val id = (obj.get("id") as? JsonValue.Num)?.literal?.toLongOrNull() ?: return null
            val name = (obj.get("name") as? JsonValue.Str)?.value ?: return null
            val fullName = (obj.get("full_name") as? JsonValue.Str)?.value ?: return null
            val htmlUrl = (obj.get("html_url") as? JsonValue.Str)?.value ?: return null
            if (name.isEmpty() || fullName.isEmpty() || !isRepositoryUrl(htmlUrl)) return null
            return GitHubRepository(id, name, fullName, htmlUrl)
        }

        internal fun isRepositoryUrl(value: String): Boolean {
            val parsed = try {
                URI(value)
            } catch (_: Exception) {
                return false
            }
            if (parsed.scheme != "https") return false
            val authority = UrlAuthority.parse(parsed.rawAuthority) ?: return false
            if (authority.host != "github.com" || authority.port != null || authority.hasUserInfo) return false
            if (parsed.rawQuery != null || parsed.rawFragment != null) return false
            return REPOSITORY_PATH.matches(parsed.rawPath ?: "")
        }

        private fun invalidResponse() = GitHubConnectorException(GitHubConnectorError.INVALID_RESPONSE)
    }
}
