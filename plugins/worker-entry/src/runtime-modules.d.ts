// SPDX-License-Identifier: MIT
/**
 * Structural declarations for the pinned DeepSeek Harness webworker runtime
 * sources imported by `runtime-binding.ts`.
 *
 * The checkout is not an npm dependency of `plugins`, so TypeScript cannot
 * resolve the runtime's `./src/*` export on its own. Only the shapes this entry
 * calls are declared here; the implementation is always the checkout's. Nothing
 * in this file is copied from DSH beyond the call signatures the entry uses.
 * @module @phone-dsh/dsh-worker-entry/runtime-modules
 */
declare module '@deepseek-ai/dsh-experimental-webworker-runtime/src/*' {
  /** Pinned image layout constants read by the runtime binding. */
  export const DEFAULT_ROOT: string
  export const IMAGE_MANIFEST_PATH: string

  export type RuntimeMutation =
    | {
      readonly kind: 'write'
      readonly path: string
      readonly bytes: Uint8Array
      readonly mode: number
      readonly entryChanged: boolean
      readonly appendedFrom?: number
    }
    | { readonly kind: 'mkdir'; readonly path: string; readonly mode: number }
    | { readonly kind: 'remove'; readonly path: string }
    | { readonly kind: 'chmod'; readonly path: string; readonly mode: number }

  export interface RuntimeVfs {
    subscribe(listener: (mutation: RuntimeMutation) => void): () => void
    flush(): Promise<void>
    existsSync(path: string): boolean
    readFileSync(path: string, options?: unknown): string | Uint8Array
    readdirSync(path: string, options?: unknown): string[]
    statSync(path: string, options?: unknown): { readonly mode: number; isFile(): boolean }
  }

  export interface RuntimeRequestListener {
    (req: unknown, res: unknown): void
  }

  export interface RuntimeResponseSink {
    head(status: number, headers: Record<string, string>): void
    chunk(bytes: Uint8Array): void
    end(payload?: { status: number; headers: Record<string, string>; body?: Uint8Array | undefined }): void
    fail(message: string): void
  }

  export interface RuntimeTunnelRequestFrame {
    readonly t: 'req'
    readonly id: number
    readonly method: string
    readonly url: string
    readonly headers: Record<string, string>
    readonly body?: Uint8Array | ArrayBuffer | Blob | ReadableStream<Uint8Array> | undefined
  }

  export interface RuntimeSyntheticExchange {
    readonly req: unknown
    readonly res: unknown
    readonly aborted: boolean
    abort(): void
  }

  export function createSyntheticExchange(
    frame: RuntimeTunnelRequestFrame,
    sink: RuntimeResponseSink,
  ): RuntimeSyntheticExchange

  export interface RuntimeWorkerHostOptions {
    readonly staticModules: Record<string, () => unknown>
    readonly staticModulePrefixes?: Record<string, () => unknown>
    readonly requestListener: () => Promise<RuntimeRequestListener>
    readonly alsCausality?: unknown
    readonly image: Uint8Array | string
    readonly overlays?: readonly (Uint8Array | string)[]
    readonly env?: Readonly<Record<string, string>>
    /** Tunnel port the runtime tunnel posts page-facing frames through. */
    readonly channel?: { postMessage(message: unknown, transfer?: Transferable[]): void }
  }

  export interface RuntimeWorkerHost {
    handleMessage(data: unknown): void
    start(): Promise<void>
    stop(): Promise<void>
    readonly vfs: RuntimeVfs | undefined
    readonly modules: unknown
  }

  function makeWorkerHost(options: RuntimeWorkerHostOptions): RuntimeWorkerHost
  export { makeWorkerHost as createWorkerHost }

  /** Default virtual image root (`/dsh`). */
  export const DEFAULT_ROOT: string

  /**
   * The mounted VFS slot the `node:fs` proxy reads. The entry replaces the
   * host's instance with the namespace wrapper right after `start()`.
   */
  export function setActiveVfs(vfs: unknown): void

  /** The shared `node:fs.promises` object the Worker adapters hold. */
  export const promises: Record<string, unknown>

  /** The virtual `node:fs.constants` table shared by both fs faces. */
  export const constants: Record<string, number | undefined>

  export function createNodeBuiltins(): Record<string, () => unknown>
  export const REPLACED_PREFIXES: Record<string, () => unknown>
  /** The runtime's exact-specifier proxy table (`module-proxies.ts`). */
  export const MODULE_PROXIES: Record<string, string>

  /**
   * Structural stand-in for the runtime's in-memory VFS mount.
   *
   * The shape is intentionally opaque: this declaration exists only so the
   * loader options below type-check, and the zero-patch checker must not see a
   * redefinition of a runtime class (tests cast the namespace they import).
   */
  export interface RuntimeMemoryVfs {}

  /** Construction inputs for the Worker module loader. */
  export interface RuntimeModuleLoaderOptions {
    readonly vfs: RuntimeMemoryVfs
    readonly root?: string
    readonly staticModules: Record<string, () => unknown>
    readonly staticModulePrefixes?: Record<string, () => unknown>
    readonly alsCausality?: unknown
  }

  /** The CommonJS require face the loader publishes to `node:module`. */
  export interface WorkerRequire {
    (specifier: string): unknown
    readonly resolve: {
      (specifier: string): string
      paths(specifier: string): string[] | null
    }
  }

  /** The CommonJS loader over one VFS mount. */
  export class WorkerModuleLoader {
    constructor(options: RuntimeModuleLoaderOptions)
    requireFrom(directory: string): (specifier: string) => unknown
    /** Build one require bound to a directory, file path, or file URL. */
    createRequire(location: string | URL): WorkerRequire
    /** Resolve one specifier from a directory without evaluating it. */
    resolve(specifier: string, fromDirectory: string): unknown
    /** Load one previously resolved module. */
    load(resolution: unknown): unknown
    /** Node-loader-compatible seam the cascaded ESM loader imports through. */
    readonly internal: {
      import(specifier: string, parentURL?: string | URL, attributes?: unknown): Promise<unknown>
    }
  }

  /** Publish the loader the `node:module` proxy resolves through. */
  export function setActiveModuleLoader(loader: WorkerModuleLoader): void

  /** Read the loader published by {@link setActiveModuleLoader}. */
  export function requireActiveModuleLoader(): WorkerModuleLoader

  /** Inflate one gzip image into its ustar bytes. */
  export function inflateImage(bytes: Uint8Array, source: string): Promise<Uint8Array>
  export const alsCausality: unknown
  export function runAtAsyncContextRoot<T>(task: () => T): T

  export function whenRequestListener(): Promise<RuntimeRequestListener>
  export function installAsyncContextHooks(): void
  export function installTimerGlobals(): void
  export function installCryptoGlobals(): void

  export interface RuntimeProcessOptions {
    readonly cwd: string
    readonly env: Record<string, string>
  }

  export function installProcessGlobal(options: RuntimeProcessOptions): unknown

  export interface RuntimeShellStartFrame {
    readonly t: 'shell-start'
    readonly script?: string | undefined
    readonly argv: readonly string[]
    readonly cwd: string
    readonly env: Record<string, string>
    readonly stdin: string
  }

  export function isShellStartFrame(data: unknown): data is RuntimeShellStartFrame
  export function runShellProcess(frame: RuntimeShellStartFrame, port: unknown): void
}

/**
 * Page-half export used by `web-boot.ts`.
 *
 * The full Web page imports the runtime's page bundle; this entry imports the
 * checkout source directly at build time, so only the tunnel and injection
 * shapes this layer calls need declarations here.
 */
declare module '@deepseek-ai/dsh-experimental-webworker-runtime/client' {
  export type TunnelFetch = (input: URL | string, init?: RequestInit) => Promise<Response>

  /** Boot payload returned by the worker tunnel's `/__boot__` route. */
  export interface BootPayload {
    readonly injections: readonly unknown[]
  }

  /** Page half of the postMessage tunnel. */
  export class WorkerTunnel {
    constructor(worker: Worker)
    readonly fetch: TunnelFetch
    init(image: string, overlays?: readonly string[]): void
    open(
      endpoint: string,
      payload: unknown,
      signal: AbortSignal,
      uplink?: AsyncIterable<unknown>,
    ): AsyncGenerator<unknown>
    loadBundle(url: string): Promise<void>
    bootPayload(): Promise<BootPayload>
  }

  /** Execute the structured boot injection table in row order. */
  export function applyIndexInjections(
    rows: readonly unknown[],
    loadScript: (src: string) => Promise<void>,
  ): Promise<void>
}

declare module '@deepseek-ai/dsh-client-web/injections' {
  export function applyIndexInjections(
    rows: readonly unknown[],
    loadScript: (src: string) => Promise<void>,
  ): Promise<void>
}
