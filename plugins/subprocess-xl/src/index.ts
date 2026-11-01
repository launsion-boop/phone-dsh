// SPDX-License-Identifier: MIT
/**
 * `ctx.subprocess` with the executor inversion of PLAN D12 / exec.md §3.
 *
 * - On the phone Worker (`channel` / `fetch` transport) every command runs in
 *   the Worker's own shell (`node:child_process`, which the packed runtime
 *   backs with its JavaScript shell). `bash -c` and every program that can
 *   write the workspace never cross the channel.
 * - Only a read-only accelerator advertised by the host HELLO caps
 *   (`accelerator:<name>`) travels as EXEC_REQ 0x20, carrying
 *   `requires_mseq = last emitted sink mseq` and the exec.md §1 `idem_key`
 *   injected by the channel transport at dispatch time.
 * - On the desktop transport (`node:http`) every command still goes to the
 *   reference exec bridge, preserving the nodejs-mobile path and `sim/`.
 *
 * Structure follows `@deepseek-ai/dsh-subprocess-ssh`: one handle per process,
 * collect-mode output through the shared `OutputCollector`, a provider-owned
 * termination procedure, and quiescence observed from the provider rather than
 * inferred locally. A per-workspace mutex serializes executions so parallel
 * sub-agent writes meet at tool-call boundaries; the mseq revision is re-read
 * when the slot is granted, because the accelerator's EXEC_REQ is built after
 * the mutex admits it.
 *
 * Every command that stays in the Worker is a job ({@link WorkerJobRegistry},
 * G2-FIX-82): registered before dispatch with the Worker's command budget,
 * bounded after any termination, and always settled, so a wedged engine or a
 * command-boundary flush that never reaches its ack can no longer hold the
 * mutex with no event (the G2-A10 shape: `timeoutMs` expired and nothing
 * settled).
 * @module @phone-dsh/dsh-subprocess-xl
 */

import { randomUUID } from 'node:crypto'
import { posix } from 'node:path'
import { PassThrough, Writable } from 'node:stream'
import type { Duplex, Readable } from 'node:stream'
import type { Context } from '@deepseek-ai/cordis'
import { SubprocessExecutableNotFoundError, SubprocessRuntime } from '@deepseek-ai/dsh-subprocess'
import type {
  SubprocessCollectedOutputs,
  SubprocessHandle,
  SubprocessOutcome,
  SubprocessOutputMode,
  SubprocessOutputReader,
  SubprocessSpawnSpec,
  SubprocessTerminalEnvironment,
  SubprocessTerminalHandle,
  SubprocessTerminalSpawnSpec,
} from '@deepseek-ai/dsh-subprocess'
import { OutputCollector, logSpillFailure, prepareManagedProcessBinding } from '@deepseek-ai/dsh-subprocess-local/output'
import type { ManagedProcessBinding } from '@deepseek-ai/dsh-subprocess-local/output'
import { ExecBridgeError, currentToolCall } from '@phone-dsh/dsh-exec-bridge'
import type { EventStream, ExecEvent, ExecRequest, XlExecBridge } from '@phone-dsh/dsh-exec-bridge'
import {
  VfsFileSystem,
  WorkerShell,
  createExecBridgeAccelerators,
  createWorkerCommands,
  isShellInvocation,
  isWorkerShellProgram,
  resolveShellMode,
  shellTimeoutFromEnv,
  workerShellIdentity,
} from '@phone-dsh/dsh-shell-ext'
import { CONFINE_MARKER } from './marker.ts'
import { LocalWorkerProcess } from './local.ts'
import { ShellWorkerProcess } from './shell-process.ts'
import { AdmissionClosedError, ExecutionGovernor } from './governor.ts'
import { settleWorkerInterpreter } from './interpreter.ts'
import { WorkerJobRegistry } from './jobs.ts'
import { RIPGREP_PROGRAM, resolveProgramIdentity, workerRipgrepArgv } from './program.ts'

export { CONFINE_MARKER } from './marker.ts'
export { LocalWorkerProcess } from './local.ts'
export { ShellWorkerProcess } from './shell-process.ts'
export { WORKER_VFS_FLUSH_GLOBAL, flushWorkerVfs } from './durability.ts'
export { AdmissionClosedError, ExecutionGovernor, parseThermal } from './governor.ts'
export type { ExecutionGovernorOptions, ThermalState } from './governor.ts'
export {
  INTERPRETER_STOP_CAUSES, WORKER_TOOLBOX_GLOBAL, interpreterStopCause, settleWorkerInterpreter,
} from './interpreter.ts'
export type { InterpreterStopCause } from './interpreter.ts'
export { WorkerCommandJob, WorkerJobRegistry } from './jobs.ts'
export type {
  WorkerJobEvent,
  WorkerJobEventType,
  WorkerJobHooks,
  WorkerJobSettleCause,
  WorkerJobSnapshot,
  WorkerJobSpec,
  WorkerJobStatus,
} from './jobs.ts'
export { isTimeoutReason } from './signal.ts'
export { RIPGREP_PROGRAM, isRipgrepExecutable, resolveProgramIdentity, workerRipgrepArgv } from './program.ts'

/**
 * The subprocess spec plus the Worker deadline extension.
 *
 * The DSH subprocess seam carries deadlines only as an abort signal (the shell
 * executor owns the timeout value and fuses it into the spawn signal). A
 * direct caller of this provider — the Worker entry, a component test — can
 * pass the deadline explicitly instead, and the job lifecycle then enforces it
 * exactly like the upstream `bash` tool would: the command settles at the
 * bound, the job account records `timeout`, and the lane is released.
 */
export interface XlWorkerSpawnSpec extends SubprocessSpawnSpec {
  /** Foreground deadline in milliseconds; defaults to the Worker shell budget. */
  readonly timeoutMs?: number
  /**
   * Trusted out-of-band idempotency key for accelerator dispatch. The phone
   * console passes its client-owned `execId` here; a shell variable with the
   * same name is never consulted.
   */
  readonly idempotencyKey?: string
}

/** Environment variable carrying the tool call's idempotency key into the guest. */
export const IDEMPOTENCY_ENV = 'XL_IDEMPOTENCY_KEY'

const MAX_REATTACH = 5

type ExitEvent = Extract<ExecEvent, { type: 'exit' }>

/** Serialize executions per workspace so parallel writes meet at tool-call boundaries. */
export class ExecutionMutex {
  private readonly tails = new Map<string, Promise<void>>()

  /**
   * Run one task after every earlier task for the same key settled.
   * @param key - workspace identity.
   * @param task - the execution's lifetime (spawn through quiescence).
   */
  run<T>(key: string, task: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve()
    const result = previous.then(task, task)
    const tail = result.then(() => {}, () => {})
    this.tails.set(key, tail)
    void tail.finally(() => { if (this.tails.get(key) === tail) this.tails.delete(key) })
    return result
  }
}

/**
 * True when argv[0] names an advertised accelerator (exec.md §3).
 *
 * The comparison is by program identity, so an absolute executable path (the
 * packaged ripgrep's `resolveRgPath()`, for example) matches the bare name the
 * host advertised, and a bare name is unchanged.
 */
export function isAccelerator(program: string, hello: { capabilities: { accelerators?: readonly string[] } }): boolean {
  const advertised = hello.capabilities.accelerators ?? []
  return advertised.includes(resolveProgramIdentity(program, advertised))
}

/** Strip the sandbox marker from an argv (still in the source path space). */
export function stripConfineMarker(argv: readonly string[]): { argv: string[]; mode?: 'read-only' | 'workspace-write'; workspaceRoot?: string } {
  if (argv[0] !== CONFINE_MARKER) return { argv: [...argv] }
  const [, mode, root, separator, ...rest] = argv
  if ((mode !== 'read-only' && mode !== 'workspace-write') || root === undefined || separator !== '--' || rest.length === 0) {
    throw new Error('subprocess-xl: malformed confinement argv')
  }
  return { argv: rest, mode, workspaceRoot: root }
}

/**
 * Replace argv[0] with a resolved program identity, keeping a confinement
 * marker in place (`[marker, mode, root, '--', program, ...args]`).
 * @param argv - the caller's argv, with or without the marker.
 * @param identity - the resolved bare program name.
 * @returns a copy of argv with the program slot replaced.
 */
export function withProgramIdentity(argv: readonly string[], identity: string): string[] {
  const stripped = stripConfineMarker(argv)
  const offset = argv.length - stripped.argv.length
  return [...argv.slice(0, offset), identity, ...stripped.argv.slice(1)]
}

/** Strip the marker and map its root into the guest for a host request. */
function stripConfine(bridge: Pick<XlExecBridge, 'paths'>, argv: readonly string[]): { argv: string[]; confine?: ExecRequest['confine'] } {
  const stripped = stripConfineMarker(argv)
  if (stripped.mode === undefined || stripped.workspaceRoot === undefined) return { argv: stripped.argv }
  return {
    argv: stripped.argv,
    confine: { mode: stripped.mode, workspace_root: guestPath(bridge, stripped.workspaceRoot, 'confinement root') },
  }
}

/** Build the bridge request; throws synchronously for invalid input, as the seam requires. */
export function buildExecRequest(bridge: Pick<XlExecBridge, 'paths' | 'hello'>, spec: SubprocessSpawnSpec, execId: string): ExecRequest {
  if (spec.argv.length === 0 || spec.argv[0] === '') throw new Error('subprocess-xl: argv must name a program')
  if (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0) throw new Error('subprocess-xl: graceMs must be positive and finite')
  if ((spec.stdio as { control?: string }).control !== undefined) {
    throw new Error('subprocess-xl: the exec bridge has no control channel (PTC Node programs are disabled in the phone profile)')
  }
  const extended = spec as XlWorkerSpawnSpec
  if (extended.timeoutMs !== undefined && (!Number.isFinite(extended.timeoutMs) || extended.timeoutMs <= 0)) {
    throw new Error('subprocess-xl: timeoutMs must be a positive finite number')
  }
  const stripped = stripConfine(bridge, spec.argv)
  const env: Record<string, string | null> = {}
  for (const [key, value] of Object.entries(spec.env ?? {})) env[key] = value ?? null
  // Identity is ambient or out-of-band, never the caller's env map: a script
  // that exports XL_IDEMPOTENCY_KEY must not choose the host call identity.
  delete env[IDEMPOTENCY_ENV]
  const call = currentToolCall()
  if (extended.idempotencyKey !== undefined && extended.idempotencyKey !== '') {
    env[IDEMPOTENCY_ENV] = extended.idempotencyKey
  } else if (call !== undefined && call.key !== '') {
    env[IDEMPOTENCY_ENV] = call.key
  }
  const stdin = spec.stdio.stdin
  if (stdin === 'pipe' && bridge.hello.capabilities.stdin_pipe !== true) {
    throw new Error('subprocess-xl: the exec bridge does not support piped stdin')
  }
  return {
    exec_id: execId,
    argv: stripped.argv,
    cwd: guestPath(bridge, spec.cwd, 'cwd'),
    env,
    grace_ms: Math.min(60_000, Math.ceil(spec.graceMs)),
    ...extended.timeoutMs === undefined ? {} : { deadline: Date.now() + Math.ceil(extended.timeoutMs) },
    stdin: stdin === 'ignore'
      ? { mode: 'ignore' }
      : stdin === 'pipe' ? { mode: 'pipe' } : { mode: 'data', data: Buffer.from(stdin.data, 'utf8').toString('base64') },
    ...stripped.confine === undefined ? {} : { confine: stripped.confine },
  }
}

/** Map a harness path into the guest; a guest path inside a mount passes through. */
function guestPath(bridge: Pick<XlExecBridge, 'paths'>, path: string, what: string): string {
  if (!posix.isAbsolute(path)) throw new Error(`subprocess-xl: ${what} must be absolute, got ${JSON.stringify(path)}`)
  const mapped = bridge.paths.toGuest(path)
  if (mapped !== undefined) return mapped
  if (bridge.paths.toHost(path) !== undefined) return path
  throw new Error(`subprocess-xl: ${what} ${JSON.stringify(path)} is outside every exec-bridge mount`)
}

/** The next deterministic execution id for the current tool call, or a random one outside calls. */
export function nextExecId(): string {
  const call = currentToolCall()
  if (call === undefined) return `xl-${randomUUID()}`
  return `${call.key}-${call.spawns++}`
}

/** One guest execution behind the bridge. */
class BridgeProcess implements SubprocessHandle {
  readonly stdin: Writable | undefined
  readonly stdout: Readable | undefined
  readonly stderr: Readable | undefined
  readonly control: Duplex | undefined = undefined
  readonly collected: SubprocessCollectedOutputs
  readonly done: Promise<SubprocessOutcome>
  private readonly bridge: XlExecBridge
  private readonly spec: SubprocessSpawnSpec
  private request: ExecRequest
  private readonly out = new PassThrough()
  private readonly err = new PassThrough()
  private readonly collectors: Partial<Record<'stdout' | 'stderr', OutputCollector>> = {}
  private readonly lifetime = new AbortController()
  private readonly opened = Promise.withResolvers<void>()
  private readonly quiet = Promise.withResolvers<void>()
  private readonly exited = Promise.withResolvers<SubprocessOutcome>()
  private stream: EventStream | undefined
  private lastSeq = -1
  private exit: ExitEvent | undefined
  private quiescent = false
  private unobservable: Error | undefined
  private terminateRequested = false
  private cancelSent: Promise<void> | undefined
  private forceTimer: ReturnType<typeof setTimeout> | undefined
  private hardSettled = false
  private started = false
  private readonly detachAbort: () => void

  constructor(bridge: XlExecBridge, spec: SubprocessSpawnSpec, request: ExecRequest, spill: ManagedProcessBinding) {
    this.bridge = bridge
    this.spec = spec
    this.request = request
    this.stdout = spec.stdio.stdout === 'pipe' ? this.out : undefined
    this.stderr = spec.stdio.stderr === 'pipe' ? this.err : undefined
    this.stdin = spec.stdio.stdin === 'pipe' ? this.pipedStdin() : undefined
    for (const stream of [this.out, this.err, this.stdin]) stream?.on('error', () => {})
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
    const onAbort = (): void => { this.terminate() }
    spec.signal?.addEventListener('abort', onAbort, { once: true })
    this.detachAbort = () => { spec.signal?.removeEventListener('abort', onAbort) }
    this.done = this.exited.promise
    void this.done.catch(() => {})
    void this.opened.promise.catch(() => {})
  }

  /**
   * Start the execution; called once the per-workspace mutex grants the slot.
   * The EXEC_REQ is built by the channel transport only now, so
   * `requires_mseq` is the sink revision at that moment.
   */
  start(): void {
    if (this.started) return
    this.started = true
    void this.run()
  }

  /** Piped stdin: each write is one ordered `stdin` request after the execution opened. */
  private pipedStdin(): Writable {
    return new Writable({
      write: (chunk: Buffer, _encoding, callback) => {
        this.opened.promise
          .then(() => this.bridge.client.stdin(this.request.exec_id, { data: Buffer.from(chunk).toString('base64') }))
          .then(() => { callback() }, (error: unknown) => { callback(error as Error) })
      },
      final: (callback) => {
        this.opened.promise
          .then(() => this.bridge.client.stdin(this.request.exec_id, { eof: true }))
          .then(() => { callback() }, (error: unknown) => { callback(error as Error) })
      },
    })
  }

  /**
   * Read the event stream until the range is quiescent. `done` settles at the
   * `exit` event (the spawned command's facts); reading continues afterwards
   * so `waitForExit` can observe the range draining.
   */
  private async run(): Promise<void> {
    if (this.hardSettled) return
    try {
      this.stream = await this.openStream()
      if (this.hardSettled) return
      this.opened.resolve()
      if (this.terminateRequested) this.sendCancel()
      let attempts = 0
      for (;;) {
        try {
          for await (const event of this.stream) {
            this.handle(event)
            if (this.quiescent) break
          }
          if (this.exit !== undefined && this.quiescent) break
          throw new ExecBridgeError('exec bridge stream ended before the execution was quiescent', 'transport')
        } catch (error) {
          // A forced settlement owns the stream lifetime: never re-issue
          // EXEC_REQ for a handle the console/provider already released.
          if (this.hardSettled) return
          if (!(error instanceof ExecBridgeError) || error.code !== 'transport' || attempts >= MAX_REATTACH) throw error
          attempts++
          await new Promise(resolve => setTimeout(resolve, 100 * attempts))
          if (this.hardSettled) return
          this.stream = await this.bridge.client.events(this.request.exec_id, this.lastSeq, this.lifetime.signal)
        }
      }
    } catch (error) {
      this.opened.reject(error)
      if (!this.quiescent) this.unobservable = error instanceof Error ? error : new Error(String(error))
      this.quiet.resolve()
      this.finishStreams()
      this.exited.reject(error)
    } finally {
      this.stream?.close()
      this.detachAbort()
    }
  }

  /** Open the execution; an `exec_id` the provider retains for a different request is re-keyed once. */
  private async openStream(): Promise<EventStream> {
    try {
      return await this.bridge.client.exec(this.request, this.lifetime.signal)
    } catch (error) {
      if (!(error instanceof ExecBridgeError) || error.code !== 'exec_id_conflict') throw error
      this.request = { ...this.request, exec_id: `${this.request.exec_id}-r${randomUUID().slice(0, 8)}` }
      return await this.bridge.client.exec(this.request, this.lifetime.signal)
    }
  }

  private handle(event: ExecEvent): void {
    if (event.seq <= this.lastSeq) return
    this.lastSeq = event.seq
    switch (event.type) {
      case 'start':
        break
      case 'output': {
        const bytes = Buffer.from(event.data, 'base64')
        const collector = this.collectors[event.stream]
        if (collector !== undefined) collector.push(bytes)
        else (event.stream === 'stdout' ? this.out : this.err).write(bytes)
        break
      }
      case 'exit':
        this.exit = event
        this.finishStreams()
        if (event.status === 'failed' || event.status === 'rejected') {
          const error = Object.assign(new Error(`spawn ${this.request.argv[0]} failed in the guest: ${event.error ?? event.status}`), {
            code: /ENOENT/.test(event.error ?? '') ? 'ENOENT' : 'EXEC_BRIDGE_REJECTED',
            path: this.request.argv[0],
            syscall: 'spawn',
          })
          this.quiescent = true
          this.quiet.resolve()
          this.exited.reject(error)
          break
        }
        this.exited.resolve(outcomeOf(event))
        if (event.quiescent) { this.quiescent = true; this.quiet.resolve() }
        break
      case 'quiescent':
        this.quiescent = true
        this.quiet.resolve()
        break
      case 'error':
        throw new ExecBridgeError(`exec bridge failed: ${event.message}`, event.code)
      default:
        // Unknown event types are ignored (additive protocol evolution).
        break
    }
  }

  private finishStreams(): void {
    for (const collector of Object.values(this.collectors)) collector.seal()
    if (!this.out.writableEnded) this.out.end()
    if (!this.err.writableEnded) this.err.end()
  }

  private sendCancel(): void {
    this.cancelSent ??= this.bridge.client.cancel(this.request.exec_id, { signal: 'SIGTERM', grace_ms: this.request.grace_ms })
      .catch((error: unknown) => {
        // An execution the provider no longer knows is already gone.
        if (error instanceof ExecBridgeError && error.code === 'not_found') return
        this.unobservable ??= error instanceof Error ? error : new Error(String(error))
      })
  }

  /** Reject a handle that never got an execution slot. */
  abort(error: unknown): void {
    if (this.quiescent || this.terminateRequested) return
    this.quiescent = true
    this.quiet.resolve()
    this.finishStreams()
    this.detachAbort()
    this.exited.reject(error instanceof Error ? error : new Error(String(error)))
  }

  terminate(): void {
    if (this.hardSettled || this.quiescent || this.terminateRequested) return
    this.terminateRequested = true
    if (this.stream !== undefined) this.sendCancel()
    else {
      // Not yet accepted: the provider may still start it, so cancel right after the stream opens.
      void this.opened.promise.then(() => { this.sendCancel() }, () => {})
    }
    // The provider owns the termination grace. After it, a host that ignores
    // EXEC_CTL or never emits `quiescent` must not keep the workspace lane
    // (and this handle) occupied indefinitely.
    this.forceTimer ??= setTimeout(() => {
      this.hardSettle(new Error(`subprocess-xl: execution ${this.request.exec_id} did not confirm termination within ${String(this.request.grace_ms)} ms`))
    }, this.request.grace_ms)
  }

  async waitForExit(signal?: AbortSignal): Promise<boolean> {
    if (this.quiescent) return true
    if (signal?.aborted) return false
    const aborted = Promise.withResolvers<false>()
    const onAbort = (): void => { aborted.resolve(false) }
    signal?.addEventListener('abort', onAbort, { once: true })
    try {
      const result = await Promise.race([this.quiet.promise.then(() => true as const), aborted.promise])
      if (result && !this.quiescent && this.unobservable !== undefined) {
        throw new Error(`subprocess-xl: execution ${this.request.exec_id} can no longer be observed`, { cause: this.unobservable })
      }
      return result
    } finally {
      signal?.removeEventListener('abort', onAbort)
    }
  }

  /**
   * Force the handle to a terminal state without waiting for another host
   * event.
   *
   * This is the one owner of a leaked accelerator lane: it marks the range
   * quiescent, resolves `waitForExit`, settles/rejects `done`, closes the
   * event stream (so late EXEC_EVT frames have no observer), stops the
   * re-attach loop and aborts every pending transport wait. The caller's
   * per-workspace mutex can then release and the next command runs.
   * It is idempotent, and it never invents stdout or an exit code: callers
   * that force a settlement report their own timeout/cancel classification.
   * @param error - the reason the provider could not be observed to quiesce.
   */
  hardSettle(error: Error): void {
    if (this.hardSettled) return
    this.hardSettled = true
    this.terminateRequested = true
    this.quiescent = true
    if (this.forceTimer !== undefined) {
      clearTimeout(this.forceTimer)
      this.forceTimer = undefined
    }
    this.quiet.resolve()
    this.opened.reject(error)
    this.exited.reject(error)
    this.detachAbort()
    this.lifetime.abort(error)
    this.stream?.close()
    this.stream = undefined
    this.finishStreams()
  }

  /** Detach and stop reading; a handle the provider still owns is force-settled. */
  close(): void {
    this.hardSettle(new Error(`subprocess-xl: execution ${this.request.exec_id} was closed before it was observed quiescent`))
  }

  get execId(): string { return this.request.exec_id }
}

function outcomeOf(exit: ExitEvent): SubprocessOutcome {
  return { exitCode: exit.code, signal: exit.signal as NodeJS.Signals | null }
}

/** Subprocess provider for the inverted execution world. */
export class XlSubprocessRuntime extends SubprocessRuntime {
  static inject = ['xlExecBridge']
  /** Sub-agent concurrency and admission (budgets.md §4, W5-SHELL). */
  readonly governor = new ExecutionGovernor()
  /** Job lifecycle of every command that stays in the Worker (G2-FIX-82). */
  readonly jobs = new WorkerJobRegistry()
  private readonly live = new Set<SubprocessHandle>()
  private readonly lifetime = new AbortController()
  private readonly mutex = new ExecutionMutex()
  private spill: ManagedProcessBinding | undefined
  private watchedChannel: unknown

  constructor(ctx: Context) {
    super(ctx)
    this.observeChannel()
    ctx.effect(() => () => { this.governor.close('subprocess-xl provider disposed') }, 'subprocess-xl admission')
    // Host drain/abort: closing admission rejects queued waiters but must also
    // settle every command already executing (PLAN D14 Draining), including an
    // interpreter blocked in a proxied syscall. The registry fan-out runs
    // synchronously and hard-terminates each handle, so settlement does not
    // wait behind the per-workspace execution lane (G2-FIX-104).
    ctx.effect(() => this.governor.onCancel(() => {
      this.jobs.settleAll('drain')
      for (const handle of this.live) {
        if (handle instanceof LocalWorkerProcess || handle instanceof ShellWorkerProcess) {
          if (!handle.finished) handle.hardTerminate('drain')
        } else handle.terminate()
      }
    }), 'subprocess-xl host cancellation')
    ctx.effect(() => async () => {
      this.lifetime.abort(new Error('subprocess-xl provider disposed'))
      for (const handle of this.live) {
        if (handle instanceof LocalWorkerProcess || handle instanceof ShellWorkerProcess) handle.hardTerminate('drain')
        else handle.terminate()
      }
      const results = await Promise.allSettled([...this.live].map(async (handle) => {
        try { await handle.waitForExit(AbortSignal.timeout(10_000)) } finally {
          if (handle instanceof BridgeProcess) handle.close()
        }
      }))
      const errors = results.flatMap(result => result.status === 'rejected' ? [result.reason as unknown] : [])
      if (errors.length > 0) throw new AggregateError(errors, 'subprocess-xl: execution cleanup could not be confirmed')
    }, 'subprocess-xl live executions')
  }

  override spawn(spec: SubprocessSpawnSpec): SubprocessHandle {
    this.lifetime.signal.throwIfAborted()
    spec.signal?.throwIfAborted()
    if (spec.argv.length === 0 || spec.argv[0] === '') throw new Error('subprocess-xl: argv must name a program')
    if (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0) throw new Error('subprocess-xl: graceMs must be positive and finite')
    if ((spec.stdio as { control?: string }).control !== undefined) {
      throw new Error('subprocess-xl: the exec bridge has no control channel (PTC Node programs are disabled in the phone profile)')
    }
    const bridge = this.ctx.xlExecBridge
    this.observeChannel()
    if (!this.governor.admissionOpen) throw new AdmissionClosedError(this.governor.closed ?? 'lifecycle admission')
    const stripped = stripConfineMarker(spec.argv)
    const program = stripped.argv[0] as string
    // A caller may name the program by its absolute executable path (DSH's
    // tool-fs-search spawns `resolveRgPath()`). Resolve it to the identity the
    // dispatch speaks before the host/local decision, so the whole class of
    // path-form spawns follows the same advertised-name rule as bare ones.
    const identity = workerShellIdentity(resolveProgramIdentity(program, bridge.hello.capabilities.accelerators ?? []))
    // D12: only an advertised read-only accelerator may leave the Worker; the
    // desktop reference transport keeps sending everything to its provider.
    const workerAccelerator = bridge.transport.kind !== 'node-http' && isAccelerator(identity, bridge.hello)
    const host = bridge.transport.kind === 'node-http' || workerAccelerator
    const spill = this.spill ??= prepareManagedProcessBinding({ onSpillFailure: logSpillFailure(this.ctx.logger('subprocess-xl'), 'subprocess-xl') })
    if (!host) {
      const call = currentToolCall()
      // The Worker's bash core is just-bash (PLAN W5). A direct `git ...`
      // argv — what the workspace-changes plugin spawns — is a Worker program
      // too: it runs through the same command table as `bash -c 'git ...'`
      // instead of the runtime's `node:child_process` shim, which has no git
      // (W7-GIT). The packaged ripgrep path (see the identity above) is just
      // as much a Worker program: it becomes the Worker shell's `rg` (the
      // shell-ext shim over just-bash's built-in, which keeps the DSH globset
      // contract), with the flags just-bash documents as unsupported
      // translated. Other direct
      // commands keep that shim; the desktop reference transport never takes
      // this branch.
      const localArgv = identity === RIPGREP_PROGRAM ? workerRipgrepArgv(stripped.argv) : stripped.argv
      const explicitKey = (spec as XlWorkerSpawnSpec).idempotencyKey
      const trustedKey = explicitKey !== undefined && explicitKey !== '' ? explicitKey : call?.key
      let localEnv = spec.env
      if (spec.env?.[IDEMPOTENCY_ENV] !== undefined || (trustedKey !== undefined && trustedKey !== '')) {
        localEnv = { ...spec.env }
        delete localEnv[IDEMPOTENCY_ENV]
        if (trustedKey !== undefined && trustedKey !== '') localEnv[IDEMPOTENCY_ENV] = trustedKey
      }
      const localSpec: SubprocessSpawnSpec = {
        ...spec,
        argv: localArgv,
        ...localEnv === undefined ? {} : { env: localEnv },
      }
      // A path-form argv names a file in the Worker VFS, not a host program.
      // Script files (`./rotate.sh`, `/dsh/workspace/rotate.sh`) must reach the
      // composed Worker shell for the same reason `bash script.sh` does: the
      // transform plugin and command table live at our layer, and the engine's
      // bare path executor would run the script without them (G2-FIX-66: base#
      // arithmetic reached that executor as a `NaN<n>` pseudo-variable and
      // `set -u` did not abort).
      const scriptPath = identity.includes('/')
      const workerProgram = isShellInvocation(stripped.argv) || isWorkerShellProgram(identity) || scriptPath
      // Job lifecycle (G2-FIX-82): the command is registered before it can be
      // dispatched (or queued behind another command) and carries the Worker's
      // command budget. A caller-supplied `timeoutMs` — the seam's counterpart
      // of the `bash` tool's argument — bounds it exactly at that value.
      const requestedTimeout = (spec as XlWorkerSpawnSpec).timeoutMs
      if (requestedTimeout !== undefined && (!Number.isFinite(requestedTimeout) || requestedTimeout <= 0)) {
        throw new Error('subprocess-xl: timeoutMs must be a positive finite number')
      }
      const justBash = workerProgram && resolveShellMode(process.env) === 'just-bash'
      const handle: LocalWorkerProcess | ShellWorkerProcess = justBash
        ? new ShellWorkerProcess(localSpec, spill, this.createWorkerShell(bridge, localSpec), {
          terminateInterpreter: (cause) => settleWorkerInterpreter(cause),
          explicitDeadline: requestedTimeout !== undefined,
        })
        : new LocalWorkerProcess(localSpec, spill)
      // The registry owns the deadline and the drain fan-out (G2-FIX-104) and
      // hard-terminates the handle synchronously — including the WASI tool
      // worker the command may be blocked in — so settlement never waits
      // behind the per-workspace execution lane. The upstream executor's fused
      // spawn signal is the authoritative deadline when present; the registry
      // timer is armed one grace later only as its backstop.
      const job = this.jobs.register({
        argv: localSpec.argv,
        cwd: localSpec.cwd,
        timeoutMs: requestedTimeout ?? shellTimeoutFromEnv(process.env),
        ...requestedTimeout === undefined
          ? { deadlineMarginMs: Math.min(spec.graceMs, 5_000) }
          : {},
      }, {
        terminate: cause => { handle.hardTerminate(cause) },
      })
      handle.attachJob(job)
      this.live.add(handle)
      void this.mutex.run(this.workspaceKey(bridge, spec.cwd), async () => {
        let release: (() => void) | undefined
        try {
          release = await this.governor.acquire(spec.signal)
        } catch (error) {
          handle.abort(error)
          return
        }
        try {
          handle.begin()
          await handle.done.catch(() => {})
          await handle.waitForExit().catch(() => {})
        } finally {
          release()
        }
      }).catch(() => {}).finally(() => { this.live.delete(handle) })
      return handle
    }
    // The host accelerator is addressed by its advertised bare name; the
    // desktop transport keeps the caller's argv verbatim (its provider spawns
    // the real binary path).
    const hostSpec = workerAccelerator && identity !== program
      ? { ...spec, argv: withProgramIdentity(spec.argv, identity) }
      : spec
    const request = buildExecRequest(bridge, hostSpec, nextExecId())
    const handle = new BridgeProcess(bridge, spec, request, spill)
    this.live.add(handle)
    void this.mutex.run(this.workspaceKey(bridge, request.cwd), async () => {
      // The slot is open: the channel transport now reads the sink's last
      // emitted mseq and builds EXEC_REQ, so a parallel writer's acked work is
      // visible to this read-only accelerator.
      let release: (() => void) | undefined
      try {
        release = await this.governor.acquire(spec.signal)
      } catch (error) {
        handle.abort(error)
        return
      }
      try {
        handle.start()
        await handle.done.catch(() => {})
        await handle.waitForExit().catch(() => {})
      } finally {
        release()
      }
    }).catch(() => {}).finally(() => { this.live.delete(handle) })
    return handle
  }

  /** Watch the ordered channel once it exists (the Worker entry installs it before boot). */
  private observeChannel(): void {
    const channel = (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    if (channel === this.watchedChannel) return
    this.watchedChannel = channel
    this.governor.watchChannel(channel)
  }

  /** Build the just-bash shell for one `bash -c`, with the accelerator bridge. */
  private createWorkerShell(bridge: XlExecBridge, spec: SubprocessSpawnSpec): WorkerShell {
    const extended = spec as XlWorkerSpawnSpec
    const accelerators = createExecBridgeAccelerators({
      client: bridge.client,
      hello: bridge.hello,
      revision: () => bridge.lastMseq,
      // The console's foreground deadline is the host EXEC_REQ deadline; the
      // termination grace only bounds cancel/force settlement.
      deadlineMs: extended.timeoutMs ?? shellTimeoutFromEnv(process.env),
      ...extended.idempotencyKey === undefined ? {} : { idempotencyKey: extended.idempotencyKey },
      graceMs: spec.graceMs,
    })
    return new WorkerShell({
      fs: new VfsFileSystem({ root: process.env.PDSH_VFS_ROOT ?? '/' }),
      commands: createWorkerCommands({ accelerators }),
    })
  }

  override async resolveExecutable(command: string, env?: Readonly<Record<string, string>>, signal?: AbortSignal): Promise<string> {
    if (command === '' || (!posix.isAbsolute(command) && command.includes('/'))) {
      throw new Error(`subprocess-xl: executable ${JSON.stringify(command)} must be an absolute path or a bare name`)
    }
    const bridge = this.ctx.xlExecBridge
    if (bridge.transport.kind !== 'node-http') {
      // The Worker shell resolves bare names against its own command table.
      signal?.throwIfAborted()
      void env
      return command
    }
    const script = 'case "$1" in /*) [ -f "$1" ] && [ -x "$1" ] && printf "%s" "$1" ;; *) command -v -- "$1" ;; esac'
    const stream = await bridge.client.exec({
      exec_id: `pdsh-which-${randomUUID()}`,
      argv: ['/bin/sh', '-c', script, 'sh', command],
      cwd: bridge.paths.defaultGuestRoot,
      env: { ...env },
      stdin: { mode: 'ignore' },
      grace_ms: 1000,
      deadline: Date.now() + 10_000,
    }, signal)
    let stdout = ''
    let exit: ExitEvent | undefined
    try {
      for await (const event of stream) {
        if (event.type === 'output' && event.stream === 'stdout') stdout += Buffer.from(event.data, 'base64').toString('utf8')
        if (event.type === 'exit') { exit = event; break }
      }
    } finally {
      stream.close()
    }
    const path = stdout.trim()
    if (exit?.code === 0 && posix.isAbsolute(path)) return path
    throw new SubprocessExecutableNotFoundError(`subprocess-xl: ${command} was not found in the execution world`)
  }

  override terminalEnvironment(_signal?: AbortSignal): Promise<SubprocessTerminalEnvironment> {
    const bridge = this.ctx.xlExecBridge
    if (bridge.transport.kind !== 'node-http') return Promise.resolve({ platform: 'posix', defaultShell: '/bin/sh' })
    const guest = bridge.hello.guest
    return Promise.resolve({ platform: 'posix', ...guest.default_shell === undefined ? {} : { defaultShell: guest.default_shell } })
  }

  override spawnTerminal(_spec: SubprocessTerminalSpawnSpec): Promise<SubprocessTerminalHandle> {
    return Promise.reject(new Error('subprocess-xl: the phone execution world has no terminal (PTY) primitive; terminal-bash is disabled in the phone profile'))
  }

  /** Per-workspace mutex key: one workspace serializes, subdirectories included. */
  private workspaceKey(bridge: XlExecBridge, cwd: string): string {
    if (bridge.transport.kind === 'node-http') return bridge.workspaceRoot
    for (const root of ['/dsh/workspace', '/dsh/home']) {
      if (cwd === root || cwd.startsWith(`${root}/`)) return root
    }
    return cwd
  }
}

export default XlSubprocessRuntime
