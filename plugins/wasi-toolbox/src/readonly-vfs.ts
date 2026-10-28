// SPDX-License-Identifier: MIT
/**
 * Read-only in-memory filesystem and the overlay used to mount it beside the
 * writable proxy VFS. This is the stdlib loader the CPython package feeds: a
 * tree of files packed as bytes is visible under preopened roots, reads and
 * `readdir` merge with the writable tree, and any attempt to change a read-only
 * path answers `EROFS` instead of silently shadowing it.
 * @module @phone-dsh/dsh-wasi-toolbox/readonly-vfs
 */
import { VfsProxyError } from './errors.ts'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { isWithinRoot, normalizeAbsolutePath } from './vfs-paths.ts'
import type { VfsDirEntry, VfsOpenOptions, VfsStat, WasiVfs } from './types.ts'

/** One read-only file: absolute host path and bytes. */
export interface ReadOnlyFile {
  readonly path: string
  readonly data: Uint8Array
  readonly mode?: number
}

/** A read-only layer that can name the subtree it owns. */
export interface ReadOnlyLayer extends WasiVfs {
  /** True for every path the layer owns, including not-yet-created children. */
  isReadOnlyPath(path: string): boolean
}

/** Read-only `WasiVfs` over an in-memory tree. */
export class ReadOnlyMemoryVfs implements ReadOnlyLayer {
  private readonly files = new MemoryVfsBackend()
  /** Mount root: mutations anywhere below it answer `EROFS`. */
  readonly root: string
  private readonly mounted: boolean

  constructor(entries: Iterable<ReadOnlyFile> = [], options: { readonly root?: string } = {}) {
    const files = [...entries]
    for (const entry of files) {
      this.files.seedFile(normalizeAbsolutePath(entry.path), entry.data, entry.mode ?? 0o444)
    }
    this.mounted = files.length > 0 || options.root !== undefined
    this.root = normalizeAbsolutePath(options.root ?? commonAncestor(files.map(entry => entry.path)))
  }

  /** Build a layer from a prefix plus relative paths, as a stdlib pack does. */
  static fromTree(prefix: string, entries: Iterable<{ path: string; data: Uint8Array }>): ReadOnlyMemoryVfs {
    const root = normalizeAbsolutePath(prefix)
    return new ReadOnlyMemoryVfs([...entries].map(entry => ({
      path: normalizeAbsolutePath(`${root === '/' ? '' : root}/${entry.path}`),
      data: entry.data,
    })), { root })
  }

  /** True for the whole mounted subtree, whether or not an entry exists yet. */
  isReadOnlyPath(path: string): boolean {
    return this.mounted && isWithinRoot(this.root, normalizeAbsolutePath(path))
  }

  /** Test/diagnostic access to the bytes of one read-only file. */
  peek(path: string): Uint8Array | undefined {
    return this.files.peek(path)
  }

  stat(path: string): VfsStat {
    return this.files.stat(path) as VfsStat
  }

  readdir(path: string): readonly VfsDirEntry[] {
    return this.files.readdir(path)
  }

  open(path: string, options: VfsOpenOptions): VfsStat {
    const stat = this.stat(path)
    if (stat.kind === 'directory') {
      if (options.directory) return stat
      throw new VfsProxyError('EISDIR', 'is a directory', path)
    }
    if (options.create && options.exclusive) throw new VfsProxyError('EEXIST', 'file exists', path)
    if (options.truncate) throw new VfsProxyError('EROFS', 'read-only filesystem', path)
    return stat
  }

  read(path: string, offset: number, length: number): Uint8Array {
    const stat = this.stat(path)
    if (stat.kind === 'directory') throw new VfsProxyError('EISDIR', 'is a directory', path)
    return this.files.readFile(path).slice(Math.max(0, offset), Math.max(0, offset) + Math.max(0, length))
  }

  write(path: string): number {
    throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }

  truncate(path: string): void {
    throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }

  mkdir(path: string): void {
    throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }

  unlink(path: string): void {
    throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }

  rmdir(path: string): void {
    throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }

  rename(from: string): void {
    throw new VfsProxyError('EROFS', 'read-only filesystem', from)
  }

  sync(): void {
    // Nothing to flush.
  }
}

/** Construction inputs of {@link OverlayWasiVfs}. */
export interface OverlayWasiVfsOptions {
  /** Layers consulted in order for reads; every one is read-only. */
  readonly layers: readonly WasiVfs[]
  /** The single writable layer (the VFS proxy). */
  readonly writable: WasiVfs
}

/** Read-through overlay: layers first, then the writable proxy. */
export class OverlayWasiVfs implements WasiVfs {
  private readonly layers: readonly WasiVfs[]
  private readonly writable: WasiVfs

  constructor(options: OverlayWasiVfsOptions) {
    this.layers = options.layers
    this.writable = options.writable
  }

  stat(path: string): VfsStat {
    for (const layer of this.layers) {
      const stat = tryStat(layer, path)
      if (stat !== undefined) return stat
    }
    return this.writable.stat(path)
  }

  readdir(path: string): readonly VfsDirEntry[] {
    const entries = new Map<string, VfsDirEntry>()
    let found = false
    for (const layer of this.layers) {
      const listing = tryReaddir(layer, path)
      if (listing === undefined) continue
      found = true
      for (const entry of listing) entries.set(entry.name, entry)
    }
    // A directory owned by a read-only layer cannot have writable children
    // (every mutation below its root answers EROFS), and the writable proxy
    // only has capabilities for its own preopens. Asking it anyway turns a
    // successful listing inside the stdlib mount into ENOTCAPABLE, so the
    // merge stops at the layer that owns the path.
    const sorted = (): VfsDirEntry[] => [...entries.values()].sort(byName)
    if (found && this.rejectsMutation(path)) return sorted()
    if (found || this.layers.length === 0) {
      const writable = tryReaddir(this.writable, path)
      for (const entry of writable ?? []) {
        if (!entries.has(entry.name)) entries.set(entry.name, entry)
      }
    } else {
      for (const entry of this.writable.readdir(path)) entries.set(entry.name, entry)
    }
    return sorted()
  }

  open(path: string, options: VfsOpenOptions): VfsStat {
    const normalized = normalizeAbsolutePath(path)
    const readonly = this.readOnlyEntry(normalized)
    if (readonly !== undefined) {
      if (readonly.kind === 'directory') {
        if (options.directory) return readonly
        throw new VfsProxyError('EISDIR', 'is a directory', path)
      }
      if (options.truncate || options.create || options.exclusive) {
        throw new VfsProxyError('EROFS', 'read-only filesystem', path)
      }
      return readonly
    }
    if ((options.create || options.truncate) && this.rejectsMutation(normalized)) {
      throw new VfsProxyError('EROFS', 'read-only filesystem', path)
    }
    return this.writable.open(path, options)
  }

  read(path: string, offset: number, length: number): Uint8Array {
    for (const layer of this.layers) {
      const stat = tryStat(layer, path)
      if (stat === undefined) continue
      if (stat.kind === 'directory') throw new VfsProxyError('EISDIR', 'is a directory', path)
      return layer.read(path, offset, length)
    }
    return this.writable.read(path, offset, length)
  }

  write(path: string, offset: number, data: Uint8Array, options: { append: boolean; create: boolean; mode?: number }): number {
    this.rejectIfReadOnly(path)
    return this.writable.write(path, offset, data, options)
  }

  truncate(path: string, length: number): void {
    this.rejectIfReadOnly(path)
    this.writable.truncate(path, length)
  }

  mkdir(path: string, mode?: number): void {
    this.rejectIfReadOnly(path)
    this.writable.mkdir(path, mode)
  }

  unlink(path: string, options: { directory: boolean }): void {
    this.rejectIfReadOnly(path)
    this.writable.unlink(path, options)
  }

  /** Remove an empty directory through the writable layer. */
  rmdir(path: string): void {
    this.rejectIfReadOnly(path)
    const rmdir = this.writable.rmdir
    if (typeof rmdir === 'function') rmdir.call(this.writable, path)
    else this.writable.unlink(path, { directory: true })
  }

  rename(from: string, to: string): void {
    this.rejectIfReadOnly(from)
    this.rejectIfReadOnly(to)
    this.writable.rename(from, to)
  }

  sync(): void {
    this.writable.sync()
  }

  private readOnlyEntry(path: string): VfsStat | undefined {
    for (const layer of this.layers) {
      const stat = tryStat(layer, path)
      if (stat !== undefined) return stat
    }
    return undefined
  }

  private rejectsMutation(path: string): boolean {
    const normalized = normalizeAbsolutePath(path)
    for (const layer of this.layers) {
      if (isReadOnlyLayer(layer)) {
        if (layer.isReadOnlyPath(normalized)) return true
        continue
      }
      if (tryStat(layer, normalized) !== undefined) return true
    }
    return false
  }

  private rejectIfReadOnly(path: string): void {
    if (this.rejectsMutation(path)) throw new VfsProxyError('EROFS', 'read-only filesystem', path)
  }
}

function isReadOnlyLayer(layer: WasiVfs): layer is ReadOnlyLayer {
  return typeof (layer as { isReadOnlyPath?: unknown }).isReadOnlyPath === 'function'
}

function byName(left: VfsDirEntry, right: VfsDirEntry): number {
  return left.name < right.name ? -1 : left.name > right.name ? 1 : 0
}

/** Deepest directory shared by every file path, used as the default mount root. */
function commonAncestor(paths: readonly string[]): string {
  const normalized = paths.map(path => normalizeAbsolutePath(path).split('/').slice(1))
  const first = normalized[0]
  if (first === undefined) return '/'
  let length = 0
  while (first[length] !== undefined && normalized.every(parts => parts[length] === first[length])) {
    length += 1
  }
  return length === 0 ? '/' : `/${first.slice(0, length).join('/')}`
}

function tryStat(layer: WasiVfs, path: string): VfsStat | undefined {
  try {
    return layer.stat(path)
  } catch (error) {
    if (error instanceof VfsProxyError && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) return undefined
    throw error
  }
}

function tryReaddir(layer: WasiVfs, path: string): readonly VfsDirEntry[] | undefined {
  try {
    return layer.readdir(path)
  } catch (error) {
    if (error instanceof VfsProxyError && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) return undefined
    throw error
  }
}
