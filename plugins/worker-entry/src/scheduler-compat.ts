// SPDX-License-Identifier: MIT
/**
 * `scheduler.yield` prelude for engines that predate it.
 *
 * `dsh-api-session-controller` and `dsh-session-persistence-jsonl` call
 * `await scheduler.yield()` unguarded when a turn runs (it is how the session
 * controller hands the event loop back between steps). Chromium shipped
 * `scheduler.postTask` in 94 but `scheduler.yield` only in 129, so a
 * Chromium-109 kernel reaches the prompt and throws `scheduler is not defined`.
 *
 * The fallback uses `scheduler.postTask` with `user-blocking` priority when the
 * engine has it — that is the same queue `yield()` targets — and a macrotask
 * otherwise. Either way it yields to pending work before continuing, which is
 * the only property the callers rely on. Feature-detected and idempotent.
 * @module @phone-dsh/dsh-worker-entry/scheduler-compat
 */

/** The slice of the Scheduler API this prelude needs. */
export interface SchedulerLike {
  yield?: () => Promise<void>
  postTask?: (callback: () => void, options?: { priority?: string }) => Promise<unknown>
}

/** The global surface this prelude patches; `globalThis` in production. */
export interface SchedulerCompatScope {
  readonly scheduler?: SchedulerLike | undefined
  readonly setTimeout?: ((callback: () => void, delay?: number) => unknown) | undefined
}

/**
 * Yield to the event loop: a macrotask boundary.
 * @param scheduler - The engine's scheduler, when present.
 * @param setTimeoutFn - Macrotask fallback.
 * @returns A promise that settles after the yield.
 */
export function yieldToEventLoop(
  scheduler: SchedulerLike | undefined,
  setTimeoutFn: ((callback: () => void, delay?: number) => unknown) | undefined,
): Promise<void> {
  if (typeof scheduler?.postTask === 'function') {
    return scheduler.postTask(() => {}, { priority: 'user-blocking' }).then(() => {})
  }
  if (typeof setTimeoutFn === 'function') {
    return new Promise<void>(resolve => {
      setTimeoutFn(() => {
        resolve()
      }, 0)
    })
  }
  return Promise.resolve()
}

/**
 * Install `scheduler.yield` when the engine lacks it.
 * @param scope - Global surface to patch; `globalThis` by default.
 * @returns `true` when this call installed the method.
 */
export function installSchedulerYield(
  scope: SchedulerCompatScope = globalThis as unknown as SchedulerCompatScope,
): boolean {
  // Chromium has `scheduler` since 94, so the object usually exists and only
  // the method is missing; a bare JavaScriptCore has neither.
  const existing = scope.scheduler
  if (existing === undefined) {
    if (scope.setTimeout === undefined) return false
    const created: SchedulerLike = {}
    Object.defineProperty(scope, 'scheduler', { configurable: true, writable: true, value: created })
    Object.defineProperty(created, 'yield', {
      configurable: true,
      writable: true,
      value: function yieldPromise(): Promise<void> {
        return yieldToEventLoop(undefined, scope.setTimeout)
      },
    })
    return true
  }
  if (typeof existing.yield === 'function') return false
  Object.defineProperty(existing, 'yield', {
    configurable: true,
    writable: true,
    value: function yieldPromise(): Promise<void> {
      return yieldToEventLoop(existing, scope.setTimeout)
    },
  })
  return true
}

/**
 * Import-time installation. `boot.ts` and `entry.ts` import this module beside
 * the other preludes, so the method exists before any DSH module evaluates.
 */
export const schedulerYield: boolean = installSchedulerYield()
