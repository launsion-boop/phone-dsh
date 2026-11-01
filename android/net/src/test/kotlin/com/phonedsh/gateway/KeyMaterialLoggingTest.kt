// phone-dsh — :gateway tests: the key path contains no logging call at all.
// SPDX-License-Identifier: MIT
//
// The production claim of this lane is "the model key never reaches logcat or an
// app log". A runtime assertion inside the app cannot read another process's log,
// and an instrumented test cannot prove a negative over all future edits, so the
// static half lives here: the only files that ever hold the key are checked for
// every logging entry point the App has (`android.util.Log`, `println`,
// `System.out/err`, `Throwable.printStackTrace`). A future edit that adds a log
// line to the key path fails this test before it can leak the key.
//
// The runtime half is the instrumented suite in `:app` plus the acceptance
// script's `adb logcat` grep.

package com.phonedsh.gateway

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyMaterialLoggingTest {

    /** Files that hold, read or inject the stored model key. */
    private val keyPathFiles = listOf(
        "android/app/src/main/kotlin/com/phonedsh/probe/ApiKeyStore.kt",
        "android/app/src/main/kotlin/com/phonedsh/probe/ProbeLaunchConfig.kt",
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
    fun theKeyPathHasNoLoggingCall() {
        for (relative in keyPathFiles) {
            val text = withoutComments(sourceOf(relative))
            for (api in loggingApis) {
                assertFalse(
                    "$relative must not contain `$api`: the model key rides this file",
                    text.contains(api),
                )
            }
        }
    }

    @Test
    fun theWorkerEnvCarriesTheGatewayPlaceholderNotAKey() {
        val text = withoutComments(sourceOf("android/app/src/main/kotlin/com/phonedsh/probe/ProbeLaunchConfig.kt"))
        assertTrue(
            "the placeholder the Worker sends must be the gateway's own constant, so the value " +
                "that is sent and the value the sanitizer drops cannot drift",
            text.contains("HOST_MANAGED_PLACEHOLDER"),
        )
        assertFalse(
            "the demo's old app-owned pseudo-key must never come back",
            text.contains("pdsh-app-placeholder"),
        )
        assertFalse(
            "the env builder must not contain a key-shaped literal",
            text.contains("DEEPSEEK_API_KEY\", \"sk-"),
        )
        assertFalse(
            "no state may put the stored value into the env",
            text.contains("DEEPSEEK_API_KEY, state.value"),
        )
    }

    @Test
    fun theStoreNeverWritesTheKeyIntoItsOwnSource() {
        val text = sourceOf("android/app/src/main/kotlin/com/phonedsh/probe/ApiKeyStore.kt")
        assertTrue(
            "the key is read from the platform SecureStore, not a literal",
            text.contains("SecureLookup"),
        )
        assertFalse("no key-shaped literal may be committed", text.contains("sk-test"))
        assertFalse("no key-shaped literal may be committed", text.contains("sk-live"))
    }

    // ---- helpers ---------------------------------------------------------

    /**
     * Resolves [relative] from this module's working directory without any
     * machine-specific path: Gradle runs a test with the module directory as the
     * working directory, so walking up to the repository root is portable.
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

    /**
     * Drops `//` and block comments so a documented example (`// never log ...`)
     * is not mistaken for a call. Strings are kept: a logging call inside a
     * string literal is still a leak when the string is a format.
     */
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
