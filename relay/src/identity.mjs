// SPDX-License-Identifier: MIT
// PCLink identity primitives used by the relay plane.
//
// The relay is self-contained by contract: it uses only the machineId
// derivation and Ed25519 verification here.  It never derives E2E keys and
// never imports pclink/core (change record §13.4).

import { createHash, createPublicKey, verify } from 'node:crypto'
import { base32Lower } from './base64url.mjs'

export const RELAY_AUTH_DOMAIN = 'pclink-v1/relay-auth'

// DER prefix for a raw 32-byte Ed25519 public key in SubjectPublicKeyInfo.
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex')

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest()
}

export function machineIdFromPublicKey(rawPublicKey) {
  const raw = Buffer.from(rawPublicKey)
  if (raw.length !== 32) throw new Error('machineId input must be a raw 32-byte Ed25519 public key')
  return base32Lower(sha256(raw)).slice(0, 26)
}

export function relayAuthTranscript(origin, nonceRaw) {
  const nonce = Buffer.from(nonceRaw)
  if (nonce.length !== 32) throw new Error('relay auth nonce must be 32 bytes')
  return Buffer.concat([
    Buffer.from(RELAY_AUTH_DOMAIN, 'utf8'),
    Buffer.from([0]),
    Buffer.from(String(origin), 'utf8'),
    Buffer.from([0]),
    nonce,
  ])
}

export function ed25519PublicKeyFromRaw(rawPublicKey) {
  const raw = Buffer.from(rawPublicKey)
  if (raw.length !== 32) throw new Error('Ed25519 public key must be 32 bytes')
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  })
}

export function verifyRelayAuthSignature(publicKeyRaw, origin, nonceRaw, signatureRaw) {
  const signature = Buffer.from(signatureRaw)
  if (signature.length !== 64) return false
  try {
    return verify(
      null,
      relayAuthTranscript(origin, nonceRaw),
      ed25519PublicKeyFromRaw(publicKeyRaw),
      signature,
    )
  } catch {
    return false
  }
}

export function hashPrefix(value, hexChars = 8) {
  return sha256(Buffer.from(String(value), 'utf8')).toString('hex').slice(0, hexChars)
}
