// SPDX-License-Identifier: MIT
/**
 * ES2023 prelude tests.
 *
 * The helpers run in the Worker on engines that predate them — Chromium 109
 * (the `android-33` image) has none of the six — so the tests exercise them on a
 * bare `Array`/`String` prototype, not on Node's native ones. The last test
 * proves the prelude leaves a modern engine untouched.
 * @module @phone-dsh/dsh-worker-entry/es2023-compat.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { es2023Compat, installEs2023Compat, type Es2023CompatScope } from './es2023-compat.ts'

/** A global surface whose Array/String prototypes are empty, like Chromium 109. */
function bareScope(): Es2023CompatScope {
  class BareArray {}
  class BareString {}
  return {
    Array: BareArray as unknown as { prototype: Record<PropertyKey, unknown> },
    String: BareString as unknown as { prototype: Record<PropertyKey, unknown> },
  }
}

/** Call an installed helper with an array-like receiver. */
function call<T>(target: Record<PropertyKey, unknown>, name: string, receiver: unknown, ...args: unknown[]): T {
  const method = target[name]
  assert.equal(typeof method, 'function', `${name} must be installed`)
  return (method as (...inner: unknown[]) => T).apply(receiver, args)
}

test('installEs2023Compat fills the Chromium-109 gaps', () => {
  const scope = bareScope()
  const array = scope.Array!.prototype
  const string = scope.String!.prototype

  assert.deepEqual(installEs2023Compat(scope), {
    arrayToReversed: true,
    arrayToSorted: true,
    arrayToSpliced: true,
    arrayWith: true,
    stringIsWellFormed: true,
    stringToWellFormed: true,
  })

  assert.deepEqual(call<unknown[]>(array, 'toReversed', [1, 2, 3]), [3, 2, 1])
  assert.deepEqual(call<unknown[]>(array, 'toSorted', [3, 1, 2]), [1, 2, 3])
  assert.deepEqual(call<unknown[]>(array, 'toSorted', [3, 1, 2], (a: unknown, b: unknown) => Number(b) - Number(a)), [3, 2, 1])
  assert.deepEqual(call<unknown[]>(array, 'toSpliced', [1, 2, 3, 4], 1, 2, 'x'), [1, 'x', 4])
  assert.deepEqual(call<unknown[]>(array, 'toSpliced', [1, 2, 3], -2), [1])
  assert.deepEqual(call<unknown[]>(array, 'with', [1, 2, 3], -1, 9), [1, 2, 9])
  assert.throws(() => call<unknown[]>(array, 'with', [1, 2, 3], 3, 9), RangeError)

  // The helpers copy: the receiver is untouched.
  const source = [1, 2, 3]
  call<unknown[]>(array, 'toReversed', source)
  assert.deepEqual(source, [1, 2, 3])

  assert.equal(call<boolean>(string, 'isWellFormed', 'ok \u{1F600}'), true)
  assert.equal(call<boolean>(string, 'isWellFormed', 'lone \uD800'), false)
  assert.equal(call<string>(string, 'toWellFormed', 'lone \uD800 pair \u{1F600}'), 'lone \uFFFD pair \u{1F600}')
})

test('installEs2023Compat is idempotent', () => {
  const scope = bareScope()
  assert.equal(installEs2023Compat(scope).arrayToReversed, true)
  const installed = scope.Array!.prototype.toReversed
  assert.deepEqual(installEs2023Compat(scope), {
    arrayToReversed: false,
    arrayToSorted: false,
    arrayToSpliced: false,
    arrayWith: false,
    stringIsWellFormed: false,
    stringToWellFormed: false,
  })
  assert.equal(scope.Array!.prototype.toReversed, installed)
})

test('installEs2023Compat leaves a modern engine untouched', () => {
  const names = ['toReversed', 'toSorted', 'toSpliced', 'with'] as const
  const strings = ['isWellFormed', 'toWellFormed'] as const
  const before = names.map(name => Object.getOwnPropertyDescriptor(Array.prototype, name))
  const stringBefore = strings.map(name => Object.getOwnPropertyDescriptor(String.prototype, name))

  assert.deepEqual(installEs2023Compat(globalThis as unknown as Es2023CompatScope), {
    arrayToReversed: false,
    arrayToSorted: false,
    arrayToSpliced: false,
    arrayWith: false,
    stringIsWellFormed: false,
    stringToWellFormed: false,
  })
  assert.deepEqual(names.map(name => Object.getOwnPropertyDescriptor(Array.prototype, name)), before)
  assert.deepEqual(strings.map(name => Object.getOwnPropertyDescriptor(String.prototype, name)), stringBefore)
  assert.deepEqual(es2023Compat, {
    arrayToReversed: false,
    arrayToSorted: false,
    arrayToSpliced: false,
    arrayWith: false,
    stringIsWellFormed: false,
    stringToWellFormed: false,
  })
})
