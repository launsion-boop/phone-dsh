/** Relay origin normalization and the relay-plane codecs (§3.1-§3.7). */

import { b64urlDecode, b64urlEncode, validateName } from './encoding.mjs'
import { isPairCloseReason, RELAY_ERROR_CODES, pclinkError } from './errors.mjs'
import { parseStrictJsonObject } from './json.mjs'
import { ed25519Sign, ed25519Verify } from './identity.mjs'
import { machineIdFromPublicKey } from './encoding.mjs'

const MACHINE_ID = /^[a-z2-7]{26}$/
const SID = /^[A-Za-z0-9_-]{22}$/
const ID = /^[A-Za-z0-9._:-]{1,64}$/
const RENDEZVOUS = /^[A-Za-z0-9_-]{22}$/
const LOOPBACK_HOST = /^localhost$|^127\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$/

/**
 * Validate and normalize the §3.1 origin form. Uppercase is rejected, never lowered.
 * @param {unknown} origin Candidate origin.
 * @returns {string} the same valid origin.
 */
export function validateRelayOrigin(origin) {
  if (typeof origin !== 'string' || origin.length < 1 || origin.length > 128) {
    throw pclinkError('bad_frame', 'relay origin must be 1-128 characters')
  }
  if (!/^[\x20-\x7e]+$/.test(origin)) throw pclinkError('bad_frame', 'relay origin must be ASCII')
  if (/[A-Z]/.test(origin)) throw pclinkError('bad_frame', 'relay origin must be lowercase')
  const match = /^(https?):\/\/([a-z0-9][a-z0-9.-]*)(?::([0-9]{1,5}))?$/.exec(origin)
  if (match === null) throw pclinkError('bad_frame', 'invalid relay origin')
  const [, scheme, host, portText] = match
  if (host.includes('..') || host.startsWith('.') || host.endsWith('.')) throw pclinkError('bad_frame', 'invalid relay host')
  // §3.1: cleartext WebSocket is allowed only for loopback tests.
  if (scheme === 'http' && !LOOPBACK_HOST.test(host)) {
    throw pclinkError('bad_frame', 'http relay origin is loopback-only')
  }
  if (portText !== undefined) {
    const port = Number(portText)
    if (port < 1 || port > 65535) throw pclinkError('bad_frame', 'relay port out of range')
    if ((scheme === 'https' && port === 443) || (scheme === 'http' && port === 80)) {
      throw pclinkError('bad_frame', 'default relay port must be omitted')
    }
  }
  return origin
}

/**
 * Derive the WebSocket URL from a validated origin (§3.1).
 * @param {string} origin Valid relay origin.
 * @returns {string} `wss://.../` or `ws://.../`.
 */
export function relayWsUrl(origin) {
  const valid = validateRelayOrigin(origin)
  return `${valid.startsWith('https://') ? 'wss' : 'ws'}://${valid.slice(valid.indexOf('://') + 3)}/`
}

/**
 * Validate an origin claimed by a received challenge against the dialed origin.
 * @param {unknown} claimed Claimed origin.
 * @param {string} expected Dialed/pinned origin.
 * @returns {string} the claimed origin.
 */
export function requireSameOrigin(claimed, expected) {
  if (typeof claimed !== 'string' || claimed !== expected) throw pclinkError('auth_failed', 'relay origin mismatch')
  validateRelayOrigin(claimed)
  return claimed
}

function requireObject(value, where) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw pclinkError('bad_frame', `${where} must be an object`)
  }
}

function requireExactMembers(value, required, optional, where) {
  requireObject(value, where)
  for (const name of required) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `${where} missing ${name}`)
  }
  const allowed = new Set([...required, ...optional])
  for (const name of Object.keys(value)) {
    if (!allowed.has(name)) throw pclinkError('bad_frame', `${where} unknown member ${name}`)
  }
}

function requireMachineId(value, where) {
  if (typeof value !== 'string' || !MACHINE_ID.test(value)) throw pclinkError('bad_frame', `${where} is not a machineId`)
  return value
}

function requireSid(value, where) {
  if (typeof value !== 'string' || !SID.test(value)) throw pclinkError('bad_frame', `${where} is not a sid`)
  return value
}

function requireId(value, where) {
  if (typeof value !== 'string' || !ID.test(value)) throw pclinkError('bad_frame', `${where} is not an id`)
  return value
}

function requireRendezvous(value, where) {
  if (typeof value !== 'string' || !RENDEZVOUS.test(value)) throw pclinkError('bad_frame', `${where} is not a rendezvous`)
  return value
}

function requireText(value, where, maxBytes) {
  if (typeof value !== 'string') throw pclinkError('bad_frame', `${where} must be a string`)
  if (Buffer.byteLength(value, 'utf8') > maxBytes) throw pclinkError('bad_frame', `${where} is too long`)
  if (value.includes('\u0000')) throw pclinkError('bad_frame', `${where} contains U+0000`)
  return value
}

/**
 * Validate `relay.challenge`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayChallenge(value) {
  requireExactMembers(value, ['v', 'type', 'nonce', 'relay'], [], 'relay.challenge')
  if (value.v !== 1 || value.type !== 'relay.challenge') throw pclinkError('bad_frame', 'not a relay.challenge')
  b64urlDecode(value.nonce, { length: 32 })
  // The exact-origin comparison is the auth boundary; requireSameOrigin rejects
  // uppercase or any other mismatch as auth_failed before the origin is trusted.
  if (typeof value.relay !== 'string' || value.relay.length < 1 || value.relay.length > 128) {
    throw pclinkError('bad_frame', 'relay.challenge.relay')
  }
  return value
}

/**
 * Validate `relay.ready`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayReady(value) {
  requireExactMembers(value, ['v', 'type', 'machineId', 'role'], [], 'relay.ready')
  if (value.v !== 1 || value.type !== 'relay.ready') throw pclinkError('bad_frame', 'not a relay.ready')
  requireMachineId(value.machineId, 'relay.ready.machineId')
  if (value.role !== 'pc' && value.role !== 'phone') throw pclinkError('bad_frame', 'relay.ready.role')
  return value
}

/**
 * Validate `relay.error`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayError(value) {
  requireExactMembers(value, ['v', 'type', 'code'], ['message', 'id', 'streamId', 'sid', 'retryAfterMs'], 'relay.error')
  if (value.v !== 1 || value.type !== 'relay.error') throw pclinkError('bad_frame', 'not a relay.error')
  if (!RELAY_ERROR_CODES.includes(value.code)) throw pclinkError('bad_frame', 'unknown relay error code')
  if (value.message !== undefined) requireText(value.message, 'relay.error.message', 2048)
  if (value.id !== undefined) requireId(value.id, 'relay.error.id')
  if (value.streamId !== undefined) requireId(value.streamId, 'relay.error.streamId')
  if (value.sid !== undefined) requireSid(value.sid, 'relay.error.sid')
  if (value.retryAfterMs !== undefined && (!Number.isInteger(value.retryAfterMs) || value.retryAfterMs < 0 || value.retryAfterMs > 86_400_000)) {
    throw pclinkError('bad_frame', 'relay.error.retryAfterMs')
  }
  return value
}

/**
 * Validate `relay.offline`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayOffline(value) {
  requireExactMembers(value, ['v', 'type', 'to'], ['id', 'streamId', 'sid'], 'relay.offline')
  if (value.v !== 1 || value.type !== 'relay.offline') throw pclinkError('bad_frame', 'not a relay.offline')
  requireMachineId(value.to, 'relay.offline.to')
  if (value.id !== undefined) requireId(value.id, 'relay.offline.id')
  if (value.streamId !== undefined) requireId(value.streamId, 'relay.offline.streamId')
  if (value.sid !== undefined) requireSid(value.sid, 'relay.offline.sid')
  return value
}

/**
 * Validate `relay.allow`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayAllow(value) {
  requireExactMembers(value, ['v', 'type', 'peers'], [], 'relay.allow')
  if (value.v !== 1 || value.type !== 'relay.allow') throw pclinkError('bad_frame', 'not a relay.allow')
  if (!Array.isArray(value.peers) || value.peers.length > 1024) throw pclinkError('bad_frame', 'relay.allow.peers')
  const seen = new Set()
  for (const peer of value.peers) {
    requireMachineId(peer, 'relay.allow.peers[]')
    if (seen.has(peer)) throw pclinkError('bad_frame', 'relay.allow.peers duplicate')
    seen.add(peer)
  }
  return value
}

/**
 * Validate one relay heartbeat frame.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayHeartbeat(value) {
  requireExactMembers(value, ['v', 'type', 'nonce'], [], 'relay.ping/pong')
  if (value.v !== 1 || (value.type !== 'relay.ping' && value.type !== 'relay.pong')) {
    throw pclinkError('bad_frame', 'not a relay heartbeat')
  }
  b64urlDecode(value.nonce, { length: 16 })
  return value
}

/**
 * Validate reserved `relay.redirect`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayRedirect(value) {
  requireExactMembers(value, ['v', 'type', 'url'], [], 'relay.redirect')
  if (value.v !== 1 || value.type !== 'relay.redirect') throw pclinkError('bad_frame', 'not a relay.redirect')
  if (typeof value.url !== 'string' || value.url.length > 512) throw pclinkError('bad_frame', 'relay.redirect.url')
  new URL(value.url)
  return value
}

function validatePairBase(value, type, required, optional) {
  requireExactMembers(value, ['v', 'type', 'rendezvous', ...required], optional, type)
  if (value.v !== 1 || value.type !== type) throw pclinkError('bad_frame', `not a ${type}`)
  requireRendezvous(value.rendezvous, `${type}.rendezvous`)
}

/**
 * Validate `relay.pair.open` / `relay.pair.join`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayPairRequest(value) {
  requireObject(value, 'relay.pair request')
  if (value.type !== 'relay.pair.open' && value.type !== 'relay.pair.join') throw pclinkError('bad_frame', 'not a relay.pair request')
  validatePairBase(value, value.type, [], [])
  return value
}

/**
 * Validate `relay.pair.joined`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayPairJoined(value) {
  validatePairBase(value, 'relay.pair.joined', ['role', 'peerMachineId'], [])
  if (value.role !== 'pc' && value.role !== 'phone') throw pclinkError('bad_frame', 'relay.pair.joined.role')
  requireMachineId(value.peerMachineId, 'relay.pair.joined.peerMachineId')
  return value
}

/**
 * Validate `relay.pair.message`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayPairMessage(value) {
  validatePairBase(value, 'relay.pair.message', ['payload'], [])
  requireObject(value.payload, 'relay.pair.message.payload')
  return value
}

/**
 * Validate `relay.pair.close`.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayPairClose(value) {
  validatePairBase(value, 'relay.pair.close', ['reason'], [])
  if (!isPairCloseReason(value.reason)) throw pclinkError('bad_frame', 'relay.pair.close.reason')
  return value
}

/**
 * Validate one `e2e` outer frame shape (§5.4). AEAD contents are checked separately.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateE2eFrame(value) {
  requireExactMembers(value, ['v', 'type', 'sid', 'seq', 'from', 'to', 'body'], [], 'e2e')
  if (value.v !== 1 || value.type !== 'e2e') throw pclinkError('bad_frame', 'not an e2e frame')
  requireSid(value.sid, 'e2e.sid')
  requireMachineId(value.from, 'e2e.from')
  requireMachineId(value.to, 'e2e.to')
  if (!Number.isInteger(value.seq) || value.seq < 0 || value.seq > 1_048_575) throw pclinkError('bad_frame', 'e2e.seq')
  b64urlDecode(value.body)
  return value
}

/**
 * Validate one `e2e.handshake` outer frame shape; body type/direction is checked by the handshake codec.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateE2eHandshakeOuter(value) {
  requireExactMembers(value, ['v', 'type', 'sid', 'from', 'to', 'body'], [], 'e2e.handshake')
  if (value.v !== 1 || value.type !== 'e2e.handshake') throw pclinkError('bad_frame', 'not an e2e.handshake frame')
  requireSid(value.sid, 'e2e.handshake.sid')
  requireMachineId(value.from, 'e2e.handshake.from')
  requireMachineId(value.to, 'e2e.handshake.to')
  requireObject(value.body, 'e2e.handshake.body')
  return value
}

/**
 * Validate any registered relay-plane frame.
 * @param {unknown} value Parsed frame.
 * @returns {Record<string, unknown>} validated frame.
 */
export function validateRelayFrame(value) {
  requireObject(value, 'relay frame')
  if (value.v !== 1) throw pclinkError('version_unsupported', 'unknown relay frame version')
  switch (value.type) {
    case 'relay.challenge': return validateRelayChallenge(value)
    case 'relay.ready': return validateRelayReady(value)
    case 'relay.error': return validateRelayError(value)
    case 'relay.offline': return validateRelayOffline(value)
    case 'relay.allow': return validateRelayAllow(value)
    case 'relay.redirect': return validateRelayRedirect(value)
    case 'relay.ping':
    case 'relay.pong': return validateRelayHeartbeat(value)
    case 'relay.pair.open':
    case 'relay.pair.join': return validateRelayPairRequest(value)
    case 'relay.pair.joined': return validateRelayPairJoined(value)
    case 'relay.pair.message': return validateRelayPairMessage(value)
    case 'relay.pair.close': return validateRelayPairClose(value)
    case 'e2e': return validateE2eFrame(value)
    case 'e2e.handshake': return validateE2eHandshakeOuter(value)
    default: throw pclinkError('bad_frame', `unknown relay frame type ${String(value.type)}`)
  }
}

/**
 * Parse and validate one relay text frame, enforcing the 16 MiB cap.
 * @param {string | Uint8Array} text Frame text.
 * @param {{maxBytes?: number}} [options] Frame byte cap.
 * @returns {{frame: Record<string, unknown>, bytes: number}} parsed frame.
 */
export function parseRelayFrame(text, options = {}) {
  const bytes = typeof text === 'string' ? Buffer.byteLength(text, 'utf8') : text.byteLength
  const cap = options.maxBytes ?? 16 * 1024 * 1024
  if (bytes > cap) throw pclinkError('frame_too_large', 'relay frame exceeds 16 MiB')
  const frame = parseStrictJsonObject(text, { maxBytes: cap })
  return { frame: validateRelayFrame(frame), bytes }
}

/**
 * The §3.2 relay-auth transcript.
 * @param {string} relay Origin exactly from the challenge.
 * @param {Uint8Array} nonce Raw 32-byte challenge nonce.
 * @returns {Buffer} transcript bytes.
 */
export function relayAuthTranscript(relay, nonce) {
  if (!(nonce instanceof Uint8Array) || nonce.length !== 32) throw pclinkError('bad_frame', 'relay nonce must be 32 bytes')
  return Buffer.concat([
    Buffer.from('pclink-v1/relay-auth', 'utf8'),
    Buffer.from([0]),
    Buffer.from(relay, 'utf8'),
    Buffer.from([0]),
    Buffer.from(nonce),
  ])
}

/**
 * Build a signed `peer.auth` frame for one validated challenge.
 * @param {{privateKey: import('node:crypto').KeyObject, publicKey: Uint8Array, machineId: string}} identity Local identity.
 * @param {{origin: string, nonce: string}} challenge Validated challenge.
 * @param {'phone'|'pc'} role Connection role claim.
 * @returns {Record<string, unknown>} peer.auth frame.
 */
export function buildRelayAuth(identity, challenge, role) {
  const nonce = b64urlDecode(challenge.nonce, { length: 32 })
  const signature = ed25519Sign(identity.privateKey, relayAuthTranscript(challenge.origin, nonce))
  return {
    v: 1,
    type: 'peer.auth',
    machineId: identity.machineId,
    publicKey: b64urlEncode(identity.publicKey),
    role,
    sig: b64urlEncode(signature),
  }
}

/**
 * Validate and cryptographically verify one `peer.auth` frame.
 * @param {unknown} value Parsed frame.
 * @param {{origin: string, nonce: Uint8Array}} challenge Authenticated challenge.
 * @returns {{machineId: string, publicKey: string, role: string}} verified facts.
 */
export function verifyRelayAuth(value, challenge) {
  requireExactMembers(value, ['v', 'type', 'machineId', 'publicKey', 'role', 'sig'], [], 'peer.auth')
  if (value.v !== 1 || value.type !== 'peer.auth') throw pclinkError('bad_frame', 'not a peer.auth')
  requireMachineId(value.machineId, 'peer.auth.machineId')
  if (value.role !== 'phone' && value.role !== 'pc') throw pclinkError('auth_failed', 'peer.auth.role')
  const publicKey = b64urlDecode(value.publicKey, { length: 32 })
  const signature = b64urlDecode(value.sig, { length: 64 })
  if (machineIdFromPublicKey(publicKey) !== value.machineId) throw pclinkError('auth_failed', 'peer.auth machineId mismatch')
  if (!ed25519Verify(publicKey, relayAuthTranscript(challenge.origin, challenge.nonce), signature)) {
    throw pclinkError('auth_failed', 'peer.auth signature invalid')
  }
  return { machineId: value.machineId, publicKey: value.publicKey, role: value.role }
}

/**
 * Validate a `peer.hello` display name from an already-parsed object.
 * @param {unknown} name Candidate name.
 * @returns {string} the validated name.
 */
export function validatePeerName(name) {
  return validateName(name)
}
