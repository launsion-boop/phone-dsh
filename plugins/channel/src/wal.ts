// SPDX-License-Identifier: MIT
/**
 * WAL segment header and record codecs (wal.md §2–§4).
 *
 * Segment header, 40 bytes: `XLWAL1\0\0`, `format u16 = 1`, `reserved u16 = 0`,
 * `first_mseq u64`, 16-byte `boot_id`, `header_crc32c u32` over bytes 0–35.
 *
 * Record: `len u32` (mseq + body) · `crc32c u32` (over mseq + body) ·
 * `mseq u64` · mutation body. The epoch-close body starts with `op = 0xFF` and
 * its mseq equals `durable_upto`.
 * @module @phone-dsh/dsh-channel/wal
 */
import {
  bytesEqual, readU32be, readU64be, writeU32be, writeU64be,
} from './bytes.ts'
import { crc32c } from './crc32c.ts'
import { WalError } from './errors.ts'
import { decodeVfsMutationBody, encodeVfsMutationBody, type VfsMutationBody } from './vfs-mutation.ts'

/** Segment magic bytes `XLWAL1\0\0`. */
export const WAL_MAGIC: readonly number[] = Object.freeze([0x58, 0x4c, 0x57, 0x41, 0x4c, 0x31, 0x00, 0x00])
/** Segment header size in bytes. */
export const WAL_SEGMENT_HEADER_SIZE = 40
/** On-disk WAL format this codec implements. */
export const WAL_FORMAT = 1
/** First body byte of the epoch-close record (D7). */
export const WAL_EPOCH_CLOSE_OP = 0xff
/** Byte size of a boot identity. */
export const WAL_BOOT_ID_SIZE = 16

/** Decoded 40-byte segment header. */
export interface WalSegmentHeader {
  readonly format: number
  readonly reserved: number
  readonly firstMseq: bigint
  readonly bootId: Uint8Array
  readonly headerCrc32c: number
}

/** Input for {@link encodeWalSegmentHeader}; the CRC is computed. */
export interface WalSegmentHeaderInput {
  readonly format?: number
  readonly reserved?: number
  readonly firstMseq: bigint
  readonly bootId: Uint8Array
}

/** A mutation record as stored in a WAL segment. */
export interface WalMutationRecord {
  readonly kind: 'mutation'
  readonly mseq: bigint
  readonly mutation: VfsMutationBody
  readonly crc32c: number
}

/** An epoch-close record (D7). Its mseq field is `durableUpto`. */
export interface WalEpochCloseRecord {
  readonly kind: 'epoch_close'
  readonly mseq: bigint
  readonly wallMs: bigint
  readonly durableUpto: bigint
  readonly crc32c: number
}

/** Any decoded WAL record. */
export type WalRecord = WalMutationRecord | WalEpochCloseRecord

/** Record input for {@link encodeWalRecord}. */
export type WalRecordInput =
  | { readonly kind: 'mutation'; readonly mseq: bigint; readonly mutation: VfsMutationBody }
  | { readonly kind: 'epoch_close'; readonly mseq: bigint; readonly wallMs: bigint; readonly durableUpto: bigint }

function requireU64(value: bigint, what: string): bigint {
  if (typeof value !== 'bigint' || value < 0n || value > 0xffffffffffffffffn) {
    throw new WalError('WAL_BAD_RECORD', `${what} is not a u64`)
  }
  return value
}

/** Encode and checksum a 40-byte segment header. */
export function encodeWalSegmentHeader(header: WalSegmentHeaderInput): Uint8Array {
  const format = header.format ?? WAL_FORMAT
  const reserved = header.reserved ?? 0
  if (format !== WAL_FORMAT) throw new WalError('WAL_BAD_HEADER', `unsupported WAL format ${format}`)
  if (reserved !== 0) throw new WalError('WAL_BAD_HEADER', 'reserved header field must be zero')
  if (!(header.bootId instanceof Uint8Array) || header.bootId.byteLength !== WAL_BOOT_ID_SIZE) {
    throw new WalError('WAL_BAD_HEADER', `boot_id must be ${WAL_BOOT_ID_SIZE} raw bytes`)
  }
  if (header.firstMseq < 1n || header.firstMseq > 0xffffffffffffffffn) {
    throw new WalError('WAL_BAD_HEADER', 'first_mseq is not a positive u64')
  }
  const out = new Uint8Array(WAL_SEGMENT_HEADER_SIZE)
  out.set(WAL_MAGIC, 0)
  out[8] = 0
  out[9] = WAL_FORMAT
  out[10] = 0
  out[11] = 0
  writeU64be(out, 12, header.firstMseq)
  out.set(header.bootId, 20)
  writeU32be(out, 36, crc32c(out.subarray(0, 36)))
  return out
}

/** Decode and verify a 40-byte segment header. */
export function decodeWalSegmentHeader(bytes: Uint8Array): WalSegmentHeader {
  if (bytes.byteLength !== WAL_SEGMENT_HEADER_SIZE) {
    throw new WalError('WAL_BAD_HEADER', `segment header is ${bytes.byteLength} bytes, expected ${WAL_SEGMENT_HEADER_SIZE}`)
  }
  if (!bytesEqual(bytes.subarray(0, 8), Uint8Array.from(WAL_MAGIC))) {
    throw new WalError('WAL_BAD_HEADER', 'segment magic is not XLWAL1')
  }
  const format = (bytes[8]! << 8) | bytes[9]!
  const reserved = (bytes[10]! << 8) | bytes[11]!
  if (format !== WAL_FORMAT) throw new WalError('WAL_BAD_HEADER', `unsupported WAL format ${format}`)
  if (reserved !== 0) throw new WalError('WAL_BAD_HEADER', 'reserved header field must be zero')
  const headerCrc32c = readU32be(bytes, 36)
  if (crc32c(bytes.subarray(0, 36)) !== headerCrc32c) {
    throw new WalError('WAL_BAD_HEADER', 'segment header CRC32C mismatch')
  }
  const firstMseq = readU64be(bytes, 12)
  if (firstMseq < 1n) throw new WalError('WAL_BAD_HEADER', 'first_mseq must be at least 1')
  return {
    format,
    reserved,
    firstMseq,
    bootId: bytes.slice(20, 36),
    headerCrc32c,
  }
}

/** Encode one WAL record, `len` and `crc32c` included. */
export function encodeWalRecord(record: WalRecordInput): Uint8Array {
  if (record.kind === 'mutation') {
    const mseq = requireU64(record.mseq, 'mseq')
    const body = encodeVfsMutationBody(record.mutation)
    const payloadLength = 8 + body.byteLength
    const out = new Uint8Array(8 + payloadLength)
    writeU32be(out, 0, payloadLength)
    writeU64be(out, 8, mseq)
    out.set(body, 16)
    writeU32be(out, 4, crc32c(out.subarray(8)))
    return out
  }
  const durableUpto = requireU64(record.durableUpto, 'durable_upto')
  const wallMs = requireU64(record.wallMs, 'wall_ms')
  if (record.mseq !== durableUpto) {
    throw new WalError('WAL_BAD_RECORD', 'the epoch-close record mseq must equal durable_upto')
  }
  const payloadLength = 8 + 17
  const out = new Uint8Array(8 + payloadLength)
  writeU32be(out, 0, payloadLength)
  writeU64be(out, 8, durableUpto)
  out[16] = WAL_EPOCH_CLOSE_OP
  writeU64be(out, 17, wallMs)
  writeU64be(out, 25, durableUpto)
  writeU32be(out, 4, crc32c(out.subarray(8)))
  return out
}

/** Decode and verify exactly one WAL record. */
export function decodeWalRecord(bytes: Uint8Array): WalRecord {
  if (bytes.byteLength < 8) throw new WalError('WAL_BAD_RECORD', 'record is shorter than len and crc32c')
  const length = readU32be(bytes, 0)
  if (length < 9) throw new WalError('WAL_BAD_RECORD', `record length ${length} is too small`)
  if (bytes.byteLength !== 8 + length) {
    throw new WalError('WAL_BAD_RECORD', `record length ${length} does not match ${bytes.byteLength - 8} available bytes`)
  }
  const storedCrc = readU32be(bytes, 4)
  const payload = bytes.subarray(8)
  if (crc32c(payload) !== storedCrc) {
    throw new WalError('WAL_BAD_CRC', 'record CRC32C mismatch')
  }
  const mseq = readU64be(payload, 0)
  const body = payload.subarray(8)
  if (body[0] === WAL_EPOCH_CLOSE_OP) {
    if (body.byteLength !== 17) {
      throw new WalError('WAL_BAD_RECORD', `epoch-close body is ${body.byteLength} bytes, expected 17`)
    }
    const wallMs = readU64be(body, 1)
    const durableUpto = readU64be(body, 9)
    if (mseq !== durableUpto) {
      throw new WalError('WAL_BAD_RECORD', 'the epoch-close record mseq must equal durable_upto')
    }
    return { kind: 'epoch_close', mseq, wallMs, durableUpto, crc32c: storedCrc }
  }
  if (body.byteLength < 1) throw new WalError('WAL_BAD_RECORD', 'mutation record has no body')
  return {
    kind: 'mutation',
    mseq,
    mutation: decodeVfsMutationBody(body),
    crc32c: storedCrc,
  }
}
