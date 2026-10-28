// SPDX-License-Identifier: MIT
// P0-1: the Worker install path must never resolve the node:https transport.
// The runtime's module table only carries a structural TLS mock (no usable
// `Agent`), and a Worker has no node:http client at all. llm-bridge therefore
// carries every request over the host `/v1/http` route with the channel bearer,
// and the node:http implementation is a lazy desktop-only fallback.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { IncomingHttpHeaders } from 'node:http'
import { registerHooks } from 'node:module'
import type { AddressInfo } from 'node:net'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const INSTALL_SOURCE = fileURLToPath(new URL('../llm-bridge/src/install.ts', import.meta.url))

test('install.ts has no static node:http(s) transport import', () => {
  const source = readFileSync(INSTALL_SOURCE, 'utf8')
  // A value import re-exports nothing: only `import type` may mention the file.
  assert.doesNotMatch(source, /^import (?!type\b)[^;]*from '\.\/node-fetch\.ts'/m)
  assert.doesNotMatch(source, /from 'node:https'/)
  assert.doesNotMatch(source, /from 'node:http'/)
})

test('the Worker host route installs while node:https is unresolvable', async () => {
  const seen: IncomingHttpHeaders[] = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      seen.push(req.headers)
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify({ target: req.headers['x-pdsh-target-url'], body: Buffer.concat(chunks).toString() }))
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const token = 'llm-install-token-0123456789'
  const previousLocation = Object.getOwnPropertyDescriptor(globalThis, 'location')
  const previous = { PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN, PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN }
  // Simulate the DSH Worker module table: resolving node:https is a load-time
  // failure, exactly like a table without the mock entry.
  const hooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === 'node:https') throw new Error('node:https is not in the Worker module table')
      return nextResolve(specifier, context)
    },
  })
  Object.defineProperty(globalThis, 'location', { value: { origin: base }, configurable: true, writable: true })
  process.env.PDSH_CHANNEL_TOKEN = token
  process.env.PDSH_CHANNEL_ORIGIN = base
  try {
    // Cache-bust so this test evaluates install.ts afresh under the hook.
    const specifier = `${new URL('../llm-bridge/src/install.ts', import.meta.url).href}?worker-install-probe`
    const module = await import(specifier) as typeof import('../llm-bridge/src/install.ts')
    const restore = module.installNodeFetch({ mode: 'auto' })
    try {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{"prompt":"hi"}' })
      assert.equal(response.status, 200)
      assert.equal(response.headers.get('cache-control'), 'no-store')
      const body = await response.json() as Record<string, string>
      assert.equal(body.target, 'https://model.example/v1/messages')
      assert.equal(body.body, '{"prompt":"hi"}')
      assert.equal(seen.length, 1)
      assert.equal(seen[0]?.authorization, `Bearer ${token}`)
    } finally {
      restore()
    }
  } finally {
    hooks.deregister()
    server.closeAllConnections()
    server.close()
    if (previousLocation === undefined) delete (globalThis as { location?: unknown }).location
    else Object.defineProperty(globalThis, 'location', previousLocation)
    for (const key of ['PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN'] as const) {
      const value = previous[key]
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
})

// --- Response-delivery deadline (G2-FIX-1) --------------------------------
//
// The host gateway can receive a complete model response while the last bytes
// never reach the Worker's platform fetch (a frozen WebKit page, a broken
// stream hop). Before the fix nothing owned a delivery deadline, so the model
// client waited until the scenario budget expired. The wrapper now arms an
// inactivity interval when the response is handed over and for every pending
// body read; it fails with a typed `LlmError` the DSH adapter rethrows
// unchanged, so the retry policy sees the non-retryable delivery code.

let deliveryProbe = 0

/** Installs the Worker host route over a fake platform fetch for one test. */
async function withWorkerHostRoute<T>(
  fake: typeof fetch,
  idleMs: number,
  run: (module: typeof import('../llm-bridge/src/install.ts')) => Promise<T>,
  origin = 'http://127.0.0.1:9',
): Promise<T> {
  const scope = globalThis as { __PDSH_CHANNEL__?: unknown }
  const previousChannel = scope.__PDSH_CHANNEL__
  const previousToken = process.env.PDSH_CHANNEL_TOKEN
  const previousOrigin = process.env.PDSH_CHANNEL_ORIGIN
  scope.__PDSH_CHANNEL__ = { deliveryProbe: true }
  process.env.PDSH_CHANNEL_TOKEN = 'delivery-probe-token'
  process.env.PDSH_CHANNEL_ORIGIN = origin
  deliveryProbe += 1
  const specifier = `${new URL('../llm-bridge/src/install.ts', import.meta.url).href}?delivery-probe-${deliveryProbe}`
  const module = await import(specifier) as typeof import('../llm-bridge/src/install.ts')
  const restore = module.installNodeFetch({
    mode: 'auto',
    proxyFetch: fake,
    deliveryIdleTimeoutMs: idleMs,
  })
  try {
    return await run(module)
  } finally {
    restore()
    if (previousChannel === undefined) delete scope.__PDSH_CHANNEL__
    else scope.__PDSH_CHANNEL__ = previousChannel
    if (previousToken === undefined) delete process.env.PDSH_CHANNEL_TOKEN
    else process.env.PDSH_CHANNEL_TOKEN = previousToken
    if (previousOrigin === undefined) delete process.env.PDSH_CHANNEL_ORIGIN
    else process.env.PDSH_CHANNEL_ORIGIN = previousOrigin
  }
}

/** Fails a test that would otherwise hang past its own guard interval. */
async function settleWithin<T>(promise: Promise<T>, milliseconds: number,
                               label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const guard = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`test guard: ${label} did not settle`)), milliseconds)
  })
  try {
    return await Promise.race([promise, guard])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

test('a stalled host-route body fails with a typed delivery timeout', async () => {
  const fake = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('event: ping\ndata: {}\n\n'))
      // Never closes: the delivery leg holds the remaining SSE bytes.
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const reader = response.body?.getReader()
    assert.ok(reader !== undefined)
    await reader.read()
    try {
      await settleWithin(reader.read(), 2_000, 'stalled body read')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(errorType !== undefined && observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).stage, 'body')
  // DSH's adapter rethrows a thrown `LlmError` instead of re-classifying it as
  // TRANSPORT; the stable code is not in the default retryable set, so a
  // stalled delivery ends the request instead of retrying the same frozen leg.
  const { LlmError } = await import('@deepseek-ai/dsh-llm')
  assert.ok(observed.error instanceof LlmError,
    'the delivery timeout must reach the adapter as a DSH LlmError')
  assert.equal((observed.error as InstanceType<typeof LlmError>).failure.code,
    'PDSH_DELIVERY_TIMEOUT')
})

test('a stalled host-route response head fails with a typed delivery timeout', async () => {
  const fake = (() => new Promise<Response>(() => {})) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    try {
      await settleWithin(fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' }),
        2_000, 'stalled head fetch')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(errorType !== undefined && observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).stage, 'head')
})

test('a healthy host-route response streams every chunk without a timeout', async () => {
  const chunks = [new TextEncoder().encode('event: a\n\n'),
    new TextEncoder().encode('event: b\n\n'),
    new TextEncoder().encode('event: c\n\n')]
  const fake = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk)
      controller.close()
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })) as typeof fetch
  const body = await withWorkerHostRoute(fake, 5_000, async () => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const bytes = new Uint8Array(await response.arrayBuffer())
    return bytes
  })
  assert.deepEqual(Buffer.from(body), Buffer.concat(chunks.map(chunk => Buffer.from(chunk))))
})

// --- Delivery-window resume (G2-FIX-20) -----------------------------------
//
// The real-model batch showed the host response log holding complete SSE
// bodies while the Worker's platform fetch stopped receiving them once the
// consumer had not pulled for a while (a suspended WebKit page). Abandoning
// the response is what lost the turn: the host already owns the bytes. The
// wrapper now counts what it actually delivered and re-fetches the same host
// route from that byte offset; the host serves the suffix from its committed
// response log and never re-contacts the upstream.

test('a body that stops mid-stream resumes from the host delivery window', async () => {
  const first = new TextEncoder().encode('a'.repeat(120))
  const rest = new TextEncoder().encode('b'.repeat(180))
  const resumeHeaders: Array<string | null> = []
  const fake = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    resumeHeaders.push(headers.get('x-pdsh-resume-from'))
    if (resumeHeaders.length === 1) {
      let phase = 0
      return new Response(new ReadableStream<Uint8Array>({
        pull(controller) {
          phase += 1
          if (phase === 1) {
            controller.enqueue(first)
            return
          }
          // The downstream consumer stopped pulling after the first chunk:
          // the platform fetch fails with the bytes it already delivered.
          controller.error(new Error('delivery consumer suspended'))
        },
      }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
    }
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(rest)
        controller.close()
      },
    }), {
      status: 200,
      headers: { 'content-type': 'text/event-stream', 'x-pdsh-resumed': '1' },
    })
  }) as typeof fetch

  const observed = await withWorkerHostRoute(fake, 200, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const bytes = new Uint8Array(await response.arrayBuffer())
    return { bytes, metrics: module.deliveryMetricsSnapshot() }
  })

  assert.deepEqual(resumeHeaders, [null, String(first.byteLength)],
    'the second attempt must ask for the suffix at the delivered offset')
  assert.deepEqual(Buffer.from(observed.bytes), Buffer.concat([Buffer.from(first), Buffer.from(rest)]))
  assert.equal(observed.metrics.resumes, 1)
  assert.equal(observed.metrics.stalls, 0)
  assert.equal(observed.metrics.attempts, 2)
  assert.equal(observed.metrics.resumedBytes, rest.byteLength)
})

test('a delivery that the host cannot resume still fails with PDSH_DELIVERY_TIMEOUT', async () => {
  const first = new TextEncoder().encode('a'.repeat(64))
  let calls = 0
  const fake = (async () => {
    calls += 1
    if (calls === 1) {
      return new Response(new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(first)
          // Never closes: the host body was not committed, so the resume
          // request below is refused.
        },
      }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
    }
    return new Response('the response is not committed', {
      status: 502,
      headers: { 'content-type': 'application/json', 'x-pdsh-proxy-error': 'upstream' },
    })
  }) as typeof fetch

  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    const reader = response.body?.getReader()
    assert.ok(reader !== undefined)
    await reader.read()
    try {
      await settleWithin(reader.read(), 2_000, 'irrecoverable body read')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })

  assert.equal(calls, 2, 'exactly one bounded resume attempt')
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
})

test('a request already addressed to the host /v1/http route passes through untouched', async () => {
  // The Worker `curl` shim builds the host-route request itself: target in
  // `X-PDSH-Target-*`, the channel bearer in `Authorization`. Re-routing that
  // request would move its bearer into `x-pdsh-upstream-authorization` and make
  // the host call its own loopback, which answers 401 "missing token".
  const seen: { url: string; headers: Headers }[] = []
  const fake: typeof fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    seen.push({ url: request.url, headers: new Headers(request.headers) })
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })
  }) as typeof fetch
  await withWorkerHostRoute(fake, 5_000, async () => {
    await globalThis.fetch('http://127.0.0.1:9/v1/http', {
      method: 'POST',
      headers: {
        authorization: 'Bearer curl-shim-token',
        'x-pdsh-target-url': 'https://weather.example/city?format=3',
        'x-pdsh-target-method': 'GET',
      },
    })
    const routed = await globalThis.fetch('https://model.example/v1/messages', {
      method: 'POST',
      headers: { authorization: 'Bearer upstream-key' },
      body: '{}',
    })
    await routed.arrayBuffer()
  })
  assert.equal(seen.length, 2)
  // 1. the host-route request itself: same URL, same headers, nothing rewritten
  assert.equal(seen[0]?.url, 'http://127.0.0.1:9/v1/http')
  assert.equal(seen[0]?.headers.get('authorization'), 'Bearer curl-shim-token')
  assert.equal(seen[0]?.headers.get('x-pdsh-upstream-authorization'), null)
  assert.equal(seen[0]?.headers.get('x-pdsh-target-url'), 'https://weather.example/city?format=3')
  // 2. an ordinary upstream request still travels through the host route
  assert.equal(seen[1]?.url, 'http://127.0.0.1:9/v1/http')
  assert.equal(seen[1]?.headers.get('authorization'), 'Bearer delivery-probe-token')
  assert.equal(seen[1]?.headers.get('x-pdsh-upstream-authorization'), 'Bearer upstream-key')
  assert.equal(seen[1]?.headers.get('x-pdsh-target-url'), 'https://model.example/v1/messages')
})

// --- Bodyless host responses (MCP Streamable HTTP) -------------------------
//
// A Streamable HTTP client registers with `initialize`, then posts
// `notifications/initialized`, which a compliant server answers with 204 and
// no body. The installed host route must hand that bodyless response through
// without reconstructing a `Response` around a stream: WebKit throws
// "Response cannot have a body with the given status." for a 204 that carries
// any body, including the terminating chunk of a chunked response.

test('a host 204 notification response stays bodyless through the installed route', async () => {
  const seen: Array<{ method?: string | undefined; headers: IncomingHttpHeaders; body: string }> = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      const target = String(req.headers['x-pdsh-target-url'] ?? '')
      seen.push({ method: req.method, headers: req.headers, body: Buffer.concat(chunks).toString() })
      if (target === 'https://mcp.example.test/mcp') {
        res.writeHead(204, { 'mcp-session-id': 'session-204', 'cache-control': 'no-store' })
        res.end()
        return
      }
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end('{"ok":true}')
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const nativeFetch = globalThis.fetch
  const hostFetch = ((input: RequestInfo | URL, init?: RequestInit) =>
    nativeFetch(input, init)) as typeof fetch
  const notification = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  try {
    await withWorkerHostRoute(hostFetch, 5_000, async () => {
      const response = await globalThis.fetch('https://mcp.example.test/mcp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: notification,
      })
      assert.equal(response.status, 204)
      assert.equal(response.body, null, 'a 204 fetch response must have a null body')
      assert.equal(response.headers.get('mcp-session-id'), 'session-204')
      assert.equal(await response.text(), '')

      // The same keep-alive host route must still carry the next JSON request.
      const next = await globalThis.fetch('https://model.example.test/v1/messages', {
        method: 'POST',
        body: '{"prompt":"hi"}',
      })
      assert.equal(next.status, 200)
      assert.deepEqual(await next.json(), { ok: true })
    }, base)
  } finally {
    server.closeAllConnections()
    server.close()
  }
  assert.equal(seen.length, 2)
  assert.equal(seen[0]?.method, 'POST')
  assert.equal(seen[0]?.headers.authorization, 'Bearer delivery-probe-token')
  assert.equal(seen[0]?.headers['x-pdsh-target-url'], 'https://mcp.example.test/mcp')
  assert.equal(seen[0]?.headers['x-pdsh-target-method'], 'POST')
  assert.equal(seen[0]?.body, notification)
  assert.equal(seen[1]?.headers['x-pdsh-target-url'], 'https://model.example.test/v1/messages')
})

test('a bodyless status is never re-wrapped around a stray body', async () => {
  // A platform fetch is expected to expose a null body for 204/205/304, but
  // the delivery wrapper is the last Response constructor on the host route.
  // If a platform hands back a stream anyway, it must be cancelled instead of
  // being passed to `new Response(stream, { status: 204 })`.
  let cancelled = false
  const stray = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('must not reach the caller'))
    },
    cancel() {
      cancelled = true
    },
  })
  const fake = (async () => ({
    status: 204,
    statusText: 'No Content',
    headers: new Headers({ 'mcp-session-id': 'session-stray' }),
    body: stray,
    url: 'https://mcp.example.test/mcp',
    redirected: false,
  } as unknown as Response)) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 5_000, async () => {
    const response = await globalThis.fetch('https://mcp.example.test/mcp', {
      method: 'POST',
      body: '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    })
    return {
      status: response.status,
      body: response.body,
      headers: response.headers,
      url: response.url,
      text: await response.text(),
    }
  })
  assert.equal(observed.status, 204)
  assert.equal(observed.body, null)
  assert.equal(observed.headers.get('mcp-session-id'), 'session-stray')
  assert.equal(observed.url, 'https://mcp.example.test/mcp')
  assert.equal(observed.text, '')
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(cancelled, true, 'the stray body stream must be cancelled')
})
