// phone-dsh — :engine / com.phonedsh.engine: version and feature telemetry (§6.3-3).
// SPDX-License-Identifier: MIT
//
// The plan demotes version gates to telemetry and makes runtime feature detection
// the norm: a Huawei WebView reports a Chromium-99-era baseline but a versionName
// from another universe, so the engine reports both the provider identity and the
// androidx.webkit feature probes and lets the host decide. Nothing here gates a
// page load: the page's own capability check is the authority.

package com.phonedsh.engine

/** What this device's WebView provider says it can do. Safe to log and to show. */
data class EngineCapabilities(
    val providerPackage: String?,
    val providerVersion: String?,
    /** `WebViewFeature.WEB_MESSAGE_LISTENER`: the scoped bridge of the future. */
    val supportsWebMessageListener: Boolean,
    /** `WebViewFeature.DOCUMENT_START_SCRIPT`: inject before page script. */
    val supportsDocumentStartScript: Boolean,
    /** `WebViewFeature.WEB_VIEW_RENDERER_CLIENT_BASIC_USAGE`: renderer termination hooks. */
    val supportsWebViewRendererClient: Boolean,
) {
    fun describe(): String = buildString {
        append("provider=").append(providerPackage ?: "unknown")
        append('/').append(providerVersion ?: "unknown")
        append(", webMessageListener=").append(supportsWebMessageListener)
        append(", documentStartScript=").append(supportsDocumentStartScript)
        append(", rendererClient=").append(supportsWebViewRendererClient)
    }

    companion object {
        /** Used before a provider is resolvable (or when probing throws). */
        val Unknown: EngineCapabilities =
            EngineCapabilities(null, null, false, false, false)
    }
}
