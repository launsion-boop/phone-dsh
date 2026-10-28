// SPDX-License-Identifier: MIT
/**
 * Production wiring of the jq-compatible WASI engine.
 *
 * The Worker shell keeps a `jq` command, but the pinned just-bash built-in has
 * no public jq parser and cannot express `input`/`inputs`, lazy consumption,
 * scopes or `break`. The image therefore stages a real engine (`jq.wasm`,
 * built from this repository's `pdsh-jaq-wasm` crate over jaq-core) and this
 * module registers it on the one published toolbox as `jq-wasi`.
 *
 * The artifact is optional at boot: an image packed before this engine (or a
 * deliberately jq-free build) simply keeps the fail-loud shell shim. An image
 * that stages `jq.wasm` must have a working module: a compile/trap/read
 * failure fails the boot instead of advertising a command that would fail on
 * first use.
 * @module @phone-dsh/dsh-worker-entry/jq-toolbox
 */
import {
  NodeFsBackend,
  setWorkerToolbox,
  WasiToolbox,
  WORKER_VFS_PREOPENS,
} from '../../wasi-toolbox/src/index.ts'
import type {
  NodeFsPromisesLike,
  ToolWorkerTransport,
  VfsBackend,
  VfsWriteOutcomes,
  WorkerToolbox,
} from '../../wasi-toolbox/src/index.ts'
import type { WorkerEntryVfs } from './entry.ts'
import { hostVfsPromises, readImageArtifact } from './python-toolbox.ts'

/** Image-relative directory the packer stages the jq engine under. */
export const JQ_IMAGE_MOUNT = 'bin/jq'
/** Absolute image (VFS) directory of the jq artifact. */
export const JQ_IMAGE_DIRECTORY = `/dsh/${JQ_IMAGE_MOUNT}`
/** Mounted path of the WASI jq executable. */
export const JQ_WASM_IMAGE_PATH = `${JQ_IMAGE_DIRECTORY}/jq.wasm`
/** Optional build report staged beside the artifact. */
export const JQ_ENGINE_IMAGE_PATH = `${JQ_IMAGE_DIRECTORY}/engine.json`
/** Program name on the toolbox command table. */
export const JQ_PROGRAM = 'jq-wasi'
/** Build command the loud failure points at. */
export const JQ_BUILD_COMMAND = 'bash plugins/wasi-toolbox/jq/build.sh --out <dir>'

/** Facts the build probe recorded for the capability manifest. */
export interface JqEngineProbe {
  readonly engine?: string
  readonly bytes?: number
  readonly sha256?: string
  /** Source identity of the artifact, recorded by the source-bound build. */
  readonly source?: {
    readonly algorithm?: string
    readonly fingerprint?: string
  }
}

/** Inputs for {@link installJqToolbox}. */
export interface JqToolboxOptions {
  /** Mounted VFS: source of the artifact bytes and the flush sink. */
  readonly vfs: WorkerEntryVfs
  /** VFS proxy backend; defaults to the Worker's `node:fs/promises` face. */
  readonly backend?: VfsBackend
  /** Injected promise face (tests); used when `backend` is absent. */
  readonly fsPromises?: NodeFsPromisesLike
  /** Ordered-channel outcome tracker shared with the Worker sink. */
  readonly writeOutcomes?: VfsWriteOutcomes
  /** Tool worker factory; defaults to `new Worker(./tool-worker.js)`. */
  readonly spawnWorker?: (command: { readonly program: string }) => ToolWorkerTransport
  /** URL of the built generic tool worker, for relocated deployments. */
  readonly workerUrl?: URL | string
  /** Override the automatic `crossOriginIsolated` detection (tests). */
  readonly crossOriginIsolated?: boolean
  /** Visible-line sink; defaults to `console.info`. */
  readonly log?: (message: string) => void
  /**
   * WASI hot-instance ceiling for the jq tool worker (budgets.md §4,
   * `wasiHotInstanceBytes`); omitted means the 8 GiB default.
   */
  readonly memoryLimitBytes?: number
}

/** The published jq toolbox and the probed engine facts. */
export interface JqToolboxWiring {
  readonly toolbox: WasiToolbox
  readonly probe: JqEngineProbe | undefined
}

/**
 * Build and publish the jq engine from the image artifact.
 * @param options - VFS, backend/tool-worker seams and the log sink.
 * @returns The wiring, or undefined when the image carries no jq engine.
 * @throws {Error} When the image stages an unreadable/empty/broken artifact.
 */
export async function installJqToolbox(
  options: JqToolboxOptions,
): Promise<JqToolboxWiring | undefined> {
  const log = options.log ?? ((message: string): void => { console.info(message) })
  const reader = options.vfs.readFileSync
  if (typeof reader !== 'function') {
    log('worker entry: this VFS exposes no readFileSync, so the image jq engine cannot be loaded; jq stays on the shim')
    return undefined
  }
  const wasm = readImageArtifact(options.vfs, reader, JQ_WASM_IMAGE_PATH)
  const engineBytes = readImageArtifact(options.vfs, reader, JQ_ENGINE_IMAGE_PATH)
  if (wasm === undefined && engineBytes === undefined) {
    log(`worker entry: the image carries no jq engine (looked for ${JQ_WASM_IMAGE_PATH}); jq stays on the fail-loud shim`)
    return undefined
  }
  if (wasm === undefined) {
    throw new Error(
      `worker entry: the image declares a jq engine (${JQ_ENGINE_IMAGE_PATH}) but ${JQ_WASM_IMAGE_PATH} is missing; `
      + `rebuild it with ${JQ_BUILD_COMMAND} and pass that directory to scripts/pack-image.mjs --jq <dir>`,
    )
  }
  if (wasm.byteLength === 0) {
    throw new Error(`worker entry: the image's jq engine is empty (${JQ_WASM_IMAGE_PATH}); rebuild it with ${JQ_BUILD_COMMAND}`)
  }
  if (engineBytes === undefined) {
    throw new Error(
      `worker entry: the image carries ${JQ_WASM_IMAGE_PATH} but not ${JQ_ENGINE_IMAGE_PATH}; `
      + `the engine bytes have no build report to verify, so jq cannot be advertised. Rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  const probe = readJqEngineProbe(engineBytes)
  await verifyJqArtifact(wasm, probe)
  const backend = options.backend ?? new NodeFsBackend(
    options.fsPromises ?? await hostVfsPromises(options.vfs),
    {
      flush: () => options.vfs.flush(),
      ...options.writeOutcomes === undefined ? {} : { writeOutcomes: options.writeOutcomes },
    },
  )
  const toolbox = new WasiToolbox({
    commands: [{
      program: JQ_PROGRAM,
      aliases: ['jaq'],
      description: 'jq-compatible filter engine (WASI)',
      module: { url: `image://${JQ_WASM_IMAGE_PATH}`, load: async () => wasm },
    }],
    backend,
    preopens: WORKER_VFS_PREOPENS,
    snapshotFallback: true,
    refreshSnapshotOnRun: true,
    ...options.spawnWorker === undefined ? {} : { spawnWorker: options.spawnWorker },
    ...options.workerUrl === undefined ? {} : { workerUrl: options.workerUrl },
    ...options.crossOriginIsolated === undefined ? {} : { crossOriginIsolated: options.crossOriginIsolated },
    ...options.memoryLimitBytes === undefined ? {} : { memoryLimitBytes: options.memoryLimitBytes },
  })
  // Prove the guest can resolve the shell's workspace before publishing. A
  // toolbox that cannot read the preopened roots would turn every jq step
  // into ENOTCAPABLE at first file access.
  await toolbox.assertFileView()
  return { toolbox, probe }
}

/**
 * Validate the build report the packer staged beside `jq.wasm`.
 * @param bytes - `engine.json` bytes.
 * @returns The engine identity and the source binding the report records.
 */
function readJqEngineProbe(bytes: Uint8Array): JqEngineProbe {
  let parsed: unknown
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes)) as unknown
  } catch (error) {
    throw new Error(
      `worker entry: ${JQ_ENGINE_IMAGE_PATH} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`worker entry: ${JQ_ENGINE_IMAGE_PATH} must be a JSON object`)
  }
  const record = parsed as Record<string, unknown>
  const engine = record['engine']
  if (engine !== undefined && typeof engine !== 'string') {
    throw new Error(`worker entry: ${JQ_ENGINE_IMAGE_PATH} engine must be a string when present`)
  }
  const wasm = record['wasm']
  const bytesRecord = typeof wasm === 'object' && wasm !== null && !Array.isArray(wasm)
    ? wasm as Record<string, unknown>
    : undefined
  const source = record['source']
  const sourceRecord = typeof source === 'object' && source !== null && !Array.isArray(source)
    ? source as Record<string, unknown>
    : undefined
  return {
    ...engine === undefined ? {} : { engine },
    ...typeof bytesRecord?.['bytes'] === 'number' ? { bytes: bytesRecord['bytes'] } : {},
    ...typeof bytesRecord?.['sha256'] === 'string' ? { sha256: bytesRecord['sha256'] } : {},
    ...sourceRecord === undefined ? {} : {
      source: {
        ...typeof sourceRecord['algorithm'] === 'string' ? { algorithm: sourceRecord['algorithm'] } : {},
        ...typeof sourceRecord['fingerprint'] === 'string' ? { fingerprint: sourceRecord['fingerprint'] } : {},
      },
    },
  }
}

/**
 * Bind the staged wasm to its report before advertising `jq`.
 *
 * The boot cannot recompute the Rust source fingerprint (the sources are not
 * in the image), so the packer owns that comparison. It can and must check the
 * bytes themselves: the report's sha256 and byte count have to describe the
 * exact module about to be loaded. An artifact without that binding is not
 * advertised.
 * @param wasm - staged module bytes.
 * @param probe - parsed `engine.json`.
 * @throws {Error} When the report does not describe these bytes.
 */
async function verifyJqArtifact(wasm: Uint8Array, probe: JqEngineProbe): Promise<void> {
  if (typeof probe.engine !== 'string' || probe.engine.trim() === '') {
    throw new Error(
      `worker entry: ${JQ_ENGINE_IMAGE_PATH} does not name the engine identity; `
      + `rebuild the engine with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (probe.sha256 === undefined || probe.bytes === undefined) {
    throw new Error(
      `worker entry: ${JQ_ENGINE_IMAGE_PATH} does not record the wasm sha256 and byte count; `
      + `rebuild the engine with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (probe.bytes !== wasm.byteLength) {
    throw new Error(
      `worker entry: ${JQ_WASM_IMAGE_PATH} has ${String(wasm.byteLength)} bytes but ${JQ_ENGINE_IMAGE_PATH} `
      + `records ${String(probe.bytes)}; rebuild the engine with ${JQ_BUILD_COMMAND}`,
    )
  }
  const subtle = globalThis.crypto?.subtle
  if (subtle === undefined) {
    throw new Error(
      `worker entry: this Worker has no SubtleCrypto, so ${JQ_WASM_IMAGE_PATH} cannot be checked against `
      + `${JQ_ENGINE_IMAGE_PATH}; refusing to advertise an unverified jq engine`,
    )
  }
  // The artifact is a plain owned Uint8Array; the DOM lib types the digest
  // input as ArrayBuffer-backed, while the runtime accepts this view.
  const digest = await subtle.digest('SHA-256', wasm as unknown as BufferSource)
  const actual = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
  if (actual !== probe.sha256) {
    throw new Error(
      `worker entry: ${JQ_WASM_IMAGE_PATH} has sha256 ${actual} but ${JQ_ENGINE_IMAGE_PATH} records `
      + `${probe.sha256}; rebuild the engine with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (probe.source?.algorithm !== 'pdsh-jq-source-v1'
    || typeof probe.source.fingerprint !== 'string'
    || !/^[0-9a-f]{64}$/u.test(probe.source.fingerprint)) {
    throw new Error(
      `worker entry: ${JQ_ENGINE_IMAGE_PATH} carries no source fingerprint; `
      + `rebuild the engine with ${JQ_BUILD_COMMAND} and repack the image`,
    )
  }
}

/**
 * Release a wiring: unpublish when it is the current sole toolbox and dispose
 * the warm tool worker. Safe to call twice and with `undefined`.
 * @param wiring - result of {@link installJqToolbox}.
 */
export async function disposeJqToolbox(wiring: JqToolboxWiring | undefined): Promise<void> {
  if (wiring === undefined) return
  if (getCurrentSoleToolbox() === wiring.toolbox) setWorkerToolbox(undefined)
  await wiring.toolbox.dispose()
}

/** The global toolbox only when it is exactly this concrete instance. */
function getCurrentSoleToolbox(): WorkerToolbox | undefined {
  const value = (globalThis as { __PDSH_WASI_TOOLBOX__?: unknown }).__PDSH_WASI_TOOLBOX__
  return value === undefined ? undefined : value as WorkerToolbox
}

/** One jq wiring per Worker global scope, re-bound on every boot path. */
export class JqToolboxLifecycle {
  private wiring: JqToolboxWiring | undefined
  private vfs: WorkerEntryVfs | undefined
  private writeOutcomes: VfsWriteOutcomes | undefined
  private pending: Promise<unknown> | undefined

  /** The currently published wiring, if any. */
  current(): JqToolboxWiring | undefined {
    return this.wiring
  }

  /** The host VFS the current wiring is bound to, if any. */
  boundTo(): WorkerEntryVfs | undefined {
    return this.vfs
  }

  /**
   * Bind (or re-bind) the engine to a host VFS.
   *
   * Re-binding to the same VFS/outcome tracker is a no-op. A different host
   * VFS first disposes the stale wiring, so the published `jq` never reaches a
   * filesystem the new host does not mount.
   * @param options - VFS and wiring seams.
   * @returns The published wiring, or undefined when the image has no engine.
   */
  async bind(options: JqToolboxOptions): Promise<JqToolboxWiring | undefined> {
    if (
      this.wiring !== undefined
      && this.vfs === options.vfs
      && this.writeOutcomes === options.writeOutcomes
    ) return this.wiring
    const previous = this.pending
    const run = (async (): Promise<JqToolboxWiring | undefined> => {
      await previous?.catch(() => {})
      if (
        this.wiring !== undefined
        && (this.vfs !== options.vfs || this.writeOutcomes !== options.writeOutcomes)
      ) {
        const stale = this.wiring
        this.wiring = undefined
        this.vfs = undefined
        this.writeOutcomes = undefined
        await disposeJqToolbox(stale)
      }
      const wiring = await installJqToolbox(options)
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
      await disposeJqToolbox(stale)
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
export const jqToolboxLifecycle = new JqToolboxLifecycle()
