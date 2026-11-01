// phone-dsh — :loopback tests: the D22 launch exchange and its cookie.
// SPDX-License-Identifier: MIT
//
// The protocol under test is the one `Sources/PhoneDSHLoopback/LoopbackServer.swift`
// registers and the App relies on:
//
//   * `GET /?token=<launch token>` answers 303 to `/` with
//     `Set-Cookie: xl_launch_token=<token>; Path=/; HttpOnly; SameSite=Strict`
//     (name at line 112, attributes at lines 636-641 of the iOS baseline);
//   * the cookie is a credential for the page, its subresources and the
//     browser's `/channel` upgrade;
//   * the cookie is bound to the authority that received it: a request whose
//     Host is not this origin gets no cookie and no credential from one;
//   * no response ever echoes the token, and the exchange never puts it in
//     `Location`.

package com.phonedsh.loopback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.net.URLEncoder
import java.nio.file.Path

class LoopbackLaunchCookieTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun theLaunchExchangeSetsExactlyTheBaselineCookie() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            for (page in listOf("/", "/index.html")) {
                val exchange = rawRequest(endpoint.port, "GET", "$page?token=${endpoint.token}")
                assertEquals("status of $page?token=", 303, exchange.status)
                assertEquals("/", exchange.header("Location"))
                assertEquals("no-store", exchange.header("Cache-Control"))
                val cookie = exchange.header("Set-Cookie")
                assertEquals(
                    "the exact iOS baseline value (LoopbackServer.swift:639-641)",
                    "xl_launch_token=${endpoint.token}; Path=/; HttpOnly; SameSite=Strict",
                    cookie,
                )
                assertTrue("HttpOnly keeps page script from reading it", cookie!!.contains("HttpOnly"))
                assertTrue(cookie.contains("SameSite=Strict"))
                assertTrue(cookie.contains("Path=/"))
                assertFalse("loopback is HTTP: a Secure cookie would never be sent", cookie.contains("Secure"))
                assertFalse("host-only: no Domain attribute", cookie.contains("Domain"))
                assertFalse("Location must not repeat the token", exchange.header("Location")!!.contains(endpoint.token))
                assertFalse("the 303 body must not echo the token", exchange.bodyText.contains(endpoint.token))
            }
        }
    }

    @Test
    fun theCookieAuthenticatesThePageAndItsSubresources() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val cookie = LaunchCookie.headerValue(endpoint.token)
            for ((path, body) in listOf(
                "/" to Fixtures.INDEX_HTML,
                "/boot.js" to Fixtures.BOOT_JS,
                "/manifest.json" to Fixtures.MANIFEST,
                "/engine.wasm" to null,
            )) {
                val response = rawRequest(endpoint.port, "GET", path, mapOf("Cookie" to cookie))
                assertEquals("cookie-authenticated $path", 200, response.status)
                if (body != null) assertEquals("body of $path", body, response.bodyText)
                assertEquals("no-store on $path", "no-store", response.header("Cache-Control"))
            }
            // The page response seeds the cookie as well (iOS parity), so a
            // Bearer-authenticated page load leaves its subresources a credential.
            val bearerPage = rawRequest(
                endpoint.port,
                "GET",
                "/",
                mapOf("Authorization" to "Bearer ${endpoint.token}"),
            )
            assertEquals(200, bearerPage.status)
            assertEquals(LaunchCookie.headerValue(endpoint.token), bearerPage.header("Set-Cookie"))
        }
    }

    @Test
    fun theCookieAuthenticatesTheChannelUpgrade() {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            val upgrade = rawRequest(
                endpoint.port,
                "GET",
                LoopbackConfiguration.CHANNEL_PATH,
                upgradeHeaders(token = null) + ("Cookie" to LaunchCookie.headerValue(endpoint.token)),
            )
            assertEquals("a cookie alone must carry the browser's upgrade", 101, upgrade.status)
            awaitTrue(5_000, "the cookie-authenticated channel to open") { handler.opened.get() == 1 }
        }
    }

    @Test
    fun aMissingOrWrongCookieIs401AndWrongTokenIs401() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val wrong = "0".repeat(64)
            assertEquals(401, rawRequest(endpoint.port, "GET", "/").status)
            assertEquals(401, rawRequest(endpoint.port, "GET", "/boot.js").status)
            assertEquals(
                401,
                rawRequest(endpoint.port, "GET", "/", mapOf("Cookie" to "$wrong=whatever")).status,
            )
            assertEquals(
                401,
                rawRequest(endpoint.port, "GET", "/", mapOf("Cookie" to LaunchCookie.headerValue(wrong))).status,
            )
            assertEquals(
                "a wrong query token is the same 401 as a missing one",
                401,
                rawRequest(endpoint.port, "GET", "/?token=$wrong").status,
            )
            // A valid query token still wins when an unrelated cookie is present.
            assertEquals(
                303,
                rawRequest(
                    endpoint.port,
                    "GET",
                    "/?token=${endpoint.token}",
                    mapOf("Cookie" to LaunchCookie.headerValue(wrong)),
                ).status,
            )
        }
    }

    @Test
    fun theCookieIsBoundToTheAuthorityThatReceivedIt() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val foreign = "evil.example"
            // No exchange for a request addressed elsewhere: no Set-Cookie, and
            // the token is not leaked in the refusal.
            val exchange = rawRequest(endpoint.port, "GET", "/?token=${endpoint.token}", host = foreign)
            assertEquals(403, exchange.status)
            assertNull("a foreign authority must not be handed the cookie", exchange.header("Set-Cookie"))
            assertFalse(exchange.bodyText.contains(endpoint.token))
            // A cookie the browser could only have received from this authority
            // is still not accepted when the Host names another one.
            val page = rawRequest(
                endpoint.port,
                "GET",
                "/",
                headers = mapOf("Cookie" to LaunchCookie.headerValue(endpoint.token)),
                host = "$foreign:80",
            )
            assertEquals(403, page.status)
            // The same request to the real authority succeeds.
            assertEquals(
                200,
                rawRequest(
                    endpoint.port,
                    "GET",
                    "/",
                    headers = mapOf("Cookie" to LaunchCookie.headerValue(endpoint.token)),
                    host = "127.0.0.1:${endpoint.port}",
                ).status,
            )
        }
    }

    @Test
    fun theInjectedTokenIsTheOneBothCarriersUse() {
        val injected = "0123456789abcdef".repeat(4)
        LoopbackServer().use { server ->
            val endpoint = server.start(assets, injected)
            assertEquals("the host's per-start token is the live one", injected, endpoint.token)
            val exchange = rawRequest(endpoint.port, "GET", "/?token=$injected")
            assertEquals(303, exchange.status)
            assertEquals(LaunchCookie.headerValue(injected), exchange.header("Set-Cookie"))
            assertEquals(
                200,
                rawRequest(
                    endpoint.port,
                    "GET",
                    "/",
                    mapOf("Cookie" to LaunchCookie.headerValue(injected)),
                ).status,
            )
        }
    }

    @Test
    fun anInjectedTokenMustBeUsableAndIsNeverEchoedByTheFailure() {
        LoopbackServer().use { server ->
            val tooShort = "short"
            val failure = try {
                server.start(assets, tooShort)
                null
            } catch (expected: IllegalArgumentException) {
                expected
            }
            assertTrue("a short per-start token must be refused", failure != null)
            assertFalse("the failure must not echo the token", failure!!.message!!.contains(tooShort))
            assertNull("nothing may be started", server.endpoint())
        }
    }

    @Test
    fun aPinnedTokenThatCannotBeACookieKeepsThePreD22Page() {
        // A pinned token is allowed to be any printable string today. One that
        // is not a cookie-octet sequence must not corrupt a Set-Cookie header,
        // so the exchange is skipped and the page is served as before.
        val pinned = "0123456789abcdef;still-usable"
        LoopbackServer(LoopbackConfiguration(token = pinned)).use { server ->
            val endpoint = server.start(assets)
            val encoded = URLEncoder.encode(pinned, Charsets.UTF_8.name())
            val page = rawRequest(endpoint.port, "GET", "/?token=$encoded")
            assertEquals(200, page.status)
            assertEquals(Fixtures.INDEX_HTML, page.bodyText)
            assertNull(page.header("Set-Cookie"))
        }
    }
}
