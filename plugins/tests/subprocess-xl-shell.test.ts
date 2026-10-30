// SPDX-License-Identifier: MIT
// W5-SHELL: subprocess-xl dispatch. `bash -c` runs on the Worker's just-bash
// core; a host accelerator inside it crosses the exec bridge; the sub-agent cap
// is 2 (1 on thermal fair) and a fatal channel event closes admission.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime } from '@deepseek-ai/dsh-subprocess'
import { FrameType } from '../channel/src/index.ts'
import { XlExecBridge, deriveIdemKey, toolCallStorage } from '../exec-bridge/src/index.ts'
import { acceleratorExecID } from '../shell-ext/src/index.ts'
import { AdmissionClosedError, ExecutionGovernor, XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import type { XlWorkerSpawnSpec } from '../subprocess-xl/src/index.ts'
import { MockChannel, eventually, jsonPayload } from './test-channel.ts'

const roots: string[] = []
const SAVED_ENV = {
  PDSH_SHELL: process.env.PDSH_SHELL,
  PDSH_VFS_ROOT: process.env.PDSH_VFS_ROOT,
  PDSH_SHELL_TIMEOUT_MS: process.env.PDSH_SHELL_TIMEOUT_MS,
  PDSH_THERMAL_STATE: process.env.PDSH_THERMAL_STATE,
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  restoreEnv()
})

function restoreEnv(): void {
  for (const [name, value] of Object.entries(SAVED_ENV)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
}

interface HarnessOptions {
  readonly caps?: readonly string[]
  readonly nextMseq?: bigint
  readonly env?: Readonly<Record<string, string>>
}

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly subprocess: SubprocessRuntime
  dispose(): Promise<void>
}

async function harness(options: HarnessOptions = {}): Promise<Harness> {
  for (const [name, value] of Object.entries(options.env ?? {})) process.env[name] = value
  const mock = new MockChannel({ caps: options.caps ?? [], nextMseq: options.nextMseq ?? 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_SHELL_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_SHELL_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1_000,
  })
  await ctx.plugin(XlSubprocessRuntime)
  return {
    ctx,
    mock,
    subprocess: ctx.get('subprocess') as SubprocessRuntime,
    async dispose() {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
      restoreEnv()
    },
  }
}

const collect = { maxBytes: 64 * 1024 }

function spec(cwd: string, argv: string[], extra: Partial<XlWorkerSpawnSpec> = {}): XlWorkerSpawnSpec {
  return { argv, cwd, graceMs: 3_000, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra }
}

function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-dispatch-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  return root
}

function complete(mock: MockChannel, execId: string, stdout = ''): void {
  mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 1 })
  let seq = 1
  if (stdout !== '') mock.execEvent({ type: 'output', exec_id: execId, seq: seq++, stream: 'stdout', data: Buffer.from(stdout).toString('base64') })
  mock.execEvent({ type: 'exit', exec_id: execId, seq, code: 0, signal: null, status: 'exited', quiescent: true })
}

test('dispatch: bash -c runs on just-bash against the Worker VFS, not a host process', async () => {
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_SHELL: 'just-bash', PDSH_VFS_ROOT: root } })
  try {
    const handle = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'echo hi > a.txt; for x in 1 2; do echo "$x"; done',
    ]))
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, '1\n2\n')
    // A real child process could not have used this cwd: it exists only in the
    // VFS root the adapter maps onto.
    assert.equal(readFileSync(join(root, 'dsh/workspace/a.txt'), 'utf8'), 'hi\n')
  } finally {
    await h.dispose()
  }
})

test('dispatch: a direct spawn(["find", ...]) reaches the same -type shim as bash -c', async () => {
  const root = virtualRoot()
  mkdirSync(join(root, 'dsh/workspace/sub'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a\n')
  const h = await harness({ env: { PDSH_VFS_ROOT: root } })
  try {
    // Before `find` joined WORKER_SHELL_PROGRAMS this took LocalWorkerProcess:
    // a real child process with cwd `/dsh/workspace`, which does not exist.
    const link = h.subprocess.spawn(spec('/dsh/workspace', ['find', '.', '-type', 'l']))
    assert.deepEqual(await link.done, { exitCode: 0, signal: null })
    assert.equal(link.collected.stdout?.readFrom(0).text, '')
    assert.equal(link.collected.stderr?.readFrom(0).text, '')

    const direct = h.subprocess.spawn(spec('/dsh/workspace', ['find', '.', '-type', 'f', '-printf', '%P\n']))
    assert.deepEqual(await direct.done, { exitCode: 0, signal: null })
    assert.equal(direct.collected.stdout?.readFrom(0).text, 'a.txt\n')
    const script = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', "find . -type f -printf '%P\\n'"]))
    assert.deepEqual(await script.done, { exitCode: 0, signal: null })
    assert.equal(script.collected.stdout?.readFrom(0).text, direct.collected.stdout?.readFrom(0).text)
  } finally {
    await h.dispose()
  }
})

test('dispatch: piped stdin is fed to the just-bash command', async () => {
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_VFS_ROOT: root } })
  try {
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'cat'], {
      stdio: { stdin: 'pipe', stdout: collect, stderr: collect },
    }))
    handle.stdin?.write('fed through the VFS shell\n')
    handle.stdin?.end()
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'fed through the VFS shell\n')
  } finally {
    await h.dispose()
  }
})

test('dispatch: terminate releases a bash -c waiting for piped stdin', async () => {
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_VFS_ROOT: root } })
  try {
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'cat'], {
      stdio: { stdin: 'pipe', stdout: collect, stderr: collect },
    }))
    await new Promise(resolve => setTimeout(resolve, 10))
    handle.terminate()
    assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' })
  } finally {
    await h.dispose()
  }
})

test('dispatch: PDSH_SHELL=runtime sends bash -c back to the runtime shell', async () => {
  const h = await harness({ env: { PDSH_SHELL: 'runtime' } })
  try {
    delete process.env.PDSH_VFS_ROOT
    // A cwd that only exists in a VFS makes a real spawn fail, while the
    // just-bash path above succeeds against the same virtual path.
    const missing = join(tmpdir(), `pdsh-runtime-${String(Date.now())}-${Math.random().toString(16).slice(2)}`)
    const handle = h.subprocess.spawn(spec(missing, ['bash', '-c', 'echo hi']))
    await assert.rejects(handle.done, (error: unknown) => (error as { code?: string }).code === 'ENOENT')
  } finally {
    await h.dispose()
  }
})

test('dispatch: an accelerator inside bash -c reaches 0x20 with requires_mseq and idem_key', async () => {
  const root = virtualRoot()
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 49n, env: { PDSH_VFS_ROOT: root } })
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'rg --json needle'])),
    )
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.deepEqual(request.argv, ['rg', '--json', 'needle'])
    assert.equal(request.cwd, '/dsh/workspace')
    assert.equal(request.requires_mseq, 48)
    assert.match(String(request.idem_key), /^[0-9a-f]{64}$/)
    assert.equal((request.env as Record<string, string>).XL_IDEMPOTENCY_KEY, key)
    complete(h.mock, String(request.exec_id), 'match\n')
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'match\n')
  } finally {
    await h.dispose()
  }
})

test('dispatch: an accelerator default deadline follows the command budget, not cancel grace', async () => {
  const root = virtualRoot()
  const h = await harness({ caps: ['accelerator:rg'], env: {
    PDSH_VFS_ROOT: root,
    PDSH_SHELL_TIMEOUT_MS: '45000',
  } })
  const key = 'xl1-command-budget-deadline'
  try {
    const started = Date.now()
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'rg --json needle'])),
    )
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.equal(request.grace_ms, 3_000)
    assert.ok(Number(request.deadline) >= started + 44_000)
    assert.ok(Number(request.deadline) <= Date.now() + 45_000)
    complete(h.mock, String(request.exec_id), 'match\n')
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('dispatch: the console deadline is the host deadline and an exported key cannot pick the identity', async () => {
  const root = virtualRoot()
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 49n, env: { PDSH_VFS_ROOT: root } })
  const ambient = 'xl1-ambient-call'
  const consoleId = 'console-deadline-1'
  try {
    const started = Date.now()
    const handle = await toolCallStorage().run(
      { sessionId: 's', callId: 'c', key: ambient, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec('/dsh/workspace', [
        'bash', '-c', 'XL_IDEMPOTENCY_KEY=scripted rg --json needle',
      ], {
        timeoutMs: 5_000,
        idempotencyKey: consoleId,
        graceMs: 250,
      })),
    )
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.equal((request.env as Record<string, string>).XL_IDEMPOTENCY_KEY, consoleId)
    assert.equal(request.idem_key, deriveIdemKey(
      request.argv as string[],
      String(request.cwd),
      request.env as Record<string, string>,
      { key: consoleId },
    ))
    assert.equal(request.exec_id, acceleratorExecID(request.idem_key!, 0))
    assert.equal(request.grace_ms, 250)
    assert.ok(Number(request.deadline) >= started + 4_000, 'the EXEC_REQ deadline is the requested 5 s, not graceMs')
    complete(h.mock, String(request.exec_id), 'match\n')
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('dispatch: terminate force-settles an ignored host run after grace and releases the lane', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 1n })
  const key = 'xl1-lane-release'
  try {
    const first = h.subprocess.spawn(spec('/dsh/workspace', ['rg', '--json', 'needle'], {
      timeoutMs: 5_000,
      idempotencyKey: key,
      graceMs: 100,
    }))
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const firstId = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)['exec_id'] as string
    first.terminate()
    assert.equal(await first.waitForExit(), true)
    await assert.rejects(first.done, /did not confirm termination|closed before/u)
    // The forced execution's late event has no retained observer.
    h.mock.execEvent({ type: 'exit', exec_id: firstId, seq: 1, code: 0, signal: null, status: 'exited', quiescent: true })

    const second = h.subprocess.spawn(spec('/dsh/workspace', ['rg', '--json', 'after'], {
      timeoutMs: 5_000,
      idempotencyKey: 'xl1-lane-after',
      graceMs: 250,
    }))
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 2)
    const secondId = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[1]!)['exec_id'] as string
    assert.notEqual(secondId, firstId)
    complete(h.mock, secondId, 'after\n')
    assert.deepEqual(await second.done, { exitCode: 0, signal: null })
    assert.equal(second.collected.stdout?.readFrom(0).text, 'after\n')
  } finally {
    await h.dispose()
  }
})

test('dispatch: a direct advertised argv carries its requested host deadline', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 1n })
  const consoleId = 'console-direct-deadline'
  try {
    const started = Date.now()
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['rg', '--json', 'needle'], {
      timeoutMs: 4_000,
      idempotencyKey: consoleId,
      graceMs: 250,
    }))
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.equal((request.env as Record<string, string>).XL_IDEMPOTENCY_KEY, consoleId)
    assert.equal(request.grace_ms, 250)
    assert.ok(Number(request.deadline) >= started + 3_000, 'direct host argv must not omit the deadline')
    complete(h.mock, String(request.exec_id))
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('dispatch: the spawn signal cancels a running just-bash command', async () => {
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_VFS_ROOT: root } })
  try {
    const controller = new AbortController()
    // The command records that the shell is executing it before it blocks in
    // `sleep`. Waiting for that marker (rather than a fixed 20 ms timer) keeps
    // the abort out of just-bash's startup window: an abort that lands before
    // the shell has attached its cancellation listener is reported by just-bash
    // as its internal deadline exit 124, not as the spawn signal. This test is
    // about cancelling a running command, and the marker makes that the
    // precondition instead of a scheduling race.
    const marker = join(root, 'dsh/workspace/cancel-me.txt')
    const handle = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'echo started > cancel-me.txt; sleep 5; echo never',
    ], { signal: controller.signal }))
    const deadline = Date.now() + 5_000
    while (!existsSync(marker)) {
      if (Date.now() > deadline) assert.fail('the just-bash command never wrote its start marker')
      await new Promise(resolve => setTimeout(resolve, 2))
    }
    controller.abort(new Error('test cancel'))
    assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' })
    assert.equal(handle.collected.stdout?.readFrom(0).text, '')
  } finally {
    await h.dispose()
  }
})

test('governor: the sub-agent cap is 2, 1 on thermal fair, and admission close rejects waiters', async () => {
  const governor = new ExecutionGovernor({ maxConcurrent: 2 })
  const first = await governor.acquire()
  const second = await governor.acquire()
  assert.equal(governor.activeCount, 2)
  const third = governor.acquire()
  await new Promise(resolve => setTimeout(resolve, 10))
  assert.equal(governor.waitingCount, 1)
  first()
  const releaseThird = await third
  assert.equal(governor.activeCount, 2)
  second()
  releaseThird()

  governor.setThermal('fair')
  assert.equal(governor.limit, 1)

  const held = await governor.acquire()
  const queued = governor.acquire()
  await new Promise(resolve => setTimeout(resolve, 5))
  governor.close('BAD_SEQ: test')
  await assert.rejects(queued, AdmissionClosedError)
  held()
  await assert.rejects(governor.acquire(), AdmissionClosedError)
})

test('governor: thermal is a host signal, not a non-contract LIFECYCLE field', () => {
  const globals = globalThis as { __PDSH_LIFECYCLE__?: unknown }
  const previous = globals.__PDSH_LIFECYCLE__
  globals.__PDSH_LIFECYCLE__ = { state: 'run', budget: 0, admission: 'open', reason: 'thermal:fair', thermal: 'fair' }
  try {
    const governor = new ExecutionGovernor({ maxConcurrent: 2, thermal: 'nominal' })
    // channel.md §4.5 defines state/budget/admission/reason only: neither a
    // `thermal` field nor a `thermal:*` reason may change the cap.
    assert.equal(governor.thermalState, 'nominal')
    assert.equal(governor.limit, 2)
    governor.setThermal('fair')
    assert.equal(governor.thermalState, 'fair')
    assert.equal(governor.limit, 1)
  } finally {
    if (previous === undefined) delete globals.__PDSH_LIFECYCLE__
    else globals.__PDSH_LIFECYCLE__ = previous
  }
})

test('dispatch: thermal fair serializes two bash -c executions on different workspaces', async () => {
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_VFS_ROOT: root, PDSH_THERMAL_STATE: 'fair' } })
  try {
    const first = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'echo A1 >> /dsh/workspace/log; sleep 0.15; echo A2 >> /dsh/workspace/log',
    ]))
    const second = h.subprocess.spawn(spec('/dsh/home', [
      'bash', '-c', 'echo B1 >> /dsh/workspace/log; echo B2 >> /dsh/workspace/log',
    ]))
    await Promise.all([first.done, second.done])
    assert.deepEqual(readFileSync(join(root, 'dsh/workspace/log'), 'utf8').trim().split('\n'), ['A1', 'A2', 'B1', 'B2'])
  } finally {
    await h.dispose()
  }
})

test('dispatch: a fatal channel ERROR closes admission for new executions', async () => {
  const h = await harness()
  try {
    h.mock.fatal('BAD_SEQ', 'sequence mismatch')
    assert.throws(
      () => h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo hi'])),
      (error: unknown) => error instanceof AdmissionClosedError,
    )
  } finally {
    await h.dispose()
  }
})

test('dispatch: a materialised `command -v` path routes back to the Worker command table', async () => {
  // G2-FIX-25: `command -v tar` answers `/usr/bin/tar`; a caller that spawns
  // that path must reach the same Worker program, not the runtime's host shell.
  const root = virtualRoot()
  writeFileSync(join(root, 'dsh/workspace/t.txt'), 'hello\n')
  const h = await harness({ env: { PDSH_SHELL: 'just-bash', PDSH_VFS_ROOT: root } })
  try {
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['/usr/bin/find', '.', '-maxdepth', '1', '-type', 'f', '-printf', '%P|%y\n']))
    await handle.done
    assert.equal(handle.collected.stdout?.readFrom(0).text, 't.txt|f\n')
  } finally {
    await h.dispose()
  }
})

test('dispatch: command stderr follows the script redirection, not the captured stream', async () => {
  // G2-FIX-68: the interpreter owns fd redirection. `tar`'s diagnostic (and
  // the contract trailer it appends to its own stderr) must land in `err.txt`
  // under `2>err.txt`, and must be discarded under `2>/dev/null`; neither may
  // appear in `collected.stderr` after ShellWorkerProcess emits the result.
  const root = virtualRoot()
  const h = await harness({ env: { PDSH_SHELL: 'just-bash', PDSH_VFS_ROOT: root } })
  try {
    const toFile = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'tar --bogus 2>err.txt; cat err.txt',
    ]))
    assert.deepEqual(await toFile.done, { exitCode: 0, signal: null })
    const redirected = toFile.collected.stdout?.readFrom(0).text ?? ''
    assert.match(redirected, /tar: unrecognized option '--bogus'/)
    assert.match(redirected, /pdsh-shell: exit=2 program=tar reason=unsupported-option/)
    assert.equal(readFileSync(join(root, 'dsh/workspace/err.txt'), 'utf8'), redirected)
    assert.equal(toFile.collected.stderr?.readFrom(0).text, '')

    const discarded = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'tar --bogus 2>/dev/null']))
    assert.deepEqual(await discarded.done, { exitCode: 2, signal: null })
    assert.equal(discarded.collected.stdout?.readFrom(0).text, '')
    assert.equal(discarded.collected.stderr?.readFrom(0).text, '')
  } finally {
    await h.dispose()
  }
})
