// SPDX-License-Identifier: MIT
/**
 * Isolate-only `node:vm` face backed by an embedded QuickJS/WASM realm.
 *
 * The official workflow runtime (and only the official runtime) runs in the
 * workflow Worker's own JavaScript realm. The user's workflow script does
 * **not**: `Script.runInContext` evaluates it inside a fresh QuickJS runtime
 * whose only host bindings are the `agent`/`parallel`/`pipeline`/`phase`/`log`
 * hooks installed by the official `WorkflowExecution`. QuickJS has no DOM,
 * Worker, fetch, EventSource, WebTransport, process, filesystem, module loader
 * or dynamic `import()`, so `({}).constructor.constructor(...)` can only reach
 * that guest global.
 *
 * The QuickJS runtime is created per workflow run and discarded afterwards.
 * Its interrupt handler enforces the official synchronous/activity budget, so
 * a guest `while (true) {}` stops inside QuickJS instead of relying only on the
 * parent worker watchdog.
 *
 * This module is bundled only into `workflow-isolate.js`; it is never loaded by
 * the DSH Worker or the image module loader.
 * @module @phone-dsh/dsh-workflow-worker/quickjs-vm
 */

import type {
  QuickJSContext, QuickJSDeferredPromise, QuickJSHandle, QuickJSWASMModule,
} from 'quickjs-emscripten'
import type { QuickJSRuntime } from 'quickjs-emscripten'
import { WorkflowBudgetError } from './budget-error.ts'

/** Marker included in the isolate bundle to prove the realm is reachable. */
export const QUICKJS_REALM_MARKER = 'pdsh-quickjs-workflow-realm-v1'

/** A host-side deferred that does not require `Promise.withResolvers`. */
interface Deferred<T> {
  readonly promise: Promise<T>
  readonly resolve: (value: T) => void
  readonly reject: (reason: unknown) => void
}

/** Create one deferred. */
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
  return { promise, resolve, reject }
}

/** The module instance, loaded once per isolate. */
let quickjs: Promise<QuickJSWASMModule> | undefined

/**
 * Load and instantiate the embedded QuickJS WASM module.
 *
 * The WASM bytes are bundled by `worker-entry/build.mjs` (esbuild `binary`
 * loader); nothing is fetched at runtime, so the isolate works from the same
 * app-bundle origin as `worker-isolate.js`.
 * @returns the ready module.
 */
export async function prepareQuickJs(): Promise<QuickJSWASMModule> {
  quickjs ??= (async () => {
    const { RELEASE_SYNC, newQuickJSWASMModuleFromVariant, newVariant } = await import('quickjs-emscripten')
    const { default: wasmBytes } = await import('@jitl/quickjs-wasmfile-release-sync/wasm')
    const wasmBinary = wasmBytes.buffer.slice(
      wasmBytes.byteOffset,
      wasmBytes.byteOffset + wasmBytes.byteLength,
    ) as ArrayBuffer
    return await newQuickJSWASMModuleFromVariant(newVariant(RELEASE_SYNC, { wasmBinary }))
  })()
  return await quickjs
}

/** Listener invoked whenever guest execution yields back to the host. */
let activityListener: (() => void) | undefined

/**
 * Install the per-run progress listener. The isolate forwards each yield as a
 * `sync-yield` message so the parent re-arms its activity watchdog.
 * @param listener - callback, or undefined to clear.
 */
export function setQuickJsActivityListener(listener: (() => void) | undefined): void {
  activityListener = listener
}

/** Report one guest-to-host yield. */
function activity(): void {
  try {
    activityListener?.()
  } catch {
    // A broken listener must not corrupt guest state; the parent watchdog is
    // the second line of defence.
  }
}

/** Hidden property carrying a host error id across the QuickJS boundary. */
const HOST_ERROR_KEY = `__pdsh_host_error_${Math.random().toString(36).slice(2)}_${Date.now().toString(36)}`

/** Contexts created by this shim, so `isContext` does not trust a bare object. */
const contexts = new WeakSet<object>()

/** Structural `node:vm` context options the official runtime passes. */
export interface ScriptOptions {
  readonly filename?: string
  readonly lineOffset?: number
  readonly columnOffset?: number
  readonly displayErrors?: boolean
}

/** Runtime options `runInContext` accepts from the official runtime. */
export interface RunOptions {
  readonly timeout?: number
  readonly breakOnSigint?: boolean
}

/** One guest realm + the host bridge for one script run. */
class Realm {
  private readonly vm: QuickJSContext
  private readonly runtime: QuickJSRuntime
  private readonly sliceMs: number
  private readonly errors = new Map<number, unknown>()
  private nextErrorId = 1
  private deadline = 0
  /** Set only by the QuickJS interrupt callback, never by guest error text. */
  private interrupted = false
  private fault: unknown
  private readonly pendingRejects = new Set<(error: unknown) => void>()
  private readonly heldFunctions = new Set<QuickJSHandle>()
  private readonly pendingPromises = new Set<QuickJSDeferredPromise>()
  private disposed = false
  private readonly helpers: {
    readonly isArray: QuickJSHandle
    readonly keys: QuickJSHandle
    readonly symbols: QuickJSHandle
    readonly proto: QuickJSHandle
    readonly has: QuickJSHandle
  }
  private readonly then: QuickJSHandle
  private readonly errorKeyValue: QuickJSHandle

  constructor(module: QuickJSWASMModule, timeout: number | undefined) {
    this.vm = module.newContext()
    this.runtime = this.vm.runtime
    this.sliceMs = timeout !== undefined && Number.isFinite(timeout) && timeout > 0 ? timeout : 5000
    // 64 MiB is far above any workflow's JSON payload but below a WASM OOM.
    this.runtime.setMemoryLimit(64 * 1024 * 1024)
    this.runtime.setMaxStackSize(1024 * 1024)
    this.runtime.setInterruptHandler(() => {
      const expired = this.deadline !== 0 && Date.now() > this.deadline
      if (expired) this.interrupted = true
      return expired
    })

    const helperSource = `({
      isArray: Array.isArray,
      keys: Object.keys,
      symbols: Object.getOwnPropertySymbols,
      proto: Object.getPrototypeOf,
      has: function (object, key) { return key in object },
    })`
    const helpersResult = this.vm.evalCode(helperSource, 'pdsh-helpers.js')
    if (helpersResult.error) {
      const error = this.errorToHost(helpersResult.error)
      helpersResult.error.dispose()
      this.dispose()
      throw error
    }
    const helpers = helpersResult.value
    const helper = (name: string): QuickJSHandle => this.vm.getProp(helpers, name)
    this.helpers = {
      isArray: helper('isArray'),
      keys: helper('keys'),
      symbols: helper('symbols'),
      proto: helper('proto'),
      has: helper('has'),
    }
    helpers.dispose()
    // Capture the intrinsics before user code can replace them.
    const promise = this.vm.getProp(this.vm.global, 'Promise')
    const prototype = this.vm.getProp(promise, 'prototype')
    this.then = this.vm.getProp(prototype, 'then')
    prototype.dispose()
    promise.dispose()
    this.errorKeyValue = this.vm.newString(HOST_ERROR_KEY)
  }

  /** Arm the interrupt deadline for one synchronous slice. */
  private arm(): void {
    this.deadline = Date.now() + this.sliceMs
  }

  /** Dispose a handle unless it is one of QuickJS's shared static values. */
  private disposeHandle(handle: QuickJSHandle | undefined): void {
    if (handle === undefined || !handle.alive) return
    if (handle === this.vm.undefined || handle === this.vm.null) return
    if (handle === this.vm.true || handle === this.vm.false) return
    handle.dispose()
  }

  /** The realm's own hard-stop diagnostic for an over-budget synchronous slice. */
  private budgetError(): Error {
    return new WorkflowBudgetError(this.sliceMs, 'by the isolated realm')
  }

  /** Map only a genuine QuickJS interrupt to the stable deadline diagnostic. */
  private mapInterrupt(error: unknown): unknown {
    // QuickJS throws `InternalError: interrupted` when the interrupt callback
    // fires. Its text is not an identity: guest code can throw an error with the
    // same name or message. The callback's own flag is the only trustworthy
    // signal, so a guest-forged sentinel keeps its original identity.
    if (this.interrupted) {
      const budget = this.budgetError()
      // An interrupt terminates the run even if orchestration code catches the
      // thrown value: QuickJS's deadline is not an ordinary per-item failure.
      this.fault ??= budget
      return budget
    }
    return error
  }

  /** Execute pending guest jobs, converting a guest fault to a host throw. */
  private pump(): void {
    if (this.fault !== undefined) throw this.fault
    this.arm()
    let executed = 0
    try {
      for (;;) {
        const result = this.runtime.executePendingJobs(256)
        if (result.error) {
          const error = this.mapInterrupt(this.errorToHost(result.error))
          result.error.dispose()
          throw error
        }
        const count = result.value
        result.dispose()
        if (count === 0) break
        executed += count
      }
    } catch (error: unknown) {
      this.deadline = 0
      this.fault = error
      for (const reject of this.pendingRejects) reject(error)
      this.pendingRejects.clear()
      throw error
    }
    this.deadline = 0
    if (executed > 0) activity()
  }

  /** Schedule a pump after a host promise settles (never inside a C callback). */
  private schedulePump(): void {
    setTimeout(() => {
      if (this.disposed) return
      try {
        this.pump()
      } catch {
        // The fault has already been delivered to every pending waiter.
      }
    }, 0)
  }

  /** Convert a QuickJS value into plain host data for the official runtime. */
  private toHost(handle: QuickJSHandle, seen: { handle: QuickJSHandle; value: object }[] = []): unknown {
    const type = this.vm.typeof(handle)
    switch (type) {
      case 'undefined':
        return undefined
      case 'boolean':
        return this.vm.dump(handle) === true
      case 'number':
        return this.vm.getNumber(handle)
      case 'string':
        return this.vm.getString(handle)
      case 'bigint':
        return this.vm.getBigInt(handle)
      case 'symbol':
        return this.vm.getSymbol(handle)
      case 'function': {
        // Keep the guest function alive for the run and expose a host closure
        // the official parallel()/pipeline() implementations can call.
        const held = handle.dup()
        this.heldFunctions.add(held)
        return (...args: unknown[]) => this.callGuest(held, args)
      }
      case 'object':
        break
      default:
        return undefined
    }
    if (this.vm.eq(handle, this.vm.null)) return null
    for (const known of seen) {
      if (this.vm.eq(known.handle, handle)) return known.value
    }
    if (this.callHelperBoolean(this.helpers.isArray, handle)) {
      const length = this.vm.getLength(handle) ?? 0
      const out: unknown[] = new Array(length)
      const record = { handle: handle.dup(), value: out }
      seen.push(record)
      try {
        for (let index = 0; index < length; index++) {
          const indexHandle = this.vm.newNumber(index)
          let present: boolean
          try {
            present = this.callHelperBoolean(this.helpers.has, handle, indexHandle)
          } finally {
            indexHandle.dispose()
          }
          if (!present) {
            // Preserve the hole so the official materializer rejects it.
            continue
          }
          const value = this.vm.getProp(handle, index)
          try {
            out[index] = this.toHost(value, seen)
          } finally {
            value.dispose()
          }
        }
        const keys = this.callHelperArray(this.helpers.keys, handle)
        for (const key of keys) {
          const numeric = Number(key)
          if (Number.isInteger(numeric) && numeric >= 0 && numeric < length) continue
          // A non-index enumerable property must survive to be rejected.
          const value = this.vm.getProp(handle, key)
          try {
            // defineProperty, not assignment: a "__proto__" key must stay an
            // own property so the official materializer rejects it.
            Object.defineProperty(out, key, {
              value: this.toHost(value, seen),
              enumerable: true,
              writable: true,
              configurable: true,
            })
          } finally {
            value.dispose()
          }
        }
        const symbols = this.callHelperSymbols(this.helpers.symbols, handle)
        if (symbols.length > 0) {
          Object.defineProperty(out, symbols[0] as symbol, { value: 1, enumerable: false })
        }
      } finally {
        record.handle.dispose()
        seen.pop()
      }
      return out
    }
    const prototype = this.vm.callFunction(this.helpers.proto, this.vm.undefined, handle)
    if (prototype.error) {
      const error = this.errorToHost(prototype.error)
      prototype.error.dispose()
      throw error
    }
    const proto = prototype.value
    let plain: boolean
    if (this.vm.eq(proto, this.vm.null)) {
      plain = true
    } else {
      const grand = this.vm.callFunction(this.helpers.proto, this.vm.undefined, proto)
      plain = !grand.error && this.vm.eq(grand.value, this.vm.null)
      if (!grand.error) grand.value.dispose()
      else grand.error.dispose()
    }
    proto.dispose()
    // A non-plain guest object (Date, Map, class instance) is represented by a
    // host object with an exotic prototype so the official materializer rejects
    // it instead of silently flattening it.
    const out: Record<string, unknown> = plain ? {} : Object.create({ pdsh: 'exotic guest value' })
    const record = { handle: handle.dup(), value: out }
    seen.push(record)
    try {
      const keys = this.callHelperArray(this.helpers.keys, handle)
      for (const key of keys) {
        const value = this.vm.getProp(handle, key)
        try {
          Object.defineProperty(out, key, {
            value: this.toHost(value, seen),
            enumerable: true,
            writable: true,
            configurable: true,
          })
        } finally {
          value.dispose()
        }
      }
      const symbols = this.callHelperSymbols(this.helpers.symbols, handle)
      if (symbols.length > 0) {
        Object.defineProperty(out, symbols[0] as symbol, { value: 1, enumerable: false })
      }
    } finally {
      record.handle.dispose()
      seen.pop()
    }
    return out
  }

  /** Call one guest helper with no arguments and read a boolean. */
  private callHelperBoolean(helper: QuickJSHandle, ...args: QuickJSHandle[]): boolean {
    const result = this.vm.callFunction(helper, this.vm.undefined, args)
    if (result.error) {
      const error = this.errorToHost(result.error)
      result.error.dispose()
      throw error
    }
    const value = this.vm.dump(result.value) === true
    result.value.dispose()
    return value
  }

  /** Call one guest helper and materialize a string array. */
  private callHelperArray(helper: QuickJSHandle, handle: QuickJSHandle): string[] {
    const result = this.vm.callFunction(helper, this.vm.undefined, handle)
    if (result.error) {
      const error = this.errorToHost(result.error)
      result.error.dispose()
      throw error
    }
    const length = this.vm.getLength(result.value) ?? 0
    const out: string[] = []
    for (let index = 0; index < length; index++) {
      const item = this.vm.getProp(result.value, index)
      out.push(this.vm.getString(item))
      item.dispose()
    }
    result.value.dispose()
    return out
  }

  /** Call one guest helper and materialize a symbol array. */
  private callHelperSymbols(helper: QuickJSHandle, handle: QuickJSHandle): symbol[] {
    const result = this.vm.callFunction(helper, this.vm.undefined, handle)
    if (result.error) {
      const error = this.errorToHost(result.error)
      result.error.dispose()
      throw error
    }
    const length = this.vm.getLength(result.value) ?? 0
    const out: symbol[] = []
    for (let index = 0; index < length; index++) {
      const item = this.vm.getProp(result.value, index)
      out.push(this.vm.getSymbol(item))
      item.dispose()
    }
    result.value.dispose()
    return out
  }

  /** Convert one host value, disposing intermediate cycle-anchor handles. */
  private toGuestRoot(value: unknown): QuickJSHandle {
    const seen = new Map<unknown, QuickJSHandle>()
    const handle = this.toGuest(value, seen)
    for (const anchor of seen.values()) this.disposeHandle(anchor)
    return handle
  }

  /** Convert a host value into one guest value. */
  private toGuest(value: unknown, seen = new Map<unknown, QuickJSHandle>()): QuickJSHandle {
    if (value === undefined) return this.vm.undefined
    if (value === null) return this.vm.null
    switch (typeof value) {
      case 'string':
        return this.vm.newString(value)
      case 'number':
        return this.vm.newNumber(value)
      case 'boolean':
        return value ? this.vm.true : this.vm.false
      case 'bigint':
        return this.vm.newBigInt(value)
      case 'symbol':
        return this.vm.newSymbolFor(value)
      case 'function':
        // Data crossing into the guest is JSON; a function here is unsupported
        // data, represented by a function the guest can see and the official
        // materializer later rejects.
        return this.vm.newFunction('unsupportedHostFunction', () => this.vm.undefined)
      case 'object':
        break
    }
    const existing = seen.get(value)
    if (existing !== undefined) return existing.dup()
    if (Array.isArray(value)) {
      const array = this.vm.newArray()
      seen.set(value, array)
      for (let index = 0; index < value.length; index++) {
        const item = this.toGuest(value[index], seen)
        this.vm.setProp(array, index, item)
        this.disposeHandle(item)
      }
      return array.dup()
    }
    const object = this.vm.newObject()
    seen.set(value, object)
    for (const [key, item] of Object.entries(value)) {
      const guest = this.toGuest(item, seen)
      this.vm.defineProp(object, key, { value: guest, enumerable: true, configurable: true })
      this.disposeHandle(guest)
    }
    return object.dup()
  }

  /** Build a guest Error carrying a host-error id. */
  private errorToGuest(error: unknown): QuickJSHandle {
    const id = this.nextErrorId++
    this.errors.set(id, error)
    const name = error instanceof Error ? error.name : 'Error'
    const message = error instanceof Error ? error.message : String(error)
    const handle = this.vm.newError({ name, message })
    const idHandle = this.vm.newNumber(id)
    this.vm.defineProp(handle, HOST_ERROR_KEY, {
      value: idHandle,
      enumerable: false,
      configurable: false,
    })
    idHandle.dispose()
    return handle
  }

  /** Map a guest thrown value back to its original host error when tagged. */
  private errorToHost(handle: QuickJSHandle): unknown {
    if (this.vm.typeof(handle) === 'object' && !this.vm.eq(handle, this.vm.null)) {
      const tag = this.vm.getProp(handle, this.errorKeyValue)
      if (this.vm.typeof(tag) === 'number') {
        const id = this.vm.getNumber(tag)
        tag.dispose()
        const original = this.errors.get(id)
        if (original !== undefined) return original
      } else {
        tag.dispose()
      }
    }
    if (this.vm.typeof(handle) === 'object' && !this.vm.eq(handle, this.vm.null)) {
      const name = this.readStringProperty(handle, 'name')
      const message = this.readStringProperty(handle, 'message')
      if (message !== undefined) {
        const error = new Error(message)
        if (name !== undefined) error.name = name
        const stack = this.readStringProperty(handle, 'stack')
        if (stack !== undefined && stack !== '') {
          // QuickJS's stack is a frame list; the official runtime renders the
          // stack first, so prepend the name/message it is missing. Never let an
          // engine's frame-only form replace a real message.
          const header = `${name ?? 'Error'}: ${message}`
          error.stack = stack.startsWith(header) ? stack : `${header}\n${stack}`
        }
        return error
      }
    }
    return this.toHost(handle)
  }

  /** Read a string property without letting a throwing getter escape. */
  private readStringProperty(handle: QuickJSHandle, key: string): string | undefined {
    try {
      const value = this.vm.getProp(handle, key)
      try {
        return this.vm.typeof(value) === 'string' ? this.vm.getString(value) : undefined
      } finally {
        value.dispose()
      }
    } catch {
      return undefined
    }
  }

  /** Call one guest function from host code and await its result. */
  private async callGuest(fn: QuickJSHandle, args: readonly unknown[]): Promise<unknown> {
    if (!fn.alive) throw new Error('workflow guest function is no longer available')
    if (this.fault !== undefined) throw this.fault
    const guestArgs = args.map(arg => this.toGuestRoot(arg))
    try {
      // A thunk called by the host is still guest computation. Arm before the
      // call and tell the parent it resumed, so neither deadline can be left
      // disarmed by a preceding host wait.
      this.arm()
      activity()
      const result = this.vm.callFunction(fn, this.vm.undefined, guestArgs)
      if (result.error) {
        const error = this.mapInterrupt(this.errorToHost(result.error))
        result.error.dispose()
        throw error
      }
      return await this.awaitGuest(result.value)
    } finally {
      for (const arg of guestArgs) this.disposeHandle(arg)
    }
  }

  /** Await a guest value that may or may not be a promise. */
  private async awaitGuest(handle: QuickJSHandle): Promise<unknown> {
    // Materializing a value can run guest getters and proxies; keep the
    // deadline armed for every path that executes guest code.
    this.arm()
    const state = this.vm.getPromiseState(handle)
    if (state.type === 'fulfilled') {
      try {
        if (state.value === handle && state.notAPromise === true) {
          // `getPromiseState` returns the same handle for non-promises; it is
          // owned by the caller, so convert without disposing it here.
          return this.toHost(handle)
        }
        try {
          return this.toHost(state.value)
        } finally {
          this.disposeHandle(state.value)
        }
      } finally {
        this.deadline = 0
      }
    }
    if (state.type === 'rejected') {
      try {
        throw this.mapInterrupt(this.errorToHost(state.error))
      } finally {
        this.disposeHandle(state.error)
        this.deadline = 0
      }
    }
    return await new Promise<unknown>((resolve, reject) => {
      const settle = (): void => { this.pendingRejects.delete(reject) }
      this.pendingRejects.add(reject)
      const onValue = this.vm.newFunction('pdshResolve', (value) => {
        settle()
        try {
          resolve(this.toHost(value))
        } catch (error: unknown) {
          reject(error)
        }
      })
      const onError = this.vm.newFunction('pdshReject', (error) => {
        settle()
        reject(this.mapInterrupt(this.errorToHost(error)))
      })
      try {
        this.arm()
        const result = this.vm.callFunction(this.then, handle, onValue, onError)
        if (result.error) {
          const error = this.errorToHost(result.error)
          result.error.dispose()
          settle()
          reject(error)
        } else {
          result.value.dispose()
          this.pump()
        }
      } catch (error: unknown) {
        settle()
        reject(error)
      } finally {
        onValue.dispose()
        onError.dispose()
      }
    })
  }

  /** Install the official hook set as guest functions over this realm. */
  install(context: Record<string, unknown>): void {
    const factory = this.vm.evalCode(`(function (invoke, asynchronous) {
      if (asynchronous) {
        return async function () {
          const result = await invoke(Array.prototype.slice.call(arguments))
          if (!result.ok) throw result.error
          return result.value
        }
      }
      return function () {
        const result = invoke(Array.prototype.slice.call(arguments))
        if (!result.ok) throw result.error
        return result.value
      }
    })`, 'pdsh-hooks.js')
    if (factory.error) {
      const error = this.errorToHost(factory.error)
      factory.error.dispose()
      throw error
    }
    const factoryHandle = factory.value
    try {
      for (const [name, value] of Object.entries(context)) {
        if (typeof value !== 'function') {
          const guest = this.toGuestRoot(value)
          this.vm.setProp(this.vm.global, name, guest)
          this.disposeHandle(guest)
          continue
        }
        const asynchronous = name === 'agent' || name === 'parallel' || name === 'pipeline'
        const invoke = this.vm.newFunction(`${name}Invoke`, (...args: QuickJSHandle[]) => {
          // Do not disarm here: the guest may continue synchronously after a
          // non-awaited `agent()` call, and that loop must still hit the realm
          // deadline. Host work itself is not guest execution.
          try {
            let hostArgs: unknown[]
            try {
              // The guest wrapper invokes `invoke(Array.prototype.slice.call(arguments))`,
              // so the single guest argument is the real call's argument array.
              const list = args[0]
              const converted = list === undefined ? [] : this.toHost(list)
              if (!Array.isArray(converted)) throw new TypeError('workflow bridge arguments are not an array')
              hostArgs = converted
            } catch (error: unknown) {
              return this.bridgeFailure(error)
            }
            try {
              const result = value(...hostArgs)
              if (asynchronous) return this.bridgeAsync(result)
              return this.bridgeSuccess(result)
            } catch (error: unknown) {
              return this.bridgeFailure(error)
            }
          } finally {
            // Re-arm the parent watchdog after a host hook: a child-start may
            // already have cleared it, and a script that does not await this
            // hook is about to run guest code again.
            activity()
          }
        })
        const mode = asynchronous ? this.vm.true : this.vm.false
        try {
          const created = this.vm.callFunction(factoryHandle, this.vm.undefined, invoke, mode)
          if (created.error) {
            const error = this.errorToHost(created.error)
            created.error.dispose()
            throw error
          }
          this.vm.setProp(this.vm.global, name, created.value)
          created.value.dispose()
        } finally {
          invoke.dispose()
        }
      }
    } finally {
      factoryHandle.dispose()
    }
  }

  /** One `{ ok, value }` bridge result. */
  private bridgeSuccess(value: unknown): QuickJSHandle {
    const object = this.vm.newObject()
    const ok = this.vm.true
    this.vm.defineProp(object, 'ok', { value: ok, enumerable: true, configurable: false })
    const guest = this.toGuestRoot(value)
    this.vm.defineProp(object, 'value', { value: guest, enumerable: true, configurable: false })
    this.disposeHandle(guest)
    return object
  }

  /** One `{ ok: false, error }` bridge result. */
  private bridgeFailure(error: unknown): QuickJSHandle {
    const object = this.vm.newObject()
    const ok = this.vm.false
    this.vm.defineProp(object, 'ok', { value: ok, enumerable: true, configurable: false })
    const guest = this.errorToGuest(error)
    this.vm.defineProp(object, 'error', { value: guest, enumerable: true, configurable: false })
    this.disposeHandle(guest)
    return object
  }

  /** Wrap one asynchronous hook result in a guest promise of `{ ok, ... }`. */
  private bridgeAsync(value: unknown): QuickJSHandle {
    const promise: QuickJSDeferredPromise = this.vm.newPromise()
    this.pendingPromises.add(promise)
    Promise.resolve(value).then(
      (resolved) => {
        try {
          const object = this.bridgeSuccess(resolved)
          promise.resolve(object)
          object.dispose()
        } catch (error: unknown) {
          const object = this.bridgeFailure(error)
          promise.resolve(object)
          object.dispose()
        }
        this.pendingPromises.delete(promise)
        promise.dispose()
        this.schedulePump()
      },
      (error: unknown) => {
        const object = this.bridgeFailure(error)
        promise.resolve(object)
        object.dispose()
        this.pendingPromises.delete(promise)
        promise.dispose()
        this.schedulePump()
      },
    )
    return promise.handle
  }

  /** Run one compiled script and materialize its JSON result. */
  async run(code: string, filename: string): Promise<unknown> {
    this.arm()
    let evaluated
    try {
      evaluated = this.vm.evalCode(code, filename)
    } finally {
      this.deadline = 0
    }
    if (evaluated.error) {
      const error = this.mapInterrupt(this.errorToHost(evaluated.error))
      evaluated.error.dispose()
      throw error
    }
    const handle = evaluated.value
    try {
      activity()
      return await this.awaitGuest(handle)
    } finally {
      if (handle.alive) handle.dispose()
    }
  }

  /**
   * Retire the realm.
   *
   * QuickJS/WASM memory is intentionally reclaimed by terminating the
   * dedicated workflow Worker, not by freeing the runtime in place: the
   * embedded release build asserts when a handle is still reachable during
   * `JS_FreeRuntime`, and a half-freed runtime would be worse than the
   * worker's whole-realm teardown. No guest code can run after this point.
   */
  dispose(): void {
    this.disposed = true
    this.deadline = 0
    for (const reject of this.pendingRejects) reject(new Error('workflow realm disposed'))
    this.pendingRejects.clear()
    this.fault ??= new Error('workflow realm disposed')
  }
}

/** A `node:vm`-shaped compiled script. */
export class Script {
  private readonly code: string
  private readonly filename: string

  /**
   * @param code - script source, already wrapped by the official runtime.
   * @param options - `node:vm` filename/lineOffset options (line offset is not
   *   supported by QuickJS and is accepted for API compatibility).
   */
  constructor(code: string, options: ScriptOptions = {}) {
    if (typeof code !== 'string') throw new TypeError('vm.Script code must be a string')
    this.code = code
    this.filename = options.filename ?? 'eval.js'
    // Compile-only validation, exactly like the official constructor's parse
    // guard. `new Function` compiles the source; it does not execute it.
    try {
      void new Function(`return (async () => {\n${code}\n})()`)
    } catch (error: unknown) {
      throw new Error(`workflow script does not parse: ${String(error)}`)
    }
  }

  /**
   * Evaluate the script in a fresh QuickJS realm.
   * @param context - object created by {@link createContext}.
   * @param options - `timeout` is the guest activity/synchronous budget.
   * @returns a host promise of the materialized script result.
   */
  async runInContext(context: Record<string, unknown>, options: RunOptions = {}): Promise<unknown> {
    if (!isContext(context)) throw new TypeError('Script.runInContext requires a context created by createContext()')
    const module = await prepareQuickJs()
    const realm = new Realm(module, options.timeout)
    try {
      realm.install(context)
      return await realm.run(this.code, this.filename)
    } finally {
      realm.dispose()
    }
  }
}

/** Marker property used by `isContext`. */
const CONTEXT = Symbol('phone-dsh.quickjs-context')

/** The shape this shim's contexts use. */
type ContextObject = Record<string, unknown> & { readonly [CONTEXT]?: true }

/**
 * Create a guest-global bag for `Script.runInContext`.
 * @param sandbox - initial own properties exposed as guest globals.
 * @returns the context object.
 */
export function createContext(sandbox: Record<string, unknown> = {}): Record<string, unknown> {
  const context: ContextObject = { ...sandbox }
  Object.defineProperty(context, CONTEXT, { value: true, enumerable: false })
  contexts.add(context)
  return context
}

/**
 * Whether a value came from {@link createContext}.
 * @param value - candidate.
 * @returns true for this shim's contexts.
 */
export function isContext(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && contexts.has(value)
}

/**
 * Compile and run one script in a fresh QuickJS realm.
 * @param code - script source.
 * @param sandbox - initial globals.
 * @param options - timeout/filename options.
 * @returns the materialized result.
 */
export async function runInContext(
  code: string,
  sandbox: Record<string, unknown> = {},
  options: RunOptions & ScriptOptions = {},
): Promise<unknown> {
  return await new Script(code, options).runInContext(createContext(sandbox), options)
}

/**
 * Run a script in a fresh context with no shared globals.
 * @param code - script source.
 * @param sandbox - initial globals.
 * @param options - timeout/filename options.
 * @returns the materialized result.
 */
export async function runInNewContext(
  code: string,
  sandbox: Record<string, unknown> = {},
  options: RunOptions & ScriptOptions = {},
): Promise<unknown> {
  return await runInContext(code, sandbox, options)
}

/**
 * Run a script in a fresh, empty guest context. It is never the isolate's own
 * global, so this is not `eval` in the host realm.
 * @param code - script source.
 * @param options - timeout/filename options.
 * @returns the materialized result.
 */
export async function runInThisContext(code: string, options: RunOptions & ScriptOptions = {}): Promise<unknown> {
  return await runInContext(code, {}, options)
}

export default { Script, createContext, runInContext, runInNewContext, runInThisContext, isContext }
