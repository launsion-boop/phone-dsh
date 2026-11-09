/** AEAD application frames: ChaCha20-Poly1305, nonce, AAD, strict seq and rekey counters (§5.4/§5.5). */

import {
  createCipheriv,
  createDecipheriv,
} from 'node:crypto'
import { b64urlDecode, b64urlEncode, decodeUtf8, utf8 } from './encoding.mjs'
import { pclinkError } from './errors.mjs'
import { validateE2eFrame } from './relay.mjs'

/** Soft sender threshold: 2^19 frames in one direction. */
export const SEQ_REKEY = 524_288
/** Hard frame cap: 2^20 frames in one direction. */
export const SEQ_MAX = 1_048_576
/** Soft sender threshold: 1 GiB plaintext in one direction. */
export const BYTE_REKEY = 1_073_741_824
/** Hard plaintext cap: 2 GiB in one direction. */
export const BYTE_HARD = 2_147_483_648

/**
 * 12-byte AEAD nonce: four zero bytes then the 8-byte big-endian seq.
 * @param {number} seq Frame sequence number.
 * @returns {Buffer} nonce bytes.
 */
export function aeadNonce(seq) {
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64BE(BigInt(seq), 4)
  return nonce
}

/**
 * Exact §5.4 AAD bytes.
 * @param {{sid: string, seq: number, from: string, to: string}} frame Validated outer fields.
 * @returns {Buffer} AAD bytes.
 */
export function aadBytes(frame) {
  return Buffer.concat([
    Buffer.from('pclink-v1/aad', 'utf8'), Buffer.from([0]),
    Buffer.from('1', 'utf8'), Buffer.from([0]),
    Buffer.from('e2e', 'utf8'), Buffer.from([0]),
    Buffer.from(frame.sid, 'utf8'), Buffer.from([0]),
    Buffer.from(String(frame.seq), 'utf8'), Buffer.from([0]),
    Buffer.from(frame.from, 'utf8'), Buffer.from([0]),
    Buffer.from(frame.to, 'utf8'),
  ])
}

/**
 * Encrypt one inner plaintext into an AEAD `body`.
 * @param {{key: Uint8Array, sid: string, seq: number, from: string, to: string, plaintext: string | Uint8Array}} input Frame fields.
 * @returns {string} b64url(ciphertext||tag).
 */
export function sealE2eBody(input) {
  const plaintext = typeof input.plaintext === 'string' ? utf8(input.plaintext) : Buffer.from(input.plaintext)
  const cipher = createCipheriv('chacha20-poly1305', Buffer.from(input.key), aeadNonce(input.seq), { authTagLength: 16 })
  cipher.setAAD(aadBytes(input))
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()])
  return b64urlEncode(Buffer.concat([ciphertext, cipher.getAuthTag()]))
}

/**
 * Decrypt one AEAD `body`; any outer-field change fails authentication.
 * @param {{key: Uint8Array, sid: string, seq: number, from: string, to: string, body: string}} input Frame fields.
 * @returns {Buffer} plaintext bytes.
 */
export function openE2eBody(input) {
  const body = b64urlDecode(input.body)
  if (body.length < 16) throw pclinkError('auth_failed', 'AEAD body too short')
  const ciphertext = body.subarray(0, body.length - 16)
  const tag = body.subarray(body.length - 16)
  let decipher
  try {
    decipher = createDecipheriv('chacha20-poly1305', Buffer.from(input.key), aeadNonce(input.seq), { authTagLength: 16 })
    decipher.setAAD(aadBytes(input))
    decipher.setAuthTag(tag)
    return Buffer.concat([decipher.update(ciphertext), decipher.final()])
  } catch {
    throw pclinkError('auth_failed', 'AEAD authentication failed')
  }
}

/**
 * Classify one incoming seq against the strict contiguous rule (§5.4).
 * @param {{first?: boolean, lastSeq?: number, seq: number, hardFrames?: number}} input Seq facts.
 * @returns {'accept'|'bad_frame'|'replay'|'session_expired'} outcome.
 */
export function classifySequence(input) {
  const hardFrames = input.hardFrames ?? SEQ_MAX
  if (!Number.isInteger(input.seq) || input.seq < 0) return 'bad_frame'
  if (input.seq >= hardFrames) return 'session_expired'
  if (input.first === true) return input.seq === 0 ? 'accept' : 'bad_frame'
  const lastSeq = input.lastSeq ?? -1
  if (input.seq <= lastSeq) return 'replay'
  if (input.seq !== lastSeq + 1) return 'bad_frame'
  return 'accept'
}

/**
 * Classify the receive-side plaintext hard cap backstop.
 * @param {{bytes: number, added: number, hardBytes?: number}} input Byte facts.
 * @returns {'accept'|'session_expired'} outcome.
 */
export function classifyBytes(input) {
  const hardBytes = input.hardBytes ?? BYTE_HARD
  return input.bytes + input.added > hardBytes ? 'session_expired' : 'accept'
}

/**
 * Build one sealed `e2e` outer frame and enforce the send-side hard cap.
 * @param {{v?: number, type?: string, sid: string, seq: number, from: string, to: string, body: string}} frame Plain fields.
 * @returns {Record<string, unknown>} frame object.
 */
export function buildE2eFrame(frame) {
  return {
    v: 1,
    type: 'e2e',
    sid: frame.sid,
    seq: frame.seq,
    from: frame.from,
    to: frame.to,
    body: frame.body,
  }
}

/**
 * One direction-pair of a PCLink session with strict contiguous-seq state and counters.
 */
export class FrameCrypto {
  /**
   * @param {{sendKey: Uint8Array, recvKey: Uint8Array, sid: string, from: string, to: string, softFrames?: number, softBytes?: number, hardFrames?: number, hardBytes?: number}} options Keys and counters.
   */
  constructor(options) {
    this.sendKey = Buffer.from(options.sendKey)
    this.recvKey = Buffer.from(options.recvKey)
    this.sid = options.sid
    this.from = options.from
    this.to = options.to
    this.softFrames = options.softFrames ?? SEQ_REKEY
    this.softBytes = options.softBytes ?? BYTE_REKEY
    this.hardFrames = options.hardFrames ?? SEQ_MAX
    this.hardBytes = options.hardBytes ?? BYTE_HARD
    this.sendSeq = 0
    this.lastSeq = -1
    this.sendBytes = 0
    this.recvBytes = 0
    this.closed = false
  }

  /**
   * Whether either direction has reached the soft rekey threshold.
   * @returns {boolean} true when the phone should start a rekey.
   */
  get needsRekey() {
    return this.sendSeq >= this.softFrames
      || this.lastSeq + 1 >= this.softFrames
      || this.sendBytes >= this.softBytes
      || this.recvBytes >= this.softBytes
  }

  /**
   * Whether either direction reached the hard cap (session must close).
   * @returns {boolean} true at/after 2^20 frames or 2 GiB.
   */
  get hardExceeded() {
    return this.sendSeq >= this.hardFrames
      || this.lastSeq + 1 >= this.hardFrames
      || this.sendBytes >= this.hardBytes
      || this.recvBytes >= this.hardBytes
  }

  /**
   * Seal one inner plaintext at the next seq.
   * @param {string} plaintext One inner message JSON text.
   * @returns {Record<string, unknown>} outer frame.
   */
  seal(plaintext) {
    if (this.closed) throw pclinkError('session_expired', 'session is closed')
    if (this.sendSeq >= this.hardFrames) throw pclinkError('session_expired', 'frame hard cap reached')
    const bytes = Buffer.byteLength(plaintext, 'utf8')
    if (this.sendBytes + bytes > this.hardBytes) throw pclinkError('session_expired', 'plaintext hard cap reached')
    const body = sealE2eBody({ key: this.sendKey, sid: this.sid, seq: this.sendSeq, from: this.from, to: this.to, plaintext })
    const frame = buildE2eFrame({ sid: this.sid, seq: this.sendSeq, from: this.from, to: this.to, body })
    this.sendSeq += 1
    this.sendBytes += bytes
    return frame
  }

  /**
   * Validate and decrypt one frame, enforcing direction, sid, seq and hard caps.
   * @param {unknown} value Parsed frame.
   * @returns {{plaintext: string, bytes: number}} decrypted inner text.
   */
  open(value) {
    if (this.closed) throw pclinkError('session_expired', 'session is closed')
    if (value?.v !== 1 || value?.type !== 'e2e') throw pclinkError('auth_failed', 'outer version/type change fails authentication')
    if (Number.isInteger(value?.seq) && value.seq >= this.hardFrames) throw pclinkError('session_expired', 'frame hard cap reached')
    const frame = validateE2eFrame(value)
    if (frame.from !== this.to || frame.to !== this.from) throw pclinkError('auth_failed', 'wrong frame direction')
    const sequence = classifySequence({ first: this.lastSeq < 0, lastSeq: this.lastSeq, seq: frame.seq, hardFrames: this.hardFrames })
    if (sequence === 'session_expired') throw pclinkError('session_expired', 'frame hard cap reached')
    if (sequence === 'replay') throw pclinkError('replay', 'replayed or non-increasing seq')
    if (sequence === 'bad_frame') throw pclinkError('bad_frame', 'sequence gap')
    const plaintextBytes = openE2eBody({ key: this.recvKey, sid: frame.sid, seq: frame.seq, from: frame.from, to: frame.to, body: frame.body })
    if (frame.sid !== this.sid) throw pclinkError('replay', 'cross-session frame')
    if (classifyBytes({ bytes: this.recvBytes, added: plaintextBytes.length, hardBytes: this.hardBytes }) === 'session_expired') {
      throw pclinkError('session_expired', 'plaintext hard cap reached')
    }
    this.lastSeq = frame.seq
    this.recvBytes += plaintextBytes.length
    let plaintext
    try {
      plaintext = decodeUtf8(plaintextBytes)
    } catch {
      throw pclinkError('bad_frame', 'inner message is not UTF-8')
    }
    return { plaintext, bytes: plaintextBytes.length }
  }

  /** Mark this direction-pair closed; keys are discarded by the owner. */
  close() {
    this.closed = true
  }
}
