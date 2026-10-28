// SPDX-License-Identifier: MIT
/**
 * In-memory ordered-channel pair for tests.
 *
 * Two {@link ChannelClient} implementations are connected through a synchronous
 * ordered pipe with optional frame dropping and per-frame delay. The pair keeps
 * the host's expected mseq, the worker's unacknowledged VFS_MUT buffer and both
 * seq spaces, so a disconnect/reconnect exercises the D3 rule: the worker
 * re-sends every VFS_MUT with `mseq > acked_mseq`, preserving the original mseq,
 * and the host accepts only its expected mseq.
 * @module @phone-dsh/dsh-channel/memory-channel
 */
import { decodeUtf8, concatBytes, encodeUtf8, readU64be } from './bytes.ts'
import {
  decodeApiAbort, decodeApiEnd, decodeApiResponse, encodeApiRequest, encodeApiResponse,
} from './api-frames.ts'
import { AckTracker, AsyncQueue, VFS_ACK_KEY } from './ack-tracker.ts'
import { makeHostHello } from './host-hello.ts'
import { canonicalStringify } from './canonical-json.ts'
import type { ApiResponseChunk, ChannelClient, ChannelRole } from './client.ts'
import { FrameError, type FrameErrorCode } from './errors.ts'
import { encodeFrame, FrameType, type Frame } from './frames.ts'
import {
  hostMaySend, workerMaySend,
  type ApiRequestHead, type HelloHostPayload,
} from './payloads.ts'
import {
  decodeJournalAck, decodeVfsAck, decodeVfsBarrier, encodeVfsAck, encodeVfsBarrier,
} from './vfs-mutation.ts'

/** Direction a memory frame travels. */
export type MemoryDirection = 'host->worker' | 'worker->host'

/** Return true to drop a frame before it reaches the peer. */
export type MemoryDropPredicate = (direction: MemoryDirection, frame: Frame) => boolean

/** Construction inputs for {@link createMemoryChannelPair}. */
export interface MemoryChannelOptions {
  /** Host-allocated mseq for the first VFS_MUT; defaults to 1. */
  readonly nextMseq?: bigint
  /** Highest mseq the worker treats as acknowledged before reconnect. */
  readonly ackedMseq?: bigint
  /** Auto-send level-1 VFS_ACKs (and barrier acks); defaults to true. */
  readonly autoAck?: boolean
  /** Drop predicate installed before the first frame. */
  readonly drop?: MemoryDropPredicate
  /** Delay every delivery by this many milliseconds; defaults to 0 (microtask). */
  readonly delayMs?: number
  /** Connect both ends before returning; defaults to true. */
  readonly autoConnect?: boolean
  /**
   * Host HELLO payload the pair hands to the worker on connect (and on every
   * reconnect). Absent means `hostHello` stays undefined until a test sets it.
   */
  readonly hostHello?: HelloHostPayload
  /** Convenience: build the host HELLO with exactly these extra caps. */
  readonly caps?: readonly string[]
  /** Bound for a durability wait; defaults to the validated 30 s window. */
  readonly ackTimeoutMs?: number
}

/** Thrown by {@link ChannelClient.request} when the peer aborts a request. */
export class ChannelRequestError extends Error {
  readonly reqId: number
  readonly reason: string

  constructor(reqId: number, reason: string) {
    super(`API request ${reqId} aborted: ${reason}`)
    this.name = 'ChannelRequestError'
    this.reqId = reqId
    this.reason = reason
  }
}

/** Scheduling and shared mseq state for one memory pair. */
class SharedLink {
  transportOpen = true
  nextMseq: bigint
  expectedMseq: bigint
  autoAck: boolean
  drop: MemoryDropPredicate | undefined
  delayMs: number
  hostHello: HelloHostPayload | undefined
  generation = 0
  host!: MemoryChannelClient
  worker!: MemoryChannelClient
  private chain: Promise<void> = Promise.resolve()

  constructor(options: MemoryChannelOptions) {
    this.nextMseq = options.nextMseq ?? 1n
    if (this.nextMseq < 1n) throw new RangeError('nextMseq must be at least 1')
    this.expectedMseq = this.nextMseq
    this.autoAck = options.autoAck ?? true
    this.drop = options.drop
    this.delayMs = options.delayMs ?? 0
    this.hostHello = options.hostHello
      ?? (options.caps === undefined
        ? undefined
        : makeHostHello({
          caps: options.caps,
          ackedMseq: options.ackedMseq ?? (this.nextMseq - 1n),
          nextMseq: this.nextMseq,
        }))
  }

  schedule(task: () => void): void {
    this.chain = this.chain.then(async () => {
      await new Promise<void>((resolve) => {
        const run = (): void => {
          try {
            task()
          } catch (error) {
            console.error('memory channel: delivery failed', error)
          } finally {
            resolve()
          }
        }
        if (this.delayMs > 0) setTimeout(run, this.delayMs)
        else queueMicrotask(run)
      })
    })
  }

  /** Await queued deliveries, including ones queued by earlier deliveries. */
  async flush(): Promise<void> {
    for (;;) {
      const current = this.chain
      await current
      if (current === this.chain) return
    }
  }
}

const HEX_REQUEST_ID = 0xffffffff

/** In-memory {@link ChannelClient}; create it through {@link createMemoryChannelPair}. */
export class MemoryChannelClient implements ChannelClient {
  readonly role: ChannelRole
  private readonly shared: SharedLink
  private readonly peer: () => MemoryChannelClient
  private readonly listeners = new Set<(frame: Frame) => void>()
  private readonly hostHelloListeners = new Set<(hello: HelloHostPayload) => void>()
  private readonly unacked = new Map<bigint, Uint8Array>()
  private readonly vfsAcks: AckTracker
  private readonly journalAcks: AckTracker
  private readonly pending = new Map<number, AsyncQueue<ApiResponseChunk>>()
  private hostHelloValue: HelloHostPayload | undefined
  private connected = false
  private closed = false
  private outboundSeq = 0n
  private inboundSeq = 0n
  private nextRequestId = 1

  /** @internal Use {@link createMemoryChannelPair}. */
  constructor(role: ChannelRole, shared: SharedLink, peer: () => MemoryChannelClient, options: MemoryChannelOptions) {
    this.role = role
    this.shared = shared
    this.peer = peer
    this.vfsAcks = new AckTracker({ timeoutMs: options.ackTimeoutMs })
    this.journalAcks = new AckTracker({ timeoutMs: options.ackTimeoutMs })
    this.vfsAcks.resolve(VFS_ACK_KEY, 1, options.ackedMseq ?? (shared.nextMseq - 1n))
    this.hostHelloValue = role === 'host' ? shared.hostHello : undefined
  }

  async connect(): Promise<void> {
    if (this.closed) throw new Error('memory channel is closed')
    if (this.connected) return
    this.connected = true
    this.shared.transportOpen = true
    this.outboundSeq = 0n
    this.inboundSeq = 0n
    const hello = this.shared.hostHello
    if (hello !== undefined) {
      // Every connection starts with the host HELLO (D1); the test pair hands
      // the configured payload to the worker again, so cap changes across a
      // reconnect are visible through `hostHello`/`onHostHello`.
      this.hostHelloValue = hello
      this.vfsAcks.resolve(VFS_ACK_KEY, 1, hello.acked_mseq)
      this.vfsAcks.resolve(VFS_ACK_KEY, 2, hello.durable_mseq)
      for (const mseq of [...this.unacked.keys()]) {
        if (mseq <= this.ackedMseq(1)) this.unacked.delete(mseq)
      }
      this.notifyHostHello(hello)
    }
    if (this.role === 'worker' && this.shared.generation > 0) {
      // The host HELLO reports its effective tail on reconnect (D3); treat it
      // as the new acknowledged floor before re-sending the buffer.
      const hostTail = this.shared.expectedMseq - 1n
      this.vfsAcks.resolve(VFS_ACK_KEY, 1, hostTail)
      for (const mseq of [...this.unacked.keys()]) {
        if (mseq <= this.ackedMseq(1)) this.unacked.delete(mseq)
      }
      this.resendUnacked()
    }
    await this.shared.flush()
  }

  send(type: FrameType, payload: Uint8Array): bigint {
    if (this.closed) throw new Error('memory channel is closed')
    if (!this.connected || !this.shared.transportOpen) throw new Error('memory channel is not connected')
    const maySend = this.role === 'host' ? hostMaySend(type) : workerMaySend(type)
    if (!maySend) {
      throw new FrameError('PROTO_MISMATCH', `frame type 0x${type.toString(16)} is not outbound for the ${this.role}`)
    }
    const seq = this.outboundSeq + 1n
    const frame: Frame = { type, seq, payload }
    // Reuse the real encoder so a test double rejects exactly what the wire rejects.
    encodeFrame(frame)
    this.outboundSeq = seq
    if (type === FrameType.VFS_MUT) {
      if (payload.byteLength < 8) throw new FrameError('BAD_PAYLOAD', 'VFS_MUT payload is shorter than its mseq')
      const mseq = readU64be(payload, 0)
      if (mseq >= this.shared.nextMseq) this.shared.nextMseq = mseq + 1n
      this.unacked.set(mseq, payload.slice())
    }
    this.deliver(frame)
    return seq
  }

  onFrame(handler: (frame: Frame) => void): () => void {
    this.listeners.add(handler)
    return () => { this.listeners.delete(handler) }
  }

  get hostHello(): HelloHostPayload | undefined {
    return this.hostHelloValue
  }

  onHostHello(handler: (hello: HelloHostPayload) => void): () => void {
    this.hostHelloListeners.add(handler)
    return () => { this.hostHelloListeners.delete(handler) }
  }

  ackedMseq(level: 1 | 2): bigint {
    return this.vfsAcks.acked(VFS_ACK_KEY, level)
  }

  async waitAck(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    if (this.closed) throw new Error('memory channel is closed')
    if (this.ackedMseq(level) >= uptoMseq) return
    if (!this.connected) throw new Error('memory channel is not connected')
    await this.vfsAcks.wait(VFS_ACK_KEY, level, uptoMseq, signal, options?.timeoutMs)
  }

  journalAcked(sessionId: string, level: 1 | 2): bigint {
    return this.journalAcks.acked(sessionId, level)
  }

  async waitJournalAck(
    level: 1 | 2,
    sessionId: string,
    uptoJseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    if (this.closed) throw new Error('memory channel is closed')
    if (this.journalAcked(sessionId, level) >= uptoJseq) return
    if (!this.connected) throw new Error('memory channel is not connected')
    await this.journalAcks.wait(sessionId, level, uptoJseq, signal, options?.timeoutMs)
  }

  async barrier(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    if (this.role === 'worker') {
      this.send(FrameType.VFS_BARRIER, encodeVfsBarrier({ wantLevel: level, uptoMseq }))
    }
    await this.waitAck(level, uptoMseq, signal, options)
  }

  nextMseq(): bigint {
    return this.shared.nextMseq
  }

  request(head: ApiRequestHead, body: Uint8Array | ReadableStream<Uint8Array>): AsyncIterable<ApiResponseChunk> {
    if (this.role === 'worker') {
      throw new FrameError('PROTO_MISMATCH', 'API_REQ (0x40) is host->worker only; a Worker channel cannot send it')
    }
    return this.requestHost(head, body)
  }

  private async *requestHost(
    head: ApiRequestHead,
    body: Uint8Array | ReadableStream<Uint8Array>,
  ): AsyncGenerator<ApiResponseChunk> {
    if (this.nextRequestId > HEX_REQUEST_ID) throw new Error('API request id space exhausted')
    const reqId = this.nextRequestId++
    const queue = new AsyncQueue<ApiResponseChunk>()
    this.pending.set(reqId, queue)
    try {
      const bytes = body instanceof Uint8Array ? body : await readBody(body)
      this.send(FrameType.API_REQ, encodeApiRequest({ reqId, head, body: bytes }))
      for (;;) {
        const result = await queue.next()
        if (result.done) return
        yield result.value
      }
    } finally {
      this.pending.delete(reqId)
    }
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.connected = false
    this.shared.transportOpen = false
    this.vfsAcks.rejectAll(new Error('memory channel closed'))
    this.journalAcks.rejectAll(new Error('memory channel closed'))
    for (const queue of this.pending.values()) queue.fail(new Error('memory channel closed'))
    this.pending.clear()
    const peer = this.peer()
    if (!peer.closed) peer.connected = false
  }

  /** @internal Drop the transport but keep the reconnect buffers. */
  disconnect(): void {
    this.connected = false
    this.inboundSeq = 0n
    this.outboundSeq = 0n
    // channel.md §3.10: the local side aborts its own in-flight requests with
    // `connection_closed`; the frame is delivered locally, not to the dead peer.
    for (const [reqId, queue] of this.pending) {
      queue.fail(new ChannelRequestError(reqId, 'connection_closed'))
    }
    this.pending.clear()
    this.hostHelloValue = undefined
    this.vfsAcks.rejectAll(new Error('memory channel disconnected'))
    this.journalAcks.rejectAll(new Error('memory channel disconnected'))
  }

  /** @internal The host reports the tail it accepted as `expectedMseq - 1`. */
  get expectedInboundMseq(): bigint {
    return this.shared.expectedMseq
  }

  private deliver(frame: Frame): void {
    const direction: MemoryDirection = this.role === 'host' ? 'host->worker' : 'worker->host'
    if (this.shared.drop?.(direction, frame) === true) return
    this.shared.schedule(() => {
      if (!this.shared.transportOpen) return
      this.peer().accept(frame)
    })
  }

  private accept(frame: Frame): void {
    if (!this.connected) return
    if (frame.seq !== this.inboundSeq + 1n) {
      this.sendError('BAD_SEQ', `expected ${String(this.inboundSeq + 1n)}, got ${String(frame.seq)}`, frame.seq)
      this.connected = false
      return
    }
    this.inboundSeq = frame.seq
    switch (frame.type) {
      case FrameType.VFS_MUT:
        if (!this.acceptVfsMutation(frame)) return
        break
      case FrameType.VFS_ACK:
        this.acceptVfsAck(frame)
        break
      case FrameType.VFS_BARRIER:
        this.acceptVfsBarrier(frame)
        break
      case FrameType.JOURNAL_ACK:
        this.acceptJournalAck(frame)
        break
      case FrameType.API_RES:
        this.acceptApiResponse(frame)
        break
      case FrameType.API_END:
        try {
          this.pending.get(decodeApiEnd(frame.payload))?.end()
        } catch {
          this.sendError('BAD_PAYLOAD', 'malformed API_END', frame.seq)
          return
        }
        break
      case FrameType.API_ABORT:
        try {
          const abort = decodeApiAbort(frame.payload)
          this.pending.get(abort.reqId)?.fail(new ChannelRequestError(abort.reqId, abort.reason))
        } catch {
          this.sendError('BAD_PAYLOAD', 'malformed API_ABORT', frame.seq)
          return
        }
        break
      case FrameType.ERROR:
        this.acceptError(frame)
        break
      default:
        break
    }
    this.notify(frame)
  }

  private acceptVfsMutation(frame: Frame): boolean {
    if (this.role !== 'host') return true
    if (frame.payload.byteLength < 8) {
      this.sendError('BAD_PAYLOAD', 'VFS_MUT payload is shorter than its mseq', frame.seq)
      return false
    }
    const mseq = readU64be(frame.payload, 0)
    if (mseq !== this.shared.expectedMseq) {
      this.sendError('BAD_MSEQ', `expected mseq ${String(this.shared.expectedMseq)}, got ${String(mseq)}`, frame.seq)
      return false
    }
    this.shared.expectedMseq = mseq + 1n
    if (this.shared.autoAck) {
      this.send(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: mseq }))
    }
    return true
  }

  private acceptVfsAck(frame: Frame): void {
    let ack
    try {
      ack = decodeVfsAck(frame.payload)
    } catch {
      this.sendError('BAD_PAYLOAD', 'malformed VFS_ACK', frame.seq)
      return
    }
    this.vfsAcks.resolve(VFS_ACK_KEY, ack.level, ack.uptoMseq)
    for (const mseq of [...this.unacked.keys()]) {
      if (mseq <= this.ackedMseq(1)) this.unacked.delete(mseq)
    }
  }

  private acceptJournalAck(frame: Frame): void {
    let ack
    try {
      ack = decodeJournalAck(frame.payload)
    } catch {
      this.sendError('BAD_PAYLOAD', 'malformed JOURNAL_ACK', frame.seq)
      return
    }
    this.journalAcks.resolve(ack.sessionId, ack.level, ack.uptoJseq)
  }

  private acceptVfsBarrier(frame: Frame): void {
    if (this.role !== 'host') return
    let barrier
    try {
      barrier = decodeVfsBarrier(frame.payload)
    } catch {
      this.sendError('BAD_PAYLOAD', 'malformed VFS_BARRIER', frame.seq)
      return
    }
    if (this.shared.autoAck) {
      this.send(FrameType.VFS_ACK, encodeVfsAck({ level: barrier.wantLevel, uptoMseq: barrier.uptoMseq }))
    }
  }

  private acceptApiResponse(frame: Frame): void {
    let chunk
    try {
      chunk = decodeApiResponse(frame.payload)
    } catch {
      this.sendError('BAD_PAYLOAD', 'malformed API_RES', frame.seq)
      return
    }
    const queue = this.pending.get(chunk.reqId)
    if (queue === undefined) return
    queue.push(chunk.head === undefined ? { body: chunk.body } : { head: chunk.head, body: chunk.body })
  }

  private acceptError(frame: Frame): void {
    let code = 'BAD_PAYLOAD'
    let message = 'peer reported an error'
    try {
      const parsed = JSON.parse(decodeUtf8(frame.payload)) as { code?: unknown; message?: unknown }
      if (typeof parsed.code === 'string') code = parsed.code
      if (typeof parsed.message === 'string') message = parsed.message
    } catch {
      // Keep the generic message; the ERROR payload is already malformed.
    }
    const error = new Error(`peer error ${code}: ${message}`)
    for (const queue of this.pending.values()) queue.fail(error)
    this.pending.clear()
    this.vfsAcks.rejectAll(error)
    this.journalAcks.rejectAll(error)
  }

  private sendError(code: FrameErrorCode, message: string, refSeq: bigint): void {
    const payload = encodeUtf8(canonicalStringify({ code, message, ref_seq: refSeq }))
    try {
      this.send(FrameType.ERROR, payload)
    } catch {
      // The connection is already gone; nothing else to report.
    }
  }

  private notify(frame: Frame): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(frame)
      } catch (error) {
        console.error('memory channel: frame handler failed', error)
      }
    }
  }

  private notifyHostHello(hello: HelloHostPayload): void {
    for (const listener of [...this.hostHelloListeners]) {
      try {
        listener(hello)
      } catch (error) {
        console.error('memory channel: host-hello handler failed', error)
      }
    }
  }

  private resendUnacked(): void {
    const entries = [...this.unacked.entries()].sort((left, right) => left[0] < right[0] ? -1 : left[0] > right[0] ? 1 : 0)
    for (const [mseq, payload] of entries) {
      if (mseq <= this.ackedMseq(1)) continue
      this.send(FrameType.VFS_MUT, payload)
    }
  }

}

/** The two connected clients plus transport controls. */
export interface MemoryChannelPair {
  readonly host: MemoryChannelClient
  readonly worker: MemoryChannelClient
  /** Simulate a connection loss; unacknowledged mutations stay buffered. */
  disconnect(): void
  /** Reconnect both ends and let the worker resend the unacked VFS_MUT buffer. */
  reconnect(): Promise<void>
  /** Replace or clear the drop predicate. */
  setDrop(predicate: MemoryDropPredicate | undefined): void
  /** Set the per-delivery delay; 0 means a microtask. */
  setDelay(delayMs: number): void
  /** Replace the host HELLO handed to the worker on the next connect. */
  setHostHello(hello: HelloHostPayload | undefined): void
}

/** Build two connected in-memory channel clients. */
export function createMemoryChannelPair(options: MemoryChannelOptions = {}): MemoryChannelPair {
  const shared = new SharedLink(options)
  let host: MemoryChannelClient
  let worker: MemoryChannelClient
  host = new MemoryChannelClient('host', shared, () => worker, options)
  worker = new MemoryChannelClient('worker', shared, () => host, options)
  shared.host = host
  shared.worker = worker
  if (options.autoConnect ?? true) {
    void host.connect()
    void worker.connect()
  }
  return {
    host,
    worker,
    disconnect(): void {
      shared.transportOpen = false
      shared.generation += 1
      host.disconnect()
      worker.disconnect()
    },
    async reconnect(): Promise<void> {
      shared.transportOpen = true
      await host.connect()
      await worker.connect()
      await shared.flush()
    },
    setDrop(predicate: MemoryDropPredicate | undefined): void {
      shared.drop = predicate
    },
    setDelay(delayMs: number): void {
      shared.delayMs = delayMs
    },
    setHostHello(hello: HelloHostPayload | undefined): void {
      shared.hostHello = hello
    },
  }
}

async function readBody(body: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const chunks: Uint8Array[] = []
  for await (const chunk of body as unknown as AsyncIterable<Uint8Array>) chunks.push(chunk)
  return concatBytes(chunks)
}
