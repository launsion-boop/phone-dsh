// SPDX-License-Identifier: MIT
/**
 * The HTTP transport git uses for `clone`/`fetch`/`push`.
 *
 * A Worker has no sockets. Every request is a same-origin `fetch` to the host
 * loopback route `POST /v1/http`, carrying the upstream URL and method in
 * `X-PDSH-Target-URL` / `X-PDSH-Target-Method` and the channel bearer in
 * `Authorization` — the same egress the `curl` shim uses (phone-dsh-v1). The
 * host owns the allow-list: a rejected origin answers 403 and the git command
 * fails loud instead of finding a second path. Tests inject a transport that
 * talks to an in-process smart-HTTP server, so no socket is opened either.
 * @module @phone-dsh/dsh-wasi-toolbox/git/http
 */
import { fatal } from './errors.ts'

/** One HTTP response, body fully collected. */
export interface HttpResult {
  readonly status: number
  readonly body: Uint8Array
  readonly contentType?: string
}

/** One HTTP request the smart-HTTP client makes. */
export interface HttpRequest {
  readonly url: string
  readonly method: 'GET' | 'POST'
  readonly headers: Readonly<Record<string, string>>
  readonly body?: Uint8Array
}

/** The narrow transport the remote commands need. */
export interface RemoteTransport {
  request(request: HttpRequest): Promise<HttpResult>
}

/** Coordinates of the host `/v1/http` route. */
export interface HostHttpOptions {
  /** Loopback origin (for example `http://127.0.0.1:41234`). */
  readonly origin?: string | undefined
  /** Channel bearer token. */
  readonly token?: string | undefined
  /** Fetch used for the loopback hop; defaults to `globalThis.fetch`. */
  readonly fetch?: typeof fetch | undefined
}

/** Resolve the loopback route from explicit options or the Worker environment. */
export function resolveHostHttp(options: HostHttpOptions = {}): { origin: string; token: string } | undefined {
  const env = process.env
  const origin = options.origin ?? env.PDSH_CHANNEL_ORIGIN ?? env.PDSH_EXEC_BRIDGE_URL
  const token = options.token ?? env.PDSH_CHANNEL_TOKEN ?? env.PDSH_EXEC_BRIDGE_TOKEN
  if (origin === undefined || origin === '' || token === undefined || token === '') return undefined
  return { origin: origin.replace(/\/+$/, ''), token }
}

/** Percent-encode the Basic credentials a URL may carry. */
function basicAuthorization(url: URL): string | undefined {
  if (url.username === '' && url.password === '') return undefined
  const raw = `${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`
  return `Basic ${btoa(raw)}`
}

/** `RemoteTransport` over the host `/v1/http` route. */
export class HostHttpTransport implements RemoteTransport {
  private readonly route: { origin: string; token: string }
  private readonly fetchImpl: typeof fetch

  constructor(options: HostHttpOptions = {}) {
    const route = resolveHostHttp(options)
    if (route === undefined) {
      throw fatal('no host /v1/http route for git (set PDSH_CHANNEL_ORIGIN and PDSH_CHANNEL_TOKEN)')
    }
    this.route = route
    const fetchImpl = options.fetch ?? globalThis.fetch
    if (typeof fetchImpl !== 'function') throw fatal('this runtime has no fetch for the host /v1/http route')
    this.fetchImpl = fetchImpl
  }

  async request(request: HttpRequest): Promise<HttpResult> {
    const target = new URL(request.url)
    const authorization = basicAuthorization(target)
    const headers: Record<string, string> = {
      ...request.headers,
      'X-PDSH-Target-URL': request.url,
      'X-PDSH-Target-Method': request.method,
      Authorization: `Bearer ${this.route.token}`,
    }
    if (authorization !== undefined) headers['X-PDSH-Upstream-Authorization'] = authorization
    const response = await this.fetchImpl(new URL('/v1/http', this.route.origin), {
      method: 'POST',
      headers,
      ...request.body === undefined ? {} : { body: request.body as unknown as BodyInit },
    })
    const body = new Uint8Array(await response.arrayBuffer())
    if (response.status === 403) {
      throw fatal(
        `the host allow-list rejected ${redactUrl(request.url)} (403): the repository origin is not permitted `
        + 'by the Worker egress policy. Nothing was written.',
      )
    }
    if (response.status === 401) {
      throw fatal(`the host rejected the git credentials for ${redactUrl(request.url)} (401)`)
    }
    return {
      status: response.status,
      body,
      ...response.headers.get('content-type') === null
        ? {}
        : { contentType: response.headers.get('content-type') as string },
    }
  }
}

/** Drop credentials from a URL before printing it. */
export function redactUrl(url: string): string {
  try {
    const parsed = new URL(url)
    if (parsed.username !== '' || parsed.password !== '') {
      parsed.username = '***'
      parsed.password = ''
    }
    return parsed.toString()
  } catch {
    return url
  }
}
