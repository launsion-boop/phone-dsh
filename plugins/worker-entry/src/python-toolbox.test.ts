// SPDX-License-Identifier: MIT
/**
 * G2-FIX-8 regression: the W7 CPython-on-WASI runtime must be wired into the
 * phone Worker at boot, not merely implemented as a library.
 *
 * Before the fix `startPhoneWorker` never constructed `PythonRuntime` and never
 * published a toolbox, so `getWorkerToolbox()` stayed undefined,
 * `createWorkerCommands()` registered no `python3`, and just-bash answered
 * `command not available in browser environments` (exit 127) for every Python
 * step. These tests drive the real boot path, the real shell command table and
 * the real toolbox dispatch with the checked-in `stub-python.wasm` fixture.
 * @module @phone-dsh/dsh-worker-entry/python-toolbox.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { getWorkerToolbox, MemoryVfsBackend, setWorkerToolbox, workerTransport } from '../../wasi-toolbox/src/index.ts'
import type { ToolWorkerTransport, WorkerLike } from '../../wasi-toolbox/src/index.ts'
import { createMemoryChannelPair, decodeUtf8, FrameType } from '../../channel/src/index.ts'
import { XlExecBridge } from '../../exec-bridge/src/index.ts'
import { createWorkerCommands, isWorkerShellProgram, VfsFileSystem, WorkerShell } from '../../shell-ext/src/index.ts'
import { XlSubprocessRuntime } from '../../subprocess-xl/src/index.ts'
import { MockChannel } from '../../tests/test-channel.ts'
import {
  startPhoneWorker,
  type PhoneWorkerHostLike,
  type PhoneWorkerOptions,
  type PhoneWorkerRuntime,
  type WorkerEntrySynthesize,
  type WorkerEntryVfs,
} from './entry.ts'
import {
  disposePythonToolbox,
  installPythonToolbox,
  PYTHON_MODULES_IMAGE_PATH,
  PYTHON_STDLIB_IMAGE_PATH,
  PYTHON_WASM_IMAGE_PATH,
  readPythonModuleProbe,
} from './python-toolbox.ts'
import { CAPABILITIES_JSON_PATH } from './capabilities.ts'
import { discoverJqArtifact } from '../../wasi-toolbox/jq/artifacts.ts'
import { JQ_ENGINE_IMAGE_PATH, JQ_WASM_IMAGE_PATH } from './jq-toolbox.ts'

const stubWasm = readFileSync(new URL('../../wasi-toolbox/python/testdata/stub-python.wasm', import.meta.url))
/** The stub never reads the zip; the toolbox only needs non-empty bytes. */
const stubStdlib = new Uint8Array(64)
const scratch: string[] = []

after(() => {
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
  setWorkerToolbox(undefined)
})

function scratchDir(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix))
  scratch.push(root)
  return root
}

/** The artifact slice of the mounted image: exactly the paths the packer writes. */
class ImageVfs implements WorkerEntryVfs {
  readonly files = new Map<string, Uint8Array>()

  subscribe(): () => void { return () => {} }

  async flush(): Promise<void> {}

  writeFileSync(path: string, data: string | Uint8Array): void {
    this.files.set(path, typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data))
  }

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

function spawnGenericWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../../wasi-toolbox/src/node-worker-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

function memoryBackend(): MemoryVfsBackend {
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/home')
  return backend
}

const testSynthesize: WorkerEntrySynthesize = (_request, sink) => {
  const res = {
    writeHead(): unknown { return res },
    write(): boolean { return true },
    end(): unknown { sink.end({ status: 200, headers: {}, body: new Uint8Array(0) }); return res },
    destroy(): void { sink.fail('destroyed') },
  }
  return {
    req: { method: 'GET', url: '/', headers: {}, async *[Symbol.asyncIterator](): AsyncGenerator<Uint8Array> {} },
    res,
    aborted: false,
    abort: () => { sink.fail('aborted') },
  }
}

interface BootInput {
  readonly options: PhoneWorkerOptions
  readonly pageMessages: unknown[]
  readonly hostConsole: () => readonly string[]
  readonly vfs: ImageVfs
}

/**
 * The exact `startPhoneWorker` inputs the page's init frame produces.
 * @param artifacts - python pair bytes and the optional staged modules.json.
 */
function bootInput(artifacts: {
  wasm?: Uint8Array
  stdlib?: Uint8Array
  modules?: string
  jqWasm?: Uint8Array
  jqEngine?: Uint8Array
} = {}): BootInput {
  const pair = createMemoryChannelPair({ autoConnect: true })
  const vfs = new ImageVfs()
  if (artifacts.wasm !== undefined) vfs.files.set(PYTHON_WASM_IMAGE_PATH, artifacts.wasm)
  if (artifacts.stdlib !== undefined) vfs.files.set(PYTHON_STDLIB_IMAGE_PATH, artifacts.stdlib)
  if (artifacts.modules !== undefined) vfs.files.set(PYTHON_MODULES_IMAGE_PATH, new TextEncoder().encode(artifacts.modules))
  if (artifacts.jqWasm !== undefined) vfs.files.set(JQ_WASM_IMAGE_PATH, artifacts.jqWasm)
  if (artifacts.jqEngine !== undefined) vfs.files.set(JQ_ENGINE_IMAGE_PATH, artifacts.jqEngine)
  const host: PhoneWorkerHostLike = {
    handleMessage: () => {},
    start: async () => {},
    vfs,
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: () => host,
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  const backend = memoryBackend()
  const pageMessages: unknown[] = []
  const consoleLines: string[] = []
  pair.host.onFrame((frame) => {
    if (frame.type !== FrameType.CONSOLE) return
    const line = JSON.parse(decodeUtf8(frame.payload)) as { text?: unknown }
    if (typeof line.text === 'string') consoleLines.push(line.text)
  })
  return {
    pageMessages,
    hostConsole: () => consoleLines,
    vfs,
    options: {
      channelURL: 'ws://127.0.0.1:1/channel',
      token: 'token',
      imageURL: 'image.tar.gz',
      runtime,
      python: { backend, spawnWorker: spawnPythonWorker },
      jq: { backend, spawnWorker: spawnGenericWorker },
      pagePost: (message) => { pageMessages.push(message) },
    },
  }
}

test('boot publishes python3 from the packed image artifacts and bash -c reaches the stub', { timeout: 30_000 }, async () => {
  const input = bootInput({ wasm: stubWasm, stdlib: stubStdlib })
  const handle = await startPhoneWorker(input.options)
  try {
    // The whole G2-A07 class: the toolbox must be installed before pdsh-ready,
    // because createWorkerCommands() reads it when the first command runs.
    const toolbox = getWorkerToolbox()
    assert.ok(toolbox !== undefined, 'startPhoneWorker must publish the toolbox before posting pdsh-ready')
    assert.equal(handle.python?.toolbox, toolbox)
    assert.equal(isWorkerShellProgram('python3'), true)
    assert.deepEqual(input.pageMessages.at(-1), { t: 'pdsh-ready' })

    const root = scratchDir('pdsh-python-boot-')
    mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root }),
      commands: createWorkerCommands({ git: false, curl: false }),
    })
    const result = await shell.run(['bash', '-c', 'python3 --version'], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.match(result.stdout, /^python3-stub\n/)
  } finally {
    await handle.stop()
  }
  assert.equal(getWorkerToolbox(), undefined, 'stop() releases the published toolbox')
})

test('boot fails loud when the image declares python3 but one artifact is missing', { timeout: 30_000 }, async () => {
  const input = bootInput({ wasm: stubWasm })
  await assert.rejects(startPhoneWorker(input.options), (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error)
    assert.match(message, /python313\.zip/, 'the missing half is named')
    assert.match(message, /build\.sh/, 'the failure says how to produce the artifacts')
    return true
  })
  assert.equal(getWorkerToolbox(), undefined)
  assert.ok(
    input.pageMessages.some(message => (message as { t?: unknown }).t === 'pdsh-error'),
    'the page sees the loud failure',
  )
})

test('an image with no python artifacts stays bootable and logs one visible line', { timeout: 30_000 }, async () => {
  const input = bootInput()
  const handle = await startPhoneWorker(input.options)
  try {
    assert.deepEqual(input.pageMessages.at(-1), { t: 'pdsh-ready' })
    assert.equal(getWorkerToolbox(), undefined)
    const notices = input.hostConsole().filter(text => /python3/.test(text))
    assert.equal(notices.length, 1, `expected exactly one visible notice, got ${JSON.stringify(notices)}`)
    assert.match(notices[0] as string, /python3 stays unavailable/)
  } finally {
    await handle.stop()
  }
})

test('readPythonModuleProbe validates the staged compression report', async () => {
  const vfs = new ImageVfs()
  vfs.files.set(PYTHON_MODULES_IMAGE_PATH, new TextEncoder().encode(JSON.stringify({
    python: '3.13',
    modules: ['json', 're', 'zlib'],
    compression: { modules: ['bz2', 'lzma'], tarfileGzip: false, zlibRuntime: '1.3.1' },
  })))
  const probe = await readPythonModuleProbe(vfs)
  assert.equal(probe?.version, '3.13')
  assert.deepEqual(probe?.modules, ['json', 're', 'zlib'])
  assert.deepEqual(probe?.compression, {
    modules: ['bz2', 'lzma'],
    tarfileGzip: false,
    zlibRuntime: '1.3.1',
  })

  // An image packed before the block existed reports no compression, not a
  // default "all linked".
  const oldImage = new ImageVfs()
  oldImage.files.set(PYTHON_MODULES_IMAGE_PATH, new TextEncoder().encode(JSON.stringify({ modules: ['json'] })))
  assert.equal((await readPythonModuleProbe(oldImage))?.compression, undefined)

  for (const compression of [
    { modules: 'zlib', tarfileGzip: true },
    { modules: [1], tarfileGzip: true },
    { modules: ['zlib'], tarfileGzip: 'yes' },
    { modules: ['zlib'], tarfileGzip: true, zlibRuntime: 131 },
  ]) {
    const broken = new ImageVfs()
    broken.files.set(PYTHON_MODULES_IMAGE_PATH, new TextEncoder().encode(JSON.stringify({
      modules: ['json'],
      compression,
    })))
    await assert.rejects(readPythonModuleProbe(broken), /compression/)
  }
})

test('the boot manifest compression is exactly the probe, and null without one', { timeout: 30_000 }, async () => {
  const modules = JSON.stringify({
    python: '3.13',
    // The ZIP carries zlib.py, but the interpreter probe says zlib is absent.
    modules: ['json', 're', 'zlib'],
    compression: { modules: ['bz2', 'lzma'], tarfileGzip: false, zlibRuntime: '1.3.1' },
  })
  const probed = bootInput({ wasm: stubWasm, stdlib: stubStdlib, modules })
  const probedHandle = await startPhoneWorker(probed.options)
  try {
    const manifest = JSON.parse(Buffer.from(probed.vfs.files.get(CAPABILITIES_JSON_PATH) ?? []).toString('utf8'))
    assert.deepEqual(manifest.python.compression, {
      zlib: false,
      bz2: true,
      lzma: true,
      tarfileGzip: false,
    })
    const agents = Buffer.from(probed.vfs.files.get('/dsh/home/AGENTS.md') ?? []).toString('utf8')
    assert.match(agents, /zlib no/)
    assert.doesNotMatch(agents, /zlib\/bz2\/lzma are linked/)
    assert.doesNotMatch(agents, /zlib yes/)
  } finally {
    await probedHandle.stop()
  }

  const unprobed = bootInput({ wasm: stubWasm, stdlib: stubStdlib })
  const unprobedHandle = await startPhoneWorker(unprobed.options)
  try {
    const manifest = JSON.parse(Buffer.from(unprobed.vfs.files.get(CAPABILITIES_JSON_PATH) ?? []).toString('utf8'))
    assert.equal(manifest.python.compression, null, 'no probe means "not reported", never true')
    const agents = Buffer.from(unprobed.vfs.files.get('/dsh/home/AGENTS.md') ?? []).toString('utf8')
    assert.match(agents, /not reported by the build probe/)
    assert.doesNotMatch(agents, /zlib\/bz2\/lzma are linked/)
    assert.doesNotMatch(agents, /zlib yes/)
  } finally {
    await unprobedHandle.stop()
  }
})

test('a direct spawn(["python3", ...]) dispatches to the same published toolbox', { timeout: 30_000 }, async () => {
  const vfs = new ImageVfs()
  vfs.files.set(PYTHON_WASM_IMAGE_PATH, stubWasm)
  vfs.files.set(PYTHON_STDLIB_IMAGE_PATH, stubStdlib)
  const wiring = await installPythonToolbox({ vfs, backend: memoryBackend(), spawnWorker: spawnPythonWorker })
  assert.ok(wiring !== undefined)
  const root = scratchDir('pdsh-python-spawn-')
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })

  const savedShell = process.env.PDSH_SHELL
  const savedRoot = process.env.PDSH_VFS_ROOT
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  const mock = new MockChannel({ caps: [], nextMseq: 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  try {
    assert.equal(isWorkerShellProgram('python3'), true)
    await ctx.plugin(XlExecBridge, {
      transport: 'channel',
      tokenEnv: 'PDSH_PYTHON_WIRING_UNUSED_TOKEN',
      tokenFileEnv: 'PDSH_PYTHON_WIRING_UNUSED_TOKEN_FILE',
      connectTimeoutMs: 1_000,
    })
    await ctx.plugin(XlSubprocessRuntime)
    const spec: SubprocessSpawnSpec = {
      argv: ['python3', '--version'],
      cwd: '/dsh/workspace',
      graceMs: 3_000,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    }
    const handle = (ctx.get('subprocess') as SubprocessRuntime).spawn(spec)
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    const stdout = handle.collected.stdout?.readFrom(0).text ?? ''
    assert.match(stdout, /^python3-stub\n/, 'the direct argv route used the toolbox, not node:child_process')
    // The stub prints the number of stdin bytes it drained; an empty stdin is 0.
    assert.match(stdout, /stdin-bytes=00000000/)
  } finally {
    await ctx.fiber.dispose()
    delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    await disposePythonToolbox(wiring)
    if (savedShell === undefined) delete process.env.PDSH_SHELL
    else process.env.PDSH_SHELL = savedShell
    if (savedRoot === undefined) delete process.env.PDSH_VFS_ROOT
    else process.env.PDSH_VFS_ROOT = savedRoot
  }
})

const jqArtifact = discoverJqArtifact()

test('boot publishes jq-wasi beside python3 and stop clears the composite toolbox', { skip: jqArtifact.skipReason, timeout: 60_000 }, async () => {
  const artifact = jqArtifact.artifact
  if (artifact === undefined) return
  const input = bootInput({
    wasm: stubWasm,
    stdlib: stubStdlib,
    jqWasm: readFileSync(artifact.wasm),
    jqEngine: readFileSync(artifact.engine),
  })
  const handle = await startPhoneWorker(input.options)
  try {
    const toolbox = getWorkerToolbox()
    assert.ok(toolbox !== undefined)
    assert.equal(handle.jq?.toolbox.has('jq-wasi'), true)
    assert.equal(toolbox.has('python3'), true, 'the composite still serves python3')
    assert.equal(toolbox.has('jq-wasi'), true, 'the composite serves the jq engine')
    const root = scratchDir('pdsh-jq-boot-')
    mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root }),
      commands: createWorkerCommands({ git: false, curl: false }),
    })
    const result = await shell.run(['bash', '-c', "jq -n -c '1+1'"], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stdout, '2\n')
    const manifest = JSON.parse(Buffer.from(input.vfs.files.get(CAPABILITIES_JSON_PATH) ?? []).toString('utf8'))
    assert.equal(manifest.jq?.available, true)
    assert.equal(manifest.jq?.program, 'jq-wasi')
    assert.match(manifest.jq?.engine ?? '', /jaq-core/u)
  } finally {
    await handle.stop()
  }
  assert.equal(getWorkerToolbox(), undefined, 'stop() clears the composite toolbox')
})
