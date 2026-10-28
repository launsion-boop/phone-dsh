// SPDX-License-Identifier: MIT
/**
 * The engine's authoritative terminal state for one root shell execution.
 *
 * just-bash 3.6.0 runs each `Bash.exec` in a local execution state. Its public
 * result env has two historical defects on the paths this shell cares about:
 * a fatal catch returns the *initial* environment, and a script may assign
 * `PWD` independently of the real cwd. The dependency patch recorded in
 * `THIRD_PARTY.md` attaches a `metadata.terminal` record from that local state
 * on every root return, plus a non-enumerable snapshot used to seed the EXIT
 * handler. This module validates that record. It never infers cwd, env,
 * options or pipeline statuses from stderr or from the script text.
 * @module @phone-dsh/dsh-shell-ext/terminal
 */

/** Symbol the patched engine uses for the non-enumerable restore snapshot. */
export const TERMINAL_STATE_SYMBOL = Symbol.for('@phone-dsh/just-bash/terminal-state/v1')

/**
 * Symbol the patched engine reads from `ExecOptions` to start a root execution
 * with trusted terminal facts (the EXIT handler's status/PIPESTATUS/options and
 * the per-execution source-staging path).
 *
 * It is a symbol option, not an environment variable or a shell command, so a
 * user script cannot define a same-named function, print a fake marker or see
 * the value through `env`/`set -x`.
 */
export const TERMINAL_SEED_SYMBOL: unique symbol = Symbol.for('@phone-dsh/just-bash/terminal-seed/v1')

/** Trusted initial state for one root execution. */
export interface TerminalSeed {
  /** `$?` at the first handler command. */
  readonly status?: number
  /** `PIPESTATUS` at the first handler command. */
  readonly pipeStatus?: readonly number[]
  /** Shell options (`errexit`, `nounset`, `xtrace`, `pipefail`, ...). */
  readonly options?: Readonly<Record<string, boolean>>
  /** `shopt` options the engine should start with. */
  readonly shopt?: Readonly<Record<string, boolean>>
  /**
   * Per-execution hidden path where the patched `source` builtin stages its
   * transformed text for the shell's bounded cleanup. It is engine state, not
   * a shell variable.
   */
  readonly sourceStagePath?: string
}

/** The metadata format this consumer understands. */
export const TERMINAL_FORMAT = 'just-bash-terminal/1'

/** One shell array, elements in insertion order. */
export interface TerminalArray {
  readonly kind: string
  readonly values: readonly (readonly [string, string])[]
}

/** The last completed pipeline, or `[status]` when a fatal aborted the statement. */
export interface TerminalPipeline {
  readonly statuses: readonly number[]
  readonly status: number
  readonly negated: boolean
}

/** Where the root shell actually stopped. */
export type TerminalTermination =
  | 'completed'
  | 'errexit'
  | 'explicit-exit'
  | 'fatal-unwind'
  | 'not-ordinary'

/** The terminal record the patched engine attaches to `metadata.terminal`. */
export interface TerminalState {
  readonly format: string
  readonly authority: 'engine'
  readonly engine: {
    readonly name: 'just-bash'
    readonly version: '3.6.0'
    readonly seam: 'phone-dsh/terminal-state/1'
  }
  /** True only when no function/local scope was still active. */
  readonly authoritative: boolean
  /** Engine error class for the stopping point, never a stderr guess. */
  readonly cause: string
  readonly termination: TerminalTermination
  readonly status: number
  readonly cwd?: string
  /** The `PWD` *variable*; it may differ from {@link cwd} after `PWD=...`. */
  readonly pwdVariable?: string
  readonly env?: Readonly<Record<string, string>>
  readonly options?: Readonly<Record<string, boolean>>
  readonly shopt?: Readonly<Record<string, boolean>>
  readonly functions: readonly string[]
  readonly arrays: Readonly<Record<string, TerminalArray>>
  readonly pipeline: TerminalPipeline
  readonly lastExitCode?: number
  readonly unwound: boolean
  readonly unsupportedReason?: string
}

/** The subset of a `BashExecResult` this module reads. */
export interface TerminalResultLike {
  readonly exitCode: number
  readonly metadata?: Readonly<Record<string, unknown>> | undefined
}

/** True when a value is a plain object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Read one optional string record without trusting its prototype. */
function stringRecord(value: unknown): Record<string, string> | undefined {
  if (!isRecord(value)) return undefined
  const out: Record<string, string> = {}
  for (const [name, item] of Object.entries(value)) {
    if (typeof item !== 'string') return undefined
    out[name] = item
  }
  return out
}

/** Read one optional boolean record. */
function booleanRecord(value: unknown): Record<string, boolean> | undefined {
  if (!isRecord(value)) return undefined
  const out: Record<string, boolean> = {}
  for (const [name, item] of Object.entries(value)) {
    if (typeof item !== 'boolean') return undefined
    out[name] = item
  }
  return out
}

/** Validate array elements. */
function terminalArrays(value: unknown): Record<string, TerminalArray> | undefined {
  if (!isRecord(value)) return undefined
  const out: Record<string, TerminalArray> = {}
  for (const [name, raw] of Object.entries(value)) {
    if (!isRecord(raw) || typeof raw.kind !== 'string' || !Array.isArray(raw.values)) return undefined
    const values: [string, string][] = []
    for (const pair of raw.values) {
      if (!Array.isArray(pair) || pair.length !== 2) return undefined
      const [key, item] = pair as unknown[]
      if (typeof key !== 'string' || typeof item !== 'string') return undefined
      values.push([key, item])
    }
    out[name] = { kind: raw.kind, values }
  }
  return out
}

/** Validate one pipeline record. */
function terminalPipeline(value: unknown): TerminalPipeline | undefined {
  if (!isRecord(value) || !Array.isArray(value.statuses)) return undefined
  const statuses: number[] = []
  for (const status of value.statuses) {
    if (typeof status !== 'number' || !Number.isInteger(status)) return undefined
    statuses.push(status)
  }
  if (typeof value.status !== 'number' || !Number.isInteger(value.status)) return undefined
  if (typeof value.negated !== 'boolean') return undefined
  return { statuses, status: value.status, negated: value.negated }
}

/**
 * Validate `metadata.terminal` from one engine result.
 *
 * A missing or malformed record is `undefined`; the caller must fail loud
 * instead of falling back to an old env snapshot. `authoritative: false` is a
 * valid record: it says the engine could not prove an unwound terminal state.
 * @param result - the engine result.
 * @returns the validated terminal record, or undefined.
 */
export function readTerminalState(result: TerminalResultLike): TerminalState | undefined {
  const metadata = result.metadata
  if (!isRecord(metadata)) return undefined
  const raw = metadata.terminal
  if (!isRecord(raw)) return undefined
  if (raw.format !== TERMINAL_FORMAT || raw.authority !== 'engine') return undefined
  if (!isRecord(raw.engine) || raw.engine.name !== 'just-bash' || raw.engine.version !== '3.6.0'
    || raw.engine.seam !== 'phone-dsh/terminal-state/1') return undefined
  if (typeof raw.authoritative !== 'boolean' || typeof raw.unwound !== 'boolean') return undefined
  if (typeof raw.cause !== 'string' || typeof raw.termination !== 'string' || typeof raw.status !== 'number') return undefined
  const terminations: readonly string[] = ['completed', 'errexit', 'explicit-exit', 'fatal-unwind', 'not-ordinary']
  if (!terminations.includes(raw.termination)) return undefined
  const cwd = typeof raw.cwd === 'string' ? raw.cwd : undefined
  const pwdVariable = typeof raw.pwdVariable === 'string' ? raw.pwdVariable : undefined
  const env = stringRecord(raw.env)
  const options = booleanRecord(raw.options)
  const shopt = booleanRecord(raw.shopt)
  if (!Array.isArray(raw.functions) || raw.functions.some(name => typeof name !== 'string')) return undefined
  const arrays = terminalArrays(raw.arrays)
  const pipeline = terminalPipeline(raw.pipeline)
  if (arrays === undefined || pipeline === undefined) return undefined
  if (typeof raw.lastExitCode !== 'undefined' && typeof raw.lastExitCode !== 'number') return undefined
  if (typeof raw.unsupportedReason !== 'undefined' && typeof raw.unsupportedReason !== 'string') return undefined
  if (raw.authoritative) {
    if (cwd === undefined || !cwd.startsWith('/')) return undefined
    if (env === undefined || options === undefined || shopt === undefined) return undefined
  }
  return {
    format: TERMINAL_FORMAT,
    authority: 'engine',
    engine: { name: 'just-bash', version: '3.6.0', seam: 'phone-dsh/terminal-state/1' },
    authoritative: raw.authoritative,
    cause: raw.cause,
    termination: raw.termination as TerminalTermination,
    status: raw.status,
    ...cwd === undefined ? {} : { cwd },
    ...pwdVariable === undefined ? {} : { pwdVariable },
    ...env === undefined ? {} : { env },
    ...options === undefined ? {} : { options },
    ...shopt === undefined ? {} : { shopt },
    functions: raw.functions as string[],
    arrays,
    pipeline,
    ...typeof raw.lastExitCode === 'number' ? { lastExitCode: raw.lastExitCode } : {},
    unwound: raw.unwound,
    ...raw.unsupportedReason === undefined ? {} : { unsupportedReason: raw.unsupportedReason },
  }
}

/**
 * Whether an EXIT handler may run from this terminal state.
 *
 * Complete/errexit/explicit-exit/fatal-unwind are ordinary shell terminal
 * states. Engine ceilings, cancellation, parse/security failures and engine
 * exceptions are not: GNU runs an EXIT trap for the first class but this layer
 * has never promised safe cleanup for the second.
 * @param terminal - a validated terminal record.
 * @returns whether the handler may run.
 */
export function terminalHandlerEligible(terminal: TerminalState): boolean {
  if (!terminal.authoritative || !terminal.unwound) return false
  return terminal.termination === 'completed'
    || terminal.termination === 'errexit'
    || terminal.termination === 'explicit-exit'
    || terminal.termination === 'fatal-unwind'
}

/**
 * Read the engine's non-enumerable restore snapshot.
 * @param result - the engine result.
 * @returns the opaque snapshot, or undefined when the engine is unpatched.
 */
export function terminalSnapshotFromResult(result: object): unknown {
  return (result as Record<symbol, unknown>)[TERMINAL_STATE_SYMBOL]
}
