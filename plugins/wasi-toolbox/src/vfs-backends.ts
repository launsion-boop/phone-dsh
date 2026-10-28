// SPDX-License-Identifier: MIT
/**
 * VFS backends for the proxy server. `NodeFsBackend` is the production path:
 * the DSH worker passes the `node:fs/promises` face of its runtime filesystem
 * (the in-memory authority whose sink mirrors mutations into the WAL), so a
 * WASI write lands exactly where every other DSH write lands. The in-memory
 * backend exists for deterministic tests and for hosts without `node:fs`.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-backends
 */
import { normalizeAbsolutePath } from './vfs-paths.ts'
import { VfsProxyError, toVfsProxyError } from './errors.ts'
import { MAX_FILE_SIZE, formatByteLimit } from './limits.ts'
import { WORKER_VFS_NAMESPACE, wrapFsPromises, type VfsNamespace } from './vfs-namespace.ts'
import type { VfsWriteOutcomes } from './write-outcomes.ts'
import type { VfsBackend, VfsDirEntry, VfsStat } from './types.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/**
 * Refuse a write whose post-write file would exceed the configured single-file
 * budget.
 *
 * The WASI guest reaches the runtime VFS through these backends, not through
 * the shell's `VfsFileSystem` adapter, so the cap has to be enforced here too:
 * letting the bytes through would make the sink's publish-time guard close the
 * ordered channel after the mutation already landed (G2-A09's python3 path).
 * The byte count and the MiB spelling are rendered from the one configured
 * value by {@link formatByteLimit}, so a host-published budget can never be
 * described as the old 15 MiB tier (G2-FIX-100).
 * @param path - host VFS path of the target.
 * @param wouldBe - post-write file length in bytes.
 * @throws {VfsProxyError} `EFBIG` naming the limit when over it.
 */
function checkFileSize(path: string, wouldBe: number): void {
  if (wouldBe <= MAX_FILE_SIZE) return
  throw new VfsProxyError(
    'EFBIG',
    `File too large: ${path} would be ${wouldBe} bytes; a file is limited to ${formatByteLimit(MAX_FILE_SIZE)}`,
    path,
  )
}

/** Structural `fs.Stats` face the backend reads. */
export interface NodeFsStatsLike {
  readonly size: number
  readonly mode: number
  readonly mtimeMs: number
  readonly ino: number
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

/** Structural `fs.Dirent` face the backend reads. */
export interface NodeFsDirentLike {
  readonly name: string
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

/** Structural `node:fs/promises` face the DSH worker supplies. */
export interface NodeFsPromisesLike {
  stat(path: string): Promise<NodeFsStatsLike>
  lstat?(path: string): Promise<NodeFsStatsLike>
  readdir(path: string, options: { withFileTypes: true }): Promise<readonly (NodeFsDirentLike | string)[]>
  readFile(path: string): Promise<Uint8Array | string>
  writeFile(
    path: string,
    data: Uint8Array,
    options?: { readonly mode?: number },
  ): Promise<void>
  /**
   * Append without materialising the whole file first. The production VFS
   * publishes this as an `appended` mutation, so one `fd_write` of a growing
   * file costs its own bytes in the WAL instead of the whole file so far.
   */
  appendFile?(path: string, data: Uint8Array): Promise<void>
  mkdir(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): Promise<unknown>
  unlink(path: string): Promise<void>
  rmdir?(path: string): Promise<void>
  rm?(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  truncate(path: string, length?: number): Promise<void>
  chmod?(path: string, mode: number): Promise<void>
}

function kindOf(stats: NodeFsStatsLike): VfsStat['kind'] {
  if (stats.isDirectory()) return 'directory'
  if (stats.isSymbolicLink()) return 'symlink'
  return 'file'
}

function statOf(stats: NodeFsStatsLike): VfsStat {
  return {
    kind: kindOf(stats),
    size: stats.size,
    mode: stats.mode & 0o777,
    mtimeMs: stats.mtimeMs,
    ino: stats.ino,
  }
}

function bytesOf(data: Uint8Array | string): Uint8Array {
  return typeof data === 'string' ? encoder.encode(data) : data
}

/** Backend over a `node:fs/promises`-shaped object. */
export class NodeFsBackend implements VfsBackend {
  readonly fs: NodeFsPromisesLike
  private readonly flushSink: (() => Promise<void> | void) | undefined
  private readonly writeOutcomes: VfsWriteOutcomes | undefined

  /**
   * @param fs - The DSH worker's `node:fs/promises` face.
   * @param options.flush - Durability hook, normally `host.vfs.flush`, so a
   * guest `fsync` waits for the VFS sink instead of lying about durability.
   * @param options.namespace - Path authority; the face is wrapped with it so
   * `/tmp/x` and `/dsh/tmp/x` name one file and DSH session state stays
   * unreadable to `python3` (G2-D01/G2-D05).
   * @param options.writeOutcomes - Ordered-channel outcome tracker shared with
   * the Worker sink. When present, every write and truncate awaits the host's
   * level-1 ack (or refusal) before the proxy answers the guest, so a resource
   * refusal becomes a WASI errno and a stalled flow-control window fails loud
   * instead of parking the interpreter (G2-A09 attempt 7).
   */
  constructor(
    fs: NodeFsPromisesLike,
    options: {
      readonly flush?: () => Promise<void> | void
      readonly namespace?: VfsNamespace
      readonly writeOutcomes?: VfsWriteOutcomes
    } = {},
  ) {
    const namespace = options.namespace ?? WORKER_VFS_NAMESPACE
    this.fs = wrapFsPromises(fs, namespace)
    this.flushSink = options.flush
    this.writeOutcomes = options.writeOutcomes
  }

  /**
   * Run one VFS mutation and, when an outcome tracker is bound, wait for the
   * sink to publish it and the host to acknowledge it. A refusal or a stalled
   * flow-control window rejects here, inside the guest's write syscall, so the
   * WASI host can return an errno and the command settles with a tool result.
   *
   * The publication window is closed as soon as `run()` returns: the sink calls
   * {@link VfsWriteOutcomes.notePublished} synchronously from the runtime's
   * mutation observer, which runs inside `run()`. No ack is awaited when the
   * mutation never reached the sink (a volatile root, or a local refusal).
   * @param path - canonical host VFS path of the mutation.
   * @param run - the filesystem call that publishes the mutation.
   */
  private async awaitPublished(path: string, run: () => Promise<void>): Promise<void> {
    const outcomes = this.writeOutcomes
    if (outcomes === undefined) {
      await run()
      return
    }
    const ticket = outcomes.begin(path)
    try {
      await run()
    } finally {
      outcomes.endPublishing(ticket)
    }
    await outcomes.awaitOutcome(ticket)
  }

  async stat(path: string): Promise<VfsStat> {
    try {
      const stats = await this.fs.stat(path)
      return statOf(stats)
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async readdir(path: string): Promise<readonly VfsDirEntry[]> {
    try {
      const raw = await this.fs.readdir(path, { withFileTypes: true })
      const entries: VfsDirEntry[] = []
      for (const item of raw) {
        if (typeof item === 'string') {
          const stats = await this.fs.stat(`${path === '/' ? '' : path}/${item}`)
          entries.push({ name: item, kind: kindOf(stats), ino: stats.ino })
          continue
        }
        entries.push({
          name: item.name,
          kind: item.isDirectory() ? 'directory' : item.isSymbolicLink() ? 'symlink' : 'file',
          ino: 0,
        })
      }
      entries.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0))
      return entries
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async readFile(path: string): Promise<Uint8Array> {
    try {
      return bytesOf(await this.fs.readFile(path))
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async writeFile(
    path: string,
    data: Uint8Array,
    options: { create?: boolean; append?: boolean; truncate?: boolean; mode?: number } = {},
  ): Promise<void> {
    try {
      if (options.append === true) {
        const appendFile = this.fs.appendFile
        if (typeof appendFile === 'function') {
          // The production VFS has a real append: it records only the suffix
          // for the sink, so a chunked write of a large file is linear in the
          // WAL instead of quadratic (the G2-A09 shard-write shape).
          let size = 0
          try {
            size = (await this.fs.stat(path)).size
          } catch (error) {
            if (toVfsProxyError(error, 'EIO', path).code !== 'ENOENT' || options.create !== true) throw error
          }
          checkFileSize(path, size + data.byteLength)
          await this.awaitPublished(path, () => appendFile.call(this.fs, path, data))
          return
        }
        let existing: Uint8Array
        try {
          existing = bytesOf(await this.fs.readFile(path))
        } catch (error) {
          if (toVfsProxyError(error, 'EIO', path).code !== 'ENOENT' || options.create !== true) throw error
          existing = new Uint8Array(0)
        }
        const joined = new Uint8Array(existing.byteLength + data.byteLength)
        joined.set(existing, 0)
        joined.set(data, existing.byteLength)
        // `node:fs` has no append here: the complete post-write file is about
        // to be written, so this is the size the sink would publish.
        checkFileSize(path, joined.byteLength)
        await this.awaitPublished(path, () => this.fs.writeFile(
          path,
          joined,
          options.mode === undefined ? undefined : { mode: options.mode },
        ))
        return
      }
      // A whole-file write replaces the file, so `data` is the post-write size.
      checkFileSize(path, data.byteLength)
      if (options.create === false) {
        // A plain write to a missing entry is ENOENT; `open` normally created it.
        await this.fs.stat(path)
      }
      await this.awaitPublished(path, () => this.fs.writeFile(
        path,
        data,
        options.mode === undefined ? undefined : { mode: options.mode },
      ))
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async mkdir(path: string, mode?: number): Promise<void> {
    try {
      await this.fs.mkdir(path, { recursive: false, ...(mode === undefined ? {} : { mode }) })
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async unlink(path: string, options: { directory?: boolean; recursive?: boolean } = {}): Promise<void> {
    try {
      if (options.directory === true) {
        await this.removeDirectory(path, options.recursive === true)
        return
      }
      await this.removeFile(path)
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  /**
   * Remove one directory with POSIX semantics.
   *
   * The Worker's production `node:fs/promises` face (`MemoryVfs.promises`)
   * has no `rmdir`: its `unlink` covers files only and `rm` refuses a
   * directory unless `recursive` is true. Falling through to
   * `rm(path, {recursive:false})` therefore answered `ERR_FS_EISDIR`, which is
   * not an errno spelling and reached CPython as EIO — every `os.rmdir` and
   * `tempfile.TemporaryDirectory()` cleanup failed (G2-D06). A face that does
   * publish `rmdir` uses it directly; otherwise the entry is proved to be a
   * directory, proved empty through `readdir`, and removed with the recursive
   * `rm` primitive, which can only remove that one already-empty directory.
   * @param path - host VFS path of the directory.
   * @param recursive - remove the subtree (internal callers only; WASI's
   * `path_remove_directory` is never recursive).
   */
  private async removeDirectory(path: string, recursive: boolean): Promise<void> {
    const rmdir = this.fs.rmdir
    if (typeof rmdir === 'function' && !recursive) {
      await rmdir.call(this.fs, path)
      return
    }
    let stats: NodeFsStatsLike
    try {
      stats = await this.fs.stat(path)
    } catch (error) {
      if (toVfsProxyError(error, 'EIO', path).code === 'ENOENT') {
        throw new VfsProxyError('ENOENT', 'no such directory', path)
      }
      throw error
    }
    if (!stats.isDirectory()) throw new VfsProxyError('ENOTDIR', 'not a directory', path)
    if (!recursive) {
      const entries = await this.fs.readdir(path, { withFileTypes: true })
      if (entries.length > 0) throw new VfsProxyError('ENOTEMPTY', 'directory not empty', path)
    }
    const rm = this.fs.rm
    if (typeof rm === 'function') {
      await rm.call(this.fs, path, { recursive: true })
      return
    }
    // Last resort for a face with neither `rmdir` nor `rm`: some `unlink`
    // implementations remove any entry, and a strict one answers EISDIR/EPERM.
    await this.fs.unlink(path)
  }

  /**
   * Remove one file, reporting a directory as EISDIR.
   *
   * A face whose `unlink` covers files only answers ENOENT for a directory
   * (the Worker `MemoryVfs` does). POSIX `unlink` on a directory is EISDIR, and
   * CPython's `tempfile`/`shutil` cleanup distinguishes the two, so a missing
   * path is re-checked before the ENOENT is passed through.
   * @param path - host VFS path of the file.
   */
  private async removeFile(path: string): Promise<void> {
    try {
      await this.fs.unlink(path)
    } catch (error) {
      const mapped = toVfsProxyError(error, 'EIO', path)
      if (mapped.code !== 'ENOENT') throw mapped
      let stats: NodeFsStatsLike | undefined
      try {
        stats = await this.fs.stat(path)
      } catch {
        stats = undefined
      }
      if (stats?.isDirectory() === true) throw new VfsProxyError('EISDIR', 'is a directory', path)
      throw mapped
    }
  }

  async rename(from: string, to: string): Promise<void> {
    try {
      await this.fs.rename(from, to)
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', from)
    }
  }

  async truncate(path: string, length: number): Promise<void> {
    try {
      // Extending a file is a write of `length` zero bytes; refuse it at the
      // same surface instead of publishing an oversized mutation.
      checkFileSize(path, length)
      await this.awaitPublished(path, () => this.fs.truncate(path, length))
    } catch (error) {
      throw toVfsProxyError(error, 'EIO', path)
    }
  }

  async sync(): Promise<void> {
    await this.flushSink?.()
  }
}

interface MemoryFile {
  bytes: Uint8Array
  mode: number
  mtimeMs: number
  ino: number
}

interface MemoryDirectory {
  mode: number
  mtimeMs: number
  ino: number
}

/**
 * In-memory VFS backend with POSIX-ish errors. It is intentionally small: files
 * and directories, whole-file writes, rename, and empty-directory removal.
 */
export class MemoryVfsBackend implements VfsBackend {
  private readonly files = new Map<string, MemoryFile>()
  private readonly directories = new Map<string, MemoryDirectory>()
  private readonly clock: () => number
  private nextIno = 1

  constructor(options: { readonly clock?: () => number } = {}) {
    this.clock = options.clock ?? (() => Date.now())
    this.directories.set('/', { mode: 0o755, mtimeMs: this.clock(), ino: this.allocateIno() })
  }

  /** Create a file and any missing parent directories. */
  seedFile(path: string, data: Uint8Array | string, mode = 0o644,
           mtimeMs = this.clock()): void {
    const target = normalizeAbsolutePath(path)
    this.ensureParents(target)
    this.files.set(target, {
      bytes: typeof data === 'string' ? encoder.encode(data) : data.slice(),
      mode,
      mtimeMs,
      ino: this.allocateIno(),
    })
  }

  /** Create a directory and any missing parent directories. */
  seedDirectory(path: string, mode = 0o755, mtimeMs = this.clock()): void {
    const target = normalizeAbsolutePath(path)
    this.ensureParents(target)
    this.directories.set(target, { mode, mtimeMs, ino: this.allocateIno() })
  }

  /**
   * Drop every stored entry and re-create the root.
   *
   * Subclasses that mirror a capture of the live VFS use this before seeding a
   * fresh capture, so a deleted file does not survive as a stale entry.
   */
  protected resetTree(): void {
    this.files.clear()
    this.directories.clear()
    this.directories.set('/', { mode: 0o755, mtimeMs: this.clock(), ino: this.allocateIno() })
  }

  /** Current bytes of one file, or `undefined`. */
  peek(path: string): Uint8Array | undefined {
    return this.files.get(normalizeAbsolutePath(path))?.bytes.slice()
  }

  /** Names currently stored, for assertions. */
  list(): readonly string[] {
    return [...this.directories.keys(), ...this.files.keys()].sort()
  }

  stat(path: string): VfsStat {
    const target = normalizeAbsolutePath(path)
    const file = this.files.get(target)
    if (file !== undefined) {
      return { kind: 'file', size: file.bytes.byteLength, mode: file.mode, mtimeMs: file.mtimeMs, ino: file.ino }
    }
    const directory = this.directories.get(target)
    if (directory !== undefined) {
      return { kind: 'directory', size: 0, mode: directory.mode, mtimeMs: directory.mtimeMs, ino: directory.ino }
    }
    throw new VfsProxyError('ENOENT', 'no such file or directory', target)
  }

  readdir(path: string): readonly VfsDirEntry[] {
    const target = normalizeAbsolutePath(path)
    if (!this.directories.has(target)) throw new VfsProxyError('ENOENT', 'no such directory', target)
    const prefix = target === '/' ? '/' : `${target}/`
    const entries: VfsDirEntry[] = []
    for (const [filePath, file] of this.files) {
      if (!filePath.startsWith(prefix)) continue
      const rest = filePath.slice(prefix.length)
      if (rest.includes('/')) continue
      entries.push({ name: rest, kind: 'file', ino: file.ino })
    }
    for (const [directoryPath, directory] of this.directories) {
      if (directoryPath === target || !directoryPath.startsWith(prefix)) continue
      const rest = directoryPath.slice(prefix.length)
      if (rest.includes('/')) continue
      entries.push({ name: rest, kind: 'directory', ino: directory.ino })
    }
    entries.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0))
    return entries
  }

  readFile(path: string): Uint8Array {
    const target = normalizeAbsolutePath(path)
    const file = this.files.get(target)
    if (file === undefined) {
      if (this.directories.has(target)) throw new VfsProxyError('EISDIR', 'is a directory', target)
      throw new VfsProxyError('ENOENT', 'no such file or directory', target)
    }
    return file.bytes.slice()
  }

  writeFile(
    path: string,
    data: Uint8Array,
    options: { create?: boolean; append?: boolean; truncate?: boolean; mode?: number } = {},
  ): void {
    const target = normalizeAbsolutePath(path)
    const existing = this.files.get(target)
    if (existing === undefined && options.create === false) {
      throw new VfsProxyError('ENOENT', 'no such file or directory', target)
    }
    if (this.directories.has(target)) throw new VfsProxyError('EISDIR', 'is a directory', target)
    if (existing === undefined) this.ensureParents(target)
    const base = options.append === true && existing !== undefined ? existing.bytes : new Uint8Array(0)
    const joined = new Uint8Array(base.byteLength + data.byteLength)
    joined.set(base, 0)
    joined.set(data, base.byteLength)
    checkFileSize(target, joined.byteLength)
    this.files.set(target, {
      bytes: joined,
      mode: options.mode ?? existing?.mode ?? 0o644,
      mtimeMs: this.clock(),
      ino: existing?.ino ?? this.allocateIno(),
    })
  }

  mkdir(path: string, mode = 0o755): void {
    const target = normalizeAbsolutePath(path)
    if (target === '/') throw new VfsProxyError('EEXIST', 'directory exists', target)
    if (this.directories.has(target) || this.files.has(target)) {
      throw new VfsProxyError('EEXIST', 'entry exists', target)
    }
    this.requireDirectory(parentOf(target))
    this.directories.set(target, { mode, mtimeMs: this.clock(), ino: this.allocateIno() })
  }

  /** Change the permission bits of one file or directory. */
  chmod(path: string, mode: number): void {
    const target = normalizeAbsolutePath(path)
    const file = this.files.get(target)
    if (file !== undefined) {
      file.mode = mode
      return
    }
    const directory = this.directories.get(target)
    if (directory !== undefined) {
      directory.mode = mode
      return
    }
    throw new VfsProxyError('ENOENT', 'no such file or directory', target)
  }

  unlink(path: string, options: { directory?: boolean; recursive?: boolean } = {}): void {
    const target = normalizeAbsolutePath(path)
    if (target === '/') throw new VfsProxyError('EPERM', 'cannot remove the root', target)
    if (options.directory === true) {
      if (!this.directories.has(target)) {
        if (this.files.has(target)) throw new VfsProxyError('ENOTDIR', 'not a directory', target)
        throw new VfsProxyError('ENOENT', 'no such directory', target)
      }
      if (options.recursive !== true) {
        const prefix = `${target}/`
        for (const key of this.files.keys()) if (key.startsWith(prefix)) throw new VfsProxyError('ENOTEMPTY', 'directory not empty', target)
        for (const key of this.directories.keys()) if (key !== target && key.startsWith(prefix)) throw new VfsProxyError('ENOTEMPTY', 'directory not empty', target)
      } else {
        // POSIX `rm -r` removes the whole subtree. Dropping only the directory
        // node would leave its children in the maps, so a re-created directory
        // with the same name would expose stale files again.
        const prefix = `${target}/`
        for (const key of [...this.files.keys()]) if (key.startsWith(prefix)) this.files.delete(key)
        for (const key of [...this.directories.keys()]) if (key !== target && key.startsWith(prefix)) this.directories.delete(key)
      }
      this.directories.delete(target)
      this.touchParent(target)
      return
    }
    if (!this.files.has(target)) {
      if (this.directories.has(target)) throw new VfsProxyError('EISDIR', 'is a directory', target)
      throw new VfsProxyError('ENOENT', 'no such file', target)
    }
    this.files.delete(target)
    this.touchParent(target)
  }

  rename(from: string, to: string): void {
    const source = normalizeAbsolutePath(from)
    const target = normalizeAbsolutePath(to)
    const file = this.files.get(source)
    if (file !== undefined) {
      if (this.directories.has(target)) throw new VfsProxyError('EISDIR', 'is a directory', target)
      this.requireDirectory(parentOf(target))
      this.files.delete(source)
      this.files.set(target, file)
      this.touchParent(source)
      this.touchParent(target)
      return
    }
    const directory = this.directories.get(source)
    if (directory === undefined) throw new VfsProxyError('ENOENT', 'no such entry', source)
    if (this.files.has(target) || this.directories.has(target)) {
      throw new VfsProxyError('EEXIST', 'target exists', target)
    }
    this.requireDirectory(parentOf(target))
    this.directories.set(target, directory)
    this.directories.delete(source)
    const prefix = `${source}/`
    for (const [path, entry] of [...this.files]) {
      if (!path.startsWith(prefix)) continue
      this.files.delete(path)
      this.files.set(`${target}/${path.slice(prefix.length)}`, entry)
    }
    for (const [path, entry] of [...this.directories]) {
      if (!path.startsWith(prefix)) continue
      this.directories.delete(path)
      this.directories.set(`${target}/${path.slice(prefix.length)}`, entry)
    }
    this.touchParent(source)
    this.touchParent(target)
  }

  truncate(path: string, length: number): void {
    const target = normalizeAbsolutePath(path)
    const file = this.files.get(target)
    if (file === undefined) throw new VfsProxyError('ENOENT', 'no such file', target)
    checkFileSize(target, length)
    const resized = new Uint8Array(length)
    resized.set(file.bytes.subarray(0, length), 0)
    file.bytes = resized
    file.mtimeMs = this.clock()
  }

  sync(): void {
    // Memory only.
  }

  private allocateIno(): number {
    const ino = this.nextIno
    this.nextIno += 1
    return ino
  }

  private requireDirectory(path: string): void {
    if (path === '/') return
    if (!this.directories.has(path)) {
      if (this.files.has(path)) throw new VfsProxyError('ENOTDIR', 'not a directory', path)
      throw new VfsProxyError('ENOENT', 'no such directory', path)
    }
  }

  private ensureParents(path: string): void {
    const parent = parentOf(path)
    if (parent === '/' || this.directories.has(parent)) return
    this.ensureParents(parent)
    this.directories.set(parent, { mode: 0o755, mtimeMs: this.clock(), ino: this.allocateIno() })
  }

  /** Record that a parent directory's entry list changed (POSIX mtime). */
  private touchParent(path: string): void {
    const parent = this.directories.get(parentOf(path))
    if (parent !== undefined) parent.mtimeMs = this.clock()
  }
}

function parentOf(path: string): string {
  const index = path.lastIndexOf('/')
  return index <= 0 ? '/' : path.slice(0, index)
}
