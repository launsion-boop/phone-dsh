// SPDX-License-Identifier: MIT
/**
 * G2-FIX-29 regression: the single-file budget is enforced at both
 * Worker write surfaces — the shell's `VfsFileSystem` and the WASI toolbox
 * backends that `python3` uses — before the in-memory VFS publishes a mutation.
 *
 * The defect: a `yes ... >> file` append past the single-file budget first succeeded in the
 * Worker VFS; the sink's publish-time EFBIG guard then called `failLoud`,
 * closed the ordered channel, and the dispatched `bash` call never produced a
 * tool result (transcript tool_use without tool_result, journal start without
 * finish, ~521 s of silence until the wall-clock budget). G2-A09's rerun then
 * exposed the same shape through `python3` and the WASI `NodeFsBackend`, which
 * had no guard at all.
 *
 * These tests drive the real `WorkerShell`/`VfsFileSystem` and the real
 * `VfsProxyServer`/`NodeFsBackend` over a deterministic `MemoryVfs` double
 * that publishes mutations the same way the runtime's `MemoryVfs` does
 * (synchronously, swallowing observer errors), with the real sink over an
 * in-memory channel pair. Before the fix the write is a command success and
 * the sink closes the channel; after the fix the command itself fails with
 * EFBIG and the channel/session stay usable.
 */
import assert from 'node:assert/strict'
import type { Stats } from 'node:fs'
import { posix } from 'node:path'
import { test } from 'node:test'
import {
  createMemoryChannelPair, decodeUtf8, decodeVfsMutation,
  FrameType,
  type Frame, type MemoryChannelPair,
} from '../../channel/src/index.ts'
import {
  MAX_FILE_SIZE, VfsFileSystem, WorkerShell,
  type VfsDirentLike, type VfsFileSystemIo, type VfsReaddirSync,
} from '../../shell-ext/src/index.ts'
import { NodeFsBackend, VfsProxyServer } from '../../wasi-toolbox/src/index.ts'
import type { NodeFsPromisesLike } from '../../wasi-toolbox/src/index.ts'
import { installSink, type WorkerEntryMutation } from './entry.ts'

/** A node:fs-shaped ENOENT. */
function enoent(path: string, syscall: string): Error {
  return Object.assign(new Error(`ENOENT: no such file or directory, ${syscall} '${path}'`), {
    code: 'ENOENT',
    path,
    syscall,
  })
}

/** Bytes exactly as `node:fs` would store `data` under `encoding`. */
function storedBytes(data: string | Uint8Array, encoding?: BufferEncoding): Uint8Array {
  return typeof data === 'string' ? new Uint8Array(Buffer.from(data, encoding ?? 'utf8')) : new Uint8Array(data)
}

/**
 * Deterministic in-memory VFS with the publish contract of the runtime's
 * `MemoryVfs`: a write updates the tree first and then calls every observer
 * synchronously; an observer failure is recorded and swallowed so the caller
 * still sees a successful write.
 */
class MemoryVfs {
  private readonly files = new Map<string, Uint8Array>()
  private readonly directories = new Set<string>(['/', '/dsh', '/dsh/home', '/dsh/workspace', '/dsh/tmp'])
  private readonly listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  /** Observer failures the tree swallowed, exactly as `MemoryVfs.publish` does. */
  readonly observerErrors: unknown[] = []

  readonly nodeFs: VfsFileSystemIo
  readonly readdirSync: VfsReaddirSync
  /** The same tree seen through the `node:fs/promises` face the WASI backend uses. */
  readonly promises: NodeFsPromisesLike

  constructor() {
    const io: VfsFileSystemIo = {
      readFile: async (path) => Buffer.from(this.file(path)),
      writeFile: async (path, data, options) => { this.write(path, storedBytes(data, options?.encoding), true) },
      appendFile: async (path, data, options) => { this.append(path, storedBytes(data, options?.encoding)) },
      stat: async (path) => this.statOf(path),
      lstat: async (path) => this.statOf(path),
      access: async (path) => {
        if (!this.files.has(path) && !this.directories.has(path)) throw enoent(path, 'access')
      },
      mkdir: async (path) => {
        this.directories.add(path)
      },
      readdir: async (path, options) => this.dirents(path, options?.withFileTypes === true),
      rm: async (path) => {
        this.files.delete(path)
        this.directories.delete(path)
      },
      rmdir: async (path) => {
        this.directories.delete(path)
      },
      cp: async (src, dest) => {
        this.write(dest, this.file(src), true)
      },
      rename: async (from, to) => {
        const bytes = this.file(from)
        this.files.delete(from)
        this.files.set(to, bytes)
      },
      chmod: async () => {},
      link: async (existing, next) => {
        this.files.set(next, this.file(existing))
      },
    }
    this.nodeFs = io
    this.readdirSync = path => this.dirents(path, true) as VfsDirentLike[]
    this.promises = {
      stat: async path => this.statOf(path),
      readdir: async (path, options) => this.dirents(path, options.withFileTypes),
      readFile: async path => Buffer.from(this.file(path)),
      writeFile: async (path, data) => { this.write(path, new Uint8Array(data), true) },
      mkdir: async path => { this.directories.add(path) },
      unlink: async path => { this.files.delete(path) },
      rmdir: async path => { this.directories.delete(path) },
      rm: async path => {
        this.files.delete(path)
        this.directories.delete(path)
      },
      rename: async (from, to) => {
        const bytes = this.file(from)
        this.files.delete(from)
        this.files.set(to, bytes)
      },
      truncate: async (path, length) => {
        const bytes = this.file(path)
        const size = length ?? 0
        const resized = new Uint8Array(size)
        resized.set(bytes.subarray(0, size))
        this.files.set(path, resized)
      },
      chmod: async () => {},
    }
  }

  /** Put bytes in the tree without publishing (image seeding, test fixtures). */
  seed(path: string, bytes: Uint8Array): void {
    this.files.set(path, new Uint8Array(bytes))
  }

  /** Current size, read directly from the double for assertions. */
  sizeOf(path: string): number {
    return this.file(path).byteLength
  }

  subscribe(listener: (mutation: WorkerEntryMutation) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  async flush(): Promise<void> {}

  private file(path: string): Uint8Array {
    const bytes = this.files.get(path)
    if (bytes === undefined) throw enoent(path, 'open')
    return bytes
  }

  private statOf(path: string): Stats {
    const bytes = this.files.get(path)
    const isFile = bytes !== undefined
    if (!isFile && !this.directories.has(path)) throw enoent(path, 'stat')
    return {
      size: bytes?.byteLength ?? 0,
      mode: isFile ? 0o100644 : 0o040755,
      mtime: new Date(0),
      dev: 0,
      ino: 1,
      isFile: () => isFile,
      isDirectory: () => !isFile,
      isSymbolicLink: () => false,
    } as unknown as Stats
  }

  private dirents(path: string, withTypes: boolean): string[] | VfsDirentLike[] {
    const prefix = path === '/' ? '/' : `${path}/`
    const names = new Set<string>()
    for (const known of [...this.files.keys(), ...this.directories]) {
      if (!known.startsWith(prefix)) continue
      const rest = known.slice(prefix.length)
      if (rest !== '') names.add(rest.split('/')[0] as string)
    }
    const sorted = [...names].sort()
    if (!withTypes) return sorted
    return sorted.map(name => {
      const child = posix.join(path, name)
      const file = this.files.has(child)
      return {
        name,
        isFile: () => file,
        isDirectory: () => !file,
        isSymbolicLink: () => false,
      }
    })
  }

  /** Publish after the tree changed; an observer failure cannot roll it back. */
  private publish(mutation: WorkerEntryMutation): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(mutation)
      } catch (error) {
        this.observerErrors.push(error)
      }
    }
  }

  private write(path: string, bytes: Uint8Array, entryChanged: boolean): void {
    this.files.set(path, bytes)
    this.publish({ kind: 'write', path, bytes, mode: 0o644, entryChanged })
  }

  private append(path: string, addition: Uint8Array): void {
    const existing = this.files.get(path)
    if (existing === undefined) {
      this.write(path, addition, true)
      return
    }
    const bytes = new Uint8Array(existing.byteLength + addition.byteLength)
    bytes.set(existing)
    bytes.set(addition, existing.byteLength)
    this.files.set(path, bytes)
    // The runtime publishes the complete post-write bytes plus the append
    // offset; the sink takes the suffix from there.
    this.publish({
      kind: 'write', path, bytes, mode: 0o644, entryChanged: false, appendedFrom: existing.byteLength,
    })
  }
}

/** One connected pair plus the frames the host received. */
function fixture(): { vfs: MemoryVfs; pair: MemoryChannelPair; frames: Frame[]; dispose: () => void } {
  const vfs = new MemoryVfs()
  const pair = createMemoryChannelPair({ autoConnect: true, nextMseq: 7n, autoAck: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => frames.push(frame))
  const dispose = installSink(vfs, pair.worker)
  return { vfs, pair, frames, dispose }
}

function vfsMutations(frames: readonly Frame[]): ReturnType<typeof decodeVfsMutation>[] {
  return frames.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
}

test('G2-FIX-29: an append past the single-file budget fails as the command error, not as a channel close', async () => {
  assert.equal(MAX_FILE_SIZE, 64 * 1024 * 1024, 'the write cap is the 8 GiB tier single-file budget')
  const { vfs, pair, frames, dispose } = fixture()
  try {
    // A file already at the exact single-file limit; one more byte must be refused.
    vfs.seed('/dsh/workspace/testdata.bin', new Uint8Array(MAX_FILE_SIZE))
    const fs = new VfsFileSystem({ nodeFs: vfs.nodeFs, readdirSync: vfs.readdirSync })
    const shell = new WorkerShell({ fs })

    const refused = await shell.run(['bash', '-c', "printf 'x' >> testdata.bin"], { cwd: '/dsh/workspace' })
    // Before the fix this is where the defect shows: the write already
    // succeeded in the VFS, the sink guard threw EFBIG (recorded here) and
    // closed the ordered channel; the command itself exited 0.
    assert.deepEqual(vfs.observerErrors, [], 'the refusal happens at the write surface, before the VFS publishes')
    assert.equal(
      refused.exitCode !== 0,
      true,
      `the over-limit append must be the command's own error; got exit ${refused.exitCode}, stderr ${JSON.stringify(refused.stderr)}`,
    )
    assert.match(refused.stderr, /EFBIG/)
    assert.match(refused.stderr, /File too large/)
    assert.equal(refused.stderr.includes(String(MAX_FILE_SIZE)), true, 'the message names the 64 MiB byte limit')
    assert.match(refused.stderr, /64 MiB/)

    // The refused write never reached the VFS sink: no oversized frame, no
    // ERROR frame, and the channel was not closed. The shell bootstrap itself
    // is allowed exactly one published artifact — the capability manifest the
    // not-available hint names (G2-FIX-58) — and nothing from this command.
    assert.equal(vfs.sizeOf('/dsh/workspace/testdata.bin'), MAX_FILE_SIZE)
    const afterRefusal = vfsMutations(frames)
    assert.deepEqual(afterRefusal.filter(mutation => mutation.path === '/dsh/workspace/testdata.bin'), [])
    assert.equal(
      afterRefusal.every(mutation => mutation.path === '/dsh/home/capabilities.json'),
      true,
      `only the capability manifest may be published here: ${JSON.stringify(afterRefusal.map(mutation => mutation.path))}`,
    )
    assert.equal(frames.some(frame => frame.type === FrameType.ERROR), false, 'the refusal is not a channel teardown')

    // The session stays usable: the very next small write is published and
    // acknowledged on the same open channel.
    const accepted = await shell.run(['bash', '-c', "printf 'ok' > after.txt"], { cwd: '/dsh/workspace' })
    assert.equal(accepted.exitCode, 0)
    assert.equal(await fs.readFile('/dsh/workspace/after.txt'), 'ok')
    const mutations = vfsMutations(frames)
    assert.ok(mutations.length >= 1, 'the follow-up write reached the sink')
    assert.equal(
      mutations.filter(mutation => mutation.path !== '/dsh/home/capabilities.json')
        .every(mutation => mutation.path === '/dsh/workspace/after.txt'),
      true,
      `the follow-up write is the only command mutation: ${JSON.stringify(mutations.map(mutation => mutation.path))}`,
    )
    assert.equal(decodeUtf8(mutations.at(-1)!.data), 'ok')
    assert.equal(vfs.observerErrors.length, 0)
    await pair.worker.waitAck(1, mutations.at(-1)!.mseq)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-FIX-29: a WASI guest (python3) write past the single-file budget is refused before the VFS publishes', async () => {
  const { vfs, pair, frames, dispose } = fixture()
  try {
    // G2-A09's real failure path: python3 writes through the WASI VFS proxy,
    // whose production backend is `NodeFsBackend` over the runtime's
    // `node:fs/promises`. This adapter is not the shell's `VfsFileSystem`, so
    // the shell-ext guard never ran: the 16 MiB write landed in the VFS and
    // the sink's publish-time guard closed the channel.
    vfs.seed('/dsh/workspace/testdata.bin', new Uint8Array(MAX_FILE_SIZE))
    const backend = new NodeFsBackend(vfs.promises)
    const server = new VfsProxyServer({
      backend,
      preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    })

    const refused = await server.execute({
      op: 'write',
      path: '/dsh/workspace/testdata.bin',
      offset: MAX_FILE_SIZE,
      append: false,
      create: false,
      data: new Uint8Array(1),
    })
    // Before the fix the backend stores the 15728641-byte file, the real sink
    // throws EFBIG, failLoud closes the channel, and this response is `ok`.
    assert.equal(refused.ok, false, 'the over-limit WASI write must fail as the guest command error')
    if (refused.ok) return
    assert.equal(refused.code, 'EFBIG')
    assert.match(refused.message, /File too large/)
    assert.equal(refused.message.includes(String(MAX_FILE_SIZE)), true, 'the message names the 64 MiB byte limit')

    // The refusal happened before the VFS mutation: the tree keeps the exact
    // limit, no observer error was swallowed, and no channel teardown started.
    assert.equal(vfs.sizeOf('/dsh/workspace/testdata.bin'), MAX_FILE_SIZE)
    assert.deepEqual(vfs.observerErrors, [])
    assert.equal(frames.some(frame => frame.type === FrameType.ERROR), false, 'the refusal is not a channel teardown')

    // The same channel/session still accepts the next ordinary WASI write.
    const accepted = await server.execute({
      op: 'write',
      path: '/dsh/workspace/after.txt',
      offset: 0,
      append: false,
      create: true,
      data: new TextEncoder().encode('ok'),
    })
    assert.equal(accepted.ok, true)
    assert.equal(new TextDecoder().decode(await vfs.promises.readFile('/dsh/workspace/after.txt') as Uint8Array), 'ok')
    const mutations = vfsMutations(frames)
    assert.equal(mutations.length, 1)
    assert.equal(mutations[0]?.path, '/dsh/workspace/after.txt')
    await pair.worker.waitAck(1, mutations[0]!.mseq)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-FIX-29: every NodeFsBackend write form refuses a post-write file above the single-file budget', async () => {
  const { vfs, pair, frames, dispose } = fixture()
  try {
    const backend = new NodeFsBackend(vfs.promises)
    await assert.rejects(
      backend.writeFile('/dsh/workspace/full.bin', new Uint8Array(MAX_FILE_SIZE + 1), { create: true }),
      (error: unknown) => (error as { code?: string }).code === 'EFBIG',
    )
    vfs.seed('/dsh/workspace/testdata.bin', new Uint8Array(MAX_FILE_SIZE))
    await assert.rejects(
      backend.writeFile('/dsh/workspace/testdata.bin', new Uint8Array(1), { append: true, create: false }),
      (error: unknown) => (error as { code?: string }).code === 'EFBIG',
    )
    vfs.seed('/dsh/workspace/resize.bin', new Uint8Array(0))
    await assert.rejects(
      backend.truncate('/dsh/workspace/resize.bin', MAX_FILE_SIZE + 1),
      (error: unknown) => (error as { code?: string }).code === 'EFBIG',
    )
    assert.equal(vfs.sizeOf('/dsh/workspace/testdata.bin'), MAX_FILE_SIZE)
    assert.equal(vfs.sizeOf('/dsh/workspace/resize.bin'), 0)
    assert.deepEqual(vfs.observerErrors, [])
    assert.equal(frames.some(frame => frame.type === FrameType.ERROR), false)

    // The backend remains usable for a legal write on the same channel.
    await backend.writeFile('/dsh/workspace/after.txt', new TextEncoder().encode('ok'), { create: true })
    assert.equal(new TextDecoder().decode(await vfs.promises.readFile('/dsh/workspace/after.txt') as Uint8Array), 'ok')
    const mutations = vfsMutations(frames)
    assert.equal(mutations.at(-1)?.path, '/dsh/workspace/after.txt')
    await pair.worker.waitAck(1, mutations.at(-1)!.mseq)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-FIX-29: a complete write above the single-file budget is refused before node:fs runs', async () => {
  const { vfs, pair, frames, dispose } = fixture()
  try {
    const fs = new VfsFileSystem({ nodeFs: vfs.nodeFs, readdirSync: vfs.readdirSync })
    await assert.rejects(
      fs.writeFile('/dsh/workspace/full.bin', new Uint8Array(MAX_FILE_SIZE + 1)),
      (error: unknown) => {
        const coded = error as { code?: string; message?: string }
        assert.equal(coded.code, 'EFBIG')
        assert.match(String(coded.message), /File too large/)
        assert.equal(String(coded.message).includes(String(MAX_FILE_SIZE)), true, 'the message names the 64 MiB byte limit')
        assert.match(String(coded.message), /64 MiB/)
        return true
      },
    )
    // The adapter refused before the VFS write, so nothing was published and
    // the tree is unchanged.
    assert.deepEqual(vfs.observerErrors, [])
    assert.deepEqual(vfsMutations(frames), [])
    assert.equal(await fs.exists('/dsh/workspace/full.bin'), false)

    // A copy is a whole-file write at the destination too: a source over the
    // limit is refused before the destination is created.
    vfs.seed('/dsh/workspace/huge.bin', new Uint8Array(MAX_FILE_SIZE + 1))
    await assert.rejects(
      fs.cp('/dsh/workspace/huge.bin', '/dsh/workspace/copy.bin'),
      (error: unknown) => (error as { code?: string }).code === 'EFBIG',
    )
    assert.deepEqual(vfs.observerErrors, [])
    assert.equal(await fs.exists('/dsh/workspace/copy.bin'), false)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-FIX-29: concurrent appends to one target cannot both pass the size check', async () => {
  const { vfs, pair, frames, dispose } = fixture()
  try {
    vfs.seed('/dsh/workspace/race.bin', new Uint8Array(MAX_FILE_SIZE - 2))
    // subprocess-xl builds one adapter per bash command; two instances over the
    // same VFS must still share the per-target append queue.
    const first = new VfsFileSystem({ nodeFs: vfs.nodeFs, readdirSync: vfs.readdirSync })
    const second = new VfsFileSystem({ nodeFs: vfs.nodeFs, readdirSync: vfs.readdirSync })
    const outcomes = await Promise.allSettled([
      first.appendFile('/dsh/workspace/race.bin', 'ab'),
      second.appendFile('/dsh/workspace/race.bin', 'cd'),
    ])
    const rejected = outcomes.filter((outcome): outcome is PromiseRejectedResult => outcome.status === 'rejected')
    const accepted = outcomes.filter(outcome => outcome.status === 'fulfilled')
    assert.equal(accepted.length, 1, 'exactly one append fits the remaining two bytes')
    assert.equal(rejected.length, 1)
    assert.equal((rejected[0]?.reason as { code?: string }).code, 'EFBIG')
    // The second append never reached the VFS: the tree keeps the exact limit
    // and the sink never had to close the channel.
    assert.equal(vfs.sizeOf('/dsh/workspace/race.bin'), MAX_FILE_SIZE)
    assert.deepEqual(vfs.observerErrors, [])
    assert.equal(frames.some(frame => frame.type === FrameType.ERROR), false)
  } finally {
    dispose()
    await pair.worker.close()
  }
})
