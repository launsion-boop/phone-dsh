// SPDX-License-Identifier: MIT
/**
 * Binary payload codecs of channel.md §3: VFS mutations and their acks,
 * barriers and resyncs, plus the journal frames.
 * @module @phone-dsh/dsh-channel/vfs-mutation
 */
import {
  decodeUtf8, encodeUtf8, readU16be, readU32be, readU64be,
  writeU16be, writeU32be, writeU64be,
} from './bytes.ts'
import { FrameError } from './errors.ts'
import { requireIdentifier, requireMutationPath } from './validate.ts'

/** Mutation operations of channel.md §3.1. */
export const VfsOp = {
  WRITE: 1,
  MKDIR: 2,
  REMOVE: 3,
  CHMOD: 4,
} as const

/** Numeric union of the mutation operations. */
export type VfsOp = (typeof VfsOp)[keyof typeof VfsOp]

/** `mflags` bit 0: the directory entry changed (create, replace, remove, chmod). */
export const VFS_MFLAG_ENTRY_CHANGED = 0x01
/** `mflags` bit 1: `data` is the suffix starting at `appendFrom`. */
export const VFS_MFLAG_APPENDED = 0x02
/** A single VFS_MUT carries at most 15 MiB of data (16 MiB frame minus header/path). */
export const MAX_MUTATION_DATA = 15 * 1024 * 1024
/**
 * Historical name for {@link MAX_MUTATION_DATA}.
 *
 * D4 once equated the per-mutation frame cap with the single-file cap. The
 * large-file budget (budgets.md §4) separates them: a file may be up to
 * `single_file_limit`, while one mutation stays at 15 MiB. Kept as an alias so
 * existing wire callers cannot silently start emitting oversized frames.
 */
export const VFS_SINGLE_FILE_LIMIT = MAX_MUTATION_DATA
/** Default single-file budget, 8 GiB tier (budgets.md §4): 128 MiB. */
export const DEFAULT_SINGLE_FILE_LIMIT = 128 * 1024 * 1024
/** Contract floor for a host-configured single-file limit: 16 MiB. */
export const MIN_SINGLE_FILE_LIMIT = 16 * 1024 * 1024
/** Absolute host maximum for a configured single-file limit: 256 MiB. */
export const MAX_SINGLE_FILE_LIMIT = 256 * 1024 * 1024

/** The mutation body of VFS_MUT without the leading host-allocated `mseq`. */
export interface VfsMutationBody {
  readonly op: VfsOp
  readonly mode: number
  readonly mflags: number
  readonly appendFrom: bigint
  readonly path: string
  readonly data: Uint8Array
}

/** A complete VFS_MUT payload, including the leading `mseq`. */
export interface VfsMutation extends VfsMutationBody {
  readonly mseq: bigint
}

/** VFS_ACK payload. */
export interface VfsAck {
  readonly level: 1 | 2
  readonly uptoMseq: bigint
}

/** VFS_BARRIER payload. */
export interface VfsBarrier {
  readonly wantLevel: 1 | 2
  readonly uptoMseq: bigint
}

/** VFS_RESYNC payload. */
export interface VfsResync {
  readonly path: string
}

/** JOURNAL payload. */
export interface JournalFrame {
  readonly jseq: bigint
  readonly sessionId: string
  readonly record: Uint8Array
}

/** JOURNAL_ACK payload. */
export interface JournalAck {
  readonly level: 1 | 2
  readonly sessionId: string
  readonly uptoJseq: bigint
}

/** Validate a mutation body against channel.md §3.1 and D4. */
export function validateVfsMutationBody(body: VfsMutationBody): void {
  if (body.op !== VfsOp.WRITE && body.op !== VfsOp.MKDIR && body.op !== VfsOp.REMOVE && body.op !== VfsOp.CHMOD) {
    throw new FrameError('BAD_PAYLOAD', `unknown VFS op ${String(body.op)}`)
  }
  if (!Number.isInteger(body.mode) || body.mode < 0 || body.mode > 0o7777) {
    throw new FrameError('BAD_PAYLOAD', `mode ${String(body.mode)} is not a permission bit mask`)
  }
  if (body.op === VfsOp.REMOVE && body.mode !== 0) {
    throw new FrameError('BAD_PAYLOAD', 'remove carries mode 0')
  }
  if (!Number.isInteger(body.mflags) || body.mflags < 0 || body.mflags > 0x03) {
    throw new FrameError('BAD_PAYLOAD', `mflags ${String(body.mflags)} has reserved bits set`)
  }
  if (body.appendFrom < 0n || body.appendFrom > 0xffffffffffffffffn) {
    throw new FrameError('BAD_PAYLOAD', 'append_from is not a u64')
  }
  requireMutationPath(body.path)
  if (!(body.data instanceof Uint8Array)) {
    throw new FrameError('BAD_PAYLOAD', 'mutation data must be bytes')
  }
  if (body.op !== VfsOp.WRITE) {
    if (body.mflags !== 0 || body.appendFrom !== 0n || body.data.byteLength !== 0) {
      throw new FrameError('BAD_PAYLOAD', 'mkdir/remove/chmod carry no data, flags or append offset')
    }
    return
  }
  if ((body.mflags & VFS_MFLAG_APPENDED) === 0 && body.appendFrom !== 0n) {
    throw new FrameError('BAD_PAYLOAD', 'append_from is only valid with the appended bit')
  }
  if (body.data.byteLength > MAX_MUTATION_DATA) {
    throw new FrameError('BAD_PAYLOAD', `write data length ${body.data.byteLength} exceeds ${MAX_MUTATION_DATA}`)
  }
}

/** Encode a mutation body (no `mseq`). */
export function encodeVfsMutationBody(body: VfsMutationBody): Uint8Array {
  validateVfsMutationBody(body)
  const path = encodeUtf8(body.path)
  const out = new Uint8Array(16 + path.byteLength + 4 + body.data.byteLength)
  out[0] = body.op
  writeU32be(out, 1, body.mode)
  out[5] = body.mflags
  writeU64be(out, 6, body.appendFrom)
  writeU16be(out, 14, path.byteLength)
  out.set(path, 16)
  writeU32be(out, 16 + path.byteLength, body.data.byteLength)
  out.set(body.data, 20 + path.byteLength)
  return out
}

/** Decode a mutation body (no `mseq`). */
export function decodeVfsMutationBody(bytes: Uint8Array): VfsMutationBody {
  if (bytes.byteLength < 20) {
    throw new FrameError('BAD_PAYLOAD', `mutation body is ${bytes.byteLength} bytes, need at least 20`)
  }
  const op = bytes[0]! as VfsOp
  const mode = readU32be(bytes, 1)
  const mflags = bytes[5]!
  const appendFrom = readU64be(bytes, 6)
  const pathLength = readU16be(bytes, 14)
  if (16 + pathLength + 4 > bytes.byteLength) {
    throw new FrameError('BAD_PAYLOAD', `mutation path length ${pathLength} overruns the payload`)
  }
  let path: string
  try {
    path = decodeUtf8(bytes.subarray(16, 16 + pathLength))
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'mutation path is not valid UTF-8')
  }
  const dataLength = readU32be(bytes, 16 + pathLength)
  if (20 + pathLength + dataLength !== bytes.byteLength) {
    throw new FrameError('BAD_PAYLOAD', `mutation data length ${dataLength} does not match the payload`)
  }
  const data = bytes.slice(20 + pathLength)
  const body: VfsMutationBody = { op, mode, mflags, appendFrom, path, data }
  validateVfsMutationBody(body)
  return body
}

/** Encode a complete VFS_MUT payload, leading `mseq` included. */
export function encodeVfsMutation(mutation: VfsMutation): Uint8Array {
  if (mutation.mseq < 1n || mutation.mseq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_MSEQ', `mseq ${String(mutation.mseq)} is not a positive u64`)
  }
  const body = encodeVfsMutationBody(mutation)
  const out = new Uint8Array(8 + body.byteLength)
  writeU64be(out, 0, mutation.mseq)
  out.set(body, 8)
  return out
}

/** Decode a complete VFS_MUT payload. */
export function decodeVfsMutation(bytes: Uint8Array): VfsMutation {
  if (bytes.byteLength < 8) throw new FrameError('BAD_PAYLOAD', 'VFS_MUT payload is shorter than its mseq')
  const mseq = readU64be(bytes, 0)
  if (mseq < 1n) throw new FrameError('BAD_MSEQ', 'VFS_MUT mseq must be at least 1')
  return { mseq, ...decodeVfsMutationBody(bytes.subarray(8)) }
}

function requireLevel(value: number, what: string): 1 | 2 {
  if (value !== 1 && value !== 2) throw new FrameError('BAD_PAYLOAD', `${what} must be 1 or 2`)
  return value
}

/** Encode a VFS_ACK payload. */
export function encodeVfsAck(ack: VfsAck): Uint8Array {
  if (ack.uptoMseq < 0n || ack.uptoMseq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_PAYLOAD', 'upto_mseq is not a u64')
  }
  const out = new Uint8Array(9)
  out[0] = requireLevel(ack.level, 'VFS_ACK level')
  writeU64be(out, 1, ack.uptoMseq)
  return out
}

/** Decode a VFS_ACK payload. */
export function decodeVfsAck(bytes: Uint8Array): VfsAck {
  if (bytes.byteLength !== 9) throw new FrameError('BAD_PAYLOAD', `VFS_ACK payload is ${bytes.byteLength} bytes, expected 9`)
  return { level: requireLevel(bytes[0]!, 'VFS_ACK level'), uptoMseq: readU64be(bytes, 1) }
}

/** Encode a VFS_BARRIER payload. */
export function encodeVfsBarrier(barrier: VfsBarrier): Uint8Array {
  if (barrier.uptoMseq < 0n || barrier.uptoMseq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_PAYLOAD', 'upto_mseq is not a u64')
  }
  const out = new Uint8Array(9)
  out[0] = requireLevel(barrier.wantLevel, 'VFS_BARRIER want_level')
  writeU64be(out, 1, barrier.uptoMseq)
  return out
}

/** Decode a VFS_BARRIER payload. */
export function decodeVfsBarrier(bytes: Uint8Array): VfsBarrier {
  if (bytes.byteLength !== 9) {
    throw new FrameError('BAD_PAYLOAD', `VFS_BARRIER payload is ${bytes.byteLength} bytes, expected 9`)
  }
  return { wantLevel: requireLevel(bytes[0]!, 'VFS_BARRIER want_level'), uptoMseq: readU64be(bytes, 1) }
}

/** Encode a VFS_RESYNC payload. */
export function encodeVfsResync(resync: VfsResync): Uint8Array {
  requireMutationPath(resync.path)
  const path = encodeUtf8(resync.path)
  const out = new Uint8Array(2 + path.byteLength)
  writeU16be(out, 0, path.byteLength)
  out.set(path, 2)
  return out
}

/** Decode a VFS_RESYNC payload. */
export function decodeVfsResync(bytes: Uint8Array): VfsResync {
  if (bytes.byteLength < 2) throw new FrameError('BAD_PAYLOAD', 'VFS_RESYNC payload is shorter than its path length')
  const pathLength = readU16be(bytes, 0)
  if (2 + pathLength !== bytes.byteLength) {
    throw new FrameError('BAD_PAYLOAD', 'VFS_RESYNC path length does not match the payload')
  }
  let path: string
  try {
    path = decodeUtf8(bytes.subarray(2))
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'VFS_RESYNC path is not valid UTF-8')
  }
  return { path: requireMutationPath(path, 'VFS_RESYNC path') }
}

/** Encode a JOURNAL payload. */
export function encodeJournal(frame: JournalFrame): Uint8Array {
  if (frame.jseq < 1n || frame.jseq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_PAYLOAD', 'journal jseq must be a positive u64')
  }
  requireIdentifier(frame.sessionId, 'session_id')
  if (!(frame.record instanceof Uint8Array) || frame.record.byteLength === 0) {
    throw new FrameError('BAD_PAYLOAD', 'a journal record carries at least one byte')
  }
  const sessionId = encodeUtf8(frame.sessionId)
  if (sessionId.byteLength > 0xffff) throw new FrameError('BAD_PAYLOAD', 'session_id is too long')
  const out = new Uint8Array(8 + 2 + sessionId.byteLength + frame.record.byteLength)
  writeU64be(out, 0, frame.jseq)
  writeU16be(out, 8, sessionId.byteLength)
  out.set(sessionId, 10)
  out.set(frame.record, 10 + sessionId.byteLength)
  return out
}

/** Decode a JOURNAL payload. */
export function decodeJournal(bytes: Uint8Array): JournalFrame {
  if (bytes.byteLength < 11) throw new FrameError('BAD_PAYLOAD', 'JOURNAL payload is too short')
  const jseq = readU64be(bytes, 0)
  const sessionLength = readU16be(bytes, 8)
  if (10 + sessionLength + 1 > bytes.byteLength) {
    throw new FrameError('BAD_PAYLOAD', 'JOURNAL session_id length overruns the payload')
  }
  let sessionId: string
  try {
    sessionId = decodeUtf8(bytes.subarray(10, 10 + sessionLength))
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'JOURNAL session_id is not valid UTF-8')
  }
  return {
    jseq,
    sessionId: requireIdentifier(sessionId, 'session_id'),
    record: bytes.slice(10 + sessionLength),
  }
}

/** Encode a JOURNAL_ACK payload. */
export function encodeJournalAck(ack: JournalAck): Uint8Array {
  requireIdentifier(ack.sessionId, 'session_id')
  if (ack.uptoJseq < 0n || ack.uptoJseq > 0xffffffffffffffffn) {
    throw new FrameError('BAD_PAYLOAD', 'upto_jseq is not a u64')
  }
  const sessionId = encodeUtf8(ack.sessionId)
  const out = new Uint8Array(3 + sessionId.byteLength + 8)
  out[0] = requireLevel(ack.level, 'JOURNAL_ACK level')
  writeU16be(out, 1, sessionId.byteLength)
  out.set(sessionId, 3)
  writeU64be(out, 3 + sessionId.byteLength, ack.uptoJseq)
  return out
}

/** Decode a JOURNAL_ACK payload. */
export function decodeJournalAck(bytes: Uint8Array): JournalAck {
  if (bytes.byteLength < 12) throw new FrameError('BAD_PAYLOAD', 'JOURNAL_ACK payload is too short')
  const level = requireLevel(bytes[0]!, 'JOURNAL_ACK level')
  const sessionLength = readU16be(bytes, 1)
  if (3 + sessionLength + 8 !== bytes.byteLength) {
    throw new FrameError('BAD_PAYLOAD', 'JOURNAL_ACK session_id length does not match the payload')
  }
  let sessionId: string
  try {
    sessionId = decodeUtf8(bytes.subarray(3, 3 + sessionLength))
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'JOURNAL_ACK session_id is not valid UTF-8')
  }
  return {
    level,
    sessionId: requireIdentifier(sessionId, 'session_id'),
    uptoJseq: readU64be(bytes, 3 + sessionLength),
  }
}

