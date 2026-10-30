// SPDX-License-Identifier: MIT
/**
 * Large-file publication regression (ENG-07).
 *
 * The sink used to treat the 15 MiB VFS_MUT payload cap as the single-file
 * cap: a 60 MiB complete write was refused as EFBIG, and a VFS_RESYNC for the
 * same file answered VFS_CONFLICT and closed the ordered channel. channel.md
 * §3.1 now publishes one file as one complete write plus appended suffixes,
 * each at the next normal mseq, so the class disappears without raising the
 * frame cap.
 *
 * These tests drive the real sink and the in-memory ordered channel: the
 * first one fails on the pre-fix tree because a 60 MiB mutation is refused
 * before any frame is sent.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, truncateSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  createMemoryChannelPair, decodeVfsMutation, encodeVfsMutation, encodeVfsResync, FrameType,
  MAX_MUTATION_DATA,
  type Frame, type MemoryChannelPair,
} from '../channel/src/index.ts'
import {
  installResyncHandler, installSink, type WorkerEntryMutation,
} from '../worker-entry/src/entry.ts'
import {
  MAX_FILE_READ_SIZE, MAX_FILE_SIZE, VfsFileSystem, parseShellTrailer,
} from '../shell-ext/src/index.ts'

const MIB = 1024 * 1024

/** Minimal VFS with the runtime's synchronous publish contract. */
class BigVfs {
  private readonly listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  readonly observerErrors: unknown[] = []
  private readonly files = new Map<string, Uint8Array>()

  subscribe(listener: (mutation: WorkerEntryMutation) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  async flush(): Promise<void> {}

  seed(path: string, bytes: Uint8Array): void {
    this.files.set(path, bytes)
  }

  /** Runtime `MemoryVfs.readFileSync` face used by the resync handler. */
  readFileSync(path: string): Uint8Array {
    return this.file(path)
  }

  /** Runtime `MemoryVfs.statSync` face used by the resync handler. */
  statSync(_path: string): { readonly mode: number; isFile(): boolean } {
    return { mode: 0o100644, isFile: () => true }
  }

  file(path: string): Uint8Array {
    const bytes = this.files.get(path)
    if (bytes === undefined) throw new Error(`missing ${path}`)
    return bytes
  }

  emit(mutation: WorkerEntryMutation): void {
    if (mutation.kind === 'write') this.files.set(mutation.path, mutation.bytes)
    for (const listener of [...this.listeners]) {
      try {
        listener(mutation)
      } catch (error) {
        this.observerErrors.push(error)
      }
    }
  }
}

function connect(options: Parameters<typeof createMemoryChannelPair>[0] = {}): MemoryChannelPair {
  return createMemoryChannelPair({ autoConnect: true, ...options })
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
}

function mutationsOf(frames: readonly Frame[]): ReturnType<typeof decodeVfsMutation>[] {
  return frames.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
}

/** Replay the host-side materializer view of a write + appended chain. */
function materialize(mutations: readonly ReturnType<typeof decodeVfsMutation>[]): Uint8Array {
  let file = new Uint8Array(0)
  for (const mutation of mutations) {
    if (mutation.path !== '/dsh/workspace/big.bin') continue
    const appended = (mutation.mflags & 2) !== 0
    if (!appended) {
      file = mutation.data.slice()
      continue
    }
    const from = Number(mutation.appendFrom)
    assert.equal(from, file.byteLength, 'an appended mutation follows the current logical length')
    const next = new Uint8Array(file.byteLength + mutation.data.byteLength)
    next.set(file)
    next.set(mutation.data, from)
    file = next
  }
  return file
}

/** Source bytes with a non-repeating byte per 4 KiB page, so order is checked. */
function sourceBytes(size: number): Uint8Array {
  const bytes = new Uint8Array(size)
  for (let offset = 0; offset < size; offset += 4096) {
    bytes.fill((offset / 4096) & 0xff, offset, Math.min(offset + 4096, size))
  }
  return bytes
}

function assertSameBytes(actual: Uint8Array, expected: Uint8Array): void {
  assert.equal(actual.byteLength, expected.byteLength)
  for (let index = 0; index < actual.byteLength; index++) {
    if (actual[index] !== expected[index]) {
      assert.fail(`byte ${index} differs: ${String(actual[index])} != ${String(expected[index])}`)
    }
  }
}

test('ENG-07: a 60 MiB write is one complete write plus appended suffixes', async () => {
  const pair = connect({ nextMseq: 1n, ackedMseq: 0n, autoAck: true })
  const vfs = new BigVfs()
  const hostFrames: Frame[] = []
  pair.host.onFrame(frame => hostFrames.push(frame))
  const dispose = installSink(vfs, pair.worker)
  try {
    const source = sourceBytes(60 * MIB)
    vfs.emit({
      kind: 'write',
      path: '/dsh/workspace/big.bin',
      bytes: source,
      mode: 0o644,
      entryChanged: true,
    })
    await settle()

    assert.deepEqual(vfs.observerErrors, [], 'the sink publishes instead of refusing the legal 60 MiB file')
    const mutations = mutationsOf(hostFrames)
    assert.equal(mutations.length, 4, '60 MiB / 15 MiB per mutation = one write plus three appends')
    assert.equal(mutations[0]!.mflags & 2, 0, 'the first mutation is a complete write')
    assert.equal(mutations[0]?.appendFrom, 0n)
    for (const [index, mutation] of mutations.entries()) {
      assert.equal(mutation.mseq, BigInt(index + 1), 'mseq is consecutive')
      assert.equal(mutation.path, '/dsh/workspace/big.bin')
      assert.ok(mutation.data.byteLength <= MAX_MUTATION_DATA, `chunk ${String(index)} fits one frame`)
      if (index > 0) {
        assert.equal(mutation.mflags & 2, 2, `chunk ${String(index)} is appended`)
        assert.equal(mutation.appendFrom, BigInt(index * MAX_MUTATION_DATA))
      }
    }
    assert.equal(mutations[0]?.data.byteLength, MAX_MUTATION_DATA)
    assert.equal(mutations[3]?.data.byteLength, 15 * MIB)
    assertSameBytes(materialize(mutations), source)
    await pair.worker.waitAck(1, mutations.at(-1)!.mseq)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('ENG-07: a killed publish resumes the unacked appended chain and converges', async () => {
  const pair = connect({ nextMseq: 1n, ackedMseq: 0n, autoAck: false })
  const vfs = new BigVfs()
  const hostFrames: Frame[] = []
  pair.host.onFrame(frame => hostFrames.push(frame))
  const dispose = installSink(vfs, pair.worker)
  try {
    // Lose the transport after the first two mutations reached the host; the
    // remaining appended chunks stay in the worker's unacked buffer.
    pair.setDrop((_direction, frame) => frame.type === FrameType.VFS_MUT && decodeVfsMutation(frame.payload).mseq > 2n)
    const source = sourceBytes(60 * MIB)
    vfs.emit({
      kind: 'write',
      path: '/dsh/workspace/big.bin',
      bytes: source,
      mode: 0o644,
      entryChanged: true,
    })
    await settle()
    assert.equal(mutationsOf(hostFrames).length, 2, 'the interruption leaves the accepted prefix')
    assert.equal(pair.host.expectedInboundMseq, 3n)

    pair.setDrop(undefined)
    pair.disconnect()
    await pair.reconnect()
    await settle()

    const mutations = mutationsOf(hostFrames)
    assert.deepEqual(mutations.map(mutation => mutation.mseq), [1n, 2n, 3n, 4n],
      'the reconnect re-sends only the unacked chunks with their original mseq')
    assert.equal(pair.host.expectedInboundMseq, 5n, 'no mseq gap or duplicate')
    assertSameBytes(materialize(mutations), source)
  } finally {
    dispose()
    await pair.worker.close()
  }
})


test('ENG-07: a VFS_RESYNC for a 60 MiB file is re-sent in chunks and keeps the channel', async () => {
  const pair = connect({ nextMseq: 1n, ackedMseq: 0n, autoAck: false })
  const vfs = new BigVfs()
  const hostFrames: Frame[] = []
  pair.host.onFrame(frame => hostFrames.push(frame))
  const dispose = installResyncHandler(vfs, pair.worker)
  try {
    const source = sourceBytes(60 * MIB)
    vfs.seed('/dsh/workspace/big.bin', source)
    pair.host.send(FrameType.VFS_RESYNC, encodeVfsResync({ path: '/dsh/workspace/big.bin' }))
    await settle()

    assert.equal(hostFrames.some(frame => frame.type === FrameType.ERROR), false,
      'a legal large resync is never VFS_CONFLICT')
    const mutations = mutationsOf(hostFrames)
    assert.equal(mutations.length, 4, 'the resync re-sends one complete write plus three appends')
    assert.equal(mutations[0]!.mflags & 2, 0)
    for (const [index, mutation] of mutations.entries()) {
      assert.equal(mutation.mseq, BigInt(index + 1))
      assert.ok(mutation.data.byteLength <= MAX_MUTATION_DATA)
      if (index > 0) assert.equal(mutation.appendFrom, BigInt(index * MAX_MUTATION_DATA))
    }
    assertSameBytes(materialize(mutations), source)

    // The channel is still open: the next ordinary mutation is accepted.
    const nextMseq = pair.worker.nextMseq()
    pair.worker.send(FrameType.VFS_MUT, encodeVfsMutation({
      mseq: nextMseq,
      op: 1,
      mode: 0o644,
      mflags: 1,
      appendFrom: 0n,
      path: '/dsh/workspace/after.txt',
      data: new TextEncoder().encode('ok'),
    }))
    await settle()
    assert.equal(pair.host.expectedInboundMseq, nextMseq + 1n)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('ENG-07: the read cap is the single-file budget and an over-cap read has a chunk hint', async () => {
  assert.equal(MAX_FILE_SIZE, 128 * MIB, 'the default 8 GiB tier single-file budget')
  assert.equal(MAX_FILE_READ_SIZE, MAX_FILE_SIZE, 'the read cap follows the single-file budget')
  assert.ok(MAX_FILE_SIZE > MAX_MUTATION_DATA, 'the file cap is not the per-mutation cap')

  const root = mkdtempSync(join(tmpdir(), 'pdsh-bigfile-read-'))
  const workspace = join(root, 'dsh/workspace')
  mkdirSync(workspace, { recursive: true })
  const sixty = join(workspace, 'sixty.bin')
  writeFileSync(sixty, new Uint8Array(0))
  truncateSync(sixty, 60 * MIB)
  const over = join(workspace, 'over.bin')
  writeFileSync(over, new Uint8Array(0))
  truncateSync(over, MAX_FILE_SIZE + 1)
  try {
    const fs = new VfsFileSystem({ root })
    // A 60 MiB file is inside the single-file budget, so a whole-file read is
    // allowed; the old 15 MiB read cap refused it.
    assert.equal((await fs.readFileBuffer('/dsh/workspace/sixty.bin')).byteLength, 60 * MIB)

    for (const read of [
      () => fs.readFileBuffer('/dsh/workspace/over.bin'),
      () => fs.readFile('/dsh/workspace/over.bin'),
    ]) {
      await assert.rejects(read, (error: unknown) => {
        const message = (error as Error).message
        assert.equal((error as { code?: string }).code, 'EFBIG')
        assert.match(message, /File too large/)
        assert.equal(message.includes(String(MAX_FILE_SIZE)), true, 'the message names the 128 MiB byte limit')
        assert.match(message, /134217728 bytes \(128 MiB\)/)
        const trailer = parseShellTrailer(message.trimEnd().split('\n').at(-1) as string)
        assert.equal(trailer?.reason, 'limit-refused', 'the read refusal carries a contract trailer')
        assert.equal(trailer?.program, 'vfs')
        assert.match(trailer?.hint ?? '', /chunks/u, 'the hint points at chunked reads')
        assert.match(trailer?.hint ?? '', /head|tail|sed|python3/u)
        return true
      })
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
