// SPDX-License-Identifier: MIT
/**
 * Worker runtime of the CPython package: the dedicated tool worker that runs
 * `python.wasm` through the W7 WASI host. It differs from the generic
 * `installToolWorker` in exactly one place: the writable VFS proxy is wrapped
 * in an {@link OverlayWasiVfs}, so the CPython standard library zip lives in an
 * in-memory read-only layer of *this* worker and `import json, re, pathlib`
 * never performs a VFS proxy request. The workspace and home preopens still go
 * through the synchronous proxy, so a Python write is an ordinary DSH write.
 *
 * The message protocol is the toolbox's: `init`, `exec`, `reset`, `terminate`,
 * `ping`; replies are `ready`, `stdout`, `stderr`, `exit`, `error` plus the
 * package-private `python-info` / `python` diagnostics fields the host wrapper
 * reads.
 *
 * The worker also installs the subprocess bridge. The read-only layer carries a
 * `subprocess` shadow module and `_xl_subprocess.py`; the WASI host intercepts
 * the private `/__xl__/spawn` descriptor. A guest `Popen` therefore runs a
 * fresh interpreter instance through this same `HotInstancePool` and the same
 * `WasiVfs` object (proxy or snapshot) as the parent command — one filesystem
 * path, one durability fence (G2-FIX-61), one preopen/cwd table (G2-FIX-23).
 * @module @phone-dsh/dsh-wasi-toolbox/python/python-worker-runtime
 */
import { WasiToolboxError, WasiTrapError } from '../src/errors.ts'
import {
  createLoopbackXhrTransport,
} from '../src/http-bridge.ts'
import type { HttpTransport, LoopbackHttpRoute } from '../src/http-bridge.ts'
import { HotInstance, HotInstancePool } from '../src/hot-instance.ts'
import {
  PYTHON_CWD_SHIM_DIR_NAME,
  PYTHON_CWD_SHIM_FILENAME,
  PYTHON_CWD_SHIM_SOURCE,
  pythonCwdShimGuestDir,
} from './cwd-shim.ts'
import { DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PREOPENS, DEFAULT_VFS_SYNC_TIMEOUT_MS } from '../src/limits.ts'
import { AsyncVfsClient, ProxyWasiVfs, SyncVfsClient, UnavailableWasiVfs } from '../src/vfs-client.ts'
import { probeSynchronousPreopens } from '../src/preopen-probe.ts'
import { OverlayWasiVfs, ReadOnlyMemoryVfs } from '../src/readonly-vfs.ts'
import {
  MAX_SPAWN_DEPTH, MAX_SPAWN_STDIO_BYTES, SpawnBridgeError, spawnProgramTable,
  PDSH_SPAWN_GUEST_ROOT, PDSH_SPAWN_HOST_ROOT,
} from '../src/spawn-bridge.ts'
import type { HotRunResult, NestedSpawner } from '../src/hot-instance.ts'
import type { SpawnExecRequest, SpawnExecResult } from '../src/spawn-bridge.ts'
import { isStdinFrame, StdinAssembly, StdinDeliveryError } from '../src/stdin-delivery.ts'
import { resolveGuestCwd, resolveGuestPath } from '../src/vfs-paths.ts'
import { isVfsSnapshot, SnapshotWasiVfs } from '../src/vfs-snapshot.ts'
import { PYTHON_SHIM_ROOT, pythonShimFiles, withPythonShims } from './subprocess-shim.ts'
import type { ToolWorkerInitMessage } from '../src/tool-worker-runtime.ts'
import type { VfsRequest } from '../src/types.ts'
import type { GuestPreopen, VfsDirEntry, VfsOpenOptions, VfsStat, WasiVfs } from '../src/types.ts'
import type { ToolWorkerScope } from '../src/worker-scope.ts'

/** Where the standard library zip is mounted inside the guest. */
export interface PythonStdlibMount {
  /** Bytes of the zipped standard library (`python313.zip`). */
  readonly stdlibZip: Uint8Array
  /** Guest path of the zip; also the default `PYTHONPATH`. */
  readonly guestPath: string
  /** Host path the read-only layer is mounted at inside the tool worker. */
  readonly hostRoot: string
}

/** Init message of the python tool worker. */
export interface PythonWorkerInitMessage extends ToolWorkerInitMessage {
  readonly python: PythonStdlibMount
  /**
   * Loopback `/v1/http` coordinates injected by the DSH Worker. The bearer is
   * consumed here by the synchronous XHR transport and never enters the guest
   * environment or the VFS.
   */
  readonly http?: LoopbackHttpRoute
}

/** Counters the host wrapper records to prove the layer stays in-worker. */
export interface PythonWorkerMetrics {
  /** Calls that reached the writable VFS proxy. */
  readonly proxyCalls: number
  /** Calls that reached the writable VFS proxy for a path under `hostRoot`. */
  readonly proxyStdlibReads: number
  /** Size of the mounted standard library zip. */
  readonly stdlibBytes: number
}

export interface PythonWorkerState {
  readonly pool: HotInstancePool
  readonly program: string
  readonly preopens: readonly GuestPreopen[]
  /** Frames of the exec the host is delivering; taken on `exec`. */
  readonly stdin: StdinAssembly
  readonly asyncClient: AsyncVfsClient
  readonly metrics: PythonWorkerCounters
  readonly stdlib: PythonStdlibMount
  readonly proxyPreopens: readonly GuestPreopen[]
  /** Local snapshot view whose queued mutations must settle before `exit`. */
  readonly view?: SnapshotWasiVfs | undefined
  /** Synchronous client used by the post-init preopen verification. */
  readonly syncClient?: SyncVfsClient | undefined
}

/** Mutable counters shared by the worker state and the VFS wrapper. */
export interface PythonWorkerCounters {
  proxyCalls: number
  proxyStdlibReads: number
}

/** The composed VFS and the extra preopen it needs. */
export interface PythonVfsBundle {
  readonly vfs: WasiVfs
  readonly preopen: GuestPreopen
  readonly zipHostPath: string
  /** Host path of the mounted startup cwd shim (`sitecustomize.py`). */
  readonly cwdShimHostPath: string
  /** Guest directory that must be on `PYTHONPATH` to import the shim. */
  readonly cwdShimGuestDir: string
  /** Read-only preopen of the subprocess shadow module directory. */
  readonly subprocessPreopen: GuestPreopen
  /** Private preopen of the spawn control file; the WASI host intercepts it. */
  readonly spawnPreopen: GuestPreopen
  readonly metrics: PythonWorkerCounters
}

interface WorkerMessage {
  readonly type?: unknown
  readonly id?: unknown
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

/**
 * Install the python tool worker on a scope. Returns a disposer that detaches
 * the message listener; tests use it to run several workers in one thread.
 */
export function installPythonToolWorker(scope: ToolWorkerScope): () => void {
  let state: PythonWorkerState | undefined
  const post = (message: unknown): void => { scope.postMessage(message) }

  const handle = (message: unknown): void => {
    if (typeof message !== 'object' || message === null) return
    const type = (message as { type?: unknown }).type
    if (type === 'init') {
      try {
        state = createState(message as PythonWorkerInitMessage, scope)
        post({
          type: 'ready',
          program: state.program,
          python: {
            stdlibZip: state.stdlib.guestPath,
            stdlibBytes: state.stdlib.stdlibZip.byteLength,
            stdlibHostRoot: state.stdlib.hostRoot,
          },
        })
        probePreopens(state, post)
        probeSynchronousPreopens(state.syncClient, state.program, state.proxyPreopens, post)
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
      post({ type: 'error', message: 'python tool worker received a command before init' })
      return
    }
    if (type === 'snapshot') {
      // The host recaptured the preopened trees between commands: replace the
      // local view so a bash write made since the previous python3 run is
      // visible to the next one (G2-FIX-54). The body crosses a thread
      // boundary, so validate it instead of casting.
      const snapshot = (message as { snapshot?: unknown }).snapshot
      if (!isVfsSnapshot(snapshot)) {
        post({ type: 'error', message: 'python tool worker received a malformed snapshot message' })
        return
      }
      state.view?.update(snapshot)
      return
    }
    if (type === 'stdin') {
      // The host sends every stdin frame before the exec it belongs to.
      if (!isStdinFrame(message)) {
        post({ type: 'error', code: 'E_STDIN_UNEXPECTED', message: 'python tool worker received a malformed stdin frame' })
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
      void execute(state, message as WorkerMessage, post)
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
      post({ type: 'pong', python: snapshotMetrics(state) })
    }
    // VFS request/response and sync-wake frames belong to the proxy clients.
  }

  return scope.onMessage(handle)
}

function createState(message: PythonWorkerInitMessage, scope: ToolWorkerScope): PythonWorkerState {
  if (!(message.module instanceof WebAssembly.Module)) {
    throw new WasiToolboxError('init message does not carry a WebAssembly.Module')
  }
  const stdlib = message.python
  if (stdlib === undefined || !(stdlib.stdlibZip instanceof Uint8Array) || stdlib.stdlibZip.byteLength === 0) {
    throw new WasiToolboxError('init message does not carry the CPython standard library zip')
  }
  if (!stdlib.guestPath.startsWith('/') || !stdlib.hostRoot.startsWith('/')) {
    throw new WasiToolboxError('the standard library mount paths must be absolute')
  }
  const httpTransport = message.http === undefined ? undefined : createHttpTransport(message.http)
  const endpoint = {
    postMessage: (outbound: unknown): void => { scope.postMessage(outbound) },
    onMessage: (handler: (inbound: unknown) => void): (() => void) => scope.onMessage(handler),
  }
  const asyncClient = new AsyncVfsClient(endpoint, {
    timeoutMs: message.syncTimeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS,
  })
  const proxyPreopens = message.preopens ?? DEFAULT_PREOPENS
  const metrics: PythonWorkerCounters = { proxyCalls: 0, proxyStdlibReads: 0 }
  let writable: WasiVfs = new UnavailableWasiVfs()
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
    writable = new ProxyWasiVfs(syncClient)
  } else if (message.snapshot !== undefined) {
    // No SharedArrayBuffer in this host: serve the captured preopened trees
    // synchronously and write mutations back over the async channel before the
    // exit is reported (G2-FIX-54, the same fallback the generic runtime has).
    view = new SnapshotWasiVfs(message.snapshot, { call: (request: VfsRequest) => asyncClient.call(request) })
    writable = view
  }
  const bundle = createPythonVfs({ writable, stdlib, metrics })
  // The private mounts are invisible to the shell: they are added inside this
  // tool worker so the guest can import the subprocess shim and reach the
  // spawn descriptor, while every ordinary path still uses the proxy chain.
  const preopens: readonly GuestPreopen[] = [
    ...proxyPreopens,
    bundle.preopen,
    bundle.subprocessPreopen,
    bundle.spawnPreopen,
  ]
  const defaultEnv = withPythonShims(message.defaultEnv, {
    stdlibZip: stdlib.guestPath,
    cwdShimDir: bundle.cwdShimGuestDir,
  })
  // The toolbox command table the host posted with init is the spawn table:
  // aliases are the shell's own, and the unknown-program failure lists the
  // programs the Worker can dispatch.
  const spawnTable = spawnProgramTable(
    message.program,
    message.programs ?? [{ program: message.program }],
  )
  const nestedContext: NestedContext = {
    // Bound to the pool below; a nested run only happens during an exec, long
    // after this object and the pool are fully constructed.
    pool: undefined as unknown as HotInstancePool,
    program: message.program,
    vfs: bundle.vfs,
    preopens,
    defaultCwd: message.defaultCwd,
  }
  const nested: NestedSpawner = {
    table: spawnTable,
    run: request => runNestedSpawn(nestedContext, request),
  }
  const pool = new HotInstancePool({
    create: program => new HotInstance({
      program,
      module: message.module,
      vfs: bundle.vfs,
      preopens,
      memoryLimitBytes: message.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES,
      defaultEnv,
      ...(message.defaultCwd === undefined ? {} : { defaultCwd: message.defaultCwd }),
      spawn: nested,
      ...(httpTransport === undefined ? {} : { http: httpTransport }),
    }),
  })
  // The spawner needs the pool it belongs to; bind it once the pool exists so
  // a nested run reuses the same warm instance/module/VFS rather than
  // constructing a second world.
  nestedContext.pool = pool
  return {
    pool,
    program: message.program,
    preopens,
    stdin: new StdinAssembly(),
    asyncClient,
    metrics,
    stdlib,
    proxyPreopens,
    view,
    syncClient,
  }
}

/**
 * Build the guest's only network transport from the injected loopback route.
 * A bad route fails init loudly: the alternative is a Python process whose
 * network silently disappears.
 */
function createHttpTransport(route: LoopbackHttpRoute): HttpTransport {
  if (
    typeof route !== 'object' || route === null
    || typeof route.origin !== 'string' || route.origin === ''
    || typeof route.token !== 'string' || route.token === ''
  ) {
    throw new WasiToolboxError('the python init http route must carry a non-empty origin and token')
  }
  return createLoopbackXhrTransport({ origin: route.origin, token: route.token })
}

/** The context one nested interpreter run needs. */
interface NestedContext {
  pool: HotInstancePool
  program: string
  vfs: WasiVfs
  preopens: readonly GuestPreopen[]
  defaultCwd: string | undefined
}

/**
 * Run one nested interpreter instance for the Python `subprocess` shim.
 *
 * The child is a fresh `WebAssembly.Instance` from the same warm instance, on
 * the same tool-worker thread and the same `WasiVfs`; stdout/stderr are piped
 * through this function instead of the parent's streams. `cwd` is resolved
 * through the same preopen table the shell dispatch uses, and the depth cap
 * turns a runaway spawn chain into one loud error.
 */
function runNestedSpawn(context: NestedContext, request: SpawnExecRequest & { depth: number }): SpawnExecResult {
  if (request.depth + 1 > MAX_SPAWN_DEPTH) {
    throw new SpawnBridgeError(
      'depth',
      `subprocess nesting depth ${request.depth + 1} exceeds the WASI toolbox limit of ${MAX_SPAWN_DEPTH}`,
    )
  }
  let cwd: string | undefined
  if (request.cwd !== undefined && request.cwd !== '/') {
    // `/` is the interpreter's own start directory, not an unmapped path: a
    // parent that runs there gives the child no cwd at all (it also starts in
    // `/`), while an explicit path outside every preopen is a real refusal.
    cwd = resolveGuestCwd(context.preopens, request.cwd)
    if (cwd === undefined) {
      throw new SpawnBridgeError('cwd', `subprocess cwd ${request.cwd} is outside the preopened directories`)
    }
    const host = resolveGuestPath(context.preopens, undefined, cwd)
    let kind: string
    try {
      kind = context.vfs.stat(host.hostPath).kind
    } catch (error) {
      throw new SpawnBridgeError(
        'cwd',
        `subprocess cwd ${request.cwd} does not exist in the Worker VFS: ${error instanceof Error ? error.message : String(error)}`,
      )
    }
    if (kind !== 'directory') {
      throw new SpawnBridgeError('cwd', `subprocess cwd ${request.cwd} is not a directory`)
    }
  }
  const env: Record<string, string> = { ...request.env }
  if (cwd !== undefined) env.PWD = cwd
  else if (env.PWD === undefined && context.defaultCwd !== undefined) env.PWD = context.defaultCwd
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  let capturedBytes = 0
  let outputLimitExceeded = false
  const capture = (chunks: Uint8Array[]) => (chunk: Uint8Array): void => {
    // Once tripped, every later write traps again. A host-side writer that
    // swallows the first trap (the WASI layer's best-effort errno message to
    // stderr) must not let the child keep running with its output dropped.
    if (outputLimitExceeded || capturedBytes + chunk.byteLength > MAX_SPAWN_STDIO_BYTES) {
      outputLimitExceeded = true
      // HotInstance invokes this callback inside WASI fd_write. Throwing unwinds
      // the synchronous nested _start immediately.
      throw new WasiTrapError('nested subprocess output limit exceeded')
    }
    chunks.push(chunk.slice())
    capturedBytes += chunk.byteLength
  }
  let result: HotRunResult | undefined
  try {
    result = context.pool.acquire(context.program).run({
      argv: request.argv,
      env,
      ...(cwd === undefined ? {} : { cwd }),
      stdin: request.stdin,
      spawnDepth: request.depth + 1,
      onStdout: capture(stdout),
      onStderr: capture(stderr),
    })
  } catch (error) {
    // A trap or memory-ceiling diagnostic written after the budget was spent
    // re-throws from `capture`; the child's terminal state is the limit.
    if (!outputLimitExceeded) throw error
  }
  if (outputLimitExceeded || result === undefined) {
    throw new SpawnBridgeError(
      'output-limit',
      `the nested command exceeded the shared stdout/stderr limit of ${MAX_SPAWN_STDIO_BYTES} bytes`,
    )
  }
  return {
    exitCode: result.exitCode,
    stdout: concatBytes(stdout),
    stderr: concatBytes(stderr),
  }
}

function concatBytes(chunks: readonly Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
  const joined = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    joined.set(chunk, offset)
    offset += chunk.byteLength
  }
  return joined
}

/**
 * Probe the proxy preopens with one batched async `stat`; the stdlib mount is
 * local to this worker and always reported as present.
 */
function probePreopens(state: PythonWorkerState, post: (message: unknown) => void): void {
  void state.asyncClient
    .batchSettled(state.proxyPreopens.map(preopen => ({ op: 'stat' as const, path: preopen.hostPath })))
    .then(results => {
      const present: string[] = []
      const missing: string[] = []
      results.forEach((result, index) => {
        const preopen = state.proxyPreopens[index]
        if (preopen === undefined) return
        if (result.value?.kind === 'stat') present.push(preopen.guestPath)
        else missing.push(preopen.guestPath)
      })
      present.push(dirname(state.stdlib.guestPath))
      post({ type: 'preopens', program: state.program, present, missing })
    })
    .catch((error: unknown) => {
      post({
        type: 'preopens',
        program: state.program,
        present: [dirname(state.stdlib.guestPath)],
        missing: state.proxyPreopens.map(preopen => preopen.guestPath),
        error: error instanceof Error ? error.message : String(error),
      })
    })
}

async function execute(state: PythonWorkerState, message: WorkerMessage, post: (message: unknown) => void): Promise<void> {
  let stdin: Uint8Array
  try {
    stdin = message.stdin ?? state.stdin.take(message.id as number)
  } catch (error) {
    // A truncated delivery must not reach CPython as an empty script: report
    // the structured failure so the host watchdog settles the dispatch.
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
  // Keep the shim directory first, then the stdlib zip and the cwd shim, so
  // `import subprocess` resolves the bridge module and the startup chdir still
  // happens even when the caller exported its own PYTHONPATH.
  const env = withPythonShims(message.env, {
    stdlibZip: state.stdlib.guestPath,
    cwdShimDir: pythonCwdShimGuestDir(state.stdlib.guestPath),
  })
  // The inbox has the complete stdin feed now; CPython will report its first
  // fd_read(0) below. The host treats that read as proof the script is being
  // consumed rather than a wedged dispatch.
  post({ type: 'exec-started', id: message.id, stdinBytes: stdin.byteLength })
  let readReported = false
  const result = state.pool.acquire(state.program).run({
    ...(message.argv === undefined ? {} : { argv: message.argv }),
    env,
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
  // A snapshot view is local, so its queued mutations must reach the live VFS
  // before the next step (a bash read, the WAL sink) can observe the command.
  if (state.view !== undefined) {
    try {
      await state.view.flushWrites()
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error)
      post({ type: 'stderr', id: message.id, chunk: new TextEncoder().encode(`python3: ${detail}\n`) })
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
    python: snapshotMetrics(state),
  })
}

/**
 * Compose the writable proxy with the in-worker read-only stdlib layer. The
 * layer owns exactly the zip file; every other path falls through to the proxy.
 * Exported so tests can prove a zip read is served without a proxy call.
 */
export function createPythonVfs(options: {
  readonly writable: WasiVfs
  readonly stdlib: PythonStdlibMount
  readonly metrics?: PythonWorkerCounters
}): PythonVfsBundle {
  const stdlib = options.stdlib
  const metrics = options.metrics ?? { proxyCalls: 0, proxyStdlibReads: 0 }
  const root = stdlib.hostRoot.replace(/\/+$/, '')
  const zipHostPath = `${root}/${lastSegment(stdlib.guestPath)}`
  const cwdShimHostPath = `${root}/${PYTHON_CWD_SHIM_DIR_NAME}/${PYTHON_CWD_SHIM_FILENAME}`
  const counted = new CountingWasiVfs(options.writable, zipHostPath, metrics)
  // The startup shim lives in the same in-worker read-only layer as the zip,
  // so importing it never reaches (or allocates through) the VFS proxy.
  const layer = new ReadOnlyMemoryVfs(
    [
      { path: zipHostPath, data: stdlib.stdlibZip, mode: 0o444 },
      { path: cwdShimHostPath, data: new TextEncoder().encode(PYTHON_CWD_SHIM_SOURCE), mode: 0o444 },
    ],
    { root: stdlib.hostRoot },
  )
  // The subprocess shim is a second read-only layer with its own root: it must
  // precede the stdlib zip on PYTHONPATH to shadow `subprocess`, and keeping it
  // out of the stdlib tree means the mounted library listing stays exactly
  // "python-cwd, python313.zip".
  const shimLayer = new ReadOnlyMemoryVfs(
    pythonShimFiles().map(file => ({
      path: file.path,
      data: new TextEncoder().encode(file.source),
      mode: 0o444,
    })),
    { root: PYTHON_SHIM_ROOT },
  )
  return {
    vfs: new OverlayWasiVfs({ layers: [layer, shimLayer], writable: counted }),
    preopen: { guestPath: dirname(stdlib.guestPath), hostPath: stdlib.hostRoot },
    zipHostPath,
    cwdShimHostPath,
    cwdShimGuestDir: pythonCwdShimGuestDir(stdlib.guestPath),
    subprocessPreopen: { guestPath: PYTHON_SHIM_ROOT, hostPath: PYTHON_SHIM_ROOT },
    spawnPreopen: { guestPath: PDSH_SPAWN_GUEST_ROOT, hostPath: PDSH_SPAWN_HOST_ROOT },
    metrics,
  }
}

function snapshotMetrics(state: PythonWorkerState): PythonWorkerMetrics {
  return {
    proxyCalls: state.metrics.proxyCalls,
    proxyStdlibReads: state.metrics.proxyStdlibReads,
    stdlibBytes: state.stdlib.stdlibZip.byteLength,
  }
}

/**
 * Delegate to the writable proxy while counting calls. A call for the stdlib
 * zip path means the read-only layer was bypassed; the host benchmark asserts
 * that counter stays zero for `import json, re, pathlib`.
 */
class CountingWasiVfs implements WasiVfs {
  private readonly inner: WasiVfs
  private readonly stdlibZipPath: string
  private readonly metrics: PythonWorkerCounters

  constructor(inner: WasiVfs, stdlibZipPath: string, metrics: PythonWorkerCounters) {
    this.inner = inner
    this.stdlibZipPath = stdlibZipPath
    this.metrics = metrics
  }

  stat(path: string): VfsStat {
    this.count(path)
    return this.inner.stat(path)
  }

  readdir(path: string): readonly VfsDirEntry[] {
    this.count(path)
    return this.inner.readdir(path)
  }

  open(path: string, options: VfsOpenOptions): VfsStat {
    this.count(path)
    return this.inner.open(path, options)
  }

  read(path: string, offset: number, length: number): Uint8Array {
    this.count(path)
    return this.inner.read(path, offset, length)
  }

  write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { readonly append: boolean; readonly create: boolean; readonly mode?: number },
  ): number {
    this.count(path)
    return this.inner.write(path, offset, data, options)
  }

  truncate(path: string, length: number): void {
    this.count(path)
    this.inner.truncate(path, length)
  }

  mkdir(path: string, mode?: number): void {
    this.count(path)
    this.inner.mkdir(path, mode)
  }

  unlink(path: string, options: { readonly directory: boolean }): void {
    this.count(path)
    this.inner.unlink(path, options)
  }

  rmdir(path: string): void {
    this.count(path)
    const rmdir = this.inner.rmdir
    if (typeof rmdir === 'function') rmdir.call(this.inner, path)
    else this.inner.unlink(path, { directory: true })
  }

  rename(from: string, to: string): void {
    this.count(from)
    this.count(to)
    this.inner.rename(from, to)
  }

  sync(): void {
    this.inner.sync()
  }

  private count(path: string): void {
    this.metrics.proxyCalls += 1
    if (path === this.stdlibZipPath) this.metrics.proxyStdlibReads += 1
  }
}

function lastSegment(path: string): string {
  const index = path.lastIndexOf('/')
  return index < 0 ? path : path.slice(index + 1)
}

function dirname(path: string): string {
  const normalized = path.replace(/\/+$/, '')
  const index = normalized.lastIndexOf('/')
  return index <= 0 ? '/' : normalized.slice(0, index)
}
