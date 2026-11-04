// The predictive-back fact, and the manifest declaration it must not drift from.
// SPDX-License-Identifier: MIT
//
// `predictiveBack` is a platform fact, not a build constant: the manifest can opt
// in and the device can still not carry the gesture, so the fact is computed from
// three readings. The tests below pin the two that can be checked on the JVM — the
// declaration (parsed from the real manifest file) and the decision table — while
// the third (the platform actually delivering a gesture) is the device test's job.
package com.phonedsh.probe

import com.phonedsh.ui.page.FactState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackNavigationTest {
    // ------------------------------------------------------------------ manifest

    /**
     * The constant the fact reads must be the declaration the APK carries.
     *
     * `ApplicationInfo` exposes no public getter for `enableOnBackInvokedCallback`
     * (the field is `@hide`), so :app carries the declaration as
     * [MANIFEST_DECLARES_BACK_INVOKED]. This test is what keeps the two honest: a
     * build whose manifest lost the attribute fails here instead of reporting a
     * predictive back it never opted into.
     */
    @Test
    fun `the manifest opts in, and the constant matches it`() {
        val manifest = manifestFile()
        val text = manifest.readText()
        val declared = Regex("""android:enableOnBackInvokedCallback\s*=\s*"(\w+)"""")
            .find(text)
            ?.groupValues
            ?.get(1)
        assertEquals(
            "src/main/AndroidManifest.xml must declare " +
                "android:enableOnBackInvokedCallback=\"true\" (found: ${manifest.path})",
            MANIFEST_DECLARES_BACK_INVOKED.toString(),
            declared,
        )
    }

    /**
     * The attribute really sits on `<application>`: an `enableOnBackInvokedCallback`
     * on some other element is not a declaration the platform reads, and a grep-only
     * check would accept it.
     */
    @Test
    fun `the attribute is on the application element`() {
        val text = manifestFile().readText()
        val application = Regex("""<application\b[^>]*>""").find(text)?.value
        assertTrue("no <application> element found", application != null)
        assertTrue(
            "<application> must carry android:enableOnBackInvokedCallback (was: $application)",
            application!!.contains("""android:enableOnBackInvokedCallback="true""""),
        )
    }

    // ------------------------------------------------------------------ decision

    /**
     * The four readings, one assertion each.
     *
     * The API-34 branch is the one that matters for honesty: a declared manifest
     * with no observed gesture is 未知, not 是 — the device has not answered yet.
     */
    @Test
    fun `no manifest opt-in means NO, whatever the platform can do`() {
        assertEquals(
            FactState.NO,
            predictiveBackFact(sdkInt = 35, declared = false, observed = false),
        )
        assertEquals(
            FactState.NO,
            predictiveBackFact(sdkInt = 35, declared = false, observed = true),
        )
    }

    @Test
    fun `a platform without the invoker means NO`() {
        assertEquals(
            FactState.NO,
            predictiveBackFact(sdkInt = 32, declared = true, observed = false),
        )
    }

    @Test
    fun `an observed predictive gesture means YES`() {
        assertEquals(
            FactState.YES,
            predictiveBackFact(sdkInt = 35, declared = true, observed = true),
        )
    }

    @Test
    fun `a declared manifest without an observation is UNKNOWN on API 34 plus`() {
        assertEquals(
            FactState.UNKNOWN,
            predictiveBackFact(sdkInt = 34, declared = true, observed = false),
        )
        assertEquals(
            FactState.UNKNOWN,
            predictiveBackFact(sdkInt = 35, declared = true, observed = false),
        )
    }

    /**
     * API 33 is the one asymmetric case: `BackEvent` does not exist there, so no
     * observation is possible and waiting for one would print 未知 forever on a
     * phone where the opt-in works. The declaration plus the platform's invoker is
     * the whole reading.
     */
    @Test
    fun `API 33 reads YES without an observation, because it cannot send one`() {
        assertEquals(
            FactState.YES,
            predictiveBackFact(sdkInt = 33, declared = true, observed = false),
        )
    }

    /** The production call site reads the real manifest, so it starts at 未知/是/否. */
    @Test
    fun `the production default is a reading, not a constant`() {
        val fact = predictiveBackFact()
        assertTrue(
            "the reading must be one of the three states, was $fact",
            fact in FactState.entries,
        )
    }

    // --------------------------------------------------------------------- files

    /**
     * The manifest as the plugin sees it.
     *
     * A Gradle unit test runs in the module directory and also from the repo root
     * (some harnesses), so both layouts are accepted; a test that silently skipped
     * when the file moved would be worse than no test.
     */
    private fun manifestFile(): File {
        val candidates = listOf(
            File("src/main/AndroidManifest.xml"),
            File("android/app/src/main/AndroidManifest.xml"),
        )
        return candidates.firstOrNull { it.isFile }
            ?: error("AndroidManifest.xml not found from ${File(".").absolutePath}")
    }
}
