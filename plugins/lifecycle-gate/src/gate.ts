// SPDX-License-Identifier: MIT
/**
 * The run/pause/stop gate itself, independent of DSH and of the signal source.
 * @module @phone-dsh/dsh-lifecycle-gate/gate
 */

export type GateState = 'run' | 'pause' | 'stop'

export interface GateSnapshot {
  state: GateState
  reason?: string
  budgetMs?: number
}

/** Thrown at the gate when the host refuses new work (`stop`). */
export class LifecycleRefusedError extends Error {
  readonly code = 'PDSH_LIFECYCLE_REFUSED'

  constructor(reason: string | undefined) {
    super(`the host app refused new work${reason === undefined ? '' : ` (${reason})`}; the step was not started and can be retried after the app resumes`)
    this.name = 'LifecycleRefusedError'
  }
}

export class Gate {
  private snapshot: GateSnapshot = { state: 'run' }
  private waiters = new Set<() => void>()
  private readonly listeners = new Set<(snapshot: GateSnapshot) => void>()

  get current(): GateSnapshot { return this.snapshot }

  set(next: GateSnapshot): void {
    const changed = next.state !== this.snapshot.state || next.reason !== this.snapshot.reason
    this.snapshot = { ...next }
    if (!changed) return
    for (const listener of this.listeners) listener(this.snapshot)
    if (next.state !== 'pause') {
      const waiters = this.waiters
      this.waiters = new Set()
      for (const wake of waiters) wake()
    }
  }

  onChange(listener: (snapshot: GateSnapshot) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  /**
   * Admit one unit of new work: returns at once in `run`, waits while
   * `pause`, throws {@link LifecycleRefusedError} in `stop`.
   * @param signal - cancellation of the wait (rejects with its reason).
   */
  async admit(signal?: AbortSignal): Promise<void> {
    for (;;) {
      signal?.throwIfAborted()
      const { state, reason } = this.snapshot
      if (state === 'run') return
      if (state === 'stop') throw new LifecycleRefusedError(reason)
      await new Promise<void>((resolve, reject) => {
        const onAbort = (): void => { this.waiters.delete(wake); reject(signal?.reason) }
        const wake = (): void => { signal?.removeEventListener('abort', onAbort); resolve() }
        this.waiters.add(wake)
        signal?.addEventListener('abort', onAbort, { once: true })
      })
    }
  }

  /** Number of callers currently parked at the gate. */
  get parked(): number { return this.waiters.size }
}

/** Parse a control-file body: `run` / `pause` / `stop`, or JSON `{state, reason?, budget_ms?}`. */
export function parseSignal(text: string): GateSnapshot | undefined {
  const trimmed = text.trim()
  if (trimmed === 'run' || trimmed === 'pause' || trimmed === 'stop') return { state: trimmed }
  try {
    const parsed = JSON.parse(trimmed) as { state?: string; reason?: string; budget_ms?: number }
    if (parsed.state === 'run' || parsed.state === 'pause' || parsed.state === 'stop') {
      return {
        state: parsed.state,
        ...parsed.reason === undefined ? {} : { reason: parsed.reason },
        ...parsed.budget_ms === undefined ? {} : { budgetMs: parsed.budget_ms },
      }
    }
  } catch {
    // Not JSON: unrecognized body.
  }
  return undefined
}

/** One row of the lifecycle budget threshold table. */
export interface BudgetThreshold {
  /** Applies when the remaining budget is positive and at or below this many ms. */
  readonly atOrBelowMs: number
  readonly state: GateState
  readonly reason: string
}

/**
 * Thresholds below which the host is effectively out of background budget.
 * A budget of `0` means "none/unlimited" on the wire and never moves the gate.
 */
export const DEFAULT_THRESHOLDS: readonly BudgetThreshold[] = Object.freeze([
  { atOrBelowMs: 2_000, state: 'pause' as const, reason: 'background_budget_low' },
])

const STATE_RANK: Record<GateState, number> = { run: 0, pause: 1, stop: 2 }

/**
 * Apply the threshold table to one host snapshot. Only ever downgrades:
 * a host that already said `stop` is not loosened by a healthy budget.
 * @param snapshot - host state after its own mapping.
 * @param thresholds - table rows; the first matching positive-budget row wins.
 */
export function applyThresholds(snapshot: GateSnapshot, thresholds: readonly BudgetThreshold[] = DEFAULT_THRESHOLDS): GateSnapshot {
  const budget = snapshot.budgetMs
  if (budget === undefined || budget <= 0 || snapshot.state !== 'run') return snapshot
  const row = thresholds.find(candidate => budget <= candidate.atOrBelowMs)
  if (row === undefined) return snapshot
  if (STATE_RANK[row.state] <= STATE_RANK[snapshot.state]) return snapshot
  return { state: row.state, reason: row.reason, budgetMs: budget }
}

/** One watchdog observation. */
export interface WatchdogDecision {
  readonly allowed: boolean
  /** Consecutive identical calls seen, including this one. */
  readonly count: number
  /** The configured limit (the N-th call is refused). */
  readonly limit: number
  /** Stable identity of the inputs. */
  readonly signature: string
}

/**
 * Refuse a loop of identical consecutive tool calls (same name and same
 * arguments, i.e. the same idem_key inputs). Any different call resets the
 * counter, and the N-th identical call and every later one are refused.
 */
export class LoopWatchdog {
  readonly limit: number
  private signature = ''
  private count = 0

  constructor(limit = 3) {
    if (!Number.isInteger(limit) || limit < 1) throw new RangeError('loop watchdog limit must be a positive integer')
    this.limit = limit
  }

  /** Record one dispatch and answer whether it may run. */
  observe(tool: string, args: unknown): WatchdogDecision {
    const signature = canonicalIdentity({ tool, arguments: args })
    if (signature === this.signature) this.count += 1
    else { this.signature = signature; this.count = 1 }
    return { allowed: this.count < this.limit, count: this.count, limit: this.limit, signature }
  }

  /** Forget the current run (e.g. after a deliberate user-visible retry boundary). */
  reset(): void {
    this.signature = ''
    this.count = 0
  }
}

function canonicalIdentity(value: unknown): string {
  const canonical = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(canonical)
    if (v !== null && typeof v === 'object') {
      return Object.fromEntries(Object.keys(v).sort().map(key => [key, canonical((v as Record<string, unknown>)[key])]))
    }
    return v
  }
  return JSON.stringify(canonical(value)) ?? 'undefined'
}

/**
 * Consume an update-push global such as `__PDSH_LIFECYCLE__` instead of polling:
 * install an accessor whose setter notifies the listener. The current value is
 * delivered once at install; dispose restores the previous property.
 * @param name - global property name.
 * @param listener - called with every assigned value.
 */
export function installGlobalPush<T>(name: string, listener: (value: T | undefined) => void): () => void {
  const target = globalThis as unknown as Record<string, unknown>
  const previous = Object.getOwnPropertyDescriptor(target, name)
  let value = target[name] as T | undefined
  const descriptor: PropertyDescriptor = {
    configurable: true,
    enumerable: true,
    get: () => value,
    set: (next: T | undefined) => {
      value = next
      try { listener(next) } catch { /* the push channel cannot report a listener failure */ }
    },
  }
  Object.defineProperty(target, name, descriptor)
  if (value !== undefined) listener(value)
  return () => {
    const current = Object.getOwnPropertyDescriptor(target, name)
    if (current === undefined || current.get !== descriptor.get) return
    if (previous === undefined) Reflect.deleteProperty(target, name)
    else Object.defineProperty(target, name, previous)
  }
}
