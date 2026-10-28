// SPDX-License-Identifier: MIT
// G2-FIX-83: the tool-call boundary persistence chain is event-driven.
//
// A boundary is a VFS flush of the last emitted mseq (0x10 -> 0x11) plus the
// tool-journal append of the boundary record (0x30 -> 0x31), not a timer. These
// tests pin the Worker half of that chain after a multi-MiB sink write: the
// flush resolves only on ack arrival, and the journal sync/wait p95 stays under
// the one-second gate the work package applies. The matching host half lives in
// `ChannelMetrics.ackTimings` (`ChannelServerAckTimingTests`); the host-side
// rescan regression lives in `BoundaryAckCadenceTests` in the Swift log tests.

import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  createMemoryChannelPair, decodeJournal, encodeJournalAck, FrameType,
  encodeVfsAck,
} from '../channel/src/index.ts'
import {
  installSink, type VfsFlushTiming, type WorkerEntryMutation, type WorkerEntryVfs,
} from '../worker-entry/src/entry.ts'
import {
  ToolJournalStore, type JournalRecord, type JournalSyncTiming,
} from '../tool-journal/src/journal.ts'

const MIB = 1024 * 1024
/** Gate from the work package: one call boundary p95 < 1 s. */
const PER_CALL_BUDGET_MS = 1_000

function settle(): Promise<void> {
  return new Promise<void>((resolve) => { setTimeout(resolve, 0) })
}

interface FakeVfs extends WorkerEntryVfs {
  emit(mutation: WorkerEntryMutation): void
}

function createFakeVfs(): FakeVfs {
  const listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  return {
    subscribe(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    async flush() {},
    emit(mutation) {
      for (const listener of [...listeners]) listener(mutation)
    },
  }
}

function largeWrite(bytes: number): WorkerEntryMutation {
  const data = new Uint8Array(bytes)
  data.fill(0x5a)
  return { kind: 'write', path: '/dsh/workspace/sink/large.bin',
    bytes: data, mode: 0o644, entryChanged: true }
}

function startRecord(call: number): JournalRecord {
  return {
    v: 1, t: 'start', key: `xl1-${String(call).padStart(32, '0')}`, call_id: `call-${call}`,
    tool: 'bash', class: 'non-idempotent', args_sha256: 'a', schema_sha256: null,
    profile: 'phone', at: call,
  }
}

function doneRecord(call: number): JournalRecord {
  return {
    v: 1, t: 'done', key: `xl1-${String(call).padStart(32, '0')}`, call_id: `call-${call}`,
    result: { content: [{ type: 'text', text: 'ok' }], isError: false }, at: call,
  }
}

function percentile(samples: readonly number[], fraction: number): number {
  const sorted = [...samples].sort((left, right) => left - right)
  const rank = Math.min(sorted.length - 1,
    Math.max(0, Math.ceil(sorted.length * fraction) - 1))
  return sorted[rank]!
}

test('a multi-MiB sink flush resolves on the level-1 ack arrival, never on a timer', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 1n, autoAck: false })
  const vfs = createFakeVfs()
  const timings: VfsFlushTiming[] = []
  const dispose = installSink(vfs, pair.worker, {
    onFlushTiming: (timing) => { timings.push(timing) },
  })
  try {
    vfs.emit(largeWrite(2 * MIB))
    await settle()
    let resolved = false
    const started = Date.now()
    const flushing = vfs.flush().then(() => { resolved = true })
    await settle()
    assert.equal(resolved, false, 'the flush must wait for the host ack')
    pair.host.send(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 1n }))
    await flushing
    assert.equal(resolved, true)
    const elapsed = Date.now() - started
    assert.ok(elapsed < PER_CALL_BUDGET_MS,
      `the ack-arrival wake-up took ${String(elapsed)} ms`)
    assert.equal(timings.length, 1)
    const timing = timings[0]!
    assert.equal(timing.mseq, 1n)
    assert.equal(timing.alreadyAcked, false)
    assert.ok(timing.ackedAtMilliseconds >= timing.startedAtMilliseconds)
    assert.ok(timing.waitMilliseconds < PER_CALL_BUDGET_MS,
      `flush hop for mseq ${String(timing.mseq)} took ${String(timing.waitMilliseconds)} ms`)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('zero-work tool-call boundaries keep p95 < 1 s after a large sink write', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 1n })
  // Host double for the journal: answer every 0x30 with its level-1 0x31 on the
  // next microtask, like the host's ack-emission path after a group commit.
  pair.host.onFrame((frame) => {
    if (frame.type !== FrameType.JOURNAL) return
    const journal = decodeJournal(frame.payload)
    const reply = encodeJournalAck({
      level: 1, sessionId: journal.sessionId, uptoJseq: journal.jseq,
    })
    queueMicrotask(() => { pair.host.send(FrameType.JOURNAL_ACK, reply) })
  })
  const vfs = createFakeVfs()
  const flushTimings: VfsFlushTiming[] = []
  const dispose = installSink(vfs, pair.worker, {
    onFlushTiming: (timing) => { flushTimings.push(timing) },
  })
  const syncTimings: JournalSyncTiming[] = []
  const store = new ToolJournalStore(mkdtempSync(join(tmpdir(), 'pdsh-boundary-')), 'phone', {
    channel: pair.worker,
    onSyncTiming: (timing) => { syncTimings.push(timing) },
  })
  try {
    // Large sink write first: this is the trigger the defect report names.
    vfs.emit(largeWrite(2 * MIB))
    await vfs.flush()
    const samples: number[] = []
    for (let call = 1; call <= 20; call += 1) {
      const started = Date.now()
      // Tool-journal start + completion: the boundary the host records as
      // tool_dispatched -> journaled. The command itself does no work.
      await store.append('session-1', startRecord(call))
      await store.append('session-1', doneRecord(call))
      samples.push(Date.now() - started)
    }
    const p95 = percentile(samples, 0.95)
    assert.ok(p95 < PER_CALL_BUDGET_MS,
      `tool-call boundary p95 ${String(p95)} ms exceeds the ${String(PER_CALL_BUDGET_MS)} ms gate (samples: ${JSON.stringify(samples)})`)
    assert.equal(syncTimings.length, 40)
    for (const timing of syncTimings) {
      assert.ok(timing.waitMilliseconds < PER_CALL_BUDGET_MS,
        `journal hop for jseq ${String(timing.jseq)} took ${String(timing.waitMilliseconds)} ms`)
      assert.ok(timing.ackedAtMilliseconds >= timing.startedAtMilliseconds)
    }
    assert.ok(flushTimings.length >= 1, 'the large write produced a flush hop sample')
  } finally {
    store.close()
    dispose()
    await pair.worker.close()
  }
})
