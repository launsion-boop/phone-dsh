// SPDX-License-Identifier: MIT
// G2-FIX-98: just-bash 3.6.0's cp parser rejects `-a`/`-d` and accepts `-p`
// without ever consuming it. The Worker shell shadows cp with an archive shim
// that keeps the bundled copy engine, normalises the archive options to the
// flags it understands, and restores the target mode through an explicit VFS
// chmod (op 4) instead of relying on `node:fs.cp` happening to copy it.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { setTimeout as settle } from 'node:timers/promises'
import { Bash } from 'just-bash/browser'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  FrameType,
  VfsOp,
  type Frame,
  type VfsMutation,
} from '../channel/src/index.ts'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  disciplineEnvironment,
  hasCpArchiveArguments,
  isWorkerShellProgram,
  parseCpArguments,
  type VfsFileSystemIo,
} from '../shell-ext/src/index.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { TreeVfs } from './tree-vfs.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker VFS over a temp directory backed by the real filesystem. */
function workspace(): { fs: VfsFileSystem; shell: WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-cp-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace/notes'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/notes/a.md'), 'alpha\n')
  const fs = new VfsFileSystem({ root })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, curl: false, toolbox: false }),
  })
  return { fs, shell }
}

/** Run one script through the unshadowed just-bash built-in. */
async function builtin(fs: VfsFileSystem, script: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const bash = new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
  return await bash.exec(script, { cwd: CWD })
}

test('regression G2-FIX-98 baseline: the unshadowed built-in cp rejects -a and -d', async () => {
  const { fs } = workspace()
  await builtin(fs, 'mkdir -p d; printf x > d/f')
  const archive = await builtin(fs, 'cp -a d c')
  assert.equal(archive.exitCode, 1, 'the pre-fix parser must reject -a')
  assert.equal(archive.stdout, '')
  assert.match(archive.stderr, /cp: invalid option -- 'a'/u)
  assert.equal(await fs.exists('/dsh/workspace/c'), false, 'a rejected option creates no target')

  const noDeref = await builtin(fs, 'cp -d d/f i')
  assert.equal(noDeref.exitCode, 1, 'the pre-fix parser must reject -d')
  assert.match(noDeref.stderr, /cp: invalid option -- 'd'/u)
  assert.equal(await fs.exists('/dsh/workspace/i'), false)
})

test('parseCpArguments: clusters, repeated preserve lists and the fail-loud attribute', () => {
  assert.equal(hasCpArchiveArguments(['cp', 'a', 'b']), false)
  assert.equal(hasCpArchiveArguments(['-R', 'a', 'b']), false)
  assert.equal(hasCpArchiveArguments(['-av', 'a', 'b']), true)
  const archive = parseCpArguments(['-av', 'd', 'c'])
  assert.equal(archive.archive, true)
  assert.equal(archive.recursive, true)
  assert.equal(archive.noDereference, true)
  assert.equal(archive.verbose, true)
  assert.deepEqual([...archive.preserve].sort(), ['links', 'mode', 'ownership', 'timestamps'])
  assert.deepEqual(archive.delegated, ['-R', '-p', '-v', 'd', 'c'])
  assert.deepEqual(archive.operands, ['d', 'c'])

  const cluster = parseCpArguments(['-aR', '--preserve=mode', '--preserve=timestamps', '--preserve', 's', 't'])
  assert.deepEqual([...cluster.preserve].sort(), ['links', 'mode', 'ownership', 'timestamps'])
  assert.deepEqual(cluster.delegated, ['-R', '-p', 's', 't'])

  assert.throws(
    () => parseCpArguments(['--preserve=mode,bogus', 's', 't']),
    /invalid argument 'bogus' for '--preserve'/u,
  )
})

test('cp -a preserves directory and file modes with explicit chmod', async () => {
  const { fs, shell } = workspace()
  const result = await shell.run(['bash', '-c', [
    'mkdir -p d',
    'chmod 700 d',
    'printf x > d/f',
    'chmod 600 d/f',
    'cp -a d c',
    'stat -c "%a" c c/f',
  ].join('; ')], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, '700\n600\n')
  assert.equal(await fs.readFile('/dsh/workspace/c/f'), 'x')
  assert.equal((await fs.stat('/dsh/workspace/c')).mode & 0o777, 0o700)
  assert.equal((await fs.stat('/dsh/workspace/c/f')).mode & 0o777, 0o600)
})

test('cp -av stays verbose and preserves modes; -p and --preserve=mode preserve the file mode', async () => {
  const { fs, shell } = workspace()
  const verbose = await shell.run(['bash', '-c', [
    'mkdir -p d',
    'chmod 700 d',
    'printf x > d/f',
    'chmod 600 d/f',
    'cp -av d c2',
  ].join('; ')], { cwd: CWD })
  assert.equal(verbose.exitCode, 0, verbose.stderr)
  assert.match(verbose.stdout, /'d' -> /u)
  assert.equal((await fs.stat('/dsh/workspace/c2')).mode & 0o777, 0o700)
  assert.equal((await fs.stat('/dsh/workspace/c2/f')).mode & 0o777, 0o600)

  const modes = await shell.run(['bash', '-c', [
    'printf x > f',
    'chmod 640 f',
    'cp -p f g',
    'cp --preserve=mode f h',
    'stat -c "%a" g h',
  ].join('; ')], { cwd: CWD })
  assert.equal(modes.exitCode, 0, modes.stderr)
  assert.equal(modes.stdout, '640\n640\n')
})

test('cp --preserve=timestamps restores the source mtime on a temporary-directory backend', async () => {
  const { fs, shell } = workspace()
  await fs.writeFile('/dsh/workspace/f', 'x')
  const stamp = new Date(1_600_000_000_000)
  await fs.utimes('/dsh/workspace/f', stamp, stamp)
  const result = await shell.run(['bash', '-c', 'cp --preserve=timestamps f t'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  const copied = await fs.stat('/dsh/workspace/t')
  assert.equal(Math.floor(copied.mtime.getTime() / 1000), 1_600_000_000)
})

test('cp -d is accepted on the symlink-free VFS and an invalid preserve attribute creates nothing', async () => {
  const { fs, shell } = workspace()
  const direct = await shell.run(['bash', '-c', 'printf y > i0; cp -d i0 i'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(await fs.readFile('/dsh/workspace/i'), 'y')

  const invalid = await shell.run(['bash', '-c', 'printf x > f; cp --preserve=bogus f bad'], { cwd: CWD })
  assert.notEqual(invalid.exitCode, 0)
  assert.match(invalid.stderr, /^cp: invalid argument 'bogus' for '--preserve'/mu)
  assert.equal(await fs.exists('/dsh/workspace/bad'), false, 'a bad preserve list creates no target')
})

test('cp without archive options keeps the bundled behavior and output bytes', async () => {
  const { fs, shell } = workspace()
  const result = await shell.run(['bash', '-c', 'cp notes/a.md copy.md'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
  assert.equal(await fs.readFile('/dsh/workspace/copy.md'), 'alpha\n')

  const quiet = await shell.run(['bash', '-c', 'cp -R notes notes-copy && cp -n notes/a.md notes-copy/a.md'], { cwd: CWD })
  assert.equal(quiet.exitCode, 0, quiet.stderr)
  assert.equal(await fs.readFile('/dsh/workspace/notes-copy/a.md'), 'alpha\n')
})

test('cp: a direct spawn reaches the same shim as bash -c', async () => {
  const { fs, shell } = workspace()
  assert.equal(isWorkerShellProgram('cp'), true, 'a direct spawn must route to the Worker shell table')
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  assert.ok(commands.some(command => command.name === 'cp'), 'createWorkerCommands must carry cp')

  const setup = await shell.run(['bash', '-c', [
    'mkdir -p d',
    'chmod 700 d',
    'printf x > d/f',
    'chmod 600 d/f',
  ].join('; ')], { cwd: CWD })
  assert.equal(setup.exitCode, 0, setup.stderr)

  const direct = await shell.run(['cp', '-av', 'd', 'direct'], { cwd: CWD })
  const scripted = await shell.run(['bash', '-c', 'cp -av d scripted'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(scripted.exitCode, 0, scripted.stderr)
  assert.match(direct.stdout, /'d' -> /u)
  assert.match(scripted.stdout, /'d' -> /u)
  for (const target of ['direct', 'scripted']) {
    assert.equal((await fs.stat(`/dsh/workspace/${target}`)).mode & 0o777, 0o700)
    assert.equal((await fs.stat(`/dsh/workspace/${target}/f`)).mode & 0o777, 0o600)
  }
})

interface TreeFixture {
  readonly tree: TreeVfs
  readonly shell: WorkerShell
  readonly frames: Frame[]
  dispose(): void
}

/** The production table over the in-memory TreeVfs (what the sink sees). */
function treeFixture(): TreeFixture {
  const tree = new TreeVfs()
  for (const root of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) tree.mkdirSync(root, { recursive: true })
  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => { frames.push(frame) })
  const dispose = installSink(tree, pair.worker)
  const fs = new VfsFileSystem({
    root: '',
    workerPaths: false,
    nodeFs: tree.promises as unknown as VfsFileSystemIo,
  })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, curl: false, toolbox: false }),
  })
  return { tree, shell, frames, dispose }
}

/** VFS_MUT bodies the sink has published by now. */
async function sinkMutations(frames: readonly Frame[]): Promise<VfsMutation[]> {
  await settle(0)
  return frames
    .filter(frame => frame.type === FrameType.VFS_MUT)
    .map(frame => decodeVfsMutation(frame.payload))
}

test('cp -a publishes an explicit chmod (VFS op 4) for the copied target', async () => {
  const { tree, shell, frames, dispose } = treeFixture()
  try {
    const result = await shell.run(['bash', '-c', 'printf x > f; chmod 600 f; cp -a f g'], { cwd: CWD })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(tree.statSync('/dsh/workspace/g').mode & 0o777, 0o600)
    const published = tree.published.filter(mutation => mutation.path === '/dsh/workspace/g')
    assert.ok(
      published.some(mutation => mutation.kind === 'chmod' && mutation.mode === 0o600),
      `expected an explicit chmod mutation (got ${JSON.stringify(published.map(m => [m.kind, 'mode' in m ? m.mode : undefined]))})`,
    )
    const chmod = (await sinkMutations(frames)).find(
      mutation => mutation.path === '/dsh/workspace/g' && mutation.op === VfsOp.CHMOD,
    )
    assert.ok(chmod, 'the sink must see VFS op 4 for the preserved mode')
    assert.equal(chmod.mode, 0o600)
  } finally {
    dispose()
  }
})
