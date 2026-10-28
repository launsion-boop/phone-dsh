// SPDX-License-Identifier: MIT
/**
 * G2-FIX-67 transport half: the private `/__xl__/http` control descriptor and
 * the synchronous `/v1/http` XHR bridge.
 *
 * These tests use a fake XMLHttpRequest and an in-memory WASI host. No model,
 * phone, WKWebView or real socket is involved.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  createHttpBridge,
  createLoopbackXhrTransport,
  decodeHttpRequest,
  encodeHttpFailure,
  encodeHttpResponse,
  forbiddenRequestHeader,
  HttpBridgeError,
  MAX_HTTP_HEADER_BYTES,
  MAX_HTTP_REQUEST_BODY_BYTES,
  MAX_HTTP_REQUEST_FRAME_BYTES,
  MAX_HTTP_RESPONSE_BODY_BYTES,
  PDSH_HTTP_GUEST_PATH,
} from '../wasi-toolbox/src/http-bridge.ts'
import type {
  HttpTransport,
  HttpTransportRequest,
  XhrLike,
} from '../wasi-toolbox/src/http-bridge.ts'
import { MemoryWasiVfs } from '../wasi-toolbox/src/memory-wasi-vfs.ts'
import { WASI_ERRNO } from '../wasi-toolbox/src/wasi-errno.ts'
import { WasiPreview1 } from '../wasi-toolbox/src/wasi-preview1.ts'
import { MemoryVfsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import type { ToolWorkerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import { PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import { resolvePythonHttpRoute } from '../worker-entry/src/python-toolbox.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function requestFrame(header: Record<string, unknown>, body = new Uint8Array(0)): Uint8Array {
  const headerBytes = encoder.encode(JSON.stringify(header))
  const out = new Uint8Array(8 + headerBytes.byteLength + body.byteLength)
  const view = new DataView(out.buffer)
  view.setUint32(0, headerBytes.byteLength, true)
  view.setUint32(4, body.byteLength, true)
  out.set(headerBytes, 8)
  out.set(body, 8 + headerBytes.byteLength)
  return out
}

function readResponseFrame(frame: Uint8Array): { header: Record<string, unknown>; body: Uint8Array } {
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  const headerLength = view.getUint32(0, true)
  const header = JSON.parse(decoder.decode(frame.subarray(4, 4 + headerLength))) as Record<string, unknown>
  return { header, body: frame.slice(4 + headerLength) }
}

class FakeXhr implements XhrLike {
  readonly opened: { method: string; url: string; async: boolean }[] = []
  readonly requestHeaders: Record<string, string> = {}
  statusText = 'OK'
  responseHeaderText = ''
  sentBody: Uint8Array | ArrayBuffer | string | null = null
  sendCount = 0
  sendError: Error | undefined
  responseTypeError: Error | undefined
  private responseTypeValue = ''
  private currentStatus = 200
  private currentResponse: unknown = new ArrayBuffer(0)
  private currentResponseText = ''

  get responseType(): string {
    return this.responseTypeValue
  }

  set responseType(value: string) {
    if (this.responseTypeError !== undefined) throw this.responseTypeError
    this.responseTypeValue = value
  }

  get status(): number {
    return this.currentStatus
  }

  set status(value: number) {
    this.currentStatus = value
  }

  get response(): unknown {
    // A real failed XHR has no response at all; it never delivers a body.
    return this.currentStatus === 0 ? null : this.currentResponse
  }

  set response(value: unknown) {
    this.currentResponse = value
  }

  get responseText(): string {
    if (this.currentStatus === 0) {
      // Mirrors WebKit/Blink: responseText is not readable for a failed XHR.
      const error = new Error('the response is not available when status is 0')
      error.name = 'InvalidStateError'
      throw error
    }
    return this.currentResponseText
  }

  set responseText(value: string) {
    this.currentResponseText = value
  }

  open(method: string, url: string, async: boolean): void {
    this.opened.push({ method, url, async })
  }

  setRequestHeader(name: string, value: string): void {
    this.requestHeaders[name] = value
  }

  send(body?: Uint8Array | ArrayBuffer | string | null): void {
    this.sendCount += 1
    this.sentBody = body ?? null
    if (this.sendError !== undefined) throw this.sendError
  }

  getAllResponseHeaders(): string {
    return this.responseHeaderText
  }
}

function responseOf(body: Uint8Array, headers: [string, string][] = []): HttpTransport {
  return {
    request(request: HttpTransportRequest) {
      void request
      return { status: 200, reason: 'OK', headers, body }
    },
  }
}

test('http bridge frame: decode accepts a valid request and rejects malformed frames', () => {
  const body = encoder.encode('{"hello":"world"}')
  const frame = requestFrame({
    op: 'request',
    method: 'POST',
    url: 'https://example.test/upload?q=1',
    headers: { 'Content-Type': 'application/json' },
  }, body)
  const decoded = decodeHttpRequest(frame)
  assert.equal(decoded.method, 'POST')
  assert.equal(decoded.url, 'https://example.test/upload?q=1')
  assert.deepEqual(decoded.headers, { 'Content-Type': 'application/json' })
  assert.deepEqual([...decoded.body], [...body])

  assert.throws(
    () => decodeHttpRequest(frame.slice(0, frame.byteLength - 1)),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'protocol',
  )
  assert.throws(
    () => decodeHttpRequest(new Uint8Array([1, 2, 3])),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'protocol',
  )
  assert.throws(
    () => decodeHttpRequest(requestFrame({ op: 'other', method: 'GET', url: 'http://a.test/' })),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'protocol',
  )
  assert.throws(
    () => decodeHttpRequest(requestFrame({ op: 'request', method: 'BAD METHOD', url: 'http://a.test/' })),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'method',
  )
  assert.throws(
    () => decodeHttpRequest(requestFrame({ op: 'request', method: 'GET', url: 'ftp://a.test/' })),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'url',
  )
  assert.throws(
    () => decodeHttpRequest(requestFrame({ op: 'request', method: 'GET', url: 'http://a.test/', headers: { 'X-Test': 1 } })),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'protocol',
  )
  assert.throws(
    () => decodeHttpRequest(requestFrame({ op: 'request', method: 'GET', url: 'http://a.test/', headers: { 'Bad Name': 'x' } })),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'protocol',
  )
})

test('http bridge frame: header and body limits are structured errors, not truncation', () => {
  const oversizedHeader = new Uint8Array(8 + 1)
  new DataView(oversizedHeader.buffer).setUint32(0, MAX_HTTP_HEADER_BYTES + 1, true)
  assert.throws(
    () => decodeHttpRequest(oversizedHeader),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'limit',
  )

  const oversizedBody = new Uint8Array(8)
  new DataView(oversizedBody.buffer).setUint32(4, MAX_HTTP_REQUEST_BODY_BYTES + 1, true)
  assert.throws(
    () => decodeHttpRequest(oversizedBody),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'limit',
  )

  const huge = new Uint8Array(MAX_HTTP_RESPONSE_BODY_BYTES + 1)
  assert.throws(
    () => encodeHttpResponse({ status: 200, reason: 'OK', headers: [], body: huge }),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'limit',
  )

  const failure = readResponseFrame(encodeHttpFailure('network', 'offline'))
  assert.deepEqual(failure.header, { error: { kind: 'network', message: 'offline' } })
  assert.equal(failure.body.byteLength, 0)
})

test('http bridge: a response keeps repeated headers and encodes status/reason/body', () => {
  const bridge = createHttpBridge({
    transport: responseOf(encoder.encode('payload'), [
      ['X-Twice', 'a'],
      ['X-Twice', 'b'],
      ['X-Test', 'yes'],
    ]),
  })
  const request = requestFrame({
    op: 'request',
    method: 'GET',
    url: 'https://example.test/',
    headers: {},
  })
  const { header, body } = readResponseFrame(bridge.dispatch(request))
  assert.equal(header['status'], 200)
  assert.equal(header['reason'], 'OK')
  assert.equal(header['bodyBytes'], 7)
  assert.deepEqual(header['headers'], [
    ['X-Twice', 'a'],
    ['X-Twice', 'b'],
    ['X-Test', 'yes'],
  ])
  assert.equal(decoder.decode(body), 'payload')
})

test('http bridge: transport failures become structured error frames, never traps', () => {
  const bridge = createHttpBridge({
    transport: {
      request() {
        throw new Error('host allow-list rejected the target')
      },
    },
  })
  const { header, body } = readResponseFrame(bridge.dispatch(requestFrame({
    op: 'request',
    method: 'GET',
    url: 'https://blocked.test/',
  })))
  assert.deepEqual(header, { error: { kind: 'internal', message: 'host allow-list rejected the target' } })
  assert.equal(body.byteLength, 0)

  const badBridge = createHttpBridge({
    transport: { request: () => ({ status: 99, reason: '', headers: [], body: new Uint8Array(0) }) },
  })
  const bad = readResponseFrame(badBridge.dispatch(requestFrame({
    op: 'request',
    method: 'GET',
    url: 'https://example.test/',
  })))
  assert.equal((bad.header['error'] as { kind: string }).kind, 'protocol')

  const badUrl = readResponseFrame(bridge.dispatch(requestFrame({
    op: 'request',
    method: 'GET',
    url: 'file:///etc/passwd',
  })))
  assert.equal((badUrl.header['error'] as { kind: string }).kind, 'url')

  const transportFailure = readResponseFrame(createHttpBridge({
    transport: {
      request() {
        throw new HttpBridgeError('transport', 'the loopback answered from another route')
      },
    },
  }).dispatch(requestFrame({
    op: 'request',
    method: 'GET',
    url: 'https://example.test/',
  })))
  assert.deepEqual(transportFailure.header, {
    error: { kind: 'transport', message: 'the loopback answered from another route' },
  })
})

test('loopback XHR transport: one POST /v1/http with target headers, bearer and upstream auth', () => {
  const fake = new FakeXhr()
  fake.status = 201
  fake.statusText = 'Created'
  fake.response = encoder.encode('created').buffer
  fake.responseHeaderText = [
    'Set-Cookie: xl_launch_token=stolen; Path=/',
    'Set-Cookie2: legacy=stolen; Path=/',
    'Clear-Site-Data: "cookies"',
    'Alt-Svc: h2=":443"; ma=86400',
    'X-Twice: a',
    'X-Twice: b',
    'X-Test: yes',
    'Content-Length: 7',
    'Content-Encoding: gzip',
    'Transfer-Encoding: chunked',
    'Connection: keep-alive',
  ].join('\r\n')
  let factories = 0
  const transport = createLoopbackXhrTransport({
    origin: 'https://loopback.test:8443',
    token: 'channel-secret',
    xhrFactory: () => {
      factories += 1
      return fake
    },
  })
  const response = transport.request({
    method: 'POST',
    url: 'https://upstream.test/api?x=1',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer upstream-token',
      Host: 'evil.test',
      Cookie: 'session=1',
      Origin: 'https://evil.test',
      Referer: 'https://evil.test/',
      'User-Agent': 'guest-agent',
      'Accept-Encoding': 'gzip',
      'X-PDSH-Target-URL': 'https://evil.test/',
      'Proxy-Authorization': 'proxy',
      'X-Keep': 'yes',
    },
    body: encoder.encode('{"a":1}'),
  })

  assert.equal(factories, 1)
  assert.deepEqual(fake.opened, [{ method: 'POST', url: 'https://loopback.test:8443/v1/http', async: false }])
  assert.equal(fake.requestHeaders['X-PDSH-Target-URL'], 'https://upstream.test/api?x=1')
  assert.equal(fake.requestHeaders['X-PDSH-Target-Method'], 'POST')
  assert.equal(fake.requestHeaders['Authorization'], 'Bearer channel-secret')
  assert.equal(fake.requestHeaders['X-PDSH-Upstream-Authorization'], 'Bearer upstream-token')
  assert.equal(fake.requestHeaders['Content-Type'], 'application/json')
  assert.equal(fake.requestHeaders['X-Keep'], 'yes')
  for (const forbidden of ['Host', 'Cookie', 'Origin', 'Referer', 'User-Agent', 'Accept-Encoding', 'Proxy-Authorization']) {
    assert.equal(fake.requestHeaders[forbidden], undefined, `${forbidden} must be filtered`)
  }
  assert.notEqual(fake.requestHeaders['X-PDSH-Target-URL'], 'https://evil.test/')
  assert.deepEqual([...fake.sentBody as Uint8Array], [...encoder.encode('{"a":1}')])

  assert.equal(response.status, 201)
  assert.equal(response.reason, 'Created')
  assert.deepEqual(response.headers, [
    ['X-Twice', 'a'],
    ['X-Twice', 'b'],
    ['X-Test', 'yes'],
  ])
  for (const dropped of ['set-cookie', 'set-cookie2', 'clear-site-data', 'alt-svc']) {
    assert.equal(
      response.headers.some(([name]) => name.toLowerCase() === dropped),
      false,
      `${dropped} must not reach Python`,
    )
  }
  assert.equal(decoder.decode(response.body), 'created')
})

test('loopback XHR transport: status 0, thrown send and invalid targets are network/url failures', () => {
  const statusZero = new FakeXhr()
  statusZero.status = 0
  assert.equal(statusZero.response, null, 'a failed XHR has no response body')
  assert.throws(() => statusZero.responseText, /InvalidStateError|status is 0/u)
  const zeroTransport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:9',
    token: 't',
    xhrFactory: () => statusZero,
  })
  assert.throws(
    () => zeroTransport.request({ method: 'GET', url: 'http://example.test/', headers: {}, body: new Uint8Array(0) }),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'network',
  )

  const throwing = new FakeXhr()
  throwing.sendError = new Error('blocked by the browser')
  const throwingTransport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:9',
    token: 't',
    xhrFactory: () => throwing,
  })
  assert.throws(
    () => throwingTransport.request({ method: 'GET', url: 'http://example.test/', headers: {}, body: new Uint8Array(0) }),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'network',
  )

  let created = 0
  const urlTransport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:9',
    token: 't',
    xhrFactory: () => {
      created += 1
      return new FakeXhr()
    },
  })
  assert.throws(
    () => urlTransport.request({ method: 'GET', url: 'ftp://example.test/', headers: {}, body: new Uint8Array(0) }),
    (error: unknown) => error instanceof HttpBridgeError && error.kind === 'url',
  )
  assert.equal(created, 0, 'an invalid URL must not reach the XHR')
  assert.equal(forbiddenRequestHeader('Cookie'), true)
  assert.equal(forbiddenRequestHeader('X-PDSH-Target-URL'), true)
  assert.equal(forbiddenRequestHeader('X-Keep'), false)
})

/**
 * The host egress writer strips `Location` from every residual `3xx` on
 * `/v1/http` (real-TCP Swift regression in `LoopbackHTTPTests`). The browser
 * therefore has no target to follow, and the transport must return the
 * original status/body to Python instead of inventing a success. Python's
 * `urllib` then raises `HTTPError` for the non-success status.
 */
test('loopback XHR transport: a host-stripped 3xx is returned without a second control request', () => {
  const fake = new FakeXhr()
  fake.status = 302
  fake.statusText = 'Found'
  fake.response = encoder.encode('redirect refused at the proxy boundary').buffer
  fake.responseHeaderText = 'Content-Type: text/plain\r\nX-Test: kept'
  const transport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:9',
    token: 'channel-secret',
    xhrFactory: () => fake,
  })
  const response = transport.request({
    method: 'POST',
    url: 'https://upstream.test/api',
    headers: { 'Content-Type': 'application/json' },
    body: encoder.encode('{"task":"x"}'),
  })
  assert.equal(response.status, 302)
  assert.equal(response.reason, 'Found')
  assert.equal(decoder.decode(response.body), 'redirect refused at the proxy boundary')
  assert.equal(response.headers.some(([name]) => name.toLowerCase() === 'location'), false)
  assert.deepEqual(fake.opened, [{ method: 'POST', url: 'http://127.0.0.1:9/v1/http', async: false }])
  assert.equal(fake.sendCount, 1, 'the transport must issue exactly one /v1/http request')
})

test('loopback XHR transport: a rejected arraybuffer responseType fails structurally, never as lossy text', () => {
  const fake = new FakeXhr()
  fake.responseTypeError = new Error('responseType is not supported for synchronous requests')
  const transport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:9',
    token: 't',
    xhrFactory: () => fake,
  })
  const body = new Uint8Array([0xff, 0x00, 0x80, 0x41])
  assert.throws(
    () => transport.request({ method: 'POST', url: 'https://example.test/binary', headers: {}, body }),
    (error: unknown) => error instanceof HttpBridgeError
      && error.kind === 'transport'
      && /arraybuffer|bytes|lossy/u.test(error.message),
  )
  assert.equal(fake.sentBody, null, 'a response that cannot be read as bytes must not be requested')
})

/** A fake spawn bridge so the same private root also advertises `spawn`. */
const fakeSpawn = {
  guestRoot: '/__xl__',
  guestPath: '/__xl__/spawn',
  dispatch: (): Uint8Array => new Uint8Array([1, 0, 0, 0, 0]),
}

function wasiImports(wasi: WasiPreview1): Record<string, (...args: unknown[]) => number> {
  return wasi.imports.wasi_snapshot_preview1 as unknown as Record<string, (...args: unknown[]) => number>
}

function writeGuest(bytes: Uint8Array, memory: WebAssembly.Memory, pointer: number): void {
  new Uint8Array(memory.buffer).set(bytes, pointer)
}

test('wasi host: /__xl__/http is an fd kind, readdir lists spawn and http, outside paths stay ENOENT/EROFS', () => {
  const memory = new WebAssembly.Memory({ initial: 2 })
  const transport: HttpTransport = {
    request(request) {
      assert.equal(request.url, 'https://example.test/hello')
      return {
        status: 200,
        reason: 'OK',
        headers: [['Content-Type', 'text/plain'], ['X-Twice', 'a'], ['X-Twice', 'b']],
        body: encoder.encode('hello'),
      }
    },
  }
  const wasi = new WasiPreview1({
    args: [],
    preopens: [{ guestPath: '/__xl__', hostPath: '/pdsh-control' }],
    vfs: new MemoryWasiVfs(),
    spawn: fakeSpawn,
    http: createHttpBridge({ transport }),
  })
  wasi.setMemory(memory)
  const imports = wasiImports(wasi)
  const view = new DataView(memory.buffer)

  // list the private root
  const names: string[] = []
  const readdir = imports.fd_readdir!(3, 8000, 2048, 0n, 7800)
  assert.equal(readdir, WASI_ERRNO.SUCCESS)
  const used = view.getUint32(7800, true)
  let cursor = 8000
  while (cursor < 8000 + used) {
    const nameLength = view.getUint32(cursor + 16, true)
    names.push(decoder.decode(new Uint8Array(memory.buffer).subarray(cursor + 24, cursor + 24 + nameLength)))
    cursor += 24 + nameLength
  }
  assert.deepEqual(names, ['spawn', 'http'])

  // open the HTTP control file through the private preopen
  writeGuest(encoder.encode('http'), memory, 100)
  assert.equal(imports.path_open!(3, 0, 100, 4, 0, 0n, 0n, 0, 200), WASI_ERRNO.SUCCESS)
  const fd = view.getUint32(200, true)

  const frame = requestFrame({
    op: 'request',
    method: 'GET',
    url: 'https://example.test/hello',
    headers: { 'X-Test': 'yes' },
  })
  writeGuest(frame, memory, 400)
  view.setUint32(300, 400, true)
  view.setUint32(304, frame.byteLength, true)
  assert.equal(imports.fd_write!(fd, 300, 1, 500), WASI_ERRNO.SUCCESS)
  assert.equal(view.getUint32(500, true), frame.byteLength)

  // read the whole response frame in one guest read
  view.setUint32(600, 7000, true)
  view.setUint32(604, 8192, true)
  assert.equal(imports.fd_read!(fd, 600, 1, 620), WASI_ERRNO.SUCCESS)
  const readBytes = view.getUint32(620, true)
  const response = readResponseFrame(new Uint8Array(memory.buffer).slice(7000, 7000 + readBytes))
  assert.equal(response.header['status'], 200)
  assert.equal(response.header['bodyBytes'], 5)
  assert.deepEqual(response.header['headers'], [['Content-Type', 'text/plain'], ['X-Twice', 'a'], ['X-Twice', 'b']])
  assert.equal(decoder.decode(response.body), 'hello')

  // a path under the private root that is not a descriptor stays ENOENT
  writeGuest(encoder.encode('missing'), memory, 100)
  assert.equal(imports.path_open!(3, 0, 100, 7, 0, 0n, 0n, 0, 200), WASI_ERRNO.NOENT)
  // mutations under the private root stay read-only
  assert.equal(imports.path_unlink_file!(3, 100, 7), WASI_ERRNO.ROFS)
  assert.equal(PDSH_HTTP_GUEST_PATH, '/__xl__/http')
})

test('wasi host: a single over-limit fd_write answers a structured limit error', () => {
  const frame = new Uint8Array(8 + MAX_HTTP_HEADER_BYTES + 1 + MAX_HTTP_REQUEST_BODY_BYTES)
  const frameView = new DataView(frame.buffer)
  frameView.setUint32(0, MAX_HTTP_HEADER_BYTES + 1, true)
  frameView.setUint32(4, MAX_HTTP_REQUEST_BODY_BYTES, true)
  assert.equal(frame.byteLength, MAX_HTTP_REQUEST_FRAME_BYTES + 1)

  const framePointer = 1024
  const responsePointer = framePointer + frame.byteLength + 1024
  const memory = new WebAssembly.Memory({
    initial: Math.ceil((responsePointer + 8192) / 65536),
  })
  const wasi = new WasiPreview1({
    args: [],
    preopens: [{ guestPath: '/__xl__', hostPath: '/pdsh-control' }],
    vfs: new MemoryWasiVfs(),
    http: createHttpBridge({
      transport: {
        request() {
          assert.fail('an over-limit frame must never reach the transport')
        },
      },
    }),
  })
  wasi.setMemory(memory)
  const imports = wasiImports(wasi)
  const view = new DataView(memory.buffer)
  writeGuest(encoder.encode('http'), memory, 100)
  assert.equal(imports.path_open!(3, 0, 100, 4, 0, 0n, 0n, 0, 200), WASI_ERRNO.SUCCESS)
  const fd = view.getUint32(200, true)

  writeGuest(frame, memory, framePointer)
  view.setUint32(300, framePointer, true)
  view.setUint32(304, frame.byteLength, true)
  assert.equal(imports.fd_write!(fd, 300, 1, 500), WASI_ERRNO.SUCCESS)
  assert.equal(view.getUint32(500, true), frame.byteLength)

  view.setUint32(600, responsePointer, true)
  view.setUint32(604, 8192, true)
  assert.equal(imports.fd_read!(fd, 600, 1, 620), WASI_ERRNO.SUCCESS)
  const readBytes = view.getUint32(620, true)
  assert.ok(readBytes > 0, 'an over-limit frame must not read as EOF')
  const response = readResponseFrame(
    new Uint8Array(memory.buffer).slice(responsePointer, responsePointer + readBytes),
  )
  assert.equal((response.header['error'] as { kind: string }).kind, 'limit')
  assert.match((response.header['error'] as { message: string }).message, /limit/u)
  assert.equal(response.body.byteLength, 0)
})

test('wasi host: an oversized declared prefix is answered before its body arrives', () => {
  const memory = new WebAssembly.Memory({ initial: 2 })
  const wasi = new WasiPreview1({
    args: [],
    preopens: [{ guestPath: '/__xl__', hostPath: '/pdsh-control' }],
    vfs: new MemoryWasiVfs(),
    http: createHttpBridge({
      transport: {
        request() {
          assert.fail('an over-limit prefix must never reach the transport')
        },
      },
    }),
  })
  wasi.setMemory(memory)
  const imports = wasiImports(wasi)
  const view = new DataView(memory.buffer)
  writeGuest(encoder.encode('http'), memory, 100)
  assert.equal(imports.path_open!(3, 0, 100, 4, 0, 0n, 0n, 0, 200), WASI_ERRNO.SUCCESS)
  const fd = view.getUint32(200, true)

  const prefix = new Uint8Array(8)
  const prefixView = new DataView(prefix.buffer)
  prefixView.setUint32(0, MAX_HTTP_HEADER_BYTES + 1, true)
  prefixView.setUint32(4, MAX_HTTP_REQUEST_BODY_BYTES, true)
  writeGuest(prefix, memory, 400)
  view.setUint32(300, 400, true)
  view.setUint32(304, prefix.byteLength, true)
  assert.equal(imports.fd_write!(fd, 300, 1, 500), WASI_ERRNO.SUCCESS)

  // The declared body is never sent; the host must not wait for it.
  view.setUint32(600, 7000, true)
  view.setUint32(604, 8192, true)
  assert.equal(imports.fd_read!(fd, 600, 1, 620), WASI_ERRNO.SUCCESS)
  const readBytes = view.getUint32(620, true)
  assert.ok(readBytes > 0)
  const response = readResponseFrame(new Uint8Array(memory.buffer).slice(7000, 7000 + readBytes))
  assert.equal((response.header['error'] as { kind: string }).kind, 'limit')
})

class FakePythonToolWorker implements ToolWorkerTransport {
  readonly messages: unknown[] = []
  readonly listeners = new Set<(message: unknown) => void>()
  init: Record<string, unknown> | undefined

  postMessage(message: unknown): void {
    this.messages.push(message)
    const record = message as { readonly type?: unknown; readonly id?: unknown }
    if (record.type === 'init') {
      this.init = message as Record<string, unknown>
      const notify = (): void => {
        for (const listener of [...this.listeners]) {
          listener({
            type: 'ready',
            program: 'python3',
            python: { stdlibZip: '/usr/local/lib/python313.zip', stdlibBytes: 64, stdlibHostRoot: '/python-stdlib' },
          })
        }
      }
      queueMicrotask(notify)
      return
    }
    if (record.type === 'exec') {
      const id = record.id
      queueMicrotask(() => {
        for (const listener of [...this.listeners]) {
          listener({
            type: 'exit',
            id,
            code: 0,
            memoryExceeded: false,
            memoryPeakBytes: 1024,
            stdoutBytes: 0,
            stderrBytes: 0,
            python: { proxyCalls: 0, proxyStdlibReads: 0, stdlibBytes: 64 },
          })
        }
      })
    }
  }

  onMessage(handler: (message: unknown) => void): () => void {
    this.listeners.add(handler)
    return () => { this.listeners.delete(handler) }
  }

  onError(): () => void {
    return () => {}
  }

  terminate(): void {}
}

function pythonBackend(): { backend: MemoryVfsBackend; preopens: { guestPath: string; hostPath: string }[] } {
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/home')
  return {
    backend,
    preopens: [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
    ],
  }
}

test('python runtime: the http route reaches the tool worker init but never the guest environment', async () => {
  const { backend, preopens } = pythonBackend()
  const token = 'channel-token-do-not-leak'
  const fake = new FakePythonToolWorker()
  const runtime = new PythonRuntime({
    backend,
    wasm: new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]),
    stdlib: new Uint8Array(64),
    preopens,
    cwd: '/dsh/workspace',
    crossOriginIsolated: false,
    spawnWorker: () => fake,
    workerReadyTimeoutMs: 5000,
    http: { origin: 'https://loopback.test', token },
  })
  try {
    const result = await runtime.run({ program: 'python3', argv: ['-c', 'pass'] })
    assert.equal(result.exitCode, 0)
    assert.ok(fake.init !== undefined)
    assert.deepEqual(fake.init['http'], { origin: 'https://loopback.test', token })
    const defaultEnv = fake.init['defaultEnv'] as Record<string, string>
    assert.equal(defaultEnv['PDSH_PYTHON_HTTP'], '1')
    for (const value of Object.values(defaultEnv)) assert.equal(value.includes(token), false)
    assert.equal(JSON.stringify(fake.init['preopens']).includes(token), false)
    assert.equal(JSON.stringify(fake.init['python']).includes(token), false)
  } finally {
    await runtime.dispose()
  }
})

test('python runtime: without an http route nothing is injected and the flag is absent', async () => {
  const { backend, preopens } = pythonBackend()
  const fake = new FakePythonToolWorker()
  const runtime = new PythonRuntime({
    backend,
    wasm: new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]),
    stdlib: new Uint8Array(64),
    preopens,
    cwd: '/dsh/workspace',
    crossOriginIsolated: false,
    spawnWorker: () => fake,
    workerReadyTimeoutMs: 5000,
  })
  try {
    assert.equal((await runtime.run({ program: 'python3', argv: ['-c', 'pass'] })).exitCode, 0)
    assert.equal(fake.init?.['http'], undefined)
    assert.equal((fake.init?.['defaultEnv'] as Record<string, string> | undefined)?.['PDSH_PYTHON_HTTP'], undefined)
  } finally {
    await runtime.dispose()
  }
})

test('worker entry: the route comes from the curl-compatible environment names', () => {
  assert.deepEqual(resolvePythonHttpRoute({ PDSH_CHANNEL_ORIGIN: 'http://127.0.0.1:1', PDSH_CHANNEL_TOKEN: 'x' }), {
    origin: 'http://127.0.0.1:1',
    token: 'x',
  })
  assert.deepEqual(resolvePythonHttpRoute({ PDSH_EXEC_BRIDGE_URL: 'http://127.0.0.1:2', PDSH_EXEC_BRIDGE_TOKEN: 'y' }), {
    origin: 'http://127.0.0.1:2',
    token: 'y',
  })
  assert.equal(resolvePythonHttpRoute({ PDSH_CHANNEL_ORIGIN: 'http://127.0.0.1:1' }), undefined)
  assert.equal(resolvePythonHttpRoute({ PDSH_CHANNEL_TOKEN: 'x' }), undefined)
  assert.equal(resolvePythonHttpRoute({ PDSH_CHANNEL_ORIGIN: '', PDSH_CHANNEL_TOKEN: 'x' }), undefined)
})
