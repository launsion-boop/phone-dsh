// SPDX-License-Identifier: MIT
/**
 * `VfsFileSystem`: just-bash's filesystem interface over `node:fs`.
 *
 * Inside the DSH Web Worker `node:fs` is the runtime's `MemoryVfs` bridge, so
 * every call this adapter makes is the same call the runtime's own shell makes:
 * a write becomes a sink mutation at the next `mseq`, not a second copy of the
 * workspace. Outside the Worker the same adapter is pointed at a temporary
 * directory (`root`) so the tests exercise real file I/O.
 *
 * The adapter deliberately uses only members the Worker shim implements
 * (`readFile`, `writeFile`, `mkdir`, `rm`, `cp`, `rename`, `chmod`, ...) and
 * answers the optional members just-bash probes (`utimes`, `symlink`,
 * `readlink`) with an explicit `ENOSYS`/`EPERM` instead of silently pretending.
 *
 * ## Device files
 *
 * just-bash implements every redirection (`>`, `>>`, `2>`, `2>&1`, `<`, `&>`,
 * `&>>`) and every command-internal open by calling `IFileSystem` methods on
 * the target; it has no separate device-file layer. The Worker VFS is a
 * `node:fs` facade over `MemoryVfs`, which has no `/dev` tree and cannot create
 * one outside the `/dsh` roots, so without this adapter answering the devices
 * itself `find . -type f 2>/dev/null` fails `ENOENT` and exits 1 and
 * `head -c 4 /dev/zero` burns a tool round-trip.
 *
 * {@link WORKER_DEVICE_PATHS} is therefore a fixed, documented set handled
 * before `node:fs` is reached: writes and appends are discarded (no sink
 * mutation, hence no `VFS_MUT` under PLAN D4), reads follow the device's
 * documented behavior and `stat`/`lstat` report `S_IFCHR | 0666`. The set is
 * `/dev/null`, `/dev/zero` and `/dev/urandom`; `/dev/stdout` and `/dev/stderr`
 * are the shell's own streams, which `IFileSystem` cannot represent, so
 * answering them here would silently lie instead of failing loud. Anything
 * outside the set keeps the normal `node:fs` path. The devices are virtual:
 * they are never created below the VFS root and `getAllPaths()` does not list
 * them.
 *
 * `/dev/urandom` is a bounded read, not an infinite stream: `IFileSystem` has
 * no streaming read, so every read surface returns exactly
 * {@link WORKER_DEVICE_READ_BYTES} bytes (1 MiB) and then EOF. `cat /dev/zero`
 * therefore ends at that window instead of running forever. The bound is part
 * of the contract; callers that need more read the device again.
 *
 * ## The POSIX temp root
 *
 * The Worker image ships only `/dsh/home`, `/dsh/workspace` and the volatile
 * `/dsh/tmp` (`webworker-packer` default `emptyDirectories`); POSIX `/tmp` does
 * not exist in it and `TMPDIR=/dsh/tmp` is only an environment hint. Without a
 * bridge the whole class of temp staging (`cat > /tmp/f`, `tee /tmp/f`, a
 * script writing `/tmp`, a Python step reading a file staged there) dies with a
 * bare `ENOENT` at the VFS root.
 *
 * The adapter therefore owns one documented, configuration-validated alias:
 * `/tmp` -> `/dsh/tmp` ({@link WORKER_TMP_ALIAS}, PLAN D4/D15). It is a
 * resolution, not a copy: the write is an ordinary `MemoryVfs` mutation below
 * `/dsh/tmp/**`, so it is never sink-sent (D4), still counts against the tmp
 * budget and disappears on restart. `getAllPaths()` lists the real
 * `/dsh/tmp/**` entries once and never synthesizes a second `/tmp/**` view.
 *
 * The alias is on for the Worker's virtual root (`''` or `'/'`, the only
 * configuration where `node:fs` is the runtime `MemoryVfs`) and off for a real
 * directory root, so desktop simulation and tests keep verbatim POSIX
 * behaviour. Callers can enable it explicitly with `workerPaths: true`, turn
 * it off with `workerPaths: false`, or replace the table with `aliases`
 * (validated at construction: only `/tmp` may be the source, both endpoints
 * absolute and normalised, the target inside `/dsh`, no overlap between
 * entries). No other root is redirected.
 *
 * Write-side failures (`writeFile`, `appendFile`, `createExclusive`, `mkdir`)
 * whose path is outside the writable roots get one remediation line naming
 * `/dsh/workspace`, `/dsh/home`, `/dsh/tmp` and `TMPDIR`; the error keeps its
 * code and virtual path and is never swallowed.
 * @module @phone-dsh/dsh-shell-ext/filesystem
 */

import { readdirSync, writeFileSync as writeFileSyncNode, promises as fsp } from 'node:fs'
import type { Stats } from 'node:fs'
import { posix } from 'node:path'
import {
  MAX_FILE_SIZE,
  MAX_SINGLE_FILE_LIMIT,
  MIN_SINGLE_FILE_LIMIT,
  SINGLE_FILE_LIMIT_ENV,
  formatByteLimit,
  singleFileLimitFromEnvironment,
} from '../../wasi-toolbox/src/limits.ts'
import { trailerLine } from './contract.ts'
import type { FileContent, IFileSystem } from 'just-bash/browser'

/** just-bash's latin1-shaped byte string (the interface brands it). */
type ByteString = Awaited<ReturnType<NonNullable<IFileSystem['readFileBytes']>>>
/** Directory entry just-bash's optional `readdirWithFileTypes` returns. */
type DirentEntry = Awaited<ReturnType<NonNullable<IFileSystem['readdirWithFileTypes']>>>[number]
/** just-bash's stat shape. */
type FsStat = Awaited<ReturnType<IFileSystem['stat']>>
type ReadFileOptions = Exclude<Parameters<IFileSystem['readFile']>[1], string | undefined>
type WriteFileOptions = Exclude<Parameters<IFileSystem['writeFile']>[2], string | undefined>
type MkdirOptions = Parameters<IFileSystem['mkdir']>[1]
type RmOptions = Parameters<IFileSystem['rm']>[1]
type CpOptions = Parameters<IFileSystem['cp']>[2]
type CreateExclusiveOptions = Parameters<NonNullable<IFileSystem['createExclusive']>>[1]

/**
 * Default single-file budget: 64 MiB, the 8 GiB tier of budgets.md §4.
 *
 * Re-exported from the budget owner (`wasi-toolbox/src/limits.ts`)
 * so this adapter, the WASI backends and the sink's default all read one
 * value. The binding is live: `configureSingleFileLimit` applied by the Worker
 * entry before the host boots is the budget this constructor defaults to.
 *
 * This is the file cap, not the per-mutation frame cap. A file larger than one
 * VFS_MUT is published as one complete write plus appended suffixes
 * (channel.md §3.1), so this value is deliberately above the 15 MiB frame
 * bound. The Worker write surface refuses a write whose post-write file would
 * exceed this with `EFBIG` before the VFS publishes it; the sink's own payload
 * guard stays as the last-resort backstop for writers outside this adapter.
 * A host-configured `single_file_limit` arrives through
 * {@link SINGLE_FILE_LIMIT_ENV} and is read when the adapter is constructed.
 */
export { MAX_FILE_SIZE, MAX_SINGLE_FILE_LIMIT, MIN_SINGLE_FILE_LIMIT, SINGLE_FILE_LIMIT_ENV }

/** Default per-file read cap: the single-file limit, not the mutation bound. */
export const MAX_FILE_READ_SIZE = MAX_FILE_SIZE

/**
 * Tail of the serialised append queue, one entry per real target path.
 *
 * Module-level so every `VfsFileSystem` instance in this Worker shares it:
 * `subprocess-xl` builds one adapter per `bash` command, so an instance field
 * would not serialise two concurrent commands appending to the same file.
 */
const appendTails = new Map<string, Promise<void>>()

/**
 * One virtual path prefix resolved to another before it reaches `node:fs`.
 *
 * The prefix matches the path itself and every path below it (`/tmp` and
 * `/tmp/a`, not `/tmpx`). Aliases are only a resolution step: the target is
 * the real VFS location, so normal sink, budget and durability rules apply.
 */
export interface VfsPathAlias {
  /** Absolute virtual prefix to replace; the contract allows exactly `/tmp`. */
  readonly from: string
  /** Absolute virtual prefix it resolves to (inside `/dsh`, normally `/dsh/tmp`). */
  readonly to: string
}

/**
 * The Worker's documented POSIX temp-root bridge (PLAN D4/D15): `/tmp` is the
 * volatile `/dsh/tmp` root of the image, the same directory `TMPDIR` names.
 */
export const WORKER_TMP_ALIAS: VfsPathAlias = Object.freeze({ from: '/tmp', to: '/dsh/tmp' })

/** The alias table the Worker wiring enables for the virtual root. */
export const WORKER_PATH_ALIASES: readonly VfsPathAlias[] = Object.freeze([WORKER_TMP_ALIAS])

/** The roots a Worker command may create files under (PLAN D4/D15). */
export const WORKER_WRITABLE_ROOTS: readonly string[] = Object.freeze(['/dsh/workspace', '/dsh/home', '/dsh/tmp'])

/**
 * Bytes one read of a bounded virtual device returns.
 *
 * `/dev/zero` and `/dev/urandom` are infinite devices in POSIX, but
 * `IFileSystem` exposes whole-file reads only. The Worker therefore defines a
 * finite read window (1 MiB, the same order as the 256 KiB per-stream output
 * cap) and returns it on every read surface; `head -c 4 /dev/zero` sees 4
 * bytes, while `cat /dev/zero` reaches EOF after this many bytes instead of
 * looping forever. `/dev/null` stays empty and is unaffected.
 */
export const WORKER_DEVICE_READ_BYTES = 1024 * 1024

/** Largest buffer `crypto.getRandomValues` accepts in one call (65536). */
const CRYPTO_RANDOM_CHUNK_BYTES = 65_536

/** How one fixed device answers a read. */
type WorkerDeviceRead = 'empty' | 'zero' | 'random'

/** One entry of the fixed device table. */
interface WorkerDeviceDescriptor {
  /** POSIX file type: every entry is a character special file. */
  readonly kind: 'character'
  /** Bytes a read of this device produces (bounded per {@link WORKER_DEVICE_READ_BYTES}). */
  readonly read: WorkerDeviceRead
}

/**
 * The fixed device table the Worker shell filesystem answers itself.
 *
 * `/dev/null` reads empty; `/dev/zero` reads {@link WORKER_DEVICE_READ_BYTES}
 * zero bytes; `/dev/urandom` reads the same window of cryptographically random
 * bytes. All three are character devices (`S_IFCHR | 0666`), are sinks for
 * writes/appends and are never real tree entries. `cp` from a device writes
 * this read window; `cp` to any device discards.
 */
const WORKER_DEVICE_TABLE: readonly (readonly [string, WorkerDeviceDescriptor])[] = Object.freeze([
  ['/dev/null', Object.freeze({ kind: 'character', read: 'empty' })],
  ['/dev/zero', Object.freeze({ kind: 'character', read: 'zero' })],
  ['/dev/urandom', Object.freeze({ kind: 'character', read: 'random' })],
])

const WORKER_DEVICES: ReadonlyMap<string, WorkerDeviceDescriptor> = new Map(WORKER_DEVICE_TABLE)

/**
 * The fixed set of device files the Worker shell filesystem answers itself:
 * `/dev/null`, `/dev/zero` and `/dev/urandom`.
 *
 * Writes/appends discard and `stat` reports a character device. See the module
 * documentation for the bounded read window and for why `/dev/stdout` /
 * `/dev/stderr` stay outside the set (and keep failing loud).
 */
export const WORKER_DEVICE_PATHS: readonly string[] = Object.freeze([...WORKER_DEVICES.keys()])

/** `S_IFCHR` file-type bits plus the `0666` mode every fixed device reports. */
const CHARACTER_DEVICE_MODE = 0o020666

/** One directory entry as `readdir(..., { withFileTypes: true })` returns it. */
export interface VfsDirentLike {
  readonly name: string
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

/**
 * The `node:fs/promises` face this adapter calls.
 *
 * An interface (rather than the module object) so a test can back the adapter
 * with the Worker's in-memory VFS and drive the real shell against the real
 * sink; production passes nothing and gets `node:fs/promises`.
 */
export interface VfsFileSystemIo {
  readFile(path: string): Promise<Buffer>
  /**
   * Read at most `length` bytes starting at `start` without materialising the
   * whole file. Optional: the pinned Worker runtime's `node:fs` replacement
   * implements whole-file reads only, so a backend that cannot seek omits it
   * and consumers such as `od` fall back to a bounded whole-file read.
   * @param path - real path below the adapter root.
   * @param start - non-negative byte offset.
   * @param length - maximum bytes to return.
   */
  readFileRange?(path: string, start: number, length: number): Promise<Uint8Array | Buffer>
  writeFile(path: string, data: FileContent, options?: { encoding?: BufferEncoding; flag?: string; mode?: number }): Promise<void>
  appendFile(path: string, data: FileContent, options?: { encoding?: BufferEncoding }): Promise<void>
  stat(path: string): Promise<Stats>
  lstat(path: string): Promise<Stats>
  access(path: string): Promise<void>
  mkdir(path: string, options?: { recursive?: boolean; mode?: number }): Promise<unknown>
  readdir(path: string, options?: { withFileTypes?: boolean }): Promise<string[] | VfsDirentLike[]>
  rm(path: string, options?: { recursive?: boolean; force?: boolean }): Promise<void>
  /**
   * `rmdir` exists in Node's `node:fs`, but the pinned Worker runtime's
   * replacement implements only `rm`/`unlink`. It stays optional and is never
   * called: {@link VfsFileSystem.rm} removes an empty directory through
   * `rm(..., {recursive:true})` after proving it is empty.
   */
  rmdir?(path: string): Promise<void>
  cp(src: string, dest: string, options?: { recursive?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  link(existing: string, next: string): Promise<void>
  utimes?(path: string, atime: Date, mtime: Date): Promise<void>
}

/** Synchronous directory reader used by {@link VfsFileSystem.getAllPaths}. */
export type VfsReaddirSync = (path: string, options: { withFileTypes: true }) => readonly VfsDirentLike[]

/** One ranged-read implementation over a real path. */
type VfsFileRangeReader = (path: string, start: number, length: number) => Promise<Uint8Array | Buffer>

/**
 * Default ranged reader over `node:fs/promises`.
 *
 * It opens the file read-only and loops `FileHandle.read` until the requested
 * window is filled or EOF is reached, so a caller never materialises bytes
 * outside the window. Only used when the active `node:fs` face exposes
 * `open`; the pinned Worker runtime's replacement may not, in which case the
 * adapter advertises no ranged reader and consumers apply their own explicit
 * fallback bound instead of silently reading a whole large file.
 * @param path - real path below the adapter root.
 * @param start - byte offset to start at.
 * @param length - maximum bytes to read.
 * @returns the bytes available in the window.
 */
async function defaultReadFileRange(path: string, start: number, length: number): Promise<Uint8Array> {
  if (length === 0) return new Uint8Array(0)
  const handle = await fsp.open(path, 'r')
  try {
    const buffer = Buffer.alloc(length)
    let offset = 0
    while (offset < length) {
      const { bytesRead } = await handle.read(buffer, offset, length - offset, start + offset)
      if (bytesRead === 0) break
      offset += bytesRead
    }
    return buffer.subarray(0, offset)
  } finally {
    await handle.close()
  }
}

/** Options for {@link VfsFileSystem}. */
export interface VfsFileSystemOptions {
  /**
   * Real filesystem directory the virtual root `/` maps to. `''` or `'/'`
   * means "every virtual path is already a real path", which is the Worker
   * case because the runtime's `node:fs` is the VFS itself.
   */
  root?: string
  /**
   * Post-write single-file bound. Defaults to the environment's
   * `PDSH_SINGLE_FILE_LIMIT_BYTES` when present, else the budget owner's
   * {@link MAX_FILE_SIZE} (the value `configureSingleFileLimit` applied).
   * Writes above it fail with `EFBIG` before `node:fs` runs.
   */
  maxFileSize?: number
  /**
   * Maximum bytes a read surface returns; larger files fail with `EFBIG` and
   * the shared `pdsh-shell:` trailer. Defaults to the active single-file budget,
   * so the read cap follows the single-file budget rather than the 15 MiB
   * mutation bound.
   */
  maxFileReadSize?: number
  /**
   * Promise face used for every filesystem call; defaults to
   * `node:fs/promises`. Tests inject the Worker VFS so the real shell and the
   * real sink run against an in-memory tree.
   */
  nodeFs?: VfsFileSystemIo
  /** Sync directory reader for {@link VfsFileSystem.getAllPaths}; defaults to `node:fs`. */
  readdirSync?: VfsReaddirSync
  /**
   * Enable the Worker POSIX path aliases ({@link WORKER_PATH_ALIASES},
   * currently exactly `/tmp` -> `/dsh/tmp`).
   *
   * Defaults to `true` for the Worker's virtual root (`''` or `'/'`, where
   * `node:fs` is the runtime `MemoryVfs`) and to `false` for a real directory
   * root, so desktop simulation and tests keep verbatim POSIX behaviour unless
   * they opt in. An explicit `aliases` table wins over this flag.
   */
  workerPaths?: boolean
  /**
   * Explicit alias table replacing the Worker default. Validated at
   * construction: the source must be exactly `/tmp`, both endpoints must be
   * absolute and normalised, the target must be inside `/dsh`, and entries
   * must not overlap.
   */
  aliases?: readonly VfsPathAlias[]
}

/** Node error shape the runtime VFS and `node:fs` both use. */
type CodedError = Error & { code?: string; path?: string; syscall?: string }

/**
 * True when `path` is `root` itself or lies below it; both are normalised
 * absolute paths.
 * @param root - candidate ancestor.
 * @param path - candidate descendant.
 * @returns whether the descendant relation holds.
 */
function isWithin(root: string, path: string): boolean {
  return path === root || path.startsWith(`${root}/`)
}

/** True when a virtual path is one of the writable Worker roots. */
function isWritableRoot(path: string): boolean {
  return WORKER_WRITABLE_ROOTS.some(root => isWithin(root, path))
}

/**
 * Validate one alias endpoint: absolute, normalised, not the virtual root.
 * @param value - configured endpoint.
 * @param field - which endpoint, for the error message.
 * @returns the normalised endpoint.
 * @throws {TypeError} when the endpoint cannot be used as a prefix.
 */
function aliasEndpoint(value: unknown, field: 'from' | 'to'): string {
  if (typeof value !== 'string' || !value.startsWith('/')) {
    throw new TypeError(`VfsFileSystem: alias ${field} must be an absolute path, got ${JSON.stringify(value)}`)
  }
  if (value.includes('\0')) throw new TypeError(`VfsFileSystem: alias ${field} contains a NUL byte`)
  const normalised = posix.normalize(value)
  if (normalised.length > 1 && normalised.endsWith('/')) {
    throw new TypeError(`VfsFileSystem: alias ${field} ${JSON.stringify(value)} must not end with '/'`)
  }
  if (normalised !== value) {
    throw new TypeError(
      `VfsFileSystem: alias ${field} ${JSON.stringify(value)} must be normalised (${JSON.stringify(normalised)})`,
    )
  }
  if (normalised === '/') throw new TypeError(`VfsFileSystem: alias ${field} cannot be the virtual root`)
  return normalised
}

/**
 * Validate and freeze an alias table.
 *
 * The contract bridges exactly one POSIX root: `/tmp` onto the volatile tmp
 * root the image ships. A different source, a source inside `/dsh`, or a
 * target outside `/dsh` would redirect one of the contract roots instead, so
 * every one of them is a configuration error.
 * @param aliases - configured table.
 * @returns a frozen copy with the same order.
 * @throws {TypeError} on a relative, unnormalised, non-`/tmp`, overlapping or out-of-contract entry.
 */
function validateAliases(aliases: readonly VfsPathAlias[]): readonly VfsPathAlias[] {
  if (!Array.isArray(aliases)) throw new TypeError('VfsFileSystem: aliases must be an array')
  const validated: VfsPathAlias[] = []
  for (const alias of aliases) {
    if (typeof alias !== 'object' || alias === null) {
      throw new TypeError('VfsFileSystem: every alias must be a { from, to } object')
    }
    const from = aliasEndpoint(alias.from, 'from')
    const to = aliasEndpoint(alias.to, 'to')
    if (from !== WORKER_TMP_ALIAS.from) {
      throw new TypeError(
        `VfsFileSystem: only ${JSON.stringify(WORKER_TMP_ALIAS.from)} may be bridged, got ${JSON.stringify(from)}`,
      )
    }
    if (to === '/dsh' || !to.startsWith('/dsh/')) {
      throw new TypeError(`VfsFileSystem: alias target ${JSON.stringify(to)} must be a path inside the contract root /dsh`)
    }
    for (const seen of validated) {
      if (isWithin(seen.from, from) || isWithin(from, seen.from)) {
        throw new TypeError(`VfsFileSystem: alias source ${JSON.stringify(from)} overlaps ${JSON.stringify(seen.from)}`)
      }
    }
    validated.push(Object.freeze({ from, to }))
  }
  return Object.freeze(validated)
}

/**
 * Resolve one normalised virtual path through the alias table.
 *
 * Validation allows one source (`/tmp`) with no overlapping target, so the
 * first matching entry is the only possible match and one pass is enough.
 * @param path - normalised absolute virtual path.
 * @param aliases - validated alias table.
 * @returns the mapped virtual path (the input when no alias matches).
 */
function applyAliases(path: string, aliases: readonly VfsPathAlias[]): string {
  for (const alias of aliases) {
    if (path === alias.from) return alias.to
    if (path.startsWith(`${alias.from}/`)) return `${alias.to}${path.slice(alias.from.length)}`
  }
  return path
}

/** One virtual path, its alias-mapped form and the real path below the root. */
interface ResolvedVfsPath {
  /** Normalised virtual path the caller named (what errors report). */
  readonly virtual: string
  /** Alias-mapped contract path; the writable-root check uses this. */
  readonly mapped: string
  /** `root + mapped`, the path handed to `node:fs`. */
  readonly real: string
}

/**
 * Generate the bounded `/dev/urandom` read window from the platform crypto
 * source, chunk by chunk (the Web Crypto API caps one call at 65536 bytes).
 * @param path - virtual device path for the failure message.
 * @returns {@link WORKER_DEVICE_READ_BYTES} random bytes.
 * @throws {CodedError} `ENOSYS` when the Worker has no `crypto.getRandomValues`.
 */
function randomDeviceBytes(path: string): Uint8Array {
  const crypto = (globalThis as { crypto?: { getRandomValues?: (array: Uint8Array) => Uint8Array } }).crypto
  if (crypto?.getRandomValues === undefined) {
    throw errno('ENOSYS', 'no crypto.getRandomValues available to serve /dev/urandom', path)
  }
  const bytes = new Uint8Array(WORKER_DEVICE_READ_BYTES)
  for (let offset = 0; offset < bytes.byteLength; offset += CRYPTO_RANDOM_CHUNK_BYTES) {
    const chunk = bytes.subarray(offset, Math.min(offset + CRYPTO_RANDOM_CHUNK_BYTES, bytes.byteLength))
    crypto.getRandomValues(chunk)
  }
  return bytes
}

/**
 * Build one `ERRNO`-shaped error whose message starts with the code, which is
 * the convention just-bash's command error handling recognises.
 * @param code - Node error code.
 * @param message - human-readable detail.
 * @param path - offending path.
 * @returns the error.
 */
function errno(code: string, message: string, path: string): CodedError {
  return Object.assign(new Error(`${code}: ${message}, '${path}'`), { code, path })
}

/** Re-throw a Node error unchanged when it already carries a code. */
function rethrow(error: unknown): never {
  if (error instanceof Error) throw error
  throw new Error(String(error))
}

/** Map one `node:fs` stat to just-bash's `FsStat`. */
function statOf(stats: Stats): FsStat {
  // just-bash's same-file checks (`cp`, `mv`, `[ -ef ]`) need a stable
  // identity; Node's device/inode pair is exactly that.
  const { dev, ino } = stats
  return {
    isFile: stats.isFile(),
    isDirectory: stats.isDirectory(),
    isSymbolicLink: stats.isSymbolicLink(),
    // The VFS stores permission bits only; Node also sets the file-type bits.
    mode: stats.mode & 0o7777,
    size: stats.size,
    mtime: stats.mtime,
    // The Worker's MemoryVfs stats carry `ino` but not Node's `dev`; the whole
    // image is one virtual device, so a stable `dev` keeps the identity usable.
    dev: dev ?? 0,
    ino,
  }
}

/** Decode a just-bash encoding option into a Node buffer encoding. */
function encodingOf(options: ReadFileOptions | WriteFileOptions | string | null | undefined): BufferEncoding | undefined {
  if (options === undefined || options === null) return undefined
  if (typeof options === 'string') return options as BufferEncoding
  return options.encoding as BufferEncoding | undefined
}

/**
 * Bytes a write stores for one just-bash `FileContent` and encoding, counted
 * conservatively.
 *
 * On a real directory `node:fs` applies the declared encoding
 * (`binary`/`latin1`/`ascii` = one byte per code unit, `base64`/`hex` decode,
 * UTF-8 otherwise). Inside the Worker the runtime's `node:fs` proxy ignores a
 * string encoding and its `MemoryVfs` stores the UTF-8 encoding of the string;
 * the maximum of the two counts is therefore the only value that can never
 * under-estimate the mutation the sink will see. The common UTF-8 path stays a
 * copy-free `Buffer.byteLength`.
 * @param content - text or bytes the shell handed to the adapter.
 * @param encoding - declared text encoding, if any.
 * @returns the stored byte length bound.
 */
function contentByteLength(content: FileContent, encoding: BufferEncoding | undefined): number {
  if (typeof content !== 'string') return content.byteLength
  const utf8 = Buffer.byteLength(content, 'utf8')
  switch (encoding) {
    case undefined:
    case 'utf8':
    case 'utf-8':
      return utf8
    case 'ascii':
    case 'binary':
    case 'latin1':
      return Math.max(content.length, utf8)
    default:
      return Math.max(Buffer.from(content, encoding).byteLength, utf8)
  }
}

/**
 * Collapse a hint to one line so the trailer grammar stays parseable.
 * @param text - multi-line candidate.
 * @returns the single-line form.
 */
function oneLine(text: string): string {
  return text.replace(/[\r\n]+/gu, ' ').trim()
}

/**
 * Build the `EFBIG` a command sees for a write whose post-write file would
 * exceed the single-file limit. The message names the byte limit and its MiB
 * spelling — both rendered from `limit` by the shared budget owner — so a
 * model can quote it without another probe and can never see a label that
 * disagrees with the enforced value.
 * @param path - virtual target path.
 * @param wouldBe - post-write byte length.
 * @param limit - active single-file bound.
 * @returns the refusal error (never thrown here; callers `throw` it).
 */
function oversizeRefusal(path: string, wouldBe: number, limit: number): CodedError {
  return errno(
    'EFBIG',
    `File too large: ${path} would be ${wouldBe} bytes; a file is limited to ${formatByteLimit(limit)}`,
    path,
  )
}

/**
 * Build the `EFBIG` a command sees when a read would pull a whole file over
 * the read cap into one result. The message ends in the shared `pdsh-shell:`
 * trailer with a hint that points at chunked reads, so the model gets a
 * self-healing instruction instead of a bare errno.
 * @param path - virtual source path.
 * @param size - current file size in bytes.
 * @param limit - active read cap.
 * @returns the refusal error (never thrown here; callers `throw` it).
 */
function readRefusal(path: string, size: number, limit: number): CodedError {
  const hint = oneLine(
    `${path} is ${String(size)} bytes, over the ${formatByteLimit(limit)} read cap; `
      + 'read it in chunks (head/tail/sed -n, or python3 with seek/read)',
  )
  const error = new Error(
    `EFBIG: File too large: ${path} would be ${String(size)} bytes; a single read is limited to `
      + `${formatByteLimit(limit)}\n`
      + trailerLine({ exitCode: 1, program: 'vfs', reason: 'limit-refused', hint }),
  ) as CodedError
  error.code = 'EFBIG'
  error.path = path
  error.syscall = 'read'
  return error
}

/** Validate one byte-limit option. */
function byteLimit(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`VfsFileSystem: ${field} must be a non-negative safe integer, got ${String(value)}`)
  }
  return value
}

/**
 * `IFileSystem` over `node:fs`, rooted at a real directory.
 *
 * Every member resolves its virtual path through the alias table and then
 * prefixes {@link realRoot}; the mapping stays synchronous from the command's
 * point of view, so a mutation is visible to the runtime's VFS sink
 * synchronously: the sink subscription fires on the `MemoryVfs` write itself.
 *
 * `writeFile` and `appendFile` enforce the active single-file budget here,
 * before `node:fs` runs: the runtime's `MemoryVfs` publishes a mutation
 * synchronously inside the write and swallows observer failures, so a guard on
 * the sink side can only close the channel after the bytes are already in the
 * Worker tree. Refusing at this surface turns the over-limit write into the
 * command's own `EFBIG` (non-zero exit, `File too large`, the exact limit) and
 * leaves the ordered channel usable.
 */
export class VfsFileSystem implements IFileSystem {
  private readonly root: string
  private readonly maxFileSizeBytes: number
  private readonly maxFileReadSize: number
  private readonly aliases: readonly VfsPathAlias[]
  private readonly nodeFs: VfsFileSystemIo
  private readonly rangeReader: VfsFileRangeReader | undefined
  private readonly syncReaddir: VfsReaddirSync
  /**
   * Synthetic command entry points (`/usr/bin/<name>`, `/bin/<name>`) served
   * from memory; see {@link registerCommandNames}. No file is created, so the
   * tree below the VFS root and `getAllPaths()` keep only real entries.
   */
  private commandEntries: ReadonlyMap<string, string> | undefined
  private commandDirectories: ReadonlyMap<string, readonly string[]> | undefined

  /**
   * @param options - real root directory, read cap, I/O face and Worker path aliases.
   */
  constructor(options: VfsFileSystemOptions = {}) {
    const root = options.root ?? ''
    if (root !== '' && root !== '/' && !posix.isAbsolute(root)) {
      throw new TypeError(`VfsFileSystem: root must be absolute or empty, got ${JSON.stringify(root)}`)
    }
    this.root = root === '/' ? '' : root.replace(/\/+$/, '')
    const envLimit = options.maxFileSize === undefined ? singleFileLimitFromEnvironment() : undefined
    this.maxFileSizeBytes = byteLimit(options.maxFileSize ?? envLimit ?? MAX_FILE_SIZE, 'maxFileSize')
    this.maxFileReadSize = byteLimit(options.maxFileReadSize ?? this.maxFileSizeBytes, 'maxFileReadSize')
    this.nodeFs = options.nodeFs ?? (fsp as unknown as VfsFileSystemIo)
    const injectedRange = options.nodeFs?.readFileRange
    const defaultRangeAvailable = options.nodeFs === undefined
      && typeof (fsp as unknown as { open?: unknown }).open === 'function'
    this.rangeReader = injectedRange !== undefined
      ? injectedRange.bind(options.nodeFs)
      : defaultRangeAvailable ? defaultReadFileRange : undefined
    this.syncReaddir = options.readdirSync ?? readdirSync
    // The Worker's virtual root is the only configuration where `node:fs` is
    // the runtime MemoryVfs (the image has no POSIX `/tmp`). A real directory
    // root keeps verbatim behaviour unless the caller opts in.
    const workerRoot = this.root === ''
    const aliases = options.aliases ?? ((options.workerPaths ?? workerRoot) ? WORKER_PATH_ALIASES : [])
    this.aliases = validateAliases(aliases)
  }

  /** Real directory backing virtual `/`. */
  get realRoot(): string { return this.root === '' ? '/' : this.root }

  /**
   * Active single-file budget in bytes: the exact value every write check
   * enforces and every refusal renders.
   *
   * The shell reads it to name the budget in its `limit-refused` trailer, so
   * the diagnostic and the check cannot disagree.
   */
  get maxFileSize(): number { return this.maxFileSizeBytes }

  /** Validated alias table in effect (introspection for diagnostics). */
  get pathAliases(): readonly VfsPathAlias[] { return this.aliases }

  /**
   * Resolve a relative path against a virtual base path.
   * @param base - absolute virtual base.
   * @param path - absolute or relative virtual path.
   * @returns an absolute, normalised virtual path.
   */
  resolvePath(base: string, path: string): string {
    return posix.resolve(base, path)
  }

  /**
   * Normalise one virtual path, rejecting anything but an absolute path.
   * @param path - virtual path.
   * @returns the normalised absolute virtual path.
   */
  private normaliseVirtual(path: string): string {
    if (typeof path !== 'string' || !path.startsWith('/')) {
      throw errno('EINVAL', 'path must be absolute', String(path))
    }
    const normalised = posix.normalize(path)
    if (!normalised.startsWith('/')) throw errno('EINVAL', 'path escapes the virtual root', path)
    return normalised
  }

  /**
   * Resolve a virtual path to its contract form and its real `node:fs` path.
   * @param path - virtual absolute path.
   * @returns the virtual, alias-mapped and real forms.
   */
  private resolve(path: string): ResolvedVfsPath {
    const virtual = this.normaliseVirtual(path)
    const mapped = applyAliases(virtual, this.aliases)
    return { virtual, mapped, real: `${this.root}${mapped}` }
  }

  /**
   * Map a virtual path to the real path below {@link realRoot}.
   * @param path - virtual absolute path.
   * @returns the real filesystem path.
   */
  private toReal(path: string): string {
    return this.resolve(path).real
  }

  /**
   * Re-throw a failed write, adding one remediation line when the target is
   * outside the writable Worker roots.
   *
   * The code, syscall and the virtual path are preserved; the original error
   * becomes the `cause`. Nothing is swallowed and no target is rewritten.
   * @param error - error from `node:fs`.
   * @param resolved - the path the adapter resolved.
   */
  private rethrowWrite(error: unknown, resolved: ResolvedVfsPath): never {
    if (!(error instanceof Error)) rethrow(error)
    const coded = error as CodedError
    const code = coded.code
    if ((code === 'ENOENT' || code === 'EACCES') && !isWritableRoot(resolved.mapped)) {
      const roots = WORKER_WRITABLE_ROOTS.join(', ')
      const hint = `pdsh-shell: writable roots are ${roots} (TMPDIR=${WORKER_TMP_ALIAS.to})`
      throw Object.assign(new Error(`${coded.message}\n${hint}`, { cause: error }), {
        code,
        path: resolved.virtual,
        syscall: coded.syscall,
      })
    }
    throw error
  }

  /**
   * The descriptor when `path` names a virtual device from
   * {@link WORKER_DEVICE_PATHS}, otherwise `undefined`.
   * @param path - virtual path.
   * @returns the fixed device entry, or undefined for a normal path.
   */
  private device(path: string): WorkerDeviceDescriptor | undefined {
    if (typeof path !== 'string' || !path.startsWith('/')) return undefined
    return WORKER_DEVICES.get(posix.normalize(path))
  }

  /**
   * True when `path` names a virtual device from {@link WORKER_DEVICE_PATHS}.
   * @param path - virtual path.
   * @returns whether the adapter answers the path itself instead of `node:fs`.
   */
  private isDevice(path: string): boolean {
    return this.device(path) !== undefined
  }

  /**
   * Produce one read of a virtual device.
   *
   * The window is fixed and bounded for every device that produces data; the
   * three `IFileSystem` read surfaces all call this one function so their
   * lengths cannot diverge. Random bytes come from the platform crypto source
   * in 64 KiB chunks; a Worker without one fails loud instead of substituting
   * a predictable generator.
   * @param path - virtual device path (named in the failure).
   * @param descriptor - the device's read behavior.
   * @returns the device bytes for one read.
   * @throws {CodedError} `ENOSYS` when `/dev/urandom` has no crypto source.
   */
  private deviceReadBytes(path: string, descriptor: WorkerDeviceDescriptor): Uint8Array {
    switch (descriptor.read) {
      case 'empty':
        return new Uint8Array(0)
      case 'zero':
        return new Uint8Array(WORKER_DEVICE_READ_BYTES)
      case 'random':
        return randomDeviceBytes(path)
    }
  }

  /** The fixed metadata of a virtual character device. */
  private deviceStat(path: string): FsStat {
    return {
      isFile: false,
      isDirectory: false,
      isSymbolicLink: false,
      mode: CHARACTER_DEVICE_MODE,
      size: 0,
      mtime: new Date(0),
      // A stable identity lets just-bash's same-file checks (`cp`, `mv`,
      // `[ -ef ]`) answer "different" instead of "unknown".
      identity: `device:${posix.normalize(path)}`,
    }
  }

  /**
   * Register the shell's command table as virtual `PATH` entry points.
   *
   * just-bash resolves a registered command through the filesystem and falls
   * back to a fabricated `/usr/bin/<name>` when no file matches, so a shell
   * with a bare `PATH` lies about where a command lives (G2-A05). Writing
   * ~90 files into the Worker VFS on every shell start would pollute the tree
   * (and every `find /`), so the adapter answers these entries itself, exactly
   * like the fixed `/dev/null` device: they exist for `exists`/`stat`/`read`
   * and the `PATH` search, but never appear in `getAllPaths()` or below the
   * real root. `command -v X` can therefore only return a path that exists, and
   * executing it reaches the registered command through just-bash's
   * `/usr/bin/<name>` identity rule.
   * @param names - command names the shell serves.
   */
  registerCommandNames(names: readonly string[]): void {
    const entries = new Map<string, string>()
    const usrBin: string[] = []
    const bin: string[] = []
    for (const name of [...new Set(names)].sort()) {
      if (!/^[A-Za-z0-9_+.-]+$/u.test(name)) continue
      const content = `#!/bin/bash\n# Built-in command: ${name}\n`
      entries.set(`/usr/bin/${name}`, content)
      usrBin.push(name)
      if (name === 'bash' || name === 'sh') {
        entries.set(`/bin/${name}`, content)
        bin.push(name)
      }
    }
    this.commandEntries = entries
    this.commandDirectories = new Map([
      ['/usr/bin', usrBin],
      ['/bin', bin],
    ])
  }

  /**
   * Record a command registration just-bash performs during `Bash`
   * construction.
   *
   * just-bash registers every bundled command by writing `/bin/<name>` and
   * `/usr/bin/<name>` through `IFileSystem.writeFileSync`; implementing the
   * sync hook (rather than pre-seeding a name list) means the virtual `PATH`
   * entries are exactly the commands this bundle actually instantiated —
   * browser-excluded names (`tar`, `python3`, `sqlite3`, ...) never get an
   * executable entry they cannot run. Anything outside those two directories
   * keeps the ordinary real write.
   * @param path - virtual path.
   * @param data - file contents.
   * @param options - Node write options (`mode`, `flag`).
   */
  writeFileSync(path: string, data: string | Uint8Array, options?: { mode?: number; flag?: string }): void {
    const normalised = posix.normalize(path)
    // A sync write to a device is the same sink: discard before node:fs.
    if (this.isDevice(normalised)) return
    const match = /^\/(usr\/)?bin\/([A-Za-z0-9_+.-]+)$/u.exec(normalised)
    if (match !== null) {
      const name = match[2] as string
      // The capture distinguishes `/usr/bin/<name>` from `/bin/<name>`.
      const inBinDirectory = match[1] === undefined
      if (inBinDirectory && name !== 'bash' && name !== 'sh') return
      const content = typeof data === 'string' ? data : new TextDecoder().decode(data)
      const entries = new Map(this.commandEntries ?? [])
      entries.set(`/usr/bin/${name}`, content)
      const directories = new Map(this.commandDirectories ?? [])
      const usrBin = new Set(directories.get('/usr/bin') ?? [])
      usrBin.add(name)
      directories.set('/usr/bin', [...usrBin].sort())
      if (name === 'bash' || name === 'sh') {
        const bin = new Set(directories.get('/bin') ?? [])
        bin.add(name)
        directories.set('/bin', [...bin].sort())
        entries.set(`/bin/${name}`, content)
      }
      this.commandEntries = entries
      this.commandDirectories = directories
      return
    }
    writeFileSyncNode(this.toReal(path), data, options)
  }

  /** Names in a synthetic command directory, or undefined for any other path. */
  private virtualDirectory(path: string): readonly string[] | undefined {
    return this.commandDirectories?.get(posix.normalize(path))
  }

  /** Content of a synthetic command entry, or undefined for a real path. */
  private virtualEntry(path: string): string | undefined {
    return this.commandEntries?.get(posix.normalize(path))
  }

  /** Stat for one synthetic command directory. */
  private commandDirectoryStat(): FsStat {
    return {
      isFile: false,
      isDirectory: true,
      isSymbolicLink: false,
      mode: 0o040755,
      size: 0,
      mtime: new Date(0),
      dev: 0,
      ino: 0,
    }
  }

  /** Stat for one synthetic command entry (an executable regular file). */
  private commandEntryStat(path: string): FsStat {
    const content = this.virtualEntry(path) as string
    return {
      isFile: true,
      isDirectory: false,
      isSymbolicLink: false,
      mode: 0o100755,
      size: Buffer.byteLength(content, 'utf8'),
      mtime: new Date(0),
      dev: 0,
      ino: 0,
      identity: `command:${posix.normalize(path)}`,
    }
  }

  /**
   * Enforce the read cap before a whole-file read.
   *
   * The cap equals the active single-file budget, not the 15 MiB mutation
   * bound: a legal 60 MiB file can be read by a consumer that streams it, but
   * a surface that would pull the entire file into one result refuses with a
   * trailer that points at chunked reads.
   * @param real - real VFS path.
   * @param virtual - path named in the error.
   * @throws {CodedError} `EFBIG` with the `pdsh-shell:` trailer when too large.
   */
  private async checkReadSize(real: string, virtual: string): Promise<void> {
    const stats = await this.nodeFs.stat(real)
    if (stats.size > this.maxFileReadSize) {
      throw readRefusal(virtual, stats.size, this.maxFileReadSize)
    }
  }

  async readFile(path: string, options?: ReadFileOptions | string): Promise<string> {
    const encoding = encodingOf(options) ?? 'utf8'
    const device = this.device(path)
    if (device !== undefined) {
      const bytes = Buffer.from(this.deviceReadBytes(path, device))
      return encoding === undefined || encoding === 'utf8' || encoding === 'utf-8'
        ? bytes.toString('utf8')
        : bytes.toString(encoding)
    }
    const synthetic = this.virtualEntry(path)
    if (synthetic !== undefined) return synthetic
    const real = this.toReal(path)
    await this.checkReadSize(real, this.normaliseVirtual(path))
    const bytes = await this.nodeFs.readFile(real)
    return encoding === undefined || encoding === 'utf8' || encoding === 'utf-8'
      ? bytes.toString('utf8')
      : bytes.toString(encoding)
  }

  async readFileBytes(path: string): Promise<ByteString> {
    const device = this.device(path)
    if (device !== undefined) {
      return Buffer.from(this.deviceReadBytes(path, device)).toString('latin1') as unknown as ByteString
    }
    const synthetic = this.virtualEntry(path)
    if (synthetic !== undefined) return synthetic as unknown as ByteString
    const real = this.toReal(path)
    await this.checkReadSize(real, this.normaliseVirtual(path))
    const bytes = await this.nodeFs.readFile(real)
    return bytes.toString('latin1') as unknown as ByteString
  }

  async readFileBuffer(path: string): Promise<Uint8Array> {
    const device = this.device(path)
    if (device !== undefined) return this.deviceReadBytes(path, device)
    const synthetic = this.virtualEntry(path)
    if (synthetic !== undefined) return new TextEncoder().encode(synthetic)
    const real = this.toReal(path)
    await this.checkReadSize(real, this.normaliseVirtual(path))
    return new Uint8Array(await this.nodeFs.readFile(real))
  }

  /**
   * Whether {@link readFileBufferRange} can avoid a whole-file read.
   *
   * False when the injected `node:fs` face has no ranged reader (the pinned
   * Worker runtime's `MemoryVfs` bridge is the production case). Consumers
   * must then choose an explicit fallback bound; they must not call this
   * method as a synonym for a whole-file read.
   */
  get supportsRangedReads(): boolean { return this.rangeReader !== undefined }

  /**
   * Read only one byte window of a virtual file.
   *
   * Devices and synthetic command entries answer from their in-memory window.
   * A real file is read through the optional ranged `node:fs` face; when that
   * face has no seek primitive the method throws `ENOSYS` instead of silently
   * materialising the whole file. `length` is also capped by the active
   * single-read budget, so even an explicit `od -N` cannot pull more than the
   * adapter's read ceiling into this process.
   * @param path - virtual absolute path.
   * @param start - non-negative byte offset.
   * @param length - maximum bytes to return.
   * @returns the bytes available in the window (possibly shorter at EOF).
   */
  async readFileBufferRange(path: string, start: number, length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(start) || start < 0) {
      throw errno('EINVAL', 'range start must be a non-negative safe integer', String(start))
    }
    if (!Number.isSafeInteger(length) || length < 0) {
      throw errno('EINVAL', 'range length must be a non-negative safe integer', String(length))
    }
    if (length === 0) return new Uint8Array(0)
    const virtual = this.normaliseVirtual(path)
    const device = this.device(path)
    if (device !== undefined) return this.deviceReadBytes(path, device).subarray(start, start + length)
    const synthetic = this.virtualEntry(path)
    if (synthetic !== undefined) {
      return new TextEncoder().encode(synthetic).subarray(start, start + length)
    }
    if (length > this.maxFileReadSize) throw readRefusal(virtual, length, this.maxFileReadSize)
    if (this.rangeReader === undefined) {
      throw errno('ENOSYS', 'this filesystem has no ranged read', virtual)
    }
    return new Uint8Array(await this.rangeReader(this.toReal(path), start, length))
  }

  async writeFile(path: string, content: FileContent, options?: WriteFileOptions | string): Promise<void> {
    // A device is a sink: discard before any `node:fs` call, so no MemoryVfs
    // write happens and no VFS_MUT is emitted (PLAN D4).
    if (this.isDevice(path)) return
    const encoding = encodingOf(options)
    const resolved = this.resolve(path)
    // A complete write stores exactly this content; refuse it here so the
    // runtime VFS never publishes an over-limit mutation (D4).
    const bytes = contentByteLength(content, encoding)
    if (bytes > this.maxFileSizeBytes) throw oversizeRefusal(resolved.virtual, bytes, this.maxFileSizeBytes)
    try {
      await this.nodeFs.writeFile(resolved.real, content, encoding === undefined ? undefined : { encoding })
    } catch (error) {
      this.rethrowWrite(error, resolved)
    }
  }

  async appendFile(path: string, content: FileContent, options?: WriteFileOptions | string): Promise<void> {
    if (this.isDevice(path)) return
    const encoding = encodingOf(options)
    const resolved = this.resolve(path)
    // Two appends to the same target must not both pass the size check and
    // then jointly cross the limit: the stat and the write are one critical
    // section per real path. (A post-write check would be too late — the VFS
    // publishes the mutation inside `appendFile` and the sink guard would
    // already have closed the channel.)
    await this.serializeAppend(resolved.real, async () => {
      const addition = contentByteLength(content, encoding)
      // The post-write size is the existing file plus the suffix. Stat first:
      // `MemoryVfs` already holds the old bytes, and a failed write must not
      // publish the over-limit file on the way out.
      let existing: Stats | undefined
      try {
        existing = await this.nodeFs.stat(resolved.real)
      } catch (error) {
        if ((error as CodedError).code !== 'ENOENT') this.rethrowWrite(error, resolved)
      }
      if (existing?.isFile() === true) {
        // just-bash opens every `>>` target with an empty append; that is a
        // no-op and must not republish the whole existing file.
        if (addition === 0) return
        if (existing.size + addition > this.maxFileSizeBytes) {
          throw oversizeRefusal(resolved.virtual, existing.size + addition, this.maxFileSizeBytes)
        }
      } else if (existing === undefined && addition > this.maxFileSizeBytes) {
        throw oversizeRefusal(resolved.virtual, addition, this.maxFileSizeBytes)
      }
      try {
        await this.nodeFs.appendFile(resolved.real, content, encoding === undefined ? undefined : { encoding })
      } catch (error) {
        this.rethrowWrite(error, resolved)
      }
    })
  }

  /**
   * Run one append's stat→append sequence after every earlier append to the
   * same real path. Entries are removed when their queue drains, so a file
   * that is appended once leaves no state behind.
   * @param key - real target path.
   * @param run - the critical section.
   */
  private async serializeAppend<T>(key: string, run: () => Promise<T>): Promise<T> {
    const previous = appendTails.get(key) ?? Promise.resolve()
    const result = previous.then(run, run)
    const tail: Promise<void> = result.then(() => undefined, () => undefined)
    appendTails.set(key, tail)
    try {
      return await result
    } finally {
      if (appendTails.get(key) === tail) appendTails.delete(key)
    }
  }

  async exists(path: string): Promise<boolean> {
    if (this.isDevice(path)) return true
    if (this.virtualDirectory(path) !== undefined || this.virtualEntry(path) !== undefined) return true
    try {
      await this.nodeFs.access(this.toReal(path))
      return true
    } catch {
      return false
    }
  }

  async stat(path: string): Promise<FsStat> {
    if (this.isDevice(path)) return this.deviceStat(path)
    if (this.virtualDirectory(path) !== undefined) return this.commandDirectoryStat()
    if (this.virtualEntry(path) !== undefined) return this.commandEntryStat(path)
    return statOf(await this.nodeFs.stat(this.toReal(path)))
  }

  async lstat(path: string): Promise<FsStat> {
    if (this.isDevice(path)) return this.deviceStat(path)
    if (this.virtualDirectory(path) !== undefined) return this.commandDirectoryStat()
    if (this.virtualEntry(path) !== undefined) return this.commandEntryStat(path)
    return statOf(await this.nodeFs.lstat(this.toReal(path)))
  }

  async mkdir(path: string, options?: MkdirOptions): Promise<void> {
    if (this.isDevice(path)) throw errno('EEXIST', 'device file already exists', path)
    const resolved = this.resolve(path)
    try {
      await this.nodeFs.mkdir(resolved.real, options)
    } catch (error) {
      this.rethrowWrite(error, resolved)
    }
  }

  async createExclusive(path: string, options: CreateExclusiveOptions): Promise<void> {
    if (this.isDevice(path)) throw errno('EEXIST', 'device file already exists', path)
    const resolved = this.resolve(path)
    try {
      if (options.directory === true) await this.nodeFs.mkdir(resolved.real, { mode: options.mode })
      else await this.nodeFs.writeFile(resolved.real, new Uint8Array(0), { flag: 'wx', mode: options.mode })
    } catch (error) {
      this.rethrowWrite(error, resolved)
    }
  }

  async readdir(path: string): Promise<string[]> {
    if (this.isDevice(path)) throw errno('ENOTDIR', 'not a directory', path)
    const synthetic = this.virtualDirectory(path)
    if (synthetic !== undefined) return [...synthetic]
    return await this.nodeFs.readdir(this.toReal(path)) as string[]
  }

  async readdirWithFileTypes(path: string): Promise<DirentEntry[]> {
    if (this.isDevice(path)) throw errno('ENOTDIR', 'not a directory', path)
    const synthetic = this.virtualDirectory(path)
    if (synthetic !== undefined) {
      return synthetic.map(name => ({ name, isFile: true, isDirectory: false, isSymbolicLink: false }))
    }
    const entries = await this.nodeFs.readdir(this.toReal(path), { withFileTypes: true }) as VfsDirentLike[]
    return entries.map(entry => ({
      name: entry.name,
      isFile: entry.isFile(),
      isDirectory: entry.isDirectory(),
      isSymbolicLink: entry.isSymbolicLink(),
    }))
  }

  async rm(path: string, options?: RmOptions): Promise<void> {
    if (this.isDevice(path)) throw errno('EPERM', 'cannot remove a virtual device', path)
    const real = this.toReal(path)
    const recursive = options?.recursive === true
    const force = options?.force === true
    try {
      if (!recursive) {
        const stats = await this.nodeFs.lstat(real)
        if (stats.isDirectory()) {
          // `rmdir` calls `rm` without `recursive`. The pinned Worker runtime's
          // `node:fs` replacement implements `rm`/`unlink` but has no
          // `rmdir`/`rmdirSync` (G2-FIX-64), so the one empty directory is
          // removed through the implemented recursive face after proving it is
          // empty: a populated tree stays untouched and fails ENOTEMPTY, as
          // POSIX `rm` without `-r` requires.
          const entries = await this.nodeFs.readdir(real)
          if (entries.length > 0) throw errno('ENOTEMPTY', 'directory not empty', path)
          await this.nodeFs.rm(real, { recursive: true })
          return
        }
      }
      await this.nodeFs.rm(real, { recursive, force })
    } catch (error) {
      const code = (error as CodedError).code
      if (force && code === 'ENOENT') return
      rethrow(error)
    }
  }

  async cp(src: string, dest: string, options?: CpOptions): Promise<void> {
    const sourceDevice = this.device(src)
    const destDevice = this.device(dest)
    if (sourceDevice !== undefined && destDevice !== undefined) return
    if (destDevice !== undefined) {
      // The destination is a sink; still fail loud when the source is missing
      // or is a directory, exactly as a normal copy would.
      const stats = await this.nodeFs.stat(this.toReal(src))
      if (stats.isDirectory()) throw errno('EISDIR', 'cannot copy a directory onto a device', src)
      return
    }
    if (sourceDevice !== undefined) {
      // Copying a device stores exactly one bounded read, so `/dev/null`
      // stays empty and `/dev/zero`/`/dev/urandom` are finite files.
      const bytes = this.deviceReadBytes(src, sourceDevice)
      if (bytes.byteLength > this.maxFileSizeBytes) {
        throw oversizeRefusal(this.resolve(dest).virtual, bytes.byteLength, this.maxFileSizeBytes)
      }
      await this.nodeFs.writeFile(this.toReal(dest), bytes)
      return
    }
    // A copied regular file is a whole-file write at the destination; refuse a
    // source that cannot fit one D4 mutation before `cp` starts streaming it.
    const source = await this.nodeFs.stat(this.toReal(src))
    if (source.isFile() && source.size > this.maxFileSizeBytes) {
      throw oversizeRefusal(this.resolve(dest).virtual, source.size, this.maxFileSizeBytes)
    }
    await this.nodeFs.cp(this.toReal(src), this.toReal(dest), { recursive: options?.recursive === true })
  }

  async mv(src: string, dest: string): Promise<void> {
    if (this.isDevice(src) || this.isDevice(dest)) {
      throw errno('EPERM', 'cannot move a virtual device', this.isDevice(src) ? src : dest)
    }
    await this.nodeFs.rename(this.toReal(src), this.toReal(dest))
  }

  async chmod(path: string, mode: number): Promise<void> {
    // A device's mode is virtual and fixed; forwarding would hit `node:fs`.
    if (this.isDevice(path)) return
    if (this.virtualEntry(path) !== undefined || this.virtualDirectory(path) !== undefined) return
    await this.nodeFs.chmod(this.toReal(path), mode)
  }

  async symlink(_target: string, linkPath: string): Promise<void> {
    throw errno('EPERM', 'the Worker VFS is symlink-free', linkPath)
  }

  async link(existingPath: string, newPath: string): Promise<void> {
    if (this.isDevice(existingPath) || this.isDevice(newPath)) {
      throw errno('EPERM', 'cannot hard-link a virtual device', this.isDevice(existingPath) ? existingPath : newPath)
    }
    await this.nodeFs.link(this.toReal(existingPath), this.toReal(newPath))
  }

  async readlink(path: string): Promise<string> {
    throw errno('EINVAL', 'the Worker VFS is symlink-free', path)
  }

  async realpath(path: string): Promise<string> {
    return posix.normalize(path.startsWith('/') ? path : `/${path}`)
  }

  async utimes(path: string, atime: Date, mtime: Date): Promise<void> {
    // Device timestamps are virtual and fixed; forwarding would hit node:fs.
    if (this.isDevice(path)) return
    // The runtime VFS keeps mtimes virtual and its `node:fs` face has no
    // `utimes`; a timestamp update is a no-op there rather than a hard error.
    if (this.nodeFs.utimes === undefined) return
    try {
      await this.nodeFs.utimes(this.toReal(path), atime, mtime)
    } catch (error) {
      rethrow(error)
    }
  }

  /**
   * Every virtual path in the tree, once (used by just-bash's glob matcher).
   *
   * An alias is a resolution, not a second entry: the walk lists the real
   * `/dsh/tmp/**` paths and never synthesizes a duplicate `/tmp/**` view.
   * @returns the absolute virtual paths below `/`.
   */
  getAllPaths(): string[] {
    const paths: string[] = []
    const walk = (virtual: string): void => {
      let entries
      try {
        entries = this.syncReaddir(this.toReal(virtual), { withFileTypes: true })
      } catch {
        return
      }
      for (const entry of entries) {
        const child = posix.join(virtual, entry.name)
        paths.push(child)
        if (entry.isDirectory()) walk(child)
      }
    }
    walk('/')
    return paths
  }
}

export default VfsFileSystem
