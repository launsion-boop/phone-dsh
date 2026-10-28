// SPDX-License-Identifier: MIT
/**
 * A global surface without the two platform features JavaScriptCore lacks:
 * `Symbol.dispose` / `Symbol.asyncDispose` and
 * `ReadableStream.prototype[Symbol.asyncIterator]`.
 *
 * Shared by `jsc-compat.test.ts` (a fake scope) and the child process that
 * imports the Worker entry under the stub (`fixtures/jsc-stub-entry.ts`).
 * Everything else is copied from the real `Symbol`, so Node's module loader
 * and the entry's imports keep working after the swap.
 * @module @phone-dsh/dsh-worker-entry/fixtures/jsc-stub-globals
 */

/** Reader face the prelude's async iterator uses. */
export interface StubStreamReader {
  read(): Promise<IteratorResult<unknown>>
  cancel(reason?: unknown): Promise<void>
}

/** Stream instance the prelude reads. */
export interface StubReadableStreamInstance {
  getReader(): StubStreamReader
}

/** Constructor face of the stub. */
export type StubReadableStreamConstructor =
  (new (chunks: readonly unknown[]) => StubReadableStreamInstance) & {
    readonly prototype: Record<PropertyKey, unknown>
  }

/** `ReadableStream` stand-in: `getReader()` only, no async iteration. */
export class StubReadableStream implements StubReadableStreamInstance {
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

/**
 * Build a `Symbol` constructor that lacks the two explicit-resource-management
 * symbols but keeps every other static (notably `for`, `keyFor` and
 * `asyncIterator`) and the real prototype.
 * @returns The stub constructor.
 */
export function createStubSymbol(): SymbolConstructor {
  const real = Symbol
  const stub = function Symbol(description?: string): symbol {
    return real(description)
  } as unknown as SymbolConstructor & { prototype: object }
  for (const key of Reflect.ownKeys(real)) {
    if (key === 'dispose' || key === 'asyncDispose' || key === 'prototype' || key === 'length' || key === 'name') continue
    const descriptor = Object.getOwnPropertyDescriptor(real, key)
    if (descriptor !== undefined) Object.defineProperty(stub, key, descriptor)
  }
  stub.prototype = real.prototype
  return stub
}

/**
 * Replace the process-wide `Symbol` and `ReadableStream` with the stubs.
 * Call before importing a module whose first import must install the prelude.
 * @returns The installed constructors.
 */
export function installStubPlatform(): {
  symbol: SymbolConstructor
  readableStream: StubReadableStreamConstructor
} {
  const symbol = createStubSymbol()
  const readableStream = StubReadableStream as unknown as StubReadableStreamConstructor
  Object.defineProperty(globalThis, 'Symbol', { value: symbol, configurable: true, writable: true })
  Object.defineProperty(globalThis, 'ReadableStream', { value: readableStream, configurable: true, writable: true })
  return { symbol, readableStream }
}
