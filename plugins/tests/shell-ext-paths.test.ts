// SPDX-License-Identifier: MIT
// G2-FIX-25: `realpath` was absent (exit 127) and just-bash's `readlink`
// rejected `-m`. These tests cover the GNU canonicalisation modes and the
// symlink resolution the Worker VFS itself cannot exercise.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { InMemoryFs } from 'just-bash/browser'
import {
  CanonicalizeError,
  VfsFileSystem,
  WorkerShell,
  canonicalizePath,
  createWorkerCommands,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker shell over a temporary real-directory VFS. */
async function realFixture(): Promise<{ fs: VfsFileSystem; shell: WorkerShell }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-paths-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace/notes', { recursive: true })
  await fs.writeFile('/dsh/workspace/notes/a.md', 'a\n')
  await fs.writeFile('/dsh/workspace/t.txt', 't\n')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell }
}

/** A symlink-capable in-memory VFS for the readlink/realpath symlink forms. */
async function linkFixture(): Promise<{ fs: InMemoryFs; shell: WorkerShell }> {
  const fs = new InMemoryFs({
    '/dsh/workspace/t.txt': 't\n',
    '/dsh/workspace/dir/a.md': 'a\n',
  })
  await fs.symlink('/dsh/workspace/t.txt', '/dsh/workspace/link.txt')
  await fs.symlink('../t.txt', '/dsh/workspace/dir/up.txt')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell }
}

test('realpath: default mode canonicalises a missing final component', async () => {
  const { fs } = await realFixture()
  assert.equal(await canonicalizePath(fs, CWD, 'notes/../t.txt', 'all-but-last'), '/dsh/workspace/t.txt')
  assert.equal(await canonicalizePath(fs, CWD, 'missing.txt', 'all-but-last'), '/dsh/workspace/missing.txt')
})

test('realpath: -e requires the whole path and -m allows every component', async () => {
  const { fs } = await realFixture()
  await assert.rejects(canonicalizePath(fs, CWD, 'missing.txt', 'existing'), (error: unknown) => error instanceof CanonicalizeError && error.code === 'ENOENT')
  assert.equal(await canonicalizePath(fs, CWD, 'missing/deep/file.txt', 'missing'), '/dsh/workspace/missing/deep/file.txt')
})

test('realpath: the command prints absolute paths and reports failures per operand', async () => {
  const { shell } = await realFixture()
  const ok = await shell.run(['bash', '-c', 'realpath notes/../t.txt missing.txt'], { cwd: CWD })
  assert.equal(ok.exitCode, 0, ok.stderr)
  assert.equal(ok.stdout, '/dsh/workspace/t.txt\n/dsh/workspace/missing.txt\n')

  const failed = await shell.run(['bash', '-c', 'realpath -e missing.txt'], { cwd: CWD })
  assert.equal(failed.exitCode, 1)
  assert.equal(failed.stdout, '')
  assert.match(failed.stderr, /realpath: missing\.txt: No such file or directory/u)

  const relative = await shell.run(['bash', '-c', 'realpath --relative-to=/dsh notes/a.md'], { cwd: CWD })
  assert.equal(relative.exitCode, 0, relative.stderr)
  assert.equal(relative.stdout, 'workspace/notes/a.md\n')
})

test('readlink: -f/-e/-m accept the canonicalisation modes', async () => {
  const { shell } = await realFixture()
  const resolved = await shell.run(['bash', '-c', 'readlink -f notes/a.md'], { cwd: CWD })
  assert.equal(resolved.exitCode, 0, resolved.stderr)
  assert.equal(resolved.stdout, '/dsh/workspace/notes/a.md\n')

  const missing = await shell.run(['bash', '-c', 'readlink -m notes/missing/../a.md'], { cwd: CWD })
  assert.equal(missing.exitCode, 0, missing.stderr)
  assert.equal(missing.stdout, '/dsh/workspace/notes/a.md\n')

  const existing = await shell.run(['bash', '-c', 'readlink -e absent.txt'], { cwd: CWD })
  assert.equal(existing.exitCode, 1)
  assert.match(existing.stderr, /readlink: absent\.txt: No such file or directory/u)
})

test('readlink: a symlink prints its target and a regular file fails with a contract trailer', async () => {
  const { shell } = await linkFixture()
  const link = await shell.run(['bash', '-c', 'readlink link.txt'], { cwd: CWD })
  assert.equal(link.exitCode, 0, link.stderr)
  assert.equal(link.stdout, '/dsh/workspace/t.txt\n')

  const regular = await shell.run(['bash', '-c', 'readlink t.txt'], { cwd: CWD })
  assert.equal(regular.exitCode, 1)
  assert.equal(regular.stdout, '')
  assert.match(regular.stderr, /^pdsh-shell: exit=1 program=readlink reason=command-exited$/mu)
})

test('realpath/readlink resolve symlinks through the backend', async () => {
  const { fs, shell } = await linkFixture()
  assert.equal(await canonicalizePath(fs, CWD, 'link.txt', 'existing'), '/dsh/workspace/t.txt')
  assert.equal(await canonicalizePath(fs, CWD, 'dir/up.txt', 'existing'), '/dsh/workspace/t.txt')
  const result = await shell.run(['bash', '-c', 'realpath -e dir/up.txt'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '/dsh/workspace/t.txt\n')
})
