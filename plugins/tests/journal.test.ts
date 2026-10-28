// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { appendFileSync, mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { ToolJournalStore, canonicalHash, idempotencyKey } from '../tool-journal/src/journal.ts'
import { createClassifier } from '../tool-journal/src/classify.ts'

test('idempotency keys are deterministic per (session, call)', () => {
  const a = idempotencyKey('session-1', 'call-1')
  assert.match(a, /^xl1-[0-9a-f]{32}$/)
  assert.equal(a, idempotencyKey('session-1', 'call-1'))
  assert.notEqual(a, idempotencyKey('session-1', 'call-2'))
  assert.notEqual(a, idempotencyKey('session-2', 'call-1'))
})

test('canonical hashes ignore key order', () => {
  assert.equal(canonicalHash({ b: 1, a: [{ y: 2, x: 1 }] }), canonicalHash({ a: [{ x: 1, y: 2 }], b: 1 }))
  assert.notEqual(canonicalHash({ a: 1 }), canonicalHash({ a: 2 }))
})

test('records survive reload; a torn final line is ignored', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-journal-'))
  const store = new ToolJournalStore(root, 'pdsh-phone/1+test')
  await store.append('s1', { v: 1, t: 'start', key: 'k', call_id: 'c1', tool: 'bash', class: 'non-idempotent', args_sha256: 'a', schema_sha256: 'b', profile: 'pdsh-phone/1+test', at: 1 })
  await store.append('s1', { v: 1, t: 'done', key: 'k', call_id: 'c1', result: { content: [{ type: 'text', text: 'ok' }], isError: false }, at: 2 })
  store.close()
  appendFileSync(store.path('s1'), '{"v":1,"t":"start","key":"k2","call_id":"c2"') // crash mid-append
  const { header, calls } = store.entries('s1')
  assert.equal(header?.profile, 'pdsh-phone/1+test')
  assert.equal(calls.size, 1)
  assert.deepEqual(calls.get('c1')?.done?.content, [{ type: 'text', text: 'ok' }])
})

test('compaction keeps only a fresh header', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-journal-'))
  const store = new ToolJournalStore(root, 'p')
  await store.append('s1', { v: 1, t: 'resolved', key: 'k', call_id: 'c1', action: 'unknown', at: 1 })
  await store.compact('s1')
  const lines = readFileSync(store.path('s1'), 'utf8').trim().split('\n')
  assert.equal(lines.length, 1)
  assert.equal(JSON.parse(lines[0] as string).t, 'header')
  await store.append('s1', { v: 1, t: 'resolved', key: 'k', call_id: 'c2', action: 'rerun', at: 2 })
  assert.equal(store.entries('s1').calls.size, 1)
})

test('session ids that are not file-name safe are hashed', () => {
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-journal-')), 'p')
  assert.match(store.path('../escape'), /[0-9a-f]{64}\.journal\.ndjson$/)
})

test('classifier: defaults, overrides, prefixes, unknown is non-idempotent', () => {
  const classify = createClassifier({ 'mcp__phone__calendar_*': 'read-only', bash: 'non-idempotent', write: 'idempotent' })
  assert.equal(classify('read'), 'read-only')
  assert.equal(classify('grep'), 'read-only')
  assert.equal(classify('bash'), 'non-idempotent')
  assert.equal(classify('write'), 'idempotent')
  assert.equal(classify('mcp__phone__calendar_list'), 'read-only')
  assert.equal(classify('mcp__phone__calendar'), 'non-idempotent')
  assert.equal(classify('something_new'), 'non-idempotent')
})

test('the journal source never calls fsyncSync', () => {
  const source = readFileSync(new URL('../tool-journal/src/journal.ts', import.meta.url), 'utf8')
  assert.doesNotMatch(source, /fsyncSync/)
})
