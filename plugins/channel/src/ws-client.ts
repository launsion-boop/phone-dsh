// SPDX-License-Identifier: MIT
/**
 * WebSocket implementation of the worker face of the ordered channel.
 *
 * One connection carries every frame (channel.md §2). Each direction has its own
 * `seq` space starting at 1 with a HELLO first (D1); the outbound `mseq` space
 * continues from the host HELLO's `next_mseq` (D3). Unacknowledged VFS mutations
 * and journal records survive a reconnect and are re-sent after the fresh HELLO
 * exchange: VFS mutations in ascending `mseq` order with their original `mseq`,
 * journal records per `(session_id, jseq)`, which the host deduplicates.
 *
 * Flow control follows channel.md §8: at most {@link MAX_UNACKED_VFS_BYTES}
 * bytes of VFS_MUT may be on the wire unacknowledged. Applying a mutation is
 * synchronous in the VFS, so new mutations queue once the window is full; when
 * an ack arrives the queue drains. If no level-1 ack advances the window for
 * {@link RING_TIMEOUT_MS}, the client sends `RING_TIMEOUT`, closes admission and
 * fails loud instead of dropping a mutation.
 *
 * Every single durability wait is also bounded (channel.md does not require
 * that bound; D3 only bounds the 32 MiB condition). On an ack timeout the
 * client sends an ERROR, recycles the connection and lets the reconnect replay
 * of unacked JOURNAL/VFS_MUT frames run with their original jseq/mseq; the
 * stuck callers reject instead of parking the agent loop.
 *
 * The transport is the global `WebSocket` (browsers and Node >= 22). Tests
 * inject an in-memory socket through {@link WebSocketChannelOptions.createSocket}.
 * @module @phone-dsh/dsh-channel/ws-client
 */
import { decodeApiAbort } from './api-frames.ts'
import {
  AckTimeoutError, AckTracker, resolveDurabilityAckTimeoutMs, VFS_ACK_KEY,
} from './ack-tracker.ts'
import { canonicalStringify } from './canonical-json.ts'
import { decodeUtf8, encodeUtf8, writeU64be } from './bytes.ts'
import {
  MAX_UNACKED_VFS_BYTES, RING_TIMEOUT_MS,
  type ChannelClient, type ChannelRole, type DurabilityWaitOptions,
} from './client.ts'
import { FrameError, type FrameErrorCode } from './errors.ts'
import { FrameDecoder, FrameType, encodeFrame, isFrameType, MAX_FRAME_PAYLOAD, type Frame } from './frames.ts'
import {
  parseVfsRefusedDiagnostic, VfsRefusedError,
  workerMaySend, WORKER_CAPABILITIES,
  type Admission, type Fence, type FencePayload, type HelloHostPayload, type LifecyclePayload,
  type VfsRefusedDiagnostic,
} from './payloads.ts'
import { parseHostHello } from './host-hello.ts'
import { isValidBootId, isValidFenceOwner } from './validate.ts'
import {
  decodeJournal, decodeJournalAck, decodeVfsAck, decodeVfsMutation, decodeVfsResync,
  encodeVfsBarrier,
} from './vfs-mutation.ts'

/** The slice of the browser `WebSocket` this client uses. */
export interface WebSocketLike {
  readonly readyState: number
  binaryType: string
  send(data: ArrayBuffer | ArrayBufferView | string): void
  close(code?: number, reason?: string): void
  addEventListener(type: string, listener: (event: unknown) => void): void
}

/** Factory for the transport; defaults to the global `WebSocket` constructor. */
export type WebSocketFactory = (url: string) => WebSocketLike

/** Construction inputs for {@link WebSocketChannelClient}. */
export interface WebSocketChannelOptions {
  /** Loopback channel URL. A relative URL resolves against `location.href` when present. */
  readonly url: string
  /** Per-start loopback token; appended as the `token` query parameter (C_SECURITY). */
  readonly token?: string
  /** 32 lowercase hex characters, one per Worker process boot (D6). */
  readonly bootId: string
  /** Host session incarnation; the worker echoes its boot value. */
  readonly sessionEpoch: bigint | number
  /** Execution authority the page supplied before booting. */
  readonly fence: Fence
  /** Highest mseq already assigned by this worker process; defaults to 0. */
  readonly lastMseq?: bigint
  /** Worker capabilities; defaults to the four of channel.md §4.1. */
  readonly caps?: readonly string[]
  /** Injected transport, normally the global `WebSocket`. */
  readonly createSocket?: WebSocketFactory
  /** First reconnect delay; doubles up to {@link backoffMaxMs}. */
  readonly backoffMinMs?: number
  /** Reconnect delay ceiling. */
  readonly backoffMaxMs?: number
  /** Unacknowledged VFS_MUT byte window. */
  readonly maxUnackedVfsBytes?: number
  /** Time without level-1 progress before `RING_TIMEOUT`. */
  readonly ringTimeoutMs?: number
  /**
   * Bound for one durability acknowledgement wait (`0x11`, `0x12`, `0x31`).
   * Defaults to the validated env/constant window; on expiry the client emits
   * an ERROR frame, closes this connection and reconnects so the D2/D3 replay
   * path resends the original jseq/mseq.
   */
  readonly ackTimeoutMs?: number
}

/** A request owner retries after this error; the connection was replaced. */
export class ChannelReconnectError extends Error {
  readonly code = 'RECONNECT'

  constructor(message = 'channel reconnected; retry the request on the new connection') {
    super(message)
    this.name = 'ChannelReconnectError'
  }
}

/** The channel was closed by its owner. */
export class ChannelClosedError extends Error {
  readonly code = 'CLOSED'

  constructor(message = 'channel closed') {
    super(message)
    this.name = 'ChannelClosedError'
  }
}

/** The peer rejected the connection or the flow-control window stalled. */
export class ChannelPeerError extends Error {
  readonly code: FrameErrorCode | 'RING_TIMEOUT'

  constructor(code: FrameErrorCode | 'RING_TIMEOUT', message: string) {
    super(`${code}: ${message}`)
    this.name = 'ChannelPeerError'
    this.code = code
  }
}

/** Re-exported so a channel consumer can catch the non-fatal refusal here. */
export { VfsRefusedError } from './payloads.ts'
export type { VfsRefusedDiagnostic } from './payloads.ts'

interface UnackedMutation {
  payload: Uint8Array
  readonly bytes: number
  readonly path: string
  sent: boolean
  /** Connection seq of the current transmission, for a host `ref_seq`. */
  seq: bigint | undefined
}

/**
 * Channel client over one WebSocket at a time, reconnecting with backoff.
 *
 * Protocol errors and `RING_TIMEOUT` are fatal: the connection closes and is not
 * retried. A transport loss is retried until {@link close} is called.
 */
export class WebSocketChannelClient implements ChannelClient {
  readonly role: ChannelRole = 'worker'

  private readonly options: Required<Pick<WebSocketChannelOptions,
    'backoffMinMs' | 'backoffMaxMs' | 'maxUnackedVfsBytes' | 'ringTimeoutMs' | 'ackTimeoutMs'
    | 'caps' | 'lastMseq'>> & WebSocketChannelOptions
  private readonly listeners = new Set<(frame: Frame) => void>()
  private readonly transportLostListeners = new Set<() => void>()
  private readonly hostHelloListeners = new Set<(hello: HelloHostPayload) => void>()
  private readonly vfsAcks: AckTracker
  private readonly journalAcks: AckTracker
  private readonly unackedVfs = new Map<bigint, UnackedMutation>()
  private readonly vfsQueue: bigint[] = []
  private readonly unackedJournal = new Map<string, Map<bigint, Uint8Array>>()
  private readonly pendingBarriers = new Map<string, { level: 1 | 2; uptoMseq: bigint }>()
  /**
   * Resource refusals received from the host, keyed by the mseq that was
   * refused (channel.md §4.8). A refused mutation consumes no mseq, so the
   * entry makes later `waitAck` calls for that unreachable range reject with
   * the structured error even after no waiter was pending. It clears when a
   * new mutation owns that mseq or an ack covers it.
   */
  private readonly refusals = new Map<bigint, VfsRefusedError>()

  private hostHelloValue: HelloHostPayload | undefined
  private socket: WebSocketLike | undefined
  private decoder = new FrameDecoder()
  private transportOpen = false
  private helloDone = false
  private closing = false
  private fatalError: Error | undefined
  private durabilityFailure: AckTimeoutError | undefined
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private reconnectAttempts = 0
  private outboundSeq = 0n
  private inboundSeq = 0n
  private nextMseqValue: bigint
  private lastMseqValue: bigint
  private sentVfsBytes = 0
  private ringTimer: ReturnType<typeof setTimeout> | undefined
  private lifecycleAdmission: Admission = 'open'
  private fenceAdmission: Admission = 'open'
  private connectPromise: Promise<void> | undefined
  private connectResolve: (() => void) | undefined
  private connectReject: ((reason: unknown) => void) | undefined

  constructor(options: WebSocketChannelOptions) {
    if (typeof options.url !== 'string' || options.url.length === 0) {
      throw new TypeError('WebSocketChannelClient: url is required')
    }
    if (!isValidBootId(options.bootId)) {
      throw new TypeError('WebSocketChannelClient: bootId must be 32 lowercase hex characters')
    }
    if (!isValidFenceOwner(options.fence.owner)) {
      throw new TypeError('WebSocketChannelClient: fence.owner is invalid')
    }
    this.options = {
      ...options,
      caps: options.caps ?? WORKER_CAPABILITIES,
      lastMseq: options.lastMseq ?? 0n,
      backoffMinMs: options.backoffMinMs ?? 100,
      backoffMaxMs: options.backoffMaxMs ?? 5_000,
      maxUnackedVfsBytes: options.maxUnackedVfsBytes ?? MAX_UNACKED_VFS_BYTES,
      ringTimeoutMs: options.ringTimeoutMs ?? RING_TIMEOUT_MS,
      ackTimeoutMs: resolveDurabilityAckTimeoutMs(options.ackTimeoutMs),
    }
    this.vfsAcks = new AckTracker({ timeoutMs: this.options.ackTimeoutMs })
    this.journalAcks = new AckTracker({ timeoutMs: this.options.ackTimeoutMs })
    this.lastMseqValue = options.lastMseq ?? 0n
    this.nextMseqValue = this.lastMseqValue + 1n
  }

  /** Open (or re-open) the transport and resolve once the HELLO exchange is complete. */
  async connect(): Promise<void> {
    if (this.closing) throw new ChannelClosedError()
    if (this.fatalError !== undefined) throw this.fatalError
    if (this.helloDone) return
    if (this.connectPromise === undefined) {
      this.connectPromise = new Promise<void>((resolve, reject) => {
        this.connectResolve = resolve
        this.connectReject = reject
      })
      // A backoff timer already owns the next attempt; do not race it.
      if (this.socket === undefined && this.reconnectTimer === undefined) this.openSocket()
    }
    return await this.connectPromise
  }

  /**
   * Queue one frame. VFS_MUT and JOURNAL frames get a connection `seq` only when
   * the transport is usable; their application-level buffers survive reconnects.
   * @returns The assigned `seq`, or 0n when the frame is buffered for a later
   *   connection (VFS flow control or a transport interruption).
   */
  send(type: FrameType, payload: Uint8Array): bigint {
    if (this.closing) throw new ChannelClosedError()
    if (this.fatalError !== undefined) throw this.fatalError
    // Header-level validation before anything is remembered.
    if (!isFrameType(type)) throw new FrameError('BAD_PAYLOAD', `unknown frame type 0x${String(type)}`)
    // channel.md §2: a known type in the wrong direction is PROTO_MISMATCH.
    // API_REQ (0x40) in particular is host->worker only; the Worker must never
    // answer a 0x40 fallback by sending one of its own.
    if (!workerMaySend(type)) {
      throw new FrameError('PROTO_MISMATCH', `frame type 0x${type.toString(16)} is not outbound on a worker channel`)
    }
    if (payload.byteLength === 0) throw new FrameError('BAD_PAYLOAD', 'frames have no zero-length payload')
    if (payload.byteLength > MAX_FRAME_PAYLOAD) {
      throw new FrameError('BAD_PAYLOAD', `payload length ${payload.byteLength} exceeds ${MAX_FRAME_PAYLOAD}`)
    }
    switch (type) {
      case FrameType.VFS_MUT:
        return this.acceptVfsMutation(payload)
      case FrameType.JOURNAL:
        return this.acceptJournal(payload)
      default:
        this.requireTransport()
        return this.transmit(type, payload)
    }
  }

  onFrame(handler: (frame: Frame) => void): () => void {
    this.listeners.add(handler)
    return () => { this.listeners.delete(handler) }
  }

  /** Parsed host HELLO of the current connection; undefined before the first HELLO. */
  get hostHello(): HelloHostPayload | undefined {
    return this.hostHelloValue
  }

  /** Observe every host HELLO, including the fresh one after a reconnect. */
  onHostHello(handler: (hello: HelloHostPayload) => void): () => void {
    this.hostHelloListeners.add(handler)
    return () => { this.hostHelloListeners.delete(handler) }
  }

  /** Called whenever an established connection dies, before a reconnect is scheduled. */
  onTransportLost(handler: () => void): () => void {
    this.transportLostListeners.add(handler)
    return () => { this.transportLostListeners.delete(handler) }
  }

  ackedMseq(level: 1 | 2): bigint {
    return this.vfsAcks.acked(VFS_ACK_KEY, level)
  }

  nextMseq(): bigint {
    return this.nextMseqValue
  }

  /** Highest mseq this worker process has assigned (the HELLO `last_mseq`). */
  get lastMseq(): bigint {
    return this.lastMseqValue
  }

  /** Effective admission: the last LIFECYCLE and FENCE admissions and no ring timeout. */
  get admissionOpen(): boolean {
    return this.fatalError === undefined && this.lifecycleAdmission === 'open' && this.fenceAdmission === 'open'
  }

  async waitAck(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: DurabilityWaitOptions,
  ): Promise<void> {
    if (this.ackedMseq(level) >= uptoMseq) return
    const refusal = this.refusalFor(level, uptoMseq)
    if (refusal !== undefined) throw refusal
    if (this.closing) throw new ChannelClosedError()
    if (this.fatalError !== undefined) throw this.fatalError
    try {
      await this.vfsAcks.wait(VFS_ACK_KEY, level, uptoMseq, signal, options?.timeoutMs)
    } catch (error) {
      this.noteWaitFailure(error)
      throw error
    }
  }

  async barrier(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: DurabilityWaitOptions,
  ): Promise<void> {
    if (this.ackedMseq(level) >= uptoMseq) return
    const key = `${String(level)}:${String(uptoMseq)}`
    this.pendingBarriers.set(key, { level, uptoMseq })
    if (this.transportOpen && this.helloDone) {
      this.transmit(FrameType.VFS_BARRIER, encodeVfsBarrier({ wantLevel: level, uptoMseq }))
    }
    await this.waitAck(level, uptoMseq, signal, options)
  }

  request(..._args: Parameters<ChannelClient['request']>): AsyncIterable<never> {
    // channel.md §2/§3.7: API_REQ is host -> worker. A Worker-side request is a
    // protocol direction error, never a frame to put on the wire.
    throw new FrameError('PROTO_MISMATCH', 'API_REQ (0x40) is host->worker only; a Worker channel cannot send it')
  }

  /** Level-1 (or level-2) journal ack for one session, for the tool-journal bridge. */
  journalAcked(sessionId: string, level: 1 | 2): bigint {
    return this.journalAcks.acked(sessionId, level)
  }

  /** Wait until the host acknowledged journal records up to `uptoJseq`. */
  async waitJournalAck(
    level: 1 | 2,
    sessionId: string,
    uptoJseq: bigint,
    signal?: AbortSignal,
    options?: DurabilityWaitOptions,
  ): Promise<void> {
    if (this.journalAcked(sessionId, level) >= uptoJseq) return
    if (this.closing) throw new ChannelClosedError()
    if (this.fatalError !== undefined) throw this.fatalError
    try {
      await this.journalAcks.wait(sessionId, level, uptoJseq, signal, options?.timeoutMs)
    } catch (error) {
      this.noteWaitFailure(error)
      throw error
    }
  }

  async close(): Promise<void> {
    if (this.closing) return
    this.closing = true
    this.transportOpen = false
    this.helloDone = false
    this.hostHelloValue = undefined
    this.clearReconnectTimer()
    this.clearRingTimer()
    const socket = this.socket
    this.socket = undefined
    if (socket !== undefined) {
      try { socket.close(1000, 'normal closure') } catch { /* already closed */ }
    }
    const reason = new ChannelClosedError()
    this.rejectConnect(reason)
    this.vfsAcks.rejectAll(reason)
    this.journalAcks.rejectAll(reason)
  }

  // --------------------------------------------------------------- transport

  private openSocket(): void {
    if (this.closing || this.fatalError !== undefined) return
    let socket: WebSocketLike
    try {
      socket = (this.options.createSocket ?? defaultWebSocketFactory)(this.resolveUrl())
    } catch (error) {
      if (this.connectReject !== undefined) {
        this.rejectConnect(error instanceof Error ? error : new Error(String(error)))
      } else {
        this.scheduleReconnect()
      }
      return
    }
    this.socket = socket
    this.decoder = new FrameDecoder()
    socket.binaryType = 'arraybuffer'
    socket.addEventListener('open', () => { this.handleOpen(socket) })
    socket.addEventListener('message', (event) => { this.handleMessage(socket, event) })
    socket.addEventListener('error', () => { this.handleSocketLost(socket) })
    socket.addEventListener('close', () => { this.handleSocketLost(socket) })
  }

  private resolveUrl(): string {
    const raw = this.options.url
    const base = (globalThis as { location?: { href: string } }).location?.href
    const url = base === undefined ? new URL(raw) : new URL(raw, base)
    if (url.protocol === 'http:') url.protocol = 'ws:'
    else if (url.protocol === 'https:') url.protocol = 'wss:'
    if (this.options.token !== undefined && this.options.token !== '') {
      url.searchParams.set('token', this.options.token)
    }
    return url.href
  }

  private handleOpen(socket: WebSocketLike): void {
    if (socket !== this.socket || this.closing) return
    this.transportOpen = true
    this.outboundSeq = 0n
    this.inboundSeq = 0n
    this.decoder.reset()
    // D1: the worker HELLO is the first frame of the direction, seq = 1.
    this.transmit(FrameType.HELLO, this.workerHello())
  }

  private handleSocketLost(socket: WebSocketLike): void {
    if (socket !== this.socket) return
    this.socket = undefined
    this.transportOpen = false
    this.helloDone = false
    // The caps of a dead connection are not authority for the next one: the
    // fresh host HELLO replaces this before any frame of the new connection.
    this.hostHelloValue = undefined
    this.decoder.reset()
    this.clearRingTimer()
    // Items already sent on the dead connection are candidates for the resend.
    for (const mutation of this.unackedVfs.values()) {
      mutation.sent = false
      mutation.seq = undefined
    }
    this.sentVfsBytes = 0
    this.vfsQueue.length = 0
    this.notifyTransportLost()
    if (this.closing || this.fatalError !== undefined) return
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    if (this.closing || this.fatalError !== undefined || this.reconnectTimer !== undefined) return
    const shift = Math.min(this.reconnectAttempts, 8)
    const delay = Math.min(this.options.backoffMaxMs, this.options.backoffMinMs * 2 ** shift)
    this.reconnectAttempts += 1
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      this.openSocket()
    }, delay)
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== undefined) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = undefined
    }
  }

  private requireTransport(): void {
    if (!this.transportOpen || !this.helloDone || this.socket === undefined) {
      throw new ChannelReconnectError('channel is not connected; retry after the HELLO exchange')
    }
  }

  private transmit(type: FrameType, payload: Uint8Array): bigint {
    const socket = this.socket
    if (!this.transportOpen || socket === undefined) throw new ChannelReconnectError('channel transport is not open')
    const seq = this.outboundSeq + 1n
    const bytes = encodeFrame({ type, seq, payload })
    socket.send(bytes)
    this.outboundSeq = seq
    return seq
  }

  private workerHello(): Uint8Array {
    const payload = {
      proto: 1,
      role: 'worker' as const,
      boot_id: this.options.bootId,
      session_epoch: BigInt(this.options.sessionEpoch),
      fence: this.options.fence,
      caps: this.options.caps,
      last_mseq: this.lastMseqValue,
    }
    return encodeUtf8(canonicalStringify(payload))
  }

  // ------------------------------------------------------------- VFS buffers

  private acceptVfsMutation(payload: Uint8Array): bigint {
    let mutation
    try {
      mutation = decodeVfsMutation(payload)
    } catch (error) {
      throw asFrameError(error, 'BAD_PAYLOAD')
    }
    if (mutation.mseq !== this.nextMseqValue) {
      throw new FrameError('BAD_MSEQ', `next mseq is ${String(this.nextMseqValue)}, got ${String(mutation.mseq)}`)
    }
    this.nextMseqValue = mutation.mseq + 1n
    if (mutation.mseq > this.lastMseqValue) this.lastMseqValue = mutation.mseq
    // A new mutation now owns this mseq; an older refusal of that slot is
    // superseded and must not fail waits for the new mutation.
    this.refusals.delete(mutation.mseq)
    const entry: UnackedMutation = {
      payload: payload.slice(),
      bytes: payload.byteLength,
      path: mutation.path,
      sent: false,
      seq: undefined,
    }
    this.unackedVfs.set(mutation.mseq, entry)
    this.vfsQueue.push(mutation.mseq)
    this.pumpVfs()
    return entry.sent ? this.outboundSeq : 0n
  }

  private acceptJournal(payload: Uint8Array): bigint {
    let frame
    try {
      frame = decodeJournal(payload)
    } catch (error) {
      throw asFrameError(error, 'BAD_PAYLOAD')
    }
    let bySession = this.unackedJournal.get(frame.sessionId)
    if (bySession === undefined) {
      bySession = new Map()
      this.unackedJournal.set(frame.sessionId, bySession)
    }
    bySession.set(frame.jseq, payload.slice())
    if (this.transportOpen && this.helloDone) return this.transmit(FrameType.JOURNAL, payload)
    return 0n
  }

  private pumpVfs(): void {
    if (!this.transportOpen || !this.helloDone) return
    while (this.vfsQueue.length > 0) {
      const mseq = this.vfsQueue[0]!
      const entry = this.unackedVfs.get(mseq)
      if (entry === undefined) {
        this.vfsQueue.shift()
        continue
      }
      if (entry.sent) {
        this.vfsQueue.shift()
        continue
      }
      const limit = this.options.maxUnackedVfsBytes
      if (this.sentVfsBytes > 0 && this.sentVfsBytes + entry.bytes > limit) {
        this.noteWindowPressure()
        return
      }
      this.vfsQueue.shift()
      entry.sent = true
      this.sentVfsBytes += entry.bytes
      entry.seq = this.transmit(FrameType.VFS_MUT, entry.payload)
    }
  }

  private noteWindowPressure(): void {
    if (this.ringTimer !== undefined) return
    if (!this.transportOpen || !this.helloDone) return
    if (this.vfsQueue.length === 0) return
    this.ringTimer = setTimeout(() => {
      this.ringTimer = undefined
      this.ringTimeout()
    }, this.options.ringTimeoutMs)
  }

  private clearRingTimer(): void {
    if (this.ringTimer !== undefined) {
      clearTimeout(this.ringTimer)
      this.ringTimer = undefined
    }
  }

  private ringTimeout(): void {
    if (this.closing || this.fatalError !== undefined) return
    this.fenceAdmission = 'closed'
    this.fatalError = new ChannelPeerError('RING_TIMEOUT', 'no level-1 acks with a full VFS window')
    const payload = encodeUtf8(canonicalStringify({
      code: 'RING_TIMEOUT',
      message: `no level-1 ack progress for ${String(this.options.ringTimeoutMs)} ms within the 32 MiB VFS window`,
    }))
    try {
      this.transmit(FrameType.ERROR, payload)
    } catch {
      // The transport is already gone; the local failure below is what matters.
    }
    const socket = this.socket
    if (socket !== undefined) {
      try { socket.close(1011, 'ring timeout') } catch { /* already closed */ }
    }
    this.socket = undefined
    this.transportOpen = false
    this.helloDone = false
    this.clearReconnectTimer()
    this.notifyTransportLost()
    this.vfsAcks.rejectAll(this.fatalError)
    this.journalAcks.rejectAll(this.fatalError)
    this.rejectConnect(this.fatalError)
  }

  // ------------------------------------------------------------ ack timeouts

  /**
   * A bounded durability wait expired. The ack was lost on a transport that
   * still looks open; the only safe recovery is loud: tell the host with an
   * ERROR, recycle the connection and let the D2/D3 replay re-send every
   * unacked JOURNAL/VFS_MUT with its original jseq/mseq. The waiters reject so
   * the tool-journal chain and the VFS flush fail instead of hanging.
   */
  private noteWaitFailure(error: unknown): void {
    if (!(error instanceof AckTimeoutError)) return
    if (this.closing || this.durabilityFailure !== undefined) return
    this.durabilityFailure = error
    console.error('ws channel: durability ack wait timed out; restarting the connection', error)
    const payload = encodeUtf8(canonicalStringify({
      code: 'RING_TIMEOUT',
      message: `durability ack timeout: ${error.message}`,
    }))
    try {
      this.transmit(FrameType.ERROR, payload)
    } catch {
      // The transport is already gone; the close below still fires rejectAll.
    }
    const socket = this.socket
    // Clear the socket before closing so handleSocketLost() does not run the
    // regular loss path twice; this path already resets and schedules.
    this.socket = undefined
    this.transportOpen = false
    this.helloDone = false
    this.hostHelloValue = undefined
    this.decoder.reset()
    this.clearRingTimer()
    this.clearReconnectTimer()
    for (const mutation of this.unackedVfs.values()) {
      mutation.sent = false
      mutation.seq = undefined
    }
    this.sentVfsBytes = 0
    this.vfsQueue.length = 0
    if (socket !== undefined) {
      try { socket.close(1011, 'durability ack timeout') } catch { /* already closed */ }
    }
    this.notifyTransportLost()
    this.vfsAcks.rejectAll(error)
    this.journalAcks.rejectAll(error)
    this.scheduleReconnect()
  }

  // ---------------------------------------------------------------- inbound

  private handleMessage(socket: WebSocketLike, event: unknown): void {
    if (socket !== this.socket) return
    const data = (event as { data?: unknown }).data
    if (typeof data === 'string') {
      this.protocolFailure('BAD_PAYLOAD', 'text WebSocket messages are a protocol error')
      return
    }
    if (data instanceof ArrayBuffer) {
      this.acceptBytes(new Uint8Array(data))
      return
    }
    if (ArrayBuffer.isView(data)) {
      this.acceptBytes(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
      return
    }
    if (typeof Blob !== 'undefined' && data instanceof Blob) {
      void data.arrayBuffer().then(
        (buffer) => { this.acceptBytes(new Uint8Array(buffer)) },
        () => { this.protocolFailure('BAD_PAYLOAD', 'binary WebSocket message could not be read') },
      )
      return
    }
    this.protocolFailure('BAD_PAYLOAD', 'unexpected WebSocket message payload')
  }

  private acceptBytes(bytes: Uint8Array): void {
    let frames: Frame[]
    try {
      frames = this.decoder.push(bytes)
    } catch (error) {
      const failure = asFrameError(error, 'BAD_PAYLOAD')
      this.protocolFailure(failure.code, failure.message, failure.refSeq)
      return
    }
    for (const frame of frames) this.acceptFrame(frame)
  }

  private acceptFrame(frame: Frame): void {
    if (this.closing || this.fatalError !== undefined) return
    if (frame.seq !== this.inboundSeq + 1n) {
      this.protocolFailure('BAD_SEQ', `expected seq ${String(this.inboundSeq + 1n)}, got ${String(frame.seq)}`, frame.seq)
      return
    }
    this.inboundSeq = frame.seq
    const first = this.helloDone === false && this.inboundSeq === 1n
    if (frame.type === FrameType.HELLO) {
      this.acceptHello(frame, first)
      return
    }
    if (first || !this.helloDone) {
      this.protocolFailure('PROTO_MISMATCH', 'the first inbound frame must be HELLO', frame.seq)
      return
    }
    try {
      this.acceptNonHello(frame)
    } catch (error) {
      const failure = asFrameError(error, 'BAD_PAYLOAD')
      this.protocolFailure(failure.code, failure.message, frame.seq)
      return
    }
    this.notify(frame)
  }

  private acceptHello(frame: Frame, first: boolean): void {
    if (!first || this.helloDone) {
      this.protocolFailure('PROTO_MISMATCH', 'duplicate HELLO', frame.seq)
      return
    }
    let hello
    try {
      hello = parseHostHello(frame.payload)
    } catch (error) {
      const failure = asFrameError(error, 'BAD_PAYLOAD')
      this.protocolFailure(failure.code, failure.message, frame.seq)
      return
    }
    this.helloDone = true
    this.reconnectAttempts = 0
    this.clearReconnectTimer()
    // A fresh connection start: a previous ack-timeout failure no longer
    // owns the transport, and the unacked buffers below are replayed.
    this.durabilityFailure = undefined
    this.hostHelloValue = hello
    this.vfsAcks.resolve(VFS_ACK_KEY, 1, hello.acked_mseq)
    this.vfsAcks.resolve(VFS_ACK_KEY, 2, hello.durable_mseq)
    for (const mseq of [...this.unackedVfs.keys()]) {
      if (mseq <= hello.acked_mseq) this.unackedVfs.delete(mseq)
    }
    for (const refusedMseq of [...this.refusals.keys()]) {
      if (refusedMseq <= hello.acked_mseq) this.refusals.delete(refusedMseq)
    }
    this.nextMseqValue = maxBigInt(this.nextMseqValue, hello.next_mseq)
    this.resendAfterHello(hello.acked_mseq)
    // A waitAck()/barrier() that spans the reconnect may already be satisfied by
    // the tail the host reports in HELLO; resolve it instead of waiting for an
    // ack that will never come because nothing new is sent.
    this.pruneSatisfiedBarriers()
    this.resolveConnect()
    this.notifyHostHello(hello)
    this.notify(frame)
  }

  private acceptNonHello(frame: Frame): void {
    switch (frame.type) {
      case FrameType.VFS_ACK: {
        const ack = decodeVfsAck(frame.payload)
        this.acceptVfsAck(ack.level, ack.uptoMseq)
        return
      }
      case FrameType.JOURNAL_ACK: {
        const ack = decodeJournalAck(frame.payload)
        this.acceptJournalAck(ack.level, ack.sessionId, ack.uptoJseq)
        return
      }
      case FrameType.API_RES:
      case FrameType.API_END:
        // 0x41/0x42 are worker -> host; receiving one on a Worker client means
        // the peer or the direction table is wrong.
        throw new FrameError('PROTO_MISMATCH', `frame type 0x${frame.type.toString(16)} is not inbound on a worker channel`)
      case FrameType.API_ABORT:
        // API_ABORT is bidirectional and idempotent. The Worker has no pending
        // API_REQ of its own, so a syntactically valid abort has no local target.
        decodeApiAbort(frame.payload)
        return
      case FrameType.LIFECYCLE:
        this.acceptLifecycle(frame.payload)
        return
      case FrameType.FENCE:
        this.acceptFence(frame.payload)
        return
      case FrameType.VFS_RESYNC:
        decodeVfsResync(frame.payload)
        return
      case FrameType.ERROR:
        this.acceptError(frame)
        return
      case FrameType.API_REQ:
      case FrameType.EXEC_EVT:
        return
      default:
        throw new FrameError('PROTO_MISMATCH', `frame type 0x${frame.type.toString(16)} is not inbound on a worker channel`)
    }
  }

  private acceptVfsAck(level: 1 | 2, uptoMseq: bigint): void {
    if (level !== 1 && level !== 2) throw new FrameError('BAD_PAYLOAD', 'VFS_ACK level must be 1 or 2')
    if (!this.vfsAcks.resolve(VFS_ACK_KEY, level, uptoMseq)) return
    for (const [mseq, mutation] of [...this.unackedVfs]) {
      if (mseq <= this.ackedMseq(1)) {
        if (mutation.sent) this.sentVfsBytes -= mutation.bytes
        this.unackedVfs.delete(mseq)
      }
    }
    this.clearRingTimer()
    this.pruneSatisfiedBarriers()
    for (const refusedMseq of [...this.refusals.keys()]) {
      if (refusedMseq <= this.ackedMseq(1)) this.refusals.delete(refusedMseq)
    }
    this.pumpVfs()
  }

  private acceptJournalAck(level: 1 | 2, sessionId: string, uptoJseq: bigint): void {
    if (level !== 1 && level !== 2) throw new FrameError('BAD_PAYLOAD', 'JOURNAL_ACK level must be 1 or 2')
    this.journalAcks.resolve(sessionId, level, uptoJseq)
    const bySession = this.unackedJournal.get(sessionId)
    if (bySession !== undefined) {
      const upto = this.journalAcked(sessionId, 1)
      for (const jseq of [...bySession.keys()]) {
        if (jseq <= upto) bySession.delete(jseq)
      }
      if (bySession.size === 0) this.unackedJournal.delete(sessionId)
    }
  }

  private acceptLifecycle(payload: Uint8Array): void {
    const value = parseJsonObject(payload, 'LIFECYCLE')
    const state = value['state']
    const budget = value['budget']
    const admission = value['admission']
    const reason = value['reason']
    if (state !== 'run' && state !== 'pause' && state !== 'stop') {
      throw new FrameError('BAD_PAYLOAD', 'LIFECYCLE state must be run, pause or stop')
    }
    if (typeof budget !== 'number' || !Number.isSafeInteger(budget) || budget < 0) {
      throw new FrameError('BAD_PAYLOAD', 'LIFECYCLE budget must be a non-negative integer')
    }
    if (admission !== 'open' && admission !== 'closed') {
      throw new FrameError('BAD_PAYLOAD', 'LIFECYCLE admission must be open or closed')
    }
    if (typeof reason !== 'string') throw new FrameError('BAD_PAYLOAD', 'LIFECYCLE reason must be a string')
    this.lifecycleAdmission = admission
    const parsed: LifecyclePayload = { state, budget: BigInt(budget), admission, reason }
    if (this.lifecycleListener !== undefined) this.lifecycleListener(parsed)
  }

  private acceptFence(payload: Uint8Array): void {
    const value = parseJsonObject(payload, 'FENCE')
    const fence = value['fence']
    const admission = value['admission']
    if (admission !== 'open' && admission !== 'closed') {
      throw new FrameError('BAD_PAYLOAD', 'FENCE admission must be open or closed')
    }
    const parsedFence = parseFence(fence, 'FENCE fence')
    this.fenceAdmission = admission
    const parsed: FencePayload = { fence: parsedFence, admission }
    if (this.fenceListener !== undefined) this.fenceListener(parsed)
  }

  private acceptError(frame: Frame): void {
    let value: Record<string, unknown> = {}
    try {
      value = parseJsonObject(frame.payload, 'ERROR')
    } catch {
      // The ERROR payload itself is malformed; the generic fatal path below
      // still reports BAD_PAYLOAD and closes.
    }
    if (value['code'] === 'VFS_REFUSED') {
      let diagnostic: VfsRefusedDiagnostic
      try {
        diagnostic = parseVfsRefusedDiagnostic(value) as VfsRefusedDiagnostic
      } catch (error) {
        const failure = asFrameError(error, 'BAD_PAYLOAD')
        this.protocolFailure(failure.code, failure.message, frame.seq)
        return
      }
      this.acceptVfsRefused(diagnostic)
      return
    }
    let code: FrameErrorCode | 'RING_TIMEOUT' = 'BAD_PAYLOAD'
    let message = 'peer reported an error'
    if (typeof value['code'] === 'string') code = value['code'] as FrameErrorCode
    if (typeof value['message'] === 'string') message = value['message']
    this.failPeer(new ChannelPeerError(code, message))
  }

  /**
   * Consume one host `ERROR VFS_REFUSED` (channel.md §4.8, §8, §10).
   *
   * A resource refusal is a diagnostic, not a protocol error: the connection
   * stays open, nothing is retried on this connection, and the mseq is not
   * consumed. The refused mutation (and any mutation pipelined after it) is
   * removed from the unacked buffer; later mutations are renumbered into the
   * freed slot so the Worker's buffer stays exactly contiguous from the host's
   * unchanged `expected_mseq`. Waiters on the unreachable range reject with the
   * structured refusal, which the sink turns into the same `VfsRefusalError` a
   * local `EFBIG` produces.
   */
  private acceptVfsRefused(diagnostic: VfsRefusedDiagnostic): void {
    const failure = new VfsRefusedError(diagnostic)
    const refusedMseq = diagnostic.mseq ?? this.locateRefusedMseq(diagnostic)
    if (refusedMseq === undefined) {
      // Nothing local owns this diagnostic (duplicate, or a refusal the host
      // sent for state this client no longer has). It is still not fatal.
      console.warn('ws channel: VFS_REFUSED did not name a pending mutation', diagnostic.path)
      return
    }
    if (refusedMseq < 1n || refusedMseq >= this.nextMseqValue) {
      // A refusal can only name a mutation this worker already assigned.
      console.warn(`ws channel: VFS_REFUSED names unassigned mseq ${String(refusedMseq)}`)
      return
    }
    if (refusedMseq <= this.ackedMseq(1)) {
      // The host already acknowledged past it; this is a stale diagnostic.
      return
    }
    const hadRefusedMutation = this.releaseRefusedMutation(refusedMseq)
    if (hadRefusedMutation) {
      // New mutations occupy the freed slot; a stale refusal there would fail
      // their waits. Only keep it while the slot stays free.
      if (!this.unackedVfs.has(refusedMseq)) this.refusals.set(refusedMseq, failure)
      this.vfsAcks.rejectFrom(VFS_ACK_KEY, 1, refusedMseq, failure)
      this.vfsAcks.rejectFrom(VFS_ACK_KEY, 2, refusedMseq, failure)
      for (const [key, barrier] of [...this.pendingBarriers]) {
        if (barrier.uptoMseq >= refusedMseq) this.pendingBarriers.delete(key)
      }
    }
    this.clearRingTimer()
    this.pumpVfs()
  }

  /** Identify the refused mutation by `ref_seq`, else path, when `mseq` is absent. */
  private locateRefusedMseq(diagnostic: VfsRefusedDiagnostic): bigint | undefined {
    if (diagnostic.refSeq !== undefined) {
      for (const [mseq, entry] of this.unackedVfs) {
        if (entry.seq === diagnostic.refSeq) return mseq
      }
    }
    let found: bigint | undefined
    for (const [mseq, entry] of this.unackedVfs) {
      if (entry.path !== diagnostic.path) continue
      if (found === undefined || mseq < found) found = mseq
    }
    return found
  }

  /**
   * Remove the refused mutation and renumber every later unacked mutation into
   * the freed mseq slots, re-encoding its leading mseq and re-sending it if it
   * had already been transmitted. The host left `expected_mseq` unchanged, so
   * the Worker's next buffer slot must be the refused mseq again.
   * @returns whether the refused mseq owned a local mutation.
   */
  private releaseRefusedMutation(refusedMseq: bigint): boolean {
    const refused = this.unackedVfs.get(refusedMseq)
    if (refused === undefined) return false
    if (refused.sent) this.sentVfsBytes -= refused.bytes
    this.unackedVfs.delete(refusedMseq)
    const later = [...this.unackedVfs.entries()]
      .filter(([mseq]) => mseq > refusedMseq)
      .sort(([left], [right]) => compareBigInt(left, right))
    for (const [oldMseq, entry] of later) {
      this.unackedVfs.delete(oldMseq)
      if (entry.sent) this.sentVfsBytes -= entry.bytes
      const newMseq = oldMseq - 1n
      const payload = entry.payload.slice()
      writeU64be(payload, 0, newMseq)
      entry.payload = payload
      entry.sent = false
      entry.seq = undefined
      this.unackedVfs.set(newMseq, entry)
      this.refusals.delete(newMseq)
    }
    this.nextMseqValue = refusedMseq + BigInt(later.length)
    this.vfsQueue.length = 0
    for (const [mseq, entry] of [...this.unackedVfs.entries()].sort(([left], [right]) => compareBigInt(left, right))) {
      if (!entry.sent) this.vfsQueue.push(mseq)
    }
    return true
  }

  /** The structured refusal covering a wait target, if the range is unreachable. */
  private refusalFor(level: 1 | 2, uptoMseq: bigint): VfsRefusedError | undefined {
    let found: VfsRefusedError | undefined
    for (const [refusedMseq, failure] of this.refusals) {
      if (refusedMseq > uptoMseq) continue
      if (refusedMseq <= this.ackedMseq(level)) continue
      if (found === undefined) found = failure
    }
    return found
  }

  /** Close on a peer-sent protocol ERROR; the connection is not retried. */
  private failPeer(failure: ChannelPeerError): void {
    this.fatalError = failure
    const socket = this.socket
    this.transportOpen = false
    this.helloDone = false
    this.socket = undefined
    this.clearReconnectTimer()
    this.clearRingTimer()
    if (socket !== undefined) {
      try { socket.close(1002, 'peer error') } catch { /* already closed */ }
    }
    this.notifyTransportLost()
    this.rejectConnect(failure)
    this.vfsAcks.rejectAll(failure)
    this.journalAcks.rejectAll(failure)
  }

  private protocolFailure(code: FrameErrorCode, message: string, refSeq?: bigint): void {
    if (this.fatalError !== undefined) return
    const failure = new ChannelPeerError(code, message)
    this.fatalError = failure
    const payload = encodeUtf8(canonicalStringify(
      refSeq === undefined ? { code, message } : { code, message, ref_seq: refSeq },
    ))
    try {
      this.transmit(FrameType.ERROR, payload)
    } catch {
      // The connection is already gone.
    }
    const socket = this.socket
    this.socket = undefined
    this.transportOpen = false
    this.helloDone = false
    this.clearReconnectTimer()
    this.clearRingTimer()
    if (socket !== undefined) {
      try { socket.close(1002, 'protocol error') } catch { /* already closed */ }
    }
    this.notifyTransportLost()
    this.rejectConnect(failure)
    this.vfsAcks.rejectAll(failure)
    this.journalAcks.rejectAll(failure)
  }

  // -------------------------------------------------------------- resending

  private resendAfterHello(hostAckedMseq: bigint): void {
    this.vfsQueue.length = 0
    this.sentVfsBytes = 0
    for (const mutation of this.unackedVfs.values()) {
      mutation.sent = false
      mutation.seq = undefined
    }
    for (const mseq of [...this.unackedVfs.keys()].sort(compareBigInt)) {
      if (mseq <= hostAckedMseq || mseq <= this.ackedMseq(1)) continue
      this.vfsQueue.push(mseq)
    }
    this.pumpVfs()
    for (const barrier of this.pendingBarriers.values()) {
      if (this.ackedMseq(barrier.level) >= barrier.uptoMseq) continue
      this.transmit(FrameType.VFS_BARRIER, encodeVfsBarrier({ wantLevel: barrier.level, uptoMseq: barrier.uptoMseq }))
    }
    // Journal records are deduplicated by (session_id, jseq) on the host, so a
    // reconnect re-sends every record not yet acknowledged at level 1.
    for (const [sessionId, bySession] of this.unackedJournal) {
      for (const jseq of [...bySession.keys()].sort(compareBigInt)) {
        const payload = bySession.get(jseq)
        if (payload !== undefined) this.transmit(FrameType.JOURNAL, payload)
      }
    }
  }

  // --------------------------------------------------------------- listeners

  private lifecycleListener: ((payload: LifecyclePayload) => void) | undefined
  private fenceListener: ((payload: FencePayload) => void) | undefined

  /** Observe validated LIFECYCLE payloads (in addition to `onFrame`). */
  onLifecycle(listener: ((payload: LifecyclePayload) => void) | undefined): () => void {
    this.lifecycleListener = listener
    return () => { if (this.lifecycleListener === listener) this.lifecycleListener = undefined }
  }

  /** Observe validated FENCE payloads (in addition to `onFrame`). */
  onFence(listener: ((payload: FencePayload) => void) | undefined): () => void {
    this.fenceListener = listener
    return () => { if (this.fenceListener === listener) this.fenceListener = undefined }
  }

  private notify(frame: Frame): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(frame)
      } catch (error) {
        console.error('ws channel: onFrame handler failed', error)
      }
    }
  }

  private notifyHostHello(hello: HelloHostPayload): void {
    for (const listener of [...this.hostHelloListeners]) {
      try {
        listener(hello)
      } catch (error) {
        console.error('ws channel: onHostHello handler failed', error)
      }
    }
  }

  private resolveConnect(): void {
    const resolve = this.connectResolve
    this.connectResolve = undefined
    this.connectReject = undefined
    this.connectPromise = undefined
    resolve?.()
  }

  private rejectConnect(reason: unknown): void {
    const reject = this.connectReject
    this.connectResolve = undefined
    this.connectReject = undefined
    this.connectPromise = undefined
    reject?.(reason)
  }

  private pruneSatisfiedBarriers(): void {
    for (const [key, barrier] of [...this.pendingBarriers]) {
      if (this.ackedMseq(barrier.level) >= barrier.uptoMseq) this.pendingBarriers.delete(key)
    }
  }

  private notifyTransportLost(): void {
    for (const listener of [...this.transportLostListeners]) {
      try {
        listener()
      } catch (error) {
        console.error('ws channel: transport-lost handler failed', error)
      }
    }
  }
}

function defaultWebSocketFactory(url: string): WebSocketLike {
  const Constructor = (globalThis as { WebSocket?: new (url: string) => unknown }).WebSocket
  if (Constructor === undefined) throw new Error('WebSocketChannelClient: no global WebSocket; pass createSocket')
  return new Constructor(url) as WebSocketLike
}

function asFrameError(error: unknown, fallback: FrameErrorCode): FrameError {
  if (error instanceof FrameError) return error
  return new FrameError(fallback, error instanceof Error ? error.message : String(error))
}

function maxBigInt(left: bigint, right: bigint): bigint {
  return left > right ? left : right
}

function compareBigInt(left: bigint, right: bigint): number {
  return left < right ? -1 : left > right ? 1 : 0
}

function parseJsonObject(payload: Uint8Array, what: string): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(decodeUtf8(payload)) as unknown
  } catch {
    throw new FrameError('BAD_PAYLOAD', `${what} payload is not valid UTF-8 JSON`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new FrameError('BAD_PAYLOAD', `${what} payload must be a JSON object`)
  }
  return parsed as Record<string, unknown>
}

function requireU64Integer(value: unknown, what: string): bigint {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new FrameError('BAD_PAYLOAD', `${what} must be a non-negative integer`)
  }
  return BigInt(value)
}

function parseFence(value: unknown, what: string): Fence {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new FrameError('BAD_PAYLOAD', `${what} must be an object`)
  }
  const record = value as Record<string, unknown>
  const owner = record['owner']
  if (!isValidFenceOwner(owner)) throw new FrameError('BAD_PAYLOAD', `${what}.owner is invalid`)
  return {
    owner,
    generation: requireU64Integer(record['generation'], `${what}.generation`),
    wal_seq: requireU64Integer(record['wal_seq'], `${what}.wal_seq`),
  }
}
