// SPDX-License-Identifier: MIT
/**
 * Bounded standard-input delivery for the WASI toolbox.
 *
 * A WASI program's fd 0 is a byte stream that must be complete before the
 * synchronous preview1 host starts: `fd_read` returns bytes and only reports
 * EOF once every delivered byte was consumed. The DSH worker therefore owns
 * the stdin write as an explicit step of the dispatch:
 *
 *  1. the script/pipe bytes are split into frames no larger than
 *     {@link STDIN_CHUNK_BYTES} so one `postMessage` never has to clone an
 *     unbounded buffer;
 *  2. the last frame carries `eof: true`; the tool worker assembles the frames
 *     and refuses to start the interpreter without that EOF marker
 *     (`E_STDIN_INCOMPLETE`), so a truncated delivery fails loud instead of
 *     being read as an empty script;
 *  3. {@link MAX_STDIN_BYTES} is a hard bound above the D4 file limit: a
 *     caller that hands the toolbox more than one maximum-size frame is
 *     refused before dispatch (`E_STDIN_OVERSIZE`), never silently truncated.
 *
 * The host-side watchdog in `toolbox.ts` uses the same protocol to observe the
 * interpreter's first `fd_read(0)` (`stdin-read`), which is the only way to
 * tell "the interpreter is running the script" apart from "the dispatch is
 * wedged and nothing will ever consume stdin".
 * @module @phone-dsh/dsh-wasi-toolbox/stdin-delivery
 */

/** One MiB per stdin frame; bounded structured-clone cost per message. */
export const STDIN_CHUNK_BYTES = 1024 * 1024

/**
 * Largest stdin payload the toolbox accepts (16 MiB, one channel frame).
 *
 * The shell script itself is far smaller in practice; the bound exists so a
 * caller cannot make the Worker clone unbounded bytes and so an oversized
 * delivery fails fast with a structured code instead of stalling the lane.
 */
export const MAX_STDIN_BYTES = 16 * 1024 * 1024

/** Structured failure codes of the stdin/exec dispatch. */
export type StdinFailureCode =
  | 'E_STDIN_OVERSIZE'
  | 'E_STDIN_SEQUENCE'
  | 'E_STDIN_INCOMPLETE'
  | 'E_STDIN_UNEXPECTED'
  | 'E_EXEC_START_TIMEOUT'
  | 'E_STDIN_READ_TIMEOUT'

/** A stdin delivery or dispatch-watchdog failure with a stable code. */
export class StdinDeliveryError extends Error {
  readonly code: StdinFailureCode

  constructor(code: StdinFailureCode, message: string) {
    super(message)
    this.name = 'StdinDeliveryError'
    this.code = code
  }
}

/** One stdin chunk sent before the `exec` it belongs to. */
export interface StdinFrame {
  readonly type: 'stdin'
  readonly id: number
  /** Zero-based frame index; frames of one id must arrive in order. */
  readonly seq: number
  readonly data: Uint8Array
  /** True only on the final frame; the interpreter sees EOF after it. */
  readonly eof: boolean
}

/**
 * Split one complete stdin payload into frames.
 *
 * An empty payload still produces one zero-length `eof: true` frame, so the
 * tool worker can distinguish "stdin was delivered as empty" from "stdin was
 * never delivered".
 * @param id - execution id the frames belong to.
 * @param bytes - complete payload.
 * @returns the frames in send order.
 * @throws {StdinDeliveryError} `E_STDIN_OVERSIZE` above {@link MAX_STDIN_BYTES}.
 */
export function splitStdinFrames(id: number, bytes: Uint8Array): StdinFrame[] {
  if (bytes.byteLength > MAX_STDIN_BYTES) {
    throw new StdinDeliveryError(
      'E_STDIN_OVERSIZE',
      `stdin is ${bytes.byteLength} bytes; the WASI dispatch limit is ${MAX_STDIN_BYTES} bytes`,
    )
  }
  if (bytes.byteLength === 0) return [{ type: 'stdin', id, seq: 0, data: new Uint8Array(0), eof: true }]
  const frames: StdinFrame[] = []
  for (let offset = 0, seq = 0; offset < bytes.byteLength; offset += STDIN_CHUNK_BYTES, seq += 1) {
    const end = Math.min(offset + STDIN_CHUNK_BYTES, bytes.byteLength)
    // Copy instead of `subarray`: a structured clone copies the whole backing
    // ArrayBuffer of a view, so a 16 MiB payload split into views of one shared
    // buffer would clone 16 MiB per frame. One owned buffer per frame keeps
    // the per-message cost at its own chunk size.
    frames.push({ type: 'stdin', id, seq, data: bytes.slice(offset, end), eof: end === bytes.byteLength })
  }
  return frames
}

/** True when `message` has the shape of a {@link StdinFrame}. */
export function isStdinFrame(message: unknown): message is StdinFrame {
  if (typeof message !== 'object' || message === null) return false
  const frame = message as Partial<StdinFrame>
  return frame.type === 'stdin'
    && typeof frame.id === 'number'
    && typeof frame.seq === 'number'
    && frame.data instanceof Uint8Array
    && typeof frame.eof === 'boolean'
}

/**
 * The guest-side stdin stream a WASI module reads through `fd_read`.
 *
 * `read` never blocks: the complete payload is already in worker memory, and
 * EOF (a zero-length read) is reported only after the feed is exhausted *and*
 * the delivery marked it complete. The `complete` flag is what makes a
 * truncated delivery observable instead of looking like an empty script.
 */
export class WasiStdin {
  private readonly bytes: Uint8Array
  private readonly complete: boolean
  private offset = 0

  /**
   * @param bytes - delivered payload (empty when there is no stdin).
   * @param complete - whether the delivery carried its EOF marker.
   */
  constructor(bytes: Uint8Array = new Uint8Array(0), complete = true) {
    this.bytes = bytes
    this.complete = complete
  }

  /** Total bytes delivered, whether read or not. */
  get totalBytes(): number { return this.bytes.byteLength }

  /** Bytes consumed by the guest so far. */
  get bytesRead(): number { return this.offset }

  /** True when every delivered byte was consumed and the feed is complete. */
  get atEof(): boolean { return this.complete && this.offset >= this.bytes.byteLength }

  /**
   * Consume up to `max` bytes.
   * @param max - the guest's iovec capacity.
   * @returns the next bytes; empty at EOF.
   */
  read(max: number): Uint8Array {
    if (max <= 0 || this.offset >= this.bytes.byteLength) return new Uint8Array(0)
    const end = Math.min(this.offset + max, this.bytes.byteLength)
    const data = this.bytes.subarray(this.offset, end)
    this.offset = end
    return data
  }
}

interface PendingStdin {
  readonly chunks: Uint8Array[]
  received: number
  nextSeq: number
  eof: boolean
}

/**
 * Tool-worker half of the stdin protocol: collect the frames of one execution
 * and hand them to the interpreter only after the EOF frame arrived.
 */
export class StdinAssembly {
  private readonly pending = new Map<number, PendingStdin>()

  /** Accept one frame; validates order, size and duplicate EOF. */
  accept(frame: StdinFrame): void {
    let entry = this.pending.get(frame.id)
    if (entry === undefined) {
      if (frame.seq !== 0) {
        throw new StdinDeliveryError('E_STDIN_SEQUENCE', `stdin frame ${frame.seq} arrived before frame 0`)
      }
      entry = { chunks: [], received: 0, nextSeq: 0, eof: false }
      this.pending.set(frame.id, entry)
    }
    if (entry.eof) {
      throw new StdinDeliveryError('E_STDIN_UNEXPECTED', `stdin frame ${frame.seq} arrived after the EOF frame`)
    }
    if (frame.seq !== entry.nextSeq) {
      throw new StdinDeliveryError(
        'E_STDIN_SEQUENCE',
        `stdin frame ${frame.seq} arrived where frame ${entry.nextSeq} was expected`,
      )
    }
    entry.received += frame.data.byteLength
    if (entry.received > MAX_STDIN_BYTES) {
      throw new StdinDeliveryError(
        'E_STDIN_OVERSIZE',
        `stdin is ${entry.received} bytes; the WASI dispatch limit is ${MAX_STDIN_BYTES} bytes`,
      )
    }
    // Copy: the frame's buffer is owned by the caller and may be reused.
    entry.chunks.push(Uint8Array.from(frame.data))
    entry.nextSeq += 1
    entry.eof = frame.eof
  }

  /** True when the id has received its EOF frame. */
  isComplete(id: number): boolean {
    return this.pending.get(id)?.eof === true
  }

  /** Bytes received for an id, for diagnostics. */
  bytesFor(id: number): number {
    return this.pending.get(id)?.received ?? 0
  }

  /**
   * Take the complete payload of one execution.
   * @throws {StdinDeliveryError} `E_STDIN_INCOMPLETE` when the EOF frame is
   *   missing, so the dispatch fails loud instead of running with half a
   *   script.
   */
  take(id: number): Uint8Array {
    const entry = this.pending.get(id)
    this.pending.delete(id)
    if (entry === undefined) return new Uint8Array(0)
    if (!entry.eof) {
      throw new StdinDeliveryError(
        'E_STDIN_INCOMPLETE',
        `exec ${id} started with ${entry.received} stdin bytes but without the EOF frame`,
      )
    }
    const joined = new Uint8Array(entry.received)
    let offset = 0
    for (const chunk of entry.chunks) {
      joined.set(chunk, offset)
      offset += chunk.byteLength
    }
    return joined
  }

  /** Drop a canceled execution's pending frames. */
  discard(id: number): void {
    this.pending.delete(id)
  }
}
