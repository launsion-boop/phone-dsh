// SPDX-License-Identifier: MIT
// Integration: the DSH subprocess seam over the reference exec bridge (sim/exec-bridge-sim.mjs).
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { mkdtempSync, readFileSync, realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, before, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import { SandboxUnavailableError } from '@deepseek-ai/dsh-sandbox'
import { SubprocessExecutableNotFoundError } from '@deepseek-ai/dsh-subprocess'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { ExecBridgeClient, ExecBridgeError, XlExecBridge } from '../exec-bridge/src/index.ts'
import type { ExecEvent } from '../exec-bridge/src/index.ts'
import { toolCallStorage } from '../exec-bridge/src/call-context.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import { XlGuestSandboxProvider } from '../subprocess-xl/src/sandbox.ts'

const here = dirname(fileURLToPath(import.meta.url))
const scratch = mkdtempSync(join(tmpdir(), 'pdsh-subprocess-'))
const workspace = join(scratch, 'ws')
let sim: ChildProcess
let url = ''
let token = ''
let ctx: Context
let subprocess: SubprocessRuntime

before(async () => {
  sim = spawn(process.execPath, [join(here, '../sim/exec-bridge-sim.mjs'), '--workspace', workspace, '--token-file', join(scratch, 'token')], { stdio: ['ignore', 'pipe', 'ignore'] })
  const line = await new Promise<string>((resolve) => { sim.stdout?.once('data', (chunk: Buffer) => resolve(chunk.toString())) })
  url = JSON.parse(line).url
  token = readFileSync(join(scratch, 'token'), 'utf8').trim()
  process.env.PDSH_TEST_BRIDGE_TOKEN = token
  ctx = new Context()
  await ctx.plugin(XlExecBridge, { url, tokenEnv: 'PDSH_TEST_BRIDGE_TOKEN', tokenFileEnv: 'PDSH_TEST_UNUSED', connectTimeoutMs: 5000 })
  await ctx.plugin(XlSubprocessRuntime)
  await ctx.plugin(XlGuestSandboxProvider)
  subprocess = ctx.get('subprocess') as SubprocessRuntime
})

after(async () => {
  await ctx.fiber.dispose()
  sim.kill('SIGTERM')
})

const cwd = (): string => realpathSync(workspace)
const collect = { maxBytes: 64 * 1024, spill: { maxBytes: 1024 * 1024 } }
const spec = (argv: string[], extra: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec => ({
  argv, cwd: cwd(), graceMs: 500, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra,
})

test('collect mode: stdout, stderr, exit code, explicit env, and the tool-call idempotency key', async () => {
  const handle = await toolCallStorage().run({ sessionId: 's', callId: 'c', key: 'xl1-abc', spawns: 0 }, () => subprocess.spawn(spec(
    ['/bin/sh', '-c', 'echo "out $GREETING $XL_IDEMPOTENCY_KEY $(pwd)"; echo err >&2; exit 3'],
    { env: { GREETING: 'hi', HOME: undefined } },
  )))
  assert.deepEqual(await handle.done, { exitCode: 3, signal: null })
  assert.equal(handle.collected.stdout?.readFrom(0).text, `out hi xl1-abc ${cwd()}\n`)
  assert.equal(handle.collected.stderr?.readFrom(0).text, 'err\n')
  assert.equal(await handle.waitForExit(), true)
})

test('stdin data and piped streams', async () => {
  const fed = subprocess.spawn(spec(['/bin/cat'], { stdio: { stdin: { data: 'fed through stdin' }, stdout: collect, stderr: collect } }))
  await fed.done
  assert.equal(fed.collected.stdout?.readFrom(0).text, 'fed through stdin')

  const piped = subprocess.spawn(spec(['/bin/cat'], { stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' } }))
  let text = ''
  piped.stdout?.on('data', (chunk: Buffer) => { text += chunk })
  piped.stdin?.write('line one\n')
  piped.stdin?.end('line two\n')
  assert.deepEqual(await piped.done, { exitCode: 0, signal: null })
  await new Promise(resolve => piped.stdout?.once('end', resolve).resume())
  assert.equal(text, 'line one\nline two\n')
})

test('a missing program rejects done like a local ENOENT spawn failure', async () => {
  const handle = subprocess.spawn(spec(['definitely-not-a-program-xl']))
  await assert.rejects(handle.done, (error: unknown) => (error as { code?: string }).code === 'ENOENT')
  assert.equal(await handle.waitForExit(), true)
})

test('terminate signals the guest process group; waitForExit observes quiescence', async () => {
  const handle = subprocess.spawn(spec(['/bin/sh', '-c', 'sleep 30 & sleep 30; echo never']))
  await new Promise(resolve => setTimeout(resolve, 200))
  handle.terminate()
  handle.terminate()
  const outcome = await handle.done
  assert.equal(outcome.signal, 'SIGTERM')
  assert.equal(await handle.waitForExit(AbortSignal.timeout(5000)), true)
})

test('a background child keeps the range busy after the command exits', async () => {
  const handle = subprocess.spawn(spec(['/bin/sh', '-c', '(sleep 0.6) > /dev/null 2>&1 < /dev/null & echo started']))
  assert.deepEqual(await handle.done, { exitCode: 0, signal: null })
  const started = Date.now()
  assert.equal(await handle.waitForExit(AbortSignal.timeout(100)), false)
  assert.equal(await handle.waitForExit(AbortSignal.timeout(5000)), true)
  assert.ok(Date.now() - started >= 300)
})

test('the spec abort signal terminates the execution', async () => {
  const controller = new AbortController()
  const handle = subprocess.spawn(spec(['/bin/sleep', '30'], { signal: controller.signal }))
  setTimeout(() => controller.abort(), 100)
  assert.equal((await handle.done).signal, 'SIGTERM')
})

test('invalid requests throw synchronously: cwd outside the mounts, control channel', () => {
  assert.throws(() => subprocess.spawn(spec(['/bin/true'], { cwd: '/etc' })), /outside every exec-bridge mount/)
  assert.throws(() => subprocess.spawn(spec(['/bin/true'], { stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', control: 'pipe' } })), /control channel/)
})

test('executable lookup runs in the guest', async () => {
  assert.match(await subprocess.resolveExecutable('sh'), /^\/.*\/sh$/)
  assert.equal(await subprocess.resolveExecutable('/bin/sh'), '/bin/sh')
  await assert.rejects(subprocess.resolveExecutable('no-such-tool-xl'), SubprocessExecutableNotFoundError)
  await assert.rejects(subprocess.resolveExecutable('bin/sh'), /absolute path or a bare name/)
  assert.deepEqual(await subprocess.terminalEnvironment(), { platform: 'posix', defaultShell: '/bin/sh' })
  await assert.rejects(subprocess.spawnTerminal({ argv: ['/bin/sh'], cwd: cwd(), rows: 24, cols: 80, terminalType: 'xterm', graceMs: 100 }), /no terminal/)
})

test('re-submitting an exec_id replays the retained execution instead of running it again', async () => {
  const client = new ExecBridgeClient({ url, token })
  const request = { exec_id: 'xl1-replay-0', argv: ['/bin/sh', '-c', 'echo x >> count.txt; echo ran'], cwd: cwd(), stdin: { mode: 'ignore' as const } }
  const drain = async (): Promise<ExecEvent[]> => {
    const events: ExecEvent[] = []
    for await (const event of await client.exec(request)) events.push(event)
    return events
  }
  const first = await drain()
  const second = await drain()
  assert.equal(readFileSync(join(cwd(), 'count.txt'), 'utf8'), 'x\n')
  assert.equal((first[0] as { replayed?: boolean }).replayed, false)
  assert.equal((second[0] as { replayed?: boolean }).replayed, true)
  assert.deepEqual(second.map(e => e.seq), first.map(e => e.seq))
  await assert.rejects(client.exec({ ...request, argv: ['/bin/true'] }), (error: unknown) => error instanceof ExecBridgeError && error.code === 'exec_id_conflict')
  client.destroy()
})

test('the bridge refuses a wrong token and browser origins', async () => {
  const wrong = new ExecBridgeClient({ url, token: 'x'.repeat(64) })
  await assert.rejects(wrong.hello(), (error: unknown) => error instanceof ExecBridgeError && error.code === 'unauthorized' && error.status === 401)
  wrong.destroy()
  const response = await fetch(`${url}/v1/hello`, { headers: { authorization: `Bearer ${token}`, origin: 'https://evil.example' } })
  assert.equal(response.status, 403)
})

test('the guest sandbox provider fails closed when the provider cannot confine', async () => {
  const sandbox = ctx.get('sandbox') as XlGuestSandboxProvider
  await assert.rejects(sandbox.confine(['bash', '-c', 'true'], { mode: 'workspace-write', workspaceRoot: cwd() }), SandboxUnavailableError)
})
