// SPDX-License-Identifier: MIT
/**
 * Frame header and streaming codec (channel.md §1, §2, §7).
 *
 * A frame is a 16-byte big-endian header followed by 1..16 MiB of payload:
 * `magic u16 = 0x5A4C`, `type u8`, `flags u8 = 0`, `seq u64`, `len u32`.
 * @module @phone-dsh/dsh-channel/frames
 */
import { readU64be, writeU16be, writeU32be, writeU64be } from './bytes.ts'
import { FrameError } from './errors.ts'

/** Header magic of every phone-dsh-v1 frame. */
export const FRAME_MAGIC = 0x5a4c
/** Fixed header size in bytes. */
export const FRAME_HEADER_SIZE = 16
/** Largest payload a frame may carry (channel.md §1). */
export const MAX_FRAME_PAYLOAD = 16 * 1024 * 1024
/**
 * Hard ceiling for a single unparsed frame the decoder will hold. The protocol
 * ceiling is {@link MAX_FRAME_PAYLOAD}; this is a defensive bound so a corrupt
 * length field can never make the decoder buffer an arbitrary amount.
 */
export const MAX_DECODER_BUFFER = 64 * 1024 * 1024
/** The first frame of each direction and connection carries this seq. */
export const FIRST_SEQ = 1n

/** The 18 frame type bytes of channel.md §2. */
export const FrameType = {
  HELLO: 0x01,
  VFS_MUT: 0x10,
  VFS_ACK: 0x11,
  VFS_BARRIER: 0x12,
  VFS_RESYNC: 0x13,
  EXEC_REQ: 0x20,
  EXEC_EVT: 0x21,
  EXEC_CTL: 0x22,
  JOURNAL: 0x30,
  JOURNAL_ACK: 0x31,
  API_REQ: 0x40,
  API_RES: 0x41,
  API_END: 0x42,
  API_ABORT: 0x43,
  LIFECYCLE: 0x50,
  CONSOLE: 0x60,
  FENCE: 0x70,
  ERROR: 0x7f,
} as const

/** Numeric union of the 18 frame types. */
export type FrameType = (typeof FrameType)[keyof typeof FrameType]

const FRAME_TYPE_NAMES: Readonly<Record<number, string>> = Object.freeze({
  [FrameType.HELLO]: 'HELLO',
  [FrameType.VFS_MUT]: 'VFS_MUT',
  [FrameType.VFS_ACK]: 'VFS_ACK',
  [FrameType.VFS_BARRIER]: 'VFS_BARRIER',
  [FrameType.VFS_RESYNC]: 'VFS_RESYNC',
  [FrameType.EXEC_REQ]: 'EXEC_REQ',
  [FrameType.EXEC_EVT]: 'EXEC_EVT',
  [FrameType.EXEC_CTL]: 'EXEC_CTL',
  [FrameType.JOURNAL]: 'JOURNAL',
  [FrameType.JOURNAL_ACK]: 'JOURNAL_ACK',
  [FrameType.API_REQ]: 'API_REQ',
  [FrameType.API_RES]: 'API_RES',
  [FrameType.API_END]: 'API_END',
  [FrameType.API_ABORT]: 'API_ABORT',
  [FrameType.LIFECYCLE]: 'LIFECYCLE',
  [FrameType.CONSOLE]: 'CONSOLE',
  [FrameType.FENCE]: 'FENCE',
  [FrameType.ERROR]: 'ERROR',
})

/** Name of a frame type byte, or `undefined` when the byte is reserved. */
export function frameTypeName(type: number): string | undefined {
  return FRAME_TYPE_NAMES[type]
}

/** Whether a byte is one of the 18 defined frame types. */
export function isFrameType(type: number): type is FrameType {
  return FRAME_TYPE_NAMES[type] !== undefined
}

/** One decoded frame: the header fields plus the raw payload bytes. */
export interface Frame {
  readonly type: FrameType
  readonly seq: bigint
  readonly payload: Uint8Array
}

/**
 * Encode one frame, header included.
 * @throws {FrameError} `BAD_PAYLOAD` for an unknown type or a payload length
 *   outside 1..16 MiB.
 */
export function encodeFrame(frame: Frame): Uint8Array {
  const type: number = frame.type
  if (!isFrameType(type)) {
    throw new FrameError('BAD_PAYLOAD', `unknown frame type 0x${type.toString(16)}`)
  }
  if (frame.seq < 0n || frame.seq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_SEQ', `seq is not a u64: ${String(frame.seq)}`)
  }
  if (frame.payload.byteLength === 0) {
    throw new FrameError('BAD_PAYLOAD', 'frames have no zero-length payload')
  }
  if (frame.payload.byteLength > MAX_FRAME_PAYLOAD) {
    throw new FrameError('BAD_PAYLOAD', `payload length ${frame.payload.byteLength} exceeds ${MAX_FRAME_PAYLOAD}`)
  }
  const out = new Uint8Array(FRAME_HEADER_SIZE + frame.payload.byteLength)
  writeU16be(out, 0, FRAME_MAGIC)
  out[2] = frame.type
  out[3] = 0
  writeU64be(out, 4, frame.seq)
  writeU32be(out, 12, frame.payload.byteLength)
  out.set(frame.payload, FRAME_HEADER_SIZE)
  return out
}

/**
 * Streaming frame decoder. `push` accepts arbitrary chunks, including partial
 * headers, partial payloads and several concatenated frames, and returns every
 * complete frame in order.
 *
 * On a header violation the decoder throws a {@link FrameError}; the caller
 * closes the connection and discards the decoder.
 */
export class FrameDecoder {
  private buffer = new Uint8Array(0)
  private offset = 0

  /** Number of bytes currently buffered but not yet decoded. */
  get buffered(): number {
    return this.buffer.byteLength - this.offset
  }

  /**
   * Append bytes and decode every complete frame.
   * @throws {FrameError} `BAD_MAGIC` for a bad magic, `BAD_PAYLOAD` for a
   *   non-zero flags byte, an out-of-range length or an unknown type.
   */
  push(bytes: Uint8Array): Frame[] {
    if (bytes.byteLength > 0) this.append(bytes)
    const frames: Frame[] = []
    for (;;) {
      const available = this.buffer.byteLength - this.offset
      if (available < FRAME_HEADER_SIZE) break
      const start = this.offset
      const magic = (this.buffer[start]! << 8) | this.buffer[start + 1]!
      if (magic !== FRAME_MAGIC) {
        throw new FrameError('BAD_MAGIC', `frame magic is 0x${magic.toString(16)}, expected 0x${FRAME_MAGIC.toString(16)}`)
      }
      const type = this.buffer[start + 2]!
      const flags = this.buffer[start + 3]!
      const seq = readU64be(this.buffer, start + 4)
      const length = ((this.buffer[start + 12]! * 0x1000000)
        + ((this.buffer[start + 13]! << 16) | (this.buffer[start + 14]! << 8) | this.buffer[start + 15]!))
      if (flags !== 0) throw new FrameError('BAD_PAYLOAD', `frame flags must be zero, got ${flags}`, seq)
      if (length === 0) throw new FrameError('BAD_PAYLOAD', 'frames have no zero-length payload', seq)
      if (length > MAX_FRAME_PAYLOAD) {
        throw new FrameError('BAD_PAYLOAD', `payload length ${length} exceeds ${MAX_FRAME_PAYLOAD}`, seq)
      }
      if (!isFrameType(type)) {
        throw new FrameError('BAD_PAYLOAD', `unknown frame type 0x${type.toString(16)}`, seq)
      }
      if (available < FRAME_HEADER_SIZE + length) break
      const payload = this.buffer.slice(start + FRAME_HEADER_SIZE, start + FRAME_HEADER_SIZE + length)
      frames.push({ type, seq, payload })
      this.offset += FRAME_HEADER_SIZE + length
    }
    this.compact()
    return frames
  }

  /** Drop any partially buffered frame; used when a connection closes. */
  reset(): void {
    this.buffer = new Uint8Array(0)
    this.offset = 0
  }

  private append(bytes: Uint8Array): void {
    const remaining = this.buffer.byteLength - this.offset
    const next = new Uint8Array(remaining + bytes.byteLength)
    next.set(this.buffer.subarray(this.offset))
    next.set(bytes, remaining)
    this.buffer = next
    this.offset = 0
  }

  private compact(): void {
    const remaining = this.buffer.byteLength - this.offset
    if (remaining === 0) {
      this.buffer = new Uint8Array(0)
      this.offset = 0
      return
    }
    if (this.offset >= 64 * 1024) {
      this.buffer = this.buffer.slice(this.offset)
      this.offset = 0
    }
  }
}
