// SPDX-License-Identifier: MIT
// Canonical base64url (RFC 4648, no padding) and RFC 4648 base32 helpers.
//
// PCLink b64url fields must reject padding, a non-canonical re-encoding (the
// unused low bits of the final character must be zero) and a wrong decoded
// length.  Re-encoding is the simplest reliable canonicality check.

const B64URL = /^[A-Za-z0-9_-]+$/
const B32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

export function encodeB64url(bytes) {
  return Buffer.from(bytes).toString('base64url')
}

export function decodeB64url(text, expectedBytes) {
  if (typeof text !== 'string' || !B64URL.test(text)) return null
  let bytes
  try {
    bytes = Buffer.from(text, 'base64url')
  } catch {
    return null
  }
  if (bytes.toString('base64url') !== text) return null
  if (expectedBytes !== undefined && bytes.length !== expectedBytes) return null
  return bytes
}

export function base32Lower(bytes) {
  const input = Buffer.from(bytes)
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of input) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      out += B32_ALPHABET[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }
  if (bits > 0) out += B32_ALPHABET[(value << (5 - bits)) & 31]
  return out.toLowerCase()
}
