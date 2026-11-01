// SPDX-License-Identifier: MIT
/**
 * JavaScriptCore compatibility prelude tests.
 *
 * The direct tests cover the installer (feature detection, idempotency,
 * untouched native definitions). The child-process tests run the Worker entry
 * with `Symbol`, `ReadableStream` and Node's `global` missing, once from source
 * and once from the bundle `build.mjs` emits, which proves the bundle root
 * installs the prelude before the entry's module body.
 *
 * The last test deletes Node's native `ReadableStream` async-iteration pair —
 * both `values()` and `[Symbol.asyncIterator]`, the Chromium-109 shape the
 * Android Worker runs — before evaluating the prelude, so the *shim* is what
 * gets measured. It then compares the shim against the captured native methods
 * scenario by scenario (locking, `return()` reasons, iterator self-reference,
 * and `values({ preventCancel: true })`), through both entry points.
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

/**
 * Node's own async-iteration pair, captured before any test deletes it. Web IDL
 * derives `[Symbol.asyncIterator]` from `values()`, so Node exposes one function
 * object under both names; the DOM lib types neither, so both are read through
 * a plain record.
 */
const streamPrototype = ReadableStream.prototype as unknown as Record<PropertyKey, unknown>
const nativeReadableStreamAsyncIterator: unknown = streamPrototype[Symbol.asyncIterator]
const nativeReadableStreamValues: unknown = streamPrototype['values']
const nativeReadableStreamAsyncIteratorDescriptor = Object.getOwnPropertyDescriptor(
  ReadableStream.prototype,
  Symbol.asyncIterator,
)
const nativeReadableStreamValuesDescriptor = Object.getOwnPropertyDescriptor(
  ReadableStream.prototype,
  'values',
)

/** Put Node's native async iterator back; safe to call when nothing was patched. */
function restoreNativeAsyncIterator(): void {
  const descriptor = nativeReadableStreamAsyncIteratorDescriptor
  if (descriptor === undefined) return
  Object.defineProperty(ReadableStream.prototype, Symbol.asyncIterator, descriptor)
}

/** Put Node's native `values()` back; safe to call when nothing was patched. */
function restoreNativeValues(): void {
  const descriptor = nativeReadableStreamValuesDescriptor
  if (descriptor === undefined) return
  Object.defineProperty(ReadableStream.prototype, 'values', descriptor)
}

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

// A failing parity test must not leave Node's prototype patched for the rest.
after(() => {
  restoreNativeValues()
  restoreNativeAsyncIterator()
})

/** Read the async-iterator method the prelude installs on a stream prototype. */
function asyncIteratorOf(prototype: Record<PropertyKey, unknown>): unknown {
  return prototype[Symbol.asyncIterator]
}

/** Read the `values()` method the prelude installs on a stream prototype. */
function valuesOf(prototype: Record<PropertyKey, unknown>): unknown {
  return prototype['values']
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
  assert.equal(valuesOf(stream.prototype), undefined)

  const report = installJscCompat(scope)
  assert.deepEqual(report, {
    dispose: true,
    asyncDispose: true,
    readableStreamValues: true,
    readableStreamAsyncIterator: true,
    promiseWithResolvers: false,
    nodeGlobal: true,
  })

  assert.equal(Symbol.keyFor((symbol as { dispose: symbol }).dispose), 'xl.symbol.dispose')
  assert.equal(Symbol.keyFor((symbol as { asyncDispose: symbol }).asyncDispose), 'xl.symbol.asyncDispose')
  const method = asyncIteratorOf(stream.prototype)
  assert.equal(typeof method, 'function', 'ReadableStream.prototype[Symbol.asyncIterator] must be callable')
  // Web IDL installs one function object under both names; that identity is
  // what makes `values(options)` and `for await` the same code path.
  assert.equal(valuesOf(stream.prototype), method,
    'values and [Symbol.asyncIterator] must be the same function object')
  assert.equal((valuesOf(stream.prototype) as { name?: string }).name, 'values')

  const instance = new stream([1, 2]) as StubReadableStreamInstance & { cancelled: unknown[] }
  const iterator = (method as (this: unknown) => AsyncIterator<unknown>).call(instance)
  assert.deepEqual(await iterator.next(), { done: false, value: 1 })
  assert.deepEqual(await iterator.next(), { done: false, value: 2 })
  assert.deepEqual(await iterator.next(), { done: true, value: undefined })

  const returning = new stream(['x']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const returningIterator = (method as (this: unknown) => AsyncIterator<unknown>).call(returning)
  await returningIterator.next()
  assert.equal(
    (returningIterator as AsyncIterator<unknown> & AsyncIterable<unknown>)[Symbol.asyncIterator](),
    returningIterator,
    'the iterator must be its own async iterator',
  )
  assert.deepEqual(await returningIterator.return?.('stop reading'), { done: true, value: 'stop reading' })
  assert.deepEqual(returning.cancelled, ['stop reading'], 'return(value) must forward the reason to cancel')

  // `values({ preventCancel: true })` releases the reader without cancelling.
  // (The stub restarts its cursor per reader, so the surviving chunks are
  // asserted against real streams in the parity test below.)
  const prevented = new stream(['keep', 'going']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const preventedIterator = (
    valuesOf(stream.prototype) as (
      this: unknown,
      options?: { preventCancel?: boolean },
    ) => AsyncIterator<unknown>
  ).call(prevented, { preventCancel: true })
  assert.deepEqual(await preventedIterator.next(), { done: false, value: 'keep' })
  assert.deepEqual(await preventedIterator.return?.('stop reading'), { done: true, value: 'stop reading' })
  assert.deepEqual(prevented.cancelled, [], 'preventCancel must release the reader without cancelling')
  assert.deepEqual(await preventedIterator.next(), { done: true, value: undefined },
    'a released iterator must report done without touching the reader again')

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
  const values = valuesOf(stream.prototype)
  const disposeDescriptor = Object.getOwnPropertyDescriptor(symbol, 'dispose')

  assert.deepEqual(installJscCompat(scope), {
    dispose: false,
    asyncDispose: false,
    readableStreamValues: false,
    readableStreamAsyncIterator: false,
    promiseWithResolvers: false,
    nodeGlobal: false,
  })
  assert.equal((symbol as { dispose: symbol }).dispose, dispose)
  assert.equal((symbol as { asyncDispose: symbol }).asyncDispose, asyncDispose)
  assert.equal(asyncIteratorOf(stream.prototype), method)
  assert.equal(valuesOf(stream.prototype), values)
  assert.equal(valuesOf(stream.prototype), asyncIteratorOf(stream.prototype),
    'an idempotent install must not split the two names onto different functions')
  assert.deepEqual(Object.getOwnPropertyDescriptor(symbol, 'dispose'), disposeDescriptor)
})

test('installJscCompat aliases the missing name instead of adding a second implementation', () => {
  // An engine that has only `values()`: the missing `@@asyncIterator` must be
  // the native function itself, not the shim.
  const valuesOnly = bareStream()
  const nativeValues = function values(): void {}
  Object.defineProperty(valuesOnly.prototype, 'values', {
    value: nativeValues,
    configurable: true,
    writable: true,
    enumerable: true,
  })
  const valuesScope = { Symbol: createStubSymbol(), ReadableStream: valuesOnly }
  assert.deepEqual(installJscCompat(valuesScope), {
    dispose: true,
    asyncDispose: true,
    readableStreamValues: false,
    readableStreamAsyncIterator: true,
    promiseWithResolvers: false,
    nodeGlobal: true,
  })
  assert.equal(asyncIteratorOf(valuesOnly.prototype), nativeValues,
    'the missing async iterator must alias the native values()')

  // The pre-`values()` engine shape: an async iterator without `values()`.
  const iteratorOnly = bareStream()
  const nativeIterator = function values(): void {}
  Object.defineProperty(iteratorOnly.prototype, Symbol.asyncIterator, {
    value: nativeIterator,
    configurable: true,
    writable: true,
    enumerable: false,
  })
  const iteratorScope = { Symbol: createStubSymbol(), ReadableStream: iteratorOnly }
  const report = installJscCompat(iteratorScope)
  assert.equal(report.readableStreamValues, true)
  assert.equal(report.readableStreamAsyncIterator, false,
    'a native async iterator must not be replaced')
  assert.equal(valuesOf(iteratorOnly.prototype), nativeIterator,
    'the missing values() must alias the native async iterator')
  assert.equal(valuesOf(iteratorOnly.prototype), asyncIteratorOf(iteratorOnly.prototype))
})

test('installJscCompat leaves Node and modern engines untouched', () => {
  const dispose = Object.getOwnPropertyDescriptor(Symbol, 'dispose')
  const asyncDispose = Object.getOwnPropertyDescriptor(Symbol, 'asyncDispose')
  const iterator = Object.getOwnPropertyDescriptor(ReadableStream.prototype, Symbol.asyncIterator)
  const values = Object.getOwnPropertyDescriptor(ReadableStream.prototype, 'values')
  const withResolvers = Object.getOwnPropertyDescriptor(Promise, 'withResolvers')

  assert.deepEqual(installJscCompat(globalThis as unknown as JscCompatScope), {
    dispose: false,
    asyncDispose: false,
    readableStreamValues: false,
    readableStreamAsyncIterator: false,
    promiseWithResolvers: false,
    nodeGlobal: false,
  })
  assert.deepEqual(Object.getOwnPropertyDescriptor(Symbol, 'dispose'), dispose)
  assert.deepEqual(Object.getOwnPropertyDescriptor(Symbol, 'asyncDispose'), asyncDispose)
  assert.deepEqual(Object.getOwnPropertyDescriptor(ReadableStream.prototype, Symbol.asyncIterator), iterator)
  assert.deepEqual(Object.getOwnPropertyDescriptor(ReadableStream.prototype, 'values'), values,
    'a native values() must not be replaced')
  assert.deepEqual(Object.getOwnPropertyDescriptor(Promise, 'withResolvers'), withResolvers,
    'a native Promise.withResolvers must not be replaced')
  // The import-time installation on Node had nothing to add either.
  assert.deepEqual(jscCompat, {
    dispose: false,
    asyncDispose: false,
    readableStreamValues: false,
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

/**
 * ---------------------------------------------------------------------------
 * Native-parity tests for the installed `ReadableStream` async iterator.
 *
 * The prelude patches a *global* prototype, so the only way to test it on Node
 * is to delete the native methods first and let the prelude's import-time
 * installation fill the gap — the Chromium-109 shape the Android Worker runs.
 * Every scenario then runs twice against the same kind of real stream: once
 * through the native methods captured before the deletion, once through the
 * installed shim, and the two observations must deep-equal. The native run is
 * also checked against a literal expectation first, so a Node behaviour change
 * is reported as reference drift instead of silently redefining parity.
 * ---------------------------------------------------------------------------
 */

/** The native iterator shape both implementations must satisfy. */
type StreamIterator = AsyncIterator<unknown> & AsyncIterable<unknown>

/** The `ReadableStreamIteratorOptions` members the shim reads. */
interface IteratorOptions {
  readonly preventCancel?: boolean
}

/** Call `values()` or `[Symbol.asyncIterator]()` — the native method or the shim. */
type IteratorFactory = (stream: ReadableStream<unknown>, options?: IteratorOptions) => StreamIterator

/**
 * The two names a stream exposes async iteration under. Web IDL derives one
 * from the other, so a conforming engine makes them the same function object;
 * a scenario that uses both proves the aliasing holds for real streams.
 */
interface StreamEntryPoints {
  readonly values: IteratorFactory
  readonly asyncIterator: IteratorFactory
}

/** One scenario result; deep-equal against the native run and a literal. */
type Observation = Record<string, unknown>

/** A real `ReadableStream` a scenario drives chunk by chunk. */
interface ControlledStream {
  readonly stream: ReadableStream<unknown>
  readonly controller: ReadableStreamDefaultController<unknown>
  readonly cancelled: readonly unknown[]
}

/**
 * Build a real stream whose underlying source records cancel reasons.
 *
 * The tests deliberately avoid `bareStream` here: the platform's `locked` and
 * `releaseLock` are exactly the semantics under test, and a stub does not have
 * them.
 * @param cancel - Extra underlying cancel behaviour, e.g. one that rejects.
 * @returns The stream, its controller and the recorded cancel reasons.
 */
function controlledStream(cancel?: (reason: unknown) => void | Promise<void>): ControlledStream {
  const cancelled: unknown[] = []
  let controller: ReadableStreamDefaultController<unknown> | undefined
  const stream = new ReadableStream<unknown>({
    start(value) {
      controller = value as ReadableStreamDefaultController<unknown>
    },
    cancel(reason: unknown) {
      cancelled.push(reason)
      return cancel?.(reason)
    },
  })
  if (controller === undefined) throw new Error('a ReadableStream must start synchronously')
  return { stream, controller, cancelled }
}

/**
 * A stream iterated through the patched prototype. The DOM lib does not declare
 * `ReadableStream[Symbol.asyncIterator]`; the prelude is what installs it.
 * @param stream - The stream to iterate.
 * @returns The same stream, typed as async iterable.
 */
function asAsyncIterable(stream: ReadableStream<unknown>): ReadableStream<unknown> & AsyncIterable<unknown> {
  return stream as ReadableStream<unknown> & AsyncIterable<unknown>
}

/** Describe what a stream still allows after a scenario. */
function reuseStream(stream: ReadableStream<unknown>): string {
  try {
    stream.getReader().releaseLock()
    return 'readable'
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

/** The shim's cancel reasons are unknown values; compare them as names. */
function reasons(cancelled: readonly unknown[]): readonly string[] {
  return cancelled.map(reason => String(reason))
}

interface Scenario {
  readonly name: string
  readonly run: (entries: StreamEntryPoints) => Promise<Observation>
  /** What Node's native iterator does, spelled out so the reference cannot drift silently. */
  readonly expected: Observation
}

/** Read every chunk, then observe the lock and whether the stream is reusable. */
async function observeExhausted(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue('a')
  controller.enqueue('b')
  controller.close()
  const iterator = entries.asyncIterator(stream)
  const results = [await iterator.next(), await iterator.next(), await iterator.next()]
  const lockedAfterDone = stream.locked
  const nextAfterDone = await iterator.next()
  return {
    results,
    lockedAfterDone,
    nextAfterDone,
    reuse: reuseStream(stream),
    cancelled: reasons(cancelled),
  }
}

/** `return(value)`: cancel reason, synchronous unlock, argument echo, no double cancel. */
async function observeReturn(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue('first')
  controller.enqueue('second')
  const iterator = entries.asyncIterator(stream)
  const first = await iterator.next()
  const pending = iterator.return?.('consumer stopped')
  // Native releases the reader synchronously, before the cancel settles.
  const lockedSynchronouslyAfterReturn = stream.locked
  const returned = await pending
  const lockedAfterReturn = stream.locked
  const secondReturn = await iterator.return?.('again')
  const nextAfterReturn = await iterator.next()
  return {
    first,
    lockedSynchronouslyAfterReturn,
    returned,
    lockedAfterReturn,
    secondReturn,
    nextAfterReturn,
    reuse: reuseStream(stream),
    cancelled: reasons(cancelled),
  }
}

/** `break` out of `for await` over the iterator: AsyncIteratorClose calls `return()`. */
async function observeBreak(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue(1)
  controller.enqueue(2)
  controller.enqueue(3)
  const iterator = entries.asyncIterator(stream)
  const seen: unknown[] = []
  for await (const chunk of iterator) {
    seen.push(chunk)
    break
  }
  const lockedAfterBreak = stream.locked
  const secondPass: unknown[] = []
  for await (const chunk of iterator) secondPass.push(chunk)
  return { seen, lockedAfterBreak, secondPass, reuse: reuseStream(stream), cancelled: reasons(cancelled) }
}

/** Iterating the iterator to completion must not cancel the stream. */
async function observeCompleteThroughIterator(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue(1)
  controller.enqueue(2)
  controller.close()
  const iterator = entries.asyncIterator(stream)
  const seen: unknown[] = []
  for await (const chunk of iterator) seen.push(chunk)
  return { seen, lockedAfterDone: stream.locked, reuse: reuseStream(stream), cancelled: reasons(cancelled) }
}

/** The iterator is its own async iterator and can be iterated directly. */
async function observeSelfReference(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller } = controlledStream()
  controller.enqueue('only')
  controller.close()
  const iterator = entries.asyncIterator(stream)
  const method = iterator[Symbol.asyncIterator] as (() => StreamIterator) | undefined
  const self = method === undefined ? undefined : method.call(iterator)
  const seen: unknown[] = []
  if (self !== undefined) for await (const chunk of self) seen.push(chunk)
  return {
    hasAsyncIterator: typeof method,
    selfIsIterator: self === iterator,
    seen,
    lockedAfterIteration: stream.locked,
  }
}

/** A failing read releases the reader and keeps rejecting, like a native one. */
async function observeError(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue('ok')
  const iterator = entries.asyncIterator(stream)
  const first = await iterator.next()
  controller.error(new Error('stream failed'))
  let failure = 'did not throw'
  try {
    await iterator.next()
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error)
  }
  const lockedAfterError = stream.locked
  const nextAfterError = await iterator.next()
  const returnAfterError = await iterator.return?.('too late')
  return {
    first,
    failure,
    lockedAfterError,
    nextAfterError,
    returnAfterError,
    reuse: reuseStream(stream),
    cancelled: reasons(cancelled),
  }
}

/** A rejecting underlying cancel rejects `return()` and still releases the lock. */
async function observeCancelFailure(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller } = controlledStream(() => {
    throw new Error('cancel failed')
  })
  controller.enqueue('first')
  const iterator = entries.asyncIterator(stream)
  await iterator.next()
  const pending = iterator.return?.('stop')
  const lockedSynchronouslyAfterReturn = stream.locked
  let failure = 'did not reject'
  try {
    await pending
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error)
  }
  return {
    lockedSynchronouslyAfterReturn,
    failure,
    lockedAfterFailure: stream.locked,
    reuse: reuseStream(stream),
  }
}

/** `return()` on a closed stream resolves done, echoes the argument and unlocks. */
async function observeReturnOnClosed(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller } = controlledStream()
  controller.enqueue('queued')
  controller.close()
  const iterator = entries.asyncIterator(stream)
  const returned = await iterator.return?.('closed reason')
  return { returned, locked: stream.locked, reuse: reuseStream(stream) }
}

/** `values()` reads the stream and releases it on completion, like `@@asyncIterator`. */
async function observeValues(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue('a')
  controller.enqueue('b')
  controller.close()
  const iterator = entries.values(stream)
  const results = [await iterator.next(), await iterator.next(), await iterator.next()]
  const nextAfterDone = await iterator.next()
  return {
    results,
    nextAfterDone,
    lockedAfterDone: stream.locked,
    reuse: reuseStream(stream),
    cancelled: reasons(cancelled),
  }
}

/**
 * `values({ preventCancel: true })`: `return()` releases the reader without
 * cancelling, so the queued chunks survive for a second iterator on the same
 * stream. The observable proof of "no cancel" is the underlying source's
 * `cancel` callback never running, plus those chunks still being readable.
 */
async function observePreventCancel(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue(1)
  controller.enqueue(2)
  controller.enqueue(3)
  controller.close()
  const iterator = entries.values(stream, { preventCancel: true })
  const first = await iterator.next()
  const pending = iterator.return?.('consumer stopped')
  // The release happens before the returned promise settles, as on the
  // cancelling path — the difference is that no cancel is even started.
  const lockedSynchronouslyAfterReturn = stream.locked
  const returned = await pending
  const lockedAfterReturn = stream.locked
  const nextAfterReturn = await iterator.next()
  const returnAgain = await iterator.return?.('again')
  const cancelledAfterReturn = reasons(cancelled)
  // A second `values({ preventCancel: true })` on the same stream must still
  // see the chunks the first iterator left queued.
  const secondPass: unknown[] = []
  for await (const chunk of entries.values(stream, { preventCancel: true })) secondPass.push(chunk)
  return {
    first,
    lockedSynchronouslyAfterReturn,
    returned,
    lockedAfterReturn,
    nextAfterReturn,
    returnAgain,
    cancelledAfterReturn,
    secondPass,
    lockedAfterSecondPass: stream.locked,
    cancelled: reasons(cancelled),
    reuse: reuseStream(stream),
  }
}

/**
 * `break` through `values()` under both settings: `preventCancel` releases and
 * keeps the stream readable, the default still cancels (the pre-existing
 * `for await … break` behaviour).
 */
async function observeBreakOptions(entries: StreamEntryPoints): Promise<Observation> {
  const prevented = controlledStream()
  prevented.controller.enqueue(1)
  prevented.controller.enqueue(2)
  const preventedSeen: unknown[] = []
  for await (const chunk of entries.values(prevented.stream, { preventCancel: true })) {
    preventedSeen.push(chunk)
    break
  }

  const defaulted = controlledStream()
  defaulted.controller.enqueue(1)
  defaulted.controller.enqueue(2)
  const defaultSeen: unknown[] = []
  for await (const chunk of entries.values(defaulted.stream)) {
    defaultSeen.push(chunk)
    break
  }

  return {
    preventedSeen,
    preventedLockedAfterBreak: prevented.stream.locked,
    preventedCancelled: reasons(prevented.cancelled),
    defaultSeen,
    defaultLockedAfterBreak: defaulted.stream.locked,
    defaultCancelled: reasons(defaulted.cancelled),
    preventedReuse: reuseStream(prevented.stream),
  }
}

/**
 * One stream, both entry points: `values({ preventCancel: true })` releases
 * after the first chunk, then `[Symbol.asyncIterator]` reads the rest. Both
 * names must share one implementation, one reader discipline and one outcome.
 */
async function observeEntryPointsOnOneStream(entries: StreamEntryPoints): Promise<Observation> {
  const { stream, controller, cancelled } = controlledStream()
  controller.enqueue('a')
  controller.enqueue('b')
  controller.close()
  const viaValues: unknown[] = []
  for await (const chunk of entries.values(stream, { preventCancel: true })) {
    viaValues.push(chunk)
    break
  }
  const lockedAfterValuesBreak = stream.locked
  const viaAsyncIterator: unknown[] = []
  for await (const chunk of entries.asyncIterator(stream)) viaAsyncIterator.push(chunk)
  return {
    viaValues,
    lockedAfterValuesBreak,
    viaAsyncIterator,
    lockedAfterBoth: stream.locked,
    cancelled: reasons(cancelled),
    reuse: reuseStream(stream),
  }
}

const scenarios: readonly Scenario[] = [
  {
    name: 'next() to completion',
    run: observeExhausted,
    expected: {
      results: [
        { done: false, value: 'a' },
        { done: false, value: 'b' },
        { done: true, value: undefined },
      ],
      lockedAfterDone: false,
      nextAfterDone: { done: true, value: undefined },
      reuse: 'readable',
      cancelled: [],
    },
  },
  {
    name: 'return(value)',
    run: observeReturn,
    expected: {
      first: { done: false, value: 'first' },
      lockedSynchronouslyAfterReturn: false,
      returned: { done: true, value: 'consumer stopped' },
      lockedAfterReturn: false,
      secondReturn: { done: true, value: 'again' },
      nextAfterReturn: { done: true, value: undefined },
      reuse: 'readable',
      cancelled: ['consumer stopped'],
    },
  },
  {
    name: 'break out of for await',
    run: observeBreak,
    expected: {
      seen: [1],
      lockedAfterBreak: false,
      secondPass: [],
      reuse: 'readable',
      // `for await` calls `return()` without an argument.
      cancelled: ['undefined'],
    },
  },
  {
    name: 'full for await over the iterator',
    run: observeCompleteThroughIterator,
    expected: { seen: [1, 2], lockedAfterDone: false, reuse: 'readable', cancelled: [] },
  },
  {
    name: 'iterator self-reference',
    run: observeSelfReference,
    expected: {
      hasAsyncIterator: 'function',
      selfIsIterator: true,
      seen: ['only'],
      lockedAfterIteration: false,
    },
  },
  {
    name: 'errored stream',
    run: observeError,
    expected: {
      first: { done: false, value: 'ok' },
      failure: 'stream failed',
      lockedAfterError: false,
      nextAfterError: { done: true, value: undefined },
      returnAfterError: { done: true, value: 'too late' },
      reuse: 'readable',
      cancelled: [],
    },
  },
  {
    name: 'rejecting cancel',
    run: observeCancelFailure,
    expected: {
      lockedSynchronouslyAfterReturn: false,
      failure: 'cancel failed',
      lockedAfterFailure: false,
      reuse: 'readable',
    },
  },
  {
    name: 'return() on a closed stream',
    run: observeReturnOnClosed,
    expected: { returned: { done: true, value: 'closed reason' }, locked: false, reuse: 'readable' },
  },
  {
    name: 'values() to completion',
    run: observeValues,
    expected: {
      results: [
        { done: false, value: 'a' },
        { done: false, value: 'b' },
        { done: true, value: undefined },
      ],
      nextAfterDone: { done: true, value: undefined },
      lockedAfterDone: false,
      reuse: 'readable',
      cancelled: [],
    },
  },
  {
    name: 'values({ preventCancel: true })',
    run: observePreventCancel,
    expected: {
      first: { done: false, value: 1 },
      lockedSynchronouslyAfterReturn: false,
      returned: { done: true, value: 'consumer stopped' },
      lockedAfterReturn: false,
      nextAfterReturn: { done: true, value: undefined },
      returnAgain: { done: true, value: 'again' },
      cancelledAfterReturn: [],
      secondPass: [2, 3],
      lockedAfterSecondPass: false,
      cancelled: [],
      reuse: 'readable',
    },
  },
  {
    name: 'break: default cancels, preventCancel does not',
    run: observeBreakOptions,
    expected: {
      preventedSeen: [1],
      preventedLockedAfterBreak: false,
      preventedCancelled: [],
      defaultSeen: [1],
      defaultLockedAfterBreak: false,
      // `for await` calls `return()` without an argument.
      defaultCancelled: ['undefined'],
      preventedReuse: 'readable',
    },
  },
  {
    name: 'values() and @@asyncIterator share one stream',
    run: observeEntryPointsOnOneStream,
    expected: {
      viaValues: ['a'],
      lockedAfterValuesBreak: false,
      viaAsyncIterator: ['b'],
      lockedAfterBoth: false,
      cancelled: [],
      reuse: 'readable',
    },
  },
]

/**
 * Import the prelude again under a query string.
 *
 * Node keys ES modules by their full URL, so this re-evaluates the module —
 * including its import-time `installJscCompat()` — after the caller deleted the
 * native methods. A static import would have installed nothing (Node has the
 * feature), and the test would then measure the native methods.
 * @returns The reloaded module namespace.
 */
function reloadPrelude(): Promise<typeof import('./jsc-compat.ts')> {
  const specifier: string = `./jsc-compat.ts?chromium-109=${process.pid}-${Date.now()}`
  return import(specifier) as Promise<typeof import('./jsc-compat.ts')>
}

/** The property attributes both the native install and the shim must carry. */
function attributes(descriptor: PropertyDescriptor | undefined): Record<string, unknown> | undefined {
  if (descriptor === undefined) return undefined
  return {
    writable: descriptor.writable,
    enumerable: descriptor.enumerable,
    configurable: descriptor.configurable,
  }
}

/** Wrap a captured method as an {@link IteratorFactory}. */
function methodFactory(method: unknown): IteratorFactory {
  return (stream, options) =>
    (method as (this: ReadableStream<unknown>, options?: IteratorOptions) => StreamIterator)
      .call(stream, options)
}

test('the installed shim matches native ReadableStream async iteration', async () => {
  assert.notEqual(nativeReadableStreamAsyncIterator, undefined,
    'this test needs Node\'s native async iterator as the reference')
  assert.notEqual(nativeReadableStreamValues, undefined,
    'this test needs Node\'s native values() as the reference')
  // Web IDL derives `@@asyncIterator` from `values()`, and Node exposes one
  // function object under both names. If that reference drifts, the shim's
  // structural target has changed and this test must be re-derived.
  assert.equal(nativeReadableStreamValues, nativeReadableStreamAsyncIterator,
    'precondition: native values() and @@asyncIterator must be the same function object')
  assert.equal(streamPrototype[Symbol.asyncIterator], nativeReadableStreamAsyncIterator,
    'precondition: no other test may have patched the stream prototype')
  assert.equal(streamPrototype['values'], nativeReadableStreamValues,
    'precondition: no other test may have patched the stream prototype')

  // Chromium 109 has neither method. Delete both: leaving Node's native
  // `values()` behind would make the prelude (correctly) alias it instead of
  // installing the shim, and the test would measure the native function.
  Reflect.deleteProperty(ReadableStream.prototype, Symbol.asyncIterator)
  Reflect.deleteProperty(ReadableStream.prototype, 'values')
  assert.equal(streamPrototype[Symbol.asyncIterator], undefined,
    'the Chromium-109 shape requires the native async iterator to be gone before the prelude evaluates')
  assert.equal(streamPrototype['values'], undefined,
    'the Chromium-109 shape requires the native values() to be gone before the prelude evaluates')

  try {
    const prelude = await reloadPrelude()
    assert.equal(prelude.jscCompat.readableStreamAsyncIterator, true,
      'evaluating the prelude after the deletion must install the async iterator')
    assert.equal(prelude.jscCompat.readableStreamValues, true,
      'evaluating the prelude after the deletion must install values()')

    // Read through the helpers: `assert.equal(…, undefined)` narrows the
    // indexed access itself to `undefined` for the rest of the function.
    const installedValues = valuesOf(streamPrototype)
    const installedAsyncIterator = asyncIteratorOf(streamPrototype)
    assert.equal(typeof installedValues, 'function', 'values() must be callable')
    assert.equal(typeof installedAsyncIterator, 'function')
    assert.notEqual(installedValues, nativeReadableStreamValues,
      'the installed values() must be the shim, not the native function')
    assert.notEqual(installedAsyncIterator, nativeReadableStreamAsyncIterator,
      'the installed async iterator must be the shim, not the native function')
    // The structural requirement: one function object under both names, as the
    // Web IDL asynchronous iterable declaration installs it. A separately
    // shaped `@@asyncIterator` (even one that delegates) would fail here.
    assert.equal(installedAsyncIterator, installedValues,
      'values() and @@asyncIterator must be the same function object')
    assert.equal((installedValues as { name?: string }).name,
      (nativeReadableStreamValues as { name?: string }).name,
      'the shim function must keep the native name')
    assert.deepEqual(
      attributes(Object.getOwnPropertyDescriptor(ReadableStream.prototype, 'values')),
      attributes(nativeReadableStreamValuesDescriptor),
      'values() must keep the native property attributes (enumerable data property)',
    )
    assert.deepEqual(
      attributes(Object.getOwnPropertyDescriptor(ReadableStream.prototype, Symbol.asyncIterator)),
      attributes(nativeReadableStreamAsyncIteratorDescriptor),
      '@@asyncIterator must keep the native property attributes (non-enumerable method)',
    )

    const nativeEntries: StreamEntryPoints = {
      values: methodFactory(nativeReadableStreamValues),
      asyncIterator: methodFactory(nativeReadableStreamAsyncIterator),
    }
    const shimEntries: StreamEntryPoints = {
      values: methodFactory(installedValues),
      asyncIterator: methodFactory(installedAsyncIterator),
    }

    for (const scenario of scenarios) {
      const nativeObservation = await scenario.run(nativeEntries)
      const shimObservation = await scenario.run(shimEntries)
      assert.deepEqual(nativeObservation, scenario.expected,
        `Node's native behaviour changed for ${scenario.name}`)
      assert.deepEqual(shimObservation, nativeObservation,
        `the shim differs from native behaviour for ${scenario.name}`)
    }

    // The same three fixes through the patched prototype, exactly as DSH code
    // reaches them: `for await` over the stream itself (P11's regression).
    const exhausted = controlledStream()
    exhausted.controller.enqueue('p1')
    exhausted.controller.enqueue('p2')
    exhausted.controller.close()
    const seen: unknown[] = []
    for await (const chunk of asAsyncIterable(exhausted.stream)) seen.push(chunk)
    assert.deepEqual(seen, ['p1', 'p2'])
    assert.equal(exhausted.stream.locked, false, 'a completed for await must release the lock')
    assert.equal(reuseStream(exhausted.stream), 'readable')

    const broken = controlledStream()
    broken.controller.enqueue('b1')
    broken.controller.enqueue('b2')
    for await (const chunk of asAsyncIterable(broken.stream)) {
      assert.equal(chunk, 'b1')
      break
    }
    assert.equal(broken.stream.locked, false, 'break must release the lock')
    assert.deepEqual(reasons(broken.cancelled), ['undefined'], 'break must cancel the stream')
    assert.equal(reuseStream(broken.stream), 'readable', 'break must leave the stream reusable')
    const secondPass: unknown[] = []
    for await (const chunk of asAsyncIterable(broken.stream)) secondPass.push(chunk)
    assert.deepEqual(secondPass, [], 'a second for await must not throw TypeError: locked')

    // `stream.values({ preventCancel: true })` through the patched prototype —
    // the call Chromium 109 previously answered with `TypeError: not a function`
    // — then proving the stream survived the early exit.
    const prevented = controlledStream()
    prevented.controller.enqueue('v1')
    prevented.controller.enqueue('v2')
    prevented.controller.close()
    const valuesIterator = (
      prevented.stream as unknown as { values(options?: IteratorOptions): StreamIterator }
    ).values({ preventCancel: true })
    const preventedSeen: unknown[] = []
    for await (const chunk of valuesIterator) {
      preventedSeen.push(chunk)
      break
    }
    assert.deepEqual(preventedSeen, ['v1'])
    assert.equal(prevented.stream.locked, false, 'preventCancel break must release the lock')
    assert.deepEqual(reasons(prevented.cancelled), [], 'preventCancel break must not cancel the stream')
    const remaining: unknown[] = []
    for await (const chunk of asAsyncIterable(prevented.stream)) remaining.push(chunk)
    assert.deepEqual(remaining, ['v2'],
      'the chunk the first iterator left queued must still be readable')
  } finally {
    restoreNativeValues()
    restoreNativeAsyncIterator()
    assert.equal(valuesOf(streamPrototype), nativeReadableStreamValues,
      'the native values() must be restored after the test')
    assert.equal(asyncIteratorOf(streamPrototype), nativeReadableStreamAsyncIterator,
      'the native method must be restored after the test')
  }
})
