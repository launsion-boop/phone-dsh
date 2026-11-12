// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createTailCancelQueue } from '../bot-runtime/src/identity-bridge.ts'

test('the tail queue never blocks the caller and collapses duplicate ids', async () => {
  const seen: string[] = []
  let release: () => void = () => {}
  const gate = new Promise<void>(resolve => { release = resolve })
  const queue = createTailCancelQueue(async id => {
    seen.push(id)
    await gate
  }, 5_000, run => queueMicrotask(run))

  queue.enqueue('registration-a')
  queue.enqueue('registration-a')
  queue.enqueue('registration-b')
  queue.enqueue(undefined)
  // The caller returns immediately; the first transport call is dispatched on
  // a microtask, not awaited here.
  assert.equal(seen.length, 0)
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.deepEqual(seen, ['registration-a'])
  release()
  await queue.flush()
  assert.deepEqual(seen, ['registration-a', 'registration-b'])
  assert.equal(queue.pending, 0)
})

test('a failing cancellation is swallowed and does not strand later ids', async () => {
  const seen: string[] = []
  const queue = createTailCancelQueue(async id => {
    seen.push(id)
    if (id === 'bad') throw new Error('host unavailable')
  }, 5_000, run => queueMicrotask(run))
  queue.enqueue('bad')
  queue.enqueue('good')
  await queue.flush()
  assert.deepEqual(seen, ['bad', 'good'])
})
