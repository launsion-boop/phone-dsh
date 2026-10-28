// SPDX-License-Identifier: MIT
/**
 * Recovery re-run cancellation releases the write-open even when the tool body
 * does not settle on its own AbortSignal.
 *
 * DSH's tool registry waits for a started body to reach quiescence before it
 * reports `ABORTED`, so awaiting `tools.execute` alone can hold the session
 * writer past the route deadline. `ToolJournal.reconcile` races the real
 * execution against the fused route/rerun-timeout signal instead. A re-run is
 * restricted to read-only / idempotent calls, so releasing the writer at the
 * deadline is safe; the abandoned body is observed and never journaled as a
 * result.
 */
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { Context } from '@deepseek-ai/cordis'

import { ToolJournal } from '../tool-journal/src/index.ts'
import type { LogEvent } from '../tool-journal/src/reconcile.ts'

const PROFILE = 'pdsh-phone/1+rerun-cancel'
const SESSION_ID = 'rerun-cancel-1'
const CALL_ID = 'call-rerun-cancel-1'

/** The open tail turn of a session whose one `read` call has no result. */
function interruptedLog(): LogEvent[] {
  const args = '{"file_path":"blocked.txt"}'
  return [
    { type: 'turn/start', seq: 1, time: 1, data: { turn: 1 } },
    { type: 'step/start', seq: 2, time: 2, data: { turn: 1, step: 1 } },
    {
      type: 'assistant/message', seq: 3, time: 3,
      data: { step: 1, message: { content: [{ type: 'tool-call', id: CALL_ID, name: 'read', arguments: args }] } },
    },
    { type: 'tool/call', seq: 4, time: 4, data: { turn: 1, step: 1, callId: CALL_ID, name: 'read', arguments: args } },
  ]
}

/** A write handle whose reads return the interrupted log and whose appends are counted. */
function handleFor(appended: LogEvent[]): Record<string, unknown> {
  return {
    read: async () => ({ events: interruptedLog(), eventState: 'owned' }),
    append: async (events: LogEvent[]) => { appended.push(...events) },
    flush: async () => {},
  }
}

test('a route deadline releases a re-run whose body never settles', { timeout: 10_000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-rerun-cancel-'))
  const ctx = new Context()
  let bodySignal: AbortSignal | undefined
  let bodyObservedAbort = false
  let bodyStarted = false
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', {
    get: () => ({ name: 'read', description: 'read', parameters: { type: 'object' } }),
    execute: async (exec: { signal: AbortSignal }) => {
      bodySignal = exec.signal
      bodyStarted = true
      exec.signal.addEventListener('abort', () => { bodyObservedAbort = true }, { once: true })
      // Deliberately ignores cancellation, like a body blocked in native I/O.
      return await new Promise<never>(() => {})
    },
  })
  await ctx.plugin(ToolJournal, { root, profile: PROFILE, classes: {}, rerun: true, rerunTimeoutMs: 60_000 })
  const journal = ctx.get('toolJournal') as ToolJournal
  await journal.store.append(SESSION_ID, {
    v: 1, t: 'start', key: 'xl1-test', call_id: CALL_ID, tool: 'read', class: 'read-only',
    args_sha256: '', schema_sha256: null, profile: PROFILE, at: 1,
  })
  await journal.store.settled(SESSION_ID)

  const appended: LogEvent[] = []
  const controller = new AbortController()
  const startedAt = Date.now()
  const reconcile = journal.reconcile(SESSION_ID, handleFor(appended) as never, controller.signal)
  setTimeout(() => { controller.abort(new Error('recovery route deadline')) }, 100)
  const outcome = await Promise.race([
    reconcile.then(() => 'resolved', (error: unknown) => error),
    new Promise<'timeout'>(resolve => { setTimeout(() => { resolve('timeout') }, 2_000) }),
  ])
  const elapsed = Date.now() - startedAt

  assert.notEqual(outcome, 'timeout',
    'the reconcile must release the writer on the route deadline even though the tool body ignores its signal')
  assert.ok(outcome instanceof Error, `the cancelled re-run must reject: ${String(outcome)}`)
  assert.match(outcome.message, /recovery route deadline/)
  assert.equal(bodyStarted, true, 'the real tool body was dispatched before cancellation')
  assert.equal(bodyObservedAbort, true, 'the tool body received the route cancellation')
  assert.equal(bodySignal?.aborted, true)
  assert.ok(elapsed < 1_500, `the cancellation settled in ${elapsed} ms, not after the 60 s rerun timeout`)
  assert.deepEqual(appended, [], 'a cancelled re-run must not synthesize a tool/result')
  const entry = journal.store.entries(SESSION_ID).calls.get(CALL_ID)
  assert.equal(entry?.done, undefined, 'a cancelled re-run must not journal a result')
  assert.equal(entry?.resolved, undefined, 'a cancelled re-run must not journal a resolution')
  await ctx.fiber.dispose()
})

test('the re-run timeout settles an uncooperative body as unknown, not a hang', { timeout: 10_000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-rerun-timeout-'))
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', {
    get: () => ({ name: 'read', description: 'read', parameters: { type: 'object' } }),
    execute: async () => await new Promise<never>(() => {}),
  })
  await ctx.plugin(ToolJournal, { root, profile: PROFILE, classes: {}, rerun: true, rerunTimeoutMs: 100 })
  const journal = ctx.get('toolJournal') as ToolJournal
  await journal.store.append(SESSION_ID, {
    v: 1, t: 'start', key: 'xl1-test', call_id: CALL_ID, tool: 'read', class: 'read-only',
    args_sha256: '', schema_sha256: null, profile: PROFILE, at: 1,
  })
  await journal.store.settled(SESSION_ID)

  const appended: LogEvent[] = []
  const startedAt = Date.now()
  const report = await Promise.race([
    journal.reconcile(SESSION_ID, handleFor(appended) as never),
    new Promise<'timeout'>(resolve => { setTimeout(() => { resolve('timeout') }, 2_000) }),
  ])
  assert.notEqual(report, 'timeout', 'the rerunTimeoutMs deadline must settle the reconcile')
  assert.equal(Array.isArray(report), true)
  const decisions = report as Array<{ callId: string; action: string; detail?: string }>
  assert.equal(decisions.length, 1)
  assert.equal(decisions[0]?.callId, CALL_ID)
  assert.equal(decisions[0]?.action, 'unknown')
  assert.match(decisions[0]?.detail ?? '', /^re-run failed: .*timeout/i)
  assert.ok(Date.now() - startedAt < 1_500)
  assert.equal(appended.length, 1, 'the timed-out re-run is reported once as unknown')
  assert.equal((appended[0]?.data as { error?: { code?: string } } | undefined)?.error?.code, 'TOOL_OUTCOME_UNKNOWN')
  await ctx.fiber.dispose()
})
