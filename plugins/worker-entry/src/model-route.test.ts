// SPDX-License-Identifier: MIT
/**
 * Truth gate for the model-route refusal (P27).
 *
 * The defect these tests pin: a launch that named no `pdsh.deepseek.baseUrl`
 * mounted no host model edge, published the placeholder credential and the key
 * state, and the pinned `llm-deepseek` resolver filled the missing endpoint with
 * `PUBLIC_BASE_URL`. The Worker then sent `phone-host-injects-mcp-key` to
 * `https://api.deepseek.com/anthropic/v1/messages` and got a 401 that blamed the
 * key (measured 2026-11-01). The property under test is not "the error text is
 * nice": it is that **the transport a refused request would use is never
 * called**. The fake fetch below throws if it is reached, so a regression fails
 * loudly instead of producing a network request.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  installModelRouteGuard,
  isModelProtocolRequest,
  MODEL_KEY_STATE_ENV,
  MODEL_ROUTE_ENV,
  MODEL_ROUTE_MISSING_ENV,
  modelRouteOf,
  modelRouteRefusal,
} from './model-route.ts'

type FetchCall = { readonly input: unknown; readonly init: unknown }

/** A fetch that records every call and fails the test when a request reaches it. */
function tripwire(): { fetch: typeof fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = []
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ input, init })
    throw new Error('the refusal must happen before the transport is reached')
  }) as typeof fetch
  return { fetch: fetchImpl, calls }
}

/** The environment the P27 launch produces (P25's members plus the route). */
function noRouteEnv(overrides: Record<string, string> = {}): Record<string, string> {
  return {
    DEEPSEEK_API_KEY: 'phone-host-injects-mcp-key',
    [MODEL_KEY_STATE_ENV]: 'configured',
    [MODEL_ROUTE_ENV]: 'none',
    [MODEL_ROUTE_MISSING_ENV]: 'base-url',
    ...overrides,
  }
}

test('a declared route is not refused and says nothing at boot', () => {
  for (const route of ['host-edge', 'direct']) {
    const decision = modelRouteOf({ [MODEL_ROUTE_ENV]: route })
    assert.equal(decision.refusal, undefined, `${route} must not arm the refusal`)
    assert.equal(decision.notice, undefined, `${route} must not log a boot notice`)
  }
})

test('an undeclared route is not refused by omission', () => {
  // A host that predates the declaration keeps the pinned behaviour; the guard
  // must be opt-in, or every other consumer of this entry changes behaviour.
  const decision = modelRouteOf({ DEEPSEEK_API_KEY: 'phone-host-injects-mcp-key' })
  assert.equal(decision.declared, undefined)
  assert.equal(decision.refusal, undefined)
  assert.equal(decision.notice, undefined)
})

test('an unknown route value is reported, never guessed at', () => {
  const decision = modelRouteOf({ [MODEL_ROUTE_ENV]: 'host-edge-remote' })
  assert.equal(decision.refusal, undefined, 'an unknown value is version skew, not a refusal')
  assert.match(decision.notice ?? '', /unknown PDSH_MODEL_ROUTE/)
  assert.match(decision.notice ?? '', /host-edge-remote/)
})

test('a no-route launch names the endpoint, never the credential', () => {
  const decision = modelRouteOf(noRouteEnv())
  const refusal = decision.refusal ?? ''
  assert.match(refusal, /no model route/)
  assert.match(refusal, /pdsh\.deepseek\.baseUrl was not supplied/)
  assert.match(refusal, /No request was sent/)
  assert.match(refusal, /PDSH_MODEL_KEY_STATE=configured/)
  assert.match(refusal, /the missing fact is the endpoint, not the credential/)
  // The P27 complaint about the 401 shape: it must not send the reader to the key.
  assert.doesNotMatch(refusal, /invalid/i)
  assert.doesNotMatch(refusal, /no API key/i)
  assert.equal(decision.notice, refusal, 'the boot line is the same sentence')
})

test('a no-route launch with no key state still names the missing input', () => {
  const env = noRouteEnv()
  delete env[MODEL_KEY_STATE_ENV]
  const refusal = modelRouteOf(env).refusal ?? ''
  assert.match(refusal, /pdsh\.deepseek\.baseUrl was not supplied/)
  assert.doesNotMatch(refusal, /PDSH_MODEL_KEY_STATE/)
})

test('a missing code the Worker does not know is reported as unknown, not invented', () => {
  const refusal = modelRouteRefusal('future-input', 'configured')
  assert.match(refusal, /the host reported no model route without naming the missing input/)
})

test('the Messages and Files protocol paths are recognised', () => {
  assert.equal(isModelProtocolRequest('https://api.deepseek.com/anthropic/v1/messages'), true)
  assert.equal(isModelProtocolRequest('http://127.0.0.1:40053/v1/messages'), true)
  assert.equal(isModelProtocolRequest('https://api.deepseek.com/anthropic/v1/files/f_1'), true)
  assert.equal(isModelProtocolRequest('http://127.0.0.1:40053/v1/http'), false)
  assert.equal(isModelProtocolRequest('https://api.deepseek.com/anthropic/health'), false)
  assert.equal(isModelProtocolRequest('not a url'), false)
})

test('a refused model request never reaches the transport and answers a provider error', async () => {
  const wire = tripwire()
  const warnings: string[] = []
  const originalWarn = console.warn
  // `installModelRouteGuard` wraps the process-wide transport; a test that
  // leaves its tripwire installed would hand the next test a throwing fetch.
  const originalFetch = globalThis.fetch
  console.warn = (message: unknown) => { warnings.push(String(message)) }
  const restore = installModelRouteGuard({
    decision: modelRouteOf(noRouteEnv()),
    fetchImpl: wire.fetch,
  })
  try {
    const response = await globalThis.fetch('https://api.deepseek.com/anthropic/v1/messages', {
      method: 'POST',
      body: '{"messages":[]}',
    })
    assert.deepEqual(wire.calls, [], 'the transport must not be called')
    assert.equal(response.status, 400)
    assert.equal(response.headers.get('x-pdsh-model-route'), 'none')
    const body = await response.json() as { error: { type: string; message: string } }
    assert.equal(body.error.type, 'invalid_request_error')
    assert.match(body.error.message, /pdsh\.deepseek\.baseUrl was not supplied/)
    assert.equal(warnings.length, 1, 'the refusal logs one line for logcat')
    assert.match(warnings[0] ?? '', /no model route/)
  } finally {
    restore()
    console.warn = originalWarn
    globalThis.fetch = originalFetch
  }
  assert.equal(globalThis.fetch, originalFetch, 'the disposer restored, then the test put the global back')
})

test('a routed launch forwards every request and leaves the transport identical', async () => {
  const wire = tripwire()
  const originalFetch = globalThis.fetch
  const restore = installModelRouteGuard({
    decision: modelRouteOf({ [MODEL_ROUTE_ENV]: 'host-edge' }),
  })
  try {
    assert.equal(globalThis.fetch, originalFetch, 'a routed launch must not wrap the global')
  } finally {
    restore()
  }
  // And the forwarded path: with route `none`, a non-model URL still reaches the
  // transport (the loopback /v1/http route is not a model request).
  const restoreAgain = installModelRouteGuard({
    decision: modelRouteOf(noRouteEnv()),
    fetchImpl: wire.fetch,
  })
  try {
    await assert.rejects(
      () => globalThis.fetch('http://127.0.0.1:40053/v1/http', { method: 'POST' }),
      /the refusal must happen before the transport is reached/,
    )
    assert.equal(wire.calls.length, 1, 'a non-model request is forwarded')
  } finally {
    restoreAgain()
  }
})
