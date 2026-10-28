// SPDX-License-Identifier: MIT
// G2-FIX-47 regression: directory removal through the WASI VFS proxy.
//
// The defect: the production `node:fs/promises` face of the Worker
// (`MemoryVfs.promises`) has no `rmdir`. `NodeFsBackend.unlink(path,
// {directory:true})` fell through to `rm(path, {recursive:false})`, whose
// `ERR_FS_EISDIR` is not an errno-style code and so reached the guest as EIO.
// Every `os.rmdir` in the Worker therefore failed, which broke
// `tempfile.TemporaryDirectory()` cleanup and `shutil.rmtree`'s rmdir path
// (G2-D06). The component contract is POSIX: removing an empty directory
// succeeds and updates the parent, a non-empty directory fails with
// ENOTEMPTY, a file fails with ENOTDIR, and unlinking a directory with the
// file operation fails with EISDIR.
//
// The tests here drive the backend over the runtime-shaped face
// (`tests/fixtures/runtime-fs-face.ts`) and the real proxy frame path, so a
// future change that silently loses directory removal fails at the component
// boundary instead of in a model scenario.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MessageChannel } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import { VfsProxyError } from '../wasi-toolbox/src/errors.ts'
import { AsyncVfsClient } from '../wasi-toolbox/src/vfs-client.ts'
import type { MessageEndpoint } from '../wasi-toolbox/src/message-endpoint.ts'
import { MemoryVfsBackend, NodeFsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import { VfsProxyServer } from '../wasi-toolbox/src/vfs-server.ts'
import { runtimeFsFace } from './fixtures/runtime-fs-face.ts'

function portEndpoint(port: MessagePort): MessageEndpoint {
  return {
    postMessage: message => { port.postMessage(message) },
    onMessage(handler) {
      const listener = (message: unknown): void => { handler(message) }
      port.on('message', listener)
      return () => { port.off('message', listener) }
    },
  }
}

function workspaceFace(): { backend: MemoryVfsBackend; fs: NodeFsBackend } {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  backend.seedDirectory('/dsh/workspace')
  return { backend, fs: new NodeFsBackend(runtimeFsFace(backend)) }
}

function codeOf(error: unknown): string | undefined {
  return error instanceof VfsProxyError ? error.code : undefined
}

test('vfs rmdir: removing an empty directory succeeds and updates the parent entry', async () => {
  let now = 1_700_000_000_000
  const backend = new MemoryVfsBackend({ clock: () => now })
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/workspace/empty')
  const parentMtime = backend.stat('/dsh/workspace').mtimeMs
  const fs = new NodeFsBackend(runtimeFsFace(backend))

  now += 5_000
  await fs.unlink('/dsh/workspace/empty', { directory: true })

  assert.throws(() => backend.stat('/dsh/workspace/empty'), (error: unknown) => codeOf(error) === 'ENOENT')
  assert.deepEqual(backend.readdir('/dsh/workspace'), [])
  // The parent's entry list changed: its mtime advanced, and the name is
  // immediately reusable.
  assert.equal(backend.stat('/dsh/workspace').mtimeMs, parentMtime + 5_000)
  backend.mkdir('/dsh/workspace/empty')
  assert.equal(backend.stat('/dsh/workspace/empty').kind, 'directory')
})

test('vfs rmdir: a non-empty directory fails ENOTEMPTY and leaves the tree intact', async () => {
  const { backend, fs } = workspaceFace()
  backend.seedFile('/dsh/workspace/full/keep.txt', 'keep')
  backend.seedDirectory('/dsh/workspace/full/sub')

  await assert.rejects(
    fs.unlink('/dsh/workspace/full', { directory: true }),
    (error: unknown) => codeOf(error) === 'ENOTEMPTY',
  )
  assert.deepEqual(backend.readdir('/dsh/workspace/full').map(entry => entry.name), ['keep.txt', 'sub'])
  assert.equal(new TextDecoder().decode(backend.readFile('/dsh/workspace/full/keep.txt')), 'keep')

  // Emptying the directory makes the same call succeed.
  await fs.unlink('/dsh/workspace/full/keep.txt', { directory: false })
  await fs.unlink('/dsh/workspace/full/sub', { directory: true })
  await fs.unlink('/dsh/workspace/full', { directory: true })
  assert.throws(() => backend.stat('/dsh/workspace/full'), (error: unknown) => codeOf(error) === 'ENOENT')
})

test('vfs rmdir: POSIX errno for a missing target and for a regular file', async () => {
  const { backend, fs } = workspaceFace()
  backend.seedFile('/dsh/workspace/plain.txt', 'x')

  await assert.rejects(
    fs.unlink('/dsh/workspace/absent', { directory: true }),
    (error: unknown) => codeOf(error) === 'ENOENT',
  )
  await assert.rejects(
    fs.unlink('/dsh/workspace/plain.txt', { directory: true }),
    (error: unknown) => codeOf(error) === 'ENOTDIR',
  )
  // The refused file is untouched.
  assert.equal(new TextDecoder().decode(backend.readFile('/dsh/workspace/plain.txt')), 'x')
})

test('vfs unlink: a directory is EISDIR, not "missing"', async () => {
  const { backend, fs } = workspaceFace()
  backend.seedDirectory('/dsh/workspace/dir')

  await assert.rejects(
    fs.unlink('/dsh/workspace/dir', { directory: false }),
    (error: unknown) => codeOf(error) === 'EISDIR',
  )
  assert.equal(backend.stat('/dsh/workspace/dir').kind, 'directory')

  backend.seedFile('/dsh/workspace/file.txt', 'x')
  await fs.unlink('/dsh/workspace/file.txt', { directory: false })
  assert.throws(() => backend.stat('/dsh/workspace/file.txt'), (error: unknown) => codeOf(error) === 'ENOENT')
})

test('vfs rmdir: the runtime face\'s ERR_FS_EISDIR maps to EISDIR, never EIO', async () => {
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/workspace/dir')
  const face = runtimeFsFace(backend)

  // The primitive the old fallback used; it is not an errno spelling, so the
  // proxy must translate it before the guest sees EIO.
  assert.ok(face.rm !== undefined)
  const rm = face.rm
  await assert.rejects(
    rm.call(face, '/dsh/workspace/dir', { recursive: false }),
    (error: unknown) => (error as { code?: unknown }).code === 'ERR_FS_EISDIR',
  )
  const fs = new NodeFsBackend(face)
  // Removing the file of a directory through the file path stays EISDIR even
  // when the face answers with the runtime's prefixed code.
  await assert.rejects(
    fs.unlink('/dsh/workspace/dir', { directory: false }),
    (error: unknown) => codeOf(error) === 'EISDIR',
  )
})

test('vfs proxy: directory removal over the fake runtime fs face keeps POSIX errors', async () => {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/full/keep.txt', 'keep')
  backend.seedDirectory('/dsh/workspace/empty')
  const server = new VfsProxyServer({
    backend: new NodeFsBackend(runtimeFsFace(backend)),
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
  })
  const { port1, port2 } = new MessageChannel()
  const detach = server.attach(portEndpoint(port1))
  const client = new AsyncVfsClient(portEndpoint(port2), { timeoutMs: 2000 })
  try {
    await client.call({ op: 'unlink', path: '/dsh/workspace/empty', directory: true })
    await assert.rejects(
      client.call({ op: 'stat', path: '/dsh/workspace/empty' }),
      (error: unknown) => codeOf(error) === 'ENOENT',
    )
    await assert.rejects(
      client.call({ op: 'unlink', path: '/dsh/workspace/full', directory: true }),
      (error: unknown) => codeOf(error) === 'ENOTEMPTY',
    )
    await assert.rejects(
      client.call({ op: 'unlink', path: '/dsh/workspace/full/keep.txt', directory: true }),
      (error: unknown) => codeOf(error) === 'ENOTDIR',
    )
    const entries = await client.call({ op: 'readdir', path: '/dsh/workspace' })
    assert.equal(entries.kind, 'entries')
    if (entries.kind === 'entries') {
      assert.deepEqual(entries.entries.map(entry => [entry.name, entry.kind]), [['full', 'directory']])
    }
  } finally {
    client.close()
    detach()
    port1.close()
    port2.close()
  }
})
