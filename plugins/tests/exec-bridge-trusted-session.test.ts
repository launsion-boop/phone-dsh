// SPDX-License-Identifier: MIT
// PR14 T1-8: `PDSH_TOOL_CALL_SESSION` belongs to the `ubuntu` command's
// out-of-band dispatch field only. The transports must delete any caller or
// shell value on every dispatch, and write the member only from the explicit
// trusted mark the bridge puts on the `ubuntu` command's own ExecRequest.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { after, before, test } from 'node:test'
import type { ExecEvent, ExecRequest, EventStream } from '../exec-bridge/src/client.ts'
import { toolCallStorage } from '../exec-bridge/src/call-context.ts'
import {
  FetchExecTransport,
  TOOL_CALL_SESSION_ENV,
  execRequestJson,
  withPhoneExecFields,
} from '../exec-bridge/src/transport.ts'
import { TOOL_CALL_SESSION_ENV as BRIDGE_SESSION_ENV, createExecBridgeAccelerators } from '../shell-ext/src/bridge.ts'

const IDEM_KEY = '2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a'
const ambient = { sessionId: 'sess-a', callId: 'c', key: 'k1', spawns: 0 } as const

function request(overrides: Partial<ExecRequest> = {}): ExecRequest {
  return {
    exec_id: 'xl1-test-0',
    argv: ['phone', 'ubuntu', 'run', '--', 'true'],
    cwd: '/dsh/workspace',
    env: { TERM: 'dumb' },
    grace_ms: 3000,
    stdin: { mode: 'ignore' },
    requires_mseq: 0,
    idem_key: IDEM_KEY,
    ...overrides,
  }
}

function exitStream(execId: string): EventStream {
  return {
    async *[Symbol.asyncIterator](): AsyncGenerator<ExecEvent> {
      yield { type: 'exit', exec_id: execId, seq: 0, code: 0, signal: null, status: 'exited', quiescent: true }
    },
    close(): void {},
  }
}

/** Apply the production mark helper without making baseline import fail. */
async function markTrusted(request: ExecRequest, session: string): Promise<void> {
  const transport = await import('../exec-bridge/src/transport.ts')
  transport.markTrustedToolCallSession(request, session)
}

function hasSession(env: Record<string, string | null> | undefined): boolean {
  return env !== undefined && Object.hasOwn(env, TOOL_CALL_SESSION_ENV)
}

test('T1-8a: a script-shaped phone ubuntu dispatch forwards no ambient session', () => {
  const original = request({ env: { TERM: 'dumb' } })
  const prepared = toolCallStorage().run(ambient, () => withPhoneExecFields(original, 0n))
  assert.equal(hasSession(prepared.env), false)
  assert.equal(prepared.env?.[TOOL_CALL_SESSION_ENV], undefined)
  assert.equal(hasSession(original.env), false)
  // The forwarded env is a copy; the provider's request object is not mutated.
  assert.notEqual(prepared.env, original.env)
})

test('T1-8b: the ubuntu command\'s marked dispatch carries its trusted session', async () => {
  const captured: ExecRequest[] = []
  const host = createExecBridgeAccelerators({
    client: {
      async exec(candidate: ExecRequest): Promise<EventStream> {
        captured.push(candidate)
        return exitStream(candidate.exec_id)
      },
      async cancel(): Promise<void> {},
    },
    hello: { capabilities: { exec: true, accelerators: ['phone'] } },
    revision: () => 0n,
    graceMs: 1_000,
  })
  const result = await toolCallStorage().run(
    ambient,
    () => host.exec({
      argv: ['phone', 'ubuntu', 'run', '--', 'true'],
      cwd: '/dsh/workspace',
      env: { TERM: 'dumb' },
      stdin: '',
      sessionId: 'sess-a',
    }),
  )
  assert.equal(result.exitCode, 0)
  assert.equal(captured.length, 1)
  const forwarded = withPhoneExecFields(captured[0]!, 0n)
  assert.equal(forwarded.env?.[TOOL_CALL_SESSION_ENV], 'sess-a')
  // Only the forwarded env changes; the D10 key still describes the request the
  // bridge built, exactly as before this fix.
  assert.equal(forwarded.idem_key, captured[0]!.idem_key)
})

test('T1-8c: a caller-supplied session is deleted with and without an ambient tool call', () => {
  const forged = 'sess-forged'
  for (const context of [undefined, ambient]) {
    const original = request({ env: { TERM: 'dumb', [TOOL_CALL_SESSION_ENV]: forged } })
    const prepared = context === undefined
      ? withPhoneExecFields(original, 0n)
      : toolCallStorage().run(context, () => withPhoneExecFields(original, 0n))
    assert.equal(hasSession(prepared.env), false)
    assert.equal(JSON.stringify(execRequestJson(prepared)).includes(forged), false)
    // The caller's env object keeps its own value; only the forwarded copy loses it.
    assert.equal(original.env?.[TOOL_CALL_SESSION_ENV], forged)
  }
})

test('T1-8c: a session exported through the bridge never reaches the forwarded env', async () => {
  const captured: ExecRequest[] = []
  const host = createExecBridgeAccelerators({
    client: {
      async exec(candidate: ExecRequest): Promise<EventStream> {
        captured.push(candidate)
        return exitStream(candidate.exec_id)
      },
      async cancel(): Promise<void> {},
    },
    hello: { capabilities: { exec: true, accelerators: ['phone'] } },
    revision: () => 0n,
    graceMs: 1_000,
  })
  await toolCallStorage().run(
    ambient,
    () => host.exec({
      argv: ['phone', 'ubuntu', 'run', '--', 'true'],
      cwd: '/dsh/workspace',
      env: { TERM: 'dumb', [BRIDGE_SESSION_ENV]: 'sess-inherited' },
      stdin: '',
    }),
  )
  assert.equal(captured.length, 1)
  assert.equal(BRIDGE_SESSION_ENV, TOOL_CALL_SESSION_ENV)
  assert.equal(captured[0]?.env?.[TOOL_CALL_SESSION_ENV], undefined)
  const forwarded = withPhoneExecFields(captured[0]!, 0n)
  assert.equal(hasSession(forwarded.env), false)
})

// ---------------------------------------------------------------------------
// Transport level: the posted /v1/exec body, not just the helper result.
// ---------------------------------------------------------------------------

interface Posted {
  readonly url: string
  readonly body: string
}

let base = ''
const posted: Posted[] = []
const server = createServer((req: IncomingMessage, res: ServerResponse) => {
  const chunks: Buffer[] = []
  req.on('data', (chunk: Buffer) => { chunks.push(Buffer.from(chunk)) })
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8')
    posted.push({ url: req.url ?? '', body })
    if (req.method === 'POST' && req.url === '/v1/exec') {
      res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' })
      res.end(`${JSON.stringify({ type: 'exit', exec_id: 'xl1-test-0', seq: 0, code: 0, signal: null, status: 'exited', quiescent: true })}\n`)
      return
    }
    res.writeHead(404)
    res.end()
  })
})

before(async () => {
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})
after(() => {
  server.closeAllConnections()
  server.close()
})

async function postedExecEnv(transport: FetchExecTransport, candidate: ExecRequest): Promise<Record<string, string | null>> {
  const stream = await transport.exec(candidate)
  for await (const _event of stream) {
    // Drain the NDJSON response.
  }
  const sent = [...posted].reverse().find(entry => entry.url === '/v1/exec')
  assert.ok(sent, 'the transport posted /v1/exec')
  return (JSON.parse(sent.body) as { env: Record<string, string | null> }).env
}

test('T1-8d: the fetch transport omits a script session and sends only the marked one', async () => {
  const transport = new FetchExecTransport({ url: base, token: 'fetch-token-0123456789' })

  const script = request({ exec_id: 'xl1-test-script', env: { TERM: 'dumb' } })
  const scriptEnv = await toolCallStorage().run(ambient, () => postedExecEnv(transport, script))
  assert.equal(hasSession(scriptEnv), false)

  const forged = 'sess-forged'
  const ubuntu = request({
    exec_id: 'xl1-test-ubuntu',
    env: { TERM: 'dumb', [TOOL_CALL_SESSION_ENV]: forged },
  })
  await markTrusted(ubuntu, 'sess-a')
  // The ambient call is a different session: the explicit mark must win.
  const ubuntuEnv = await toolCallStorage().run(ambient, () => postedExecEnv(transport, ubuntu))
  assert.equal(ubuntuEnv[TOOL_CALL_SESSION_ENV], 'sess-a')

  const sent = [...posted].reverse().find(entry => entry.url === '/v1/exec')
  assert.ok(sent)
  assert.equal(sent.body.includes(forged), false)
  transport.destroy()
})
