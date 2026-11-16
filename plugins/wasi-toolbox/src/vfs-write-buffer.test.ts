// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { MAX_FILE_SIZE, configureSingleFileLimit } from './limits.ts'
import { workerTransport } from './message-endpoint.ts'
import type { WorkerLike } from './message-endpoint.ts'
import { WasiToolbox } from './toolbox.ts'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { DEFAULT_WRITE_BUFFER_BYTES, VfsProxyServer } from './vfs-server.ts'
import type { VfsBackend, VfsRequest, VfsResponse } from './types.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()
const TMP = '/dsh/tmp/out.elf'
const DURABLE = '/dsh/workspace/out.elf'

/** Real in-memory backend; counts whole-file stores and can refuse them. */
function counting(): {
  backend: MemoryVfsBackend
  face: VfsBackend
  stores: (path: string) => number
  refuse: (message: string | undefined) => void
} {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) backend.seedDirectory(directory)
  const stores = new Map<string, number>()
  let refusal: string | undefined
  const face: VfsBackend = {
    stat: path => backend.stat(path),
    readdir: path => backend.readdir(path),
    readFile: path => backend.readFile(path),
    writeFile: (path, data, opts) => {
      if (opts?.append !== true && data.byteLength > 0) {
        if (refusal !== undefined) throw new Error(refusal)
        stores.set(path, (stores.get(path) ?? 0) + 1)
      }
      return backend.writeFile(path, data, opts)
    },
    mkdir: (path, mode) => backend.mkdir(path, mode),
    unlink: (path, opts) => backend.unlink(path, opts),
    rename: (from, to) => backend.rename(from, to),
    truncate: (path, length) => backend.truncate(path, length),
  }
  return { backend, face, stores: path => stores.get(path) ?? 0, refuse: (message) => { refusal = message } }
}

function server(face: VfsBackend, writeBufferBytes?: number): VfsProxyServer {
  return new VfsProxyServer({ backend: face, ...(writeBufferBytes === undefined ? {} : { writeBufferBytes }) })
}

async function ok(proxy: VfsProxyServer, request: VfsRequest): Promise<VfsResponse & { ok: true }> {
  const response = await proxy.execute(request)
  assert.equal(response.ok, true, response.ok ? '' : `${response.code}: ${response.message}`)
  return response as VfsResponse & { ok: true }
}

async function code(proxy: VfsProxyServer, request: VfsRequest): Promise<string> {
  const response = await proxy.execute(request)
  assert.equal(response.ok, false)
  return response.ok ? '' : response.code
}

const write = (path: string, offset: number, text: string, append = false): VfsRequest =>
  ({ op: 'write', path, offset, append, create: false, data: encoder.encode(text) })
const open = (path: string, truncate = true): VfsRequest =>
  ({ op: 'open', path, create: true, truncate, exclusive: false, directory: false })

async function readAll(proxy: VfsProxyServer, path: string): Promise<string> {
  const response = await ok(proxy, { op: 'read', path, offset: 0, length: 1 << 20 })
  if (response.value.kind !== 'data') throw new Error('not data')
  return decoder.decode(response.value.data)
}

async function size(proxy: VfsProxyServer, path: string): Promise<number> {
  const response = await ok(proxy, { op: 'stat', path })
  if (response.value.kind !== 'stat') throw new Error('not stat')
  return response.value.stat.size
}

const stored = (backend: MemoryVfsBackend, path: string): string => decoder.decode(backend.peek(path) ?? new Uint8Array(0))

test('write buffer: patches to a volatile file are stored once, at the flush', async () => {
  const { backend, face, stores } = counting()
  const proxy = server(face)
  assert.equal(proxy.writeBufferBytes, DEFAULT_WRITE_BUFFER_BYTES)
  await ok(proxy, open(TMP))
  await ok(proxy, write(TMP, 0, '................'))
  for (let index = 0; index < 8; index += 1) await ok(proxy, write(TMP, index * 2, 'ab'))
  assert.equal(proxy.pendingWrites, 1)
  assert.equal(stores(TMP), 0, 'no whole-file store while patching')
  assert.equal(stored(backend, TMP), '................', 'the backend still holds the pre-patch bytes')
  // The guest itself sees its own writes through the proxy.
  assert.equal(await readAll(proxy, TMP), 'abababababababab')
  assert.equal(await size(proxy, TMP), 16)

  await proxy.flushWrites()
  assert.equal(proxy.pendingWrites, 0)
  assert.equal(stores(TMP), 1)
  assert.equal(stored(backend, TMP), 'abababababababab')
  assert.equal(await readAll(proxy, TMP), 'abababababababab')
})

test('write buffer: the /tmp spelling reaches the same buffered file', async () => {
  const { backend, face } = counting()
  const proxy = server(face)
  await ok(proxy, open('/tmp/out.elf'))
  await ok(proxy, write('/tmp/out.elf', 0, 'abcdef'))
  await ok(proxy, write('/tmp/out.elf', 1, 'XY'))
  assert.equal(await readAll(proxy, TMP), 'aXYdef')
  await proxy.flushWrites()
  assert.equal(stored(backend, TMP), 'aXYdef')
})

test('write buffer: a durable file is never buffered', async () => {
  const { backend, face, stores } = counting()
  const proxy = server(face)
  await ok(proxy, open(DURABLE))
  await ok(proxy, write(DURABLE, 0, 'abcdef'))
  await ok(proxy, write(DURABLE, 1, 'XY'))
  await ok(proxy, write(DURABLE, 4, 'Z'))
  assert.equal(proxy.pendingWrites, 0)
  assert.equal(stored(backend, DURABLE), 'aXYdZf', 'every patch is in the backend when the write returns')
  assert.equal(stores(DURABLE), 2)
})

test('write buffer: appends and holes keep byte order once a file is buffered', async () => {
  const { backend, face } = counting()
  const proxy = server(face)
  await ok(proxy, open(TMP))
  await ok(proxy, write(TMP, 0, 'AAAAAAAA'))
  await ok(proxy, write(TMP, 2, 'bb'))
  await ok(proxy, write(TMP, 8, 'cc'))
  await ok(proxy, write(TMP, 0, '!!', true))
  await ok(proxy, write(TMP, 14, 'd'))
  assert.equal(await size(proxy, TMP), 15)
  await proxy.flushWrites()
  assert.deepEqual([...(backend.peek(TMP) ?? [])], [...encoder.encode('AAbbAAAAcc!!'), 0, 0, 0x64])
})

test('write buffer: fsync, truncate and rename store the file; unlink and a truncating open drop it', async () => {
  const { backend, face } = counting()
  const proxy = server(face)
  const patch = async (path: string): Promise<void> => {
    await ok(proxy, open(path))
    await ok(proxy, write(path, 0, 'abcdef'))
    await ok(proxy, write(path, 1, 'XY'))
    assert.equal(proxy.pendingWrites, 1)
  }

  await patch(TMP)
  await ok(proxy, { op: 'sync' })
  assert.equal(proxy.pendingWrites, 0)
  assert.equal(stored(backend, TMP), 'aXYdef')

  await patch(TMP)
  await ok(proxy, { op: 'truncate', path: TMP, length: 3 })
  assert.equal(stored(backend, TMP), 'aXY')
  assert.equal(await readAll(proxy, TMP), 'aXY')

  await patch(TMP)
  await ok(proxy, { op: 'rename', from: TMP, to: '/dsh/tmp/moved.elf' })
  assert.equal(stored(backend, '/dsh/tmp/moved.elf'), 'aXYdef')
  assert.equal(await code(proxy, { op: 'stat', path: TMP }), 'ENOENT')

  await patch(TMP)
  await ok(proxy, { op: 'unlink', path: TMP, directory: false })
  await proxy.flushWrites()
  assert.equal(backend.peek(TMP), undefined, 'a flush after unlink must not recreate the file')

  await patch(TMP)
  await ok(proxy, open(TMP, true))
  assert.equal(proxy.pendingWrites, 0)
  assert.equal(await size(proxy, TMP), 0)
  await proxy.flushWrites()
  assert.equal(stored(backend, TMP), '')
})

test('write buffer: the single-file limit is refused at the write, not at the flush', async () => {
  const previous = MAX_FILE_SIZE
  configureSingleFileLimit(8)
  try {
    const { backend, face } = counting()
    const proxy = server(face)
    await ok(proxy, open(TMP))
    await ok(proxy, write(TMP, 0, 'abcdef'))
    await ok(proxy, write(TMP, 1, 'XY'))
    assert.equal(await code(proxy, write(TMP, 6, 'toolong')), 'EFBIG')
    assert.equal(await code(proxy, write(TMP, 0, 'xxx', true)), 'EFBIG')
    assert.equal(await readAll(proxy, TMP), 'aXYdef', 'a refused write leaves the buffered file intact')
    await proxy.flushWrites()
    assert.equal(stored(backend, TMP), 'aXYdef')
  } finally {
    configureSingleFileLimit(previous)
  }
})

test('write buffer: over budget and disabled both fall back to direct stores', async () => {
  for (const budget of [0, 8]) {
    const { backend, face, stores } = counting()
    const proxy = server(face, budget)
    await ok(proxy, open(TMP))
    await ok(proxy, write(TMP, 0, '0123456789abcdef'))
    await ok(proxy, write(TMP, 1, 'XY'))
    await ok(proxy, write(TMP, 5, 'Z'))
    assert.equal(proxy.pendingWrites, 0)
    assert.equal(stored(backend, TMP), '0XY34Z6789abcdef')
    assert.equal(stores(TMP), 2)
  }
  // A buffered file that outgrows the budget is stored and continues directly.
  const { backend, face } = counting()
  const proxy = server(face, 12)
  await ok(proxy, open(TMP))
  await ok(proxy, write(TMP, 0, 'abcdef'))
  await ok(proxy, write(TMP, 1, 'XY'))
  assert.equal(proxy.pendingWrites, 1)
  await ok(proxy, write(TMP, 6, '0123456789'))
  assert.equal(proxy.pendingWrites, 0)
  assert.equal(stored(backend, TMP), 'aXYdef0123456789')
})

test('write buffer: a refused store fails the flush once and is not retried', async () => {
  const { backend, face, refuse } = counting()
  const proxy = server(face)
  await ok(proxy, open(TMP))
  await ok(proxy, write(TMP, 0, 'abcdef'))
  await ok(proxy, write(TMP, 1, 'XY'))
  refuse('ENOSPC: tmp quota')
  await assert.rejects(proxy.flushWrites(), /tmp quota/)
  assert.equal(proxy.pendingWrites, 0)
  refuse(undefined)
  await proxy.flushWrites()
  assert.equal(stored(backend, TMP), 'abcdef', 'the backend keeps the pre-patch bytes')
})

test('write buffer: discardWrites leaves the backend at the pre-patch bytes', async () => {
  const { backend, face } = counting()
  const proxy = server(face)
  await ok(proxy, open(TMP))
  await ok(proxy, write(TMP, 0, 'abcdef'))
  await ok(proxy, write(TMP, 1, 'XY'))
  proxy.discardWrites()
  assert.equal(proxy.pendingWrites, 0)
  await proxy.flushWrites()
  assert.equal(stored(backend, TMP), 'abcdef')
  assert.equal(await readAll(proxy, TMP), 'abcdef')
})

test('write buffer: a real guest that back-patches /tmp output has it stored when the command returns', { timeout: 20_000 }, async () => {
  const { backend, face, stores } = counting()
  const bytes = readFileSync(new URL('./testdata/fd-patch.wasm', import.meta.url))
  const toolbox = new WasiToolbox({
    commands: [{ program: 'fd-patch', module: { url: 'image://fd-patch.wasm', load: async () => bytes } }],
    backend: face,
    crossOriginIsolated: true,
    spawnWorker: () => workerTransport(
      new Worker(new URL('./node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
    workerReadyTimeoutMs: 5000,
  })
  try {
    const expected = [...encoder.encode('AAbbAAAAcc'), 0, 0, 0x64]
    for (const path of ['/tmp/patched.bin', '/dsh/workspace/patched.bin']) {
      let stderr = ''
      const result = await toolbox.run({
        program: 'fd-patch', argv: [path], onStderr: (chunk) => { stderr += decoder.decode(chunk) },
      })
      assert.equal(result.exitCode, 0, stderr)
      const host = path.startsWith('/tmp/') ? `/dsh${path}` : path
      assert.deepEqual([...(backend.peek(host) ?? [])], expected, `${path} is complete in the VFS at command return`)
    }
    assert.equal(stores('/dsh/tmp/patched.bin'), 1, 'the volatile output was stored once')
    assert.ok(stores('/dsh/workspace/patched.bin') >= 2, 'the durable output is still stored per patch')
  } finally {
    await toolbox.dispose()
  }
  // The toolbox option reaches the proxy server: with the buffer disabled the
  // same volatile output is stored per patch again.
  const direct = counting()
  const unbuffered = new WasiToolbox({
    commands: [{ program: 'fd-patch', module: { url: 'image://fd-patch.wasm', load: async () => bytes } }],
    backend: direct.face,
    crossOriginIsolated: true,
    writeBufferBytes: 0,
    spawnWorker: () => workerTransport(
      new Worker(new URL('./node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
    workerReadyTimeoutMs: 5000,
  })
  try {
    const result = await unbuffered.run({ program: 'fd-patch', argv: ['/tmp/patched.bin'] })
    assert.equal(result.exitCode, 0)
    assert.deepEqual([...(direct.backend.peek('/dsh/tmp/patched.bin') ?? [])], [...encoder.encode('AAbbAAAAcc'), 0, 0, 0x64])
    assert.ok(direct.stores('/dsh/tmp/patched.bin') >= 2)
  } finally {
    await unbuffered.dispose()
  }
})
