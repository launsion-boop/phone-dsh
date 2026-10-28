// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { currentToolCall } from '../exec-bridge/src/call-context.ts'
import { createClassifier } from '../tool-journal/src/classify.ts'
import { ToolJournal, schemaHash } from '../tool-journal/src/index.ts'
import { idempotencyKey } from '../tool-journal/src/journal.ts'
import type { CallEntry } from '../tool-journal/src/journal.ts'
import { interruptedCalls, plan } from '../tool-journal/src/reconcile.ts'
import type { LogEvent } from '../tool-journal/src/reconcile.ts'

const PROFILE = 'pdsh-phone/1+test'
const tools = {
  bash: { name: 'bash', description: 'run', parameters: { type: 'object' } },
  read: { name: 'read', description: 'read a file', parameters: { type: 'object' } },
  grep: { name: 'grep', description: 'search', parameters: { type: 'object' } },
}

/** An interrupted turn: four calls, three recorded as started, one never started. */
function crashedLog(): LogEvent[] {
  const call = (seq: number, id: string, name: string): LogEvent => ({ type: 'tool/call', seq, time: 10, data: { turn: 1, step: 2, callId: id, name, arguments: '{}' } })
  return [
    { type: 'turn/start', seq: 0, time: 1, data: { turn: 1 } },
    { type: 'step/start', seq: 1, time: 1, data: { turn: 1, step: 1 } },
    { type: 'assistant/message', seq: 2, time: 2, data: { step: 1, message: { content: [{ type: 'tool-call', id: 'old', name: 'read', arguments: '{}' }] } } },
    call(3, 'old', 'read'),
    { type: 'tool/result', seq: 4, time: 3, data: { turn: 1, step: 1, message: { source: { kind: 'tool', callId: 'old' } } } },
    { type: 'step/end', seq: 5, time: 3, data: { turn: 1, step: 1 } },
    { type: 'step/start', seq: 6, time: 4, data: { turn: 1, step: 2 } },
    {
      type: 'assistant/message', seq: 7, time: 5, data: {
        step: 2,
        message: {
          content: [
            { type: 'text', text: 'working' },
            { type: 'tool-call', id: 'c-bash', name: 'bash', arguments: '{"command":"charge"}' },
            { type: 'tool-call', id: 'c-read', name: 'read', arguments: '{"file_path":"a.txt"}' },
            { type: 'tool-call', id: 'c-done', name: 'bash', arguments: '{"command":"echo"}' },
            { type: 'tool-call', id: 'c-new', name: 'grep', arguments: '{}' },
          ],
        },
      },
    },
    call(8, 'c-bash', 'bash'),
    call(9, 'c-read', 'read'),
    call(10, 'c-done', 'bash'),
  ]
}

const start = (callId: string, tool: keyof typeof tools, profile = PROFILE, schema = schemaHash(tools[tool])): CallEntry['start'] => ({
  v: 1, t: 'start', key: idempotencyKey('s1', callId), call_id: callId, tool, class: 'x', args_sha256: '', schema_sha256: schema, profile, at: 1,
})

test('interruptedCalls returns only the open step\'s unanswered calls, with started seqs', () => {
  const calls = interruptedCalls(crashedLog())
  assert.deepEqual(calls.map(c => [c.callId, c.step, c.callSeq]), [['c-bash', 2, 8], ['c-read', 2, 9], ['c-done', 2, 10], ['c-new', 2, undefined]])
  assert.deepEqual(interruptedCalls([...crashedLog(), { type: 'step/end', seq: 11, time: 9, data: {} }]), [])
})

test('plan: backfill journaled results, re-run read-only, unknown for side effects, skip never-started', () => {
  const journal = new Map<string, CallEntry>([
    ['c-bash', { start: start('c-bash', 'bash') }],
    ['c-read', { start: start('c-read', 'read') }],
    ['c-done', { start: start('c-done', 'bash'), done: { content: [{ type: 'text', text: 'echoed' }], isError: false } }],
  ])
  const decisions = plan({
    calls: interruptedCalls(crashedLog()), journal, profile: PROFILE, classify: createClassifier(),
    schemaHash: name => schemaHash(tools[name as keyof typeof tools]),
  })
  assert.deepEqual(decisions.map(d => [d.call.callId, d.kind, 'reason' in d ? d.reason : undefined]), [
    ['c-bash', 'unknown', 'non-idempotent'],
    ['c-read', 'rerun', undefined],
    ['c-done', 'backfill', undefined],
    ['c-new', 'skip', undefined],
  ])
})

test('plan refuses a journal written by another profile or tool schema', () => {
  const calls = interruptedCalls(crashedLog()).slice(1, 3)
  const journal = new Map<string, CallEntry>([
    ['c-read', { start: start('c-read', 'read', 'pdsh-phone/0+old') }],
    ['c-done', { start: start('c-done', 'bash', PROFILE, 'stale-schema'), done: { content: [], isError: false } }],
  ])
  const decisions = plan({ calls, journal, profile: PROFILE, classify: createClassifier(), schemaHash: name => schemaHash(tools[name as keyof typeof tools]) })
  assert.equal(decisions[0]?.kind, 'unknown')
  assert.match((decisions[0] as { reason: string }).reason, /profile/)
  assert.equal(decisions[1]?.kind, 'unknown')
  assert.match((decisions[1] as { reason: string }).reason, /schema/)
})

test('ToolJournal.reconcile appends settled tool/results through the handle before closers run', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-reconcile-'))
  const executed: Array<{ name: string; key: string | undefined }> = []
  const ctx = new Context()
  ctx.provide('sessions', {})
  ctx.provide('tools', {
    get: (name: string) => tools[name as keyof typeof tools],
    execute: async (exec: { name: string }) => {
      executed.push({ name: exec.name, key: currentToolCall()?.key })
      return { isError: false, value: null, content: [{ type: 'text', text: 'fresh file text' }] }
    },
  })
  await ctx.plugin(ToolJournal, { root, profile: PROFILE, classes: {}, rerun: true, rerunTimeoutMs: 5000 })
  const journal = ctx.get('toolJournal') as ToolJournal
  await journal.store.append('s1', start('c-bash', 'bash') as never)
  await journal.store.append('s1', start('c-read', 'read') as never)
  await journal.store.append('s1', start('c-done', 'bash') as never)
  await journal.store.append('s1', { v: 1, t: 'done', key: idempotencyKey('s1', 'c-done'), call_id: 'c-done', result: { content: [{ type: 'text', text: 'echoed' }], isError: false }, at: 2 })
  const appended: LogEvent[] = []
  const handle = {
    read: async () => ({ events: crashedLog(), eventState: 'owned' }),
    append: async (events: LogEvent[]) => { appended.push(...events) },
    flush: async () => {},
  }
  const report = await journal.reconcile('s1', handle as never)
  assert.deepEqual(report.map(r => `${r.callId}=${r.action}`), ['c-bash=unknown', 'c-read=rerun', 'c-done=backfilled-done'])
  assert.deepEqual(executed, [{ name: 'read', key: idempotencyKey('s1', 'c-read') }])
  assert.deepEqual(appended.map(e => [e.type, e.seq, (e.data as { message: { toolCallId: string } }).message.toolCallId]), [
    ['tool/result', 11, 'c-bash'], ['tool/result', 12, 'c-read'], ['tool/result', 13, 'c-done'],
  ])
  const unknown = appended[0]?.data as { error: { code: string }; message: { isError: boolean; content: Array<{ text: string }> } }
  assert.equal(unknown.error.code, 'TOOL_OUTCOME_UNKNOWN')
  assert.equal(unknown.message.isError, true)
  assert.match(unknown.message.content[0]?.text ?? '', new RegExp(idempotencyKey('s1', 'c-bash')))
  assert.deepEqual(appended.map(e => e.sourceEventSeqs), [[8], [9], [10]])
  // Every decision is journaled as resolved, so a second open does not redo it.
  // The journal append is asynchronous (it may wait for a channel ack); the
  // caller's entry point settled it before reading back.
  await journal.store.settled('s1')
  const resolved = [...journal.store.entries('s1').calls.values()].map(e => e.resolved)
  assert.deepEqual(resolved, ['unknown', 'rerun', 'backfilled-done'])
  ctx.registry.delete(ToolJournal)
})
