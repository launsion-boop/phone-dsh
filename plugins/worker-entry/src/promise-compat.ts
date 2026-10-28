// SPDX-License-Identifier: MIT
/**
 * Minimal `Promise.withResolvers` compatibility for the iOS 17 deployment
 * floor.
 *
 * WebKit only shipped `Promise.withResolvers` in Safari 17.4. The project
 * supports iOS 17.0, and both page code and the Worker's pinned runtime call
 * it during boot (the boot-readiness gate is the first one), so the missing
 * method is installed before the first boot module awaits. The installation is
 * feature-detected and idempotent; modern engines keep their native method.
 *
 * This module deliberately implements only the standard shape
 * (`{promise, resolve, reject}`): it adds no policy, state or persistence.
 * @module @phone-dsh/dsh-worker-entry/promise-compat
 */

/** The mutable slice of a `Promise` constructor this prelude needs. */
export interface PromiseWithResolversHost {
  withResolvers?: <T>() => PromiseWithResolvers<T>
}

/** Build one deferred with the standard resolve/reject wiring. */
function makeResolvers<T>(): PromiseWithResolvers<T> {
  let resolve!: (value: T | PromiseLike<T>) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((settle, fail) => {
    resolve = settle
    reject = fail
  })
  return { promise, resolve, reject }
}

/**
 * Return the platform `Promise.withResolvers` when present, otherwise the
 * minimal fallback.
 *
 * The optional host exists so tests can exercise the missing-method path
 * without replacing the process-wide `Promise` constructor.
 * @param host - Constructor face to inspect; `Promise` by default.
 * @returns A deferred for `T`.
 */
export function promiseWithResolvers<T>(
  host: PromiseWithResolversHost = Promise as unknown as PromiseWithResolversHost,
): PromiseWithResolvers<T> {
  const native = host.withResolvers
  if (typeof native === 'function') {
    return (native as <U>() => PromiseWithResolvers<U>).call(host) as PromiseWithResolvers<T>
  }
  return makeResolvers<T>()
}

/**
 * Install the fallback on `host` when the method is absent.
 * @param host - Constructor face to patch; `Promise` by default.
 * @returns `true` when this call added the method.
 */
export function installPromiseWithResolvers(
  host: PromiseWithResolversHost = Promise as unknown as PromiseWithResolversHost,
): boolean {
  if (typeof host.withResolvers === 'function') return false
  Object.defineProperty(host, 'withResolvers', {
    configurable: true,
    writable: true,
    value: function withResolvers<T>(): PromiseWithResolvers<T> {
      return makeResolvers<T>()
    },
  })
  return true
}
