// SPDX-License-Identifier: MIT
/**
 * The dedicated tool worker's runtime: it receives a compiled module and the
 * synchronous VFS channel from the DSH worker, owns one `HotInstance`, and
 * streams stdout/stderr and the exit code back over the control channel.
 *
 * It initialises synchronously on the `init` message (the module arrives as a
 * structured clone), so the DSH worker can post `exec` immediately after
 * `ready`. When the host has no synchronous channel it sends a `snapshot`
 * instead: the preopened trees captured over the async control channel, mounted
 * as a local `SnapshotWasiVfs` whose mutations are written back before the exit
 * is reported (G2-FIX-54).
 * @module @phone-dsh/dsh-wasi-toolbox/tool-worker-runtime
 */
import { WasiToolboxError } from './errors.ts'
import { DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PREOPENS, DEFAULT_VFS_SYNC_TIMEOUT_MS } from './limits.ts'
import { HotInstance, HotInstancePool } from './hot-instance.ts'
import { AsyncVfsClient, ProxyWasiVfs, SyncVfsClient, UnavailableWasiVfs } from './vfs-client.ts'
import { probeSynchronousPreopens } from './preopen-probe.ts'
import { isStdinFrame, StdinAssembly, StdinDeliveryError } from './stdin-delivery.ts'
import { isVfsSnapshot, SnapshotWasiVfs } from './vfs-snapshot.ts'
import type { VfsSnapshot } from './vfs-snapshot.ts'
import type { ToolWorkerScope } from './worker-scope.ts'
import type { GuestPreopen, VfsRequest, WasiVfs } from './types.ts'

/** Init message the DSH worker sends after spawning the tool worker. */
export interface ToolWorkerInitMessage {
  readonly type: 'init'
  readonly program: string
  readonly module: WebAssembly.Module
  readonly preopens?: readonly GuestPreopen[]
  readonly memoryLimitBytes?: number
  readonly defaultEnv?: Readonly<Record<string, string>>
  readonly defaultCwd?: string
  /** Present when the host supports SharedArrayBuffer (crossOriginIsolated). */
  readonly sync?: {
    readonly control: SharedArrayBuffer
    readonly request: SharedArrayBuffer
    readonly response: SharedArrayBuffer
  }
  /**
   * Present when the host has no synchronous channel: the preopened trees
   * captured over the async channel, served locally with write-behind.
   */
  readonly snapshot?: VfsSnapshot
  readonly syncTimeoutMs?: number
  readonly maxFrameBytes?: number
  /**
   * The toolbox command table at init time. A program that nests an
   * interpreter (the CPython `subprocess` shim) resolves argv[0] against this
   * same table, and the loud unknown-program failure lists it. Absent for a
   * tool worker that no table entry can nest into.
   */
  readonly programs?: readonly {
    readonly program: string
    readonly aliases?: readonly string[] | undefined
  }[]
}

/** Exec message the DSH worker sends for each command. */
export interface ToolWorkerExecMessage {
  readonly type: 'exec'
  readonly id: number
  readonly argv?: readonly string[]
  readonly env?: Readonly<Record<string, string>>
  readonly cwd?: string
  /** Legacy inline payload; new hosts deliver `stdin` frames before the exec. */
  readonly stdin?: Uint8Array
  /** Number of bytes the host delivered in the stdin frames, when named. */
  readonly stdinBytes?: number
  /** True when the host sent the complete delivery (EOF included). */
  readonly stdinEof?: boolean
}

interface RuntimeState {
  pool: HotInstancePool
  program: string
  preopens: readonly GuestPreopen[]
  /** Frames of the exec the host is delivering; taken on `exec`. */
  stdin: StdinAssembly
  asyncClient: AsyncVfsClient
  /** Local view whose queued mutations must settle before the exit message. */
  view?: SnapshotWasiVfs | undefined
  /** Synchronous client, for the post-init preopen verification. */
  syncClient?: SyncVfsClient | undefined
}

/**
 * Install the tool worker message loop on a scope. Returns a disposer that
 * detaches the listener (used by tests).
 */
export function installToolWorker(scope: ToolWorkerScope): () => void {
  let state: RuntimeState | undefined

  const post = (message: unknown): void => { scope.postMessage(message) }

  const handle = (message: unknown): void => {
    if (typeof message !== 'object' || message === null) return
    const type = (message as { type?: unknown }).type
    if (type === 'init') {
      try {
        state = createState(message as ToolWorkerInitMessage, scope)
        post({ type: 'ready', program: state.program })
        probePreopens(state, post)
        probeSynchronousPreopens(state.syncClient, state.program, state.preopens, post)
      } catch (error) {
        post({
          type: 'init-error',
          program: (message as { program?: unknown }).program,
          message: error instanceof Error ? error.message : String(error),
        })
      }
      return
    }
    if (state === undefined) {
      post({ type: 'error', message: 'tool worker received a command before init' })
      return
    }
    if (type === 'snapshot') {
      // The host recaptured the preopened trees between commands: replace the
      // local view so a bash write made since the previous python run is
      // visible to the next one (G2-FIX-54). The body crosses a thread
      // boundary, so validate it instead of casting.
      const snapshot = (message as { snapshot?: unknown }).snapshot
      if (!isVfsSnapshot(snapshot)) {
        post({ type: 'error', message: 'tool worker received a malformed snapshot message' })
        return
      }
      state.view?.update(snapshot)
      return
    }
    if (type === 'stdin') {
      // The host sends every stdin frame before the exec it belongs to.
      if (!isStdinFrame(message)) {
        post({ type: 'error', code: 'E_STDIN_UNEXPECTED', message: 'tool worker received a malformed stdin frame' })
        return
      }
      try {
        state.stdin.accept(message)
      } catch (error) {
        post({
          type: 'error',
          id: message.id,
          code: error instanceof StdinDeliveryError ? error.code : 'E_STDIN_UNEXPECTED',
          message: error instanceof Error ? error.message : String(error),
        })
      }
      return
    }
    if (type === 'exec') {
      void execute(state, message as ToolWorkerExecMessage, post)
      return
    }
    if (type === 'reset') {
      state.pool.release(state.program)
      post({ type: 'reset-ok', program: state.program })
      return
    }
    if (type === 'terminate') {
      state.pool.terminate(state.program)
      scope.close?.()
      return
    }
    if (type === 'ping') {
      post({ type: 'pong' })
      return
    }
    // VFS request/response and sync-wake frames belong to the proxy clients.
  }

  return scope.onMessage(handle)
}

function createState(message: ToolWorkerInitMessage, scope: ToolWorkerScope): RuntimeState {
  if (!(message.module instanceof WebAssembly.Module)) {
    throw new WasiToolboxError('init message does not carry a WebAssembly.Module')
  }
  const endpoint = {
    postMessage: (outbound: unknown): void => { scope.postMessage(outbound) },
    onMessage: (handler: (inbound: unknown) => void): (() => void) => scope.onMessage(handler),
  }
  // The async client serves the control-plane preopen probe (batched stat)
  // regardless of the synchronous channel; WASI syscalls use the SAB client.
  const asyncClient = new AsyncVfsClient(endpoint, {
    timeoutMs: message.syncTimeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS,
  })
  let vfs: WasiVfs = new UnavailableWasiVfs()
  let view: SnapshotWasiVfs | undefined
  let syncClient: SyncVfsClient | undefined
  if (message.sync !== undefined) {
    syncClient = new SyncVfsClient({
      control: message.sync.control,
      request: message.sync.request,
      response: message.sync.response,
      endpoint,
      timeoutMs: message.syncTimeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS,
    })
    vfs = new ProxyWasiVfs(syncClient)
  } else if (message.snapshot !== undefined) {
    // No SharedArrayBuffer: serve the captured view synchronously and write
    // every mutation back over the async channel before the exit is reported.
    view = new SnapshotWasiVfs(message.snapshot, { call: (request: VfsRequest) => asyncClient.call(request) })
    vfs = view
  }
  const pool = new HotInstancePool({
    create: program => new HotInstance({
      program,
      module: message.module,
      vfs,
      preopens: message.preopens ?? DEFAULT_PREOPENS,
      memoryLimitBytes: message.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES,
      ...(message.defaultEnv === undefined ? {} : { defaultEnv: message.defaultEnv }),
      ...(message.defaultCwd === undefined ? {} : { defaultCwd: message.defaultCwd }),
    }),
  })
  return {
    pool,
    program: message.program,
    preopens: message.preopens ?? DEFAULT_PREOPENS,
    stdin: new StdinAssembly(),
    asyncClient,
    view,
    syncClient,
  }
}

/**
 * Probe every preopen root with one batched async `stat`, reporting which
 * roots exist. This is the non-blocking proxy path; it never gates execution.
 */
function probePreopens(state: RuntimeState, post: (message: unknown) => void): void {
  void state.asyncClient
    .batchSettled(state.preopens.map(preopen => ({ op: 'stat' as const, path: preopen.hostPath })))
    .then(results => {
      const missing: string[] = []
      const present: string[] = []
      results.forEach((result, index) => {
        const preopen = state.preopens[index]
        if (preopen === undefined) return
        if (result.value?.kind === 'stat') present.push(preopen.guestPath)
        else missing.push(preopen.guestPath)
      })
      post({ type: 'preopens', program: state.program, present, missing })
    })
    .catch((error: unknown) => {
      post({
        type: 'preopens',
        program: state.program,
        present: [],
        missing: state.preopens.map(preopen => preopen.guestPath),
        error: error instanceof Error ? error.message : String(error),
      })
    })
}

async function execute(
  state: RuntimeState,
  message: ToolWorkerExecMessage,
  post: (message: unknown) => void,
): Promise<void> {
  let stdin: Uint8Array
  try {
    stdin = message.stdin ?? state.stdin.take(message.id)
  } catch (error) {
    // A truncated delivery is a dispatch failure, not an empty script: the
    // host turns this into a structured error instead of waiting for an exit
    // the interpreter can never produce (E_STDIN_INCOMPLETE).
    post({
      type: 'error',
      id: message.id,
      code: error instanceof StdinDeliveryError ? error.code : 'E_STDIN_INCOMPLETE',
      message: error instanceof Error ? error.message : String(error),
    })
    return
  }
  if (message.stdinBytes !== undefined && message.stdinBytes !== stdin.byteLength) {
    post({
      type: 'error',
      id: message.id,
      code: 'E_STDIN_INCOMPLETE',
      message: `exec ${message.id} named ${message.stdinBytes} stdin bytes but ${stdin.byteLength} arrived`,
    })
    return
  }
  // The inbox has the complete stdin feed now; tell the host before entering
  // the synchronous interpreter, which is the only liveness evidence until
  // the first fd_read(0) arrives.
  post({ type: 'exec-started', id: message.id, stdinBytes: stdin.byteLength })
  let readReported = false
  const result = state.pool.acquire(state.program).run({
    ...(message.argv === undefined ? {} : { argv: message.argv }),
    ...(message.env === undefined ? {} : { env: message.env }),
    ...(message.cwd === undefined ? {} : { cwd: message.cwd }),
    stdin,
    onStdinRead: () => {
      if (readReported) return
      readReported = true
      post({ type: 'stdin-read', id: message.id })
    },
    onStdout: chunk => { post({ type: 'stdout', id: message.id, chunk }) },
    onStderr: chunk => { post({ type: 'stderr', id: message.id, chunk }) },
  })
  let exitCode = result.exitCode
  // The guest finished against the local view; the live VFS gets the bytes
  // before the next step observes the command as complete.
  if (state.view !== undefined) {
    try {
      await state.view.flushWrites()
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error)
      post({ type: 'stderr', id: message.id, chunk: new TextEncoder().encode(`wasi-toolbox: ${detail}\n`) })
      if (exitCode === 0) exitCode = 1
    }
  }
  post({
    type: 'exit',
    id: message.id,
    code: exitCode,
    memoryExceeded: result.memoryExceeded,
    memoryPeakBytes: result.memoryPeakBytes,
    stdoutBytes: result.stdoutBytes,
    stderrBytes: result.stderrBytes,
  })
}
