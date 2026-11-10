// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  diagnosticPath, installBootFetchDiagnostics,
  type BootFetchDiagnosticPhase,
} from './boot-fetch-diagnostics.ts'

interface Line {
  phase: BootFetchDiagnosticPhase
  path: string
  elapsedMs?: number
}

function collector(): { lines: Line[]; emit: (phase: BootFetchDiagnosticPhase, path: string, elapsedMs?: number) => void } {
  const lines: Line[] = []
  return {
    lines,
    emit: (phase, path, elapsedMs) => {
      lines.push(elapsedMs === undefined ? { phase, path } : { phase, path, elapsedMs })
    },
  }
}

interface ScheduledTimer {
  callback: () => void
  milliseconds: number
}

function manualTimers(): {
  setTimeoutImpl: (callback: () => void, milliseconds: number) => unknown
  clearTimeoutImpl: (handle: unknown) => void
  runDue: () => void
  size: () => number
} {
  const timers = new Map<number, ScheduledTimer>()
  let next = 1
  return {
    setTimeoutImpl: (callback, milliseconds) => {
      const handle = next++
      timers.set(handle, { callback, milliseconds })
      return handle
    },
    clearTimeoutImpl: (handle) => { timers.delete(handle as number) },
    runDue: () => {
      const pending = [...timers.entries()]
      timers.clear()
      for (const [, timer] of pending) timer.callback()
    },
    size: () => timers.size,
  }
}

test('slow fetch reports only the query-free path and milliseconds', async () => {
  const { lines, emit } = collector()
  let now = 0
  const target: { fetch?: typeof fetch } = {
    fetch: async () => {
      now += 2_100
      return new Response('ok')
    },
  }
  const dispose = installBootFetchDiagnostics({
    emit,
    target,
    now: () => now,
    slowMilliseconds: 2_000,
    inflightMilliseconds: 10_000,
  })
  try {
    const response = await target.fetch!(
      'http://127.0.0.1:4567/v1/http?token=launch-secret',
      { headers: { authorization: 'Bearer sk-secret', 'x-api-key': 'sk-header' } })
    assert.equal(response.status, 200)
  } finally {
    dispose()
  }
  assert.deepEqual(lines, [{ phase: 'slow-fetch', path: '/v1/http', elapsedMs: 2_100 }])
  const text = JSON.stringify(lines)
  assert.equal(text.includes('launch-secret'), false)
  assert.equal(text.includes('sk-secret'), false)
  assert.equal(text.includes('authorization'), false)
})

test('fast fetch is silent and a Request input still yields only its path', async () => {
  const { lines, emit } = collector()
  let now = 0
  const target: { fetch?: typeof fetch } = {
    fetch: async () => {
      now += 20
      return new Response('ok')
    },
  }
  const dispose = installBootFetchDiagnostics({
    emit, target, now: () => now, slowMilliseconds: 2_000, inflightMilliseconds: 10_000,
  })
  try {
    await target.fetch!(new Request('http://127.0.0.1:9/v1/models?api_key=sk-model',
      { headers: { authorization: 'Bearer sk-header' } }))
  } finally {
    dispose()
  }
  assert.deepEqual(lines, [])
})

test('an unresolved fetch reports every interval and stops after settle', async () => {
  const { lines, emit } = collector()
  const timers = manualTimers()
  let now = 0
  let resolveFetch: ((response: Response) => void) | undefined
  const target: { fetch?: typeof fetch } = {
    fetch: () => new Promise<Response>((resolve) => { resolveFetch = resolve }),
  }
  const dispose = installBootFetchDiagnostics({
    emit,
    target,
    now: () => now,
    slowMilliseconds: 60_000,
    inflightMilliseconds: 10_000,
    setTimeoutImpl: timers.setTimeoutImpl,
    clearTimeoutImpl: timers.clearTimeoutImpl,
  })
  try {
    const pending = target.fetch!('http://127.0.0.1:9/v1/http?token=secret')
    now = 10_000
    timers.runDue()
    now = 20_000
    timers.runDue()
    assert.deepEqual(lines, [
      { phase: 'fetch-inflight', path: '/v1/http' },
      { phase: 'fetch-inflight', path: '/v1/http' },
    ])
    resolveFetch!(new Response('ok'))
    await pending
    assert.equal(lines.length, 2)
    assert.equal(timers.size(), 0)
  } finally {
    dispose()
  }
})

test('dispose restores the previous fetch and stops emitting', async () => {
  const { lines, emit } = collector()
  let now = 0
  const original = async (_input?: RequestInfo | URL, _init?: RequestInit) => {
    now += 2_500
    return new Response('original')
  }
  const target: { fetch?: typeof fetch } = { fetch: original }
  const dispose = installBootFetchDiagnostics({
    emit, target, now: () => now, slowMilliseconds: 2_000, inflightMilliseconds: 10_000,
  })
  assert.notEqual(target.fetch, original)
  dispose()
  dispose()
  assert.equal(target.fetch, original)
  await target.fetch!('http://127.0.0.1:9/v1/http')
  assert.deepEqual(lines, [])
})

test('dispose leaves an llm-bridge replacement in place and it keeps forwarding', async () => {
  const { lines, emit } = collector()
  let now = 0
  let originalCalls = 0
  const original = async () => {
    originalCalls += 1
    now += 2_500
    return new Response('original')
  }
  const target: { fetch?: typeof fetch } = { fetch: original }
  const dispose = installBootFetchDiagnostics({
    emit, target, now: () => now, slowMilliseconds: 2_000, inflightMilliseconds: 10_000,
  })
  const instrumented = target.fetch!
  // P27: llm-bridge replaces the global during host.start. Its transport may
  // capture the wrapper that was current at install time.
  const replacement = async (input: RequestInfo | URL, init?: RequestInit) =>
    await instrumented(input, init)
  target.fetch = replacement
  dispose()
  assert.equal(target.fetch, replacement, 'the llm-bridge replacement must survive')
  const response = await target.fetch!('http://127.0.0.1:9/v1/http?token=secret')
  assert.equal(await response.text(), 'original')
  assert.equal(originalCalls, 1)
  assert.deepEqual(lines, [], 'a disposed wrapper must not emit')
})

test('a rejecting slow fetch still reports and rethrows', async () => {
  const { lines, emit } = collector()
  let now = 0
  const target: { fetch?: typeof fetch } = {
    fetch: async () => { now += 2_100; throw new Error('gateway down') },
  }
  const dispose = installBootFetchDiagnostics({
    emit, target, now: () => now, slowMilliseconds: 2_000, inflightMilliseconds: 10_000,
  })
  try {
    await assert.rejects(target.fetch!('http://127.0.0.1:9/v1/http'), /gateway down/)
  } finally {
    dispose()
  }
  assert.deepEqual(lines, [{ phase: 'slow-fetch', path: '/v1/http', elapsedMs: 2_100 }])
})

test('diagnosticPath strips query and fragment from unparsable input', () => {
  assert.equal(diagnosticPath('/v1/http?token=x#y' as unknown as RequestInfo), '/v1/http')
  assert.equal(diagnosticPath('http://' as unknown as RequestInfo), '/unknown')
})
