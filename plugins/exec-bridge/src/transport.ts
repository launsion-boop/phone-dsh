// SPDX-License-Identifier: MIT
/**
 * Exec transport abstraction for the three deployments of the harness:
 *
 * - `channel`: EXEC_REQ / EXEC_EVT / EXEC_CTL over the phone-dsh-v1 ordered
 *   channel (`globalThis.__PDSH_CHANNEL__`), used by the Worker.
 * - `fetch`: the same-origin loopback `/v1/exec*` endpoints over the Worker's
 *   own `fetch`, bearer-authenticated, NDJSON streaming.
 * - `node-http`: the desktop exec-bridge v1 client (nodejs-mobile and the
 *   reference simulation), still the compatibility path.
 *
 * The transports share one event shape and one idempotency field set; a
 * provider (subprocess-xl) selects the executor, not the wire.
 * @module @phone-dsh/dsh-exec-bridge/transport
 */

import { AsyncQueue, acceleratorsFromCaps, waitForHostHello } from '@phone-dsh/dsh-channel'
import { canonicalStringify } from '@phone-dsh/dsh-channel/canonical-json'
import { decodeUtf8, encodeUtf8, readU64be } from '@phone-dsh/dsh-channel/bytes'
import type { ChannelClient } from '@phone-dsh/dsh-channel/client'
import { FrameType, type Frame } from '@phone-dsh/dsh-channel/frames'
import type { HelloHostPayload } from '@phone-dsh/dsh-channel/payloads'
import { encodeJournal } from '@phone-dsh/dsh-channel/vfs-mutation'
import { ExecBridgeClient, ExecBridgeError } from './client.ts'
import type { ExecClient, ExecEvent, ExecRequest, Hello, LifecycleState } from './client.ts'
import { currentToolCall } from './call-context.ts'
import { deriveIdemKey, idemKeyFromContext } from './idem.ts'
import type { IdemKeyFacts } from './idem.ts'

/** Deployment behind one {@link ExecTransport}. */
export type ExecTransportKind = 'channel' | 'fetch' | 'node-http'

/** One open event stream. Closing detaches; the execution keeps running. */
export interface EventStream extends AsyncIterable<ExecEvent> {
  close(): void
}

/** A transport failure with a stable machine-readable code. */
export class ExecTransportError extends Error {
  readonly code: string

  constructor(message: string, code: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ExecTransportError'
    this.code = code
  }
}

/** Wire face shared by the three transports. */
export interface ExecTransport {
  readonly kind: ExecTransportKind
  hello(signal?: AbortSignal): Promise<Hello>
  exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream>
  events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream>
  cancel(execId: string, body?: { signal?: string; grace_ms?: number }, signal?: AbortSignal): Promise<void>
  stdin(execId: string, body?: { data?: string; eof?: boolean }, signal?: AbortSignal): Promise<void>
  lifecycle?(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState>
  /** Highest VFS mseq this worker emitted; 0 outside the ordered channel. */
  lastMseq(): bigint
  destroy(): void
}

/** True for a loopback host name. */
export function isLoopbackHost(hostname: string): boolean {
  return hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1' || hostname === 'localhost'
}

export { acceleratorsFromCaps }

/** Read `capabilities.accelerators` from an exec-bridge hello body, if present. */
function acceleratorsOfHello(hello: Hello): string[] {
  const advertised = hello.capabilities.accelerators
  return Array.isArray(advertised) ? advertised.filter((name): name is string => typeof name === 'string') : []
}

/** Transports report the host accelerator facts in `hello`; this normalizes them. */
function withAccelerators(hello: Hello, accelerators: readonly string[]): Hello {
  return {
    ...hello,
    capabilities: {
      ...hello.capabilities,
      accelerators: [...accelerators],
    },
  }
}

/** One `EventStream` over an async queue with a detach callback. */
function queueStream(queue: AsyncQueue<ExecEvent>, detach: () => void): EventStream {
  let closed = false
  const iterator = async function* (): AsyncGenerator<ExecEvent> {
    for (;;) {
      const result = await queue.next()
      if (result.done) return
      if (closed) return
      yield result.value
    }
  }
  return {
    [Symbol.asyncIterator]: () => iterator(),
    close: () => {
      if (closed) return
      closed = true
      detach()
      queue.end()
    },
  }
}

/** Parse one JSON payload; a malformed frame is a protocol error. */
function parseJson(payload: Uint8Array, what: string): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(decodeUtf8(payload))
  } catch (error) {
    throw new ExecTransportError(`${what} is not valid JSON`, 'BAD_PAYLOAD', { cause: error })
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new ExecTransportError(`${what} is not a JSON object`, 'BAD_PAYLOAD')
  }
  return parsed as Record<string, unknown>
}

/** Build the EXEC_REQ representation shared by channel and fetch. */
export function execRequestJson(request: ExecRequest): Record<string, unknown> {
  const json: Record<string, unknown> = {
    exec_id: request.exec_id,
    argv: [...request.argv],
    cwd: request.cwd,
  }
  if (request.env !== undefined) json.env = request.env
  if (request.deadline !== undefined) json.deadline = request.deadline
  if (request.grace_ms !== undefined) json.grace_ms = request.grace_ms
  if (request.stdin !== undefined) json.stdin = request.stdin
  if (request.tier !== undefined) json.tier = request.tier
  if (request.confine !== undefined) json.confine = request.confine
  if (request.requires_mseq !== undefined) json.requires_mseq = request.requires_mseq
  if (request.idem_key !== undefined) json.idem_key = request.idem_key
  return json
}

/** JSON-safe copy: `bigint` becomes an exact safe integer (wire `u64`). */
export function jsonSafe(value: unknown): unknown {
  if (typeof value === 'bigint') {
    if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) throw new RangeError(`cannot encode ${String(value)} as a JSON integer`)
    return Number(value)
  }
  if (Array.isArray(value)) return value.map(jsonSafe)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, member]) => [key, jsonSafe(member)]))
  }
  return value
}

/**
 * Fill the two phone-dsh-v1 EXEC_REQ members the exec-bridge v1 request shape
 * does not carry (channel.md §4.2, D10/D12):
 *
 * - `requires_mseq` is the Worker's last emitted VFS mseq at dispatch time, so
 *   the host applies every Worker write before the accelerator reads.
 * - `idem_key` is the deterministic second key. The identity comes from the
 *   request's `XL_IDEMPOTENCY_KEY` (injected by subprocess-xl from the tool
 *   call) or, failing that, the ambient tool-call context.
 *
 * A caller that already knows a value keeps it (the golden vector and the
 * desktop simulation pass both explicitly). An accelerator dispatched outside
 * any tool call has no identity and fails locally instead of crossing 0x20
 * unattributed.
 * @param request - exec-bridge v1 request from a provider.
 * @param lastMseq - highest VFS mseq the Worker emitted before dispatch.
 * @returns a copy with both EXEC_REQ members set.
 */
export function withPhoneExecFields(request: ExecRequest, lastMseq: bigint): ExecRequest {
  const requiresMseq = request.requires_mseq ?? Number(lastMseq)
  if (!Number.isSafeInteger(requiresMseq) || requiresMseq < 0) {
    throw new ExecTransportError(`requires_mseq ${String(lastMseq)} is outside the JSON safe-integer range`, 'BAD_PAYLOAD')
  }
  let idemKey = request.idem_key
  if (idemKey === undefined) {
    idemKey = deriveRequestIdemKey(request)
    if (idemKey === undefined) {
      throw new ExecTransportError(
        'the host accelerator request needs a tool-call idem_key (XL_IDEMPOTENCY_KEY or session/turn/step)',
        'unsupported',
      )
    }
  }
  return { ...request, requires_mseq: requiresMseq, idem_key: idemKey }
}

/** Derive the D10 key from the request env or the ambient tool-call context; undefined outside both. */
function deriveRequestIdemKey(request: ExecRequest): string | undefined {
  const injected = request.env?.['XL_IDEMPOTENCY_KEY']
  try {
    if (typeof injected === 'string' && injected !== '') {
      const facts: IdemKeyFacts = { key: injected }
      return deriveIdemKey(request.argv, request.cwd, request.env, facts)
    }
    return idemKeyFromContext(request.argv, request.cwd, request.env, currentToolCall())
  } catch {
    return undefined
  }
}

/**
 * Exec over the phone-dsh-v1 ordered channel.
 *
 * Request payloads are canonical JSON EXEC_REQ (0x20); events arrive as
 * EXEC_EVT (0x21) keyed by `exec_id`; cancel/stdin are EXEC_CTL (0x22).
 * A repeated request replays the host's retained event stream, so `events()`
 * re-sends the stored request instead of a re-attach endpoint.
 */
export class ChannelExecTransport implements ExecTransport {
  readonly kind = 'channel' as const
  private readonly channel: ChannelClient
  /** Explicit config list; undefined means "the current host HELLO caps". */
  private readonly configuredAccelerators: readonly string[] | undefined
  private readonly helloTimeoutMs: number
  private resolvedAccelerators: readonly string[] | undefined
  private readonly queues = new Map<string, { queue: AsyncQueue<ExecEvent>; afterSeq: number }>()
  private readonly requests = new Map<string, Uint8Array>()
  private disposed = false
  private detach: (() => void) | undefined

  constructor(channel: ChannelClient, accelerators?: readonly string[], options: { helloTimeoutMs?: number } = {}) {
    this.channel = channel
    this.configuredAccelerators = accelerators
    this.helloTimeoutMs = options.helloTimeoutMs ?? 10_000
  }

  /**
   * D12: the accelerator set is the explicit config list, or exactly the
   * `accelerator:<name>` entries of the current host HELLO caps. There is no
   * built-in fallback: before the HELLO arrives this waits (bounded) instead of
   * guessing, and the hello it reports always reflects the latest caps.
   */
  private async ensureAccelerators(signal?: AbortSignal): Promise<readonly string[]> {
    if (this.configuredAccelerators !== undefined) return this.configuredAccelerators
    const hello = this.channel.hostHello ?? await waitForHostHello(this.channel, this.helloTimeoutMs, signal)
    const resolved = acceleratorsFromCaps(hello.caps)
    this.resolvedAccelerators = resolved
    return resolved
  }

  async hello(signal?: AbortSignal): Promise<Hello> {
    const accelerators = await this.ensureAccelerators(signal)
    return withAccelerators(this.helloFacts(), accelerators)
  }

  /**
   * The ordered channel HELLO carries `caps` (and therefore the real
   * `accelerator:<name>` list) only. It does not publish a host provider,
   * mounts or resource limits, so those members stay explicitly unknown
   * instead of being synthesized as xz-shell facts. `XlExecBridge` builds a
   * guest-only mapper for this shape; it never invents a host mount here.
   */
  private helloFacts(): Hello {
    return {
      protocol: 'pdsh-exec-bridge/1',
      facts_source: 'channel-caps',
      provider: { name: 'unknown' },
      guest: {
        platform: 'posix',
        default_shell: '/bin/sh',
        mounts: [],
      },
      capabilities: { exec: true, process_group: false, lifecycle: false, confine: [] },
      limits: {},
    }
  }

  /** Last resolved accelerator names (host HELLO caps or the explicit config). */
  get acceleratorNames(): readonly string[] {
    return this.configuredAccelerators ?? this.resolvedAccelerators ?? []
  }

  /** The host HELLO currently backing routing decisions. */
  get hostHello(): HelloHostPayload | undefined {
    return this.channel.hostHello
  }

  lastMseq(): bigint {
    const next = this.channel.nextMseq()
    return next > 0n ? next - 1n : 0n
  }

  async exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream> {
    this.assertUsable()
    const program = request.argv[0]
    const accelerators = await this.ensureAccelerators(signal)
    if (program === undefined || !accelerators.includes(program)) {
      throw new ExecTransportError(
        `${program ?? 'the program'} is not an advertised host accelerator; it stays in the Worker`,
        'unsupported',
      )
    }
    // D10/D12: the provider request carries only the exec-bridge v1 fields; the
    // wire needs requires_mseq and idem_key, injected here on every channel
    // dispatch so no caller can forget them.
    const prepared = withPhoneExecFields(request, this.lastMseq())
    const payload = encodeUtf8(canonicalStringify(execRequestJson(prepared)))
    this.requests.set(prepared.exec_id, payload)
    return this.open(prepared.exec_id, payload, 0, signal)
  }

  async events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream> {
    this.assertUsable()
    const payload = this.requests.get(execId)
    if (payload === undefined) throw new ExecTransportError(`no retained EXEC_REQ for ${execId}`, 'not_found')
    return this.open(execId, payload, afterSeq + 1, signal)
  }

  async cancel(execId: string, _body: { signal?: string; grace_ms?: number } = {}, _signal?: AbortSignal): Promise<void> {
    this.assertUsable()
    this.channel.send(FrameType.EXEC_CTL, encodeUtf8(canonicalStringify({ exec_id: execId, op: 'cancel' })))
  }

  async stdin(execId: string, body: { data?: string; eof?: boolean } = {}, _signal?: AbortSignal): Promise<void> {
    this.assertUsable()
    if (body.eof === true) {
      throw new ExecTransportError('the ordered channel has no stdin EOF control; pipe stdin stays worker-local', 'unsupported')
    }
    this.channel.send(FrameType.EXEC_CTL, encodeUtf8(canonicalStringify({ exec_id: execId, op: 'stdin', data: body.data ?? '' })))
  }

  destroy(): void {
    if (this.disposed) return
    this.disposed = true
    this.detach?.()
    this.detach = undefined
    const error = new ExecTransportError('channel transport disposed', 'disposed')
    for (const entry of this.queues.values()) entry.queue.fail(error)
    this.queues.clear()
  }

  /**
   * Append one JOURNAL record (0x30) for a session and resolve on the
   * level-1 ack (0x31). Exposed for the tool journal.
   * @param jseq - per-session consecutive sequence.
   * @param sessionId - D6 session identifier.
   * @param record - opaque record bytes.
   */
  async journal(jseq: bigint, sessionId: string, record: Uint8Array, signal?: AbortSignal): Promise<void> {
    this.assertUsable()
    signal?.throwIfAborted()
    // 0x30 goes out through the channel, which also buffers it across a
    // reconnect; the 0x31 high-water mark is the channel package's one tracker.
    this.channel.send(FrameType.JOURNAL, encodeJournal({ jseq, sessionId, record }))
    if (this.channel.journalAcked(sessionId, 1) >= jseq) return
    await this.channel.waitJournalAck(1, sessionId, jseq, signal)
  }

  /** Highest journal jseq the host acknowledged (level 1) for a session. */
  journalAck(sessionId: string): bigint {
    return this.channel.journalAcked(sessionId, 1)
  }

  private open(execId: string, payload: Uint8Array, afterSeq: number, signal?: AbortSignal): EventStream {
    this.ensureListener()
    const previous = this.queues.get(execId)
    previous?.queue.fail(new ExecTransportError(`EXEC_REQ for ${execId} was re-issued`, 'replaced'))
    const queue = new AsyncQueue<ExecEvent>()
    this.queues.set(execId, { queue, afterSeq })
    try {
      this.channel.send(FrameType.EXEC_REQ, payload)
    } catch (error) {
      this.queues.delete(execId)
      throw error
    }
    return queueStream(queue, () => { this.queues.delete(execId) })
  }

  private handle(frame: Frame): void {
    if (frame.type === FrameType.EXEC_EVT) {
      let event: ExecEvent
      try {
        event = parseJson(frame.payload, 'EXEC_EVT') as unknown as ExecEvent
      } catch {
        return
      }
      if (typeof event.exec_id !== 'string') return
      const entry = this.queues.get(event.exec_id)
      if (entry === undefined || event.seq < entry.afterSeq) return
      entry.queue.push(event)
      if (event.type === 'exit' || event.type === 'error') {
        entry.queue.end()
        this.queues.delete(event.exec_id)
      }
      return
    }
    if (frame.type === FrameType.ERROR) {
      let code = 'channel_error'
      let message = 'the ordered channel reported a fatal error'
      try {
        const payload = parseJson(frame.payload, 'ERROR')
        if (typeof payload.code === 'string') code = payload.code
        if (typeof payload.message === 'string') message = payload.message
      } catch {
        // Keep the generic facts.
      }
      const error = new ExecTransportError(message, code)
      for (const entry of this.queues.values()) entry.queue.fail(error)
      this.queues.clear()
    }
  }

  private ensureListener(): void {
    this.detach ??= this.channel.onFrame(frame => { this.handle(frame) })
  }

  private assertUsable(): void {
    if (this.disposed) throw new ExecTransportError('channel transport disposed', 'disposed')
  }
}

/**
 * A channel reference that resolves `globalThis.__PDSH_CHANNEL__` at call time.
 * The Worker entry may install the ordered WebSocket after plugin startup; the
 * exec bridge must not select a different wire for that boot window.
 */
export class DeferredChannel implements ChannelClient {
  private get inner(): ChannelClient {
    const channel = globalThis.__PDSH_CHANNEL__
    if (channel === undefined) throw new ExecTransportError('the ordered channel is not installed yet', 'transport')
    return channel
  }

  connect(): Promise<void> { return this.inner.connect() }
  send(type: Parameters<ChannelClient['send']>[0], payload: Uint8Array): bigint { return this.inner.send(type, payload) }
  onFrame(handler: Parameters<ChannelClient['onFrame']>[0]): () => void { return this.inner.onFrame(handler) }
  get hostHello(): HelloHostPayload | undefined { return globalThis.__PDSH_CHANNEL__?.hostHello }
  onHostHello(handler: (hello: HelloHostPayload) => void): () => void {
    const channel = globalThis.__PDSH_CHANNEL__
    // Before the entry installs the channel there is nothing to subscribe to;
    // the bounded wait in ChannelExecTransport reports HELLO_TIMEOUT instead.
    return channel === undefined ? () => {} : channel.onHostHello(handler)
  }
  ackedMseq(level: 1 | 2): bigint { return this.inner.ackedMseq(level) }
  waitAck(level: 1 | 2, uptoMseq: bigint, signal?: AbortSignal): Promise<void> { return this.inner.waitAck(level, uptoMseq, signal) }
  barrier(level: 1 | 2, uptoMseq: bigint): Promise<void> { return this.inner.barrier(level, uptoMseq) }
  nextMseq(): bigint { return this.inner.nextMseq() }
  journalAcked(sessionId: string, level: 1 | 2): bigint { return this.inner.journalAcked(sessionId, level) }
  waitJournalAck(level: 1 | 2, sessionId: string, uptoJseq: bigint, signal?: AbortSignal): Promise<void> {
    return this.inner.waitJournalAck(level, sessionId, uptoJseq, signal)
  }
  request(...args: Parameters<ChannelClient['request']>): ReturnType<ChannelClient['request']> { return this.inner.request(...args) }
  close(): Promise<void> { return this.inner.close() }
}

/** Same-origin loopback `/v1/exec*` over the Worker's own fetch (bearer token). */
export class FetchExecTransport implements ExecTransport {
  readonly kind = 'fetch' as const
  private readonly base: URL
  private readonly token: string
  private readonly accelerators: readonly string[]
  private readonly lifetime = new AbortController()
  private readonly retained = new Map<string, ExecRequest>()
  private helloFacts: Hello | undefined

  constructor(options: { url: string; token: string; accelerators?: readonly string[] }) {
    const base = new URL(options.url)
    if (base.protocol !== 'http:') throw new Error(`exec fetch transport needs an http:// loopback origin, got ${base.protocol}`)
    if (!isLoopbackHost(base.hostname)) {
      const origin = globalThis.location?.origin
      if (origin === undefined || new URL(origin).origin !== base.origin) {
        throw new Error(`exec fetch transport needs a loopback or same-origin URL, got ${base.origin}`)
      }
    }
    if (options.token.length < 16) throw new Error('exec fetch transport needs a bearer token of at least 16 characters')
    this.base = base
    this.token = options.token
    this.accelerators = options.accelerators ?? []
  }

  async hello(signal?: AbortSignal): Promise<Hello> {
    const response = await this.request('GET', '/v1/hello', undefined, signal)
    if (!response.ok) throw await responseError(response)
    const hello = await response.json() as Hello
    if (hello.protocol !== 'pdsh-exec-bridge/1') throw new ExecTransportError(`exec provider speaks ${JSON.stringify(hello.protocol)}`, 'protocol')
    const advertised = acceleratorsOfHello(hello)
    this.helloFacts = withAccelerators(hello, advertised.length > 0 ? advertised : this.accelerators)
    return this.helloFacts
  }

  lastMseq(): bigint { return 0n }

  async exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream> {
    // The same two phone-dsh-v1 members as the channel wire: the fetch route is
    // the Worker's fallback and the host expects the same idempotency facts.
    const prepared = withPhoneExecFields(request, this.lastMseq())
    this.retained.set(prepared.exec_id, prepared)
    const response = await this.request('POST', '/v1/exec', jsonSafe(execRequestJson(prepared)), signal)
    if (!response.ok) throw await responseError(response)
    return ndjsonStream(response)
  }

  async events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream> {
    const response = await this.request('GET', `/v1/exec/${encodeURIComponent(execId)}/events?after_seq=${afterSeq}`, undefined, signal)
    if (!response.ok) throw await responseError(response)
    return ndjsonStream(response)
  }

  async cancel(execId: string, body: { signal?: string; grace_ms?: number } = {}, signal?: AbortSignal): Promise<void> {
    const response = await this.request('POST', `/v1/exec/${encodeURIComponent(execId)}/cancel`, body, signal)
    if (!response.ok) throw await responseError(response)
  }

  async stdin(execId: string, body: { data?: string; eof?: boolean } = {}, signal?: AbortSignal): Promise<void> {
    const response = await this.request('POST', `/v1/exec/${encodeURIComponent(execId)}/stdin`, body, signal)
    if (!response.ok) throw await responseError(response)
  }

  lifecycle(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState> {
    return this.request('GET', `/v1/lifecycle?wait_ms=${Math.max(0, Math.floor(waitMs))}${since === undefined ? '' : `&since=${since}`}`, undefined, signal)
      .then(async response => {
        if (!response.ok) throw await responseError(response)
        return await response.json() as LifecycleState
      })
  }

  destroy(): void {
    this.lifetime.abort(new ExecTransportError('fetch transport disposed', 'disposed'))
  }

  private async request(method: string, path: string, body: unknown, signal?: AbortSignal): Promise<Response> {
    const target = new URL(path, this.base)
    const headers: Record<string, string> = {
      authorization: `Bearer ${this.token}`,
      accept: 'application/json, application/x-ndjson',
    }
    let payload: string | undefined
    if (body !== undefined) {
      payload = JSON.stringify(body)
      headers['content-type'] = 'application/json'
    }
    const signals = signal === undefined ? [this.lifetime.signal] : [this.lifetime.signal, signal]
    try {
      return await fetch(target, {
        method,
        headers,
        body: payload,
        cache: 'no-store',
        redirect: 'manual',
        signal: AbortSignal.any(signals),
      })
    } catch (error) {
      if (this.lifetime.signal.aborted) throw new ExecTransportError('exec fetch transport disposed', 'disposed', { cause: error })
      throw new ExecTransportError(`exec provider unreachable: ${error instanceof Error ? error.message : String(error)}`, 'transport', { cause: error })
    }
  }
}

/** Wrap an exec-bridge v1 NDJSON response as an event stream. */
export function ndjsonStream(response: Response): EventStream {
  const abort = new AbortController()
  const iterator = async function* (): AsyncGenerator<ExecEvent> {
    if (response.body === null) {
      throw new ExecTransportError('exec event stream has no body', 'transport')
    }
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffered = ''
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        buffered += decoder.decode(value, { stream: true })
        let newline = buffered.indexOf('\n')
        while (newline >= 0) {
          const line = buffered.slice(0, newline).trim()
          buffered = buffered.slice(newline + 1)
          if (line !== '') yield JSON.parse(line) as ExecEvent
          newline = buffered.indexOf('\n')
        }
      }
      buffered += decoder.decode()
      if (buffered.trim() !== '') throw new ExecTransportError('exec event stream ended inside a line', 'transport')
    } catch (error) {
      if (abort.signal.aborted) return
      throw error
    } finally {
      reader.releaseLock()
    }
  }
  const generator = iterator()
  return {
    [Symbol.asyncIterator]: () => generator,
    close: () => {
      abort.abort()
      void response.body?.cancel().catch(() => {})
    },
  }
}

/**
 * The exec-bridge v1 client face over a Worker transport (`channel` or
 * `fetch`).
 *
 * `XlExecBridge.client` used to be a node:http-only object, so a provider that
 * called it under the ordered channel failed before the transport could route
 * anything. This adapter keeps the provider contract (`exec`, `events`,
 * `cancel`, `stdin`, `lifecycle`) while every call goes through the selected
 * transport, where `requires_mseq`/`idem_key` are injected and unadvertised
 * programs are refused locally.
 */
export class TransportExecClient implements ExecClient {
  private readonly transport: ExecTransport

  constructor(transport: ExecTransport) {
    this.transport = transport
  }

  hello(signal?: AbortSignal): Promise<Hello> {
    return this.transport.hello(signal)
  }

  exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream> {
    return this.transport.exec(request, signal)
  }

  events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream> {
    return this.transport.events(execId, afterSeq, signal)
  }

  cancel(execId: string, body: { signal?: string; grace_ms?: number } = {}, signal?: AbortSignal): Promise<void> {
    return this.transport.cancel(execId, body, signal)
  }

  stdin(execId: string, body: { data?: string; eof?: boolean } = {}, signal?: AbortSignal): Promise<void> {
    return this.transport.stdin(execId, body, signal)
  }

  lifecycle(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState> {
    const lifecycle = this.transport.lifecycle
    if (lifecycle === undefined) {
      return Promise.reject(new ExecBridgeError(`the ${this.transport.kind} transport has no lifecycle endpoint`, 'unsupported'))
    }
    return lifecycle.call(this.transport, since, waitMs, signal)
  }

  destroy(): void {
    // The transport lifetime belongs to XlExecBridge; a provider may only drop
    // its own view of the client.
  }
}

/** The desktop exec-bridge v1 client (node:http), unchanged on the wire. */
export class NodeHttpExecTransport implements ExecTransport {
  readonly kind = 'node-http' as const
  readonly client: ExecBridgeClient
  private readonly accelerators: readonly string[]
  private facts: Hello | undefined

  constructor(options: { client: ExecBridgeClient; accelerators?: readonly string[] }) {
    this.client = options.client
    this.accelerators = options.accelerators ?? []
  }

  async hello(signal?: AbortSignal): Promise<Hello> {
    const hello = await this.client.hello(signal)
    const advertised = acceleratorsOfHello(hello)
    this.facts = withAccelerators(hello, advertised.length > 0 ? advertised : this.accelerators)
    return this.facts
  }

  exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream> {
    return this.client.exec(request, signal)
  }

  events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream> {
    return this.client.events(execId, afterSeq, signal)
  }

  cancel(execId: string, body: { signal?: string; grace_ms?: number } = {}, signal?: AbortSignal): Promise<void> {
    return this.client.cancel(execId, body, signal)
  }

  stdin(execId: string, body: { data?: string; eof?: boolean } = {}, signal?: AbortSignal): Promise<void> {
    return this.client.stdin(execId, body, signal)
  }

  lifecycle(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState> {
    return this.client.lifecycle(since, waitMs, signal)
  }

  lastMseq(): bigint { return 0n }

  destroy(): void { this.client.destroy() }
}

async function responseError(response: Response): Promise<ExecTransportError> {
  let code = `http_${response.status}`
  let message = `exec provider answered HTTP ${response.status}`
  try {
    const body = await response.json() as { error?: { code?: string; message?: string } }
    if (body.error?.code !== undefined) code = body.error.code
    if (body.error?.message !== undefined) message = body.error.message
  } catch {
    // Non-JSON failure: keep the status facts.
  }
  return new ExecTransportError(message, code)
}

/** Read a `u64` VFS mseq out of a VFS_MUT payload (used by the sink/scheduler). */
export function mutationMseq(payload: Uint8Array): bigint {
  return readU64be(payload, 0)
}
