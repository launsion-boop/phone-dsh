// SPDX-License-Identifier: MIT
// Resident phone surface: the remote API the SDK's DSHRemoteHarness speaks,
// served on 127.0.0.1 with a launch-token cookie exchange. This test boots the
// built phone bundle against the desktop simulation (exec-bridge stand-in and
// the scripted mock model) — the same process-level contract LocalDSHHost
// drives — and exercises that API directly.

import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, before, test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const bundle = join(root, 'dist', 'dsh-phone-surface.mjs')
const LAUNCH_TOKEN = `launch-${process.pid}-${Math.random().toString(16).slice(2)}`

interface ReadyHelper {
  child: ChildProcess
  info: { url: string }
  stderr: () => string
}

interface CallResult {
  status: number
  body: string
  json: Record<string, any> | undefined
}

let dir: string | undefined
let workspace = ''
let home = ''
let bridge: ReadyHelper
let model: ReadyHelper
let surface: ChildProcess | undefined
let baseURL = ''
let cookie = ''

/** Spawn a helper that prints one JSON ready line on stdout. */
function startHelper(name: string, args: string[]): Promise<ReadyHelper> {
  const child = spawn(process.execPath, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] })
  const errors: Buffer[] = []
  child.stderr?.on('data', (chunk: Buffer) => errors.push(chunk))
  return new Promise<ReadyHelper>((resolveReady, reject) => {
    let buffered = ''
    const timer = setTimeout(() => reject(new Error(`${name} did not print a ready line\n${Buffer.concat(errors)}`)), 15000)
    child.stdout?.on('data', (chunk: Buffer) => {
      buffered += chunk
      const newline = buffered.indexOf('\n')
      if (newline < 0) return
      clearTimeout(timer)
      try {
        resolveReady({ child, info: JSON.parse(buffered.slice(0, newline)), stderr: () => Buffer.concat(errors).toString('utf8') })
      } catch (error) {
        reject(error)
      }
    })
    child.once('exit', (code) => { clearTimeout(timer); reject(new Error(`${name} exited early (${code})\n${Buffer.concat(errors)}`)) })
  })
}

/** Wait for the surface's `XL_DSH_READY <port>` line. */
function waitForSurface(child: ChildProcess): Promise<number> {
  return new Promise<number>((resolveReady, reject) => {
    let buffered = ''
    let errors = ''
    const timer = setTimeout(() => reject(new Error(`surface did not become ready\n${errors}`)), 30000)
    child.stdout?.on('data', (chunk: Buffer) => {
      buffered += chunk
      const match = /(?:^|\n)XL_DSH_READY (\d+)\n/.exec(buffered)
      if (match === null) return
      clearTimeout(timer)
      resolveReady(Number(match[1]))
    })
    child.stderr?.on('data', (chunk: Buffer) => { errors += chunk })
    child.once('exit', (code, signal) => {
      clearTimeout(timer)
      reject(new Error(`surface exited before ready (${code ?? signal})\n${errors}`))
    })
  })
}

async function tokenExchange(token: string): Promise<Response> {
  return await fetch(`${baseURL}/?token=${encodeURIComponent(token)}`, { redirect: 'manual' })
}

async function call(method: string, args: unknown, cookieValue: string = cookie): Promise<CallResult> {
  const rpcId = crypto.randomUUID()
  const response = await fetch(`${baseURL}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...cookieValue === undefined ? {} : { cookie: cookieValue } },
    body: JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } }),
  })
  const text = await response.text()
  return { status: response.status, body: text, json: (() => { try { return JSON.parse(text) as Record<string, any> } catch { return undefined } })() }
}

before(async () => {
  if (!existsSync(join(root, 'node_modules', '@deepseek-ai', 'dsh'))) {
    throw new Error('plugins/node_modules is missing; run npm install --ignore-scripts first')
  }
  // Always rebuild: `dist/` is gitignored, so a bundle left behind by an
  // earlier source revision would otherwise satisfy the gate with stale code
  // (the /connect 404 and D22 401 regressions this test is the proof for).
  const build = spawnSync(process.execPath, [join(root, 'bundle', 'build.mjs'), '--surface', 'phone'], { cwd: root, encoding: 'utf8' })
  assert.equal(build.status, 0, `bundle build failed: ${build.stderr}`)
  dir = mkdtempSync(join(tmpdir(), 'pdsh-surface-phone-'))
  workspace = join(dir, 'ws')
  home = join(dir, 'home')
  mkdirSync(workspace, { recursive: true })
  mkdirSync(home, { recursive: true })
  // The exec bridge canonicalizes its mount root with realpath, and the bundle
  // maps its cwd onto that mount; on macOS /var is a symlink to /private/var.
  workspace = realpathSync(workspace)
  home = realpathSync(home)
  bridge = await startHelper('exec-bridge-sim', ['sim/exec-bridge-sim.mjs', '--workspace', workspace, '--token-file', join(dir, 'bridge.token')])
  model = await startHelper('mock-llm', ['sim/mock-llm.mjs', '--sleep', '0'])
  const tokenFile = join(dir, 'bridge.token')
  // The sim writes the token file before it prints its ready line.
  const bridgeToken = readFileSync(tokenFile, 'utf8').trim()
  surface = spawn(process.execPath, [bundle], {
    cwd: workspace,
    env: {
      PATH: process.env.PATH,
      HOME: home,
      DSH_HOME: home,
      PDSH_EXEC_BRIDGE_URL: bridge.info.url,
      PDSH_EXEC_BRIDGE_TOKEN: bridgeToken,
      DEEPSEEK_BASE_URL: `${model.info.url}/mock-llm`,
      DEEPSEEK_API_KEY: 'mock-not-a-secret',
      PDSH_SANDBOX_MODE: 'danger-full-access',
      PDSH_DSH_PORT: '0',
      PDSH_DSH_LAUNCH_TOKEN: LAUNCH_TOKEN,
      // The Worker host injects the ordered-channel coordinates (D24); their
      // presence is what lets the surface trust the entry-owned D22 marker.
      // The origin is the coordinate the desktop exec/LLM fallbacks ignore.
      PDSH_CHANNEL_ORIGIN: 'http://127.0.0.1:9',
      DSH_TELEMETRY_DISABLED: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const port = await waitForSurface(surface)
  baseURL = `http://127.0.0.1:${port}`
  const exchange = await tokenExchange(LAUNCH_TOKEN)
  assert.equal(exchange.status, 303, 'launch-token exchange must redirect')
  const setCookie = exchange.headers.get('set-cookie') ?? ''
  assert.match(setCookie, /HttpOnly/)
  cookie = setCookie.split(';')[0] ?? ''
  assert.ok(cookie.includes('='))
})

after(async () => {
  surface?.kill('SIGTERM')
  bridge?.child.kill('SIGTERM')
  model?.child.kill('SIGTERM')
  await sleep(200)
  if (dir !== undefined) rmSync(dir, { recursive: true, force: true })
})

test('surface-phone: the ready line carries the listening port', () => {
  const port = Number(new URL(baseURL).port)
  assert.ok(port > 0)
})

test('surface-phone: requests without the launch token are rejected', async () => {
  const missing = await call('session/create', { request: {} }, '')
  assert.equal(missing.status, 401)
  const wrong = await call('session/create', { request: {} }, 'pdsh-dsh-session=not-the-cookie')
  assert.equal(wrong.status, 401)
  const wrongToken = await tokenExchange('not-the-launch-token')
  assert.equal(wrongToken.status, 401)
  const noToken = await fetch(`${baseURL}/`, { redirect: 'manual' })
  assert.equal(noToken.status, 401)
})

test('surface-phone: the mux upgrade without the cookie is rejected', async () => {
  const Socket = WebSocket as unknown as new (
    url: string, options?: { headers?: Record<string, string> },
  ) => WebSocket
  const socket = new Socket(`${baseURL.replace('http', 'ws')}/api/remote.mux`, {
    headers: { cookie: 'pdsh-dsh-session=not-the-cookie' },
  })
  const opened = await new Promise<boolean>((resolveOpened) => {
    const timer = setTimeout(() => resolveOpened(false), 2000)
    socket.onopen = () => { clearTimeout(timer); resolveOpened(true) }
    socket.onerror = () => { clearTimeout(timer); resolveOpened(false) }
    socket.onclose = () => { clearTimeout(timer); resolveOpened(false) }
  })
  if (opened) socket.close()
  assert.equal(opened, false, 'the WebSocket upgrade must go through the same cookie admission')
})

test('surface-phone: the /connect exchange mints an API operator cookie', async () => {
  const exchange = await fetch(`${baseURL}/connect?token=${encodeURIComponent(LAUNCH_TOKEN)}&interactions=none`, { redirect: 'manual' })
  assert.equal(exchange.status, 302)
  assert.equal(exchange.headers.get('location'), './api/remote.mux')
  const apiCookie = (exchange.headers.get('set-cookie') ?? '').split(';', 1)[0] ?? ''
  assert.ok(apiCookie.includes('='))
  const listed = await call('session/list', { _request: {} }, apiCookie)
  assert.equal(listed.status, 200, listed.body)
  assert.equal(listed.json?.result?.ok, true, listed.body)
})

test('surface-phone: the Worker channel marker authenticates without a cookie', async () => {
  // D22: requests forwarded by the Worker entry over the ordered channel carry
  // the host-verified bearer as this header; the entry strips inbound copies.
  const response = await fetch(`${baseURL}/api/session/list`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-pdsh-channel-authenticated': '1' },
    body: JSON.stringify({ type: 'client-request', rpcId: crypto.randomUUID(), method: 'session/list', payload: { args: {} } }),
  })
  assert.equal(response.status, 200, await response.text())
})

test('surface-phone: the Worker command route fails closed without Worker VFS roots', async () => {
  const response = await fetch(`${baseURL}/api/pdsh-worker-command/execute`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({
      command: 'printf "surface-worker:%s" "$PDSH_WORKER_COMMAND_LOCATION"',
      program: 'bash',
      cwd: '/dsh/workspace',
      scenario_id: 'G2-SURFACE-WC',
      session_id: 'session-surface',
      turn: 0,
      assertion_index: 0,
      completion_watermark: 0,
    }),
  })
  const text = await response.text()
  assert.equal(response.status, 200, text)
  const body = JSON.parse(text) as {
    ok?: boolean
    value?: {
      protocol?: string
      location?: { kind?: string; worker_vfs?: boolean; host_process?: boolean; fork?: string }
      binding?: { scenario_id?: string; session_id?: string; assertion_index?: number }
      source?: { fork?: boolean; source_frozen?: boolean; digest?: string; entries?: number
        missing_roots?: string[]; failure?: string }
      execution?: { exit_code?: number; stdout?: string; timed_out?: boolean; stderr?: string }
      model_requests?: number
      live_workspace_unchanged?: boolean
    }
  }
  assert.equal(body.ok, true, text)
  assert.equal(body.value?.protocol, 'pdsh-worker-command/1')
  assert.equal(body.value?.location?.kind, 'worker')
  // The desktop simulation does not mount the Worker's `/dsh/*` roots. A
  // missing root is a failed snapshot, not an empty immutable fork: the route
  // must return the capture-failure envelope with no execution and no digest.
  assert.equal(body.value?.location?.worker_vfs, false)
  assert.equal(body.value?.location?.host_process, false)
  assert.equal(body.value?.location?.fork, 'none')
  assert.equal(body.value?.binding?.scenario_id, 'G2-SURFACE-WC')
  assert.equal(body.value?.binding?.session_id, 'session-surface')
  assert.equal(body.value?.binding?.assertion_index, 0)
  assert.equal(body.value?.source?.fork, false)
  assert.equal(body.value?.source?.source_frozen, false)
  assert.equal(body.value?.source?.digest, '')
  assert.equal(body.value?.source?.entries, 0)
  assert.deepEqual(body.value?.source?.missing_roots, ['/dsh/workspace'])
  assert.equal(body.value?.source?.failure, 'worker-command/snapshot-missing-root')
  assert.equal(body.value?.execution?.exit_code, 1)
  assert.equal(body.value?.execution?.timed_out, false)
  assert.equal(body.value?.execution?.stdout, '')
  assert.match(body.value?.execution?.stderr ?? '', /\/dsh\/workspace is missing/)
  assert.equal(body.value?.model_requests, 0)
  assert.equal(body.value?.live_workspace_unchanged, false)
})

test('surface-phone: one session completes through the remote API', async () => {
  const created = await call('session/create', { request: { cwd: workspace } })
  assert.equal(created.status, 200)
  assert.equal(created.json?.result?.ok, true, created.body)
  const sessionId = created.json.result.value.sessionId
  assert.match(sessionId, /^session-/)

  const events: Array<{ type?: string }> = []
  const Socket = WebSocket as unknown as new (
    url: string, options?: { headers?: Record<string, string> },
  ) => WebSocket
  const socket = new Socket(`${baseURL.replace('http', 'ws')}/api/remote.mux`, { headers: { cookie } })
  const done = new Promise<void>((resolveDone, reject) => {
    const timer = setTimeout(() => reject(new Error('no turn/end through the mux')), 30000)
    socket.onerror = () => reject(new Error('mux socket error'))
    socket.onmessage = (message) => {
      const frame = JSON.parse(String(message.data)) as {
        type?: string
        streamId?: string
        value?: { type?: string; event?: { type?: string } }
      }
      if (frame.type === 'item' && frame.streamId === 'follow') {
        const value = frame.value
        if (value?.type === 'event' && value.event !== undefined) {
          events.push(value.event)
          if (value.event.type === 'turn/end') { clearTimeout(timer); resolveDone() }
        }
      }
    }
  })
  await new Promise<void>((resolveOpen, reject) => {
    socket.onopen = () => resolveOpen()
    socket.onerror = () => reject(new Error('mux socket error'))
  })
  socket.send(JSON.stringify({
    type: 'open', streamId: 'follow', endpoint: 'session/follow',
    payload: { args: { request: { address: { kind: 'session', sessionId }, maxMessages: 50, assistantStream: true } } },
  }))
  const prompted = await call('session/prompt', {
    request: {
      requestId: crypto.randomUUID(), sessionId, mode: 'queue',
      content: [{ type: 'text', text: 'Charge the ledger once and write report.md.' }],
    },
  })
  assert.equal(prompted.status, 200, prompted.body)
  assert.equal(prompted.json?.result?.ok, true, prompted.body)
  await done
  socket.close()

  const types = events.map((event) => event.type ?? '')
  assert.ok(types.includes('turn/start'), `events: ${types.join(',')}`)
  assert.ok(types.includes('tool/result'), `events: ${types.join(',')}`)
  assert.ok(existsSync(join(workspace, 'report.md')), 'the write tool must have run in the workspace')
  assert.deepEqual(readFileSync(join(workspace, 'ledger.txt'), 'utf8').trim().split('\n').length, 1)
})
