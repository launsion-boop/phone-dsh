// SPDX-License-Identifier: MIT
/**
 * A WHATWG `fetch` implemented on node:http / node:https instead of undici.
 *
 * Under `node --jitless` (required on iOS, where JIT pages are not allowed)
 * WebAssembly is undefined, and Node's built-in fetch fails on its first
 * request because undici's HTTP parser is llhttp compiled to WebAssembly.
 * `Request`, `Response`, `Headers` and web streams are plain JavaScript and
 * keep working, so this module only replaces the transport underneath them.
 *
 * The node:http(s), node:stream and node:zlib clients are resolved with
 * `import()` on the first request that reaches this desktop transport. The
 * package entry exposes a lazily forwarding `createNodeFetch`, so no builtin is
 * evaluated at plugin load in the Worker; the Worker module table has no usable
 * TLS/net/zlib client, and no Worker code path ever calls the loader below.
 *
 * Optional host route: requests whose URL matches `proxy.match` are sent to
 * the host app's exec-bridge `POST /v1/http` endpoint instead (spec section 6),
 * so the app's own HTTP stack carries them and can inject credentials.
 * @module @phone-dsh/dsh-llm-bridge/node-fetch
 */

import type { Readable } from 'node:stream'

export interface HostProxyOptions {
  /** Exec-bridge base URL (loopback). */
  url: string
  /** Exec-bridge bearer token. */
  token: string
  /** Which upstream URLs go through the host; default: every http(s) URL that is not loopback. */
  match?: (url: URL) => boolean
}

export interface NodeFetchOptions {
  proxy?: HostProxyOptions | undefined
  /** Extra headers per request (e.g. the tool-call idempotency key); return undefined for none. */
  extraHeaders?: ((url: URL, viaProxy: boolean) => Record<string, string> | undefined) | undefined
  /** Redirect hop limit (fetch's own limit is 20). */
  maxRedirects?: number
}

const NULL_BODY_STATUS = new Set([101, 103, 204, 205, 304])
const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308])
const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer'])

/** The node:http(s)/stream/zlib client surface this transport needs, resolved lazily. */
interface NodeClient {
  readonly http: typeof import('node:http')
  readonly https: typeof import('node:https')
  readonly zlib: typeof import('node:zlib')
  /** `Readable.toWeb` from node:stream, loaded with the rest of the desktop client. */
  readonly toWeb: (stream: Readable) => ReadableStream<Uint8Array>
  readonly agents: {
    readonly 'http:': InstanceType<typeof import('node:http').Agent>
    readonly 'https:': InstanceType<typeof import('node:https').Agent>
  }
}

let nodeClient: Promise<NodeClient> | undefined

/**
 * Load the desktop transport on first use. This is the only place the
 * node:http(s)/stream/zlib clients are referenced, and it runs only when a
 * request is actually sent through the node transport (never on the Worker
 * `/v1/http` route, which uses the platform fetch).
 */
function loadNodeClient(): Promise<NodeClient> {
  nodeClient ??= (async () => {
    const [http, https, zlib, stream] = await Promise.all([
      import('node:http'),
      import('node:https'),
      import('node:zlib'),
      import('node:stream'),
    ])
    return {
      http,
      https,
      zlib,
      toWeb: stream.Readable.toWeb as unknown as (stream: Readable) => ReadableStream<Uint8Array>,
      agents: {
        'http:': new http.Agent({ keepAlive: true }),
        'https:': new https.Agent({ keepAlive: true }),
      },
    }
  })()
  return nodeClient
}

export function isLoopback(url: URL): boolean {
  return url.hostname === '127.0.0.1' || url.hostname === '[::1]' || url.hostname === '::1' || url.hostname === 'localhost'
}

/** fetch-shaped failure, matching undici's `TypeError: fetch failed` so callers classify it as transport. */
function fetchFailed(cause: unknown): TypeError {
  return new TypeError('fetch failed', { cause })
}

/**
 * Create a fetch function backed by node:http(s).
 * @param options - optional host proxy route and per-request header hook.
 * @returns a function with the global fetch signature.
 */
export function createNodeFetch(options: NodeFetchOptions = {}): typeof fetch {
  const maxRedirects = options.maxRedirects ?? 20
  const proxy = options.proxy
  const proxyUrl = proxy === undefined ? undefined : new URL('/v1/http', proxy.url)
  if (proxyUrl !== undefined && (proxyUrl.protocol !== 'http:' || !isLoopback(proxyUrl))) {
    throw new Error('llm-bridge: the host proxy must be the loopback exec bridge (http://127.0.0.1:<port>)')
  }
  const routeViaProxy = (url: URL): boolean => proxy !== undefined && (proxy.match ?? ((u: URL) => !isLoopback(u)))(url)

  const nodeFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    const signal = request.signal
    signal.throwIfAborted()
    // Buffer the body once: model and MCP requests are JSON, and a buffered body
    // can be replayed across redirects and carries an exact Content-Length.
    let body: Buffer | undefined = request.body === null ? undefined : Buffer.from(await request.arrayBuffer())
    let method = request.method
    let url = new URL(request.url)
    const headers = new Headers(request.headers)
    if (!headers.has('accept-encoding')) headers.set('accept-encoding', 'gzip, deflate, br')
    if (!headers.has('accept')) headers.set('accept', '*/*')
    const client = await loadNodeClient()

    for (let hop = 0; ; hop++) {
      if (url.protocol !== 'http:' && url.protocol !== 'https:') throw fetchFailed(new Error(`unsupported scheme ${url.protocol}`))
      const viaProxy = routeViaProxy(url)
      const response = await send(client, url, method, headers, body, signal, viaProxy)
      const status = response.statusCode ?? 0
      if (REDIRECT_STATUS.has(status) && request.redirect !== 'manual' && response.headers.location !== undefined) {
        response.resume()
        if (request.redirect === 'error') throw fetchFailed(new Error(`unexpected redirect to ${response.headers.location}`))
        if (hop + 1 > maxRedirects) throw fetchFailed(new Error('redirect count exceeded'))
        const next = new URL(response.headers.location, url)
        if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
          method = 'GET'
          body = undefined
          for (const name of ['content-type', 'content-length', 'content-encoding', 'content-language', 'content-location']) headers.delete(name)
        }
        if (next.origin !== url.origin) {
          headers.delete('authorization')
          headers.delete('cookie')
          headers.delete('proxy-authorization')
        }
        url = next
        continue
      }
      return toResponse(client, response, url, method, hop > 0, signal)
    }
  }

  function send(client: NodeClient, url: URL, method: string, headers: Headers, body: Buffer | undefined, signal: AbortSignal, viaProxy: boolean): Promise<import('node:http').IncomingMessage> {
    return new Promise<import('node:http').IncomingMessage>((resolve, reject) => {
      const outgoing: Record<string, string | string[]> = {}
      headers.forEach((value, name) => { outgoing[name] = value })
      const extra = options.extraHeaders?.(url, viaProxy)
      if (extra !== undefined) Object.assign(outgoing, extra)
      let target = url
      let transport: typeof import('node:http') | typeof import('node:https') = url.protocol === 'https:' ? client.https : client.http
      let agent: InstanceType<typeof import('node:http').Agent> = client.agents[url.protocol as 'http:' | 'https:']
      let outMethod = method
      if (viaProxy && proxyUrl !== undefined && proxy !== undefined) {
        if (outgoing.authorization !== undefined) {
          outgoing['x-pdsh-upstream-authorization'] = outgoing.authorization
          delete outgoing.authorization
        }
        outgoing['x-pdsh-target-url'] = url.href
        outgoing['x-pdsh-target-method'] = method
        outgoing.authorization = `Bearer ${proxy.token}`
        target = proxyUrl
        transport = client.http
        agent = client.agents['http:']
        outMethod = 'POST'
      }
      if (body !== undefined) outgoing['content-length'] = String(body.length)
      const req = transport.request(target, { method: outMethod, headers: outgoing, agent })
      const onAbort = (): void => { req.destroy(signal.reason instanceof Error ? signal.reason : new Error('aborted')) }
      signal.addEventListener('abort', onAbort, { once: true })
      req.once('response', (response) => {
        signal.removeEventListener('abort', onAbort)
        resolve(response)
      })
      req.once('error', (error) => {
        signal.removeEventListener('abort', onAbort)
        reject(signal.aborted ? signal.reason : fetchFailed(error))
      })
      req.end(body)
    })
  }

  function toResponse(client: NodeClient, response: import('node:http').IncomingMessage, url: URL, method: string, redirected: boolean, signal: AbortSignal): Response {
    const status = response.statusCode ?? 0
    const headers = new Headers()
    for (let i = 0; i < response.rawHeaders.length; i += 2) {
      const name = response.rawHeaders[i] as string
      if (HOP_BY_HOP.has(name.toLowerCase())) continue
      headers.append(name, response.rawHeaders[i + 1] as string)
    }
    let body: ReadableStream<Uint8Array> | null = null
    if (!NULL_BODY_STATUS.has(status) && method !== 'HEAD') {
      let stream: Readable = response
      const encoding = (response.headers['content-encoding'] ?? '').toLowerCase().trim()
      const decoder = encoding === 'gzip' || encoding === 'x-gzip'
        ? client.zlib.createGunzip({ flush: client.zlib.constants.Z_SYNC_FLUSH, finishFlush: client.zlib.constants.Z_SYNC_FLUSH })
        : encoding === 'deflate'
          ? client.zlib.createInflate({ flush: client.zlib.constants.Z_SYNC_FLUSH, finishFlush: client.zlib.constants.Z_SYNC_FLUSH })
          : encoding === 'br' ? client.zlib.createBrotliDecompress() : undefined
      if (decoder !== undefined) {
        response.on('error', (error) => { decoder.destroy(error) })
        stream = response.pipe(decoder)
      }
      const onAbort = (): void => { response.destroy(signal.reason instanceof Error ? signal.reason : new Error('aborted')); stream.destroy(signal.reason) }
      signal.addEventListener('abort', onAbort, { once: true })
      stream.once('close', () => { signal.removeEventListener('abort', onAbort) })
      body = client.toWeb(stream)
    } else {
      response.resume()
    }
    const result = new Response(body, { status, statusText: response.statusMessage ?? '', headers })
    Object.defineProperty(result, 'url', { value: url.href })
    Object.defineProperty(result, 'redirected', { value: redirected })
    return result
  }

  return nodeFetch as typeof fetch
}
