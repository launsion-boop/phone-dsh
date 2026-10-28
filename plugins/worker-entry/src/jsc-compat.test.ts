// SPDX-License-Identifier: MIT
/**
 * JavaScriptCore compatibility prelude tests.
 *
 * The direct tests cover the installer (feature detection, idempotency,
 * untouched native definitions). The child-process tests run the Worker entry
 * with `Symbol`, `ReadableStream` and Node's `global` missing, once from source
 * and once from the bundle `build.mjs` emits, which proves the bundle root
 * installs the prelude before the entry's module body.
 * @module @phone-dsh/dsh-worker-entry/jsc-compat.test
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { after, test } from 'node:test'

import { installJscCompat, jscCompat, type JscCompatScope } from './jsc-compat.ts'
import type { PromiseWithResolversHost } from './promise-compat.ts'
import {
  createStubSymbol,
  type StubReadableStreamConstructor,
  type StubReadableStreamInstance,
  type StubStreamReader,
} from './fixtures/jsc-stub-globals.ts'

const here = dirname(fileURLToPath(import.meta.url))
const checkout = process.env.PDSH_DSH_CHECKOUT
const skipBuild = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the bundle build resolves the pinned checkout'
  : false

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/** Read the async-iterator method the prelude installs on a stream prototype. */
function asyncIteratorOf(prototype: Record<PropertyKey, unknown>): unknown {
  return prototype[Symbol.asyncIterator]
}

/** A fresh `ReadableStream` stand-in, so tests never share a patched prototype. */
function bareStream(): StubReadableStreamConstructor {
  class BareReadableStream {
    readonly chunks: readonly unknown[]
    readonly cancelled: unknown[] = []

    constructor(chunks: readonly unknown[]) {
      this.chunks = chunks
    }

    getReader(): StubStreamReader {
      let index = 0
      return {
        read: async () => index < this.chunks.length
          ? { done: false, value: this.chunks[index++] }
          : { done: true, value: undefined },
        cancel: async (reason?: unknown) => {
          this.cancelled.push(reason)
        },
      }
    }
  }
  return BareReadableStream as unknown as StubReadableStreamConstructor
}

/**
 * Run the child fixture against one module URL and parse its result line.
 * @param moduleURL - `file:` URL of the entry or built bundle.
 * @returns Exit status and the parsed result line, if any.
 */
function runStubChild(moduleURL: string): { status: number | null; result?: unknown; output: string } {
  const child = spawnSync(process.execPath, [join(here, 'fixtures', 'jsc-stub-entry.ts'), moduleURL], {
    encoding: 'utf8',
  })
  const output = `${child.stdout}${child.stderr}`
  const marker = child.stdout.split('\n').find(line => line.startsWith('__PDSH_JSC_STUB_RESULT__ '))
  return {
    status: child.status,
    output,
    ...marker === undefined
      ? {}
      : { result: JSON.parse(marker.slice('__PDSH_JSC_STUB_RESULT__ '.length)) as unknown },
  }
}

test('installJscCompat fills the JavaScriptCore gaps in a stubbed global', async () => {
  const symbol = createStubSymbol()
  const stream = bareStream()
  const scope = { Symbol: symbol, ReadableStream: stream }

  assert.equal((symbol as { dispose?: unknown }).dispose, undefined)
  assert.equal((symbol as { asyncDispose?: unknown }).asyncDispose, undefined)
  assert.equal(asyncIteratorOf(stream.prototype), undefined)

  const report = installJscCompat(scope)
  assert.deepEqual(report, {
    dispose: true,
    asyncDispose: true,
    readableStreamAsyncIterator: true,
    promiseWithResolvers: false,
    nodeGlobal: true,
  })

  assert.equal(Symbol.keyFor((symbol as { dispose: symbol }).dispose), 'xl.symbol.dispose')
  assert.equal(Symbol.keyFor((symbol as { asyncDispose: symbol }).asyncDispose), 'xl.symbol.asyncDispose')
  const method = asyncIteratorOf(stream.prototype)
  assert.equal(typeof method, 'function', 'ReadableStream.prototype[Symbol.asyncIterator] must be callable')

  const instance = new stream([1, 2]) as StubReadableStreamInstance & { cancelled: unknown[] }
  const iterator = (method as (this: unknown) => AsyncIterator<unknown>).call(instance)
  assert.deepEqual(await iterator.next(), { done: false, value: 1 })
  assert.deepEqual(await iterator.next(), { done: false, value: 2 })
  assert.deepEqual(await iterator.next(), { done: true, value: undefined })

  const returning = new stream(['x']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const returningIterator = (method as (this: unknown) => AsyncIterator<unknown>).call(returning)
  await returningIterator.next()
  assert.deepEqual(await returningIterator.return?.(), { done: true, value: undefined })
  assert.equal(returning.cancelled.length, 1, 'return() cancels the reader')

  const throwing = new stream(['x']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const throwingIterator = (method as (this: unknown) => AsyncIterator<unknown>).call(throwing)
  await throwingIterator.next()
  await assert.rejects(
    (throwingIterator.throw as (error?: unknown) => Promise<unknown>)(new Error('stop the stream')),
    /stop the stream/,
  )
  assert.equal(throwing.cancelled.length, 1, 'throw() cancels the reader')
})

test('installJscCompat fills the Node global alias a Web Worker lacks', () => {
  const scope = { Symbol: createStubSymbol(), ReadableStream: bareStream() } as JscCompatScope
  assert.equal((scope as { global?: unknown }).global, undefined)

  const report = installJscCompat(scope)
  assert.equal(report.nodeGlobal, true)
  assert.equal((scope as { global?: unknown }).global, scope)

  // Node-style package bodies read globals through this alias; the same alias
  // must keep answering the worker global on a second install.
  ;(scope as { global?: Record<string, unknown> }).global!.TESTING_WINDOWS = false
  assert.equal(installJscCompat(scope).nodeGlobal, false)
  assert.equal((scope as { global?: Record<string, unknown> }).global!.TESTING_WINDOWS, false)
})

test('installJscCompat installs a resolving/rejecting Promise.withResolvers fallback', async () => {
  const promiseHost: PromiseWithResolversHost = {}
  const scope: JscCompatScope = {
    Symbol: createStubSymbol(),
    ReadableStream: bareStream(),
    Promise: promiseHost,
  }
  const report = installJscCompat(scope)
  assert.equal(report.promiseWithResolvers, true)
  assert.equal(report.nodeGlobal, true)
  assert.equal(typeof promiseHost.withResolvers, 'function')
  assert.equal(installJscCompat(scope).promiseWithResolvers, false)

  const resolved = promiseHost.withResolvers!<number>()
  resolved.resolve(7)
  assert.equal(await resolved.promise, 7)

  const rejected = promiseHost.withResolvers!<number>()
  const failure = new Error('fallback rejects')
  rejected.reject(failure)
  await assert.rejects(rejected.promise, /fallback rejects/)
})

test('installJscCompat is idempotent', () => {
  const symbol = createStubSymbol()
  const stream = bareStream()
  const scope = { Symbol: symbol, ReadableStream: stream }

  assert.equal(installJscCompat(scope).dispose, true)
  const dispose = (symbol as { dispose: symbol }).dispose
  const asyncDispose = (symbol as { asyncDispose: symbol }).asyncDispose
  const method = asyncIteratorOf(stream.prototype)
  const disposeDescriptor = Object.getOwnPropertyDescriptor(symbol, 'dispose')

  assert.deepEqual(installJscCompat(scope), {
    dispose: false,
    asyncDispose: false,
    readableStreamAsyncIterator: false,
    promiseWithResolvers: false,
    nodeGlobal: false,
  })
  assert.equal((symbol as { dispose: symbol }).dispose, dispose)
  assert.equal((symbol as { asyncDispose: symbol }).asyncDispose, asyncDispose)
  assert.equal(asyncIteratorOf(stream.prototype), method)
  assert.deepEqual(Object.getOwnPropertyDescriptor(symbol, 'dispose'), disposeDescriptor)
})

test('installJscCompat leaves Node and modern engines untouched', () => {
  const dispose = Object.getOwnPropertyDescriptor(Symbol, 'dispose')
  const asyncDispose = Object.getOwnPropertyDescriptor(Symbol, 'asyncDispose')
  const iterator = Object.getOwnPropertyDescriptor(ReadableStream.prototype, Symbol.asyncIterator)
  const withResolvers = Object.getOwnPropertyDescriptor(Promise, 'withResolvers')

  assert.deepEqual(installJscCompat(globalThis as unknown as JscCompatScope), {
    dispose: false,
    asyncDispose: false,
    readableStreamAsyncIterator: false,
    promiseWithResolvers: false,
    nodeGlobal: false,
  })
  assert.deepEqual(Object.getOwnPropertyDescriptor(Symbol, 'dispose'), dispose)
  assert.deepEqual(Object.getOwnPropertyDescriptor(Symbol, 'asyncDispose'), asyncDispose)
  assert.deepEqual(Object.getOwnPropertyDescriptor(ReadableStream.prototype, Symbol.asyncIterator), iterator)
  assert.deepEqual(Object.getOwnPropertyDescriptor(Promise, 'withResolvers'), withResolvers,
    'a native Promise.withResolvers must not be replaced')
  // The import-time installation on Node had nothing to add either.
  assert.deepEqual(jscCompat, {
    dispose: false,
    asyncDispose: false,
    readableStreamAsyncIterator: false,
    promiseWithResolvers: false,
    nodeGlobal: false,
  })
})

test('the entry installs the prelude before its module body under a stubbed global', () => {
  const run = runStubChild(pathToFileURL(join(here, 'entry.ts')).href)
  assert.equal(run.status, 0, run.output)
  assert.deepEqual(run.result, { ok: true })
})

test('the built bundle installs the prelude first under a stubbed global', {
  skip: skipBuild,
  timeout: 180_000,
}, () => {
  assert.notEqual(checkout, undefined)
  const out = mkdtempSync(join(tmpdir(), 'pdsh-jsc-bundle-'))
  scratch.push(out)
  const build = spawnSync(process.execPath, [join(here, '..', 'build.mjs'), '--out', out], {
    cwd: join(here, '..'),
    env: { ...process.env, PDSH_DSH_CHECKOUT: checkout },
    encoding: 'utf8',
  })
  assert.equal(build.status, 0, `worker-entry build failed:\n${build.stdout}${build.stderr}`)

  const run = runStubChild(pathToFileURL(join(out, 'worker-entry.js')).href)
  assert.equal(run.status, 0, run.output)
  assert.deepEqual(run.result, { ok: true })
})
