// SPDX-License-Identifier: MIT
/**
 * G2-FIX-57 regression: a WASI interpreter invoked with its script on stdin
 * (`python3 - <<'PY'`) must receive those bytes, observe EOF, run, and exit
 * with its own status; a dispatch that cannot deliver the script must fail
 * fast with a structured error instead of holding the Worker command lane
 * until the 120 s shell timeout.
 *
 * The tests drive the production components: the just-bash `WorkerShell` with
 * `createWorkerCommands()`, the `WasiToolbox` command table, the real Node tool
 * worker harness, and the `XlSubprocessRuntime` dispatch/mutex. No model, no
 * WKWebView.
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import { createWorkerCommands, VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import {
  MemoryVfsBackend,
  NodeFsBackend,
  setWorkerToolbox,
  WasiToolbox,
  workerTransport,
  configureSingleFileLimit,
} from '../wasi-toolbox/src/index.ts'
import type {
  NodeFsPromisesLike,
  ToolWorkerTransport,
  VfsDirEntry,
  VfsStat,
  WorkerLike,
} from '../wasi-toolbox/src/index.ts'
import { PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import { MockChannel } from './test-channel.ts'

const stubWasm = readFileSync(new URL('../wasi-toolbox/python/testdata/stub-python.wasm', import.meta.url))
const stubStdlib = new Uint8Array(64)
const decoder = new TextDecoder()
const scratch: string[] = []
const SAVED_ENV = {
  PDSH_SHELL: process.env.PDSH_SHELL,
  PDSH_VFS_ROOT: process.env.PDSH_VFS_ROOT,
  PDSH_SHELL_STDIN_TIMEOUT_MS: process.env.PDSH_SHELL_STDIN_TIMEOUT_MS,
}

after(() => {
  setWorkerToolbox(undefined)
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
  restoreEnv()
})

function restoreEnv(): void {
  for (const [name, value] of Object.entries(SAVED_ENV)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
}

/** A VFS root with the three Worker mounts. */
function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-python-stdin-'))
  scratch.push(root)
  for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  return root
}

/** `node:fs/promises` over a real-directory VFS root with virtual absolute paths. */
function rootedPromises(root: string): NodeFsPromisesLike {
  const real = (path: string): string => `${root}${path}`
  return {
    stat: async path => fsPromises.stat(real(path)),
    lstat: async path => fsPromises.lstat(real(path)),
    readdir: async (path, options) => fsPromises.readdir(real(path), options),
    readFile: async path => fsPromises.readFile(real(path)),
    writeFile: async (path, data, options) => fsPromises.writeFile(real(path), data, options),
    mkdir: async (path, options) => fsPromises.mkdir(real(path), options),
    unlink: async path => fsPromises.unlink(real(path)),
    rm: async (path, options) => fsPromises.rm(real(path), options),
    rename: async (from, to) => fsPromises.rename(real(from), real(to)),
    truncate: async (path, length) => fsPromises.truncate(real(path), length),
    chmod: async (path, mode) => fsPromises.chmod(real(path), mode),
  }
}

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

interface ProductionShell {
  readonly root: string
  readonly shell: WorkerShell
  readonly runtime: PythonRuntime
  dispose(): Promise<void>
}

async function productionShell(options: {
  readonly wasm?: Uint8Array
  readonly stdlib?: Uint8Array
} = {}): Promise<ProductionShell> {
  // The tier default is 64 MiB; this file exercises the G2-A09 refusal shape
  // with the old 15 MiB bound so the over-limit write stays a few MiB, not 64.
  configureSingleFileLimit(15 * 1024 * 1024)
  const root = virtualRoot()
  const runtime = new PythonRuntime({
    wasm: options.wasm ?? stubWasm,
    stdlib: options.stdlib ?? stubStdlib,
    backend: new NodeFsBackend(rootedPromises(root)),
    preopens: [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
      { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
    ],
    cwd: '/dsh/workspace',
    crossOriginIsolated: true,
    spawnWorker: spawnPythonWorker,
    workerReadyTimeoutMs: 30_000,
  })
  runtime.installShellDispatch()
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createWorkerCommands({ git: false, curl: false }),
  })
  return {
    root,
    shell,
    runtime,
    async dispose() {
      await runtime.dispose()
      setWorkerToolbox(undefined)
    },
  }
}

/** Run a shell command, bounded so a wedged dispatch fails the test, not the run. */
async function boundedRun(shell: WorkerShell, script: string, timeoutMs = 30_000): Promise<{
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
  readonly elapsedMs: number
}> {
  const started = Date.now()
  const result = await Promise.race([
    shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' }),
    new Promise<never>((_resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`python3 stdin dispatch did not settle within ${timeoutMs} ms`))
      }, timeoutMs)
      timer.unref?.()
    }),
  ])
  return { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode, elapsedMs: Date.now() - started }
}

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

test('G2-FIX-57: a heredoc script is delivered to WASI stdin, drained to EOF and run', { timeout: 60_000 }, async () => {
  const setup = await productionShell()
  try {
    const script = "print('hello from heredoc')\n"
    const hex = script.length.toString(16).padStart(8, '0')
    const result = await boundedRun(setup.shell, `python3 - <<'PY'\n${script}PY\n`)
    assert.equal(result.exitCode, 0, result.stderr)
    assert.match(result.stdout, /^python3-stub\n/)
    // The stub drains fd 0 until WASI reports EOF and prints the exact number
    // of bytes it consumed: this fails (never settles) if the heredoc bytes or
    // the EOF marker do not reach the instance.
    assert.match(result.stdout, new RegExp(`stdin-bytes=${hex}\\n`))
    assert.equal(result.stderr, '')
    assert.ok(result.elapsedMs < 30_000, `settled in ${result.elapsedMs} ms`)
  } finally {
    await setup.dispose()
  }
})

test('G2-FIX-57: piped input reaches stdin and EOF terminates the interpreter', { timeout: 60_000 }, async () => {
  const setup = await productionShell()
  try {
    const result = await boundedRun(setup.shell, "printf 'a\\nb\\n' | python3 -c pass")
    assert.equal(result.exitCode, 0, result.stderr)
    assert.match(result.stdout, /stdin-bytes=00000004\n/)

    const empty = await boundedRun(setup.shell, 'python3 -c pass')
    assert.equal(empty.exitCode, 0, empty.stderr)
    assert.match(empty.stdout, /stdin-bytes=00000000\n/)
  } finally {
    await setup.dispose()
  }
})

test('G2-FIX-57: CPython reads a heredoc, writes the file and exits with its own status', {
  timeout: 120_000,
}, async (t) => {
  const artifacts = pythonArtifacts()
  if (artifacts === undefined) {
    t.skip('set PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB or build into $TMPDIR/pdsh-python-wasi to run real CPython')
    return
  }
  const setup = await productionShell(artifacts)
  try {
    const script = [
      'from pathlib import Path',
      "target = Path('/dsh/workspace/testdata.bin')",
      "target.write_bytes(b'x' * 1024)",
      "print('created', target.stat().st_size)",
      '',
    ].join('\n')
    const result = await boundedRun(setup.shell, `python3 - <<'PY'\n${script}PY\n`)
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stdout, 'created 1024\n')
    assert.equal(result.elapsedMs < 30_000, true, `heredoc settled in ${result.elapsedMs} ms`)
    assert.equal(statSync(join(setup.root, 'dsh/workspace/testdata.bin')).size, 1024)

    // The interpreter's real exit status, not the toolbox's or the shell's.
    const failing = await boundedRun(setup.shell, "python3 - <<'PY'\nraise SystemExit(7)\nPY\n")
    assert.equal(failing.exitCode, 7, failing.stderr)

    // Stdin EOF: a program that drains all of stdin must terminate, and see
    // exactly the bytes the shell piped into it.
    const eof = await boundedRun(
      setup.shell,
      "printf 'first\\nsecond\\n' | python3 -c \"import sys; data = sys.stdin.buffer.read(); print(len(data), data.count(b'\\n'))\"",
    )
    assert.equal(eof.exitCode, 0, eof.stderr)
    assert.equal(eof.stdout, '13 2\n')
  } finally {
    await setup.dispose()
  }
})

test('G2-FIX-57: G2-A09 shape — a heredoc 16 MiB write is refused fast and the next heredoc still runs', {
  timeout: 120_000,
}, async (t) => {
  const artifacts = pythonArtifacts()
  if (artifacts === undefined) {
    t.skip('set PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB or build into $TMPDIR/pdsh-python-wasi to run real CPython')
    return
  }
  const setup = await productionShell(artifacts)
  try {
    const target = join(setup.root, 'dsh/workspace/testdata.bin')
    const oversized = await boundedRun(setup.shell, [
      "python3 - <<'PY'",
      'from pathlib import Path',
      "Path('/dsh/workspace/testdata.bin').write_bytes(b'x' * (16 * 1024 * 1024))",
      'PY',
      '',
    ].join('\n'))
    assert.notEqual(oversized.exitCode, 0, 'the 16 MiB single-file write must be refused')
    assert.match(oversized.stderr, /EFBIG|file too large|limited to 15 MiB|would be \d+ bytes/i)
    assert.ok(oversized.elapsedMs < 30_000, `refusal settled in ${oversized.elapsedMs} ms`)
    assert.equal(existsSync(target) && statSync(target).size > 15 * 1024 * 1024, false)
    if (existsSync(target)) {
      rmSync(target)
    }

    // The refusal must not wedge the interpreter or the command lane: the very
    // next heredoc dispatch runs and produces both parts (DESIGN: split the
    // 16 MiB into two files under the 15 MiB limit).
    const parts = await boundedRun(setup.shell, [
      "python3 - <<'PY'",
      'from pathlib import Path',
      "Path('/dsh/workspace/part1.bin').write_bytes(b'a' * (8 * 1024 * 1024))",
      "Path('/dsh/workspace/part2.bin').write_bytes(b'b' * (8 * 1024 * 1024))",
      "print('parts done')",
      'PY',
      '',
    ].join('\n'))
    assert.equal(parts.exitCode, 0, parts.stderr)
    assert.equal(parts.stdout, 'parts done\n')
    assert.equal(parts.elapsedMs < 30_000, true, `follow-up heredoc settled in ${parts.elapsedMs} ms`)
    assert.equal(statSync(join(setup.root, 'dsh/workspace/part1.bin')).size, 8 * 1024 * 1024)
    assert.equal(statSync(join(setup.root, 'dsh/workspace/part2.bin')).size, 8 * 1024 * 1024)
    assert.equal(existsSync(target), false)
  } finally {
    await setup.dispose()
  }
})

/**
 * A tool worker test double for the observed G2-A09 hang shapes: it answers
 * `init` with `ready`, and can either go silent at `exec` (a wedged worker) or
 * acknowledge the exec but never read stdin (a worker that started without the
 * delivered script).
 */
class ScriptWorker {
  readonly received: unknown[] = []
  terminated = false
  private readonly listeners = new Set<(message: unknown) => void>()
  private readonly acknowledgeExec: boolean
  private readonly readStdin: boolean
  private readonly assembledStdinBytes: number | undefined

  constructor(options: {
    readonly acknowledgeExec?: boolean
    readonly readStdin?: boolean
    /** Report this count instead of the bytes the exec named (truncation shape). */
    readonly assembledStdinBytes?: number
  } = {}) {
    this.acknowledgeExec = options.acknowledgeExec === true
    this.readStdin = options.readStdin === true
    this.assembledStdinBytes = options.assembledStdinBytes
  }

  readonly transport: ToolWorkerTransport = {
    postMessage: message => this.receive(message),
    onMessage: handler => {
      this.listeners.add(handler)
      return () => { this.listeners.delete(handler) }
    },
    onError: () => () => {},
    terminate: () => { this.terminated = true },
  }

  private receive(message: unknown): void {
    this.received.push(message)
    if (typeof message !== 'object' || message === null) return
    const record = message as { type?: unknown; id?: unknown; program?: unknown; stdinBytes?: unknown }
    if (record.type === 'init') {
      queueMicrotask(() => { this.emit({ type: 'ready', program: record.program }) })
      return
    }
    if (record.type !== 'exec' || !this.acknowledgeExec) return
    queueMicrotask(() => {
      this.emit({
        type: 'exec-started',
        id: record.id,
        stdinBytes: this.assembledStdinBytes ?? record.stdinBytes,
      })
      if (this.readStdin) this.emit({ type: 'stdin-read', id: record.id })
    })
  }

  private emit(message: unknown): void {
    for (const listener of [...this.listeners]) listener(message)
  }
}

/** Run one toolbox dispatch, bounded so a hang fails the test. */
async function boundedDispatch(toolbox: WasiToolbox, request: Parameters<WasiToolbox['run']>[0], timeoutMs: number): Promise<{
  readonly result?: Awaited<ReturnType<WasiToolbox['run']>>
  readonly stderr: string
  readonly elapsedMs: number
}> {
  const stderr: Uint8Array[] = []
  const started = Date.now()
  const result = await Promise.race([
    toolbox.run({ ...request, onStderr: chunk => { stderr.push(chunk) } }),
    new Promise<undefined>(resolve => {
      const timer = setTimeout(() => { resolve(undefined) }, timeoutMs)
      timer.unref?.()
    }),
  ])
  return {
    ...(result === undefined ? {} : { result }),
    stderr: decoder.decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk)))),
    elapsedMs: Date.now() - started,
  }
}

test('G2-FIX-57: a python3 - heredoc dispatch that never acknowledges the exec fails fast', {
  timeout: 30_000,
}, async () => {
  const wedged = new ScriptWorker()
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: new WebAssembly.Module(stubWasm),
      scriptFromStdin: argv => argv[0] === '-',
      description: 'wedged-dispatch test double',
    }],
    backend: new MemoryVfsBackend(),
    crossOriginIsolated: false,
    spawnWorker: () => wedged.transport,
    workerReadyTimeoutMs: 5_000,
    execStartTimeoutMs: 250,
    stdinReadTimeoutMs: 250,
  })
  try {
    const script = new TextEncoder().encode("print('never')\n")
    const outcome = await boundedDispatch(toolbox, { program: 'python3', argv: ['-'], stdin: script }, 5_000)
    assert.ok(outcome.result !== undefined, 'the dispatch must settle instead of hanging')
    assert.equal(outcome.result.exitCode, 134)
    assert.equal(outcome.result.failureCode, 'E_EXEC_START_TIMEOUT')
    assert.match(outcome.stderr, /did not acknowledge the exec within 250 ms/)
    assert.match(outcome.stderr, /stdin delivery could not be confirmed/)
    assert.match(outcome.stderr, /\[E_EXEC_START_TIMEOUT\]/)
    assert.equal(wedged.terminated, true, 'the wedged tool worker is terminated so the next dispatch can retry')

    // The host owns stdin delivery: bounded frames with one explicit EOF
    // marker precede the exec that names the delivery.
    const frames = wedged.received.filter(message => (message as { type?: unknown }).type === 'stdin')
    assert.equal(frames.length, 1)
    assert.deepEqual(
      { eof: (frames[0] as { eof?: unknown }).eof, bytes: (frames[0] as { data?: Uint8Array }).data?.byteLength },
      { eof: true, bytes: script.byteLength },
    )
    const exec = wedged.received.find(message => (message as { type?: unknown }).type === 'exec') as
      | { stdinBytes?: number; stdinEof?: boolean; stdin?: unknown }
      | undefined
    assert.deepEqual(exec === undefined ? undefined : { stdinBytes: exec.stdinBytes, stdinEof: exec.stdinEof, stdin: exec.stdin },
      { stdinBytes: script.byteLength, stdinEof: true, stdin: undefined })
  } finally {
    await toolbox.dispose()
  }
})

test('G2-FIX-57: a python3 - heredoc whose script the interpreter never reads fails fast', {
  timeout: 30_000,
}, async () => {
  const silent = new ScriptWorker({ acknowledgeExec: true, readStdin: false })
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: new WebAssembly.Module(stubWasm),
      scriptFromStdin: argv => argv[0] === '-',
    }],
    backend: new MemoryVfsBackend(),
    crossOriginIsolated: false,
    spawnWorker: () => silent.transport,
    workerReadyTimeoutMs: 5_000,
    execStartTimeoutMs: 1_000,
    stdinReadTimeoutMs: 250,
  })
  try {
    const outcome = await boundedDispatch(toolbox, {
      program: 'python3',
      argv: ['-'],
      stdin: new TextEncoder().encode("print('never')\n"),
    }, 5_000)
    assert.ok(outcome.result !== undefined, 'the dispatch must settle instead of hanging')
    assert.equal(outcome.result.exitCode, 134)
    assert.equal(outcome.result.failureCode, 'E_STDIN_READ_TIMEOUT')
    assert.match(outcome.stderr, /did not read its script from stdin within 250 ms/)
    assert.match(outcome.stderr, /refusing to hold the Worker command lane/)
    assert.match(outcome.stderr, /\[E_STDIN_READ_TIMEOUT\]/)
    assert.equal(silent.terminated, true)
  } finally {
    await toolbox.dispose()
  }
})

test('G2-FIX-57: a tool worker that assembled fewer stdin bytes than delivered fails fast', {
  timeout: 30_000,
}, async () => {
  // The dispatch delivered N bytes; the worker reports it assembled none. That
  // is the "script bytes never reached the instance stdin" shape and must be a
  // structured failure, never a silent empty-script run or a 120 s hang.
  const truncated = new ScriptWorker({ acknowledgeExec: true, readStdin: true, assembledStdinBytes: 0 })
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: new WebAssembly.Module(stubWasm),
      scriptFromStdin: argv => argv[0] === '-',
    }],
    backend: new MemoryVfsBackend(),
    crossOriginIsolated: false,
    spawnWorker: () => truncated.transport,
    workerReadyTimeoutMs: 5_000,
    execStartTimeoutMs: 1_000,
    stdinReadTimeoutMs: 1_000,
  })
  try {
    const outcome = await boundedDispatch(toolbox, {
      program: 'python3',
      argv: ['-'],
      stdin: new TextEncoder().encode("print('never')\n"),
    }, 5_000)
    assert.ok(outcome.result !== undefined, 'the dispatch must settle instead of hanging')
    assert.equal(outcome.result.exitCode, 134)
    assert.equal(outcome.result.failureCode, 'E_STDIN_INCOMPLETE')
    assert.match(outcome.stderr, /assembled 0 stdin bytes but the dispatch delivered 15/)
    assert.match(outcome.stderr, /\[E_STDIN_INCOMPLETE\]/)
    assert.equal(truncated.terminated, true)
  } finally {
    await toolbox.dispose()
  }
})

test('G2-FIX-57: an oversized stdin payload is refused before a worker is acquired', { timeout: 10_000 }, async () => {
  let spawned = 0
  const toolbox = new WasiToolbox({
    commands: [{ program: 'python3', module: new WebAssembly.Module(stubWasm) }],
    backend: new MemoryVfsBackend(),
    crossOriginIsolated: false,
    spawnWorker: () => { spawned += 1; return new ScriptWorker().transport },
  })
  try {
    const outcome = await boundedDispatch(toolbox, {
      program: 'python3',
      argv: ['-'],
      stdin: new Uint8Array(16 * 1024 * 1024 + 1),
    }, 5_000)
    assert.ok(outcome.result !== undefined)
    assert.equal(outcome.result.exitCode, 134)
    assert.equal(outcome.result.failureCode, 'E_STDIN_OVERSIZE')
    assert.match(outcome.stderr, /dispatch limit is 16777216 bytes/)
    assert.match(outcome.stderr, /\[E_STDIN_OVERSIZE\]/)
    assert.equal(spawned, 0, 'the refusal happens before the tool worker spawns')
  } finally {
    await toolbox.dispose()
  }
})

interface DispatchHarness {
  readonly ctx: Context
  readonly subprocess: SubprocessRuntime
  dispose(): Promise<void>
}

async function dispatchHarness(root: string): Promise<DispatchHarness> {
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  const mock = new MockChannel({ caps: [], nextMseq: 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_STDIN_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_STDIN_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1_000,
  })
  await ctx.plugin(XlSubprocessRuntime)
  return {
    ctx,
    subprocess: ctx.get('subprocess') as SubprocessRuntime,
    async dispose() {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
      restoreEnv()
    },
  }
}

const collect = { maxBytes: 64 * 1024 }

function spec(cwd: string, argv: string[], extra: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec {
  return { argv, cwd, graceMs: 3_000, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra }
}

test('G2-FIX-57: an unrelated bash command completes while a wedged python3 heredoc is bounded', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const wedged = new ScriptWorker()
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: new WebAssembly.Module(stubWasm),
      scriptFromStdin: argv => argv[0] === '-',
    }],
    backend: new MemoryVfsBackend(),
    crossOriginIsolated: false,
    spawnWorker: () => wedged.transport,
    workerReadyTimeoutMs: 5_000,
    execStartTimeoutMs: 300,
    stdinReadTimeoutMs: 300,
  })
  setWorkerToolbox(toolbox)
  const h = await dispatchHarness(root)
  try {
    const started = Date.now()
    const python = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', "python3 - <<'PY'\nprint('never')\nPY\n",
    ]))
    // Let the first command take the per-workspace slot and wedge.
    await new Promise(resolve => setTimeout(resolve, 100))
    const live = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo lane-alive']))
    const liveOutcome = await Promise.race([
      live.done,
      new Promise<undefined>(resolve => {
        const timer = setTimeout(() => { resolve(undefined) }, 10_000)
        timer.unref?.()
      }),
    ])
    assert.ok(liveOutcome !== undefined, 'the unrelated bash command must not wait for the wedged job')
    assert.deepEqual(liveOutcome, { exitCode: 0, signal: null })
    assert.equal(live.collected.stdout?.readFrom(0).text, 'lane-alive\n')

    assert.deepEqual(await python.done, { exitCode: 134, signal: null })
    const stderr = python.collected.stderr?.readFrom(0).text ?? ''
    assert.match(stderr, /did not acknowledge the exec within 300 ms/)
    assert.ok(Date.now() - started < 10_000, 'the lane recovered long before the 120 s shell timeout')
  } finally {
    await h.dispose()
    await toolbox.dispose()
    setWorkerToolbox(undefined)
  }
})

test('G2-FIX-57: a piped command whose stdin never reaches EOF fails fast with a structured error', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const h = await dispatchHarness(root)
  try {
    process.env.PDSH_SHELL_STDIN_TIMEOUT_MS = '200'
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'cat'], {
      stdio: { stdin: 'pipe', stdout: collect, stderr: collect },
    }))
    const started = Date.now()
    await assert.rejects(
      Promise.race([
        handle.done,
        new Promise<never>((_resolve, reject) => {
          const timer = setTimeout(() => { reject(new Error('the handle never settled')) }, 5_000)
          timer.unref?.()
        }),
      ]),
      (error: unknown) => {
        const failure = error as { code?: string; message?: string }
        assert.equal(failure.code, 'E_STDIN_EOF_TIMEOUT')
        assert.match(String(failure.message), /stdin was not closed within 200 ms/)
        return true
      },
    )
    assert.ok(Date.now() - started < 5_000, 'no EOF must not mean no settlement')
  } finally {
    await h.dispose()
  }
})
