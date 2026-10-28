// SPDX-License-Identifier: MIT
/**
 * Shared types of the WASI toolbox: the VFS proxy wire values, the synchronous
 * filesystem face the WASI host consumes, and the command table surface that
 * `subprocess-xl` routes program names through.
 * @module @phone-dsh/dsh-wasi-toolbox/types
 */

/** A guest directory and the host VFS directory it is served from. */
export interface GuestPreopen {
  /** Absolute path as the guest sees it, for example `/workspace`. */
  readonly guestPath: string
  /** Absolute path in the DSH worker VFS, for example `/dsh/workspace`. */
  readonly hostPath: string
}

/** Entry kind reported by `stat` and `readdir`. */
export type VfsKind = 'file' | 'directory' | 'symlink'

/** Metadata the VFS proxy returns for one entry. */
export interface VfsStat {
  readonly kind: VfsKind
  readonly size: number
  /** Permission bits (`0o777` mask). */
  readonly mode: number
  /** Modification time in milliseconds since the epoch. */
  readonly mtimeMs: number
  /** Stable file identity, or 0 when the backend has none. */
  readonly ino: number
}

/** One directory entry returned by a batched `readdir`. */
export interface VfsDirEntry {
  readonly name: string
  readonly kind: VfsKind
  readonly ino: number
}

/** Open-time effects a guest path request asks the proxy to apply. */
export interface VfsOpenOptions {
  readonly create: boolean
  readonly truncate: boolean
  readonly exclusive: boolean
  readonly directory: boolean
  readonly mode?: number
}

/** One logical VFS proxy request. Paths are host paths. */
export type VfsRequest =
  | { readonly op: 'stat'; readonly path: string }
  | { readonly op: 'readdir'; readonly path: string }
  | ({ readonly op: 'open'; readonly path: string } & VfsOpenOptions)
  | { readonly op: 'read'; readonly path: string; readonly offset: number; readonly length: number }
  | {
    readonly op: 'write'
    readonly path: string
    readonly offset: number
    readonly append: boolean
    readonly create: boolean
    readonly mode?: number
    readonly data: Uint8Array
  }
  | { readonly op: 'truncate'; readonly path: string; readonly length: number }
  | { readonly op: 'mkdir'; readonly path: string; readonly mode?: number }
  | { readonly op: 'unlink'; readonly path: string; readonly directory: boolean }
  | { readonly op: 'rename'; readonly from: string; readonly to: string }
  | { readonly op: 'sync' }

/** Payload of one successful proxy request. */
export type VfsValue =
  | { readonly kind: 'stat'; readonly stat: VfsStat }
  | { readonly kind: 'entries'; readonly entries: readonly VfsDirEntry[] }
  | { readonly kind: 'data'; readonly data: Uint8Array }
  | { readonly kind: 'written'; readonly written: number }
  | { readonly kind: 'void' }

/** One proxy response, successful or not. */
export type VfsResponse =
  | { readonly ok: true; readonly value: VfsValue }
  | { readonly ok: false; readonly code: string; readonly message: string }

/**
 * Host-side filesystem the proxy server applies requests to. The DSH worker
 * implements it over its `node:fs` face (the in-memory authority whose sink
 * mirrors writes to the WAL); tests use the in-memory implementation.
 */
export interface VfsBackend {
  stat(path: string): Promise<VfsStat> | VfsStat
  readdir(path: string): Promise<readonly VfsDirEntry[]> | readonly VfsDirEntry[]
  readFile(path: string): Promise<Uint8Array> | Uint8Array
  /**
   * Store bytes. `create` creates a missing file, `append` appends instead of
   * replacing, and `truncate` empties the file first.
   */
  writeFile(
    path: string,
    data: Uint8Array,
    options?: { readonly create?: boolean; readonly append?: boolean; readonly truncate?: boolean; readonly mode?: number },
  ): Promise<void> | void
  mkdir(path: string, mode?: number): Promise<void> | void
  unlink(path: string, options?: { readonly directory?: boolean; readonly recursive?: boolean }): Promise<void> | void
  rename(from: string, to: string): Promise<void> | void
  truncate(path: string, length: number): Promise<void> | void
  sync?(): Promise<void> | void
}

/**
 * Synchronous filesystem face the WASI host calls. Guest paths have already
 * been resolved to host paths when a method is invoked.
 */
export interface WasiVfs {
  stat(path: string): VfsStat
  readdir(path: string): readonly VfsDirEntry[]
  open(path: string, options: VfsOpenOptions): VfsStat
  read(path: string, offset: number, length: number): Uint8Array
  write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { readonly append: boolean; readonly create: boolean; readonly mode?: number },
  ): number
  truncate(path: string, length: number): void
  mkdir(path: string, mode?: number): void
  unlink(path: string, options: { readonly directory: boolean }): void
  /**
   * Remove an empty directory (POSIX `rmdir`, WASI `path_remove_directory`).
   * Succeeds only on an empty directory; a non-empty one fails `ENOTEMPTY`, a
   * file `ENOTDIR`, a missing path `ENOENT`. Optional so a host that serves
   * only an in-memory tree can keep the older `unlink`-with-`directory` face;
   * when absent the WASI host falls back to that call.
   */
  rmdir?(path: string): void
  rename(from: string, to: string): void
  sync(): void
}

/** Where a toolbox program's wasm bytes come from. */
export interface ToolboxModuleSource {
  /** Identity used by the module cache; one compile per URL. */
  readonly url: string
  load(): Promise<Uint8Array>
}

/** Dispatch facts an argv mapper may use. */
export interface ToolboxArgvContext {
  /** Guest cwd resolved from the dispatch, when one is covered by a preopen. */
  readonly cwd?: string
  /** Environment the program will receive (including the translated PWD). */
  readonly env: Readonly<Record<string, string>>
}

/** One program the toolbox can route. */
export interface ToolboxCommand {
  /** Canonical program name as it appears in argv. */
  readonly program: string
  /** Additional names that route to the same command. */
  readonly aliases?: readonly string[]
  /**
   * Rewrite argv once the dispatch cwd/env is known. Python uses it to make a
   * relative script operand absolute before CPython's pre-site path
   * configuration resolves it against `/`.
   */
  readonly mapArgv?: (argv: readonly string[], context: ToolboxArgvContext) => readonly string[]
  /** Compiled module or the cached source of its bytes. */
  readonly module: WebAssembly.Module | ToolboxModuleSource
  /** Arguments inserted before the caller's argv. */
  readonly args?: readonly string[]
  /** Extra environment entries for every run. */
  readonly env?: Readonly<Record<string, string>>
  /** Default cwd inside the guest namespace. */
  readonly cwd?: string
  /**
   * True when this invocation reads its program/script from standard input
   * (`python3 -`, or a bare `python3` with no script operand). The toolbox
   * uses it for the stdin delivery watchdog: such an invocation must observe
   * its first `fd_read(0)` shortly after the exec starts, otherwise the
   * interpreter is wedged before it can make progress and the dispatch fails
   * fast instead of holding the command lane.
   */
  readonly scriptFromStdin?: (argv: readonly string[]) => boolean
  /** Preopened directories; defaults to the toolbox-level list. */
  readonly preopens?: readonly GuestPreopen[]
  /** Memory ceiling for one hot instance. */
  readonly memoryLimitBytes?: number
  readonly description?: string
}

/** One toolbox invocation, shaped for `subprocess-xl` routing. */
export interface ToolboxRunRequest {
  readonly program: string
  /** Arguments after argv[0]. */
  readonly argv?: readonly string[]
  readonly env?: Readonly<Record<string, string>>
  readonly cwd?: string
  /**
   * Complete standard input for the program (heredoc body, pipeline output or
   * `stdio.stdin` data). Delivery is bounded by `MAX_STDIN_BYTES`; EOF is
   * delivered immediately after the last byte, so a guest that drains stdin
   * terminates instead of blocking on a read that can never complete.
   */
  readonly stdin?: Uint8Array
  readonly signal?: AbortSignal
  /**
   * Hard per-stream capture cap. The host keeps at most this many bytes, stops
   * forwarding the stream once the cap is crossed, and terminates the guest so
   * a program that never stops writing cannot grow the Worker heap without
   * bound. Omitted means the historical unbounded streaming behaviour.
   */
  readonly maxStdoutBytes?: number
  /** Hard stderr cap; same stop semantics as {@link maxStdoutBytes}. */
  readonly maxStderrBytes?: number
  readonly onStdout?: (chunk: Uint8Array) => void
  readonly onStderr?: (chunk: Uint8Array) => void
}

/** Result of one toolbox invocation. */
export interface ToolboxResult {
  readonly program: string
  readonly exitCode: number
  readonly cancelled: boolean
  readonly memoryExceeded: boolean
  readonly memoryPeakBytes: number
  /** Guest bytes produced on stdout (host cap diagnostics are not counted). */
  readonly stdoutBytes: number
  /** Guest bytes produced on stderr (host cap diagnostics are not counted). */
  readonly stderrBytes: number
  /**
   * Stable failure code when the dispatch failed before the guest exited
   * (`E_STDIN_*`/`E_EXEC_START_TIMEOUT` from `stdin-delivery.ts`). Absent for
   * a normal interpreter exit, including a non-zero one. A stream cap stop
   * reports `E_OUTPUT_LIMIT`.
   */
  readonly failureCode?: string
  /** True when `maxStdoutBytes` stopped the dispatch (bytes counts produced). */
  readonly stdoutTruncated?: boolean
  /** True when `maxStderrBytes` stopped the dispatch (bytes counts produced). */
  readonly stderrTruncated?: boolean
}
