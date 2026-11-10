/** PCLink v1 conventions (§2.1): base64url, base32, UTF-8, names, hashes and time. */

import { createHash, createHmac, hkdfSync, randomBytes as nodeRandomBytes, timingSafeEqual } from 'node:crypto'
import { pclinkError } from './errors.mjs'

/** RFC 4648 base32 alphabet without padding. */
export const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

/** Crockford base32 alphabet (§4.1), no I/L/O/U. */
export const CROCKFORD_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

/** 1 MiB: single-value item threshold and soft chunk target (§6.2). */
export const CHUNK_BYTES = 1024 * 1024
/** 8 MiB: maximum reassembled value/result (§6.2). */
export const MAX_VALUE_BYTES = 8 * 1024 * 1024
/** 16 MiB: maximum relay text frame (§3.1). */
export const MAX_FRAME_BYTES = 16 * 1024 * 1024
/** B64url length cap for one chunk's `data` (§6.2). */
export const MAX_CHUNK_B64_CHARS = 1_500_000

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder('utf-8', { fatal: true })

/**
 * Encode bytes as unpadded RFC 4648 base64url.
 * @param {Uint8Array} bytes Raw bytes.
 * @returns {string} base64url text.
 */
export function b64urlEncode(bytes) {
  return Buffer.from(bytes).toString('base64url')
}

/**
 * Decode canonical unpadded base64url.
 *
 * Rejects padding, a non-canonical re-encoding (unused low bits non-zero), a
 * character outside the alphabet and, when `length` is passed, a wrong byte
 * length.
 * @param {unknown} text Candidate text.
 * @param {{length?: number}} [options] Exact decoded length.
 * @returns {Buffer} decoded bytes.
 */
export function b64urlDecode(text, options = {}) {
  if (typeof text !== 'string' || text.length === 0 || text.length % 4 === 1) {
    throw pclinkError('bad_frame', 'invalid base64url')
  }
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw pclinkError('bad_frame', 'invalid base64url character')
  let bytes
  try {
    bytes = Buffer.from(text, 'base64url')
  } catch {
    throw pclinkError('bad_frame', 'invalid base64url')
  }
  if (bytes.toString('base64url') !== text) throw pclinkError('bad_frame', 'non-canonical base64url')
  if (options.length !== undefined && bytes.length !== options.length) {
    throw pclinkError('bad_frame', `base64url decodes to ${String(bytes.length)} bytes, expected ${String(options.length)}`)
  }
  return bytes
}

/**
 * Encode bytes with RFC 4648 base32, uppercase, without padding.
 * @param {Uint8Array} bytes Raw bytes.
 * @returns {string} base32 text.
 */
export function base32Encode(bytes) {
  let output = ''
  let buffer = 0
  let bits = 0
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      output += BASE32_ALPHABET[(buffer >>> bits) & 31]
    }
  }
  if (bits > 0) output += BASE32_ALPHABET[(buffer << (5 - bits)) & 31]
  return output
}

/**
 * Derive the §2.2 machineId from a raw Ed25519 public key.
 * @param {Uint8Array} publicKeyRaw 32-byte raw Ed25519 public key.
 * @returns {string} 26 lowercase base32 characters (130 bits).
 */
export function machineIdFromPublicKey(publicKeyRaw) {
  if (!(publicKeyRaw instanceof Uint8Array) || publicKeyRaw.length !== 32) {
    throw pclinkError('bad_frame', 'Ed25519 public key must be 32 bytes')
  }
  return base32Encode(sha256(publicKeyRaw)).slice(0, 26).toLowerCase()
}

/**
 * Canonical human fingerprint `machineId[0:12]` grouped in threes (§2.2).
 * @param {string} machineId Valid 26-character machineId.
 * @returns {string} `xxxx-xxxx-xxxx`.
 */
export function fingerprintOf(machineId) {
  if (typeof machineId !== 'string' || !/^[a-z2-7]{26}$/.test(machineId)) {
    throw pclinkError('bad_frame', 'invalid machineId')
  }
  const value = machineId.slice(0, 12)
  return `${value.slice(0, 4)}-${value.slice(4, 8)}-${value.slice(8, 12)}`
}

/**
 * Normalize operator fingerprint input: ignore `-`, whitespace and letter case,
 * then require exactly 12 characters of the machineId alphabet (§2.2/§4.4).
 * @param {unknown} input Typed fingerprint.
 * @returns {string} 12 lowercase characters, no separators.
 */
export function normalizeFingerprintInput(input) {
  if (typeof input !== 'string') throw pclinkError('bad_frame', 'fingerprint must be a string')
  const normalized = input.replace(/[-\s]/g, '').toLowerCase()
  if (!/^[a-z2-7]{12}$/.test(normalized)) throw pclinkError('bad_frame', 'fingerprint must be 12 machineId characters')
  return normalized
}

/**
 * Compare a typed fingerprint with a machineId's canonical 60-bit prefix.
 * @param {string} machineId 26-character machineId.
 * @param {unknown} input Operator input.
 * @returns {boolean} true when normalized input equals the fingerprint.
 */
export function fingerprintMatches(machineId, input) {
  return normalizeFingerprintInput(input) === machineId.slice(0, 12)
}

/** C0/C1/FORMAT control check.
 * @param {number} codePoint Unicode code point.
 * @returns {boolean} true when the code point is C0, C1 or Unicode Cf.
 */
export function isControlOrFormat(codePoint) {
  if (codePoint < 0x20) return true
  if (codePoint >= 0x7f && codePoint <= 0x9f) return true
  return (
    codePoint === 0x00ad
    || (codePoint >= 0x0600 && codePoint <= 0x0605)
    || codePoint === 0x061c
    || codePoint === 0x06dd
    || codePoint === 0x070f
    || (codePoint >= 0x0890 && codePoint <= 0x0891)
    || codePoint === 0x08e2
    || codePoint === 0x180e
    || (codePoint >= 0x200b && codePoint <= 0x200f)
    || (codePoint >= 0x202a && codePoint <= 0x202e)
    || (codePoint >= 0x2060 && codePoint <= 0x2064)
    || (codePoint >= 0x2066 && codePoint <= 0x206f)
    || codePoint === 0xfeff
    || (codePoint >= 0xfff9 && codePoint <= 0xfffb)
    || codePoint === 0x110bd
    || codePoint === 0x110cd
    || (codePoint >= 0x13430 && codePoint <= 0x1343f)
    || (codePoint >= 0x1bca0 && codePoint <= 0x1bca3)
    || (codePoint >= 0x1d173 && codePoint <= 0x1d17a)
    || codePoint === 0xe0001
    || (codePoint >= 0xe0020 && codePoint <= 0xe007f)
  )
}

/**
 * Validate the §2.1 display-name rule: 1–64 UTF-8 bytes, NFC, no C0/C1/Cf.
 * A non-NFC value is rejected, never silently normalized.
 * @param {unknown} value Candidate name.
 * @param {string} [what] Field label for the message.
 * @returns {string} the unchanged name.
 */
export function validateName(value, what = 'name') {
  if (typeof value !== 'string') throw pclinkError('bad_frame', `${what} must be a string`)
  const bytes = Buffer.byteLength(value, 'utf8')
  if (bytes < 1 || bytes > 64) throw pclinkError('bad_frame', `${what} must be 1-64 UTF-8 bytes`)
  if (value.normalize('NFC') !== value) throw pclinkError('bad_frame', `${what} must be NFC-normalized`)
  for (const character of value) {
    const codePoint = character.codePointAt(0)
    if (isControlOrFormat(codePoint)) {
      throw pclinkError('bad_frame', `${what} contains a control/format character U+${codePoint.toString(16).toUpperCase()}`)
    }
  }
  return value
}

/**
 * Encode text as UTF-8, rejecting lone surrogates.
 * @param {string} value Text.
 * @returns {Buffer} UTF-8 bytes.
 */
export function utf8(value) {
  if (typeof value !== 'string') throw pclinkError('bad_frame', 'expected text')
  if (value.isWellFormed !== undefined && !value.isWellFormed()) throw pclinkError('bad_frame', 'unpaired surrogate')
  return Buffer.from(textEncoder.encode(value))
}

/**
 * Decode strict UTF-8.
 * @param {Uint8Array} bytes Bytes.
 * @returns {string} decoded text.
 */
export function decodeUtf8(bytes) {
  try {
    return textDecoder.decode(bytes)
  } catch {
    throw pclinkError('bad_frame', 'invalid UTF-8')
  }
}

/**
 * SHA-256 over concatenated bytes.
 * @param {Uint8Array} bytes Input.
 * @returns {Buffer} 32-byte digest.
 */
export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest()
}

/**
 * HMAC-SHA256 (32 bytes).
 * @param {Uint8Array} key Key bytes.
 * @param {Uint8Array} bytes Message.
 * @returns {Buffer} MAC.
 */
export function hmacSha256(key, bytes) {
  return createHmac('sha256', key).update(bytes).digest()
}

/**
 * HKDF-SHA256, 32-byte output (§4.4/§5.3).
 * @param {Uint8Array} ikm Input key material.
 * @param {Uint8Array} salt Salt.
 * @param {string} info UTF-8 info string.
 * @returns {Buffer} 32-byte output.
 */
export function hkdf32(ikm, salt, info) {
  return Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), 32))
}

/**
 * Concatenate byte chunks.
 * @param {...Uint8Array} chunks Byte chunks.
 * @returns {Buffer} concatenation.
 */
export function concatBytes(...chunks) {
  return Buffer.concat(chunks.map(chunk => Buffer.from(chunk)))
}

/**
 * Constant-time comparison for equal-length byte strings.
 * @param {Uint8Array} left Left bytes.
 * @param {Uint8Array} right Right bytes.
 * @returns {boolean} true when equal.
 */
export function timingSafeEqualBytes(left, right) {
  const a = Buffer.from(left)
  const b = Buffer.from(right)
  return a.length === b.length && timingSafeEqual(a, b)
}

/**
 * CSPRNG bytes.
 * @param {number} length Byte count.
 * @returns {Buffer} random bytes.
 */
export function randomBytes(length) {
  return nodeRandomBytes(length)
}

/**
 * Format a time as RFC 3339 UTC with second precision and trailing `Z` (§2.1).
 * @param {Date} [date] Time, default now.
 * @returns {string} canonical timestamp.
 */
export function formatRfc3339(date = new Date()) {
  return new Date(Math.floor(date.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/**
 * Parse the canonical RFC 3339 second-precision timestamp form.
 * @param {unknown} value Candidate text.
 * @returns {number} epoch milliseconds, or NaN when invalid.
 */
export function parseRfc3339(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return Number.NaN
  return Date.parse(value)
}

/**
 * Whether a value is a canonical timestamp.
 * @param {unknown} value Candidate.
 * @returns {boolean} true for the exact form.
 */
export function isRfc3339(value) {
  return typeof value === 'string' && !Number.isNaN(parseRfc3339(value)) && formatRfc3339(new Date(parseRfc3339(value))) === value
}

/**
 * Lowercase hex encoding.
 * @param {Uint8Array} bytes Bytes.
 * @returns {string} lowercase hex.
 */
export function hexEncode(bytes) {
  return Buffer.from(bytes).toString('hex')
}
