// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { VfsProxyError } from '../src/errors.ts'
import { workerTransport } from '../src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../src/message-endpoint.ts'
import type { VfsDirEntry, VfsStat, WasiVfs } from '../src/types.ts'
import { NodeFsBackend } from '../src/vfs-backends.ts'
import type { NodeFsPromisesLike } from '../src/vfs-backends.ts'
import {
  PythonRuntime, PYTHON_STDLIB_GUEST_PATH, PYTHON_STDLIB_HOST_ROOT, pythonReadsScriptFromStdin,
} from './runtime.ts'
import { createPythonVfs } from './python-worker-runtime.ts'

const stubWasm = readFileSync(new URL('./testdata/stub-python.wasm', import.meta.url))
/** The stub never parses the zip; the worker only mounts these bytes. */
const stubStdlib = new Uint8Array(64)
const decoder = new TextDecoder()

interface Fixture {
  readonly root: string
  readonly workspace: string
  readonly runtime: PythonRuntime
  readonly cleanup: () => Promise<void>
}

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('./node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

async function fixture(options: {
  wasm?: Uint8Array
  stdlib?: Uint8Array
  memoryLimitBytes?: number
} = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), 'pdsh-python-'))
  const workspace = join(root, 'workspace')
  await mkdir(workspace, { recursive: true })
  const runtime = new PythonRuntime({
    wasm: options.wasm ?? stubWasm,
    stdlib: options.stdlib ?? stubStdlib,
    backend: new NodeFsBackend(fsPromises as unknown as NodeFsPromisesLike),
    preopens: [{ guestPath: '/workspace', hostPath: workspace }],
    cwd: '/workspace',
    crossOriginIsolated: true,
    spawnWorker: spawnPythonWorker,
    workerReadyTimeoutMs: 10_000,
    ...(options.memoryLimitBytes === undefined ? {} : { memoryLimitBytes: options.memoryLimitBytes }),
  })
  return {
    root,
    workspace,
    runtime,
    cleanup: async () => {
      await runtime.dispose()
      await rm(root, { recursive: true, force: true })
    },
  }
}

function collect(): { chunks: Uint8Array[]; text: () => string } {
  const chunks: Uint8Array[] = []
  return { chunks, text: () => decoder.decode(concat(chunks)) }
}

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
  const joined = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    joined.set(chunk, offset)
    offset += chunk.byteLength
  }
  return joined
}

test('python: registers python3 in the toolbox and runs the stub through it', { timeout: 20_000 }, async () => {
  const setup = await fixture()
  try {
    assert.equal(setup.runtime.hasPython3(), true)
    assert.equal(setup.runtime.toolbox.has('python3'), true)
    assert.deepEqual(setup.runtime.toolbox.list().map(entry => entry.program), ['python3'])

    const stdout = collect()
    const stderr = collect()
    const first = await setup.runtime.run({
      program: 'python3',
      argv: ['-c', 'pass'],
      onStdout: chunk => stdout.chunks.push(chunk),
      onStderr: chunk => stderr.chunks.push(chunk),
    })
    assert.equal(first.exitCode, 0)
    assert.equal(first.cancelled, false)
    assert.equal(stderr.text(), '')
    assert.match(stdout.text(), /^python3-stub\n/)
    assert.match(stdout.text(), /stdin-bytes=00000000/)
    assert.ok(first.memoryPeakBytes > 0)

    const second = await setup.runtime.run({ program: 'python3', argv: ['-c', 'pass'] })
    assert.equal(second.exitCode, 0)
    assert.equal(setup.runtime.toolbox.stats().hotInstances, 1)
    assert.equal(setup.runtime.diagnostics().stdlibProxyReads, 0)
  } finally {
    await setup.cleanup()
  }
})

test('python: the stdlib zip is served from the in-worker layer, not the proxy', async () => {
  const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xaa, 0xbb, 0xcc, 0xdd])
  const unwritable = new ExplodingVfs()
  const bundle = createPythonVfs({
    writable: unwritable,
    stdlib: { stdlibZip: zip, guestPath: PYTHON_STDLIB_GUEST_PATH, hostRoot: PYTHON_STDLIB_HOST_ROOT },
  })
  assert.equal(bundle.zipHostPath, `${PYTHON_STDLIB_HOST_ROOT}/python313.zip`)
  assert.deepEqual([...bundle.vfs.read(bundle.zipHostPath, 0, 4)], [0x50, 0x4b, 0x03, 0x04])
  assert.equal(bundle.vfs.stat(bundle.zipHostPath).size, zip.byteLength)
  assert.equal(bundle.metrics.proxyCalls, 0)
  assert.equal(bundle.metrics.proxyStdlibReads, 0)
  assert.throws(
    () => bundle.vfs.write(bundle.zipHostPath, 0, new Uint8Array([1]), { append: false, create: false }),
    (error: unknown) => error instanceof VfsProxyError && error.code === 'EROFS',
  )
  assert.throws(
    () => bundle.vfs.read('/workspace/other.txt', 0, 1),
    /unexpected proxy read/,
  )
  assert.equal(bundle.metrics.proxyCalls, 1)
  assert.equal(bundle.metrics.proxyStdlibReads, 0)
})

test('python: benchmark reports cold start, warm start, imports and 1 MiB JSON', { timeout: 30_000 }, async () => {
  const setup = await fixture()
  try {
    const stdin = collect()
    const fed = await setup.runtime.run({
      program: 'python3',
      argv: ['-c', 'pass'],
      stdin: new Uint8Array(1024 * 1024),
      onStdout: chunk => stdin.chunks.push(chunk),
    })
    assert.equal(fed.exitCode, 0)
    assert.match(stdin.text(), /stdin-bytes=00100000/)

    const report = await setup.runtime.benchmark({ jsonBytes: 1024 * 1024, runs: 2 })
    assert.equal(report.jsonBytes, 1024 * 1024)
    assert.ok(report.coldStartMs >= 0)
    assert.equal(report.warmStartRunsMs.length, 2)
    assert.equal(report.importRunsMs.length, 2)
    assert.equal(report.jsonRunsMs.length, 2)
    assert.deepEqual(report.importedModules, ['json', 're', 'pathlib'])
    assert.ok(report.peakMemoryBytes > 0)
    assert.equal(report.stdlibProxyReads, 0)
    assert.equal(report.proxyCalls, 0)
    assert.equal(setup.runtime.diagnostics().stdlibProxyReads, 0)
  } finally {
    await setup.cleanup()
  }
})

const realWasmPath = process.env.PDSH_PYTHON_WASM
const realStdlibPath = process.env.PDSH_PYTHON_STDLIB
  ?? (realWasmPath === undefined ? undefined : join(dirname(realWasmPath), 'python313.zip'))

test(
  'python: real CPython 3.13 benchmark (PDSH_PYTHON_WASM)',
  {
    timeout: 180_000,
    skip: realWasmPath === undefined || realStdlibPath === undefined
      ? 'set PDSH_PYTHON_WASM (and optionally PDSH_PYTHON_STDLIB) to a built artifact'
      : false,
  },
  async () => {
    const setup = await fixture({
      wasm: readFileSync(realWasmPath as string),
      stdlib: readFileSync(realStdlibPath as string),
    })
    try {
      const report = await setup.runtime.benchmark({ jsonBytes: 1024 * 1024, runs: 3 })
      assert.match(report.pythonVersion ?? '', /^3\.13\./)
      assert.ok(report.coldStartMs > 0)
      assert.ok(report.warmStartMs >= 0)
      assert.ok(report.importMs >= 0)
      assert.ok(report.jsonParseMs >= 0)
      assert.equal(report.jsonBytes, 1024 * 1024)
      assert.equal(report.stdlibProxyReads, 0, 'stdlib reads must stay in the tool worker')
      assert.ok(report.peakMemoryBytes > 0)
    } finally {
      await setup.cleanup()
    }
  },
)

/** A writable VFS that fails the test if the stdlib lookup ever reaches it. */
class ExplodingVfs implements WasiVfs {
  stat(): VfsStat {
    throw new VfsProxyError('EIO', 'unexpected proxy stat')
  }

  readdir(): readonly VfsDirEntry[] {
    throw new VfsProxyError('EIO', 'unexpected proxy readdir')
  }

  open(): VfsStat {
    throw new VfsProxyError('EIO', 'unexpected proxy open')
  }

  read(): Uint8Array {
    throw new VfsProxyError('EIO', 'unexpected proxy read')
  }

  write(): number {
    throw new VfsProxyError('EIO', 'unexpected proxy write')
  }

  truncate(): void {
    throw new VfsProxyError('EIO', 'unexpected proxy truncate')
  }

  mkdir(): void {
    throw new VfsProxyError('EIO', 'unexpected proxy mkdir')
  }

  unlink(): void {
    throw new VfsProxyError('EIO', 'unexpected proxy unlink')
  }

  rename(): void {
    throw new VfsProxyError('EIO', 'unexpected proxy rename')
  }

  sync(): void {
    throw new VfsProxyError('EIO', 'unexpected proxy sync')
  }
}

test('python: only invocations that read their program from stdin get the read watchdog', () => {
  for (const argv of [[], ['-'], ['-i'], ['-i', '-'], ['-W', 'error', '-'], ['-Xdev'], ['--', '-'], ['-u']]) {
    assert.equal(pythonReadsScriptFromStdin(argv), true, JSON.stringify(argv))
  }
  for (const argv of [
    ['-c', 'pass'], ['-cpass'], ['-m', 'json.tool'], ['-mjson.tool'], ['script.py'], ['./x.py'],
    ['-W', 'error', 'script.py'], ['--version'], ['--help'], ['-V'], ['-h'], ['--', 'script.py'],
  ]) {
    assert.equal(pythonReadsScriptFromStdin(argv), false, JSON.stringify(argv))
  }
})
