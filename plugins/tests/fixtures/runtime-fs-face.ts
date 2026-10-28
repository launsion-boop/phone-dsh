// SPDX-License-Identifier: MIT
/**
 * `node:fs/promises`-shaped test face that mirrors the DSH Worker's
 * `MemoryVfs.promises` object, the face the WASI toolbox sees in production.
 *
 * The runtime face has no `rmdir`. Its `unlink` covers files only and answers
 * `ENOENT` for a directory, and `rm` refuses a directory unless `recursive` is
 * true with the runtime's own `ERR_FS_EISDIR` code. Keeping that exact shape
 * in tests is what makes a toolbox directory-removal regression reproduce on
 * this side of the Worker boundary: a face with `rmdir` (Node's own
 * `node:fs/promises`) hides the defect.
 * @module @phone-dsh/dsh-tests/runtime-fs-face
 */
import { VfsProxyError } from '../../wasi-toolbox/src/errors.ts'
import { MemoryVfsBackend } from '../../wasi-toolbox/src/vfs-backends.ts'
import type {
  NodeFsDirentLike, NodeFsPromisesLike, NodeFsStatsLike,
} from '../../wasi-toolbox/src/vfs-backends.ts'
import type { VfsStat } from '../../wasi-toolbox/src/types.ts'

function statsLike(stat: VfsStat): NodeFsStatsLike {
  return {
    size: stat.size,
    mode: stat.mode,
    mtimeMs: stat.mtimeMs,
    ino: stat.ino,
    isFile: () => stat.kind === 'file',
    isDirectory: () => stat.kind === 'directory',
    isSymbolicLink: () => stat.kind === 'symlink',
  }
}

function direntLike(entry: { readonly name: string; readonly kind: string }): NodeFsDirentLike {
  return {
    name: entry.name,
    isFile: () => entry.kind === 'file',
    isDirectory: () => entry.kind === 'directory',
    isSymbolicLink: () => entry.kind === 'symlink',
  }
}

/**
 * Build the runtime-shaped promise face over an in-memory tree.
 *
 * Every method delegates to {@link MemoryVfsBackend} so the data model stays
 * ours; only the *shape* (which primitives exist and what they refuse) follows
 * the runtime. A missing path therefore rejects with `ENOENT`, an `unlink` of
 * a directory with `ENOENT`, and a non-recursive `rm` of a directory with
 * `ERR_FS_EISDIR`, exactly as `MemoryVfs.promises` does.
 * @param backend - tree the face stores bytes in.
 * @returns a `node:fs/promises`-shaped face without `rmdir`.
 */
export function runtimeFsFace(backend = new MemoryVfsBackend()): NodeFsPromisesLike {
  return {
    async stat(path: string): Promise<NodeFsStatsLike> {
      return statsLike(backend.stat(path))
    },
    async lstat(path: string): Promise<NodeFsStatsLike> {
      return statsLike(backend.stat(path))
    },
    async readdir(path: string): Promise<readonly NodeFsDirentLike[]> {
      return backend.readdir(path).map(direntLike)
    },
    async readFile(path: string): Promise<Uint8Array> {
      return backend.readFile(path)
    },
    async writeFile(
      path: string,
      data: Uint8Array,
      options?: { readonly mode?: number },
    ): Promise<void> {
      backend.writeFile(path, data, {
        create: true,
        ...(options?.mode === undefined ? {} : { mode: options.mode }),
      })
    },
    async appendFile(path: string, data: Uint8Array): Promise<void> {
      backend.writeFile(path, data, { append: true, create: true })
    },
    async mkdir(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): Promise<void> {
      if (options?.recursive !== true) {
        backend.mkdir(path, options?.mode)
        return
      }
      let current = ''
      for (const part of path.split('/')) {
        if (part === '') continue
        current += `/${part}`
        try {
          backend.mkdir(current, options.mode)
        } catch (error) {
          // The runtime's recursive mkdir treats an existing directory as a
          // successful no-op; only other failures propagate.
          if (!(error instanceof VfsProxyError) || error.code !== 'EEXIST') throw error
        }
      }
    },
    async unlink(path: string): Promise<void> {
      // `MemoryVfs.unlinkSync` only knows files: a directory is reported as a
      // missing file, not as EISDIR.
      if (backend.stat(path).kind === 'directory') {
        throw new VfsProxyError('ENOENT', 'no such file or directory', path)
      }
      backend.unlink(path, { directory: false })
    },
    async rm(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): Promise<void> {
      const stat = backend.stat(path)
      if (stat.kind !== 'directory') {
        backend.unlink(path, { directory: false })
        return
      }
      if (options?.recursive !== true) {
        throw Object.assign(new Error(`ERR_FS_EISDIR: rm failed, rm '${path}'`), {
          code: 'ERR_FS_EISDIR',
          path,
          syscall: 'rm',
        })
      }
      backend.unlink(path, { directory: true, recursive: true })
    },
    async rename(from: string, to: string): Promise<void> {
      backend.rename(from, to)
    },
    async truncate(path: string, length?: number): Promise<void> {
      backend.truncate(path, length ?? 0)
    },
    async chmod(path: string, mode: number): Promise<void> {
      // Permission bits are not stored by the memory backend; like the runtime
      // face, an existing entry accepts the call and a missing one fails.
      backend.stat(path)
      void mode
    },
  }
}
