/** Sender-side pacing queue (contract §3.8, pclink-v1.5). */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  PacingBucket,
  PacingQueue,
  frameByteLength,
  PACING_BURST_BYTES,
  PACING_RATE_BYTES_PER_SEC,
} from '../core/pacing.mjs'
import { FakeTimers } from './helpers.mjs'

function frameOfSize(seq, bytes) {
  const overhead = frameByteLength({ type: 'e2e', seq, ciphertext: '' })
  const frame = { type: 'e2e', seq, ciphertext: 'x'.repeat(bytes - overhead) }
  assert.equal(frameByteLength(frame), bytes)
  return frame
}

function makeQueue(options = {}) {
  const timers = new FakeTimers()
  const sent = []
  const queue = new PacingQueue({
    send: frame => { sent.push(frame); return true },
    timers,
    ratePerSecond: 1_000,
    burst: 2_000,
    ...options,
  })
  return { queue, timers, sent }
}

test('reference pacing values leave margin under the relay pair limit (§3.5)', () => {
  assert.ok(PACING_RATE_BYTES_PER_SEC <= Math.floor(0.9 * 1024 * 1024))
  assert.ok(PACING_BURST_BYTES <= Math.floor(3.5 * 1024 * 1024))
  assert.ok(PACING_RATE_BYTES_PER_SEC < 1024 * 1024)
  assert.ok(PACING_BURST_BYTES < 4 * 1024 * 1024)
})

test('pacing queues in call order and waits for tokens instead of dropping', () => {
  const { queue, timers, sent } = makeQueue()
  const frames = [0, 1, 2].map(index => frameOfSize(index, 1_000))
  for (const frame of frames) assert.equal(queue.enqueue(frame), true)
  // Two 1,000-byte frames fit the 2,000-byte burst; the third waits.
  assert.equal(sent.length, 2)
  assert.equal(queue.queued, 1)
  timers.advance(999)
  assert.equal(sent.length, 2)
  timers.advance(1)
  assert.equal(sent.length, 3)
  assert.deepEqual(sent.map(frame => frame.seq), [0, 1, 2])
})

test('a frame larger than the burst waits for a full bucket then overdraws', () => {
  const { queue, timers, sent } = makeQueue()
  const big = frameOfSize(0, 3_000)
  queue.enqueue(big)
  assert.equal(sent.length, 1, 'a full bucket may overdraw one oversized frame')
  const next = frameOfSize(1, 1_000)
  queue.enqueue(next)
  // The balance is now negative; the following 1,000-byte frame waits for
  // the debt to be paid and its own cost to accrue (2 s at 1 KB/s).
  timers.advance(1_999)
  assert.equal(sent.length, 1)
  timers.advance(1)
  assert.equal(sent.length, 2)
  assert.deepEqual(sent.map(frame => frame.seq), [0, 1])
})

test('a large frame enqueued into a partly drained bucket waits for a full bucket', () => {
  const { queue, timers, sent } = makeQueue({ burst: 2_000, ratePerSecond: 1_000 })
  queue.enqueue(frameOfSize(0, 1_000))
  const big = frameOfSize(1, 3_000)
  queue.enqueue(big)
  assert.equal(sent.length, 1)
  timers.advance(999)
  assert.equal(sent.length, 1)
  timers.advance(1)
  assert.equal(sent.length, 2)
})

test('closing a session drops its queued data but keeps its terminal close', () => {
  const { queue, timers, sent } = makeQueue()
  const session = { closed: false }
  const items = [0, 1, 2].map(seq => frameOfSize(seq, 950))
  for (const frame of items) queue.enqueue(frame, { session })
  assert.equal(sent.length, 2)
  session.closed = true
  queue.dropSession(session)
  assert.equal(queue.queued, 0)
  queue.enqueue(frameOfSize(3, 100), { session, terminal: true })
  timers.advance(1_000)
  assert.deepEqual(sent.map(frame => frame.seq), [0, 1, 3])
})

test('frameByteLength is the exact UTF-8 length of the serialized frame', () => {
  const frame = { v: 1, type: 'e2e', sid: 'ODU-xxharZz-k1yXN2XWRA', seq: 7, ciphertext: '你好' }
  assert.equal(frameByteLength(frame), Buffer.byteLength(JSON.stringify(frame), 'utf8'))
})

test('PacingBucket never refills above the burst and recovers from overdraft', () => {
  const bucket = new PacingBucket({ ratePerSecond: 1_000, burst: 2_000 })
  assert.equal(bucket.delayFor(2_000, 0), 0)
  bucket.consume(2_000, 0)
  assert.equal(bucket.delayFor(3_000, 0), 2_000, 'an oversized frame waits for a full bucket')
  bucket.consume(3_000, 2_000)
  assert.equal(bucket.tokens, -1_000)
  assert.equal(bucket.delayFor(1_000, 4_000), 0, '2 s of refill pays the debt')
  bucket.consume(1_000, 4_000)
  assert.equal(bucket.tokens, 0)
  assert.equal(bucket.delayFor(2_000, 100_000), 0)
  bucket.consume(2_000, 100_000)
  assert.equal(bucket.delayFor(1, 100_000), 1)
})
