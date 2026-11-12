// SPDX-License-Identifier: MIT
// spec/bot/v1/mcp-endpoint.md §2 "Long approvals" (PC-20261112-bot-approval-keepalive).
// The shared `approval` golden block drives the real Worker stream parser, and
// the llm-bridge host route shows the operator-visible failure shapes: an SSE
// keepalive stream survives the 60 s-class delivery watchdog, while a stalled
// JSON head still fails with PDSH_DELIVERY_TIMEOUT (the watchdog is unchanged).

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import {
  parseApprovalEventStream, postApproval,
} from '../bot-runtime/src/approval-gate.ts'

interface ApprovalGolden {
  readonly worker_accept: string
  readonly valid_streams: readonly {
    readonly name: string
    readonly body: string
    readonly expect: Record<string, unknown>
  }[]
  readonly invalid_streams: readonly {
    readonly name: string
    readonly body: string
    readonly expect: string
  }[]
}

interface Golden {
  readonly approval: ApprovalGolden
}

const golden = JSON.parse(readFileSync(
  new URL('../../spec/v1/golden/mcp-long-call/cases.json', import.meta.url), 'utf8',
)) as Golden

test('the shared approval stream fixtures drive the Worker parser', () => {
  for (const item of golden.approval.valid_streams) {
    assert.deepEqual(parseApprovalEventStream(item.body), item.expect, item.name)
  }
  for (const item of golden.approval.invalid_streams) {
    assert.equal(parseApprovalEventStream(item.body), undefined, item.name)
  }
  assert.equal(golden.approval.worker_accept, 'application/json, text/event-stream')
})

/** A streamed approval answer: keepalives every 80 ms, one message at `delayMs`. */
function approvalStream(delayMs: number): Response {
  const encoder = new TextEncoder()
  let keepalive: ReturnType<typeof setInterval> | undefined
  let message: ReturnType<typeof setTimeout> | undefined
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      keepalive = setInterval(() => controller.enqueue(encoder.encode(': keepalive\n\n')), 80)
      message = setTimeout(() => {
        clearInterval(keepalive)
        controller.enqueue(encoder.encode(
          'event: message\ndata: {"ok":true,"allowed":true,'
            + '"approvalId":"approval-worker-stream","message":"allowed"}\n\n'))
        controller.close()
      }, delayMs)
    },
    cancel() {
      clearInterval(keepalive)
      clearTimeout(message)
    },
  })
  return new Response(body, {
    status: 200, headers: { 'content-type': 'text/event-stream' },
  })
}

interface HostRouteCall {
  readonly path: string
  readonly headers: Headers
}

/** Installs the host `/v1/http` route over a stub for one test, then restores it. */
async function withHostRoute<T>(
  stub: (call: HostRouteCall) => Promise<Response>,
  run: (calls: HostRouteCall[]) => Promise<T>,
): Promise<T> {
  const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
  const calls: HostRouteCall[] = []
  const proxyFetch: typeof fetch = async (input, init) => {
    const url = input instanceof URL ? input
      : typeof input === 'string' ? new URL(input) : new URL(input.url)
    const call = { path: url.pathname, headers: new Headers(init?.headers) }
    calls.push(call)
    return await stub(call)
  }
  const restore = installNodeFetch({
    mode: 'always',
    proxy: { url: 'http://127.0.0.1:47231', token: 'host-route-token' },
    proxyFetch,
    deliveryIdleTimeoutMs: 200,
  })
  try {
    return await run(calls)
  } finally {
    restore()
  }
}

test('an SSE approval answer with keepalives outlives the delivery watchdog', async () => {
  const started = Date.now()
  const outcome = await withHostRoute(async call => {
    // Every hop of the host route targets /v1/http; the Worker asked for the
    // approval URL through the host.
    assert.equal(call.path, '/v1/http')
    return approvalStream(700)
  }, async calls => {
    const result = await postApproval(
      'http://127.0.0.1:47231/approval', 'bot-bearer-placeholder', { callId: 'worker-stream' })
    const accept = calls[0]?.headers.get('accept') ?? ''
    assert.match(accept, /text\/event-stream/,
      'the Worker approval client must explicitly accept the SSE answer form')
    assert.equal(calls[0]?.headers.get('x-pdsh-target-url'),
      'http://127.0.0.1:47231/approval')
    assert.equal(calls.length, 1)
    return result
  })
  const elapsed = Date.now() - started
  assert.equal(outcome.ok, true)
  assert.equal(outcome.allowed, true)
  assert.equal(outcome.approvalId, 'approval-worker-stream')
  assert.doesNotMatch(String(outcome.message ?? ''), /PDSH_DELIVERY_TIMEOUT/)
  assert.ok(elapsed >= 600, `the keepalives must keep the stream open (${elapsed} ms)`)
})

test('a JSON head that stalls past the idle window still fails with PDSH_DELIVERY_TIMEOUT', async () => {
  const started = Date.now()
  const outcome = await withHostRoute(async call => {
    assert.equal(call.path, '/v1/http')
    await new Promise(resolve => setTimeout(resolve, 700))
    return new Response('{"ok":true,"allowed":true}', {
      status: 200, headers: { 'content-type': 'application/json' },
    })
  }, async calls => {
    const result = await postApproval(
      'http://127.0.0.1:47231/approval', 'bot-bearer-placeholder', { callId: 'worker-stalled' })
    assert.match(calls[0]?.headers.get('accept') ?? '', /text\/event-stream/)
    return result
  })
  const elapsed = Date.now() - started
  assert.equal(outcome.ok, false, 'a stalled approval must fail closed')
  assert.match(String(outcome.message ?? ''), /PDSH_DELIVERY_TIMEOUT/,
    'the delivery watchdog itself must not be widened')
  assert.ok(elapsed < 700, `the watchdog must fail the head before the stub answers (${elapsed} ms)`)
})
