// SPDX-License-Identifier: MIT
// Executor inversion (PLAN D12 / exec.md §3): bash and writing commands run in
// the Worker's own child_process, only advertised read-only accelerators cross
// the ordered channel, with requires_mseq and the exec.md §1 idem_key.
import assert from 'node:assert/strict'
import { readFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { dirname } from 'node:path'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { SandboxUnavailableError } from '@deepseek-ai/dsh-sandbox'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import { toolCallStorage } from '../exec-bridge/src/call-context.ts'
import { CONFINE_MARKER, XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import { XlGuestSandboxProvider } from '../subprocess-xl/src/sandbox.ts'
import { MockChannel, eventually, jsonPayload } from './test-channel.ts'

const here = dirname(fileURLToPath(import.meta.url))
const scratchRoots: string[] = []

after(() => {
  for (const root of scratchRoots) rmSync(root, { recursive: true, force: true })
})

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly subprocess: SubprocessRuntime
  readonly scratch: string
  dispose(): Promise<void>
}

/** One isolated channel-transport plugin context. */
async function harness(caps: readonly string[], nextMseq = 1n): Promise<Harness> {
  const scratch = mkdtempSync(join(tmpdir(), 'pdsh-inversion-'))
  scratchRoots.push(scratch)
  const mock = new MockChannel({ caps, nextMseq })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_TEST_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_TEST_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1000,
    accelerators: [],
  })
  await ctx.plugin(XlSubprocessRuntime)
  return {
    ctx,
    mock,
    subprocess: ctx.get('subprocess') as SubprocessRuntime,
    scratch,
    async dispose() {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    },
  }
}

const collect = { maxBytes: 64 * 1024, spill: { maxBytes: 1024 * 1024 } }

function spec(cwd: string, argv: string[], extra: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec {
  return { argv, cwd, graceMs: 3000, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra }
}

/** Emit a complete host event stream for an accelerator. */
function complete(mock: MockChannel, execId: string, stdout = ''): void {
  mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 1 })
  if (stdout !== '') mock.execEvent({ type: 'output', exec_id: execId, seq: 1, stream: 'stdout', data: Buffer.from(stdout).toString('base64') })
  mock.execEvent({ type: 'exit', exec_id: execId, seq: stdout === '' ? 1 : 2, code: 0, signal: null, status: 'exited', quiescent: true })
}

test('inversion: bash writes in the Worker and never emits EXEC_REQ', async () => {
  const h = await harness(['accelerator:rg'])
  try {
    const handle = await toolCallStorage().run({ sessionId: 's', callId: 'c', key: 'xl1-local', spawns: 0 }, () => h.subprocess.spawn(spec(h.scratch, [
      'bash', '-c', 'echo "$XL_IDEMPOTENCY_KEY" > local.txt',
    ])))
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(readFileSync(join(h.scratch, 'local.txt'), 'utf8'), 'xl1-local\n')
    assert.equal(h.mock.framesOf(0x20).length, 0, 'a write command must stay in the Worker')
  } finally {
    await h.dispose()
  }
})

test('inversion: a non-advertised program stays Worker-local and fails like a missing binary', async () => {
  const h = await harness(['accelerator:rg'])
  try {
    const handle = h.subprocess.spawn(spec(h.scratch, ['definitely-not-a-program-xl']))
    await assert.rejects(handle.done, (error: unknown) => (error as { code?: string }).code === 'ENOENT')
    assert.equal(h.mock.framesOf(0x20).length, 0)
  } finally {
    await h.dispose()
  }
})

test('inversion: an advertised accelerator goes to the host with requires_mseq and the golden idem_key', async () => {
  const h = await harness(['channel/1', 'wal/1', 'exec/1', 'accelerator:rg'], 48n)
  try {
    const handle = await toolCallStorage().run({
      sessionId: 'session-1', callId: 'call-1', key: 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0', turnId: '1', stepId: '1', spawns: 0,
    }, () => h.subprocess.spawn(spec('/dsh/workspace', ['rg', '--json', 'needle'], { env: { TERM: 'dumb' } })))
    await eventually(() => h.mock.framesOf(0x20).length === 1)
    const request = jsonPayload(h.mock.framesOf(0x20)[0] as never)
    assert.deepEqual(request.argv, ['rg', '--json', 'needle'])
    assert.equal(request.cwd, '/dsh/workspace')
    assert.deepEqual(request.env, { TERM: 'dumb', XL_IDEMPOTENCY_KEY: 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0' })
    assert.equal(request.grace_ms, 3000)
    // spec/v1 golden vector: idem_key and the mseq readiness fence.
    const golden = JSON.parse(readFileSync(join(here, '../../spec/v1/golden/frames/exec-req-1.json'), 'utf8')) as {
      fields: { idem_key: string; requires_mseq: number; argv: string[]; cwd: string; env: Record<string, string> }
    }
    assert.equal(request.requires_mseq, golden.fields.requires_mseq)
    assert.equal(request.idem_key, golden.fields.idem_key)
    assert.deepEqual(request.argv, golden.fields.argv)
    assert.equal(request.cwd, golden.fields.cwd)
    assert.deepEqual(request.env, golden.fields.env)
    complete(h.mock, request.exec_id as string, 'match\n')
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'match\n')
  } finally {
    await h.dispose()
  }
})

test('inversion: idem_key falls back to session_id, turn_id and step_id', async () => {
  const h = await harness(['accelerator:rg'], 3n)
  try {
    const call = { sessionId: 'sess_01', callId: 'call-2', key: '', turnId: '7', stepId: '2', spawns: 0 }
    const handle = await toolCallStorage().run(call, () => h.subprocess.spawn(spec('/dsh/workspace', ['rg', 'x'], { env: { TERM: 'dumb' } })))
    await eventually(() => h.mock.framesOf(0x20).length === 1)
    const request = jsonPayload(h.mock.framesOf(0x20)[0] as never)
    assert.equal(request.env && (request.env as Record<string, string>).XL_IDEMPOTENCY_KEY, undefined)
    const envHash = createHash('sha256').update('{"TERM":"dumb"}').digest('hex')
    const expected = createHash('sha256').update(`sess_01\u001f7\u001f2\u001f["rg","x"]\u001f/dsh/workspace\u001f${envHash}`).digest('hex')
    assert.equal(request.idem_key, expected)
    complete(h.mock, request.exec_id as string)
    await handle.done
  } finally {
    await h.dispose()
  }
})

test('inversion: the per-workspace mutex serializes parallel sub-agent commands', async () => {
  const h = await harness([])
  try {
    const first = h.subprocess.spawn(spec(h.scratch, ['bash', '-c', 'echo start1 >> order.log; sleep 0.2; echo end1 >> order.log']))
    const second = h.subprocess.spawn(spec(h.scratch, ['bash', '-c', 'echo start2 >> order.log; echo end2 >> order.log']))
    await Promise.all([first.done, second.done])
    assert.deepEqual(readFileSync(join(h.scratch, 'order.log'), 'utf8').trim().split('\n'), ['start1', 'end1', 'start2', 'end2'])
  } finally {
    await h.dispose()
  }
})

test('inversion: an accelerator re-reads the sink revision when its execution slot opens', async () => {
  const h = await harness(['accelerator:rg'], 5n)
  try {
    const first = await toolCallStorage().run({ sessionId: 's', callId: 'a', key: 'xl1-a', spawns: 0 }, () => h.subprocess.spawn(spec('/dsh/workspace', ['rg', 'a'])))
    await eventually(() => h.mock.framesOf(0x20).length === 1)
    const firstId = jsonPayload(h.mock.framesOf(0x20)[0] as never).exec_id as string
    const second = await toolCallStorage().run({ sessionId: 's', callId: 'b', key: 'xl1-b', spawns: 0 }, () => h.subprocess.spawn(spec('/dsh/workspace', ['rg', 'b'])))
    await sleep(20)
    assert.equal(h.mock.framesOf(0x20).length, 1, 'the second execution must wait for the slot')
    h.mock.setNextMseq(9n)
    complete(h.mock, firstId)
    await first.done
    await eventually(() => h.mock.framesOf(0x20).length === 2)
    const request = jsonPayload(h.mock.framesOf(0x20)[1] as never)
    assert.equal(request.requires_mseq, 8)
    complete(h.mock, request.exec_id as string)
    await second.done
  } finally {
    await h.dispose()
  }
})

test('inversion: an unadvertised accelerator name is executed locally, never forwarded', async () => {
  const h = await harness(['accelerator:rg'])
  try {
    mkdirSync(join(h.scratch, 'sub'), { recursive: true })
    const handle = h.subprocess.spawn(spec(h.scratch, ['jaq-xl-not-installed']))
    await assert.rejects(handle.done, (error: unknown) => (error as { code?: string }).code === 'ENOENT')
    assert.equal(h.mock.framesOf(0x20).length, 0)
  } finally {
    await h.dispose()
  }
})

test('sandbox: local workspace-write is admitted by the Worker boundary, local read-only fails closed, accelerators need no wrapper', async () => {
  const h = await harness(['accelerator:rg'])
  try {
    await h.ctx.plugin(XlGuestSandboxProvider)
    const sandbox = h.ctx.get('sandbox') as XlGuestSandboxProvider
    const write = await sandbox.confine(['bash', '-c', 'echo hi'], { mode: 'workspace-write', workspaceRoot: '/dsh/workspace' })
    assert.deepEqual(write.argv, [CONFINE_MARKER, 'workspace-write', '/dsh/workspace', '--', 'bash', '-c', 'echo hi'])
    await assert.rejects(sandbox.confine(['bash', '-c', 'echo hi'], { mode: 'read-only', workspaceRoot: '/dsh/workspace' }), SandboxUnavailableError)
    const accelerator = await sandbox.confine(['rg', 'needle'], { mode: 'workspace-write', workspaceRoot: '/dsh/workspace' })
    assert.deepEqual(accelerator.argv, ['rg', 'needle'])
  } finally {
    await h.dispose()
  }
})

test('inversion: a confined Worker command strips the sandbox marker and runs locally', async () => {
  const h = await harness([])
  try {
    const handle = h.subprocess.spawn({
      ...spec(h.scratch, [CONFINE_MARKER, 'workspace-write', h.scratch, '--', 'bash', '-c', 'echo confined > out.txt']),
    })
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(readFileSync(join(h.scratch, 'out.txt'), 'utf8'), 'confined\n')
    assert.equal(h.mock.framesOf(0x20).length, 0)
  } finally {
    await h.dispose()
  }
})

test('channel transport: cancel and stdin are EXEC_CTL 0x22 JSON frames', async () => {
  const { ChannelExecTransport } = await import('../exec-bridge/src/transport.ts')
  const mock = new MockChannel()
  const transport = new ChannelExecTransport(mock)
  await transport.cancel('xl1-ctl-0')
  await transport.stdin('xl1-ctl-0', { data: Buffer.from('hi').toString('base64') })
  const frames = mock.framesOf(0x22).map(frame => jsonPayload(frame))
  assert.deepEqual(frames, [
    { exec_id: 'xl1-ctl-0', op: 'cancel' },
    { exec_id: 'xl1-ctl-0', op: 'stdin', data: 'aGk=' },
  ])
  transport.destroy()
})

test('inversion: resolveExecutable stays local in the Worker and never emits EXEC_REQ', async () => {
  const h = await harness(['accelerator:rg'])
  try {
    assert.equal(await h.subprocess.resolveExecutable('bash'), 'bash')
    assert.equal(h.mock.framesOf(0x20).length, 0)
  } finally {
    await h.dispose()
  }
})
