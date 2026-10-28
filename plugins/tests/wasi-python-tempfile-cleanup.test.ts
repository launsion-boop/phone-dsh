// SPDX-License-Identifier: MIT
// G2-FIX-47 regression: CPython's stdlib cleanup path inside the Worker.
//
// The defect: `tempfile.TemporaryDirectory()` cleanup failed for both an empty
// directory and one containing a file, and `os.rmdir` on a non-empty directory
// answered Errno 29 (EIO) instead of ENOTEMPTY. The model in G2-D06 had to
// rewrite its tests with `ignore_cleanup_errors=True`. Root cause: the
// production `node:fs/promises` face (`MemoryVfs.promises`) has no `rmdir`,
// and the toolbox's fallback (`rm(path, {recursive:false})`) answered the
// non-errno code `ERR_FS_EISDIR`, which reached CPython as EIO.
//
// This test runs the real `python.wasm` through the production stack — the
// toolbox VFS proxy (SharedArrayBuffer client), `NodeFsBackend`, and a
// runtime-shaped fs face without `rmdir` — so the stdlib behavior that broke
// in the scenario is pinned at the component boundary. It provisions the
// pinned build with `ensurePythonArtifacts` (the same policy as the
// compression tests): a missing verified interpreter fails the suite instead
// of silently skipping the capability.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { MemoryVfsBackend, NodeFsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import { DEFAULT_PREOPENS } from '../wasi-toolbox/src/limits.ts'
import { ensurePythonArtifacts } from '../wasi-toolbox/python/python-artifacts.ts'
import type { PythonArtifactPair } from '../wasi-toolbox/python/python-artifacts.ts'
import { PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import { runtimeFsFace } from './fixtures/runtime-fs-face.ts'

const decoder = new TextDecoder()

const artifacts = ensurePythonArtifacts()
const pair: PythonArtifactPair | undefined = artifacts.pair
if (artifacts.failure !== undefined) {
  // A broken/unbuildable artifact must fail the gate, not skip the capability.
  test('python cleanup: a verified CPython wasm32-wasi artifact is available', () => {
    assert.fail(artifacts.failure)
  })
}

const CLEANUP_PROGRAM = `
import errno
import os
import shutil
import tempfile

BASE = '/dsh/workspace'


def report(name, ok, detail=''):
    print('%s\\t%s\\t%s' % (name, 'ok' if ok else 'FAIL', detail))


def case(name, body):
    try:
        body()
        report(name, True)
    except Exception as error:  # noqa: BLE001 - each case reports its own failure
        report(name, False, '%s: %s' % (type(error).__name__, error))


def empty_temporary_directory():
    with tempfile.TemporaryDirectory(dir=BASE) as directory:
        assert os.path.isdir(directory), directory
        name = os.path.basename(directory)
    assert not os.path.exists(directory), directory
    assert name not in os.listdir(BASE), name


def file_temporary_directory():
    with tempfile.TemporaryDirectory(dir=BASE) as directory:
        with open(os.path.join(directory, 'payload.txt'), 'w') as handle:
            handle.write('payload')
        nested = os.path.join(directory, 'nested')
        os.mkdir(nested)
        with open(os.path.join(nested, 'deep.txt'), 'w') as handle:
            handle.write('deep')
        name = os.path.basename(directory)
    assert not os.path.exists(directory), directory
    assert name not in os.listdir(BASE), name


def rmdir_non_empty_directory():
    path = os.path.join(BASE, 'full')
    os.makedirs(os.path.join(path, 'sub'))
    with open(os.path.join(path, 'sub', 'x.txt'), 'w') as handle:
        handle.write('x')
    try:
        try:
            os.rmdir(path)
        except OSError as error:
            assert error.errno == errno.ENOTEMPTY, 'errno=%r expected ENOTEMPTY=%r' % (error.errno, errno.ENOTEMPTY)
            assert os.path.isdir(path), path
            assert os.path.isfile(os.path.join(path, 'sub', 'x.txt')), path
        else:
            raise AssertionError('os.rmdir accepted a non-empty directory')
    finally:
        shutil.rmtree(path, ignore_errors=True)


def rmdir_empty_directory():
    path = tempfile.mkdtemp(dir=BASE, prefix='empty-')
    os.rmdir(path)
    assert not os.path.exists(path), path
    assert os.path.basename(path) not in os.listdir(BASE), path


def syscall_surface_named_by_tempfile_and_shutil():
    # mkdtemp -> write -> rename -> unlink -> rmdir is the sequence
    # TemporaryDirectory cleanup and shutil.rmtree's fast path rely on.
    directory = tempfile.mkdtemp(dir=BASE, prefix='surface-')
    source = os.path.join(directory, 'a.txt')
    with open(source, 'w') as handle:
        handle.write('a')
    target = os.path.join(directory, 'b.txt')
    os.rename(source, target)
    assert not os.path.exists(source), source
    assert os.path.isfile(target), target
    os.unlink(target)
    os.rmdir(directory)
    assert not os.path.exists(directory), directory

    tree = os.path.join(BASE, 'tree')
    os.makedirs(os.path.join(tree, 'a', 'b'))
    with open(os.path.join(tree, 'a', 'b', 'x.txt'), 'w') as handle:
        handle.write('x')
    shutil.rmtree(tree)
    assert not os.path.exists(tree), tree


case('tempfile-empty', empty_temporary_directory)
case('tempfile-with-file', file_temporary_directory)
case('rmdir-non-empty-enotempty', rmdir_non_empty_directory)
case('rmdir-empty', rmdir_empty_directory)
case('syscall-surface-mkdtemp-rename-unlink-rmdir', syscall_surface_named_by_tempfile_and_shutil)
print('cleanup-done')
`

interface CleanupResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
  readonly cases: ReadonlyMap<string, { readonly ok: boolean; readonly detail: string }>
}

async function runCleanupProbe(artifact: PythonArtifactPair): Promise<CleanupResult> {
  const backend = new MemoryVfsBackend()
  for (const preopen of DEFAULT_PREOPENS) backend.seedDirectory(preopen.hostPath)
  const runtime = new PythonRuntime({
    wasm: readFileSync(artifact.wasm),
    stdlib: readFileSync(artifact.stdlib),
    backend: new NodeFsBackend(runtimeFsFace(backend)),
    preopens: DEFAULT_PREOPENS,
    cwd: '/dsh/workspace',
    crossOriginIsolated: true,
    spawnWorker(): ToolWorkerTransport {
      const worker = new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
      return workerTransport(worker as unknown as WorkerLike)
    },
    workerReadyTimeoutMs: 30_000,
  })
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  try {
    const result = await runtime.run({
      program: 'python3',
      argv: ['-c', CLEANUP_PROGRAM],
      cwd: '/dsh/workspace',
      env: { PWD: '/dsh/workspace' },
      onStdout: chunk => { stdout.push(chunk) },
      onStderr: chunk => { stderr.push(chunk) },
    })
    const text = decoder.decode(Buffer.concat(stdout.map(chunk => Buffer.from(chunk))))
    const cases = new Map<string, { ok: boolean; detail: string }>()
    for (const line of text.split('\n')) {
      const parts = line.split('\t')
      if (parts.length < 2) continue
      cases.set(parts[0] as string, { ok: parts[1] === 'ok', detail: parts[2] ?? '' })
    }
    return {
      exitCode: result.exitCode,
      stdout: text,
      stderr: decoder.decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk)))),
      cases,
    }
  } finally {
    await runtime.dispose()
  }
}

test('python cleanup: TemporaryDirectory and os.rmdir behave over the production VFS face', { timeout: 120_000 }, async () => {
  assert.ok(pair, 'the cleanup probe needs a verified python.wasm/python313.zip pair')
  const result = await runCleanupProbe(pair)
  const diagnostic = `exit=${result.exitCode}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
  assert.equal(result.exitCode, 0, diagnostic)
  for (const name of [
    'tempfile-empty',
    'tempfile-with-file',
    'rmdir-non-empty-enotempty',
    'rmdir-empty',
    'syscall-surface-mkdtemp-rename-unlink-rmdir',
  ]) {
    const outcome = result.cases.get(name)
    assert.ok(outcome, `missing case ${name} in:\n${diagnostic}`)
    assert.equal(outcome.ok, true, `${name}: ${outcome.detail}\n${diagnostic}`)
  }
  assert.match(result.stdout, /cleanup-done/, diagnostic)
})
