// SPDX-License-Identifier: MIT
// P0-2 production chain: DSH's subprocess provider (subprocess-xl) reaches the
// ordered channel through `ctx.xlExecBridge.client`, and the transport injects
// the two phone-dsh-v1 EXEC_REQ members the exec-bridge v1 request cannot carry:
// `requires_mseq` (D12 revision fence) and `idem_key` (D10). Writing commands
// never reach 0x20 (executor inversion); unattributed accelerators fail locally.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { FrameType } from '../channel/src/index.ts'
import { toolCallStorage, XlExecBridge } from '../exec-bridge/src/index.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import { MockChannel, eventually, jsonPayload } from './test-channel.ts'

const KEY = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
const collect = { maxBytes: 64 * 1024 }

/** The phone-dsh-v1 oracle for the two transport-injected EXEC_REQ members. */
const GOLDEN = JSON.parse(readFileSync(
  fileURLToPath(new URL('../../spec/v1/golden/frames/exec-req-1.json', import.meta.url)),
  'utf8',
)) as { fields: { idem_key: string; requires_mseq: number; argv: string[]; cwd: string; env: Record<string, string> } }

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly subprocess: SubprocessRuntime
  dispose(): Promise<void>
}

/** One isolated Cordis context: the channel-backed exec bridge plus subprocess-xl. */
async function harness(options: { caps?: readonly string[]; nextMseq?: bigint } = {}): Promise<Harness> {
  const mock = new MockChannel({
    caps: options.caps ?? [],
    nextMseq: options.nextMseq ?? 1n,
    ackedMseq: (options.nextMseq ?? 1n) - 1n,
  })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_CHAIN_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_CHAIN_UNUSED_TOKEN_FILE',
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
    },
  }
}

function spec(argv: readonly string[], extra: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec {
  return {
    argv: [...argv],
    cwd: '/dsh/workspace',
    graceMs: 1_000,
    stdio: { stdin: 'ignore', stdout: collect, stderr: collect },
    ...extra,
  }
}

/** Emit a complete host event stream for an execution. */
function complete(mock: MockChannel, execId: string, stdout = ''): void {
  mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 41 })
  let seq = 1
  if (stdout !== '') mock.execEvent({ type: 'output', exec_id: execId, seq: seq++, stream: 'stdout', data: Buffer.from(stdout).toString('base64') })
  mock.execEvent({ type: 'exit', exec_id: execId, seq, code: 0, signal: null, status: 'exited', quiescent: true })
}

test('an advertised accelerator reaches 0x20 through ctx.xlExecBridge.client with the injected fields', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 48n })
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 'session-1', callId: 'call-1', key: KEY, turnId: '1', stepId: '1', spawns: 0 },
      () => h.subprocess.spawn(spec(['rg', '--json', 'needle'], { env: { TERM: 'dumb' } })),
    )
    await eventually(() => h.mock.framesOf(FrameType.EXEC_REQ).length === 1)
    const request = jsonPayload(h.mock.framesOf(FrameType.EXEC_REQ)[0]!)
    assert.deepEqual(request['argv'], GOLDEN.fields.argv)
    assert.equal(request['cwd'], GOLDEN.fields.cwd)
    assert.deepEqual(request['env'], GOLDEN.fields.env)
    // D12: the Worker's last emitted sink mseq (next_mseq 48) is the fence.
    assert.equal(request['requires_mseq'], GOLDEN.fields.requires_mseq)
    // D10: the deterministic key the host will recompute, exactly as the golden
    // vector encodes it (not a self-comparison).
    assert.equal(request['idem_key'], GOLDEN.fields.idem_key)
    complete(h.mock, `${KEY}-0`, 'match\n')
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(await handle.waitForExit(), true)
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'match\n')
  } finally {
    await h.dispose()
  }
})

test('an unadvertised command runs in the Worker and never emits EXEC_REQ', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 48n })
  try {
    const handle = await toolCallStorage().run(
      { sessionId: 'session-1', callId: 'call-2', key: KEY, turnId: '1', stepId: '2', spawns: 0 },
      () => h.subprocess.spawn(spec(['bash', '-c', 'printf "worker-local"'], { cwd: process.cwd() })),
    )
    assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
    assert.equal(handle.collected.stdout?.readFrom(0).text, 'worker-local')
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('an advertised accelerator outside a tool call has no idem identity and fails locally', async () => {
  const h = await harness({ caps: ['accelerator:rg'], nextMseq: 48n })
  try {
    const handle = h.subprocess.spawn(spec(['rg', 'needle']))
    await assert.rejects(handle.done, /needs a tool-call idem_key/)
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})
