// SPDX-License-Identifier: MIT
/**
 * G2-FIX-57 repair: a `fd_write` that starts exactly at EOF is published as
 * an append, and the production `NodeFsBackend` uses the VFS's real
 * `appendFile` instead of materialising and rewriting the whole file.
 *
 * Without this, a chunked write of an 8 MiB file sends 1+2+...+8 MiB through
 * the WAL sink (36 MiB per file); G2-A09's two shards then exhausted the
 * 256 MiB WAL budget and the python command never returned. The write is the
 * same byte stream either way, not a scenario special case.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MessageChannel } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import { AsyncVfsClient } from './vfs-client.ts'
import { MemoryVfsBackend, NodeFsBackend } from './vfs-backends.ts'
import type { NodeFsPromisesLike, NodeFsStatsLike } from './vfs-backends.ts'
import type { MessageEndpoint } from './message-endpoint.ts'
import { VfsProxyServer } from './vfs-server.ts'
import type { VfsBackend } from './types.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function statsFor(size: number): NodeFsStatsLike {
  return {
    size,
    mode: 0o644,
    mtimeMs: 1,
    ino: 1,
    isFile: () => true,
    isDirectory: () => false,
    isSymbolicLink: () => false,
  }
}

/** A tiny `node:fs/promises` face with a real append. */
function fakeFs(): {
  readonly fs: NodeFsPromisesLike
  readonly files: Map<string, Uint8Array>
  readonly writes: number
  readonly appends: number[]
  } {
  const files = new Map<string, Uint8Array>()
  const counters = { writes: 0, appends: [] as number[] }
  const fs: NodeFsPromisesLike = {
    stat: async path => {
      const data = files.get(path)
      if (data === undefined) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
      return statsFor(data.byteLength)
    },
    readdir: async () => [],
    readFile: async path => {
      const data = files.get(path)
      if (data === undefined) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
      return data
    },
    writeFile: async (path, data) => {
      counters.writes += 1
      files.set(path, Uint8Array.from(data))
    },
    appendFile: async (path, data) => {
      counters.appends.push(data.byteLength)
      const existing = files.get(path) ?? new Uint8Array(0)
      const joined = new Uint8Array(existing.byteLength + data.byteLength)
      joined.set(existing, 0)
      joined.set(data, existing.byteLength)
      files.set(path, joined)
    },
    mkdir: async () => {},
    unlink: async () => {},
    rename: async () => {},
    truncate: async () => {},
  }
  return {
    fs,
    files,
    get writes() { return counters.writes },
    get appends() { return counters.appends },
  }
}

test('G2-FIX-57: NodeFsBackend appends through the VFS append face, not a whole-file rewrite', async () => {
  const fake = fakeFs()
  const backend = new NodeFsBackend(fake.fs)
  await backend.writeFile('/dsh/workspace/shards.bin', encoder.encode('abc'), { create: true })
  await backend.writeFile('/dsh/workspace/shards.bin', encoder.encode('def'), { append: true, create: true })
  assert.equal(decoder.decode(fake.files.get('/dsh/workspace/shards.bin')), 'abcdef')
  assert.equal(fake.writes, 1, 'the append does not materialise a second whole-file write')
  assert.deepEqual(fake.appends, [3], 'only the new suffix crosses the append face')
})

test('G2-FIX-57: NodeFsBackend keeps the read+rewrite fallback when the face has no appendFile', async () => {
  const fake = fakeFs()
  const { appendFile: _unused, ...withoutAppend } = fake.fs
  const backend = new NodeFsBackend(withoutAppend)
  await backend.writeFile('/dsh/workspace/shards.bin', encoder.encode('abc'), { create: true })
  await backend.writeFile('/dsh/workspace/shards.bin', encoder.encode('def'), { append: true, create: true })
  assert.equal(decoder.decode(fake.files.get('/dsh/workspace/shards.bin')), 'abcdef')
  assert.equal(fake.writes, 2)
})

function endpoint(port: MessagePort): MessageEndpoint {
  return {
    postMessage: message => { port.postMessage(message) },
    onMessage(handler) {
      const listener = (message: unknown): void => { handler(message) }
      port.on('message', listener)
      return () => { port.off('message', listener) }
    },
  }
}

test('G2-FIX-57: a write at EOF is dispatched as an append through the VFS proxy', async () => {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  backend.seedFile('/dsh/workspace/in.txt', 'hello')
  const calls: { append?: boolean }[] = []
  const writeFile = backend.writeFile.bind(backend) as VfsBackend['writeFile']
  backend.writeFile = (path, data, options) => {
    calls.push(options ?? {})
    return writeFile(path, data, options)
  }
  const server = new VfsProxyServer({
    backend,
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
  })
  const { port1, port2 } = new MessageChannel()
  const detach = server.attach(endpoint(port1))
  const client = new AsyncVfsClient(endpoint(port2), { timeoutMs: 2_000 })
  try {
    await client.call({
      op: 'write', path: '/dsh/workspace/in.txt', offset: 5, append: false, create: false,
      data: encoder.encode(' world'),
    })
    assert.equal(decoder.decode(backend.peek('/dsh/workspace/in.txt')), 'hello world')
    assert.equal(calls.at(-1)?.append, true, 'offset == existing length is an append')

    // A partial overwrite still goes through the read+merge path.
    await client.call({
      op: 'write', path: '/dsh/workspace/in.txt', offset: 1, append: false, create: false,
      data: encoder.encode('XY'),
    })
    assert.equal(decoder.decode(backend.peek('/dsh/workspace/in.txt')), 'hXYlo world')
    assert.equal(calls.at(-1)?.append, undefined)
  } finally {
    client.close()
    detach()
    port1.close()
    port2.close()
  }
})
