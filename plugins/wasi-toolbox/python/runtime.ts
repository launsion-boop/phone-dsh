// SPDX-License-Identifier: MIT
/**
 * CPython-on-WASI package for the DSH phone Web Worker.
 *
 * `PythonRuntime` registers `python3` in the W7 toolbox command table and runs
 * a real `python.wasm` (CPython's own wasm32-wasi build) in a dedicated tool
 * worker. The standard library is a `python313.zip` that the host passes once
 * at init; the tool worker mounts it in a read-only in-memory layer and sets
 * `PYTHONHOME`/`PYTHONPATH`, so `import json, re, pathlib` is served by
 * `zipimport` from worker memory and never issues a VFS proxy request. The
 * workspace and home preopens keep using the synchronous proxy, so a Python
 * `open(..., "w")` is an ordinary DSH write.
 *
 * The same read-only layer carries a `subprocess` shadow module and its bridge
 * implementation (`subprocess-shim.ts`), so Python code that shells out runs a
 * fresh nested interpreter instance on the same tool worker and VFS instead of
 * dying on WASI's missing process model. Programs outside the toolbox command
 * table fail loud at `Popen` construction.
 *
 * The same class measures cold start (worker spawn + module compile + CPython
 * init), warm start (a fresh interpreter instance in the warm worker) and a
 * 1 MiB JSON benchmark (document on stdin, `json.loads` in Python). The real
 * benchmark runs only when the caller or the test suite supplies built bytes;
 * unit tests inject the tiny stdio stub in `testdata/`.
 * @module @phone-dsh/dsh-wasi-toolbox/python/runtime
 */
import { WasiToolboxError } from '../src/errors.ts'
import type { LoopbackHttpRoute } from '../src/http-bridge.ts'
import { DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PREOPENS, WORKER_DEFAULT_CWD } from '../src/limits.ts'
import { workerTransport } from '../src/message-endpoint.ts'
import type { ToolWorkerTransport } from '../src/message-endpoint.ts'
import { WasiToolbox, setWorkerToolbox } from '../src/toolbox.ts'
import type { GuestPreopen, ToolboxModuleSource, ToolboxResult, ToolboxRunRequest, VfsBackend } from '../src/types.ts'
import { joinPosixPath, resolveGuestCwd } from '../src/vfs-paths.ts'
import { pythonCwdShimGuestDir } from './cwd-shim.ts'
import { withPythonShims } from './subprocess-shim.ts'
import type { PythonWorkerInitMessage, PythonWorkerMetrics } from './python-worker-runtime.ts'

/** Guest path of the zipped standard library. */
export const PYTHON_STDLIB_GUEST_PATH = '/usr/local/lib/python313.zip'
/** Guest prefix CPython reports (`PYTHONHOME`). */
export const PYTHON_HOME = '/usr/local'
/** Host path of the read-only layer inside the tool worker. */
export const PYTHON_STDLIB_HOST_ROOT = '/python-stdlib'
/** Module cache identity of the default `python.wasm` source. */
export const PYTHON_WASM_URL = 'image://python.wasm'

const PYTHON_VERSION_PROGRAM = 'import sys; print(sys.version.split()[0])'
const IMPORT_PROGRAM = 'import json, re, pathlib'
const JSON_PROGRAM = 'import json, sys; json.loads(sys.stdin.buffer.read())'
const PASS_PROGRAM = 'pass'

/** The modules the acceptance benchmark imports from the zipped stdlib. */
export const PYTHON_BENCHMARK_IMPORTS = ['json', 're', 'pathlib'] as const

/** Lazy byte source of one artifact. */
export interface PythonArtifact {
  /** Stable identity for diagnostics; defaults to the file kind. */
  readonly url?: string
  load(): Promise<Uint8Array>
}

/** Construction inputs of {@link PythonRuntime}. */
export interface PythonRuntimeOptions {
  /** The DSH worker's `node:fs` face; its sink mirrors writes to the WAL. */
  readonly backend: VfsBackend
  /** `python.wasm` bytes or a loader. */
  readonly wasm: Uint8Array | PythonArtifact
  /** `python313.zip` bytes or a loader (mounted read-only in the tool worker). */
  readonly stdlib: Uint8Array | PythonArtifact
  /**
   * Guest roots the interpreter sees; defaults to the namespace's identity
   * roots (`/dsh/workspace`, `/dsh/home`, `/tmp`, `/dsh/tmp`). `/tmp` and
   * `/dsh/tmp` are two spellings of one volatile store; the namespace
   * canonicalises both before the VFS sees them (G2-D05).
   */
  readonly preopens?: readonly GuestPreopen[]
  /** Extra environment for every Python process. */
  readonly env?: Readonly<Record<string, string>>
  /** Default guest cwd; the shell's dispatch cwd/PWD overrides it per run. */
  readonly cwd?: string
  readonly memoryLimitBytes?: number
  /** Override the automatic `crossOriginIsolated` detection (tests). */
  readonly crossOriginIsolated?: boolean
  /** Factory for the dedicated tool worker; defaults to `new Worker(workerUrl)`. */
  readonly spawnWorker?: (command: { readonly program: string }) => ToolWorkerTransport
  /** URL of the built python tool worker; defaults to `./tool-worker-python.js`. */
  readonly workerUrl?: URL | string
  readonly workerReadyTimeoutMs?: number
  readonly stdlibGuestPath?: string
  readonly stdlibHostRoot?: string
  /**
   * Loopback `/v1/http` coordinates. When present, every tool worker init gets
   * this route, the guest environment is marked `PDSH_PYTHON_HTTP=1` so the
   * sitecustomize shim installs the urllib/http.client bridge, and the bearer
   * stays out of the guest environment.
   */
  readonly http?: LoopbackHttpRoute | undefined
}

/** One benchmark invocation profile. */
export interface PythonBenchmarkOptions {
  /** Size of the JSON document fed on stdin; defaults to 1 MiB. */
  readonly jsonBytes?: number
  /** Repetitions for the warm/import/JSON measurements; defaults to 3. */
  readonly runs?: number
}

/** Result of {@link PythonRuntime.benchmark}. */
export interface PythonBenchmarkReport {
  /** `sys.version` major.minor.patch parsed from the cold run, when present. */
  readonly pythonVersion?: string
  /** First run: worker spawn + wasm compile + CPython initialisation + `pass`. */
  readonly coldStartMs: number
  /** Median of the warm `pass` runs (fresh interpreter in the warm worker). */
  readonly warmStartMs: number
  /** Every warm `pass` measurement, in order. */
  readonly warmStartRunsMs: readonly number[]
  /** Median of `import json, re, pathlib`. */
  readonly importMs: number
  /** Every import measurement, in order. */
  readonly importRunsMs: readonly number[]
  /** Modules the import run requested. */
  readonly importedModules: readonly string[]
  /** Bytes of the JSON document written to stdin. */
  readonly jsonBytes: number
  /** Median wall time of the 1 MiB `json.loads` runs. */
  readonly jsonParseMs: number
  /** Every JSON measurement, in order. */
  readonly jsonRunsMs: readonly number[]
  /** Largest linear-memory size observed after an interpreter run. */
  readonly peakMemoryBytes: number
  /** Ceiling configured for the hot instance. */
  readonly memoryLimitBytes: number
  /** VFS proxy requests for the stdlib zip; must stay 0 for a real build. */
  readonly stdlibProxyReads: number
  /** All VFS proxy requests during the benchmark. */
  readonly proxyCalls: number
}

/** Runtime diagnostics for the phone status screen and tests. */
export interface PythonRuntimeDiagnostics {
  readonly programs: readonly string[]
  readonly hotInstances: number
  readonly stdlibBytes?: number
  readonly stdlibProxyReads: number
  readonly proxyCalls: number
}

interface CapturedRun {
  readonly result: ToolboxResult
  readonly stdout: Uint8Array
  readonly stderr: Uint8Array
}

/** `python3` on the WASI toolbox, backed by CPython's wasm32-wasi build. */
export class PythonRuntime {
  readonly toolbox: WasiToolbox
  readonly memoryLimitBytes: number
  private readonly transports: PythonTransport[] = []
  private readonly stdlibGuestPath: string
  private readonly stdlibHostRoot: string
  private readonly preopens: readonly GuestPreopen[]
  private readonly defaultCwd: string

  constructor(options: PythonRuntimeOptions) {
    this.stdlibGuestPath = options.stdlibGuestPath ?? PYTHON_STDLIB_GUEST_PATH
    this.stdlibHostRoot = options.stdlibHostRoot ?? PYTHON_STDLIB_HOST_ROOT
    this.memoryLimitBytes = options.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES
    this.preopens = options.preopens ?? DEFAULT_PREOPENS
    this.defaultCwd = options.cwd ?? WORKER_DEFAULT_CWD
    const cwdShimGuestDir = pythonCwdShimGuestDir(this.stdlibGuestPath)
    const env = withPythonShims({
      PYTHONHOME: PYTHON_HOME,
      PYTHONDONTWRITEBYTECODE: '1',
      PYTHONNOUSERSITE: '1',
      ...(options.env ?? {}),
      // Forced after the caller's environment: the flag must describe the
      // route this runtime actually injected, never a stale caller value.
      ...(options.http === undefined ? {} : { PDSH_PYTHON_HTTP: '1' }),
    }, {
      // The shim directory comes first so `import subprocess` finds the
      // bridge-backed module rather than the stdlib one; the zip and the cwd
      // shim follow, and a caller's entries are kept after the runtime's.
      stdlibZip: this.stdlibGuestPath,
      cwdShimDir: cwdShimGuestDir,
    })
    const command = {
      program: 'python3',
      // The shell already serves `python` as an alias of `python3`; declaring
      // it on the command makes the toolbox table the single place the
      // interpreter's names live, and the nested subprocess shim resolves
      // argv[0] against this same list.
      aliases: ['python'],
      module: moduleSource(options.wasm),
      cwd: this.defaultCwd,
      env,
      mapArgv: (argv: readonly string[], context: { readonly cwd?: string }): readonly string[] =>
        context.cwd === undefined ? argv : rewritePythonScriptArgument(argv, context.cwd, this.preopens),
      // `python3 -` (a heredoc script) and a bare `python3` read the program
      // from stdin. The toolbox watches that first fd_read so a dispatch that
      // never receives its script fails fast instead of stalling the lane.
      scriptFromStdin: pythonReadsScriptFromStdin,
      description: 'CPython 3.13 on wasm32-wasi with the standard library in worker memory',
    }
    this.toolbox = new WasiToolbox({
      commands: [command],
      backend: options.backend,
      preopens: this.preopens,
      // CPython's file view is the product surface: a rebuilt Worker without a
      // SharedArrayBuffer channel must still see the shell's tree, not an empty
      // `/` (G2-FIX-54).
      snapshotFallback: true,
      // The persisted roots D4 mirrors: a python3 that cannot see these has no
      // usable file view, whatever the volatile tmp mount does.
      requiredPreopens: [WORKER_DEFAULT_CWD, '/dsh/home'],
      ...(options.memoryLimitBytes === undefined ? {} : { memoryLimitBytes: options.memoryLimitBytes }),
      ...(options.crossOriginIsolated === undefined ? {} : { crossOriginIsolated: options.crossOriginIsolated }),
      ...(options.workerReadyTimeoutMs === undefined ? {} : { workerReadyTimeoutMs: options.workerReadyTimeoutMs }),
      spawnWorker: (spawned): ToolWorkerTransport => {
        const transport = options.spawnWorker?.(spawned) ?? defaultSpawnWorker(
          options.workerUrl ?? new URL('./tool-worker-python.js', import.meta.url),
        )
        const wrapped = new PythonTransport(transport, artifactLoader(options.stdlib), {
          guestPath: this.stdlibGuestPath,
          hostRoot: this.stdlibHostRoot,
          program: spawned.program,
          ...(options.http === undefined ? {} : { http: options.http }),
        })
        this.transports.push(wrapped)
        return wrapped
      },
    })
  }

  /** True once `python3` is in the toolbox command table. */
  hasPython3(): boolean {
    return this.toolbox.has('python3')
  }

  /** Run one command through the toolbox command table. */
  run(request: ToolboxRunRequest): Promise<ToolboxResult> {
    return this.toolbox.run(request)
  }

  /**
   * Publish this runtime's toolbox so the Worker shell serves `python3`.
   *
   * Call once at Worker boot. `createWorkerCommands()` (and therefore
   * `subprocess-xl`'s `bash -c`) registers one shell command per toolbox
   * program, so `python3` reaches this runtime through the same
   * `toolbox.run()` dispatch as a direct `WasiToolbox` call — there is no
   * second Python code path in the shell.
   * @returns the published toolbox.
   */
  installShellDispatch(): WasiToolbox {
    setWorkerToolbox(this.toolbox)
    return this.toolbox
  }

  /**
   * Measure cold start, warm start, the stdlib imports and a JSON parse.
   * Every command goes through the real toolbox route, so the numbers include
   * worker messaging and the WASI host, not just the interpreter.
   */
  async benchmark(options: PythonBenchmarkOptions = {}): Promise<PythonBenchmarkReport> {
    const runs = Math.max(1, Math.trunc(options.runs ?? 3))
    const jsonBytes = Math.max(2, Math.trunc(options.jsonBytes ?? 1024 * 1024))
    const document = jsonDocument(jsonBytes)

    const cold = await this.capture(['-c', PYTHON_VERSION_PROGRAM])
    const coldStartMs = cold.elapsedMs
    const pythonVersion = parsePythonVersion(decoder.decode(cold.stdout))
    let peakMemoryBytes = cold.result.memoryPeakBytes

    const warmStartRunsMs: number[] = []
    for (let index = 0; index < runs; index += 1) {
      const run = await this.capture(['-c', PASS_PROGRAM])
      warmStartRunsMs.push(run.elapsedMs)
      peakMemoryBytes = Math.max(peakMemoryBytes, run.result.memoryPeakBytes)
    }

    const importRunsMs: number[] = []
    for (let index = 0; index < runs; index += 1) {
      const run = await this.capture(['-c', IMPORT_PROGRAM])
      importRunsMs.push(run.elapsedMs)
      peakMemoryBytes = Math.max(peakMemoryBytes, run.result.memoryPeakBytes)
    }

    const jsonRunsMs: number[] = []
    for (let index = 0; index < runs; index += 1) {
      const run = await this.capture(['-c', JSON_PROGRAM], document)
      jsonRunsMs.push(run.elapsedMs)
      peakMemoryBytes = Math.max(peakMemoryBytes, run.result.memoryPeakBytes)
    }

    const diagnostics = this.diagnostics()
    return {
      ...(pythonVersion === undefined ? {} : { pythonVersion }),
      coldStartMs,
      warmStartMs: median(warmStartRunsMs),
      warmStartRunsMs,
      importMs: median(importRunsMs),
      importRunsMs,
      importedModules: [...PYTHON_BENCHMARK_IMPORTS],
      jsonBytes,
      jsonParseMs: median(jsonRunsMs),
      jsonRunsMs,
      peakMemoryBytes,
      memoryLimitBytes: this.memoryLimitBytes,
      stdlibProxyReads: diagnostics.stdlibProxyReads,
      proxyCalls: diagnostics.proxyCalls,
    }
  }

  /** Diagnostics aggregated over the python workers this runtime spawned. */
  diagnostics(): PythonRuntimeDiagnostics {
    let stdlibBytes: number | undefined
    let stdlibProxyReads = 0
    let proxyCalls = 0
    for (const transport of this.transports) {
      const stats = transport.stats()
      if (stats.stdlibBytes !== undefined) stdlibBytes = stats.stdlibBytes
      stdlibProxyReads += stats.stdlibProxyReads
      proxyCalls += stats.proxyCalls
    }
    return {
      programs: this.toolbox.list().map(entry => entry.program),
      hotInstances: this.toolbox.stats().hotInstances,
      ...(stdlibBytes === undefined ? {} : { stdlibBytes }),
      stdlibProxyReads,
      proxyCalls,
    }
  }

  /** Terminate the warm worker and release the command table. */
  async dispose(): Promise<void> {
    await this.toolbox.dispose()
    this.transports.length = 0
  }

  private async capture(args: readonly string[], stdin?: Uint8Array): Promise<CapturedRun & { elapsedMs: number }> {
    const stdout: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const started = performance.now()
    const result = await this.toolbox.run({
      program: 'python3',
      argv: args,
      ...(stdin === undefined ? {} : { stdin }),
      onStdout: chunk => { stdout.push(chunk) },
      onStderr: chunk => { stderr.push(chunk) },
    })
    const elapsedMs = performance.now() - started
    if (result.exitCode !== 0) {
      const detail = decoder.decode(concat(stderr)).trim()
      throw new WasiToolboxError(
        `python3 ${args.join(' ')} exited ${result.exitCode}${detail === '' ? '' : `: ${detail}`}`,
      )
    }
    return { result, stdout: concat(stdout), stderr: concat(stderr), elapsedMs }
  }
}

interface PythonTransportConfig {
  readonly guestPath: string
  readonly hostRoot: string
  readonly program: string
  readonly http?: LoopbackHttpRoute | undefined
}

interface PythonTransportStats {
  readonly stdlibBytes?: number
  readonly proxyCalls: number
  readonly stdlibProxyReads: number
  readonly ready: boolean
}

class PythonTransport implements ToolWorkerTransport {
  private readonly inner: ToolWorkerTransport
  private readonly config: PythonTransportConfig
  private readonly listeners = new Set<(message: unknown) => void>()
  private readonly disposeInner: () => void
  private stdlib?: Promise<Uint8Array>
  private queued: unknown[] = []
  private initialized = false
  private initStarted = false
  private ready = false
  private metrics: PythonWorkerMetrics = { proxyCalls: 0, proxyStdlibReads: 0, stdlibBytes: 0 }

  constructor(inner: ToolWorkerTransport, stdlib: () => Promise<Uint8Array>, config: PythonTransportConfig) {
    this.inner = inner
    this.config = config
    this.disposeInner = inner.onMessage(message => { this.receive(message) })
    // Start loading as soon as the transport exists so byte loading overlaps
    // the module compile the toolbox performs before posting `init`.
    this.stdlib = stdlib()
    void this.stdlib.catch(() => {})
  }

  postMessage(message: unknown): void {
    if (isInitMessage(message)) {
      if (this.initStarted) return
      this.initStarted = true
      void this.sendInit(message)
      return
    }
    if (!this.initialized) {
      this.queued.push(message)
      return
    }
    this.inner.postMessage(message)
  }

  onMessage(handler: (message: unknown) => void): () => void {
    this.listeners.add(handler)
    return () => { this.listeners.delete(handler) }
  }

  onError(handler: (error: Error) => void): () => void {
    return this.inner.onError?.(handler) ?? (() => {})
  }

  terminate(): void | Promise<void> {
    this.disposeInner()
    this.listeners.clear()
    return this.inner.terminate()
  }

  stats(): PythonTransportStats {
    return {
      ...(this.metrics.stdlibBytes > 0 ? { stdlibBytes: this.metrics.stdlibBytes } : {}),
      proxyCalls: this.metrics.proxyCalls,
      stdlibProxyReads: this.metrics.proxyStdlibReads,
      ready: this.ready,
    }
  }

  private async sendInit(message: PythonWorkerInitMessage): Promise<void> {
    try {
      const pending = this.stdlib
      if (pending === undefined) throw new WasiToolboxError('the standard library bytes were already consumed')
      const stdlibZip = await pending
      // The bytes are copied into the worker by postMessage; drop the host
      // reference so a 10 MiB stdlib is not retained twice for the life of the
      // DSH worker.
      this.stdlib = undefined
      const init: PythonWorkerInitMessage = {
        ...message,
        python: {
          stdlibZip,
          guestPath: this.config.guestPath,
          hostRoot: this.config.hostRoot,
        },
        ...(this.config.http === undefined ? {} : { http: { ...this.config.http } }),
      }
      this.inner.postMessage(init)
      this.initialized = true
      const queued = this.queued
      this.queued = []
      for (const item of queued) this.inner.postMessage(item)
    } catch (error) {
      this.inner.postMessage({
        type: 'init-error',
        program: this.config.program,
        message: error instanceof Error ? error.message : String(error),
      })
    }
  }

  private receive(message: unknown): void {
    this.observe(message)
    for (const listener of [...this.listeners]) listener(message)
  }

  private observe(message: unknown): void {
    if (typeof message !== 'object' || message === null) return
    const record = message as {
      readonly type?: unknown
      readonly python?: Partial<PythonWorkerMetrics>
    }
    if (record.type === 'ready') {
      this.ready = true
      if (typeof record.python?.stdlibBytes === 'number') {
        this.metrics = { ...this.metrics, stdlibBytes: record.python.stdlibBytes }
      }
      return
    }
    if (record.python === undefined) return
    if (record.type === 'exit' || record.type === 'pong') {
      this.metrics = {
        proxyCalls: numberOr(record.python.proxyCalls, this.metrics.proxyCalls),
        proxyStdlibReads: numberOr(record.python.proxyStdlibReads, this.metrics.proxyStdlibReads),
        stdlibBytes: numberOr(record.python.stdlibBytes, this.metrics.stdlibBytes),
      }
    }
  }
}

function numberOr(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function moduleSource(wasm: Uint8Array | PythonArtifact): ToolboxModuleSource {
  if (wasm instanceof Uint8Array) {
    const bytes = wasm
    return { url: `${PYTHON_WASM_URL}:memory`, load: async () => bytes }
  }
  return { url: wasm.url ?? PYTHON_WASM_URL, load: () => wasm.load() }
}

function artifactLoader(artifact: Uint8Array | PythonArtifact): () => Promise<Uint8Array> {
  if (artifact instanceof Uint8Array) {
    const bytes = artifact
    return async () => bytes
  }
  return () => artifact.load()
}

function defaultSpawnWorker(url: URL | string): ToolWorkerTransport {
  const WorkerCtor = (globalThis as { Worker?: typeof Worker }).Worker
  if (WorkerCtor === undefined) {
    throw new WasiToolboxError('no Worker constructor in this host; pass spawnWorker to PythonRuntime')
  }
  const worker = new WorkerCtor(url, { type: 'module' })
  return workerTransport(worker)
}

function isInitMessage(message: unknown): message is PythonWorkerInitMessage {
  return typeof message === 'object' && message !== null
    && (message as { readonly type?: unknown }).type === 'init'
    && (message as { readonly module?: unknown }).module instanceof WebAssembly.Module
}

function parsePythonVersion(stdout: string): string | undefined {
  const match = /\b(3\.\d+\.\d+)\b/.exec(stdout)
  return match?.[1]
}

function jsonDocument(size: number): Uint8Array {
  const rows: string[] = []
  let length = 2 // "[]"
  for (let index = 0; ; index += 1) {
    const row = JSON.stringify({
      id: index,
      name: `row-${index}`,
      active: index % 2 === 0,
      values: [index, index + 1, index + 2, index + 3],
    })
    const addition = row.length + (rows.length === 0 ? 0 : 1)
    if (length + addition > size) break
    rows.push(row)
    length += addition
  }
  let text = `[${rows.join(',')}]`
  if (text.length < size) text += ' '.repeat(size - text.length)
  return new TextEncoder().encode(text)
}

function median(values: readonly number[]): number {
  if (values.length === 0) return 0
  const sorted = [...values].sort((left, right) => left - right)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1
    ? sorted[middle] as number
    : ((sorted[middle - 1] as number) + (sorted[middle] as number)) / 2
}

const decoder = new TextDecoder()

function concat(chunks: readonly Uint8Array[]): Uint8Array {
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
 * Make a relative CPython script operand absolute against the dispatch cwd.
 *
 * CPython resolves its script filename during path configuration, before
 * `site.py` imports the cwd shim and before the chdir lands, so
 * `python3 exports/x.py` would otherwise open `/exports/x.py` and fail with
 * Errno 44. The shell resolves a path against its cwd; doing the same to the
 * operand keeps the script open on the same file `cat` sees. `-c`, `-m` and
 * stdin invocations, absolute paths and paths outside every preopen are left
 * untouched.
 * @param argv - arguments after `python3`.
 * @param cwd - guest cwd resolved for this dispatch.
 * @param preopens - preopen table of the interpreter.
 * @returns the original argv, or a copy with the script operand resolved.
 */
export function rewritePythonScriptArgument(
  argv: readonly string[],
  cwd: string,
  preopens: readonly GuestPreopen[],
): readonly string[] {
  const index = pythonScriptIndex(argv)
  if (index === undefined) return argv
  const script = argv[index] as string
  if (script === '' || script.startsWith('/')) return argv
  let resolved: string
  try {
    resolved = joinPosixPath(cwd, script)
  } catch {
    return argv
  }
  if (resolveGuestCwd(preopens, resolved) === undefined) return argv
  const rewritten = [...argv]
  rewritten[index] = resolved
  return rewritten
}

/**
 * True when a CPython invocation takes its program from standard input.
 *
 * That is `python3 -`, a bare `python3`, an option-only invocation such as
 * `python3 -i`, or `-- -`. The toolbox uses this shape to bound the wait for
 * the interpreter's first `fd_read(0)`: a script delivered on stdin must be
 * consumed at interpreter startup, so the absence of that read is a dispatch
 * failure rather than a long-running program.
 * @param argv - arguments after `python3`.
 * @returns true when CPython reads the script from stdin.
 */
export function pythonReadsScriptFromStdin(argv: readonly string[]): boolean {
  let index = 0
  while (index < argv.length) {
    const argument = argv[index] as string
    if (argument === '-') return true
    if (argument === '--') {
      const next = argv[index + 1]
      return next === undefined || next === '-'
    }
    if (argument === '') return false
    if (!argument.startsWith('-')) return false
    if (argument.startsWith('--')) {
      if (argument === '--check-hash-based-pycs') {
        index += 2
        continue
      }
      if (argument === '--version' || argument === '--help') return false
      index += 1
      continue
    }
    const flags = argument.slice(1)
    let consumesNext = false
    for (let offset = 0; offset < flags.length; offset += 1) {
      const flag = flags[offset] as string
      if (flag === 'c' || flag === 'm' || flag === 'h' || flag === '?' || flag === 'V') return false
      if (flag === 'W' || flag === 'X' || flag === 'Q') {
        if (offset + 1 >= flags.length) consumesNext = true
        break
      }
    }
    index += consumesNext ? 2 : 1
  }
  return true
}

/**
 * Index of CPython's script operand in argv, or undefined when the invocation
 * runs from `-c`, `-m`, stdin or an option that exits before a script.
 *
 * The scan follows the interpreter options that consume a value (`-W`, `-X`,
 * `-Q`, `--check-hash-based-pycs`) and accepts both the separate and attached
 * short forms; `--` ends the option list. A shape the scan does not understand
 * stops it, so this helper never rewrites an argument Python would not treat as
 * the script.
 * @param argv - arguments after `python3`.
 * @returns the index of the script operand, or undefined.
 */
export function pythonScriptIndex(argv: readonly string[]): number | undefined {
  let index = 0
  while (index < argv.length) {
    const argument = argv[index] as string
    if (argument === '') return index
    if (argument === '--') {
      const next = index + 1
      return next < argv.length ? next : undefined
    }
    if (argument === '-') return undefined
    if (!argument.startsWith('-')) return index
    if (argument.startsWith('--')) {
      if (argument === '--check-hash-based-pycs') {
        index += 2
        continue
      }
      index += 1
      continue
    }
    const flags = argument.slice(1)
    let offset = 0
    let consumesNext = false
    let exits = false
    while (offset < flags.length) {
      const flag = flags[offset] as string
      if (flag === 'c' || flag === 'm') return undefined
      if (flag === 'W' || flag === 'X' || flag === 'Q') {
        if (offset + 1 >= flags.length) consumesNext = true
        offset = flags.length
        continue
      }
      if (flag === 'h' || flag === '?' || flag === 'V') {
        exits = true
        break
      }
      offset += 1
    }
    if (exits) return undefined
    index += consumesNext ? 2 : 1
  }
  return undefined
}
