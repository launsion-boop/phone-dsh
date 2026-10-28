// SPDX-License-Identifier: MIT
/**
 * G2-FIX-54: the snapshot fallback that keeps a WASI guest's file view alive in
 * a Worker without a synchronous VFS channel.
 *
 * The captured view is what a rebuilt `python3` reads (`cwd`, absolute `/dsh`
 * paths, relative paths); mutations are applied locally and written back to the
 * live VFS before the command's exit is reported.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-snapshot.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MemoryVfsBackend } from './vfs-backends.ts'
import type { VfsRequest, VfsValue } from './types.ts'
import { captureVfsSnapshot, SnapshotWasiVfs } from './vfs-snapshot.ts'

function seed(): MemoryVfsBackend {
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/workspace/exports')
  backend.seedDirectory('/dsh/home')
  backend.seedFile('/dsh/workspace/data.txt', 'hello\n')
  backend.seedFile('/dsh/workspace/exports/ledger.csv', 'id,amount\n1,10\n')
  backend.seedFile('/dsh/home/notes.md', '# notes\n')
  return backend
}

/** Records every write-behind request and answers success. */
class RecordingWriter {
  readonly calls: VfsRequest[] = []
  failWith: Error | undefined

  async call(request: VfsRequest): Promise<VfsValue> {
    this.calls.push(request)
    if (this.failWith !== undefined) throw this.failWith
    return { kind: 'void' }
  }
}

test('snapshot capture walks the preopened trees deterministically', async () => {
  const backend = seed()
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/workspace', '/dsh/home'])
  try {
    assert.deepEqual(snapshot.missing, [])
    assert.equal(snapshot.truncated, false)
    assert.equal(snapshot.bytes, 'hello\n'.length + 'id,amount\n1,10\n'.length + '# notes\n'.length)
    // Roots are visited in the given order and each directory in name order,
    // so two captures of the same tree are byte-for-byte identical.
    const paths = snapshot.entries.map(entry => entry.path)
    assert.deepEqual(paths, [
      '/dsh/workspace',
      '/dsh/workspace/data.txt',
      '/dsh/workspace/exports',
      '/dsh/workspace/exports/ledger.csv',
      '/dsh/home',
      '/dsh/home/notes.md',
    ])
    const file = snapshot.entries.find(entry => entry.path === '/dsh/workspace/data.txt')
    assert.equal(new TextDecoder().decode(file?.bytes), 'hello\n')
    // A root the live VFS does not have is reported, never silently dropped.
    const missing = await captureVfsSnapshot(backend, ['/dsh/workspace', '/dsh/tmp'])
    assert.deepEqual(missing.missing, ['/dsh/tmp'])
  } finally {
    await backend.sync?.()
  }
})

test('snapshot capture reports a truncated view instead of pretending', async () => {
  const backend = seed()
  const bounded = await captureVfsSnapshot(backend, ['/dsh/workspace'], { maxEntries: 1 })
  assert.equal(bounded.truncated, true)
  const small = await captureVfsSnapshot(backend, ['/dsh/workspace'], { maxBytes: 2 })
  assert.equal(small.truncated, true)
})

test('a snapshot view serves cwd-style reads with no SharedArrayBuffer channel', async () => {
  const backend = seed()
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/workspace'])
  const writer = new RecordingWriter()
  const vfs = new SnapshotWasiVfs(snapshot, writer)
  // stat / readdir / open / read are the calls wasi-libc makes for
  // os.getcwd(), os.listdir() and open().
  assert.equal(vfs.stat('/dsh/workspace').kind, 'directory')
  assert.deepEqual(vfs.readdir('/dsh/workspace').map(entry => entry.name), ['data.txt', 'exports'])
  const handle = vfs.open('/dsh/workspace/data.txt', {
    create: false,
    truncate: false,
    exclusive: false,
    directory: false,
  })
  assert.equal(handle.kind, 'file')
  assert.equal(new TextDecoder().decode(vfs.read('/dsh/workspace/data.txt', 0, 64)), 'hello\n')
  assert.equal(writer.calls.length, 0, 'reads never reach the proxy')
})

test('a snapshot view can be updated with a fresh capture of the live VFS', async () => {
  const backend = seed()
  const writer = new RecordingWriter()
  const vfs = new SnapshotWasiVfs(await captureVfsSnapshot(backend, ['/dsh/workspace']), writer)
  // A bash step changes one file, adds one and removes one after the capture.
  backend.seedFile('/dsh/workspace/data.txt', 'changed\n')
  backend.seedFile('/dsh/workspace/added.txt', 'added\n')
  backend.unlink('/dsh/workspace/exports/ledger.csv')
  vfs.update(await captureVfsSnapshot(backend, ['/dsh/workspace']))
  assert.equal(new TextDecoder().decode(vfs.read('/dsh/workspace/data.txt', 0, 64)), 'changed\n')
  assert.equal(new TextDecoder().decode(vfs.read('/dsh/workspace/added.txt', 0, 64)), 'added\n')
  assert.deepEqual(vfs.readdir('/dsh/workspace/exports').map(entry => entry.name), [])
  assert.equal(writer.calls.length, 0, 'seeding a capture is not a guest write')
})

test('a snapshot view applies mutations locally and writes them back on flush', async () => {
  const backend = seed()
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/workspace'])
  const writer = new RecordingWriter()
  const vfs = new SnapshotWasiVfs(snapshot, writer)
  vfs.write('/dsh/workspace/out.txt', 0, new TextEncoder().encode('result\n'), { append: false, create: true })
  // A later read in the same program sees its own write.
  assert.equal(new TextDecoder().decode(vfs.read('/dsh/workspace/out.txt', 0, 64)), 'result\n')
  vfs.mkdir('/dsh/workspace/sub')
  vfs.rename('/dsh/workspace/out.txt', '/dsh/workspace/sub/out.txt')
  vfs.truncate('/dsh/workspace/sub/out.txt', 0)
  vfs.sync()
  assert.deepEqual(writer.calls.map(call => call.op), ['write', 'mkdir', 'rename', 'truncate', 'sync'])
  const write = writer.calls[0] as { readonly path: string; readonly data: Uint8Array }
  assert.equal(write.path, '/dsh/workspace/out.txt')
  assert.equal(new TextDecoder().decode(write.data), 'result\n')
  assert.deepEqual(writer.calls[2], {
    op: 'rename',
    from: '/dsh/workspace/out.txt',
    to: '/dsh/workspace/sub/out.txt',
  })
  await vfs.flushWrites()
})

test('a snapshot view fails loud when a write-back is refused', async () => {
  const backend = seed()
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/workspace'])
  const writer = new RecordingWriter()
  writer.failWith = new Error('the live VFS refused the write')
  const vfs = new SnapshotWasiVfs(snapshot, writer)
  vfs.write('/dsh/workspace/out.txt', 0, new TextEncoder().encode('x'), { append: false, create: true })
  await assert.rejects(vfs.flushWrites(), /refused the write/)
})

test('a read-only snapshot refuses a write instead of losing it', async () => {
  const backend = seed()
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/workspace'])
  const vfs = new SnapshotWasiVfs(snapshot)
  vfs.write('/dsh/workspace/out.txt', 0, new TextEncoder().encode('x'), { append: false, create: true })
  await assert.rejects(vfs.flushWrites(), /read-only/)
})
