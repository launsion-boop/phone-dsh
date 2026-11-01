// phone-dsh — :engine / com.phonedsh.engine: the static-asset security boundary.
// SPDX-License-Identifier: MIT
//
// The responder maps WebView request paths to files under the materialized bundle.
// Its rules mirror :net's StaticAssetStore; every rejection here is a 404, never a
// file outside the root. JVM-only: the android.webkit wrapper is not involved.

package com.phonedsh.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class WorkerFileStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun store(): WorkerFileStore {
        val root = temporary.newFolder("worker")
        write(root, "index.html", "page")
        write(root, "boot.js", "boot")
        write(root, "lazy/a.tar.gz", "archive")
        write(root, "dir/index.html", "nested")
        return WorkerFileStore(root.toPath())
    }

    private fun write(root: File, relativePath: String, content: String) {
        val file = File(root, relativePath)
        val parent = file.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
            throw IllegalStateException("cannot create $parent")
        }
        file.writeText(content)
    }

    @Test
    fun resolvesTheLaunchPageAndFilesUnderTheRoot() {
        val store = store()
        assertEquals("index.html", store.resolve("/")?.fileName?.toString())
        assertEquals("index.html", store.resolve("/index.html")?.fileName?.toString())
        assertEquals("boot.js", store.resolve("/boot.js")?.fileName?.toString())
        assertEquals("a.tar.gz", store.resolve("/lazy/a.tar.gz")?.fileName?.toString())
        assertEquals("index.html", store.resolve("/dir/")?.fileName?.toString())
        assertEquals("boot.js", store.resolve("/boot.js?cache=0")?.fileName?.toString())
    }

    @Test
    fun rejectsTraversalEscapesAndWeirdSegments() {
        val store = store()
        for (hostile in listOf(
            "/../secret.txt",
            "/lazy/../../secret.txt",
            "//etc/passwd",
            "/%2e%2e/%2e%2e/etc/passwd",
            "/C:/Windows/win.ini",
            "/boot.js\u0000.png",
            "/lazy\\..\\boot.js",
            "relative/path",
        )) {
            assertNull("$hostile must not resolve", store.resolve(hostile))
        }
        assertNull(store.resolve("/missing.js"))
        assertNull(store.resolve("/lazy"))
    }

    @Test
    fun mapsTheMediaTypesTheBundleNeeds() {
        assertEquals("application/wasm", WorkerFileStore.contentTypeFor("engine.wasm"))
        assertEquals("text/javascript; charset=utf-8", WorkerFileStore.contentTypeFor("app.js"))
        assertEquals("text/javascript; charset=utf-8", WorkerFileStore.contentTypeFor("app.mjs"))
        assertEquals("text/javascript; charset=utf-8", WorkerFileStore.contentTypeFor("APP.JS"))
        assertEquals("application/json; charset=utf-8", WorkerFileStore.contentTypeFor("app.js.map"))
        assertEquals("text/html; charset=utf-8", WorkerFileStore.contentTypeFor("index.html"))
        assertEquals("application/gzip", WorkerFileStore.contentTypeFor("image.tar.gz"))
        assertEquals(WorkerFileStore.OCTET_STREAM, WorkerFileStore.contentTypeFor("no-extension"))
        assertEquals(WorkerFileStore.OCTET_STREAM, WorkerFileStore.contentTypeFor(".hidden"))
    }

    @Test
    fun requiresAnExistingRootDirectory() {
        val missing = File(temporary.root, "nope")
        val failure = runCatching { WorkerFileStore(missing.toPath()) }.exceptionOrNull()
        assertNotNull(failure)
    }
}
