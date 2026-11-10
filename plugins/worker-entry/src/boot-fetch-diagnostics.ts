// SPDX-License-Identifier: MIT
/**
 * Temporary `globalThis.fetch` instrumentation for the Worker boot window.
 *
 * The resume evidence stops between `runtime.createHost()` and
 * `await host.start()`, where DSH may fetch a model list or an MCP handshake
 * through the host gateway. The wrapper reports a fetch that takes at least
 * 2 s and keeps reporting one still in flight every 10 s. The host turns the
 * reserved console line into a `worker-phases` line in `boot-timings.log`, so
 * no channel frame or boot field is added.
 *
 * Security: only the query-free path and milliseconds are reported. Headers,
 * cookies and bodies are never read.
 *
 * Lifecycle: the wrapper is installed just before `host.start()` and disposed
 * right after it. `llm-bridge` may replace `globalThis.fetch` with its own
 * transport while the plugins activate (P27 in `entry.ts`). The disposer only
 * restores the global when it still points at this wrapper; a replacement is
 * left untouched. A replacement that captured this wrapper keeps forwarding to
 * the previous fetch, and the wrapper stops emitting once inactive.
 * @module @phone-dsh/dsh-worker-entry/boot-fetch-diagnostics
 */

/** The two diagnostic phase tokens understood by the host boot-phase parser. */
export type BootFetchDiagnosticPhase = 'slow-fetch' | 'fetch-inflight'

/** One diagnostic line source. `elapsedMs` is present for `slow-fetch` only. */
export type BootFetchDiagnosticEmitter = (
  phase: BootFetchDiagnosticPhase,
  path: string,
  elapsedMs?: number,
) => void

interface FetchTarget {
  fetch?: typeof fetch
}

export interface BootFetchDiagnosticsOptions {
  /** Existing boot-phase console channel. */
  emit: BootFetchDiagnosticEmitter
  /** Defaults to `globalThis`; tests pass a local object. */
  target?: FetchTarget
  /** Monotonic milliseconds. Defaults to `performance.now()`. */
  now?: () => number
  /** A completed fetch at or above this duration is reported. */
  slowMilliseconds?: number
  /** An unresolved fetch is reported once per interval. */
  inflightMilliseconds?: number
  setTimeoutImpl?: (callback: () => void, milliseconds: number) => unknown
  clearTimeoutImpl?: (handle: unknown) => void
}

/** Longest path reported in one line, matching the host parser's bound. */
const DIAGNOSTIC_PATH_LIMIT = 200

/**
 * Install the temporary wrapper.
 * @param options - emitter, monotonic clock and timer seams.
 * @returns an idempotent disposer that never overwrites a later replacement.
 */
export function installBootFetchDiagnostics(
  options: BootFetchDiagnosticsOptions,
): () => void {
  const target = options.target ?? globalThis as FetchTarget
  const previous = target.fetch
  if (typeof previous !== 'function') return () => {}
  const now = options.now
    ?? (() => (typeof performance !== 'undefined' ? performance.now() : Date.now()))
  const slowMilliseconds = Math.max(0, options.slowMilliseconds ?? 2_000)
  const inflightMilliseconds = Math.max(1, options.inflightMilliseconds ?? 10_000)
  const setTimeoutImpl = options.setTimeoutImpl
    ?? ((callback, milliseconds) => setTimeout(callback, milliseconds))
  const clearTimeoutImpl = options.clearTimeoutImpl
    ?? ((handle) => clearTimeout(handle as ReturnType<typeof setTimeout>))
  const timers = new Set<unknown>()
  let active = true

  const clearTimer = (handle: unknown): void => {
    timers.delete(handle)
    try {
      clearTimeoutImpl(handle)
    } catch {
      // Observability must never reach the fetch path.
    }
  }

  const wrapped = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    if (!active) return await previous(input, init)
    const path = diagnosticPath(input)
    const startedAt = now()
    let settled = false
    let timer: unknown
    const tick = (): void => {
      if (!active || settled) return
      const elapsed = Math.max(0, now() - startedAt)
      if (elapsed >= inflightMilliseconds) {
        try {
          options.emit('fetch-inflight', path)
        } catch {
          // See above: diagnostics never fail the request.
        }
      }
      timer = setTimeoutImpl(tick, inflightMilliseconds)
      timers.add(timer)
    }
    timer = setTimeoutImpl(tick, inflightMilliseconds)
    timers.add(timer)
    try {
      return await previous(input, init)
    } finally {
      settled = true
      clearTimer(timer)
      const elapsed = Math.max(0, now() - startedAt)
      if (active && elapsed >= slowMilliseconds) {
        try {
          options.emit('slow-fetch', path, elapsed)
        } catch {
          // See above.
        }
      }
    }
  }) as typeof fetch

  target.fetch = wrapped
  return () => {
    if (!active) return
    active = false
    for (const timer of timers) clearTimer(timer)
    timers.clear()
    if (target.fetch === wrapped) target.fetch = previous
  }
}

/**
 * The query-free path of a fetch input. A URL that cannot be parsed yields
 * `/unknown` rather than an unredacted raw string.
 */
export function diagnosticPath(input: RequestInfo | URL): string {
  const raw = requestUrl(input)
  if (raw === undefined) return '/unknown'
  let path: string | undefined
  try {
    path = new URL(raw, 'http://worker.invalid').pathname
  } catch {
    const cut = raw.search(/[?#]/)
    const candidate = cut < 0 ? raw : raw.slice(0, cut)
    path = candidate.startsWith('/') ? candidate : undefined
  }
  if (path === undefined || path.length === 0) return '/unknown'
  const filtered = path.replace(/[\s\u0000-\u001F\u007F]/g, '')
  return filtered.length > DIAGNOSTIC_PATH_LIMIT
    ? filtered.slice(0, DIAGNOSTIC_PATH_LIMIT)
    : filtered
}

/** The URL string of a fetch input, or `undefined` when it has no readable URL. */
function requestUrl(input: RequestInfo | URL): string | undefined {
  if (typeof input === 'string') return input
  if (typeof input === 'object' && input !== null) {
    if ('href' in input && typeof input.href === 'string') return input.href
    const url = (input as { url?: unknown }).url
    if (typeof url === 'string') return url
  }
  return undefined
}
