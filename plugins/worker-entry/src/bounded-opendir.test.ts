// SPDX-License-Identifier: MIT
// Unit contract for the capture-only bounded directory opener that the Worker
// installs on its virtual node:fs.promises face. The integration test in
// tests/worker-command-bounded-opendir.test.ts proves the same code over the
// pinned MemoryVfs and the production capture.

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  WORKER_BOUNDED_DIRECTORY_MATERIALIZATION,
  WORKER_BOUNDED_OPENDIR_MAX_ENTRIES,
  WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER,
  WORKER_COMMAND_BOUNDED_OPENDIR,
  installBoundedDirectoryOpener,
  type BoundedDirectoryVfs,
} from './bounded-opendir.ts'

const MANIFEST = '/dsh/config/vfs-manifest.json'

interface FakeVfs extends BoundedDirectoryVfs {
  readonly deferredCalls: unknown[]
}

/** A public manifest with the requested number of initial lazy registrations. */
function manifestText(lazyFiles: number): string {
  return JSON.stringify({
    lazy: lazyFiles === 0
      ? []
      : [{
        archive: 'lazy/test.tar.gz',
        files: Array.from({ length: lazyFiles }, (_, index) => ({ path: `lazy/f-${String(index)}`, size: 1 })),
      }],
  })
}

function fakeVfs(
  files: number,
  directories: number,
  options: { readonly lazyFiles?: number, readonly noManifest?: boolean, readonly noDefer?: boolean } = {},
): FakeVfs {
  const manifests = new Map<string, string>()
  if (options.noManifest !== true) manifests.set(MANIFEST, manifestText(options.lazyFiles ?? 0))
  const deferredCalls: unknown[] = []
  const vfs: FakeVfs = {
    usage: () => ({ files, directories, bytes: files }),
    existsSync: (path: string) => manifests.has(path),
    readFileSync: (path: string) => {
      const value = manifests.get(path)
      if (value === undefined) throw Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })
      return value
    },
    deferredCalls,
  }
  if (options.noDefer !== true) {
    vfs.deferArchive = (archive) => { deferredCalls.push(archive) }
  }
  return vfs
}

type MarkedOpener = ((...args: unknown[]) => unknown) & Record<symbol, unknown>

/** The installed opener, with its symbol facts visible to the assertions. */
function marked(opener: ((...args: unknown[]) => unknown) | undefined): MarkedOpener {
  return opener as MarkedOpener
}

/** The separate capture-only opener exposed by the transparent wrapper. */
function bounded(opener: ((...args: unknown[]) => unknown) | undefined): (...args: unknown[]) => unknown {
  const value = marked(opener)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER]
  assert.equal(typeof value, 'function')
  return value as (...args: unknown[]) => unknown
}

function fakeFace() {
  const calls: unknown[][] = []
  const original = (...args: unknown[]): unknown => {
    calls.push(args)
    return { path: args[0], read: async () => null, close: async () => {} }
  }
  return { face: { opendir: original }, calls, original }
}

describe('bounded directory opener', () => {
  test('a small VFS is verified through the separate capture opener', async () => {
    const { face, calls, original } = fakeFace()
    const vfs = fakeVfs(2, 3)
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 10 })
    assert.notEqual(face.opendir, original)
    assert.equal(marked(face.opendir)[WORKER_COMMAND_BOUNDED_OPENDIR], undefined,
      'the shared opener must not advertise the legacy cap it no longer applies')
    const opener = bounded(face.opendir)
    let checks = 0
    assert.deepEqual(marked(opener)[WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], {
      mode: 'bounded-materialization',
      upperBound: 'vfs-usage-and-deferred-registrations',
      maxEntries: 10,
    })
    const directory = await opener('/dsh/workspace', { buffered: false } as never, () => { checks += 1 })
    assert.equal(checks, 2, 'the per-call check runs before and after the scans')
    assert.deepEqual((directory as { path: unknown }).path, '/dsh/workspace')
    assert.deepEqual(calls, [['/dsh/workspace', { buffered: false }]],
      'the per-call check is consumed and never forwarded to the original opener')
    dispose()
  })

  test('changing the public manifest after boot cannot shrink the deferred entry bound', async () => {
    const { face, calls } = fakeFace()
    const vfs = fakeVfs(1, 1, { lazyFiles: 20 })
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 10 })
    // Lazy entries are already registered in the runtime. Editing their public
    // manifest later cannot remove them from its hidden deferred map.
    vfs.readFileSync = () => manifestText(0)
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace'),
      (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET',
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('an oversized whole VFS fails on the capture opener before the original runs', async () => {
    const { face, calls } = fakeFace()
    const dispose = installBoundedDirectoryOpener({ vfs: fakeVfs(8, 1), fs: face, maxEntries: 8 })
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace'),
      (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET'
        && /whole-VFS ceiling/u.test((error as Error).message),
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('ordinary shared opendir stays unbounded when the VFS exceeds the capture ceiling', async () => {
    const { face, calls, original } = fakeFace()
    const dispose = installBoundedDirectoryOpener({ vfs: fakeVfs(8, 1), fs: face, maxEntries: 8 })
    const directory = await face.opendir?.('/dsh/home/sessions')
    assert.deepEqual((directory as { path: unknown }).path, '/dsh/home/sessions')
    assert.deepEqual(calls, [['/dsh/home/sessions']])
    assert.notEqual(face.opendir, original)
    dispose()
  })

  test('the default ceiling is the Worker command default, not an unlimited fallback', async () => {
    assert.equal(WORKER_BOUNDED_OPENDIR_MAX_ENTRIES, 20_000)
    const { face, calls } = fakeFace()
    const dispose = installBoundedDirectoryOpener({ vfs: fakeVfs(WORKER_BOUNDED_OPENDIR_MAX_ENTRIES, 1), fs: face })
    await assert.rejects(async () => bounded(face.opendir)('/dsh/workspace'), /whole-VFS ceiling/u)
    assert.equal(calls.length, 0)
    dispose()
  })

  test('initial lazy registrations invisible to usage() still count toward the bound', async () => {
    const { face, calls } = fakeFace()
    // usage() reports one file and no directories; the manifest says eight
    // deferred files would be enumerated by readdirSync.
    const vfs = fakeVfs(1, 0, { lazyFiles: 8 })
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 8 })
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace'),
      (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET'
        && /8 observed lazy registrations/u.test((error as Error).message),
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('later public deferArchive calls are observed even when usage() never changes', async () => {
    const { face, calls } = fakeFace()
    const vfs = fakeVfs(1, 1)
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 10 })
    vfs.deferArchive?.({
      files: Array.from({ length: 10 }, (_, index) => ({ path: `lazy/l-${String(index)}`, size: 1 })),
    })
    assert.equal(vfs.deferredCalls.length, 1, 'the wrapper must still call the original deferArchive')
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace'),
      (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET',
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('missing or malformed initial lazy accounting fails closed', async () => {
    const broken: Array<{ readonly vfs: BoundedDirectoryVfs, readonly pattern: RegExp }> = []
    const noManifest = fakeVfs(1, 1, { noManifest: true })
    broken.push({ vfs: noManifest, pattern: /manifest .* is missing/u })
    const noDefer = fakeVfs(1, 1, { noDefer: true })
    broken.push({ vfs: noDefer, pattern: /no public deferArchive/u })

    const malformed: Array<[string, RegExp]> = [
      ['not json', /not valid JSON/u],
      [JSON.stringify({}), /no lazy archive list/u],
      [JSON.stringify({ lazy: [{}] }), /lists no files/u],
      [JSON.stringify({ lazy: [{ files: 'many' }] }), /lists no files/u],
    ]
    for (const [text, pattern] of malformed) {
      const vfs = fakeVfs(1, 1)
      vfs.readFileSync = () => text
      broken.push({ vfs, pattern })
    }

    for (const { vfs, pattern } of broken) {
      const { face, calls } = fakeFace()
      const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 100 })
      await assert.rejects(
        async () => bounded(face.opendir)('/dsh/workspace'),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE'
          && pattern.test((error as Error).message),
      )
      assert.equal(calls.length, 0)
      dispose()
    }
  })

  test('an uncountable later deferArchive call refuses the next bounded open', async () => {
    const { face, calls } = fakeFace()
    const vfs = fakeVfs(1, 1)
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 100 })
    ;(vfs.deferArchive as unknown as (archive: unknown) => void)({ files: 'not an array' })
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace'),
      (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE'
        && /cannot be counted/u.test((error as Error).message),
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('missing, throwing or non-finite usage fails closed before the original opener', async () => {
    const broken: unknown[] = [
      {},
      { usage: () => { throw new Error('usage exploded') } },
      { usage: () => null },
      { usage: () => ({ files: 1 }) },
      { usage: () => ({ files: Number.NaN, directories: 1 }) },
      { usage: () => ({ files: 1, directories: Number.POSITIVE_INFINITY }) },
      { usage: () => ({ files: -1, directories: 1 }) },
      { usage: () => ({ files: 1.5, directories: 1 }) },
      { usage: () => ({ files: 1, directories: Number.MAX_SAFE_INTEGER + 1 }) },
    ]
    for (const vfs of broken) {
      const { face, calls } = fakeFace()
      installBoundedDirectoryOpener({ vfs: vfs as BoundedDirectoryVfs, fs: face, maxEntries: 100 })
      await assert.rejects(
        async () => bounded(face.opendir)('/dsh/workspace'),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE',
        `expected usage refusal for ${JSON.stringify(vfs)}`,
      )
      assert.equal(calls.length, 0)
    }
  })

  test('the optional deadline check runs before and after the synchronous scans', async () => {
    const { face, calls } = fakeFace()
    let checks = 0
    const dispose = installBoundedDirectoryOpener({
      vfs: fakeVfs(1, 1),
      fs: face,
      maxEntries: 10,
      check: () => {
        checks += 1
        if (checks === 2) throw Object.assign(new Error('deadline exceeded'), { code: 'ABORT_ERR' })
      },
    })
    await assert.rejects(async () => bounded(face.opendir)('/dsh/workspace'), /deadline exceeded/u)
    assert.equal(checks, 2, 'one check before the scans and one before the original opener')
    assert.equal(calls.length, 0, 'the original opener must not run after the post-scan check fails')
    dispose()
  })

  test('a per-call deadline check fails closed after the scans and before the original opener', async () => {
    const { face, calls } = fakeFace()
    const dispose = installBoundedDirectoryOpener({ vfs: fakeVfs(1, 1), fs: face, maxEntries: 10 })
    let checks = 0
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace', () => {
        checks += 1
        if (checks === 2) throw Object.assign(new Error('per-call deadline exceeded'), { code: 'ABORT_ERR' })
      }),
      /per-call deadline exceeded/u,
    )
    assert.equal(checks, 2, 'the capture-owned check must be called on both sides of the scans')
    assert.equal(calls.length, 0, 'the original opener must not run when the post-scan check fails')
    dispose()
  })

  test('a per-call check must be a function and never becomes an original argument', async () => {
    const { face, calls } = fakeFace()
    const dispose = installBoundedDirectoryOpener({ vfs: fakeVfs(1, 1), fs: face, maxEntries: 10 })
    await assert.rejects(
      async () => bounded(face.opendir)('/dsh/workspace', undefined, 'not a check'),
      /per-call bounded opendir check/u,
    )
    assert.equal(calls.length, 0)
    dispose()
  })

  test('dispose restores the exact opener and deferArchive and removes both markers', async () => {
    const { face, original, calls } = fakeFace()
    const vfs = fakeVfs(1, 1)
    const originalDefer = vfs.deferArchive
    const dispose = installBoundedDirectoryOpener({ vfs, fs: face, maxEntries: 10 })
    const disposedFacade = face.opendir
    const disposeFacts = marked(disposedFacade)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER]
    assert.notEqual(face.opendir, original)
    assert.notEqual(vfs.deferArchive, originalDefer)
    dispose()
    assert.equal(face.opendir, original)
    assert.equal(vfs.deferArchive, originalDefer)
    assert.equal(marked(face.opendir)[WORKER_COMMAND_BOUNDED_OPENDIR], undefined)
    assert.equal(marked(face.opendir)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined)
    assert.equal(marked(face.opendir)[WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], undefined)
    assert.equal(marked(disposedFacade)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined,
      'a retained disposed facade must lose its capability')
    assert.equal(marked(disposeFacts as (...args: unknown[]) => unknown)[WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], undefined,
      'a retained disposed bounded function must lose its facts marker')
    await assert.rejects(
      async () => (disposeFacts as (...args: unknown[]) => unknown)('/dsh/workspace'),
      /disposed/u,
    )
    assert.equal(calls.length, 0, 'a retained capability must not materialise after disposal')
    await face.opendir?.('/dsh/workspace')
  })

  test('an older disposer does not remove a newer wrapper or leave its marker behind', async () => {
    const { face } = fakeFace()
    const first = installBoundedDirectoryOpener({ vfs: fakeVfs(1, 1), fs: face, maxEntries: 10 })
    const firstWrapper = face.opendir
    const second = installBoundedDirectoryOpener({ vfs: fakeVfs(2, 2), fs: face, maxEntries: 20 })
    const installed = face.opendir
    first()
    assert.equal(face.opendir, installed)
    assert.deepEqual(marked(bounded(installed))[WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], {
      mode: 'bounded-materialization',
      upperBound: 'vfs-usage-and-deferred-registrations',
      maxEntries: 20,
    })
    assert.equal(marked(firstWrapper)[WORKER_COMMAND_BOUNDED_OPENDIR], undefined,
      'the disposed lower wrapper can never satisfy the legacy capture marker again')
    assert.equal(marked(firstWrapper)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined,
      'the disposed lower wrapper can never satisfy the new capture marker again')
    await bounded(installed)('/dsh/workspace')
    second()
    assert.equal(face.opendir, firstWrapper, 'the lower wrapper is now an unmarked delegate')
    assert.equal(marked(face.opendir)[WORKER_COMMAND_BOUNDED_OPENDIR], undefined)
    assert.equal(marked(face.opendir)[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined)
    await face.opendir?.('/dsh/workspace')
  })

  test('the host Node fs.promises object is never touched', async () => {
    const { promises: hostFsp } = await import('node:fs')
    const opener = hostFsp.opendir as unknown as Record<symbol, unknown>
    assert.equal(opener[WORKER_COMMAND_BOUNDED_OPENDIR], undefined)
    assert.equal(opener[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined)
    assert.equal(opener[WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], undefined)
  })
})
