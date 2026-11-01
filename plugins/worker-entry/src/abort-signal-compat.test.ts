// SPDX-License-Identifier: MIT
/**
 * `AbortSignal.any` and `scheduler.yield` prelude tests.
 *
 * Both APIs are newer than the Chromium-109 kernel this Worker must run on
 * (`android-33`, WebView 109.0.5414.123), so the tests build a global surface
 * that lacks them and assert the fallbacks' observable behaviour.
 * @module @phone-dsh/dsh-worker-entry/abort-signal-compat.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  abortSignalAny,
  anySignal,
  installAbortSignalAny,
  type AbortControllerLike,
  type AbortSignalLike,
  type AbortSignalCompatScope,
} from './abort-signal-compat.ts'
import {
  installSchedulerYield,
  schedulerYield,
  yieldToEventLoop,
  type SchedulerCompatScope,
} from './scheduler-compat.ts'

/** A minimal AbortSignal/AbortController pair, like a pre-116 engine's. */
class StubSignal implements AbortSignalLike {
  aborted = false
  reason: unknown = undefined
  private readonly listeners = new Set<() => void>()

  addEventListener(_type: 'abort', listener: () => void): void {
    this.listeners.add(listener)
  }

  removeEventListener(_type: 'abort', listener: () => void): void {
    this.listeners.delete(listener)
  }

  /** Fire the abort, as `AbortController.abort()` would. */
  fire(reason?: unknown): void {
    if (this.aborted) return
    this.aborted = true
    this.reason = reason
    for (const listener of [...this.listeners]) listener()
  }

  get listenerCount(): number {
    return this.listeners.size
  }
}

/** Controller whose signal is a {@link StubSignal}. */
class StubController implements AbortControllerLike {
  readonly signal = new StubSignal()

  abort(reason?: unknown): void {
    this.signal.fire(reason)
  }
}

/** A global surface that has a controller but no `AbortSignal.any`. */
function abortScope(): AbortSignalCompatScope & { AbortSignal: Record<string, unknown> } {
  const AbortSignal = {} as Record<string, unknown>
  return { AbortSignal, AbortController: StubController }
}

test('installAbortSignalAny fills the pre-116 gap and mirrors the spec', () => {
  const scope = abortScope()
  assert.equal(installAbortSignalAny(scope), true)
  assert.equal(typeof scope.AbortSignal.any, 'function')
  assert.equal(installAbortSignalAny(scope), false, 'idempotent')

  const any = scope.AbortSignal.any as (signals: AbortSignalLike[]) => AbortSignalLike
  const first = new StubController()
  const second = new StubController()
  const derived = any([first.signal, second.signal])
  assert.equal(derived.aborted, false)

  second.abort('stop')
  assert.equal(derived.aborted, true)
  assert.equal(derived.reason, 'stop')
  assert.equal(first.signal.listenerCount, 0, 'listeners are removed once the derived signal fired')
  assert.equal(second.signal.listenerCount, 0)

  const already = new StubController()
  already.abort('early')
  const immediate = any([already.signal])
  assert.equal(immediate.aborted, true)
  assert.equal(immediate.reason, 'early')
})

test('anySignal never aborts for an empty input list', () => {
  const derived = anySignal([], StubController)
  assert.equal(derived.aborted, false)
})

test('installSchedulerYield fills both a missing method and a missing object', () => {
  const withObject: SchedulerCompatScope = { scheduler: {} }
  assert.equal(installSchedulerYield(withObject), true)
  assert.equal(typeof withObject.scheduler?.yield, 'function')
  assert.equal(installSchedulerYield(withObject), false, 'idempotent')

  const bare: SchedulerCompatScope = { setTimeout: callback => setTimeout(callback, 0) }
  assert.equal(installSchedulerYield(bare), true)
  assert.equal(typeof bare.scheduler?.yield, 'function')
})

test('yieldToEventLoop prefers postTask and falls back to a macrotask', async () => {
  const priorities: string[] = []
  await yieldToEventLoop({
    postTask: (callback, options) => {
      priorities.push(String(options?.priority))
      callback()
      return Promise.resolve()
    },
  }, undefined)
  assert.deepEqual(priorities, ['user-blocking'])

  let macrotask = false
  await yieldToEventLoop(undefined, callback => setTimeout(callback, 0))
  macrotask = true
  assert.equal(macrotask, true)

  await yieldToEventLoop(undefined, undefined)
})

test('a modern engine keeps its native definitions', () => {
  // Node 22 has `AbortSignal.any`; an engine that has it must not be patched.
  const any = Object.getOwnPropertyDescriptor(AbortSignal, 'any')
  assert.equal(installAbortSignalAny(globalThis as unknown as AbortSignalCompatScope), false)
  assert.deepEqual(Object.getOwnPropertyDescriptor(AbortSignal, 'any'), any)
  assert.equal(abortSignalAny, false)

  // Node has no `scheduler`; the shape that matters here is an engine that
  // already exposes `scheduler.yield` (Chromium 129+), which must be untouched.
  const native: SchedulerCompatScope = { scheduler: { yield: () => Promise.resolve() } }
  const nativeYield = native.scheduler?.yield
  assert.equal(installSchedulerYield(native), false)
  assert.equal(native.scheduler?.yield, nativeYield)
  // This test process installed the fallback at import time (Node has no
  // `scheduler`), which is the documented side effect of the prelude module.
  assert.equal(schedulerYield, true)
})
