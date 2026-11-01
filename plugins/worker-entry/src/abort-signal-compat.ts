// SPDX-License-Identifier: MIT
/**
 * `AbortSignal.any` prelude for engines that predate it.
 *
 * The Worker's HTTP and model paths compose cancellation with
 * `AbortSignal.any([...])` (undici's fetch plumbing and DSH's transport both
 * do). It became available in Chromium 116 / Safari 17.4, so a Chromium-109
 * kernel throws `AbortSignal.any is not a function` on the first prompt:
 * measured 2026-11-01 on the `android-33` image (WebView 109.0.5414.123),
 * `session/create` succeeds and `session/prompt` fails with exactly that
 * message.
 *
 * The fallback mirrors the specification: it aborts as soon as any input
 * aborts, carries the first input's `reason`, is already aborted when any input
 * is, and removes its listeners once it has fired. Feature-detected and
 * idempotent.
 * @module @phone-dsh/dsh-worker-entry/abort-signal-compat
 */

/** The slice of `AbortSignal` this prelude needs. */
export interface AbortSignalLike {
  readonly aborted: boolean
  readonly reason?: unknown
  addEventListener(type: 'abort', listener: () => void, options?: { once?: boolean }): void
  removeEventListener(type: 'abort', listener: () => void): void
}

/** The slice of `AbortController` this prelude needs. */
export interface AbortControllerLike {
  readonly signal: AbortSignalLike
  abort(reason?: unknown): void
}

/** The global surface this prelude patches; `globalThis` in production. */
export interface AbortSignalCompatScope {
  readonly AbortSignal?:
    | { readonly any?: unknown; prototype?: unknown }
    | undefined
  readonly AbortController?: (new () => AbortControllerLike) | undefined
}

/**
 * Compose abort signals the way `AbortSignal.any` does.
 * @param signals - Inputs; an empty list never aborts.
 * @param Controller - Constructor used for the derived signal.
 * @returns The derived signal.
 */
export function anySignal(
  signals: Iterable<AbortSignalLike>,
  Controller: new () => AbortControllerLike,
): AbortSignalLike {
  const controller = new Controller()
  const inputs = Array.from(signals)
  const already = inputs.find(signal => signal.aborted)
  if (already !== undefined) {
    controller.abort(already.reason)
    return controller.signal
  }
  const onAbort = (): void => {
    const source = inputs.find(signal => signal.aborted)
    for (const signal of inputs) signal.removeEventListener('abort', onAbort)
    controller.abort(source?.reason)
  }
  for (const signal of inputs) signal.addEventListener('abort', onAbort, { once: true })
  return controller.signal
}

/**
 * Install `AbortSignal.any` when the engine lacks it.
 * @param scope - Global surface to patch; `globalThis` by default.
 * @returns `true` when this call installed the method.
 */
export function installAbortSignalAny(
  scope: AbortSignalCompatScope = globalThis as unknown as AbortSignalCompatScope,
): boolean {
  const signal = scope.AbortSignal
  const controller = scope.AbortController
  if (signal === undefined || controller === undefined) return false
  if (typeof signal.any === 'function') return false
  Object.defineProperty(signal, 'any', {
    configurable: true,
    writable: true,
    value: function any(inputs: Iterable<AbortSignalLike>): AbortSignalLike {
      return anySignal(inputs, controller)
    },
  })
  return true
}

/**
 * Import-time installation. `boot.ts` and `entry.ts` import this module beside
 * the other preludes, so the method exists before any DSH module evaluates.
 */
export const abortSignalAny: boolean = installAbortSignalAny()
