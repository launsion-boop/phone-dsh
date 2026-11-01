// SPDX-License-Identifier: MIT
/**
 * A promise with its settlement callbacks exposed, without
 * `Promise.withResolvers`.
 *
 * The shared Worker tree runs unchanged inside `com.huawei.webview`, whose
 * engine is pinned at roughly Chromium 99 / V8 9.9. `Promise.withResolvers`
 * shipped in Chromium 119 (ES2024), so on the phone it is `undefined` and
 * every process pump in this package (bridge handle, local child, just-bash
 * child) would throw `TypeError` before it registered its first waiter.
 *
 * This module is the package-local replacement rather than a cross-package
 * import: the packages in this tree are shipped independently and a new
 * inter-package dependency would have to be declared in `package.json` for a
 * twelve-line helper. It is intentionally not exported from the package
 * index; it is an implementation detail of the handles.
 *
 * The contract mirrors the TC39 record exactly: the promise exists before the
 * record is returned, `resolve` adopts a `T | PromiseLike<T>` like the native
 * method does (a `Promise` is never settled as a plain value), `reject`
 * accepts any reason, and the promise identity is stable so callers can race
 * or `.then` it more than once.
 * @module @phone-dsh/dsh-subprocess-xl/deferred
 */

/** The record `Promise.withResolvers<T>()` returns. */
export interface Deferred<T> {
  readonly promise: Promise<T>
  readonly resolve: (value: T | PromiseLike<T>) => void
  readonly reject: (reason?: unknown) => void
}

/** Build one deferred, settling through callbacks captured at construction. */
export function withResolvers<T>(): Deferred<T> {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((accept, refuse) => {
    resolve = accept
    reject = refuse
  })
  return { promise, resolve, reject }
}
