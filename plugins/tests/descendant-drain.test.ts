// SPDX-License-Identifier: MIT
/**
 * G2-F01: real pinned-DSH parent/child descendant teardown.
 *
 * The host may not tear the Worker down while a spawned child still owns an
 * open DSH turn. `PhoneDSHTrackedTransport` only sees the App's root
 * `session/create`/`session/prompt`, and `session/cancel` is scoped to one
 * Agent (a subagent-owned id is refused as `session/agent-busy`). This test
 * boots the real phone surface bundle (pinned DSH AgentLoop, JSONL persistence,
 * subagent manager, phone profile), lets the real `subagent` tool spawn a
 * child whose model stream stays open, and calls the phone-only descendant
 * drain route.
 *
 * It proves:
 *   1. the route resolves the exact live App-owned root and awaits DSH's own
 *      `subagents.drainDescendants` (the child journals `turn/end`);
 *   2. an unrelated root live in the same Worker is not cancelled;
 *   3. the root `session/cancel` after the child drain is still required and
 *      closes the parent turn; the child stays terminal;
 *   4. a retry after the child is gone is a successful no-op, and a child id
 *      passed as a root is refused rather than cancelled directly.
 */

import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, before, test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const bundle = join(root, 'dist', 'dsh-phone-surface.mjs')
const LAUNCH_TOKEN = `descendant-drain-${process.pid}-${Math.random().toString(16).slice(2)}`
const DRAIN_PATH = '/api/pdsh-descendant-drain'

let directory = ''
let workspace = ''
let home = ''
let surface: ChildProcess | undefined
let baseURL = ''
let cookie = ''
let modelServer: ReturnType<typeof createServer> | undefined
/** Requests whose SSE body this test deliberately leaves open. */
const held: ServerResponse[] = []
let childRequests = 0
let parentAfterDelegationRequests = 0
let unrelatedRequests = 0
let modelRequests = 0

/** Recursively collect files below one directory. */
function filesBelow(path: string): string[] {
  if (!existsSync(path)) return []
  const files: string[] = []
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name)
    if (entry.isDirectory()) files.push(...filesBelow(child))
    else if (entry.isFile()) files.push(child)
  }
  return files
}

/** The current-generation session log whose header id matches `sessionID`. */
function sessionLogPath(sessionID: string): string | undefined {
  const matches = filesBelow(join(home, 'sessions'))
    .filter(path => /session\.v\d+\.jsonl$/.test(path))
    .filter((path) => {
      try {
        return readFileSync(path, 'utf8').startsWith(`{"type":"session"`)
          && readFileSync(path, 'utf8').includes(`"id":"${sessionID}"`)
      } catch {
        return false
      }
    })
  return matches[0]
}

/** One durable JSONL record. */
function records(path: string | undefined): Array<Record<string, any>> {
  if (path === undefined || !existsSync(path)) return []
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter(line => line.trim() !== '')
    .flatMap((line) => {
      try { return [JSON.parse(line) as Record<string, any>] } catch { return [] }
    })
}

function lastRecordType(path: string | undefined): string | undefined {
  return records(path).at(-1)?.type
}

/** Header fields of one journal. */
function headerOf(path: string): Record<string, any> {
  return records(path)[0] ?? {}
}

/** The child journal under root `rootID`; there is exactly one in this test. */
function childJournalPath(rootID: string): string | undefined {
  return filesBelow(join(home, 'sessions'))
    .filter(path => /session\.v\d+\.jsonl$/.test(path))
    .find((path) => {
      const header = headerOf(path)
      return header['origin'] === 'subagent' && header['parentSession'] === rootID
    })
}

function sse(response: ServerResponse, event: string, data: Record<string, unknown>): void {
  response.write(`event: ${event}\n`)
  response.write(`data: ${JSON.stringify({ type: event, ...data })}\n\n`)
}

/** Open an SSE response and never end it (the model stream stays pending). */
function holdStream(response: ServerResponse, requestNumber: number, model: unknown): void {
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'close',
  })
  sse(response, 'message_start', {
    message: {
      id: `msg_hold_${String(requestNumber)}`, type: 'message', role: 'assistant', model,
      content: [], stop_reason: null, stop_sequence: null,
      usage: { input_tokens: 100, output_tokens: 0 },
    },
  })
  sse(response, 'content_block_start', {
    index: 0, content_block: { type: 'text', text: '' },
  })
  sse(response, 'content_block_delta', {
    index: 0, delta: { type: 'text_delta', text: 'Holding this turn open.' },
  })
  held.push(response)
}

/** Serialize the user-visible text of one Messages request. */
function requestText(body: Record<string, any>): string {
  return JSON.stringify(body.messages ?? [])
}

/** Decide the scripted parent/child behavior from the real request history. */
function decide(body: Record<string, any>): {
  kind: 'hold-child' | 'hold-parent' | 'hold-unrelated' | 'delegate' | 'hold-other'
  tool?: { name: string, input: Record<string, unknown> }
} {
  const text = requestText(body)
  // The parent's second request contains its own `subagent` tool_use argument,
  // so match the child on its last user message (a prompt, not a tool_result),
  // not on the whole conversation.
  const lastUser = [...(body.messages ?? [])].reverse()
    .find(message => message.role === 'user')
  const lastUserBlocks = Array.isArray(lastUser?.content) ? lastUser.content : []
  const lastUserHasToolResult = lastUserBlocks.some((block: Record<string, any>) =>
    block.type === 'tool_result')
  const lastUserText = lastUserBlocks
    .filter((block: Record<string, any>) => block.type === 'text')
    .map((block: Record<string, any>) => block.text)
    .join('\n')
  if (!lastUserHasToolResult && lastUserText.includes('Child task: wait forever')) {
    return { kind: 'hold-child' }
  }
  const toolUses: Array<Record<string, any>> = []
  const results = new Set<string>()
  for (const message of body.messages ?? []) {
    if (!Array.isArray(message.content)) continue
    for (const block of message.content) {
      if (message.role === 'assistant' && block.type === 'tool_use') toolUses.push(block)
      if (message.role === 'user' && block.type === 'tool_result') results.add(block.tool_use_id)
    }
  }
  const last = toolUses.at(-1)
  if (last?.name === 'subagent' && results.has(last.id)) return { kind: 'hold-parent' }
  if (last === undefined && text.includes('Unrelated root')) return { kind: 'hold-unrelated' }
  if (last === undefined) {
    return {
      kind: 'delegate',
      tool: {
        name: 'subagent',
        input: { prompt: 'Child task: wait forever', description: 'Hold child open' },
      },
    }
  }
  return { kind: 'hold-other' }
}

/** Answer one scripted Messages request. */
function answer(request: IncomingMessage, response: ServerResponse): void {
  const chunks: Buffer[] = []
  request.on('data', (chunk: Buffer) => chunks.push(chunk))
  request.on('end', () => {
    let body: Record<string, any>
    try {
      body = JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, any>
    } catch {
      response.writeHead(400).end()
      return
    }
    modelRequests += 1
    const decision = decide(body)
    if (decision.kind === 'hold-child') {
      childRequests += 1
      holdStream(response, modelRequests, body.model)
      return
    }
    if (decision.kind === 'hold-parent') {
      parentAfterDelegationRequests += 1
      holdStream(response, modelRequests, body.model)
      return
    }
    if (decision.kind === 'hold-unrelated') {
      unrelatedRequests += 1
      holdStream(response, modelRequests, body.model)
      return
    }
    if (decision.kind === 'hold-other') {
      holdStream(response, modelRequests, body.model)
      return
    }
    const tool = decision.tool
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
    sse(response, 'message_start', {
      message: {
        id: `msg_delegate_${String(modelRequests)}`, type: 'message', role: 'assistant', model: body.model,
        content: [], stop_reason: null, stop_sequence: null,
        usage: { input_tokens: 100, output_tokens: 0 },
      },
    })
    sse(response, 'content_block_start', { index: 0, content_block: { type: 'text', text: '' } })
    sse(response, 'content_block_delta', {
      index: 0, delta: { type: 'text_delta', text: 'I will delegate this to a child.' },
    })
    sse(response, 'content_block_stop', { index: 0 })
    assert.ok(tool, 'the delegate decision needs a tool')
    sse(response, 'content_block_start', {
      index: 1,
      content_block: {
        type: 'tool_use',
        id: `toolu_delegate_${String(modelRequests)}`,
        name: tool.name,
        input: {},
      },
    })
    sse(response, 'content_block_delta', {
      index: 1, delta: { type: 'input_json_delta', partial_json: JSON.stringify(tool.input) },
    })
    sse(response, 'content_block_stop', { index: 1 })
    sse(response, 'message_delta', { delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 10 } })
    sse(response, 'message_stop', {})
    response.end()
  })
}

/** Wait for the surface's `XL_DSH_READY <port>` line. */
function waitForSurface(child: ChildProcess): Promise<number> {
  return new Promise<number>((resolveReady, reject) => {
    let buffered = ''
    let errors = ''
    const timer = setTimeout(() => reject(new Error(`surface did not become ready\n${errors}`)), 30_000)
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

interface CallResult {
  status: number
  text: string
  json?: Record<string, any>
}

async function call(method: string, args: unknown): Promise<CallResult> {
  const response = await fetch(`${baseURL}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: crypto.randomUUID(),
      method,
      payload: { args },
    }),
  })
  const text = await response.text()
  return { status: response.status, text, json: (() => {
    try { return JSON.parse(text) as Record<string, any> } catch { return undefined }
  })() }
}

async function createSession(cwd: string): Promise<string> {
  const created = await call('session/create', { request: { cwd } })
  assert.equal(created.status, 200, created.text)
  assert.equal(created.json?.result?.ok, true, created.text)
  const sessionID = created.json?.result?.value?.sessionId as string | undefined
  assert.ok(sessionID, created.text)
  return sessionID
}

async function prompt(sessionID: string, text: string): Promise<void> {
  const prompted = await call('session/prompt', {
    request: {
      requestId: crypto.randomUUID(),
      sessionId: sessionID,
      mode: 'queue',
      content: [{ type: 'text', text }],
    },
  })
  assert.equal(prompted.status, 200, prompted.text)
  assert.equal(prompted.json?.result?.ok, true, prompted.text)
}

async function drain(sessionIds: string[], timeoutMs = 10_000): Promise<CallResult> {
  const response = await fetch(`${baseURL}${DRAIN_PATH}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionIds, timeoutMs }),
  })
  const text = await response.text()
  return { status: response.status, text, json: (() => {
    try { return JSON.parse(text) as Record<string, any> } catch { return undefined }
  })() }
}

async function waitUntil(label: string, timeoutMs: number, predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`)
    await sleep(25)
  }
}

before(async () => {
  if (!existsSync(join(root, 'node_modules', '@deepseek-ai', 'dsh'))) {
    throw new Error('plugins/node_modules is missing; run npm install --ignore-scripts first')
  }
  const build = spawnSync(process.execPath, [join(root, 'bundle', 'build.mjs'), '--surface', 'phone'], {
    cwd: root,
    encoding: 'utf8',
  })
  assert.equal(build.status, 0, `bundle build failed: ${build.stderr}`)
  directory = mkdtempSync(join(tmpdir(), 'pdsh-descendant-drain-'))
  workspace = join(directory, 'ws')
  home = join(directory, 'home')
  mkdirSync(workspace, { recursive: true })
  mkdirSync(home, { recursive: true })
  workspace = realpathSync(workspace)
  home = realpathSync(home)

  modelServer = createServer((request, response) => {
    if (request.method !== 'POST' || !request.url?.endsWith('/v1/messages')) {
      response.writeHead(404, { 'content-type': 'application/json' })
      response.end('{"type":"error","error":{"type":"not_found_error"}}')
      return
    }
    answer(request, response)
  })
  await new Promise<void>(resolveListen => modelServer?.listen(0, '127.0.0.1', resolveListen))
  const modelBase = `http://127.0.0.1:${(modelServer.address() as AddressInfo).port}/mock-llm`

  surface = spawn(process.execPath, [bundle], {
    cwd: workspace,
    env: {
      PATH: process.env.PATH,
      HOME: home,
      DSH_HOME: home,
      DEEPSEEK_BASE_URL: modelBase,
      DEEPSEEK_API_KEY: 'mock-not-a-secret',
      PDSH_SANDBOX_MODE: 'danger-full-access',
      PDSH_DSH_PORT: '0',
      PDSH_DSH_LAUNCH_TOKEN: LAUNCH_TOKEN,
      PDSH_DSH_VERSION: '0.2.1-rc.2',
      DSH_TELEMETRY_DISABLED: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const port = await waitForSurface(surface)
  baseURL = `http://127.0.0.1:${String(port)}`
  const exchange = await fetch(`${baseURL}/?token=${encodeURIComponent(LAUNCH_TOKEN)}`, { redirect: 'manual' })
  assert.equal(exchange.status, 303, 'launch-token exchange must redirect')
  cookie = (exchange.headers.get('set-cookie') ?? '').split(';', 1)[0] ?? ''
  assert.ok(cookie.includes('='))
})

after(async () => {
  for (const response of held) {
    try { response.destroy() } catch { /* the surface is exiting */ }
  }
  surface?.kill('SIGTERM')
  modelServer?.closeAllConnections()
  modelServer?.close()
  await sleep(200)
  if (directory !== '') rmSync(directory, { recursive: true, force: true })
})

test('drains only the named root descendants, leaves an unrelated root live, then parent cancel closes the root', {
  timeout: 60_000,
}, async () => {
  const parent = await createSession(workspace)
  const unrelated = await createSession(workspace)
  await prompt(parent, 'Delegate a child task.')
  await prompt(unrelated, 'Unrelated root: hold this turn open.')

  await waitUntil('the parent delegation model stream', 20_000,
    () => parentAfterDelegationRequests > 0)
  await waitUntil('the child model stream', 20_000, () => childRequests > 0)
  await waitUntil('the unrelated root model stream', 20_000, () => unrelatedRequests > 0)

  const parentLog = sessionLogPath(parent)
  const unrelatedLog = sessionLogPath(unrelated)
  await waitUntil('the parent journal', 20_000, () => lastRecordType(parentLog) !== undefined)
  await waitUntil('the child journal', 20_000,
    () => childJournalPath(parent) !== undefined)
  await waitUntil('the unrelated root journal', 20_000,
    () => lastRecordType(unrelatedLog) !== undefined)
  const childLog = childJournalPath(parent)
  assert.ok(childLog)
  await waitUntil('the parent open turn', 20_000,
    () => records(parentLog).some(record => record.type === 'turn/start'))
  await waitUntil('the child open turn', 20_000,
    () => records(childLog).some(record => record.type === 'turn/start'))
  assert.equal(records(childLog).at(-1)?.type === 'turn/end', false,
    'the child must still own an open turn before the drain')

  // A child id is not a legal root: the route must refuse instead of
  // cancelling the child directly through the wrong primitive.
  const childHeader = headerOf(childLog)
  const childID = childHeader['id'] as string
  const refused = await drain([childID])
  assert.equal(refused.status, 409, refused.text)
  assert.match(refused.text, /descendant-drain\/not-root/)
  assert.equal(records(childLog).at(-1)?.type === 'turn/end', false,
    'a refused direct child drain must not cancel the child')

  const before = records(childLog).length
  const drained = await drain([parent])
  assert.equal(drained.status, 200, drained.text)
  assert.equal(drained.json?.ok, true, drained.text)
  assert.equal(drained.json?.value?.protocol, 'pdsh-descendant-drain/1', drained.text)
  assert.deepEqual(drained.json?.value?.roots, [parent], drained.text)
  assert.deepEqual(drained.json?.value?.missing, [], drained.text)
  assert.ok(Array.isArray(drained.json?.value?.descendants), drained.text)
  assert.ok(drained.json?.value?.descendants?.includes(childID),
    `the receipt must name the live child it drained: ${drained.text}`)

  await waitUntil('the drained child turn/end', 10_000,
    () => records(childLog).at(-1)?.type === 'turn/end')
  const childRecords = records(childLog)
  assert.ok(childRecords.length > before, 'the child journal must gain its own terminal record')
  assert.equal(childRecords.at(-1)?.type, 'turn/end')
  const childReason = childRecords.at(-1)?.data?.reason
  assert.ok(childReason && typeof childReason.kind === 'string',
    `the child turn/end must carry DSH's reason: ${JSON.stringify(childRecords.at(-1))}`)

  // The drain is scoped to the child; the parent model stream is still open
  // and the unrelated root is untouched.
  assert.notEqual(records(parentLog).at(-1)?.type, 'turn/end',
    'the scoped child drain must not cancel its parent root')
  assert.equal(records(unrelatedLog).at(-1)?.type === 'turn/end', false,
    'an unrelated root must not be cancelled by the descendant drain')

  // The parent now needs its own cancel, and the already-terminal child must
  // stay terminal instead of opening a second turn.
  const cancelled = await call('session/cancel', { request: { sessionId: parent } })
  assert.equal(cancelled.status, 200, cancelled.text)
  await waitUntil('the parent turn/end', 10_000,
    () => records(parentLog).at(-1)?.type === 'turn/end')
  assert.equal(records(childLog).at(-1)?.type, 'turn/end',
    'the child must remain terminal after the parent cancel')
  assert.equal(records(unrelatedLog).at(-1)?.type === 'turn/end', false,
    'the parent cancel must not reach the unrelated root')

  // A retry after the child is gone is a successful no-op, not a fabricated
  // drain or a second child record.
  const childCount = records(childLog).length
  const retry = await drain([parent])
  assert.equal(retry.status, 200, retry.text)
  assert.deepEqual(retry.json?.value?.roots, [parent], retry.text)
  assert.equal(records(childLog).length, childCount,
    'a retry after the child disposal must not append another child record')

  // Clean up the unrelated held turn; this is test teardown, not part of the
  // drain proof.
  await call('session/cancel', { request: { sessionId: unrelated } })
  await waitUntil('the unrelated root turn/end', 10_000,
    () => records(unrelatedLog).at(-1)?.type === 'turn/end')
})
