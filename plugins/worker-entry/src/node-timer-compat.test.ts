// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { captureNodeTimerPrototypes, installNodeTimerCompat } from './node-timer-compat.ts'

test('Node Timeout objects become numeric ids before the runtime timer wrappers', async () => {
  const checkout = process.env.PDSH_DSH_CHECKOUT
  assert.ok(checkout, 'the timer contract needs the pinned DSH checkout')
  const { installTimerGlobals } = await import(pathToFileURL(
    join(checkout, 'packages/experimental/webworker-runtime/src/node/globals/timers.ts'),
  ).href) as { installTimerGlobals: () => void }
  const original = {
    setTimeout: globalThis.setTimeout,
    setInterval: globalThis.setInterval,
    setImmediate: globalThis.setImmediate,
    clearTimeout: globalThis.clearTimeout,
    clearInterval: globalThis.clearInterval,
    clearImmediate: globalThis.clearImmediate,
  }
  captureNodeTimerPrototypes()
  const baselineTimeouts = process.getActiveResourcesInfo()
    .filter(resource => resource === 'Timeout').length
  const nativeTimeout = original.setTimeout(() => {}, 0)
  const expectedTimeoutPrototype = Object.getPrototypeOf(nativeTimeout)
  clearTimeout(nativeTimeout)
  const nativeInterval = original.setInterval(() => {}, 0)
  const expectedIntervalPrototype = Object.getPrototypeOf(nativeInterval)
  clearInterval(nativeInterval)
  try {
    installTimerGlobals()
    installNodeTimerCompat()
    const timeout = setTimeout(() => {}, 100)
    assert.equal(Object.getPrototypeOf(Object.getPrototypeOf(timeout)), expectedTimeoutPrototype)
    assert.equal(typeof timeout.refresh, 'function')
    assert.ok(Number.isFinite(Number(timeout)))
    assert.equal(timeout.hasRef(), true)
    timeout.unref()
    assert.equal(timeout.hasRef(), false)
    timeout.ref()
    assert.equal(timeout.hasRef(), true)
    timeout.refresh()
    clearTimeout(timeout)
    const interval = setInterval(() => {}, 100)
    assert.equal(Object.getPrototypeOf(Object.getPrototypeOf(interval)), expectedIntervalPrototype)
    assert.equal(typeof interval.refresh, 'function')
    assert.ok(Number.isFinite(Number(interval)))
    clearInterval(interval)
    const immediate = setImmediate(() => {})
    assert.equal(typeof immediate.ref, 'function')
    assert.equal(immediate.hasRef(), true)
    immediate.unref()
    assert.equal(immediate.hasRef(), false)
    clearImmediate(immediate)
  } finally {
    globalThis.setTimeout = original.setTimeout
    globalThis.setInterval = original.setInterval
    globalThis.setImmediate = original.setImmediate
    globalThis.clearTimeout = original.clearTimeout
    globalThis.clearInterval = original.clearInterval
    globalThis.clearImmediate = original.clearImmediate
  }
  await new Promise<void>(resolve => { original.setTimeout(resolve, 20) })
  const remainingTimeouts = process.getActiveResourcesInfo()
    .filter(resource => resource === 'Timeout').length
  assert.ok(remainingTimeouts <= baselineTimeouts, 'timer probing must not leave a live interval')
})
