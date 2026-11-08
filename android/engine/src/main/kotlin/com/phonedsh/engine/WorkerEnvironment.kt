// phone-dsh — :engine / com.phonedsh.engine: the worker's `env` page parameter.
// SPDX-License-Identifier: MIT
//
// boot.js (`examples/probe-app/Bundle/worker/boot.js:75,120-136,158-170`) reads
// `?env=` as JSON, refuses anything that is not a JSON object, and forwards the
// object to the worker's `init` frame as `xl.env`. The worker entry
// (`plugins/worker-entry/src/entry.ts:1659,1900-1911`) re-validates it as an
// object of strings and passes it to the runtime host, whose process shim
// exposes it as `process.env`. That is how the resident phone surface receives
// `PDSH_DSH_LAUNCH_TOKEN` (`plugins/surface-phone/src/index.js:365`).
//
// The token is the only value this module always adds. A host may supply more
// keys through the ordinary `pageParams["env"]` entry; they are merged, and the
// launch token always wins over a stale same-named key.
//
// `DEEPSEEK_BASE_URL` is the second engine-owned key, and only when the host
// mounted a model proxy on this start: the Worker must point at the loopback
// origin, never at the real provider, because the host injects the credential at
// that edge. Without a proxy the host's value is left exactly as supplied, so a
// scripted-upstream launch keeps working.

package com.phonedsh.engine

import org.json.JSONException
import org.json.JSONObject

/** Builds the `env` page parameter the worker boot consumes. */
object WorkerEnvironment {
    /**
     * The variable the resident phone surface requires.
     *
     * `plugins/surface-phone/src/index.js:365-366` throws when it is empty, and
     * the worker boot then reports "the tree activated without a Connection
     * service"; the App generates the value per start and passes this same value
     * to the loopback origin.
     */
    const val LAUNCH_TOKEN: String = "PDSH_DSH_LAUNCH_TOKEN"

    /**
     * The Worker's model endpoint variable (`dsh-llm-deepseek`'s `baseURL`).
     *
     * The host edge owns its value whenever a model proxy is mounted: the Worker
     * appends the protocol path (`/v1/messages`) to it and the proxy forwards the
     * request to the configured real upstream, injecting the credential there.
     * The Worker itself only ever sees the loopback origin.
     */
    const val MODEL_BASE_URL: String = "DEEPSEEK_BASE_URL"

    /**
     * The JSON object string for `?env=`.
     *
     * Shape: `{"PDSH_DSH_LAUNCH_TOKEN":"<per-start token>"}` plus every entry of
     * [hostSupplied] when the host passed a `pageParams["env"]` object. When the
     * call also names [modelBaseUrl] (a mounted model proxy's loopback origin),
     * that one key is overwritten; every other host entry — `DEEPSEEK_API_KEY`'s
     * placeholder, `PDSH_MODEL_KEY_STATE`, ... — is kept byte for byte.
     *
     * The value is never logged; callers only put it in the page URL, whose query
     * is stripped by [EngineLogText.baseUrl] on every log line.
     *
     * @throws IllegalArgumentException when [hostSupplied] is not a JSON object;
     *   the message is constant and does not echo the input.
     */
    fun pageParam(
        launchToken: String,
        hostSupplied: String? = null,
        modelBaseUrl: String? = null,
        phoneMcpUrl: String? = null,
    ): String {
        val env = parseObject(hostSupplied)
        if (modelBaseUrl != null) env.put(MODEL_BASE_URL, modelBaseUrl)
        // native-mcp.md: with a mounted `/mcp/native` the host points the official
        // `mcp-phone` plugin at it (iOS `PhoneDSHHost.swift`, same two keys). The
        // token is this start's loopback token, i.e. the launch token.
        if (phoneMcpUrl != null) {
            env.put(PHONE_MCP_URL, phoneMcpUrl)
            env.put(PHONE_MCP_TOKEN, launchToken)
        }
        env.put(LAUNCH_TOKEN, launchToken)
        return env.toString()
    }

    /** `plugins/profile/phone.worker.cordis.patch.yml`: the app MCP endpoint (optional). */
    const val PHONE_MCP_URL: String = "PDSH_PHONE_MCP_URL"

    /** Bearer token for [PHONE_MCP_URL]; the same per-start origin token. */
    const val PHONE_MCP_TOKEN: String = "PDSH_PHONE_MCP_TOKEN"

    private fun parseObject(raw: String?): JSONObject {
        if (raw.isNullOrBlank()) return JSONObject()
        return try {
            JSONObject(raw)
        } catch (invalid: JSONException) {
            throw IllegalArgumentException("pageParams[\"env\"] must be a JSON object", invalid)
        }
    }
}
