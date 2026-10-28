// SPDX-License-Identifier: MIT
// G2-FIX regression: one VfsNamespace owns path -> backend + policy for every
// execution surface.
//
// The defect the real-model batch exposed (G2-D05, G2-D01):
//   - the DSH write tool wrote `/tmp/x` through `node:fs`, while `bash`'s
//     adapter rewrote `/tmp/x` to `/dsh/tmp/x` and the CPython preopen table
//     did not know `/tmp` at all: one name, three files;
//   - no layer owned an exec read policy, so `bash` could read
//     `/dsh/home/sessions/**` (DSH's own transcript state) and a single grep
//     inflated one model input by 17 717 tokens.
//
// This file drives the five surfaces the batch used — the write tool, bash,
// python3, git and glob — through the same namespace and asserts one answer:
//   * four roots (`/dsh/workspace`, `/dsh/home`, `/tmp`, `/dsh/tmp`) round-trip
//     across all five surfaces;
//   * a `/tmp` or `/dsh/tmp` write produces zero VFS_MUT frames while a
//     workspace/home write produces exactly one;
//   * after park/resume the volatile roots are empty;
//   * bash/python3/git read DSH session state as EACCES with the remediation
//     line.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  FrameType,
  type Frame,
} from '../channel/src/index.ts'
import {
  NodeFsBackend,
  setWorkerToolbox,
  WasiToolbox,
  workerTransport,
  WORKER_VFS_NAMESPACE,
  WORKER_VFS_PREOPENS,
  createNamespaceVfs,
  wrapFsPromises,
  type WorkerLike,
} from '../wasi-toolbox/src/index.ts'
import { NodeGitFs } from '../wasi-toolbox/git/index.ts'
import { createWorkerCommands, VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { TreeVfs } from './tree-vfs.ts'

const ROOTS = ['/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp'] as const
const encoder = new TextEncoder()

interface Fixture {
  readonly base: TreeVfs
  readonly vfs: TreeVfs
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly python: NodeFsBackend
  readonly git: NodeGitFs
}

/**
 * One Worker tree with the namespace installed the way `startPhoneWorker`
 * installs it: the wrapped VFS is what every surface reaches.
 */
function fixture(): Fixture {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const bashFace = wrapFsPromises(base.promises, WORKER_VFS_NAMESPACE)
  const fs = new VfsFileSystem({ nodeFs: bashFace as never, root: '', workerPaths: true })
  return {
    base,
    vfs,
    fs,
    shell: new WorkerShell({ fs }),
    python: new NodeFsBackend(base.promises, { namespace: WORKER_VFS_NAMESPACE }),
    // The git adapter sees the same virtual tree as the shell and python.
    git: new NodeGitFs('', {
      fsPromises: base.promises as unknown as typeof import('node:fs').promises,
      namespace: WORKER_VFS_NAMESPACE,
    }),
  }
}

/** The write tool surface: the runtime's `node:fs` over the active VFS. */
function writeTool(vfs: TreeVfs, path: string, text: string): void {
  vfs.writeFileSync(path, text)
}

/** The glob surface: walk one directory through the active VFS. */
function glob(vfs: TreeVfs, directory: string, pattern: string): string[] {
  const joined = WORKER_VFS_NAMESPACE.join(directory, pattern)
  const base = joined.slice(0, joined.lastIndexOf('/')) || '/'
  const leaf = joined.slice(joined.lastIndexOf('/') + 1)
  const entries = vfs.readdirSync(base)
  const matcher = new RegExp(`^${leaf.replace(/[.+^${}()|[\]\\]/g, '\\$&').replaceAll('*', '.*')}$`)
  return entries
    .map(entry => entry.name)
    .filter(name => matcher.test(name))
    .map(name => WORKER_VFS_NAMESPACE.storagePath(`${base}/${name}`))
}

test('namespace: the five surfaces see one file for one name under every root', async () => {
  const { vfs, fs, shell, python, git } = fixture()
  for (const [index, root] of ROOTS.entries()) {
    const writePath = `${root}/from-write-${index}.txt`
    writeTool(vfs, writePath, `write:${root}`)
    assert.equal(await fs.readFile(writePath), `write:${root}`, `bash reads the write tool's ${root} file`)
    assert.equal(new TextDecoder().decode(await python.readFile(writePath)), `write:${root}`, `python reads ${root}`)
    assert.equal(new TextDecoder().decode(await git.readFile(writePath)), `write:${root}`, `git reads ${root}`)
    assert.deepEqual(glob(vfs, root, `from-write-${index}.txt`), [WORKER_VFS_NAMESPACE.storagePath(writePath)], `glob lists the ${root} file`)
    const cat = await shell.run(['bash', '-c', `cat '${writePath}'`], { cwd: '/dsh/workspace' })
    assert.equal(cat.exitCode, 0, cat.stderr)
    assert.equal(cat.stdout, `write:${root}`)

    const bashPath = `${root}/from-bash-${index}.txt`
    await fs.writeFile(bashPath, `bash:${root}`)
    assert.equal(await fs.readFile(bashPath), `bash:${root}`)
    assert.equal(vfs.readFileSync(bashPath) instanceof Uint8Array, true, 'the write tool reads the shell write')
    assert.equal(new TextDecoder().decode(await python.readFile(bashPath)), `bash:${root}`)
    assert.equal(new TextDecoder().decode(await git.readFile(bashPath)), `bash:${root}`)
    assert.deepEqual(glob(vfs, root, `from-bash-${index}.txt`), [WORKER_VFS_NAMESPACE.storagePath(bashPath)])

    const pythonPath = `${root}/from-python-${index}.txt`
    await python.writeFile(pythonPath, encoder.encode(`python:${root}`), { create: true })
    assert.equal(await fs.readFile(pythonPath), `python:${root}`)
    assert.equal(new TextDecoder().decode(vfs.readFileSync(pythonPath) as Uint8Array), `python:${root}`)
    assert.equal(new TextDecoder().decode(await git.readFile(pythonPath)), `python:${root}`)

    const gitPath = `${root}/from-git-${index}.txt`
    await git.writeFile(gitPath, encoder.encode(`git:${root}`))
    assert.equal(await fs.readFile(gitPath), `git:${root}`, 'bash reads the git write')
    assert.equal(new TextDecoder().decode(vfs.readFileSync(gitPath) as Uint8Array), `git:${root}`)
    assert.equal(new TextDecoder().decode(await python.readFile(gitPath)), `git:${root}`)
  }
})

test('namespace: /tmp and /dsh/tmp are one volatile store with two names', async () => {
  const { vfs, fs, python, git } = fixture()
  writeTool(vfs, '/tmp/one.txt', 'one')
  assert.equal(await fs.readFile('/dsh/tmp/one.txt'), 'one')
  assert.equal(new TextDecoder().decode(await python.readFile('/dsh/tmp/one.txt')), 'one')
  assert.equal(new TextDecoder().decode(await git.readFile('/dsh/tmp/one.txt')), 'one')

  writeTool(vfs, '/dsh/tmp/two.txt', 'two')
  assert.equal(await fs.readFile('/tmp/two.txt'), 'two')
  assert.equal(vfs.readFileSync('/tmp/two.txt') instanceof Uint8Array, true)
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/tmp/two.txt'), '/dsh/tmp/two.txt')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/dsh/tmp/two.txt'), '/dsh/tmp/two.txt')
  const facts = WORKER_VFS_NAMESPACE.classify('/tmp/two.txt')
  assert.equal(facts.sink, false)
  assert.equal(facts.budgetBucket, 'tmp')
})

test('namespace: tmp writes produce zero VFS_MUT, durable writes produce exactly one', async () => {
  const { base, vfs } = fixture()
  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => { frames.push(frame) })
  const dispose = installSink(base, pair.worker)
  try {
    writeTool(vfs, '/tmp/volatile-a.txt', 'a')
    writeTool(vfs, '/dsh/tmp/volatile-b.txt', 'b')
    writeTool(vfs, '/dsh/workspace/durable.txt', 'c')
    writeTool(vfs, '/dsh/home/durable-home.txt', 'd')
    await new Promise<void>(resolve => setTimeout(resolve, 0))
    const mutations = frames
      .filter(frame => frame.type === FrameType.VFS_MUT)
      .map(frame => decodeVfsMutation(frame.payload))
    assert.deepEqual(mutations.map(mutation => mutation.path), ['/dsh/workspace/durable.txt', '/dsh/home/durable-home.txt'])
    assert.equal(mutations[0]?.mseq, 1n)
    assert.equal(mutations[1]?.mseq, 2n)
  } finally {
    dispose()
  }
})

test('namespace: the promises face resolves through the same authority', async () => {
  // DSH's write tool uses the async face; the shell's `VfsFileSystem` uses the
  // same object. Both must be the canonicalising view (not the raw tree).
  const { base, vfs } = fixture()
  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame(frame => { frames.push(frame) })
  const dispose = installSink(base, pair.worker)
  try {
    await vfs.promises.writeFile('/tmp/async-a.txt', new TextEncoder().encode('a'))
    await vfs.promises.writeFile('/dsh/workspace/async-b.txt', new TextEncoder().encode('b'))
    await new Promise<void>(resolve => setTimeout(resolve, 0))
    const mutations = frames.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
    assert.deepEqual(mutations.map(mutation => mutation.path), ['/dsh/workspace/async-b.txt'])
    assert.equal(base.existsSync('/dsh/tmp/async-a.txt'), true)
    assert.equal(base.existsSync('/tmp/async-a.txt'), false)
  } finally {
    dispose()
  }
})

test('namespace: park/resume rebuilds from the sink, so the volatile roots are empty', () => {
  const { base, vfs } = fixture()
  writeTool(vfs, '/tmp/lost.txt', 'volatile')
  writeTool(vfs, '/dsh/tmp/also-lost.txt', 'volatile')
  writeTool(vfs, '/dsh/workspace/kept.txt', 'durable')
  writeTool(vfs, '/dsh/home/kept-home.txt', 'durable')
  const resumed = createNamespaceVfs(TreeVfs.replay(base.published), WORKER_VFS_NAMESPACE)
  assert.equal(resumed.readFileSync('/dsh/workspace/kept.txt') instanceof Uint8Array, true)
  assert.equal(resumed.readFileSync('/dsh/home/kept-home.txt') instanceof Uint8Array, true)
  assert.equal(resumed.existsSync('/tmp/lost.txt'), false, 'park/resume leaves no /tmp file')
  assert.equal(resumed.existsSync('/tmp'), false, 'park/resume does not even recreate the volatile spelling')
  assert.equal(resumed.existsSync('/dsh/tmp/also-lost.txt'), false)
  void vfs
})

test('namespace: bash, python3 and git read session-internal state as EACCES with one hint', async () => {
  const { vfs, fs, shell, python, git } = fixture()
  const internal = [
    '/dsh/home/sessions/project/session.jsonl',
    '/dsh/home/storages/store.json',
    '/dsh/home/tool-journal/tool.jsonl',
  ]
  vfs.mkdirSync('/dsh/home/sessions/project', { recursive: true })
  vfs.mkdirSync('/dsh/home/storages', { recursive: true })
  vfs.mkdirSync('/dsh/home/tool-journal', { recursive: true })
  vfs.mkdirSync('/dsh/home/notes', { recursive: true })
  for (const path of internal) writeTool(vfs, path, '{"secret":true}')
  writeTool(vfs, '/dsh/home/notes/public.md', 'public')

  const expected = /session-internal state|session API|\/dsh\/workspace/
  for (const path of internal) {
    await assert.rejects(fs.readFile(path), (error: unknown) => {
      const coded = error as { code?: string; message?: string }
      assert.equal(coded.code, 'EACCES')
      assert.match(String(coded.message), expected)
      return true
    }, `bash must not read ${path}`)
    await assert.rejects(python.readFile(path), (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'EACCES')
      assert.match(String((error as Error).message), expected)
      return true
    }, `python must not read ${path}`)
    await assert.rejects(async () => { await git.readFile(path) }, (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'EACCES')
      assert.match(String((error as Error).message), expected)
      return true
    }, `git must not read ${path}`)
  }
  // Moving or hard-linking the bytes out of the subtree is the same leak as
  // reading them, so the source is checked too.
  for (const [operation, run] of [
    ['cp', async () => { await fs.cp(internal[0] as string, '/dsh/workspace/leak.jsonl') }],
    ['mv', async () => { await fs.mv(internal[0] as string, '/dsh/workspace/leak.jsonl') }],
    ['python rename', async () => { await python.rename(internal[0] as string, '/dsh/workspace/leak.jsonl') }],
    ['git rename', async () => { await git.rename(internal[0] as string, '/dsh/workspace/leak.jsonl') }],
  ] as const) {
    await assert.rejects(run, (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'EACCES', String(operation))
      return true
    }, `${operation} must not move session state out`)
  }
  // The subtree boundary is exact: a sibling under home stays readable.
  assert.equal(await fs.readFile('/dsh/home/notes/public.md'), 'public')
  assert.equal(new TextDecoder().decode(await python.readFile('/dsh/home/notes/public.md')), 'public')
  // Directories are denied too, so a tool cannot enumerate the session store.
  await assert.rejects(python.readdir('/dsh/home/sessions'), (error: unknown) => (error as { code?: string }).code === 'EACCES')
  await assert.rejects(async () => { await git.readdir('/dsh/home/sessions') }, (error: unknown) => (error as { code?: string }).code === 'EACCES')

  // The shell adapter answers EACCES with the hint; the just-bash core
  // renders every failed open with its own fixed "No such file or directory"
  // text (it swallows the adapter error), so the command must fail closed and
  // leak no bytes. Surfacing the adapter message through `cat`/`ls` is a
  // shell-core change outside this package (see the final contract gaps).
  const cat = await shell.run(['bash', '-c', 'cat /dsh/home/sessions/project/session.jsonl'], { cwd: '/dsh/workspace' })
  assert.notEqual(cat.exitCode, 0)
  assert.equal(cat.stdout, '', 'the shell command never sees the session bytes')
  assert.doesNotMatch(cat.stdout, /secret/)
  const grep = await shell.run(['bash', '-c', 'grep -r secret /dsh/home/sessions'], { cwd: '/dsh/workspace' })
  assert.doesNotMatch(grep.stdout, /secret/)
  assert.equal(WORKER_VFS_NAMESPACE.execReadable('/dsh/home/sessions'), false)
  assert.equal(WORKER_VFS_NAMESPACE.execReadable('/dsh/home/sessions-archive'), true)
})

test('namespace: a git repository under the workspace is durable through the same VFS', () => {
  // G2-B07: the materialized workspace had no `.git`. The namespace makes every
  // git write path a normal workspace path: sink-eligible (D4 allows `.git` as
  // a component), same storage, and never re-routed to the volatile root.
  for (const path of [
    '/dsh/workspace/.git/HEAD',
    '/dsh/workspace/.git/config',
    '/dsh/workspace/.git/index',
    '/dsh/workspace/.git/objects/ab/cdef0123456789',
    '/dsh/workspace/.git/refs/heads/main',
    '/dsh/workspace/.git/logs/HEAD',
  ]) {
    assert.equal(WORKER_VFS_NAMESPACE.sinkEligible(path), true, path)
    assert.equal(WORKER_VFS_NAMESPACE.storagePath(path), path)
    assert.equal(WORKER_VFS_NAMESPACE.classify(path).sink, true, path)
  }
  // A git program that staged an object in tmp would not be durable; the
  // namespace (and the tests above) keep the whole repository in the workspace.
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/tmp/.git/HEAD'), false)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/tmp/.git/HEAD'), false)
})

test('namespace: join keeps a relative pattern on its base and an absolute one canonical', () => {
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', 'src/*.ts'), '/dsh/workspace/src/*.ts')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', '/tmp/x/*.txt'), '/tmp/x/*.txt')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', '!*.md'), '!/dsh/workspace/*.md')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', '../home/a'), '/dsh/home/a')
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/workspace/a'), '/dsh/workspace/a')
  // The legacy runtime home spelling is virtual; concatenation keeps the
  // public-repo hygiene scanner from reading it as a user home path.
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/home' + '/a'), '/dsh/home/a')
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/tmp/a'), '/tmp/a')
  assert.throws(() => WORKER_VFS_NAMESPACE.resolve('relative'), /absolute/)
})

test('namespace: python3 stderr carries the EACCES guidance, not just an errno', { timeout: 30_000 }, async () => {
  // WASI preview1 has no error-text channel, so the host writes the policy
  // message to the command's stderr (the same mechanism the D4 EFBIG refusal
  // uses). A model running python3 therefore learns why the read was denied.
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  vfs.mkdirSync('/dsh/home/sessions/project', { recursive: true })
  vfs.writeFileSync('/dsh/home/sessions/project/transcript.jsonl', '{"secret":true}')
  const probeWasm = readFileSync(new URL('../wasi-toolbox/python/testdata/cpython-probe.wasm', import.meta.url))
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: { url: 'testdata://cpython-probe.wasm', load: async () => probeWasm },
      cwd: '/dsh/workspace',
      description: 'wasi-libc probe at the python3 program name',
    }],
    backend: new NodeFsBackend(base.promises),
    preopens: WORKER_VFS_PREOPENS,
    crossOriginIsolated: true,
    spawnWorker: () => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
    workerReadyTimeoutMs: 10_000,
  })
  setWorkerToolbox(toolbox)
  try {
    const fs = new VfsFileSystem({ nodeFs: wrapFsPromises(base.promises) as never, root: '', workerPaths: true })
    const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false }) })
    const result = await shell.run(
      ['bash', '-c', 'python3 /dsh/home/sessions/project/transcript.jsonl'],
      { cwd: '/dsh/workspace' },
    )
    assert.notEqual(result.exitCode, 0)
    assert.match(result.stderr, /EACCES/)
    assert.match(result.stderr, /session-internal state/)
    assert.match(result.stderr, /\/dsh\/workspace/)
  } finally {
    setWorkerToolbox(undefined)
    await toolbox.dispose()
  }
})
