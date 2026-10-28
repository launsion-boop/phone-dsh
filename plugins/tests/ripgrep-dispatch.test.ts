// SPDX-License-Identifier: MIT
// G2 regression: DSH's `tool-fs-search` spawns the packaged ripgrep by the
// absolute path from `resolveRgPath()` (`argv[0] = /.../@vscode/ripgrep.../rg`,
// optionally the single-file `<exe>-rg` sidecar). The Worker dispatch must
// resolve that executable shape to the `rg` program identity: to the host
// accelerator (EXEC_REQ 0x20, normalized bare argv) when the HELLO caps
// advertise `rg`, and to the Worker `rg` shim over just-bash's built-in when
// they do not. A path that resolves to no known program keeps failing loud.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import { after, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import {
  buildGlobCommand,
  buildGrepCommand,
  parseGrepMatches,
  resolveRgPath,
  runRipgrep,
} from '@deepseek-ai/dsh-tool-fs-search'
import { FrameType } from '../channel/src/index.ts'
import { XlExecBridge, toolCallStorage } from '../exec-bridge/src/index.ts'
import { XlGuestSandboxProvider } from '../subprocess-xl/src/sandbox.ts'
import {
  CONFINE_MARKER,
  ShellWorkerProcess,
  XlSubprocessRuntime,
  resolveProgramIdentity,
  workerRipgrepArgv,
} from '../subprocess-xl/src/index.ts'
import { MockChannel, eventually, jsonPayload } from './test-channel.ts'

const roots: string[] = []
const SAVED_ENV = {
  PDSH_SHELL: process.env.PDSH_SHELL,
  PDSH_VFS_ROOT: process.env.PDSH_VFS_ROOT,
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  for (const [name, value] of Object.entries(SAVED_ENV)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
})

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly subprocess: SubprocessRuntime
  readonly root: string
  dispose(): Promise<void>
}

/** One isolated channel-transport Worker with a VFS root on disk. */
async function harness(options: { caps?: readonly string[]; nextMseq?: bigint } = {}): Promise<Harness> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-rg-dispatch-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  process.env.PDSH_VFS_ROOT = root
  delete process.env.PDSH_SHELL
  const mock = new MockChannel({ caps: options.caps ?? [], nextMseq: options.nextMseq ?? 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_RG_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_RG_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1_000,
  })
  await ctx.plugin(XlSubprocessRuntime)
  return {
    ctx,
    mock,
    subprocess: ctx.get('subprocess') as SubprocessRuntime,
    root,
    async dispose() {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    },
  }
}

const collect = { maxBytes: 64 * 1024 }

function spec(argv: string[], extra: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec {
  return { argv, cwd: '/dsh/workspace', graceMs: 3_000, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra }
}

function seedWorkspace(root: string): void {
  writeFileSync(join(root, 'dsh/workspace/a.txt'), 'hello needle\n')
  writeFileSync(join(root, 'dsh/workspace/b.md'), 'other\n')
  mkdirSync(join(root, 'dsh/workspace/sub'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/sub/c.txt'), 'needle too\n')
}

function complete(mock: MockChannel, execId: string, stdout = ''): void {
  mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 1 })
  let seq = 1
  if (stdout !== '') mock.execEvent({ type: 'output', exec_id: execId, seq: seq++, stream: 'stdout', data: Buffer.from(stdout).toString('base64') })
  mock.execEvent({ type: 'exit', exec_id: execId, seq, code: 0, signal: null, status: 'exited', quiescent: true })
}

/** The minimal slice of `Context` + `ToolExecution` `runRipgrep` touches. */
type ToolContext = Parameters<typeof runRipgrep>[0]
type ToolExecution = Parameters<typeof runRipgrep>[1]
const RAW_MAX = 1024 * 1024
const STDERR_MAX = 8 * 1024
const GRACE = 3_000
function toolContext(h: Harness): ToolContext {
  return {
    subprocess: h.subprocess,
    workingDirectory: { ensure: async () => '/dsh/workspace' },
  } as unknown as ToolContext
}
function toolExecution(): ToolExecution {
  return { agent: {}, signal: new AbortController().signal } as unknown as ToolExecution
}

test('identity: the ripgrep executable shapes resolve to rg and other programs keep their own identity', () => {
  // Every shape resolveRgPath() can return.
  for (const path of [
    '/plugins/node_modules/@vscode/ripgrep-darwin-arm64/bin/rg',
    '/plugins/node_modules/@vscode/ripgrep/bin/rg',
    '/opt/pkg-runtime/lib/dsh-rg',
    '/usr/local/bin/node-rg',
  ]) {
    assert.equal(resolveProgramIdentity(path), 'rg', `${path} is the packaged ripgrep`)
  }
  assert.equal(resolveProgramIdentity('rg'), 'rg')
  assert.equal(resolveProgramIdentity('/usr/bin/jaq', ['jaq']), 'jaq', 'an advertised program is known by its basename')
  assert.equal(resolveProgramIdentity('/usr/bin/jaq'), '/usr/bin/jaq', 'an unadvertised path keeps failing loud')
  assert.equal(resolveProgramIdentity('/usr/bin/not-a-search-program', ['rg', 'jaq']), '/usr/bin/not-a-search-program')
})

test('identity: the Worker-local rg argv keeps glob searches intact and translates only the built-in-only flags elsewhere', () => {
  // G2-FIX-16 repair: a glob search is owned by the shell-ext shim, which
  // applies the globset and then orders by mtime. Pre-translating
  // `--sort=modified` to `--sort=path` here would erase the ordering before
  // the shim can honour it, so a glob argv reaches the shim verbatim (argv[0]
  // normalized to the program identity).
  assert.deepEqual(
    workerRipgrepArgv([
      '/plugins/node_modules/@vscode/ripgrep/bin/rg', '--no-config', '--files', '--glob=*.txt', '--sort=modified', '--no-ignore', '--', '.',
    ]),
    ['rg', '--no-config', '--files', '--glob=*.txt', '--sort=modified', '--no-ignore', '--', '.'],
  )
  assert.deepEqual(
    workerRipgrepArgv(['rg', '--json', '--regexp=needle', '--iglob=*.PY', '--sort=modified']),
    ['rg', '--json', '--regexp=needle', '--iglob=*.PY', '--sort=modified'],
  )
  // Without a glob the shell-ext shim stays out of the way: the built-in
  // still needs the flags it documents as unsupported translated.
  assert.deepEqual(
    workerRipgrepArgv(['/plugins/node_modules/@vscode/ripgrep/bin/rg', '--no-config', '--json', '--regexp=needle', '--', 'sub']),
    ['rg', '--json', '--regexp=needle', 'sub'],
  )
  assert.deepEqual(
    workerRipgrepArgv(['rg', '--no-config', '--files', '--sort=modified', '--no-ignore', '--hidden', '--', '.']),
    ['rg', '--files', '--sort=path', '--no-ignore', '--hidden', '.'],
  )
})

test('regression: resolveRgPath()-shaped argv[0] is the Worker rg program, not a host child process', async () => {
  const rg = await resolveRgPath()
  assert.ok(isAbsolute(rg), `resolveRgPath() must stay an absolute path, got ${JSON.stringify(rg)}`)
  // An unrelated accelerator is advertised: only the rg identity decides.
  const h = await harness({ caps: ['accelerator:jaq'] })
  seedWorkspace(h.root)
  try {
    const handle = h.subprocess.spawn(spec([rg, '--no-config', ...buildGlobCommand({ pattern: '*.txt' })]))
    // Await the handle either way: the pre-fix local spawn rejects, and a
    // rejected handle must settle before the provider is disposed.
    const settled = handle.done.then(
      value => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    )
    const result = await settled
    assert.ok(
      handle instanceof ShellWorkerProcess,
      `the packaged ripgrep path fell through to ${handle.constructor.name}; it must resolve to the Worker shell rg program`,
    )
    assert.equal(result.ok, true, result.ok ? '' : `the packaged ripgrep path did not run in the Worker: ${String(result.error)}`)
    assert.deepEqual(result.ok ? result.value : undefined, { exitCode: 0, signal: null })
    const stdout = handle.collected.stdout?.readFrom(0).text ?? ''
    assert.match(stdout, /a\.txt/)
    assert.match(stdout, /sub\/c\.txt/)
    // The host did not advertise rg: the exchange stays in the Worker.
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('host advertises rg: the glob spawn shape becomes EXEC_REQ 0x20 with a normalized argv', async () => {
  const h = await harness({ caps: ['channel/1', 'exec/1', 'accelerator:rg'], nextMseq: 49n })
  const rg = await resolveRgPath()
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const globArgv = buildGlobCommand({ pattern: '*.txt' })
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec([rg, '--no-config', ...globArgv])),
    )
    const settled = handle.done.then(value => value, (error: unknown) => error)
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    // The identity is the accelerator name; `--no-config` and every DSH search
    // flag stay because the host rg is the real ripgrep.
    assert.deepEqual(request.argv, ['rg', '--no-config', ...globArgv])
    assert.equal(request.cwd, '/dsh/workspace')
    assert.equal(request.requires_mseq, 48)
    assert.equal((request.env as Record<string, string>).XL_IDEMPOTENCY_KEY, key)
    assert.match(String(request.idem_key), /^[0-9a-f]{64}$/)
    complete(h.mock, String(request.exec_id), 'a.txt\nsub/c.txt\n')
    assert.deepEqual(await settled, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'a.txt\nsub/c.txt\n')
  } finally {
    await h.dispose()
  }
})

test('host advertises rg: the grep spawn shape keeps the --json flag set and reaches the host once', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 3n })
  const rg = await resolveRgPath()
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const grepArgv = buildGrepCommand({ pattern: 'needle' })
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec([rg, '--no-config', ...grepArgv])),
    )
    const settled = handle.done.then(value => value, (error: unknown) => error)
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.deepEqual(request.argv, ['rg', '--no-config', ...grepArgv])
    assert.equal(request.requires_mseq, 2)
    complete(h.mock, String(request.exec_id))
    assert.deepEqual(await settled, { exitCode: 0, signal: null })
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 1, 'one accelerator spawn is one EXEC_REQ')
  } finally {
    await h.dispose()
  }
})

test('host advertises rg: a confined packaged-ripgrep spawn keeps its confine field and normalized argv', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  const rg = await resolveRgPath()
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec([
        CONFINE_MARKER, 'workspace-write', '/dsh/workspace', '--', rg, '--no-config', '--json', 'needle',
      ])),
    )
    const settled = handle.done.then(value => value, (error: unknown) => error)
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.deepEqual(request.argv, ['rg', '--no-config', '--json', 'needle'])
    assert.deepEqual(request.confine, { mode: 'workspace-write', workspace_root: '/dsh/workspace' })
    complete(h.mock, String(request.exec_id))
    assert.deepEqual(await settled, { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('sandbox: a confined packaged-ripgrep path is recognized as the advertised read-only accelerator', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  const rg = await resolveRgPath()
  try {
    await h.ctx.plugin(XlGuestSandboxProvider)
    const sandbox = h.ctx.get('sandbox') as XlGuestSandboxProvider
    const confined = await sandbox.confine([rg, '--no-config', '--json', 'needle'], {
      mode: 'workspace-write',
      workspaceRoot: '/dsh/workspace',
    })
    assert.deepEqual(
      confined.argv,
      [rg, '--no-config', '--json', 'needle'],
      'a host accelerator is read-only by construction, so no Worker confine marker is needed',
    )
  } finally {
    await h.dispose()
  }
})

test('an absolute path that resolves to no known program still fails loud, never forwarded', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const missing = '/opt/pdsh-not-a-program/definitely-not-a-search-binary'
    const handle = h.subprocess.spawn(spec([missing, '--version']))
    await assert.rejects(handle.done, (error: unknown) => (error as { code?: string }).code === 'ENOENT')
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('e2e: the glob tool returns results from the Worker VFS through the packaged ripgrep path', async () => {
  const h = await harness()
  seedWorkspace(h.root)
  try {
    const run = await runRipgrep(
      toolContext(h),
      toolExecution(),
      'glob',
      buildGlobCommand({ pattern: '*.txt' }),
      RAW_MAX,
      GRACE,
      STDERR_MAX,
    )
    assert.equal(run.noMatches, false)
    const paths = run.stdout.trim().split('\n')
    assert.ok(paths.includes('a.txt'), `glob result names a.txt: ${JSON.stringify(run.stdout)}`)
    assert.ok(paths.includes('sub/c.txt'), `glob result names sub/c.txt: ${JSON.stringify(run.stdout)}`)
    // A search root rides behind `--`; just-bash's rg has no end-of-options
    // marker, so the Worker-local argv keeps the operand and drops the marker.
    const rooted = await runRipgrep(
      toolContext(h),
      toolExecution(),
      'glob',
      buildGlobCommand({ pattern: '*.txt', path: 'sub' }),
      RAW_MAX,
      GRACE,
      STDERR_MAX,
    )
    assert.deepEqual(rooted.stdout.trim().split('\n'), ['sub/c.txt'])
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('e2e: the grep tool parses matches from the Worker VFS through the packaged ripgrep path', async () => {
  const h = await harness()
  seedWorkspace(h.root)
  try {
    const run = await runRipgrep(
      toolContext(h),
      toolExecution(),
      'grep',
      buildGrepCommand({ pattern: 'needle' }),
      RAW_MAX,
      GRACE,
      STDERR_MAX,
    )
    const matches = parseGrepMatches(run.stdout)
    assert.deepEqual(matches.map(match => [match.path, match.lineNumber, match.line]), [
      ['a.txt', 1, 'hello needle'],
      ['sub/c.txt', 1, 'needle too'],
    ])
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('e2e: the grep tool reaches the advertised host rg through EXEC_REQ and parses its events', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 5n })
  seedWorkspace(h.root)
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const jsonLine = JSON.stringify({
    type: 'match',
    data: {
      path: { text: 'a.txt' },
      lines: { text: 'hello needle\n' },
      line_number: 1,
      absolute_offset: 6,
      submatches: [{ match: { text: 'needle' }, start: 6, end: 12 }],
    },
  })
  try {
    const running = toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => runRipgrep(
        toolContext(h),
        toolExecution(),
        'grep',
        buildGrepCommand({ pattern: 'needle' }),
        RAW_MAX,
        GRACE,
        STDERR_MAX,
      ),
    )
    running.catch(() => {})
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.deepEqual(request.argv, ['rg', '--no-config', ...buildGrepCommand({ pattern: 'needle' })])
    assert.equal(request.requires_mseq, 4)
    complete(h.mock, String(request.exec_id), `${jsonLine}\n`)
    const run = await running
    const matches = parseGrepMatches(run.stdout)
    assert.deepEqual(matches.map(match => [match.path, match.lineNumber, match.line]), [['a.txt', 1, 'hello needle']])
  } finally {
    await h.dispose()
  }
})

// G2-FIX-16: the Worker-local ripgrep path must keep ripgrep's globset
// semantics. DSH's real glob argv starts with `**/*.py` (zero or more
// components) and pairs `!**/.git` with `!**/.git/**` to prune VCS metadata;
// just-bash's built-in `rg` matched neither and returned a clean empty result.
test('regression G2-B08: e2e glob **/*.py keeps root-level files and prunes .git', async () => {
  const h = await harness()
  seedWorkspace(h.root)
  writeFileSync(join(h.root, 'dsh/workspace/root.py'), 'print("root")\n')
  mkdirSync(join(h.root, 'dsh/workspace/sub/deep'), { recursive: true })
  writeFileSync(join(h.root, 'dsh/workspace/sub/deep/nested.py'), 'print("nested")\n')
  mkdirSync(join(h.root, 'dsh/workspace/.git/objects'), { recursive: true })
  writeFileSync(join(h.root, 'dsh/workspace/.git/objects/leak.py'), 'print("git")\n')
  // Pin the modification times so the expected order is deterministic. This
  // vector keeps the alphabetical order on purpose (the mtime-order vector is
  // the next test).
  const rootFile = join(h.root, 'dsh/workspace/root.py')
  const nestedFile = join(h.root, 'dsh/workspace/sub/deep/nested.py')
  utimesSync(rootFile, new Date('2024-01-01T00:00:00Z'), new Date('2024-01-01T00:00:00Z'))
  utimesSync(nestedFile, new Date('2024-02-01T00:00:00Z'), new Date('2024-02-01T00:00:00Z'))
  try {
    const run = await runRipgrep(
      toolContext(h),
      toolExecution(),
      'glob',
      buildGlobCommand({ pattern: '**/*.py' }),
      RAW_MAX,
      GRACE,
      STDERR_MAX,
    )
    assert.equal(run.noMatches, false)
    assert.deepEqual(run.stdout.trim().split('\n'), ['root.py', 'sub/deep/nested.py'])
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

// G2-FIX-16 repair: DSH's glob command is `--sort=modified`. Translating that
// flag away before the shell-ext shim runs left the filtered result in path
// order, so the tool's "modification-time order" (and its over-cap head) was
// silently wrong. Pin two mtimes whose order is the reverse of the path order.
test('regression G2-B08: the Worker glob result keeps --sort=modified order (non-alphabetical mtimes)', async () => {
  const h = await harness()
  seedWorkspace(h.root)
  const rootFile = join(h.root, 'dsh/workspace/root.py')
  const nestedFile = join(h.root, 'dsh/workspace/sub/deep/nested.py')
  mkdirSync(join(h.root, 'dsh/workspace/sub/deep'), { recursive: true })
  writeFileSync(rootFile, 'print("root")\n')
  writeFileSync(nestedFile, 'print("nested")\n')
  utimesSync(nestedFile, new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'))
  utimesSync(rootFile, new Date('2024-01-01T00:00:00Z'), new Date('2024-01-01T00:00:00Z'))
  try {
    const run = await runRipgrep(
      toolContext(h),
      toolExecution(),
      'glob',
      buildGlobCommand({ pattern: '**/*.py' }),
      RAW_MAX,
      GRACE,
      STDERR_MAX,
    )
    assert.equal(run.noMatches, false)
    assert.deepEqual(
      run.stdout.trim().split('\n'),
      ['sub/deep/nested.py', 'root.py'],
      `mtime order must win over path order: ${JSON.stringify(run.stdout)}`,
    )
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})
