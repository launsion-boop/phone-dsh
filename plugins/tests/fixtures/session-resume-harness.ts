// SPDX-License-Identifier: MIT
/**
 * Two-boot session-resume harness for `tests/session-resume.test.ts`.
 *
 * The App's P0 defect was not in the Worker: the App opened a new Worker session
 * whenever the first turn of a conversation did not start, so the model lost
 * every earlier message while the transcript kept them. Two facts have to be
 * proven against the real runtime, not against a fake:
 *
 *   `first`   a `session/prompt` whose `requestId` repeats one already recorded
 *             on the Session's durable `user/message` is answered
 *             `{accepted:true}` and never starts a turn (DSH
 *             `hasPromptRequest`). This is the silent swallow the App used to
 *             misread as "the stored session is stale".
 *
 *             It also drains `/dsh/home/sessions` to a directory, which the test
 *             packs as the next boot's overlay — the same `/dsh/home/**` the
 *             Android host repacks from its materialized tree (`wal.md` §8).
 *
 *   `second`  a **new process** mounts that overlay and sends a recall question
 *             to the same Worker session id. The scripted model answers from the
 *             request transcript it receives: `CONTEXT-OK 323` when the earlier
 *             prompt is in the model request, `UNKNOWN` when it is not.
 *
 * The model is a script; every byte of the transcript, the persistence and the
 * resume path is the real Worker. Not a model provider.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/session-resume-harness
 */
import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { ServerResponse } from 'node:http'
import { basename, dirname, join } from 'node:path'

import { createSyntheticExchange } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/transport/synthetic-http.ts'

import { createPhoneWorkerHost, whenRequestListener } from '../../worker-entry/src/runtime-binding.ts'
import { createPhoneProfileOverlay } from '../../worker-entry/src/profile-overlay.ts'

/** The first prompt of the conversation: the fact the recall question asks for. */
const FIRST_PROMPT = 'Reply with PR14CHATOK and the result of 17 times 19'
/** The product's own recall question (`run-product-flow.sh` / L85 acceptance). */
const RECALL_PROMPT = 'Without tools or guessing, what exact multiplication did I request at the start of this chat? Reply UNKNOWN if absent from your context.'
/** What the scripted model answers when the transcript still carries the first prompt. */
const CONTEXT_ANSWER = 'CONTEXT-OK 323'
/** What it answers when the request carries no earlier user message. */
const NO_CONTEXT_ANSWER = 'UNKNOWN'

/** One recorded model request (the wire body the adapter sent). */
interface ModelRequest {
  readonly url: string
  readonly body: string
}

/** Facts this harness reports to the test. */
interface ResumeProbe {
  phase?: string
  sessionId?: string
  /** `first`: the duplicate prompt's receipt said accepted. */
  duplicateAccepted?: boolean
  /** `first`: the duplicate prompt started a turn (must be false). */
  duplicateStartedTurn?: boolean
  /** `first`: model requests the duplicate prompt caused (must be 0). */
  duplicateModelRequests?: number
  /** `first`: turns the session log holds after both prompts (must be 1). */
  turnsAfterDuplicate?: number
  /** `second`: the scripted model's text for the recall question. */
  recallAnswer?: string
  /** `second`: a model request carried the first prompt's text. */
  requestCarriedEarlierPrompt?: boolean
  /** `second`: the recall request's own user text reached the model. */
  requestCarriedRecallPrompt?: boolean
  /** `second`: model request count during this boot. */
  modelRequests?: number
  /** `second`: the session log's slice written by this boot. */
  newLogBytes?: number
  /** `second`: the slice of the session log this boot appended (evidence). */
  newLogTail?: string
}

/** The host process exit, captured before the runtime shims `process.exit`. */
const nativeExit = process.exit.bind(process)
const rawSetTimeout = globalThis.setTimeout.bind(globalThis)
const rawLog = console.log.bind(console)
const rawError = console.error.bind(console)
const lines: { level: string; text: string }[] = []
const capture = (level: string) => (...args: unknown[]): void => {
  const text = args
    .map(value => typeof value === 'string' ? value : value instanceof Error ? value.stack ?? value.message : String(value))
    .join(' ')
  lines.push({ level, text })
  rawError(`[${level}] ${text}`)
}
console.log = capture('log') as typeof console.log
console.warn = capture('warn') as typeof console.warn
console.error = capture('error') as typeof console.error
process.on('uncaughtException', (error) => { lines.push({ level: 'uncaught', text: error.stack ?? String(error) }) })
process.on('unhandledRejection', (reason) => { lines.push({ level: 'unhandled', text: String(reason) }) })

// The runtime keeps long-lived timers (exec-bridge reconnect) after the tree is
// active; fail by exiting, never by hanging.
rawSetTimeout(() => {
  rawError('resume harness watchdog expired')
  rawLog(`__PDSH_RESUME_RESULT__ ${JSON.stringify({ ok: false, thrown: 'watchdog expired', lines })}`)
  nativeExit(7)
}, 90_000)

/** Emit one Messages SSE event. */
function sse(response: ServerResponse, event: string, data: Record<string, unknown>): void {
  response.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`)
}

/** All text a wire transcript carries, as one string (the model's context). */
function transcriptText(value: unknown): string {
  return JSON.stringify(value)
}

/** The last `user` text of a Messages transcript. */
function lastUserText(messages: unknown): string {
  if (!Array.isArray(messages)) return ''
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index] as { role?: string; content?: unknown }
    if (message?.role !== 'user') continue
    if (typeof message.content === 'string') return message.content
    if (Array.isArray(message.content)) {
      return message.content
        .map((block: { type?: string; text?: string }) => block?.type === 'text' ? block.text ?? '' : '')
        .join('')
    }
  }
  return ''
}

const modelRequests: ModelRequest[] = []

/** The scripted Messages-compatible endpoint; records every wire body it served. */
const modelServer = createServer((request, response) => {
  void (async () => {
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(Buffer.from(chunk))
    const body = Buffer.concat(chunks).toString('utf8')
    const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
    if (request.method !== 'POST' || !pathname.endsWith('/v1/messages')) {
      rawError(`[model] not a Messages request: ${request.method ?? '?'} ${pathname}`)
      response.writeHead(404, { 'content-type': 'application/json' })
      response.end('{"type":"error","error":{"type":"not_found_error","message":"no route"}}')
      return
    }
    // `request.url` is `string | undefined` in Node's typings; the harness only
    // records what the server actually received, and an absent url is the empty
    // string here rather than an invented one.
    modelRequests.push({ url: request.url ?? '', body })
    let parsed: { messages?: unknown; model?: string } = {}
    try { parsed = JSON.parse(body) as { messages?: unknown; model?: string } } catch { parsed = {} }
    const recall = lastUserText(parsed.messages).includes('Without tools or guessing')
    const text = recall
      ? transcriptText(parsed.messages).includes('PR14CHATOK') ? CONTEXT_ANSWER : NO_CONTEXT_ANSWER
      : 'PR14CHATOK 323'
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
    sse(response, 'message_start', {
      message: {
        id: `msg_resume_${String(modelRequests.length)}`,
        type: 'message',
        role: 'assistant',
        model: parsed.model,
        content: [],
        usage: { input_tokens: 64, output_tokens: 0 },
      },
    })
    sse(response, 'content_block_start', { index: 0, content_block: { type: 'text', text: '' } })
    sse(response, 'content_block_delta', { index: 0, delta: { type: 'text_delta', text } })
    sse(response, 'content_block_stop', { index: 0 })
    sse(response, 'message_delta', { delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 16 } })
    sse(response, 'message_stop', {})
    response.end()
  })().catch((error: unknown) => {
    if (!response.headersSent) response.writeHead(500, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ type: 'error', error: { type: 'server_error', message: String(error) } }))
  })
})
await new Promise<void>((resolveListen, reject) => {
  modelServer.once('error', reject)
  modelServer.listen(0, '127.0.0.1', resolveListen)
})
const modelAddress = modelServer.address()
if (modelAddress === null || typeof modelAddress === 'string') throw new Error('resume harness: no model port')
const modelUrl = `http://127.0.0.1:${String(modelAddress.port)}/mock`

// The image's llm-bridge replaces globalThis.fetch with the host `/v1/http`
// carrier; the gateway below must dial the scripted model directly.
const nativeFetch = globalThis.fetch.bind(globalThis)

// The runtime replaces `globalThis.process` (and its `env`) with the Worker
// environment at boot, so every host-side knob is read here, before that.
const hostEnv: NodeJS.ProcessEnv = { ...process.env }
const phase = hostEnv.PDSH_RESUME_PHASE ?? 'first'
const imagePath = process.argv[2] ?? ''
if (imagePath === '') throw new Error('usage: session-resume-harness <image.tar.gz>')
const imageDirectory = dirname(imagePath)

// Serve the packed directory so lazy closures resolve against a URL, as the
// loopback host serves the App's image.
const imageServer = createServer((request, response) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
  // The Worker carries every outbound model request through the host
  // `POST /v1/http` route (llm-bridge `installNodeFetch`); stand in for the
  // Android gateway: restore the upstream Authorization the Worker moved aside
  // and forward to the target the header names.
  if (pathname === '/v1/http') {
    void (async () => {
      const target = request.headers['x-pdsh-target-url']
      if (typeof target !== 'string') {
        response.writeHead(400)
        response.end()
        return
      }
      const headers = new Headers()
      for (const [name, value] of Object.entries(request.headers)) {
        if (name === 'x-pdsh-target-url' || name === 'x-pdsh-upstream-authorization' || value === undefined) continue
        for (const member of Array.isArray(value) ? value : [value]) headers.append(name, member)
      }
      const authorization = request.headers['x-pdsh-upstream-authorization']
      if (typeof authorization === 'string') headers.set('authorization', authorization)
      const chunks: Buffer[] = []
      for await (const chunk of request) chunks.push(chunk as Buffer)
      try {
        const upstream = await nativeFetch(target, {
          method: request.method,
          headers,
          body: chunks.length === 0 ? undefined : Buffer.concat(chunks),
        })
        const responseHeaders: Record<string, string> = {}
        upstream.headers.forEach((value, name) => { responseHeaders[name] = value })
        delete responseHeaders['content-length']
        response.writeHead(upstream.status, responseHeaders)
        if (upstream.body === null) {
          response.end()
          return
        }
        const reader = upstream.body.getReader()
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          response.write(Buffer.from(value))
        }
        response.end()
      } catch {
        if (!response.headersSent) response.writeHead(502)
        response.end()
      }
    })()
    return
  }
  const relative = pathname === '/image.tar.gz'
    ? basename(imagePath)
    : pathname.startsWith('/lazy/') ? join('lazy', basename(pathname)) : undefined
  if (relative === undefined) {
    response.writeHead(404)
    response.end()
    return
  }
  try {
    const bytes = readFileSync(join(imageDirectory, relative))
    response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': String(bytes.byteLength) })
    response.end(bytes)
  } catch {
    response.writeHead(404)
    response.end()
  }
})
await new Promise<void>((resolveListen, reject) => {
  imageServer.once('error', reject)
  imageServer.listen(0, '127.0.0.1', resolveListen)
})
const imageAddress = imageServer.address()
if (imageAddress === null || typeof imageAddress === 'string') throw new Error('resume harness: no image port')
const imageOrigin = `http://127.0.0.1:${String(imageAddress.port)}`
const imageUrl = `${imageOrigin}/image.tar.gz`

// The ordered-channel stub the Worker entry installs before DSH boots.
const hostHello = {
  proto: 1,
  role: 'host',
  boot_id: '0'.repeat(32),
  session_epoch: 0n,
  fence: { owner: 'test', generation: 0n, wal_seq: 0n },
  caps: ['channel/1'],
  next_mseq: 1n,
  acked_mseq: 0n,
  durable_mseq: 0n,
}
;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = {
  hostHello,
  onHostHello: () => () => {},
  nextMseq: () => 1n,
  ackedMseq: () => 0n,
  waitAck: async () => {},
  barrier: async () => {},
  journalAcked: () => 0n,
  waitJournalAck: async () => {},
  send: () => 1n,
  onFrame: () => () => {},
  request: async () => { throw new Error('resume harness does not serve API requests over the channel') },
  connect: async () => {},
  close: async () => {},
}
;(globalThis as Record<string, unknown>).postMessage = () => {}

const profileOverlay = await createPhoneProfileOverlay()
const overlays: (string | Uint8Array)[] = [profileOverlay]
const overlayPath = hostEnv.PDSH_RESUME_OVERLAY
if (overlayPath !== undefined && overlayPath !== '') overlays.push(readFileSync(overlayPath))

const host = createPhoneWorkerHost({
  image: imageUrl,
  overlays,
  env: {
    PDSH_DSH_LAUNCH_TOKEN: 'test-launch-token',
    PDSH_DSH_PORT: '0',
    PDSH_SANDBOX_MODE: 'workspace-write',
    PDSH_SHELL: 'runtime',
    DSH_HOME: '/dsh/home',
    PDSH_CHANNEL_URL: 'ws://127.0.0.1:1/channel',
    PDSH_CHANNEL_TOKEN: 'test-channel-token',
    PDSH_CHANNEL_ORIGIN: imageOrigin,
    DEEPSEEK_BASE_URL: modelUrl,
    DEEPSEEK_API_KEY: 'dummy-not-a-secret',
    DSH_TELEMETRY_DISABLED: '1',
  },
})

interface HostVfs {
  readdirSync?: (path: string) => unknown[]
  readFileSync?: (path: string, options?: unknown) => unknown
}
let vfs: HostVfs | undefined

/** The bytes of one VFS file, or `undefined`. */
function readVfs(path: string): Uint8Array | undefined {
  try {
    const value = vfs?.readFileSync?.(path)
    if (value === undefined) return undefined
    if (typeof value === 'string') return new TextEncoder().encode(value)
    if (value instanceof Uint8Array) return value
    return undefined
  } catch {
    return undefined
  }
}

/** The names in one VFS directory, or `[]`. */
function listVfs(path: string): string[] {
  try {
    const entries = vfs?.readdirSync?.(path) ?? []
    return entries.map(entry => typeof entry === 'string' ? entry : String((entry as { name?: unknown }).name ?? ''))
      .filter(name => name !== '')
  } catch {
    return []
  }
}

/** The session JSONL text, found by session id under the persisted root. */
function sessionLogText(sessionId: string): string {
  const root = '/dsh/home/sessions'
  for (const bucket of listVfs(root)) {
    for (const directory of listVfs(`${root}/${bucket}`)) {
      if (!directory.includes(sessionId)) continue
      for (const name of listVfs(`${root}/${bucket}/${directory}`)) {
        if (!name.endsWith('.jsonl')) continue
        const bytes = readVfs(`${root}/${bucket}/${directory}/${name}`)
        if (bytes !== undefined) return new TextDecoder().decode(bytes)
      }
    }
  }
  return ''
}

/** Count of one durable event type in a session log. */
function countOf(log: string, type: string): number {
  return log.split(`"type":"${type}"`).length - 1
}

/** Every settled assistant message line of a session log, in order. */
function assistantLines(log: string): string[] {
  return log.split('\n').filter(line => line.includes('"type":"assistant/message"'))
}

const probe: ResumeProbe = { phase }
let ok = false
let thrown: string | undefined
try {
  await host.start()
  vfs = (host as unknown as { vfs?: HostVfs }).vfs
  if (vfs === undefined) throw new Error('resume harness: the host exposes no vfs')

  const listen = await whenRequestListener()
  let nextRequestID = 1
  const callEnvelope = async (method: string, args: unknown): Promise<{
    ok: boolean
    value: Record<string, unknown>
    error: unknown
  }> => {
    const rpcId = randomUUID()
    const encoded = new TextEncoder().encode(JSON.stringify({
      type: 'client-request', rpcId, method, payload: { args },
    }))
    const body = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength)
    return await new Promise((resolveCall, rejectCall) => {
      const chunks: Uint8Array[] = []
      const sink = {
        head: () => {},
        chunk: (bytes: Uint8Array) => { chunks.push(bytes) },
        end: (payload?: { status?: number; headers?: Record<string, string>; body?: Uint8Array }) => {
          try {
            const bytes = payload?.body
              ?? (chunks.length === 0
                ? new Uint8Array(0)
                : new Uint8Array(chunks.reduce((total, chunk) => total + chunk.byteLength, 0)))
            if (payload?.body === undefined && chunks.length > 0) {
              let offset = 0
              for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength }
            }
            const envelope = JSON.parse(new TextDecoder().decode(bytes)) as {
              type?: string
              rpcId?: string
              result?: { ok?: boolean; value?: Record<string, unknown>; error?: unknown }
            }
            if (envelope.type !== 'server-response' || envelope.rpcId !== rpcId) {
              throw new Error(`unexpected API envelope for ${method}: ${JSON.stringify(envelope).slice(0, 400)}`)
            }
            resolveCall({
              ok: envelope.result?.ok === true,
              value: envelope.result?.value ?? {},
              error: envelope.result?.error,
            })
          } catch (error) {
            rejectCall(error)
          }
        },
        fail: (message: string) => rejectCall(new Error(`API ${method} transport failed: ${message}`)),
      }
      const exchange = createSyntheticExchange({
        t: 'req',
        id: nextRequestID++,
        url: `/api/${method}`,
        method: 'POST',
        headers: {
          host: '127.0.0.1:3080',
          'content-type': 'application/json',
          'x-pdsh-channel-authenticated': '1',
        },
        body,
      }, sink)
      listen(exchange.req, exchange.res)
    })
  }
  const call = async (method: string, args: unknown): Promise<Record<string, unknown>> => {
    const envelope = await callEnvelope(method, args)
    if (!envelope.ok) throw new Error(`API ${method} failed: ${JSON.stringify(envelope.error)}`)
    return envelope.value
  }
  const prompt = async (sessionId: string, text: string, requestId: string): Promise<void> => {
    await call('session/prompt', {
      request: {
        requestId,
        sessionId,
        mode: 'queue',
        content: [{ type: 'text', text }],
      },
    })
  }
  const waitFor = async (what: string, read: () => boolean, timeoutMs: number): Promise<boolean> => {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (read()) return true
      await new Promise<void>(resolveWait => { rawSetTimeout(resolveWait, 250) })
    }
    rawError(`resume harness: timed out waiting for ${what}`)
    return false
  }

  if (phase === 'first') {
    const initialized = await call('workspace/initializeDefault', {})
    const workspace = initialized.workspace as Record<string, unknown> | undefined
    const workspaceId = workspace?.workspaceId
    if (typeof workspaceId !== 'string') throw new Error('workspace/initializeDefault returned no workspaceId')
    const created = await call('session/create', { request: { workspaceId } })
    const sessionId = created.sessionId
    if (typeof sessionId !== 'string') throw new Error('session/create returned no sessionId')
    probe.sessionId = sessionId

    // One real turn. The first submission identity is fixed so the duplicate
    // below can reuse it; the App's fix is that it never reuses one.
    const firstRequestId = 'pdsh-prompt-1'
    await prompt(sessionId, FIRST_PROMPT, firstRequestId)
    const started = await waitFor('the first turn to settle', () => {
      const log = sessionLogText(sessionId)
      return log.includes('"type":"turn/start"') && log.includes('"type":"turn/end"')
    }, 45_000)
    if (!started) throw new Error('the first turn never settled')
    const afterFirst = sessionLogText(sessionId)
    if (!assistantLines(afterFirst).some(line => line.includes('PR14CHATOK 323'))) {
      throw new Error('the first answer never made it into the session log as an assistant message')
    }

    // Everything the Worker would have done by now (including the title request)
    // has had time to land before the duplicate is measured.
    await new Promise<void>(resolveWait => { rawSetTimeout(resolveWait, 1_500) })
    const turnsBefore = countOf(sessionLogText(sessionId), 'turn/start')
    const requestsBefore = modelRequests.length
    const duplicate = await callEnvelope('session/prompt', {
      request: {
        requestId: firstRequestId,
        sessionId,
        mode: 'queue',
        content: [{ type: 'text', text: 'a second submission reusing the same requestId' }],
      },
    })
    probe.duplicateAccepted = duplicate.ok
    await new Promise<void>(resolveWait => { rawSetTimeout(resolveWait, 3_000) })
    const afterDuplicate = sessionLogText(sessionId)
    probe.turnsAfterDuplicate = countOf(afterDuplicate, 'turn/start')
    probe.duplicateStartedTurn = probe.turnsAfterDuplicate > turnsBefore
    probe.duplicateModelRequests = modelRequests.length - requestsBefore

    // Drain the persisted home the next boot mounts (the Android host repacks
    // `materialized/home` into every boot overlay).
    const out = hostEnv.PDSH_RESUME_HOME_OUT
    if (out === undefined || out === '') throw new Error('PDSH_RESUME_HOME_OUT is required for phase first')
    const drain = (virtual: string, real: string): void => {
      mkdirSync(real, { recursive: true })
      for (const name of listVfs(virtual)) {
        const source = `${virtual}/${name}`
        const target = join(real, name)
        const bytes = readVfs(source)
        if (bytes !== undefined) writeFileSync(target, bytes)
        else drain(source, target)
      }
    }
    drain('/dsh/home/sessions', join(out, 'home', 'sessions'))
    // The session header records the workspace directory
    // (`workspace/initializeDefault`), and a resumed turn refuses to start when
    // that directory is gone ("working-directory: directory does not exist"), so
    // the overlay carries the workspace tree the host also repacks.
    drain('/dsh/workspace', join(out, 'workspace'))
  } else if (phase === 'second') {
    const sessionId = hostEnv.PDSH_RESUME_SESSION ?? ''
    if (sessionId === '') throw new Error('PDSH_RESUME_SESSION is required for phase second')
    probe.sessionId = sessionId
    const logBeforeText = sessionLogText(sessionId)
    const logBefore = logBeforeText.length
    if (logBefore === 0) throw new Error(`the overlay carried no session log for ${sessionId}`)
    const turnsBefore = countOf(logBeforeText, 'turn/end')
    // A fresh identity, as the fixed App mints for every submission.
    await prompt(sessionId, RECALL_PROMPT, `pdsh-prompt-${randomUUID()}`)
    await waitFor('the recall turn to settle', () => countOf(sessionLogText(sessionId), 'turn/end') > turnsBefore, 45_000)
    const log = sessionLogText(sessionId)
    probe.newLogBytes = log.length - logBefore
    probe.newLogTail = log.slice(logBefore).slice(-2_000)
    const answer = assistantLines(log).at(-1) ?? ''
    probe.recallAnswer = answer.includes(CONTEXT_ANSWER)
      ? CONTEXT_ANSWER
      : answer.includes(NO_CONTEXT_ANSWER) ? NO_CONTEXT_ANSWER : undefined
    probe.modelRequests = modelRequests.length
    const recallRequest = modelRequests.find(entry => entry.body.includes('Without tools or guessing'))
    probe.requestCarriedEarlierPrompt = recallRequest?.body.includes(FIRST_PROMPT) === true
    probe.requestCarriedRecallPrompt = recallRequest !== undefined
    // The wire bodies are the evidence a reader can audit: write them beside the
    // result for the test's own assertions (token-free; the key is a dummy).
    const out = hostEnv.PDSH_RESUME_REQUESTS_OUT
    if (out !== undefined && out !== '') {
      writeFileSync(out, JSON.stringify(modelRequests.map(entry => ({
        url: entry.url,
        carriedEarlierPrompt: entry.body.includes(FIRST_PROMPT),
        carriedRecallPrompt: entry.body.includes('Without tools or guessing'),
      })), null, 2))
    }
  } else {
    throw new Error(`unknown PDSH_RESUME_PHASE=${phase}`)
  }
  ok = true
} catch (error) {
  thrown = (error as Error)?.stack ?? String(error)
  lines.push({ level: 'uncaught', text: thrown })
}
// Let the last log line and any activation audit run before reporting.
await new Promise<void>(resolveWait => { rawSetTimeout(resolveWait, 1_000) })
rawLog(`__PDSH_RESUME_RESULT__ ${JSON.stringify({ ok, thrown, probe, lines })}`)
try { await host.stop?.() } catch { /* the process exits below */ }
modelServer.closeAllConnections()
await new Promise<void>(resolve => { modelServer.close(() => resolve()) })
imageServer.closeAllConnections()
await new Promise<void>(resolve => { imageServer.close(() => resolve()) })
nativeExit(ok ? 0 : 1)
