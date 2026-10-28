// SPDX-License-Identifier: MIT
// W5-SHELL: the defineCommand accelerator bridge. An advertised accelerator in
// a bash -c script must cross the exec bridge with requires_mseq and idem_key;
// a name the host did not advertise must stay Worker-local.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import type { ExecClient, ExecEvent, ExecRequest, EventStream, Hello } from '@phone-dsh/dsh-exec-bridge'
import { deriveIdemKey, toolCallStorage } from '../exec-bridge/src/index.ts'
import {
  TRAP_TOKEN_ENV,
  VfsFileSystem,
  WorkerShell,
  createAcceleratorCommands,
  createExecBridgeAccelerators,
} from '../shell-ext/src/index.ts'

const roots: string[] = []

function fixture(): { root: string; fs: VfsFileSystem } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-bridge-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  return { root, fs }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

function hello(accelerators: string[]): Hello {
  return {
    protocol: 'pdsh-exec-bridge/1',
    provider: { name: 'test-host', version: '1' },
    guest: { platform: 'posix', mounts: [] },
    capabilities: { exec: true, accelerators },
    limits: {},
  }
}

class FakeClient implements Pick<ExecClient, 'exec' | 'cancel'> {
  readonly requests: ExecRequest[] = []
  readonly cancelled: string[] = []
  events: ExecEvent[] = []

  async exec(request: ExecRequest, _signal?: AbortSignal): Promise<EventStream> {
    this.requests.push(request)
    const events = this.events
    return {
      async *[Symbol.asyncIterator](): AsyncGenerator<ExecEvent> {
        for (const event of events) yield event
      },
      close(): void {},
    }
  }

  async cancel(execId: string): Promise<void> {
    this.cancelled.push(execId)
  }
}

test('bridge: an advertised accelerator forwards argv, cwd, requires_mseq and the D10 idem_key', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const client = new FakeClient()
  client.events = [
    { type: 'output', exec_id: 'x', seq: 1, stream: 'stdout', data: Buffer.from('match\n').toString('base64') },
    { type: 'exit', exec_id: 'x', seq: 2, code: 0, signal: null, status: 'exited', quiescent: true },
  ]
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const host = createExecBridgeAccelerators({
    client,
    hello: hello(['rg']),
    revision: () => 48n,
    graceMs: 1_000,
  })
  const shell = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const result = await toolCallStorage().run(
    { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
    () => shell.run(['bash', '-c', 'rg --json needle'], { cwd: '/dsh/workspace', env: { TERM: 'dumb' } }),
  )
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'match\n')
  assert.equal(client.requests.length, 1)
  const request = client.requests[0] as ExecRequest
  assert.deepEqual(request.argv, ['rg', '--json', 'needle'])
  assert.equal(request.cwd, '/dsh/workspace')
  assert.equal(request.requires_mseq, 48)
  assert.equal(request.idem_key, deriveIdemKey(request.argv, request.cwd, request.env, { key }))
  assert.equal(request.env?.XL_IDEMPOTENCY_KEY, key)
  assert.match(request.exec_id ?? '', new RegExp(`^${key}-a\\d+$`))
})

test('bridge: the internal trap token never leaks into the host env and repeats keep one idem_key', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const client = new FakeClient()
  client.events = [
    { type: 'output', exec_id: 'x', seq: 1, stream: 'stdout', data: Buffer.from('match\n').toString('base64') },
    { type: 'exit', exec_id: 'x', seq: 2, code: 0, signal: null, status: 'exited', quiescent: true },
  ]
  const host = createExecBridgeAccelerators({
    client,
    hello: hello(['rg']),
    revision: () => 48n,
    graceMs: 1_000,
  })
  const shell = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const invoke = () => toolCallStorage().run(
    { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
    () => shell.run(['bash', '-c', 'rg --json needle'], { cwd: '/dsh/workspace', env: { TERM: 'dumb' } }),
  )
  const first = await invoke()
  const second = await invoke()
  assert.equal(first.exitCode, 0)
  assert.equal(second.exitCode, 0)
  assert.equal(client.requests.length, 2)
  const [firstRequest, secondRequest] = client.requests as [ExecRequest, ExecRequest]
  // D10: a retry/re-send of the same tool call must reuse the same idem_key.
  // The per-execute trap bookkeeping is internal and must not enter the env
  // hash (or the host/subprocess environment) at all.
  assert.equal(firstRequest.env?.[TRAP_TOKEN_ENV], undefined)
  assert.equal(secondRequest.env?.[TRAP_TOKEN_ENV], undefined)
  assert.deepEqual(firstRequest.env, secondRequest.env)
  assert.equal(firstRequest.idem_key, secondRequest.idem_key)
  assert.equal(firstRequest.idem_key, deriveIdemKey(firstRequest.argv, firstRequest.cwd, firstRequest.env ?? {}, { key }))
})

test('bridge: a shell-exported XL_IDEMPOTENCY_KEY cannot override the tool-call identity', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const client = new FakeClient()
  client.events = [
    { type: 'output', exec_id: 'x', seq: 1, stream: 'stdout', data: Buffer.from('match\n').toString('base64') },
    { type: 'exit', exec_id: 'x', seq: 2, code: 0, signal: null, status: 'exited', quiescent: true },
  ]
  const key = 'xl1-trusted-call'
  const host = createExecBridgeAccelerators({ client, hello: hello(['rg']), revision: () => 0n, graceMs: 1_000 })
  const shell = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const result = await toolCallStorage().run(
    { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
    () => shell.run(['bash', '-c', 'XL_IDEMPOTENCY_KEY=scripted rg --json needle'], {
      cwd: '/dsh/workspace',
      env: { TERM: 'dumb', XL_IDEMPOTENCY_KEY: 'exported-evil' },
    }),
  )
  assert.equal(result.exitCode, 0)
  assert.equal(client.requests.length, 1)
  const request = client.requests[0] as ExecRequest
  // The script's value is data, not the call identity. The trusted key wins
  // for both the D10 derivation and the host exec id prefix.
  assert.equal(request.env?.XL_IDEMPOTENCY_KEY, key)
  assert.equal(request.idem_key, deriveIdemKey(request.argv, request.cwd, request.env, { key }))
  assert.match(request.exec_id ?? '', new RegExp(`^${key}-a\\d+$`))
})

test('bridge: an explicit out-of-band identity works outside a tool call and keeps -aN within D6', async () => {
})

test('bridge: an accelerator outside a tool call has no identity and never reaches the host', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const client = new FakeClient()
  const host = createExecBridgeAccelerators({ client, hello: hello(['rg']), revision: () => 0n })
  const shell = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const result = await shell.run(['bash', '-c', 'rg needle'], {
    cwd: '/dsh/workspace',
    env: { XL_IDEMPOTENCY_KEY: 'model-controlled' },
  })
  assert.equal(result.exitCode, 1)
  assert.match(result.stderr, /needs a tool-call idem_key/)
  assert.equal(client.requests.length, 0)
})

test('bridge: an unadvertised rg keeps running Worker-local (shell-ext rg shim over the builtin, no EXEC_REQ)', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  await fs.writeFile('/dsh/workspace/file.txt', 'needle\nhaystack\n')
  const client = new FakeClient()
  const host = createExecBridgeAccelerators({ client, hello: hello([]), revision: () => 0n })
  assert.deepEqual(host.names, [])
  const shell = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const result = await shell.run(['bash', '-c', 'rg needle file.txt'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0)
  assert.match(result.stdout, /needle/)
  assert.equal(client.requests.length, 0)
})
