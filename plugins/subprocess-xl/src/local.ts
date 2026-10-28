// SPDX-License-Identifier: MIT
/**
 * The Worker-local executor (PLAN D12): `bash -c` and every command that can
 * write the workspace run in the runtime's own shell through `node:child_process`.
 * In the packed Worker that module is the DSH JavaScript shell; on a desktop
 * Node it is the real process layer, so this file is also the local half of
 * the desktop tests.
 *
 * The handle mirrors the exec-bridge handle shape exactly (offset-based
 * collected output, raw pipes, range quiescence), so the subprocess seam does
 * not know which side of the inversion it is talking to.
 *
 * Like its just-bash sibling it carries the job lifecycle (G2-FIX-82): a
 * deadline from the job account, and a bounded settlement after any
 * termination, so a child that ignores `SIGTERM` cannot hold the per-workspace
 * execution lane forever.
 * @module @phone-dsh/dsh-subprocess-xl/local
 */

import { spawn } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { PassThrough, Writable } from 'node:stream'
import type { Readable } from 'node:stream'
import type {
  SubprocessCollectedOutputs, SubprocessHandle, SubprocessOutcome, SubprocessOutputMode,
  SubprocessOutputReader, SubprocessSpawnSpec,
} from '@deepseek-ai/dsh-subprocess'
import { scrubbedParentEnv } from '@deepseek-ai/dsh-subprocess'
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output'
import type { ManagedProcessBinding } from '@deepseek-ai/dsh-subprocess-local/output'
import { isTimeoutReason } from './signal.ts'
import { MAX_TIMER_DELAY_MS } from './jobs.ts'
import type { WorkerCommandJob, WorkerJobSettleCause } from './jobs.ts'

type ExitFacts = SubprocessOutcome

/** Largest grace a force settlement may wait for an uncooperative child. */
const MAX_FORCE_SETTLE_GRACE_MS = 60_000

/** Environment for one local child: the scrubbed ambient base plus explicit entries. */
export function localEnvironment(spec: SubprocessSpawnSpec): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = scrubbedParentEnv()
  for (const [key, value] of Object.entries(spec.env ?? {})) {
    if (value === undefined) delete env[key]
    else env[key] = value
  }
  return env
}

/** One command running in the Worker's own shell. */
export class LocalWorkerProcess implements SubprocessHandle {
  readonly stdin: Writable | undefined
  readonly stdout: Readable | undefined
  readonly stderr: Readable | undefined
  readonly control = undefined
  readonly collected: SubprocessCollectedOutputs
  readonly done: Promise<SubprocessOutcome>
  private readonly spec: SubprocessSpawnSpec
  private readonly out = new PassThrough()
  private readonly err = new PassThrough()
  private readonly input = new PassThrough()
  private readonly collectors: Partial<Record<'stdout' | 'stderr', OutputCollector>> = {}
  private readonly exited = Promise.withResolvers<ExitFacts>()
  private readonly quiet = Promise.withResolvers<void>()
  private readonly detachAbort: () => void
  private job: WorkerCommandJob | undefined
  private deadlineTimer: NodeJS.Timeout | undefined
  private settledOutcome: SubprocessOutcome | undefined
  private settledError: Error | undefined
  private cancelCause: WorkerJobSettleCause | undefined
  private child: ChildProcess | undefined
  private started = false
  private settled = false
  private quiescent = false
  private terminateRequested = false
  private killTimer: NodeJS.Timeout | undefined
  private forceTimer: NodeJS.Timeout | undefined

  constructor(spec: SubprocessSpawnSpec, spill: ManagedProcessBinding) {
    this.spec = spec
    this.stdin = spec.stdio.stdin === 'pipe' ? this.input : undefined
    this.stdout = spec.stdio.stdout === 'pipe' ? this.out : undefined
    this.stderr = spec.stdio.stderr === 'pipe' ? this.err : undefined
    for (const stream of [this.out, this.err, this.input]) stream.on('error', () => {})
    const reader = (name: 'stdout' | 'stderr', mode: SubprocessOutputMode): SubprocessOutputReader | undefined => {
      if (mode === 'pipe') return undefined
      if (mode === 'inherit') return undefined
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
    const onAbort = (): void => {
      const cause: WorkerJobSettleCause = spec.signal !== undefined && isTimeoutReason(spec.signal.reason)
        ? 'timeout'
        : 'cancel'
      if (this.job !== undefined) this.job.forceSettle(cause)
      else this.terminate(cause)
    }
    spec.signal?.addEventListener('abort', onAbort, { once: true })
    this.detachAbort = () => { spec.signal?.removeEventListener('abort', onAbort) }
  }

  /**
   * Attach the job account and arm its deadline (before the lane admits the
   * command, so queue time counts against the same wall clock).
   * @param job - the registered job record.
   */
  attachJob(job: WorkerCommandJob): void {
    if (this.job !== undefined) throw new Error('subprocess-xl: this execution already has a job')
    this.job = job
    // The job registry owns the deadline (G2-FIX-104): its timer fires even
    // while this handle holds the per-workspace execution lane.
    if (job.timeoutMs !== undefined && !job.deadlineOwnedByRegistry) {
      this.deadlineTimer = setTimeout(() => { this.onDeadline() }, Math.max(1, Math.min(job.timeoutMs, MAX_TIMER_DELAY_MS)))
      this.deadlineTimer.unref?.()
    }
    if (this.settledError !== undefined) job.fail(this.settledError)
    else if (this.settledOutcome !== undefined) job.settle(this.settledOutcome, this.cancelCause ?? 'exit')
  }

  /** Start the child; called by the per-workspace execution mutex. */
  begin(): void {
    if (this.started || this.settled) return
    this.started = true
    this.job?.markStarted()
    const stdio: Array<'pipe' | 'ignore' | 'inherit'> = [
      this.spec.stdio.stdin === 'pipe' || typeof this.spec.stdio.stdin === 'object' ? 'pipe' : 'ignore',
      this.spec.stdio.stdout === 'pipe' || typeof this.spec.stdio.stdout === 'object' ? 'pipe' : 'inherit',
      this.spec.stdio.stderr === 'pipe' || typeof this.spec.stdio.stderr === 'object' ? 'pipe' : 'inherit',
    ]
    let child: ChildProcess
    try {
      child = spawn(this.spec.argv[0] as string, [...this.spec.argv.slice(1)], {
        cwd: this.spec.cwd,
        env: localEnvironment(this.spec),
        stdio,
      })
    } catch (error) {
      this.fail(error)
      return
    }
    this.child = child
    child.on('error', (error) => { this.fail(error) })
    child.on('close', (code, signal) => { this.settle(code, signal, this.cancelCause ?? 'exit') })
    this.bind('stdout', child.stdout, this.spec.stdio.stdout)
    this.bind('stderr', child.stderr, this.spec.stdio.stderr)
    if (this.spec.stdio.stdin === 'pipe') this.input.pipe(child.stdin as Writable)
    else if (typeof this.spec.stdio.stdin === 'object') {
      child.stdin?.end(Buffer.from(this.spec.stdio.stdin.data, 'utf8'))
    }
    if (this.terminateRequested) this.signal('SIGTERM')
  }

  /** True once this handle reached a terminal state. */
  get finished(): boolean { return this.settled }

  /** Reject a handle that never got an execution slot. */
  abort(error: unknown): void {
    this.fail(error)
  }

  /**
   * Stop the command by the first interruption cause.
   * @param cause - why the execution is stopping.
   */
  terminate(cause: WorkerJobSettleCause = 'cancel'): void {
    if (this.quiescent || this.settled) return
    // An attached job is settled by its owner's hard terminator (G2-FIX-104);
    // a bare handle keeps the soft SIGTERM/grace path.
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
    this.signal('SIGTERM')
    const grace = Math.max(1, Math.min(this.spec.graceMs, MAX_FORCE_SETTLE_GRACE_MS))
    this.killTimer ??= setTimeout(() => { this.signal('SIGKILL') }, grace)
    this.killTimer.unref?.()
    // The managed range is bounded even when the child does not die on SIGKILL
    // (a stuck syscall in a mocked runtime): the lane must still be released.
    this.forceTimer ??= setTimeout(() => {
      this.forceTimer = undefined
      this.settle(null, 'SIGTERM', cause)
    }, grace)
    this.forceTimer.unref?.()
  }

  /**
   * Hard-terminate from the job owner (G2-FIX-104).
   *
   * Sends SIGKILL (no SIGTERM grace) and settles the handle at once, so the
   * per-workspace lane is released even when the child is stuck in a syscall
   * or the managed range never reports its close event.
   * @param cause - why the job is being cut off.
   */
  hardTerminate(cause: WorkerJobSettleCause): void {
    if (this.settled || this.quiescent) return
    if (this.cancelCause === undefined) this.cancelCause = cause
    this.job?.beginSettling(cause)
    this.terminateRequested = true
    if (this.started) this.signal('SIGKILL')
    this.settle(cause === 'timeout' ? 124 : null, cause === 'timeout' ? null : 'SIGTERM', cause)
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

  /** The job deadline expired: stop the child and bound its settlement. */
  private onDeadline(): void {
    if (this.settled || this.quiescent) return
    this.deadlineTimer = undefined
    this.job?.beginSettling('timeout')
    if (!this.started) {
      this.settle(124, null, 'timeout')
      return
    }
    this.terminate('timeout')
  }

  private clearTimers(): void {
    if (this.deadlineTimer !== undefined) clearTimeout(this.deadlineTimer)
    if (this.killTimer !== undefined) clearTimeout(this.killTimer)
    if (this.forceTimer !== undefined) clearTimeout(this.forceTimer)
    this.deadlineTimer = undefined
    this.killTimer = undefined
    this.forceTimer = undefined
  }

  private bind(name: 'stdout' | 'stderr', stream: Readable | null, mode: SubprocessOutputMode): void {
    if (stream === null) return
    const collector = this.collectors[name]
    if (collector !== undefined) stream.on('data', (chunk: Buffer) => { collector.push(chunk) })
    else if (mode === 'pipe') stream.pipe(name === 'stdout' ? this.out : this.err, { end: true })
    else if (mode === 'inherit') stream.pipe(name === 'stdout' ? process.stdout : process.stderr, { end: false })
    else stream.resume()
  }

  private signal(value: NodeJS.Signals): void {
    if (this.child === undefined || this.quiescent) return
    try {
      this.child.kill(value)
    } catch {
      // The child already went away.
    }
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

  private settle(code: number | null, signal: NodeJS.Signals | null, cause: WorkerJobSettleCause = 'exit'): void {
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
