// SPDX-License-Identifier: MIT
/**
 * The subset of the DeepSeek Harness sources the bundled probe exposes.
 *
 * The probe re-exports the checkout's own modules; these interfaces only
 * describe the shapes the contract tests read. They are not a copy of DSH:
 * the implementation is always the checkout's, and a shape change is exactly
 * what the contract suite reports.
 * @module @phone-dsh/dsh-contract-tests/probe-types
 */

/** One committed in-memory VFS mutation, as the runtime publishes it. */
export type ProbeMutation =
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

/** Durable write-behind observer accepted by the in-memory VFS. */
export interface ProbeMutationSink {
  record(mutation: ProbeMutation): void
  flush(): Promise<void>
}

/** The in-memory VFS surface the phone host and its sink rely on. */
export interface ProbeVfs {
  flush(): Promise<void>
  subscribe(listener: (mutation: ProbeMutation) => void): () => void
  writeFileSync(path: string, data: string | Uint8Array, options?: { mode?: number; flag?: string }): void
  appendFileSync(path: string, data: string | Uint8Array): void
  mkdirSync(path: string, options?: { recursive?: boolean; mode?: number }): string | undefined
  chmodSync(path: string, mode: number): void
  rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void
  readFileSync(path: string, options?: string | { encoding?: string }): string | Uint8Array
  existsSync(path: string): boolean
  seedDirectory(path: string, options?: { mode?: number; mtimeMs?: number }): void
}

/** Constructor of the checkout's in-memory VFS. */
export interface ProbeVfsConstructor {
  new (options?: { sink?: ProbeMutationSink }): ProbeVfs
}

/** Child process handle members the contract reads. */
export interface ProbeChildProcess {
  readonly stdout: { on(event: 'data', listener: (chunk: unknown) => void): unknown } | null
  readonly stderr: { on(event: 'data', listener: (chunk: unknown) => void): unknown } | null
  on(event: 'error', listener: (error: unknown) => void): unknown
  on(event: 'close', listener: (code: unknown, signal: unknown) => void): unknown
}

/** Synchronous spawn result, in the Node shape the shim returns. */
export interface ProbeSpawnSyncResult {
  readonly status: number | null
  readonly signal: string | null
  readonly stdout: Uint8Array
  readonly stderr: Uint8Array
  readonly error?: {
    readonly code?: string
    readonly errno?: number
    readonly path?: string
    readonly syscall?: string
    readonly message?: string
  }
}

/** The fake HTTP server members the worker host's request listener needs. */
export interface ProbeServer {
  on(event: string, listener: (...args: unknown[]) => void): ProbeServer
  once(event: string, listener: (...args: unknown[]) => void): ProbeServer
  listen(...args: unknown[]): ProbeServer
  address(): { address: string; family: string; port: number }
  close(callback?: () => void): ProbeServer
  closeAllConnections(): void
  closeIdleConnections(): void
}

/** Request listener captured from the app's fake `node:http`. */
export type ProbeRequestListener = (request: unknown, response: unknown) => void

/** One shell run's settled result. */
export interface ProbeShellRun {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

/** One patch row `app-boot` merges into the effective profile. */
export interface ProbePatchRow {
  readonly id?: string
  readonly [field: string]: unknown
}

/** Profile context fields `readProfilePatches` reads. */
export interface ProbeProfileContext {
  readonly name: string
  readonly dir: string
  readonly patchPath: string
  readonly installAnchor: string
  readonly cwd: string
  readonly home: string
  readonly startedBundles: readonly string[]
  readonly overlays: readonly ProbePatchRow[]
  readonly telemetryDisabledEnv?: string | undefined
}

/** Already loaded profile shape `readProfilePatches` accepts. */
export interface ProbeLoadedProfile {
  readonly name: string
  readonly dir: string
  readonly patchPath: string
  readonly layers: readonly {
    readonly packageName: string
    readonly packageDir: string
    readonly patchPaths: readonly string[]
    readonly patches: readonly ProbePatchRow[]
  }[]
  readonly patches: readonly ProbePatchRow[]
  readonly skippedBundles: readonly string[]
}

/** The checkout modules the bundled probe re-exports. */
export interface ProbeModule {
  readonly runtimeApi: Record<string, unknown>
  readonly PLATFORM_ENTRY_CONFIG: Readonly<Record<string, Readonly<Record<string, unknown>>>>
  readonly IMAGE_OVERLAY_DIRECTORIES: readonly string[]
  readonly IMAGE_EMPTY_DIRECTORIES: readonly string[]
  readonly IMAGE_HOME_DIRECTORY: string
  readonly IMAGE_MANIFEST_PATH: string
  readonly DEFAULT_ROOT: string
  readonly MemoryVfs: ProbeVfsConstructor
  setActiveVfs(vfs: ProbeVfs): void
  spawn(program: string, args?: readonly string[], options?: {
    cwd?: string | undefined
    env?: Readonly<Record<string, string>> | undefined
  }): ProbeChildProcess
  spawnSync(program: string, args?: readonly string[]): ProbeSpawnSyncResult
  createServer(listener?: ProbeRequestListener): ProbeServer
  requestListener(): ProbeRequestListener | undefined
  whenRequestListener(): Promise<ProbeRequestListener>
  standardPrograms(): ReadonlyMap<string, unknown>
  runShellCommand(source: string, options: {
    cwd: string
    env: Readonly<Record<string, string>>
    stdin?: string | undefined
  }): Promise<ProbeShellRun>
  readProfilePatches(
    binName: string,
    context: ProbeProfileContext,
    initialProfile?: ProbeLoadedProfile,
  ): ProbePatchRow[]
  readonly PROFILE_PATCH_FILENAME: string
}
