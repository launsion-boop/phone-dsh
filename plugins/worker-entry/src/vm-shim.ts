// SPDX-License-Identifier: MIT
/**
 * The `node:vm` face used by the isolated workflow realm.
 *
 * This is NOT a security sandbox and must never be the only thing standing
 * between a model-written workflow and the host Worker. It exists so official
 * `@deepseek-ai/dsh-workflow-ptc` code can run unchanged inside the dedicated
 * workflow isolate: `new Function` + `with` gives the script an isolated
 * identifier scope, while the actual isolation (separate global, no VFS, no
 * module loader, no token, hard termination) comes from the Worker boundary
 * around it.
 *
 * Every identifier resolves through a scope proxy whose `has` trap answers
 * true, so an absent name cannot fall through to the isolate's global
 * `fetch`/`process`/`globalThis`/`self`/`require`. The isolate runner removes
 * those globals before executing a script as a second, independent barrier.
 * `Function` remains an ECMAScript intrinsic: constructor/prototype tricks can
 * reach the isolate's OWN global, which carries no parent credential, module
 * loader or VFS handle.
 *
 * `timeout` is accepted and ignored. A synchronous loop cannot be interrupted
 * from inside the same realm; the orchestrating Worker enforces its deadline by
 * terminating this isolated Worker and waiting for child cleanup.
 * @module @phone-dsh/dsh-worker-entry/vm-shim
 */

/** Options accepted by {@link Script} and the `runIn*` helpers. */
export interface ScriptOptions {
  filename?: string
  lineOffset?: number
  columnOffset?: number
  displayErrors?: boolean
  timeout?: number
  breakOnSigint?: boolean
}

/** Marks objects created by {@link createContext}. */
const contexts = new WeakSet<object>()

/** Called after the first synchronous slice of a script returns (or throws). */
let syncYieldListener: (() => void) | undefined

/**
 * Install the isolated runner's notification that the script's first
 * synchronous slice has yielded. The parent Worker uses it to disarm the
 * hard deadline: after this point the script is either awaiting a host call or
 * already settled, and cancellation owns termination.
 * @param listener - callback invoked after the initial synchronous slice.
 * @returns nothing.
 */
export function setVmSyncYieldListener(listener: (() => void) | undefined): void {
  syncYieldListener = listener
}

/** The ECMAScript intrinsics a workflow script may see. */
const INTRINSIC_NAMES = [
  'Object', 'Function', 'Array', 'String', 'Number', 'Boolean', 'Symbol', 'BigInt',
  'Math', 'JSON', 'Date', 'RegExp', 'Error', 'AggregateError', 'EvalError',
  'RangeError', 'ReferenceError', 'SyntaxError', 'TypeError', 'URIError',
  'Promise', 'Map', 'Set', 'WeakMap', 'WeakSet', 'WeakRef', 'FinalizationRegistry',
  'ArrayBuffer', 'DataView', 'Uint8Array', 'Int8Array', 'Uint8ClampedArray',
  'Uint16Array', 'Int16Array', 'Uint32Array', 'Int32Array', 'Float32Array',
  'Float64Array', 'BigInt64Array', 'BigUint64Array', 'Reflect', 'Proxy', 'Intl',
  'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'encodeURI', 'decodeURI',
  'encodeURIComponent', 'decodeURIComponent', 'NaN', 'Infinity', 'undefined',
] as const

/** Build the intrinsic values from the current (isolate) realm. */
function intrinsics(): Record<string, unknown> {
  const source = globalThis as Record<string, unknown>
  const values: Record<string, unknown> = Object.create(null) as Record<string, unknown>
  for (const name of INTRINSIC_NAMES) values[name] = source[name]
  return values
}

/** The `this` value the script sees at top level (never the isolate global). */
const SCRIPT_THIS = Object.freeze(Object.create(null) as object)

/** A scope proxy that shadows every identifier not explicitly supplied. */
function scopeProxy(target: Record<string, unknown>): object {
  return new Proxy(target, {
    has: () => true,
    get: (object, key) => key === Symbol.unscopables ? undefined : Reflect.get(object, key),
    set: (object, key, value) => Reflect.set(object, key, value),
    deleteProperty: (object, key) => Reflect.deleteProperty(object, key),
  })
}

/** Compile one script body against a contextified scope. */
function compile(code: string, options: ScriptOptions | undefined): (scope: object) => unknown {
  const filename = options?.filename ?? 'vm-shim'
  const source = `${code}\n//# sourceURL=${filename.replace(/\n/g, ' ')}`
  const expressionBody = `with (__pdshScope__) { return (${source}\n); }`
  try {
    // eslint-disable-next-line no-new-func -- this module is the isolate's sanctioned vm face
    return new Function('__pdshScope__', expressionBody) as (scope: object) => unknown
  } catch (error: unknown) {
    if (!(error instanceof SyntaxError)) throw error
    // A statement body (not the official workflow wrapper) runs as a block and
    // returns undefined, matching vm.Script's statement semantics closely
    // enough for this isolate's callers.
    const statementBody = `with (__pdshScope__) { ${source}\n }`
    // eslint-disable-next-line no-new-func -- see above
    return new Function('__pdshScope__', statementBody) as (scope: object) => unknown
  }
}

/** Execute one compiled script against one contextified scope. */
function execute(compiled: (scope: object) => unknown, context: object): unknown {
  const target = context as Record<string, unknown>
  const scope = scopeProxy({ ...intrinsics(), ...target })
  try {
    return compiled.call(SCRIPT_THIS, scope)
  } finally {
    syncYieldListener?.()
  }
}

/** `node:vm` `Script` with the subset the workflow runtime uses. */
export class Script {
  readonly #code: string
  readonly #options: ScriptOptions | undefined

  /**
   * Compile one script.
   * @param code - JavaScript source. The official workflow runtime passes an
   *   expression (`(async () => { ... })()`).
   * @param options - filename and ignored timeout fields.
   */
  constructor(code: string, options?: ScriptOptions) {
    if (typeof code !== 'string') throw new TypeError('vm.Script code must be a string')
    this.#code = code
    this.#options = options
    // Compile eagerly, like Node: a syntax error surfaces here, not at run().
    compile(code, options)
  }

  /**
   * Run the script with the supplied context's properties in scope.
   * @param context - object returned by {@link createContext}.
   * @param options - ignored timeout and display options.
   * @returns the script's completion value.
   */
  runInContext(context: object, options?: ScriptOptions): unknown {
    return execute(compile(this.#code, options ?? this.#options), context)
  }

  /**
   * Run the script against a fresh context built from `sandbox`.
   * @param sandbox - properties to expose in scope.
   * @param options - ignored timeout and display options.
   * @returns the script's completion value.
   */
  runInNewContext(sandbox?: Record<string, unknown>, options?: ScriptOptions): unknown {
    return execute(compile(this.#code, options ?? this.#options), createContext(sandbox))
  }

  /**
   * Run against this module's restricted intrinsic scope (never the real
   * isolate global), so host globals stay unexposed.
   * @param options - ignored timeout and display options.
   * @returns the script's completion value.
   */
  runInThisContext(options?: ScriptOptions): unknown {
    return execute(compile(this.#code, options ?? this.#options), createContext({}))
  }
}

/**
 * Contextify a sandbox. The object is returned as-is; execution copies its
 * properties into a fresh shadowing scope, so no shared global is involved.
 * @param sandbox - initial scope properties.
 * @param options - accepted for signature compatibility and ignored.
 * @returns the context object.
 */
export function createContext(sandbox?: Record<string, unknown> | object, options?: { name?: string; origin?: string }): Record<string, unknown> {
  void options
  const context = (sandbox ?? {}) as Record<string, unknown>
  if (typeof context !== 'object' || context === null) throw new TypeError('vm.createContext requires an object')
  contexts.add(context)
  return context
}

/**
 * Whether an object was created by {@link createContext}.
 * @param value - candidate.
 * @returns true for a contextified object.
 */
export function isContext(value: unknown): boolean {
  return typeof value === 'object' && value !== null && contexts.has(value)
}

/**
 * Compile and run source in the supplied context.
 * @param code - JavaScript source.
 * @param context - contextified object.
 * @param options - filename and ignored timeout fields.
 * @returns the script's completion value.
 */
export function runInContext(code: string, context: object, options?: ScriptOptions): unknown {
  return new Script(code, options).runInContext(context)
}

/**
 * Compile and run source in a fresh context.
 * @param code - JavaScript source.
 * @param sandbox - initial scope properties.
 * @param options - filename and ignored timeout fields.
 * @returns the script's completion value.
 */
export function runInNewContext(code: string, sandbox?: Record<string, unknown>, options?: ScriptOptions): unknown {
  return new Script(code, options).runInNewContext(sandbox)
}

/**
 * Compile and run source against the restricted intrinsic scope.
 * @param code - JavaScript source.
 * @param options - filename and ignored timeout fields.
 * @returns the script's completion value.
 */
export function runInThisContext(code: string, options?: ScriptOptions): unknown {
  return new Script(code, options).runInThisContext()
}

/** CommonJS interop marker: the Worker loader hands `default` to default imports. */
export const __esModule = true

/** The `node:vm` declarations this module stands in for. */
export default {
  Script, createContext, runInContext, runInNewContext, runInThisContext, isContext,
}
