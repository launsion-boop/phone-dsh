// SPDX-License-Identifier: MIT
// G2-FIX-25: `command -v python3` answered `/usr/bin/python3` while `/usr/bin`
// did not exist in the VFS, so the model chased a path that could not run.
// The shell now materialises its command table as virtual PATH entries: every
// path `command -v` reports exists, is executable, and runs the same command.
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  WORKER_BIN_COMMANDS,
  VfsFileSystem,
  WorkerShell,
  commandEntryContent,
  commandPathsReady,
  createWorkerCommands,
  findCommandPath,
  materializeCommandPaths,
  sanitizeCommandPath,
} from '../shell-ext/src/index.ts'
import { workerShellIdentity } from '../shell-ext/src/commands.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker shell over a fresh temporary VFS. */
async function fixture(): Promise<{ fs: VfsFileSystem; shell: WorkerShell; root: string }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-command-v-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace/notes', { recursive: true })
  await fs.writeFile('/dsh/workspace/notes/a.md', 'alpha\n')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell, root }
}

test('command -v: every reported path exists and is executable', async () => {
  const { fs, shell } = await fixture()
  for (const name of ['tar', 'realpath', 'readlink', 'awk', 'find', 'stat', 'gzip', 'ls', 'bash']) {
    const result = await shell.run(['bash', '-c', `command -v ${name}`], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${name}: ${result.stderr}`)
    const path = result.stdout.trim()
    assert.match(path, /^\/(?:usr\/)?bin\//u, `${name}: ${path}`)
    assert.equal(await fs.exists(path), true, path)
    const stat = await fs.stat(path)
    assert.equal(stat.isFile, true, path)
    assert.equal(stat.mode & 0o111, 0o111, `${path} is executable`)
  }
})

test('command -v: an unknown command has no output and exit 1', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'command -v pdsh-definitely-not-a-command'], { cwd: CWD })
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, '')
})

test('command -v: PATH advertises only directories that exist', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'printf \'%s\\n\' "$PATH"'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  const dirs = result.stdout.trim().split(':')
  assert.ok(dirs.length >= 2)
  for (const dir of dirs) {
    assert.equal(await fs.exists(dir), true, dir)
    assert.equal((await fs.stat(dir)).isDirectory, true, dir)
  }
})

test('command -v: an inherited PATH entry outside the VFS is dropped', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'printf \'%s\\n\' "$PATH"'], {
    cwd: CWD,
    env: { PATH: '/usr/local/bin:/usr/bin:/bin' },
  })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout.trim(), '/usr/bin:/bin')
})

test('command -v: type and which agree with the path and with existence', async () => {
  const { shell } = await fixture()
  const type = await shell.run(['bash', '-c', 'type tar'], { cwd: CWD })
  assert.equal(type.exitCode, 0, type.stderr)
  assert.equal(type.stdout, 'tar is /usr/bin/tar\n')

  const which = await shell.run(['bash', '-c', 'which tar'], { cwd: CWD })
  assert.equal(which.exitCode, 0, which.stderr)
  assert.equal(which.stdout, '/usr/bin/tar\n')

  const missing = await shell.run(['bash', '-c', 'which pdsh-definitely-not-a-command'], { cwd: CWD })
  assert.equal(missing.exitCode, 1)
  assert.equal(missing.stdout, '')
  assert.match(missing.stderr, /which: no pdsh-definitely-not-a-command in \(\/usr\/bin:\/bin\)/u)
})

test('command -v: the returned path executes the same registered command', async () => {
  const { shell } = await fixture()
  const script = 'tar_path=$(command -v tar); "$tar_path" -czf notes.tar.gz notes && tar -tzf notes.tar.gz'
  const result = await shell.run(['bash', '-c', script], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'notes/\nnotes/a.md\n')
})

test('command paths: virtual entries never create files below the real root', async () => {
  const { fs, shell, root } = await fixture()
  assert.equal(commandPathsReady(fs), false)
  await shell.run(['bash', '-c', 'command -v tar'], { cwd: CWD })
  assert.equal(commandPathsReady(fs), true)
  assert.equal(existsSync(join(root, 'usr')), false)
  assert.equal(existsSync(join(root, 'bin')), false)
  assert.equal(fs.getAllPaths().some(path => path.startsWith('/usr') || path.startsWith('/bin')), false)
  // Reading a virtual entry is still possible and shows the wrapper just-bash
  // itself writes for a registered command.
  assert.equal(await fs.readFile('/usr/bin/tar'), commandEntryContent('tar'))
  assert.deepEqual((await fs.readdir('/bin')).sort(), [...WORKER_BIN_COMMANDS].sort())
  assert.deepEqual((await fs.readdirWithFileTypes('/usr/bin')).length, (await fs.readdir('/usr/bin')).length)
})

test('command paths: a browser-excluded name never gets a fake executable', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'command -v python3'], { cwd: CWD })
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, '')
  assert.equal(await fs.exists('/usr/bin/python3'), false)
  assert.equal(await fs.exists('/usr/bin/tar'), true)
  const bare = await shell.run(['bash', '-c', 'python3 --version'], { cwd: CWD })
  assert.equal(bare.exitCode, 127)
})

test('command paths: a backend without the virtual API materialises entries on disk', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-command-paths-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  // Hide both the virtual table and the synchronous registration hook so the
  // adapter is driven through the explicit write fallback.
  const plain = Object.create(fs) as VfsFileSystem
  Object.defineProperty(plain, 'registerCommandNames', { value: undefined })
  Object.defineProperty(plain, 'writeFileSync', { value: undefined })
  await fs.mkdir('/dsh/workspace', { recursive: true })
  assert.equal(await materializeCommandPaths(plain, ['alpha', 'beta', 'bad/name']), true)
  assert.equal(await fs.readFile('/usr/bin/alpha'), commandEntryContent('alpha'))
  assert.equal(await fs.readFile('/bin/sh'), commandEntryContent('sh'))
  assert.equal((await fs.stat('/usr/bin/alpha')).mode & 0o111, 0o111)
})

test('PATH helpers: sanitize and lookup reject what the VFS does not have', async () => {
  const { fs } = await fixture()
  await materializeCommandPaths(fs, [])
  fs.writeFileSync('/usr/bin/tar', commandEntryContent('tar'))
  assert.equal(await sanitizeCommandPath(fs, '/nowhere:/usr/bin'), '/usr/bin')
  assert.equal(await sanitizeCommandPath(fs, '/nowhere'), '/usr/bin:/bin')
  assert.equal(await findCommandPath(fs, 'tar', '/usr/bin:/bin'), '/usr/bin/tar')
  assert.equal(await findCommandPath(fs, 'nope', '/usr/bin:/bin'), undefined)
})

test('program identity: a materialised path routes back to the bare Worker program', () => {
  assert.equal(workerShellIdentity('/usr/bin/tar'), 'tar')
  assert.equal(workerShellIdentity('/bin/sh'), 'sh')
  assert.equal(workerShellIdentity('/opt/none/bin/tar'), 'tar')
  assert.equal(workerShellIdentity('/opt/none/bin/not-a-worker-program'), '/opt/none/bin/not-a-worker-program')
  assert.equal(workerShellIdentity('tar'), 'tar')
})
