// SPDX-License-Identifier: MIT
// G2-FIX-10 regression: every Worker-side durability confirmation wait is
// bounded. A host that silently drops a 0x11/0x31/0x12 frame used to park the
// tool-journal chain and the VFS flush forever (the agent loop then never
// dispatched the next model request). Pre-fix both tests below hung until the
// runner killed the wall clock; post-fix they reject with ACK_TIMEOUT.
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { ChannelClient } from '@phone-dsh/dsh-channel/client'
import { AckTimeoutError } from '@phone-dsh/dsh-channel/ack-tracker'
import { ChannelJournalSync, ToolJournalStore } from '../tool-journal/src/journal.ts'
import type { JournalRecord } from '../tool-journal/src/journal.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { FrameType } from '@phone-dsh/dsh-channel/frames'
import { MockChannel } from './test-channel.ts'
import { TreeVfs } from './tree-vfs.ts'

const ACK_TIMEOUT_MS = 20

const start = (callId: string): JournalRecord => ({
  v: 1, t: 'start', key: `xl1-${callId}`, call_id: callId, tool: 'bash', class: 'non-idempotent',
  args_sha256: 'a', schema_sha256: null, profile: 'p', at: 1, turn_id: '1', step_id: '1',
})

test('journal append rejects within the bound when the host swallows the 0x31', async () => {
  const mock = new MockChannel({ journalAck: 'manual', ackTimeoutMs: ACK_TIMEOUT_MS })
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-durability-')), 'p', {
    channel: mock,
    ackTimeoutMs: ACK_TIMEOUT_MS,
  })
  try {
    const started = Date.now()
    await assert.rejects(
      store.append('sess_01', start('c1')),
      (error: unknown) => error instanceof AckTimeoutError && error.code === 'ACK_TIMEOUT',
    )
    assert.ok(Date.now() - started < 2_000, 'the append wait must be bounded')
    // The record was sent with its original jseq; replay is the channel path.
    assert.equal(mock.framesOf(FrameType.JOURNAL).length, 1)
  } finally {
    store.close()
    await mock.close()
  }
})

test('wrapped vfs flush rejects within the bound when the host swallows the 0x11', async () => {
  const mock = new MockChannel({ journalAck: 1, ackTimeoutMs: ACK_TIMEOUT_MS })
  const vfs = new TreeVfs()
  vfs.mkdirSync('/dsh', { recursive: true })
  vfs.mkdirSync('/dsh/workspace', { recursive: true })
  const dispose = installSink(vfs, mock, { ackTimeoutMs: ACK_TIMEOUT_MS })
  try {
    vfs.writeFileSync('/dsh/workspace/a.txt', 'hello')
    assert.equal(mock.framesOf(FrameType.VFS_MUT).length, 1)
    const started = Date.now()
    await assert.rejects(
      vfs.flush(),
      (error: unknown) => error instanceof AckTimeoutError && error.code === 'ACK_TIMEOUT',
    )
    assert.ok(Date.now() - started < 2_000, 'the flush ack wait must be bounded')
  } finally {
    dispose()
    await mock.close()
  }
})

test('checkpoint barrier (0x12 level 2) rejects within the bound when unanswered', async () => {
  // Only the level-2 barrier path is exercised; the mock call sites above use
  // a channel whose ack trackers are real.
  const hangingBarrier = new Promise<void>(() => {})
  const stub = {
    nextMseq: () => 5n,
    barrier: () => hangingBarrier,
  } as unknown as ChannelClient
  const sync = new ChannelJournalSync(stub, { ackTimeoutMs: ACK_TIMEOUT_MS })
  const started = Date.now()
  await assert.rejects(
    sync.checkpoint('sess_01'),
    (error: unknown) => error instanceof AckTimeoutError,
  )
  assert.ok(Date.now() - started < 2_000, 'the barrier wait must be bounded')
})
