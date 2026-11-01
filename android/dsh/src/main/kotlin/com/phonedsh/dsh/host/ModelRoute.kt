// phone-dsh — :dsh / com.phonedsh.dsh.host: the model route a launch can offer (P27).
// SPDX-License-Identifier: MIT
//
// ---- the fact this file makes publishable --------------------------------
// The Worker env is where this host publishes the facts a worker cannot observe
// for itself; `PDSH_SINGLE_FILE_LIMIT_BYTES` (HostBudgetTier) is the other one.
// This file publishes the **model route**: whether this launch mounted a host
// model edge, talks to the launch's endpoint directly, or has no route at all.
//
// Until it existed, "no route" was not a value anybody published. The Worker
// env carried the key *state* (`PDSH_MODEL_KEY_STATE`, P25) and the placeholder
// credential (`DEEPSEEK_API_KEY=phone-host-injects-mcp-key`) but no endpoint —
// and `DEEPSEEK_BASE_URL` absent at that layer is indistinguishable, from the
// Worker's side, from "the engine has not rewritten it yet", because a mounted
// edge omits the member too and the engine fills it in at page-load time
// (`WorkerEnvironment.pageParam`). The single ambiguous absence was therefore
// folded by the pinned `llm-deepseek` resolver into a **known** endpoint:
// `config.baseURL ?? environment.get('DEEPSEEK_BASE_URL') ?? PUBLIC_BASE_URL`
// (`packages/llm/llm-deepseek/src/config.ts:300`, `PUBLIC_BASE_URL` at :115).
// A launch with no `pdsh.deepseek.baseUrl` then sent the placeholder to
// `https://api.deepseek.com/anthropic`, produced real external traffic and got
// a 401 whose message blamed the key. Measured 2026-11-01 (P25 receipt).
//
// ---- what the three values mean ------------------------------------------
// `host-edge`  the composition root mounted `LoopbackModelProxy`; the engine
//              rewrites `DEEPSEEK_BASE_URL` to the loopback origin, the host
//              injects the real credential at that edge, and a broken key is a
//              fail-closed `502 credential_unavailable` from the edge. This is
//              the only route on which model traffic may reach a provider.
// `direct`     the launch itself asked for no edge (`pdsh.model.proxy=false`).
//              The Worker talks to the launch's base URL directly. The
//              acceptance lane uses this to point at a scripted upstream
//              without letting a production credential near a test fixture.
// `none`       no route: the launch named no base URL, or the host could not
//              build an edge for it. Only DSH's public fallback remains — a
//              request that cannot authenticate (the Worker holds a
//              placeholder, never a key) and that must not be sent.
//
// ---- why `none` is published instead of being left to the Worker ---------
// The Worker could guess from `DEEPSEEK_BASE_URL` being absent, but that is
// exactly the ambiguous fact this file removes: "the edge will rewrite it" and
// "nothing named an endpoint" are different facts and get different members.
// The host publishes the route; the Worker refuses on `none` (see
// `plugins/worker-entry/src/model-route.ts`). Neither side guesses.
//
// The three values are a closed set: an unknown value is version skew, not a
// fourth route, and consumers must not invent a meaning for it.

package com.phonedsh.dsh.host

/** The model route this launch can offer the Worker. */
public enum class ModelRoute(public val wire: String) {
    /** A host model edge is mounted; the engine points `DEEPSEEK_BASE_URL` at it. */
    HOST_EDGE("host-edge"),

    /** The launch asked for no edge and named an endpoint: the Worker talks to it directly. */
    DIRECT("direct"),

    /** No route: model requests can only fail, so the Worker refuses them locally. */
    NONE("none"),
}

/**
 * The configuration whose absence left a launch with [ModelRoute.NONE].
 *
 * The code travels in the Worker env (so the Worker can name the same fact in
 * its refusal) and [sentence] is the App's own wording of it. Two renderings of
 * one code, not two diagnoses: only the composition root knows which input was
 * missing, and it is not re-derived anywhere else.
 */
public enum class ModelRouteMissing(
    public val wire: String,
    public val sentence: String,
) {
    /** The launch supplied no `pdsh.deepseek.baseUrl`, so no edge could be addressed. */
    BASE_URL("base-url", "pdsh.deepseek.baseUrl was not supplied"),

    /**
     * The launch named an endpoint but this process installed no device key
     * store (`ApiKeyStore`), so there was no credential to inject at an edge.
     * Without an edge the Worker would send the placeholder to the provider.
     */
    API_KEY_STORE("api-key-store", "the device key store is not installed"),
}

/**
 * Whether this launch has a model route, and if not, which input was missing.
 *
 * Immutable and pure: it carries no endpoint and no credential, so it is safe
 * to log, to put in the Worker env and to show on a page.
 */
public data class ModelRouteFact(
    public val route: ModelRoute,
    public val missing: ModelRouteMissing? = null,
) {
    init {
        require((route == ModelRoute.NONE) == (missing != null)) {
            "a model route fact names why it is none exactly when it is none (route=$route, missing=$missing)"
        }
    }

    /** `true` when model requests may leave the Worker toward the launch's endpoint. */
    public val routable: Boolean get() = route != ModelRoute.NONE

    /**
     * The Worker environment entries this fact publishes.
     *
     * `PDSH_MODEL_ROUTE` is always present: an omitted member would be the same
     * ambiguity this file exists to remove. `PDSH_MODEL_ROUTE_MISSING` is
     * present exactly when the route is `none`, and holds a [ModelRouteMissing.wire]
     * code — the Worker composes the sentence, so the host never ships prose into
     * a protocol field.
     */
    public fun workerEnvironment(): Map<String, String> {
        val env = linkedMapOf(ENV to route.wire)
        missing?.let { env[MISSING_ENV] = it.wire }
        return env
    }

    /**
     * The App's one sentence about a failed turn on a routeless launch.
     *
     * `null` when a route exists: a failed turn then has some other cause and
     * this fact says nothing about it. A non-null sentence is a fact about the
     * **launch**, not a claim about the failure, and it never says the key is
     * wrong — the missing fact is the endpoint. It is bounded because the App
     * stamps it onto a one-line failure (`ProbeEngineViewModel.failTurn` keeps
     * the first 240 characters).
     */
    public fun diagnosis(): String? {
        val missing = missing ?: return null
        return "no model route (${missing.sentence}); the Worker refused the model request locally, " +
            "so no request was sent"
    }

    public companion object {
        /**
         * The Worker environment member naming the route
         * (`plugins/worker-entry/src/model-route.ts`, `MODEL_ROUTE_ENV`).
         *
         * The Worker refuses a model-protocol request unless this member names a
         * route it can use; an unknown value is version skew and is reported, never
         * guessed at.
         */
        public const val ENV: String = "PDSH_MODEL_ROUTE"

        /** The Worker environment member naming the missing configuration, when there is no route. */
        public const val MISSING_ENV: String = "PDSH_MODEL_ROUTE_MISSING"

        /**
         * The route of one launch, from the three inputs the composition root has.
         *
         * @param baseUrl the launch's `pdsh.deepseek.baseUrl`, or `null` when it
         *   named none (or named one that was not an `http(s)` URL).
         * @param proxyRequested `pdsh.model.proxy` (default `true`). `false` is the
         *   scripted/diagnostic escape hatch: no edge, and the endpoint is used as
         *   given.
         * @param credentialAvailable this process installed a key store and the
         *   launch named an endpoint, so [credentialAvailable] means an edge could
         *   actually inject a credential.
         *
         * `none` covers both "no endpoint" and "an endpoint but no edge": they
         * differ only in [missing], and both leave the Worker holding a
         * placeholder it cannot authenticate with.
         */
        public fun forLaunch(
            baseUrl: String?,
            proxyRequested: Boolean,
            credentialAvailable: Boolean,
        ): ModelRouteFact = when {
            baseUrl == null -> ModelRouteFact(ModelRoute.NONE, ModelRouteMissing.BASE_URL)
            !proxyRequested -> ModelRouteFact(ModelRoute.DIRECT)
            !credentialAvailable -> ModelRouteFact(ModelRoute.NONE, ModelRouteMissing.API_KEY_STORE)
            else -> ModelRouteFact(ModelRoute.HOST_EDGE)
        }
    }
}
