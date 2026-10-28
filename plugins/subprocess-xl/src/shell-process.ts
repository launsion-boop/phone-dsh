// SPDX-License-Identifier: MIT
/**
 * The Worker-local `bash -c` handle (PLAN D12).
 *
 * One handle per command, just like the desktop `LocalWorkerProcess`, but the
 * child is the just-bash core instead of `node:child_process`: inside the
 * Worker that module is the runtime's JavaScript shell, which parses only four
 * node kinds and ships 41 programs. The handle keeps the exact
 * `SubprocessHandle` shape (offset-based collected output, raw pipes, a
 * termination procedure, range quiescence), so the DSH seam does not know which
 * shell core is behind it.
 * @module @phone-dsh/dsh-subprocess-xl/shell-process
 */

import { PassThrough, Writable } from 'node:stream'
import type { Readable } from 'node:stream'
import type {
  SubprocessCollectedOutputs, SubprocessHandle, SubprocessOutcome, SubprocessOutputMode,
  SubprocessOutputReader, SubprocessSpawnSpec,
} from '@deepseek-ai/dsh-subprocess'
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output'
import type { ManagedProcessBinding } from '@deepseek-ai/dsh-subprocess-local/output'
import { stdinEofTimeoutFromEnv } from '@phone-dsh/dsh-shell-ext'
import type { WorkerShell } from '@phone-dsh/dsh-shell-ext'
import { localEnvironment } from './local.ts'
import { flushWorkerVfs } from './durability.ts'
import { isTimeoutReason } from './signal.ts'
import { MAX_TIMER_DELAY_MS } from './jobs.ts'
import type { WorkerCommandJob, WorkerJobSettleCause } from './jobs.ts'

/** Largest grace a force settlement may wait for a non-cooperative engine. */
const MAX_FORCE_SETTLE_GRACE_MS = 60_000

/**
 * Bound on the settlement a job-owner hard termination may wait for a
 * non-cooperative engine. It must stay well inside the host's 20 s drain
 * window even when the spawn spec carries a larger grace (G2-FIX-104).
 */
const HARD_SETTLE_GRACE_MS = 5_000

/** One `bash -c` running on the just-bash core. */
export class ShellWorkerProcess implements SubprocessHandle {
  readonly stdin: Writable | undefined
  readonly stdout: Readable | undefined
  readonly stderr: Readable | undefined
  readonly control = undefined
  readonly collected: SubprocessCollectedOutputs
  readonly done: Promise<SubprocessOutcome>
  private readonly spec: SubprocessSpawnSpec
  private readonly shell: WorkerShell
  private readonly out = new PassThrough()
  private readonly err = new PassThrough()
  private readonly input = new PassThrough()
  private readonly inputChunks: Buffer[] = []
  private readonly inputClosed = Promise.withResolvers<void>()
  private readonly collectors: Partial<Record<'stdout' | 'stderr', OutputCollector>> = {}
  private readonly exited = Promise.withResolvers<SubprocessOutcome>()
  private readonly quiet = Promise.withResolvers<void>()
  private readonly detachAbort: () => void
  private readonly stdinEofTimeoutMs: number
  private readonly lifetime = new AbortController()
  private job: WorkerCommandJob | undefined
  private deadlineMs: number | undefined
  private deadlineTimer: NodeJS.Timeout | undefined
  private forceTimer: NodeJS.Timeout | undefined
  private settledOutcome: SubprocessOutcome | undefined
  private settledError: Error | undefined
  private cancelCause: WorkerJobSettleCause | undefined
  private started = false
  private inputClosedResolved = false
  private settled = false
  private quiescent = false
  private terminateRequested = false

  private readonly terminateInterpreter: ((cause: WorkerJobSettleCause) => number) | undefined
  /**
   * True when the deadline came from the spawn spec instead of the upstream
   * executor's fused signal. The two paths report different timeout shapes:
   * a direct caller gets the conventional 124 result, while the upstream
   * executor classifies its own aborted signal.
   */
  private readonly explicitDeadline: boolean

  constructor(
    spec: SubprocessSpawnSpec,
    spill: ManagedProcessBinding,
    shell: WorkerShell,
    options: {
      readonly stdinEofTimeoutMs?: number
      /**
       * Hard termination of the WASI dispatches this command may hold
       * (G2-FIX-104). Returns how many were actually cut off; a non-zero
       * count lets the handle settle at the deadline instead of waiting for
       * an interpreter that is blocked in a proxied syscall.
       */
      readonly terminateInterpreter?: (cause: WorkerJobSettleCause) => number
      /** The deadline came from the spawn spec, not the caller's signal. */
      readonly explicitDeadline?: boolean
    } = {},
  ) {
    this.spec = spec
    this.shell = shell
    this.terminateInterpreter = options.terminateInterpreter
    this.explicitDeadline = options.explicitDeadline === true
    this.stdinEofTimeoutMs = options.stdinEofTimeoutMs ?? stdinEofTimeoutFromEnv(process.env)
    this.stdin = spec.stdio.stdin === 'pipe' ? this.input : undefined
    this.stdout = spec.stdio.stdout === 'pipe' ? this.out : undefined
    this.stderr = spec.stdio.stderr === 'pipe' ? this.err : undefined
    for (const stream of [this.out, this.err, this.input]) stream.on('error', () => {})
    const reader = (name: 'stdout' | 'stderr', mode: SubprocessOutputMode): SubprocessOutputReader | undefined => {
      if (mode === 'pipe') return undefined
      if (mode === 'inherit') {
        (name === 'stdout' ? this.out : this.err).pipe(name === 'stdout' ? process.stdout : process.stderr, { end: false })
        return undefined
      }
      const collector = new OutputCollector(mode.maxBytes, name, mode.spill === undefined
        ? undefined
        : { maxBytes: mode.spill.maxBytes, dir: spill.spillDir, onFailure: spill.onSpillFailure })
      this.collectors[name] = collector
      return { readFrom: (offset: number) => collector.readFrom(offset) }
    }
    const stdout = reader('stdout', spec.stdio.stdout)
    const stderr = reader('stderr', spec.stdio.stderr)
    this.collected = { ...stdout === undefined ? {} : { stdout }, ...stderr === undefined ? {} : { stderr } }
    this.done = this.exited.promise
    void this.done.catch(() => {})
    if (spec.stdio.stdin === 'pipe') {
      this.input.on('data', (chunk: Buffer) => { this.inputChunks.push(Buffer.from(chunk)) })
      // `end()` on the Writable emits `finish`; a destroyed stream emits
      // `close`. Accept all three so a piped command never waits forever.
      for (const event of ['finish', 'end', 'close']) {
        this.input.on(event, () => {
          this.inputClosedResolved = true
          this.inputClosed.resolve()
        })
      }
    }
    const onAbort = (): void => {
      const cause: WorkerJobSettleCause = spec.signal !== undefined && isTimeoutReason(spec.signal.reason)
        ? 'timeout'
        : 'cancel'
      // The job owner settles outside the execution-mutex domain; a bare
      // handle (a component test) keeps the soft termination path.
      if (this.job !== undefined) this.job.forceSettle(cause)
      else this.terminate(cause)
    }
    spec.signal?.addEventListener('abort', onAbort, { once: true })
    this.detachAbort = () => { spec.signal?.removeEventListener('abort', onAbort) }
  }

  /**
   * Attach the job account and arm its deadline.
   *
   * Called once, before the execution lane admits the command, so a command
   * queued behind a wedged one is bounded from dispatch time exactly like the
   * upstream executor's deadline (which starts before the process spawns).
   * @param job - the registered job record.
   */
  attachJob(job: WorkerCommandJob): void {
    if (this.job !== undefined) throw new Error('subprocess-xl: this execution already has a job')
    this.job = job
    // Giving the engine the deadline is what makes a cooperative command
    // report the conventional timeout result (124) at the bound. The registry
    // owns the settlement timer itself (G2-FIX-104): it must fire while the
    // per-workspace execution lane is held by a wedged interpreter, which an
    // in-handle timer cannot guarantee once the settlement it starts waits
    // behind that same lane.
    if (job.timeoutMs !== undefined) this.deadlineMs = job.timeoutMs
    if (job.timeoutMs !== undefined && !job.deadlineOwnedByRegistry) {
      this.deadlineTimer = setTimeout(() => { this.onDeadline() }, Math.max(1, Math.min(job.timeoutMs, MAX_TIMER_DELAY_MS)))
      this.deadlineTimer.unref?.()
    }
    if (this.settledError !== undefined) job.fail(this.settledError)
    else if (this.settledOutcome !== undefined) job.settle(this.settledOutcome, this.cancelCause ?? 'exit')
  }

  /** Start the shell; called once the per-workspace mutex and governor grant a slot. */
  begin(): void {
    if (this.started || this.settled) return
    this.started = true
    this.job?.markStarted()
    void this.run()
  }

  /** True once this handle reached a terminal state. */
  get finished(): boolean { return this.settled }

  /** Reject a handle that never got a slot (admission closed while queued). */
  abort(error: unknown): void {
    this.fail(error)
  }

  private async run(): Promise<void> {
    try {
      if (this.spec.stdio.stdin === 'pipe') await this.waitForStdinEof()
      const stdin = this.spec.stdio.stdin === 'pipe'
        ? Buffer.concat(this.inputChunks).toString('utf8')
        : typeof this.spec.stdio.stdin === 'object' ? this.spec.stdio.stdin.data : ''
      if (this.terminateRequested) this.lifetime.abort(new Error('subprocess-xl: terminated before start'))
      const result = await this.shell.run(this.spec.argv, {
        cwd: this.spec.cwd,
        env: localEnvironment(this.spec) as Record<string, string | undefined>,
        stdin,
        signal: this.lifetime.signal,
        // The job deadline is the shell's own wall clock, so a cooperative
        // engine produces the conventional timeout result (124) at exactly
        // the bound the job account records.
        timeoutMs: this.deadlineMs ?? this.shell.commandTimeoutMs,
      })
      // A forced settlement already reported the command; the abandoned engine
      // result must not write into sealed streams or re-settle the handle.
      if (this.settled) return
      // Once the caller terminates the handle, that is the outcome: a shell
      // engine may settle a cancelled command with its own deadline status
      // (just-bash maps every abort to 124), and relaying that status would
      // turn a cancellation into a timeout.
      if (this.terminateRequested) {
        // Writes the cancelled command already made still belong to the WAL.
        // A cooperative engine that reported its own wall-clock timeout keeps
        // the conventional 124 result; an engine that had to be cut off is a
        // SIGTERM outcome. A dead channel must not turn cancellation into a
        // different failure shape.
        await flushWorkerVfs().catch(() => {})
        if (this.settled) return
        // The engine was cut off by a deadline: report the conventional 124
        // even though our own abort surfaced as an engine cancellation. An
        // engine that finished normally and only hangs at the command-boundary
        // flush stays a SIGTERM settlement (the force-timer case).
        const interruptedByDeadline = this.explicitDeadline && this.cancelCause === 'timeout'
          && (result.timedOut || result.aborted || result.exitCode === 130)
        if (interruptedByDeadline) {
          this.settle(124, null, 'timeout')
          return
        }
        this.settle(null, 'SIGTERM', this.cancelCause ?? 'cancel')
        return
      }
      if (result.missingProgram !== undefined) {
        await flushWorkerVfs().catch(() => {})
        if (this.settled) return
        throw Object.assign(new Error(`spawn ${result.missingProgram} ENOENT`), {
          code: 'ENOENT',
          path: result.missingProgram,
          syscall: 'spawn',
        })
      }
      this.emit('stdout', result.stdout)
      this.emit('stderr', result.stderr)
      // Command-boundary durability fence (G2-FIX-61): the sink publishes
      // VFS_MUT asynchronously, so reporting the exit before the host acked the
      // command's writes lets a Worker kill drop them. A refused mutation
      // rejects here and fails the command instead of being reported as a
      // success the host does not have. This await is the one place an
      // in-Worker command can hang *after* the engine finished: the job's
      // deadline bounds it, and the force timer settles the handle.
      await flushWorkerVfs()
      if (this.settled) return
      if (result.timedOut) {
        this.settle(124, null, 'timeout')
        return
      }
      this.settle(result.exitCode, result.aborted ? 'SIGTERM' : null, result.aborted ? 'cancel' : 'exit')
    } catch (error) {
      // A cancelled execution is a SIGTERM outcome, not a rejected spawn, even
      // when the engine rejects with its own abort error while unwinding.
      await flushWorkerVfs().catch(() => {})
      if (this.settled) return
      if (this.terminateRequested) this.settle(null, 'SIGTERM', this.cancelCause ?? 'cancel')
      else this.fail(error)
    }
  }

  /**
   * The job deadline expired.
   *
   * A cooperative engine settles itself at the same wall clock (it received
   * the deadline as `timeoutMs`), so this only starts the force timer: a shell
   * that never returns — or a command-boundary flush that never reaches its
   * ack — must still be accounted and release the lane. A command that has not
   * started yet has no engine to cooperate: it settles here, as the executor's
   * own preparation timeout does upstream.
   */
  private onDeadline(): void {
    if (this.settled || this.quiescent) return
    this.deadlineTimer = undefined
    this.job?.beginSettling('timeout')
    if (!this.started) {
      this.settle(124, null, 'timeout')
      return
    }
    this.armForceTimer('timeout')
  }

  /**
   * Hard-terminate the execution from the job owner (G2-FIX-104).
   *
   * This is the external settlement path: it runs synchronously from the
   * registry's deadline timer or drain fan-out, terminates whatever WASI
   * dispatch the command is blocked in, aborts the shell engine and settles
   * the handle without awaiting the engine, the execution mutex or a
   * command-boundary flush. A live WASI dispatch is settled immediately; a
   * cooperative shell engine still gets its bounded grace so a normal timeout
   * result (124) is preserved.
   * @param cause - why the job is being cut off.
   */
  hardTerminate(cause: WorkerJobSettleCause): void {
    if (this.settled || this.quiescent) return
    if (!this.started) {
      // Queued behind the wedged lane: there is no engine to stop.
      this.job?.beginSettling(cause)
      this.settle(cause === 'timeout' ? 124 : null, cause === 'timeout' ? null : 'SIGTERM', cause)
      return
    }
    if (this.cancelCause === undefined) this.cancelCause = cause
    this.terminateRequested = true
    // A command still waiting for EOF on a piped stdin must not hold the slot.
    this.inputClosedResolved = true
    this.inputClosed.resolve()
    // The interpreter lives in a dedicated tool worker and can be stuck in a
    // proxied syscall that never observes the shell abort. Terminating it is
    // synchronous and settles its `run()` promise with the job's own cause.
    // It runs before the engine abort: just-bash wraps an aborted command in
    // its own `ExecutionAbortedError`, which would erase timeout vs drain.
    const stopped = this.terminateInterpreter?.(cause) ?? 0
    if (stopped > 0) {
      this.lifetime.abort(new Error('subprocess-xl: execution hard-terminated'))
      this.forceSettle(cause, true)
      return
    }
    this.lifetime.abort(new Error('subprocess-xl: execution hard-terminated'))
    this.armForceTimer(cause, HARD_SETTLE_GRACE_MS)
  }

  /** Arm the bounded settlement that follows an uncooperative termination. */
  private armForceTimer(cause: WorkerJobSettleCause, maxGraceMs = MAX_FORCE_SETTLE_GRACE_MS): void {
    if (this.forceTimer !== undefined || this.settled) return
    const grace = Math.max(1, Math.min(this.spec.graceMs, maxGraceMs))
    this.forceTimer = setTimeout(() => {
      this.forceTimer = undefined
      this.forceSettle(cause)
    }, grace)
    this.forceTimer.unref?.()
  }

  /**
   * Settle a command the engine/managed range did not stop within the grace.
   * @param cause - why the job is being cut off.
   * @param interpreterStopped - true when a live WASI dispatch was hard-stopped
   *   (its `run()` promise is already terminal); a direct deadline then reports
   *   the conventional 124 result.
   */
  private forceSettle(cause: WorkerJobSettleCause, interpreterStopped = false): void {
    if (this.settled) return
    // Last chance for an interpreter that started after the first hard
    // termination attempt (the dispatch was still mounting): terminating it
    // here is what makes the settlement external rather than optimistic.
    if (cause !== 'exit') this.terminateInterpreter?.(cause)
    // Best effort: the writes the cancelled command already made still belong
    // to the WAL, but a channel that stopped acking must not hold the lane.
    void flushWorkerVfs().catch(() => {})
    if (interpreterStopped && this.explicitDeadline && cause === 'timeout') {
      this.settle(124, null, 'timeout')
      return
    }
    this.settle(null, 'SIGTERM', cause)
  }

  /**
   * Wait for the caller's stdin EOF, but never forever.
   *
   * The shell cannot start a piped command without deciding how much input
   * belongs to it. A caller that keeps the pipe open (a crashed protocol, a
   * lost stream end) must fail the command with a structured error instead of
   * holding the per-workspace execution lane until the shell's wall clock.
   */
  private async waitForStdinEof(): Promise<void> {
    if (this.inputClosedResolved) return
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        this.inputClosed.promise,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => {
            reject(Object.assign(
              new Error(
                `subprocess-xl: stdin was not closed within ${this.stdinEofTimeoutMs} ms; `
                + 'the caller never delivered EOF for the piped command',
              ),
              { code: 'E_STDIN_EOF_TIMEOUT' },
            ))
          }, this.stdinEofTimeoutMs)
          timer.unref?.()
        }),
      ])
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  }

  private emit(name: 'stdout' | 'stderr', text: string): void {
    if (text === '' || this.settled) return
    const bytes = Buffer.from(text, 'utf8')
    const collector = this.collectors[name]
    if (collector !== undefined) collector.push(bytes)
    else if (this.spec.stdio[name] === 'pipe') (name === 'stdout' ? this.out : this.err).write(bytes)
    else if (this.spec.stdio[name] === 'inherit') (name === 'stdout' ? process.stdout : process.stderr).write(bytes)
  }

  /**
   * Stop the command by the first interruption cause.
   *
   * The engine is asked to abort (SIGTERM rung) and the job's grace starts a
   * total settlement bound: an engine or a command-boundary flush that ignores
   * the abort can no longer hold the per-workspace lane forever.
   * @param cause - why the execution is stopping.
   */
  terminate(cause: WorkerJobSettleCause = 'cancel'): void {
    if (this.quiescent || this.settled) return
    // An attached job is settled by its owner, which hard-terminates the WASI
    // dispatch outside the execution-mutex domain (G2-FIX-104). A bare handle
    // (no job) keeps the soft engine-abort path.
    if (this.job !== undefined) {
      this.job.forceSettle(cause)
      return
    }
    if (!this.started) {
      this.settle(null, 'SIGTERM', cause)
      return
    }
    if (this.cancelCause === undefined) this.cancelCause = cause
    this.terminateRequested = true
    // A command still waiting for EOF on a piped stdin must not hold the slot.
    this.inputClosedResolved = true
    this.inputClosed.resolve()
    this.lifetime.abort(new Error('subprocess-xl: execution terminated'))
    this.armForceTimer(cause)
  }

  async waitForExit(signal?: AbortSignal): Promise<boolean> {
    if (this.quiescent) return true
    if (signal?.aborted) return false
    const aborted = Promise.withResolvers<false>()
    const onAbort = (): void => { aborted.resolve(false) }
    signal?.addEventListener('abort', onAbort, { once: true })
    try {
      return await Promise.race([this.quiet.promise.then(() => true as const), aborted.promise])
    } finally {
      signal?.removeEventListener('abort', onAbort)
    }
  }

  private clearTimers(): void {
    if (this.deadlineTimer !== undefined) clearTimeout(this.deadlineTimer)
    if (this.forceTimer !== undefined) clearTimeout(this.forceTimer)
    this.deadlineTimer = undefined
    this.forceTimer = undefined
  }

  private fail(error: unknown): void {
    if (this.settled) return
    this.settled = true
    this.quiescent = true
    this.settledError = error instanceof Error ? error : new Error(String(error))
    this.clearTimers()
    this.detachAbort()
    this.finishStreams()
    this.quiet.resolve()
    this.job?.fail(this.settledError)
    this.exited.reject(this.settledError)
  }

  private settle(code: number | null, signal: NodeJS.Signals | null, cause: WorkerJobSettleCause): void {
    if (this.settled) return
    this.settled = true
    this.quiescent = true
    this.settledOutcome = { exitCode: signal === null ? code : null, signal }
    this.clearTimers()
    this.detachAbort()
    this.finishStreams()
    this.quiet.resolve()
    this.job?.settle(this.settledOutcome, cause)
    this.exited.resolve(this.settledOutcome)
  }

  private finishStreams(): void {
    for (const collector of Object.values(this.collectors)) collector.seal()
    if (!this.out.writableEnded) this.out.end()
    if (!this.err.writableEnded) this.err.end()
    if (!this.input.writableEnded) this.input.end()
  }
}
