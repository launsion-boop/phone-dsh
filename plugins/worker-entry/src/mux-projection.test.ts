// SPDX-License-Identifier: MIT
//
// The phone mux projection exists because one float aborts a whole turn:
//
//   worker: API_ABORT reason=canonical JSON accepts integers only
//   App:    APP_TURN_FAILED reason=api_aborted
//
// The first retry of a failed model request waits
// `initialDelayMs * 2**n * (1 - jitterRatio + 2 * jitterRatio * random())`
// milliseconds, which is fractional by construction (`481.7056…`), and a
// provider `retry-after: 1.005` becomes `Number("1.005") * 1000 ===
// 1004.9999999999999`. That same failure is recorded three times — on the retry
// event, inside the failed attempt's embedded stream, and on a failed turn's
// reason — so all three carriers are pinned here.
//
// These tests pin both halves of the fix: the projection rounds the *timing*
// fields a retry carries, and canonical JSON itself still refuses floats.

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { canonicalStringify, CanonicalJsonError } from '../../channel/src/canonical-json.ts'
import { encodeMuxFrameLine, type WorkerEntryMuxServerFrame } from './mux-bridge.ts'
import { projectMuxServerFrame, type MuxProjectionRounding } from './mux-projection.ts'

/** `1.005 * 1000`: a fractional provider retry-after in milliseconds. */
const FRACTIONAL_RETRY_AFTER = 1004.9999999999999

/** `.data.failure` of the retry event, as DSH records the failed attempt. */
function failure(providerRetryAfterMs?: number): Record<string, unknown> {
  return {
    message: 'DeepSeek Messages request failed (429)',
    code: 'RATE_LIMIT',
    status: 429,
    ...providerRetryAfterMs === undefined ? {} : { providerRetryAfterMs },
  }
}

/** One durable `llm/retry` event exactly as DSH appends it (0.2.1 data shape). */
function retryEvent(delayMs: number, providerRetryAfterMs?: number): Record<string, unknown> {
  return {
    type: 'llm/retry',
    seq: 17,
    time: 1761933600000,
    data: {
      retryId: 'retry-1',
      turn: 1,
      step: 1,
      provider: 'deepseek-official',
      mode: 'normal',
      policyKey: '["normal",5,["EMPTY_RESPONSE","RATE_LIMIT","SERVER","TIMEOUT","TRANSPORT"],500,10000,0.1]',
      retry: 1,
      maxRetries: 5,
      delayMs,
      failure: failure(providerRetryAfterMs),
    },
  }
}

/**
 * One durable `assistant/attempt` event: the failed attempt's exact stream,
 * whose finish chunk carries the same failure. Copy from a real device session.
 */
function attemptEvent(providerRetryAfterMs: number): Record<string, unknown> {
  return {
    type: 'assistant/attempt',
    seq: 16,
    time: 1761933600000,
    data: {
      turn: 1,
      step: 1,
      stream: [{
        type: 'chunk',
        time: 1761933600000,
        chunk: {
          type: 'finish',
          reason: { kind: 'error', failure: failure(providerRetryAfterMs) },
        },
      }],
    },
  }
}

/** One `session/follow` item frame: the wire shape the phone receives. */
function followFrame(event: Record<string, unknown>): WorkerEntryMuxServerFrame {
  return { type: 'item', streamId: 'follow', value: { type: 'event', event } }
}

function dataOf(frame: WorkerEntryMuxServerFrame): Record<string, unknown> {
  const value = frame.type === 'item' ? frame.value as { event: { data: Record<string, unknown> } } : undefined
  assert.ok(value !== undefined, 'fixture is an item frame')
  return value.event.data
}

test('the mux projection rounds a jittered llm/retry delay to whole milliseconds', () => {
  const frame = followFrame(retryEvent(481.7056))
  assert.equal(dataOf(frame)['delayMs'], 481.7056, 'the fixture starts fractional')

  const rounds: MuxProjectionRounding[] = []
  const projected = projectMuxServerFrame(frame, rounding => { rounds.push(rounding) })

  const delayMs = dataOf(projected)['delayMs']
  assert.equal(delayMs, 482, 'the retry wait is rounded to the nearest millisecond')
  assert.ok(Number.isInteger(delayMs), 'the projected value is an integer')
  // Visibility: the round is reported with both values, not applied silently.
  assert.deepEqual(rounds, [{ eventType: 'llm/retry', field: 'data.delayMs', from: 481.7056, to: 482 }])
})

test('a projected retry event passes canonical JSON', () => {
  const projected = projectMuxServerFrame(followFrame(retryEvent(481.7056)))
  const text = canonicalStringify(projected)
  assert.match(text, /"delayMs":482/u, 'the wire carries the integer')
  assert.doesNotMatch(text, /481\.7056/u, 'the float never reaches the wire')
  assert.equal((JSON.parse(text) as { value: { event: { data: { delayMs: number } } } })
    .value.event.data.delayMs, 482)
})

test('canonical JSON still refuses floats (the projection is the only relaxation)', () => {
  // Independent assertion, deliberately not routed through the projection.
  assert.throws(() => canonicalStringify({ delayMs: 481.7056 }), (error: unknown) => {
    assert.ok(error instanceof CanonicalJsonError)
    assert.equal(error.message, 'canonical JSON accepts integers only')
    return true
  })
  assert.throws(() => canonicalStringify(retryEvent(481.7056)), /canonical JSON accepts integers only/u)
  assert.throws(() => canonicalStringify(attemptEvent(FRACTIONAL_RETRY_AFTER)), /canonical JSON accepts integers only/u)
})

test('the retry event rounds both its own wait and the provider wait on its failure', () => {
  const frame = followFrame(retryEvent(FRACTIONAL_RETRY_AFTER, FRACTIONAL_RETRY_AFTER))
  const rounds: MuxProjectionRounding[] = []
  const projected = projectMuxServerFrame(frame, rounding => { rounds.push(rounding) })
  const data = dataOf(projected)
  assert.equal(data['delayMs'], 1005)
  assert.equal((data['failure'] as Record<string, unknown>)['providerRetryAfterMs'], 1005)
  assert.deepEqual(rounds, [
    { eventType: 'llm/retry', field: 'data.delayMs', from: FRACTIONAL_RETRY_AFTER, to: 1005 },
    {
      eventType: 'llm/retry',
      field: 'data.failure.providerRetryAfterMs',
      from: FRACTIONAL_RETRY_AFTER,
      to: 1005,
    },
  ])
  assert.doesNotThrow(() => canonicalStringify(projected))
})

test('the failed attempt stream rounds its embedded provider wait (the device regression)', () => {
  // Without this the receive still aborts with
  // 'canonical JSON accepts integers only' the moment a 429 carries a
  // fractional retry-after, even though llm/retry.delayMs was already rounded.
  const frame = followFrame(attemptEvent(FRACTIONAL_RETRY_AFTER))
  const rounds: MuxProjectionRounding[] = []
  const projected = projectMuxServerFrame(frame, rounding => { rounds.push(rounding) })
  const stream = dataOf(projected)['stream'] as { chunk: { reason: { failure: Record<string, unknown> } } }[]
  assert.equal(stream[0]?.chunk.reason.failure['providerRetryAfterMs'], 1005)
  assert.deepEqual(rounds, [{
    eventType: 'assistant/attempt',
    field: 'data.stream[0].chunk.reason.failure.providerRetryAfterMs',
    from: FRACTIONAL_RETRY_AFTER,
    to: 1005,
  }])
  assert.doesNotThrow(() => canonicalStringify(projected))
})

test('a failed turn reason rounds its embedded provider wait', () => {
  const frame: WorkerEntryMuxServerFrame = {
    type: 'item',
    streamId: 'follow',
    value: {
      type: 'event',
      event: {
        type: 'turn/end',
        seq: 20,
        time: 1761933600000,
        data: { turn: 1, reason: { kind: 'error', error: failure(FRACTIONAL_RETRY_AFTER) } },
      },
    },
  }
  const rounds: MuxProjectionRounding[] = []
  const projected = projectMuxServerFrame(frame, rounding => { rounds.push(rounding) })
  const reason = (projected.type === 'item' ? projected.value as { event: { data: { reason: { error: Record<string, unknown> } } } } : undefined)
  assert.equal(reason?.event.data.reason.error['providerRetryAfterMs'], 1005)
  assert.deepEqual(rounds.map(round => round.field), ['data.reason.error.providerRetryAfterMs'])
  assert.doesNotThrow(() => canonicalStringify(projected))
})

test('an integral wait is left alone and reported as no change', () => {
  const frame = followFrame(retryEvent(2000, 2000))
  const rounds: MuxProjectionRounding[] = []
  const projected = projectMuxServerFrame(frame, rounding => { rounds.push(rounding) })
  assert.equal(projected, frame, 'an all-integer frame keeps its identity (no copy)')
  assert.deepEqual(rounds, [], 'nothing was rewritten, so nothing is logged')
})

test('a sub-millisecond wait rounds to 0 and stays encodable', () => {
  const projected = projectMuxServerFrame(followFrame(retryEvent(0.4, 0.4)))
  const data = dataOf(projected)
  assert.equal(data['delayMs'], 0)
  assert.equal((data['failure'] as Record<string, unknown>)['providerRetryAfterMs'], 0)
  assert.doesNotThrow(() => canonicalStringify(projected))
})

test('the projection does not touch semantically precise numbers', () => {
  // Everything canonical JSON also carries today must survive untouched:
  // token usage, epoch timestamps, wall-time totals and the numbers inside a
  // tool result's own meta.
  const frame: WorkerEntryMuxServerFrame = {
    type: 'item',
    streamId: 'follow',
    value: {
      type: 'snapshot',
      records: [
        {
          type: 'event',
          event: {
            type: 'assistant/message',
            seq: 3,
            time: 1761933600000,
            data: {
              turn: 1,
              step: 1,
              usage: { inputTokens: 64, outputTokens: 12, totalTokens: 76 },
              message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] },
              stream: [{ type: 'text-chunks', time0: 1761933600000, index: 0, dt: [1, 2, 3], texts: ['o', 'k'] }],
            },
          },
        },
        {
          type: 'event',
          event: {
            type: 'tool/result',
            seq: 4,
            time: 1761933600001,
            data: { turn: 1, step: 1, message: { role: 'user', content: [] }, meta: { bytes: 12, ratio: 0.5 } },
          },
        },
      ],
      projections: { asOfSeq: 4, values: { sessionStats: { llmMs: 812, turns: 1 } } },
    },
  }
  const rounds: MuxProjectionRounding[] = []
  assert.equal(projectMuxServerFrame(frame, rounding => { rounds.push(rounding) }), frame)
  assert.deepEqual(rounds, [])
})

test('a float outside the timing scope still fails loudly', () => {
  // `request/header` carries `temperature` when a caller sets it. Rounding it
  // would change what the model was asked to do, so the projection leaves it
  // and canonical JSON refuses the frame — a visible contract failure, not a
  // silent rewrite.
  const frame: WorkerEntryMuxServerFrame = {
    type: 'item',
    streamId: 'follow',
    value: {
      type: 'event',
      event: {
        type: 'request/header',
        seq: 9,
        time: 1761933600000,
        data: {
          reason: 'initial',
          header: { config: { provider: 'deepseek-official', model: 'deepseek-flash', temperature: 0.7 } },
        },
      },
    },
  }
  assert.equal(projectMuxServerFrame(frame), frame)
  assert.throws(() => canonicalStringify(frame), /canonical JSON accepts integers only/u)
})

test('encodeMuxFrameLine carries a jittered retry event as canonical JSON', () => {
  const rounds: MuxProjectionRounding[] = []
  const line = new TextDecoder().decode(
    encodeMuxFrameLine(followFrame(retryEvent(481.7056)), rounding => { rounds.push(rounding) }),
  )
  assert.equal(line.endsWith('\n'), true)
  const parsed = JSON.parse(line) as { value: { event: { data: { delayMs: number } } } }
  assert.equal(parsed.value.event.data.delayMs, 482)
  assert.deepEqual(rounds, [{ eventType: 'llm/retry', field: 'data.delayMs', from: 481.7056, to: 482 }])
})

test('encodeMuxFrameLine carries a failed attempt stream as canonical JSON', () => {
  const line = encodeMuxFrameLine(followFrame(attemptEvent(FRACTIONAL_RETRY_AFTER)))
  const text = new TextDecoder().decode(line)
  assert.match(text, /"providerRetryAfterMs":1005/u)
  assert.doesNotMatch(text, /1004\.999/u)
})
