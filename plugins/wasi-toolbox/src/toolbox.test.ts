// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import * as fsPromises from 'node:fs/promises'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { workerTransport } from './message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from './message-endpoint.ts'
import { NodeFsBackend } from './vfs-backends.ts'
import type { NodeFsPromisesLike } from './vfs-backends.ts'
import { WasiToolbox } from './toolbox.ts'
import type { ToolboxCommand } from './types.ts'

const moduleBytes = readFileSync(new URL('./testdata/fd-echo.wasm', import.meta.url))
const decoder = new TextDecoder()

interface Fixture {
  readonly root: string
  readonly workspace: string
  readonly toolbox: WasiToolbox
  readonly loads: () => number
  readonly spawns: () => number
  readonly cleanup: () => Promise<void>
}

async function fixture(options: {
  crossOriginIsolated?: boolean
  memoryLimitBytes?: number
  programs?: readonly string[]
  shareModule?: boolean
  snapshotFallback?: boolean
  requiredPreopens?: readonly string[]
} = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), 'pdsh-wasi-toolbox-'))
  const workspace = join(root, 'workspace')
  await mkdir(workspace, { recursive: true })
  await writeFile(join(workspace, 'in.txt'), 'hello\n')
  await writeFile(join(workspace, 'second.txt'), 'again\n')
  let loads = 0
  let spawns = 0
  const source = {
    url: 'image://fd-echo.wasm',
    load: async () => {
      loads += 1
      return moduleBytes
    },
  }
  const programs = options.programs ?? ['fd-echo']
  const commands: ToolboxCommand[] = programs.map(program => ({
    program,
    module: options.shareModule === false
      ? { url: `image://${program}.wasm`, load: async () => moduleBytes }
      : source,
    description: 'fd-echo test program',
  }))
  const toolbox = new WasiToolbox({
    commands,
    backend: new NodeFsBackend(fsPromises as unknown as NodeFsPromisesLike),
    preopens: [{ guestPath: '/workspace', hostPath: workspace }],
    crossOriginIsolated: options.crossOriginIsolated ?? true,
    ...(options.memoryLimitBytes === undefined ? {} : { memoryLimitBytes: options.memoryLimitBytes }),
    ...(options.snapshotFallback === undefined ? {} : { snapshotFallback: options.snapshotFallback }),
    ...(options.requiredPreopens === undefined ? {} : { requiredPreopens: options.requiredPreopens }),
    spawnWorker: (): ToolWorkerTransport => {
      spawns += 1
      const worker = new Worker(new URL('./node-worker-harness.ts', import.meta.url))
      return workerTransport(worker as unknown as WorkerLike)
    },
    workerReadyTimeoutMs: 5000,
  })
  return {
    root,
    workspace,
    toolbox,
    loads: () => loads,
    spawns: () => spawns,
    cleanup: async () => {
      await toolbox.dispose()
      await rm(root, { recursive: true, force: true })
    },
  }
}

function collect(): { chunks: Uint8Array[]; text: () => string } {
  const chunks: Uint8Array[] = []
  return {
    chunks,
    text: () => decoder.decode(concat(chunks)),
  }
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

test('toolbox: a WASI program runs in a tool worker over the SAB VFS proxy', { timeout: 20_000 }, async () => {
  const setup = await fixture()
  try {
    assert.equal(setup.toolbox.stats().synchronousVfs, true)
    const stdout = collect()
    const stderr = collect()
    const result = await setup.toolbox.run({
      program: 'fd-echo',
      argv: ['in.txt', 'out.txt'],
      onStdout: chunk => stdout.chunks.push(chunk),
      onStderr: chunk => stderr.chunks.push(chunk),
    })
    assert.equal(result.exitCode, 0)
    assert.equal(result.cancelled, false)
    assert.equal(stderr.text(), '')
    assert.equal(stdout.text(), '[in.txt] hello\n\n')
    assert.equal(await readFile(join(setup.workspace, 'out.txt'), 'utf8'), 'echo:hello\n')
    assert.equal(setup.loads(), 1)
    assert.equal(setup.spawns(), 1)
    assert.deepEqual(setup.toolbox.stats().modules, { modules: 1, compiles: 1 })

    const second = await setup.toolbox.run({ program: 'fd-echo', argv: ['second.txt', 'second.out'] })
    assert.equal(second.exitCode, 0)
    assert.equal(await readFile(join(setup.workspace, 'second.out'), 'utf8'), 'echo:again\n')
    assert.equal(setup.loads(), 1)
    assert.equal(setup.spawns(), 1)
    assert.equal(setup.toolbox.stats().hotInstances, 1)
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: two programs share one compiled Module but keep separate hot workers', { timeout: 20_000 }, async () => {
  const setup = await fixture({ programs: ['fd-echo', 'fd-echo-two'] })
  try {
    assert.equal((await setup.toolbox.run({ program: 'fd-echo', argv: ['in.txt', 'a.txt'] })).exitCode, 0)
    assert.equal((await setup.toolbox.run({ program: 'fd-echo-two', argv: ['second.txt', 'b.txt'] })).exitCode, 0)
    assert.equal(setup.loads(), 1)
    assert.equal(setup.spawns(), 2)
    assert.deepEqual(setup.toolbox.stats().modules, { modules: 1, compiles: 1 })
    assert.equal(setup.toolbox.stats().hotInstances, 2)
    assert.equal(await readFile(join(setup.workspace, 'b.txt'), 'utf8'), 'echo:again\n')
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: abort terminates the hot worker and the next run spawns a new one', { timeout: 20_000 }, async () => {
  const setup = await fixture()
  try {
    const controller = new AbortController()
    const timer = setTimeout(() => { controller.abort() }, 150)
    const result = await setup.toolbox.run({
      program: 'fd-echo',
      argv: ['spin', 'unused.txt'],
      signal: controller.signal,
    })
    clearTimeout(timer)
    assert.equal(result.cancelled, true)
    assert.equal(result.exitCode, 130)
    assert.equal(setup.toolbox.stats().hotInstances, 0)

    const recovered = await setup.toolbox.run({ program: 'fd-echo', argv: ['in.txt', 'after.txt'] })
    assert.equal(recovered.exitCode, 0)
    assert.equal(await readFile(join(setup.workspace, 'after.txt'), 'utf8'), 'echo:hello\n')
    assert.equal(setup.spawns(), 2)
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: an abort while the worker is being acquired releases it instead of leaving it hot', {
  timeout: 20_000,
}, async () => {
  const setup = await fixture()
  try {
    const controller = new AbortController()
    // Abort after `run()` has begun acquiring the hot worker but before it can
    // post the exec. The pre-fix code returned a cancelled result and kept the
    // acquired instance in the pool; the next run then silently reused it.
    const pending = setup.toolbox.run({
      program: 'fd-echo',
      argv: ['in.txt', 'never-written.txt'],
      signal: controller.signal,
    })
    controller.abort()
    const result = await pending
    assert.equal(result.cancelled, true)
    assert.equal(result.exitCode, 130)
    assert.equal(setup.toolbox.stats().hotInstances, 0)

    const recovered = await setup.toolbox.run({ program: 'fd-echo', argv: ['in.txt', 'after-early-abort.txt'] })
    assert.equal(recovered.exitCode, 0)
    assert.equal(await readFile(join(setup.workspace, 'after-early-abort.txt'), 'utf8'), 'echo:hello\n')
    assert.equal(setup.spawns(), 2, 'the cancelled instance was terminated rather than reused')
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: the memory ceiling exits 137 and the warm worker recovers', { timeout: 20_000 }, async () => {
  const setup = await fixture({ memoryLimitBytes: 1024 * 1024 })
  try {
    const limited = await setup.toolbox.run({ program: 'fd-echo', argv: ['grow', 'grow.txt'] })
    assert.equal(limited.exitCode, 137)
    assert.equal(limited.memoryExceeded, true)
    assert.ok(limited.memoryPeakBytes > 1024 * 1024)

    const normal = await setup.toolbox.run({ program: 'fd-echo', argv: ['in.txt', 'normal.txt'] })
    assert.equal(normal.exitCode, 0)
    assert.equal(await readFile(join(setup.workspace, 'normal.txt'), 'utf8'), 'echo:hello\n')
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: without crossOriginIsolated the sync channel is absent and file I/O fails cleanly', { timeout: 20_000 }, async () => {
  const setup = await fixture({ crossOriginIsolated: false })
  try {
    assert.equal(setup.toolbox.stats().synchronousVfs, false)
    const stderr = collect()
    const result = await setup.toolbox.run({
      program: 'fd-echo',
      argv: ['in.txt', 'out.txt'],
      onStderr: chunk => stderr.chunks.push(chunk),
    })
    assert.notEqual(result.exitCode, 0)
    assert.equal(stderr.text(), 'fd-echo: error\n')
    assert.equal(setup.toolbox.stats().hotInstances, 1)
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: the snapshot fallback recaptures the live VFS before each dispatch', {
  timeout: 20_000,
}, async () => {
  const setup = await fixture({ crossOriginIsolated: false, snapshotFallback: true, requiredPreopens: ['/workspace'] })
  try {
    assert.equal(setup.toolbox.stats().synchronousVfs, false)
    const first = await setup.toolbox.run({ program: 'fd-echo', argv: ['in.txt', 'first.txt'] })
    assert.equal(first.exitCode, 0)
    assert.equal(await readFile(join(setup.workspace, 'first.txt'), 'utf8'), 'echo:hello\n')

    // A shell step writes through the live VFS after the tool worker captured
    // its view. The next dispatch must see the new bytes and the new file; a
    // capture taken only at init would keep serving the boot-time tree.
    await writeFile(join(setup.workspace, 'in.txt'), 'changed\n')
    await writeFile(join(setup.workspace, 'added.txt'), 'added\n')
    const stdout = collect()
    const secondError = collect()
    const second = await setup.toolbox.run({
      program: 'fd-echo',
      argv: ['in.txt', 'out-changed.txt'],
      onStdout: chunk => stdout.chunks.push(chunk),
      onStderr: chunk => secondError.chunks.push(chunk),
    })
    assert.equal(second.exitCode, 0, secondError.text())
    assert.equal(stdout.text(), '[in.txt] changed\n\n')
    assert.equal(await readFile(join(setup.workspace, 'out-changed.txt'), 'utf8'), 'echo:changed\n')

    const stderr = collect()
    const added = await setup.toolbox.run({
      program: 'fd-echo',
      argv: ['added.txt', 'copy.txt'],
      onStderr: chunk => stderr.chunks.push(chunk),
    })
    assert.equal(added.exitCode, 0, stderr.text())
    assert.equal(await readFile(join(setup.workspace, 'copy.txt'), 'utf8'), 'echo:added\n')
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: an unknown program answers 127', async () => {
  const setup = await fixture({ programs: [] })
  try {
    const stderr = collect()
    const result = await setup.toolbox.run({
      program: 'python3',
      onStderr: chunk => stderr.chunks.push(chunk),
    })
    assert.equal(result.exitCode, 127)
    assert.match(stderr.text(), /command not found/)
    assert.equal(setup.toolbox.has('python3'), false)
  } finally {
    await setup.cleanup()
  }
})

test('toolbox: aliases route to the canonical program', async () => {
  const setup = await fixture()
  try {
    setup.toolbox.register({
      program: 'fd-echo',
      aliases: ['fe', 'echo-fd'],
      module: { url: 'image://fd-echo.wasm', load: async () => moduleBytes },
    })
    assert.equal(setup.toolbox.get('fe')?.program, 'fd-echo')
    assert.equal(setup.toolbox.has('echo-fd'), true)
    const result = await setup.toolbox.run({ program: 'fe', argv: ['in.txt', 'alias.txt'] })
    assert.equal(result.exitCode, 0)
    assert.match(result.program, /fd-echo/)
  } finally {
    await setup.cleanup()
  }
})
