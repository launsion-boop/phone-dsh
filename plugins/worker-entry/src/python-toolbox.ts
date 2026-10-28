// SPDX-License-Identifier: MIT
/**
 * Production wiring of the CPython-on-WASI runtime into the phone Worker.
 *
 * `PythonRuntime` (W7-PYTHON) is a library until something constructs it at
 * boot. This module is that production caller: it reads the two artifacts the
 * image packer staged (`/dsh/bin/python/python.wasm` and
 * `/dsh/bin/python/python313.zip`), builds the runtime over the mounted VFS,
 * and publishes its toolbox with `installShellDispatch()` (which is
 * `setWorkerToolbox()`). `createWorkerCommands()` in
 * `@phone-dsh/dsh-shell-ext` then registers one just-bash command per
 * toolbox program and `subprocess-xl` routes a direct
 * `spawn(['python3', ...])` through the same `toolbox.run()` dispatch — so
 * `python3` has exactly one implementation in the Worker (PLAN D12).
 *
 * The artifact paths are the packer's `bin/python` mount under the image root
 * `/dsh` (`scripts/pack-image.mjs` `PYTHON_IMAGE_MOUNT`). The bytes are read
 * through the mounted VFS — the same `MemoryVfs` the runtime's `node:fs`
 * proxy reads through `storage/active.ts` — so the entry keeps a single
 * filesystem authority and a test can inject an in-memory image.
 *
 * Failure policy:
 *  - neither artifact exists: the image carries no python, log one visible
 *    line and keep booting (the host may legitimately run an image without it);
 *  - exactly one exists, an artifact is empty, or a read fails: the image
 *    declares python but cannot serve it — fail loud so the boot reports
 *    `pdsh-error` instead of letting every step exit 127 later.
 * @module @phone-dsh/dsh-worker-entry/python-toolbox
 */
// Relative imports, like the entry's channel imports: worker-entry declares no
// workspace dependencies and is bundled by the page, not staged into the image.
import {
  getWorkerToolbox,
  NodeFsBackend,
  setWorkerToolbox,
  WORKER_DEFAULT_CWD,
  WORKER_VFS_PREOPENS,
} from '../../wasi-toolbox/src/index.ts'
import type {
  GuestPreopen,
  NodeFsPromisesLike,
  ToolWorkerTransport,
  VfsBackend,
  VfsWriteOutcomes,
  WorkerToolbox,
} from '../../wasi-toolbox/src/index.ts'
import type { LoopbackHttpRoute } from '../../wasi-toolbox/src/http-bridge.ts'
import { PythonRuntime } from '../../wasi-toolbox/python/runtime.ts'
import type { HostVfsPromises, WorkerEntryVfs } from './entry.ts'

/** Image-relative directory the packer stages the CPython artifacts under. */
export const PYTHON_IMAGE_MOUNT = 'bin/python'
/** Absolute image (VFS) directory of the CPython artifacts. */
export const PYTHON_IMAGE_DIRECTORY = `/dsh/${PYTHON_IMAGE_MOUNT}`
/** Mounted path of the CPython wasm32-wasi interpreter. */
export const PYTHON_WASM_IMAGE_PATH = `${PYTHON_IMAGE_DIRECTORY}/python.wasm`
/** Mounted path of the zipped standard library. */
export const PYTHON_STDLIB_IMAGE_PATH = `${PYTHON_IMAGE_DIRECTORY}/python313.zip`
/** File the packer's build-time probe stages beside the artifact pair. */
export const PYTHON_MODULES_FILENAME = 'modules.json'
/** Mounted path of the build-time importable-module probe output. */
export const PYTHON_MODULES_IMAGE_PATH = `${PYTHON_IMAGE_DIRECTORY}/${PYTHON_MODULES_FILENAME}`

/**
 * The real interpreter probe's answer, from `build.sh`'s `compression.json`
 * as staged into `modules.json`. `modules` lists the compression modules the
 * probe imported and roundtripped; `tarfileGzip` says the probe wrote and read
 * a real archive. This is the only source of the compression capability: the
 * stdlib ZIP's `zlib.py` entry proves the wrapper is packed, not that the
 * native extension is linked into the interpreter.
 */
export interface PythonCompressionProbe {
  readonly modules: readonly string[]
  readonly tarfileGzip: boolean
  /** zlib runtime version the probe printed, when the build reported one. */
  readonly zlibRuntime?: string
}

/** The build-time probe's answer: interpreter version, importable modules and compression. */
export interface PythonModuleProbe {
  readonly version?: string
  readonly modules: readonly string[]
  readonly compression?: PythonCompressionProbe
}

/**
 * Guest preopens: the exact roots the Worker shell serves, mounted under the
 * same `/dsh/*` names (PLAN D4/D15). Guest path == host VFS path, so
 * `python3` and `ls`/`cat`/`awk` read and write the same files through the
 * same names: a relative `open()` resolved from the bash workdir and an
 * absolute `/dsh/workspace/…` both land on the shell's file.
 *
 * There is deliberately no `/workspace`, `/home` or `/tmp` *mount*: those
 * POSIX spellings are translated into this namespace before dispatch (the
 * toolbox resolves PWD/cwd through `workerNamespacePath`), which keeps one
 * preopen root per file instead of two aliases over the same tree.
 */
export const PYTHON_PREOPENS: readonly GuestPreopen[] = WORKER_VFS_PREOPENS

/** Guest cwd a bare `python3` starts in (`PYTHON_PREOPENS[0]`). */
export const PYTHON_DEFAULT_CWD = WORKER_DEFAULT_CWD

/** The build command the loud failures point at. */
export const PYTHON_BUILD_COMMAND = 'bash plugins/wasi-toolbox/python/build.sh --out <dir>'

/** Inputs for {@link installPythonToolbox}. */
export interface PythonToolboxOptions {
  /** Mounted VFS: source of the artifact bytes and the flush sink. */
  readonly vfs: WorkerEntryVfs
  /**
   * VFS proxy backend for the tool worker. Defaults to the Worker's
   * `node:fs/promises` proxy, so a Python write is an ordinary DSH write.
   */
  readonly backend?: VfsBackend
  /** Injected `node:fs/promises` face (tests); used when `backend` is absent. */
  readonly fsPromises?: NodeFsPromisesLike
  /**
   * Ordered-channel write-outcome tracker shared with the Worker sink. When
   * present, a `python3` write answers the guest only after the host
   * acknowledged it (or refused it), so a resource refusal becomes a WASI errno
   * and a stalled flow-control window fails loud (G2-FIX-103).
   */
  readonly writeOutcomes?: VfsWriteOutcomes
  /** Tool worker factory; defaults to `new Worker(./tool-worker-python.js)`. */
  readonly spawnWorker?: (command: { readonly program: string }) => ToolWorkerTransport
  /** URL of the built python tool worker, for deployments that relocate it. */
  readonly workerUrl?: URL | string
  /**
   * Override the automatic `crossOriginIsolated` detection of the synchronous
   * VFS channel. Tests and a host that has already verified isolation use it;
   * production leaves it unset so the toolbox detects the Worker context.
   */
  readonly crossOriginIsolated?: boolean
  /** Visible-line sink; defaults to `console.info` (mirrored as 0x60 CONSOLE). */
  readonly log?: (message: string) => void
  /** Explicit loopback route (tests); defaults to {@link resolvePythonHttpRoute}. */
  readonly http?: LoopbackHttpRoute
  /** Environment the route is read from; defaults to `process.env`. */
  readonly processEnv?: Readonly<Record<string, string | undefined>>
  /**
   * WASI hot-instance ceiling for the python tool workers (budgets.md §4,
   * `wasiHotInstanceBytes`); omitted means the 8 GiB default.
   */
  readonly memoryLimitBytes?: number
}

/** The published runtime and the toolbox the Worker shell dispatches to. */
export interface PythonToolboxWiring {
  readonly runtime: PythonRuntime
  readonly toolbox: WorkerToolbox
}

/**
 * Build and publish `python3` from the image artifacts.
 * @param options - VFS, backend/tool-worker seams and the log sink.
 * @returns The wiring, or undefined when the image carries no python artifacts.
 * @throws {Error} When the image declares python but the artifacts cannot be read.
 */
export async function installPythonToolbox(
  options: PythonToolboxOptions,
): Promise<PythonToolboxWiring | undefined> {
  const log = options.log ?? ((message: string): void => { console.info(message) })
  const reader = options.vfs.readFileSync
  if (typeof reader !== 'function') {
    log(
      'worker entry: this VFS exposes no readFileSync, so the image python3 artifacts cannot be loaded; '
      + 'python3 stays unavailable',
    )
    return undefined
  }
  const wasm = readImageArtifact(options.vfs, reader, PYTHON_WASM_IMAGE_PATH)
  const stdlib = readImageArtifact(options.vfs, reader, PYTHON_STDLIB_IMAGE_PATH)
  if (wasm === undefined && stdlib === undefined) {
    log(
      `worker entry: the image carries no python3 artifacts (looked for ${PYTHON_WASM_IMAGE_PATH} `
      + `and ${PYTHON_STDLIB_IMAGE_PATH}); python3 stays unavailable`,
    )
    return undefined
  }
  if (wasm === undefined || stdlib === undefined) {
    const present = wasm === undefined ? PYTHON_STDLIB_IMAGE_PATH : PYTHON_WASM_IMAGE_PATH
    const missing = wasm === undefined ? PYTHON_WASM_IMAGE_PATH : PYTHON_STDLIB_IMAGE_PATH
    throw new Error(
      `worker entry: the image declares python3 (${present}) but ${missing} is missing; `
      + `rebuild it with ${PYTHON_BUILD_COMMAND} and pass that directory to `
      + `scripts/pack-image.mjs --python <dir>`,
    )
  }
  if (wasm.byteLength === 0 || stdlib.byteLength === 0) {
    throw new Error(
      `worker entry: the image's python3 artifacts are empty (${PYTHON_WASM_IMAGE_PATH}=${wasm.byteLength} B, `
      + `${PYTHON_STDLIB_IMAGE_PATH}=${stdlib.byteLength} B); rebuild them with ${PYTHON_BUILD_COMMAND}`,
    )
  }

  const backend = options.backend ?? new NodeFsBackend(
    // Prefer the host VFS's own promise face: it is pinned to the filesystem
    // object this host mounted, so a toolbox built after a rebuild can never
    // follow the module-global `storage/active.ts` slot to a torn-down VFS
    // (G2-FIX-54).
    options.fsPromises ?? await hostVfsPromises(options.vfs),
    {
      // A guest fsync waits for the DSH VFS sink (the WAL mirror) instead of
      // claiming durability the in-memory filesystem cannot give.
      flush: () => options.vfs.flush(),
      ...options.writeOutcomes === undefined ? {} : { writeOutcomes: options.writeOutcomes },
    },
  )
  const http = options.http ?? resolvePythonHttpRoute(options.processEnv ?? process.env)
  const runtime = new PythonRuntime({
    backend,
    wasm: { url: `image://${PYTHON_WASM_IMAGE_PATH}`, load: async () => wasm },
    stdlib: { url: `image://${PYTHON_STDLIB_IMAGE_PATH}`, load: async () => stdlib },
    preopens: PYTHON_PREOPENS,
    cwd: PYTHON_DEFAULT_CWD,
    ...options.spawnWorker === undefined ? {} : { spawnWorker: options.spawnWorker },
    ...options.workerUrl === undefined ? {} : { workerUrl: options.workerUrl },
    ...options.crossOriginIsolated === undefined ? {} : { crossOriginIsolated: options.crossOriginIsolated },
    ...options.memoryLimitBytes === undefined ? {} : { memoryLimitBytes: options.memoryLimitBytes },
    ...http === undefined ? {} : { http },
  })
  // Verify the guest's file view *before* publishing: a toolbox that cannot
  // resolve the shell's workspace would serve `python3` an empty `/`, and every
  // step would then fail with Errno 44 long after the wiring went wrong. This
  // is the class-level guard for every Worker (re)construction path (G2-FIX-54).
  await runtime.toolbox.assertFileView()
  const toolbox = runtime.installShellDispatch()
  return { runtime, toolbox }
}

/**
 * Release a wiring: unpublish the toolbox and terminate the warm tool worker.
 * Safe to call twice and with `undefined`.
 * @param wiring - result of {@link installPythonToolbox}.
 */
export async function disposePythonToolbox(wiring: PythonToolboxWiring | undefined): Promise<void> {
  if (wiring === undefined) return
  if (getWorkerToolbox() === wiring.toolbox) setWorkerToolbox(undefined)
  await wiring.runtime.dispose()
}

/**
 * The single python toolbox wiring slot of this Worker global scope.
 *
 * Every boot path — cold boot and every rebuild (park/resume, planned restart,
 * Worker kill, WebContent kill) — goes through {@link PythonToolboxLifecycle.bind}.
 * A bind against a different host VFS first disposes the previous wiring, so
 * the published `python3` is always the one bound to the live host and there is
 * never a window where a torn-down toolbox serves a command. One instance is
 * shared per module graph, next to the `globalThis` toolbox slot it publishes.
 */
export class PythonToolboxLifecycle {
  private wiring: PythonToolboxWiring | undefined
  private vfs: WorkerEntryVfs | undefined
  private writeOutcomes: VfsWriteOutcomes | undefined
  private pending: Promise<unknown> | undefined

  /** The currently published wiring, if any. */
  current(): PythonToolboxWiring | undefined {
    return this.wiring
  }

  /** The host VFS the current wiring is bound to, if any. */
  boundTo(): WorkerEntryVfs | undefined {
    return this.vfs
  }

  /**
   * Bind (or re-bind) the toolbox to a host VFS.
   *
   * Re-binding to the same VFS object is a no-op, so a boot that only repeats
   * the wiring does not churn the warm tool worker. Re-binding to a different
   * VFS disposes the stale wiring first: its backend answers for a filesystem
   * the new host does not mount.
   * @param options - VFS and wiring seams.
   * @returns The published wiring, or undefined when the image has no python.
   * @throws {Error} When the VFS cannot serve the python file view.
   */
  async bind(options: PythonToolboxOptions): Promise<PythonToolboxWiring | undefined> {
    if (
      this.wiring !== undefined
      && this.vfs === options.vfs
      && this.writeOutcomes === options.writeOutcomes
    ) return this.wiring
    const previous = this.pending
    const run = (async (): Promise<PythonToolboxWiring | undefined> => {
      await previous?.catch(() => {})
      if (
        this.wiring !== undefined
        && (this.vfs !== options.vfs || this.writeOutcomes !== options.writeOutcomes)
      ) {
        const stale = this.wiring
        this.wiring = undefined
        this.vfs = undefined
        this.writeOutcomes = undefined
        await disposePythonToolbox(stale)
      }
      const wiring = await installPythonToolbox(options)
      if (wiring !== undefined) {
        this.wiring = wiring
        this.vfs = options.vfs
        this.writeOutcomes = options.writeOutcomes
      }
      return wiring
    })()
    this.pending = run
    try {
      return await run
    } finally {
      if (this.pending === run) this.pending = undefined
    }
  }

  /** Dispose the published wiring and clear the slot. Safe to call twice. */
  async unbind(): Promise<void> {
    const previous = this.pending
    const run = (async (): Promise<void> => {
      await previous?.catch(() => {})
      const stale = this.wiring
      this.wiring = undefined
      this.vfs = undefined
      this.writeOutcomes = undefined
      await disposePythonToolbox(stale)
    })()
    this.pending = run
    try {
      await run
    } finally {
      if (this.pending === run) this.pending = undefined
    }
  }
}

/** One wiring lifecycle per Worker global scope. */
export const pythonToolboxLifecycle = new PythonToolboxLifecycle()

/**
 * Resolve the Worker's loopback `/v1/http` route from the environment.
 *
 * The names match the `curl` shim and the llm bridge: `PDSH_CHANNEL_ORIGIN` /
 * `PDSH_CHANNEL_TOKEN` first, then the exec-bridge spellings. Both halves are
 * required; without them the Python runtime keeps its original behaviour and
 * never pretends the network works.
 * @param env - environment to read (defaults to `process.env` at the caller).
 * @returns the route, or undefined when either half is absent.
 */
export function resolvePythonHttpRoute(
  env: Readonly<Record<string, string | undefined>> = process.env,
): LoopbackHttpRoute | undefined {
  const origin = env.PDSH_CHANNEL_ORIGIN ?? env.PDSH_EXEC_BRIDGE_URL
  const token = env.PDSH_CHANNEL_TOKEN ?? env.PDSH_EXEC_BRIDGE_TOKEN
  if (origin === undefined || origin === '' || token === undefined || token === '') return undefined
  return { origin, token }
}

/**
 * Read one artifact from the mounted image.
 * @returns The bytes, or undefined when the path does not exist.
 * @throws {Error} When the path exists but cannot be read as a file.
 */
export function readImageArtifact(
  vfs: WorkerEntryVfs,
  reader: NonNullable<WorkerEntryVfs['readFileSync']>,
  path: string,
): Uint8Array | undefined {
  let value: string | Uint8Array
  try {
    value = reader.call(vfs, path)
  } catch (error) {
    if ((error as { code?: unknown }).code === 'ENOENT') return undefined
    throw new Error(
      `worker entry: cannot read the image artifact ${path}: `
      + `${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
  if (typeof value === 'string') return new TextEncoder().encode(value)
  return value
}

/**
 * Read the build-time module probe the image packer staged beside the pair.
 *
 * `scripts/pack-image.mjs` lists the importable top-level modules straight
 * from the produced `python313.zip` and writes them to
 * {@link PYTHON_MODULES_IMAGE_PATH}. That list is the only honest answer to
 * "can I `import numpy` / `socketserver` / `zlib`?" before the model spends a
 * request on the question, so it goes into the boot capability manifest.
 * A missing file means an older image packed before this probe existed; the
 * manifest then says the list is unavailable instead of inventing modules.
 * @param vfs - Mounted (namespace-wrapped) Worker VFS.
 * @returns Probe output, or undefined when the image did not stage it.
 * @throws {Error} When the file exists but is not the documented JSON shape.
 */
export async function readPythonModuleProbe(vfs: WorkerEntryVfs): Promise<PythonModuleProbe | undefined> {
  let value: string | Uint8Array
  try {
    if (typeof vfs.promises?.readFile === 'function') {
      value = await vfs.promises.readFile(PYTHON_MODULES_IMAGE_PATH)
    } else if (typeof vfs.readFileSync === 'function') {
      value = vfs.readFileSync(PYTHON_MODULES_IMAGE_PATH)
    } else {
      return undefined
    }
  } catch (error) {
    if ((error as { code?: unknown }).code === 'ENOENT') return undefined
    throw new Error(
      `worker entry: cannot read the python module probe ${PYTHON_MODULES_IMAGE_PATH}: `
      + `${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
  const text = typeof value === 'string' ? value : new TextDecoder().decode(value)
  let parsed: unknown
  try {
    parsed = JSON.parse(text) as unknown
  } catch (error) {
    throw new Error(
      `worker entry: ${PYTHON_MODULES_IMAGE_PATH} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
  const record = typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
    ? parsed as Record<string, unknown>
    : undefined
  const rawModules = Array.isArray(parsed) ? parsed : record?.['modules']
  if (!Array.isArray(rawModules) || rawModules.some(module => typeof module !== 'string')) {
    throw new Error(`worker entry: ${PYTHON_MODULES_IMAGE_PATH} must carry a modules[] array of strings`)
  }
  const version = record?.['python']
  return {
    ...typeof version === 'string' && version !== '' ? { version } : {},
    modules: [...new Set(rawModules as string[])].sort(),
    ...readCompressionProbe(record?.['compression'], PYTHON_MODULES_IMAGE_PATH),
  }
}

/**
 * Validate the compression block the packer copied from `compression.json`.
 *
 * A missing block is a pre-report image: the manifest then says the capability
 * was not reported instead of guessing. A present but malformed block is a
 * broken probe file and fails loud, so the capability manifest can never quote
 * a half-read report.
 * @param value - the `compression` member of `modules.json`.
 * @param path - probe path for the diagnostic.
 * @returns `{}` when absent, else the validated compression block.
 * @throws {Error} When the block is present but not the documented shape.
 */
function readCompressionProbe(value: unknown, path: string): { compression?: PythonCompressionProbe } {
  if (value === undefined) return {}
  const record = typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
  if (record === undefined) {
    throw new Error(`worker entry: ${path} compression must be an object`)
  }
  const modules = record['modules']
  if (!Array.isArray(modules) || modules.some(module => typeof module !== 'string')) {
    throw new Error(`worker entry: ${path} compression.modules must be an array of strings`)
  }
  if (typeof record['tarfileGzip'] !== 'boolean') {
    throw new Error(`worker entry: ${path} compression.tarfileGzip must be a boolean`)
  }
  const zlibRuntime = record['zlibRuntime']
  if (zlibRuntime !== undefined && typeof zlibRuntime !== 'string') {
    throw new Error(`worker entry: ${path} compression.zlibRuntime must be a string when present`)
  }
  return {
    compression: {
      modules: [...new Set(modules as string[])].sort(),
      tarfileGzip: record['tarfileGzip'],
      ...zlibRuntime === undefined ? {} : { zlibRuntime },
    },
  }
}

/**
 * The host VFS's own promise face, or the Worker's `node:fs/promises` proxy.
 *
 * `MemoryVfs.promises` is instance-bound, so it follows the host that owns the
 * filesystem instead of the module-global active-VFS slot. The proxy stays as
 * the fallback for a host that exposes only the structural `WorkerEntryVfs`.
 * @param vfs - Mounted host VFS.
 * @returns A `node:fs/promises`-shaped face for {@link NodeFsBackend}.
 */
export async function hostVfsPromises(vfs: WorkerEntryVfs): Promise<NodeFsPromisesLike> {
  const promises = vfs.promises
  if (promises !== undefined) {
    if (typeof promises.stat !== 'function' || typeof promises.writeFile !== 'function') {
      throw new Error('worker entry: the host VFS promise face does not expose stat/writeFile')
    }
    return promises as unknown as NodeFsPromisesLike
  }
  return loadNodeFsPromises()
}

/**
 * Load the Worker's `node:fs/promises` module proxy.
 *
 * The bundle resolves `node:fs/promises` through the pinned runtime's module
 * proxy table (the same table `build.mjs` reads), and the proxy reads the VFS
 * mounted in `storage/active.ts`. Under Node the import is the real module,
 * which tests replace with an injected backend anyway.
 * @returns The `node:fs/promises` face for {@link NodeFsBackend}.
 */
async function loadNodeFsPromises(): Promise<NodeFsPromisesLike> {
  const imported = await import('node:fs/promises') as { default?: NodeFsPromisesLike } & Partial<NodeFsPromisesLike>
  const face = imported.default ?? imported
  if (typeof face?.stat !== 'function' || typeof face.writeFile !== 'function') {
    throw new Error('worker entry: the node:fs/promises proxy does not expose stat/writeFile')
  }
  return face as NodeFsPromisesLike
}
