// SPDX-License-Identifier: MIT
/**
 * Job lifecycle for executions that stay in the Worker (`bash -c` and every
 * writing command, PLAN D12).
 *
 * The subprocess seam describes a live handle but has no notion of a job: an
 * in-Worker command is just a promise. When that promise cannot settle — the
 * command-boundary VFS flush never reaches its host ack, a queued command waits
 * behind a wedged lane, a shell engine ignores its abort — nothing records the
 * command, nothing bounds it, and the per-workspace execution mutex stays held
 * with no event to show why (G2-A10: a `timeoutMs` 30 s `bash` call produced no
 * tool result until the runner's wall-clock kill).
 *
 * {@link WorkerJobRegistry} is the settlement owner (G2-FIX-104). Earlier the
 * deadline timer lived in each handle, i.e. in the command-dispatch layer that
 * the per-workspace execution mutex serializes. A WASI interpreter blocked in a
 * proxied syscall therefore held the lane while its deadline and a
 * channel-delivered cancel waited in band behind the same lane: no terminal
 * `tool/result`, no journal end, no D13 step settlement, no partial-write
 * marker. The registry now owns the timer and the drain fan-out and calls the
 * handle's hard terminator synchronously, outside the mutex, so a wedged
 * interpreter is cut off at the deadline (or at the host drain) and the job
 * account reaches a terminal state regardless of what the engine is doing.
 *
 * The events stay the same (`job/registered` → `job/started` →
 * `job/settling` → `job/settled`); the account is what a subscriber (a
 * component test, the Worker entry) observes.
 * @module @phone-dsh/dsh-subprocess-xl/jobs
 */

import type { SubprocessOutcome } from '@deepseek-ai/dsh-subprocess'

/** Where one in-Worker command is in its lifecycle. */
export type WorkerJobStatus = 'queued' | 'running' | 'settling' | 'settled'

/**
 * Why a job reached `settling`/`settled`.
 *
 * - `exit`: the command reported its own status.
 * - `timeout`: the job's deadline expired (the Worker shell's wall clock).
 * - `cancel`: the caller aborted the spawn signal (a tool-call abort).
 * - `drain`: the host closed admission / moved execution rights (LIFECYCLE,
 *   FENCE or a fatal channel ERROR).
 * - `failure`: the execution could not be observed or started.
 */
export type WorkerJobSettleCause = 'exit' | 'timeout' | 'cancel' | 'drain' | 'failure'

/** Lifecycle transitions a subscriber observes. */
export type WorkerJobEventType = 'job/registered' | 'job/started' | 'job/settling' | 'job/settled'

/** Immutable projection of one job at one instant. */
export interface WorkerJobSnapshot {
  /** Registry-unique identity (`pdsh-job-<n>`). */
  readonly id: string
  /** The argv the Worker actually dispatched (after any identity rewrite). */
  readonly argv: readonly string[]
  /** Absolute virtual working directory. */
  readonly cwd: string
  readonly status: WorkerJobStatus
  /** Effective job deadline in milliseconds, when one was armed. */
  readonly timeoutMs?: number
  /** First terminal cause (present from `settling` on). */
  readonly cause?: WorkerJobSettleCause
  /** Exit facts once the command settled (absent for an unobservable failure). */
  readonly outcome?: SubprocessOutcome
  /** Failure text when the execution could not be observed or started. */
  readonly error?: string
  readonly registeredAt: number
  readonly startedAt?: number
  readonly settledAt?: number
}

/** One lifecycle transition. */
export interface WorkerJobEvent {
  readonly type: WorkerJobEventType
  readonly job: WorkerJobSnapshot
}

/** Inputs for {@link WorkerJobRegistry.register}. */
export interface WorkerJobSpec {
  readonly argv: readonly string[]
  readonly cwd: string
  /** Effective deadline in milliseconds; absent means the caller armed none. */
  readonly timeoutMs?: number | undefined
  /**
   * Extra time the settlement owner allows after {@link timeoutMs} before it
   * hard-terminates.
   *
   * The upstream `bash` executor fuses its own deadline into the spawn signal;
   * that signal is the authoritative bound and reaches the job instantly. The
   * registry timer is only its backstop, so it is armed a grace period later.
   * An explicit caller-supplied `timeoutMs` (a component test, a direct
   * dispatcher) has no other timer and uses zero margin.
   */
  readonly deadlineMarginMs?: number | undefined
}

/**
 * How the registry cuts a job off.
 *
 * The terminator is supplied by the runtime and must hard-terminate the
 * execution behind the job (abort the engine, terminate a WASI instance,
 * settle the handle). It runs synchronously from the registry — the deadline
 * timer and the drain fan-out are both built on it — so it must never await the
 * execution mutex or a command-boundary flush.
 */
export interface WorkerJobHooks {
  readonly terminate?: ((cause: WorkerJobSettleCause) => void) | undefined
}

/** How many settled records the registry retains for diagnostics. */
const RETAINED_JOBS = 64

/** Largest delay `setTimeout` schedules without clamping it to one millisecond. */
export const MAX_TIMER_DELAY_MS = 2_147_483_647

/**
 * Bound after which a hard termination that did not settle the handle still
 * writes the job's terminal account.
 *
 * The handle normally settles inside its own bounded settlement (the engine
 * abort plus the grace timer). This backstop only exists so a broken handle
 * cannot leave the account non-terminal forever; it is far inside the host's
 * 20 s drain window and never runs in the happy path.
 */
export const EXTERNAL_SETTLE_FALLBACK_MS = 5_000

/** The exit facts a hard settlement reports when no provider outcome exists. */
export function forcedOutcome(cause: WorkerJobSettleCause): SubprocessOutcome {
  return cause === 'timeout'
    ? { exitCode: 124, signal: null }
    : { exitCode: null, signal: 'SIGTERM' }
}

/** Schedule a timer without keeping a short-lived Node process alive. */
function unrefTimer(timer: ReturnType<typeof setTimeout>): void {
  ;(timer as { unref?: () => void }).unref?.()
}

/**
 * One in-Worker command's lifecycle record.
 *
 * Handles own the mechanics (engine abort, WASI termination, stream sealing);
 * this object owns the account and the deadline. `beginSettling` and `settle`
 * are idempotent and keep the first cause, so a command that is terminated by
 * both its deadline and a drain still reports the cause that arrived first —
 * the same first-cause rule the shell itself applies to abort vs timeout.
 */
export class WorkerCommandJob {
  readonly id: string
  readonly argv: readonly string[]
  readonly cwd: string
  readonly timeoutMs: number | undefined
  readonly registeredAt: number
  private readonly deadlineMarginMs: number
  /**
   * True when the registry, not the handle, armed the deadline. The handle
   * therefore does not schedule a second, in-band timer for an attached job.
   */
  readonly deadlineOwnedByRegistry = true
  private readonly notify: (event: WorkerJobEvent) => void
  private readonly terminate: ((cause: WorkerJobSettleCause) => void) | undefined
  private state: WorkerJobStatus = 'queued'
  private terminalCause: WorkerJobSettleCause | undefined
  private finalOutcome: SubprocessOutcome | undefined
  private finalError: string | undefined
  private runningAt: number | undefined
  private finishedAt: number | undefined
  private deadlineTimer: ReturnType<typeof setTimeout> | undefined
  private fallbackTimer: ReturnType<typeof setTimeout> | undefined

  constructor(
    id: string,
    spec: WorkerJobSpec,
    notify: (event: WorkerJobEvent) => void,
    hooks: WorkerJobHooks = {},
  ) {
    this.id = id
    this.argv = Object.freeze([...spec.argv])
    this.cwd = spec.cwd
    this.timeoutMs = spec.timeoutMs
    this.deadlineMarginMs = spec.deadlineMarginMs ?? 0
    this.registeredAt = Date.now()
    this.notify = notify
    this.terminate = hooks.terminate
  }

  /** Announce the record once the registry holds it (called by the registry). */
  announce(): void {
    this.notify({ type: 'job/registered', job: this.snapshot() })
  }

  /**
   * Arm the registry-owned deadline.
   *
   * The timer belongs to the settlement owner, not to the handle: it fires
   * even while the command holds the per-workspace execution lane.
   */
  armDeadline(): void {
    if (this.timeoutMs === undefined || this.deadlineTimer !== undefined || this.settled) return
    const delay = Math.max(1, Math.min(this.timeoutMs + Math.max(0, this.deadlineMarginMs), MAX_TIMER_DELAY_MS))
    this.deadlineTimer = setTimeout(() => {
      this.deadlineTimer = undefined
      this.forceSettle('timeout')
    }, delay)
    unrefTimer(this.deadlineTimer)
  }

  /** True once the job reached a terminal state. */
  get settled(): boolean { return this.state === 'settled' }

  /** Mark the job as dispatched (the execution lane admitted it). */
  markStarted(): void {
    if (this.state !== 'queued') return
    this.state = 'running'
    this.runningAt = Date.now()
    this.notify({ type: 'job/started', job: this.snapshot() })
  }

  /**
   * Record the first reason the command is being stopped. A job that exits
   * normally never reaches this state.
   * @param cause - the interruption cause.
   */
  beginSettling(cause: WorkerJobSettleCause): void {
    if (this.state === 'settled') return
    if (this.terminalCause !== undefined) return
    this.terminalCause = cause
    this.state = 'settling'
    this.notify({ type: 'job/settling', job: this.snapshot() })
  }

  /**
   * Cut the execution off from outside the execution-mutex domain.
   *
   * The terminator is invoked synchronously before any await so a WASI
   * instance blocked in a proxied syscall is released now, not after the lane
   * drains. If the terminator returns without settling the account (a handle
   * that could not observe its own abort), a bounded fallback writes the
   * terminal state anyway; the handle's own settlement still wins when it
   * arrives first.
   * @param cause - why the job is being cut off.
   */
  forceSettle(cause: WorkerJobSettleCause): void {
    if (this.settled) return
    this.beginSettling(cause)
    if (this.terminate !== undefined) {
      try {
        this.terminate(cause)
      } catch (error) {
        this.fail(error)
        return
      }
    }
    if (this.settled) return
    this.fallbackTimer ??= setTimeout(() => {
      this.fallbackTimer = undefined
      this.settle(forcedOutcome(cause), cause)
    }, EXTERNAL_SETTLE_FALLBACK_MS)
    unrefTimer(this.fallbackTimer)
  }

  /**
   * Commit the terminal account.
   *
   * A command that reports its own status transitions straight to `settled`
   * (there is nothing to interrupt); only an interruption that was announced
   * through {@link beginSettling} emits the intermediate `settling` event.
   * @param outcome - exit facts; omitted when none could be observed.
   * @param cause - terminal cause (first cause wins when one was recorded).
   */
  settle(outcome: SubprocessOutcome | undefined, cause: WorkerJobSettleCause): void {
    if (this.state === 'settled') return
    if (this.terminalCause === undefined) this.terminalCause = cause
    this.finalOutcome = outcome
    this.finishedAt = Date.now()
    this.state = 'settled'
    this.clearTimers()
    this.notify({ type: 'job/settled', job: this.snapshot() })
  }

  /**
   * Commit a terminal account for an execution that could not be observed.
   * @param error - the failure that ended the execution.
   */
  fail(error: unknown): void {
    if (this.state === 'settled') return
    this.terminalCause ??= 'failure'
    this.finalError = error instanceof Error ? error.message : String(error)
    this.finishedAt = Date.now()
    this.state = 'settled'
    this.clearTimers()
    this.notify({ type: 'job/settled', job: this.snapshot() })
  }

  /** Freeze the current state for readers and events. */
  snapshot(): WorkerJobSnapshot {
    return {
      id: this.id,
      argv: this.argv,
      cwd: this.cwd,
      status: this.state,
      ...this.timeoutMs === undefined ? {} : { timeoutMs: this.timeoutMs },
      ...this.terminalCause === undefined ? {} : { cause: this.terminalCause },
      ...this.finalOutcome === undefined ? {} : { outcome: this.finalOutcome },
      ...this.finalError === undefined ? {} : { error: this.finalError },
      registeredAt: this.registeredAt,
      ...this.runningAt === undefined ? {} : { startedAt: this.runningAt },
      ...this.finishedAt === undefined ? {} : { settledAt: this.finishedAt },
    }
  }

  private clearTimers(): void {
    if (this.deadlineTimer !== undefined) clearTimeout(this.deadlineTimer)
    if (this.fallbackTimer !== undefined) clearTimeout(this.fallbackTimer)
    this.deadlineTimer = undefined
    this.fallbackTimer = undefined
  }
}

/**
 * The Worker's in-process job account and external settlement owner.
 *
 * Subscribers are synchronous and isolated from one another: a throwing
 * listener must never change the job's outcome or stop the next listener.
 */
export class WorkerJobRegistry {
  private sequence = 0
  private readonly records = new Map<string, WorkerCommandJob>()
  private readonly listeners = new Set<(event: WorkerJobEvent) => void>()

  /**
   * Register one command before dispatch.
   * @param spec - dispatched argv, cwd and effective deadline.
   * @param hooks - the runtime's hard terminator for this execution.
   * @returns the live job record the handle drives.
   */
  register(spec: WorkerJobSpec, hooks: WorkerJobHooks = {}): WorkerCommandJob {
    this.sequence += 1
    const job = new WorkerCommandJob(`pdsh-job-${String(this.sequence)}`, spec, (event) => { this.publish(event) }, hooks)
    this.records.set(job.id, job)
    this.trim()
    job.announce()
    job.armDeadline()
    return job
  }

  /**
   * Observe lifecycle transitions.
   * @param listener - called for every transition of every registered job.
   * @returns a disposer.
   */
  onEvent(listener: (event: WorkerJobEvent) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  /**
   * Cut every unsettled job off — the drain/abort fan-out (PLAN D14/D24).
   *
   * Called synchronously from the admission-closed path, so settlement does
   * not depend on any handle continuing to run or on the execution lane being
   * free.
   * @param cause - `drain` for a host drain/abort, `cancel` for a caller abort.
   * @returns how many jobs were forced to settle.
   */
  settleAll(cause: WorkerJobSettleCause): number {
    let settled = 0
    for (const job of [...this.records.values()]) {
      if (job.settled) continue
      settled += 1
      job.forceSettle(cause)
    }
    return settled
  }

  /** Every retained job, oldest first. */
  snapshots(): readonly WorkerJobSnapshot[] {
    return [...this.records.values()].map(job => job.snapshot())
  }

  /** One retained job by id. */
  get(id: string): WorkerJobSnapshot | undefined {
    return this.records.get(id)?.snapshot()
  }

  private publish(event: WorkerJobEvent): void {
    for (const listener of [...this.listeners]) {
      try { listener(event) } catch { /* a subscriber cannot change an execution outcome */ }
    }
  }

  /** Keep the newest {@link RETAINED_JOBS} records; the live ones are never dropped. */
  private trim(): void {
    if (this.records.size <= RETAINED_JOBS) return
    for (const [id, job] of this.records) {
      if (this.records.size <= RETAINED_JOBS) return
      if (job.settled) this.records.delete(id)
    }
  }
}
