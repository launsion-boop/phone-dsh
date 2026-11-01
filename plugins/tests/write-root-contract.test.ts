// SPDX-License-Identifier: MIT
// P13 / G2-B: the execution surfaces may write only the root table.
//
// `spec/v1/channel.md:259-261` is the whole writable namespace:
// `/dsh/workspace`, `/dsh/home`, `/tmp`, `/dsh/tmp` and `/dev/null`.
// `/` and `/dsh/config` are not roots, and `/dsh/bin` is the image's
// read-only program directory (`plugins/worker-entry/src/capabilities.ts`
// declares `image_readonly: ['/dsh/bin']`). Before this contract the shell
// could write all four: `printf x > /dsh/config/probe.txt` exited 0 (and so
// did `/` and `/dsh/bin`), which also meant those bytes never entered a budget
// bucket (`spec/v1/budgets.md` has workspace/sessions/tmp only).
//
// The guard lives in two places, and both are pinned here:
//
//   * `VfsNamespace.assertWritable` / `wrapFsPromises` (wasi-toolbox) — the
//     policy on the `node:fs.promises` face the Worker installs, which covers
//     every execution adapter that imports it (shell, git);
//   * `VfsFileSystem` (shell-ext) — the adapter's own gate before `node:fs`,
//     which also covers the synchronous write path.
//
// Both reuse P2's one remediation sentence. This file asserts one answer for
// all four illegal roots and success for all five legal ones.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import {
  createNamespaceVfs,
  installExecFsPolicy,
  WORKER_VFS_NAMESPACE,
  wrapFsPromises,
} from '../wasi-toolbox/src/index.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { TreeVfs } from './tree-vfs.ts'

/** The one sentence every refused write ends with (P2's wording). */
const SENTENCE = 'pdsh-shell: writable roots are /dsh/workspace, /dsh/home, /tmp, /dsh/tmp, /dev/null '
  + '(TMPDIR=/dsh/tmp)'

/** Roots a command may create files under: the namespace's table. */
const LEGAL = ['/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp'] as const

/** Image paths a command must never create or change. */
const ILLEGAL = ['/', '/dsh/config', '/dsh/bin', '/etc'] as const

interface Fixture {
  /** The in-memory tree behind the adapter (the Worker's `MemoryVfs` stand-in). */
  readonly tree: TreeVfs
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/**
 * One Worker-shaped shell: the production adapter root (`'/'`), an in-memory
 * tree behind it, and the `/tmp` alias on so the five contract roots are the
 * five spellings the model uses.
 */
async function fixture(): Promise<Fixture> {
  const tree = new TreeVfs()
  const fs = new VfsFileSystem({
    root: '/',
    nodeFs: tree.promises as unknown as never,
    workerPaths: true,
  })
  // The Worker image seeds every directory root at boot; seed the same four
  // directory roots (plus the image's program directory) here.
  for (const legal of LEGAL) await fs.mkdir(legal, { recursive: true })
  return { tree, fs, shell: new WorkerShell({ fs }) }
}

/** Run one bash script from the workspace. */
async function bash(shell: WorkerShell, script: string) {
  return await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
}

/** The full errno phrase a node-shaped refusal starts with. */
function errnoLine(path: string): string {
  return `EACCES: permission denied, open '${path}'`
}

test('write roots: the five contract roots accept a write', async () => {
  const { tree, shell } = await fixture()
  for (const [index, legal] of LEGAL.entries()) {
    const target = `${legal}/legal-${index}.txt`
    const result = await bash(shell, `printf ok > '${target}'`)
    assert.equal(result.exitCode, 0, `${legal}: ${result.stderr}`)
    assert.equal(result.stderr, '', `${legal} writes without a diagnostic`)
    // /tmp is the alias of /dsh/tmp, so its bytes land below /dsh/tmp.
    const real = legal === '/tmp' ? `/dsh/tmp/legal-${index}.txt` : target
    assert.equal(tree.existsSync(real), true, `${legal} wrote a file`)
  }
  // `/dev/null` is the one device: the write succeeds and stores nothing.
  const device = await bash(shell, 'printf x > /dev/null')
  assert.equal(device.exitCode, 0, device.stderr)
  assert.equal(device.stderr, '')
  assert.equal(tree.existsSync('/dev/null'), false, 'a device write creates no file')
})

test('write roots: /, /dsh/config, /dsh/bin and /etc all refuse with one identical shape', async () => {
  const { tree, shell } = await fixture()
  const results: { path: string; stderr: string; exitCode: number }[] = []
  for (const illegal of ILLEGAL) {
    const target = illegal === '/' ? '/probe-h2.txt' : `${illegal}/probe-h2.txt`
    const result = await bash(shell, `printf x > '${target}'`)
    results.push({ path: target, stderr: result.stderr, exitCode: result.exitCode })
    assert.equal(result.exitCode, 1, `${target} is refused with a failure status`)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, new RegExp(`^${errnoLine(target).replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}$`, 'mu'))
    assert.ok(result.stderr.split('\n').includes(SENTENCE), `${target} carries the P2 sentence`)
    assert.doesNotMatch(result.stderr, /<path>/u, 'the sanitizer never mangles the roots list')
    assert.doesNotMatch(result.stderr, /maxOutputSize/u)
    // Nothing is created: not the target, not a `<path>` residue, no fragment.
    assert.equal(tree.existsSync(target), false, `${target} was not created`)
  }
  // One shape modulo the path: the refusal is the contract's single answer,
  // not four per-command diagnostics.
  const shapes = results.map(result => result.stderr.split(result.path).join('<path>'))
  assert.equal(new Set(shapes).size, 1, `one answer for four paths:\n${shapes.join('\n---\n')}`)
  const lines = results[0]?.stderr.trimEnd().split('\n') ?? []
  assert.deepEqual(lines, [errnoLine(results[0]?.path ?? ''), SENTENCE])
})

test('write roots: the adapter refuses a mutation before node:fs, not only redirection', async () => {
  const { tree, fs, shell } = await fixture()
  // A write through the API keeps the node-shaped code and path, and is marked
  // for the shell's rendering layer.
  await assert.rejects(fs.writeFile('/dsh/config/direct.txt', 'x'), (error: unknown) => {
    const coded = error as { code?: string; path?: string; message?: string }
    assert.equal(coded.code, 'EACCES')
    assert.equal(coded.path, '/dsh/config/direct.txt')
    assert.equal(coded.message, errnoLine('/dsh/config/direct.txt'))
    return true
  })
  assert.equal(tree.existsSync('/dsh/config/direct.txt'), false)

  // mkdir, rm, mv and cp are mutations of the same namespace.
  const made = await bash(shell, 'mkdir /dsh/config/sub')
  assert.notEqual(made.exitCode, 0)
  assert.match(made.stderr, /EACCES: permission denied, mkdir '\/dsh\/config\/sub'/u)
  assert.ok(made.stderr.split('\n').includes(SENTENCE))
  assert.equal(tree.existsSync('/dsh/config/sub'), false)

  // The image's program directory really exists; removing or moving out of it
  // is a change to the read-only image.
  tree.mkdirSync('/dsh/bin', { recursive: true })
  tree.writeFileSync('/dsh/bin/bash', '#!/bin/bash\n')
  const removed = await bash(shell, 'rm -rf /dsh/bin')
  assert.notEqual(removed.exitCode, 0, removed.stderr)
  assert.ok(removed.stderr.split('\n').includes(SENTENCE), removed.stderr)
  assert.equal(tree.existsSync('/dsh/bin/bash'), true, 'the image file survives rm -rf')

  const moved = await bash(shell, 'mv /dsh/bin/bash /tmp/bash')
  assert.notEqual(moved.exitCode, 0, moved.stderr)
  assert.ok(moved.stderr.split('\n').includes(SENTENCE), moved.stderr)
  assert.equal(tree.existsSync('/dsh/bin/bash'), true, 'the image file survives mv')

  const copied = await bash(shell, 'cp /dsh/bin/bash /dsh/config/bash')
  assert.notEqual(copied.exitCode, 0, copied.stderr)
  assert.ok(copied.stderr.split('\n').includes(SENTENCE), copied.stderr)
  assert.equal(tree.existsSync('/dsh/config/bash'), false)
})

test('write roots: the namespace policy installed on the Worker node:fs face refuses the same paths', async () => {
  // The Worker installs `installExecFsPolicy` on `node:fs.promises`, in place;
  // this is the TreeVfs instance the namespace matrix uses, so the test drives
  // the exact face the shell adapter sees in production.
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const face = base.promises as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>
  const dispose = installExecFsPolicy(face, WORKER_VFS_NAMESPACE)

  for (const legal of LEGAL) {
    await face.writeFile?.(`${legal}/wrapped.txt`, new TextEncoder().encode('ok'))
    assert.equal(new TextDecoder().decode(base.readFileSync(`${WORKER_VFS_NAMESPACE.storagePath(legal)}/wrapped.txt`) as Uint8Array), 'ok')
  }
  const refused: readonly [string, () => Promise<unknown>][] = [
    ['writeFile', async () => await face.writeFile?.('/dsh/config/x', new Uint8Array())],
    ['appendFile', async () => await face.appendFile?.('/dsh/bin/x', new Uint8Array())],
    ['mkdir', async () => await face.mkdir?.('/dsh/bin')],
    ['rm', async () => await face.rm?.('/dsh/bin/bash')],
    ['rename', async () => await face.rename?.('/dsh/workspace/wrapped.txt', '/dsh/config/wrapped.txt')],
    ['cp', async () => await face.cp?.('/dsh/workspace/wrapped.txt', '/dsh/config/wrapped.txt')],
    ['open-write', async () => await face.open?.('/dsh/config/x', 'w')],
  ]
  for (const [name, attempt] of refused) {
    await assert.rejects(attempt, (error: unknown) => {
      const coded = error as { code?: string; message?: string }
      assert.equal(coded.code, 'EACCES', `${name} refuses with EACCES`)
      assert.match(String(coded.message), /^EACCES: permission denied, /u, `${name} keeps the node shape`)
      assert.doesNotMatch(String(coded.message), /<path>/u)
      return true
    }, `${name} is refused`)
  }
  assert.equal(base.existsSync('/dsh/config/wrapped.txt'), false)
  assert.equal(base.existsSync('/dsh/bin/wrapped.txt'), false)
  dispose()
})

test('write roots: the shell over the wrapped face answers with the same sentence', async () => {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const fs = new VfsFileSystem({
    nodeFs: wrapFsPromises(base.promises, WORKER_VFS_NAMESPACE) as never,
    root: '',
    workerPaths: true,
  })
  const shell = new WorkerShell({ fs })
  for (const illegal of ILLEGAL) {
    const target = illegal === '/' ? '/probe-h2.txt' : `${illegal}/probe-h2.txt`
    const result = await bash(shell, `printf x > '${target}'`)
    assert.equal(result.exitCode, 1, `${target}: ${result.stderr}`)
    assert.ok(result.stderr.split('\n').includes(SENTENCE), `${target}: ${result.stderr}`)
    assert.equal(base.existsSync(target), false)
  }
  const ok = await bash(shell, 'printf ok > /dsh/workspace/from-shell.txt; cat /dsh/workspace/from-shell.txt')
  assert.equal(ok.exitCode, 0, ok.stderr)
  assert.equal(ok.stdout, 'ok')
})

// P29: process substitution is a POSIX shell feature, not a write escape.
//
// just-bash implements `<(...)`/`>(...)` by writing the descriptor through the
// active filesystem first and installing a private in-memory filesystem at
// `/dev/fd` only when that write fails — the failure is the mount trigger.
// The base VFS therefore has to answer `ENOENT` there, never the writable-roots
// sentence: the shell renders every recorded refusal at the end, so the
// recovered probe used to turn `diff <(echo a) <(echo a)` into exit 1 with a
// policy line even though the command's stdout was correct.
//
// The fix does not widen the writable surface: `/dev/fd` stays outside the root
// table (the sentence still names exactly the five roots), a direct write there
// still fails, and no byte reaches the VFS — the engine's private mount owns
// the descriptors, so `/dev/fd` cannot be used to store or reach a real file.
test('write roots: process substitution works and /dev/fd stays outside the table', async () => {
  const { tree, shell } = await fixture()
  // The three committed golden vectors, here through the policy-enabled
  // Worker-shaped adapter rather than the golden harness's real-directory root.
  const vectors: readonly (readonly [string, string])[] = [
    ['diff <(echo a) <(echo a) && echo same', 'same\n'],
    ['comm -12 <(printf "a\\nb\\n") <(printf "b\\nc\\n")', 'b\n'],
    ['paste -d, <(printf "a\\nb\\n") <(printf "1\\n2\\n")', 'a,1\nb,2\n'],
  ]
  for (const [script, stdout] of vectors) {
    const result = await bash(shell, script)
    assert.equal(result.exitCode, 0, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, stdout, script)
    assert.equal(result.stderr, '', `${script} must print no refusal`)
  }
  // The engine's private mount point is not namespace storage.
  assert.equal(tree.existsSync('/dev'), false, 'no /dev tree is created')
  assert.equal(tree.existsSync('/dev/fd'), false, 'no /dev/fd directory is created')
  // A direct write there is still refused — "absent", not a writable root —
  // and stores nothing, so `/dev/fd` cannot become a bypass.
  const direct = await bash(shell, 'printf x > /dev/fd/63')
  assert.equal(direct.exitCode, 1, direct.stderr)
  assert.equal(direct.stderr, "ENOENT: no such file or directory, open '/dev/fd/63'\n")
  assert.equal(tree.existsSync('/dev/fd/63'), false)
  // The one sentence the model reads is still the five-root P2 sentence.
  assert.equal(WORKER_VFS_NAMESPACE.writableRootsLine(), SENTENCE)
})

