// SPDX-License-Identifier: MIT
/**
 * One acknowledgement tracker for both binary ack families of the ordered
 * channel, plus the ordered queue used by streaming adapters.
 *
 * 0x11 VFS_ACK tracks `mseq` and 0x31 JOURNAL_ACK tracks the per-session
 * `jseq`; both carry a level (1 = `write()` returned, 2 = epoch
 * `F_FULLFSYNC`) and are cumulative. The WebSocket client, the in-memory test
 * pair, exec-bridge and tool-journal all consume this one implementation
 * instead of keeping private high-water maps and waiter lists.
 *
 * Level 2 is produced by the host only at an epoch close. A VFS_BARRIER or a
 * journal checkpoint may *request* it, but this tracker records only frames
 * the host actually sent; nothing is inferred from a barrier resolving.
 * @module @phone-dsh/dsh-channel/ack-tracker
 */

/** The two acknowledgement levels of channel.md §3.2 and §3.6. */
export type AckLevel = 1 | 2

/** Key used for the single VFS mseq space; journal keys are session ids. */
export const VFS_ACK_KEY = 'vfs'

/**
 * Default bound for one durability acknowledgement wait.
 *
 * channel.md bounds only the 32 MiB unacknowledged-VFS condition (D3's
 * `RING_TIMEOUT`); it does not require a bound on a single ack wait. A lost
 * `0x11`/`0x31` frame would otherwise park `vfs.flush()` and the tool-journal
 * chain forever: the Worker never dispatches the next model request and the
 * runner can only kill the wall clock. 30 s is the same fail-loud window D3
 * uses for no ack progress.
 */
export const DEFAULT_DURABILITY_ACK_TIMEOUT_MS = 30_000
/** Environment override for {@link DEFAULT_DURABILITY_ACK_TIMEOUT_MS}, in ms. */
export const DURABILITY_ACK_TIMEOUT_ENV = 'PDSH_DURABILITY_ACK_TIMEOUT_MS'
/** Upper bound accepted for an override; a longer wait cannot beat a runner budget. */
export const MAX_DURABILITY_ACK_TIMEOUT_MS = 600_000

/**
 * Resolve the bounded durability wait. An explicit value wins; otherwise the
 * process environment may set {@link DURABILITY_ACK_TIMEOUT_ENV}. Both are
 * validated `1..MAX_DURABILITY_ACK_TIMEOUT_MS` integers so a typo fails at
 * boot instead of silently restoring the unbounded wait this constant exists
 * to remove.
 */
export function resolveDurabilityAckTimeoutMs(explicit?: number): number {
  if (explicit !== undefined) {
    return validateDurabilityAckTimeoutMs(explicit, 'durability ack timeout')
  }
  const processEnv = (globalThis as {
    process?: { env?: Record<string, string | undefined> }
  }).process?.env
  const raw = processEnv?.[DURABILITY_ACK_TIMEOUT_ENV]
  if (raw === undefined || raw === '') return DEFAULT_DURABILITY_ACK_TIMEOUT_MS
  if (!/^[0-9]+$/.test(raw)) {
    throw new RangeError(`${DURABILITY_ACK_TIMEOUT_ENV} must be a positive integer in milliseconds`)
  }
  return validateDurabilityAckTimeoutMs(Number(raw), DURABILITY_ACK_TIMEOUT_ENV)
}

function validateDurabilityAckTimeoutMs(value: number, what: string): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > MAX_DURABILITY_ACK_TIMEOUT_MS) {
    throw new RangeError(`${what} must be an integer in 1..${String(MAX_DURABILITY_ACK_TIMEOUT_MS)} ms`)
  }
  return value
}

/** Keep a pending timeout from holding a short-lived Node test process open. */
function unrefTimer(timer: unknown): void {
  ;(timer as { unref?: () => void } | undefined)?.unref?.()
}

/** One durability wait exceeded its bound; the caller must fail loud. */
export class AckTimeoutError extends Error {
  readonly code = 'ACK_TIMEOUT'
  readonly timeoutMs: number
  readonly what: string

  constructor(what: string, timeoutMs: number) {
    super(`${what} was not acknowledged within ${String(timeoutMs)} ms`)
    this.name = 'AckTimeoutError'
    this.what = what
    this.timeoutMs = timeoutMs
  }
}

/**
 * Race a durability wait against the same bound at its call site. A channel
 * implementation that honours {@link AckTrackerOptions.timeoutMs} fails the
 * connection loud before this backstop fires; this rejects the caller even
 * for an injected transport that does not implement the bound itself.
 */
export function withDurabilityAckTimeout<T>(
  work: Promise<T>,
  timeoutMs: number,
  what: string,
): Promise<T> {
  const bounded = resolveDurabilityAckTimeoutMs(timeoutMs)
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new AckTimeoutError(what, bounded))
    }, bounded)
    unrefTimer(timer)
    work.then(
      (value) => { clearTimeout(timer); resolve(value) },
      (error: unknown) => { clearTimeout(timer); reject(error) },
    )
  })
}

/** Construction inputs for {@link AckTracker}. */
export interface AckTrackerOptions {
  /** Per-wait bound; defaults to the validated env/constant window. */
  readonly timeoutMs?: number
}

interface HighWater {
  level1: bigint
  level2: bigint
}

interface AckWaiter {
  readonly key: string
  readonly level: AckLevel
  readonly upto: bigint
  readonly resolve: () => void
  readonly reject: (reason: unknown) => void
  readonly onAbort: (() => void) | undefined
  readonly signal: AbortSignal | undefined
}

/**
 * Cumulative two-level acknowledgement tracker.
 *
 * `key` partitions independent sequences: {@link VFS_ACK_KEY} for the worker's
 * mseq space and the session id for journal jseq. A level-2 ack implies level 1
 * for the same sequence, matching the host's durability order.
 */
export class AckTracker {
  private readonly highs = new Map<string, HighWater>()
  private readonly waiters = new Set<AckWaiter>()
  private readonly timeoutMs: number

  constructor(options: AckTrackerOptions = {}) {
    this.timeoutMs = resolveDurabilityAckTimeoutMs(options.timeoutMs)
  }

  /** The bound this tracker applies to a wait that does not override it. */
  get defaultTimeoutMs(): number {
    return this.timeoutMs
  }

  private high(key: string): HighWater {
    let high = this.highs.get(key)
    if (high === undefined) {
      high = { level1: 0n, level2: 0n }
      this.highs.set(key, high)
    }
    return high
  }

  /** Highest acknowledged value for `key` at `level`. */
  acked(key: string, level: AckLevel): bigint {
    const high = this.highs.get(key)
    if (high === undefined) return 0n
    return level === 1 ? high.level1 : high.level2
  }

  /**
   * Record one cumulative acknowledgement.
   * @returns true when a high-water mark advanced (waiters were re-evaluated).
   */
  resolve(key: string, level: AckLevel, upto: bigint): boolean {
    if (upto < 0n) throw new RangeError('ack value must be non-negative')
    const high = this.high(key)
    const before1 = high.level1
    const before2 = high.level2
    if (upto > high.level1) high.level1 = upto
    if (level === 2 && upto > high.level2) high.level2 = upto
    if (before1 === high.level1 && before2 === high.level2) return false
    this.resolveWaiters()
    return true
  }

  /**
   * Wait until `key` reaches `upto` at `level`; rejects on abort,
   * {@link rejectAll}, or when the bounded wait expires.
   * @param timeoutMs - Per-wait override of the tracker's bound.
   */
  wait(key: string, level: AckLevel, upto: bigint, signal?: AbortSignal, timeoutMs?: number): Promise<void> {
    if (this.acked(key, level) >= upto) return Promise.resolve()
    signal?.throwIfAborted()
    const bounded = timeoutMs === undefined
      ? this.timeoutMs
      : resolveDurabilityAckTimeoutMs(timeoutMs)
    return new Promise<void>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined
      const cleanup = (): void => {
        if (timer !== undefined) {
          clearTimeout(timer)
          timer = undefined
        }
        if (signal !== undefined && onAbort !== undefined) {
          signal.removeEventListener('abort', onAbort as () => void)
        }
      }
      const retire = (): boolean => this.waiters.delete(waiter)
      const onAbort = signal === undefined
        ? undefined
        : (): void => {
          if (!retire()) return
          cleanup()
          reject(signal.reason)
        }
      const waiter: AckWaiter = {
        key,
        level,
        upto,
        resolve: () => { cleanup(); resolve() },
        reject: (reason: unknown) => { cleanup(); reject(reason) },
        onAbort,
        signal,
      }
      this.waiters.add(waiter)
      signal?.addEventListener('abort', onAbort as () => void, { once: true })
      timer = setTimeout(() => {
        if (!retire()) return
        cleanup()
        reject(new AckTimeoutError(
          `durability ack level ${String(level)} up to ${String(upto)} for ${JSON.stringify(key)}`,
          bounded,
        ))
      }, bounded)
      unrefTimer(timer)
    })
  }

  /** Reject every outstanding wait (used on close and fatal protocol errors). */
  rejectAll(reason: unknown): void {
    for (const waiter of [...this.waiters]) {
      this.waiters.delete(waiter)
      waiter.reject(reason)
    }
  }

  /**
   * Reject the waiters for one sequence whose target is at or above `from`.
   *
   * A resource-refused VFS_MUT consumes no mseq, so no cumulative ack for that
   * sequence can ever reach a target at or above it: the durable write really
   * failed and every caller waiting on that range must hear it now instead of
   * waiting for the bounded ack timeout. Unrelated sequences (journal acks) and
   * lower, already satisfiable targets are untouched.
   */
  rejectFrom(key: string, level: AckLevel, from: bigint, reason: unknown): void {
    for (const waiter of [...this.waiters]) {
      if (waiter.key !== key || waiter.level !== level || waiter.upto < from) continue
      this.waiters.delete(waiter)
      waiter.reject(reason)
    }
  }

  /** Number of outstanding waits; exposed for tests and diagnostics. */
  get pending(): number {
    return this.waiters.size
  }

  private resolveWaiters(): void {
    for (const waiter of [...this.waiters]) {
      if (this.acked(waiter.key, waiter.level) < waiter.upto) continue
      this.waiters.delete(waiter)
      waiter.resolve()
    }
  }
}

/**
 * Minimal ordered async queue used to turn callback/frame input into an async
 * iterator (API response chunks, exec event streams). Exactly one copy lives in
 * this package so the adapters do not grow their own.
 */
export class AsyncQueue<T> {
  private readonly items: T[] = []
  private readonly waiters: { resolve: (result: IteratorResult<T>) => void; reject: (reason: unknown) => void }[] = []
  private ended = false
  private failure: unknown

  push(item: T): void {
    if (this.ended) return
    const waiter = this.waiters.shift()
    if (waiter !== undefined) waiter.resolve({ value: item, done: false })
    else this.items.push(item)
  }

  end(): void {
    if (this.ended) return
    this.ended = true
    for (const waiter of this.waiters.splice(0)) waiter.resolve({ value: undefined, done: true })
  }

  fail(reason: unknown): void {
    if (this.ended) return
    this.ended = true
    this.failure = reason
    for (const waiter of this.waiters.splice(0)) waiter.reject(reason)
  }

  async next(): Promise<IteratorResult<T>> {
    const item = this.items.shift()
    if (item !== undefined) return { value: item, done: false }
    if (this.ended) {
      if (this.failure !== undefined) throw this.failure
      return { value: undefined, done: true }
    }
    return await new Promise<IteratorResult<T>>((resolve, reject) => {
      this.waiters.push({ resolve, reject })
    })
  }
}
