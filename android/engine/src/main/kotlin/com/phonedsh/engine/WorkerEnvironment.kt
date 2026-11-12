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
// The launch token and the GitHub agent facts are the values this module always
// adds. A host may supply more keys through the ordinary `pageParams["env"]`
// entry; they are merged, and the engine-owned keys always win over a stale (or
// forged) same-named host value. The token itself never enters the environment:
// `PDSH_GITHUB_AUTH` / `PDSH_GITHUB_WRITE` are the host's "a token exists" /
// "writes are enabled" decisions (`PC-20261112-github-agent-credential`).
//
// `DEEPSEEK_BASE_URL` is the second engine-owned key, and only when the host
// mounted a model proxy on this start: the Worker must point at the loopback
// origin, never at the real provider, because the host injects the credential at
// that edge. Without a proxy the host's value is left exactly as supplied, so a
// scripted-upstream launch keeps working.

package com.phonedsh.engine

import org.json.JSONException
import org.json.JSONObject

/**
 * The host's GitHub agent decision (P16 / P18).
 *
 * Mirror of the Swift `GitHubAgentConfiguration` facts that reach the Worker:
 * `enabled` is false for a host/test without the feature, `tokenAvailable` is
 * the stored-token fact, and `allowWrites` is the person's separate opt-in.
 */
data class GitHubAgentEnvironment(
    val enabled: Boolean = false,
    val tokenAvailable: Boolean = false,
    val allowWrites: Boolean = false,
) {
    companion object {
        /** A host that never reads the GitHub secret record (tests, embedded hosts). */
        val disabled: GitHubAgentEnvironment = GitHubAgentEnvironment()
    }
}

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
     * `1` when the host holds a GitHub agent token. The Worker's `github`
     * command uses it for authenticated reads and code search; the token itself
     * never enters the Worker environment.
     *
     * Same name and value rule as the Swift P16 owner
     * (`Sources/PhoneDSH/PhoneDSH.swift`, `PhoneDSHWorkerEnvironment.githubAuth`).
     */
    const val GITHUB_AUTH: String = "PDSH_GITHUB_AUTH"

    /**
     * `1` only when the host holds a GitHub agent token and the person enabled
     * writes. [GITHUB_AUTH] can still be `1` for authenticated reads.
     */
    const val GITHUB_WRITE: String = "PDSH_GITHUB_WRITE"

    /**
     * The host's GitHub agent decision, read once per page load by
     * [pageParam]. A host installs a live source through [installGitHubAgent]
     * so a token saved from Settings applies on the next engine restart.
     */
    @Volatile
    private var githubAgentSource: () -> GitHubAgentEnvironment = { GitHubAgentEnvironment.disabled }

    /**
     * Binds the live GitHub agent facts. The source is read on every
     * [pageParam] call, never cached: an engine restart reloads the page and
     * the new decision must be the one the store holds at that moment.
     */
    fun installGitHubAgent(source: () -> GitHubAgentEnvironment) {
        githubAgentSource = source
    }

    /**
     * `1` only when a token exists. The decision is host-owned, so an
     * environment override cannot make the Worker believe it has a credential
     * the host cannot inject.
     */
    fun githubAuthEnvironmentValue(agent: GitHubAgentEnvironment): String =
        if (agent.enabled && agent.tokenAvailable) "1" else "0"

    /**
     * `1` only when a token exists and the person enabled writes. This is the
     * fact behind [GITHUB_WRITE]; a token alone is not enough.
     */
    fun githubWriteEnvironmentValue(agent: GitHubAgentEnvironment): String =
        if (agent.enabled && agent.tokenAvailable && agent.allowWrites) "1" else "0"

    /**
     * The JSON object string for `?env=`.
     *
     * Shape: `{"PDSH_DSH_LAUNCH_TOKEN":"<per-start token>"}` plus every entry of
     * [hostSupplied] when the host passed a `pageParams["env"]` object. When the
     * call also names [modelBaseUrl] (a mounted model proxy's loopback origin),
     * that one key is overwritten; every other host entry — `DEEPSEEK_API_KEY`'s
     * placeholder, `PDSH_MODEL_KEY_STATE`, ... — is kept byte for byte.
     * [GITHUB_AUTH] and [GITHUB_WRITE] are always overwritten from
     * [githubAgent] (or the installed live source), so a host-supplied "1"
     * cannot forge a credential the host does not have.
     *
     * [botMcpUrl] is the Bot listener URL. It wins over a legacy [phoneMcpUrl]
     * and writes [BOT_MCP_TOKEN_PLACEHOLDER] into [PHONE_MCP_TOKEN]; the real
     * Bot bearer never enters this page parameter. [mcpEgressToken] is
     * host-start state and is never taken from [hostSupplied]: a stale value in
     * the map is removed, then the current value is written when supplied.
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
        githubAgent: GitHubAgentEnvironment? = null,
        botMcpUrl: String? = null,
        mcpEgressToken: String? = null,
    ): String {
        val env = parseObject(hostSupplied)
        val resolvedGitHubAgent = githubAgent ?: githubAgentSource()
        if (modelBaseUrl != null) env.put(MODEL_BASE_URL, modelBaseUrl)
        // P16: the egress credential is host-start state, never a host-supplied
        // environment value. Removing it first means a stale `?env=` object
        // cannot keep an old token alive after the host rotated it.
        env.remove(MCP_EGRESS_TOKEN)
        if (mcpEgressToken != null) env.put(MCP_EGRESS_TOKEN, mcpEgressToken)
        // mcp-endpoint.md §1: a Bot listener is the Worker's only `phone`
        // server. The Worker sees the listener URL and a non-secret placeholder
        // token; the real bearer is injected by the host at `/v1/http` egress.
        if (botMcpUrl != null) {
            env.put(PHONE_MCP_URL, botMcpUrl)
            env.put(PHONE_MCP_TOKEN, BOT_MCP_TOKEN_PLACEHOLDER)
        } else if (phoneMcpUrl != null) {
            // native-mcp.md: with a mounted `/mcp/native` the host points the official
            // `mcp-phone` plugin at it (iOS `PhoneDSHHost.swift`, same two keys). The
            // token is this start's loopback token, i.e. the launch token.
            env.put(PHONE_MCP_URL, phoneMcpUrl)
            env.put(PHONE_MCP_TOKEN, launchToken)
        }
        env.put(LAUNCH_TOKEN, launchToken)
        // The host owns these two values. Writing them last is the P16 rule:
        // an App environment override cannot forge "1".
        env.put(GITHUB_AUTH, githubAuthEnvironmentValue(resolvedGitHubAgent))
        env.put(GITHUB_WRITE, githubWriteEnvironmentValue(resolvedGitHubAgent))
        return env.toString()
    }

    /** `plugins/profile/phone.worker.cordis.patch.yml`: the app MCP endpoint (optional). */
    const val PHONE_MCP_URL: String = "PDSH_PHONE_MCP_URL"

    /**
     * Bearer for [PHONE_MCP_URL]. A native-only start gets the per-start
     * loopback token; a Bot-configured start gets the non-secret
     * [BOT_MCP_TOKEN_PLACEHOLDER] and the host injects the real bearer at egress.
     */
    const val PHONE_MCP_TOKEN: String = "PDSH_PHONE_MCP_TOKEN"

    /**
     * The non-secret placeholder a Bot-configured Worker sees in
     * `PDSH_PHONE_MCP_TOKEN` (mcp-endpoint.md §1.1). It is never the Bot
     * bearer; the host replaces it at `/v1/http` egress.
     */
    const val BOT_MCP_TOKEN_PLACEHOLDER: String = "phone-host-injects-bot-mcp-token"

    /**
     * The per-host-start trusted-MCP egress credential (P16 / mcp-endpoint.md
     * §1.1). The Worker sends it as `X-PDSH-MCP-Egress`; the host validates and
     * strips it before resolving the real Bot/connector credential. It never
     * enters a persisted document or a log.
     */
    const val MCP_EGRESS_TOKEN: String = "PDSH_MCP_EGRESS_TOKEN"

    private fun parseObject(raw: String?): JSONObject {
        if (raw.isNullOrBlank()) return JSONObject()
        return try {
            JSONObject(raw)
        } catch (invalid: JSONException) {
            throw IllegalArgumentException("pageParams[\"env\"] must be a JSON object", invalid)
        }
    }
}
