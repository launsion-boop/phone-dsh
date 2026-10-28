// SPDX-License-Identifier: MIT
/**
 * Snapshot fallback for hosts without a synchronous VFS channel.
 *
 * A WASI guest calls `fd_read`/`path_open` synchronously, so in production the
 * tool worker reaches the DSH worker's live VFS over a SharedArrayBuffer
 * channel (`ProxyWasiVfs`). That channel exists only in a cross-origin isolated
 * Worker; a Worker rebuilt by a recovery path can come back without it (see
 * G2-FIX-54: after `park_resume` the rebuilt Worker's `python3` lost the file
 * view while `bash` kept it). Publishing a `python3` that silently resolves
 * every path against an empty `/` is worse than not publishing it, so the
 * toolbox captures the preopened trees over the *asynchronous* control channel
 * and mounts them in the tool worker as a snapshot:
 *
 *  - reads (`stat`, `readdir`, `open`, `read`) are served synchronously from
 *    the snapshot, so cwd, absolute `/dsh/...` paths and relative paths all
 *    resolve exactly as they do in the shell;
 *  - mutations are applied to the snapshot immediately (a later read in the
 *    same program sees its own write) and forwarded to the live VFS over the
 *    asynchronous channel; the tool worker drains them before it reports the
 *    command's exit, so a following `bash` step sees the same bytes.
 *
 * The snapshot is a *fallback*: when the synchronous channel is available the
 * toolbox passes `sync` and never captures one. The capture is bounded so a
 * large workspace cannot inflate the tool worker past the WASI hot-instance
 * budget; a truncated capture is reported to the caller, which fails loud
 * instead of serving a partial view.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-snapshot
 */
import { VfsProxyError } from './errors.ts'
import { MAX_FILE_SIZE, MEBIBYTE } from './limits.ts'
import { MemoryWasiVfs } from './memory-wasi-vfs.ts'
import { isWithinRoot, normalizeAbsolutePath } from './vfs-paths.ts'
import type { VfsBackend, VfsOpenOptions, VfsRequest, VfsStat, VfsValue, WasiVfs } from './types.ts'

/** Default ceiling for one snapshot's file bytes (48 MiB, the workspace budget). */
export const DEFAULT_SNAPSHOT_BYTES = 48 * MEBIBYTE
/** Default ceiling for one snapshot's entries. */
export const DEFAULT_SNAPSHOT_ENTRIES = 8192

/** One captured entry. `path` is the DSH Worker VFS path (the guest path). */
export interface VfsSnapshotEntry {
  readonly path: string
  readonly kind: 'file' | 'directory'
  readonly mode: number
  readonly mtimeMs: number
  readonly ino: number
  /** File bytes; absent for directories. */
  readonly bytes?: Uint8Array
}

/** One captured view of the preopened trees. */
export interface VfsSnapshot {
  /** Preopen roots the snapshot was taken from (host paths). */
  readonly roots: readonly string[]
  /** Roots the live VFS did not have when the snapshot was captured. */
  readonly missing: readonly string[]
  readonly entries: readonly VfsSnapshotEntry[]
  /** Total file bytes captured. */
  readonly bytes: number
  /** True when a limit stopped the walk; the view is incomplete. */
  readonly truncated: boolean
  /** Entries skipped by a limit (for the loud failure message). */
  readonly omitted: number
}

/** Capture limits. */
export interface VfsSnapshotOptions {
  readonly maxBytes?: number
  readonly maxEntries?: number
  /** Per-file read cap; defaults to the configured single-file budget (64 MiB). */
  readonly maxFileBytes?: number
}

function isSnapshotEntry(value: unknown): value is VfsSnapshotEntry {
  if (typeof value !== 'object' || value === null) return false
  const entry = value as Record<string, unknown>
  if (typeof entry.path !== 'string' || entry.path === '') return false
  if (entry.kind !== 'file' && entry.kind !== 'directory') return false
  if (typeof entry.mode !== 'number' || typeof entry.mtimeMs !== 'number'
      || typeof entry.ino !== 'number') {
    return false
  }
  // A structured clone preserves a typed array; a plain object from an older
  // or foreign sender must not be seeded as file bytes.
  if (entry.kind === 'directory') return entry.bytes === undefined
  return entry.bytes instanceof Uint8Array
}

/**
 * Validate a `snapshot` message body received from another thread.
 *
 * The Worker control channel carries the whole preopened tree as one
 * structured-clone message. It is big and crosses a thread boundary, so the
 * receiver cannot rely on the sender's TypeScript type: a malformed body must
 * be rejected loud instead of being cast and half-seeded.
 * @param value - Untrusted message payload.
 * @returns Whether `value` has the exact {@link VfsSnapshot} shape.
 */
export function isVfsSnapshot(value: unknown): value is VfsSnapshot {
  if (typeof value !== 'object' || value === null) return false
  const snapshot = value as Record<string, unknown>
  if (!Array.isArray(snapshot.roots)
      || !snapshot.roots.every(root => typeof root === 'string')) {
    return false
  }
  if (!Array.isArray(snapshot.missing)
      || !snapshot.missing.every(root => typeof root === 'string')) {
    return false
  }
  if (!Array.isArray(snapshot.entries)) return false
  if (!snapshot.entries.every(isSnapshotEntry)) return false
  return typeof snapshot.bytes === 'number'
    && typeof snapshot.truncated === 'boolean'
    && typeof snapshot.omitted === 'number'
}

/**
 * Walk the preopened trees over the asynchronous backend and return one
 * snapshot. The walk is deterministic (directory entries are visited in
 * name order) so two boots over the same tree capture the same bytes.
 * @param backend - The host-side VFS backend the proxy serves.
 * @param roots - Host paths to capture (the preopen table's `hostPath`s).
 * @param options - Byte/entry limits.
 * @returns The captured snapshot; `truncated` when a limit was hit.
 */
export async function captureVfsSnapshot(
  backend: VfsBackend,
  roots: readonly string[],
  options: VfsSnapshotOptions = {},
): Promise<VfsSnapshot> {
  const maxBytes = options.maxBytes ?? DEFAULT_SNAPSHOT_BYTES
  const maxEntries = options.maxEntries ?? DEFAULT_SNAPSHOT_ENTRIES
  const maxFileBytes = options.maxFileBytes ?? MAX_FILE_SIZE
  const entries: VfsSnapshotEntry[] = []
  const missing: string[] = []
  let bytes = 0
  let omitted = 0
  let truncated = false

  const visited = new Set<string>()
  const walk = async (root: string, path: string): Promise<void> => {
    if (truncated) return
    if (visited.has(path)) return
    visited.add(path)
    if (!isWithinRoot(root, path)) {
      omitted += 1
      return
    }
    let stat: VfsStat
    try {
      stat = await backend.stat(path)
    } catch (error) {
      if (path === root) missing.push(path)
      else if ((error as { code?: unknown }).code !== 'ENOENT') throw error
      omitted += 1
      return
    }
    if (stat.kind === 'symlink') {
      // The snapshot backend has no link resolution; leaving symlinks out is
      // the same answer the guest gets from a preopen that does not follow it.
      omitted += 1
      return
    }
    if (entries.length >= maxEntries) {
      truncated = true
      return
    }
    if (stat.kind === 'directory') {
      entries.push({
        path,
        kind: 'directory',
        mode: stat.mode,
        mtimeMs: stat.mtimeMs,
        ino: stat.ino,
      })
      let children: readonly { readonly name: string }[]
      try {
        children = await backend.readdir(path)
      } catch (error) {
        if ((error as { code?: unknown }).code === 'ENOENT') {
          omitted += 1
          return
        }
        throw error
      }
      const names = children.map(entry => entry.name).sort()
      for (const name of names) {
        if (name === '' || name === '.' || name === '..' || name.includes('/')) {
          omitted += 1
          continue
        }
        await walk(root, normalizeAbsolutePath(path === '/' ? `/${name}` : `${path}/${name}`))
        if (truncated) return
      }
      return
    }
    if (stat.size > maxFileBytes) {
      truncated = true
      return
    }
    if (bytes + stat.size > maxBytes) {
      truncated = true
      return
    }
    const content = await backend.readFile(path)
    if (content.byteLength > maxFileBytes || bytes + content.byteLength > maxBytes) {
      truncated = true
      return
    }
    bytes += content.byteLength
    entries.push({
      path,
      kind: 'file',
      mode: stat.mode,
      mtimeMs: stat.mtimeMs,
      ino: stat.ino,
      bytes: content.slice(),
    })
  }

  for (const root of roots) {
    await walk(normalizeAbsolutePath(root), normalizeAbsolutePath(root))
  }
  return { roots, missing, entries, bytes, truncated, omitted }
}

/** Write-behind face the snapshot forwards mutations to (the async client). */
export interface SnapshotWriteThrough {
  call(request: VfsRequest): Promise<VfsValue>
}

/**
 * `WasiVfs` over a captured snapshot with write-behind.
 *
 * Reads are synchronous and local (the whole point: they work with no
 * SharedArrayBuffer). Mutations update the local view first, then queue an
 * asynchronous request; {@link flushWrites} awaits the queue so the tool worker
 * can report the command's exit only after the live VFS (and therefore the WAL
 * sink) has the bytes.
 */
export class SnapshotWasiVfs extends MemoryWasiVfs {
  private readonly writer: SnapshotWriteThrough | undefined
  private readonly pending = new Set<Promise<VfsValue>>()
  private failure: Error | undefined
  /** Set while `write()` drives the inherited whole-file path. */
  private incrementalWrite = false
  private snapshot: VfsSnapshot

  /**
   * @param snapshot - Captured entries to seed.
   * @param writer - Async request face; absent for a read-only view.
   */
  constructor(snapshot: VfsSnapshot, writer?: SnapshotWriteThrough) {
    super()
    this.snapshot = snapshot
    this.writer = writer
    this.seed(snapshot)
  }

  /**
   * Replace the local view with a fresh capture of the live preopened trees.
   *
   * The host captures again before each dispatch in fallback mode, so a file a
   * `bash` step wrote (or removed) since the previous python run is visible to
   * the next one. Files this view wrote are already in the live VFS because
   * `flushWrites()` ran before the previous exit.
   * @param snapshot - The new capture; its roots replace the whole local tree.
   */
  update(snapshot: VfsSnapshot): void {
    this.snapshot = snapshot
    this.resetTree()
    this.failure = undefined
    this.seed(snapshot)
  }

  private seed(snapshot: VfsSnapshot): void {
    // Parents first so seeding a file never has to invent a directory that
    // the snapshot itself reported with its own mode/mtime.
    const ordered = [...snapshot.entries].sort((left, right) => left.path.length - right.path.length)
    for (const entry of ordered) {
      try {
        if (entry.kind === 'directory') {
          this.seedDirectory(entry.path)
        } else if (entry.bytes !== undefined) {
          this.seedFile(entry.path, entry.bytes, entry.mode)
        }
      } catch {
        // A parent that the live VFS reported as a file cannot hold the child;
        // the snapshot is truncated for that subtree and the guest sees the
        // same ENOENT a missing directory produces.
        this.failure ??= new VfsProxyError('EIO', `snapshot entry ${entry.path} could not be seeded`)
      }
    }
  }

  /** The captured view this instance serves (diagnostics/tests). */
  get captured(): VfsSnapshot {
    return this.snapshot
  }

  override open(path: string, options: VfsOpenOptions): VfsStat {
    return super.open(path, options)
  }

  override writeFile(
    path: string,
    data: Uint8Array,
    options: { create?: boolean; append?: boolean; truncate?: boolean; mode?: number } = {},
  ): void {
    super.writeFile(path, data, options)
    if (this.incrementalWrite) return
    this.forward({
      op: 'write',
      path: normalizeAbsolutePath(path),
      offset: 0,
      append: options.append === true,
      create: options.create !== false,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
      data: this.readFile(path).slice(),
    })
  }

  override write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { append: boolean; create: boolean; mode?: number },
  ): number {
    this.incrementalWrite = true
    let written: number
    try {
      written = super.write(path, offset, data, options)
    } finally {
      this.incrementalWrite = false
    }
    this.forward({
      op: 'write',
      path: normalizeAbsolutePath(path),
      offset: Math.max(0, offset),
      append: options.append,
      create: options.create,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
      data: data.slice(),
    })
    return written
  }

  override truncate(path: string, length: number): void {
    super.truncate(path, length)
    this.forward({ op: 'truncate', path: normalizeAbsolutePath(path), length })
  }

  override mkdir(path: string, mode?: number): void {
    super.mkdir(path, mode)
    this.forward({ op: 'mkdir', path: normalizeAbsolutePath(path), ...(mode === undefined ? {} : { mode }) })
  }

  override unlink(path: string, options: { directory?: boolean; recursive?: boolean } = {}): void {
    super.unlink(path, options)
    this.forward({ op: 'unlink', path: normalizeAbsolutePath(path), directory: options.directory === true })
  }

  override rename(from: string, to: string): void {
    super.rename(from, to)
    this.forward({ op: 'rename', from: normalizeAbsolutePath(from), to: normalizeAbsolutePath(to) })
  }

  override sync(): void {
    this.forward({ op: 'sync' })
  }

  /** True when a mutation could not be represented locally. */
  get broken(): boolean {
    return this.failure !== undefined
  }

  /**
   * Await every queued mutation and surface the first failure.
   * @throws {Error} When the live VFS refused a forwarded mutation.
   */
  async flushWrites(): Promise<void> {
    if (this.failure !== undefined) throw this.failure
    if (this.pending.size === 0) return
    const pending = [...this.pending]
    this.pending.clear()
    const results = await Promise.allSettled(pending)
    for (const result of results) {
      if (result.status === 'rejected') {
        this.failure ??= result.reason instanceof Error ? result.reason : new Error(String(result.reason))
      }
    }
    if (this.failure !== undefined) throw this.failure
  }

  private forward(request: VfsRequest): void {
    if (this.writer === undefined) {
      // A read-only snapshot must not silently swallow a write: the guest
      // would see a successful write that no other step can observe.
      this.failure ??= new VfsProxyError('EROFS', `cannot write ${'path' in request ? request.path : 'the tree'}: the snapshot view is read-only`)
      return
    }
    try {
      const promise = this.writer.call(request)
      this.pending.add(promise)
      void promise.then(
        () => { this.pending.delete(promise) },
        (error: unknown) => {
          this.pending.delete(promise)
          this.failure ??= error instanceof Error ? error : new Error(String(error))
        },
      )
    } catch (error) {
      this.failure ??= error instanceof Error ? error : new Error(String(error))
    }
  }
}

/** Bind a snapshot view to the synchronous `WasiVfs` face. */
export function createSnapshotVfs(
  snapshot: VfsSnapshot,
  writer?: SnapshotWriteThrough,
): SnapshotWasiVfs & WasiVfs {
  return new SnapshotWasiVfs(snapshot, writer)
}
