// R4 — the WebView kernel matrix and feature gate (plan §6.2, §6.3-3).
// SPDX-License-Identifier: MIT
package com.phonedsh.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate must be decided by measurements, not by a version string:
 *
 *  * the Chromium major comes from the engine's user agent, so a Huawei
 *    versionName (`14.0.0.0`) can never be misread as a Chromium version;
 *  * a required feature the engine reports as missing is `UNSUPPORTED` even when
 *    the version looks new;
 *  * a feature nobody measured is never counted as present;
 *  * a kernel below the validated floor is `DEGRADED`, not blocked — it runs if
 *    the probe says it can.
 *
 * The floor is 124 because that is where `ReadableStream` async iteration became
 * native (MDN BCD `api/ReadableStream.json` `@@asyncIterator`; caniuse
 * `mdn-api_readablestream_--asynciterator`). Chromium 99/109 only run through
 * the worker prelude, which is why the probe installs that prelude before
 * measuring and why a 109 kernel is `DEGRADED`, never `UNSUPPORTED`.
 */
class WebViewKernelTest {
    private val huaweiUa =
        "Mozilla/5.0 (Linux; Android 12; ELS-AN00 Build/HUAWEIELS-AN00; wv) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 " +
            "Mobile Safari/537.36"

    /** The `android-35` image's WebView: the first engine we measured with native async iteration. */
    private val chromium124Ua =
        "Mozilla/5.0 (Linux; Android 14; sdk_gphone64_arm64 Build/UE1A) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 Mobile Safari/537.36"

    /** The `android-33` image's WebView: runs the worker only via the prelude. */
    private val chromium109Ua =
        "Mozilla/5.0 (Linux; Android 13; sdk_gphone64_arm64 Build/TE1A) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Version/4.0 Chrome/109.0.5414.123 Mobile Safari/537.36"

    private fun allRequired(present: Boolean = true): Map<KernelFeature, Boolean> =
        KernelFeature.entries
            .filter { it.required }
            .associateWith { present }

    private fun report(
        features: Map<KernelFeature, Boolean>,
        userAgent: String? = huaweiUa,
        providerPackage: String? = "com.huawei.webview",
        providerVersionName: String? = "14.0.0.0",
    ): WebViewKernelReport = WebViewKernelReport.of(
        providerPackage = providerPackage,
        providerVersionName = providerVersionName,
        probe = WebViewKernelProbe.Result(userAgent, features),
    )

    @Test
    fun theChromiumVersionComesFromTheUserAgentNeverFromVersionName() {
        val report = report(allRequired())
        assertEquals(99, report.chromiumMajor)
        assertTrue(report.versionLabel().startsWith("Chromium 99"))
        assertTrue(report.versionLabel().contains("provider 14.0.0.0"))
        assertFalse(
            "the provider's versionName must never be read as a Chromium version",
            report.versionLabel().contains("Chromium 14"),
        )
        assertNull(ChromiumVersion.majorFromUserAgent("Mozilla/5.0 (Linux) WebView/1.0"))
        assertNull(ChromiumVersion.majorFromUserAgent(null))
    }

    @Test
    fun theHuaweiProviderIsItsOwnVendorBucket() {
        assertEquals(KernelVendor.HUAWEI, KernelVendor.of("com.huawei.webview"))
        assertEquals(KernelVendor.GOOGLE, KernelVendor.of("com.google.android.webview"))
        assertEquals(KernelVendor.AOSP, KernelVendor.of("com.android.webview"))
        assertEquals(KernelVendor.OTHER, KernelVendor.of("com.miui.webview"))
        assertEquals(KernelVendor.UNKNOWN, KernelVendor.of(null))
        assertEquals(KernelVendor.HUAWEI, report(allRequired()).vendor)
    }

    @Test
    fun aMissingRequiredFeatureIsUnsupportedAndNamesItself() {
        val features = allRequired().toMutableMap()
        features[KernelFeature.READABLE_STREAM_ASYNC_ITERATION] = false
        val report = report(features)

        assertEquals(KernelVerdict.UNSUPPORTED, report.verdict)
        assertEquals(
            listOf(KernelFeature.READABLE_STREAM_ASYNC_ITERATION),
            report.missingRequired,
        )
        val detail = report.featureGateDetail()
        assertTrue("the detail must name the missing API", detail.contains("readable-stream-async-iteration"))
        assertTrue("the detail must name the engine", detail.contains("Chromium 99"))
        assertTrue("the vendor must be visible for support triage", detail.contains("huawei"))
    }

    @Test
    fun aMissingOptionalFeatureShimsInsteadOfBlocking() {
        val features = allRequired().toMutableMap()
        features[KernelFeature.SYMBOL_DISPOSE] = false
        val report = report(features, userAgent = chromium124Ua, providerPackage = "com.google.android.webview")

        assertEquals("Symbol.dispose has a shim; its absence is a note, not a gate", KernelVerdict.SUPPORTED, report.verdict)
        assertEquals(listOf(KernelFeature.SYMBOL_DISPOSE), report.missingOptional)
        assertTrue(report.featureGateDetail().contains("shimmed: symbol-dispose"))
    }

    @Test
    fun theFloorIsTheNativeAsyncIterationVersion() {
        assertEquals(
            "ReadableStream async iteration is native from Chromium 124 " +
                "(MDN BCD api/ReadableStream.json @@asyncIterator; caniuse mdn-api_readablestream_--asynciterator)",
            124,
            ChromiumVersion.FLOOR_MAJOR,
        )
        val why = KernelFeature.READABLE_STREAM_ASYNC_ITERATION.why
        assertTrue("the feature must cite the worker prelude that provides it", why.contains("jsc-compat.ts"))
        assertTrue("the feature must still cite the worker call site", why.contains("worker/worker.js"))
    }

    @Test
    fun aChromium109KernelRunsThroughThePrelude() {
        val report = report(allRequired(), userAgent = chromium109Ua, providerPackage = "com.google.android.webview")

        assertNotEquals(
            "Chromium 109 is the measured android-33 WebView; the worker's prelude makes it run",
            KernelVerdict.UNSUPPORTED,
            report.verdict,
        )
        assertEquals(KernelVerdict.DEGRADED, report.verdict)
        val detail = report.featureGateDetail()
        assertTrue(detail.contains("Chromium 109"))
        assertTrue("the detail must say the kernel is outside the native baseline", detail.contains("below baseline 124"))
        assertTrue(detail.contains("prelude"))
    }

    @Test
    fun aKernelBelowTheFloorIsDegradedNotBlocked() {
        val old = report(allRequired(), userAgent = "Mozilla/5.0 Chrome/88.0.4324.93 Safari/537.36")
        assertEquals(KernelVerdict.DEGRADED, old.verdict)
        assertTrue(old.missingRequired.isEmpty())
        assertTrue(old.featureGateDetail().contains("below baseline 124"))
    }

    @Test
    fun anUnknownEngineVersionIsDegradedNotSupported() {
        val unknown = report(allRequired(), userAgent = null)
        assertEquals(KernelVerdict.DEGRADED, unknown.verdict)
        assertEquals("Chromium unknown (provider 14.0.0.0)", unknown.versionLabel())
    }

    @Test
    fun noMeasurementIsUnverifiedNeverSupported() {
        val none = report(emptyMap())
        assertEquals(KernelVerdict.UNVERIFIED, none.verdict)
        assertEquals(KernelVerdict.UNVERIFIED, WebViewKernelReport.of(null, null, null).verdict)
        assertTrue(none.featureGateDetail().contains("probe did not run"))
    }

    @Test
    fun aPartialProbeCannotClaimSupport() {
        val partial = report(
            mapOf(KernelFeature.DECOMPRESSION_STREAM_GZIP to true),
        )
        assertEquals(KernelVerdict.UNVERIFIED, partial.verdict)
        assertTrue(partial.unmeasuredRequired.isNotEmpty())
        assertTrue(partial.featureGateDetail().contains("unmeasured:"))
    }

    @Test
    fun theEvaluatedStringLayerIsDecoded() {
        val inner = """
            {"ua":"Mozilla/5.0 (Linux; Android 12) Chrome/120.0.6099.230 Mobile",
             "features":{"readable-stream-async-iteration":true,
                         "readable-stream-pipe-through":true,
                         "decompression-stream-gzip":true,
                         "symbol-dispose":true}}
        """.trimIndent()

        // evaluateJavascript hands the callback the JSON encoding of the returned
        // string, i.e. one extra quoting layer with escaped inner quotes.
        val evaluated = JSONObject.quote(inner)
        val result = requireNotNull(WebViewKernelProbe.parse(evaluated))
        assertEquals(120, ChromiumVersion.majorFromUserAgent(result.userAgent))
        assertTrue(result.features.values.all { it })

        // A raw object (a host that unwraps it itself) is accepted too.
        assertTrue(requireNotNull(WebViewKernelProbe.parse(inner)).features.isNotEmpty())

        // Anything that is not a probe result is null, never an empty "supported".
        assertNull(WebViewKernelProbe.parse(null))
        assertNull(WebViewKernelProbe.parse("null"))
        assertNull(WebViewKernelProbe.parse("""{"features":{}}"""))
        assertNull(WebViewKernelProbe.parse("""{"ua":"x"}"""))
    }

    @Test
    fun theProbeInstallsTheWorkerPreludeBeforeMeasuring() {
        val script = WebViewKernelProbe.SCRIPT
        val install = script.indexOf("installWorkerPrelude();")
        val measure = script.indexOf("probe(\"readable-stream-async-iteration\"")
        assertTrue("the probe must carry the prelude mirror", install >= 0)
        assertTrue("the prelude must be installed before the feature is measured", install in 0 until measure)
        assertTrue("the mirror must name its source of truth", script.contains("jsc-compat.ts"))
        assertTrue(
            "the mirror's surface is machine-checked, not promised: " +
                "webview-kernel-probe.test.ts extracts the properties both sides install",
            script.contains("webview-kernel-probe.test.ts"),
        )
        assertTrue(
            "the async-iteration mirror must install values() as well as [Symbol.asyncIterator]",
            script.contains("\"values\""),
        )
        assertTrue("the probe must consume a step, not only check typeof", script.contains("iterator.next()"))
        assertFalse(
            "a bare typeof check is what refused every Chromium <124 kernel",
            script.contains("typeof ReadableStream.prototype[Symbol.asyncIterator] === \"function\""),
        )
    }

    @Test
    fun theProbeScriptCoversEveryFeatureId() {
        // An enum entry without a probe line would be "unmeasured" forever; the
        // gate would still pass on the other three and the new dependency would
        // silently go unchecked.
        for (feature in KernelFeature.entries) {
            assertTrue(
                "probe script lacks ${feature.id}",
                WebViewKernelProbe.SCRIPT.contains("\"${feature.id}\""),
            )
        }
        assertTrue(WebViewKernelProbe.SCRIPT.contains("JSON.stringify(out)"))
        assertTrue(WebViewKernelProbe.SCRIPT.contains("navigator.userAgent"))
    }

    @Test
    fun everyFeatureCitesTheWorkerCodeThatNeedsIt() {
        for (feature in KernelFeature.entries) {
            assertTrue(
                "${feature.id} must cite worker code, not a hunch",
                feature.why.contains("worker/worker.js"),
            )
        }
    }
}
