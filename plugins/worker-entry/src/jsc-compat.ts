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
 *  - async iteration over `ReadableStream`, which the DeepSeek adapter uses to
 *    read SSE (`for await (const frame of events)`), so every model request
 *    otherwise fails as a TRANSPORT error, and
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
  /** `ReadableStream.prototype[Symbol.asyncIterator]` was absent and was installed. */
  readonly readableStreamAsyncIterator: boolean
  /** `Promise.withResolvers` was absent and was installed. */
  readonly promiseWithResolvers: boolean
  /** Node's `global` alias was absent and was installed. */
  readonly nodeGlobal: boolean
}

/**
 * Async iterator over a `ReadableStream`, ported from the macOS smoke prelude.
 *
 * `next()` awaits one chunk, `return()` cancels the reader and settles done,
 * and `throw()` cancels with the error and rejects.
 * @returns The iterator object `for await` consumes.
 */
function readableStreamAsyncIterator(this: ReadableStream<unknown>): AsyncIterator<unknown> {
  const reader = this.getReader()
  return {
    next(): Promise<IteratorResult<unknown>> {
      return reader.read().then(result => result.done === true
        ? { done: true, value: undefined }
        : { done: false, value: result.value })
    },
    return(): Promise<IteratorResult<unknown>> {
      reader.cancel().catch(() => {})
      return Promise.resolve({ done: true, value: undefined })
    },
    throw(error?: unknown): Promise<IteratorResult<unknown>> {
      reader.cancel(error).catch(() => {})
      return Promise.reject(error)
    },
  }
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
    if (prototype !== undefined && typeof prototype[asyncIterator] !== 'function') {
      Object.defineProperty(prototype, asyncIterator, {
        value: readableStreamAsyncIterator,
        configurable: true,
        writable: true,
      })
      readableStreamAsyncIteratorInstalled = true
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
