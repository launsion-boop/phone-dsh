// phone-dsh — :engine / com.phonedsh.engine: the query-free log shapes.
// SPDX-License-Identifier: MIT
//
// The console callback receives page-controlled text. These tests pin the one
// property that keeps the launch URL out of logcat: every URL the page writes
// keeps its scheme, host, port and path, never its query or fragment. The
// launch URL's `env` query is the whole worker environment, so a single missed
// `?` is a credential line in logcat.

package com.phonedsh.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class EngineLogTextTest {
    /** The shape the engine itself builds: the env object URL-encoded in one query. */
    private val launchUrl = "http://127.0.0.1:41234/" +
        "?image=http%3A%2F%2F127.0.0.1%3A41234%2Fimage.tar.gz" +
        "&channel=ws%3A%2F%2F127.0.0.1%3A41234%2Fchannel" +
        "&env=%7B%22DEEPSEEK_API_KEY%22%3A%22phone-host-injects-mcp-key%22%2C" +
        "%22PDSH_DSH_LAUNCH_TOKEN%22%3A%22deadbeef%22%7D"

    @Test
    fun baseUrlDropsTheQueryAndTheFragment() {
        assertEquals("http://127.0.0.1:41234/", EngineLogText.baseUrl(launchUrl))
        assertEquals("http://127.0.0.1:41234/boot.js", EngineLogText.baseUrl("http://127.0.0.1:41234/boot.js#frag"))
        assertEquals("about:blank", EngineLogText.baseUrl("about:blank"))
    }

    @Test
    fun consoleKeepsTheMessageAndDropsTheQueryOfALoggedLocationHref() {
        val logged = EngineLogText.console("Z3_PARSER $launchUrl")

        assertEquals("Z3_PARSER http://127.0.0.1:41234/", logged)
        assertFalse(logged.contains("env="))
        assertFalse(logged.contains("PDSH_DSH_LAUNCH_TOKEN"))
    }

    @Test
    fun consoleDropsTheQueryOfEveryUrlInOneMessage() {
        assertEquals(
            "loaded http://a.test/x and ws://b.test:9/channel (retry)",
            EngineLogText.console("loaded http://a.test/x?a=1 and ws://b.test:9/channel?token=secret (retry)"),
        )
    }

    @Test
    fun consoleLeavesAUrlWithoutQueryAndFragmentAlone() {
        assertEquals("see http://a.test/path", EngineLogText.console("see http://a.test/path"))
    }

    @Test
    fun consoleLeavesOrdinaryProseAlone() {
        val prose = "boot ok? yes, 100% done"

        assertEquals(prose, EngineLogText.console(prose))
    }

    @Test
    fun consoleDoesNotNeedTheLowercaseHttpSpelling() {
        assertEquals(
            "HTTP://a.test/path",
            EngineLogText.console("HTTP://a.test/path?secret=1"),
        )
    }
}
