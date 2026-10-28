// SPDX-License-Identifier: MIT
/**
 * G2-FIX-78 worker-entry wiring: the production boot path
 * (`installPythonToolbox` -> published `python3`) must serve Python's
 * `subprocess` family inside the Worker.
 *
 * This is the same wiring `startPhoneWorker` uses: the image artifacts are read
 * from the mounted VFS, the toolbox is published with `installShellDispatch()`,
 * and every command goes through the real `WasiToolbox` dispatch. The test
 * asserts both the nested interpreter's stdout and that its file write landed
 * in the shared `MemoryVfsBackend` (the host VFS stand-in), so a nested run
 * cannot bypass the one filesystem path.
 *
 * The real CPython artifact is required; without it the test skips exactly like
 * the other real-CPython tests in this repository.
 * @module @phone-dsh/dsh-worker-entry/python-subprocess.test
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { MemoryVfsBackend } from '../../wasi-toolbox/src/vfs-backends.ts'
import { workerTransport } from '../../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../../wasi-toolbox/src/message-endpoint.ts'
import type { WorkerEntryVfs } from './entry.ts'
import {
  disposePythonToolbox, installPythonToolbox, PYTHON_STDLIB_IMAGE_PATH, PYTHON_WASM_IMAGE_PATH,
} from './python-toolbox.ts'

/** The built CPython artifacts, when this machine has them. */
function pythonArtifacts(): { wasm: Uint8Array; stdlib: Uint8Array } | undefined {
  const explicit = process.env.PDSH_PYTHON_WASM
  const candidates = explicit !== undefined && explicit !== ''
    ? [{ wasm: explicit, stdlib: process.env.PDSH_PYTHON_STDLIB ?? join(dirname(explicit), 'python313.zip') }]
    : [{ wasm: join(tmpdir(), 'pdsh-python-wasi', 'python.wasm'), stdlib: join(tmpdir(), 'pdsh-python-wasi', 'python313.zip') }]
  for (const candidate of candidates) {
    if (!existsSync(candidate.wasm) || !existsSync(candidate.stdlib)) continue
    return { wasm: readFileSync(candidate.wasm), stdlib: readFileSync(candidate.stdlib) }
  }
  return undefined
}

const artifacts = pythonArtifacts()

/** The artifact slice of the mounted image: exactly the paths the packer writes. */
class ImageVfs implements WorkerEntryVfs {
  readonly files = new Map<string, Uint8Array>()

  subscribe(): () => void { return () => {} }

  async flush(): Promise<void> {}

  readFileSync(path: string): Uint8Array {
    const bytes = this.files.get(path)
    if (bytes === undefined) {
      throw Object.assign(new Error(`ENOENT: no such file or directory, open '${path}'`), {
        code: 'ENOENT',
        path,
        syscall: 'open',
      })
    }
    return bytes
  }
}

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

function seededBackend(): MemoryVfsBackend {
  const backend = new MemoryVfsBackend()
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp', '/tmp']) backend.seedDirectory(directory)
  return backend
}

test('worker entry: the published python3 serves subprocess on the shared VFS', {
  timeout: 180_000,
  skip: artifacts === undefined
    ? 'set PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB or build into $TMPDIR/pdsh-python-wasi to run real CPython'
    : false,
}, async () => {
  const vfs = new ImageVfs()
  vfs.files.set(PYTHON_WASM_IMAGE_PATH, artifacts!.wasm)
  vfs.files.set(PYTHON_STDLIB_IMAGE_PATH, artifacts!.stdlib)
  const backend = seededBackend()
  const lines: string[] = []
  const wiring = await installPythonToolbox({
    vfs,
    backend,
    spawnWorker: spawnPythonWorker,
    crossOriginIsolated: true,
    log: message => { lines.push(message) },
  })
  assert.ok(wiring, 'the image carries python3')
  try {
    const stdout: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const result = await wiring.runtime.run({
      program: 'python3',
      argv: ['-c', `
import os, subprocess, sys
result = subprocess.run(
    [sys.executable, "-c", "import pathlib; pathlib.Path('worker-entry-child.txt').write_text('entry-child'); print('nested-ok')"],
    capture_output=True,
    text=True,
)
print("spawn", result.returncode, repr(result.stdout), repr(result.stderr))
`],
      onStdout: chunk => { stdout.push(chunk) },
      onStderr: chunk => { stderr.push(chunk) },
    })
    const out = new TextDecoder().decode(Buffer.concat(stdout.map(chunk => Buffer.from(chunk))))
    const err = new TextDecoder().decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk))))
    assert.equal(result.exitCode, 0, err)
    assert.match(out, /spawn 0 'nested-ok\\n' ''/)
    // The child wrote through the same toolbox `WasiVfs` the shell dispatch
    // uses, so the mutation is visible to every other Worker surface.
    assert.equal(
      new TextDecoder().decode(backend.peek('/dsh/workspace/worker-entry-child.txt') ?? new Uint8Array(0)),
      'entry-child',
    )
  } finally {
    await disposePythonToolbox(wiring)
  }
})
