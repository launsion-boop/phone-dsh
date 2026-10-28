// SPDX-License-Identifier: MIT
/**
 * The `/v1/http` egress bridge of the CPython-on-WASI package.
 *
 * WASI preview1 has no sockets, and the Worker is not allowed to open one:
 * the only network path of the phone Worker is the host's `POST /v1/http`
 * route, which applies the host allow-list and injects the host credentials.
 * A synchronous interpreter cannot use `fetch`, so this module turns the
 * private control descriptor `/__xl__/http` into one loopback request:
 *
 * ```
 * request  = u32 header_len | u32 body_len | JSON header | body
 * response = u32 header_len | JSON header | body
 * ```
 *
 * The request header is `{op:"request", method, url, headers}` with
 * `headers` a string-to-string object; `body_len` must equal the body bytes.
 * The success response header is `{status, reason, headers:[[n,v],...],
 * bodyBytes}` (repeated header names stay repeated) and a failure is
 * `{error:{kind,message}}`. Header, request-body and response-body limits are
 * enforced with a structured failure instead of a silent truncation.
 *
 * The transport is deliberately injectable: production uses a synchronous
 * `XMLHttpRequest`, and tests use a fake. The bearer is the channel token and
 * never travels to Python; a guest `Authorization` header becomes
 * `X-PDSH-Upstream-Authorization`, exactly like the `curl` and `llm-bridge`
 * hosts of the same route.
 *
 * Redirect safety: a synchronous `XMLHttpRequest` has no `redirect: manual`,
 * so a `3xx` answered by `/v1/http` would be followed by the browser before
 * this module can see it. Such a follow-up keeps the channel bearer
 * (same-origin redirects preserve `Authorization`) and, for 307/308, the
 * original body, so an upstream `Location: /v1/exec` could reach another
 * loopback control route. The boundary is therefore the host:
 * `HTTPResponseWriter` strips `Location` from every residual `3xx` on
 * `/v1/http` while preserving its status and body, so no navigable target
 * reaches XHR. Redirects the host egress policy itself permits and follows
 * remain host operations. A residual `3xx` without `Location` is returned to
 * Python as a non-success response; `urllib` raises `HTTPError` for it rather
 * than following. Python automatic redirects through the real bridge are
 * explicitly unsupported.
 * @module @phone-dsh/dsh-wasi-toolbox/http-bridge
 */

import { PDSH_SPAWN_GUEST_ROOT } from './spawn-bridge.ts'

/** Guest root shared with the spawn bridge; one private preopen serves both. */
export const PDSH_HTTP_GUEST_ROOT = PDSH_SPAWN_GUEST_ROOT
/** Exact guest path of the HTTP control file; the Python shim hard-codes it. */
export const PDSH_HTTP_GUEST_PATH = '/__xl__/http'
/** Largest JSON header in either direction. */
export const MAX_HTTP_HEADER_BYTES = 1024 * 1024
/** Largest guest request body. */
export const MAX_HTTP_REQUEST_BODY_BYTES = 16 * 1024 * 1024
/** Largest response body the bridge will hand back to the guest. */
export const MAX_HTTP_RESPONSE_BODY_BYTES = 64 * 1024 * 1024
/** Largest total request frame: prefix + header + body. */
export const MAX_HTTP_REQUEST_FRAME_BYTES = 8 + MAX_HTTP_HEADER_BYTES + MAX_HTTP_REQUEST_BODY_BYTES
/** Host route every request must land on. */
export const PDSH_HTTP_ROUTE = '/v1/http'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/** Stable failure classes the Python shim maps onto `OSError`. */
export type HttpBridgeErrorKind =
  | 'protocol'
  | 'url'
  | 'method'
  | 'limit'
  | 'network'
  | 'transport'
  | 'internal'

/** A failure that must reach Python as a structured response, never a trap. */
export class HttpBridgeError extends Error {
  readonly kind: HttpBridgeErrorKind

  constructor(kind: HttpBridgeErrorKind, message: string) {
    super(message)
    this.name = 'HttpBridgeError'
    this.kind = kind
  }
}

/** One request the guest asked the host route to perform. */
export interface HttpTransportRequest {
  readonly method: string
  /** Absolute upstream URL; only `http:` and `https:` are accepted. */
  readonly url: string
  /** Guest headers; the transport filters those the browser/host owns. */
  readonly headers: Readonly<Record<string, string>>
  readonly body: Uint8Array
}

/** One response the host route returned. */
export interface HttpTransportResponse {
  readonly status: number
  readonly reason: string
  /** Repeated names stay repeated; the Python side turns them into a Message. */
  readonly headers: readonly (readonly [string, string])[]
  readonly body: Uint8Array
}

/** The seam production implements with a synchronous XHR and tests fake. */
export interface HttpTransport {
  request(request: HttpTransportRequest): HttpTransportResponse
}

/** Loopback coordinates the DSH Worker injects into Python. */
export interface LoopbackHttpRoute {
  /** Loopback origin, for example the page origin. */
  readonly origin: string
  /** Ordered-channel bearer; never exposed to the guest. */
  readonly token: string
}

/**
 * Request headers a browser XHR forbids, or the host route owns.
 *
 * `content-length`/`transfer-encoding` are recomputed from the body by the
 * loopback POST; `cookie`/`origin`/`referer`/`user-agent`/`accept-encoding`
 * describe the Worker, not the upstream request; `x-pdsh-*` is the host
 * control plane and a guest must not be able to spoof it.
 */
const FORBIDDEN_REQUEST_HEADERS: ReadonlySet<string> = new Set([
  'host',
  'connection',
  'content-length',
  'transfer-encoding',
  'cookie',
  'cookie2',
  'origin',
  'referer',
  'user-agent',
  'accept-encoding',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'upgrade',
  'keep-alive',
  'expect',
])

/** Response headers the host already decoded or that describe the loopback hop. */
const DROPPED_RESPONSE_HEADERS: ReadonlySet<string> = new Set([
  'content-length',
  'content-encoding',
  'transfer-encoding',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-connection',
  'trailer',
  'upgrade',
  // Browser controls scoped to the loopback origin: a proxy response must not
  // seed/clear the launch cookie or register an alternative service for it.
  // The Swift egress writer strips these first; this is the guest-side backstop.
  'set-cookie',
  'set-cookie2',
  'clear-site-data',
  'alt-svc',
  'alt-used',
])

const METHOD_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
const HEADER_NAME_RE = METHOD_RE

/** The control-file face `WasiPreview1` serves. */
export interface HttpBridge {
  /** Guest root of the control file; every other path below it is ENOENT. */
  readonly guestRoot: string
  /** Exact guest path of the control file. */
  readonly guestPath: string
  /** Serve one complete request frame and return the response frame. */
  dispatch(request: Uint8Array): Uint8Array
}

/** Construction inputs of {@link createHttpBridge}. */
export interface HttpBridgeOptions {
  readonly transport: HttpTransport
}

/**
 * Build the dispatcher the WASI host calls when the guest opens and writes the
 * control file. Every failure is encoded in the response header; a transport
 * error never escapes as a WASI trap.
 * @param options - the transport that owns the loopback hop.
 * @returns the bridge face installed on one `WasiPreview1`.
 */
export function createHttpBridge(options: HttpBridgeOptions): HttpBridge {
  return {
    guestRoot: PDSH_HTTP_GUEST_ROOT,
    guestPath: PDSH_HTTP_GUEST_PATH,
    dispatch(request: Uint8Array): Uint8Array {
      try {
        const decoded = decodeHttpRequest(request)
        return encodeHttpResponse(options.transport.request(decoded))
      } catch (error) {
        const kind: HttpBridgeErrorKind = error instanceof HttpBridgeError ? error.kind : 'internal'
        const message = error instanceof Error ? error.message : String(error)
        return encodeHttpFailure(kind, message)
      }
    },
  }
}

/**
 * Decode and validate one request frame.
 * @param frame - complete request bytes from the guest.
 * @returns the validated request with its body.
 * @throws {HttpBridgeError} for a truncated, oversized or malformed frame.
 */
export function decodeHttpRequest(frame: Uint8Array): HttpTransportRequest {
  if (frame.byteLength < 8) {
    throw new HttpBridgeError('protocol', 'http request is shorter than its 8-byte frame prefix')
  }
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  const headerLength = view.getUint32(0, true)
  const bodyLength = view.getUint32(4, true)
  if (headerLength > MAX_HTTP_HEADER_BYTES) {
    throw new HttpBridgeError(
      'limit',
      `http request header is ${headerLength} bytes; the limit is ${MAX_HTTP_HEADER_BYTES}`,
    )
  }
  if (bodyLength > MAX_HTTP_REQUEST_BODY_BYTES) {
    throw new HttpBridgeError(
      'limit',
      `http request body is ${bodyLength} bytes; the limit is ${MAX_HTTP_REQUEST_BODY_BYTES}`,
    )
  }
  const expected = 8 + headerLength + bodyLength
  if (frame.byteLength !== expected) {
    throw new HttpBridgeError(
      'protocol',
      `http request frame is ${frame.byteLength} bytes but its prefix declares ${expected}`,
    )
  }
  let header: unknown
  try {
    header = JSON.parse(decoder.decode(frame.subarray(8, 8 + headerLength)))
  } catch (error) {
    throw new HttpBridgeError(
      'protocol',
      `http request header is not JSON: ${error instanceof Error ? error.message : String(error)}`,
    )
  }
  if (typeof header !== 'object' || header === null || Array.isArray(header)) {
    throw new HttpBridgeError('protocol', 'http request header must be a JSON object')
  }
  const record = header as Record<string, unknown>
  if (record.op !== 'request') {
    throw new HttpBridgeError('protocol', `unknown http bridge operation ${JSON.stringify(String(record.op))}`)
  }
  const method = record.method
  if (typeof method !== 'string' || method === '' || !METHOD_RE.test(method)) {
    throw new HttpBridgeError('method', 'http request method must be a non-empty HTTP token')
  }
  const url = record.url
  if (typeof url !== 'string' || url === '') {
    throw new HttpBridgeError('url', 'http request url must be a non-empty string')
  }
  validateTargetUrl(url)
  const headers = readHeaders(record.headers)
  return {
    method,
    url,
    headers,
    body: frame.slice(8 + headerLength),
  }
}

/** Encode a success response frame, adding the body byte count to its header. */
export function encodeHttpResponse(response: HttpTransportResponse): Uint8Array {
  const status = Number(response.status)
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    throw new HttpBridgeError('protocol', `http response status ${String(response.status)} is not a valid status code`)
  }
  const body = response.body instanceof Uint8Array ? response.body : new Uint8Array(response.body)
  if (body.byteLength > MAX_HTTP_RESPONSE_BODY_BYTES) {
    throw new HttpBridgeError(
      'limit',
      `http response body is ${body.byteLength} bytes; the limit is ${MAX_HTTP_RESPONSE_BODY_BYTES}`,
    )
  }
  const headers: [string, string][] = []
  for (const pair of response.headers) {
    if (!Array.isArray(pair) || pair.length !== 2) {
      throw new HttpBridgeError('protocol', 'http response headers must be [name, value] pairs')
    }
    const name = pair[0]
    const value = pair[1]
    if (typeof name !== 'string' || typeof value !== 'string') {
      throw new HttpBridgeError('protocol', 'http response header names and values must be strings')
    }
    headers.push([name, value])
  }
  return encodeFrame({
    status,
    reason: typeof response.reason === 'string' ? response.reason : '',
    headers,
    bodyBytes: body.byteLength,
  }, body)
}

/**
 * Encode one failure header. A transport or protocol failure is always a
 * readable frame; the Python shim turns it into `OSError`/`URLError`.
 */
export function encodeHttpFailure(kind: HttpBridgeErrorKind, message: string): Uint8Array {
  return encodeFrame({ error: { kind, message: safeMessage(message) } }, new Uint8Array(0))
}

/** Build a response frame from a header object and binary body. */
function encodeFrame(header: Record<string, unknown>, body: Uint8Array): Uint8Array {
  const bytes = encoder.encode(JSON.stringify(header))
  if (bytes.byteLength > MAX_HTTP_HEADER_BYTES) {
    throw new HttpBridgeError(
      'limit',
      `http response header is ${bytes.byteLength} bytes; the limit is ${MAX_HTTP_HEADER_BYTES}`,
    )
  }
  const out = new Uint8Array(4 + bytes.byteLength + body.byteLength)
  new DataView(out.buffer, out.byteOffset, out.byteLength).setUint32(0, bytes.byteLength, true)
  out.set(bytes, 4)
  out.set(body, 4 + bytes.byteLength)
  return out
}

/** Keep an error header bounded and free of line breaks a log could split on. */
function safeMessage(message: string): string {
  const text = String(message).replace(/[\r\n]+/gu, ' ')
  return text.length > 4096 ? `${text.slice(0, 4096)}...` : text
}

/** Validate an upstream URL: absolute, http/https and with a host. */
export function validateTargetUrl(url: string): URL {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new HttpBridgeError('url', `http request url ${JSON.stringify(url)} is not absolute`)
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new HttpBridgeError('url', `http request protocol ${parsed.protocol} is not http or https`)
  }
  if (parsed.hostname === '') {
    throw new HttpBridgeError('url', 'http request url has no host')
  }
  return parsed
}

/** Validate the guest header object and drop nothing here: the transport filters. */
function readHeaders(value: unknown): Record<string, string> {
  if (value === undefined) return {}
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new HttpBridgeError('protocol', 'http request headers must be a JSON object')
  }
  const headers: Record<string, string> = {}
  for (const [name, headerValue] of Object.entries(value as Record<string, unknown>)) {
    if (!HEADER_NAME_RE.test(name)) {
      throw new HttpBridgeError('protocol', `http request header name ${JSON.stringify(name)} is not a token`)
    }
    if (typeof headerValue !== 'string') {
      throw new HttpBridgeError('protocol', `http request header ${name} is not a string`)
    }
    if (/[\r\n\0]/u.test(headerValue)) {
      throw new HttpBridgeError('protocol', `http request header ${name} contains a line break or NUL`)
    }
    headers[name] = headerValue
  }
  return headers
}

/** A synchronous XMLHttpRequest face; the real class satisfies it structurally. */
export interface XhrLike {
  open(method: string, url: string, async: boolean): void
  setRequestHeader(name: string, value: string): void
  send(body?: Uint8Array | ArrayBuffer | string | null): void
  status: number
  statusText: string
  response: unknown
  responseType: string
  getAllResponseHeaders(): string
}

/** Construction inputs of {@link createLoopbackXhrTransport}. */
export interface LoopbackXhrTransportOptions extends LoopbackHttpRoute {
  /** Test seam; defaults to `new XMLHttpRequest()`. */
  readonly xhrFactory?: () => XhrLike
}

/**
 * Build the production transport: one synchronous `XMLHttpRequest` to
 * `POST <origin>/v1/http`. No request leaves any other path.
 * @param options - loopback origin, channel bearer and an optional XHR factory.
 * @returns the transport installed on the python tool worker.
 */
export function createLoopbackXhrTransport(options: LoopbackXhrTransportOptions): HttpTransport {
  if (typeof options.origin !== 'string' || options.origin === '') {
    throw new HttpBridgeError('url', 'the loopback http route needs a non-empty origin')
  }
  let origin: URL
  try {
    origin = new URL(options.origin)
  } catch {
    throw new HttpBridgeError('url', `the loopback http origin ${JSON.stringify(options.origin)} is not a URL`)
  }
  if (origin.protocol !== 'http:' && origin.protocol !== 'https:') {
    throw new HttpBridgeError('url', `the loopback http origin protocol ${origin.protocol} is not http or https`)
  }
  if (typeof options.token !== 'string' || options.token === '' || /[\r\n\0]/u.test(options.token)) {
    throw new HttpBridgeError('protocol', 'the loopback http route needs a valid channel bearer')
  }
  const endpoint = new URL(PDSH_HTTP_ROUTE, origin).href
  const token = options.token
  const factory = options.xhrFactory ?? defaultXhrFactory

  return {
    request(request: HttpTransportRequest): HttpTransportResponse {
      validateRequestShape(request)
      let xhr: XhrLike
      try {
        xhr = factory()
      } catch (error) {
        if (error instanceof HttpBridgeError) throw error
        throw new HttpBridgeError(
          'transport',
          `this host cannot build an XMLHttpRequest for /v1/http: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      try {
        xhr.open('POST', endpoint, false)
        try {
          xhr.responseType = 'arraybuffer'
        } catch {
          // A text fallback would UTF-8-encode the body: arbitrary bytes do not
          // survive, so a binary payload would silently become corrupt. Refuse
          // the request with a structured transport failure instead.
          throw new HttpBridgeError(
            'transport',
            'this host cannot read the /v1/http response as bytes: '
              + 'synchronous XMLHttpRequest rejected responseType="arraybuffer"; a lossy text fallback is refused',
          )
        }
        const headers: Record<string, string> = {}
        for (const [name, value] of Object.entries(request.headers)) {
          if (forbiddenRequestHeader(name)) continue
          headers[name] = value
        }
        let upstreamAuthorization: string | undefined
        for (const name of Object.keys(headers)) {
          if (name.toLowerCase() !== 'authorization') continue
          upstreamAuthorization ??= headers[name]
          delete headers[name]
        }
        for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, value)
        xhr.setRequestHeader('X-PDSH-Target-URL', request.url)
        xhr.setRequestHeader('X-PDSH-Target-Method', request.method)
        if (upstreamAuthorization !== undefined) {
          xhr.setRequestHeader('X-PDSH-Upstream-Authorization', upstreamAuthorization)
        }
        xhr.setRequestHeader('Authorization', `Bearer ${token}`)
        xhr.send(request.body.byteLength === 0 ? null : request.body)
      } catch (error) {
        if (error instanceof HttpBridgeError) throw error
        throw new HttpBridgeError(
          'network',
          `the loopback /v1/http request failed: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      let status: number
      try {
        status = xhr.status
      } catch (error) {
        throw new HttpBridgeError(
          'transport',
          `the loopback /v1/http status could not be read: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      // A real failed XHR reports status 0 with `response === null`. Classify
      // the network failure before touching the body or headers.
      if (status === 0) {
        throw new HttpBridgeError('network', 'the loopback /v1/http request returned status 0 (no network response)')
      }
      if (status < 100 || status > 599) {
        throw new HttpBridgeError('network', `the loopback /v1/http request returned invalid status ${status}`)
      }
      let reason: string
      let rawHeaders: string
      let body: Uint8Array
      try {
        reason = xhr.statusText
        body = responseBody(xhr)
        rawHeaders = xhr.getAllResponseHeaders()
      } catch (error) {
        if (error instanceof HttpBridgeError) throw error
        throw new HttpBridgeError(
          'transport',
          `the loopback /v1/http response could not be read: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      if (body.byteLength > MAX_HTTP_RESPONSE_BODY_BYTES) {
        throw new HttpBridgeError(
          'limit',
          `http response body is ${body.byteLength} bytes; the limit is ${MAX_HTTP_RESPONSE_BODY_BYTES}`,
        )
      }
      return {
        status,
        reason: reason ?? '',
        headers: parseResponseHeaders(rawHeaders),
        body,
      }
    },
  }
}

/** Validate a transport request before an XHR is even constructed. */
function validateRequestShape(request: HttpTransportRequest): void {
  if (typeof request.method !== 'string' || request.method === '' || !METHOD_RE.test(request.method)) {
    throw new HttpBridgeError('method', 'http request method must be a non-empty HTTP token')
  }
  validateTargetUrl(request.url)
  if (!(request.body instanceof Uint8Array)) {
    throw new HttpBridgeError('protocol', 'http request body must be a Uint8Array')
  }
  if (request.body.byteLength > MAX_HTTP_REQUEST_BODY_BYTES) {
    throw new HttpBridgeError(
      'limit',
      `http request body is ${request.body.byteLength} bytes; the limit is ${MAX_HTTP_REQUEST_BODY_BYTES}`,
    )
  }
}

/** True when the browser or the host route owns this request header. */
export function forbiddenRequestHeader(name: string): boolean {
  const lower = name.toLowerCase()
  return FORBIDDEN_REQUEST_HEADERS.has(lower) || lower.startsWith('x-pdsh-') || lower.startsWith('proxy-')
}

/** True when the host already handled this response header. */
function droppedResponseHeader(name: string): boolean {
  return DROPPED_RESPONSE_HEADERS.has(name.toLowerCase())
}

/** Split `getAllResponseHeaders()` keeping repeated names as separate pairs. */
function parseResponseHeaders(raw: string): [string, string][] {
  const headers: [string, string][] = []
  for (const line of raw.split(/\r?\n/u)) {
    if (line === '') continue
    const separator = line.indexOf(':')
    if (separator <= 0) continue
    const name = line.slice(0, separator).trim()
    if (name === '' || droppedResponseHeader(name)) continue
    headers.push([name, line.slice(separator + 1).trim()])
  }
  return headers
}

/** Read the response bytes; a non-binary XHR face is a structured failure. */
function responseBody(xhr: XhrLike): Uint8Array {
  const response = xhr.response
  if (response instanceof Uint8Array) return response
  if (response instanceof ArrayBuffer) return new Uint8Array(response)
  if (ArrayBuffer.isView(response)) {
    const view = response as ArrayBufferView
    return new Uint8Array(view.buffer, view.byteOffset, view.byteLength)
  }
  throw new HttpBridgeError(
    'transport',
    'the loopback /v1/http response body is not binary; refusing to reinterpret it as text',
  )
}

function defaultXhrFactory(): XhrLike {
  const ctor = (globalThis as { XMLHttpRequest?: new () => XhrLike }).XMLHttpRequest
  if (ctor === undefined) {
    throw new HttpBridgeError('transport', 'this host has no XMLHttpRequest for the loopback /v1/http route')
  }
  return new ctor()
}
