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
import { VfsProxyError } from './errors.ts'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { EXEC_INTERNAL_ROOTS, execReadDeniedMessage } from './vfs-namespace.ts'
import { normalizeAbsolutePath } from './vfs-paths.ts'
import type { VfsDirEntry, VfsRequest, VfsStat, VfsValue } from './types.ts'
import { captureVfsSnapshot, SnapshotWasiVfs } from './vfs-snapshot.ts'
import type { VfsSnapshot } from './vfs-snapshot.ts'

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

/**
 * A backend that answers `EACCES` for the DSH-internal roots, the way the real
 * execution-surface policy does (`channel.md` §VFS: `python3` and `jq` never see
 * `/dsh/home/{sessions,storages,tool-journal}`).
 *
 * The denial is the production shape, not a generic error: a `VfsProxyError`
 * built from the same message builder {@link VfsNamespace.assertExecReadable}
 * uses. The walk therefore has to recognise the *code* on the object the policy
 * actually throws — an in-memory backend that never denies would let a walk
 * that only tolerates `ENOENT` pass this test.
 */
class DenyingBackend extends MemoryVfsBackend {
  private deny(path: string): void {
    for (const root of EXEC_INTERNAL_ROOTS) {
      if (path !== root && !path.startsWith(`${root}/`)) continue
      throw new VfsProxyError('EACCES', execReadDeniedMessage(path, root))
    }
  }

  override stat(path: string): VfsStat {
    this.deny(normalizeAbsolutePath(path))
    return super.stat(path)
  }

  override readdir(path: string): readonly VfsDirEntry[] {
    this.deny(normalizeAbsolutePath(path))
    return super.readdir(path)
  }
}

test('a denied internal root is omitted from the snapshot, never fatal', async () => {
  const backend = new DenyingBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/sessions')
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/data.txt', 'hello\n')

  // Without the fix the walk rethrew EACCES and the whole capture failed, so
  // every WASI-backed command (`python3`, `jq`) died with backend-failed
  // before the guest ran — while capabilities.json kept advertising them.
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/home', '/dsh/workspace'])
  const paths = snapshot.entries.map(entry => entry.path)

  assert.ok(paths.includes('/dsh/home'), 'the readable root is still captured')
  assert.ok(paths.includes('/dsh/workspace/data.txt'), 'the workspace is still captured')
  assert.ok(
    !paths.some(path => path.startsWith('/dsh/home/sessions')),
    'the denied subtree stays out of the guest view',
  )
  assert.ok(snapshot.omitted > 0, 'the omission is counted, not hidden')
  assert.equal(snapshot.truncated, false, 'a policy denial is not a truncated view')
  // A second capture answers the same thing: the policy did not poison the
  // walk, so a warm toolbox can refresh before the next dispatch.
  assert.deepEqual(
    (await captureVfsSnapshot(backend, ['/dsh/home', '/dsh/workspace'])).entries.map(entry => entry.path),
    paths,
  )
})

test('a denied directory reached through readdir is omitted like an absent one', async () => {
  const backend = new DenyingBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/tool-journal')
  backend.seedFile('/dsh/home/tool-journal/entry.jsonl', '{"secret":true}')
  backend.seedFile('/dsh/home/notes.md', '# notes\n')

  const snapshot = await captureVfsSnapshot(backend, ['/dsh/home'])
  const paths = snapshot.entries.map(entry => entry.path)
  assert.ok(paths.includes('/dsh/home/notes.md'), 'the readable sibling is captured')
  assert.ok(!paths.some(path => path.startsWith('/dsh/home/tool-journal')), 'the denied subtree is gone')
})

test('a non-policy failure still aborts the capture instead of serving a short view', async () => {
  class BrokenBackend extends MemoryVfsBackend {
    override stat(path: string): VfsStat {
      if (normalizeAbsolutePath(path) === '/dsh/home/storages') {
        throw Object.assign(new Error('EIO: the image read failed'), { code: 'EIO' })
      }
      return super.stat(path)
    }
  }
  const backend = new BrokenBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/storages')
  backend.seedFile('/dsh/home/storages/store.json', '{}')

  // Only the policy's own answer is "the guest may not see this". A broken
  // read is still fatal: a silently short snapshot is worse than no command.
  await assert.rejects(
    captureVfsSnapshot(backend, ['/dsh/home']),
    /EIO: the image read failed/,
  )
})

/**
 * One denied path's expected guest answer: the policy sentence with exactly one
 * errno prefix, which is the line the WASI host renders on the guest's stderr.
 * @param path - denied virtual path.
 * @param root - internal root containing it.
 * @returns the `EACCES` error message the guest must observe.
 */
function expectedDenial(path: string, root: string): string {
  return `EACCES: ${execReadDeniedMessage(path, root)}`
}

/**
 * A backend that lets an execution surface `stat` a directory but refuses its
 * listing.
 *
 * The production policy denies `stat` too, so this shape is not what Android
 * produces today — but it is exactly what a policy that only guards `readdir`
 * produces, and the walk has to answer both the same way: the name stays out
 * of the parent's listing, and naming the path still gets `EACCES`.
 */
class ListingDeniedBackend extends MemoryVfsBackend {
  override readdir(path: string): readonly VfsDirEntry[] {
    const target = normalizeAbsolutePath(path)
    if (target === '/dsh/home/storages') {
      throw new VfsProxyError('EACCES', execReadDeniedMessage(target, target))
    }
    return super.readdir(path)
  }
}

test('a denied path is answered EACCES with the policy sentence, not the guest ENOENT', async () => {
  const backend = new DenyingBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/sessions')
  backend.seedFile('/dsh/home/sessions/session.v4.jsonl', '{"secret":true}')
  backend.seedFile('/dsh/home/notes.md', '# notes\n')

  const snapshot = await captureVfsSnapshot(backend, ['/dsh/home'])
  // The capture keeps the answer, not only the omission.
  //
  // All three internal roots are recorded, not just the one the walk happens to
  // discover: the listing filter hides these names from `readdir`, so discovery
  // alone would leave the other two answering the guest's own ENOENT for paths
  // that exist. `DenyingBackend` refuses by name, so all three are refused here.
  assert.deepEqual(
    snapshot.denied.map(denial => denial.path),
    ['/dsh/home/sessions', '/dsh/home/storages', '/dsh/home/tool-journal'],
  )
  assert.equal(snapshot.denied[0]?.code, 'EACCES')
  assert.equal(
    snapshot.denied[0]?.message,
    execReadDeniedMessage('/dsh/home/sessions', '/dsh/home/sessions'),
    'the policy sentence is carried verbatim (no second wording)',
  )

  const vfs = new SnapshotWasiVfs(snapshot)
  // The recorded sentence names the denied root — that is the path the live
  // VFS refused, and the one the remediation is about. A child the guest names
  // is reported by the guest's own error line, which is why the child's answer
  // is the root's sentence rather than a re-worded copy of it.
  const refusal = expectedDenial('/dsh/home/sessions', '/dsh/home/sessions')
  for (const path of ['/dsh/home/sessions', '/dsh/home/sessions/session.v4.jsonl', '/dsh/home/sessions/deeper/x']) {
    // stat is what `os.stat` and `path_open` ask first; a miss here would
    // become the guest's own `No such file or directory`.
    assert.throws(
      () => vfs.stat(path),
      (error: unknown) => error instanceof VfsProxyError
        && error.code === 'EACCES'
        && error.message === refusal,
      `stat(${path}) must answer the policy's EACCES`,
    )
  }
  assert.throws(
    () => vfs.open('/dsh/home/sessions', { create: false, truncate: false, exclusive: false, directory: false }),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES',
    'open() on the denied directory answers EACCES, not ENOENT/EISDIR',
  )
  assert.throws(
    () => vfs.read('/dsh/home/sessions/session.v4.jsonl', 0, 64),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES',
  )
  // A sibling whose name merely starts with the denied name is not covered.
  assert.equal(new TextDecoder().decode(vfs.read('/dsh/home/notes.md', 0, 64)), '# notes\n')
  // The local view really has no entry behind the guard: the EACCES is the
  // only thing standing between the guest and a false "not found".
  assert.throws(() => MemoryVfsBackend.prototype.stat.call(vfs, '/dsh/home/sessions'),
    (error: unknown) => (error as VfsProxyError).code === 'ENOENT')
})

test('a denied directory stays out of the listing at both layers', async () => {
  const backend = new ListingDeniedBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/storages')
  backend.seedFile('/dsh/home/storages/store.json', '{}')
  backend.seedFile('/dsh/home/notes.md', '# notes\n')

  const snapshot = await captureVfsSnapshot(backend, ['/dsh/home'])
  // Capture layer: the directory was statable, but the refused listing
  // withdraws the name the walk had already pushed.
  assert.ok(
    !snapshot.entries.some(entry => entry.path === '/dsh/home/storages'),
    'the readdir-denied directory is not an entry',
  )
  assert.deepEqual(snapshot.denied.map(denial => denial.path), ['/dsh/home/storages'])

  const vfs = new SnapshotWasiVfs(snapshot)
  assert.deepEqual(vfs.readdir('/dsh/home').map(entry => entry.name), ['notes.md'])
  assert.throws(() => vfs.stat('/dsh/home/storages'),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES')
})

test('a snapshot that still carries a denied entry never lists it', () => {
  // The view's own invariant: a snapshot produced by an older capture (or a
  // hand-written one) may contain both the entry and the denial. The listing
  // is the one place that name could become visible again, so the view
  // filters it instead of trusting the capture.
  const legacy: VfsSnapshot = {
    roots: ['/dsh/home'],
    missing: [],
    denied: [{
      path: '/dsh/home/sessions',
      code: 'EACCES',
      message: execReadDeniedMessage('/dsh/home/sessions', '/dsh/home/sessions'),
    }],
    entries: [
      { path: '/dsh/home', kind: 'directory', mode: 0o755, mtimeMs: 1, ino: 1 },
      { path: '/dsh/home/sessions', kind: 'directory', mode: 0o755, mtimeMs: 1, ino: 2 },
      { path: '/dsh/home/notes.md', kind: 'file', mode: 0o644, mtimeMs: 1, ino: 3, bytes: new TextEncoder().encode('# notes\n') },
    ],
    bytes: 8,
    truncated: false,
    omitted: 0,
  }
  const vfs = new SnapshotWasiVfs(legacy)
  assert.deepEqual(vfs.readdir('/dsh/home').map(entry => entry.name), ['notes.md'])
  assert.throws(() => vfs.readdir('/dsh/home/sessions'),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES')
})

test('a denied prefix also refuses mutations instead of forwarding them', async () => {
  const backend = new DenyingBackend()
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/home/sessions')
  const writer = new RecordingWriter()
  const vfs = new SnapshotWasiVfs(await captureVfsSnapshot(backend, ['/dsh/home']), writer)
  writer.calls.length = 0

  assert.throws(() => vfs.writeFile('/dsh/home/sessions/x', new TextEncoder().encode('x'), { create: true }),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES')
  assert.throws(() => vfs.mkdir('/dsh/home/sessions/dir'),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES')
  assert.throws(() => vfs.rename('/dsh/home/notes.md', '/dsh/home/sessions/x'),
    (error: unknown) => (error as VfsProxyError).code === 'EACCES')
  assert.deepEqual(writer.calls, [], 'a refused mutation never reaches the live VFS')
})

test('a capture whose denied root is also a preopen records the denial instead of "missing"', async () => {
  const backend = new DenyingBackend()
  backend.seedDirectory('/dsh/home/sessions')
  const snapshot = await captureVfsSnapshot(backend, ['/dsh/home/sessions'])
  // The preopen exists; calling it missing would be the same false claim in the
  // file-view summary that ENOENT is in the guest.
  assert.deepEqual(snapshot.missing, [])
  assert.deepEqual(snapshot.denied.map(denial => denial.path), ['/dsh/home/sessions'])
  assert.equal(snapshot.truncated, false)
})
