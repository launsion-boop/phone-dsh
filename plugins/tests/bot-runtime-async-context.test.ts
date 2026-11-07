// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'

const checkout = process.env.PDSH_DSH_CHECKOUT

test('the pinned Worker AsyncLocalStorage preserves interleaved hooked async chains', {
  skip: checkout === undefined || checkout === ''
    ? 'PDSH_DSH_CHECKOUT is required to execute the Worker async-context implementation'
    : false,
}, async () => {
  const runtimeRoot = join(
    checkout as string,
    'packages/experimental/webworker-runtime/src',
  )
  const { AsyncLocalStorage } = await import(pathToFileURL(join(
    runtimeRoot, 'node/builtin_modules/implemented/async_hooks.ts',
  )).href)
  const { installAsyncContextHooks } = await import(pathToFileURL(join(
    runtimeRoot, 'polyfill/async-context/async-context-hooks.ts',
  )).href)
  installAsyncContextHooks()

  const storage = new AsyncLocalStorage()
  const seen: string[] = []
  const observe = (expected: string): void => {
    seen.push(`${expected}:${storage.getStore() ?? 'missing'}`)
  }
  const left = storage.run('left', () => Promise.resolve()
    .then(() => { observe('left-then') })
    .then(() => new Promise<void>(resolve => {
      queueMicrotask(() => {
        observe('left-microtask')
        resolve()
      })
    })))
  const right = storage.run('right', () => Promise.resolve()
    .then(() => { observe('right-then') })
    .then(() => new Promise<void>(resolve => {
      queueMicrotask(() => {
        observe('right-microtask')
        resolve()
      })
    })))
  await Promise.all([left, right])

  assert.deepEqual(seen, [
    'left-then:left',
    'right-then:right',
    'left-microtask:left',
    'right-microtask:right',
  ])
  assert.equal(storage.getStore(), undefined)
  storage.disable()
})
