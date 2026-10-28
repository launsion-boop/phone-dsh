// SPDX-License-Identifier: MIT
// G2-FIX-119: a slow journal 0x30 -> 0x31 hop must distinguish a starved Worker
// event loop from real host ack latency. A CPU-bound in-Worker command can keep
// the host's fast ack queued for over a second; that wait is not a host defect
// and must not pollute the scenario's console_errors. The same test file pins
// that a genuinely slow host ack still reports exactly one error.

import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { FrameType } from '@phone-dsh/dsh-channel/frames'
import { ToolJournal } from '../tool-journal/src/index.ts'
import { ChannelJournalSync, JOURNAL_SYNC_HEARTBEAT_MILLISECONDS } from '../tool-journal/src/journal.ts'
import type { JournalRecord, JournalSyncTiming } from '../tool-journal/src/journal.ts'
import { MockChannel, eventually } from './test-channel.ts'

/** G2-FIX-119 gate: a journal sync at or above one second is a candidate. */
const SLOW_MILLISECONDS = 1_000
/** What a unit test can afford to keep the Worker blocked. */
const BUSY_MILLISECONDS = 1_200
/** What a real slow host ack costs in the idle-event-loop test. */
const SLOW_HOST_MILLISECONDS = 1_200

const startRecord = (callId: string): JournalRecord => ({
  v: 1, t: 'start', key: `xl1-${callId}`, call_id: callId, tool: 'bash', class: 'non-idempotent',
  args_sha256: 'a', schema_sha256: null, profile: 'p', at: 1,
})

function sleep(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve) => { setTimeout(resolve, milliseconds) })
}

/** Block this single-threaded Worker exactly like a CPU-bound in-process tool. */
function blockEventLoop(milliseconds: number): number {
  const started = Date.now()
  while (Date.now() - started < milliseconds) { /* spin */ }
  return Date.now() - started
}

interface NumericIntervalIds {
  /** Heartbeat intervals still registered under a numeric id. */
  readonly activeHeartbeats: number
  restore(): void
}

/**
 * JavaScriptCore's Web Worker returns a number from `setInterval`, not a Node
 * `Timeout`. Keep real timers running while exposing numeric ids so a Node-only
 * `.unref()` cannot silently depend on the test runtime.
 */
function useNumericIntervalIds(): NumericIntervalIds {
  const globals = globalThis as unknown as {
    setInterval: (handler: (...args: unknown[]) => void, timeout?: number, ...args: unknown[]) => unknown
    clearInterval: (id: unknown) => void
  }
  const originalSetInterval = globals.setInterval.bind(globalThis)
  const originalClearInterval = globals.clearInterval.bind(globalThis)
  const timers = new Map<number, unknown>()
  const heartbeatIds = new Set<number>()
  let nextId = 1
  globals.setInterval = (handler, timeout, ...args) => {
    const timer = originalSetInterval(handler, timeout, ...args)
    const id = nextId++
    timers.set(id, timer)
    if (timeout === JOURNAL_SYNC_HEARTBEAT_MILLISECONDS) heartbeatIds.add(id)
    return id
  }
  globals.clearInterval = (id) => {
    if (typeof id === 'number' && timers.has(id)) {
      const timer = timers.get(id)
      timers.delete(id)
      heartbeatIds.delete(id)
      originalClearInterval(timer)
      return
    }
    originalClearInterval(id)
  }
  return {
    get activeHeartbeats(): number { return heartbeatIds.size },
    restore(): void {
      for (const timer of timers.values()) originalClearInterval(timer)
      timers.clear()
      heartbeatIds.clear()
      globals.setInterval = originalSetInterval
      globals.clearInterval = originalClearInterval
    },
  }
}

interface SyncErrorCapture {
  readonly messages: string[]
  restore(): void
}

function captureJournalSyncErrors(): SyncErrorCapture {
  const messages: string[] = []
  const original = console.error
  console.error = (...args: unknown[]): void => {
    const text = args.map(argument => typeof argument === 'string' ? argument : String(argument)).join(' ')
    if (text.includes('pdsh-journal-sync')) messages.push(text)
    else original(...args)
  }
  return {
    messages,
    restore: (): void => { console.error = original },
  }
}

/** The bounded global the ToolJournal service publishes for artifact reconciliation. */
function syncTimings(): JournalSyncTiming[] {
  const global = globalThis as { __PDSH_JOURNAL_SYNC_TIMINGS__?: JournalSyncTiming[] }
  assert.ok(global.__PDSH_JOURNAL_SYNC_TIMINGS__ !== undefined,
    'the ToolJournal service must publish __PDSH_JOURNAL_SYNC_TIMINGS__')
  return global.__PDSH_JOURNAL_SYNC_TIMINGS__
}

function latestTiming(): JournalSyncTiming {
  const timing = syncTimings().at(-1)
  assert.ok(timing !== undefined, 'the append must retain a sync timing sample')
  return timing
}

interface JournalHarness {
  readonly journal: ToolJournal
  readonly mock: MockChannel
}

async function withJournal(run: (harness: JournalHarness) => Promise<void>): Promise<void> {
  const mock = new MockChannel({ journalAck: 'manual' })
  ;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  ctx.provide('sessions', {})
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root: mkdtempSync(join(tmpdir(), 'pdsh-jbusy-')),
    profile: 'p',
    classes: {},
    rerun: true,
    rerunTimeoutMs: 1000,
  })
  try {
    const journal = ctx.get('toolJournal') as ToolJournal
    await run({ journal, mock })
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as Record<string, unknown>).__PDSH_CHANNEL__
  }
}

test('a CPU-bound Worker block marks the slow journal sample workerBusy instead of raising an error', async () => {
  const capture = captureJournalSyncErrors()
  try {
    await withJournal(async ({ journal, mock }) => {
      const append = journal.store.append('s', startRecord('c1'))
      await eventually(() => mock.framesOf(FrameType.JOURNAL).length === 1)
      // No await from here to the ack: the Worker event loop cannot service the
      // host's queued 0x31, so the measured wait is Worker starvation.
      const blocked = blockEventLoop(BUSY_MILLISECONDS)
      mock.emitJournalAck(1, 's', 1n)
      await append
      // The pre-fix code wrote this sample to console.error as a slow ack; the
      // artifact must instead see a workerBusy sample.
      assert.deepEqual(capture.messages, [],
        'a Worker-busy sample must never be written to console.error')
      const timing = latestTiming()
      assert.equal(timing.alreadyAcked, false)
      assert.ok(timing.waitMilliseconds >= SLOW_MILLISECONDS,
        `wait ${String(timing.waitMilliseconds)} ms must cover the blocked period`)
      assert.equal(timing.workerBusy, true,
        'a wait mostly spent with a starved event loop is Worker-busy, not host latency')
      assert.ok(timing.eventLoopBlockedMilliseconds >= blocked - 100,
        `event-loop block ${String(timing.eventLoopBlockedMilliseconds)} ms must be near the ${String(blocked)} ms spin`)
      assert.ok(timing.eventLoopBlockedMilliseconds <= blocked + 250,
        `event-loop block ${String(timing.eventLoopBlockedMilliseconds)} ms must not absorb unrelated host latency`)
    })
  } finally {
    capture.restore()
  }
})

test('an ACK delivered as a macrotask after the block is still Worker-busy', async () => {
  const capture = captureJournalSyncErrors()
  try {
    await withJournal(async ({ journal, mock }) => {
      const append = journal.store.append('s', startRecord('c1'))
      await eventually(() => mock.framesOf(FrameType.JOURNAL).length === 1)
      const blocked = blockEventLoop(BUSY_MILLISECONDS)
      // Real inbound frames are macrotasks: after the block, the overdue
      // heartbeat timer runs before the queued 0x31. The blocked span must be
      // the longest heartbeat gap, not the gap since the most recent heartbeat.
      setTimeout(() => { mock.emitJournalAck(1, 's', 1n) }, 0)
      await append
      assert.deepEqual(capture.messages, [],
        'a Worker-busy sample must never be written to console.error')
      const timing = latestTiming()
      assert.equal(timing.workerBusy, true,
        'the pre-ack heartbeat must not hide the starvation')
      assert.ok(timing.waitMilliseconds >= SLOW_MILLISECONDS)
      assert.ok(timing.eventLoopBlockedMilliseconds >= blocked - 100,
        `event-loop block ${String(timing.eventLoopBlockedMilliseconds)} ms must keep the ${String(blocked)} ms spin`)
    })
  } finally {
    capture.restore()
  }
})

test('a numeric setInterval id (JavaScriptCore Web Worker) does not break the heartbeat', async () => {
  const ids = useNumericIntervalIds()
  try {
    const mock = new MockChannel({ journalAck: 'manual' })
    const timings: JournalSyncTiming[] = []
    const sync = new ChannelJournalSync(mock, {
      onSyncTiming: (timing) => { timings.push(timing) },
      ackTimeoutMs: 2_000,
    })
    const append = sync.append('s', 1n, new Uint8Array([1]))
    assert.equal(mock.framesOf(FrameType.JOURNAL).length, 1)
    assert.equal(ids.activeHeartbeats, 1, 'the diagnostic heartbeat must be running')
    setTimeout(() => { mock.emitJournalAck(1, 's', 1n) }, 60)
    // The pre-fix `heartbeat.unref()` threw here on a numeric id and left the
    // interval uncleared; a Web Worker deploy would reject every journal append.
    await append
    assert.equal(timings.length, 1)
    assert.equal(timings[0]?.alreadyAcked, false)
    assert.ok((timings[0]?.waitMilliseconds ?? 0) >= 40)
    assert.equal(ids.activeHeartbeats, 0, 'the heartbeat interval must be cleared')
    sync.close()
  } finally {
    ids.restore()
  }
})

test('a genuinely slow host ack stays workerBusy=false and still raises exactly one error', async () => {
  const capture = captureJournalSyncErrors()
  try {
    await withJournal(async ({ journal, mock }) => {
      const append = journal.store.append('s', startRecord('c1'))
      await eventually(() => mock.framesOf(FrameType.JOURNAL).length === 1)
      // The event loop stays free (heartbeat keeps ticking); only the host is slow.
      await sleep(SLOW_HOST_MILLISECONDS)
      mock.emitJournalAck(1, 's', 1n)
      await append
      const timing = latestTiming()
      assert.equal(timing.workerBusy, false)
      assert.ok(timing.waitMilliseconds >= SLOW_MILLISECONDS)
      assert.ok(timing.eventLoopBlockedMilliseconds < SLOW_MILLISECONDS / 2,
        `an idle event loop must not look blocked (${String(timing.eventLoopBlockedMilliseconds)} ms)`)
      assert.equal(capture.messages.length, 1,
        `a real slow host must still warn once (got ${JSON.stringify(capture.messages)})`)
      assert.match(capture.messages[0] as string, /event_loop_blocked_ms=/)
    })
  } finally {
    capture.restore()
  }
})

test('a short ack and an already-acknowledged append never warn', async () => {
  const capture = captureJournalSyncErrors()
  try {
    await withJournal(async ({ journal, mock }) => {
      const short = journal.store.append('s', startRecord('c1'))
      await eventually(() => mock.framesOf(FrameType.JOURNAL).length === 1)
      await sleep(50)
      mock.emitJournalAck(1, 's', 1n)
      await short
      const shortTiming = latestTiming()
      assert.ok(shortTiming.waitMilliseconds < SLOW_MILLISECONDS)
      assert.equal(shortTiming.workerBusy, false)

      // Pretend the host already covered the next jseq: no wait, no heartbeat,
      // no warning even though the sample is reported.
      mock.emitJournalAck(1, 's', 5n)
      await journal.store.append('s', startRecord('c2'))
      const ackedTiming = latestTiming()
      assert.equal(ackedTiming.alreadyAcked, true)
      assert.equal(ackedTiming.workerBusy, false)
      assert.equal(ackedTiming.eventLoopBlockedMilliseconds, 0)
      assert.deepEqual(capture.messages, [])
    })
  } finally {
    capture.restore()
  }
})
