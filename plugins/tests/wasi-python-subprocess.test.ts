// SPDX-License-Identifier: MIT
/**
 * G2-FIX-78 regression: CPython on the WASI toolbox must serve Python's
 * `subprocess` family.
 *
 * WASI preview1 has no process model, so before this fix any `subprocess.run`
 * inside the Worker interpreter raised `OSError [Errno 58] wasi does not
 * support processes`; a `python3 -m unittest` suite whose tests drive their own
 * CLI turned into one ERROR per test and exit 1. The toolbox's only available
 * mechanism is a nested interpreter instance with piped stdio on the same tool
 * worker and VFS, which `wasi-toolbox/python/subprocess-shim.ts` wires through
 * the `/__xl__/spawn` control descriptor.
 *
 * The tests drive the production components end to end: the real
 * `PythonRuntime`/`WasiToolbox` dispatch, the Node tool-worker harness, the
 * real CPython wasm artifact when this machine has one (same discovery rule as
 * the other real-CPython tests), the synchronous VFS proxy and the snapshot
 * fallback. No model, no WKWebView.
 *
 * Run directly with:
 * `node --test plugins/tests/wasi-python-subprocess.test.mjs`
 * @module @phone-dsh/dsh-tests/wasi-python-subprocess
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { MemoryWasiVfs } from '../wasi-toolbox/src/memory-wasi-vfs.ts'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { NodeFsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import type { NodeFsPromisesLike } from '../wasi-toolbox/src/vfs-backends.ts'
import {
  createSpawnBridge, MAX_SPAWN_STDIO_BYTES, SPAWN_FRAME_PREFIX_BYTES, SpawnBridgeError,
  spawnProgramTable, PDSH_SPAWN_GUEST_PATH, PDSH_SPAWN_GUEST_ROOT,
} from '../wasi-toolbox/src/spawn-bridge.ts'
import type { SpawnExecRequest, SpawnExecResult } from '../wasi-toolbox/src/spawn-bridge.ts'
import { PYTHON_STDLIB_GUEST_PATH, PYTHON_STDLIB_HOST_ROOT, PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import { createPythonVfs } from '../wasi-toolbox/python/python-worker-runtime.ts'
import { PDSH_HTTP_GUEST_PATH } from '../wasi-toolbox/src/http-bridge.ts'
import {
  PYTHON_HTTP_SHIM_FILENAME, PYTHON_HTTP_SHIM_SOURCE,
} from '../wasi-toolbox/python/http-shim.ts'
import {
  PYTHON_SHIM_ROOT, PYTHON_SUBPROCESS_MODULE_FILENAME, PYTHON_SUBPROCESS_MODULE_SOURCE,
  PYTHON_SUBPROCESS_SHIM_FILENAME, PYTHON_SUBPROCESS_SHIM_SOURCE, withPythonShims,
} from '../wasi-toolbox/python/subprocess-shim.ts'

const decoder = new TextDecoder()
const scratch: string[] = []

after(() => {
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
})

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
const NO_ARTIFACTS = artifacts === undefined
  ? 'set PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB or build into $TMPDIR/pdsh-python-wasi to run real CPython'
  : false

/** A VFS root mirroring the three Worker mounts. */
function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-python-subprocess-'))
  scratch.push(root)
  for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  return root
}

/** `node:fs/promises` over a real-directory VFS root with virtual absolute paths. */
function rootedPromises(root: string, writes: string[]): NodeFsPromisesLike {
  const real = (path: string): string => `${root}${path}`
  return {
    stat: async path => fsPromises.stat(real(path)),
    lstat: async path => fsPromises.lstat(real(path)),
    readdir: async (path, options) => fsPromises.readdir(real(path), options),
    readFile: async path => fsPromises.readFile(real(path)),
    writeFile: async (path, data, options) => {
      writes.push(path)
      await fsPromises.writeFile(real(path), data, options)
    },
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

interface Fixture {
  readonly root: string
  readonly workspace: string
  readonly runtime: PythonRuntime
  readonly writes: string[]
  readonly flushes: { count: number }
  cleanup(): Promise<void>
}

function fixture(options: { readonly crossOriginIsolated?: boolean } = {}): Fixture {
  const root = virtualRoot()
  const workspace = join(root, 'dsh/workspace')
  const writes: string[] = []
  const flushes = { count: 0 }
  const backend = new NodeFsBackend(rootedPromises(root, writes), {
    // The durability fence `WasiToolbox` calls before it reports a python
    // command as complete (G2-FIX-61).
    flush: () => { flushes.count += 1 },
  })
  const runtime = new PythonRuntime({
    wasm: artifacts?.wasm ?? new Uint8Array(0),
    stdlib: artifacts?.stdlib ?? new Uint8Array(0),
    backend,
    preopens: [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
      { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
    ],
    cwd: '/dsh/workspace',
    crossOriginIsolated: options.crossOriginIsolated ?? true,
    spawnWorker: spawnPythonWorker,
    workerReadyTimeoutMs: 30_000,
  })
  return {
    root,
    workspace,
    runtime,
    writes,
    flushes,
    async cleanup() {
      await runtime.dispose()
      rmSync(root, { recursive: true, force: true })
    },
  }
}

interface RunOutcome {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

/** Run one python3 invocation through the real toolbox dispatch. */
async function runPython(
  runtime: PythonRuntime,
  argv: readonly string[],
  stdin?: Uint8Array,
): Promise<RunOutcome> {
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  const result = await runtime.run({
    program: 'python3',
    argv,
    ...(stdin === undefined ? {} : { stdin }),
    onStdout: chunk => { stdout.push(chunk) },
    onStderr: chunk => { stderr.push(chunk) },
  })
  return {
    exitCode: result.exitCode,
    stdout: decoder.decode(Buffer.concat(stdout.map(chunk => Buffer.from(chunk)))),
    stderr: decoder.decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk)))),
  }
}

// --------------------------------------------------------------- host bridge

/** Encode one request frame the way the Python shim does. */
function requestFrame(header: Record<string, unknown>, payload = new Uint8Array(0)): Uint8Array {
  const headerBytes = new TextEncoder().encode(JSON.stringify(header))
  const frame = new Uint8Array(SPAWN_FRAME_PREFIX_BYTES + headerBytes.byteLength + payload.byteLength)
  const view = new DataView(frame.buffer)
  view.setUint32(0, headerBytes.byteLength, true)
  view.setUint32(4, payload.byteLength, true)
  frame.set(headerBytes, SPAWN_FRAME_PREFIX_BYTES)
  frame.set(payload, SPAWN_FRAME_PREFIX_BYTES + headerBytes.byteLength)
  return frame
}

/** Decode one response frame the way the Python shim does. */
function responseFrame(frame: Uint8Array): {
  readonly header: Record<string, unknown>
  readonly stdout: Uint8Array
  readonly stderr: Uint8Array
} {
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  const headerLength = view.getUint32(0, true)
  const header = JSON.parse(decoder.decode(frame.subarray(4, 4 + headerLength))) as Record<string, unknown>
  const stdoutBytes = Number(header.stdoutBytes ?? 0)
  const stderrBytes = Number(header.stderrBytes ?? 0)
  const stdout = frame.subarray(4 + headerLength, 4 + headerLength + stdoutBytes)
  const stderr = frame.subarray(4 + headerLength + stdoutBytes, 4 + headerLength + stdoutBytes + stderrBytes)
  return { header, stdout, stderr }
}

test('spawn bridge: the programs operation reports the toolbox alias table', () => {
  const bridge = createSpawnBridge({
    table: spawnProgramTable('python3', [
      { program: 'python3', aliases: ['python'] },
      { program: 'git' },
    ]),
    run: () => ({ exitCode: 0, stdout: new Uint8Array(0), stderr: new Uint8Array(0) }),
  })
  const response = responseFrame(bridge.dispatch(requestFrame({ op: 'programs' })))
  assert.equal(response.header.op, 'programs')
  assert.equal(response.header.interpreter, 'python3')
  assert.deepEqual(response.header.aliases, ['python'])
  assert.deepEqual(response.header.programs, ['python3', 'python'])
  assert.deepEqual(response.header.toolboxPrograms, ['python3', 'git'])
  assert.equal(bridge.guestPath, PDSH_SPAWN_GUEST_PATH)
  assert.equal(bridge.guestRoot, PDSH_SPAWN_GUEST_ROOT)
})

test('spawn bridge: an exec frame runs the nested instance and frames binary stdio', () => {
  const seen: SpawnExecRequest[] = []
  const bridge = createSpawnBridge({
    table: spawnProgramTable('python3', [{ program: 'python3', aliases: ['python'] }]),
    run: request => {
      seen.push(request)
      return {
        exitCode: 7,
        stdout: new Uint8Array([0, 1, 2, 255]),
        stderr: new TextEncoder().encode('boom\n'),
      }
    },
  })
  const stdin = new TextEncoder().encode('input\u0000bytes')
  const response = responseFrame(bridge.dispatch(requestFrame({
    op: 'exec',
    argv: ['-c', 'print(1)'],
    env: { A: '1' },
    cwd: '/dsh/workspace',
    stdinBytes: stdin.byteLength,
  }, stdin)))
  assert.equal(seen.length, 1)
  assert.deepEqual(seen[0]?.argv, ['-c', 'print(1)'])
  assert.deepEqual(seen[0]?.env, { A: '1' })
  assert.equal(seen[0]?.cwd, '/dsh/workspace')
  assert.deepEqual([...seen[0]!.stdin], [...stdin])
  assert.equal(response.header.code, 7)
  assert.deepEqual([...response.stdout], [0, 1, 2, 255])
  assert.equal(decoder.decode(response.stderr), 'boom\n')

  // A bare interpreter (no argv) is valid: it reads its program from stdin.
  const bare = responseFrame(bridge.dispatch(requestFrame({ op: 'exec', argv: [] })))
  assert.equal(bare.header.code, 7)
  assert.deepEqual(seen[1]?.argv, [])
})

test('spawn bridge: legacy timeout requests are refused before child execution', () => {
  let executions = 0
  const bridge = createSpawnBridge({
    table: spawnProgramTable('python3', [{ program: 'python3' }]),
    run: () => {
      executions += 1
      return { exitCode: 0, stdout: new Uint8Array(0), stderr: new Uint8Array(0) }
    },
  })
  const response = responseFrame(bridge.dispatch(requestFrame({ op: 'exec', argv: [], timeoutMs: 1 })))
  assert.equal(executions, 0)
  assert.equal((response.header.error as { kind?: unknown }).kind, 'protocol')
  assert.match(String((response.header.error as { message?: unknown }).message), /timeoutMs is unsupported/)
})

test('spawn bridge: malformed requests and refusals come back as loud errors', () => {
  const bridge = createSpawnBridge({
    table: spawnProgramTable('python3', [{ program: 'python3', aliases: ['python'] }]),
    run: request => {
      if (request.argv[0] === '--too-deep') throw new SpawnBridgeError('depth', 'nesting depth exceeded')
      return { exitCode: 0, stdout: new Uint8Array(0), stderr: new Uint8Array(0) }
    },
  })
  const truncated = responseFrame(bridge.dispatch(new Uint8Array([1, 2, 3])))
  assert.equal((truncated.header.error as { kind?: unknown }).kind, 'protocol')

  const mismatch = requestFrame({ op: 'exec', argv: ['-c', 'x'], stdinBytes: 5 })
  const mismatchResponse = responseFrame(bridge.dispatch(mismatch))
  assert.equal((mismatchResponse.header.error as { kind?: unknown }).kind, 'protocol')

  const unknown = responseFrame(bridge.dispatch(requestFrame({ op: 'nope' })))
  assert.equal((unknown.header.error as { kind?: unknown }).kind, 'protocol')

  const depth = responseFrame(bridge.dispatch(requestFrame({ op: 'exec', argv: ['--too-deep'] })))
  assert.equal((depth.header.error as { kind?: unknown }).kind, 'depth')
  assert.match(String((depth.header.error as { message?: unknown }).message), /nesting depth exceeded/)

  const huge = createSpawnBridge({
    table: spawnProgramTable('python3', [{ program: 'python3' }]),
    run: (): SpawnExecResult => ({
      exitCode: 0,
      stdout: new Uint8Array(MAX_SPAWN_STDIO_BYTES + 1),
      stderr: new Uint8Array(0),
    }),
  })
  const limited = responseFrame(huge.dispatch(requestFrame({ op: 'exec', argv: ['-c', 'x'] })))
  assert.equal((limited.header.error as { kind?: unknown }).kind, 'output-limit')
})

// ------------------------------------------------------------- shim mounting

test('python: the subprocess shim is one read-only layer ahead of the stdlib zip', () => {
  const bundle = createPythonVfs({
    writable: new MemoryWasiVfs(),
    stdlib: {
      stdlibZip: new Uint8Array([0x50, 0x4b, 0x03, 0x04]),
      guestPath: PYTHON_STDLIB_GUEST_PATH,
      hostRoot: PYTHON_STDLIB_HOST_ROOT,
    },
  })
  assert.deepEqual(
    bundle.vfs.readdir(PYTHON_SHIM_ROOT).map(entry => entry.name).sort(),
    [PYTHON_SUBPROCESS_MODULE_FILENAME, PYTHON_SUBPROCESS_SHIM_FILENAME, PYTHON_HTTP_SHIM_FILENAME].sort(),
  )
  const read = (name: string, length: number): string => decoder.decode(
    bundle.vfs.read(`${PYTHON_SHIM_ROOT}/${name}`, 0, length),
  )
  const moduleSource = PYTHON_SUBPROCESS_MODULE_SOURCE.replaceAll('__PDSH_SPAWN_PATH__', PDSH_SPAWN_GUEST_PATH)
  assert.equal(read(PYTHON_SUBPROCESS_SHIM_FILENAME, PYTHON_SUBPROCESS_SHIM_SOURCE.length), PYTHON_SUBPROCESS_SHIM_SOURCE)
  assert.equal(read(PYTHON_SUBPROCESS_MODULE_FILENAME, moduleSource.length), moduleSource)
  const httpSource = PYTHON_HTTP_SHIM_SOURCE.replaceAll('__PDSH_HTTP_PATH__', PDSH_HTTP_GUEST_PATH)
  assert.equal(read(PYTHON_HTTP_SHIM_FILENAME, httpSource.length), httpSource)
  assert.match(PYTHON_SUBPROCESS_SHIM_SOURCE, /sys\.modules\["subprocess"\] = _real/)
  assert.match(moduleSource, /_resolve_program/)
  assert.match(moduleSource, /available programs/)
  assert.throws(
    () => bundle.vfs.write(`${PYTHON_SHIM_ROOT}/${PYTHON_SUBPROCESS_SHIM_FILENAME}`, 0, new Uint8Array([1]), {
      append: false,
      create: false,
    }),
    /read-only/,
  )
  // The mounted stdlib listing is unchanged: the shim lives outside that tree.
  assert.deepEqual(bundle.vfs.readdir(PYTHON_STDLIB_HOST_ROOT).map(entry => entry.name), ['python-cwd', 'python313.zip'])
  assert.deepEqual(bundle.subprocessPreopen, { guestPath: PYTHON_SHIM_ROOT, hostPath: PYTHON_SHIM_ROOT })
  assert.deepEqual(bundle.spawnPreopen, { guestPath: PDSH_SPAWN_GUEST_ROOT, hostPath: '/pdsh-spawn' })

  const env = withPythonShims({ PYTHONPATH: '/caller/dir' }, {
    stdlibZip: PYTHON_STDLIB_GUEST_PATH,
    cwdShimDir: '/usr/local/lib/python-cwd',
  })
  assert.equal(
    env.PYTHONPATH,
    `${PYTHON_SHIM_ROOT}:${PYTHON_STDLIB_GUEST_PATH}:/usr/local/lib/python-cwd:/caller/dir`,
  )
})

// ------------------------------------------------------------ real CPython

test('python: subprocess.run([sys.executable, "-c", ...]) with capture_output and exit propagation', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
r = subprocess.run([sys.executable, "-c", "print('child-out')"], capture_output=True, text=True)
print("capture", r.returncode, repr(r.stdout), repr(r.stderr))
r = subprocess.run([sys.executable, "-c", "import sys; sys.exit(7)"], capture_output=True, text=True)
print("exit", r.returncode, repr(r.stdout), repr(r.stderr))
r = subprocess.run([sys.executable, "-c", "print('bytes')"], capture_output=True)
print("bytes", r.returncode, repr(r.stdout))
print("call", subprocess.call([sys.executable, "-c", "raise SystemExit(9)"]))
print("check_output", repr(subprocess.check_output([sys.executable, "-c", "print('checked')"], text=True)))
open("child_script.py", "w").write("print('relative-script')\\n")
r = subprocess.run([sys.executable, "child_script.py"], capture_output=True, text=True)
print("relative-script", r.returncode, repr(r.stdout), repr(r.stderr))
try:
    subprocess.check_output([sys.executable, "-c", "raise SystemExit(5)"])
except subprocess.CalledProcessError as exc:
    print("called-process-error", exc.returncode)
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.equal(outcome.stderr, '')
    assert.match(outcome.stdout, /capture 0 'child-out\\n' ''/)
    assert.match(outcome.stdout, /exit 7 '' ''/)
    assert.match(outcome.stdout, /bytes 0 b'bytes\\n'/)
    assert.match(outcome.stdout, /call 9/)
    assert.match(outcome.stdout, /check_output 'checked\\n'/)
    assert.match(outcome.stdout, /called-process-error 5/)
    assert.match(outcome.stdout, /relative-script 0 'relative-script\\n' ''/)
  } finally {
    await setup.cleanup()
  }
})

test('python: stdin is piped with input= and communicate()', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
r = subprocess.run([sys.executable, "-c", "import sys; print(sys.stdin.buffer.read().upper().decode())"],
                   input=b"pipe-me\\n", capture_output=True)
print("run", r.returncode, repr(r.stdout))
process = subprocess.Popen([sys.executable, "-c", "import sys; print(sys.stdin.read().upper())"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
out, err = process.communicate("communicate-me\\n")
print("communicate", process.returncode, repr(out), repr(err))
r = subprocess.run([sys.executable, "-c", "import sys; print(len(sys.stdin.buffer.read()))"], input=b"", capture_output=True, text=True)
print("empty", r.returncode, repr(r.stdout))
r = subprocess.run([sys.executable], input=b"print(5)\\n", capture_output=True, text=True)
print("bare-interpreter", r.returncode, repr(r.stdout), repr(r.stderr))
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /run 0 b'PIPE-ME\\n\\n'/)
    assert.match(outcome.stdout, /communicate 0 'COMMUNICATE-ME\\n\\n' ''/)
    assert.match(outcome.stdout, /empty 0 '0\\n'/)
    assert.match(outcome.stdout, /bare-interpreter 0 '5\\n' ''/)
  } finally {
    await setup.cleanup()
  }
})

test('python: a unittest suite that drives subprocess now runs instead of 10 ERRORs', {
  timeout: 180_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const tests = join(setup.workspace, 'tests')
    mkdirSync(tests, { recursive: true })
    writeFileSync(join(tests, '__init__.py'), '')
    writeFileSync(join(tests, 'test_child.py'), `
import subprocess
import sys
import unittest


class SpawnTests(unittest.TestCase):
    def test_capture(self):
        result = subprocess.run([sys.executable, "-c", "print('hello')"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "hello\\n")
        self.assertEqual(result.stderr, "")

    def test_nonzero_exit(self):
        result = subprocess.run([sys.executable, "-c", "raise SystemExit(3)"])
        self.assertEqual(result.returncode, 3)

    def test_stdin_pipe(self):
        result = subprocess.run(
            [sys.executable, "-c", "import sys; print(sys.stdin.read().upper())"],
            input="pipe",
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout, "PIPE\\n")

    def test_check_output(self):
        self.assertEqual(subprocess.check_output([sys.executable, "-c", "print(7)"], text=True), "7\\n")

    def test_call(self):
        self.assertEqual(subprocess.call([sys.executable, "-c", "raise SystemExit(4)"]), 4)

    def test_check_call_raises(self):
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            subprocess.check_call([sys.executable, "-c", "raise SystemExit(5)"])
        self.assertEqual(raised.exception.returncode, 5)

    def test_bytes_mode(self):
        result = subprocess.run([sys.executable, "-c", "print('bytes')"], capture_output=True)
        self.assertEqual(result.stdout, b"bytes\\n")

    def test_env_override(self):
        result = subprocess.run(
            [sys.executable, "-c", "import os; print(os.environ.get('PDSH_SPAWN_TEST', 'MISSING'))"],
            capture_output=True,
            text=True,
            env={"PDSH_SPAWN_TEST": "override"},
        )
        self.assertEqual(result.stdout, "override\\n")

    def test_cwd(self):
        result = subprocess.run(
            [sys.executable, "-c", "import os; print(os.getcwd())"],
            capture_output=True,
            text=True,
            cwd=".",
        )
        self.assertEqual(result.stdout, "/dsh/workspace\\n")

    def test_nested_child(self):
        result = subprocess.run(
            [sys.executable, "-c", "import subprocess, sys; print(subprocess.check_output([sys.executable, '-c', 'print(11)'], text=True).strip())"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout, "11\\n")


if __name__ == "__main__":
    unittest.main()
`)
    const outcome = await runPython(setup.runtime, ['-m', 'unittest', 'discover', '-s', 'tests', '-t', '.', '-v'])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stderr, /Ran 10 tests/)
    assert.match(outcome.stderr, /^OK$/m)
    assert.doesNotMatch(outcome.stderr, /ERROR|does not support processes/)
  } finally {
    await setup.cleanup()
  }
})

test('python: a nested interpreter reads and writes through the same VFS proxy and durability fence', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import os, subprocess, sys
os.makedirs("nested", exist_ok=True)
open("nested/parent.txt", "w").write("from-parent")
result = subprocess.run(
    [sys.executable, "-c", "import os, pathlib; print(os.getcwd()); print(pathlib.Path('parent.txt').read_text()); pathlib.Path('child.txt').write_text('from-child')"],
    cwd="nested",
    capture_output=True,
    text=True,
)
print("child", result.returncode, repr(result.stdout), repr(result.stderr))
print("parent-read", open("nested/child.txt").read())
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /child 0 '\/dsh\/workspace\/nested\\nfrom-parent\\n' ''/)
    assert.match(outcome.stdout, /parent-read from-child/)
    // The child's write is an ordinary DSH write: it reached the NodeFsBackend
    // of the same WasiVfs the shell dispatch uses (no bypass, G2-FIX-61).
    assert.equal(readFileSync(join(setup.workspace, 'nested/child.txt'), 'utf8'), 'from-child')
    assert.ok(
      setup.writes.includes('/dsh/workspace/nested/child.txt'),
      `child write did not reach the shared backend: ${JSON.stringify(setup.writes)}`,
    )
    assert.ok(setup.flushes.count >= 1, 'the command boundary did not flush the shared VFS sink')
  } finally {
    await setup.cleanup()
  }
})

test('python: a nested interpreter also works on the snapshot fallback path', {
  timeout: 180_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture({ crossOriginIsolated: false })
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
result = subprocess.run(
    [sys.executable, "-c", "import pathlib; pathlib.Path('snapshot-child.txt').write_text('snapshot-child')"],
    capture_output=True,
    text=True,
)
print("child", result.returncode, repr(result.stdout), repr(result.stderr))
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /child 0 '' ''/)
    assert.equal(readFileSync(join(setup.workspace, 'snapshot-child.txt'), 'utf8'), 'snapshot-child')
  } finally {
    await setup.cleanup()
  }
})

test('python: an unregistered program fails loud at Popen construction with the available programs', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess
try:
    subprocess.Popen(["pdsh-unregistered-program"])
except NotImplementedError as error:
    print("NotImplementedError", error)
try:
    subprocess.run(["pdsh-unregistered-program"])
except NotImplementedError as error:
    print("run-raises NotImplementedError", error)
except BaseException as error:
    print("wrong-exception", type(error).__name__, error)
try:
    subprocess.run("echo hi", shell=True)
except NotImplementedError as error:
    print("shell-refused", error)
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    const notImplemented = outcome.stdout.split('\n').filter(line => line.startsWith('NotImplementedError'))
    assert.equal(notImplemented.length, 1, outcome.stdout)
    assert.match(outcome.stdout, /pdsh-unregistered-program/)
    assert.match(outcome.stdout, /available programs: python3, python/)
    assert.match(outcome.stdout, /run-raises NotImplementedError/)
    assert.match(outcome.stdout, /shell-refused .*shell=True/)
    assert.doesNotMatch(outcome.stdout, /wrong-exception/)

    // An uncaught refusal is the command's own failure: a non-zero exit and a
    // traceback. It must never look like a successful child with no output.
    const uncaught = await runPython(setup.runtime, ['-c', 'import subprocess; subprocess.run(["pdsh-unregistered-program"])'])
    assert.notEqual(uncaught.exitCode, 0)
    assert.equal(uncaught.stdout, '')
    assert.match(uncaught.stderr, /NotImplementedError/)
    assert.match(uncaught.stderr, /available programs: python3, python/)
  } finally {
    await setup.cleanup()
  }
})

test('python: nested interpreters inherit env, honor env=/cwd= and can nest again', {
  timeout: 180_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    mkdirSync(join(setup.workspace, 'nested'), { recursive: true })
    const outcome = await runPython(setup.runtime, ['-c', `
import os, subprocess, sys
os.environ["PDSH_SUBPROCESS_TEST_VALUE"] = "inherited"
r = subprocess.run([sys.executable, "-c", "import os; print(os.environ.get('PDSH_SUBPROCESS_TEST_VALUE', 'MISSING'))"], capture_output=True, text=True)
print("inherit", repr(r.stdout))
r = subprocess.run([sys.executable, "-c", "import os; print(os.environ.get('PDSH_SUBPROCESS_TEST_VALUE', 'MISSING'))"],
                   capture_output=True, text=True, env={"PDSH_SUBPROCESS_TEST_VALUE": "override"})
print("override", repr(r.stdout))
r = subprocess.run([sys.executable, "-c", "import os; print(os.getcwd())"], capture_output=True, text=True, cwd="nested")
print("cwd", repr(r.stdout))
os.makedirs("scripts", exist_ok=True)
open("scripts/rel.py", "w").write("print('relative-child-cwd')\\n")
r = subprocess.run([sys.executable, "rel.py"], cwd="scripts", capture_output=True, text=True)
print("script-cwd", r.returncode, repr(r.stdout), repr(r.stderr))
r = subprocess.run(
    [sys.executable, "-c", "import subprocess, sys; print(subprocess.check_output([sys.executable, '-c', 'print(7)'], text=True).strip())"],
    capture_output=True, text=True,
)
print("depth2", r.returncode, repr(r.stdout), repr(r.stderr))
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /inherit 'inherited\\n'/)
    assert.match(outcome.stdout, /override 'override\\n'/)
    assert.match(outcome.stdout, /cwd '\/dsh\/workspace\/nested\\n'/)
    assert.match(outcome.stdout, /script-cwd 0 'relative-child-cwd\\n' ''/)
    assert.match(outcome.stdout, /depth2 0 '7\\n' ''/)
  } finally {
    await setup.cleanup()
  }
})

test('python: subprocess timeout= is accepted, not enforced, and the child result is returned', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
r = subprocess.run([sys.executable, "-c", "open('/dsh/workspace/timeout-run','w').write('ran'); print('run-out')"],
                   capture_output=True, text=True, timeout=30)
print("run", r.returncode, repr(r.stdout))
print("check_output", repr(subprocess.check_output([sys.executable, "-c", "print(5)"], text=True, timeout=0.001)))
for method in ("communicate", "wait"):
    child = subprocess.Popen([sys.executable, "-c", "print('m')"], stdout=subprocess.PIPE, text=True)
    getattr(child, method)(timeout=0.001)
    print("method", method, child.returncode)
with subprocess.Popen([sys.executable, "-c", "open('/dsh/workspace/timeout-context','w').write('ran')"]) as child:
    child.communicate(timeout=0.001)
print("context", child.returncode)
killed = subprocess.Popen([sys.executable, "-c", "open('/dsh/workspace/timeout-killed','w').write('ran')"])
killed.kill()
print("killed-wait", killed.wait(timeout=5))
try:
    subprocess.run([sys.executable, "-c", "raise SystemExit(3)"], timeout=10, check=True)
except subprocess.CalledProcessError as error:
    print("called-process-error", error.returncode)
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /run 0 'run-out\\n'/)
    assert.match(outcome.stdout, /check_output '5\\n'/)
    assert.match(outcome.stdout, /method communicate 0/)
    assert.match(outcome.stdout, /method wait 0/)
    assert.match(outcome.stdout, /context 0/)
    assert.match(outcome.stdout, /killed-wait -9/)
    assert.match(outcome.stdout, /called-process-error 3/)
    assert.equal(readFileSync(join(setup.workspace, 'timeout-run'), 'utf8'), 'ran')
    assert.equal(readFileSync(join(setup.workspace, 'timeout-context'), 'utf8'), 'ran')
    assert.equal(existsSync(join(setup.workspace, 'timeout-killed')), false)
    const notices = outcome.stderr.split('\n').filter(line => line.includes('timeout= is not enforced'))
    assert.equal(notices.length, 1, outcome.stderr)
  } finally {
    await setup.cleanup()
  }
})

test('python: output overflow cannot be caught to continue child side effects and the pool remains reusable', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
open("overflow_child.py", "w").write("import os\\ntry:\\n os.write(1, b'x' * (16 * 1024 * 1024 + 1))\\nexcept OSError:\\n open('/dsh/workspace/overflow-caught-error-ran','w').write('ran')\\n")
try:
    subprocess.run([sys.executable, "overflow_child.py"], capture_output=True)
except OSError as error:
    print("outer-limit", str(error))
else:
    print("NO-LIMIT")
normal = subprocess.run([sys.executable, "-c", "print('pool-reused')"], capture_output=True, text=True)
print("after-limit", normal.returncode, repr(normal.stdout), repr(normal.stderr))
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /outer-limit .*shared stdout\/stderr limit/)
    assert.match(outcome.stdout, /after-limit 0 'pool-reused\\n' ''/)
    assert.doesNotMatch(outcome.stdout, /NO-LIMIT/)
    assert.equal(existsSync(join(setup.workspace, 'overflow-caught-error-ran')), false)
  } finally {
    await setup.cleanup()
  }
})

test('python: a host diagnostic that crosses the output budget still stops the child', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
open("diag_child.py", "w").write(
    "import os\\n"
    "os.write(1, b'x' * (16 * 1024 * 1024 - 8))\\n"
    "try:\\n open('/dsh/home/tool-journal/blocked', 'w')\\nexcept OSError:\\n pass\\n"
    "open('/dsh/workspace/diag-child-continued', 'w').write('ran')\\n")
try:
    subprocess.run([sys.executable, "diag_child.py"], capture_output=True)
except OSError as error:
    print("outer-limit", str(error))
else:
    print("NO-LIMIT")
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /outer-limit .*shared stdout\/stderr limit/)
    assert.doesNotMatch(outcome.stdout, /NO-LIMIT/)
    assert.equal(existsSync(join(setup.workspace, 'diag-child-continued')), false)
  } finally {
    await setup.cleanup()
  }
})

test('python: nested stdout and stderr share a live byte budget and settle the outer command', {
  timeout: 120_000,
  skip: NO_ARTIFACTS,
}, async () => {
  const setup = fixture()
  try {
    const outcome = await runPython(setup.runtime, ['-c', `
import subprocess, sys
child = "import os; os.write(1, b'a' * (8 * 1024 * 1024)); os.write(2, b'b' * (8 * 1024 * 1024 + 1))"
try:
    subprocess.run([sys.executable, "-c", child], capture_output=True)
except OSError as error:
    print("child-refused", error.errno, str(error))
else:
    print("NO-LIMIT")
`])
    assert.equal(outcome.exitCode, 0, outcome.stderr)
    assert.match(outcome.stdout, /child-refused \d+ .*shared stdout\/stderr limit/)
    assert.doesNotMatch(outcome.stdout, /NO-LIMIT/)
  } finally {
    await setup.cleanup()
  }
})
