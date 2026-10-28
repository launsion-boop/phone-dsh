// SPDX-License-Identifier: MIT
/**
 * Big-endian byte helpers for the phone-dsh-v1 wire formats.
 * @module @phone-dsh/dsh-channel/bytes
 */

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder('utf-8', { fatal: true })

/** Encode a string as UTF-8. */
export function encodeUtf8(text: string): Uint8Array {
  return textEncoder.encode(text)
}

/**
 * Decode UTF-8 bytes, rejecting invalid sequences.
 * @throws {TypeError} When the bytes are not valid UTF-8.
 */
export function decodeUtf8(bytes: Uint8Array): string {
  return textDecoder.decode(bytes)
}

/** Write a u16 big-endian value. */
export function writeU16be(out: Uint8Array, offset: number, value: number): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    throw new RangeError(`u16 out of range: ${String(value)}`)
  }
  out[offset] = (value >>> 8) & 0xff
  out[offset + 1] = value & 0xff
}

/** Write a u32 big-endian value. */
export function writeU32be(out: Uint8Array, offset: number, value: number): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new RangeError(`u32 out of range: ${String(value)}`)
  }
  out[offset] = Math.floor(value / 0x1000000) & 0xff
  out[offset + 1] = (value >>> 16) & 0xff
  out[offset + 2] = (value >>> 8) & 0xff
  out[offset + 3] = value & 0xff
}

/** Write a u64 big-endian value. */
export function writeU64be(out: Uint8Array, offset: number, value: bigint): void {
  if (typeof value !== 'bigint' || value < 0n || value > 0xffffffffffffffffn) {
    throw new RangeError(`u64 out of range: ${String(value)}`)
  }
  out[offset] = Number((value >> 56n) & 0xffn)
  out[offset + 1] = Number((value >> 48n) & 0xffn)
  out[offset + 2] = Number((value >> 40n) & 0xffn)
  out[offset + 3] = Number((value >> 32n) & 0xffn)
  out[offset + 4] = Number((value >> 24n) & 0xffn)
  out[offset + 5] = Number((value >> 16n) & 0xffn)
  out[offset + 6] = Number((value >> 8n) & 0xffn)
  out[offset + 7] = Number(value & 0xffn)
}

/** Read a u16 big-endian value. */
export function readU16be(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! << 8) | bytes[offset + 1]!)
}

/** Read a u32 big-endian value. */
export function readU32be(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! * 0x1000000)
    + ((bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!))
}

/** Read a u64 big-endian value. */
export function readU64be(bytes: Uint8Array, offset: number): bigint {
  let value = 0n
  for (let index = 0; index < 8; index++) {
    value = (value << 8n) | BigInt(bytes[offset + index]!)
  }
  return value
}

/** Concatenate byte arrays in order. */
export function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0
  for (const part of parts) length += part.byteLength
  const out = new Uint8Array(length)
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.byteLength
  }
  return out
}

/** Lowercase hexadecimal, the form golden vectors use. */
export function bytesToHex(bytes: Uint8Array): string {
  let text = ''
  for (const byte of bytes) text += byte.toString(16).padStart(2, '0')
  return text
}

/** Parse lowercase or uppercase hexadecimal; whitespace is not accepted. */
export function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || /[^0-9a-fA-F]/.test(hex)) {
    throw new TypeError(`invalid hex: ${JSON.stringify(hex)}`)
  }
  const out = new Uint8Array(hex.length / 2)
  for (let index = 0; index < out.length; index++) {
    out[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16)
  }
  return out
}

/** Byte-wise equality. */
export function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false
  for (let index = 0; index < left.byteLength; index++) {
    if (left[index] !== right[index]) return false
  }
  return true
}
