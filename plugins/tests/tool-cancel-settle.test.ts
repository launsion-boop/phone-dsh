// SPDX-License-Identifier: MIT
/**
 * G2-FIX-84 regression: a budget/cancel teardown settles the in-flight tool
 * call instead of leaving it half-written.
 *
 * The defect: the runner stops the host on a wall/request budget. DSH cancels
 * the turn and waits for the dispatched tool body, but a long-running
 * non-idempotent command that does not observe the abort keeps the turn open
 * until the Worker is killed. Nothing then writes the terminal `tool/result`,
 * the tool journal has a `start` with no end, and the D13 step stays at
 * `tool_dispatched` forever.
 *
 * This component test drives the real `ToolJournal` boundary with a tool body
 * that represents a >= 60 s non-idempotent command (`bash` writing files after
 * a long wait). The runner budget cancel is modeled by aborting the fused
 * `exec.signal` with the same `AgentCancelCause` chain the runner uses. Before
 * the fix the boundary awaits the body for the full 60 s (the test's own
 * deadline fails) and journals no end; after the fix it returns the terminal
 * `isError` result with the cause, writes `start` + `done`, and a replay of
 * that journal backfills the same aborted result.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolJournal } from '../tool-journal/src/index.ts'
import { interruptedCalls, plan } from '../tool-journal/src/reconcile.ts'
import type { LogEvent } from '../tool-journal/src/reconcile.ts'
import { createClassifier } from '../tool-journal/src/classify.ts'

/** Fail the test rather than hang on a boundary that awaits the whole command. */
function within<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label} did not settle within ${milliseconds} ms`))
    }, milliseconds)
    timer.unref?.()
    promise.then(
      value => { clearTimeout(timer); resolve(value) },
      error => { clearTimeout(timer); reject(error) },
    )
  })
}

test('G2-FIX-84: a budget cancel settles the in-flight tool call, journal and replay', {
  timeout: 10_000,
}, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-tool-cancel-'))
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root,
    profile: 'pdsh-phone/1+g2-fix-84',
    classes: {},
    rerun: true,
    rerunTimeoutMs: 1_000,
    abortSettleMs: 100,
  })
  const journal = ctx.get('toolJournal') as ToolJournal
  const sessionId = 'session-regression'
  const callId = 'call_budget_cut'
  const controller = new AbortController()
  // The runner budget cause: a hook cause wrapping the budget reason, the
  // shape DSH forwards into the tool signal (AgentCancelCause).
  const cause = {
    kind: 'hook',
    reason: { kind: 'budget', detail: 'budget.max_minutes=10 elapsed' },
  }
  let bodySettled = false
  let bodyStarted = false

  // A long-running non-idempotent command: `bash`/python writing shards after
  // a long wait. It deliberately ignores the abort signal, which is exactly
  // the class the teardown must settle without the command's cooperation.
  const body = new Promise<never>((_resolve) => {
    bodyStarted = true
    const timer = setTimeout(() => {
      bodySettled = true
    }, 60_000)
    timer.unref?.()
  })

  const startedAt = Date.now()
  const dispatch = ctx.waterfall('tools/execute', {
    agent: { session: { id: sessionId } },
    parent: undefined,
    name: 'bash',
    callId,
    arguments: { command: 'python3 - <<PY ... write 2 x 8 MiB shards ... PY' },
    signal: controller.signal,
  } as never, (() => body) as never) as unknown as Promise<Record<string, unknown>>

  // Let the journal record `start` and the body begin, then apply the runner
  // budget cancel exactly as the drain does.
  await new Promise(resolve => setTimeout(resolve, 20))
  assert.equal(bodyStarted, true, 'the long-running command was dispatched before the cancel')
  assert.equal(journal.store.entries(sessionId).calls.get(callId)?.done, undefined,
    'the call has no end before the budget cancel')
  controller.abort(cause)

  const result = await within(dispatch, 3_000, 'the aborted tool boundary')
  const elapsed = Date.now() - startedAt

  // 1. DSH receives a terminal isError result with the full cancel cause; this
  //    is the `tool/result` it appends to the session log.
  assert.equal(result['isError'], true, 'the terminal result is an error result')
  const error = result['error'] as { message?: string; info?: Record<string, unknown> } | undefined
  assert.equal(error?.info?.['code'], 'ABORTED', `the result carries the abort code: ${JSON.stringify(result)}`)
  assert.equal(error?.info?.['reason'], JSON.stringify(cause),
    'the AgentCancelCause chain is preserved verbatim in the terminal result')
  assert.match(String((result['content'] as Array<{ text?: string }>)[0]?.text),
    /cut off|aborted|cancelled/i,
    'the model-facing text marks the call as cut off instead of pretending it completed')
  assert.equal(bodySettled, false,
    'the boundary settled the call although the command never returned')
  assert.ok(elapsed < 3_000, `the boundary settled in ${elapsed} ms, not after the 60 s command`)

  // 2. The journal has both ends: `start` and a terminal `done` with isError
  //    and the cancel cause. This is the evidence the D13 step machine turns
  //    into `journaled` instead of leaving `tool_dispatched`.
  const entry = journal.store.entries(sessionId).calls.get(callId)
  assert.notEqual(entry?.start, undefined, 'the journal recorded the dispatch start')
  assert.equal(entry?.done?.isError, true, 'the journal recorded a terminal error end')
  assert.equal(entry?.done?.error?.code, 'ABORTED')
  assert.equal(entry?.done?.error?.reason, JSON.stringify(cause))
  const lines = readFileSync(journal.store.path(sessionId), 'utf8').trim().split('\n').map(line => JSON.parse(line) as { t: string })
  assert.deepEqual(lines.map(line => line.t), ['header', 'start', 'done'],
    'the journal has start and end, not start alone')

  // 3. Replay: the persisted session log with the open tool call resolves from
  //    the journal's terminal record (no re-run, no unknown outcome) and the
  //    aborted result is visible.
  const events: LogEvent[] = [
    { type: 'turn/start', seq: 1, time: 1, data: { turn: 1 } },
    { type: 'step/start', seq: 2, time: 2, data: { turn: 1, step: 1 } },
    {
      type: 'assistant/message', seq: 3, time: 3,
      data: {
        turn: 1,
        step: 1,
        message: {
          content: [{
            type: 'tool-call',
            id: callId,
            name: 'bash',
            arguments: '{"command":"sleep 90"}',
          }],
        },
      },
    },
    { type: 'tool/call', seq: 4, time: 4, data: { turn: 1, step: 1, callId, arguments: '{"command":"sleep 90"}' } },
  ]
  const interrupted = interruptedCalls(events)
  assert.equal(interrupted.length, 1, 'the replayed session has the open tool call')
  const decisions = plan({
    calls: interrupted,
    journal: journal.store.entries(sessionId).calls,
    profile: 'pdsh-phone/1+g2-fix-84',
    classify: createClassifier({}),
    schemaHash: () => undefined,
  })
  assert.equal(decisions[0]?.kind, 'backfill', 'the replay backfills the terminal recorded result')
  if (decisions[0]?.kind === 'backfill') {
    assert.equal(decisions[0].source, 'done')
    assert.equal(decisions[0].result.isError, true)
    assert.equal(decisions[0].result.error?.reason, JSON.stringify(cause))
  }

  await ctx.fiber.dispose()
})

test('G2-FIX-84: the host LIFECYCLE stop cancels the in-flight Worker command signal', {
  timeout: 10_000,
}, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-tool-cancel-lifecycle-'))
  const events = new EventTarget()
  ;(globalThis as Record<string, unknown>).__PDSH_EVENTS__ = events
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root,
    profile: 'pdsh-phone/1+g2-fix-84',
    classes: {},
    rerun: true,
    rerunTimeoutMs: 1_000,
    abortSettleMs: 100,
  })
  const journal = ctx.get('toolJournal') as ToolJournal
  const sessionId = 'session-drain'
  const callId = 'call_drain_cut'
  const controller = new AbortController()
  let commandObservedAbort = false
  const exec = {
    agent: { session: { id: sessionId } },
    parent: undefined,
    name: 'bash',
    callId,
    arguments: { command: 'sleep 90; printf partial > shard.bin' },
    signal: controller.signal,
  }
  const dispatch = ctx.waterfall('tools/execute', exec as never, (() => {
    // This is the in-Worker command surface: it only sees `exec.signal`.
    // The host teardown must reach this exact signal, not only the session.
    const signal = (exec as { signal: AbortSignal }).signal
    signal.addEventListener('abort', () => { commandObservedAbort = true }, { once: true })
    return new Promise<never>(() => {
      const timer = setTimeout(() => {}, 60_000)
      timer.unref?.()
    })
  }) as never) as unknown as Promise<Record<string, unknown>>

  await new Promise(resolve => setTimeout(resolve, 20))
  // The host closes admission and sends `0x50 LIFECYCLE stop` at the start of
  // the drain; the Worker entry dispatches it as this event.
  events.dispatchEvent(new CustomEvent('pdsh-lifecycle', {
    detail: { state: 'stop', budget: BigInt(0), admission: 'closed', reason: 'drain' },
  }))

  const result = await within(dispatch, 3_000, 'the lifecycle-cancelled tool boundary')
  assert.equal(commandObservedAbort, true,
    'the in-flight Worker command observed the host teardown on its signal')
  assert.equal(result['isError'], true)
  const error = result['error'] as { info?: Record<string, unknown> } | undefined
  assert.equal(error?.info?.['code'], 'ABORTED')
  const cause = JSON.parse(String(error?.info?.['reason'])) as {
    kind?: string
    reason?: { kind?: string; reason?: string }
  }
  assert.equal(cause.kind, 'hook')
  assert.equal(cause.reason?.kind, 'drain')
  assert.equal(cause.reason?.reason, 'drain')
  const entry = journal.store.entries(sessionId).calls.get(callId)
  assert.notEqual(entry?.start, undefined)
  assert.equal(entry?.done?.isError, true)
  assert.match(String(entry?.done?.error?.reason), /drain/)

  await ctx.fiber.dispose()
  delete (globalThis as Record<string, unknown>).__PDSH_EVENTS__
})
