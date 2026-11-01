// SPDX-License-Identifier: MIT

const nativePrototypes = new Map<string, object>()
const nativeClearers = new Map<string, (handle: unknown) => void>()

type NativeTimer = {
  refresh?: () => void
  ref?: () => unknown
  unref?: () => unknown
  hasRef?: () => boolean
  [Symbol.toPrimitive]?: () => unknown
}

function unwrapTimer(handle: unknown): unknown {
  const toPrimitive = (handle as NativeTimer)?.[Symbol.toPrimitive]
  return typeof toPrimitive === 'function' ? toPrimitive.call(handle) : handle
}

function timerId(handle: unknown): unknown {
  const unwrapped = unwrapTimer(handle)
  if (typeof unwrapped !== 'object' || unwrapped === null) return unwrapped
  return unwrapTimer(unwrapped)
}

function clearTimer(scope: Record<string, unknown>, name: string, handle: unknown): void {
  const id = timerId(handle)
  const clear = name === 'setImmediate' && typeof id === 'number'
    ? nativeClearers.get('setTimeout') ?? nativeClearers.get(name)
    : nativeClearers.get(name)
  const fallback = clear ?? scope[`clear${name.slice(3)}`]
  if (typeof fallback === 'function') (fallback as (value: unknown) => void)(id)
}

/** Capture native handles before the runtime replaces the scheduler globals. */
export function captureNodeTimerPrototypes(): void {
  const scope = globalThis as Record<string, unknown>
  for (const name of ['setTimeout', 'setInterval', 'setImmediate']) {
    if (nativePrototypes.has(name)) continue
    const schedule = scope[name]
    if (typeof schedule !== 'function') continue
    const clear = scope[`clear${name.slice(3)}`]
    if (typeof clear === 'function' && !nativeClearers.has(name)) {
      nativeClearers.set(name, (clear as (value: unknown) => void).bind(globalThis))
    }
    const scheduled = (schedule as (handler: TimerHandler, timeout: number) => unknown)
      .call(globalThis, () => {}, 0)
    const candidate = unwrapTimer(scheduled)
    const nativeTimer = typeof candidate === 'object' && candidate !== null ? candidate : scheduled
    if (typeof nativeTimer === 'object' && nativeTimer !== null) nativePrototypes.set(name, nativeTimer)
    clearTimer(scope, name, candidate)
  }
}

/** Restore native timer handles after the runtime's numeric-ID timer shim. */
export function installNodeTimerCompat(): void {
  captureNodeTimerPrototypes()
  const scope = globalThis as Record<string, unknown>
  for (const name of ['setTimeout', 'setInterval', 'setImmediate']) {
    const schedule = scope[name]
    if (typeof schedule !== 'function') continue
    scope[`clear${name.slice(3)}`] = (handle: unknown): void => { clearTimer(scope, name, handle) }
    const bound = schedule.bind(globalThis) as (
      handler: TimerHandler, timeout?: number, ...args: unknown[]
    ) => unknown
    const prototype = nativePrototypes.get(name)
    if (prototype === undefined) continue
    scope[name] = (handler: TimerHandler, timeout?: number, ...args: unknown[]): unknown => {
      const handle = bound(handler, timeout, ...args)
      if (typeof handle !== 'object' || handle === null) return handle
      const candidate = unwrapTimer(handle)
      const nativeTimer = (typeof candidate === 'object' && candidate !== null ? candidate : handle) as NativeTimer
      const timer = handle as NativeTimer
      const id = timerId(handle)
      const { ref, unref, hasRef, refresh } = nativeTimer
      Object.setPrototypeOf(handle, prototype)
      Object.defineProperty(handle, Symbol.toPrimitive, { configurable: true, value: () => id })
      if (typeof ref === 'function') timer.ref = () => { ref.call(nativeTimer); return handle }
      if (typeof unref === 'function') timer.unref = () => { unref.call(nativeTimer); return handle }
      if (typeof hasRef === 'function') timer.hasRef = () => hasRef.call(nativeTimer)
      if (typeof refresh === 'function') timer.refresh = () => { refresh.call(nativeTimer) }
      return handle
    }
  }
}
