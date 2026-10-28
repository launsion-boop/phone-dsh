// SPDX-License-Identifier: MIT
/**
 * Component harness for the G2-FIX-54 regression: boot the phone Worker entry
 * over an image plus a workspace overlay, run the shell and the published
 * `python3` against the *same* host VFS, and report both file views.
 *
 * The runtime host is a deterministic stand-in for the pinned DSH worker host:
 * it mounts the image seed, applies the overlay entries (the shape the runtime
 * rebuilds on the resume path) and exposes both a structural VFS and the
 * instance-bound `promises` face `MemoryVfs` has. The Worker entry, the python
 * toolbox, the tool worker, the WASI host and the shell are the production
 * modules.
 *
 * The `crossOriginIsolated` switch models the rebuild condition: a cold boot in
 * a cross-origin isolated Worker gets the SharedArrayBuffer VFS channel, and a
 * Worker rebuilt by a recovery path can come back without it. That is the
 * defect class G2-FIX-54 fixes: `bash` kept the file view while `python3` lost
 * it, because the toolbox published a guest with no resolvable preopens.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/python-rebuild-harness
 */
import assert from 'node:assert/strict'
import { Buffer } from 'node:buffer'
import { readFileSync } from 'node:fs'
import { Worker } from 'node:worker_threads'
import { createWorkerCommands, VfsFileSystem, WorkerShell } from '../../shell-ext/src/index.ts'
import type { VfsFileSystemIo } from '../../shell-ext/src/index.ts'
import { MemoryVfsBackend, NodeFsBackend } from '../../wasi-toolbox/src/index.ts'
import type { ToolWorkerTransport, VfsDirEntry, VfsStat, WorkerLike } from '../../wasi-toolbox/src/index.ts'
import { workerTransport } from '../../wasi-toolbox/src/message-endpoint.ts'
import { MockChannel } from '../test-channel.ts'
import { startPhoneWorker } from '../../worker-entry/src/entry.ts'
import type {
  HostVfsPromises,
  PhoneWorkerHandle,
  PhoneWorkerHostLike,
  PhoneWorkerRuntime,
  WorkerEntrySynthesize,
  WorkerEntryVfs,
} from '../../worker-entry/src/entry.ts'
import { PYTHON_STDLIB_IMAGE_PATH, PYTHON_WASM_IMAGE_PATH } from '../../worker-entry/src/python-toolbox.ts'

/** One overlay entry the rebuilt host applies after the image. */
export interface OverlayEntry {
  readonly path: string
  readonly text: string
}

/** Inputs for {@link bootAndProbe}. */
export interface BootProbeOptions {
  /**
   * Whether the rebuilt Worker still has a cross-origin isolated context. This
   * is the only production knob that decides whether the tool worker gets the
   * SharedArrayBuffer VFS channel.
   */
  readonly crossOriginIsolated: boolean
  /** Workspace overlay the host applies after the image (the resume path). */
  readonly workspace: readonly OverlayEntry[]
  /**
   * `host` (default) leaves the backend to the entry's production wiring —
   * the host VFS's own promise face. `injected` passes the same face in
   * explicitly, which models a cold boot whose ambient `node:fs/promises`
   * proxy already resolves the live host VFS.
   */
  readonly backend?: 'host' | 'injected'
}

/** The python3 probes and the shell reads they are compared with. */
export interface FileView {
  /** `cwd=` line from the guest's `getcwd()`. */
  readonly pythonCwd: string
  /** Guest read of `/dsh/workspace/data.txt`. */
  readonly pythonAbsolute: string
  /** Guest relative listing of `exports` from the dispatch cwd. */
  readonly pythonRelativeList: readonly string[]
  /** Guest listing of `/dsh/workspace`. */
  readonly pythonList: readonly string[]
  /** Shell `pwd` in the same directory. */
  readonly bashCwd: string
  /** Shell read of `data.txt` from its cwd. */
  readonly bashRelative: string
  /** Shell read of `/dsh/workspace/data.txt`. */
  readonly bashAbsolute: string
  /** Shell `ls exports`. */
  readonly bashRelativeList: readonly string[]
  /** Shell `ls /dsh/workspace`. */
  readonly bashList: readonly string[]
  /** Guest exit codes, keyed by probe name. */
  readonly exits: Readonly<Record<string, number>>
  /** Guest stderr, keyed by probe name. */
  readonly stderr: Readonly<Record<string, string>>
}

/** One booted worker plus the handles the caller must release. */
export interface BootedProbe {
  readonly handle: PhoneWorkerHandle
  readonly view: FileView
  /** Run one script through the shell over the same live host VFS. */
  bash(script: string): Promise<string>
  /** Write one file through the live host VFS, as a shell step would. */
  writeHostFile(path: string, text: string): Promise<void>
  /** Run one python3 program through the published toolbox. */
  python(argv: readonly string[]): Promise<GuestProbe>
  dispose(): Promise<void>
}

const PROBE_WASM = new URL('../../wasi-toolbox/python/testdata/cpython-probe.wasm', import.meta.url)
const probeWasmBytes = readFileSync(PROBE_WASM)
const STDLIB_BYTES = new TextEncoder().encode('stub stdlib')
const decoder = new TextDecoder()

/** A `node:fs/promises`-and-more face over the in-memory backend. */
interface TestVfsPromises extends HostVfsPromises {
  lstat(path: string): Promise<NodeStat>
  appendFile(path: string, data: Uint8Array): Promise<void>
  rmdir(path: string): Promise<void>
  rm(path: string, options?: { recursive?: boolean; force?: boolean }): Promise<void>
  access(path: string): Promise<void>
  cp(from: string, to: string, options?: { recursive?: boolean }): Promise<void>
}

/** One `fs.Stats`-shaped value. */
interface NodeStat {
  readonly size: number
  readonly mode: number
  readonly mtimeMs: number
  readonly ino: number
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

function nodeStat(stat: VfsStat): NodeStat {
  return {
    size: stat.size,
    mode: stat.mode,
    mtimeMs: stat.mtimeMs,
    ino: stat.ino,
    isFile: () => stat.kind === 'file',
    isDirectory: () => stat.kind === 'directory',
    isSymbolicLink: () => stat.kind === 'symlink',
  }
}

function dirent(entry: VfsDirEntry): {
  name: string
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
} {
  return {
    name: entry.name,
    isFile: () => entry.kind === 'file',
    isDirectory: () => entry.kind === 'directory',
    isSymbolicLink: () => entry.kind === 'symlink',
  }
}

/**
 * The host VFS: an in-memory tree (the image + overlay) exposed through the
 * structural face the entry uses and the instance-bound promise face
 * `MemoryVfs.promises` provides in production.
 */
class TestHostVfs implements WorkerEntryVfs {
  readonly backend = new MemoryVfsBackend()
  readonly promises: TestVfsPromises

  constructor() {
    const backend = this.backend
    this.promises = {
      stat: async path => nodeStat(backend.stat(path)),
      lstat: async path => nodeStat(backend.stat(path)),
      readdir: async (path: string, options?: { withFileTypes?: boolean }) => {
        const entries = backend.readdir(path)
        return options?.withFileTypes === true ? entries.map(dirent) : entries.map(entry => entry.name)
      },
      readFile: async path => Buffer.from(backend.readFile(path)),
      writeFile: async (path, data, options) => {
        backend.writeFile(path, data, {
          create: true,
          ...(options?.mode === undefined ? {} : { mode: options.mode }),
        })
      },
      appendFile: async (path, data) => {
        backend.writeFile(path, data, { create: true, append: true })
      },
      mkdir: async (path, options) => {
        if (options?.recursive === true) backend.seedDirectory(path)
        else backend.mkdir(path, options?.mode)
      },
      unlink: async path => backend.unlink(path),
      rmdir: async path => backend.unlink(path, { directory: true }),
      rm: async (path, options) => {
        try {
          backend.unlink(path, { recursive: options?.recursive === true })
        } catch (error) {
          if (options?.force === true) return
          throw error
        }
      },
      rename: async (from, to) => backend.rename(from, to),
      truncate: async (path, length = 0) => backend.truncate(path, length),
      chmod: async () => {},
      access: async path => { backend.stat(path) },
      cp: async (from, to) => {
        backend.writeFile(to, backend.readFile(from), { create: true })
      },
    }
  }

  subscribe(): () => void {
    return () => {}
  }

  async flush(): Promise<void> {}

  readFileSync(path: string): Uint8Array {
    return this.backend.readFile(path)
  }
}

/** Seed the image root the packer would write: empty roots plus python. */
function seedImage(vfs: TestHostVfs): void {
  for (const root of ['/dsh', '/dsh/workspace', '/dsh/home', '/dsh/tmp', '/dsh/bin', '/dsh/bin/python']) {
    vfs.backend.seedDirectory(root)
  }
  vfs.backend.seedFile(PYTHON_WASM_IMAGE_PATH, new Uint8Array(probeWasmBytes))
  vfs.backend.seedFile(PYTHON_STDLIB_IMAGE_PATH, STDLIB_BYTES)
}

/** Apply the workspace overlay entries after the image, like the runtime does. */
function applyOverlay(vfs: TestHostVfs, workspace: readonly OverlayEntry[]): void {
  for (const file of workspace) vfs.backend.seedFile(`/dsh/${file.path}`, file.text)
}

/** Build the runtime seam `startPhoneWorker` expects. */
function createRuntime(state: { vfs?: TestHostVfs; workspace: readonly OverlayEntry[] }): PhoneWorkerRuntime {
  const synthesize: WorkerEntrySynthesize = (_request, sink) => {
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
  return {
    createHost: (): PhoneWorkerHostLike => {
      const host: PhoneWorkerHostLike = {
        handleMessage: () => {},
        // The host applies the image and the overlay the resume path rebuilt
        // before the tree is active; the entry wires python after this returns.
        start: async () => {
          const vfs = state.vfs
          if (vfs !== undefined) applyOverlay(vfs, state.workspace)
        },
        stop: async () => {},
        get vfs() { return state.vfs },
      }
      return host
    },
    whenRequestListener: async () => () => {},
    createChannel: () => new MockChannel({ caps: [], nextMseq: 1n }) as never,
    synthesize,
  }
}

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

/** One shell over the same host VFS the entry exposes. */
function createShell(vfs: TestHostVfs): WorkerShell {
  return new WorkerShell({
    fs: new VfsFileSystem({
      root: '',
      nodeFs: vfs.promises as unknown as VfsFileSystemIo,
      // The runtime's `node:fs` sync face reads the same MemoryVfs tree; the
      // harness host exposes it from the in-memory backend.
      readdirSync: path => vfs.backend.readdir(path).map(dirent),
    }),
    commands: createWorkerCommands({ git: false, curl: false }),
  })
}

async function runShell(shell: WorkerShell, script: string): Promise<string> {
  const result = await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
  if (result.exitCode !== 0) throw new Error(`shell failed (${result.exitCode}): ${result.stderr}`)
  return result.stdout
}

/** One python3 run's captured output. */
export interface GuestProbe {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
}

/** Run one python3 program through the published toolbox. */
async function runPython(handle: PhoneWorkerHandle, argv: readonly string[]): Promise<GuestProbe> {
  const out: Uint8Array[] = []
  const err: Uint8Array[] = []
  const result = await handle.python!.toolbox.run({
    program: 'python3',
    argv,
    cwd: '/dsh/workspace',
    env: { PWD: '/dsh/workspace' },
    onStdout: chunk => { out.push(chunk) },
    onStderr: chunk => { err.push(chunk) },
  })
  return {
    stdout: decoder.decode(Buffer.concat(out.map(chunk => Buffer.from(chunk)))),
    stderr: decoder.decode(Buffer.concat(err.map(chunk => Buffer.from(chunk)))),
    exitCode: result.exitCode,
  }
}

function lines(text: string): string[] {
  return text.split('\n').map(line => line.trim()).filter(line => line !== '').sort()
}

/**
 * Boot one Worker over the given image/overlay and collect the guest and shell
 * file views. The caller must dispose the result.
 * @param options - isolation condition and overlay entries.
 * @returns The booted worker and both file views.
 */
export async function bootAndProbe(options: BootProbeOptions): Promise<BootedProbe> {
  const vfs = new TestHostVfs()
  seedImage(vfs)
  const handle = await startPhoneWorker({
    imageURL: 'image://test',
    overlayURLs: ['overlay://workspace'],
    channelURL: 'ws://127.0.0.1:1/channel',
    token: 'test-token',
    runtime: createRuntime({ vfs, workspace: options.workspace }),
    python: {
      // The python wiring binds to the host VFS's own promise face; no ambient
      // `node:fs/promises` module is involved, which is what lets the rebuilt
      // Worker follow the new host (G2-FIX-54).
      ...(options.backend === 'injected'
        ? { backend: new NodeFsBackend(vfs.promises as never, { flush: () => vfs.flush() }) }
        : {}),
      spawnWorker: spawnPythonWorker,
      crossOriginIsolated: options.crossOriginIsolated,
    },
    pagePost: () => {},
  })
  const shell = createShell(vfs)

  const bashCwd = (await runShell(shell, 'pwd')).trim()
  const bashRelative = await runShell(shell, 'cat data.txt')
  const bashAbsolute = await runShell(shell, 'cat /dsh/workspace/data.txt')
  const bashRelativeList = lines(await runShell(shell, 'ls -1 exports'))
  const bashList = lines(await runShell(shell, 'ls -1 /dsh/workspace'))

  const cwdProbe = await runPython(handle, ['--cwd'])
  const absoluteProbe = await runPython(handle, ['/dsh/workspace/data.txt'])
  const relativeProbe = await runPython(handle, ['--list', 'exports'])
  const listProbe = await runPython(handle, ['--list', '/dsh/workspace'])
  const cwdLine = cwdProbe.stdout.split('\n').find(line => line.startsWith('cwd=')) ?? ''

  return {
    handle,
    view: {
      pythonCwd: cwdLine,
      pythonAbsolute: absoluteProbe.stdout.slice(absoluteProbe.stdout.indexOf('\n') + 1),
      pythonRelativeList: lines(relativeProbe.stdout.split('\n').slice(1).join('\n')),
      pythonList: lines(listProbe.stdout.split('\n').slice(1).join('\n')),
      bashCwd,
      bashRelative,
      bashAbsolute,
      bashRelativeList,
      bashList,
      exits: {
        cwd: cwdProbe.exitCode,
        absolute: absoluteProbe.exitCode,
        relative: relativeProbe.exitCode,
        list: listProbe.exitCode,
      },
      stderr: {
        cwd: cwdProbe.stderr,
        absolute: absoluteProbe.stderr,
        relative: relativeProbe.stderr,
        list: listProbe.stderr,
      },
    },
    bash: script => runShell(shell, script),
    writeHostFile: async (path, text) => {
      await vfs.promises.writeFile(path, new TextEncoder().encode(text))
    },
    python: argv => runPython(handle, argv),
    async dispose(): Promise<void> {
      await handle.stop()
    },
  }
}

/** The overlay every case boots with: the fixture the resume path rebuilds. */
export const WORKSPACE_OVERLAY: readonly OverlayEntry[] = [
  { path: 'workspace/data.txt', text: 'hello-from-overlay\n' },
  { path: 'workspace/main.py', text: "print('main')\n" },
  { path: 'workspace/exports/ledger.csv', text: 'id,amount\n1,10\n' },
]

/** The overlay the rebuilt Worker receives: same tree, one new file. */
export const REBUILT_WORKSPACE_OVERLAY: readonly OverlayEntry[] = [
  ...WORKSPACE_OVERLAY,
  { path: 'workspace/fresh.txt', text: 'written-after-the-rebuild\n' },
]

/**
 * Assert the guest's file view and the shell's file view are the same view.
 *
 * This is the G2-FIX-54 invariant: the rebuilt Worker's `python3` must resolve
 * the working directory, an absolute `/dsh/...` path and a relative path
 * exactly as the shell does, on the same host VFS.
 * @param view - The probes collected by {@link bootAndProbe}.
 * @param expectedEntries - Workspace entries the live overlay must expose.
 */
export function assertFileView(view: FileView, expectedEntries: readonly string[]): void {
  const failures = Object.entries(view.exits).filter(([, code]) => code !== 0)
  assert.deepEqual(
    failures,
    [],
    `python3 probes exited non-zero: ${JSON.stringify(view.exits)} stderr=${JSON.stringify(view.stderr)}`,
  )
  assert.equal(view.bashCwd, '/dsh/workspace')
  assert.equal(view.pythonCwd, `cwd=${view.bashCwd}`, 'the guest cwd is the shell cwd')
  assert.equal(view.bashRelative, 'hello-from-overlay\n')
  assert.equal(view.pythonAbsolute, view.bashAbsolute, 'the guest reads /dsh/workspace/data.txt like the shell')
  assert.equal(view.bashAbsolute, 'hello-from-overlay\n')
  assert.deepEqual(view.pythonRelativeList, view.bashRelativeList, 'the guest lists a relative directory like the shell')
  assert.deepEqual(view.pythonRelativeList, ['ledger.csv'])
  assert.deepEqual(view.pythonList, view.bashList, 'the guest lists /dsh/workspace like the shell')
  assert.deepEqual(
    view.pythonList,
    [...expectedEntries].sort(),
    'the guest sees the workspace overlay the rebuilt host applied',
  )
}
