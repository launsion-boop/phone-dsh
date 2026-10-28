// SPDX-License-Identifier: MIT
// LIFECYCLE/FENCE push consumption, the budget threshold table, the loop
// watchdog and sink-failure admission closing (PLAN W1-PLUGINS item 5).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import {
  DEFAULT_THRESHOLDS, LoopWatchdog, XlLifecycle, applyThresholds,
} from '../lifecycle-gate/src/index.ts'

function push(value: unknown): void {
  ;(globalThis as Record<string, unknown>).__PDSH_LIFECYCLE__ = value
}

function fence(value: unknown): void {
  ;(globalThis as Record<string, unknown>).__PDSH_FENCE__ = value
}

async function setup(): Promise<{ ctx: Context; lifecycle: XlLifecycle; dispatch: (name: string, args: unknown) => Promise<{ result: Record<string, unknown>; ran: number }> }> {
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {}, get: () => undefined })
  await ctx.plugin(XlLifecycle, {
    bridge: false,
    filePollMs: 250,
    minBudgetMs: 0,
    thresholds: [...DEFAULT_THRESHOLDS],
    watchdog: true,
    watchdogLimit: 3,
  })
  const lifecycle = ctx.get('xlLifecycle') as XlLifecycle
  const dispatch = async (name: string, args: unknown): Promise<{ result: Record<string, unknown>; ran: number }> => {
    let ran = 0
    const events = ctx as unknown as { waterfall(event: string, exec: unknown, next: () => Promise<unknown>): Promise<unknown> }
    const result = await events.waterfall('tools/execute', {
      agent: { session: { id: 'session-1' } },
      parent: undefined,
      name,
      arguments: args,
      signal: new AbortController().signal,
    }, async () => { ran += 1; return { isError: false, content: [] } })
    return { result: result as Record<string, unknown>, ran }
  }
  return { ctx, lifecycle, dispatch }
}

test('the budget threshold table only downgrades', () => {
  assert.deepEqual(applyThresholds({ state: 'run', budgetMs: 10_000 }), { state: 'run', budgetMs: 10_000 })
  assert.deepEqual(applyThresholds({ state: 'run', budgetMs: 1_500 }), { state: 'pause', reason: 'background_budget_low', budgetMs: 1_500 })
  // 0 means "none" on the wire: never a downgrade.
  assert.deepEqual(applyThresholds({ state: 'run', budgetMs: 0 }), { state: 'run', budgetMs: 0 })
  assert.deepEqual(applyThresholds({ state: 'stop', budgetMs: 1_500, reason: 'host' }), { state: 'stop', budgetMs: 1_500, reason: 'host' })
})

test('push: LIFECYCLE admission closes the gate, both push switches are required to open it, and FENCE closes too', async () => {
  const { ctx, lifecycle, dispatch } = await setup()
  try {
    push({ state: 'run', budget: 0, admission: 'closed', reason: 'foreground' })
    assert.equal(lifecycle.state.state, 'pause')
    assert.equal(lifecycle.admission, 'closed')
    push({ state: 'run', budget: 0, admission: 'open' })
    assert.equal(lifecycle.state.state, 'run')

    fence({ admission: 'closed', fence: { owner: 'host', generation: 1, wal_seq: 0 } })
    assert.equal(lifecycle.state.state, 'pause')
    fence({ admission: 'open', fence: { owner: 'host', generation: 2, wal_seq: 0 } })
    assert.equal(lifecycle.state.state, 'run')

    push({ state: 'stop', budget: 0, admission: 'open', reason: 'host terminating' })
    const refused = await dispatch('bash', { command: 'echo hi' })
    assert.equal(refused.ran, 0)
    assert.equal((refused.result['error'] as { info: { code: string } }).info.code, 'PDSH_LIFECYCLE_REFUSED')
    push({ state: 'run', budget: 0, admission: 'open' })
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_LIFECYCLE__
    delete (globalThis as Record<string, unknown>).__PDSH_FENCE__
  }
})

test('push: a low positive budget pauses through the threshold table', async () => {
  const { ctx, lifecycle } = await setup()
  try {
    push({ state: 'run', budget: 1_500, admission: 'open' })
    assert.deepEqual(lifecycle.state, { state: 'pause', reason: 'background_budget_low', budgetMs: 1_500 })
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_LIFECYCLE__
    delete (globalThis as Record<string, unknown>).__PDSH_FENCE__
  }
})

test('watchdog: refuses the third identical consecutive tool call with a clear error', async () => {
  const { ctx, lifecycle, dispatch } = await setup()
  try {
    push({ state: 'run', budget: 0, admission: 'open' })
    const first = await dispatch('bash', { command: 'make test' })
    const second = await dispatch('bash', { command: 'make test' })
    const third = await dispatch('bash', { command: 'make test' })
    assert.equal(first.ran, 1)
    assert.equal(second.ran, 1)
    assert.equal(third.ran, 0)
    const error = third.result['error'] as { info: { code: string }; message: string }
    assert.equal(error.info.code, 'PDSH_LOOP_WATCHDOG')
    assert.match(error.message, /identical arguments/)
    assert.match(error.message, /Limit: 3/)
    // A different call breaks the run.
    assert.equal((await dispatch('bash', { command: 'make build' })).ran, 1)
    assert.equal((await dispatch('bash', { command: 'make test' })).ran, 1)
    assert.equal(lifecycle.state.state, 'run')
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_LIFECYCLE__
    delete (globalThis as Record<string, unknown>).__PDSH_FENCE__
  }
})

test('a fatal channel ERROR closes admission', async () => {
  let fatal: ((frame: { type: number; payload: Uint8Array }) => void) | undefined
  ;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = {
    onFrame: (handler: (frame: { type: number; payload: Uint8Array }) => void) => {
      fatal = handler
      return () => {}
    },
  }
  const { ctx, lifecycle, dispatch } = await setup()
  try {
    push({ state: 'run', budget: 0, admission: 'open' })
    assert.ok(fatal !== undefined)
    fatal({ type: 0x7f, payload: new TextEncoder().encode(JSON.stringify({ code: 'RING_TIMEOUT', message: 'no ack progress' })) })
    assert.equal(lifecycle.state.state, 'stop')
    assert.match(lifecycle.state.reason ?? '', /RING_TIMEOUT/)
    const refused = await dispatch('bash', { command: 'echo hi' })
    assert.equal(refused.ran, 0)
    // The explicit host-side call is the same fail-loud path.
    lifecycle.sinkFailed('BAD_PAYLOAD', 'structural sink failure')
    assert.equal(lifecycle.state.state, 'stop')
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_LIFECYCLE__
    delete (globalThis as Record<string, unknown>).__PDSH_FENCE__
    delete (globalThis as Record<string, unknown>).__PDSH_CHANNEL__
  }
})

test('watchdog: identical arguments on different tools are different calls', () => {
  const watchdog = new LoopWatchdog(3)
  assert.equal(watchdog.observe('read', { file: 'a' }).allowed, true)
  assert.equal(watchdog.observe('read', { file: 'a' }).allowed, true)
  assert.equal(watchdog.observe('grep', { file: 'a' }).allowed, true)
  assert.equal(watchdog.observe('read', { file: 'a' }).allowed, true)
  assert.equal(watchdog.observe('read', { file: 'a' }).allowed, true)
  assert.equal(watchdog.observe('read', { file: 'a' }).allowed, false)
})
