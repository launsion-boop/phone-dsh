// SPDX-License-Identifier: MIT
// Two-level tool-journal confirmation over the ordered channel: 0x30 in,
// 0x31 level 1 for append, level 2 only through the checkpoint barrier.
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { decodeJournal } from '@phone-dsh/dsh-channel/vfs-mutation'
import { ToolJournal } from '../tool-journal/src/index.ts'
import { ToolJournalStore } from '../tool-journal/src/journal.ts'
import type { JournalRecord } from '../tool-journal/src/journal.ts'
import { MockChannel, eventually } from './test-channel.ts'

const start = (callId: string): JournalRecord => ({
  v: 1, t: 'start', key: `xl1-${callId}`, call_id: callId, tool: 'bash', class: 'non-idempotent',
  args_sha256: 'a', schema_sha256: null, profile: 'p', at: 1, turn_id: '1', step_id: '1',
})

test('journal append sends 0x30 and resolves only at the level-1 ack', async () => {
  const mock = new MockChannel({ journalAck: 'manual' })
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-jsync-')), 'p', { channel: mock })
  let settled = false
  const append = store.append('sess_01', start('c1')).then(() => { settled = true })
  await eventually(() => mock.framesOf(0x30).length === 1)
  const frame = mock.framesOf(0x30)[0] as { payload: Uint8Array }
  const decoded = decodeJournal(frame.payload)
  assert.equal(decoded.jseq, 1n)
  assert.equal(decoded.sessionId, 'sess_01')
  const wire = JSON.parse(new TextDecoder().decode(decoded.record)) as Record<string, unknown>
  assert.equal(wire.type, 'dispatched')
  assert.equal(wire.call_id, 'c1')
  assert.equal(wire.turn_id, '1')
  assert.equal(settled, false, 'the append must wait for the host ack')
  mock.emitJournalAck(1, 'sess_01', 1n)
  await append
  assert.deepEqual(store.confirmed('sess_01'), { level: 1, uptoJseq: 1n })
  store.close()
})

test('journal jseq continues across compaction and never reuses a host-deduplicated number', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jsync-'))
  const mock = new MockChannel({ journalAck: 1 })
  const store = new ToolJournalStore(root, 'p', { channel: mock })
  await store.append('s', start('c1'))
  await store.append('s', start('c2'))
  assert.deepEqual(mock.framesOf(0x30).map(frame => decodeJournal((frame as { payload: Uint8Array }).payload).jseq), [1n, 2n])
  await store.compact('s')
  const reopened = new ToolJournalStore(root, 'p', { channel: mock })
  await reopened.append('s', start('c3'))
  const frames = mock.framesOf(0x30)
  assert.equal(decodeJournal((frames[2] as { payload: Uint8Array }).payload).jseq, 3n)
  reopened.close()
  store.close()
})

test('checkpoint requests level 2 through the channel barrier and never infers the 0x31 level', async () => {
  const mock = new MockChannel({ journalAck: 1 })
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-jsync-')), 'p', { channel: mock })
  await store.append('s', start('c1'))
  assert.equal(store.confirmed('s').level, 1)
  mock.setNextMseq(10n)
  await store.checkpoint('s')
  assert.deepEqual(mock.barrierCalls.at(-1), { level: 2, uptoMseq: 9n })
  // A VFS barrier only requests an epoch close; the journal's level 2 is a
  // separate 0x31 the host emits after closeEpoch (W2 adapter), so it must not
  // be inferred here.
  assert.deepEqual(store.confirmed('s'), { level: 1, uptoJseq: 1n })
  mock.emitJournalAck(2, 's', 1n)
  assert.deepEqual(store.confirmed('s'), { level: 2, uptoJseq: 1n })
  store.close()
})

test('a malformed channel ack leaves the append pending rather than confirming it', async () => {
  const mock = new MockChannel({ journalAck: 'manual' })
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-jsync-')), 'p', { channel: mock })
  let settled = false
  const append = store.append('s', start('c1')).then(() => { settled = true })
  await eventually(() => mock.framesOf(0x30).length === 1)
  mock.emit(0x31, new Uint8Array([1, 0]))
  await new Promise(resolve => setTimeout(resolve, 20))
  assert.equal(settled, false)
  mock.emitJournalAck(1, 's', 1n)
  await append
  store.close()
})

test('the ToolJournal service mirrors its plaintext journal to the installed channel', async () => {
  const mock = new MockChannel({ journalAck: 1 })
  ;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  ctx.provide('sessions', {})
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root: mkdtempSync(join(tmpdir(), 'pdsh-jsync-')),
    profile: 'p',
    classes: {},
    rerun: true,
    rerunTimeoutMs: 1000,
  })
  try {
    const journal = ctx.get('toolJournal') as ToolJournal
    await journal.store.append('s', start('c1'))
    assert.equal(mock.framesOf(0x30).length, 1)
    assert.equal(journal.store.confirmed('s').level, 1)
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_CHANNEL__
  }
})
