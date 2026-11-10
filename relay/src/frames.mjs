// SPDX-License-Identifier: MIT
// Closed PCLink relay-plane frame shapes.
//
// This is the relay's real parser: the connection handler calls it for every
// authenticated frame, and the tests drive the same function with the shared
// schema samples and golden negative rows.  The relay never validates or
// decrypts `e2e.body`; it only checks the outer string shape.  `e2e.handshake`
// is plaintext by design, so its four body variants are shape-checked here
// (signatures/transcripts remain end-to-end responsibilities).

import { decodeB64url } from './base64url.mjs'
import { isCanonicalOrigin } from './origin.mjs'

export const SUITE = 'pclink-x25519-ed25519-chacha20poly1305-1'
export const HANDSHAKE_BODY_TYPES = new Set([
  'session.init',
  'session.resp',
  'session.confirm',
  'session.reject',
])
export const RELAY_ERROR_CODES = new Set([
  'unavailable',
  'unpaired',
  'auth_failed',
  'replaced',
  'session_expired',
  'replay',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
  'rendezvous_expired',
  'rendezvous_exhausted',
])
export const PAIR_CLOSE_REASONS = new Set([
  'paired',
  'cancelled',
  'rejected',
  'peer_offline',
  'rendezvous_expired',
  'rendezvous_exhausted',
  'auth_failed',
  'storage',
  'timeout',
])
export const SESSION_REJECT_CODES = new Set([
  'unpaired',
  'auth_failed',
  'version_unsupported',
  'rate_limited',
  'bad_frame',
  'replay',
  'frame_too_large',
  'unavailable',
  'session_expired',
])

export const RELAY_PLANE_SCHEMAS = new Set([
  'relay-challenge.schema.json',
  'relay-auth.schema.json',
  'relay-ready.schema.json',
  'relay-allow.schema.json',
  'relay-offline.schema.json',
  'relay-error.schema.json',
  'relay-heartbeat.schema.json',
  'relay-redirect.schema.json',
  'relay-pair.schema.json',
  'e2e-frame.schema.json',
  'e2e-handshake.schema.json',
])

const MACHINE_ID = /^[a-z2-7]{26}$/
const RENDEZVOUS = /^[A-Za-z0-9_-]{22}$/
const CLIENT_ID = /^[A-Za-z0-9._:-]{1,64}$/
const B64URL_TEXT = /^[A-Za-z0-9_-]+$/

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function fail(message, code = 'bad_frame') {
  return { ok: false, code, message }
}

function keysExactly(value, required, optional = []) {
  const actual = Object.keys(value)
  if (actual.length < required.length || actual.length > required.length + optional.length) return false
  const allowed = new Set([...required, ...optional])
  for (const key of actual) {
    if (!allowed.has(key)) return false
  }
  return required.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

function isIntegerInRange(value, minimum, maximum) {
  return typeof value === 'number' && Number.isInteger(value) && value >= minimum && value <= maximum
}

function isString(value, maximumLength) {
  return typeof value === 'string' && value.length <= maximumLength
}

function isMachineId(value) {
  return typeof value === 'string' && MACHINE_ID.test(value)
}

function isRole(value) {
  return value === 'phone' || value === 'pc'
}

function isRendezvous(value) {
  return typeof value === 'string' && RENDEZVOUS.test(value)
}

function isSid(value) {
  return decodeB64url(value, 16) !== null
}

function isBytes(value, length) {
  return decodeB64url(value, length) !== null
}

function isClientId(value) {
  return typeof value === 'string' && CLIENT_ID.test(value)
}

function isE2eBody(value) {
  return typeof value === 'string'
    && value.length >= 22
    && value.length <= 22_000_000
    && B64URL_TEXT.test(value)
}

function initBody(value) {
  if (!keysExactly(value, ['v', 'type', 'sid', 'suite', 'eph', 'nonce'])) return fail('invalid session.init shape')
  if (value.v !== 1 || value.type !== 'session.init') return fail('invalid session.init version/type')
  if (!isSid(value.sid)) return fail('invalid session.init sid')
  if (value.suite !== SUITE) return fail('unsupported handshake suite', 'version_unsupported')
  if (!isBytes(value.eph, 32)) return fail('invalid session.init ephemeral key')
  if (!isBytes(value.nonce, 32)) return fail('invalid session.init nonce')
  return null
}

function respBody(value) {
  if (!keysExactly(value, ['v', 'type', 'sid', 'eph', 'nonce', 'sig', 'confirm'])) return fail('invalid session.resp shape')
  if (value.v !== 1 || value.type !== 'session.resp') return fail('invalid session.resp version/type')
  if (!isSid(value.sid)) return fail('invalid session.resp sid')
  if (!isBytes(value.eph, 32)) return fail('invalid session.resp ephemeral key')
  if (!isBytes(value.nonce, 32)) return fail('invalid session.resp nonce')
  if (!isBytes(value.sig, 64)) return fail('invalid session.resp signature')
  if (!isBytes(value.confirm, 32)) return fail('invalid session.resp confirmation')
  return null
}

function confirmBody(value) {
  if (!keysExactly(value, ['v', 'type', 'sid', 'sig', 'confirm'])) return fail('invalid session.confirm shape')
  if (value.v !== 1 || value.type !== 'session.confirm') return fail('invalid session.confirm version/type')
  if (!isSid(value.sid)) return fail('invalid session.confirm sid')
  if (!isBytes(value.sig, 64)) return fail('invalid session.confirm signature')
  if (!isBytes(value.confirm, 32)) return fail('invalid session.confirm confirmation')
  return null
}

function rejectBody(value) {
  if (!keysExactly(value, ['v', 'type', 'sid', 'code'], ['message', 'sig'])) return fail('invalid session.reject shape')
  if (value.v !== 1 || value.type !== 'session.reject') return fail('invalid session.reject version/type')
  if (!isSid(value.sid)) return fail('invalid session.reject sid')
  if (typeof value.code !== 'string' || !SESSION_REJECT_CODES.has(value.code)) return fail('invalid session.reject code')
  if (value.message !== undefined && !isString(value.message, 512)) return fail('invalid session.reject message')
  if (value.sig !== undefined && !isBytes(value.sig, 64)) return fail('invalid session.reject signature')
  return null
}

function parseE2eHandshake(value) {
  if (!keysExactly(value, ['v', 'type', 'sid', 'from', 'to', 'body'])) return fail('invalid e2e.handshake shape')
  if (!isSid(value.sid)) return fail('invalid e2e.handshake sid')
  if (!isMachineId(value.from)) return fail('invalid e2e.handshake from')
  if (!isMachineId(value.to)) return fail('invalid e2e.handshake to')
  if (!isObject(value.body)) return fail('e2e.handshake body must be an object')
  const bodyType = value.body.type
  if (typeof bodyType !== 'string' || !HANDSHAKE_BODY_TYPES.has(bodyType)) {
    return fail('e2e.handshake body.type is not a session handshake message')
  }
  let result = null
  if (bodyType === 'session.init') result = initBody(value.body)
  else if (bodyType === 'session.resp') result = respBody(value.body)
  else if (bodyType === 'session.confirm') result = confirmBody(value.body)
  else result = rejectBody(value.body)
  if (result !== null && result.ok === false) return result
  return { ok: true, type: 'e2e.handshake', bodyType, frame: value }
}

export function parseRelayFrame(value) {
  if (!isObject(value)) return fail('frame must be a JSON object')
  if (!Object.prototype.hasOwnProperty.call(value, 'v')) return fail('missing v')
  if (typeof value.v !== 'number' || !Number.isInteger(value.v)) return fail('v must be an integer')
  if (value.v !== 1) return fail('unsupported protocol version', 'version_unsupported')
  if (typeof value.type !== 'string') return fail('missing type')
  const type = value.type

  switch (type) {
    case 'relay.challenge': {
      if (!keysExactly(value, ['v', 'type', 'nonce', 'relay'])) return fail('invalid relay.challenge shape')
      if (!isBytes(value.nonce, 32)) return fail('invalid relay.challenge nonce')
      if (!isCanonicalOrigin(value.relay)) return fail('invalid relay.challenge origin')
      return { ok: true, type, frame: value }
    }
    case 'peer.auth': {
      if (!keysExactly(value, ['v', 'type', 'machineId', 'publicKey', 'role', 'sig'])) return fail('invalid peer.auth shape')
      if (!isMachineId(value.machineId)) return fail('invalid peer.auth machineId')
      if (!isBytes(value.publicKey, 32)) return fail('invalid peer.auth publicKey')
      if (!isRole(value.role)) return fail('invalid peer.auth role')
      if (!isBytes(value.sig, 64)) return fail('invalid peer.auth signature')
      return {
        ok: true,
        type,
        frame: value,
        publicKey: decodeB64url(value.publicKey, 32),
        signature: decodeB64url(value.sig, 64),
      }
    }
    case 'relay.ready': {
      if (!keysExactly(value, ['v', 'type', 'machineId', 'role'])) return fail('invalid relay.ready shape')
      if (!isMachineId(value.machineId)) return fail('invalid relay.ready machineId')
      if (!isRole(value.role)) return fail('invalid relay.ready role')
      return { ok: true, type, frame: value }
    }
    case 'relay.allow': {
      if (!keysExactly(value, ['v', 'type', 'peers'])) return fail('invalid relay.allow shape')
      if (!Array.isArray(value.peers) || value.peers.length > 1024) return fail('invalid relay.allow peers')
      const seen = new Set()
      for (const peer of value.peers) {
        if (!isMachineId(peer)) return fail('invalid relay.allow peer')
        if (seen.has(peer)) return fail('duplicate relay.allow peer')
        seen.add(peer)
      }
      return { ok: true, type, frame: value }
    }
    case 'relay.offline': {
      if (!keysExactly(value, ['v', 'type', 'to'], ['id', 'streamId', 'sid'])) return fail('invalid relay.offline shape')
      if (!isMachineId(value.to)) return fail('invalid relay.offline to')
      if (value.id !== undefined && !isClientId(value.id)) return fail('invalid relay.offline id')
      if (value.streamId !== undefined && !isClientId(value.streamId)) return fail('invalid relay.offline streamId')
      if (value.sid !== undefined && !isSid(value.sid)) return fail('invalid relay.offline sid')
      return { ok: true, type, frame: value }
    }
    case 'relay.error': {
      if (!keysExactly(value, ['v', 'type', 'code'], ['message', 'id', 'streamId', 'sid', 'retryAfterMs'])) {
        return fail('invalid relay.error shape')
      }
      if (typeof value.code !== 'string' || !RELAY_ERROR_CODES.has(value.code)) return fail('unknown relay.error code')
      if (value.message !== undefined && !isString(value.message, 2048)) return fail('invalid relay.error message')
      if (value.id !== undefined && !isClientId(value.id)) return fail('invalid relay.error id')
      if (value.streamId !== undefined && !isClientId(value.streamId)) return fail('invalid relay.error streamId')
      if (value.sid !== undefined && !isSid(value.sid)) return fail('invalid relay.error sid')
      if (value.retryAfterMs !== undefined && !isIntegerInRange(value.retryAfterMs, 0, 86_400_000)) {
        return fail('invalid relay.error retryAfterMs')
      }
      return { ok: true, type, frame: value }
    }
    case 'relay.ping':
    case 'relay.pong': {
      if (!keysExactly(value, ['v', 'type', 'nonce'])) return fail(`invalid ${type} shape`)
      if (!isBytes(value.nonce, 16)) return fail(`invalid ${type} nonce`)
      return { ok: true, type, frame: value }
    }
    case 'relay.redirect': {
      if (!keysExactly(value, ['v', 'type', 'url'])) return fail('invalid relay.redirect shape')
      if (!isCanonicalOrigin(value.url)) return fail('invalid relay.redirect url')
      return { ok: true, type, frame: value }
    }
    case 'relay.pair.open':
    case 'relay.pair.join': {
      if (!keysExactly(value, ['v', 'type', 'rendezvous'])) return fail(`invalid ${type} shape`)
      if (!isRendezvous(value.rendezvous)) return fail(`invalid ${type} rendezvous`)
      return { ok: true, type, frame: value }
    }
    case 'relay.pair.joined': {
      if (!keysExactly(value, ['v', 'type', 'rendezvous', 'role', 'peerMachineId'])) return fail('invalid relay.pair.joined shape')
      if (!isRendezvous(value.rendezvous)) return fail('invalid relay.pair.joined rendezvous')
      if (!isRole(value.role)) return fail('invalid relay.pair.joined role')
      if (!isMachineId(value.peerMachineId)) return fail('invalid relay.pair.joined peerMachineId')
      return { ok: true, type, frame: value }
    }
    case 'relay.pair.message': {
      if (!keysExactly(value, ['v', 'type', 'rendezvous', 'payload'])) return fail('invalid relay.pair.message shape')
      if (!isRendezvous(value.rendezvous)) return fail('invalid relay.pair.message rendezvous')
      if (!isObject(value.payload)) return fail('invalid relay.pair.message payload')
      return { ok: true, type, frame: value }
    }
    case 'relay.pair.close': {
      if (!keysExactly(value, ['v', 'type', 'rendezvous', 'reason'])) return fail('invalid relay.pair.close shape')
      if (!isRendezvous(value.rendezvous)) return fail('invalid relay.pair.close rendezvous')
      if (typeof value.reason !== 'string' || !PAIR_CLOSE_REASONS.has(value.reason)) return fail('invalid relay.pair.close reason')
      return { ok: true, type, frame: value }
    }
    case 'e2e': {
      if (!keysExactly(value, ['v', 'type', 'sid', 'seq', 'from', 'to', 'body'])) return fail('invalid e2e shape')
      if (!isSid(value.sid)) return fail('invalid e2e sid')
      if (!isIntegerInRange(value.seq, 0, 1_048_575)) return fail('invalid e2e seq')
      if (!isMachineId(value.from)) return fail('invalid e2e from')
      if (!isMachineId(value.to)) return fail('invalid e2e to')
      if (!isE2eBody(value.body)) return fail('invalid e2e body')
      return { ok: true, type, frame: value }
    }
    case 'e2e.handshake':
      return parseE2eHandshake(value)
    default:
      return fail('unknown frame type')
  }
}
