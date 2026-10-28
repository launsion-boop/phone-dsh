// SPDX-License-Identifier: MIT
// Test transport for the recovery write-open regression.
//
// The surface bundle in this repository normally runs inside the Worker entry,
// where the real ordered WebSocket client installs `__PDSH_CHANNEL__`. The
// Node recovery test boots the same bundle directly, so this preload supplies
// a host-like ordered-channel receiver (including contiguous jseq checks) and
// one targeted `node:fs/promises.appendFile` return delay for the cancellation
// boundary. JOURNAL frames are decoded and ACKed after
// `PDSH_TEST_JOURNAL_ACK_DELAY_MS`. Everything else (pinned DSH AgentLoop,
// session persistence, the phone profile wrapper and tool-journal plugin) is
// the real production stack.
//
// Loaded with `NODE_OPTIONS=--import=<this file>` by
// `tests/recovery-write-open.test.ts`; never used by a deployment.
import { appendFileSync } from 'node:fs'
import { createRequire, syncBuiltinESMExports } from 'node:module'

import { FrameType } from '@phone-dsh/dsh-channel/frames'
import { decodeJournal } from '@phone-dsh/dsh-channel/vfs-mutation'

const tracePath = process.env.PDSH_TEST_JOURNAL_TRACE
const ackDelay = Number(process.env.PDSH_TEST_JOURNAL_ACK_DELAY_MS ?? '0')
// Optional per-session slow first ack: the recovery deadline test needs its
// first `resolved` frame to stay unacknowledged until after the retry open has
// re-emitted it, while later frames use the normal delay.
const slowSessions = new Set((process.env.PDSH_TEST_JOURNAL_SLOW_SESSIONS
  ?? process.env.PDSH_TEST_JOURNAL_SLOW_SESSION ?? '').split(',').filter(Boolean))
const slowFirstAckDelay = Number(process.env.PDSH_TEST_JOURNAL_SLOW_ACK_DELAY_MS ?? '0')
// A rerun retry appends both `done` and `resolved`; with the global delayed
// ack those two waits would exceed the route's hard 1500 ms budget. Sessions in
// this list acknowledge immediately, so the retry can prove the writer/content
// behaviour rather than the test fixture's own ack cadence.
const fastSessions = new Set((process.env.PDSH_TEST_JOURNAL_FAST_SESSIONS ?? '')
  .split(',').filter(Boolean))
const highs = new Map()
const receivedHighs = new Map()
const sentCounts = new Map()
const waiters = new Set()
const preSendCancelSession = process.env.PDSH_TEST_JOURNAL_PRE_SEND_CANCEL_SESSION ?? ''
const preSendAppendDelayMs = Number(process.env.PDSH_TEST_JOURNAL_PRE_SEND_APPEND_DELAY_MS ?? '0')
const preSendAppendSeen = new Set()
const seededSessions = (process.env.PDSH_TEST_JOURNAL_SEEDED_SESSIONS ?? '')
  .split(',').filter(Boolean)
// Optional per-session high-water mark. The default 2 is the `start` + `done`
// pair the backfill fixtures seed; a no-result rerun fixture has only `start`
// and therefore seeds jseq 1.
const seededHighs = new Map((process.env.PDSH_TEST_JOURNAL_SEED_HIGHS ?? '')
  .split(',').filter(Boolean)
  .map(entry => {
    const [sessionId, high] = entry.split(':')
    return [sessionId, BigInt(high ?? '2')]
  }))
for (const sessionId of seededSessions) {
  // The fixture's real DSH sessions are prepared before the surface process
  // starts. Their last journal record represents the host's previously
  // received high-water mark.
  const high = seededHighs.get(sessionId) ?? 2n
  highs.set(sessionId, high)
  receivedHighs.set(sessionId, high)
  trace({ event: 'seeded', sessionId, jseq: Number(high), at: Date.now() })
}

function trace(entry) {
  if (tracePath === undefined || tracePath === '') return
  appendFileSync(tracePath, `${JSON.stringify(entry)}\n`)
}

// Test-only interception at the filesystem boundary. The original append is
// allowed to finish first; only its promise return is delayed for the selected
// resolved record. With a shorter route budget this makes the real AbortSignal
// fire after the NDJSON bytes exist but before ToolJournalStore calls its
// channel mirror, without adding a production hook/API.
const require = createRequire(import.meta.url)
const fsPromises = require('node:fs/promises')
const originalAppendFile = fsPromises.appendFile
fsPromises.appendFile = async function (path, data, ...options) {
  const result = await originalAppendFile.call(this, path, data, ...options)
  if (preSendAppendDelayMs <= 0
      || !String(path).endsWith(`${preSendCancelSession}.journal.ndjson`)
      || preSendAppendSeen.has(preSendCancelSession)) return result
  const text = typeof data === 'string' ? data : Buffer.from(data).toString('utf8')
  const appended = text.split('\n').map(line => {
    try { return JSON.parse(line) } catch { return undefined }
  }).find(record => record?.t === 'resolved')
  if (appended === undefined) return result
  preSendAppendSeen.add(preSendCancelSession)
  trace({ event: 'local-append-complete', sessionId: preSendCancelSession,
    jseq: 3, record: appended, at: Date.now() })
  await new Promise(resolve => setTimeout(resolve, preSendAppendDelayMs))
  trace({ event: 'append-promise-returned', sessionId: preSendCancelSession,
    jseq: 3, at: Date.now() })
  return result
}
syncBuiltinESMExports()

function high(sessionId) {
  return highs.get(sessionId) ?? 0n
}

function settle(sessionId) {
  for (const waiter of [...waiters]) {
    if (waiter.sessionId !== sessionId || high(sessionId) < waiter.upto) continue
    waiters.delete(waiter)
    waiter.cleanup()
    waiter.resolve()
  }
}

function acknowledge(sessionId, jseq) {
  if (jseq > high(sessionId)) highs.set(sessionId, jseq)
  trace({ event: 'acked', sessionId, jseq: Number(jseq), at: Date.now() })
  settle(sessionId)
}

const channel = {
  async connect() {},
  send(type, payload) {
    if (type !== FrameType.JOURNAL) return 0n
    const frame = decodeJournal(payload)
    let record
    try {
      record = JSON.parse(new TextDecoder().decode(frame.record))
    } catch {
      record = undefined
    }
    trace({ event: 'sent', sessionId: frame.sessionId, jseq: Number(frame.jseq), record, at: Date.now() })
    const highestReceived = receivedHighs.get(frame.sessionId) ?? 0n
    if (frame.jseq <= highestReceived) {
      trace({ event: 'duplicate', sessionId: frame.sessionId,
        jseq: Number(frame.jseq), upto: Number(highestReceived), at: Date.now() })
      acknowledge(frame.sessionId, highestReceived)
      return 0n
    }
    if (frame.jseq !== highestReceived + 1n) {
      trace({ event: 'gap', sessionId: frame.sessionId,
        expected: Number(highestReceived + 1n), got: Number(frame.jseq), at: Date.now() })
      return 0n
    }
    receivedHighs.set(frame.sessionId, frame.jseq)
    trace({ event: 'received', sessionId: frame.sessionId,
      jseq: Number(frame.jseq), record, at: Date.now() })
    const sent = (sentCounts.get(frame.sessionId) ?? 0) + 1
    sentCounts.set(frame.sessionId, sent)
    const delay = fastSessions.has(frame.sessionId)
      ? 0
      : slowSessions.has(frame.sessionId) && sent === 1 && slowFirstAckDelay > 0
        ? slowFirstAckDelay
        : ackDelay
    if (delay > 0) {
      const timer = setTimeout(() => { acknowledge(frame.sessionId, frame.jseq) }, delay)
      timer.unref?.()
    } else {
      acknowledge(frame.sessionId, frame.jseq)
    }
    return 0n
  },
  onFrame() { return () => {} },
  onHostHello() { return () => {} },
  hostHello: undefined,
  ackedMseq() { return 0n },
  waitAck() { return Promise.reject(new Error('recovery test channel: no VFS ack')) },
  barrier() { return Promise.reject(new Error('recovery test channel: no barrier')) },
  nextMseq() { return 1n },
  journalAcked(sessionId, level) {
    return level === 1 ? high(sessionId) : 0n
  },
  waitJournalAck(level, sessionId, upto, signal) {
    if (level !== 1) return Promise.reject(new Error('recovery test channel: only level 1'))
    if (high(sessionId) >= upto) return Promise.resolve()
    if (signal?.aborted) return Promise.reject(signal.reason)
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        if (!waiters.delete(waiter)) return
        waiter.cleanup()
        reject(signal?.reason)
      }
      const waiter = {
        sessionId,
        upto,
        resolve,
        cleanup: () => { signal?.removeEventListener('abort', onAbort) },
      }
      waiters.add(waiter)
      signal?.addEventListener('abort', onAbort, { once: true })
    })
  },
  request() { throw new Error('recovery test channel: no API requests') },
  async close() {
    for (const waiter of [...waiters]) {
      waiters.delete(waiter)
      waiter.cleanup()
      waiter.resolve()
    }
  },
}

globalThis.__PDSH_CHANNEL__ = channel
