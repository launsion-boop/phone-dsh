// SPDX-License-Identifier: MIT
/**
 * Page-side boot for the complete DSH Web client over the phone Worker tunnel.
 *
 * The Worker entry already hosts the unmodified runtime, including its
 * `TunnelServer` (`createWorkerHost({channel})`): `/__boot__`, the client
 * bundles and every browser `/api` call travel over that one postMessage tunnel.
 * This module is the page half. It spawns `worker-entry.js`, sends the same
 * `{t:'init', image, overlays, xl}` frame the minimal `www/boot.js` page sends,
 * then uses the runtime's own `WorkerTunnel` to read the boot injection table,
 * install the transport globals the client tree reads, and execute the table
 * before releasing `__DSH_BOOT_READY__`.
 *
 * Deliberately absent: a second `/api` carrier, a WebSocket chat protocol, a
 * remote URL and a second session. The Worker remaining the single session /
 * tool authority is the point of this page boot.
 *
 * Transport coordinates are one-shot inputs: they are parsed into memory, the
 * Worker `init` frame carries them, and then every boot parameter is removed
 * from the visible URL with `history.replaceState`. Business query parameters
 * and the hash stay, so a copied link, a saved route or a screenshot cannot
 * carry the launch token, channel, image, overlays, fence or environment. The
 * parsed values are never written to `history.state` or storage.
 *
 * @module @phone-dsh/dsh-worker-entry/web-boot
 */
import {
  WorkerTunnel,
  applyIndexInjections,
} from '@deepseek-ai/dsh-experimental-webworker-runtime/client'
import {
  BOOT_TRANSPORT_PARAMS,
  bootFailureError,
  bootTransportSecretValues,
  redactBootFailureDetail,
} from './boot-redaction.ts'
import { installPromiseWithResolvers, promiseWithResolvers } from './promise-compat.ts'

export { bootTransportSecretValues, redactBootFailureDetail } from './boot-redaction.ts'

/**
 * Page-global marker the native App installs before this module runs.
 *
 * The full DSH page is also served to ordinary browsers, which keep their PWA
 * install guidance. The native App already owns the install/notification
 * surface, so it publishes an explicit display mode instead of pretending to
 * be `standalone` (which would also change unrelated media queries).
 */
export const EMBEDDED_APP_GLOBAL = '__PDSH_EMBEDDED_APP__'

/**
 * Official `ui-mobile` preference that dismisses PWA install promotion.
 * Setting it here uses the same localStorage path as the banner's own Dismiss
 * button, so ordinary DSH Web pages are untouched.
 */
export const INSTALL_PROMOTION_DISMISSED_KEY = 'dsh-ui-mobile:install-promotion-dismissed'

/** Structural page globals this adapter reads; tests supply a plain object. */
interface EmbeddedAppGlobals {
  readonly [key: string]: unknown
}

/**
 * Whether the page is the native App's embedded Web surface.
 *
 * `WebEngine` installs the marker at document start. Only the explicit
 * `displayMode: 'app'` object (or the test shorthand `true`) counts, so an
 * arbitrary page global cannot disable browser install guidance by accident.
 * @param globals - page globals; defaults to the real global object.
 * @returns true for the native embedded surface.
 */
export function isEmbeddedAppPage(globals: EmbeddedAppGlobals = globalThis as unknown as EmbeddedAppGlobals): boolean {
  const marker = globals[EMBEDDED_APP_GLOBAL]
  if (marker === true) return true
  return typeof marker === 'object' && marker !== null
    && (marker as { displayMode?: unknown }).displayMode === 'app'
}

/**
 * Suppress the browser PWA install promotion on the native App surface only.
 *
 * The native App is already installed and owns notifications, so the page must
 * not show "add to home screen" guidance or a desktop-preview modal. The
 * banner's own dismissal key is the stable, non-DOM contract; a normal DSH
 * Web page has no marker and keeps the complete PWA flow.
 * @param globals - page globals; defaults to the real global object.
 * @returns true when the native-page preference was applied.
 */
export function installEmbeddedAppPreferences(
  globals: EmbeddedAppGlobals = globalThis as unknown as EmbeddedAppGlobals,
): boolean {
  if (!isEmbeddedAppPage(globals)) return false
  try {
    const storage = globals['localStorage'] as { setItem?: (key: string, value: string) => void } | undefined
    storage?.setItem?.(INSTALL_PROMOTION_DISMISSED_KEY, '1')
  } catch {
    // Private/storage-denied WebViews must still boot; the native surface has
    // no install UI to suppress beyond this preference.
  }
  return true
}

// iOS 17.0-17.3 has no Promise.withResolvers; the page's injected prelude and
// this call install it before any boot step awaits. Feature-detected on modern
// engines. See promise-compat.ts.
installPromiseWithResolvers()

/** Transport globals consumed by the DSH client connection and upload services. */
interface WebBootGlobals {
  __DSH_BOOT_READY__?: PromiseWithResolvers<void>
  __DSH_TRANSPORT__?: {
    readonly fetch: WorkerTunnel['fetch']
    readonly openStream: (
      endpoint: string,
      payload: unknown,
      signal: AbortSignal,
      uplink?: AsyncIterable<unknown>,
    ) => AsyncIterable<unknown>
    readonly loadBundle: (url: string) => Promise<void>
    readonly ownsHost: boolean
  }
  __DSH_FILE_UPLOAD__?: {
    readonly fetch: WorkerTunnel['fetch']
  }
}

/** One parsed page query, before it becomes the Worker `init` frame. */
export interface WebBootQuery {
  readonly image: string
  readonly overlays: readonly string[]
  readonly xl: Readonly<Record<string, unknown>>
}

/** The exact init frame `plugins/worker-entry/www/boot.js` sends. */
export interface WebBootInitFrame {
  readonly t: 'init'
  readonly image: string
  readonly overlays: readonly string[]
  readonly xl: Readonly<Record<string, unknown>>
}

/** History slice used to replace the visible URL; tests supply a fake. */
export interface WebBootHistory {
  readonly state?: unknown
  replaceState(data: unknown, unused: string, url?: string | URL | null): void
}

/**
 * Upper bound for the tunnel handshake before the page paints its own failure.
 *
 * This is a last-resort bound, not the normal boot budget: a Worker that never
 * answers `/__boot__` must not leave the readiness gate pending forever. It
 * matches the repository's most generous configured boot budget (the probe's
 * 240 s) so a slow simulator boot is not cut off before the native wait; the
 * app's usual 30 s native timeout still fires first. Callers may override it
 * for a focused test.
 */
export const WEB_BOOT_HANDSHAKE_TIMEOUT_MS = 240_000

/** Inputs a caller (or the unit test) can supply instead of page globals. */
export interface WebBootOptions {
  /** Page query string, usually `location.search`. */
  readonly search?: string
  /** Page URL used to resolve relative image, overlay and channel URLs. */
  readonly href?: string
  /** Pre-spawned Worker; production omits it and this module creates the entry Worker. */
  readonly worker?: Worker
  /** Injection interpreter override; production uses the runtime's own. */
  readonly applyInjections?: typeof applyIndexInjections
  /** Failure hook called after the readiness deferred is rejected. */
  readonly onFailure?: (reason: unknown) => void
  /** History replacement target; production uses `globalThis.history`. */
  readonly history?: WebBootHistory
  /** Handshake upper bound; defaults to {@link WEB_BOOT_HANDSHAKE_TIMEOUT_MS}. */
  readonly timeoutMs?: number
}

/** Read the installed readiness deferred, creating it if the page markup did not. */
function bootReadyGate(): PromiseWithResolvers<void> {
  return ((globalThis as WebBootGlobals).__DSH_BOOT_READY__ ??= promiseWithResolvers<void>())
}

/** Parse one optional JSON query value. */
function parseJsonParam(raw: string | null, name: string): unknown {
  if (raw === null || raw === '') return undefined
  try {
    return JSON.parse(raw) as unknown
  } catch {
    throw new Error(`web boot: ?${name}= is not valid JSON`)
  }
}

/** Resolve an HTTP(S) channel URL to the WebSocket scheme the Worker expects. */
function resolveChannelUrl(raw: string, base: string): string {
  const url = new URL(raw, base)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  return url.href
}

/**
 * Parse the page query into the Worker-init values.
 *
 * The parameter names and defaults match `www/boot.js`: `channel` (alias
 * `channelURL`), repeated `overlay`, JSON `fence` / `env` / `egress`, and the
 * snake_case boot id / session epoch spellings the App emits.
 * @param search - page query string including `?`.
 * @param href - absolute page URL for relative resolution.
 * @returns the image, ordered overlays and `xl` payload.
 * @throws when a required value is missing or an optional JSON value is malformed.
 */
export function readBootQuery(search: string, href: string): WebBootQuery {
  const params = new URLSearchParams(search)
  const image = params.get('image')
  const channelParam = params.get('channel') ?? params.get('channelURL')
  if (image === null || image === '') throw new Error('web boot: missing ?image=<image-url>')
  if (channelParam === null || channelParam === '') throw new Error('web boot: missing ?channel=<channel-url>')

  // `overlay[]` is the bracketed spelling some carriers use; keep document
  // order across both spellings so overlays still apply in the order sent.
  const overlays: string[] = []
  for (const [name, value] of params) {
    if (name === 'overlay' || name === 'overlay[]') overlays.push(value)
  }
  const token = params.get('token') ?? ''
  const fence = parseJsonParam(params.get('fence'), 'fence')
    ?? { owner: 'phone', generation: 0, wal_seq: 0 }
  const env = parseJsonParam(params.get('env'), 'env') ?? {}
  if (env === null || typeof env !== 'object' || Array.isArray(env)) {
    throw new Error('web boot: ?env= must be a JSON object')
  }
  const egress = parseJsonParam(
    params.get('egress') ?? params.get('egress_allow') ?? params.get('egressAllow'),
    'egress',
  )
  if (egress !== undefined
    && (!Array.isArray(egress) || egress.some(entry => typeof entry !== 'string'))) {
    throw new Error('web boot: ?egress= must be a JSON array of strings')
  }
  const bootId = params.get('boot_id') ?? params.get('bootId')
  const sessionEpoch = params.get('session_epoch') ?? params.get('sessionEpoch')

  return {
    image,
    overlays,
    xl: {
      channelURL: resolveChannelUrl(channelParam, href),
      token,
      env,
      fence,
      ...bootId === null || bootId === '' ? {} : { bootId },
      ...sessionEpoch === null || sessionEpoch === '' ? {} : { sessionEpoch },
      ...egress === undefined ? {} : { egressAllow: egress },
    },
  }
}

/**
 * Remove every boot transport parameter from a URL, keeping business query
 * entries and the fragment exactly where they were.
 *
 * The visible page URL is the copy/share/save surface; the parsed boot values
 * live only in the caller's memory. The function does not touch
 * `history.state`, storage or the network.
 * @param href - absolute page URL to sanitize.
 * @returns the sanitized URL, or `undefined` when no transport key was present
 *   (or the URL cannot be parsed, in which case the caller must not replace).
 */
export function stripBootTransportParams(href: string): string | undefined {
  let url: URL
  try {
    url = new URL(href)
  } catch {
    return undefined
  }
  let changed = false
  // Snapshot the keys: deleting while iterating a live iterator skips entries.
  for (const name of [...url.searchParams.keys()]) {
    if (!BOOT_TRANSPORT_PARAMS.has(name)) continue
    url.searchParams.delete(name)
    changed = true
  }
  return changed ? url.href : undefined
}

/**
 * Replace the visible URL with its transport-scrubbed form.
 *
 * Runs immediately after the boot query has been captured, before the Worker is
 * spawned, so neither a boot failure nor a screenshot can expose the launch
 * token or environment. The existing history state is preserved; nothing from
 * the boot query is added to it.
 * @param options - URL and history target; production reads both from globals.
 * @returns `true` when `history.replaceState` accepted the sanitized URL.
 */
export function scrubBootLocation(
  options: { readonly href?: string; readonly history?: WebBootHistory } = {},
): boolean {
  const href = options.href ?? globalThis.location?.href
  const history = options.history ?? globalThis.history
  if (href === undefined || history === undefined) return false
  const stripped = stripBootTransportParams(href)
  if (stripped === undefined) return false
  try {
    history.replaceState(history.state ?? null, '', stripped)
    return true
  } catch {
    // A denied replaceState must not stop the boot; the init values are already
    // in memory and the Worker still needs to start.
    return false
  }
}

/**
 * Build the Worker's opening frame from a parsed query.
 * @param query - parsed image, overlays and `xl` values.
 * @returns the frame `entry.ts` consumes.
 */
export function bootInitFrame(query: WebBootQuery): WebBootInitFrame {
  return { t: 'init', image: query.image, overlays: query.overlays, xl: query.xl }
}

/**
 * Install the page transport globals over one tunnel.
 *
 * The client connection reads `__DSH_TRANSPORT__` for RPC streams and bundle
 * loading; the independent upload service reads `__DSH_FILE_UPLOAD__`. Both
 * point at the same Worker, so the page never opens a second carrier.
 * @param tunnel - tunnel attached to the phone Worker.
 */
export function installTunnelTransport(tunnel: WorkerTunnel): void {
  const globals = globalThis as WebBootGlobals
  globals.__DSH_TRANSPORT__ = {
    fetch: tunnel.fetch,
    openStream: (endpoint, payload, signal, uplink) => tunnel.open(endpoint, payload, signal, uplink),
    loadBundle: url => tunnel.loadBundle(url),
    ownsHost: true,
  }
  globals.__DSH_FILE_UPLOAD__ = { fetch: tunnel.fetch }
}

/**
 * Redact page console lines for the duration of the boot handshake.
 *
 * The pinned `WorkerTunnel` reports a 503 refusal with `console.warn`, and that
 * line carries the Worker's raw refusal text (image URL/token/environment). The
 * native observability bridge wraps `console` and forwards those lines before
 * this module can reject the readiness deferred, so field/secret redaction has
 * to be in place before the tunnel is constructed. Only string and Error
 * arguments are rewritten; the console keeps its normal shape.
 * @param currentSecrets - exact transport values captured so far.
 * @returns an idempotent restore callback.
 */
function installBootConsoleRedaction(currentSecrets: () => readonly string[]): () => void {
  const originalWarn = console.warn
  const originalError = console.error
  const sanitize = (value: unknown): unknown => {
    if (typeof value === 'string' || value instanceof Error) {
      return redactBootFailureDetail(value, currentSecrets())
    }
    return value
  }
  console.warn = (...args: unknown[]) => { originalWarn(...args.map(sanitize)) }
  console.error = (...args: unknown[]) => { originalError(...args.map(sanitize)) }
  let restored = false
  return () => {
    if (restored) return
    restored = true
    console.warn = originalWarn
    console.error = originalError
  }
}

/** Normal user-facing copy shown alongside the sanitized technical detail. */
const BOOT_FAILURE_MESSAGE = 'DSH boot failed. Please go back and try again.'

/**
 * Frames consumed by the pinned `WorkerTunnel.receive`.
 *
 * Everything else on the Worker port is out-of-band (the entry's `pdsh-ready`,
 * pre-host failures and any future Native control frame). The tunnel throws on
 * an unknown frame, so the page must intercept those frames before they reach
 * its listener. Keep this list in sync with the runtime's `TunnelOutboundFrame`.
 */
const TUNNEL_RESPONSE_FRAME_TYPES: ReadonlySet<string> = new Set([
  'res',
  'res-head',
  'res-chunk',
  'res-end',
  'res-err',
  'view-text',
  'stream-item',
  'stream-end',
  'stream-error',
])

/** Out-of-band Worker frames that terminate a boot before `/__boot__`. */
const WORKER_BOOT_FAILURE_FRAME_TYPES: ReadonlySet<string> = new Set([
  'pdsh-error',
  'init-error',
  'pdsh-boot-error',
])

/** Native boot bridge signal; `WebEngineScripts` recognizes this title text. */
export const NATIVE_BOOT_READY_TITLE = 'DSH ready'

/**
 * Tell the native observability bridge that the Worker tunnel is ready.
 *
 * The complete DSH Web page owns its title and has no `#status` element; the
 * native bridge still watches those two places for its existing ready regex.
 * Publish the signal only after every injection has applied, so native boot
 * completion and the page's readiness gate describe the same state.
 */
function announceNativeBootReady(): void {
  if (typeof document === 'undefined') return
  try {
    document.title = NATIVE_BOOT_READY_TITLE
  } catch {
    // A read-only title must not fail an otherwise complete boot.
  }
}

/**
 * Render a boot failure inside the page.
 *
 * The full DSH client owns the document and paints its own boot page, so the
 * transport's failure is appended as one fixed alert rather than replacing the
 * app shell. The panel shows normal user copy plus a bounded, redacted detail;
 * raw tokens, environment objects and URLs never reach the DOM. Absent a
 * document (unit tests) this is a no-op.
 * @param reason - failure thrown by the handshake.
 */
export function showBootFailure(reason: unknown): void {
  if (typeof document === 'undefined') return
  const detail = redactBootFailureDetail(reason)
  const message = detail === ''
    ? BOOT_FAILURE_MESSAGE
    : `${BOOT_FAILURE_MESSAGE}\n\nTechnical detail: ${detail}`
  try {
    // The native title bridge treats "DSH boot failed" as the failed state.
    document.title = 'DSH boot failed'
  } catch {
    // A title change is diagnostic only.
  }
  const existing = document.querySelector('[data-pdsh-boot-failure]')
  if (existing !== null) {
    existing.textContent = message
    return
  }
  const panel = document.createElement('pre')
  panel.dataset.pdshBootFailure = ''
  panel.setAttribute('role', 'alert')
  panel.style.cssText = [
    'position:fixed', 'inset:auto 12px 12px 12px', 'z-index:2147483647',
    'max-height:40vh', 'overflow:auto', 'margin:0', 'padding:12px',
    'border:1px solid rgba(255,255,255,.18)', 'border-radius:10px',
    'background:#2a1215', 'color:#ffd7d7',
    'font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace',
    'white-space:pre-wrap', '-webkit-user-select:text', 'user-select:text',
  ].join(';')
  panel.textContent = message
  document.body?.append(panel)
}

/**
 * Spawn the phone Worker, complete the tunnel handshake and release the page.
 *
 * Order is the boot protocol: install the readiness deferred before the first
 * await, parse the transport coordinates into memory, scrub them from the
 * visible URL, send `init` with the in-memory coordinates, wait for the tree's
 * `/__boot__`, install the transport globals, execute the injection table, and
 * only then resolve. The boot window redacts `console.warn`/`console.error`
 * (the tunnel's refusal line would otherwise reach the native log first), and
 * one control-frame filter stays ahead of the tunnel for its lifetime so
 * `pdsh-ready` and other out-of-band frames never reach its unknown-frame path.
 * A Worker `pdsh-error`/`init-error`/`pdsh-boot-error` frame or the bounded
 * handshake deadline settles the gate even when no host ever answers
 * `/__boot__`; the same deadline and abort cover the injection/bundle phase, so
 * a silent bundle cannot leave readiness pending. On failure the deferred
 * rejects with a new bounded, redacted Error, so the client entry's own
 * `console.error(reason)` and failure page can only render the safe text. The
 * raw reason is never rethrown or kept as a `cause`.
 * @param options - page inputs; production uses the defaults.
 * @throws a new Error carrying only the redacted failure detail.
 */
export async function connectWebWorker(options: WebBootOptions = {}): Promise<void> {
  // Apply the native page preference before the first await: the client entry
  // constructs `InstallController` only after this boot resolves, so the
  // official dismissal key is in place before the banner decides to render.
  installEmbeddedAppPreferences()
  const ready = bootReadyGate()
  // The client entry subscribes to this promise later; keep an early failure
  // from surfacing as an unhandled rejection before it does.
  void ready.promise.catch(() => {})
  const href = options.href ?? globalThis.location?.href ?? 'http://127.0.0.1/static/web/index.html'
  const search = options.search ?? globalThis.location?.search ?? ''
  let secrets: readonly string[] = []
  // The tunnel's own refusal warning is forwarded to the native console bridge
  // before this function can reject; redact the boot window from its start.
  const restoreConsole = installBootConsoleRedaction(() => secrets)
  // A Worker can fail before createWorkerHost exists (invalid fence, runtime
  // load, profile/overlay creation). There is then no TunnelServer to answer
  // /__boot__, so the explicit pdsh-error frame is the only prompt failure.
  const workerFailure = promiseWithResolvers<never>()
  void workerFailure.promise.catch(() => {})
  // One abort boundary for the complete handshake: the deadline below and any
  // out-of-band Worker failure abort it, and the bundle loader races it so an
  // injection that never answers cannot keep applying rows after boot failed.
  const bootAbort = new AbortController()
  const abortBoot = (reason: unknown): void => {
    if (!bootAbort.signal.aborted) bootAbort.abort(reason)
  }
  let timeout: ReturnType<typeof setTimeout> | undefined
  const timeoutMs = options.timeoutMs ?? WEB_BOOT_HANDSHAKE_TIMEOUT_MS
  try {
    // Parse first, then scrub in `finally`: even a malformed boot query must
    // not leave its token in a visible URL after the failure panel appears.
    const frame = (() => {
      try {
        const query = readBootQuery(search, href)
        // Keep the exact values in memory only for failure redaction: a Worker
        // 503 body can repeat the token/env without the init field names.
        secrets = bootTransportSecretValues({
          image: query.image,
          overlays: query.overlays,
          xl: query.xl,
        }, href)
        return bootInitFrame(query)
      } finally {
        scrubBootLocation({
          href: globalThis.location?.href ?? href,
          history: options.history,
        })
      }
    })()
    const worker = options.worker
      ?? new Worker(new URL('../worker-entry.js', import.meta.url), { type: 'module' })
    // Install the filter before WorkerTunnel: it sees every frame first, lets
    // the tunnel's response/stream types through, and stops everything else.
    // It must stay attached after boot succeeds: the Worker posts {t:'pdsh-ready'}
    // once its host is up, and that frame would otherwise hit the tunnel's
    // unknown-frame throw. Boot failures settle the handshake anyway.
    const onWorkerMessage = (event: MessageEvent): void => {
      const data = event.data as { t?: unknown; message?: unknown } | null
      const type = data !== null && typeof data === 'object' ? data.t : undefined
      if (typeof type === 'string' && TUNNEL_RESPONSE_FRAME_TYPES.has(type)) return
      event.stopImmediatePropagation?.()
      if (typeof type !== 'string' || !WORKER_BOOT_FAILURE_FRAME_TYPES.has(type)) return
      const failure = new Error(
        typeof data?.message === 'string' && data.message !== ''
          ? data.message
          : 'the Worker reported a boot failure',
      )
      abortBoot(failure)
      workerFailure.reject(failure)
    }
    worker.addEventListener('message', onWorkerMessage)
    // Constructing the tunnel installs its message listener, so it must exist
    // before the init frame can make the Worker answer.
    const tunnel = new WorkerTunnel(worker)
    worker.postMessage(frame)
    const deadline = new Promise<never>((_resolve, reject) => {
      timeout = setTimeout(() => {
        const failure = new Error(`web boot: no ready signal after ${String(timeoutMs)} ms`)
        abortBoot(failure)
        reject(failure)
      }, timeoutMs)
    })
    // The deadline covers the complete ready phase, not just `/__boot__`:
    // `applyIndexInjections` loads client bundles through the same tunnel and a
    // silent script-src would otherwise leave the readiness gate pending after
    // the boot payload had already arrived.
    const abortRejection = new Promise<never>((_resolve, reject) => {
      if (bootAbort.signal.aborted) {
        reject(bootAbort.signal.reason)
        return
      }
      bootAbort.signal.addEventListener('abort', () => {
        reject(bootAbort.signal.reason)
      }, { once: true })
    })
    void abortRejection.catch(() => {})
    const assertBootActive = (): void => {
      if (!bootAbort.signal.aborted) return
      throw bootAbort.signal.reason instanceof Error
        ? bootAbort.signal.reason
        : new Error('web boot: the handshake was aborted')
    }
    const loadBootBundle = async (src: string): Promise<void> => {
      assertBootActive()
      await Promise.race([tunnel.loadBundle(src), abortRejection])
      assertBootActive()
    }
    const boot = async (): Promise<void> => {
      const payload = await tunnel.bootPayload()
      assertBootActive()
      installTunnelTransport(tunnel)
      if (options.applyInjections === undefined) {
        await applyIndexInjections(payload.injections, loadBootBundle)
      } else {
        await options.applyInjections(payload.injections, loadBootBundle)
      }
      // Native boot completion and the page gate must describe the same state:
      // publish the signal only after every injection row applied.
      assertBootActive()
      announceNativeBootReady()
      ready.resolve()
    }
    await Promise.race([boot(), workerFailure.promise, deadline])
  } catch (reason) {
    // A failed boot must also stop any injection still awaiting a bundle.
    abortBoot(reason)
    const failure = bootFailureError(reason, secrets)
    ready.reject(failure)
    showBootFailure(failure)
    options.onFailure?.(failure)
    throw failure
  } finally {
    if (timeout !== undefined) clearTimeout(timeout)
    restoreConsole()
  }
}

/**
 * Start the page boot; called by the injected `web-boot.js` module.
 *
 * The readiness deferred owns failure presentation, so the returned promise is
 * not exposed and a failure does not become an unhandled rejection.
 */
export function bootWebWorker(): void {
  void connectWebWorker().catch((reason: unknown) => {
    // Console output is part of the native bridge and may be captured in a
    // bug report: never pass the raw reason (it can contain the URL/token).
    console.error('web boot:', redactBootFailureDetail(reason))
  })
}

// The injected `<script type="module" src="./web-boot.js">` runs on import.
// `window` is absent under Node tests, so importing this module there is inert.
if (typeof window !== 'undefined' && typeof Worker !== 'undefined') bootWebWorker()
