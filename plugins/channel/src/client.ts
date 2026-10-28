// SPDX-License-Identifier: MIT
/**
 * The transport-independent channel face the worker entry and the test doubles
 * implement. It mirrors the ordered channel of channel.md: one connection, one
 * seq space per direction, one mseq space owned by the host.
 * @module @phone-dsh/dsh-channel/client
 */
import type { ApiRequestHead, ApiResponseHead, HelloHostPayload } from './payloads.ts'
import type { Frame, FrameType } from './frames.ts'

/** Which end of the channel a client is. */
export type ChannelRole = 'host' | 'worker'

/** One API_RES chunk delivered to {@link ChannelClient.request}. */
export interface ApiResponseChunk {
  /** Present on the first chunk only. */
  readonly head?: ApiResponseHead
  readonly body: Uint8Array
}

/**
 * Optional bound for one durability wait. Omitted means the client's own
 * validated window ({@link DEFAULT_DURABILITY_ACK_TIMEOUT_MS}); a call site
 * passes an explicit value only for tests or a deployment budget.
 */
export interface DurabilityWaitOptions {
  readonly timeoutMs?: number
}

/**
 * Client face of the ordered channel.
 *
 * `connect` establishes the WebSocket (or, in tests, the memory link). `send`
 * assigns and returns the next outbound `seq`; VFS mutations additionally
 * consume the next host-allocated `mseq`, which the caller reads with
 * `nextMseq` before encoding the payload.
 *
 * `hostHello` is the host's parsed HELLO of the current connection (D12 routes
 * accelerators from its `caps`); it is undefined before the first HELLO and is
 * replaced after every reconnect. `onHostHello` observes those replacements.
 * The 0x31 journal acknowledgement is tracked here too, so exec-bridge and
 * tool-journal share one tracker instead of decoding acks themselves.
 */
export interface ChannelClient {
  connect(): Promise<void>
  send(type: FrameType, payload: Uint8Array): bigint
  onFrame(handler: (frame: Frame) => void): () => void
  /** Parsed host HELLO of the current connection; refreshed on every reconnect. */
  readonly hostHello: HelloHostPayload | undefined
  /** Called on every host HELLO, including the fresh HELLO after a reconnect. */
  onHostHello(handler: (hello: HelloHostPayload) => void): () => void
  ackedMseq(level: 1 | 2): bigint
  /**
   * Wait for the cumulative VFS ack. Every wait is bounded: on expiry the
   * implementation fails loud (ERROR + close) and rejects instead of parking
   * the caller forever.
   */
  waitAck(level: 1 | 2, uptoMseq: bigint, signal?: AbortSignal, options?: DurabilityWaitOptions): Promise<void>
  barrier(level: 1 | 2, uptoMseq: bigint, signal?: AbortSignal, options?: DurabilityWaitOptions): Promise<void>
  nextMseq(): bigint
  /** Highest level-1/2 acknowledged journal `jseq` for one session. */
  journalAcked(sessionId: string, level: 1 | 2): bigint
  /** Wait until the host acknowledged journal records up to `uptoJseq` (bounded). */
  waitJournalAck(
    level: 1 | 2,
    sessionId: string,
    uptoJseq: bigint,
    signal?: AbortSignal,
    options?: DurabilityWaitOptions,
  ): Promise<void>
  /**
   * Host role only: send one API_REQ and stream the worker's response. A
   * Worker-side client throws `PROTO_MISMATCH`: 0x40 is host → worker.
   */
  request(head: ApiRequestHead, body: Uint8Array | ReadableStream<Uint8Array>): AsyncIterable<ApiResponseChunk>
  close(): Promise<void>
}

/** Worker-side unacknowledged VFS_MUT payload limit (D3, 32 MiB). */
export const MAX_UNACKED_VFS_BYTES = 32 * 1024 * 1024
/** How long the worker waits for level-1 ack progress before RING_TIMEOUT (30 s). */
export const RING_TIMEOUT_MS = 30_000
