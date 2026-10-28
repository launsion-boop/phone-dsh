// SPDX-License-Identifier: MIT
/**
 * Process-wide installation of the node:http fetch. DSH treats outbound HTTP
 * transport as a per-process fact (its own proxy support installs undici's
 * global dispatcher before any plugin mounts, covering model adapters, web
 * tools, MCP over HTTP and telemetry); this module swaps the transport at the
 * same level, so every fetch consumer works under `--jitless` unchanged.
 *
 * The transport is installed even when WebAssembly exists: in the phone Worker
 * the browser's WebAssembly is present, but no `node:http` client exists, so
 * external requests must go through the host loopback `POST /v1/http` with
 * the Worker's own fetch. `nativeFetchUsable` is retained as a diagnostic.
 *
 * `node:http` transport is loaded lazily: the Worker path never evaluates the
 * node:https client, so the runtime module table does not need a usable
 * `node:https` module and no `https.Agent` is constructed there. The desktop
 * implementation only resolves when a request actually needs it.
 *
 * The Worker host route is found from the environment the entry sets before
 * DSH boots: `PDSH_CHANNEL_TOKEN` (bearer) and `PDSH_CHANNEL_URL` /
 * `PDSH_CHANNEL_ORIGIN` (loopback origin), with the desktop names as fallbacks.
 * @module @phone-dsh/dsh-llm-bridge/install
 */

import type { HostProxyOptions, NodeFetchOptions } from './node-fetch.ts'
import { LlmError } from '@deepseek-ai/dsh-llm'

/** Marks a globalThis.fetch installed by this module. */
export const NODE_FETCH_MARK = Symbol.for('phone-dsh.dsh.node-fetch')

/**
 * Default inactivity interval for a host-route response, in milliseconds.
 *
 * The interval covers the wait for the response head and, once the stream is
 * open, the wait for the next body chunk. It is deliberately shorter than the
 * model adapter's own stream idle watchdog: a delivery stall (the response was
 * received by the host gateway but never reaches the Worker) must fail the
 * request with a typed error instead of silently consuming the turn budget.
 */
export const DEFAULT_DELIVERY_IDLE_TIMEOUT_MS = 60_000

/** Worker → host header asking for the suffix of a previously delivered body. */
export const RESUME_FROM_HEADER = 'x-pdsh-resume-from'
/** Host → Worker header marking a response served from the host response log. */
export const RESUMED_HEADER = 'x-pdsh-resumed'
/** Bounded host-route body resumes after the inactivity interval elapses. */
export const MAX_DELIVERY_RESUMES = 1
/**
 * Head/inactivity bound for a resume attempt, in milliseconds.
 *
 * A resume may reach the host before the original recording has committed
 * (the consumer aborted first); the host waits for the commit instead of
 * re-contacting the upstream, so the resume head can take longer than the
 * normal delivery inactivity interval. Bounded so the request still fails loud
 * when the host cannot serve the resume at all.
 */
export const RESUME_TIMEOUT_MS = 30_000

/** Per-process delivery instrumentation (the Worker side of the three legs). */
export interface DeliveryMetricsSnapshot {
  /** Host-route responses whose head arrived. */
  readonly attempts: number
  /** Body bytes delivered to the model client. */
  readonly bodyBytes: number
  /** Inactivity intervals that expired on an open body. */
  readonly stalls: number
  /** Resumes issued after a stalled body. */
  readonly resumes: number
  /** Body bytes that arrived through a resumed response. */
  readonly resumedBytes: number
}

const deliveryMetrics = { attempts: 0, bodyBytes: 0, stalls: 0, resumes: 0, resumedBytes: 0 }

/** Snapshot of the Worker delivery counters. */
export function deliveryMetricsSnapshot(): DeliveryMetricsSnapshot {
  return { ...deliveryMetrics }
}

/**
 * A host-route model response stalled before its head or between body chunks.
 *
 * Extends DSH's provider-neutral `LlmError` so the adapter's own error path
 * rethrows it unchanged (`error instanceof LlmError`) instead of classifying
 * it as a transport failure. The stable code is not one of the default
 * retryable codes (`EMPTY_RESPONSE`, `RATE_LIMIT`, `SERVER`, `TIMEOUT`,
 * `TRANSPORT`): a frozen delivery leg repeats identically on every attempt, so
 * retrying would only burn the turn budget. The typed failure ends the model
 * request and reaches the session as an error event.
 */
export class DeliveryTimeoutError extends LlmError {
  /** Which leg of the delivery stalled. */
  readonly stage: 'head' | 'body'
  /** The inactivity interval that elapsed, in milliseconds. */
  readonly timeoutMs: number

  constructor(stage: 'head' | 'body', timeoutMs: number) {
    super(`llm-bridge: model response ${stage === 'head' ? 'headers' : 'body'} `
      + `delivery stalled for ${timeoutMs} ms (PDSH_DELIVERY_TIMEOUT)`, 'PDSH_DELIVERY_TIMEOUT')
    this.stage = stage
    this.timeoutMs = timeoutMs
  }
}

function resolveDeliveryIdleTimeout(explicit: number | undefined): number {
  const configured = explicit
    ?? Number((globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env?.PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS ?? '')
  if (Number.isFinite(configured) && configured > 0) return Math.trunc(configured)
  return DEFAULT_DELIVERY_IDLE_TIMEOUT_MS
}

const TOOL_CALL_CONTEXT_KEY = Symbol.for('phone-dsh.dsh.tool-call-context')

const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308])
const REDIRECT_STRIPPED = ['content-type', 'content-length', 'content-encoding', 'content-language', 'content-location']
/**
 * Final fetch null-body statuses (the Fetch standard also lists `101`/`103`,
 * which cannot be the final `Response` of a fetch): a `Response` for one of
 * these cannot carry a body. The host route re-wraps a streamed response for
 * resumable delivery; passing a body for `204`/`205`/`304` to the `Response`
 * constructor throws "Response cannot have a body with the given status." in
 * WebKit. A compliant MCP notification reply is exactly a 204, so the wrapper
 * must keep the null body instead of reconstructing one.
 */
const NULL_BODY_STATUS = new Set([204, 205, 304])

export type InstallMode = 'auto' | 'always' | 'never'

export interface InstallOptions {
  /** `auto` installs whenever the phone transport is needed; `never` keeps Node's fetch. */
  mode?: InstallMode
  /** Route matching requests through the host app's HTTP stack; defaults to the Worker route when detected. */
  proxy?: HostProxyOptions | undefined
  /** A fetch implementation for the host route; defaults to the pre-install global fetch. */
  proxyFetch?: typeof fetch | undefined
  /** Hosts that receive `X-PDSH-Idempotency-Key` inside a tool call; loopback and host-proxied requests always do. */
  idempotencyHosts?: readonly string[]
  /** Host-route response inactivity interval; defaults to `PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS` or 60 s. */
  deliveryIdleTimeoutMs?: number
}

/** Whether Node's own fetch can work in this process (WebAssembly present). Diagnostic only. */
export function nativeFetchUsable(): boolean {
  return typeof (globalThis as { WebAssembly?: unknown }).WebAssembly !== 'undefined'
}

/** True when this process is the phone Worker (ordered channel installed or its token present). */
export function workerRuntime(): boolean {
  if (typeof globalThis.__PDSH_CHANNEL__ !== 'undefined') return true
  return typeof process.env.PDSH_CHANNEL_TOKEN === 'string' && process.env.PDSH_CHANNEL_TOKEN !== ''
}

/** The implicit Worker host route: `/v1/http` on the loopback origin, bearer from the environment. */
export function defaultHostProxy(): HostProxyOptions | undefined {
  const token = process.env.PDSH_CHANNEL_TOKEN ?? process.env.PDSH_EXEC_BRIDGE_TOKEN
  if (token === undefined || token === '') return undefined
  const origin = globalThis.location?.origin
  const url = process.env.PDSH_CHANNEL_ORIGIN
    ?? process.env.PDSH_EXEC_BRIDGE_URL
    ?? (origin !== undefined && (origin.startsWith('http://') || origin.startsWith('https://')) ? origin : undefined)
    ?? httpOriginFromChannelUrl(process.env.PDSH_CHANNEL_URL)
  if (url === undefined || url === '') return undefined
  return { url, token }
}

interface ToolCallStore { getStore(): { key: string } | undefined }

/**
 * Install the node:http fetch as `globalThis.fetch`.
 * @param options - install mode, host proxy route, and idempotency-header hosts.
 * @returns a restore function (a no-op when nothing was installed).
 */
export function installNodeFetch(options: InstallOptions = {}): () => void {
  const mode = options.mode ?? 'auto'
  if (mode === 'never') return () => {}
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
  const previousFetch = typeof globalThis.fetch === 'function' ? globalThis.fetch : undefined
  const worker = workerRuntime()
  const explicit = options.proxy
  const proxy = explicit ?? (worker ? defaultHostProxy() : undefined)
  // In the Worker even a loopback URL has no node:http client: every request is
  // carried by the page's same-origin fetch to the host /v1/http route.
  const routed = proxy !== undefined && explicit === undefined && worker ? { ...proxy, match: () => true } : proxy
  if (!worker && mode === 'auto' && routed === undefined && nativeFetchUsable()) return () => {}
  const hosts = new Set(options.idempotencyHosts ?? [])
  const extraHeaders = (url: URL, viaProxy: boolean): Record<string, string> | undefined => {
    const store = (globalThis as { [TOOL_CALL_CONTEXT_KEY]?: ToolCallStore })[TOOL_CALL_CONTEXT_KEY]?.getStore()
    if (store === undefined) return undefined
    if (!viaProxy && !isLoopback(url) && !hosts.has(url.hostname)) return undefined
    return { 'x-pdsh-idempotency-key': store.key }
  }
  const proxyFetch = options.proxyFetch
    ?? (worker && routed !== undefined && previousFetch !== undefined ? previousFetch.bind(globalThis) : undefined)
  let implementation: typeof fetch
  if (routed !== undefined && proxyFetch !== undefined) {
    // The Worker's own fetch carries the loopback /v1/http request. URLs the
    // explicit match keeps local stay on the platform fetch in the Worker; only
    // a desktop process falls back to the node:http implementation.
    const fallback = worker ? previousFetch ?? unavailableFetch() : lazyNodeFetch({ proxy: routed, extraHeaders })
    implementation = hostRouteFetch(routed, proxyFetch, extraHeaders, fallback,
      resolveDeliveryIdleTimeout(options.deliveryIdleTimeoutMs))
  } else if (worker) {
    // No node:http client exists in the Worker. Without a host route there is
    // nothing to install, so keep the platform fetch untouched.
    return () => {}
  } else {
    implementation = lazyNodeFetch({ proxy: routed, extraHeaders })
  }
  Object.defineProperty(implementation, NODE_FETCH_MARK, { value: true })
  Object.defineProperty(globalThis, 'fetch', { value: implementation, writable: true, configurable: true, enumerable: true })
  return () => {
    if (globalThis.fetch !== implementation) return
    if (previous === undefined) Reflect.deleteProperty(globalThis, 'fetch')
    else Object.defineProperty(globalThis, 'fetch', previous)
  }
}

/** True when the current globalThis.fetch is this module's transport. */
export function nodeFetchInstalled(): boolean {
  return (globalThis.fetch as unknown as Record<symbol, unknown> | undefined)?.[NODE_FETCH_MARK] === true
}

/** True for a loopback host name (kept local so install.ts does not load node:http eagerly). */
function isLoopback(url: URL): boolean {
  return url.hostname === '127.0.0.1' || url.hostname === '[::1]' || url.hostname === '::1' || url.hostname === 'localhost'
}

/**
 * The desktop node:http transport, loaded on first use. Keeping the dynamic
 * import here is what removes `node:https` from the Worker's module graph: the
 * Worker branch above never calls this function.
 */
function lazyNodeFetch(options: NodeFetchOptions): typeof fetch {
  let pending: Promise<typeof fetch> | undefined
  const load = (): Promise<typeof fetch> => {
    pending ??= import('./node-fetch.ts').then(module => module.createNodeFetch(options))
    return pending
  }
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const implementation = await load()
    return await implementation(input, init)
  }) as typeof fetch
}

/** A fetch that reports the Worker routing hole instead of silently opening a socket. */
function unavailableFetch(): typeof fetch {
  return (async (): Promise<Response> => {
    throw new Error('llm-bridge: this request is not covered by the host /v1/http route and the Worker has no node:http client')
  }) as typeof fetch
}

/**
 * Carry matching requests through the host `/v1/http` route with an underlying
 * fetch (the Worker's own, which needs no WebAssembly), falling back to the
 * node:http transport for everything else.
 */
function hostRouteFetch(
  proxy: HostProxyOptions,
  underlying: typeof fetch,
  extraHeaders: (url: URL, viaProxy: boolean) => Record<string, string> | undefined,
  fallback: typeof fetch,
  deliveryIdleTimeoutMs: number,
): typeof fetch {
  const proxyUrl = new URL('/v1/http', proxy.url)
  if (proxyUrl.protocol !== 'http:' || !isLoopback(proxyUrl)) {
    throw new Error('llm-bridge: the host proxy must be the loopback exec bridge (http://127.0.0.1:<port>)')
  }
  const matches = proxy.match ?? (() => true)
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    const signal = request.signal
    let url = new URL(request.url)
    // A request already addressed to the host route (the Worker `curl` shim
    // and any other caller that speaks the /v1/http protocol itself) carries
    // its own bearer and `X-PDSH-Target-*` headers. Re-routing it would move
    // that bearer into `x-pdsh-upstream-authorization` and point the host at
    // its own loopback, which the host then answers with 401 "missing token"
    // (or 403 when the loopback is not on the egress allow-list). Hand it to
    // the platform fetch untouched.
    if (url.origin === proxyUrl.origin && url.pathname === proxyUrl.pathname) {
      return await underlying(input, init)
    }
    if (!matches(url)) return await fallback(input, init)
    let method = request.method
    const headers = new Headers(request.headers)
    let body: Uint8Array | undefined = request.body === null ? undefined : new Uint8Array(await request.arrayBuffer())

    // One attempt at the host /v1/http route. A resume attempt is the same
    // request plus the byte offset the Worker already delivered, so the host
    // can answer from its committed response log without contacting the
    // upstream again.
    const sendHop = async (resumeFrom?: number): Promise<DeliveryAttempt> => {
      signal.throwIfAborted()
      const outgoing = new Headers(headers)
      const authorization = outgoing.get('authorization')
      if (authorization !== null) {
        outgoing.set('x-pdsh-upstream-authorization', authorization)
        outgoing.delete('authorization')
      }
      outgoing.set('x-pdsh-target-url', url.href)
      outgoing.set('x-pdsh-target-method', method)
      outgoing.set('authorization', `Bearer ${proxy.token}`)
      const extra = extraHeaders(url, true)
      if (extra !== undefined) for (const [name, value] of Object.entries(extra)) outgoing.set(name, value)
      if (resumeFrom !== undefined) outgoing.set(RESUME_FROM_HEADER, String(resumeFrom))
      const controller = new AbortController()
      const attemptSignal = anySignal([signal, controller.signal])
      try {
        const response = await withHeadDeadline(
          underlying(proxyUrl, {
            method: 'POST',
            headers: outgoing,
            body: body as BodyInit | undefined,
            signal: attemptSignal,
            cache: 'no-store',
            redirect: 'manual',
          }),
          resumeFrom === undefined ? deliveryIdleTimeoutMs : Math.max(deliveryIdleTimeoutMs, RESUME_TIMEOUT_MS),
          controller,
        )
        deliveryMetrics.attempts += 1
        return { response, controller }
      } catch (error) {
        controller.abort(error)
        throw error
      }
    }

    for (let hop = 0; ; hop++) {
      const attempt = await sendHop()
      const response = attempt.response
      const status = response.status
      const location = response.headers.get('location')
      if (!REDIRECT_STATUS.has(status) || request.redirect === 'manual' || location === null) {
        return resumableDelivery(attempt, {
          timeoutMs: deliveryIdleTimeoutMs,
          signal,
          maxResumes: MAX_DELIVERY_RESUMES,
          resume: async (offset: number) => {
            const next = await sendHop(offset)
            if (next.response.status !== 200 || next.response.headers.get(RESUMED_HEADER) !== '1') {
              await next.response.body?.cancel().catch(() => {})
              next.controller.abort(new Error('the host did not serve the resume from its response log'))
              return undefined
            }
            return next
          },
        }, method === 'HEAD')
      }
      await response.body?.cancel().catch(() => {})
      attempt.controller.abort(new Error('redirect'))
      if (request.redirect === 'error') throw new TypeError('fetch failed', { cause: new Error(`unexpected redirect to ${location}`) })
      if (hop + 1 > 20) throw new TypeError('fetch failed', { cause: new Error('redirect count exceeded') })
      const next = new URL(location, url)
      if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
        method = 'GET'
        body = undefined
        for (const name of REDIRECT_STRIPPED) headers.delete(name)
      }
      if (next.origin !== url.origin) {
        headers.delete('authorization')
        headers.delete('cookie')
        headers.delete('proxy-authorization')
      }
      url = next
    }
  }) as typeof fetch
}

/** Combines the caller signal with the delivery-owned controller signal. */
function anySignal(signals: AbortSignal[]): AbortSignal {
  const defined = signals.filter(signal => signal !== undefined)
  if (defined.length === 1) return defined[0] as AbortSignal
  const combiner = (AbortSignal as unknown as {
    any?: (values: AbortSignal[]) => AbortSignal
  }).any
  if (typeof combiner === 'function') return combiner(defined)
  const controller = new AbortController()
  const abort = (event: Event): void => {
    controller.abort((event.target as AbortSignal | null)?.reason)
  }
  for (const signal of defined) {
    if (signal.aborted) {
      controller.abort(signal.reason)
      return controller.signal
    }
    signal.addEventListener('abort', abort, { once: true })
  }
  return controller.signal
}

/** Waits for the response head under the delivery inactivity interval. */
async function withHeadDeadline(
  request: Promise<Response>,
  timeoutMs: number,
  controller: AbortController,
): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      const error = new DeliveryTimeoutError('head', timeoutMs)
      controller.abort(error)
      reject(error)
    }, timeoutMs)
  })
  try {
    return await Promise.race([request, deadline])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/** One in-flight host-route attempt and the controller that owns its socket. */
interface DeliveryAttempt {
  readonly response: Response
  readonly controller: AbortController
}

interface DeliveryOptions {
  timeoutMs: number
  signal: AbortSignal
  maxResumes: number
  resume: (offset: number) => Promise<DeliveryAttempt | undefined>
}

type DeliveryRead =
  | { readonly kind: 'chunk'; readonly value: Uint8Array }
  | { readonly kind: 'done' }
  | { readonly kind: 'failure'; readonly error: unknown; readonly timedOut: boolean }

/**
 * Wraps a platform response so a suspended downstream consumer can resume.
 *
 * The host gateway may have received a complete model response while the
 * Worker's platform fetch stops receiving bytes (a suspended WebKit page, a
 * broken stream hop). The wrapper counts the bytes it actually delivered; when
 * an inactivity interval expires on an open body it asks the host for the same
 * response from that byte offset (``RESUME_FROM_HEADER``). The host serves the
 * suffix from its committed response log, so the model client sees one
 * continuous body and the delivery window is replenished instead of abandoned.
 *
 * The typed ``DeliveryTimeoutError`` is still the failure of last resort: with
 * no resumable host body, or after ``maxResumes``, the body errors with
 * `PDSH_DELIVERY_TIMEOUT` exactly as before.
 */
function resumableDelivery(initial: DeliveryAttempt, options: DeliveryOptions,
                           headRequest: boolean): Response {
  if (initial.response.body === null) return initial.response
  if (NULL_BODY_STATUS.has(initial.response.status) || headRequest) {
    // A null-body status (and a HEAD response) must never be reconstructed with
    // a body. Release the stray stream and keep the observable response fields.
    void initial.response.body.cancel(new Error('bodyless response')).catch(() => {})
    initial.controller.abort(new Error('bodyless response'))
    const bodyless = new Response(null, {
      status: initial.response.status,
      statusText: initial.response.statusText,
      headers: initial.response.headers,
    })
    Object.defineProperty(bodyless, 'url', { value: initial.response.url })
    Object.defineProperty(bodyless, 'redirected', { value: initial.response.redirected })
    return bodyless
  }
  let attempt = initial
  let reader = initial.response.body.getReader()
  let offset = 0
  let resumes = 0
  let onResumedAttempt = false
  let terminal = false
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined
  let handoffTimer: ReturnType<typeof setTimeout> | undefined

  const clearHandoff = (): void => {
    if (handoffTimer !== undefined) {
      clearTimeout(handoffTimer)
      handoffTimer = undefined
    }
  }
  const settle = (error?: unknown): void => {
    if (terminal) return
    terminal = true
    clearHandoff()
    options.signal.removeEventListener('abort', onAbort)
    if (error !== undefined) {
      try { void reader.cancel(error).catch(() => {}) } catch { /* already closed */ }
      attempt.controller.abort(error)
      try { controller?.error(error) } catch { /* already errored */ }
    } else {
      try { controller?.close() } catch { /* already closed */ }
    }
  }
  const onAbort = (): void => {
    settle(options.signal.reason ?? new DOMException('The request was aborted', 'AbortError'))
  }
  const armHandoff = (): void => {
    clearHandoff()
    if (terminal) return
    handoffTimer = setTimeout(() => {
      handoffTimer = undefined
      if (terminal) return
      deliveryMetrics.stalls += 1
      settle(new DeliveryTimeoutError('body', options.timeoutMs))
    }, options.timeoutMs)
  }
  const readOnce = async (): Promise<DeliveryRead> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const timeout = new Promise<DeliveryRead>(resolve => {
      timer = setTimeout(() => resolve({
        kind: 'failure',
        error: new DeliveryTimeoutError('body', options.timeoutMs),
        timedOut: true,
      }), options.timeoutMs)
    })
    const read = reader.read()
      .then(result => result.done === true
        ? ({ kind: 'done' } as DeliveryRead)
        : ({ kind: 'chunk', value: result.value } as DeliveryRead))
      .catch(error => ({ kind: 'failure', error, timedOut: false } as DeliveryRead))
    try {
      return await Promise.race([read, timeout])
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  }
  options.signal.addEventListener('abort', onAbort, { once: true })
  const body = new ReadableStream<Uint8Array>({
    start(value) {
      controller = value
      armHandoff()
    },
    async pull(value) {
      controller = value
      clearHandoff()
      while (true) {
        if (terminal) return
        const result = await readOnce()
        if (terminal) return
        if (result.kind === 'chunk') {
          offset += result.value.byteLength
          deliveryMetrics.bodyBytes += result.value.byteLength
          if (onResumedAttempt) deliveryMetrics.resumedBytes += result.value.byteLength
          value.enqueue(result.value)
          armHandoff()
          return
        }
        if (result.kind === 'done') {
          settle()
          return
        }
        if (options.signal.aborted) {
          settle(options.signal.reason)
          return
        }
        const failure = result.timedOut
          ? new DeliveryTimeoutError('body', options.timeoutMs)
          : result.error
        if (result.timedOut) deliveryMetrics.stalls += 1
        if (resumes >= options.maxResumes) {
          settle(failure)
          return
        }
        resumes += 1
        // Release the abandoned attempt before asking the host for the suffix.
        attempt.controller.abort(failure)
        try { await reader.cancel(failure) } catch { /* already closed */ }
        let next: DeliveryAttempt | undefined
        try { next = await options.resume(offset) } catch { next = undefined }
        if (next === undefined || next.response.body === null) {
          settle(failure)
          return
        }
        deliveryMetrics.resumes += 1
        attempt = next
        reader = next.response.body.getReader()
        onResumedAttempt = true
      }
    },
    cancel(reason) {
      if (terminal) return
      terminal = true
      clearHandoff()
      options.signal.removeEventListener('abort', onAbort)
      try { void reader.cancel(reason).catch(() => {}) } catch { /* already closed */ }
      attempt.controller.abort(reason)
    },
  })
  return new Response(body, {
    status: initial.response.status,
    statusText: initial.response.statusText,
    headers: initial.response.headers,
  })
}

function httpOriginFromChannelUrl(raw: string | undefined): string | undefined {
  if (raw === undefined || raw === '') return undefined
  try {
    const url = new URL(raw)
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:' && url.protocol !== 'http:' && url.protocol !== 'https:') return undefined
    url.protocol = url.protocol === 'ws:' || url.protocol === 'http:' ? 'http:' : 'https:'
    return url.origin
  } catch {
    return undefined
  }
}
