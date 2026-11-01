// phone-dsh — :engine / com.phonedsh.engine: the navigation whitelist, JVM-only.
// SPDX-License-Identifier: MIT
//
// The rule evaluated by WebViewClient.shouldOverrideUrlLoading. If this test
// passes and WebViewEngine wires NavigationPolicy into the callback (see README),
// the only in-browser navigation the page can perform is inside its own origin.

package com.phonedsh.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationPolicyTest {
    private val policy = NavigationPolicy("http://127.0.0.1:43210")

    @Test
    fun allowsTheOriginAndEverythingBelowIt() {
        assertTrue(policy.isAllowed("http://127.0.0.1:43210"))
        assertTrue(policy.isAllowed("http://127.0.0.1:43210/"))
        assertTrue(policy.isAllowed("http://127.0.0.1:43210/index.html?x=1#top"))
        assertTrue(policy.isAllowed("http://127.0.0.1:43210/web/index.html"))
        assertTrue(policy.isAllowed("http://127.0.0.1:43210/blob:8f3a-uuid"))
    }

    @Test
    fun allowsBlobUrlsMintedByTheOrigin() {
        assertTrue(policy.isAllowed("blob:http://127.0.0.1:43210/9f1c2d3e-4a5b"))
    }

    @Test
    fun blocksEveryOtherNavigationTarget() {
        for (hostile in listOf(
            "http://127.0.0.1:43211/", // another port on loopback
            "http://127.0.0.1:43210.evil.test/", // prefix attack
            "https://127.0.0.1:43210/", // scheme differs
            "https://example.com/",
            "file:///data/data/com.phonedsh.probe/files/worker/index.html",
            "content://com.android.providers.media.documents/document/1",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "blob:http://127.0.0.1:43211/9f1c",
            "about:blank",
            "",
            null,
        )) {
            assertFalse("$hostile must be blocked", policy.isAllowed(hostile))
            assertTrue(policy.isBlocked(hostile))
        }
    }

    @Test
    fun theOriginMustBeAnHttpOriginWithoutATrailingSlash() {
        val bad = listOf("http://127.0.0.1:1/", "https://127.0.0.1:1", "127.0.0.1:1")
        for (value in bad) {
            val failure = runCatching { NavigationPolicy(value) }.exceptionOrNull()
            assertTrue("$value must be rejected", failure is IllegalArgumentException)
        }
    }
}
