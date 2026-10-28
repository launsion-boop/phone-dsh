// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'
import { Gate, LifecycleRefusedError, parseSignal } from '../lifecycle-gate/src/gate.ts'

test('run admits immediately', async () => {
  const gate = new Gate()
  await gate.admit()
})

test('pause parks callers until run, then releases them all', async () => {
  const gate = new Gate()
  gate.set({ state: 'pause', reason: 'background_budget_exhausted' })
  let released = 0
  const a = gate.admit().then(() => { released++ })
  const b = gate.admit().then(() => { released++ })
  await sleep(20)
  assert.equal(released, 0)
  assert.equal(gate.parked, 2)
  gate.set({ state: 'run' })
  await Promise.all([a, b])
  assert.equal(released, 2)
})

test('stop refuses with a structured error, also for parked callers', async () => {
  const gate = new Gate()
  gate.set({ state: 'pause' })
  const parked = gate.admit()
  gate.set({ state: 'stop', reason: 'host terminating' })
  await assert.rejects(parked, (error: unknown) => error instanceof LifecycleRefusedError && error.code === 'PDSH_LIFECYCLE_REFUSED')
  await assert.rejects(gate.admit(), LifecycleRefusedError)
})

test('an aborted wait rejects with the abort reason and leaves the gate clean', async () => {
  const gate = new Gate()
  gate.set({ state: 'pause' })
  const controller = new AbortController()
  const waiting = gate.admit(controller.signal)
  controller.abort(new Error('turn cancelled'))
  await assert.rejects(waiting, /turn cancelled/)
  assert.equal(gate.parked, 0)
})

test('control-file bodies parse as plain words or JSON', () => {
  assert.deepEqual(parseSignal('pause\n'), { state: 'pause' })
  assert.deepEqual(parseSignal('{"state":"stop","reason":"x","budget_ms":5}'), { state: 'stop', reason: 'x', budgetMs: 5 })
  assert.equal(parseSignal('paws'), undefined)
})
