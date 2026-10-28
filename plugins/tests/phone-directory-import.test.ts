// SPDX-License-Identifier: MIT
// Real Node filesystem tests for the Worker-side directory import service.
//
// Every case uses a fresh mkdtemp workspace and source tree. The tests drive
// begin/write/commit/abort exactly as the native importer does and inspect the
// real files afterward; nothing here mocks node:fs.

import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { after, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { remoteErrorOf } from '@deepseek-ai/dsh-typert-protocol'
import {
  MAX_COMPLETED_IMPORTS,
  WorkspaceImportError,
  WorkspaceImportService,
} from '../phone-directory-import/src/import-service.ts'
import {
  MAX_ACTIVE_IMPORT_ROUTES,
  PhoneDirectoryImportRemote,
} from '../phone-directory-import/src/remote.ts'
import { DIRECTORY_IMPORT_LIMITS, type DirectoryImportBeginRequest } from '../phone-directory-import/src/types.ts'

const temporaryDirectories: string[] = []

after(async () => {
  await Promise.all(temporaryDirectories.map(directory => rm(directory, { recursive: true, force: true })))
})

async function makeWorkspace(): Promise<{ root: string; workspace: string; source: string }> {
  const root = await mkdtemp(join(tmpdir(), 'pdsh-directory-import-'))
  temporaryDirectories.push(root)
  const workspace = join(root, 'workspace')
  const source = join(root, 'Selected Folder')
  await mkdir(workspace, { recursive: true })
  await mkdir(source, { recursive: true })
  return { root, workspace, source }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}

async function collectManifest(source: string, targetDirectory: string,
  sessionId = 'session-1'): Promise<DirectoryImportBeginRequest> {
  const directories: string[] = []
  const files: { path: string; size: number }[] = []
  async function walk(directory: string, relative: string): Promise<void> {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = join(directory, entry.name)
      if (entry.isDirectory()) {
        directories.push(childRelative)
        await walk(child, childRelative)
      } else if (entry.isFile()) {
        files.push({ path: childRelative, size: (await stat(child)).size })
      }
    }
  }
  await walk(source, '')
  files.sort((left, right) => left.path.localeCompare(right.path))
  directories.sort()
  return {
    v: 1,
    sessionId,
    targetDirectory,
    entryName: basename(source),
    directories,
    files,
    totalBytes: files.reduce((sum, file) => sum + file.size, 0),
  }
}

async function upload(service: WorkspaceImportService, importId: string, source: string,
  files: readonly { path: string; size: number }[], chunkBytes = 64 * 1024): Promise<void> {
  for (const file of files) {
    const data = await readFile(join(source, file.path))
    assert.equal(data.length, file.size)
    let offset = 0
    while (offset < data.length) {
      const end = Math.min(offset + chunkBytes, data.length)
      const result = await service.write(importId, file.path, offset, data.subarray(offset, end).toString('base64'))
      assert.equal(result.received, end)
      offset = end
    }
  }
}

async function snapshot(directory: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  async function walk(current: string, relative: string): Promise<void> {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = join(current, entry.name)
      if (entry.isDirectory()) {
        result[`${childRelative}/`] = 'directory'
        await walk(child, childRelative)
      } else if (entry.isFile()) {
        result[childRelative] = (await readFile(child)).toString('base64')
      }
    }
  }
  await walk(directory, '')
  return result
}

function isBadRequest(error: unknown): boolean {
  return error instanceof WorkspaceImportError && error.code === 'bad-request'
}

test('import: nested binary files and empty directories survive byte-for-byte', async () => {
  const { workspace, source } = await makeWorkspace()
  const binary = Buffer.from(Array.from({ length: 300_000 }, (_value, index) => (index * 31) % 256))
  await mkdir(join(source, 'nested', 'deeper'), { recursive: true })
  await mkdir(join(source, 'empty', 'deep'), { recursive: true })
  await writeFile(join(source, 'alpha.bin'), binary)
  await writeFile(join(source, 'nested', 'deeper', 'beta.dat'), Buffer.from([0, 255, 1, 254, 2, 253]))

  const before = await snapshot(source)
  const manifest = await collectManifest(source, workspace)
  let flushes = 0
  const service = new WorkspaceImportService(workspace, { flush: () => { flushes += 1 } })

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  const result = await service.commit(importId)

  assert.equal(result.workspacePath, `imports/${basename(source)}`)
  assert.equal(result.absolutePath, join(workspace, 'imports', basename(source)))
  assert.equal(result.fileCount, 2)
  assert.equal(result.totalBytes, binary.length + 6)
  assert.deepEqual(await readFile(join(result.absolutePath, 'alpha.bin')), binary)
  assert.deepEqual(await readFile(join(result.absolutePath, 'nested', 'deeper', 'beta.dat')),
    Buffer.from([0, 255, 1, 254, 2, 253]))
  assert.equal((await stat(join(result.absolutePath, 'empty', 'deep'))).isDirectory(), true)
  assert.equal(flushes, 1)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  assert.deepEqual(await snapshot(source), before, 'the source directory is unchanged')
})

test('import: an existing same-name directory is never overwritten', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'new.txt'), 'new content')
  const original = join(workspace, 'imports', basename(source))
  await mkdir(original, { recursive: true })
  await writeFile(join(original, 'keep.txt'), 'keep me')
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  const result = await service.commit(importId)

  assert.equal(result.workspacePath, `imports/${basename(source)}-2`)
  assert.equal(await readFile(join(original, 'keep.txt'), 'utf8'), 'keep me')
  assert.equal(await readFile(join(result.absolutePath, 'new.txt'), 'utf8'), 'new content')
  assert.equal(await pathExists(join(result.absolutePath, 'keep.txt')), false)
})

test('import: abort removes private staging and never creates a final directory', async () => {
  const { workspace, source } = await makeWorkspace()
  await mkdir(join(source, 'nested'), { recursive: true })
  await writeFile(join(source, 'nested', 'a.bin'), Buffer.alloc(4096, 7))
  await writeFile(join(workspace, 'user-file.txt'), 'user data')
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  const importId = await service.begin(manifest)
  assert.equal(await pathExists(join(workspace, '.imports', importId)), true)
  await service.write(importId, 'nested/a.bin', 0, Buffer.alloc(1024, 7).toString('base64'))
  await service.abort(importId)

  assert.equal(await pathExists(join(workspace, 'imports')), false)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  assert.equal(await readFile(join(workspace, 'user-file.txt'), 'utf8'), 'user data')
})

test('import: abort leaves a pre-existing .imports directory and its files alone', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'a')
  await mkdir(join(workspace, '.imports', 'another-import'), { recursive: true })
  await writeFile(join(workspace, '.imports', 'another-import', 'part'), 'partial')
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  const importId = await service.begin(manifest)
  await service.abort(importId)
  assert.equal(await readFile(join(workspace, '.imports', 'another-import', 'part'), 'utf8'), 'partial')
})

test('import: path escapes, absolute paths, NUL and forged totals are refused', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'a')
  const base = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  await assert.rejects(
    () => service.begin({ ...base, files: [{ path: '../escape', size: 1 }], totalBytes: 1 }),
    isBadRequest)
  await assert.rejects(
    () => service.begin({ ...base, files: [{ path: '/absolute', size: 1 }], totalBytes: 1 }),
    isBadRequest)
  await assert.rejects(
    () => service.begin({ ...base, files: [{ path: 'a\u0000b', size: 1 }], totalBytes: 1 }),
    isBadRequest)
  await assert.rejects(
    () => service.begin({ ...base, totalBytes: 2 }),
    isBadRequest)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
})

test('import: the Worker enforces the same file, total and count limits', async () => {
  const { workspace } = await makeWorkspace()
  const service = new WorkspaceImportService(workspace)
  const manifest = (files: { path: string; size: number }[], totalBytes: number,
    directories: string[] = []): DirectoryImportBeginRequest => ({
    v: 1,
    sessionId: 'session-1',
    targetDirectory: workspace,
    entryName: 'too-big',
    directories,
    files,
    totalBytes,
  })

  await assert.rejects(
    () => service.begin(manifest(
      [{ path: 'large.bin', size: DIRECTORY_IMPORT_LIMITS.maxFileBytes + 1 }],
      DIRECTORY_IMPORT_LIMITS.maxFileBytes + 1)),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'bad-request')
  await assert.rejects(
    () => service.begin(manifest(
      [{ path: 'a', size: DIRECTORY_IMPORT_LIMITS.maxFileBytes },
        { path: 'b', size: DIRECTORY_IMPORT_LIMITS.maxTotalBytes - DIRECTORY_IMPORT_LIMITS.maxFileBytes + 1 }],
      DIRECTORY_IMPORT_LIMITS.maxTotalBytes + 1)),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'bad-request')
  await assert.rejects(
    () => service.begin(manifest(
      Array.from({ length: DIRECTORY_IMPORT_LIMITS.maxFiles + 1 }, (_value, index) =>
        ({ path: `f-${index}`, size: 0 })), 0)),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'bad-request')
  await assert.rejects(
    () => service.begin(manifest([], 0,
      Array.from({ length: DIRECTORY_IMPORT_LIMITS.maxDirectories + 1 }, (_value, index) => `d-${index}`))),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'bad-request')
  assert.equal(await pathExists(join(workspace, '.imports')), false)
})

test('import: every path segment uses the same 128 UTF-8 byte cap as native staging', async () => {
  const { workspace, source } = await makeWorkspace()
  const service = new WorkspaceImportService(workspace)
  const base = await collectManifest(source, workspace)
  const maxName = 'x'.repeat(DIRECTORY_IMPORT_LIMITS.maxEntryNameLength)
  const overName = 'x'.repeat(DIRECTORY_IMPORT_LIMITS.maxEntryNameLength + 1)
  const multibyteOver = 'é'.repeat(65) // 65 characters, 130 UTF-8 bytes

  const request = (files: { path: string; size: number }[], directories: string[] = []): DirectoryImportBeginRequest => ({
    ...base,
    entryName: 'entry',
    directories,
    files,
    totalBytes: files.reduce((sum, file) => sum + file.size, 0),
  })

  for (const path of [overName, multibyteOver]) {
    await assert.rejects(
      () => service.begin(request([{ path, size: 0 }])),
      isBadRequest,
      `a >128-byte file name must be refused: ${JSON.stringify(path)}`)
  }
  for (const path of [overName, multibyteOver]) {
    await assert.rejects(
      () => service.begin(request([], [path])),
      isBadRequest,
      `a >128-byte directory name must be refused: ${JSON.stringify(path)}`)
  }
  assert.equal(await pathExists(join(workspace, '.imports')), false)

  // Exactly the cap is accepted for both a directory and a file name; these
  // are real VFS directories, not just a validator call.
  const directoryImport = await service.begin(request([], [`${maxName}/sub`]))
  assert.equal(await pathExists(join(workspace, '.imports', directoryImport, maxName, 'sub')), true)
  await service.abort(directoryImport)

  const fileImport = await service.begin(request([{ path: maxName, size: 0 }]))
  assert.equal(await pathExists(join(workspace, '.imports', fileImport, maxName)), true)
  await service.abort(fileImport)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
})

test('import: wrong offsets, bad base64 and a missing chunk fail without a final tree', async () => {
  const { workspace, source } = await makeWorkspace()
  const data = Buffer.alloc(300_000, 3)
  await writeFile(join(source, 'chunked.bin'), data)
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  let importId = await service.begin(manifest)
  await assert.rejects(
    () => service.write(importId, 'chunked.bin', 1, data.subarray(0, 10).toString('base64')),
    isBadRequest)
  await assert.rejects(
    () => service.write(importId, 'chunked.bin', 0, 'not base64!'),
    isBadRequest)
  await service.write(importId, 'chunked.bin', 0, data.subarray(0, 131_072).toString('base64'))
  await assert.rejects(
    () => service.commit(importId),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'bad-request')
  assert.equal(await pathExists(join(workspace, 'imports')), false)
  // A commit that failed before publishing already removed its private
  // staging; it is not left behind for a later abort.
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  await assert.rejects(
    () => service.abort(importId),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'not-found')

  importId = await service.begin(manifest)
  await assert.rejects(
    () => service.write(importId, 'chunked.bin', 0, Buffer.alloc(data.length + 1, 3).toString('base64')),
    isBadRequest)
  await service.abort(importId)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
})

test('import: verification failure removes the final directory, flushes the rollback and self-cleans', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const before = await snapshot(source)
  const manifest = await collectManifest(source, workspace)
  let flushes = 0
  const service = new WorkspaceImportService(workspace, {
    verify: async () => { throw new Error('verification refused') },
    flush: () => { flushes += 1 },
  })

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  await assert.rejects(() => service.commit(importId),
    (error: unknown) => error instanceof Error && error.message.includes('verification refused'))
  assert.equal(await pathExists(join(workspace, 'imports', basename(source))), false)
  assert.equal(await pathExists(join(workspace, 'imports')), false)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  // The rename had already happened, so the rollback deletion is flushed once
  // so a recovered VFS cannot resurrect the failed import.
  assert.equal(flushes, 1)
  await assert.rejects(
    () => service.abort(importId),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'not-found')
  assert.deepEqual(await snapshot(source), before, 'the source directory is unchanged')
})

test('import: a flush failure after rename rolls the final tree back and flushes again', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const before = await snapshot(source)
  const manifest = await collectManifest(source, workspace)
  let flushes = 0
  const service = new WorkspaceImportService(workspace, {
    flush: () => {
      flushes += 1
      if (flushes === 1) throw new Error('flush refused')
    },
  })

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  await assert.rejects(() => service.commit(importId),
    (error: unknown) => error instanceof Error && error.message.includes('flush refused'))
  assert.equal(await pathExists(join(workspace, 'imports', basename(source))), false)
  assert.equal(await pathExists(join(workspace, 'imports')), false)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  assert.equal(flushes, 2, 'the rollback deletion is flushed after the failed publish flush')
  assert.deepEqual(await snapshot(source), before, 'the source directory is unchanged')
})

test('import: an abort racing a commit cannot delete the tree being published', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const manifest = await collectManifest(source, workspace)
  let releaseVerify!: () => void
  let verifyStarted!: () => void
  const started = new Promise<void>((resolve) => { verifyStarted = resolve })
  const verifyGate = new Promise<void>((resolve) => { releaseVerify = resolve })
  const service = new WorkspaceImportService(workspace, {
    verify: async () => {
      verifyStarted()
      await verifyGate
    },
  })

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)

  const commitPromise = service.commit(importId)
  await started
  const abortPromise = service.abort(importId)
  releaseVerify()
  const result = await commitPromise
  const aborted = await abortPromise

  assert.equal(aborted, false, 'abort must refuse to delete a commit that already started')
  assert.equal(result.workspacePath, `imports/${basename(source)}`)
  assert.equal(await readFile(join(result.absolutePath, 'a.bin'), 'utf8'), 'payload')
  assert.equal(await pathExists(join(workspace, 'imports', `${basename(source)}-2`)), false)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
})

test('import: concurrent and retried commits are idempotent and keep one real directory', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  const [first, second] = await Promise.all([service.commit(importId), service.commit(importId)])
  assert.deepEqual(first, second)
  // A retry after the response was lost (and after the active mapping was
  // retired) still observes the same committed result.
  const retried = await service.commit(importId)
  assert.deepEqual(retried, first)
  assert.equal(await readFile(join(first.absolutePath, 'a.bin'), 'utf8'), 'payload')
  assert.equal(await pathExists(join(workspace, 'imports', `${basename(source)}-2`)), false)
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), [basename(source)])
  // Aborting the already-committed import is a no-op, never a deletion.
  assert.equal(await service.abort(importId), false)
  assert.equal(await readFile(join(first.absolutePath, 'a.bin'), 'utf8'), 'payload')
})

test('import: concurrent writes to the same offset append once and reject the loser', async () => {
  const { workspace } = await makeWorkspace()
  const service = new WorkspaceImportService(workspace)
  const importId = await service.begin({
    v: 1,
    sessionId: 'session-1',
    targetDirectory: workspace,
    entryName: 'concurrent',
    directories: [],
    files: [{ path: 'a.bin', size: 6 }],
    totalBytes: 6,
  })

  // Both calls start in the same synchronous section, so without a per-import
  // write queue both would pass `offset === received` and append `abc` twice.
  const first = service.write(importId, 'a.bin', 0, Buffer.from('abc').toString('base64'))
  const second = service.write(importId, 'a.bin', 0, Buffer.from('abc').toString('base64'))
  const outcomes = await Promise.allSettled([first, second])
  assert.deepEqual(outcomes.map(outcome => outcome.status), ['fulfilled', 'rejected'])
  assert.equal(outcomes[0].status === 'fulfilled' ? outcomes[0].value.received : -1, 3)
  assert.equal(outcomes[1].status === 'rejected' && isBadRequest(outcomes[1].reason), true)
  // The rejected offset produced no bytes and no extra append.
  assert.equal((await stat(join(workspace, '.imports', importId, 'a.bin'))).size, 3)

  await service.write(importId, 'a.bin', 3, Buffer.from('def').toString('base64'))
  const result = await service.commit(importId)
  assert.equal(await readFile(join(result.absolutePath, 'a.bin'), 'utf8'), 'abcdef')
  assert.equal((await stat(join(result.absolutePath, 'a.bin'))).size, 6)
})

test('import: a retry during post-commit cleanup returns the same real result', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const manifest = await collectManifest(source, workspace)
  const service = new WorkspaceImportService(workspace)
  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)

  // Deterministic IO barrier: hold the *real* private-staging cleanup after the
  // atomic rename. The final directory is already published and the active
  // mapping has been retired while cleanup still awaits `readdir`/`rm`.
  let releaseCleanup!: () => void
  let cleanupStarted!: () => void
  const started = new Promise<void>((resolve) => { cleanupStarted = resolve })
  const gate = new Promise<void>((resolve) => { releaseCleanup = resolve })
  const internals = service as unknown as {
    cleanupDotImports(record: unknown): Promise<void>
  }
  const realCleanup = internals.cleanupDotImports.bind(service)
  internals.cleanupDotImports = async (record: unknown) => {
    cleanupStarted()
    await gate
    await realCleanup(record)
  }

  const commitPromise = service.commit(importId)
  await started
  const retried = service.commit(importId)
  releaseCleanup()
  const [first, second] = await Promise.all([commitPromise, retried])

  assert.deepEqual(second, first)
  assert.equal(await readFile(join(first.absolutePath, 'a.bin'), 'utf8'), 'payload')
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), [basename(source)])
  // Cleanup finished and the cached result survives for a later retry.
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  assert.deepEqual(await service.commit(importId), first)
})

test('import: commit checks the staged file length, not only the counters', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const manifest = await collectManifest(source, workspace)
  let flushes = 0
  const service = new WorkspaceImportService(workspace, { flush: () => { flushes += 1 } })
  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)

  // The manifest/counter says 7 bytes, but the staged file is truncated behind
  // the service's back. Commit must not publish a short tree.
  await writeFile(join(workspace, '.imports', importId, 'a.bin'), Buffer.from('pay'))
  await assert.rejects(
    () => service.commit(importId),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'internal')
  assert.equal(await pathExists(join(workspace, 'imports')), false)
  assert.equal(await pathExists(join(workspace, '.imports')), false)
  assert.equal(flushes, 1, 'the rollback deletion is flushed')
})

test('import: a write arriving after the commit point of no return is refused', async () => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.bin'), Buffer.from('payload'))
  const manifest = await collectManifest(source, workspace)
  let releaseVerify!: () => void
  const verifyGate = new Promise<void>((resolve) => { releaseVerify = resolve })
  const service = new WorkspaceImportService(workspace, {
    verify: async () => { await verifyGate },
  })

  const importId = await service.begin(manifest)
  await upload(service, importId, source, manifest.files)
  const commitPromise = service.commit(importId)
  await assert.rejects(
    () => service.write(importId, 'a.bin', 7, Buffer.from('x').toString('base64')),
    isBadRequest)
  releaseVerify()
  const result = await commitPromise
  assert.equal(await readFile(join(result.absolutePath, 'a.bin'), 'utf8'), 'payload')
})

test('import: zero-byte files are real files, including nested empty ones', async () => {
  const { workspace, source } = await makeWorkspace()
  await mkdir(join(source, 'nested', 'empty-parent'), { recursive: true })
  await writeFile(join(source, 'readme.txt'), 'non-empty content')
  await writeFile(join(source, 'zero.txt'), Buffer.alloc(0))
  await writeFile(join(source, 'nested', 'empty-parent', 'nested-zero.bin'), Buffer.alloc(0))
  const before = await snapshot(source)
  const manifest = await collectManifest(source, workspace)
  assert.deepEqual(manifest.files.filter(file => file.size === 0).map(file => file.path).sort(),
    ['nested/empty-parent/nested-zero.bin', 'zero.txt'])
  let flushes = 0
  const service = new WorkspaceImportService(workspace, { flush: () => { flushes += 1 } })

  const importId = await service.begin(manifest)
  assert.equal((await stat(join(workspace, '.imports', importId, 'zero.txt'))).size, 0)
  assert.equal((await stat(join(workspace, '.imports', importId, 'nested', 'empty-parent', 'nested-zero.bin'))).size, 0)

  await upload(service, importId, source, manifest.files)
  const result = await service.commit(importId)

  assert.equal(result.fileCount, 3)
  assert.equal((await stat(join(result.absolutePath, 'zero.txt'))).isFile(), true)
  assert.equal((await readFile(join(result.absolutePath, 'zero.txt'))).length, 0)
  const nestedZero = join(result.absolutePath, 'nested', 'empty-parent', 'nested-zero.bin')
  assert.equal((await stat(nestedZero)).isFile(), true)
  assert.equal((await readFile(nestedZero)).length, 0)
  assert.deepEqual(await snapshot(result.absolutePath), before)
  assert.deepEqual(await snapshot(source), before)
  assert.equal(flushes, 1)
})

test('import: a manifest containing only a zero-byte file commits that file', async () => {
  const { workspace } = await makeWorkspace()
  const service = new WorkspaceImportService(workspace)
  const importId = await service.begin({
    v: 1,
    sessionId: 'session-1',
    targetDirectory: workspace,
    entryName: 'only-zero',
    directories: [],
    files: [{ path: 'zero.txt', size: 0 }],
    totalBytes: 0,
  })

  const result = await service.commit(importId)
  assert.equal(result.fileCount, 1)
  assert.equal(result.totalBytes, 0)
  assert.equal((await stat(join(result.absolutePath, 'zero.txt'))).isFile(), true)
  assert.equal((await readFile(join(result.absolutePath, 'zero.txt'))).length, 0)
})

test('import: targetDirectory must stay inside the session workspace root', async () => {
  const { workspace, root, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'a')
  const outside = join(root, 'outside')
  await mkdir(outside, { recursive: true })
  const manifest = await collectManifest(source, outside)
  const service = new WorkspaceImportService(workspace)
  await assert.rejects(() => service.begin(manifest), isBadRequest)
  assert.equal(await pathExists(join(outside, '.imports')), false)
})

test('import: unknown import ids are rejected instead of being guessed', async () => {
  const { workspace } = await makeWorkspace()
  const service = new WorkspaceImportService(workspace)
  await assert.rejects(
    () => service.commit('not-an-import'),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'not-found')
  await assert.rejects(
    () => service.abort('not-an-import'),
    (error: unknown) => error instanceof WorkspaceImportError && error.code === 'not-found')
})

// Remote-level retry/ownership tests: the real Remote over a real temp
// workspace, with a minimal Cordis context and the same node:fs VFS.

async function makeRemote(workspace: string,
  stat?: (path: string) => Promise<{ type: string }>): Promise<{
    remote: PhoneDirectoryImportRemote
    dispose: () => Promise<void>
  }> {
  const ctx = new Context()
  ctx.provide('sessions', {
    get: (id: string) => id === 'session-1' ? { header: { cwd: workspace } } : undefined,
  })
  ctx.provide('sandboxPolicy', { workspaceRoot: workspace })
  ctx.provide('fs', {
    resolve: async (path: string) => path,
    stat: stat ?? (async () => ({ type: 'directory' })),
  })
  ctx.provide('typert', {})
  const remote = new PhoneDirectoryImportRemote(ctx as never)
  return {
    remote,
    dispose: async () => { await ctx.fiber.dispose() },
  }
}

test('remote: a retried commit returns the same result instead of not-found', async (t) => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'payload')
  const manifest = await collectManifest(source, workspace)
  const { remote, dispose } = await makeRemote(workspace)
  t.after(dispose)

  const { importId } = await remote.importBegin(manifest)
  await remote.importWrite({
    v: 1,
    sessionId: 'session-1',
    importId,
    path: 'a.txt',
    offset: 0,
    dataBase64: Buffer.from('payload').toString('base64'),
  })
  const request = { v: 1, sessionId: 'session-1', importId } as const
  const first = await remote.importCommit(request)
  // The ordered channel can resend the same rpcID after a closed socket.
  const retried = await remote.importCommit(request)
  assert.deepEqual(retried, first)
  assert.equal(await readFile(join(first.absolutePath, 'a.txt'), 'utf8'), 'payload')
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), [basename(source)])

  // A late abort is a no-op, never a deletion of the delivered directory.
  assert.deepEqual(await remote.importAbort(request), { aborted: false })
  assert.equal(await readFile(join(first.absolutePath, 'a.txt'), 'utf8'), 'payload')

  // The retained result is owned by its session, not a global import id.
  await assert.rejects(
    () => remote.importCommit({ v: 1, sessionId: 'session-2', importId }),
    (error: unknown) => remoteErrorOf(error)?.code === 'session/not-found')
})

test('remote: a commit retried during cleanup keeps the route and the real result', async (t) => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'payload')
  const manifest = await collectManifest(source, workspace)
  const { remote, dispose } = await makeRemote(workspace)
  t.after(dispose)

  const { importId } = await remote.importBegin(manifest)
  await remote.importWrite({
    v: 1,
    sessionId: 'session-1',
    importId,
    path: 'a.txt',
    offset: 0,
    dataBase64: Buffer.from('payload').toString('base64'),
  })
  const service = (remote as unknown as {
    serviceFor(sessionId: string): WorkspaceImportService
  }).serviceFor('session-1')
  let releaseCleanup!: () => void
  let cleanupStarted!: () => void
  const started = new Promise<void>((resolve) => { cleanupStarted = resolve })
  const gate = new Promise<void>((resolve) => { releaseCleanup = resolve })
  const internals = service as unknown as {
    cleanupDotImports(record: unknown): Promise<void>
  }
  const realCleanup = internals.cleanupDotImports.bind(service)
  internals.cleanupDotImports = async (record: unknown) => {
    cleanupStarted()
    await gate
    await realCleanup(record)
  }

  const request = { v: 1, sessionId: 'session-1', importId } as const
  const commitPromise = remote.importCommit(request)
  await started
  // The final directory is published, the active mapping is gone, and cleanup
  // is still awaiting real I/O. The retry must not hit Remote's catch/delete.
  const retried = remote.importCommit(request)
  releaseCleanup()
  const [first, second] = await Promise.all([commitPromise, retried])
  assert.deepEqual(second, first)
  assert.deepEqual(await remote.importCommit(request), first)
  assert.equal(await readFile(join(first.absolutePath, 'a.txt'), 'utf8'), 'payload')
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), [basename(source)])
})

test('remote: an abort that races the commit route cannot delete the delivered tree', async (t) => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'payload')
  const manifest = await collectManifest(source, workspace)
  let releaseStat!: () => void
  let statStarted!: () => void
  const started = new Promise<void>((resolve) => { statStarted = resolve })
  const gate = new Promise<void>((resolve) => { releaseStat = resolve })
  const { remote, dispose } = await makeRemote(workspace, async () => {
    statStarted()
    await gate
    return { type: 'directory' }
  })
  t.after(dispose)

  const { importId } = await remote.importBegin(manifest)
  await remote.importWrite({
    v: 1,
    sessionId: 'session-1',
    importId,
    path: 'a.txt',
    offset: 0,
    dataBase64: Buffer.from('payload').toString('base64'),
  })
  const request = { v: 1, sessionId: 'session-1', importId } as const
  const commitPromise = remote.importCommit(request)
  await started
  const abortPromise = remote.importAbort(request)
  releaseStat()
  const result = await commitPromise
  assert.deepEqual(await abortPromise, { aborted: false })
  assert.equal(await readFile(join(result.absolutePath, 'a.txt'), 'utf8'), 'payload')
  assert.equal(await pathExists(join(workspace, 'imports', `${basename(source)}-2`)), false)
})


// The completed-result retry window must not depend on how many *other* imports
// are still open. Fill the active-route cap while one import is committing:
// when that import publishes, it retires its active slot and enters the
// separate completed cache, so the immediate lost-response retry must still
// replay the real success instead of reporting `not-found`.
test('remote: a just-completed import survives a full active-route table', async (t) => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'payload')
  const manifest = await collectManifest(source, workspace)
  let releaseStat!: () => void
  let statStarted!: () => void
  const started = new Promise<void>((resolve) => { statStarted = resolve })
  const gate = new Promise<void>((resolve) => { releaseStat = resolve })
  let held = false
  const { remote, dispose } = await makeRemote(workspace, async (path: string) => {
    if (!held && path.includes('long-running')) {
      held = true
      statStarted()
      await gate
    }
    return { type: 'directory' }
  })
  t.after(dispose)

  const { importId } = await remote.importBegin({ ...manifest, entryName: 'long-running' })
  await remote.importWrite({
    v: 1,
    sessionId: 'session-1',
    importId,
    path: 'a.txt',
    offset: 0,
    dataBase64: Buffer.from('payload').toString('base64'),
  })
  const request = { v: 1, sessionId: 'session-1', importId } as const

  // Hold the commit at its real verification I/O, then fill every other active
  // slot so the committing route is the oldest entry in the route table.
  const commitPromise = remote.importCommit(request)
  await started
  for (let index = 0; index < MAX_ACTIVE_IMPORT_ROUTES - 1; index += 1) {
    await remote.importBegin({ ...manifest, entryName: `filler-${index}` })
  }
  // The 513th live route is refused instead of being allowed to evict the
  // committing route during capacity cleanup.
  await assert.rejects(
    () => remote.importBegin({ ...manifest, entryName: 'one-too-many' }),
    (error: unknown) => {
      const failure = remoteErrorOf(error)
      return failure?.code === 'gateway/bad-request' && /busy/.test(failure.message)
    })
  releaseStat()
  const first = await commitPromise

  // The lost-response retry arrives immediately after success, while the route
  // table is still full of older active imports.
  assert.deepEqual(await remote.importCommit(request), first)
  assert.deepEqual(await remote.importAbort(request), { aborted: false })
  assert.equal(await readFile(join(first.absolutePath, 'a.txt'), 'utf8'), 'payload')
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), ['long-running'])

  // Session ownership still wins over a globally reused import id.
  await assert.rejects(
    () => remote.importCommit({ v: 1, sessionId: 'session-2', importId }),
    (error: unknown) => remoteErrorOf(error)?.code === 'session/not-found')

  // Retiring the completed route freed its active slot, so new work is accepted
  // again without deleting any of the still-open filler imports.
  const after = await remote.importBegin({ ...manifest, entryName: 'after-cap' })
  assert.deepEqual(await remote.importAbort({ v: 1, sessionId: 'session-1', importId: after.importId }),
    { aborted: true })
})

// Completed-result capacity is separate from active capacity. Fill the
// completed cache to its bound with older real successes, then let an older
// long-running transaction finish: the just-finished result must become the
// newest retained entry and remain replayable, while the genuinely oldest
// completed result is the one capacity cleanup drops.
test('remote: completed-result capacity keeps the just-finished import retryable', async (t) => {
  const { workspace, source } = await makeWorkspace()
  await writeFile(join(source, 'a.txt'), 'payload')
  const longManifest = await collectManifest(source, workspace)
  let releaseStat!: () => void
  let statStarted!: () => void
  const started = new Promise<void>((resolve) => { statStarted = resolve })
  const gate = new Promise<void>((resolve) => { releaseStat = resolve })
  let held = false
  const { remote, dispose } = await makeRemote(workspace, async (path: string) => {
    if (!held && path.includes('long-running')) {
      held = true
      statStarted()
      await gate
    }
    return { type: 'directory' }
  })
  t.after(dispose)

  const long = await remote.importBegin({ ...longManifest, entryName: 'long-running' })
  await remote.importWrite({
    v: 1,
    sessionId: 'session-1',
    importId: long.importId,
    path: 'a.txt',
    offset: 0,
    dataBase64: Buffer.from('payload').toString('base64'),
  })

  // Each pool import is a real empty directory: enough to fill the completed
  // cache without retaining file bytes or touching active imports.
  const poolResults = new Map<string, string>()
  for (let index = 0; index < MAX_COMPLETED_IMPORTS; index += 1) {
    const entryName = `pool-${index}`
    const begin = await remote.importBegin({
      v: 1,
      sessionId: 'session-1',
      targetDirectory: workspace,
      entryName,
      directories: [],
      files: [],
      totalBytes: 0,
    })
    const result = await remote.importCommit({ v: 1, sessionId: 'session-1', importId: begin.importId })
    poolResults.set(begin.importId, result.absolutePath)
  }

  const longRequest = { v: 1, sessionId: 'session-1', importId: long.importId } as const
  const commitPromise = remote.importCommit(longRequest)
  await started
  releaseStat()
  const first = await commitPromise

  // The commit just completed while the completed cache was full. Its result is
  // re-inserted as the newest entry and must survive both that prune and the
  // immediate retry.
  assert.deepEqual(await remote.importCommit(longRequest), first)
  assert.equal(await readFile(join(first.absolutePath, 'a.txt'), 'utf8'), 'payload')
  assert.deepEqual(await remote.importAbort(longRequest), { aborted: false })

  // The oldest completed result was evicted; the newest pool result remains.
  const oldest = poolResults.keys().next().value as string
  await assert.rejects(
    () => remote.importCommit({ v: 1, sessionId: 'session-1', importId: oldest }),
    (error: unknown) => remoteErrorOf(error)?.code === 'session/not-found')
  const newest = [...poolResults.keys()].at(-1) as string
  assert.deepEqual(
    await remote.importCommit({ v: 1, sessionId: 'session-1', importId: newest }),
    {
      workspacePath: `imports/pool-${MAX_COMPLETED_IMPORTS - 1}`,
      absolutePath: poolResults.get(newest),
      fileCount: 0,
      totalBytes: 0,
    })

  // Completed routes remain session-owned even under capacity pressure.
  await assert.rejects(
    () => remote.importCommit({ v: 1, sessionId: 'session-2', importId: long.importId }),
    (error: unknown) => remoteErrorOf(error)?.code === 'session/not-found')
  assert.deepEqual((await readdir(join(workspace, 'imports'))).sort(), [
    'long-running',
    ...Array.from({ length: MAX_COMPLETED_IMPORTS }, (_unused, index) => `pool-${index}`),
  ].sort())
})
