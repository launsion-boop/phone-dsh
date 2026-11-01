// SPDX-License-Identifier: MIT
/**
 * A promise with its settlement callbacks exposed, without
 * `Promise.withResolvers`.
 *
 * The journal runs inside the same shared Worker tree as the rest of the
 * plugin set, and the phone image pins `com.huawei.webview` at roughly
 * Chromium 99 / V8 9.9. `Promise.withResolvers` shipped in Chromium 119
 * (ES2024), so the abort race in this package would throw `TypeError` on the
 * phone exactly when a tool call is being cancelled — the journal's most
 * fragile path.
 *
 * The module is package-local on purpose: these packages ship independently
 * and a new declared dependency for a twelve-line helper is not worth the
 * manifest churn. It is not re-exported from the package index.
 *
 * The contract mirrors the TC39 record: the promise exists before the record
 * is returned, `resolve` adopts a `T | PromiseLike<T>`, `reject` accepts any
 * reason, and every caller sees the same promise instance.
 * @module @phone-dsh/dsh-tool-journal/deferred
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
