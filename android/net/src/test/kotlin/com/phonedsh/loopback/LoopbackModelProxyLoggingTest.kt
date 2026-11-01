// phone-dsh — :loopback tests: the model edge has no logging call on the key path.
// SPDX-License-Identifier: MIT
//
// The runtime claim is "no log line names the injected key". A test process
// cannot prove a negative over every future edit, so the static half lives here:
// the production files that hold, resolve or inject the model key are scanned for
// every logging entry point this module could use (Android `Log`, `println`,
// `System.out/err`, `printStackTrace`). A future edit that adds a log line to the
// model edge fails this test before it can leak the key.
//
// The `grep` half of the same claim is run from the lane's self-check and is also
// expressed here as "no key-shaped literal in the production files".

package com.phonedsh.loopback

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Test

class LoopbackModelProxyLoggingTest {

    /** Files that resolve the key, inject it, or own the forwarding edge. */
    private val keyPathFiles = listOf(
        "android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackModelProxy.kt",
        "android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackService.kt",
        "android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackServer.kt",
        "android/net/src/main/kotlin/com/phonedsh/gateway/ModelGatewayCredentialProvider.kt",
    )

    /** Every way production Kotlin in this tree could emit a line. */
    private val loggingApis = listOf(
        "android.util.Log",
        "Log.d(",
        "Log.i(",
        "Log.w(",
        "Log.e(",
        "Log.v(",
        "Log.println(",
        "println(",
        "System.out",
        "System.err",
        "printStackTrace",
    )

    @Test
    fun theModelEdgeHasNoLoggingCall() {
        for (relative in keyPathFiles) {
            val text = withoutComments(sourceOf(relative))
            for (api in loggingApis) {
                assertFalse(
                    "$relative must not contain `$api`: the injected model key rides this path",
                    text.contains(api),
                )
            }
        }
    }

    @Test
    fun noKeyShapedLiteralIsCommittedOnTheModelEdge() {
        for (relative in keyPathFiles) {
            val text = sourceOf(relative)
            assertFalse("$relative must not carry a test key literal", text.contains("sk-test"))
            assertFalse("$relative must not carry a live key literal", text.contains("sk-live"))
        }
    }

    // ---- helpers ---------------------------------------------------------

    /**
     * Resolves [relative] from the module's working directory without a
     * machine-specific path: Gradle runs the test with `android/net` as the
     * working directory, so walking up reaches the repository root.
     */
    private fun sourceOf(relative: String): String {
        var directory: File? = File(System.getProperty("user.dir")).absoluteFile
        while (directory != null) {
            val candidate = File(directory, relative)
            if (candidate.isFile) return candidate.readText()
            directory = directory.parentFile
        }
        throw AssertionError("cannot resolve $relative from ${System.getProperty("user.dir")}")
    }

    /** Drops comments so a documented example is not mistaken for a call. */
    private fun withoutComments(text: String): String {
        val out = StringBuilder(text.length)
        var index = 0
        var inBlock = false
        var inLine = false
        var quote: Char? = null
        while (index < text.length) {
            val char = text[index]
            val next = if (index + 1 < text.length) text[index + 1] else '\u0000'
            if (inLine) {
                if (char == '\n') {
                    inLine = false
                    out.append(char)
                }
                index++
                continue
            }
            if (inBlock) {
                if (char == '*' && next == '/') {
                    inBlock = false
                    index += 2
                } else {
                    index++
                }
                continue
            }
            if (quote != null) {
                out.append(char)
                if (char == '\\' && next != '\u0000') {
                    out.append(next)
                    index += 2
                    continue
                }
                if (char == quote) quote = null
                index++
                continue
            }
            when {
                char == '/' && next == '/' -> {
                    inLine = true
                    index += 2
                }
                char == '/' && next == '*' -> {
                    inBlock = true
                    index += 2
                }
                char == '"' || char == '\'' -> {
                    quote = char
                    out.append(char)
                    index++
                }
                else -> {
                    out.append(char)
                    index++
                }
            }
        }
        return out.toString()
    }
}
