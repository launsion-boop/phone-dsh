/** Ed25519/X25519 identity primitives built only on `node:crypto` (§2.2/§5.2). */

import {
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  sign,
  verify,
} from 'node:crypto'
import { concatBytes, hmacSha256, machineIdFromPublicKey, randomBytes, sha256 } from './encoding.mjs'
import { pclinkError } from './errors.mjs'

const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')
const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')

function rawPublicFromPrivate(privateKey) {
  const der = createPublicKey(privateKey).export({ format: 'der', type: 'spki' })
  return Buffer.from(der.subarray(der.length - 32))
}

function publicKeyObject(raw, crv) {
  if (!(raw instanceof Uint8Array) || raw.length !== 32) throw pclinkError('bad_frame', `${crv} public key must be 32 bytes`)
  return createPublicKey({
    key: { kty: 'OKP', crv, x: Buffer.from(raw).toString('base64url') },
    format: 'jwk',
  })
}

/**
 * Build an Ed25519 machine identity from a raw 32-byte seed.
 * @param {Uint8Array} seed Raw 32-byte seed.
 * @returns {{seed: Buffer, privateKey: import('node:crypto').KeyObject, publicKey: Buffer, machineId: string, fingerprint: string}}
 */
export function identityFromSeed(seed) {
  if (!(seed instanceof Uint8Array) || seed.length !== 32) throw pclinkError('bad_frame', 'Ed25519 seed must be 32 bytes')
  const key = Buffer.from(seed)
  const privateKey = createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, key]),
    format: 'der',
    type: 'pkcs8',
  })
  const publicKey = rawPublicFromPrivate(privateKey)
  const machineId = machineIdFromPublicKey(publicKey)
  return {
    seed: key,
    privateKey,
    publicKey,
    machineId,
    fingerprint: machineId.slice(0, 12),
  }
}

/**
 * Generate a fresh Ed25519 identity with a CSPRNG.
 * @returns {ReturnType<typeof identityFromSeed>} identity.
 */
export function generateIdentity() {
  return identityFromSeed(randomBytes(32))
}

/**
 * Generate a fresh ephemeral X25519 key pair (never reused across handshakes).
 * @returns {{privateKey: import('node:crypto').KeyObject, publicKey: Buffer}}
 */
export function generateEphemeralX25519() {
  const seed = randomBytes(32)
  const privateKey = createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  })
  return { privateKey, publicKey: rawPublicFromPrivate(privateKey) }
}

/**
 * Build an X25519 key pair from a raw 32-byte seed (test vectors use seeded ephemerals).
 * @param {Uint8Array} seed Raw 32-byte seed.
 * @returns {{privateKey: import('node:crypto').KeyObject, publicKey: Buffer}}
 */
export function x25519FromSeed(seed) {
  if (!(seed instanceof Uint8Array) || seed.length !== 32) throw pclinkError('bad_frame', 'X25519 seed must be 32 bytes')
  const privateKey = createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, Buffer.from(seed)]),
    format: 'der',
    type: 'pkcs8',
  })
  return { privateKey, publicKey: rawPublicFromPrivate(privateKey) }
}

/**
 * X25519 shared secret, rejecting an all-zero peer key and a zero result.
 * @param {import('node:crypto').KeyObject} privateKey Local ephemeral private key.
 * @param {Uint8Array} peerPublicRaw Peer raw 32-byte public key.
 * @returns {Buffer} 32-byte shared secret.
 */
export function x25519Dh(privateKey, peerPublicRaw) {
  if (!(peerPublicRaw instanceof Uint8Array) || peerPublicRaw.length !== 32) {
    throw pclinkError('auth_failed', 'X25519 public key must be 32 bytes')
  }
  if (Buffer.from(peerPublicRaw).equals(Buffer.alloc(32))) throw pclinkError('auth_failed', 'all-zero X25519 public key')
  let shared
  try {
    shared = diffieHellman({ privateKey, publicKey: publicKeyObject(peerPublicRaw, 'X25519') })
  } catch {
    throw pclinkError('auth_failed', 'invalid X25519 public key')
  }
  if (shared.length !== 32 || shared.equals(Buffer.alloc(32))) throw pclinkError('auth_failed', 'X25519 shared secret is zero')
  return shared
}

/**
 * Sign bytes with an Ed25519 identity.
 * @param {import('node:crypto').KeyObject} privateKey Ed25519 private key.
 * @param {Uint8Array} message Message bytes.
 * @returns {Buffer} 64-byte signature.
 */
export function ed25519Sign(privateKey, message) {
  return sign(null, Buffer.from(message), privateKey)
}

/**
 * Verify a raw Ed25519 signature.
 * @param {Uint8Array} publicKeyRaw Raw 32-byte public key.
 * @param {Uint8Array} message Message bytes.
 * @param {Uint8Array} signature 64-byte signature.
 * @returns {boolean} true when valid.
 */
export function ed25519Verify(publicKeyRaw, message, signature) {
  if (!(signature instanceof Uint8Array) || signature.length !== 64) return false
  try {
    return verify(null, Buffer.from(message), publicKeyObject(publicKeyRaw, 'Ed25519'), Buffer.from(signature))
  } catch {
    return false
  }
}

/**
 * Admin server-proof HMAC (§8.2): HMAC-SHA256(token, "pclink-v1/admin-proof" || 0x00 || nonce).
 * @param {Uint8Array} token Admin token bytes.
 * @param {Uint8Array} nonce Raw 32-byte nonce.
 * @returns {Buffer} 32-byte proof.
 */
export function adminProof(token, nonce) {
  return hmacSha256(token, concatBytes(Buffer.from('pclink-v1/admin-proof', 'utf8'), Buffer.from([0]), nonce))
}

/**
 * Validate a raw identity seed length.
 * @param {Uint8Array} bytes Raw bytes from identity.key.
 * @returns {Buffer} 32-byte seed.
 */
export function seedAsIs(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length !== 32) throw new Error('identity seed must be 32 bytes')
  return Buffer.from(bytes)
}

/**
 * Derive a machineId from raw key bytes (test/helper form).
 * @param {Uint8Array} raw Raw Ed25519 public key.
 * @returns {string} machineId.
 */
export function machineIdOf(raw) {
  return machineIdFromPublicKey(raw)
}

/**
 * Label-derived test identity matching the shared vectors' rule.
 * @param {string} label Public test label.
 * @returns {ReturnType<typeof identityFromSeed>} identity.
 */
export function testIdentity(label) {
  return identityFromSeed(sha256(Buffer.from(label, 'utf8')))
}
