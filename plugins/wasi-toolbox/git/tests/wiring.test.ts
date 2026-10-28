// SPDX-License-Identifier: MIT
/**
 * W7-GIT / W7-PYTHON production wiring.
 *
 * The git program is only useful if the shipped Worker can reach it: the
 * production command table must register `git`, a direct
 * `ctx.subprocess.spawn(['git', ...])` — what DSH's `workspace-changes` does —
 * must land in the same implementation instead of the runtime's
 * `node:child_process` shim, and the packed package must export the face. The
 * last test proves the toolbox bridge that puts `python3` in the same table
 * with no second code path.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/wiring.test
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { XlExecBridge } from '../../../exec-bridge/src/index.ts'
import { createWorkerCommands, isWorkerShellProgram, VfsFileSystem, WorkerShell } from '../../../shell-ext/src/index.ts'
import { XlSubprocessRuntime } from '../../../subprocess-xl/src/index.ts'
import { MockChannel } from '../../../tests/test-channel.ts'
import { workerTransport } from '../../src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../../src/message-endpoint.ts'
import { getWorkerToolbox, setWorkerToolbox, WasiToolbox } from '../../src/index.ts'
import { MemoryVfsBackend } from '../../src/vfs-backends.ts'
import type { ToolboxResult, ToolboxRunRequest } from '../../src/types.ts'

const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  setWorkerToolbox(undefined)
})

function vfsRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-git-wiring-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  return root
}

/** Run one async body with `PDSH_VFS_ROOT` pointing at a test root. */
async function withVfsRoot<T>(root: string, body: () => Promise<T>): Promise<T> {
  const saved = process.env.PDSH_VFS_ROOT
  process.env.PDSH_VFS_ROOT = root
  try {
    return await body()
  } finally {
    if (saved === undefined) delete process.env.PDSH_VFS_ROOT
    else process.env.PDSH_VFS_ROOT = saved
  }
}

test('the package exports the faces the Worker image stages', () => {
  const manifest = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8')) as {
    exports: Record<string, string>
  }
  assert.equal(manifest.exports['./git'], './git/index.ts', 'pack-image stages lib/git.js')
  assert.equal(manifest.exports['./python'], './python/runtime.ts', 'pack-image stages lib/python.js')
  assert.equal(manifest.exports['./tool-worker-python'], './python/tool-worker-python.ts',
    'pack-image stages lib/tool-worker-python.js next to lib/python.js')
})

test('createWorkerCommands registers git and bash -c "git …" runs it', async () => {
  const root = vfsRoot()
  await withVfsRoot(root, async () => {
    const commands = createWorkerCommands({ toolbox: false })
    assert.ok(commands.some(command => command.name === 'git'), 'the production table carries git')
    const shell = new WorkerShell({ fs: new VfsFileSystem({ root }), commands })
    const init = await shell.run(['bash', '-c', 'git init -b main'], { cwd: '/dsh/workspace' })
    assert.equal(init.exitCode, 0, init.stderr)
    assert.match(init.stdout, /^Initialized empty Git repository/)
    const result = await shell.run(['bash', '-c', [
      'echo one > a.md',
      'git add -A',
      'git rev-parse --is-inside-work-tree',
      'git status --porcelain',
      'git ls-files',
    ].join(' && ')], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stdout, 'true\nA  a.md\na.md\n')
    // The repository is real state under the VFS root the shell sees.
    assert.equal(existsSync(join(root, 'dsh/workspace/.git/HEAD')), true)
  })
})

test('subprocess.spawn(["git", ...]) runs the Worker git program, not a host process', async () => {
  const root = vfsRoot()
  await withVfsRoot(root, async () => {
    const savedShell = process.env.PDSH_SHELL
    process.env.PDSH_SHELL = 'just-bash'
    const mock = new MockChannel({ caps: [], nextMseq: 1n })
    ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
    const ctx = new Context()
    await ctx.plugin(XlExecBridge, {
      transport: 'channel',
      tokenEnv: 'PDSH_GIT_WIRING_UNUSED_TOKEN',
      tokenFileEnv: 'PDSH_GIT_WIRING_UNUSED_TOKEN_FILE',
      connectTimeoutMs: 1_000,
    })
    await ctx.plugin(XlSubprocessRuntime)
    const spec = (argv: string[]): SubprocessSpawnSpec => ({
      argv,
      cwd: '/dsh/workspace',
      graceMs: 3_000,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    })
    try {
      assert.equal(isWorkerShellProgram('git'), true, 'the direct argv router sees git as a Worker program')
      const init = (ctx.get('subprocess') as SubprocessRuntime).spawn(spec(['git', 'init', '-b', 'main']))
      assert.deepEqual(await init.done, { exitCode: 0, signal: null })
      // A host child process could not have used this cwd: it exists only below
      // the VFS root. `git init` wrote the repository there through node:fs.
      assert.equal(existsSync(join(root, 'dsh/workspace/.git/HEAD')), true)
      writeFileSync(join(root, 'dsh/workspace/from-subprocess.md'), 'x\n')
      const status = (ctx.get('subprocess') as SubprocessRuntime).spawn(spec(['git', 'status', '--porcelain']))
      assert.deepEqual(await status.done, { exitCode: 0, signal: null })
      assert.equal(status.collected.stdout?.readFrom(0).text, '?? from-subprocess.md\n')
    } finally {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
      if (savedShell === undefined) delete process.env.PDSH_SHELL
      else process.env.PDSH_SHELL = savedShell
    }
  })
})

test('toolbox commands pass argv, cwd, env and stdin through and keep the exit status', async () => {
  const root = vfsRoot()
  const requests: ToolboxRunRequest[] = []
  const toolbox = {
    list: () => [
      { program: 'python3', aliases: ['python'], description: 'stub interpreter' },
    ],
    has: (program: string) => program === 'python3' || program === 'python',
    preopenTable: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
    async run(request: ToolboxRunRequest): Promise<ToolboxResult> {
      requests.push(request)
      request.onStdout?.(new TextEncoder().encode('ok\n'))
      request.onStderr?.(new TextEncoder().encode('warn\n'))
      return {
        program: request.program,
        exitCode: 3,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: 3,
        stderrBytes: 5,
      }
    },
  }
  setWorkerToolbox(toolbox)
  try {
    assert.equal(getWorkerToolbox(), toolbox, 'the shell reads the installed toolbox')
    assert.equal(isWorkerShellProgram('python3'), true)
    assert.equal(isWorkerShellProgram('python'), true)
    assert.equal(isWorkerShellProgram('bash'), false)
    const commands = createWorkerCommands({ git: false, toolbox })
    assert.ok(commands.some(command => command.name === 'python3'))
    assert.ok(commands.some(command => command.name === 'python'))
    const shell = new WorkerShell({ fs: new VfsFileSystem({ root }), commands })
    const result = await shell.run(['bash', '-c', 'echo "print(1)" | python3 -'], {
      cwd: '/dsh/workspace',
      env: { PDSH_PYTHON_PROBE: '1' },
    })
    assert.equal(result.exitCode, 3, 'the toolbox exit status survives the shell')
    assert.equal(result.stdout, 'ok\n')
    assert.equal(result.stderr, 'warn\n')
    const request = requests[0] as ToolboxRunRequest
    assert.deepEqual(request.argv, ['-'])
    assert.equal(request.cwd, '/workspace', 'the host cwd is mapped through the preopens')
    assert.equal(new TextDecoder().decode(request.stdin), 'print(1)\n')
    assert.equal(request.env?.PDSH_PYTHON_PROBE, '1')
    assert.equal(request.env?.PWD, '/workspace', 'PWD follows the mapped guest cwd')
  } finally {
    setWorkerToolbox(undefined)
  }
})

test('the installed toolbox registers python3 for the shell (real toolbox dispatch)', { timeout: 20_000 }, async () => {
  const moduleBytes = readFileSync(new URL('../../src/testdata/fd-echo.wasm', import.meta.url))
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/in.txt', 'hello\n')
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'python3',
      module: { url: 'image://python3.wasm', load: async () => moduleBytes },
      description: 'fd-echo stand-in at the python3 program name',
    }],
    backend,
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => {
      const worker = new Worker(new URL('../../src/node-worker-harness.ts', import.meta.url))
      return workerTransport(worker as unknown as WorkerLike)
    },
    workerReadyTimeoutMs: 5_000,
  })
  const root = vfsRoot()
  try {
    setWorkerToolbox(toolbox)
    assert.equal(isWorkerShellProgram('python3'), true)
    const commands = createWorkerCommands({ git: false })
    assert.ok(commands.some(command => command.name === 'python3'))
    const shell = new WorkerShell({ fs: new VfsFileSystem({ root }), commands })
    const result = await shell.run(['bash', '-c', 'python3 in.txt out.txt'], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stdout, '[in.txt] hello\n\n')
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/out.txt') ?? new Uint8Array()), 'echo:hello\n')
  } finally {
    setWorkerToolbox(undefined)
    await toolbox.dispose()
  }
})
