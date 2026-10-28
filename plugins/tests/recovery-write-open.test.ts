// SPDX-License-Identifier: MIT
/**
 * G2-FIX-93 recovery write-open against the real pinned DSH stack.
 *
 * The host may only abandon an interrupted step after the replacement Worker
 * has actually reconciled the tool journal. A history read (`session/follow`,
 * `session/page`) never opens the writer, so it cannot settle the journal. This
 * test seeds a stored session with one interrupted, journaled tool call, boots
 * the real phone surface bundle (pinned DSH AgentLoop + session-persistence +
 * tool-journal + the phone profile), and calls the phone-only recovery route.
 *
 * It proves all four facts the host relies on:
 *   1. the route performs `sessionPersistence.open(id, 'write')` (otherwise the
 *      session log never gains a `tool/result`);
 *   2. the mounted tool-journal wrapper reconciles the journal (`resolved`,
 *      `backfilled-done`) through the normal persistence path;
 *   3. the source session is not prompted, so the mock model receives 0 calls;
 *   4. the route closes the write handle and leaves no Agent behind.
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import {
  closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, readlinkSync,
  realpathSync, rmSync, statSync, truncateSync, writeFileSync, writeSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { after, before, test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'

import { Context } from '@deepseek-ai/cordis'
import { MessageId, ToolCallId, createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm'
import { SESSION_FORMAT_VERSION, SessionId, SessionSeq } from '@deepseek-ai/dsh-session'
import type { SessionEvent, SessionHeader } from '@deepseek-ai/dsh-session'

import { ToolJournalStore, idempotencyKey } from '../tool-journal/src/journal.ts'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const bundle = join(root, 'dist', 'dsh-phone-surface.mjs')
const LAUNCH_TOKEN = `recovery-${process.pid}-${Math.random().toString(16).slice(2)}`
const PROFILE = 'pdsh-phone/1+dsh-0.2.1-rc.2'
const SESSION_ID = 'recovery-orphan-1'
const CALL_ID = 'call-recovery-1'
const OPEN_TURN_SESSION_ID = 'recovery-open-turn-1'
const OPEN_TURN_CALL_ID = 'call-recovery-open-turn-1'
const TIMEOUT_SESSION_ID = 'recovery-timeout-1'
const TIMEOUT_CALL_ID = 'call-recovery-timeout-1'
const PRE_SEND_SESSION_ID = 'recovery-pre-send-cancel-1'
const PRE_SEND_CALL_ID = 'call-recovery-pre-send-cancel-1'
const RERUN_SESSION_ID = 'recovery-rerun-deadline-1'
const RERUN_CALL_ID = 'call-recovery-rerun-deadline-1'
const PENDING_INBOX_SESSION_ID = 'recovery-pending-inbox-1'
/**
 * Large enough that a full read cannot finish inside the route budget. The
 * file is sparse (only its first page carries bytes), so it costs no disk; the
 * real `read` tool streams it and must be cancelled at the deadline.
 */
const SLOW_READ_BYTES = 16 * 1024 ** 3
const SLOW_READ_PREFIX_BYTES = 8 * 1024
const RERUN_TIMEOUT_MS = 900
/** First ack of the timeout session is held past the retry open. */
const SLOW_FIRST_ACK_MS = 5_000
const FIRST_ATTEMPT_TIMEOUT_MS = 900
/**
 * The preloaded test transport acknowledges each JOURNAL frame only after this
 * delay. A route that returns before its `resolved` append is acknowledged is
 * therefore measurably faster than the delay; the real production route waits.
 */
const JOURNAL_ACK_DELAY_MS = 1000
const CHANNEL_FIXTURE = join(here, 'fixtures', 'recovery-journal-channel.mjs')

let directory = ''
let workspace = ''
let home = ''
let tracePath = ''
let slowReadPath = ''
let surface: ChildProcess | undefined
let baseURL = ''
let cookie = ''
let modelCalls = 0
let modelServer: ReturnType<typeof createServer> | undefined
let serveSuccessfulModel = false
let pendingInboxSeed: { messageId: string; text: string } | undefined

/** Recursively collect files below one directory. */
function filesBelow(directoryPath: string): string[] {
  const files: string[] = []
  for (const entry of readdirSync(directoryPath, { withFileTypes: true })) {
    const path = join(directoryPath, entry.name)
    if (entry.isDirectory()) files.push(...filesBelow(path))
    else if (entry.isFile()) files.push(path)
  }
  return files
}

/** The current-generation session log of one stored session. */
function sessionLogPath(sessionID: string = SESSION_ID): string {
  const match = filesBelow(join(home, 'sessions'))
    .filter(path => /session\.v\d+\.jsonl$/.test(path))
    .filter(path => readFileSync(path, 'utf8').includes(sessionID))
    .sort()
  assert.equal(match.length, 1,
    `expected one session log for ${sessionID}, got ${match.join(', ')}`)
  return match[0] as string
}

/** The real tool-journal NDJSON file of one stored session. */
function journalPath(sessionID: string): string {
  return join(home, 'tool-journal', `${sessionID}.journal.ndjson`)
}

/** JOURNAL frames/acks recorded by the preloaded transport, in order. */
function traceEvents(): Array<Record<string, any>> {
  if (!existsSync(tracePath)) return []
  return readFileSync(tracePath, 'utf8')
    .split('\n')
    .filter(line => line.trim() !== '')
    .map(line => JSON.parse(line) as Record<string, any>)
}

/** One JSONL record from a persisted file. */
function records(path: string): Array<Record<string, any>> {
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter(line => line.trim() !== '')
    .map(line => JSON.parse(line) as Record<string, any>)
}

/** Seed one interrupted session through the real DSH persistence backend. */
async function seedSession(sessionID: string = SESSION_ID,
                           callID: string = CALL_ID): Promise<void> {
  const ctx = new Context()
  // The repository's legacy type shim declares only the old default-class
  // export, so resolve the real 0.2.1 function plugin dynamically.
  const jsonl = await import('@deepseek-ai/dsh-session-persistence-jsonl') as unknown as {
    apply: (ctx: Context, config: { root: string; compression: string }) => Promise<void>
  }
  const fiber = await ctx.plugin({
    name: 'session-persistence-jsonl',
    apply: jsonl.apply,
  } as never, {
    root: join(home, 'sessions'),
    compression: 'none',
  } as never)
  try {
    const header: SessionHeader = {
      version: SESSION_FORMAT_VERSION,
      id: SessionId(sessionID),
      createdAt: 1_000,
      cwd: workspace,
      isSeeded: false,
    }
    const handle = await ctx.sessionPersistence.create(header)
    await handle.append([
      { type: 'turn/start', seq: SessionSeq(0), time: 1_000, data: { turn: 1 } },
      { type: 'step/start', seq: SessionSeq(1), time: 1_001, data: { turn: 1, step: 1 } },
      { type: 'assistant/message', seq: SessionSeq(2), time: 1_002, surfaceOp: 'append', data: {
        turn: 1,
        step: 1,
        stream: [],
        message: freezeMessage({
          id: MessageId(`assistant-${callID}`),
          role: 'assistant',
          content: [{
            type: 'tool-call',
            id: ToolCallId(callID),
            name: 'bash',
            arguments: '{"command":"echo hi"}',
          }],
          source: { kind: 'model', provider: 'mock', model: 'mock' },
        }),
      } },
      { type: 'tool/call', seq: SessionSeq(3), time: 1_003, data: {
        turn: 1,
        step: 1,
        callId: ToolCallId(callID),
        name: 'bash',
        arguments: '{"command":"echo hi"}',
      } },
    ] as unknown as SessionEvent[])
    await handle.close()
  } finally {
    await fiber.dispose()
  }

  const store = new ToolJournalStore(join(home, 'tool-journal'), PROFILE)
  const key = idempotencyKey(sessionID, callID)
  await store.append(sessionID, {
    v: 1,
    t: 'start',
    key,
    call_id: callID,
    tool: 'bash',
    class: 'non-idempotent',
    args_sha256: 'args-hash',
    schema_sha256: null,
    profile: PROFILE,
    at: 1_004,
  })
  await store.append(sessionID, {
    v: 1,
    t: 'done',
    key,
    call_id: callID,
    result: { content: [{ type: 'text', text: 'hi' }], isError: false },
    at: 1_005,
  })
  await store.settled(sessionID)
  store.close()
}

/**
 * Seed a stored session whose only interrupted call is a read-only `read` with
 * a journal `start` and no result, so the next write-open must re-run it.
 */
async function seedRerunSession(): Promise<void> {
  const ctx = new Context()
  const jsonl = await import('@deepseek-ai/dsh-session-persistence-jsonl') as unknown as {
    apply: (ctx: Context, config: { root: string; compression: string }) => Promise<void>
  }
  const fiber = await ctx.plugin({
    name: 'session-persistence-jsonl',
    apply: jsonl.apply,
  } as never, {
    root: join(home, 'sessions'),
    compression: 'none',
  } as never)
  const args = JSON.stringify({ file_path: 'slow-read.txt' })
  try {
    const header: SessionHeader = {
      version: SESSION_FORMAT_VERSION,
      id: SessionId(RERUN_SESSION_ID),
      createdAt: 2_000,
      cwd: workspace,
      isSeeded: false,
    }
    const handle = await ctx.sessionPersistence.create(header)
    await handle.append([
      { type: 'turn/start', seq: SessionSeq(0), time: 2_000, data: { turn: 1 } },
      { type: 'step/start', seq: SessionSeq(1), time: 2_001, data: { turn: 1, step: 1 } },
      { type: 'assistant/message', seq: SessionSeq(2), time: 2_002, surfaceOp: 'append', data: {
        turn: 1,
        step: 1,
        stream: [],
        message: freezeMessage({
          id: MessageId(`assistant-${RERUN_CALL_ID}`),
          role: 'assistant',
          content: [{
            type: 'tool-call',
            id: ToolCallId(RERUN_CALL_ID),
            name: 'read',
            arguments: args,
          }],
          source: { kind: 'model', provider: 'mock', model: 'mock' },
        }),
      } },
      { type: 'tool/call', seq: SessionSeq(3), time: 2_003, data: {
        turn: 1,
        step: 1,
        callId: ToolCallId(RERUN_CALL_ID),
        name: 'read',
        arguments: args,
      } },
    ] as unknown as SessionEvent[])
    await handle.close()
  } finally {
    await fiber.dispose()
  }

  const store = new ToolJournalStore(join(home, 'tool-journal'), PROFILE)
  await store.append(RERUN_SESSION_ID, {
    v: 1,
    t: 'start',
    key: idempotencyKey(RERUN_SESSION_ID, RERUN_CALL_ID),
    call_id: RERUN_CALL_ID,
    tool: 'read',
    class: 'read-only',
    args_sha256: 'args-hash',
    // A null schema hash accepts the registered `read` tool without pinning a
    // build-specific schema hash into the fixture.
    schema_sha256: null,
    profile: PROFILE,
    at: 2_004,
  })
  await store.settled(RERUN_SESSION_ID)
  store.close()
}

/**
 * Seed one interrupted session with a user prompt already queued in DSH's
 * durable next-turn inbox. The real recovery route must close the open turn
 * without touching that inbox: an Agent resume/dispose would splice it away
 * with `outcome:'canceled'` before the user could see it run.
 */
async function seedPendingInboxSession(): Promise<{ messageId: string; text: string }> {
  const pending = createUserMessage({
    content: [{ type: 'text', text: 'Queued follow-up must survive recovery.' }],
    source: { kind: 'user' },
  })
  const ctx = new Context()
  const jsonl = await import('@deepseek-ai/dsh-session-persistence-jsonl') as unknown as {
    apply: (ctx: Context, config: { root: string; compression: string }) => Promise<void>
  }
  const fiber = await ctx.plugin({
    name: 'session-persistence-jsonl',
    apply: jsonl.apply,
  } as never, {
    root: join(home, 'sessions'),
    compression: 'none',
  } as never)
  try {
    const header: SessionHeader = {
      version: SESSION_FORMAT_VERSION,
      id: SessionId(PENDING_INBOX_SESSION_ID),
      createdAt: 3_000,
      cwd: workspace,
      isSeeded: false,
    }
    const handle = await ctx.sessionPersistence.create(header)
    await handle.append([
      { type: 'turn/start', seq: SessionSeq(0), time: 3_000, data: { turn: 1 } },
      { type: 'step/start', seq: SessionSeq(1), time: 3_001, data: { turn: 1, step: 1 } },
      { type: 'agent/inbox/spliced', seq: SessionSeq(2), time: 3_002, data: {
        target: 'next-turn',
        start: 0,
        inserted: [pending],
      } },
    ] as unknown as SessionEvent[])
    await handle.close()
  } finally {
    await fiber.dispose()
  }
  return { messageId: String(pending.id), text: 'Queued follow-up must survive recovery.' }
}

/** The surface process's open file targets, when `/proc` is available. */
function openFileDescriptors(pid: number | undefined): { available: boolean; targets: string[] } {
  if (pid === undefined) return { available: false, targets: [] }
  try {
    const directory = `/proc/${String(pid)}/fd`
    const targets = readdirSync(directory).map((entry) => {
      try {
        return readlinkSync(join(directory, entry))
      } catch {
        return ''
      }
    })
    return { available: true, targets }
  } catch {
    return { available: false, targets: [] }
  }
}

/** Call one Remote method through the authenticated /api carrier. */
async function rpc(method: string, args: unknown): Promise<{
  status: number
  body: string
  json: Record<string, any> | undefined
}> {
  const rpcId = crypto.randomUUID()
  const response = await fetch(`${baseURL}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } }),
  })
  const text = await response.text()
  return {
    status: response.status,
    body: text,
    json: (() => { try { return JSON.parse(text) as Record<string, any> } catch { return undefined } })(),
  }
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

before(async () => {
  if (!existsSync(join(root, 'node_modules', '@deepseek-ai', 'dsh'))) {
    throw new Error('plugins/node_modules is missing; run npm install --ignore-scripts first')
  }
  // Always rebuild: dist/ is gitignored and a stale bundle must not satisfy the
  // write-open proof with the old session/follow code.
  const build = spawnSync(process.execPath, [join(root, 'bundle', 'build.mjs'), '--surface', 'phone'], {
    cwd: root,
    encoding: 'utf8',
  })
  assert.equal(build.status, 0, `bundle build failed: ${build.stderr}`)

  directory = mkdtempSync(join(tmpdir(), 'pdsh-recovery-write-open-'))
  workspace = join(directory, 'ws')
  home = join(directory, 'home')
  tracePath = join(directory, 'journal-trace.ndjson')
  mkdirSync(workspace, { recursive: true })
  mkdirSync(home, { recursive: true })
  workspace = realpathSync(workspace)
  home = realpathSync(home)
  slowReadPath = join(workspace, 'slow-read.txt')

  await seedSession()
  await seedRerunSession()
  pendingInboxSeed = await seedPendingInboxSession()

  modelServer = createServer((request, response) => {
    modelCalls += 1
    request.resume()
    if (!serveSuccessfulModel) {
      response.writeHead(500, { 'content-type': 'application/json' })
      response.end('{"type":"error","error":{"type":"unexpected_model_call"}}')
      return
    }
    // A minimal Messages-compatible stream. Only the queued-prompt regression
    // enables it, after the recovery route has already returned.
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
    response.write('event: message_start\ndata: {"type":"message_start","message":{"id":"msg_recovery_pending","type":"message","role":"assistant","model":"mock","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}\n\n')
    response.write('event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n')
    response.write('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"queued prompt consumed"}}\n\n')
    response.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
    response.write('event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}\n\n')
    response.write('event: message_stop\ndata: {"type":"message_stop"}\n\n')
    response.end()
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
      PDSH_CHANNEL_ORIGIN: 'http://127.0.0.1:9',
      PDSH_DSH_VERSION: '0.2.1-rc.2',
      DSH_TELEMETRY_DISABLED: '1',
      // The surface bundle normally inherits the Worker entry's ordered
      // channel. This preload supplies only that transport seam, with a real
      // delayed level-1 JOURNAL_ACK, so the route's wait is observable.
      NODE_OPTIONS: [process.env.NODE_OPTIONS,
        `--import=${pathToFileURL(CHANNEL_FIXTURE).href}`].filter(Boolean).join(' '),
      PDSH_TEST_JOURNAL_TRACE: tracePath,
      PDSH_TEST_JOURNAL_ACK_DELAY_MS: String(JOURNAL_ACK_DELAY_MS),
      PDSH_TEST_JOURNAL_SLOW_SESSIONS: [TIMEOUT_SESSION_ID, PRE_SEND_SESSION_ID].join(','),
      PDSH_TEST_JOURNAL_SLOW_ACK_DELAY_MS: String(SLOW_FIRST_ACK_MS),
      PDSH_TEST_JOURNAL_SEEDED_SESSIONS:
        [SESSION_ID, OPEN_TURN_SESSION_ID, TIMEOUT_SESSION_ID, PRE_SEND_SESSION_ID,
          RERUN_SESSION_ID, PENDING_INBOX_SESSION_ID].join(','),
      // The rerun fixture journals only `start` (jseq 1); the backfill fixtures
      // journal `start` + `done` (jseq 2).
      PDSH_TEST_JOURNAL_SEED_HIGHS: `${RERUN_SESSION_ID}:1`,
      // The retry's `done` + `resolved` appends must both fit under the route's
      // 1500 ms hard budget; the ack wait itself is covered by the first test.
      PDSH_TEST_JOURNAL_FAST_SESSIONS: RERUN_SESSION_ID,
      PDSH_TEST_JOURNAL_PRE_SEND_CANCEL_SESSION: PRE_SEND_SESSION_ID,
      PDSH_TEST_JOURNAL_PRE_SEND_APPEND_DELAY_MS:
        String(FIRST_ATTEMPT_TIMEOUT_MS + 300),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const port = await waitForSurface(surface)
  baseURL = `http://127.0.0.1:${port}`
  const exchange = await fetch(`${baseURL}/?token=${encodeURIComponent(LAUNCH_TOKEN)}`, { redirect: 'manual' })
  assert.equal(exchange.status, 303, 'launch-token exchange must redirect')
  cookie = (exchange.headers.get('set-cookie') ?? '').split(';', 1)[0] ?? ''
  assert.ok(cookie.includes('='))
})

after(async () => {
  surface?.kill('SIGTERM')
  modelServer?.closeAllConnections()
  modelServer?.close()
  await sleep(200)
  if (directory !== '') rmSync(directory, { recursive: true, force: true })
})

test('recovery write-open waits for the resolved JOURNAL level-1 ack and makes no model call', async () => {
  const startedAt = Date.now()
  const response = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: SESSION_ID, timeoutMs: 5_000 }),
  })
  const respondedAt = Date.now()
  const text = await response.text()
  assert.equal(response.status, 200, text)
  const value = JSON.parse(text) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean }
  }
  assert.equal(value.ok, true, text)
  assert.equal(value.value?.sessionId, SESSION_ID)
  assert.equal(value.value?.access, 'write', 'the recovery route must open the writer')
  assert.equal(value.value?.closed, true, 'the recovery route must close its write handle')

  // The route may not return before the delayed level-1 ack. Without the
  // awaited `resolved` append it returned in a few milliseconds, leaving the
  // host's 2 s grace to abandon the step before the JOURNAL frame was acked.
  assert.ok(respondedAt - startedAt >= JOURNAL_ACK_DELAY_MS - 50,
    `the route returned in ${String(respondedAt - startedAt)} ms, before the `
      + `${String(JOURNAL_ACK_DELAY_MS)} ms journal ack`)

  const trace = traceEvents()
  const sent = trace.find(event => event.event === 'sent'
    && event.sessionId === SESSION_ID && event.record?.type === 'resolved')
  assert.ok(sent, `the route must emit the resolved JOURNAL frame:\n${JSON.stringify(trace)}`)
  assert.equal(sent.record.action, 'backfilled-done')
  const acked = trace.find(event => event.event === 'acked'
    && event.sessionId === SESSION_ID && event.jseq >= sent.jseq)
  assert.ok(acked, `the resolved JOURNAL frame must be level-1 acknowledged:\n${JSON.stringify(trace)}`)
  assert.ok(acked.at >= sent.at && acked.at <= respondedAt + 20,
    'the response must follow the acknowledged resolved frame')

  const log = records(sessionLogPath())
  const result = log.find(record => record.type === 'tool/result'
    && record.data?.message?.toolCallId === CALL_ID)
  assert.ok(result, `the write-open must append the journaled tool result:\n${log.map(record => record.type).join(',')}`)

  const journal = records(journalPath(SESSION_ID))
  const resolved = journal.find(record => record.t === 'resolved' && record.call_id === CALL_ID)
  assert.ok(resolved, `the reconcile must append a resolved record:\n${journal.map(record => record.t).join(',')}`)
  assert.equal(resolved.action, 'backfilled-done', 'the journaled done result must be backfilled')

  // Read-only history cannot produce the tool/result above; a prompt would
  // have hit the model server. Zero calls proves the route activated no Agent
  // turn and never asked the model to continue.
  assert.equal(modelCalls, 0, 'recovery must not make a model call')

  // The write handle is closed: a second recovery open succeeds and produces
  // no duplicate tool/result.
  const again = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: SESSION_ID }),
  })
  assert.equal(again.status, 200, await again.text())
  const afterSecond = records(sessionLogPath())
  assert.equal(afterSecond.filter(record => record.type === 'tool/result').length, 1,
    'a second recovery open must not duplicate the reconciled result')
  assert.equal(modelCalls, 0, 'recovery must not make a model call')
  assert.ok(statSync(sessionLogPath()).size > 0)
})

test('the recovery resume route lets DSH close an interrupted tail turn without a model call', async () => {
  await seedSession(OPEN_TURN_SESSION_ID, OPEN_TURN_CALL_ID)
  const before = records(sessionLogPath(OPEN_TURN_SESSION_ID))
  assert.ok(before.some(record => record.type === 'turn/start'), 'the fixture has an open turn')
  assert.ok(!before.some(record => record.type === 'turn/end'), 'the fixture turn is still open')

  const response = await fetch(`${baseURL}/api/pdsh-recovery/resume`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: OPEN_TURN_SESSION_ID, timeoutMs: 5_000 }),
  })
  const text = await response.text()
  assert.equal(response.status, 200, text)
  const value = JSON.parse(text) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean }
  }
  assert.equal(value.ok, true, text)
  assert.equal(value.value?.sessionId, OPEN_TURN_SESSION_ID)
  assert.equal(value.value?.access, 'resume')
  assert.equal(value.value?.closed, true)

  const after = records(sessionLogPath(OPEN_TURN_SESSION_ID))
  const ended = after.filter(record => record.type === 'turn/end')
  assert.equal(ended.length, 1, `the resume must append exactly one turn/end: ${JSON.stringify(after.map(record => record.type))}`)
  assert.equal(ended[0]?.data?.reason?.kind, 'interrupted',
    'the pinned session repair owns the interrupted reason; the route must not fabricate another one')
  assert.equal(modelCalls, 0, 'resuming for recovery must not make a model call')

  const again = await fetch(`${baseURL}/api/pdsh-recovery/resume`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: OPEN_TURN_SESSION_ID }),
  })
  assert.equal(again.status, 200, await again.text())
  const afterSecond = records(sessionLogPath(OPEN_TURN_SESSION_ID))
  assert.equal(afterSecond.filter(record => record.type === 'turn/end').length, 1,
    'a second resume must not duplicate the terminal turn')
  assert.equal(modelCalls, 0, 'a second recovery resume must not make a model call')
})

test('the resume route keeps the documented recovery contract', async () => {
  const post = async (body: string, contentType = 'application/json') => {
    const response = await fetch(`${baseURL}/api/pdsh-recovery/resume`, {
      method: 'POST',
      headers: { 'content-type': contentType, cookie },
      body,
    })
    const text = await response.text()
    return {
      status: response.status,
      headers: response.headers,
      text,
      json: (() => { try { return JSON.parse(text) as Record<string, any> } catch { return undefined } })(),
    }
  }

  const wrongType = await post('{}', 'text/plain')
  assert.equal(wrongType.status, 415, wrongType.text)
  assert.equal(wrongType.json?.error?.code, 'recovery/content-type')

  const badBody = await post('{"sessionId":')
  assert.equal(badBody.status, 400, badBody.text)
  assert.equal(badBody.json?.error?.code, 'recovery/bad-json')

  const noSession = await post(JSON.stringify({ timeoutMs: 1 }))
  assert.equal(noSession.status, 400, noSession.text)
  assert.equal(noSession.json?.error?.code, 'recovery/bad-request')

  const emptySession = await post(JSON.stringify({ sessionId: '', timeoutMs: 1 }))
  assert.equal(emptySession.status, 400, emptySession.text)
  assert.equal(emptySession.json?.error?.code, 'recovery/bad-request')

  const badBudget = await post(JSON.stringify({ sessionId: OPEN_TURN_SESSION_ID, timeoutMs: 0 }))
  assert.equal(badBudget.status, 400, badBudget.text)
  assert.equal(badBudget.json?.error?.code, 'recovery/bad-budget')

  const tooLarge = await post(JSON.stringify({ sessionId: OPEN_TURN_SESSION_ID,
    padding: 'x'.repeat(5_000) }))
  assert.equal(tooLarge.status, 413, tooLarge.text)
  assert.equal(tooLarge.json?.error?.code, 'recovery/body-too-large')

  const missing = await post(JSON.stringify({ sessionId: 'recovery-contract-missing' }))
  assert.equal(missing.status, 404, missing.text)
  assert.equal(missing.json?.error?.code, 'recovery/session-not-found')

  // The already-balanced session is a successful no-op: the route still opens
  // and closes the writer, reports zero closers, and never prompts.
  const balanced = await post(JSON.stringify({ sessionId: OPEN_TURN_SESSION_ID,
    timeoutMs: 60_000 }))
  assert.equal(balanced.status, 200, balanced.text)
  assert.equal(balanced.headers.get('cache-control'), 'no-store')
  assert.equal(balanced.json?.value?.access, 'resume')
  assert.equal(balanced.json?.value?.appended, 0)
  assert.equal(modelCalls, 0)
})

test('the recovery resume route preserves a queued user prompt for a later turn', async () => {
  const seeded = pendingInboxSeed
  assert.ok(seeded, 'the pending-inbox fixture must be prepared')
  const before = records(sessionLogPath(PENDING_INBOX_SESSION_ID))
  assert.ok(before.some(record => record.type === 'turn/start'), 'the fixture turn is open')
  assert.ok(!before.some(record => record.type === 'turn/end'), 'the fixture turn is not terminal')
  assert.ok(before.some(record => record.type === 'agent/inbox/spliced'
    && record.data?.inserted?.[0]?.id === seeded.messageId),
  'the fixture must carry one pending next-turn prompt')

  const response = await fetch(`${baseURL}/api/pdsh-recovery/resume`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: PENDING_INBOX_SESSION_ID, timeoutMs: 5_000 }),
  })
  const text = await response.text()
  assert.equal(response.status, 200, text)
  const value = JSON.parse(text) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean; appended?: number }
  }
  assert.equal(value.ok, true, text)
  assert.equal(value.value?.access, 'resume')
  assert.equal(value.value?.closed, true)
  assert.ok((value.value?.appended ?? 0) > 0,
    'the interrupted fixture must need DSH-authored closers')

  const after = records(sessionLogPath(PENDING_INBOX_SESSION_ID))
  assert.equal(after.filter(record => record.type === 'turn/end').length, 1,
    'the route must append exactly one DSH turn/end')
  assert.equal(after.find(record => record.type === 'turn/end')?.data?.reason?.kind,
    'interrupted')
  assert.equal(after.filter(record => record.type === 'agent/inbox/spliced'
    && record.data?.outcome === 'canceled').length, 0,
  'recovery must not splice a pending user prompt as canceled')
  const pendingAfter = after.filter(record => record.type === 'agent/inbox/spliced')
    .flatMap(record => record.data?.inserted ?? [])
    .find(message => message.id === seeded.messageId)
  assert.ok(pendingAfter, 'the queued prompt must still be pending after repair')
  assert.equal(modelCalls, 0, 'the repair itself must not prompt the model')

  // A later turn must be able to consume the preserved prompt. The mock model
  // answers successfully only for this phase; the queued message becomes a
  // normal user/message in the resumed session.
  serveSuccessfulModel = true
  try {
    const prompted = await rpc('session/prompt', { request: {
      requestId: crypto.randomUUID(),
      sessionId: PENDING_INBOX_SESSION_ID,
      mode: 'queue',
      content: [{ type: 'text', text: 'A later turn wakes the queued prompt.' }],
    } })
    assert.equal(prompted.status, 200, prompted.body)
    assert.equal(prompted.json?.result?.ok, true, prompted.body)
    const deadline = Date.now() + 15_000
    while (true) {
      const consumed = records(sessionLogPath(PENDING_INBOX_SESSION_ID))
      if (consumed.some(record => record.type === 'user/message'
        && JSON.stringify(record.data).includes(seeded.text))) break
      if (Date.now() >= deadline) {
        throw new Error('the preserved prompt was never consumed by a later turn')
      }
      await sleep(50)
    }
    const consumed = records(sessionLogPath(PENDING_INBOX_SESSION_ID))
    assert.ok(consumed.some(record => record.type === 'agent/inbox/spliced'
      && record.data?.removedCount === 1 && record.data?.outcome !== 'canceled'),
    'the later turn must claim the preserved prompt, not cancel it')
    assert.equal(consumed.filter(record => record.type === 'agent/inbox/spliced'
      && record.data?.outcome === 'canceled').length, 0,
    'the later turn must not cancel the queued prompt')
  } finally {
    serveSuccessfulModel = false
    // Stop the agent this regression woke: the later-turn prompt and the
    // model stream are test-local, and leaving the driver running would spend
    // model calls in the following no-model-call assertions.
    try {
      await rpc('session/cancel', { request: { sessionId: PENDING_INBOX_SESSION_ID } })
    } catch {}
    const quietUntil = Date.now() + 1_000
    let lastCount = modelCalls
    while (Date.now() < quietUntil) {
      await sleep(50)
      if (modelCalls === lastCount) break
      lastCount = modelCalls
    }
    // Rebase the shared counter after the test-local driver is stopped.
    modelCalls = 0
  }
})

test('a timed-out write-open releases the writer and a retry completes without duplicates', async () => {
  await seedSession(TIMEOUT_SESSION_ID, TIMEOUT_CALL_ID)
  const timedOutAt = Date.now()
  const timedOut = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: TIMEOUT_SESSION_ID, timeoutMs: FIRST_ATTEMPT_TIMEOUT_MS }),
  })
  const timeoutText = await timedOut.text()
  assert.equal(timedOut.status, 504,
    `a deadline before the JOURNAL ack must fail loudly, got ${timeoutText}`)
  const timeoutBody = JSON.parse(timeoutText) as {
    ok?: boolean
    value?: { closed?: boolean }
    error?: { code?: string }
  }
  assert.equal(timeoutBody.ok, false, 'a timeout must not report success')
  assert.equal(timeoutBody.value, undefined,
    'a timeout must not claim the background writer was closed')
  assert.equal(timeoutBody.error?.code, 'recovery/timeout')

  // The session log append (durable before the journal ack) happened; only
  // the `resolved` acknowledgement was cut off. The next write-open must
  // retry that acknowledgement instead of returning success with the host
  // still waiting for terminal journal evidence.
  const intermediate = records(sessionLogPath(TIMEOUT_SESSION_ID))
  assert.equal(intermediate.filter(record => record.type === 'tool/result').length, 1,
    'the timed-out attempt must not duplicate or lose the tool result')

  const retryStartedAt = Date.now()
  const retry = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: TIMEOUT_SESSION_ID, timeoutMs: 5_000 }),
  })
  const retryText = await retry.text()
  assert.equal(retry.status, 200, retryText)
  const retryBody = JSON.parse(retryText) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean }
  }
  assert.equal(retryBody.ok, true, retryText)
  assert.equal(retryBody.value?.sessionId, TIMEOUT_SESSION_ID)
  assert.equal(retryBody.value?.access, 'write')
  assert.equal(retryBody.value?.closed, true)
  assert.ok(Date.now() - retryStartedAt >= JOURNAL_ACK_DELAY_MS - 200,
    'the retry must wait for its own level-1 ack, not return with an unacked record')

  const afterRetry = records(sessionLogPath(TIMEOUT_SESSION_ID))
  assert.equal(afterRetry.filter(record => record.type === 'tool/result').length, 1,
    'a retried recovery open must not duplicate the reconciled result')
  const journal = records(journalPath(TIMEOUT_SESSION_ID))
  assert.ok(journal.some(record => record.t === 'resolved' && record.call_id === TIMEOUT_CALL_ID),
    `the retry must append the missing resolved record:\n${journal.map(record => record.t).join(',')}`)
  const trace = traceEvents()
  assert.ok(trace.some(event => event.event === 'sent' && event.at >= retryStartedAt
    && event.sessionId === TIMEOUT_SESSION_ID && event.record?.type === 'resolved'),
    'the retry must re-emit the unacknowledged resolved JOURNAL frame')
  assert.ok(trace.some(event => event.event === 'acked' && event.at >= retryStartedAt
    && event.sessionId === TIMEOUT_SESSION_ID),
    'the retry must receive a level-1 ack before returning')

  // A third open is clean and immediate: the writer lock was actually
  // released by both the failed and the successful attempt.
  const third = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: TIMEOUT_SESSION_ID }),
  })
  assert.equal(third.status, 200, await third.text())
  assert.equal(records(sessionLogPath(TIMEOUT_SESSION_ID))
    .filter(record => record.type === 'tool/result').length, 1,
  'the third recovery open must not duplicate the reconciled result')
  assert.equal(modelCalls, 0, 'recovery must not make a model call')
  assert.ok(Date.now() > timedOutAt)
})

test('cancellation after local append still sends contiguous jseq before retry', async () => {
  await seedSession(PRE_SEND_SESSION_ID, PRE_SEND_CALL_ID)

  const first = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
  // The preload delays only the promise return after the real local NDJSON
  // append has completed. The shorter route deadline aborts while it is paused,
  // before the mirror is called.
    body: JSON.stringify({ sessionId: PRE_SEND_SESSION_ID, timeoutMs: FIRST_ATTEMPT_TIMEOUT_MS }),
  })
  const firstText = await first.text()
  assert.equal(first.status, 504, firstText)
  const firstBody = JSON.parse(firstText) as { value?: unknown; error?: { code?: string } }
  assert.equal(firstBody.value, undefined,
    'a cancelled pre-send recovery must not claim a closed writer')
  assert.equal(firstBody.error?.code, 'recovery/timeout')

  const afterFirst = traceEvents().filter(event => event.sessionId === PRE_SEND_SESSION_ID)
  const localAppend = afterFirst.find(event => event.event === 'local-append-complete')
  assert.equal(localAppend?.jseq, 3,
    `the probe must abort after local resolved jseq 3 was appended: ${JSON.stringify(afterFirst)}`)
  const appendReturned = afterFirst.find(event => event.event === 'append-promise-returned')
  assert.ok(appendReturned && localAppend
    && appendReturned.at - localAppend.at > FIRST_ATTEMPT_TIMEOUT_MS,
  'the recovery deadline must expire after the actual file append and before its promise returns')

  const retryStartedAt = Date.now()
  const retry = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: PRE_SEND_SESSION_ID, timeoutMs: 5_000 }),
  })
  const retryText = await retry.text()
  const trace = traceEvents().filter(event => event.sessionId === PRE_SEND_SESSION_ID)
  assert.equal(retry.status, 200,
    `${retryText}; host frame trace: ${JSON.stringify(trace)}`)
  const retryBody = JSON.parse(retryText) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean }
  }
  assert.equal(retryBody.ok, true, retryText)
  assert.equal(retryBody.value?.sessionId, PRE_SEND_SESSION_ID)
  assert.equal(retryBody.value?.access, 'write')
  assert.equal(retryBody.value?.closed, true)

  const received = trace.filter(event => event.event === 'received')
  assert.deepEqual(received.map(event => event.jseq), [3, 4],
    `the host must receive contiguous resolved jseqs: ${JSON.stringify(trace)}`)
  assert.equal(trace.filter(event => event.event === 'gap').length, 0,
    `the host fixture must not reject a jseq gap: ${JSON.stringify(trace)}`)
  assert.ok(trace.some(event => event.event === 'acked' && event.jseq === 4
    && event.at >= retryStartedAt),
  'the successful retry must wait for the host acknowledgement of jseq 4')

  const log = records(sessionLogPath(PRE_SEND_SESSION_ID))
  assert.equal(log.filter(record => record.type === 'tool/result').length, 1,
    'retry must not duplicate the tool result')
  const third = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: PRE_SEND_SESSION_ID }),
  })
  assert.equal(third.status, 200,
    `a third open proves the timed-out and retried writers were released: ${await third.text()}`)
  assert.equal(modelCalls, 0, 'recovery must not make a model call')
})

test('a route deadline cancels an in-flight read-only rerun and releases its writer', {
  timeout: 30_000,
}, async () => {
  // A sparse text file far larger than the route budget: the real `read` tool
  // streams it, so only the route's AbortSignal can end the call inside 900 ms.
  writeFileSync(slowReadPath, '')
  truncateSync(slowReadPath, SLOW_READ_BYTES)
  const slowFD = openSync(slowReadPath, 'r+')
  try {
    writeSync(slowFD, Buffer.alloc(SLOW_READ_PREFIX_BYTES, 0x61), 0, SLOW_READ_PREFIX_BYTES, 0)
  } finally {
    closeSync(slowFD)
  }

  const startedAt = Date.now()
  const request = fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: RERUN_SESSION_ID, timeoutMs: RERUN_TIMEOUT_MS }),
  })
  // The real `read` body must be in flight (and holding the huge file open)
  // when the deadline aborts it, not skipped or finished early.
  await sleep(500)
  const during = openFileDescriptors(surface?.pid)
  if (during.available) {
    assert.equal(during.targets.some(target => target.endsWith('slow-read.txt')), true,
      `the rerun read must still be running at the deadline: ${during.targets.join(', ')}`)
  }
  const timedOut = await request
  const timedOutAt = Date.now()
  const timeoutText = await timedOut.text()
  assert.equal(timedOut.status, 504, timeoutText)
  const timeoutBody = JSON.parse(timeoutText) as {
    ok?: boolean
    value?: unknown
    error?: { code?: string }
  }
  assert.equal(timeoutBody.ok, false, 'a cancelled rerun must not report success')
  assert.equal(timeoutBody.value, undefined,
    'a cancelled rerun must not claim a closed writer as a success value')
  assert.equal(timeoutBody.error?.code, 'recovery/timeout')
  assert.ok(timedOutAt - startedAt >= RERUN_TIMEOUT_MS - 100,
    `the route returned after ${String(timedOutAt - startedAt)} ms, before its `
      + `${String(RERUN_TIMEOUT_MS)} ms deadline`)
  // The huge stream takes several seconds. Returning well before that proves
  // the cancellation reached the running tool instead of waiting for it.
  assert.ok(timedOutAt - startedAt < 4_000,
    `the route waited ${String(timedOutAt - startedAt)} ms for the huge read; `
      + 'the rerun tool did not observe the route cancellation')

  // The cancelled attempt must not fabricate a result: the call still has only
  // its journal `start`, and neither a `tool/result` nor a `resolved` record.
  await sleep(250)
  assert.equal(records(sessionLogPath(RERUN_SESSION_ID))
    .filter(record => record.type === 'tool/result').length, 0,
  'the cancelled rerun must not append a tool result')
  assert.deepEqual(records(journalPath(RERUN_SESSION_ID))
    .filter(record => record.call_id === RERUN_CALL_ID).map(record => record.t), ['start'],
  'the cancelled rerun must leave the call unresolved, not fake a done/resolved record')

  // The real read stream was cancelled, not merely abandoned: its descriptor
  // must be gone from the surface process before the retry opens the writer.
  const descriptors = openFileDescriptors(surface?.pid)
  if (descriptors.available) {
    assert.equal(descriptors.targets.some(target => target.endsWith('slow-read.txt')), false,
      `the cancelled read must close its file: ${descriptors.targets.join(', ')}`)
  }

  // Make the retry finish: the same read-only call now reads a small file.
  truncateSync(slowReadPath, 0)
  writeFileSync(slowReadPath, 'recovered after cancellation\n')

  const retryStartedAt = Date.now()
  const retry = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: RERUN_SESSION_ID, timeoutMs: 5_000 }),
  })
  const retryText = await retry.text()
  assert.equal(retry.status, 200, `${retryText}; retry took ${String(Date.now() - retryStartedAt)} ms`)
  const retryBody = JSON.parse(retryText) as {
    ok?: boolean
    value?: { sessionId?: string; access?: string; closed?: boolean }
  }
  assert.equal(retryBody.ok, true, retryText)
  assert.equal(retryBody.value?.sessionId, RERUN_SESSION_ID)
  assert.equal(retryBody.value?.access, 'write')
  assert.equal(retryBody.value?.closed, true)

  const retriedLog = records(sessionLogPath(RERUN_SESSION_ID))
  const results = retriedLog.filter(record => record.type === 'tool/result'
    && record.data?.message?.toolCallId === RERUN_CALL_ID)
  assert.equal(results.length, 1, 'the retried rerun must append exactly one tool result')
  assert.equal(results[0]?.data?.message?.isError, false)
  const resultText = (results[0]?.data?.message?.content as Array<{ text?: string }> | undefined)
    ?.map(part => part.text ?? '').join('') ?? ''
  assert.match(resultText, /recovered after cancellation/,
    'the retried rerun must carry the real read result')
  assert.equal(retriedLog.filter(record => record.type === 'tool/result').length, 1,
    'the cancelled and retried open must not duplicate the tool result')

  const retriedJournal = records(journalPath(RERUN_SESSION_ID))
    .filter(record => record.call_id === RERUN_CALL_ID)
  assert.deepEqual(retriedJournal.map(record => record.t), ['start', 'done', 'resolved'],
    'the retried rerun must journal one end and one resolution after the existing start')
  assert.equal(retriedJournal[1]?.result?.isError, false)
  assert.equal(retriedJournal[2]?.action, 'rerun')

  // A third open is clean and duplicates neither record, proving the cancelled
  // and retried writers were both released.
  const third = await fetch(`${baseURL}/api/pdsh-recovery/reconcile`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ sessionId: RERUN_SESSION_ID }),
  })
  assert.equal(third.status, 200, await third.text())
  assert.equal(records(sessionLogPath(RERUN_SESSION_ID))
    .filter(record => record.type === 'tool/result').length, 1,
  'the third recovery open must not duplicate the rerun result')
  assert.deepEqual(records(journalPath(RERUN_SESSION_ID))
    .filter(record => record.call_id === RERUN_CALL_ID).map(record => record.t),
  ['start', 'done', 'resolved'], 'the third open must not duplicate the end or resolution')
  assert.equal(modelCalls, 0, 'recovery must not make a model call')
})
