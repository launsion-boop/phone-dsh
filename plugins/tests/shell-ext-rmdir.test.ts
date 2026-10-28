// SPDX-License-Identifier: MIT
// G2-FIX-64: `rmdir` in the Worker shell.
//
// The pinned runtime's `node:fs` replacement implements `rm`/`unlink` but not
// `rmdir`/`rmdirSync`. just-bash's bundled `rmdir` calls
// `fs.rm(dir, {recursive:false})`, and the shell-ext adapter answered that by
// calling `nodeFs.rmdir`, which does not exist in the Worker: every `rmdir`
// failed with `this.nodeFs.rmdir is not a function` while `rm -rf` on the same
// directory worked (G2-D06). These tests drive the production Worker command
// table over an in-memory VFS whose `node:fs` face deliberately omits `rmdir`,
// exactly like the runtime, and assert the mutation the sink publishes.
import assert from 'node:assert/strict'
import { setTimeout as settle } from 'node:timers/promises'
import { test } from 'node:test'
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
  type VfsFileSystemIo,
} from '../shell-ext/src/index.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { TreeVfs } from './tree-vfs.ts'

interface Fixture {
  readonly tree: TreeVfs
  readonly shell: WorkerShell
  readonly frames: Frame[]
  dispose(): void
}

/**
 * Build the production command table over an in-memory VFS whose promise face
 * never exposes `rmdir` — the shape of the runtime's `node:fs` replacement.
 */
function fixture(): Fixture {
  const tree = new TreeVfs()
  for (const root of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) tree.mkdirSync(root, { recursive: true })
  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => { frames.push(frame) })
  const dispose = installSink(tree, pair.worker)
  // Same object, minus the member the pinned runtime does not implement.
  const runtimeFace: Record<string, unknown> = { ...tree.promises }
  delete runtimeFace.rmdir
  const fs = new VfsFileSystem({
    root: '',
    workerPaths: false,
    nodeFs: runtimeFace as unknown as VfsFileSystemIo,
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

function names(tree: TreeVfs, path: string): string[] {
  return tree.readdirSync(path).map(entry => entry.name)
}

test('rmdir: removes an empty directory and publishes the VFS remove mutation (op 3)', async () => {
  const { tree, shell, frames, dispose } = fixture()
  try {
    const result = await shell.run(['bash', '-c', 'mkdir -p /dsh/workspace/empty && rmdir /dsh/workspace/empty'], {
      cwd: '/dsh/workspace',
    })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stderr, '')
    assert.equal(names(tree, '/dsh/workspace').includes('empty'), false, 'the directory is gone from the VFS')

    const mutations = await sinkMutations(frames)
    assert.equal(
      mutations.some(mutation => mutation.path === '/dsh/workspace/empty' && mutation.op === VfsOp.MKDIR),
      true,
      'the shell created the directory through the VFS first',
    )
    const remove = mutations.find(mutation => mutation.path === '/dsh/workspace/empty' && mutation.op === VfsOp.REMOVE)
    assert.ok(remove, `expected a remove mutation for the directory (got ${JSON.stringify(mutations.map(m => [m.op, m.path]))})`)
    assert.equal(remove.op, VfsOp.REMOVE, 'a directory removal is VFS op 3')
    assert.equal(remove.mode, 0)
    assert.equal(remove.data.byteLength, 0)

    // WAL + materialized copy: replaying exactly the sink stream leaves no directory.
    const materialized = TreeVfs.replay(tree.published)
    assert.equal(names(materialized, '/dsh/workspace').includes('empty'), false)
  } finally {
    dispose()
  }
})

test('rmdir: a non-empty directory fails ENOTEMPTY and leaves the tree intact', async () => {
  const { tree, shell, frames, dispose } = fixture()
  try {
    const result = await shell.run(['bash', '-c', [
      'mkdir -p /dsh/workspace/full/sub',
      'printf "keep\\n" > /dsh/workspace/full/file.txt',
      'printf "keep\\n" > /dsh/workspace/full/sub/leaf.txt',
      'rmdir /dsh/workspace/full',
    ].join(' && ')], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 1)
    assert.match(result.stderr, /ENOTEMPTY/)
    assert.match(result.stderr, /Directory not empty/)
    assert.deepEqual(names(tree, '/dsh/workspace/full'), ['file.txt', 'sub'])
    assert.deepEqual(names(tree, '/dsh/workspace/full/sub'), ['leaf.txt'])
    assert.equal(new TextDecoder().decode(tree.readFileSync('/dsh/workspace/full/file.txt')), 'keep\n')
    const mutations = await sinkMutations(frames)
    assert.equal(
      mutations.some(mutation => mutation.path === '/dsh/workspace/full' && mutation.op === VfsOp.REMOVE),
      false,
      'a refused rmdir publishes no remove mutation for the tree',
    )
  } finally {
    dispose()
  }
})

test('rmdir: a missing path fails ENOENT', async () => {
  const { shell, frames, dispose } = fixture()
  try {
    const result = await shell.run(['bash', '-c', 'rmdir /dsh/workspace/absent'], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 1)
    assert.match(result.stderr, /ENOENT/)
    assert.match(result.stderr, /No such file or directory/)
    const mutations = await sinkMutations(frames)
    assert.equal(mutations.some(mutation => mutation.path === '/dsh/workspace/absent'), false)
  } finally {
    dispose()
  }
})

test('rmdir: a regular file fails ENOTDIR', async () => {
  const { tree, shell, dispose } = fixture()
  try {
    await shell.run(['bash', '-c', 'printf "file\\n" > /dsh/workspace/plain.txt'], { cwd: '/dsh/workspace' })
    const result = await shell.run(['bash', '-c', 'rmdir /dsh/workspace/plain.txt'], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 1)
    assert.match(result.stderr, /ENOTDIR/)
    assert.match(result.stderr, /Not a directory/)
    assert.equal(new TextDecoder().decode(tree.readFileSync('/dsh/workspace/plain.txt')), 'file\n')
  } finally {
    dispose()
  }
})

test('rmdir: operands are removed left to right, so `rmdir a/b a` cleans up fully', async () => {
  const { tree, shell, frames, dispose } = fixture()
  try {
    const result = await shell.run(['bash', '-c', 'mkdir -p a/b && rmdir a/b a'], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(names(tree, '/dsh/workspace').includes('a'), false, 'the parent operand was removed after the child')
    const mutations = await sinkMutations(frames)
    const removed = mutations
      .filter(mutation => mutation.op === VfsOp.REMOVE)
      .map(mutation => mutation.path)
    assert.deepEqual(removed, ['/dsh/workspace/a/b', '/dsh/workspace/a'], 'one remove mutation per operand in order')
  } finally {
    dispose()
  }
})
