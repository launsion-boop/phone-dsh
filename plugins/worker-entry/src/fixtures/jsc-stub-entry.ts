// SPDX-License-Identifier: MIT
/**
 * Child process for `jsc-compat.test.ts`: remove the platform features
 * JavaScriptCore lacks — including Node's `global` alias — then import the
 * Worker entry (source or built bundle) and assert that the entry's first
 * import installed the compatibility prelude before its own module body ran.
 *
 * Usage: node jsc-stub-entry.ts <module-url>
 * @module @phone-dsh/dsh-worker-entry/fixtures/jsc-stub-entry
 */
import assert from 'node:assert/strict'

import {
  installStubPlatform,
  type StubReadableStreamInstance,
} from './jsc-stub-globals.ts'

const moduleURL = process.argv[2]
if (moduleURL === undefined || moduleURL === '') {
  console.error('usage: jsc-stub-entry <module-url>')
  process.exit(2)
}

// Node lazily initializes its bundled undici the first time a Web API is
// touched, and that CommonJS graph reads Node's `global` alias while it loads.
// Warm it before removing the alias so this child isolates the entry's prelude
// instead of failing inside Node's own module loader.
void globalThis.Headers
void globalThis.fetch
// Install the gaps *before* the dynamic import, so the entry's first import is
// what has to fill them.
const { symbol, readableStream } = installStubPlatform()
// Node defines `global`; a WKWebView Worker does not. Remove it before the
// dynamic import so the assertion below proves the production entry installed
// the alias, not that Node happened to provide it.
Reflect.deleteProperty(globalThis, 'global')
assert.equal((globalThis as { global?: unknown }).global, undefined,
  'the stub must start without the Node global alias')

try {
  const entry = await import(moduleURL) as { workerEvents?: unknown }
  const stubSymbol = symbol as SymbolConstructor & { dispose?: symbol; asyncDispose?: symbol }

  assert.equal(typeof stubSymbol.dispose, 'symbol', 'the entry must install Symbol.dispose')
  assert.equal(stubSymbol.dispose, Symbol.for('xl.symbol.dispose'))
  assert.equal(typeof stubSymbol.asyncDispose, 'symbol', 'the entry must install Symbol.asyncDispose')
  assert.equal(stubSymbol.asyncDispose, Symbol.for('xl.symbol.asyncDispose'))

  const method = readableStream.prototype[Symbol.asyncIterator]
  assert.equal(typeof method, 'function', 'the entry must install ReadableStream async iteration')

  const stream = new readableStream([1, 2, 3]) as StubReadableStreamInstance & { cancelled: unknown[] }
  const iterator = (method as (this: unknown) => AsyncIterator<unknown>).call(stream)
  assert.deepEqual(await iterator.next(), { done: false, value: 1 })
  assert.deepEqual(await iterator.next(), { done: false, value: 2 })
  assert.deepEqual(await iterator.next(), { done: false, value: 3 })
  assert.deepEqual(await iterator.next(), { done: true, value: undefined })

  const returned = new readableStream(['x']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const returning = (method as (this: unknown) => AsyncIterator<unknown>).call(returned)
  await returning.next()
  assert.deepEqual(await returning.return?.(), { done: true, value: undefined })
  assert.equal(returned.cancelled.length, 1, 'return() must cancel the reader')

  const thrown = new readableStream(['x']) as StubReadableStreamInstance & { cancelled: unknown[] }
  const throwing = (method as (this: unknown) => AsyncIterator<unknown>).call(thrown)
  await throwing.next()
  const failure = new Error('stop the stream')
  await assert.rejects(
    (throwing.throw as (error?: unknown) => Promise<unknown>)(failure),
    /stop the stream/,
  )
  assert.equal(thrown.cancelled.length, 1, 'throw() must cancel the reader')

  // The entry's own module body ran after the prelude: it publishes its event
  // target on the global scope.
  assert.equal(typeof (globalThis as { global?: unknown }).global, 'object',
    'the entry must leave a Node global alias available to image modules')
  assert.equal(typeof entry.workerEvents, 'object')
  assert.equal((globalThis as { __PDSH_EVENTS__?: unknown }).__PDSH_EVENTS__, entry.workerEvents)

  console.log('__PDSH_JSC_STUB_RESULT__ {"ok":true}')
} catch (error) {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error))
  console.log(`__PDSH_JSC_STUB_RESULT__ ${JSON.stringify({ ok: false, error: String(error) })}`)
  process.exitCode = 1
}
