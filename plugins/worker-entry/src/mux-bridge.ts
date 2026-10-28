// SPDX-License-Identifier: MIT
/**
 * Worker-side bridge for DSH's `/api/remote.mux` WebSocket (D23).
 *
 * The SDK's `ChannelDSHTransport` cannot carry a WebSocket over the ordered
 * channel, so it represents one logical mux session as unary API requests:
 *
 *   POST /api/remote.mux
 *   x-pdsh-mux-id: <32 lowercase hex>
 *   x-pdsh-mux-op: send | receive | close
 *
 * `send` carries one canonical JSON mux frame (the same client frames the DSH
 * gateway's `RemoteStreamMuxServer` consumes); `receive` answers a stream of
 * newline-delimited canonical JSON mux frames and ends when the logical mux
 * closes; `close` closes the session.
 *
 * The real mux endpoint is an HTTP upgrade route and the Worker runtime's `ws`
 * module is a deliberate not-implemented proxy, so no socket can be created in
 * the Worker. The bridge instead owns the mux protocol and hands every frame
 * to an injected {@link WorkerEntryMuxSession}; the production session drives
 * the gateway's own in-process stream opener through the runtime tunnel lane
 * (see `./mux-tunnel.ts`), which is the handler the WebSocket mux server calls
 * after decoding a frame.
 *
 * Every response body frame is canonical JSON (D5) and receive chunks are at
 * most 4 MiB, the API_RES body limit of channel.md §3.8.
 * @module @phone-dsh/dsh-worker-entry/mux-bridge
 */
import { MAX_API_BODY_BYTES } from '../../channel/src/api-frames.ts'
import { decodeUtf8, encodeUtf8 } from '../../channel/src/bytes.ts'
import { canonicalStringify } from '../../channel/src/canonical-json.ts'
import type { WorkerEntryResponseSink, WorkerEntrySyntheticRequest } from './entry.ts'

/** Path of the DSH Remote stream mux WebSocket. */
export const REMOTE_MUX_PATH = '/api/remote.mux'
/** Header naming one logical mux session. */
export const MUX_ID_HEADER = 'x-pdsh-mux-id'
/** Header naming the unary operation on a mux session. */
export const MUX_OPERATION_HEADER = 'x-pdsh-mux-op'
/** The three operations `ChannelDSHTransport` sends. */
export const MUX_SEND_OPERATION = 'send'
/** Long-lived response carrying newline-delimited mux frames. */
export const MUX_RECEIVE_OPERATION = 'receive'
/** Close the logical mux session. */
export const MUX_CLOSE_OPERATION = 'close'
/** Content type of one JSON mux frame. */
export const MUX_JSON_CONTENT_TYPE = 'application/json'
/** Content type of the receive stream. */
export const MUX_NDJSON_CONTENT_TYPE = 'application/x-ndjson'
/** One mux session id is 32 lowercase hex characters. */
export const MUX_ID_PATTERN = /^[0-9a-f]{32}$/
/** Error header used for a request the bridge itself refuses. */
export const MUX_ERROR_HEADER = 'x-pdsh-proxy-error'

/** One client-to-host mux frame of the DSH stream protocol. */
export type WorkerEntryMuxClientFrame =
  | {
    readonly type: 'open'
    readonly streamId: string
    readonly endpoint: string
    readonly payload: unknown
  }
  | { readonly type: 'item'; readonly streamId: string; readonly value?: unknown }
  | { readonly type: 'end'; readonly streamId: string }
  | { readonly type: 'cancel'; readonly streamId: string }

/** One host-to-client mux frame of the DSH stream protocol. */
export type WorkerEntryMuxServerFrame =
  | { readonly type: 'item'; readonly streamId: string; readonly value?: unknown }
  | { readonly type: 'end'; readonly streamId: string }
  | {
    readonly type: 'error'
    readonly streamId: string
    readonly error: { readonly code: string; readonly message: string; readonly details: object }
  }

/**
 * One in-Worker mux server session. The production implementation drives the
 * DSH gateway's in-process stream opener; tests supply a fake server.
 */
export interface WorkerEntryMuxSession {
  /** Deliver one validated client frame. */
  send(frame: WorkerEntryMuxClientFrame): void
  /** Observe server frames in delivery order. */
  onFrame(listener: (frame: WorkerEntryMuxServerFrame) => void): () => void
  /** Close the logical session, cancelling every open stream. */
  close(): void
}

/** Opens (or returns) the one session bound to a mux id. */
export type WorkerEntryMuxSessionFactory = (muxId: string) => WorkerEntryMuxSession

/** What `serveApiRequests` keeps for an in-flight bridge request. */
export interface WorkerEntryMuxExchange {
  /** The host abandoned the request (API_ABORT or transport loss). */
  abort(): void
}

/** Construction inputs for {@link WorkerEntryMuxBridge}. */
export interface WorkerEntryMuxBridgeOptions {
  /** In-process mux server session factory. */
  readonly createSession: WorkerEntryMuxSessionFactory
}

interface Receiver {
  readonly sink: WorkerEntryResponseSink
  ended: boolean
}

interface SessionState {
  readonly muxId: string
  readonly session: WorkerEntryMuxSession
  readonly queue: WorkerEntryMuxServerFrame[]
  unsubscribe: () => void
  receiver: Receiver | undefined
  closed: boolean
  finished: boolean
}

const NOOP_EXCHANGE: WorkerEntryMuxExchange = { abort(): void {} }

/**
 * Bridge the three `x-pdsh-mux-op` requests to per-id in-process mux sessions.
 *
 * A receive is long-lived; frames produced while no receive is attached are
 * queued and flushed in order to the next receive. `close`, disposal and a
 * lost channel cancel every open stream and drop the session.
 */
export class WorkerEntryMuxBridge {
  private readonly createSession: WorkerEntryMuxSessionFactory
  private readonly sessions = new Map<string, SessionState>()

  constructor(options: WorkerEntryMuxBridgeOptions) {
    this.createSession = options.createSession
  }

  /**
   * Serve one `/api/remote.mux` API request.
   * @param request - Decoded API_REQ head and body.
   * @param sink - Response sink of the API bridge.
   * @returns The abort handle `serveApiRequests` stores for API_ABORT.
   */
  handle(request: WorkerEntrySyntheticRequest, sink: WorkerEntryResponseSink): WorkerEntryMuxExchange {
    const muxId = headerValue(request.headers, MUX_ID_HEADER)
    const operation = headerValue(request.headers, MUX_OPERATION_HEADER)
    if (muxId === undefined || !MUX_ID_PATTERN.test(muxId)) {
      return refuse(sink, 400, 'mux_invalid_id', `${MUX_ID_HEADER} must be 32 lowercase hex characters`)
    }
    if (operation !== MUX_SEND_OPERATION
      && operation !== MUX_RECEIVE_OPERATION
      && operation !== MUX_CLOSE_OPERATION) {
      return refuse(sink, 400, 'mux_invalid_operation', `${MUX_OPERATION_HEADER} must be send, receive or close`)
    }
    if (operation === MUX_SEND_OPERATION) {
      let text: string
      try {
        text = decodeUtf8(request.body)
      } catch {
        return refuse(sink, 400, 'mux_invalid_frame', 'the send body is not valid UTF-8')
      }
      let frame: WorkerEntryMuxClientFrame
      try {
        frame = parseMuxClientFrame(text)
      } catch (error) {
        return refuse(sink, 400, 'mux_invalid_frame', messageOf(error))
      }
      const state = this.stateForRequest(muxId, sink)
      if (state === undefined) return NOOP_EXCHANGE
      return this.handleSend(state, frame, sink)
    }
    if (operation === MUX_CLOSE_OPERATION) {
      const existing = this.sessions.get(muxId)
      if (existing === undefined) {
        respondOk(sink)
        return NOOP_EXCHANGE
      }
      return this.handleClose(existing, sink)
    }
    const state = this.stateForRequest(muxId, sink)
    if (state === undefined) return NOOP_EXCHANGE
    return this.handleReceive(state, sink)
  }

  /** Cancel every stream and drop every session (disposal or channel loss). */
  closeAll(): void {
    for (const state of [...this.sessions.values()]) {
      state.closed = true
      try {
        state.session.close()
      } catch (error) {
        console.debug('worker entry: mux session close failed', error)
      }
      state.unsubscribe()
      this.drainQueue(state)
      this.endReceiver(state)
      state.finished = true
    }
    this.sessions.clear()
  }

  private stateFor(muxId: string): SessionState {
    const existing = this.sessions.get(muxId)
    if (existing !== undefined) return existing
    const session = this.createSession(muxId)
    const state: SessionState = {
      muxId,
      session,
      queue: [],
      unsubscribe: () => {},
      receiver: undefined,
      closed: false,
      finished: false,
    }
    state.unsubscribe = session.onFrame((frame) => { this.deliver(state, frame) })
    this.sessions.set(muxId, state)
    return state
  }

  private stateForRequest(muxId: string, sink: WorkerEntryResponseSink): SessionState | undefined {
    try {
      return this.stateFor(muxId)
    } catch (error) {
      refuse(sink, 500, 'mux_session_failed', messageOf(error))
      return undefined
    }
  }

  private handleSend(
    state: SessionState,
    frame: WorkerEntryMuxClientFrame,
    sink: WorkerEntryResponseSink,
  ): WorkerEntryMuxExchange {
    try {
      state.session.send(frame)
    } catch (error) {
      return refuse(sink, 400, 'mux_session_failed', messageOf(error))
    }
    respondOk(sink)
    return NOOP_EXCHANGE
  }

  private handleReceive(state: SessionState, sink: WorkerEntryResponseSink): WorkerEntryMuxExchange {
    if (state.receiver !== undefined) {
      return refuse(sink, 409, 'mux_receive_in_flight', 'a receive is already open for this mux session')
    }
    const receiver: Receiver = { sink, ended: false }
    state.receiver = receiver
    sink.head(200, {
      'content-type': MUX_NDJSON_CONTENT_TYPE,
      'cache-control': 'no-store',
    })
    // The empty first chunk publishes the head without inventing a frame.
    sink.chunk(new Uint8Array(0))
    this.drainQueue(state)
    if (state.closed) this.endReceiver(state)
    return {
      abort(): void {
        if (state.receiver === receiver && !receiver.ended) state.receiver = undefined
      },
    }
  }

  private handleClose(state: SessionState, sink: WorkerEntryResponseSink): WorkerEntryMuxExchange {
    state.closed = true
    try {
      state.session.close()
    } catch (error) {
      console.debug('worker entry: mux session close failed', error)
    }
    state.unsubscribe()
    this.sessions.delete(state.muxId)
    this.drainQueue(state)
    this.endReceiver(state)
    state.finished = true
    respondOk(sink)
    return NOOP_EXCHANGE
  }

  private deliver(state: SessionState, frame: WorkerEntryMuxServerFrame): void {
    if (state.finished) return
    const receiver = state.receiver
    if (receiver === undefined || receiver.ended) {
      state.queue.push(frame)
      return
    }
    try {
      writeMuxFrame(receiver.sink, frame)
    } catch (error) {
      this.failReceiver(state, receiver, error)
    }
  }

  private drainQueue(state: SessionState): void {
    const receiver = state.receiver
    if (receiver === undefined || receiver.ended) return
    while (state.queue.length > 0) {
      const frame = state.queue.shift()!
      try {
        writeMuxFrame(receiver.sink, frame)
      } catch (error) {
        this.failReceiver(state, receiver, error)
        return
      }
    }
  }

  private failReceiver(state: SessionState, receiver: Receiver, error: unknown): void {
    if (receiver.ended) return
    receiver.ended = true
    if (state.receiver === receiver) state.receiver = undefined
    receiver.sink.fail(messageOf(error))
  }

  private endReceiver(state: SessionState): void {
    const receiver = state.receiver
    if (receiver === undefined || receiver.ended) return
    state.receiver = undefined
    receiver.ended = true
    receiver.sink.end()
  }
}

/**
 * Validate one canonical JSON mux client frame against the DSH stream
 * protocol's exact-key rules (`stream-protocol.ts`).
 * @param text - Request body of a `send` operation.
 * @returns The validated frame.
 * @throws When the body is not exactly one legal mux client frame.
 */
export function parseMuxClientFrame(text: string): WorkerEntryMuxClientFrame {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    throw new Error('the mux frame is not JSON')
  }
  if (!isRecord(value)) throw new Error('the mux frame must be a JSON object')
  const type = value['type']
  const streamId = value['streamId']
  if (typeof streamId !== 'string' || streamId === '') {
    throw new Error('the mux frame needs a non-empty string streamId')
  }
  if (type === 'open' && hasExactKeys(value, ['type', 'streamId', 'endpoint', 'payload'])
    && typeof value['endpoint'] === 'string' && value['endpoint'] !== '') {
    return { type, streamId, endpoint: value['endpoint'], payload: value['payload'] }
  }
  if (type === 'item'
    && (hasExactKeys(value, ['type', 'streamId']) || hasExactKeys(value, ['type', 'streamId', 'value']))) {
    return Object.hasOwn(value, 'value')
      ? { type, streamId, value: value['value'] }
      : { type, streamId }
  }
  if ((type === 'end' || type === 'cancel') && hasExactKeys(value, ['type', 'streamId'])) {
    return { type, streamId }
  }
  throw new Error('the mux frame is not a legal open, item, end or cancel frame')
}

/** Encode one server frame as a canonical newline-delimited record. */
export function encodeMuxFrameLine(frame: WorkerEntryMuxServerFrame): Uint8Array {
  return encodeUtf8(`${canonicalStringify(muxWireFrame(frame))}\n`)
}

function muxWireFrame(frame: WorkerEntryMuxServerFrame): Record<string, unknown> {
  switch (frame.type) {
    case 'item':
      return frame.value !== undefined
        ? { type: frame.type, streamId: frame.streamId, value: frame.value }
        : { type: frame.type, streamId: frame.streamId }
    case 'end':
      return { type: frame.type, streamId: frame.streamId }
    case 'error':
      return {
        type: frame.type,
        streamId: frame.streamId,
        error: {
          code: frame.error.code,
          message: frame.error.message,
          details: frame.error.details,
        },
      }
  }
}

function writeMuxFrame(sink: WorkerEntryResponseSink, frame: WorkerEntryMuxServerFrame): void {
  const bytes = encodeMuxFrameLine(frame)
  let offset = 0
  while (offset < bytes.byteLength) {
    const end = Math.min(offset + MAX_API_BODY_BYTES, bytes.byteLength)
    sink.chunk(bytes.subarray(offset, end))
    offset = end
  }
}

function respondOk(sink: WorkerEntryResponseSink): void {
  sink.end({
    status: 200,
    headers: { 'content-type': MUX_JSON_CONTENT_TYPE, 'cache-control': 'no-store' },
    body: encodeUtf8('{}'),
  })
}

function refuse(
  sink: WorkerEntryResponseSink,
  status: number,
  code: string,
  message: string,
): WorkerEntryMuxExchange {
  sink.end({
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      [MUX_ERROR_HEADER]: code,
    },
    body: encodeUtf8(canonicalStringify({ error: { code, message } })),
  })
  return NOOP_EXCHANGE
}

function headerValue(headers: Readonly<Record<string, string>>, name: string): string | undefined {
  const direct = headers[name]
  if (direct !== undefined) return direct
  const lower = name.toLowerCase()
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === lower) return value
  }
  return undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const own = Object.keys(value)
  return own.length === keys.length && keys.every(key => Object.hasOwn(value, key))
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
