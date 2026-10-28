// SPDX-License-Identifier: MIT
// G2-FIX-75: just-bash 3.6.0's `ls -l` hardcodes the first column
// (`-rw-r--r--` for files, `drwxr-xr-x` for directories and `.`/`..`) instead
// of reading the VFS mode. `chmod 600 f` therefore makes `stat -c '%A' f`
// report `-rw-------` while `ls -l f` still reports `-rw-r--r--`. The Worker
// shell shadows long-format `ls` with one that reads the same `FsStat` as
// `stat` and reuses `formatSymbolicMode`; every non-long invocation stays the
// unmodified built-in.
//
// G2-FIX-71/G2-FIX-99 (chmod masks and the mode written by `chmod u+x`) are
// NO_ACTION on this baseline: just-bash 3.6.0's chmod already reads the
// current mode and applies `u/g/o/a` against it. The last test below pins that
// behaviour through the real `VfsFileSystem` -> runtime VFS `node:fs` seam.
import assert from 'node:assert/strict'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Bash } from 'just-bash/browser'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  isWorkerShellProgram,
  type VfsFileSystemIo,
} from '../shell-ext/src/index.ts'
import { TreeVfs } from './tree-vfs.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

interface Fixture {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/**
 * A Worker VFS over a temp directory. `workspaceMode` and `parentMode` make the
 * `.`/`..` rows of `ls -la` distinguishable from just-bash's hardcoded 755.
 */
function workspace(workspaceMode = 0o755, parentMode = 0o755): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-ls-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace/sub'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/f'), 'x')
  chmodSync(join(root, 'dsh/workspace/f'), 0o644)
  writeFileSync(join(root, 'dsh/workspace/notes.txt'), 'hello\n')
  writeFileSync(join(root, 'dsh/workspace/exe'), '#!/bin/sh\n')
  chmodSync(join(root, 'dsh/workspace/exe'), 0o755)
  writeFileSync(join(root, 'dsh/workspace/sub/a'), 'a\n')
  chmodSync(join(root, 'dsh/workspace/sub'), 0o700)
  chmodSync(join(root, 'dsh/workspace'), workspaceMode)
  chmodSync(join(root, 'dsh'), parentMode)
  const fs = new VfsFileSystem({ root })
  return { root, fs, shell: new WorkerShell({ fs }) }
}

/** Run a script through the unshadowed just-bash built-in. */
async function builtin(
  fs: VfsFileSystem,
  script: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const bash = new Bash({ fs, cwd: CWD })
  return await bash.exec(script, { cwd: CWD })
}

/** Replace the first column so the non-mode columns can be compared. */
function withoutMode(stdout: string): string {
  return stdout
    .split('\n')
    .map(line => line.replace(/^[-dlcbps?][rwxstST-]{9}(?= )/u, '<mode>'))
    .join('\n')
}

test('G2-FIX-75 baseline: the unshadowed built-in hardcodes `ls -l` file and directory modes', async () => {
  const { fs } = workspace()
  const file = await builtin(fs, "chmod 600 f; ls -l f | awk '{print $1}'")
  assert.equal(file.exitCode, 0, file.stderr)
  assert.equal(file.stdout, '-rw-r--r--\n', 'the defect: the VFS says 600, the built-in prints 644')

  const directory = await builtin(fs, "ls -ld sub | awk '{print $1}'")
  assert.equal(directory.exitCode, 0, directory.stderr)
  assert.equal(directory.stdout, 'drwxr-xr-x\n', 'the defect: the VFS says 700, the built-in prints 755')
})

test('G2-FIX-75: stat and ls -l report the same mode in the same command', async () => {
  const { shell } = workspace()
  const result = await shell.run(
    ['bash', '-c', "chmod 600 f && stat -c '%A' f && stat -c '%a' f && ls -l f | awk '{print $1}'"],
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, '-rw-------\n600\n-rw-------\n')
})

test('G2-FIX-75: an executable file, a 700 directory and the . / .. rows use the VFS mode', async () => {
  const { shell } = workspace(0o700, 0o750)
  const executable = await shell.run(['bash', '-c', "ls -l exe | awk '{print $1}'"], { cwd: CWD })
  assert.equal(executable.exitCode, 0, executable.stderr)
  assert.equal(executable.stdout, '-rwxr-xr-x\n')

  const directory = await shell.run(['bash', '-c', "ls -ld sub | awk '{print $1}'"], { cwd: CWD })
  assert.equal(directory.exitCode, 0, directory.stderr)
  assert.equal(directory.stdout, 'drwx------\n')

  const all = await shell.run(['bash', '-c', 'ls -la'], { cwd: CWD })
  assert.equal(all.exitCode, 0, all.stderr)
  const lines = all.stdout.split('\n')
  assert.match(lines[0] as string, /^total \d+$/u)
  const dot = lines.find(line => line.endsWith(' .'))
  const dotdot = lines.find(line => line.endsWith(' ..'))
  assert.ok(dot, all.stdout)
  assert.ok(dotdot, all.stdout)
  assert.match(dot, /^drwx------ 1 user user /u)
  assert.match(dotdot, /^drwxr-x--- 1 user user /u)
  assert.match(lines.find(line => line.endsWith(' sub')) as string, /^drwx------ 1 user user /u)
})

test('G2-FIX-75: long-format option combinations keep the built-in columns beyond the mode', async () => {
  const { fs, shell } = workspace()
  for (const script of [
    'ls -l',
    'ls -l f notes.txt',
    'ls -lh f',
    'ls -lS',
    'ls -lt',
    'ls -lr',
    'ls -lA',
    'ls -ld sub',
    'ls -lF f exe sub',
    'ls -l1 f',
    'ls -lR',
    'ls -l -- f',
  ]) {
    const expected = await builtin(fs, script)
    const actual = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stderr, expected.stderr, script)
    assert.equal(withoutMode(actual.stdout), withoutMode(expected.stdout), script)
  }
})

test('G2-FIX-75: -a with -r keeps the dot rows first, reversing dot and ordinary rows separately', async () => {
  const { root, fs, shell } = workspace()
  writeFileSync(join(root, 'dsh/workspace/.hidden'), 'h\n')
  for (const script of ['ls -lar', 'ls -l --all --reverse', 'ls -lRa']) {
    const expected = await builtin(fs, `${script} | awk '{print $NF}'`)
    const actual = await shell.run(['bash', '-c', `${script} | awk '{print $NF}'`], { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stderr, expected.stderr, script)
    assert.equal(actual.stdout, expected.stdout, script)
  }
  const order = await shell.run(['bash', '-c', "ls -lar | awk '{print $NF}'"], { cwd: CWD })
  assert.equal(order.exitCode, 0, order.stderr)
  assert.deepEqual(order.stdout.trimEnd().split('\n').slice(1), ['..', '.', 'sub', 'notes.txt', 'f', 'exe', '.hidden'])
})

test('G2-FIX-75: non-long `ls` output is byte-identical to the unshadowed built-in', async () => {
  const { fs, shell } = workspace()
  for (const script of ['ls notes.txt', 'ls sub', 'ls -a', 'ls -A', 'ls -F', 'ls --help']) {
    const expected = await builtin(fs, script)
    const actual = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
  }
})

test('G2-FIX-75: a missing operand keeps the built-in stderr and exit 2', async () => {
  const { fs, shell } = workspace()
  for (const script of ['ls missing', 'ls -l missing']) {
    const expected = await builtin(fs, script)
    const actual = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
    assert.equal(actual.exitCode, 2, script)
  }
})

test('G2-FIX-75: the production table routes ls and direct spawn matches bash -c', async () => {
  const { fs } = workspace()
  assert.equal(isWorkerShellProgram('ls'), true, 'a direct spawn must reach the Worker shell table')
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  assert.ok(commands.some(command => command.name === 'ls'), 'createWorkerCommands must carry ls')
  const shell = new WorkerShell({ fs, commands })
  const which = await shell.run(['which', 'ls'], { cwd: CWD })
  assert.equal(which.exitCode, 0, which.stderr)
  assert.equal(which.stdout, '/usr/bin/ls\n')
  const direct = await shell.run(['ls', '-l', 'f'], { cwd: CWD })
  const script = await shell.run(['bash', '-c', 'ls -l f'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(script.exitCode, 0, script.stderr)
  assert.equal(direct.stdout, script.stdout)
  assert.equal(direct.stdout.split(' ')[0], '-rw-r--r--')
})

/** A VFS over the runtime-shaped in-memory tree (`chmod` publishes a mutation). */
function noActionFixture(): { tree: TreeVfs; fs: VfsFileSystem; shell: WorkerShell } {
  const tree = new TreeVfs()
  for (const root of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) tree.mkdirSync(root, { recursive: true })
  tree.writeFileSync('/dsh/workspace/f', Buffer.from('x'), { mode: 0o644 })
  const fs = new VfsFileSystem({
    root: '',
    nodeFs: tree.promises as unknown as VfsFileSystemIo,
  })
  const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false, toolbox: false }) })
  return { tree, fs, shell }
}

test('G2-FIX-71/99 NO_ACTION: chmod 600 publishes op4 with the requested mode and stat agrees', async () => {
  const { tree, fs, shell } = noActionFixture()
  const result = await shell.run(['bash', '-c', "chmod 600 f && stat -c '%a %A' f"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '600 -rw-------\n')
  const published = tree.published.filter(mutation => mutation.kind === 'chmod')
  assert.deepEqual(published.map(mutation => ({ path: mutation.path, mode: mutation.mode })), [
    { path: '/dsh/workspace/f', mode: 0o600 },
  ])
  assert.equal((await fs.stat('/dsh/workspace/f')).mode & 0o7777, 0o600)
})

test('G2-FIX-71/99 NO_ACTION: chmod u+x applies the mask to the current 644 mode (744, not 711)', async () => {
  const { tree, fs, shell } = noActionFixture()
  const result = await shell.run(['bash', '-c', "chmod u+x f && stat -c '%a %A' f"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '744 -rwxr--r--\n')
  const chmods = tree.published.filter(mutation => mutation.kind === 'chmod')
  assert.deepEqual(chmods.map(mutation => mutation.mode), [0o744])
  assert.equal((await fs.stat('/dsh/workspace/f')).mode & 0o7777, 0o744)
})
