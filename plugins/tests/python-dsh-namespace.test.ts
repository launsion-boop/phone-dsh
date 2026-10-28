// SPDX-License-Identifier: MIT
// G2-FIX-23 regression: WASI Python must see the shell's file view.
//
// The defect: the CPython preopen table mounted the runtime-native roots
// (`/workspace`, `/home`, `/tmp`) while the Worker shell speaks `/dsh/workspace`
// and the bash tool's workdir never reached the interpreter as its cwd. A
// relative `open()` therefore resolved from an unpreopened `/` (Errno 44) and
// `/dsh/workspace/...` was outside every preopen, even though `ls`/`cat`
// succeeded on the same names.
//
// The fix has four observable parts, each pinned here at the component
// boundary the production Worker uses:
//   1. the python3 toolbox publishes the shell's `/dsh` roots as identity
//      preopens (no `/workspace` second mount);
//   2. every dispatch carries the bash tool's workdir as the exec cwd and PWD,
//      translating the legacy `/tmp` spelling into `/dsh/tmp`;
//   3. the read-only cwd shim next to the stdlib zip applies that cwd with
//      `os.chdir` at interpreter startup (WASI preview1 has no cwd argument);
//   4. a relative script operand is resolved against that cwd before dispatch,
//      because CPython resolves the filename before the shim can chdir.
//
// The always-on file-view test drives a real wasi-libc program (compiled from
// `wasi-toolbox/python/testdata/cpython-probe.c`) through the same
// `WasiToolbox`/VFS proxy/shell composition as `python3`; CPython and this
// probe both resolve paths through wasi-libc's preopen table. When
// `PDSH_PYTHON_WASM` points at a built CPython the same assertions also run
// against the real interpreter.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import {
  MemoryWasiVfs,
  NodeFsBackend,
  setWorkerToolbox,
  VfsProxyError,
  WasiToolbox,
  WORKER_DEFAULT_CWD,
  WORKER_VFS_NAMESPACE,
  WORKER_VFS_PREOPENS,
  WORKER_VFS_ROOTS,
  workerTransport,
} from '../wasi-toolbox/src/index.ts'
import type { NodeFsPromisesLike, ToolWorkerTransport, VfsDirEntry, WorkerLike } from '../wasi-toolbox/src/index.ts'
import { createPythonVfs } from '../wasi-toolbox/python/python-worker-runtime.ts'
import { PYTHON_CWD_SHIM_SOURCE, pythonCwdShimGuestDir } from '../wasi-toolbox/python/cwd-shim.ts'
import {
  PYTHON_STDLIB_GUEST_PATH,
  PYTHON_STDLIB_HOST_ROOT,
  pythonScriptIndex,
  rewritePythonScriptArgument,
} from '../wasi-toolbox/python/runtime.ts'
import {
  disposePythonToolbox,
  installPythonToolbox,
  PYTHON_DEFAULT_CWD,
  PYTHON_PREOPENS,
  PYTHON_STDLIB_IMAGE_PATH,
  PYTHON_WASM_IMAGE_PATH,
  type PythonToolboxWiring,
} from '../worker-entry/src/python-toolbox.ts'
import { createWorkerCommands, VfsFileSystem, WORKER_WRITABLE_ROOTS, WorkerShell } from '../shell-ext/src/index.ts'

const stubWasm = readFileSync(new URL('../wasi-toolbox/python/testdata/stub-python.wasm', import.meta.url))
const probeWasm = readFileSync(new URL('../wasi-toolbox/python/testdata/cpython-probe.wasm', import.meta.url))
const decoder = new TextDecoder()
const scratch: string[] = []

after(() => {
  setWorkerToolbox(undefined)
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
})

interface Fixture {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly backend: NodeFsBackend
}

/** A real-directory VFS root with the three Worker mounts and a shell over it. */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-python-ns-'))
  scratch.push(root)
  for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  const fs = new VfsFileSystem({ root, workerPaths: true })
  return { root, fs, backend: new NodeFsBackend(rootedPromises(root)) }
}

/** `node:fs/promises` face with `root` as virtual `/`. */
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

/** The packed-image artifact face `installPythonToolbox` reads. */
function imageVfs(wasm: Uint8Array, stdlib: Uint8Array): {
  subscribe(): () => void
  flush(): Promise<void>
  readFileSync(path: string): Uint8Array
} {
  const files = new Map<string, Uint8Array>([
    [PYTHON_WASM_IMAGE_PATH, wasm],
    [PYTHON_STDLIB_IMAGE_PATH, stdlib],
  ])
  return {
    subscribe: () => () => {},
    async flush() {},
    readFileSync(path: string): Uint8Array {
      const bytes = files.get(path)
      if (bytes === undefined) {
        throw Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT', path })
      }
      return bytes
    },
  }
}

interface RecordedInit {
  readonly preopens?: readonly { readonly guestPath: string; readonly hostPath: string }[]
  readonly defaultCwd?: string
  readonly defaultEnv?: Readonly<Record<string, string>>
}

interface RecordedExec {
  readonly argv?: readonly string[]
  readonly cwd?: string
  readonly env?: Readonly<Record<string, string>>
}

/**
 * A tool worker stand-in that records the init/exec envelopes the toolbox
 * sends. It answers ready/exit so the real `WasiToolbox` and `PythonTransport`
 * run unchanged.
 */
class RecordingToolWorker {
  readonly inits: RecordedInit[] = []
  readonly execs: RecordedExec[] = []
  private readonly listeners = new Set<(message: unknown) => void>()

  readonly transport: ToolWorkerTransport = {
    postMessage: message => { this.receive(message) },
    onMessage: (handler) => {
      this.listeners.add(handler)
      return () => { this.listeners.delete(handler) }
    },
    onError: () => () => {},
    terminate: async () => {},
  }

  private receive(message: unknown): void {
    if (typeof message !== 'object' || message === null) return
    const record = message as {
      readonly type?: unknown
      readonly id?: unknown
      readonly argv?: readonly string[]
      readonly cwd?: string
      readonly env?: Readonly<Record<string, string>>
      readonly preopens?: RecordedInit['preopens']
      readonly defaultCwd?: string
      readonly defaultEnv?: Readonly<Record<string, string>>
    }
    if (record.type === 'init') {
      this.inits.push({
        ...(record.preopens === undefined ? {} : { preopens: record.preopens }),
        ...(record.defaultCwd === undefined ? {} : { defaultCwd: record.defaultCwd }),
        ...(record.defaultEnv === undefined ? {} : { defaultEnv: record.defaultEnv }),
      })
      queueMicrotask(() => {
        this.emit({ type: 'ready', program: 'python3' })
        // The real tool worker verifies the preopens through both channels
        // after init; the toolbox's file-view gate waits for this answer.
        const preopens = (record.preopens ?? []).map(preopen => preopen.guestPath)
        this.emit({ type: 'preopens', program: 'python3', present: preopens, missing: [] })
        this.emit({ type: 'sync-preopens', program: 'python3', present: preopens, missing: [] })
      })
      return
    }
    if (record.type !== 'exec') return
    this.execs.push({
      ...(record.argv === undefined ? {} : { argv: record.argv }),
      ...(record.cwd === undefined ? {} : { cwd: record.cwd }),
      ...(record.env === undefined ? {} : { env: record.env }),
    })
    queueMicrotask(() => {
      this.emit({ type: 'exit', id: record.id, code: 0, memoryPeakBytes: 1 })
    })
  }

  private emit(message: unknown): void {
    for (const listener of [...this.listeners]) listener(message)
  }
}

test('python: the cwd shim is mounted read-only beside the stdlib zip on PYTHONPATH', () => {
  const bundle = createPythonVfs({
    writable: new DenyingReaddirVfs(),
    stdlib: {
      stdlibZip: new Uint8Array([0x50, 0x4b, 0x03, 0x04]),
      guestPath: PYTHON_STDLIB_GUEST_PATH,
      hostRoot: PYTHON_STDLIB_HOST_ROOT,
    },
  })
  assert.equal(bundle.cwdShimHostPath, `${PYTHON_STDLIB_HOST_ROOT}/python-cwd/sitecustomize.py`)
  assert.equal(bundle.cwdShimGuestDir, '/usr/local/lib/python-cwd')
  assert.equal(bundle.cwdShimGuestDir, pythonCwdShimGuestDir(PYTHON_STDLIB_GUEST_PATH))
  assert.equal(decoder.decode(bundle.vfs.read(bundle.cwdShimHostPath, 0, PYTHON_CWD_SHIM_SOURCE.length)), PYTHON_CWD_SHIM_SOURCE)
  assert.match(PYTHON_CWD_SHIM_SOURCE, /os\.chdir\(_target\)/)
  // The stdlib mount is read-only, so listing it must not consult the writable
  // proxy: that proxy only has capabilities for its own preopens and would
  // answer ENOTCAPABLE, which is what made the shim unimportable.
  assert.deepEqual(bundle.vfs.readdir(PYTHON_STDLIB_HOST_ROOT).map(entry => entry.name), ['python-cwd', 'python313.zip'])
  assert.deepEqual(bundle.vfs.readdir(`${PYTHON_STDLIB_HOST_ROOT}/python-cwd`).map(entry => entry.name), ['sitecustomize.py'])
  assert.equal(bundle.metrics.proxyCalls, 0, 'finding and importing the shim stays in the tool worker')
})

/** Writable face that rejects every readdir, like the proxy for a stdlib path. */
class DenyingReaddirVfs extends MemoryWasiVfs {
  override readdir(): readonly VfsDirEntry[] {
    throw new VfsProxyError('ENOTCAPABLE', 'path is outside the preopened directories')
  }
}

test('python: a relative script operand resolves against the dispatch cwd before CPython path config', () => {
  const cases: readonly [readonly string[], number | undefined][] = [
    [['exports/x.py'], 0],
    [['-iB', 'exports/x.py'], 1],
    [['-W', 'error', 'exports/x.py'], 2],
    [['-Xdev', 'exports/x.py'], 1],
    [['--check-hash-based-pycs', 'always', 'exports/x.py'], 2],
    [['--', 'exports/x.py'], 1],
    [['-c', 'pass'], undefined],
    [['-cpass'], undefined],
    [['-m', 'json.tool', 'exports/data.csv'], undefined],
    [['-mjson.tool', 'exports/data.csv'], undefined],
    [['-'], undefined],
    [['--version'], undefined],
    [[], undefined],
  ]
  for (const [argv, expected] of cases) {
    assert.equal(pythonScriptIndex(argv), expected, JSON.stringify(argv))
  }
  assert.deepEqual(
    rewritePythonScriptArgument(['exports/ledger.csv'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['/dsh/workspace/exports/ledger.csv'],
  )
  assert.deepEqual(
    rewritePythonScriptArgument(['-W', 'error', './a/../ledger.csv'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['-W', 'error', '/dsh/workspace/ledger.csv'],
  )
  assert.deepEqual(
    rewritePythonScriptArgument(['/dsh/home/script.py'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['/dsh/home/script.py'],
    'an absolute operand is already the namespace CPython opens',
  )
  assert.deepEqual(
    rewritePythonScriptArgument(['./sub/../script.py'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['/dsh/workspace/script.py'],
    'folding is the same path normalisation the shell applies',
  )
  assert.deepEqual(
    rewritePythonScriptArgument(['../script.py'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['../script.py'],
    'a path that leaves every preopen is left for CPython to report',
  )
  assert.deepEqual(
    rewritePythonScriptArgument(['-c', 'print(1)'], '/dsh/workspace', WORKER_VFS_PREOPENS),
    ['-c', 'print(1)'],
  )
})

test('python3 dispatch: /dsh identity preopens and the bash workdir as cwd/PWD', async () => {
  const { fs, backend } = fixture()
  const worker = new RecordingToolWorker()
  const wiring = await installPythonToolbox({
    vfs: imageVfs(stubWasm, new Uint8Array(64)),
    backend,
    crossOriginIsolated: true,
    spawnWorker: () => worker.transport,
  })
  assert.ok(wiring !== undefined)
  try {
    assert.deepEqual(PYTHON_PREOPENS, WORKER_VFS_PREOPENS)
    // The preopen table is generated from the one namespace root table. The
    // shell adapter's own writable-root list is the same storage set; its
    // `/tmp` spelling is the volatile root the namespace canonicalises.
    assert.deepEqual([...WORKER_VFS_ROOTS], [...WORKER_VFS_NAMESPACE.writableRoots()])
    assert.deepEqual(WORKER_VFS_ROOTS, ['/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp'])
    for (const root of WORKER_WRITABLE_ROOTS) {
      assert.equal(WORKER_VFS_ROOTS.includes(root), true, `${root} is a namespace root`)
    }
    assert.deepEqual(wiring.toolbox.preopenTable, [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
      { guestPath: '/tmp', hostPath: '/tmp' },
      { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
    ])
    assert.deepEqual(wiring.toolbox.preopenTable?.map(preopen => preopen.guestPath), WORKER_VFS_ROOTS)
    assert.equal(
      wiring.toolbox.preopenTable?.some(preopen => ['/workspace', '/home'].includes(preopen.guestPath)),
      false,
      'the legacy /workspace and /home names are translations, not second preopen roots',
    )
    assert.equal(
      wiring.toolbox.preopenTable?.some(preopen => preopen.guestPath === '/tmp'),
      true,
      '/tmp is a root of the table, not a translation',
    )
    assert.equal(PYTHON_DEFAULT_CWD, WORKER_DEFAULT_CWD)

    const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false }) })
    const run = async (script: string): Promise<void> => {
      const result = await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
      assert.equal(result.exitCode, 0, result.stderr)
    }
    await fs.mkdir('/dsh/workspace/exports')
    await run('python3 -c pass')
    await run('cd /dsh/home && python3 -c pass')
    await run('cd /tmp && python3 -c pass')
    await run('cd /dsh/workspace/exports && python3 -c pass')

    assert.equal(worker.inits.length, 1, 'one warm tool worker serves every dispatch')
    const init = worker.inits[0] as RecordedInit
    assert.deepEqual(init.preopens, WORKER_VFS_PREOPENS)
    assert.equal(init.defaultCwd, '/dsh/workspace')

    assert.deepEqual(worker.execs.map(exec => exec.cwd), [
      '/dsh/workspace',
      '/dsh/home',
      '/tmp',
      '/dsh/workspace/exports',
    ], 'every dispatch gets the directory the shell ran in, in the namespace the preopens mount')
    assert.deepEqual(worker.execs.map(exec => exec.env?.PWD), [
      '/dsh/workspace',
      '/dsh/home',
      '/tmp',
      '/dsh/workspace/exports',
    ], 'PWD names the same root as the cwd')
    for (const exec of worker.execs) {
      const pythonPath = (exec.env?.PYTHONPATH ?? '').split(':')
      assert.ok(pythonPath.includes('/usr/local/lib/python-cwd'), 'the cwd shim stays importable after a caller env override')
    }

    // The script operand is resolved against the same cwd before dispatch, so
    // CPython's pre-site path configuration opens the file the shell sees.
    await run('python3 exports/ledger_raw.csv')
    await run('python3 -c pass')
    const scriptExec = worker.execs.at(-2)
    const codeExec = worker.execs.at(-1)
    assert.deepEqual(scriptExec?.argv, ['/dsh/workspace/exports/ledger_raw.csv'])
    assert.deepEqual(codeExec?.argv, ['-c', 'pass'], 'a -c invocation is not rewritten')
  } finally {
    await disposePythonToolbox(wiring)
  }
})

test('python3 file view: a wasi-libc program reads the shell file relatively and at /dsh, and lists what ls lists', { timeout: 30_000 }, async () => {
  const { root, fs, backend } = fixture()
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: { url: 'testdata://cpython-probe.wasm', load: async () => probeWasm },
      cwd: PYTHON_DEFAULT_CWD,
      description: 'wasi-libc cwd/preopen probe at the python3 program name',
    }],
    backend,
    // The production table: the same roots as the shell.
    preopens: PYTHON_PREOPENS,
    crossOriginIsolated: true,
    spawnWorker: () => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
    workerReadyTimeoutMs: 10_000,
  })
  setWorkerToolbox(toolbox)
  try {
    const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false }) })
    const created = await shell.run(
      ['bash', '-c', "mkdir -p exports && printf 'id,amount\\n1,10\\n' > exports/ledger_raw.csv"],
      { cwd: '/dsh/workspace' },
    )
    assert.equal(created.exitCode, 0, created.stderr)
    const expected = 'id,amount\n1,10\n'

    const relative = await shell.run(['bash', '-c', 'python3 exports/ledger_raw.csv'], { cwd: '/dsh/workspace' })
    assert.equal(relative.exitCode, 0, relative.stderr)
    assert.match(relative.stdout, /^cwd=\/dsh\/workspace\n/)
    assert.equal(relative.stdout.slice('cwd=/dsh/workspace\n'.length), expected)

    const absolute = await shell.run(
      ['bash', '-c', 'python3 /dsh/workspace/exports/ledger_raw.csv'],
      { cwd: '/dsh/workspace' },
    )
    assert.equal(absolute.exitCode, 0, `${absolute.stderr}${absolute.stdout}`)
    assert.equal(absolute.stdout, relative.stdout, 'relative and /dsh absolute reads are the same bytes')

    const listed = await shell.run(['bash', '-c', 'python3 --list'], { cwd: '/dsh/workspace' })
    assert.equal(listed.exitCode, 0, `${listed.stderr}${listed.stdout}`)
    const probeEntries = listed.stdout.split('\n').slice(1).filter(line => line !== '').sort()
    const shellEntries = [...await fs.readdir('/dsh/workspace')].sort()
    assert.deepEqual(probeEntries, shellEntries, 'os.listdir(/dsh/workspace) sees the shell tree')
    assert.deepEqual(probeEntries, readdirSync(join(root, 'dsh/workspace')).sort())
    const ls = await shell.run(['bash', '-c', 'ls /dsh/workspace'], { cwd: '/dsh/workspace' })
    assert.equal(ls.exitCode, 0, ls.stderr)
    assert.deepEqual(probeEntries, ls.stdout.split('\n').filter(line => line !== '').sort())

    const listedExports = await shell.run(['bash', '-c', 'python3 --list exports'], { cwd: '/dsh/workspace' })
    assert.equal(listedExports.exitCode, 0, listedExports.stderr)
    assert.deepEqual(listedExports.stdout.split('\n').slice(1).filter(line => line !== ''), ['ledger_raw.csv'])
  } finally {
    setWorkerToolbox(undefined)
    await toolbox.dispose()
  }
})

const realWasmPath = process.env.PDSH_PYTHON_WASM
const realStdlibPath = process.env.PDSH_PYTHON_STDLIB
  ?? (realWasmPath === undefined ? undefined : join(dirname(realWasmPath), 'python313.zip'))

test(
  'python3 (real CPython): os.getcwd, relative and /dsh open, and os.listdir match the shell',
  {
    timeout: 120_000,
    skip: realWasmPath === undefined || realStdlibPath === undefined
      ? 'set PDSH_PYTHON_WASM (and optionally PDSH_PYTHON_STDLIB) to a built CPython artifact'
      : false,
  },
  async () => {
    const { fs, backend } = fixture()
    let wiring: PythonToolboxWiring | undefined
    try {
      wiring = await installPythonToolbox({
        vfs: imageVfs(readFileSync(realWasmPath as string), readFileSync(realStdlibPath as string)),
        backend,
        crossOriginIsolated: true,
        spawnWorker: () => workerTransport(
          new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url)) as unknown as WorkerLike,
        ),
      })
      assert.ok(wiring !== undefined)
      const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false }) })
      const created = await shell.run(
        ['bash', '-c', "mkdir -p exports && printf 'id,amount\\n1,10\\n' > exports/ledger_raw.csv"],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(created.exitCode, 0, created.stderr)

      const cwd = await shell.run(['bash', '-c', 'python3 -c "import os; print(os.getcwd())"'], { cwd: '/dsh/workspace' })
      assert.equal(cwd.exitCode, 0, cwd.stderr)
      assert.equal(cwd.stdout, '/dsh/workspace\n')

      const script = await shell.run(
        ['bash', '-c', "printf 'import os\\nprint(os.getcwd())\\n' > exports/hello.py && python3 exports/hello.py"],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(script.exitCode, 0, script.stderr)
      assert.equal(script.stdout, '/dsh/workspace\n')

      const read = "import sys; sys.stdout.buffer.write(open(p, 'rb').read())"
      const relative = await shell.run(
        ['bash', '-c', `python3 -c "p='exports/ledger_raw.csv'; ${read}"`],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(relative.exitCode, 0, relative.stderr)
      const absolute = await shell.run(
        ['bash', '-c', `python3 -c "p='/dsh/workspace/exports/ledger_raw.csv'; ${read}"`],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(absolute.exitCode, 0, absolute.stderr)
      assert.equal(relative.stdout, 'id,amount\n1,10\n')
      assert.equal(absolute.stdout, relative.stdout)

      const listed = await shell.run(
        ['bash', '-c', 'python3 -c "import os; print(\'\\n\'.join(sorted(os.listdir(\'/dsh/workspace\'))))"'],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(listed.exitCode, 0, listed.stderr)
      const shellEntries = [...await fs.readdir('/dsh/workspace')].sort()
      const listedEntries = listed.stdout.split('\n').filter(line => line !== '').sort()
      assert.deepEqual(listedEntries, shellEntries)
      const ls = await shell.run(['bash', '-c', 'ls /dsh/workspace'], { cwd: '/dsh/workspace' })
      assert.equal(ls.exitCode, 0, ls.stderr)
      assert.deepEqual(listedEntries, ls.stdout.split('\n').filter(line => line !== '').sort())
    } finally {
      await disposePythonToolbox(wiring)
    }
  },
)


test(
  'python3 (real CPython): overflowing stdout keeps the exact producer byte count',
  {
    timeout: 120_000,
    skip: realWasmPath === undefined || realStdlibPath === undefined
      ? 'set PDSH_PYTHON_WASM (and optionally PDSH_PYTHON_STDLIB) to a built CPython artifact'
      : false,
  },
  async () => {
    const { fs, backend } = fixture()
    let wiring: PythonToolboxWiring | undefined
    try {
      wiring = await installPythonToolbox({
        vfs: imageVfs(readFileSync(realWasmPath as string), readFileSync(realStdlibPath as string)),
        backend,
        crossOriginIsolated: true,
        spawnWorker: () => workerTransport(
          new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url)) as unknown as WorkerLike,
        ),
      })
      assert.ok(wiring !== undefined)
      const shell = new WorkerShell({
        fs,
        commands: createWorkerCommands({ git: false, curl: false }),
        maxOutputBytes: 1024,
      })
      const result = await shell.run(
        ['bash', '-c', "python3 -c \"import sys; sys.stdout.write('x'*200000)\""],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(result.exitCode, 1, result.stderr)
      assert.equal(result.stdoutTruncated, true)
      assert.equal(result.stdoutOriginalBytes, 200_000)
      assert.match(result.stdout, /output truncated: \d+ of 200000 bytes elided/u)
      assert.match(result.stderr, /reason=output-truncated/u)

      // The same real producer through a subshell pass-through stage keeps
      // the facts after byte/text transcoding; it must not look like success.
      const wrapped = await shell.run(
        ['bash', '-c', "python3 -c \"import sys; sys.stdout.write('x'*200000)\" | (cat)"],
        { cwd: '/dsh/workspace' },
      )
      assert.equal(wrapped.exitCode, 1, wrapped.stderr)
      assert.equal(wrapped.stdoutTruncated, true)
      assert.equal(wrapped.stdoutOriginalBytes, 200_000)
      assert.match(wrapped.stderr, /reason=output-truncated/u)
    } finally {
      setWorkerToolbox(undefined)
      await disposePythonToolbox(wiring)
    }
  },
)
