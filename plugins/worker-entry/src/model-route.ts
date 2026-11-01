// SPDX-License-Identifier: MIT
/**
 * The host's model-route declaration and the Worker's refusal to fall back (P27).
 *
 * ---- why this module exists ------------------------------------------------
 * The Worker never holds a model credential (`gateway-security.md` §2): the
 * host publishes `DEEPSEEK_API_KEY=phone-host-injects-mcp-key` (a placeholder)
 * and hands the real key to its own model edge, one request at a time. The
 * pinned `llm-deepseek` resolver, however, treats a missing endpoint as a
 * *known* one:
 *
 *   `config.baseURL ?? launchEnvironment.get('DEEPSEEK_BASE_URL') ?? PUBLIC_BASE_URL`
 *   (`packages/llm/llm-deepseek/src/config.ts:300`; `PUBLIC_BASE_URL` is
 *   `https://api.deepseek.com/anthropic` at :115)
 *
 * A launch that mounted no host edge therefore sent the placeholder to
 * api.deepseek.com, produced real external traffic and received a 401 whose
 * message blames the key — while the missing fact was the **endpoint**
 * (measured 2026-11-01, P25 receipt). A device that was never configured must
 * not send packets to a third party, and the error must name the configuration
 * gap. Both are this module's job.
 *
 * ---- who declares what ----------------------------------------------------
 * The composition root publishes `PDSH_MODEL_ROUTE` (one of
 * `host-edge` / `direct` / `none`, see `:dsh`'s `ModelRouteFact`), plus
 * `PDSH_MODEL_ROUTE_MISSING` with a missing-input code when the route is
 * `none`. The host is the only side that knows which input was missing, so it
 * publishes a code and this module owns the refusal's wording.
 *
 * `none` means: no host edge was mounted, so a model request can only reach
 * either a direct endpoint the host did not name (there is none) or the pinned
 * public fallback, and the credential available to the Worker cannot
 * authenticate to either. The Worker refuses the request **before the
 * network**: `globalThis.fetch` is wrapped and a model-protocol request gets a
 * local `400` whose message names the missing input. No socket is opened, so
 * "zero external traffic" is a structural property, not a log-inspection one.
 *
 * An **absent** declaration is not `none`: a Worker booted by a host that does
 * not declare a route keeps the pinned behaviour unchanged. A host cannot get
 * the refusal by omission. Only an explicit declaration can arm it, and an
 * unknown value (version skew) is reported as such and never guessed at.
 *
 * @module @phone-dsh/dsh-worker-entry/model-route
 */

/** The Worker environment member a host uses to declare this launch's route. */
export const MODEL_ROUTE_ENV = 'PDSH_MODEL_ROUTE'

/** The Worker environment member naming the missing input when the route is `none`. */
export const MODEL_ROUTE_MISSING_ENV = 'PDSH_MODEL_ROUTE_MISSING'

/** The key-state member the host publishes (`configured` / `absent` / `invalid`). */
export const MODEL_KEY_STATE_ENV = 'PDSH_MODEL_KEY_STATE'

/** The endpoint member: present only when a host edge is mounted or a base was named. */
export const MODEL_BASE_URL_ENV = 'DEEPSEEK_BASE_URL'

/** The routes this Worker understands. */
export type ModelRouteValue = 'host-edge' | 'direct' | 'none'

/** The missing-input codes the host may publish, and the sentence each becomes. */
const MISSING_SENTENCES: Readonly<Record<string, string>> = {
  'base-url': 'pdsh.deepseek.baseUrl was not supplied',
  'api-key-store': 'the device key store is not installed',
}

/** The route member's value when the host reported no route but no reason either. */
const UNKNOWN_MISSING = 'the host reported no model route without naming the missing input'

/**
 * What this boot read from the host, and the one line it implies.
 *
 * `refusal` is the message a refused model request carries; `undefined` means
 * the guard is not armed at all (a declared route, an undeclared route, or an
 * unknown value). `notice` is the single boot-time line to log, if any.
 */
export interface ModelRouteDecision {
  /** The raw `PDSH_MODEL_ROUTE` value, or `undefined` when the host declared none. */
  readonly declared: string | undefined
  /** The raw `PDSH_MODEL_ROUTE_MISSING` value, when one was published. */
  readonly missing: string | undefined
  /** The refusal message, or `undefined` when model requests are not refused. */
  readonly refusal: string | undefined
  /** One boot line recording the declaration, or `undefined` when there is nothing to say. */
  readonly notice: string | undefined
}

/**
 * Compose the refusal for a launch whose host declared no route.
 * @param missing - the raw `PDSH_MODEL_ROUTE_MISSING` value.
 * @param keyState - the raw `PDSH_MODEL_KEY_STATE` value, if published.
 * @returns one bounded sentence naming the missing input and the guarantee.
 */
export function modelRouteRefusal(missing: string | undefined, keyState: string | undefined): string {
  const gap = missing === undefined ? UNKNOWN_MISSING : MISSING_SENTENCES[missing] ?? UNKNOWN_MISSING
  const credential = keyState === 'configured'
    // The reader's first instinct is "the key is wrong". Say which fact is missing
    // so the error does not send them there (the P25/P27 diagnosis).
    ? ` ${MODEL_KEY_STATE_ENV}=configured: the missing fact is the endpoint, not the credential.`
    : keyState === undefined || keyState === ''
      ? ''
      : ` ${MODEL_KEY_STATE_ENV}=${keyState}.`
  return `pdsh: no model route for this launch: ${gap}. The host mounted no model edge, so the Worker `
    + 'refuses this model request instead of letting llm-deepseek fall back to its public base with the '
    + `non-secret placeholder credential. No request was sent and no credential left the device.${credential}`
}

/**
 * Read the host's declaration.
 *
 * Three outcomes, kept apart on purpose:
 * - `none` — the refusal is armed and the boot line says so;
 * - `host-edge` / `direct` — no refusal, no line (a healthy launch says nothing);
 * - absent or unknown — no refusal (no host may be refused by omission, and an
 *   unknown future value is version skew, not a fourth route) and, for an
 *   unknown value, one warning that names the value.
 * @param env - the Worker environment from the page's init frame.
 * @returns what this boot may refuse and what it should say.
 */
export function modelRouteOf(env: Readonly<Record<string, string>> | undefined): ModelRouteDecision {
  const declared = env?.[MODEL_ROUTE_ENV]
  const missing = env?.[MODEL_ROUTE_MISSING_ENV]
  if (declared === 'none') {
    const refusal = modelRouteRefusal(missing, env?.[MODEL_KEY_STATE_ENV])
    return { declared, missing, refusal, notice: refusal }
  }
  if (declared === undefined || declared === '' || declared === 'host-edge' || declared === 'direct') {
    return { declared, missing, refusal: undefined, notice: undefined }
  }
  return {
    declared,
    missing,
    refusal: undefined,
    notice: `pdsh: ignoring unknown ${MODEL_ROUTE_ENV}=${JSON.stringify(declared)}; `
      + 'only host-edge, direct and none are understood, so model requests are not refused',
  }
}

/**
 * True for a DeepSeek Messages-protocol request.
 *
 * The pinned transport addresses the model endpoint at
 * `${messagesApiRoot(baseURL)}/messages` and the Files API at
 * `${messagesApiRoot(baseURL)}/files...`, and `messagesApiRoot` always ends in
 * `/v1` (`packages/llm/llm-deepseek/src/messages-api.ts:14-17`). Matching the
 * protocol path — not one hard-coded host — is what makes this independent of
 * which base URL a future default names.
 * @param url - the request URL.
 * @returns true when the request is the Messages protocol or its Files API.
 */
export function isModelProtocolRequest(url: string): boolean {
  let pathname: string
  try {
    pathname = new URL(url).pathname
  } catch {
    return false
  }
  return /(?:^|\/)v1\/(?:messages|files)(?:\/|$)/u.test(pathname)
}

/** The options of {@link installModelRouteGuard}. */
export interface ModelRouteGuardOptions {
  /** What the host declared, from {@link modelRouteOf}. */
  readonly decision: ModelRouteDecision
  /** The transport a refused request must never reach; tests pass a tripwire. */
  readonly fetchImpl?: typeof fetch
  /** The object whose `fetch` is wrapped; defaults to `globalThis`. */
  readonly target?: { fetch?: typeof fetch }
}

/** The local response a refused model request gets, shaped as a provider error. */
function refusalResponse(message: string): Response {
  // The pinned adapter reads a non-2xx body as `{error:{type, message}}` and
  // raises `INVALID_REQUEST` with that message. Shaping the refusal like a
  // provider error keeps the failure on DSH's ordinary path — the message
  // reaches the turn's log line instead of becoming an unhandled exception —
  // and `invalid_request_error` is not retryable, so nothing re-attempts it.
  return new Response(
    JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message } }),
    {
      status: 400,
      statusText: 'Model route missing',
      headers: { 'content-type': 'application/json', 'x-pdsh-model-route': 'none' },
    },
  )
}

/** The URL of a fetch input, or `undefined` when it cannot be read. */
function requestUrl(input: RequestInfo | URL): string | undefined {
  if (typeof input === 'string') return input
  if (typeof input === 'object' && input !== null && 'href' in input && typeof input.href === 'string') {
    return input.href
  }
  const url = (input as { url?: unknown }).url
  return typeof url === 'string' ? url : undefined
}

/**
 * Arm the refusal on the process-wide transport.
 *
 * Returns a disposer when a guard was installed, and a no-op disposer when the
 * decision does not refuse anything (so a launch with a route behaves exactly
 * as before, including the identity of `globalThis.fetch`).
 *
 * Install it **after** the tree booted: `llm-bridge` may replace
 * `globalThis.fetch` with its own transport while the plugins activate, and a
 * guard installed before it would wrap the transport that is about to be
 * replaced. This wrapper forwards to whatever fetch is current when it is
 * called, so a later replacement is only visible if it happens after this
 * install — which is why the caller installs it last.
 *
 * @param options - the decision, the transport to guard, and the object to patch.
 * @returns the disposer that restores the previous transport.
 */
export function installModelRouteGuard(options: ModelRouteGuardOptions): () => void {
  const message = options.decision.refusal
  if (message === undefined) return () => {}
  const target = options.target ?? globalThis as { fetch?: typeof fetch }
  const previous = options.fetchImpl ?? target.fetch
  if (typeof previous !== 'function') return () => {}
  const guarded = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = requestUrl(input)
    if (url !== undefined && isModelProtocolRequest(url)) {
      // The one line that makes the refusal visible in a logcat capture even if
      // the turn's error projection drops the provider message.
      console.warn(message)
      return refusalResponse(message)
    }
    return await previous(input, init)
  }) as typeof fetch
  target.fetch = guarded
  return () => {
    if (target.fetch === guarded) target.fetch = previous
  }
}
