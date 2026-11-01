// phone-dsh — :loopback tests: static assets, media types and the path guard.
// SPDX-License-Identifier: MIT
//
// The worker bundle is served verbatim from one directory; the media type is
// fixed by extension (a wrong `.wasm` type disables WebAssembly streaming
// compilation) and the launch page plus every manifest are `no-store`.

package com.phonedsh.loopback

import io.ktor.client.statement.bodyAsBytes
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files
import java.nio.file.Path

class LoopbackStaticAssetTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: Path
    private lateinit var assets: Path

    @Before
    fun setUp() {
        root = Path.of(temporary.newFolder("root").absolutePath)
        assets = Fixtures.write(root.resolve("assets"))
    }

    @Test
    fun mediaTypesAreCorrectForTheWorkerBundle() = runBlocking {
        val expected = mapOf(
            "/index.html" to "text/html; charset=utf-8",
            "/worker-entry.js" to "text/javascript; charset=utf-8",
            "/worker-entry.mjs" to "text/javascript; charset=utf-8",
            "/boot.js" to "text/javascript; charset=utf-8",
            "/manifest.json" to "application/json; charset=utf-8",
            "/probe-bundle.json" to "application/json; charset=utf-8",
            "/tool-worker.js.map" to "application/json; charset=utf-8",
            "/engine.wasm" to "application/wasm",
            "/styles.css" to "text/css; charset=utf-8",
            "/lazy/abc.tar.gz" to "application/gzip",
            "/plain.bin" to "application/octet-stream",
        )
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                for ((path, mediaType) in expected) {
                    val response = http.getAsset(endpoint, path)
                    assertEquals("status of $path", 200, response.status.value)
                    assertEquals("Content-Type of $path", mediaType, response.headers["Content-Type"])
                }
            }
        }
    }

    @Test
    fun theLaunchPageAndEveryManifestAreNoStore() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                for (path in listOf("/", "/index.html", "/manifest.json", "/probe-bundle.json")) {
                    val response = http.getAsset(endpoint, path)
                    assertEquals("status of $path", 200, response.status.value)
                    assertEquals("Cache-Control of $path", "no-store", response.headers["Cache-Control"])
                }
            }
        }
    }

    @Test
    fun binaryAssetsAreServedByteForByte() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                assertArrayEquals(Fixtures.WASM, http.getAsset(endpoint, "/engine.wasm").bodyAsBytes())
                assertArrayEquals(Fixtures.OPAQUE, http.getAsset(endpoint, "/plain.bin").bodyAsBytes())
                assertEquals(
                    Fixtures.INDEX_HTML,
                    http.getAsset(endpoint, "/").bodyAsBytes().toString(Charsets.UTF_8),
                )
            }
        }
    }

    @Test
    fun aDirectoryServesItsIndexAndAnIndexlessDirectoryIs404() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val sub = http.getAsset(endpoint, "/sub/")
                assertEquals(200, sub.status.value)
                assertEquals(Fixtures.SUB_INDEX_HTML, sub.bodyAsBytes().toString(Charsets.UTF_8))
                assertEquals(404, http.getAsset(endpoint, "/no-index/").status.value)
                assertEquals(404, http.getAsset(endpoint, "/missing.txt").status.value)
            }
        }
    }

    @Test
    fun traversalAttemptsAre404() {
        Files.writeString(root.resolve("secret.txt"), "not for the origin\n")
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val headers = mapOf("Authorization" to "Bearer ${endpoint.token}")
            val attempts = listOf(
                "/../secret.txt",
                "/../../secret.txt",
                "/sub/../../secret.txt",
                "/%2e%2e/secret.txt",
                "/..%2fsecret.txt",
                "/./index.html",
                "/sub/..",
                "/\u0000index.html",
            )
            for (target in attempts) {
                val response = rawRequest(endpoint.port, "GET", target, headers)
                assertTrue(
                    "traversal $target must not be served (was ${response.status})",
                    response.status == 400 || response.status == 404,
                )
                assertFalse(
                    "traversal $target must not leak the outside file",
                    response.bodyText.contains("not for the origin"),
                )
            }
            assertTrue("the outside file still exists", Files.exists(root.resolve("secret.txt")))
        }
    }

    @Test
    fun aSymlinkThatEscapesTheAssetRootIs404() {
        val outside = root.resolve("secret.txt")
        Files.writeString(outside, "not for the origin\n")
        val link = assets.resolve("escape.txt")
        try {
            Files.createSymbolicLink(link, outside)
        } catch (unsupported: UnsupportedOperationException) {
            return
        } catch (denied: java.io.IOException) {
            return
        }
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val response = rawRequest(
                endpoint.port,
                "GET",
                "/escape.txt",
                mapOf("Authorization" to "Bearer ${endpoint.token}"),
            )
            assertEquals(404, response.status)
            assertFalse(response.bodyText.contains("not for the origin"))
        }
    }

    @Test
    fun theLaunchPageIsCrossOriginIsolatedAndAssetsAreNot() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val page = http.getAsset(endpoint, "/")
                assertEquals("same-origin", page.headers["Cross-Origin-Opener-Policy"])
                assertEquals("require-corp", page.headers["Cross-Origin-Embedder-Policy"])
                val script = http.getAsset(endpoint, "/worker-entry.js")
                assertNull(script.headers["Cross-Origin-Opener-Policy"])
                assertNull(script.headers["Cross-Origin-Embedder-Policy"])
            }
        }
    }

    @Test
    fun onlyGetIsServed() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            val headers = mapOf("Authorization" to "Bearer ${endpoint.token}")
            assertEquals(405, rawRequest(endpoint.port, "POST", "/index.html", headers).status)
            assertEquals(405, rawRequest(endpoint.port, "PUT", "/manifest.json", headers).status)
            assertEquals(405, rawRequest(endpoint.port, "DELETE", "/", headers).status)
            assertEquals(405, rawRequest(endpoint.port, "HEAD", "/index.html", headers).status)
        }
    }
}
