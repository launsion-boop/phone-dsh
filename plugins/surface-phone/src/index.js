// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-surface-phone` — the resident phone surface for DSH.
 *
 * The one-shot `dsh-headless` surface answers one task and exits. A phone host
 * instead keeps the harness resident and talks to it over loopback with the
 * same remote API the SDK's `DSHRemoteHarness` speaks (`dsh web`'s
 * `POST /api/<endpoint>` and the `/api/remote.mux` WebSocket). This plugin
 * mounts that carrier without the browser roster:
 *
 *   - `ctx.connection` is DSH's own `HostConnectionService` (the RPC and Fetch
 *     registries the API gateway and the controllers register into). Only the
 *     authentication object differs: the launch token is the one the host app
 *     passed in `PDSH_DSH_LAUNCH_TOKEN`, not a per-process random token.
 *   - `GET /?token=<launch token>` answers 303 with an HttpOnly session cookie
 *     bound to the request authority, then `/api` requests carry it. This is
 *     the browser-page exchange `DSHWebTransport` performs; `GET /connect`
 *     additionally exchanges the token for an API operator cookie, the 0.2.1
 *     browser-auth shape that non-page API clients use.
 *   - `POST /api/<endpoint>` is bridged from node:http to the Fetch-shaped
 *     handler; `/api/remote.mux` is registered separately by the API gateway.
 *   - Requests forwarded by the Worker entry over the ordered channel carry
 *     `x-pdsh-channel-authenticated: 1`: the channel bearer the host verified is
 *     their authentication (D22), so no cookie is needed. Only the Worker
 *     entry sets that header and it strips any inbound copy; the surface
 *     honors it only in a process the host gave the ordered-channel
 *     coordinates (D24), so the desktop carrier cannot be spoofed.
 *   - `XL_DSH_READY <port>` is printed on stdout after the tree is booted, so
 *     the host can connect without polling the port.
 *
 * Loopback only: the server binds 127.0.0.1 and HostConnectionService refuses
 * any other Host authority. Anything that can reach loopback must still show
 * the launch token (or its cookie); the token never appears in the port or in
 * a URL the model can read.
 * @module @phone-dsh/dsh-surface-phone
 */

import { randomBytes } from 'node:crypto'
import { Readable } from 'node:stream'
import { HostConnectionService } from '@deepseek-ai/dsh-client-connection'
import { applySessionPersistence } from './session-persistence.js'
import { registerRecoveryRoute } from './recovery-controller.js'
import { registerWorkerCommandRoute } from './worker-command-controller.js'
import { registerDescendantDrainRoute } from './descendant-drain-controller.js'
import { PhoneManagementRemote } from './management-remote.ts'


export const name = 'phone-surface'
/** The surface needs a listening carrier before it can mount routes. */
export const inject = []
/** Same carrier cap as the shipped web profile (a 200 MiB image budget after base64). */
const MAX_REQUEST_BODY_BYTES = 300 * 1024 * 1024
const TOKEN_QUERY = 'token'
const COOKIE_NAME = 'pdsh-dsh-session'
const CONNECT_PATH = '/connect'
const INTERACTIONS_QUERY = 'interactions'
const CHANNEL_AUTH_HEADER = 'x-pdsh-channel-authenticated'
/** Browser/API cookie lifetime; the launch token still changes every boot. */
const COOKIE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60

/**
 * Constant-time string comparison. The Worker runtime's node:crypto proxy has no
 * timingSafeEqual, so the comparison is written out: every byte is visited
 * whatever the first mismatch, and the length check does not short-circuit.
 */
function equalString(actual, expected) {
  const a = Buffer.from(actual, 'utf8')
  const b = Buffer.from(expected, 'utf8')
  let diff = a.length ^ b.length
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) diff |= (a[i % (a.length || 1)] ?? 0) ^ (b[i % (b.length || 1)] ?? 0)
  return diff === 0
}

function cookieOf(headerValue) {
  if (typeof headerValue !== 'string') return undefined
  for (const segment of headerValue.split(';')) {
    const at = segment.indexOf('=')
    if (at === -1 || segment.slice(0, at).trim() !== COOKIE_NAME) continue
    return segment.slice(at + 1).trim()
  }
  return undefined
}

/**
 * Request authority the cookie is bound to. The loopback listener's own
 * Host header is the whole audience (HTTP; the phone carrier has no TLS).
 * @param request - node:http incoming request.
 * @param secure - whether the receiving listener serves TLS.
 * @returns `host` (or `origin` under TLS), or undefined for a malformed Host.
 */
function authorityOf(request, secure = false) {
  const host = request?.headers?.host
  if (typeof host !== 'string' || host === '') return undefined
  try {
    const url = new URL(`${secure ? 'https:' : 'http:'}//${host}`)
    return secure ? url.origin : url.host
  } catch {
    return undefined
  }
}

/**
 * Ordered-channel coordinates the Worker host injects before the surface mounts
 * (D24). The desktop carrier launches the same bundle without any of them.
 */
const CHANNEL_ENV = ['PDSH_CHANNEL_URL', 'PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN']

/**
 * Whether this process serves a Worker ordered channel. The marker is only
 * meaningful on the Worker path: the desktop carrier has no entry behind it, so
 * it must not let another local process self-authenticate with a forged header
 * (D22: only the entry sets it).
 * @returns true when the ordered channel coordinates are present.
 */
function channelCarrier() {
  return CHANNEL_ENV.some(name => (process.env[name] ?? '') !== '')
}

/**
 * Whether the Worker entry authenticated this request with the ordered
 * channel bearer (D22). The entry owns the header: it sets it on forwarded
 * requests and strips any inbound copy, so a request that reaches the surface
 * with it is already authenticated. Only a process running the ordered channel
 * accepts it; without the channel there is no trusted entry to have set it.
 * @param request - node:http incoming request.
 * @returns true when the entry marked the request on the channel carrier.
 */
export function isChannelAuthenticated(request) {
  return channelCarrier() && request?.headers?.[CHANNEL_AUTH_HEADER] === '1'
}

/**
 * Launch-token authentication for the phone surface: the host-supplied token
 * exchanged for a process-local browser cookie and for 0.2.1 API-operator
 * cookies. It implements the object `HostConnectionService` (0.2.1) consumes:
 * `isAuthenticated` / `authenticateApi` / `authorizeIndex` / `authorizeConnect`
 * / `authenticatedUrl`. Cookies are random per boot: the launch token is
 * per-start, so there is nothing durable to sign or persist.
 */
export class PhoneLaunchAuth {
  constructor(token) {
    this.token = token
    /** Authority of the one browser-page cookie. */
    this.browserAuthority = undefined
    /** Random hex value of the browser-page cookie. */
    this.browserCookie = randomBytes(32).toString('hex')
    /** API-operator cookies minted by `/connect`: value → { peerId, authority }. */
    this.apiCookies = new Map()
  }

  authenticatedUrl(baseUrl) {
    const url = new URL(baseUrl)
    url.searchParams.set(TOKEN_QUERY, this.token)
    return url.href
  }

  /**
   * Verify the browser-page cookie bound to the request authority.
   * @param request - request headers carrying Host and Cookie.
   * @param secure - whether the receiving listener serves TLS.
   * @returns true only for this boot's page cookie on the issuing authority.
   */
  isAuthenticated(request, secure = false) {
    const authority = authorityOf(request, secure)
    if (authority === undefined || authority !== this.browserAuthority) return false
    const value = cookieOf(request?.headers?.cookie)
    return value !== undefined && equalString(value, this.browserCookie)
  }

  /**
   * Verify an API-operator cookie without the browser-page cookie.
   * @param request - request headers carrying Host and Cookie.
   * @param secure - whether the receiving listener serves TLS.
   * @returns the operator peer id, or undefined for an invalid cookie.
   */
  authenticateApi(request, secure = false) {
    const authority = authorityOf(request, secure)
    if (authority === undefined) return undefined
    const value = cookieOf(request?.headers?.cookie)
    if (value === undefined) return undefined
    const record = this.apiCookies.get(value)
    return record !== undefined && record.authority === authority ? record.peerId : undefined
  }

  /**
   * Authenticate an index request: mint the page cookie from a valid launch
   * token, or redirect an already-authenticated page to the clean URL.
   * @param request - incoming root request.
   * @param response - response owned when this method returns false.
   * @param secure - whether the receiving listener serves TLS.
   * @returns true only when the caller may serve the index page.
   */
  authorizeIndex(request, response, secure = false) {
    const url = new URL(request.url ?? '/', 'http://dsh.invalid')
    const tokens = url.searchParams.getAll(TOKEN_QUERY)
    if (tokens.length > 0) {
      const authority = authorityOf(request, secure)
      if (request.method === 'GET' && url.pathname === '/' && tokens.length === 1
        && authority !== undefined && equalString(tokens.join(''), this.token)) {
        this.browserAuthority = authority
        response.writeHead(303, {
          'cache-control': 'no-store',
          location: './',
          'referrer-policy': 'no-referrer',
          'set-cookie': this.cookieHeader(this.browserCookie, secure),
        })
        response.end()
        return false
      }
      if (request.method === 'GET' && url.pathname === '/' && this.isAuthenticated(request, secure)) {
        response.writeHead(303, {
          'cache-control': 'no-store',
          location: './',
          'referrer-policy': 'no-referrer',
        })
        response.end()
        return false
      }
      this.writeUnauthorized(response)
      return false
    }
    if (this.isAuthenticated(request, secure)) {
      response.writeHead(303, { 'cache-control': 'no-store', location: './', 'referrer-policy': 'no-referrer' })
      response.end()
      return false
    }
    this.writeUnauthorized(response)
    return false
  }

  /**
   * Exchange the launch token for an independent API operator, exactly as the
   * 0.2.1 browser-auth contract: the caller publishes the peer synchronously,
   * then this method exposes its cookie.
   * @param request - trusted GET request on /connect.
   * @param response - response owned to completion.
   * @param secure - whether the receiving listener serves TLS.
   * @param publish - create the operator peer before exposing its credential.
   */
  authorizeConnect(request, response, secure, publish) {
    const url = new URL(request.url ?? '/', 'http://dsh.invalid')
    const declarations = url.searchParams.getAll(INTERACTIONS_QUERY)
    const interactions = declarations[0] ?? 'none'
    if (declarations.length > 1 || (interactions !== 'answer' && interactions !== 'none')) {
      response.writeHead(400, { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8' })
      response.end('interactions must be declared once as answer or none\n')
      return
    }
    const tokens = url.searchParams.getAll(TOKEN_QUERY)
    const authority = authorityOf(request, secure)
    if (request.method !== 'GET' || url.pathname !== CONNECT_PATH || tokens.length !== 1
      || authority === undefined || !equalString(tokens.join(''), this.token)) {
      this.writeUnauthorized(response)
      return
    }
    const peerId = publish(interactions)
    const value = randomBytes(32).toString('hex')
    this.apiCookies.set(value, { peerId, authority })
    response.writeHead(302, {
      'cache-control': 'no-store',
      location: './api/remote.mux',
      'referrer-policy': 'no-referrer',
      'set-cookie': this.cookieHeader(value, secure),
    })
    response.end()
  }

  cookieHeader(value, secure) {
    const attributes = `${COOKIE_NAME}=${value}; Max-Age=${String(COOKIE_MAX_AGE_SECONDS)}; Path=/; HttpOnly; SameSite=Strict`
    return secure ? `${attributes}; Secure` : attributes
  }

  writeUnauthorized(response) {
    response.writeHead(401, { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8' })
    response.end('dsh phone surface: launch token required\n')
  }
}

/** Bridge one node:http request to the Fetch-shaped carrier the Connection owns. */
async function bridge(request, response, handler, peer) {
  const abort = new AbortController()
  response.on('close', () => {
    if (!response.writableEnded) abort.abort()
  })
  const url = new URL(request.url ?? '/', 'http://dsh.internal')
  const headers = Object.fromEntries(Object.entries(request.headers).filter(([, value]) => typeof value === 'string'))
  const mode = handler.requestBodyMode({ method: request.method ?? 'GET', url })
  let body
  if (mode === 'buffered') {
    const declared = Number(request.headers['content-length'] ?? '0')
    if (declared > MAX_REQUEST_BODY_BYTES) {
      response.writeHead(413, { connection: 'close' })
      response.end()
      request.destroy()
      return
    }
    const chunks = []
    let received = 0
    for await (const chunk of request) {
      received += chunk.byteLength
      if (received > MAX_REQUEST_BODY_BYTES) {
        response.writeHead(413, { connection: 'close' })
        response.end()
        request.destroy()
        return
      }
      chunks.push(chunk)
    }
    body = chunks.length > 0 ? Buffer.concat(chunks) : undefined
  } else {
    body = Readable.toWeb(request)
  }
  const fetchRequest = new Request(url, {
    method: request.method ?? 'GET',
    headers,
    ...body === undefined ? {} : { body },
    signal: abort.signal,
    ...mode === 'buffered' ? {} : { duplex: 'half' },
  })
  const result = await handler.fetch(fetchRequest, peer)
  const responseHeaders = {}
  for (const [key, value] of result.headers) responseHeaders[key] = value
  response.writeHead(result.status, responseHeaders)
  if (result.body === null) {
    response.end()
    return
  }
  const reader = result.body.getReader()
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!response.write(value)) await new Promise((resolve) => response.once('drain', resolve))
    }
    response.end()
  } catch (error) {
    response.destroy(error instanceof Error ? error : new Error(String(error)))
  }
}

/**
 * Mount the resident surface. The patch supplies `PDSH_DSH_PORT`; the launch
 * token is mandatory (an empty token would let any loopback client drive the
 * agent, so this fails loudly instead of falling back to an unauthenticated
 * server).
 * @param ctx - plugin context.
 * @param config - `{}` for the `phone-surface` row, or
 *   `{ mode: 'session-persistence', ...backendConfig }` for the
 *   `session-persistence-journaled` row that reuses this package.
 */
export function apply(ctx, config = {}) {
  // One package serves two loader rows: the resident surface (`phone-surface`)
  // and the 0.2.1 persistence adapter (`session-persistence-journaled`). The
  // desktop bundle aliases this package name, so a subpath row cannot resolve.
  if (config?.mode === 'session-persistence') {
    const { mode: _mode, ...backendConfig } = config
    applySessionPersistence(ctx, backendConfig)
    return
  }
  // Add two phone-only Remote methods over existing DSH services: reminder
  // creation (ScheduleService has no upstream Remote) and the public global
  // ToolRuntime schema projection. No state is copied into this adapter.
  ctx.plugin(PhoneManagementRemote)
  const token = process.env.PDSH_DSH_LAUNCH_TOKEN ?? ''
  if (token === '') throw new Error('phone-surface: PDSH_DSH_LAUNCH_TOKEN is required (the phone host generates it per start)')
  const auth = new PhoneLaunchAuth(token)
  const connection = new HostConnectionService(ctx, [], auth)
  // G2-FIX-93: the host's post-termination recovery path opens each affected
  // stored session for writing through this route, so DSH's tool-journal
  // reconcile runs before the host abandons the remaining steps.
  ctx.inject(['sessionPersistence'], recoveryCtx => {
    registerRecoveryRoute(recoveryCtx, connection)
  })
  // G2-FIX-35: the independent Worker-side command acceptance route. It shares
  // the phone connection carrier and launch-token/channel authentication with
  // every other Remote call; the route itself runs the assertion command on an
  // immutable fork of the Worker VFS and never touches the session journal.
  registerWorkerCommandRoute(ctx, connection)
  // G2-F01: the host teardown scopes `subagents.drainDescendants` to the exact
  // App-owned roots it opened or prompted. A spawned child owns its own durable
  // session, so a parent `session/cancel` is not enough to make it terminal.
  // The route waits on the public DSH manager and never writes a session
  // record; the host still verifies DSH's own turn/end before teardown.
  ctx.inject(['agents'], drainCtx => {
    registerDescendantDrainRoute(drainCtx, connection)
  })
  // 0.1.7 exposed the owner peer as `operator`; 0.2.1 renamed it `browserPeer`.
  const ownerPeer = () => connection.browserPeer ?? connection.operator
  let announced = false
  const announce = (port) => {
    if (announced) return
    announced = true
    // `XL_DSH_READY <port>` is the host's readiness contract (LocalDSHHost).
    process.stdout.write(`XL_DSH_READY ${port}\n`)
  }

  ctx.inject(['webServer'], (webCtx) => {
    const fetchHandler = connection.createSharedFetchHandler('/api')
    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: '/',
      handler: (request, response) => {
        auth.authorizeIndex(request, response)
      },
    }), 'phone-surface: launch-token exchange')
    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: CONNECT_PATH,
      handler: (request, response) => {
        if (typeof connection.authorizeConnect === 'function') {
          connection.authorizeConnect(request, response)
          return
        }
        // 0.1.7 has no /connect exchange; the page cookie is the only browser
        // credential there, so keep the route honest instead of crashing.
        response.writeHead(404, { 'cache-control': 'no-store' })
        response.end()
      },
    }), 'phone-surface: operator connect exchange')
    webCtx.effect(() => webCtx.webServer.register({
      kind: 'prefix',
      path: '/api',
      handler: async (request, response) => {
        if (isChannelAuthenticated(request)) {
          await webCtx.waterfall('connection/request', request, response,
            () => bridge(request, response, fetchHandler, ownerPeer()))
          return
        }
        const admission = connection.admit(request)
        if ('rejection' in admission) {
          response.writeHead(admission.rejection)
          response.end(admission.rejection === 401 ? 'unauthorized' : 'forbidden')
          return
        }
        await webCtx.waterfall('connection/request', request, response,
          () => bridge(request, response, fetchHandler, admission.peer))
      },
    }), 'phone-surface: /api RPC carrier')

    // The bundle entry fires appReady after the whole tree (gateway included)
    // is mounted; one macrotask later the mux route is listening too.
    webCtx.inject(['appReady'], (readyCtx) => {
      readyCtx.appReady.onReady(() => {
        setTimeout(() => announce(webCtx.webServer.port), 0)
      })
    })
  })
}
