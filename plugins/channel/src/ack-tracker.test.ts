// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { AckTracker, AsyncQueue, VFS_ACK_KEY } from './ack-tracker.ts'

test('level-1 acks are cumulative and level-2 acks also cover level 1', async () => {
  const tracker = new AckTracker()
  assert.equal(tracker.acked(VFS_ACK_KEY, 1), 0n)
  assert.equal(tracker.acked(VFS_ACK_KEY, 2), 0n)
  tracker.resolve(VFS_ACK_KEY, 1, 42n)
  assert.equal(tracker.acked(VFS_ACK_KEY, 1), 42n)
  assert.equal(tracker.acked(VFS_ACK_KEY, 2), 0n)
  tracker.resolve(VFS_ACK_KEY, 2, 47n)
  assert.equal(tracker.acked(VFS_ACK_KEY, 1), 47n)
  assert.equal(tracker.acked(VFS_ACK_KEY, 2), 47n)
})

test('wait resolves only when its own level reaches the value', async () => {
  const tracker = new AckTracker()
  let level1 = false
  let level2 = false
  const one = tracker.wait(VFS_ACK_KEY, 1, 5n).then(() => { level1 = true })
  const two = tracker.wait(VFS_ACK_KEY, 2, 5n).then(() => { level2 = true })
  tracker.resolve(VFS_ACK_KEY, 1, 5n)
  await one
  assert.equal(level1, true)
  assert.equal(level2, false)
  tracker.resolve(VFS_ACK_KEY, 2, 5n)
  await two
  assert.equal(level2, true)
  assert.equal(tracker.pending, 0)
})

test('journal sessions are independent sequences', () => {
  const tracker = new AckTracker()
  tracker.resolve('session.a', 1, 9n)
  tracker.resolve('session.b', 1, 2n)
  tracker.resolve('session.a', 2, 9n)
  assert.equal(tracker.acked('session.a', 1), 9n)
  assert.equal(tracker.acked('session.a', 2), 9n)
  assert.equal(tracker.acked('session.b', 1), 2n)
  assert.equal(tracker.acked('session.b', 2), 0n)
})

test('abort rejects one waiter without disturbing the others', async () => {
  const tracker = new AckTracker()
  const controller = new AbortController()
  const aborted = tracker.wait(VFS_ACK_KEY, 1, 3n, controller.signal)
  const kept = tracker.wait(VFS_ACK_KEY, 1, 4n)
  controller.abort(new Error('cancelled'))
  await assert.rejects(aborted, /cancelled/)
  tracker.resolve(VFS_ACK_KEY, 1, 4n)
  await kept
  assert.equal(tracker.pending, 0)
})

test('rejectAll fails every outstanding waiter', async () => {
  const tracker = new AckTracker()
  const waiting = tracker.wait('s', 1, 1n)
  tracker.rejectAll(new Error('closed'))
  await assert.rejects(waiting, /closed/)
})

test('AsyncQueue preserves order across a producer and consumer', async () => {
  const queue = new AsyncQueue<number>()
  queue.push(1)
  queue.push(2)
  assert.deepEqual(await queue.next(), { value: 1, done: false })
  queue.end()
  assert.deepEqual(await queue.next(), { value: 2, done: false })
  assert.deepEqual(await queue.next(), { value: undefined, done: true })
})
