// SPDX-License-Identifier: MIT
/**
 * The toolbox command table the DSH worker keeps. It routes program names to
 * WASI modules, owns one warm tool worker per program, attaches a VFS proxy
 * server to each worker, compiles each module once, streams stdout/stderr and
 * maps cancellation to `terminate()`.
 *
 * `subprocess-xl` uses `has()`/`list()` to decide that a command is a WASI tool
 * and `run()` to execute it; a program the table does not know answers 127,
 * the same way a shell reports an unknown command.
 * @module @phone-dsh/dsh-wasi-toolbox/toolbox
 */
import { VfsProxyError, WasiToolboxError } from './errors.ts'
import {
  DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PREOPENS, DEFAULT_VFS_FRAME_BYTES, DEFAULT_VFS_SYNC_TIMEOUT_MS,
  DEFAULT_WORKER_READY_TIMEOUT_MS,
} from './limits.ts'
import { workerTransport } from './message-endpoint.ts'
import type { ToolWorkerTransport } from './message-endpoint.ts'
import { ModuleCache } from './module-cache.ts'
import { MAX_STDIN_BYTES, splitStdinFrames } from './stdin-delivery.ts'
import { captureVfsSnapshot } from './vfs-snapshot.ts'
import type { VfsSnapshot } from './vfs-snapshot.ts'
import { VfsProxyServer } from './vfs-server.ts'
import { normalizeAbsolutePath, resolveGuestCwd, translateWorkerEnvironment } from './vfs-paths.ts'
import type { GuestPreopen, ToolboxCommand, ToolboxResult, ToolboxRunRequest, VfsBackend } from './types.ts'

/** Summary returned by {@link WasiToolbox.list}. */
export interface ToolboxCommandSummary {
  readonly program: string
  readonly aliases: readonly string[]
  readonly description?: string
}

/** Construction inputs of {@link WasiToolbox}. */
export interface WasiToolboxOptions {
  readonly commands: readonly ToolboxCommand[]
  /** The DSH worker's `node:fs` face in production. */
  readonly backend: VfsBackend
  readonly preopens?: readonly GuestPreopen[]
  readonly memoryLimitBytes?: number
  readonly maxFrameBytes?: number
  readonly syncTimeoutMs?: number
  /** Override the automatic `crossOriginIsolated` detection (tests). */
  readonly crossOriginIsolated?: boolean
  /** Factory for the dedicated tool worker; defaults to `new Worker(workerUrl)`. */
  readonly spawnWorker?: (command: ToolboxCommand) => ToolWorkerTransport
  /** URL of the built tool-worker module; defaults to `./tool-worker.js`. */
  readonly workerUrl?: URL | string
  readonly workerReadyTimeoutMs?: number
  readonly moduleCache?: ModuleCache
  /**
   * Serve the preopened trees from a local snapshot when the host has no
   * synchronous VFS channel. Without this option such a toolbox keeps the
   * documented "file I/O fails cleanly" behaviour; with it a rebuilt Worker
   * that lost its SharedArrayBuffer channel still gives the guest the same
   * file view the shell has (G2-FIX-54).
   */
  readonly snapshotFallback?: boolean
  /**
   * Recapture the snapshot from the live VFS before each dispatch, so a file a
   * `bash` step wrote or removed between two python runs is visible to the next
   * run. Defaults to `snapshotFallback`: a capture taken only at tool-worker
   * init would make the guest read the boot-time tree for the life of the warm
   * worker (G2-FIX-54). The capture is still a point-in-time view: a write that
   * happens *during* a WASI command is not seen by that command, only by the
   * next one.
   */
  readonly refreshSnapshotOnRun?: boolean
  /** How long the post-init file-view probe may take; defaults to 15 s. */
  readonly viewTimeoutMs?: number
  /**
   * How long the tool worker has to acknowledge an `exec` it received before
   * the dispatch is treated as wedged (default: `PDSH_TOOLBOX_EXEC_START_TIMEOUT_MS`
   * or 10 s). Without this bound a tool worker that stopped reading its inbox
   * left the command holding the Worker execution lane until the shell's 120 s
   * wall clock.
   */
  readonly execStartTimeoutMs?: number
  /**
   * How long a program that consumes its script from stdin (`python3 -`) has
   * to perform its first `fd_read(0)` after `exec-started` (default:
   * `PDSH_TOOLBOX_STDIN_READ_TIMEOUT_MS` or 20 s). Only invocations whose
   * command declares `scriptFromStdin` are watched, so a program that never
   * reads stdin is unaffected.
   */
  readonly stdinReadTimeoutMs?: number
  /**
   * Guest preopen roots whose absence makes the file view unusable. A missing
   * optional root (the volatile `/dsh/tmp`, say) is reported but does not fail
   * the dispatch; the persisted roots a program writes to are required.
   */
  readonly requiredPreopens?: readonly string[]
}

interface ActiveExec {
  readonly id: number
  readonly request: ToolboxRunRequest
  stdoutBytes: number
  stderrBytes: number
  /** Per-stream capture ceilings (`undefined` keeps unbounded streaming). */
  readonly stdoutLimit?: number
  readonly stderrLimit?: number
  /** Whether the interpreter performed its first `fd_read(0)`. */
  stdinRead: boolean
  /** Whether this invocation's script comes from stdin (read watchdog). */
  readonly watchStdin: boolean
  /** Bytes the host delivered; the tool worker's assembled count must agree. */
  readonly expectedStdinBytes?: number
  startTimer?: ReturnType<typeof setTimeout>
  stdinTimer?: ReturnType<typeof setTimeout>
  /**
   * Host paths this dispatch mutated through the VFS proxy. A hard stop uses
   * it to leave a terminal marker beside each half-written file (G2-FIX-104).
   */
  readonly written: Set<string>
  readonly resolve: (result: ToolboxResult) => void
}

/** Which channel answered the post-init file-view probe. */
export type ToolboxFileViewChannel = 'sync' | 'snapshot' | 'none'

/** What the guest's file view resolved after init. */
export interface ToolboxFileView {
  /** Guest roots the guest can resolve. */
  readonly present: readonly string[]
  /** Required guest roots the guest cannot resolve; non-empty is a broken view. */
  readonly missing: readonly string[]
  /** Every guest root the probe could not resolve, required or not. */
  readonly unresolved?: readonly string[]
  readonly via: ToolboxFileViewChannel
  /** Human-readable probe failure, when there was one. */
  readonly detail?: string
}

interface ProgramInstance {
  readonly command: ToolboxCommand
  readonly transport: ToolWorkerTransport
  readonly server: VfsProxyServer
  readonly ready: Promise<void>
  /**
   * Snapshot used instead of the synchronous channel, when one was captured.
   * After the init message is posted only the summary (roots/missing/limits)
   * is retained, so the host does not hold a second copy of the bytes.
   */
  snapshot?: VfsSnapshot | undefined
  /** Authoritative file-view probe result, once it arrives. */
  fileView?: ToolboxFileView
  /** Resolves with the file-view probe (async or blocking channel). */
  readonly view: Promise<ToolboxFileView>
  viewResolve?: (view: ToolboxFileView) => void
  tail: Promise<void>
  active?: ActiveExec
  closed: boolean
  /**
   * First external stop cause for this instance. Once set, the instance is
   * never reused and a run that completes later skips the durability fence.
   */
  stopCause?: ToolboxStopCause
  /** Host paths mutated by the most recent dispatch, for marker cleanup. */
  lastWritten?: ReadonlySet<string>
  disposeMessage?: () => void
  disposeError?: () => void
  readyResolve?: () => void
  readyReject?: (error: Error) => void
  readyTimer?: ReturnType<typeof setTimeout>
  preopens?: { readonly present: readonly string[]; readonly missing: readonly string[] }
}

interface Deferred<T> {
  readonly promise: Promise<T>
  resolve(value: T): void
  reject(error: Error): void
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

/**
 * Normalise the optional per-stream capture caps of one dispatch.
 *
 * A non-finite or negative value is ignored (historical unbounded behaviour);
 * zero is a valid cap that stops on the first produced byte.
 * @param request - the dispatch request.
 * @returns the ceilings to store on the active execution.
 */
function streamLimitOptions(request: ToolboxRunRequest): { readonly stdoutLimit?: number; readonly stderrLimit?: number } {
  const valid = (value: number | undefined): value is number =>
    typeof value === 'number' && Number.isFinite(value) && value >= 0
  return {
    ...valid(request.maxStdoutBytes) ? { stdoutLimit: Math.floor(request.maxStdoutBytes) } : {},
    ...valid(request.maxStderrBytes) ? { stderrLimit: Math.floor(request.maxStderrBytes) } : {},
  }
}

/** True when a synchronous SAB channel can be offered to the tool worker. */
export function supportsSynchronousVfs(flag?: boolean): boolean {
  if (typeof SharedArrayBuffer !== 'function') return false
  if (flag !== undefined) return flag
  return (globalThis as { crossOriginIsolated?: boolean }).crossOriginIsolated === true
}

/** Global property a packed Worker keeps its toolbox under. */
export const WORKER_TOOLBOX_GLOBAL = '__PDSH_WASI_TOOLBOX__'

/**
 * Why a WASI dispatch is being cut off from outside its run loop.
 *
 * - `timeout`: the enclosing job's deadline expired.
 * - `drain`: the host closed admission (park / handoff / planned restart).
 * - `cancel`: the tool call itself was cancelled.
 */
export const TOOLBOX_STOP_CAUSES = ['timeout', 'drain', 'cancel'] as const
export type ToolboxStopCause = typeof TOOLBOX_STOP_CAUSES[number]

/** The toolbox surface the Worker shell's command table dispatches to. */
export interface WorkerToolbox {
  list(): readonly ToolboxCommandSummary[]
  has(program: string): boolean
  run(request: ToolboxRunRequest): Promise<ToolboxResult>
  /** Preopens programs default to, used to map the shell's host cwd. */
  readonly preopenTable?: readonly GuestPreopen[]
  /**
   * Hard-stop every active dispatch and drop the warm workers (G2-FIX-104).
   *
   * This is the external settlement hook: it runs synchronously from the job
   * owner's terminator, resolves the blocked `run()` promises with a terminal
   * timeout/drain result and marks the partial writes of the cut-off
   * dispatches. It never awaits the tool worker, which may be wedged in a
   * proxied syscall.
   * @param cause - why the dispatch is being cut off.
   * @returns the number of active dispatches that were stopped.
   */
  terminate?(cause?: ToolboxStopCause): number
  /** Completion of the partial-write markers started by {@link terminate}. */
  partialWritesSettled?(): Promise<void>
}

/**
 * Publish the toolbox whose programs the Worker shell serves.
 *
 * The packaged Worker bundles each staged package separately, so a module-level
 * registry would fork per bundle; the toolbox therefore lives on `globalThis`,
 * next to the channel and lifecycle globals the Worker entry already uses.
 * @param toolbox - the toolbox to dispatch, or undefined to clear it.
 */
export function setWorkerToolbox(toolbox: WorkerToolbox | undefined): void {
  ;(globalThis as Record<string, unknown>)[WORKER_TOOLBOX_GLOBAL] = toolbox
}

/** The toolbox published by {@link setWorkerToolbox}, duck-typed across bundles. */
export function getWorkerToolbox(): WorkerToolbox | undefined {
  const value = (globalThis as Record<string, unknown>)[WORKER_TOOLBOX_GLOBAL]
  if (typeof value !== 'object' || value === null) return undefined
  const candidate = value as Partial<WorkerToolbox>
  return typeof candidate.run === 'function' && typeof candidate.list === 'function'
    ? candidate as WorkerToolbox
    : undefined
}

/** Suffix of the terminal marker left beside a hard-stopped partial write. */
export const PARTIAL_WRITE_SUFFIX = '.pdsh-partial'

/** Default time the tool worker has to acknowledge an `exec` (10 s). */
export const DEFAULT_EXEC_START_TIMEOUT_MS = 10_000

/** Default time a script-from-stdin program has for its first `fd_read(0)` (20 s). */
export const DEFAULT_STDIN_READ_TIMEOUT_MS = 20_000

/**
 * Environment knob for {@link DEFAULT_EXEC_START_TIMEOUT_MS}, symmetric with
 * the shell's `PDSH_SHELL_STDIN_TIMEOUT_MS`: a field diagnostic can tighten the
 * watchdog without rebuilding the Worker.
 */
export const EXEC_START_TIMEOUT_ENV = 'PDSH_TOOLBOX_EXEC_START_TIMEOUT_MS'

/** Environment knob for {@link DEFAULT_STDIN_READ_TIMEOUT_MS}. */
export const STDIN_READ_TIMEOUT_ENV = 'PDSH_TOOLBOX_STDIN_READ_TIMEOUT_MS'

/** The two dispatch watchdogs, in milliseconds. */
export interface DispatchTimeouts {
  readonly execStartTimeoutMs: number
  readonly stdinReadTimeoutMs: number
}

/** Parse one positive millisecond timeout, mirroring the shell's env parser. */
function dispatchTimeoutFromEnv(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: number,
): number {
  const raw = env[name]
  if (raw === undefined || raw.trim() === '') return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new WasiToolboxError(`${name} must be a positive number of milliseconds, got ${JSON.stringify(raw)}`)
  }
  return Math.floor(parsed)
}

/**
 * Resolve the dispatch watchdogs from the environment, so an on-device
 * diagnosis can tighten them the same way `PDSH_SHELL_STDIN_TIMEOUT_MS` tightens
 * the shell's EOF grace. Constructor options still win over the environment.
 * @param env - environment to read; defaults to `process.env`.
 * @throws {WasiToolboxError} when a knob is not a positive millisecond value.
 */
export function resolveDispatchTimeouts(
  env: Readonly<Record<string, string | undefined>> = process.env,
): DispatchTimeouts {
  return {
    execStartTimeoutMs: dispatchTimeoutFromEnv(env, EXEC_START_TIMEOUT_ENV, DEFAULT_EXEC_START_TIMEOUT_MS),
    stdinReadTimeoutMs: dispatchTimeoutFromEnv(env, STDIN_READ_TIMEOUT_ENV, DEFAULT_STDIN_READ_TIMEOUT_MS),
  }
}

/** Program table and warm-worker pool of the WASI toolbox. */
export class WasiToolbox {
  readonly moduleCache: ModuleCache
  private readonly commands = new Map<string, ToolboxCommand>()
  private readonly aliases = new Map<string, string>()
  private readonly backend: VfsBackend
  private readonly preopens: readonly GuestPreopen[]
  private readonly memoryLimitBytes: number
  private readonly maxFrameBytes: number
  private readonly syncTimeoutMs: number
  private readonly spawnWorkerImpl: (command: ToolboxCommand) => ToolWorkerTransport
  private readonly workerUrl: URL | string
  private readonly workerReadyTimeoutMs: number
  private readonly useSync: boolean
  private readonly snapshotFallback: boolean
  private readonly refreshSnapshotOnRun: boolean
  private readonly viewTimeoutMs: number
  private readonly execStartTimeoutMs: number
  private readonly stdinReadTimeoutMs: number
  private readonly requiredPreopens: readonly string[]
  private readonly instances = new Map<string, Promise<ProgramInstance>>()
  /** Instances whose workers are already up; the synchronous hard-stop set. */
  private readonly liveInstances = new Set<ProgramInstance>()
  /** Partial-write marker writes started by a hard stop, for tests/drain. */
  private readonly partialSettlements = new Set<Promise<void>>()
  /** Marker paths this toolbox wrote, so a normal run only removes real ones. */
  private readonly partialMarkers = new Set<string>()
  private nextExecId = 1
  private disposed = false
  private detachLifecycle: (() => void) | undefined

  constructor(options: WasiToolboxOptions) {
    this.backend = options.backend
    this.preopens = options.preopens ?? DEFAULT_PREOPENS
    this.memoryLimitBytes = options.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES
    this.maxFrameBytes = options.maxFrameBytes ?? DEFAULT_VFS_FRAME_BYTES
    this.syncTimeoutMs = options.syncTimeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS
    this.workerReadyTimeoutMs = options.workerReadyTimeoutMs ?? DEFAULT_WORKER_READY_TIMEOUT_MS
    this.useSync = supportsSynchronousVfs(options.crossOriginIsolated)
    this.workerUrl = options.workerUrl ?? new URL('./tool-worker.js', import.meta.url)
    this.spawnWorkerImpl = options.spawnWorker ?? (() => defaultSpawnWorker(this.workerUrl))
    this.snapshotFallback = options.snapshotFallback === true
    this.refreshSnapshotOnRun = options.refreshSnapshotOnRun ?? this.snapshotFallback
    this.viewTimeoutMs = options.viewTimeoutMs ?? 15_000
    // Environment knobs are only read for a watchdog the caller did not set,
    // so an explicit option (tests, a diagnostic build) is never overridden.
    const envTimeouts = options.execStartTimeoutMs === undefined || options.stdinReadTimeoutMs === undefined
      ? resolveDispatchTimeouts()
      : undefined
    this.execStartTimeoutMs = options.execStartTimeoutMs ?? envTimeouts!.execStartTimeoutMs
    this.stdinReadTimeoutMs = options.stdinReadTimeoutMs ?? envTimeouts!.stdinReadTimeoutMs
    this.requiredPreopens = [...(options.requiredPreopens ?? [])]
    this.moduleCache = options.moduleCache ?? new ModuleCache()
    for (const command of options.commands) this.register(command)
    this.validatePreopens(this.preopens)
    // The Worker entry publishes the host lifecycle events on `__PDSH_EVENTS__`.
    // A stop/drain must hard-stop an interpreter that is blocked in a proxied
    // syscall even if the ordered channel's 0x50 frame never reached the
    // subprocess layer (G2-FIX-104).
    const events = (globalThis as { __PDSH_EVENTS__?: EventTarget }).__PDSH_EVENTS__
    if (events !== undefined) {
      const onLifecycle = (event: Event): void => {
        const detail = (event as Event & { detail?: unknown }).detail
        if (detail === null || typeof detail !== 'object') return
        if ((detail as { state?: unknown }).state !== 'stop') return
        this.terminate('drain')
      }
      events.addEventListener('pdsh-lifecycle', onLifecycle)
      this.detachLifecycle = () => { events.removeEventListener('pdsh-lifecycle', onLifecycle) }
    }
  }

  /** Preopens programs default to; host paths are DSH Worker VFS paths. */
  get preopenTable(): readonly GuestPreopen[] { return this.preopens }

  /** Register one program and its aliases; the last registration wins. */
  register(command: ToolboxCommand): void {
    if (command.program.length === 0) throw new WasiToolboxError('command program must not be empty')
    const preopens = command.preopens ?? this.preopens
    this.validatePreopens(preopens)
    this.commands.set(command.program, command)
    this.aliases.delete(command.program)
    for (const alias of command.aliases ?? []) {
      if (alias.length === 0) throw new WasiToolboxError('command alias must not be empty')
      this.aliases.set(alias, command.program)
    }
  }

  /** Resolve a program name or alias. */
  get(program: string): ToolboxCommand | undefined {
    const canonical = this.aliases.get(program)
    return this.commands.get(canonical ?? program)
  }

  has(program: string): boolean {
    return this.get(program) !== undefined
  }

  /** Programs and aliases, for `subprocess-xl` routing and diagnostics. */
  list(): readonly ToolboxCommandSummary[] {
    return [...this.commands.values()].map(command => ({
      program: command.program,
      aliases: command.aliases ?? [],
      ...(command.description === undefined ? {} : { description: command.description }),
    }))
  }

  /**
   * Fail loud when the toolbox cannot give a WASI program a usable file view.
   *
   * The boot calls this before publishing the toolbox: a Worker path that has
   * neither a synchronous channel nor the snapshot fallback would serve the
   * guest an empty `/` (G2-FIX-54), and a backend that cannot resolve the
   * preopen roots would serve the same thing even with a channel. Both are
   * wiring defects, not a degraded image.
   * @param paths - Host VFS paths to verify; defaults to the required
   *   preopens' host paths.
   * @throws {WasiToolboxError} Naming every path that does not resolve.
   */
  async assertFileView(paths?: readonly string[]): Promise<void> {
    if (!this.useSync && !this.snapshotFallback) {
      throw new WasiToolboxError(
        'this Worker has no synchronous VFS channel (SharedArrayBuffer / crossOriginIsolated) and the toolbox '
        + 'has no snapshot fallback, so a WASI program would see an empty `/`; '
        + 'enable snapshotFallback or boot in a cross-origin isolated Worker',
      )
    }
    const missing: string[] = []
    const targets = paths ?? this.requiredPreopens.map(guest => {
      const preopen = this.preopens.find(candidate => candidate.guestPath === guest)
      return preopen?.hostPath ?? guest
    })
    for (const path of targets) {
      const host = normalizeAbsolutePath(path)
      try {
        const stat = await this.backend.stat(host)
        if (stat.kind !== 'directory') missing.push(`${path} (not a directory)`)
      } catch (error) {
        missing.push(`${path} (${error instanceof Error ? error.message : String(error)})`)
      }
    }
    if (missing.length > 0) {
      throw new WasiToolboxError(
        `the WASI toolbox cannot resolve ${missing.join(', ')}; its file view is not bound to the live VFS`,
      )
    }
  }

  /** Run one program; unknown programs answer 127 like a shell. */
  async run(request: ToolboxRunRequest): Promise<ToolboxResult> {
    if (this.disposed) throw new WasiToolboxError('toolbox is disposed')
    const command = this.get(request.program)
    if (command === undefined) {
      const message = `wasi-toolbox: ${request.program}: command not found\n`
      request.onStderr?.(new TextEncoder().encode(message))
      return {
        program: request.program,
        exitCode: 127,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: 0,
        stderrBytes: message.length,
      }
    }
    if (request.signal?.aborted === true) return this.cancelledResult(command.program, request)
    if (request.stdin !== undefined && request.stdin.byteLength > MAX_STDIN_BYTES) {
      // Bounded delivery: refuse before acquiring a worker so an oversized
      // script cannot clone an unbounded buffer or hold the execution lane.
      return this.failedResult(
        command.program,
        `stdin is ${request.stdin.byteLength} bytes; the WASI dispatch limit is ${MAX_STDIN_BYTES} bytes`,
        request,
        'E_STDIN_OVERSIZE',
      )
    }
    let instance = await this.acquire(command)
    let view = await this.awaitFileView(instance)
    if (view.missing.length > 0 && this.snapshotFallback && instance.snapshot === undefined) {
      // The async control plane answered but the guest's blocking channel did
      // not: the tool worker is bound to a VFS view this Worker cannot reach.
      // Recycle it once against a local snapshot of the live preopened trees.
      const broken = view
      await this.detach(instance)
      instance = await this.acquire(command, true)
      view = await this.awaitFileView(instance)
      if (view.missing.length > 0) {
        return this.failedResult(
          command.program,
          `the WASI file view cannot resolve ${view.missing.join(', ')} after the snapshot fallback`
          + `${broken.detail === undefined ? '' : ` (${broken.detail})`}`,
          request,
        )
      }
    } else if (view.missing.length > 0 && this.snapshotFallback) {
      return this.failedResult(
        command.program,
        `the WASI file view cannot resolve ${view.missing.join(', ')}`
        + `${view.detail === undefined ? '' : ` (${view.detail})`}`,
        request,
      )
    }
    const previous = instance.tail
    const gate = deferred<void>()
    instance.tail = gate.promise
    // The per-program dispatch queue is a mutex: a dispatch blocked in a
    // proxied syscall holds it. Waiting for the previous dispatch must
    // therefore be abort-aware, otherwise a queued run cannot observe its own
    // cancellation (G2-FIX-104).
    if (!await this.awaitTail(previous, request.signal)) {
      gate.resolve()
      return this.cancelledResult(command.program, request)
    }
    try {
      if (instance.closed) {
        return this.failedResult(command.program, 'tool worker exited; retry the command', request)
      }
      if (isAborted(request.signal)) {
        // The abort arrived after the warm worker was acquired but before any
        // exec was posted. Release it: a cancelled dispatch must not leave a
        // hot instance that the next run would silently reuse (the abort
        // listener in `execute` owns the dispatch window, so this is the only
        // path with no owner).
        await this.detach(instance).catch(() => {})
        return this.cancelledResult(command.program, request)
      }
      if (this.refreshSnapshotOnRun && instance.snapshot !== undefined) {
        let refreshed: ToolboxFileView
        try {
          refreshed = await this.refreshSnapshot(instance)
        } catch (error) {
          return this.failedResult(
            command.program,
            `the WASI file view could not be recaptured at dispatch: `
            + `${error instanceof Error ? error.message : String(error)}`,
            request,
          )
        }
        if (refreshed.missing.length > 0) {
          return this.failedResult(
            command.program,
            `the WASI file view cannot resolve ${refreshed.missing.join(', ')} at dispatch`
            + `${refreshed.detail === undefined ? '' : ` (${refreshed.detail})`}`,
            request,
          )
        }
      }
      const result = await this.execute(instance, request)
      // A dispatch stopped from outside settled with its own terminal timeout /
      // drain result. Fencing its durability would await a sink the drain may
      // already have taken away, and the command must not be reported as a
      // normal exit.
      if (instance.stopCause !== undefined) return result
      const fenced = await this.fenceDurability(result, request)
      // The command finished and its writes were acknowledged: a marker left
      // by an earlier aborted attempt of the same path is stale.
      if (fenced.failureCode === undefined) this.clearPartialMarkers(instance.lastWritten)
      return fenced
    } finally {
      gate.resolve()
    }
  }

  /**
   * Wait for the previous dispatch in the per-program queue, abort-aware.
   *
   * @returns true when the queue is free and this dispatch may proceed, false
   *   when the caller's signal aborted while it was queued.
   */
  private async awaitTail(previous: Promise<void>, signal: AbortSignal | undefined): Promise<boolean> {
    if (signal === undefined) {
      await previous
      return true
    }
    let free = false
    void previous.then(() => { free = true }, () => { free = true })
    const aborted = Promise.withResolvers<false>()
    const onAbort = (): void => { aborted.resolve(false) }
    signal.addEventListener('abort', onAbort, { once: true })
    if (signal.aborted) onAbort()
    try {
      const result = await Promise.race([previous.then(() => true as const), aborted.promise])
      if (result === true) return true
      // The abort won the race. When the previous dispatch had already
      // released the queue, the caller must still take the normal release
      // path for its acquired warm worker; only a dispatch that is genuinely
      // queued behind a running one leaves that instance alone.
      return free
    } finally {
      signal.removeEventListener('abort', onAbort)
    }
  }

  /**
   * Close the command-boundary durability window (G2-FIX-61).
   *
   * The sink publishes a VFS mutation asynchronously (0x10 frame -> host WAL
   * append -> level-1 0x11 ack), while a WASI guest's `write` only updates the
   * Worker memory VFS. Without a fence, `python3` can report success while the
   * last mutations of the command are still in flight: a Worker kill in that
   * window loses the files from the VFS, the WAL and the materialized copy
   * (the G2-F07 batch saw exactly that for the 60-frame directory). The DSH fs
   * tools reach the same fence through their `fsync`; a WASI guest's ordinary
   * `open`/`write` never issues one, so the toolbox must flush the backend
   * itself before it resolves the command.
   *
   * The flush is the backend's `sync`, which in production is
   * `host.vfs.flush()`: it waits for the level-1 ack of the last emitted mseq
   * and surfaces a resource refusal as the command's own error. A backend
   * without `sync` (the in-memory test backend) has nothing to fence.
   * @param result - the settled interpreter result.
   * @param request - the dispatch, for the failure stderr.
   * @returns the result, or a failed result when the sink did not acknowledge.
   */
  private async fenceDurability(result: ToolboxResult, request: ToolboxRunRequest): Promise<ToolboxResult> {
    const sync = this.backend.sync
    if (typeof sync !== 'function') return result
    try {
      await sync.call(this.backend)
      return result
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error)
      const message = new TextEncoder().encode(
        `wasi-toolbox: ${result.program}: the VFS sink did not acknowledge this command's writes: ${detail}\n`,
      )
      request.onStderr?.(message)
      return {
        ...result,
        exitCode: result.exitCode === 0 ? 134 : result.exitCode,
        stderrBytes: result.stderrBytes + message.byteLength,
        failureCode: result.failureCode ?? 'E_VFS_FLUSH',
      }
    }
  }

  /** Terminate every warm worker. */
  async dispose(): Promise<void> {
    this.disposed = true
    this.detachLifecycle?.()
    this.detachLifecycle = undefined
    // A disposing Worker must not leave an interpreter dispatch blocked in a
    // proxied syscall: resolve it with the terminal drain result first, then
    // release the workers.
    this.terminate('drain')
    const pending = [...this.instances.values()]
    this.instances.clear()
    await Promise.all(pending.map(async promise => {
      try {
        const instance = await promise
        await this.detach(instance)
      } catch {
        // A worker that never became ready holds nothing to release.
      }
    }))
    await this.partialWritesSettled()
  }

  /**
   * Hard-stop every active dispatch and drop the warm workers (G2-FIX-104).
   *
   * This is the external settlement owner's hook. It must be safe to call
   * while a tool worker is wedged in a proxied syscall: the active `run()`
   * promise is resolved synchronously with a terminal timeout/drain result,
   * every mutated path gets a partial-write marker (best effort), and the
   * transport is asked to terminate without waiting for it.
   * @param cause - why the dispatch is being cut off.
   * @returns the number of active dispatches that were stopped.
   */
  terminate(cause: ToolboxStopCause = 'drain'): number {
    const instances = [...this.liveInstances]
    const pending = [...this.instances.values()]
    this.liveInstances.clear()
    this.instances.clear()
    let stopped = 0
    for (const instance of instances) stopped += this.hardStop(instance, cause)
    // A worker that was still mounting when the settlement arrived belongs to
    // nobody yet; stop it as soon as it resolves so it cannot serve a dispatch
    // after the drain.
    for (const promise of pending) {
      void promise.then(instance => {
        if (instances.includes(instance)) return
        this.liveInstances.delete(instance)
        this.hardStop(instance, cause)
      }, () => {})
    }
    return stopped
  }

  /** Wait for the partial-write markers started by {@link terminate}. */
  async partialWritesSettled(): Promise<void> {
    await Promise.allSettled([...this.partialSettlements])
  }

  /** Diagnostics used by tests and the phone status screen. */
  stats(): {
    readonly programs: number
    readonly hotInstances: number
    readonly synchronousVfs: boolean
    readonly modules: { readonly modules: number; readonly compiles: number }
  } {
    return {
      programs: this.commands.size,
      hotInstances: this.instances.size,
      synchronousVfs: this.useSync,
      modules: this.moduleCache.stats(),
    }
  }

  private async acquire(command: ToolboxCommand, forceSnapshot = false): Promise<ProgramInstance> {
    if (!forceSnapshot) {
      const existing = this.instances.get(command.program)
      if (existing !== undefined) return existing
    }
    const created = this.createInstance(command, forceSnapshot).catch(error => {
      this.instances.delete(command.program)
      throw error
    })
    this.instances.set(command.program, created)
    return created
  }

  /**
   * Wait for the post-init file-view probe, bounded so a dead blocking channel
   * cannot hang a dispatch. A timeout is a broken view, never a silent pass.
   */
  private async awaitFileView(instance: ProgramInstance): Promise<ToolboxFileView> {
    if (instance.fileView !== undefined) return instance.fileView
    const immediate = instance.snapshot !== undefined
      ? snapshotFileView(
        instance.snapshot,
        this.requiredPreopens.map(guest => instance.server.preopens.find(preopen => preopen.guestPath === guest)?.hostPath ?? guest),
      )
      : undefined
    if (immediate !== undefined) {
      instance.fileView = immediate
      return immediate
    }
    if (!this.snapshotFallback) {
      // Toolboxes that do not opt into the fallback keep the documented
      // behaviour: the probe is diagnostic, the program reports its own I/O
      // errors. Only the class-level gated view waits for an answer.
      return { present: instance.server.preopens.map(preopen => preopen.guestPath), missing: [], via: 'none' }
    }
    const settled = await Promise.race([
      instance.view,
      new Promise<ToolboxFileView>(resolve => {
        const timer = setTimeout(() => {
          resolve({
            present: [],
            missing: instance.server.preopens.map(preopen => preopen.guestPath),
            via: 'sync',
            detail: `the file-view probe did not answer within ${this.viewTimeoutMs} ms`,
          })
        }, this.viewTimeoutMs)
        unrefTimer(timer)
      }),
    ])
    instance.fileView = settled
    return settled
  }

  /**
   * Replace the tool worker's local snapshot with a fresh capture of the live
   * preopened trees.
   *
   * A fallback view is captured once when the tool worker starts; without this
   * refresh every later WASI command would read the boot-time tree while
   * `bash` reads and writes the live VFS. Capturing at dispatch time makes the
   * two views agree on everything a previous step committed. The message is
   * posted before the next `exec`, and the worker processes messages in order.
   */
  private async refreshSnapshot(instance: ProgramInstance): Promise<ToolboxFileView> {
    const preopens = instance.server.preopens
    const snapshot = await captureVfsSnapshot(this.backend, preopens.map(preopen => preopen.hostPath))
    const required = this.requiredPreopens.map(
      guest => preopens.find(preopen => preopen.guestPath === guest)?.hostPath ?? guest,
    )
    const view = snapshotFileView(snapshot, required)
    instance.fileView = view
    instance.transport.postMessage({ type: 'snapshot', snapshot })
    // `postMessage` structured-clones synchronously; the worker owns the bytes
    // now and the host keeps only the view summary.
    instance.snapshot = { ...snapshot, entries: [] }
    return view
  }

  private async createInstance(command: ToolboxCommand, forceSnapshot = false): Promise<ProgramInstance> {
    const preopens = command.preopens ?? this.preopens
    const transport = this.spawnWorkerImpl(command)
    const server = new VfsProxyServer({ backend: this.backend, preopens, maxFrameBytes: this.maxFrameBytes })
    server.attach(transport)
    const ready = deferred<void>()
    const view = deferred<ToolboxFileView>()
    void view.promise.catch(() => {})
    // No blocking channel (or a forced recycle after a dead one): capture the
    // preopened trees over the async channel so the guest still has a view.
    const snapshot = this.snapshotFallback && (forceSnapshot || !this.useSync)
      ? await captureVfsSnapshot(this.backend, preopens.map(preopen => preopen.hostPath))
      : undefined
    let instance!: ProgramInstance
    instance = {
      command,
      transport,
      server,
      ready: ready.promise,
      ...(snapshot === undefined ? {} : { snapshot }),
      view: view.promise,
      tail: Promise.resolve(),
      closed: false,
    }
    this.liveInstances.add(instance)
    // Every mutation through the proxy belongs to the dispatch that is
    // currently running on this warm worker; a hard stop uses that set.
    server.onWrite = (path) => { instance.active?.written.add(path) }
    instance.viewResolve = (resolved) => {
      instance.fileView ??= resolved
      view.resolve(resolved)
    }
    if (snapshot !== undefined) {
      const requiredHosts = this.requiredPreopens.map(guest => preopens.find(preopen => preopen.guestPath === guest)?.hostPath ?? guest)
      instance.viewResolve(snapshotFileView(snapshot, requiredHosts))
    }
    instance.readyResolve = () => { ready.resolve() }
    instance.readyReject = error => { ready.reject(error) }
    void ready.promise.catch(() => {})
    instance.disposeMessage = transport.onMessage(message => { this.onWorkerMessage(instance, message) })
    instance.disposeError = transport.onError?.(error => {
      if (instance.active !== undefined) {
        this.forget(instance)
        this.settle(instance, this.failedResult(
          command.program,
          `tool worker failed: ${error.message}`,
          instance.active.request,
        ))
      } else {
        ready.reject(error)
      }
    })
    instance.readyTimer = setTimeout(() => {
      ready.reject(new WasiToolboxError(`tool worker for ${command.program} did not become ready in time`))
    }, this.workerReadyTimeoutMs)
    unrefTimer(instance.readyTimer)

    if (instance.closed) throw new WasiToolboxError('the toolbox was stopped while the tool worker was starting')
    let module: WebAssembly.Module
    try {
      module = await this.loadModule(command)
    } catch (error) {
      clearTimeout(instance.readyTimer)
      await this.detach(instance)
      throw error instanceof Error ? error : new WasiToolboxError(String(error))
    }
    const sync = snapshot === undefined && this.useSync
      ? server.createSyncEndpoint(this.maxFrameBytes)
      : undefined
    transport.postMessage({
      type: 'init',
      program: command.program,
      module,
      preopens,
      memoryLimitBytes: command.memoryLimitBytes ?? this.memoryLimitBytes,
      syncTimeoutMs: this.syncTimeoutMs,
      maxFrameBytes: this.maxFrameBytes,
      // The command table is part of the dispatch contract: the CPython
      // subprocess shim resolves argv[0] against the same aliases the shell
      // uses and lists this table in its loud unknown-program failure.
      programs: this.list(),
      ...(command.env === undefined ? {} : { defaultEnv: command.env }),
      ...(command.cwd === undefined ? {} : { defaultCwd: command.cwd }),
      ...(sync === undefined ? {} : { sync }),
      ...(snapshot === undefined ? {} : { snapshot }),
    })
    if (instance.snapshot !== undefined) {
      // `postMessage` structured-clones synchronously; the tool worker owns the
      // bytes now and the host keeps only the view summary.
      instance.snapshot = { ...instance.snapshot, entries: [] }
    }
    try {
      await ready.promise
    } catch (error) {
      clearTimeout(instance.readyTimer)
      await this.detach(instance)
      throw error
    }
    clearTimeout(instance.readyTimer)
    return instance
  }

  private execute(instance: ProgramInstance, request: ToolboxRunRequest): Promise<ToolboxResult> {
    const command = instance.command
    const id = this.nextExecId++
    const requestedArgv = [...(command.args ?? []), ...(request.argv ?? [])]
    // The guest must see the same directory the shell runs in. The shell
    // exports its cwd in PWD (with the legacy `/tmp`, `/workspace`, `/home`
    // spellings the command adapter keeps), while the WASI instance itself has
    // no cwd argument: resolve the one canonical guest cwd and hand it to the
    // program as both the exec cwd (for the runtime's startup shim) and PWD.
    const env: Record<string, string> = { ...(command.env ?? {}), ...(request.env ?? {}) }
    translateWorkerEnvironment(env)
    // A shell `cd` updates PWD but leaves the command's configured cwd as
    // the fallback, so PWD is the more specific source; `request.cwd` (the
    // adapter's mapped host cwd) wins over both.
    let cwd: string | undefined
    for (const candidate of [request.cwd, env.PWD, command.cwd]) {
      if (candidate === undefined) continue
      cwd = resolveGuestCwd(instance.server.preopens, candidate)
      if (cwd !== undefined) break
    }
    if (cwd !== undefined) env.PWD = cwd
    const argv = command.mapArgv === undefined
      ? requestedArgv
      : command.mapArgv(requestedArgv, {
        ...(cwd === undefined ? {} : { cwd }),
        env,
      })
    const stdin = request.stdin
    // stdin is delivered as an explicit owned step of the dispatch, never as
    // an incidental field of the exec message: bounded frames first, then the
    // exec that names the delivery. Only a command whose invocation reads its
    // program from stdin needs the read watchdog; a program that never reads
    // stdin (python3 -c ...) is not penalised for it.
    const scriptFromStdin = stdin !== undefined && command.scriptFromStdin?.(requestedArgv) === true
    return new Promise<ToolboxResult>(resolve => {
      const active: ActiveExec = {
        id,
        request,
        stdoutBytes: 0,
        stderrBytes: 0,
        ...streamLimitOptions(request),
        stdinRead: false,
        watchStdin: scriptFromStdin,
        ...(stdin === undefined ? {} : { expectedStdinBytes: stdin.byteLength }),
        written: new Set<string>(),
        resolve: result => {
          instance.active = undefined
          instance.lastWritten = active.written
          cleanup()
          resolve(result)
        },
      }
      const clearTimer = (timer: ReturnType<typeof setTimeout> | undefined): undefined => {
        if (timer !== undefined) clearTimeout(timer)
        return undefined
      }
      const failDispatch = (code: string, message: string): void => {
        if (instance.active !== active) return
        // Settle before releasing so the rejection path cannot resolve this
        // execution a second time as "cancelled".
        instance.stopCause ??= 'cancel'
        this.markPartialWrites(instance, active.written, 'cancel', command.program)
        this.settle(instance, this.failedResult(command.program, message, request, code))
        this.hardStop(instance, 'cancel')
      }
      let cleaned = false
      const cleanup = (): void => {
        if (cleaned) return
        cleaned = true
        active.startTimer = clearTimer(active.startTimer)
        active.stdinTimer = clearTimer(active.stdinTimer)
        request.signal?.removeEventListener('abort', onAbort)
      }
      const onAbort = (): void => {
        // Settle the dispatch synchronously: the tool worker may be blocked in
        // a proxied syscall whose own abort path never returns, and awaiting a
        // detach would put the settlement back behind the wedged worker
        // (G2-FIX-104). The transport termination stays in flight.
        if (instance.active !== active) return
        this.hardStop(instance, 'cancel')
      }
      instance.active = active
      if (request.signal !== undefined) request.signal.addEventListener('abort', onAbort, { once: true })
      if (isAborted(request.signal)) {
        // The signal aborted between the caller's pre-dispatch check and the
        // listener above; `abort` does not replay, so drive the same detach.
        onAbort()
        return
      }
      active.startTimer = setTimeout(() => {
        failDispatch(
          'E_EXEC_START_TIMEOUT',
          `the tool worker did not acknowledge the exec within ${this.execStartTimeoutMs} ms; `
          + 'the dispatch was wedged and stdin delivery could not be confirmed',
        )
      }, this.execStartTimeoutMs)
      unrefTimer(active.startTimer)
      try {
        if (stdin !== undefined) {
          for (const frame of splitStdinFrames(id, stdin)) instance.transport.postMessage(frame)
        }
        instance.transport.postMessage({
          type: 'exec',
          id,
          argv,
          env,
          ...(cwd === undefined ? {} : { cwd }),
          ...(stdin === undefined ? {} : { stdinBytes: stdin.byteLength, stdinEof: true }),
        })
      } catch (error) {
        failDispatch(
          'E_STDIN_UNEXPECTED',
          `the stdin delivery could not be posted to the tool worker: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
    })
  }

  private onWorkerMessage(instance: ProgramInstance, message: unknown): void {
    if (typeof message !== 'object' || message === null) return
    const type = (message as { type?: unknown }).type
    if (type === 'ready') {
      if (instance.readyTimer !== undefined) clearTimeout(instance.readyTimer)
      instance.readyResolve?.()
      return
    }
    if (type === 'init-error') {
      const detail = (message as { message?: unknown }).message
      instance.readyReject?.(new WasiToolboxError(
        typeof detail === 'string' ? detail : 'tool worker failed to initialise',
      ))
      return
    }
    if (type === 'preopens') {
      const present = stringList((message as { present?: unknown }).present)
      const missing = stringList((message as { missing?: unknown }).missing)
      instance.preopens = { present, missing }
      // The async probe is only authoritative when there is no blocking
      // channel: without one, it is exactly the control path the snapshot
      // fallback uses; with one, `sync-preopens` decides (G2-FIX-54).
      if (instance.snapshot !== undefined) return
      if (!this.useSync) {
        instance.viewResolve?.({
          present,
          missing,
          via: 'none',
          ...(missing.length === 0 ? {} : { detail: 'the async VFS control channel cannot resolve the preopens' }),
        })
      }
      return
    }
    if (type === 'sync-preopens') {
      const present = stringList((message as { present?: unknown }).present)
      const missing = stringList((message as { missing?: unknown }).missing)
      const detail = (message as { error?: unknown }).error
      instance.viewResolve?.(fileViewFromProbe(present, missing, this.requiredPreopens, 'sync',
        typeof detail === 'string' && detail !== '' ? detail : undefined))
      return
    }
    if (type === 'exec-started') {
      const active = instance.active
      if (active === undefined) return
      if ((message as { id?: unknown }).id !== active.id) return
      const assembled = (message as { stdinBytes?: unknown }).stdinBytes
      if (active.expectedStdinBytes !== undefined
        && (typeof assembled !== 'number' || assembled !== active.expectedStdinBytes)) {
        // The host delivered the bytes but the tool worker assembled a
        // different count: the script would run on a truncated stream. Fail
        // loud instead of letting the interpreter read a partial script.
        this.settle(instance, this.failedResult(
          instance.command.program,
          `the tool worker assembled ${typeof assembled === 'number' ? assembled : 'no'} stdin bytes `
          + `but the dispatch delivered ${active.expectedStdinBytes}`,
          active.request,
          'E_STDIN_INCOMPLETE',
        ))
        void this.detach(instance).catch(() => {})
        return
      }
      if (active.startTimer !== undefined) {
        clearTimeout(active.startTimer)
        active.startTimer = undefined
      }
      if (active.watchStdin && !active.stdinRead && active.stdinTimer === undefined) {
        // The interpreter is running now; its script is already in the tool
        // worker, so the first fd_read(0) must follow quickly. A worker that
        // starts but never reads the delivered script is the G2-A09 shape.
        active.stdinTimer = setTimeout(() => {
          if (instance.active !== active || active.stdinRead) return
          this.settle(instance, this.failedResult(
            instance.command.program,
            `the interpreter did not read its script from stdin within ${this.stdinReadTimeoutMs} ms; `
            + 'refusing to hold the Worker command lane until the shell timeout',
            active.request,
            'E_STDIN_READ_TIMEOUT',
          ))
          void this.detach(instance).catch(() => {})
        }, this.stdinReadTimeoutMs)
        unrefTimer(active.stdinTimer)
      }
      return
    }
    if (type === 'stdin-read') {
      const active = instance.active
      if (active === undefined) return
      if ((message as { id?: unknown }).id !== active.id) return
      active.stdinRead = true
      if (active.stdinTimer !== undefined) {
        clearTimeout(active.stdinTimer)
        active.stdinTimer = undefined
      }
      return
    }
    if (type === 'stdout' || type === 'stderr') {
      const active = instance.active
      if (active === undefined) return
      if ((message as { id?: unknown }).id !== active.id) return
      const chunk = (message as { chunk?: unknown }).chunk
      if (!(chunk instanceof Uint8Array)) return
      if (type === 'stdout') {
        const producedBefore = active.stdoutBytes
        active.stdoutBytes += chunk.byteLength
        const limit = active.stdoutLimit
        if (limit !== undefined && active.stdoutBytes > limit) {
          const keep = Math.max(0, limit - producedBefore)
          if (keep > 0) active.request.onStdout?.(chunk.subarray(0, keep))
          this.stopOnOutputLimit(instance, active, 'stdout', limit)
          return
        }
        active.request.onStdout?.(chunk)
      } else {
        const producedBefore = active.stderrBytes
        active.stderrBytes += chunk.byteLength
        const limit = active.stderrLimit
        if (limit !== undefined && active.stderrBytes > limit) {
          const keep = Math.max(0, limit - producedBefore)
          if (keep > 0) active.request.onStderr?.(chunk.subarray(0, keep))
          this.stopOnOutputLimit(instance, active, 'stderr', limit)
          return
        }
        active.request.onStderr?.(chunk)
      }
      return
    }
    if (type === 'exit') {
      const active = instance.active
      if (active === undefined) return
      if ((message as { id?: unknown }).id !== active.id) return
      const code = (message as { code?: unknown }).code
      const memoryPeakBytes = (message as { memoryPeakBytes?: unknown }).memoryPeakBytes
      this.settle(instance, {
        program: instance.command.program,
        exitCode: typeof code === 'number' ? code : 1,
        cancelled: false,
        memoryExceeded: (message as { memoryExceeded?: unknown }).memoryExceeded === true,
        memoryPeakBytes: typeof memoryPeakBytes === 'number' ? memoryPeakBytes : 0,
        stdoutBytes: active.stdoutBytes,
        stderrBytes: active.stderrBytes,
      })
      return
    }
    if (type === 'error') {
      const active = instance.active
      if (active === undefined) return
      const id = (message as { id?: unknown }).id
      if (id !== undefined && id !== active.id) return
      const detail = (message as { message?: unknown }).message
      const code = (message as { code?: unknown }).code
      this.settle(instance, this.failedResult(
        instance.command.program,
        typeof detail === 'string' ? detail : 'tool worker error',
        active.request,
        typeof code === 'string' ? code : undefined,
      ))
    }
  }

  /**
   * Stop a dispatch whose output crossed its per-stream cap.
   *
   * The guest is terminated rather than allowed to keep writing into the
   * Worker heap; the settled result keeps the produced byte counters, marks
   * which stream was truncated and carries a stable `E_OUTPUT_LIMIT` code. The
   * diagnostic itself is written through `onStderr` even when stderr was the
   * capped stream, because the consumer needs the reason.
   */
  private stopOnOutputLimit(
    instance: ProgramInstance,
    active: ActiveExec,
    stream: 'stdout' | 'stderr',
    limit: number,
  ): void {
    if (instance.active !== active) return
    const produced = stream === 'stdout' ? active.stdoutBytes : active.stderrBytes
    const kept = Math.min(limit, produced)
    const message = new TextEncoder().encode(
      `wasi-toolbox: ${instance.command.program}: ${stream} exceeded the ${String(limit)}-byte stream cap `
      + `(${String(produced)} bytes produced, ${String(kept)} kept); the guest was terminated [E_OUTPUT_LIMIT]\n`,
    )
    instance.stopCause ??= 'cancel'
    this.markPartialWrites(instance, active.written, 'cancel', instance.command.program)
    // `stdoutBytes`/`stderrBytes` count bytes the guest produced, not the
    // host's cap diagnostic. Both streams use the same rule so a stdout cap
    // stop cannot report a stderr count the guest never wrote.
    // Settle before writing the diagnostic: the consumer's collector may cross
    // its own stderr cap while receiving this message and abort the dispatch.
    // At this point the terminal E_OUTPUT_LIMIT result must already own the
    // promise, so the abort listener sees no active execution and cannot
    // replace it with a generic cancel result.
    this.settle(instance, {
      program: instance.command.program,
      exitCode: 1,
      cancelled: false,
      memoryExceeded: false,
      memoryPeakBytes: 0,
      stdoutBytes: active.stdoutBytes,
      stderrBytes: active.stderrBytes,
      failureCode: 'E_OUTPUT_LIMIT',
      ...stream === 'stdout' ? { stdoutTruncated: true } : { stderrTruncated: true },
    })
    active.request.onStderr?.(message)
    this.hardStop(instance, 'cancel')
  }

  private settle(instance: ProgramInstance, result: ToolboxResult): void {
    const active = instance.active
    if (active === undefined) return
    active.resolve(result)
  }

  /**
   * Stop one warm worker from outside its run loop.
   *
   * Resolves the active dispatch synchronously (so the caller's `run()`
   * promise is terminal now), marks the files it left half written, and asks
   * the transport to terminate without awaiting it — a worker blocked in a
   * proxied syscall cannot be allowed to delay settlement.
   * @returns 1 when an active dispatch was stopped, 0 for an idle worker.
   */
  private hardStop(instance: ProgramInstance, cause: ToolboxStopCause): number {
    if (instance.closed && instance.active === undefined) return 0
    instance.closed = true
    instance.stopCause ??= cause
    if (instance.readyTimer !== undefined) clearTimeout(instance.readyTimer)
    instance.disposeMessage?.()
    instance.disposeError?.()
    this.liveInstances.delete(instance)
    this.instances.delete(instance.command.program)
    // A worker that was still mounting must not complete its init after the
    // stop: reject the readiness gate so `createInstance` unwinds.
    instance.readyReject?.(new WasiToolboxError('the toolbox was stopped while the tool worker was starting'))
    const active = instance.active
    let stopped = 0
    if (active !== undefined) {
      stopped = 1
      this.markPartialWrites(instance, active.written, cause, instance.command.program)
      active.resolve(this.stopResult(instance.command.program, active, cause))
    }
    try {
      const terminated = instance.transport.terminate()
      if (terminated instanceof Promise) void terminated.catch(() => {})
    } catch {
      // A worker that already died has nothing to release.
    }
    return stopped
  }

  /** The terminal result a hard-stopped dispatch reports. */
  private stopResult(program: string, active: ActiveExec, cause: ToolboxStopCause): ToolboxResult {
    const code = cause === 'timeout' ? 'E_JOB_TIMEOUT' : cause === 'drain' ? 'E_JOB_DRAIN' : 'E_JOB_CANCEL'
    const detail = cause === 'timeout'
      ? 'timed out at the job deadline; the interpreter was hard-terminated'
      : cause === 'drain'
        ? 'cancelled by the host drain; the interpreter was hard-terminated'
        : 'cancelled; the interpreter was hard-terminated'
    const message = new TextEncoder().encode(`wasi-toolbox: ${program}: ${detail} [${code}]\n`)
    active.request.onStderr?.(message)
    return {
      program,
      exitCode: cause === 'timeout' ? 124 : 130,
      cancelled: cause !== 'timeout',
      memoryExceeded: false,
      memoryPeakBytes: 0,
      stdoutBytes: active.stdoutBytes,
      stderrBytes: active.stderrBytes + message.byteLength,
      failureCode: code,
    }
  }

  /**
   * Mark every file an aborted dispatch mutated.
   *
   * The WAL keeps a write that already happened (D8/D9), so a hard stop must
   * leave a terminal state the host can materialize: a `*.pdsh-partial` marker
   * beside the file naming the cause, program and time. When even that write
   * is refused, the half-written file is removed instead so the workspace
   * never carries an unmarked partial file.
   */
  private markPartialWrites(
    instance: ProgramInstance,
    written: ReadonlySet<string>,
    cause: ToolboxStopCause,
    program: string,
  ): void {
    if (written.size === 0) return
    const task = (async (): Promise<void> => {
      for (const path of [...written]) {
        if (path.endsWith(PARTIAL_WRITE_SUFFIX)) continue
        const marker = `${path}${PARTIAL_WRITE_SUFFIX}`
        const payload = new TextEncoder().encode(`${JSON.stringify({
          v: 1,
          kind: 'pdsh-partial-write',
          program,
          path,
          cause,
          at_ms: Date.now(),
        })}\n`)
        try {
          await this.backend.writeFile(marker, payload, { create: true })
          this.partialMarkers.add(marker)
        } catch (error) {
          try {
            await this.backend.unlink(path, { directory: false, recursive: false })
            console.info(`wasi-toolbox: removed unmarked partial file ${path} (${cause})`)
          } catch {
            console.error(`wasi-toolbox: could not mark or remove the partial file ${path}`, error)
          }
        }
      }
    })()
    this.partialSettlements.add(task)
    void task.finally(() => { this.partialSettlements.delete(task) }).catch(() => {})
  }

  /** Drop markers left by an earlier aborted attempt once the path completed. */
  private clearPartialMarkers(written: ReadonlySet<string> | undefined): void {
    if (written === undefined || written.size === 0) return
    for (const path of written) {
      if (path.endsWith(PARTIAL_WRITE_SUFFIX)) continue
      const marker = `${path}${PARTIAL_WRITE_SUFFIX}`
      if (!this.partialMarkers.has(marker)) continue
      this.partialMarkers.delete(marker)
      try {
        // A backend may throw synchronously for a missing marker.
        void Promise.resolve(this.backend.unlink(marker, { directory: false, recursive: false }))
          .catch(() => {})
      } catch {
        // The marker was already gone.
      }
    }
  }

  /** Drop a dead worker from the pool without trying to terminate it again. */
  private forget(instance: ProgramInstance): void {
    if (instance.closed) return
    instance.closed = true
    if (instance.readyTimer !== undefined) clearTimeout(instance.readyTimer)
    instance.disposeMessage?.()
    instance.disposeError?.()
    this.liveInstances.delete(instance)
    this.instances.delete(instance.command.program)
    void instance.transport.terminate()
  }

  private async detach(instance: ProgramInstance): Promise<void> {
    if (instance.closed) return
    instance.closed = true
    if (instance.readyTimer !== undefined) clearTimeout(instance.readyTimer)
    instance.disposeMessage?.()
    instance.disposeError?.()
    this.liveInstances.delete(instance)
    const current = this.instances.get(instance.command.program)
    if (current !== undefined) {
      const resolved = await current.catch(() => undefined)
      if (resolved === instance) this.instances.delete(instance.command.program)
    }
    await instance.transport.terminate()
    const active = instance.active
    if (active !== undefined) active.resolve(this.cancelledResult(instance.command.program, active.request))
  }

  private async loadModule(command: ToolboxCommand): Promise<WebAssembly.Module> {
    if (command.module instanceof WebAssembly.Module) return command.module
    return this.moduleCache.getModule(command.module)
  }

  private cancelledResult(program: string, request: ToolboxRunRequest): ToolboxResult {
    const message = `wasi-toolbox: ${program}: cancelled\n`
    request.onStderr?.(new TextEncoder().encode(message))
    return {
      program,
      exitCode: 130,
      cancelled: true,
      memoryExceeded: false,
      memoryPeakBytes: 0,
      stdoutBytes: 0,
      stderrBytes: message.length,
    }
  }

  private failedResult(program: string, message: string, request?: ToolboxRunRequest, code?: string): ToolboxResult {
    const text = `wasi-toolbox: ${program}: ${message}${code === undefined ? '' : ` [${code}]`}\n`
    request?.onStderr?.(new TextEncoder().encode(text))
    return {
      program,
      exitCode: 134,
      cancelled: false,
      memoryExceeded: false,
      memoryPeakBytes: 0,
      stdoutBytes: 0,
      stderrBytes: text.length,
      ...(code === undefined ? {} : { failureCode: code }),
    }
  }

  private validatePreopens(preopens: readonly GuestPreopen[]): void {
    const seen = new Set<string>()
    for (const preopen of preopens) {
      let guest: string
      let host: string
      try {
        guest = normalizeAbsolutePath(preopen.guestPath)
        host = normalizeAbsolutePath(preopen.hostPath)
      } catch (error) {
        throw new WasiToolboxError(
          `preopen paths must be absolute: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      if (seen.has(guest)) throw new WasiToolboxError(`duplicate preopen guest path ${guest}`)
      seen.add(guest)
      if (!host.startsWith('/')) throw new VfsProxyError('EINVAL', 'preopen host path must be absolute', host)
    }
  }
}

function defaultSpawnWorker(url: URL | string): ToolWorkerTransport {
  const WorkerCtor = (globalThis as { Worker?: typeof Worker }).Worker
  if (WorkerCtor === undefined) {
    throw new WasiToolboxError('no Worker constructor in this host; pass spawnWorker to WasiToolbox')
  }
  const worker = new WorkerCtor(url, { type: 'module' })
  return workerTransport(worker)
}

/** The file view a captured snapshot gives the guest. */
function snapshotFileView(snapshot: VfsSnapshot, required: readonly string[]): ToolboxFileView {
  const unresolved = [...snapshot.missing]
  if (snapshot.truncated) unresolved.push(...snapshot.roots)
  const missing = unresolved.filter(root => required.includes(root))
  return {
    present: snapshot.roots.filter(root => !unresolved.includes(root)),
    missing,
    unresolved,
    via: 'snapshot',
    detail: snapshot.truncated
      ? `the snapshot capture hit its limit (${snapshot.bytes} B, ${snapshot.omitted} entries omitted); `
        + 'the guest file view would be incomplete'
      : undefined,
  }
}

/** Build one file view from a probe answer, keeping required roots separate. */
function fileViewFromProbe(
  present: readonly string[],
  unresolved: readonly string[],
  required: readonly string[],
  via: ToolboxFileViewChannel,
  detail: string | undefined,
): ToolboxFileView {
  return {
    present,
    missing: unresolved.filter(root => required.includes(root)),
    unresolved,
    via,
    ...(detail === undefined ? {} : { detail }),
  }
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function isAborted(signal: AbortSignal | undefined): boolean {
  return signal !== undefined && signal.aborted
}

function unrefTimer(timer: ReturnType<typeof setTimeout>): void {
  const unref = (timer as { unref?: () => void }).unref
  if (typeof unref === 'function') unref.call(timer)
}
