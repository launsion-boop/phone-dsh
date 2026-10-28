// SPDX-License-Identifier: MIT
/**
 * A small in-memory VFS for the namespace regression tests.
 *
 * It is a faithful stand-in for the runtime `MemoryVfs` at the boundary the
 * tests exercise: virtual absolute paths, sink-eligible mutation publishing,
 * the synchronous face `createNamespaceVfs` wraps, and the promise face the
 * shell / python / git adapters consume. It is deliberately not a second
 * implementation of the runtime: it stores bytes and directories only.
 * @module @phone-dsh/dsh-tests/tree-vfs
 */
import type { WorkerEntryMutation, WorkerEntryVfs } from '../worker-entry/src/entry.ts'
import type { NodeFsPromisesLike } from '../wasi-toolbox/src/index.ts'

/** One stored file. */
interface StoredFile {
  bytes: Uint8Array
  mode: number
}

/** Node-shaped error with a code and path. */
function errno(code: string, verb: string, path: string): Error {
  return Object.assign(new Error(`${code}: ${verb}, '${path}'`), { code, path })
}

/** Node-shaped stat face the adapters read. */
export interface TreeStat {
  readonly size: number
  readonly mode: number
  readonly mtimeMs: number
  readonly ino: number
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

/** Node-shaped dirent face the adapters read. */
export interface TreeDirent {
  readonly name: string
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

/** Normalise one virtual path (no `..`, no trailing slash). */
export function treePath(path: string): string {
  if (!path.startsWith('/')) throw errno('EINVAL', 'expected an absolute path', path)
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      parts.pop()
      continue
    }
    parts.push(part)
  }
  return parts.length === 0 ? '/' : `/${parts.join('/')}`
}

/** Options a file write may carry. */
export interface TreeWriteOptions {
  readonly mode?: number
}

/**
 * The in-memory tree. Every write, mkdir, remove and chmod publishes a
 * {@link WorkerEntryMutation}, exactly as the runtime VFS does after commit.
 */
export class TreeVfs implements WorkerEntryVfs {
  private readonly files = new Map<string, StoredFile>()
  private readonly directories = new Set<string>(['/'])
  private readonly directoryModes = new Map<string, number>()
  private readonly listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  /** Every mutation published so far, in order. */
  readonly published: WorkerEntryMutation[] = []
  /** Promise face over the same tree (the shell/python/git adapters use it). */
  readonly promises: NodeFsPromisesLike

  constructor() {
    const self = this
    this.promises = {
      async readFile(path: string): Promise<Uint8Array> {
        return Buffer.from(self.readFileSync(path) as Uint8Array)
      },
      async writeFile(path: string, data: Uint8Array, options?: { readonly mode?: number }): Promise<void> {
        self.writeFileSync(path, data, options)
      },
      async appendFile(path: string, data: Uint8Array): Promise<void> {
        self.appendFileSync(path, data)
      },
      async stat(path: string): Promise<TreeStat> {
        return self.statSync(path)
      },
      async lstat(path: string): Promise<TreeStat> {
        return self.statSync(path)
      },
      async readdir(path: string): Promise<readonly TreeDirent[]> {
        return self.readdirSync(path)
      },
      async mkdir(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): Promise<unknown> {
        return self.mkdirSync(path, options)
      },
      async unlink(path: string): Promise<void> {
        self.unlinkSync(path)
      },
      async rmdir(path: string): Promise<void> {
        self.rmdirSync(path)
      },
      async rm(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): Promise<void> {
        self.rmSync(path, options)
      },
      async rename(from: string, to: string): Promise<void> {
        self.renameSync(from, to)
      },
      async truncate(path: string, length?: number): Promise<void> {
        self.truncateSync(path, length ?? 0)
      },
      async chmod(path: string, mode: number): Promise<void> {
        self.chmodSync(path, mode)
      },
      async access(path: string): Promise<void> {
        self.statSync(path)
      },
      async realpath(path: string): Promise<string> {
        return treePath(path)
      },
      async cp(from: string, to: string): Promise<void> {
        self.cpSync(from, to)
      },
      async link(from: string, to: string): Promise<void> {
        self.linkSync(from, to)
      },
      async open(path: string): Promise<{
        stat(): Promise<{ size: number }>
        read(buffer: Uint8Array, offset: number, length: number, position: number): Promise<{ bytesRead: number }>
        close(): Promise<void>
      }> {
        const bytes = self.readFileSync(path) as Uint8Array
        let moved = 0
        return {
          async stat() { return { size: bytes.byteLength } },
          async read(buffer, offset, length, position) {
            const start = position + moved
            const chunk = bytes.subarray(start, start + length)
            buffer.set(chunk, offset)
            moved += chunk.byteLength
            return { bytesRead: chunk.byteLength }
          },
          async close() {},
        }
      },
    } as NodeFsPromisesLike
  }

  subscribe(listener: (mutation: WorkerEntryMutation) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  async flush(): Promise<void> {}

  private publish(mutation: WorkerEntryMutation): void {
    this.published.push(mutation)
    for (const listener of [...this.listeners]) listener(mutation)
  }

  private isDirectory(path: string): boolean {
    return this.directories.has(path)
  }

  private requireParent(path: string): string {
    const slash = path.lastIndexOf('/')
    const parent = slash <= 0 ? '/' : path.slice(0, slash)
    if (!this.directories.has(parent)) throw errno('ENOENT', 'no such file or directory', path)
    return parent
  }

  readFileSync(path: string): Uint8Array {
    const target = treePath(path)
    const file = this.files.get(target)
    if (file === undefined) {
      if (this.directories.has(target)) throw errno('EISDIR', 'illegal operation on a directory', target)
      throw errno('ENOENT', 'no such file or directory', target)
    }
    return file.bytes
  }

  writeFileSync(path: string, data: string | Uint8Array, options?: TreeWriteOptions): void {
    const target = treePath(path)
    if (this.directories.has(target)) throw errno('EISDIR', 'illegal operation on a directory', target)
    const parent = this.requireParent(target)
    void parent
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data)
    const previous = this.files.get(target)
    this.files.set(target, { bytes, mode: options?.mode ?? previous?.mode ?? 0o644 })
    this.publish({
      kind: 'write',
      path: target,
      bytes: new Uint8Array(bytes),
      mode: options?.mode ?? previous?.mode ?? 0o644,
      entryChanged: previous === undefined,
    })
  }

  appendFileSync(path: string, data: string | Uint8Array): void {
    const target = treePath(path)
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data)
    const previous = this.files.get(target)
    const base = previous?.bytes ?? new Uint8Array(0)
    if (previous === undefined) this.requireParent(target)
    const next = new Uint8Array(base.byteLength + bytes.byteLength)
    next.set(base, 0)
    next.set(bytes, base.byteLength)
    this.files.set(target, { bytes: next, mode: previous?.mode ?? 0o644 })
    this.publish({
      kind: 'write',
      path: target,
      bytes: next,
      mode: previous?.mode ?? 0o644,
      entryChanged: previous === undefined,
      appendedFrom: base.byteLength,
    })
  }

  truncateSync(path: string, length = 0): void {
    const target = treePath(path)
    const previous = this.files.get(target)
    if (previous === undefined) throw errno('ENOENT', 'no such file or directory', target)
    const next = new Uint8Array(length)
    next.set(previous.bytes.subarray(0, Math.min(length, previous.bytes.byteLength)), 0)
    this.files.set(target, { bytes: next, mode: previous.mode })
    this.publish({ kind: 'write', path: target, bytes: next, mode: previous.mode, entryChanged: false })
  }

  existsSync(path: string): boolean {
    const target = treePath(path)
    return this.files.has(target) || this.directories.has(target)
  }

  statSync(path: string): TreeStat {
    const target = treePath(path)
    const file = this.files.get(target)
    if (file !== undefined) {
      return {
        size: file.bytes.byteLength,
        mode: file.mode,
        mtimeMs: 0,
        ino: 1,
        isFile: () => true,
        isDirectory: () => false,
        isSymbolicLink: () => false,
      }
    }
    if (this.directories.has(target)) {
      const mode = this.directoryModes.get(target) ?? 0o755
      return { size: 0, mode, mtimeMs: 0, ino: 1, isFile: () => false, isDirectory: () => true, isSymbolicLink: () => false }
    }
    throw errno('ENOENT', 'no such file or directory', target)
  }

  readdirSync(path: string): TreeDirent[] {
    const target = treePath(path)
    if (!this.directories.has(target)) {
      if (this.files.has(target)) throw errno('ENOTDIR', 'not a directory', target)
      throw errno('ENOENT', 'no such file or directory', target)
    }
    const prefix = target === '/' ? '/' : `${target}/`
    const names = new Set<string>()
    for (const candidate of [...this.files.keys(), ...this.directories]) {
      if (candidate === target || !candidate.startsWith(prefix)) continue
      const name = candidate.slice(prefix.length).split('/')[0] as string
      if (name !== '') names.add(name)
    }
    return [...names].sort().map(name => {
      const full = `${prefix}${name}`
      const directory = this.directories.has(full)
      return { name, isFile: () => !directory, isDirectory: () => directory, isSymbolicLink: () => false }
    })
  }

  mkdirSync(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): string | undefined {
    const target = treePath(path)
    if (this.directories.has(target)) {
      if (options?.recursive === true) return undefined
      throw errno('EEXIST', 'file already exists', target)
    }
    const parts = target.split('/').filter(part => part !== '')
    let current = ''
    for (const part of parts) {
      current += `/${part}`
      if (this.directories.has(current)) continue
      if (!options?.recursive) {
        this.requireParent(current)
      }
      this.directories.add(current)
      const mode = (options?.mode ?? 0o755) & 0o777
      this.directoryModes.set(current, mode)
      this.publish({ kind: 'mkdir', path: current, mode })
    }
    return undefined
  }

  rmSync(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): void {
    const target = treePath(path)
    if (this.files.delete(target)) {
      this.publish({ kind: 'remove', path: target })
      return
    }
    if (this.directories.has(target)) {
      const children = [...this.directories].filter(candidate => candidate.startsWith(`${target}/`))
      const files = [...this.files.keys()].filter(candidate => candidate.startsWith(`${target}/`))
      if (children.length > 0 && options?.recursive !== true) throw errno('ENOTEMPTY', 'directory not empty', target)
      for (const file of files) this.files.delete(file)
      for (const directory of children.sort((left, right) => right.length - left.length)) this.directories.delete(directory)
      this.directories.delete(target)
      this.publish({ kind: 'remove', path: target })
      return
    }
    if (options?.force === true) return
    throw errno('ENOENT', 'no such file or directory', target)
  }

  rmdirSync(path: string): void {
    const target = treePath(path)
    if (!this.directories.has(target)) throw errno('ENOENT', 'no such file or directory', target)
    const child = [...this.directories].some(candidate => candidate !== target && candidate.startsWith(`${target}/`))
    if (child) throw errno('ENOTEMPTY', 'directory not empty', target)
    this.directories.delete(target)
    this.publish({ kind: 'remove', path: target })
  }

  unlinkSync(path: string): void {
    const target = treePath(path)
    if (!this.files.delete(target)) throw errno('ENOENT', 'no such file or directory', target)
    this.publish({ kind: 'remove', path: target })
  }

  renameSync(from: string, to: string): void {
    const source = treePath(from)
    const target = treePath(to)
    const file = this.files.get(source)
    if (file === undefined) throw errno('ENOENT', 'no such file or directory', source)
    this.requireParent(target)
    this.files.delete(source)
    this.files.set(target, file)
    this.publish({ kind: 'remove', path: source })
    this.publish({ kind: 'write', path: target, bytes: file.bytes, mode: file.mode, entryChanged: true })
  }

  cpSync(from: string, to: string): void {
    const source = treePath(from)
    const target = treePath(to)
    const file = this.files.get(source)
    if (file === undefined) throw errno('ENOENT', 'no such file or directory', source)
    this.writeFileSync(target, file.bytes, { mode: file.mode })
  }

  linkSync(from: string, to: string): void {
    const source = treePath(from)
    const target = treePath(to)
    const file = this.files.get(source)
    if (file === undefined) throw errno('ENOENT', 'no such file or directory', source)
    this.requireParent(target)
    this.files.set(target, file)
    this.publish({ kind: 'write', path: target, bytes: file.bytes, mode: file.mode, entryChanged: true })
  }

  chmodSync(path: string, mode: number): void {
    const target = treePath(path)
    const file = this.files.get(target)
    if (file !== undefined) {
      this.files.set(target, { bytes: file.bytes, mode: mode & 0o777 })
      this.publish({ kind: 'chmod', path: target, mode: mode & 0o777 })
      return
    }
    if (this.directories.has(target)) {
      this.directoryModes.set(target, mode & 0o777)
      this.publish({ kind: 'chmod', path: target, mode: mode & 0o777 })
      return
    }
    throw errno('ENOENT', 'no such file or directory', target)
  }

  realpathSync(path: string): string {
    return treePath(path)
  }

  whenReadable(): undefined {
    return undefined
  }

  /** Replay only the durable (sink) mutations into a fresh tree — park/resume. */
  static replay(mutations: readonly WorkerEntryMutation[]): TreeVfs {
    const tree = new TreeVfs()
    for (const mutation of mutations) {
      if (!/^\/dsh\/(?:home|workspace)\//.test(mutation.path)) continue
      tree.apply(mutation)
    }
    return tree
  }

  /** Apply one mutation without publishing it. */
  apply(mutation: WorkerEntryMutation): void {
    switch (mutation.kind) {
      case 'write':
        this.mkdirParents(mutation.path)
        this.files.set(treePath(mutation.path), { bytes: new Uint8Array(mutation.bytes), mode: mutation.mode })
        return
      case 'mkdir': {
        this.mkdirParents(mutation.path)
        const directory = treePath(mutation.path)
        this.directories.add(directory)
        this.directoryModes.set(directory, mutation.mode & 0o777)
        return
      }
      case 'remove':
        this.files.delete(treePath(mutation.path))
        this.directories.delete(treePath(mutation.path))
        return
      case 'chmod': {
        const target = treePath(mutation.path)
        const file = this.files.get(target)
        if (file !== undefined) this.files.set(target, { bytes: file.bytes, mode: mutation.mode & 0o777 })
        return
      }
    }
  }

  private mkdirParents(path: string): void {
    const parts = treePath(path).split('/').filter(part => part !== '')
    let current = ''
    for (const part of parts.slice(0, -1)) {
      current += `/${part}`
      this.directories.add(current)
    }
  }
}
