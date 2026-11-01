// SPDX-License-Identifier: MIT
/**
 * JavaScriptCore compatibility prelude for the Worker.
 *
 * WKWebView runs the Worker on JavaScriptCore, which (on the engine versions
 * this project targets) lacks four platform features DSH 0.2.1's lowered code
 * or its npm dependencies rely on:
 *
 *  - the explicit-resource-management symbols used by lowered `using` /
 *    `await using` (`TypeError: Symbol.dispose is not defined` at session
 *    creation),
 *  - async iteration over `ReadableStream` — both the `values()` method and the
 *    `[Symbol.asyncIterator]` method Web IDL derives from it — which the
 *    DeepSeek adapter uses to read SSE (`for await (const frame of events)`),
 *    so every model request otherwise fails as a TRANSPORT error, and
 *  - `Promise.withResolvers`, which the pinned runtime and DSH's agent loop
 *    use while starting a session; Safari only shipped it in 17.4 while the
 *    project supports iOS 17.0, and
 *  - Node's `global` alias, which a Web Worker does not define. Node-style npm
 *    packages read it while their module body evaluates (for example the
 *    `isexe` probe reached through the official MCP SDK's stdio import), and a
 *    bare JSC Worker otherwise throws `ReferenceError: Can't find variable:
 *    global` before the plugin can mount.
 *
 * All must exist before any DSH module evaluates, so every module in the boot
 * path imports this module first (`src/boot.ts`, the build root, and the entry
 * itself). The installation is feature-detected and idempotent: Node and
 * modern engines keep their native definitions untouched.
 *
 * The async-iteration gap is filled under both names — `values()` and
 * `[Symbol.asyncIterator]` — with one function object, because Web IDL derives
 * the latter from the former and native engines expose the very same function
 * twice. An engine that has only one of the two gets the missing one aliased to
 * the present one instead of a second implementation.
 *
 * On-device JavaScriptCore behaviour remains NOT_VERIFIED; the definitions are
 * the same ones the macOS smoke bundle prepends.
 * @module @phone-dsh/dsh-worker-entry/jsc-compat
 */
import {
  installPromiseWithResolvers,
  type PromiseWithResolversHost,
} from './promise-compat.ts'

/** Symbol key used for the installed `Symbol.dispose`, matching the smoke prelude. */
export const SYMBOL_DISPOSE_KEY = 'xl.symbol.dispose'
/** Symbol key used for the installed `Symbol.asyncDispose`, matching the smoke prelude. */
export const SYMBOL_ASYNC_DISPOSE_KEY = 'xl.symbol.asyncDispose'

/**
 * The global surface this prelude patches. `globalThis` in production; tests
 * pass a stub whose `Symbol` and `ReadableStream` lack the platform features.
 */
export interface JscCompatScope {
  readonly Symbol: SymbolConstructor
  readonly ReadableStream?: { readonly prototype: Record<PropertyKey, unknown> } | undefined
  readonly Promise?: PromiseWithResolversHost | undefined
  /** Node's `global` alias; absent in a Web Worker and in bare JavaScriptCore. */
  readonly global?: unknown
}

/** What one {@link installJscCompat} call had to add. */
export interface JscCompatReport {
  /** `Symbol.dispose` was absent and was installed. */
  readonly dispose: boolean
  /** `Symbol.asyncDispose` was absent and was installed. */
  readonly asyncDispose: boolean
  /** `ReadableStream.prototype.values` was absent and was installed. */
  readonly readableStreamValues: boolean
  /** `ReadableStream.prototype[Symbol.asyncIterator]` was absent and was installed. */
  readonly readableStreamAsyncIterator: boolean
  /** `Promise.withResolvers` was absent and was installed. */
  readonly promiseWithResolvers: boolean
  /** Node's `global` alias was absent and was installed. */
  readonly nodeGlobal: boolean
}

/**
 * Async iterator over a `ReadableStream`, mirroring the platform's
 * `%ReadableStreamAsyncIteratorPrototype%`.
 *
 * Web IDL's value asynchronous iterable declaration
 * (`async_iterable<any>`, [§ 3.7.10](https://webidl.spec.whatwg.org/#js-asynchronous-iterable))
 * builds **one** function object and installs
 * it twice: as the enumerable `values` data property and as the non-enumerable
 * `[Symbol.asyncIterator]` method, where `values` additionally accepts the
 * `ReadableStreamIteratorOptions` dictionary. Native engines have exactly that
 * shape — Node 22 has `ReadableStream.prototype[Symbol.asyncIterator] ===
 * ReadableStream.prototype.values`, both named `"values"` — so this definition
 * is installed under both keys as one function object rather than as a
 * `values()` that delegates to a differently-shaped `[Symbol.asyncIterator]`.
 * A `stream.values()` call and `for await (const chunk of stream)` therefore run
 * the same code, and `stream.values({ preventCancel: true })` cannot drift from
 * the plain iterator.
 *
 * The semantics follow the Streams Standard's "asynchronous iteration"
 * algorithms ([§ 4.2.5](https://streams.spec.whatwg.org/#rs-asynciterator)) —
 * what a native engine (Node 22, Chromium 124+) does —
 * because this definition lands on `ReadableStream.prototype` and every stream
 * in the Worker then iterates through it:
 *
 *  - `next()` settles one chunk. When the stream closes or errors, the read
 *    request's close/error steps release the reader, so `stream.locked` is
 *    `false` afterwards and the stream can be read again. A manual
 *    `getReader()` keeps its lock after `done` until `releaseLock()`; the async
 *    iterator does not.
 *  - `return(value)` cancels the stream with `value` as the reason and releases
 *    the reader immediately after starting the cancel (the platform does this
 *    synchronously, before the cancel settles). It resolves `{ done: true,
 *    value }` once the cancel settles; a failing cancel rejects the returned
 *    promise, but the lock is released either way. `for await` reaches this
 *    through `AsyncIteratorClose` when the loop body `break`s or throws.
 *  - `values({ preventCancel: true })` skips the cancel: the standard's
 *    asynchronous iterator return steps match "If iterator's prevent cancel is
 *    false: cancel … Return a promise resolved with undefined", so with
 *    `preventCancel` set `return()` (`break`) only releases the reader and the
 *    stream keeps its state and queued chunks, ready for another iterator. The
 *    option is read once, when the iterator is created; the default `false`
 *    preserves the cancel-on-`break` behaviour.
 *  - `return()` on an already-settled iterator does not cancel again.
 *  - `throw(error)` is a superset of the native async iterator (which has no
 *    `throw`). `fixtures/` relies on it; `for await`/`AsyncIteratorClose` never
 *    call it, so it does not affect protocol conformance. Because it is outside
 *    the protocol it always cancels with the error, releases the reader and
 *    rejects, even when the iterator was created with `preventCancel`.
 *  - `[Symbol.asyncIterator]()` returns the iterator itself, so an iterator is
 *    directly iterable (`for await (const chunk of iterator)`).
 * @returns The iterator object `for await` consumes.
 */
interface ReadableStreamAsyncIterator extends AsyncIterator<unknown> {
  [Symbol.asyncIterator](): ReadableStreamAsyncIterator
}

const readableStreamValues = function values(
  this: ReadableStream<unknown>,
  options: { readonly preventCancel?: boolean } = {},
): ReadableStreamAsyncIterator {
  // The dictionary member is read once, at iterator creation, and coerced to a
  // boolean like a Web IDL `boolean` (so `undefined`, `null` and a missing
  // argument all mean `false`).
  const preventCancel = Boolean(options?.preventCancel)
  const reader = this.getReader()
  let released = false

  /**
   * Release the reader at most once. A release the platform refuses (it throws
   * while a read is in flight) must never turn an iteration result into an
   * error; the protocol only calls us after reads settle, except for a
   * consumer that calls `return()` before its `next()` settles.
   */
  const release = (): void => {
    if (released) return
    released = true
    const releaseLock = (reader as { releaseLock?: () => void }).releaseLock
    if (typeof releaseLock !== 'function') return
    try {
      releaseLock.call(reader)
    } catch {
      // See above: keep the platform's lock rather than fail the iteration.
    }
  }

  const iterator: ReadableStreamAsyncIterator = {
    next(): Promise<IteratorResult<unknown>> {
      if (released) return Promise.resolve({ done: true, value: undefined })
      return reader.read().then(
        result => {
          if (result.done === true) {
            release()
            return { done: true, value: undefined }
          }
          return { done: false, value: result.value }
        },
        (error: unknown) => {
          // The read request's error steps release the reader before rejecting.
          release()
          throw error
        },
      )
    },
    return(value?: unknown): Promise<IteratorResult<unknown>> {
      if (released) return Promise.resolve({ done: true, value })
      if (preventCancel) {
        // The standard's return steps: "If iterator's prevent cancel is false"
        // cancel, then "Perform ! ReadableStreamDefaultReaderRelease(reader)"
        // and "Return a promise resolved with undefined". With the option set,
        // the release is all that happens, so the stream stays readable.
        release()
        return Promise.resolve({ done: true, value })
      }
      let cancelled: Promise<void>
      try {
        cancelled = reader.cancel(value)
      } catch (error) {
        // A reader that can no longer cancel must still give the lock back.
        release()
        return Promise.reject(error)
      }
      release()
      // Native `return()` settles with `{ done: true, value }` only after the
      // cancel settles, and rejects if the cancel rejects.
      return cancelled.then(() => ({ done: true, value }))
    },
    throw(error?: unknown): Promise<IteratorResult<unknown>> {
      if (released) return Promise.reject(error)
      let cancelled: Promise<void>
      try {
        cancelled = reader.cancel(error)
      } catch (failure) {
        release()
        return Promise.reject(failure)
      }
      release()
      // The iterator protocol never observes cancel failures here; rejecting
      // with the thrown error must not leave an unhandled rejection behind.
      cancelled.catch(() => {})
      return Promise.reject(error)
    },
    [Symbol.asyncIterator](): ReadableStreamAsyncIterator {
      return iterator
    },
  }

  return iterator
}

/**
 * Install the JavaScriptCore platform gaps that are still missing.
 *
 * Every definition is feature-detected; a second call on the same scope is a
 * no-op and returns `false` for each entry it previously installed.
 * @param scope - Global surface to patch; `globalThis` by default.
 * @returns Which definitions this call added.
 */
export function installJscCompat(
  scope: JscCompatScope = globalThis as unknown as JscCompatScope,
): JscCompatReport {
  let dispose = false
  let asyncDispose = false
  let readableStreamValuesInstalled = false
  let readableStreamAsyncIteratorInstalled = false
  let promiseWithResolversInstalled = false
  let nodeGlobal = false

  const symbol = scope.Symbol
  if (symbol !== undefined) {
    // `Symbol.for` registers the same keys the smoke prelude uses, so a DSH
    // module that looks the symbol up by key finds it as well.
    if (symbol.dispose === undefined) {
      Object.defineProperty(symbol, 'dispose', {
        value: Symbol.for(SYMBOL_DISPOSE_KEY),
        configurable: true,
      })
      dispose = true
    }
    if (symbol.asyncDispose === undefined) {
      Object.defineProperty(symbol, 'asyncDispose', {
        value: Symbol.for(SYMBOL_ASYNC_DISPOSE_KEY),
        configurable: true,
      })
      asyncDispose = true
    }
  }

  const stream: unknown = scope.ReadableStream
  const asyncIterator = (Symbol as { asyncIterator?: symbol }).asyncIterator
  if (typeof stream === 'function' && asyncIterator !== undefined) {
    const prototype = (stream as { prototype?: Record<PropertyKey, unknown> }).prototype
    if (prototype !== undefined) {
      const existingValues = prototype['values']
      const existingAsyncIterator = prototype[asyncIterator]
      const nativeValues = typeof existingValues === 'function' ? existingValues : undefined
      const nativeAsyncIterator = typeof existingAsyncIterator === 'function'
        ? existingAsyncIterator
        : undefined
      // Web IDL § 3.7.10 creates *one* function object and installs it under
      // both names. An engine that already has one of them gets the other as an
      // alias of it, never a second, differently-shaped implementation; a
      // Chromium-109 engine that has neither gets this shim's one function.
      if (nativeValues === undefined || nativeAsyncIterator === undefined) {
        const method = nativeValues ?? nativeAsyncIterator ?? readableStreamValues
        if (nativeValues === undefined) {
          // `values` is an enumerable data property (CreateDataPropertyOrThrow).
          Object.defineProperty(prototype, 'values', {
            value: method,
            configurable: true,
            writable: true,
            enumerable: true,
          })
          readableStreamValuesInstalled = true
        }
        if (nativeAsyncIterator === undefined) {
          // `@@asyncIterator` is a non-enumerable method property
          // (DefineMethodProperty(…, false)).
          Object.defineProperty(prototype, asyncIterator, {
            value: method,
            configurable: true,
            writable: true,
            enumerable: false,
          })
          readableStreamAsyncIteratorInstalled = true
        }
      }
    }
  }

  if (scope.Promise !== undefined) {
    promiseWithResolversInstalled = installPromiseWithResolvers(scope.Promise)
  }

  // Node defines `global` as the same object as `globalThis`; a Web Worker
  // equates it with neither. Install it only when absent, so Node keeps its
  // native property and a second call is a no-op.
  const nodeScope = scope as { global?: unknown }
  if (nodeScope.global === undefined) {
    Object.defineProperty(scope, 'global', {
      value: scope,
      configurable: true,
      writable: true,
    })
    nodeGlobal = true
  }

  return {
    dispose,
    asyncDispose,
    readableStreamValues: readableStreamValuesInstalled,
    readableStreamAsyncIterator: readableStreamAsyncIteratorInstalled,
    promiseWithResolvers: promiseWithResolversInstalled,
    nodeGlobal,
  }
}

/**
 * Import-time installation. The entry's first import is this module, so the
 * prelude is in place before any DSH code evaluates; importing it again from
 * another boot module is a no-op.
 */
export const jscCompat: JscCompatReport = installJscCompat()
