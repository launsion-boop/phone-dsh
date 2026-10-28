// SPDX-License-Identifier: MIT
/**
 * Typed errors shared by the channel, payload and WAL codecs.
 * @module @phone-dsh/dsh-channel/errors
 */

/** Protocol error codes of channel.md §10; `VFS_REFUSED` is a diagnostic, not a FrameError. */
export type FrameErrorCode =
  | 'BAD_MAGIC'
  | 'BAD_SEQ'
  | 'BAD_MSEQ'
  | 'BAD_PATH'
  | 'BAD_PAYLOAD'
  | 'FENCE_STALE'
  | 'VFS_CONFLICT'
  | 'RING_TIMEOUT'
  | 'PROTO_MISMATCH'

/**
 * A protocol violation. The code is the wire code an ERROR frame would carry;
 * a decoder rejects locally instead of sending that frame.
 */
export class FrameError extends Error {
  readonly code: FrameErrorCode
  /** Header seq of the offending frame, when known. */
  readonly refSeq: bigint | undefined

  constructor(code: FrameErrorCode, message: string, refSeq?: bigint) {
    super(message)
    this.name = 'FrameError'
    this.code = code
    this.refSeq = refSeq
  }
}

/** WAL failures of wal.md §2, §3 and §10. */
export type WalErrorCode = 'WAL_BAD_HEADER' | 'WAL_BAD_CRC' | 'WAL_BAD_RECORD'

/** A malformed or corrupt WAL segment header or record. */
export class WalError extends Error {
  readonly code: WalErrorCode

  constructor(code: WalErrorCode, message: string) {
    super(message)
    this.name = 'WalError'
    this.code = code
  }
}
