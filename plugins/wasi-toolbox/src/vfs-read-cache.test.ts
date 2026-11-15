// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { DEFAULT_READ_CACHE_BYTES, VfsProxyServer } from './vfs-server.ts'
import type { VfsBackend, VfsRequest, VfsResponse } from './types.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()
const FILE = '/dsh/workspace/lib.a'

/** Backend double that counts whole-file loads; everything else is the real in-memory backend. */
function counting(options: { clock?: () => number } = {}): {
  backend: MemoryVfsBackend
  face: VfsBackend
  loads: () => number
} {
  const backend = new MemoryVfsBackend({ clock: options.clock ?? (() => 1_700_000_000_000) })
  let loads = 0
  const face: VfsBackend = {
    stat: path => backend.stat(path),
    readdir: path => backend.readdir(path),
    readFile: (path) => {
      loads += 1
      return backend.readFile(path)
    },
    writeFile: (path, data, opts) => backend.writeFile(path, data, opts),
    mkdir: (path, mode) => backend.mkdir(path, mode),
    unlink: (path, opts) => backend.unlink(path, opts),
    rename: (from, to) => backend.rename(from, to),
    truncate: (path, length) => backend.truncate(path, length),
  }
  return { backend, face, loads: () => loads }
}

function server(face: VfsBackend, readCacheBytes?: number): VfsProxyServer {
  return new VfsProxyServer({
    backend: face,
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
    ...(readCacheBytes === undefined ? {} : { readCacheBytes }),
  })
}

async function read(proxy: VfsProxyServer, path: string, offset: number, length: number): Promise<string> {
  const response = await proxy.execute({ op: 'read', path, offset, length })
  assert.equal(response.ok, true, response.ok ? '' : `${response.code}: ${response.message}`)
  if (!response.ok || response.value.kind !== 'data') throw new Error('not data')
  return decoder.decode(response.value.data)
}

async function ok(proxy: VfsProxyServer, request: VfsRequest): Promise<void> {
  const response = await proxy.execute(request)
  assert.equal(response.ok, true, response.ok ? '' : `${response.code}: ${response.message}`)
}

function failure(response: VfsResponse): string {
  assert.equal(response.ok, false)
  return response.ok ? '' : response.code
}

test('read cache: many ranged reads of one file load it from the backend once', async () => {
  const { backend, face, loads } = counting()
  backend.seedFile(FILE, '0123456789abcdef')
  const proxy = server(face)
  assert.equal(proxy.readCacheBytes, DEFAULT_READ_CACHE_BYTES)
  for (let index = 0; index < 16; index += 1) {
    assert.equal(await read(proxy, FILE, index, 1), '0123456789abcdef'[index])
  }
  assert.equal(await read(proxy, FILE, 10, 100), 'abcdef')
  assert.equal(await read(proxy, FILE, 99, 4), '')
  assert.equal(loads(), 1)
})

test('read cache: a returned slice is a copy, so a caller cannot corrupt later reads', async () => {
  const { backend, face } = counting()
  backend.seedFile(FILE, 'abcdef')
  const proxy = server(face)
  const first = await proxy.execute({ op: 'read', path: FILE, offset: 0, length: 6 })
  if (!first.ok || first.value.kind !== 'data') throw new Error('not data')
  first.value.data.fill(0x58)
  assert.equal(await read(proxy, FILE, 0, 6), 'abcdef')
})

test('read cache: every mutation through the proxy is visible to the next read', async () => {
  const { backend, face } = counting()
  backend.seedFile(FILE, 'abcdef')
  const proxy = server(face)
  assert.equal(await read(proxy, FILE, 0, 16), 'abcdef')

  await ok(proxy, { op: 'write', path: FILE, offset: 1, append: false, create: false, data: encoder.encode('XY') })
  assert.equal(await read(proxy, FILE, 0, 16), 'aXYdef')

  await ok(proxy, { op: 'write', path: FILE, offset: 0, append: true, create: false, data: encoder.encode('!') })
  assert.equal(await read(proxy, FILE, 0, 16), 'aXYdef!')

  await ok(proxy, { op: 'write', path: FILE, offset: 7, append: false, create: false, data: encoder.encode('?') })
  assert.equal(await read(proxy, FILE, 0, 16), 'aXYdef!?')

  await ok(proxy, { op: 'truncate', path: FILE, length: 3 })
  assert.equal(await read(proxy, FILE, 0, 16), 'aXY')

  await ok(proxy, { op: 'open', path: FILE, create: false, truncate: true, exclusive: false, directory: false })
  assert.equal(await read(proxy, FILE, 0, 16), '')

  await ok(proxy, { op: 'write', path: FILE, offset: 0, append: false, create: false, data: encoder.encode('new') })
  await ok(proxy, { op: 'rename', from: FILE, to: '/dsh/workspace/moved.a' })
  assert.equal(failure(await proxy.execute({ op: 'read', path: FILE, offset: 0, length: 4 })), 'ENOENT')
  assert.equal(await read(proxy, '/dsh/workspace/moved.a', 0, 16), 'new')

  await ok(proxy, { op: 'unlink', path: '/dsh/workspace/moved.a', directory: false })
  assert.equal(failure(await proxy.execute({ op: 'read', path: '/dsh/workspace/moved.a', offset: 0, length: 4 })), 'ENOENT')
  assert.equal(decoder.decode(backend.peek('/dsh/workspace/moved.a') ?? new Uint8Array(0)), '')
})

test('read cache: positional writes do not reload the file for each write', async () => {
  const { backend, face, loads } = counting()
  backend.seedFile(FILE, '................')
  const proxy = server(face)
  for (let index = 0; index < 8; index += 1) {
    await ok(proxy, { op: 'write', path: FILE, offset: index * 2, append: false, create: false, data: encoder.encode('ab') })
  }
  assert.equal(decoder.decode(backend.peek(FILE)), 'abababababababab')
  assert.equal(await read(proxy, FILE, 0, 16), 'abababababababab')
  assert.equal(loads(), 1)
})

test('sequential writes at EOF append without loading the file', async () => {
  for (const budget of [0, DEFAULT_READ_CACHE_BYTES]) {
    const { backend, face, loads } = counting()
    const proxy = server(face, budget)
    const out = '/dsh/workspace/out.o'
    await ok(proxy, { op: 'open', path: out, create: true, truncate: true, exclusive: false, directory: false })
    let offset = 0
    for (const chunk of ['ELF', 'header', 'sections', 'symtab']) {
      await ok(proxy, { op: 'write', path: out, offset, append: false, create: false, data: encoder.encode(chunk) })
      offset += chunk.length
    }
    assert.equal(decoder.decode(backend.peek(out)), 'ELFheadersectionssymtab')
    assert.equal(loads(), 0)
    // A write past EOF is not an append: the gap is zero-filled as before.
    await ok(proxy, { op: 'write', path: out, offset: offset + 2, append: false, create: false, data: encoder.encode('Z') })
    assert.deepEqual([...(backend.peek(out) ?? []).slice(-3)], [0, 0, 0x5a])
    // Error codes of the paths `stat` cannot settle are the old ones.
    assert.equal(failure(await proxy.execute({
      op: 'write', path: '/dsh/workspace/none', offset: 0, append: false, create: false, data: encoder.encode('x'),
    })), 'ENOENT')
    await ok(proxy, { op: 'write', path: '/dsh/workspace/made', offset: 0, append: false, create: true, data: encoder.encode('x') })
    assert.equal(decoder.decode(backend.peek('/dsh/workspace/made')), 'x')
  }
})

test('read cache: a change outside the proxy is seen when size or mtime moved', async () => {
  let now = 1_700_000_000_000
  const { backend, face, loads } = counting({ clock: () => now })
  backend.seedFile(FILE, 'abcdef')
  const proxy = server(face)
  assert.equal(await read(proxy, FILE, 0, 16), 'abcdef')

  backend.writeFile(FILE, encoder.encode('longer content'), { create: true })
  assert.equal(await read(proxy, FILE, 0, 32), 'longer content')

  now += 1
  backend.writeFile(FILE, encoder.encode('LONGER CONTENT'), { create: true })
  assert.equal(await read(proxy, FILE, 0, 32), 'LONGER CONTENT')
  assert.equal(loads(), 3)
})

test('read cache: resetReadCache drops bytes a stat-identical outside write would hide', async () => {
  const { backend, face } = counting()
  backend.seedFile(FILE, 'abcdef')
  const proxy = server(face)
  assert.equal(await read(proxy, FILE, 0, 16), 'abcdef')
  // Same size, same (frozen) clock, same inode: stat cannot tell these apart.
  backend.writeFile(FILE, encoder.encode('ABCDEF'), { create: true })
  proxy.resetReadCache()
  assert.equal(await read(proxy, FILE, 0, 16), 'ABCDEF')
})

test('read cache: the byte budget bounds what is kept and zero disables it', async () => {
  const { backend, face, loads } = counting()
  backend.seedFile(FILE, '0123456789')
  backend.seedFile('/dsh/workspace/a', 'aaaa')
  backend.seedFile('/dsh/workspace/b', 'bbbb')
  backend.seedFile('/dsh/workspace/c', 'cccc')

  const small = server(face, 8)
  assert.equal(await read(small, FILE, 0, 4), '0123')
  assert.equal(await read(small, FILE, 4, 4), '4567')
  assert.equal(loads(), 2, 'a file over the budget is never cached')

  assert.equal(await read(small, '/dsh/workspace/a', 0, 4), 'aaaa')
  assert.equal(await read(small, '/dsh/workspace/b', 0, 4), 'bbbb')
  assert.equal(await read(small, '/dsh/workspace/a', 0, 4), 'aaaa')
  assert.equal(loads(), 4, 'two files fit the budget')
  assert.equal(await read(small, '/dsh/workspace/c', 0, 4), 'cccc')
  assert.equal(await read(small, '/dsh/workspace/a', 0, 4), 'aaaa')
  assert.equal(loads(), 5, 'the least recently used file (b) was evicted, a stayed')
  assert.equal(await read(small, '/dsh/workspace/b', 0, 4), 'bbbb')
  assert.equal(loads(), 6)

  const off = server(face, 0)
  const before = loads()
  assert.equal(await read(off, '/dsh/workspace/a', 0, 4), 'aaaa')
  assert.equal(await read(off, '/dsh/workspace/a', 0, 4), 'aaaa')
  assert.equal(loads(), before + 2)
})

test('read cache: failures keep the uncached error codes and the read policy', async () => {
  for (const budget of [0, DEFAULT_READ_CACHE_BYTES]) {
    const { backend, face } = counting()
    backend.seedFile(FILE, 'abcdef')
    backend.seedDirectory('/dsh/workspace/dir')
    const proxy = server(face, budget)
    assert.equal(failure(await proxy.execute({ op: 'read', path: '/dsh/workspace/dir', offset: 0, length: 4 })), 'EISDIR')
    assert.equal(failure(await proxy.execute({ op: 'read', path: '/dsh/workspace/missing', offset: 0, length: 4 })), 'ENOENT')
    assert.equal(failure(await proxy.execute({ op: 'read', path: '/etc/passwd', offset: 0, length: 4 })), 'ENOTCAPABLE')
    assert.equal(await read(proxy, FILE, 0, 6), 'abcdef')
  }
})
