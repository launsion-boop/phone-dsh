// SPDX-License-Identifier: MIT
/**
 * CHANGE(3) diagnosis: does the pinned DSH session append a terminal
 * `turn/end` when `session/cancel` aborts a turn whose model stream is still
 * pending?
 *
 * `abort-journal.test.ts` bundles this file against the pinned checkout's
 * webworker-runtime sources and runs it as a child process with the packed
 * phone image. The child installs the same platform globals and profile
 * overlay the Worker entry installs, boots the real `createWorkerHost`, and
 * drives the real DSH webserver through exactly the pair the Worker entry
 * synthesizes for a `0x40 API_REQ` frame
 * (`transport/synthetic-http.createSyntheticExchange`).
 *
 * The model upstream is a local `POST /v1/http` host-route responder that
 * writes the Messages SSE head and one thinking delta, then holds the response
 * open forever. Once the journal has an open turn **and** that response is
 * open, the child sends the real `session/cancel` remote method and reports
 * what the session journal contains afterwards. Nothing here writes DSH
 * session records: the assertion is on the pinned runtime's own output.
 *
 * This file is not a test: it is the process the test boots. It prints one
 * `__PDSH_ABORT_JOURNAL__ {json}` line and exits.
 * @module @phone-dsh/dsh-worker-entry/fixtures/abort-journal-harness
 */

import { readFileSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'

import { createWorkerHost } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/worker-host.ts'
import '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/buffer.ts'
import { alsCausality } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/async_hooks.ts'
import { createNodeBuiltins, REPLACED_PREFIXES } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtins.ts'
import { whenRequestListener } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/http.ts'
import { installCryptoGlobals } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/globals/crypto.ts'
import { installAsyncContextHooks } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/polyfill/async-context/async-context-hooks.ts'
import {
  createSyntheticExchange,
  type RuntimeRequestListener,
  type RuntimeResponseSink,
  type RuntimeSyntheticExchange,
} from '@deepseek-ai/dsh-experimental-webworker-runtime/src/transport/synthetic-http.ts'

import { createPhoneProfileOverlay } from '../profile-overlay.ts'

/** One JSONL record as the pinned runtime appends it. */
interface JournalRecord {
  type?: string
  data?: Record<string, unknown>
}

/** Facts the test asserts on. */
interface Diagnosis {
  booted: boolean
  error?: string
  sessionId?: string
  journalPath?: string
  /** A `turn/start` is journaled and no `turn/end` is present yet. */
  journalOpenBeforeCancel?: boolean
  /** The host `/v1/http` model response was open (headers + bytes written) at cancel. */
  modelStreamOpenBeforeCancel?: boolean
  /** The synthetic `session/cancel` remote response status. */
  cancelStatus?: number
  /** The journal after cancel ends on `turn/end`. */
  sawTerminalTurn?: boolean
  /** `type` of the last journal record. */
  lastRecordType?: string
  /** `data.reason.kind` of the last `turn/end`. */
  lastTurnEndReason?: string
  /** `data.reason.reason.kind` of the last `turn/end` (the cancel cause). */
  lastTurnEndCause?: string
  /** Tail of the journal for the failure message (newest records only). */
  journalTail?: string
}

const imagePath = process.argv[2] ?? ''
const result: Diagnosis = { booted: false }
let modelRequestSeen = false
let modelStreamOpen = false
let modelResponse: ServerResponse | undefined
let host: ReturnType<typeof createWorkerHost> | undefined

/** Report the diagnosis, stop the runtime and exit without waiting on its timers. */
function finish(): void {
  console.log(`__PDSH_ABORT_JOURNAL__ ${JSON.stringify(result)}`)
  void (async () => {
    try { modelResponse?.destroy() } catch { /* the process exits below */ }
    try { modelServer.closeAllConnections() } catch { /* ignore */ }
    try { modelServer.close() } catch { /* ignore */ }
    try { await host?.stop() } catch { /* ignore */ }
    process.exit(0)
  })()
}

// A hung-but-open Messages SSE: valid `message_start` + thinking delta, then
// silence. The response never ends, so the DSH model client stays pending.
const imageDirectory = imagePath === '' ? '' : dirname(imagePath)
const modelServer = createServer((request: IncomingMessage, response: ServerResponse) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
  // The packed phone image now carries the full Web page as lazy page chunks;
  // the runtime only resolves those archive names against an image URL, so the
  // fixture serves the packed directory (image + sibling lazy/) in-process.
  const imageRelative = pathname === '/image.tar.gz'
    ? basename(imagePath)
    : pathname.startsWith('/lazy/') ? join('lazy', basename(pathname)) : undefined
  if (imageRelative !== undefined) {
    try {
      const bytes = readFileSync(join(imageDirectory, imageRelative))
      response.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': String(bytes.byteLength),
      })
      response.end(bytes)
    } catch {
      response.writeHead(404)
      response.end()
    }
    return
  }
  if (request.url !== '/v1/http') {
    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"type":"error","error":{"type":"not_found_error"}}')
    return
  }
  modelRequestSeen = true
  modelResponse = response
  request.resume()
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'close',
  })
  const emit = (event: string, payload: Record<string, unknown>): void => {
    response.write(`event: ${event}\n`)
    response.write(`data: ${JSON.stringify(payload)}\n\n`)
  }
  emit('message_start', {
    type: 'message_start',
    message: {
      id: 'msg_diagnosis_1', type: 'message', role: 'assistant', model: 'deepseek-flash',
      content: [], stop_reason: null, stop_sequence: null,
      usage: {
        input_tokens: 128, cache_creation_input_tokens: 0,
        cache_read_input_tokens: 2048, output_tokens: 0, service_tier: 'standard',
      },
    },
  })
  emit('content_block_start', {
    type: 'content_block_start', index: 0,
    content_block: { type: 'thinking', thinking: '', signature: '' },
  })
  emit('ping', { type: 'ping' })
  emit('content_block_delta', {
    type: 'content_block_delta', index: 0,
    delta: { type: 'thinking_delta', thinking: 'Diagnosis: hold the stream open' },
  })
  modelStreamOpen = true
})

const sleep = (milliseconds: number): Promise<void> =>
  new Promise<void>(resolve => setTimeout(resolve, milliseconds))

async function waitUntil(label: string, timeoutMs: number, predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`)
    await sleep(10)
  }
}

/** The mounted VFS face this diagnosis reads (the packed image's home). */
interface DiagnosisVfs {
  readdirSync(path: string): string[]
  readFileSync(path: string, options?: unknown): string | Uint8Array
}

function vfs(): DiagnosisVfs {
  return (host as unknown as { vfs: DiagnosisVfs }).vfs
}

/** Read `<session-directory>/session.v4.jsonl` from the mounted DSH home. */
function readJournal(directory: string): { path: string; text: string } | undefined {
  const path = `${directory}/session.v4.jsonl`
  try {
    const value = vfs().readFileSync(path)
    return { path, text: typeof value === 'string' ? value : new TextDecoder().decode(value) }
  } catch {
    return undefined
  }
}

/** Every session journal currently in the mounted `/dsh/home/sessions`. */
function journalPaths(): Array<{ directory: string; path: string; text: string }> {
  const journals: Array<{ directory: string; path: string; text: string }> = []
  let workspaces: string[] = []
  try { workspaces = vfs().readdirSync('/dsh/home/sessions') } catch { return journals }
  for (const workspace of workspaces) {
    let children: string[] = []
    try { children = vfs().readdirSync(`/dsh/home/sessions/${workspace}`) } catch { continue }
    for (const child of children) {
      const directory = `/dsh/home/sessions/${workspace}/${child}`
      const journal = readJournal(directory)
      if (journal !== undefined) journals.push({ directory, ...journal })
    }
  }
  return journals
}

function records(text: string): JournalRecord[] {
  const parsed: JournalRecord[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const record = JSON.parse(line) as JournalRecord
      if (typeof record.type === 'string') parsed.push(record)
    } catch {
      // A torn tail line cannot hide the durable boundary before it.
    }
  }
  return parsed
}

function lastTurnEnd(text: string): { reason?: string; cause?: string } {
  const parsed = records(text)
  for (let index = parsed.length - 1; index >= 0; index--) {
    const record = parsed[index]
    if (record?.type !== 'turn/end') continue
    const reason = record.data?.['reason'] as Record<string, unknown> | undefined
    const cause = reason?.['reason'] as Record<string, unknown> | undefined
    return {
      ...(typeof reason?.['kind'] === 'string' ? { reason: reason['kind'] } : {}),
      ...(typeof cause?.['kind'] === 'string' ? { cause: cause['kind'] } : {}),
    }
  }
  return {}
}

/** Open one real DSH remote call through the captured webserver listener. */
async function remoteCall(method: string, request: Record<string, unknown>): Promise<{ status: number; body: string }> {
  const listener: RuntimeRequestListener = await whenRequestListener()
  const body = new TextEncoder().encode(JSON.stringify({
    type: 'client-request',
    rpcId: `diagnosis-${Math.random().toString(16).slice(2)}`,
    method,
    payload: { args: { request } },
  }))
  let resolved: { status: number; body: string } | undefined
  const chunks: string[] = []
  const sink: RuntimeResponseSink = {
    head() { /* head is not interesting; the body carries the envelope */ },
    chunk(bytes: Uint8Array) { chunks.push(new TextDecoder().decode(bytes)) },
    end(payload) {
      const tail = payload?.body === undefined ? '' : new TextDecoder().decode(payload.body)
      resolved = { status: payload?.status ?? 200, body: chunks.join('') + tail }
    },
    fail(message) { resolved = { status: 0, body: message } },
  }
  const exchange: RuntimeSyntheticExchange = createSyntheticExchange({
    t: 'req',
    id: 1,
    method: 'POST',
    url: `/api/${method}`,
    headers: {
      'content-type': 'application/json',
      // D22: only the Worker entry sets this, after the host verified the
      // ordered-channel bearer. This child is that entry for the diagnosis.
      'x-pdsh-channel-authenticated': '1',
      host: '127.0.0.1',
    },
    body,
  }, sink)
  listener(exchange.req, exchange.res)
  await waitUntil(`${method} response`, 15_000, () => resolved !== undefined)
  return resolved as { status: number; body: string }
}

;(globalThis as Record<string, unknown>).postMessage = () => {}
// The surface-phone /api guard accepts the channel marker only when the Worker
// environment names the ordered channel, and the llm-bridge reads the same
// names for its host route. This diagnosis uses them without a WebSocket.
;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = {
  hostHello: {
    proto: 1, role: 'host', boot_id: '0'.repeat(32), session_epoch: 0n,
    fence: { owner: 'diagnosis', generation: 0n, wal_seq: 0n }, caps: ['channel/1'],
    next_mseq: 1n, acked_mseq: 0n, durable_mseq: 0n,
  },
  onHostHello: () => () => {},
  nextMseq: () => 1n,
  ackedMseq: () => 0n,
  waitAck: async () => {},
  barrier: async () => {},
  journalAcked: () => 0n,
  waitJournalAck: async () => {},
  send: () => 1n,
  onFrame: () => () => {},
  request: async () => { throw new Error('the diagnosis serves no API requests') },
  connect: async () => {},
  close: async () => {},
}

try {
  if (imagePath === '') throw new Error('usage: abort-journal-harness <image.tar.gz>')
  await new Promise<void>(resolve => modelServer.listen(0, '127.0.0.1', resolve))
  const modelBase = `http://127.0.0.1:${(modelServer.address() as AddressInfo).port}`
  const imageUrl = `${modelBase}/image.tar.gz`

  installAsyncContextHooks()
  installCryptoGlobals()

  const profileOverlay = await createPhoneProfileOverlay()
  host = createWorkerHost({
    staticModules: createNodeBuiltins(),
    staticModulePrefixes: REPLACED_PREFIXES,
    requestListener: whenRequestListener,
    alsCausality,
    image: imageUrl,
    overlays: [profileOverlay],
    env: {
      PDSH_DSH_LAUNCH_TOKEN: 'diagnosis-launch-token',
      PDSH_DSH_PORT: '0',
      PDSH_SANDBOX_MODE: 'workspace-write',
      PDSH_SHELL: 'runtime',
      DSH_HOME: '/dsh/home',
      DSH_TELEMETRY_DISABLED: '1',
      DEEPSEEK_BASE_URL: 'https://model.example',
      DEEPSEEK_API_KEY: 'diagnosis-key',
      PDSH_MODEL_NAME: 'deepseek-flash',
      PDSH_CHANNEL_URL: 'ws://127.0.0.1:1/channel',
      PDSH_CHANNEL_TOKEN: 'diagnosis-channel-token',
      PDSH_CHANNEL_ORIGIN: modelBase,
    },
  } as never)
  await host.start()
  result.booted = true

  const created = await remoteCall('session/create', { cwd: '/dsh/workspace' })
  const createEnvelope = JSON.parse(created.body) as {
    result?: { value?: { sessionId?: string } }
  }
  const sessionId = createEnvelope.result?.value?.sessionId ?? ''
  if (sessionId === '') throw new Error(`session/create returned no session id: ${created.body}`)
  result.sessionId = sessionId

  const prompted = await remoteCall('session/prompt', {
    requestId: 'diagnosis-1',
    sessionId,
    mode: 'queue',
    content: [{ type: 'text', text: 'Hold the model stream open.' }],
  })
  if (prompted.status !== 200) throw new Error(`session/prompt failed: ${prompted.body}`)

  // The exact precondition the defect class needs: an open DSH turn while the
  // model response stream is still pending. Wait for both facts, never one.
  let openJournal: { directory: string; path: string; text: string } | undefined
  await waitUntil('an open session turn with a pending model stream', 20_000, () => {
    if (!modelRequestSeen || !modelStreamOpen) return false
    for (const journal of journalPaths()) {
      if (journal.text.includes('"turn/start"') && !journal.text.includes('"turn/end"')) {
        openJournal = journal
        return true
      }
    }
    return false
  })
  if (openJournal === undefined) throw new Error('no open journal was found')
  result.journalPath = openJournal.path
  result.journalOpenBeforeCancel = true
  result.modelStreamOpenBeforeCancel = true

  const cancelled = await remoteCall('session/cancel', { sessionId })
  result.cancelStatus = cancelled.status

  let after: { directory: string; path: string; text: string } | undefined
  await waitUntil('a journaled turn/end after session/cancel', 15_000, () => {
    const journal = readJournal(openJournal!.directory)
    if (journal === undefined || !journal.text.includes('"turn/end"')) return false
    after = { directory: openJournal!.directory, ...journal }
    return true
  })
  if (after === undefined) throw new Error('the session journal never received turn/end')
  const parsed = records(after.text)
  result.sawTerminalTurn = true
  result.lastRecordType = parsed[parsed.length - 1]?.type
  const ending = lastTurnEnd(after.text)
  result.lastTurnEndReason = ending.reason
  result.lastTurnEndCause = ending.cause
  result.journalTail = parsed.slice(-8)
    .map(record => JSON.stringify(record))
    .join('\n')
} catch (error) {
  result.error = (error as Error)?.stack ?? String(error)
} finally {
  finish()
}
