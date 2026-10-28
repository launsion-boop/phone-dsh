// SPDX-License-Identifier: MIT
/**
 * The filesystem face git runs on.
 *
 * Inside the DSH phone Worker `node:fs` is the runtime's in-memory VFS, so the
 * git program calls it directly: a `git add` or `git commit` is an ordinary
 * VFS mutation that reaches the WAL sink at the next `mseq` (PLAN D12 — no
 * writing command leaves the Worker). Outside the Worker the same adapter runs
 * on a real temporary directory, which is how the tests compare byte-for-byte
 * against the system git.
 *
 * Only promise members the runtime's `node:fs/promises` shim implements are
 * used: `readFile`, `writeFile`, `appendFile`, `mkdir`, `readdir`, `stat`,
 * `lstat`, `realpath`, `rm`, `rename`, `chmod` and `open`. Symlinks and
 * `readlink` do not exist in the Worker image; those members answer `ENOSYS`
 * instead of pretending.
 * @module @phone-dsh/dsh-wasi-toolbox/git/fs
 */

import { promises as fsp } from 'node:fs'
import type { Stats } from 'node:fs'
import { posix } from 'node:path'
import { WORKER_VFS_NAMESPACE, type VfsNamespace } from '../src/vfs-namespace.ts'

/** One `stat` result in the shape git needs. */
export interface GitStat {
  readonly isFile: boolean
  readonly isDirectory: boolean
  readonly isSymbolicLink: boolean
  /** Permission and file-type bits as Node reports them (`0o100644`, ...). */
  readonly mode: number
  readonly size: number
  readonly mtimeMs: number
  readonly ctimeMs: number
  readonly device: number
  readonly ino: number
  readonly uid: number
  readonly gid: number
}

/** One directory entry. */
export interface GitDirent {
  readonly name: string
  readonly isFile: boolean
  readonly isDirectory: boolean
  readonly isSymbolicLink: boolean
}

/** The filesystem subset this git implementation needs. */
export interface GitFs {
  readFile(path: string): Promise<Uint8Array>
  writeFile(path: string, data: Uint8Array | string, mode?: number): Promise<void>
  appendFile(path: string, data: Uint8Array | string): Promise<void>
  mkdir(path: string, recursive?: boolean): Promise<void>
  readdir(path: string): Promise<GitDirent[]>
  stat(path: string): Promise<GitStat>
  lstat(path: string): Promise<GitStat>
  rm(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  realpath(path: string): Promise<string>
  exists(path: string): Promise<boolean>
  /** Read `[start, end)` from one file; `end === 0` means end-of-file. */
  readFileSlice(path: string, start: number, end: number): Promise<Uint8Array>
  readlink?(path: string): Promise<string>
  symlink?(target: string, path: string): Promise<void>
  utimes?(path: string, atimeMs: number, mtimeMs: number): Promise<void>
}

/** Node error shape (the runtime VFS and `node:fs` both use it). */
interface CodedError extends Error {
  code?: string
}

/** Build an errno-shaped error the caller can test through {@link isErrno}. */
export function fsError(code: string, message: string, path: string): Error {
  return Object.assign(new Error(`${code}: ${message}, '${path}'`), { code, path })
}

/** True when an error carries one of the given errno codes. */
export function isErrno(error: unknown, ...codes: readonly string[]): boolean {
  const code = (error as CodedError | undefined)?.code
  return code !== undefined && codes.includes(code)
}

function statOf(stats: Stats): GitStat {
  return {
    isFile: stats.isFile(),
    isDirectory: stats.isDirectory(),
    isSymbolicLink: stats.isSymbolicLink(),
    mode: stats.mode,
    size: stats.size,
    mtimeMs: stats.mtimeMs,
    ctimeMs: stats.ctimeMs,
    device: stats['dev'],
    ino: stats.ino,
    uid: stats.uid,
    gid: stats.gid,
  }
}

/** Construction seams of {@link NodeGitFs}. */
export interface NodeGitFsOptions {
  /**
   * Promise face the adapter calls; defaults to the Worker's
   * `node:fs/promises` face (the runtime VFS, or this host's `fs.promises`).
   */
  readonly fsPromises?: typeof fsp
  /** Path authority; defaults to the one production namespace. */
  readonly namespace?: VfsNamespace
}

/**
 * `GitFs` over `node:fs/promises` — the Worker VFS in production.
 *
 * `root` mirrors `VfsFileSystem`'s option: empty (the default) means a virtual
 * path already is the real path, which is the Worker case because the runtime's
 * `node:fs` is the VFS itself. A test or a desktop harness points the same
 * adapter at a temporary directory, so the program sees exactly the paths the
 * Worker shell sees.
 *
 * Every virtual path goes through {@link VfsNamespace}: `/tmp/x` is the same
 * file as `/dsh/tmp/x` (G2-D05), and a read of DSH session state fails
 * `EACCES` before it reaches the filesystem (G2-D01). `root` prefixing happens
 * *after* that resolution, so a real temporary directory that itself lives
 * under the host's `/tmp` is never mistaken for the Worker's volatile root.
 */
export class NodeGitFs implements GitFs {
  private readonly root: string
  private readonly namespace: VfsNamespace
  private readonly fs: typeof fsp

  /**
   * @param root - real directory virtual `/` maps onto; `''`/`'/'` is identity.
   * @param options - promise face and path authority overrides.
   */
  constructor(root = '', options: NodeGitFsOptions = {}) {
    if (root !== '' && root !== '/' && !posix.isAbsolute(root)) {
      throw new TypeError(`NodeGitFs: root must be absolute or empty, got ${JSON.stringify(root)}`)
    }
    this.root = root === '/' ? '' : root.replace(/\/+$/, '')
    this.namespace = options.namespace ?? WORKER_VFS_NAMESPACE
    this.fs = options.fsPromises ?? fsp
  }

  /** Canonical storage path of one virtual path (no policy). */
  private virtual(path: string): string {
    if (typeof path !== 'string' || !path.startsWith('/')) {
      throw fsError('EINVAL', 'git paths must be absolute', String(path))
    }
    return this.namespace.storagePath(path)
  }

  /** Canonical storage path of one virtual path that git is about to read. */
  private readable(path: string): string {
    this.namespace.assertExecReadable(path)
    return this.virtual(path)
  }

  /** Real path for one canonical virtual path. */
  private toReal(path: string): string {
    return `${this.root}${path}`
  }

  /** Virtual path for one real path below the root. */
  private fromReal(path: string): string {
    if (this.root === '') return path
    if (path === this.root) return '/'
    return path.startsWith(`${this.root}/`) ? path.slice(this.root.length) : path
  }

  async readFile(path: string): Promise<Uint8Array> {
    return new Uint8Array(await this.fs.readFile(this.toReal(this.readable(path))))
  }

  async writeFile(path: string, data: Uint8Array | string, mode?: number): Promise<void> {
    await this.fs.writeFile(this.toReal(this.virtual(path)), data, mode === undefined ? undefined : { mode })
  }

  async appendFile(path: string, data: Uint8Array | string): Promise<void> {
    await this.fs.appendFile(this.toReal(this.virtual(path)), data)
  }

  async mkdir(path: string, recursive = false): Promise<void> {
    await this.fs.mkdir(this.toReal(this.virtual(path)), recursive ? { recursive: true } : undefined)
  }

  async readdir(path: string): Promise<GitDirent[]> {
    const entries = await this.fs.readdir(this.toReal(this.readable(path)), { withFileTypes: true })
    return entries.map(entry => ({
      name: entry.name,
      isFile: entry.isFile(),
      isDirectory: entry.isDirectory(),
      isSymbolicLink: entry.isSymbolicLink(),
    }))
  }

  async stat(path: string): Promise<GitStat> {
    return statOf(await this.fs.stat(this.toReal(this.readable(path))))
  }

  async lstat(path: string): Promise<GitStat> {
    return statOf(await this.fs.lstat(this.toReal(this.readable(path))))
  }

  async rm(path: string, options: { readonly recursive?: boolean; readonly force?: boolean } = {}): Promise<void> {
    await this.fs.rm(this.toReal(this.virtual(path)), options)
  }

  async rename(from: string, to: string): Promise<void> {
    // A rename out of the session store exposes the same bytes a read would.
    await this.fs.rename(this.toReal(this.readable(from)), this.toReal(this.virtual(to)))
  }

  async chmod(path: string, mode: number): Promise<void> {
    await this.fs.chmod(this.toReal(this.virtual(path)), mode)
  }

  async realpath(path: string): Promise<string> {
    return this.fromReal(await this.fs.realpath(this.toReal(this.readable(path))))
  }

  async exists(path: string): Promise<boolean> {
    try {
      await this.fs.stat(this.toReal(this.readable(path)))
      return true
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return false
      throw error
    }
  }

  async readFileSlice(path: string, start: number, end: number): Promise<Uint8Array> {
    if (start < 0 || (end !== 0 && end < start)) throw fsError('EINVAL', 'invalid read range', path)
    const handle = await this.fs.open(this.toReal(this.readable(path)), 'r')
    try {
      const stats = await handle.stat()
      const stop = end === 0 ? stats.size : Math.min(end, stats.size)
      const length = Math.max(0, stop - start)
      const buffer = new Uint8Array(length)
      let offset = 0
      while (offset < length) {
        const read = await handle.read(buffer, offset, length - offset, start + offset)
        if (read.bytesRead === 0) break
        offset += read.bytesRead
      }
      return offset === length ? buffer : buffer.subarray(0, offset)
    } finally {
      await handle.close()
    }
  }

  async readlink(path: string): Promise<string> {
    return await this.fs.readlink(this.toReal(this.readable(path)))
  }

  async symlink(target: string, path: string): Promise<void> {
    await this.fs.symlink(target, this.toReal(this.virtual(path)))
  }

  async utimes(path: string, atimeMs: number, mtimeMs: number): Promise<void> {
    await this.fs.utimes(this.toReal(this.virtual(path)), atimeMs / 1000, mtimeMs / 1000)
  }
}

/** Absolute POSIX path from a possibly relative one. */
export function resolvePath(base: string, path: string): string {
  return path.startsWith('/') ? posix.normalize(path) : posix.normalize(posix.join(base, path))
}

/** True when `child` is `parent` or lives under it (both absolute). */
export function isInside(parent: string, child: string): boolean {
  if (parent === child) return true
  const prefix = parent.endsWith('/') ? parent : `${parent}/`
  return child.startsWith(prefix)
}

/** Path of `child` relative to `parent`; both must be absolute. */
export function relativePath(parent: string, child: string): string {
  return posix.relative(parent, child)
}

/** Decode bytes as UTF-8 (lossy on invalid input, which git treats as binary). */
export function decodeText(data: Uint8Array): string {
  return new TextDecoder('utf-8').decode(data)
}

/** Encode text as UTF-8. */
export function encodeText(text: string): Uint8Array {
  return new TextEncoder().encode(text)
}

/** Concatenate byte arrays. */
export function concatBytes(...chunks: readonly Uint8Array[]): Uint8Array {
  let length = 0
  for (const chunk of chunks) length += chunk.byteLength
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

/** Byte-wise comparison, the ordering git gives tree entries and index paths. */
export function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const length = Math.min(a.byteLength, b.byteLength)
  for (let index = 0; index < length; index += 1) {
    const left = a[index] as number
    const right = b[index] as number
    if (left !== right) return left - right
  }
  return a.byteLength - b.byteLength
}

/** Compare two strings by their UTF-8 bytes (git's `strcmp` order). */
export function compareStrings(a: string, b: string): number {
  return compareBytes(encodeText(a), encodeText(b))
}
