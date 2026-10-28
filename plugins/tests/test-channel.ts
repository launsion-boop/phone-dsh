// SPDX-License-Identifier: MIT
/** Deterministic {@link ChannelClient} test double for the Worker plugins. */
import { AckTracker, VFS_ACK_KEY, makeHostHello } from '@phone-dsh/dsh-channel'
import type { ApiResponseChunk, ChannelClient, HelloHostPayload } from '@phone-dsh/dsh-channel'
import { canonicalStringify } from '@phone-dsh/dsh-channel/canonical-json'
import { encodeUtf8 } from '@phone-dsh/dsh-channel/bytes'
import { FrameType, type Frame } from '@phone-dsh/dsh-channel/frames'
import { decodeJournal } from '@phone-dsh/dsh-channel/vfs-mutation'

export interface SentFrame {
  readonly type: FrameType
  readonly payload: Uint8Array
  readonly seq: bigint
}

/** Options for {@link MockChannel}. */
export interface MockChannelOptions {
  /** Host HELLO caps the channel client exposes as `hostHello.caps`. */
  readonly caps?: readonly string[]
  /** Next mseq the sink would assign; `nextMseq() - 1` is the last emitted. */
  readonly nextMseq?: bigint
  /** Highest mseq the mock treats as acknowledged; defaults to 0. */
  readonly ackedMseq?: bigint
  /** Auto-ack JOURNAL frames at this level, or `manual` for tests that emit 0x31. */
  readonly journalAck?: 1 | 2 | 'manual'
  /** Bound for a durability wait; defaults to the validated 30 s window. */
  readonly ackTimeoutMs?: number
}

export class MockChannel implements ChannelClient {
  readonly sent: SentFrame[] = []
  readonly barrierCalls: Array<{ level: 1 | 2; uptoMseq: bigint }> = []
  hostHello: HelloHostPayload | undefined
  nextM: bigint
  private readonly listeners = new Set<(frame: Frame) => void>()
  private readonly hostHelloListeners = new Set<(hello: HelloHostPayload) => void>()
  private readonly vfsAcks: AckTracker
  private readonly journalAcks: AckTracker
  private readonly journalAck: 1 | 2 | 'manual'
  private outSeq = 0n
  private inSeq = 0n
  private closed = false

  constructor(options: MockChannelOptions = {}) {
    this.nextM = options.nextMseq ?? 1n
    this.journalAck = options.journalAck ?? 1
    this.vfsAcks = new AckTracker({ timeoutMs: options.ackTimeoutMs })
    this.journalAcks = new AckTracker({ timeoutMs: options.ackTimeoutMs })
    this.vfsAcks.resolve(VFS_ACK_KEY, 1, options.ackedMseq ?? 0n)
    if (options.caps !== undefined) {
      this.hostHello = makeHostHello({
        caps: options.caps,
        ackedMseq: options.ackedMseq ?? 0n,
        nextMseq: options.nextMseq ?? 1n,
      })
    }
  }

  connect(): Promise<void> { return Promise.resolve() }

  send(type: FrameType, payload: Uint8Array): bigint {
    this.outSeq += 1n
    this.sent.push({ type, payload, seq: this.outSeq })
    if (type === FrameType.JOURNAL && this.journalAck !== 'manual') {
      const decoded = decodeJournal(payload)
      queueMicrotask(() => { this.emitJournalAck(this.journalAck as 1 | 2, decoded.sessionId, decoded.jseq) })
    }
    return this.outSeq
  }

  onFrame(handler: (frame: Frame) => void): () => void {
    this.listeners.add(handler)
    return () => { this.listeners.delete(handler) }
  }

  onHostHello(handler: (hello: HelloHostPayload) => void): () => void {
    this.hostHelloListeners.add(handler)
    return () => { this.hostHelloListeners.delete(handler) }
  }

  /** Replace the host HELLO and notify observers (simulates a reconnect HELLO). */
  setHostHello(hello: HelloHostPayload | undefined): void {
    this.hostHello = hello
    if (hello === undefined) return
    for (const listener of [...this.hostHelloListeners]) listener(hello)
  }

  ackedMseq(level: 1 | 2): bigint {
    return this.vfsAcks.acked(VFS_ACK_KEY, level)
  }

  waitAck(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    return this.vfsAcks.wait(VFS_ACK_KEY, level, uptoMseq, signal, options?.timeoutMs)
  }

  journalAcked(sessionId: string, level: 1 | 2): bigint {
    return this.journalAcks.acked(sessionId, level)
  }

  waitJournalAck(
    level: 1 | 2,
    sessionId: string,
    uptoJseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    return this.journalAcks.wait(sessionId, level, uptoJseq, signal, options?.timeoutMs)
  }

  async barrier(
    level: 1 | 2,
    uptoMseq: bigint,
    signal?: AbortSignal,
    options?: { readonly timeoutMs?: number },
  ): Promise<void> {
    this.barrierCalls.push({ level, uptoMseq })
    this.acked(level, uptoMseq)
    await this.waitAck(level, uptoMseq, signal, options)
  }

  nextMseq(): bigint { return this.nextM }

  request(..._args: Parameters<ChannelClient['request']>): AsyncIterable<never> {
    throw new Error('MockChannel has no API request route')
  }

  async close(): Promise<void> {
    this.closed = true
    this.listeners.clear()
    const reason = new Error('MockChannel closed')
    this.vfsAcks.rejectAll(reason)
    this.journalAcks.rejectAll(reason)
  }

  /** Assign the next sink mseq (i.e. advance the last-emitted revision). */
  setNextMseq(value: bigint): void {
    this.nextM = value
  }

  /** Emit one inbound frame to every listener. */
  emit(type: FrameType, payload: Uint8Array): void {
    if (this.closed) return
    this.inSeq += 1n
    const frame: Frame = { type, seq: this.inSeq, payload }
    for (const listener of [...this.listeners]) listener(frame)
  }

  /** Emit one EXEC_EVT event object for an execution. */
  execEvent(event: Record<string, unknown>): void {
    this.emit(FrameType.EXEC_EVT, encodeUtf8(canonicalStringify(event)))
  }

  /** Emit one JOURNAL_ACK (0x31) for a session; tests use it for manual acks. */
  emitJournalAck(level: 1 | 2, sessionId: string, jseq: bigint): void {
    const session = encodeUtf8(sessionId)
    const payload = new Uint8Array(3 + session.byteLength + 8)
    payload[0] = level
    payload[1] = (session.byteLength >> 8) & 0xff
    payload[2] = session.byteLength & 0xff
    payload.set(session, 3)
    let value = jseq
    for (let index = payload.byteLength - 1; index >= 3 + session.byteLength; index--) {
      payload[index] = Number(value & 0xffn)
      value >>= 8n
    }
    this.emit(FrameType.JOURNAL_ACK, payload)
    this.journalAcks.resolve(sessionId, level, jseq)
  }

  /** Emit a channel ERROR frame. */
  fatal(code: string, message: string): void {
    this.emit(FrameType.ERROR, encodeUtf8(JSON.stringify({ code, message })))
  }

  /** Frames of one type, in send order. */
  framesOf(type: FrameType): SentFrame[] {
    return this.sent.filter(frame => frame.type === type)
  }

  private acked(level: 1 | 2, uptoMseq: bigint): void {
    this.vfsAcks.resolve(VFS_ACK_KEY, level, uptoMseq)
  }
}

/** Decode a UTF-8 JSON frame payload. */
export function jsonPayload(frame: SentFrame): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(frame.payload)) as Record<string, unknown>
}

/** Wait for a condition on a later microtask/timer, bounded. */
export async function eventually(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('condition was not reached in time')
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}
