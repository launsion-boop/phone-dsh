// SPDX-License-Identifier: MIT
/**
 * Synchronous in-memory `WasiVfs` used by unit tests and by hosts that run the
 * WASI core without a proxy (a program that only touches stdio). It extends the
 * in-memory backend so both share one set of POSIX-ish errors.
 * @module @phone-dsh/dsh-wasi-toolbox/memory-wasi-vfs
 */
import { VfsProxyError } from './errors.ts'
import { MemoryVfsBackend } from './vfs-backends.ts'
import type { VfsDirEntry, VfsOpenOptions, VfsStat, WasiVfs } from './types.ts'

/** `WasiVfs` over the in-memory backend, with no proxying. */
export class MemoryWasiVfs extends MemoryVfsBackend implements WasiVfs {
  override stat(path: string): VfsStat {
    return super.stat(path) as VfsStat
  }

  override readdir(path: string): readonly VfsDirEntry[] {
    return super.readdir(path)
  }

  override readFile(path: string): Uint8Array {
    return super.readFile(path)
  }

  override writeFile(
    path: string,
    data: Uint8Array,
    options: { create?: boolean; append?: boolean; truncate?: boolean; mode?: number } = {},
  ): void {
    super.writeFile(path, data, options)
  }

  open(path: string, options: VfsOpenOptions): VfsStat {
    if (options.directory) {
      const stat = this.stat(path)
      if (stat.kind !== 'directory') throw new VfsProxyError('ENOTDIR', 'not a directory', path)
      return stat
    }
    let stat: VfsStat | undefined
    try {
      stat = this.stat(path)
    } catch (error) {
      if (!(error instanceof VfsProxyError) || error.code !== 'ENOENT') throw error
    }
    if (stat === undefined) {
      if (!options.create) throw new VfsProxyError('ENOENT', 'no such file or directory', path)
      this.writeFile(path, new Uint8Array(0), {
        create: true,
        ...(options.mode === undefined ? {} : { mode: options.mode }),
      })
      return this.stat(path)
    }
    if (stat.kind === 'directory') throw new VfsProxyError('EISDIR', 'is a directory', path)
    if (options.exclusive) throw new VfsProxyError('EEXIST', 'file exists', path)
    if (options.truncate) this.writeFile(path, new Uint8Array(0), { create: false })
    return this.stat(path)
  }

  read(path: string, offset: number, length: number): Uint8Array {
    return this.readFile(path).slice(Math.max(0, offset), Math.max(0, offset) + Math.max(0, length))
  }

  write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { append: boolean; create: boolean; mode?: number },
  ): number {
    if (options.append) {
      this.writeFile(path, data, {
        append: true,
        create: options.create,
        ...(options.mode === undefined ? {} : { mode: options.mode }),
      })
      return data.byteLength
    }
    let existing: Uint8Array = new Uint8Array(0)
    try {
      existing = this.readFile(path)
    } catch (error) {
      if (!(error instanceof VfsProxyError) || error.code !== 'ENOENT' || !options.create) throw error
    }
    const target = Math.max(0, offset)
    const next = new Uint8Array(Math.max(existing.byteLength, target + data.byteLength))
    next.set(existing, 0)
    next.set(data, target)
    this.writeFile(path, next, {
      create: options.create,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
    })
    return data.byteLength
  }

  /** Remove an empty directory; the backend enforces the POSIX errnos. */
  rmdir(path: string): void {
    this.unlink(path, { directory: true })
  }
}
