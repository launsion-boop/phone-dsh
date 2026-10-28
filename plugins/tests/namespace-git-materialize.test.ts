// SPDX-License-Identifier: MIT
// G2-FIX regression: a Worker git commit is a DSH VFS write like any other.
//
// G2-B07 exposed a materialized workspace without `.git`: the Worker's git
// program wrote its object database, refs, index and config through a path
// that never reached the sink, so a restart (or the evidence archive) lost the
// repository even though the work tree was there. After the VfsNamespace fix
// every git write goes through the same VFS as the shell: `/dsh/workspace/.git`
// is sink-eligible (D4 allows a `.git` component), lands in the WAL, appears in
// the materialized copy and therefore in the overlay archive.
//
// This test drives the real git program over an in-memory Worker VFS, captures
// the sink frames, replays them into a materialized tree, packs the overlay
// with `scripts/pack-overlay.mjs` and reads the archive back.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix } from 'node:path'
import { after, test } from 'node:test'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  FrameType,
  type Frame,
} from '../channel/src/index.ts'
import { WORKER_VFS_NAMESPACE, createNamespaceVfs } from '../wasi-toolbox/src/index.ts'
import { NodeGitFs, runGit } from '../wasi-toolbox/git/index.ts'
import { readTarArchive } from '../shell-ext/src/tar.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
// The build tool is plain JavaScript and ships no declarations; it is the
// production overlay packer, so the test imports the implementation itself.
// @ts-expect-error -- untyped ESM build script
import { packOverlay } from '../scripts/pack-overlay.mjs'
import { TreeVfs } from './tree-vfs.ts'

const scratch: string[] = []

after(() => {
  for (const path of scratch) rmSync(path, { recursive: true, force: true })
})

/** Run git and assert success. */
async function git(args: readonly string[], fs: NodeGitFs, env: Record<string, string> = {}): Promise<string> {
  const result = await runGit(args, { fs, cwd: '/dsh/workspace', env })
  assert.equal(result.exitCode, 0, `${args.join(' ')}: ${new TextDecoder().decode(result.stderr)}`)
  return new TextDecoder().decode(result.stdout)
}

/** Walk every file below one TreeVfs directory. */
function filesUnder(vfs: TreeVfs, directory: string, prefix = ''): string[] {
  const entries = vfs.readdirSync(directory)
  const files: string[] = []
  for (const entry of entries) {
    const path = `${directory === '/' ? '' : directory}/${entry.name}`
    const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`
    if (entry.isDirectory()) files.push(...filesUnder(vfs, path, relative))
    else files.push(relative)
  }
  return files
}

test('git: commit writes .git through the VFS sink, into the materialized copy and the archive', async () => {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => { frames.push(frame) })
  const dispose = installSink(base, pair.worker)
  const gitFs = new NodeGitFs('', {
    fsPromises: base.promises as unknown as typeof import('node:fs').promises,
    namespace: WORKER_VFS_NAMESPACE,
  })
  const env = {
    GIT_AUTHOR_NAME: 'phone dev',
    GIT_AUTHOR_EMAIL: 'dev@example.invalid',
    GIT_COMMITTER_NAME: 'phone dev',
    GIT_COMMITTER_EMAIL: 'dev@example.invalid',
  }
  try {
    await git(['init'], gitFs)
    await gitFs.writeFile('/dsh/workspace/recipes.py', new TextEncoder().encode('print("hi")\n'))
    await git(['add', '--all'], gitFs, env)
    await git(['commit', '-m', 'add recipes'], gitFs, env)
    assert.match(await git(['log', '--oneline'], gitFs), /add recipes/)

    await new Promise<void>(resolve => setTimeout(resolve, 0))
    const mutations = frames
      .filter(frame => frame.type === FrameType.VFS_MUT)
      .map(frame => decodeVfsMutation(frame.payload))
    const paths = mutations.map(mutation => mutation.path)
    assert.ok(paths.some(path => path === '/dsh/workspace/.git/HEAD'), 'the sink carries .git/HEAD')
    assert.ok(paths.some(path => path.startsWith('/dsh/workspace/.git/objects/')), 'the sink carries the object database')
    assert.ok(paths.some(path => path === '/dsh/workspace/.git/index'), 'the sink carries the index')
    assert.ok(paths.every(path => WORKER_VFS_NAMESPACE.sinkEligible(path)), 'every git mutation is sink-eligible')
    assert.ok(paths.every(path => !path.startsWith('/tmp') && !path.startsWith('/dsh/tmp')), 'git staged nothing in the volatile root')
  } finally {
    dispose()
  }

  // The host materializes exactly the sink stream; replay it into the
  // materialized copy the overlay packer consumes.
  const materialized = createNamespaceVfs(TreeVfs.replay(base.published), WORKER_VFS_NAMESPACE)
  assert.equal((materialized.readFileSync('/dsh/workspace/.git/HEAD') as Uint8Array).byteLength > 0, true)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-git-materialize-'))
  scratch.push(root)
  mkdirSync(join(root, 'workspace'), { recursive: true })
  mkdirSync(join(root, 'home'), { recursive: true })
  for (const relative of filesUnder(materialized as unknown as TreeVfs, '/dsh/workspace')) {
    const target = join(root, 'workspace', relative)
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, materialized.readFileSync(`/dsh/workspace/${posix.normalize(relative)}`) as Uint8Array)
  }
  assert.equal(existsSync(join(root, 'workspace/.git/HEAD')), true, 'the materialized copy has .git/HEAD')

  const archive = join(root, 'workspace.tar')
  await packOverlay(root, archive)
  const entries = await readTarArchive(new Uint8Array(await import('node:fs/promises').then(fs => fs.readFile(archive))))
  const names = entries.map(entry => entry.entry.name)
  assert.ok(names.includes('workspace/.git/HEAD'), `the archive carries .git/HEAD (entries: ${names.slice(0, 8).join(', ')})`)
  assert.ok(names.includes('workspace/.git/config'))
  assert.ok(names.includes('workspace/recipes.py'))
})
