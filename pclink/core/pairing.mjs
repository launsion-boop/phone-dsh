/** Pairing materials, QR/manual codes, rendezvous, MACed handshake, records and audit (§4). */

import {
  b64urlDecode,
  b64urlEncode,
  concatBytes,
  CROCKFORD_ALPHABET,
  fingerprintOf,
  formatRfc3339,
  hkdf32,
  hmacSha256,
  isRfc3339,
  machineIdFromPublicKey,
  randomBytes,
  sha256,
  timingSafeEqualBytes,
  validateName,
} from './encoding.mjs'
import { canonicalBytes, canonicalJson } from './canonical.mjs'
import { pclinkError } from './errors.mjs'
import { parseStrictJsonObject } from './json.mjs'
import { relayWsUrl, validateRelayOrigin } from './relay.mjs'

/** Pairing MAC domains (§4.4). */
export const PAIR_DOMAINS = Object.freeze({
  hello: 'pclink-v1/pair-hello',
  auth: 'pclink-v1/pair-auth',
  confirm: 'pclink-v1/pair-confirm',
  final: 'pclink-v1/pair-final',
})

const MACHINE_ID = /^[a-z2-7]{26}$/

/**
 * Encode a 10-byte manual secret as 16 Crockford base32 characters.
 * @param {Uint8Array} bytes 10-byte secret, big-endian.
 * @returns {string} 16 uppercase characters.
 */
export function crockfordEncode(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length !== 10) throw pclinkError('bad_frame', 'manual secret must be 10 bytes')
  let result = ''
  let buffer = 0
  let bits = 0
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      result += CROCKFORD_ALPHABET[(buffer >>> bits) & 31]
    }
  }
  return result
}

/**
 * Decode 16 Crockford base32 characters (canonical alphabet) to 10 bytes.
 * @param {string} text 16 characters.
 * @returns {Buffer} 10-byte secret.
 */
export function crockfordDecode(text) {
  if (typeof text !== 'string' || text.length !== 16) throw pclinkError('bad_frame', 'manual code must be 16 characters')
  let buffer = 0
  let bits = 0
  const output = []
  for (const character of text) {
    const value = CROCKFORD_ALPHABET.indexOf(character)
    if (value < 0) throw pclinkError('bad_frame', 'manual code contains a non-alphabet character')
    buffer = (buffer << 5) | value
    bits += 5
    if (bits >= 8) {
      bits -= 8
      output.push((buffer >>> bits) & 0xff)
    }
  }
  if (output.length !== 10) throw pclinkError('bad_frame', 'manual code did not decode to 10 bytes')
  return Buffer.from(output)
}

/**
 * Normalize typed manual-code input per §4.1.
 * @param {unknown} input User input.
 * @returns {string} canonical 16-character code.
 */
export function normalizeManualCode(input) {
  if (typeof input !== 'string') throw pclinkError('bad_frame', 'manual code must be a string')
  const stripped = input.toUpperCase().replace(/[-\s]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1')
  if (stripped.length !== 16) throw pclinkError('bad_frame', 'manual code must be 16 characters')
  for (const character of stripped) {
    if (!CROCKFORD_ALPHABET.includes(character)) throw pclinkError('bad_frame', 'manual code contains a rejected character')
  }
  crockfordDecode(stripped)
  return stripped
}

/**
 * Format a 16-character manual code as `XXXX-XXXX-XXXX-XXXX`.
 * @param {string} canonical Canonical code.
 * @returns {string} display form.
 */
export function formatManualCode(canonical) {
  const normalized = normalizeManualCode(canonical)
  return `${normalized.slice(0, 4)}-${normalized.slice(4, 8)}-${normalized.slice(8, 12)}-${normalized.slice(12, 16)}`
}

/**
 * Generate the single-use pairing secret for one mode.
 * @param {'qr'|'manual'} mode Pairing mode.
 * @returns {{mode: 'qr'|'manual', secret: Buffer, canonical?: string, display?: string, qrSecretB64?: string}} material.
 */
export function generatePairingSecret(mode) {
  if (mode === 'qr') {
    const secret = randomBytes(16)
    return { mode, secret, qrSecretB64: b64urlEncode(secret) }
  }
  if (mode === 'manual') {
    const secret = randomBytes(10)
    const canonical = crockfordEncode(secret)
    return { mode, secret, canonical, display: formatManualCode(canonical) }
  }
  throw pclinkError('bad_frame', 'pairing mode must be qr or manual')
}

/**
 * Origin-bound rendezvous value (§4.3).
 * @param {Uint8Array} secret S (16 bytes) or C (10 bytes).
 * @param {string} relayOrigin Normalized lowercase relay origin.
 * @returns {string} 22-character b64url prefix.
 */
export function rendezvousFor(secret, relayOrigin) {
  const origin = validateRelayOrigin(relayOrigin)
  return b64urlEncode(sha256(concatBytes(
    Buffer.from('pclink-v1/pair', 'utf8'),
    Buffer.from([0]),
    Buffer.from(origin, 'utf8'),
    Buffer.from([0]),
    Buffer.from(secret),
  ))).slice(0, 22)
}

/**
 * Pairing MAC key from S/C (§4.4).
 * @param {Uint8Array} secret Pairing secret.
 * @returns {Buffer} 32-byte pair_key.
 */
export function pairKeyFor(secret) {
  return hkdf32(secret, Buffer.alloc(32), 'pclink-v1/pair-mac')
}

/**
 * Domain-separated pairing MAC over canonical JSON without `mac`.
 * @param {Uint8Array} pairKey 32-byte pair key.
 * @param {string} domain One of PAIR_DOMAINS values.
 * @param {Record<string, unknown>} object Message including or excluding `mac`.
 * @returns {Buffer} 32-byte HMAC.
 */
export function pairMac(pairKey, domain, object) {
  if (!Object.values(PAIR_DOMAINS).includes(domain)) throw pclinkError('bad_frame', 'unknown pairing MAC domain')
  const { mac: _mac, ...withoutMac } = object
  return hmacSha256(pairKey, concatBytes(Buffer.from(domain, 'utf8'), Buffer.from([0]), canonicalBytes(withoutMac)))
}

/**
 * Pairing transcript hash from the hello/auth objects without MACs (§4.4).
 * @param {Record<string, unknown>} hello pair.hello object.
 * @param {Record<string, unknown>} auth pair.auth object.
 * @returns {{th1: Buffer, th2: Buffer, transcriptHash: Buffer}} hashes.
 */
export function pairTranscriptHash(hello, auth) {
  const { mac: _hm, ...helloWithout } = hello
  const { mac: _am, ...authWithout } = auth
  const th1 = sha256(canonicalBytes(helloWithout))
  const th2 = sha256(canonicalBytes(authWithout))
  return { th1, th2, transcriptHash: sha256(concatBytes(th1, Buffer.from([0]), th2)) }
}

function exact(value, required, where) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', `${where} must be an object`)
  for (const name of required) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `${where} missing ${name}`)
  }
  for (const name of Object.keys(value)) {
    if (!required.includes(name)) throw pclinkError('bad_frame', `${where} unknown member ${name}`)
  }
}

function machineId(value, where) {
  if (typeof value !== 'string' || !MACHINE_ID.test(value)) throw pclinkError('bad_frame', `${where} is not a machineId`)
  return value
}

function nonce(value, where) {
  try {
    b64urlDecode(value, { length: 32 })
  } catch (error) {
    throw pclinkError('bad_frame', `${where}: ${error.message}`)
  }
  return value
}

function publicKey(value, where) {
  try {
    return b64urlDecode(value, { length: 32 })
  } catch (error) {
    throw pclinkError('bad_frame', `${where}: ${error.message}`)
  }
}

function macValue(value, where) {
  try {
    return b64urlDecode(value, { length: 32 })
  } catch (error) {
    throw pclinkError('bad_frame', `${where}: ${error.message}`)
  }
}

function pairingRelay(value, expected) {
  const origin = validateRelayOrigin(value)
  if (origin !== expected) throw pclinkError('auth_failed', 'pairing relay origin mismatch')
  return origin
}

/**
 * Validate a `pair.hello` object and its MAC, with optional QR pin checks.
 * @param {unknown} value Parsed payload.
 * @param {{pairKey: Uint8Array, relay: string, pinnedPublicKey?: Uint8Array, pinnedMachineId?: string}} options Verification inputs.
 * @returns {{hello: Record<string, unknown>, publicKey: Buffer, machineId: string}} verified facts.
 */
export function verifyPairHello(value, options) {
  exact(value, ['v', 'type', 'role', 'machineId', 'publicKey', 'name', 'relay', 'nonce', 'mac'], 'pair.hello')
  if (value.v !== 1 || value.type !== 'pair.hello' || value.role !== 'pc') throw pclinkError('bad_frame', 'not a pair.hello from the PC')
  const pcMachineId = machineId(value.machineId, 'pair.hello.machineId')
  const pcPublicKey = publicKey(value.publicKey, 'pair.hello.publicKey')
  validateName(value.name, 'pair.hello.name')
  pairingRelay(value.relay, options.relay)
  nonce(value.nonce, 'pair.hello.nonce')
  const expectedMac = pairMac(options.pairKey, PAIR_DOMAINS.hello, value)
  if (!timingSafeEqualBytes(macValue(value.mac, 'pair.hello.mac'), expectedMac)) throw pclinkError('auth_failed', 'pair.hello MAC invalid')
  if (machineIdFromPublicKey(pcPublicKey) !== pcMachineId) throw pclinkError('auth_failed', 'pair.hello machineId/key mismatch')
  if (options.pinnedPublicKey !== undefined && !pcPublicKey.equals(Buffer.from(options.pinnedPublicKey))) {
    throw pclinkError('auth_failed', 'pair.hello public key does not match the QR pin')
  }
  if (options.pinnedMachineId !== undefined && pcMachineId !== options.pinnedMachineId) {
    throw pclinkError('auth_failed', 'pair.hello machineId does not match the QR')
  }
  return { hello: value, publicKey: pcPublicKey, machineId: pcMachineId }
}

/**
 * Build a MACed `pair.hello`.
 * @param {{identity: {machineId: string, publicKey: Uint8Array}, name: string, relay: string, nonce: Uint8Array, pairKey: Uint8Array}} input Fields.
 * @returns {Record<string, unknown>} pair.hello.
 */
export function buildPairHello(input) {
  const hello = {
    v: 1,
    type: 'pair.hello',
    role: 'pc',
    machineId: input.identity.machineId,
    publicKey: b64urlEncode(input.identity.publicKey),
    name: validateName(input.name, 'pair.hello.name'),
    relay: input.relay,
    nonce: b64urlEncode(input.nonce),
  }
  hello.mac = b64urlEncode(pairMac(input.pairKey, PAIR_DOMAINS.hello, hello))
  return hello
}

/**
 * Validate a `pair.auth` object and its MAC.
 * @param {unknown} value Parsed payload.
 * @param {{pairKey: Uint8Array, relay: string, peerNonce: Uint8Array}} options Verification inputs.
 * @returns {{auth: Record<string, unknown>, publicKey: Buffer, machineId: string}} verified facts.
 */
export function verifyPairAuth(value, options) {
  exact(value, ['v', 'type', 'role', 'machineId', 'publicKey', 'name', 'relay', 'nonce', 'peerNonce', 'mac'], 'pair.auth')
  if (value.v !== 1 || value.type !== 'pair.auth' || value.role !== 'phone') throw pclinkError('bad_frame', 'not a pair.auth from the phone')
  const phoneMachineId = machineId(value.machineId, 'pair.auth.machineId')
  const phonePublicKey = publicKey(value.publicKey, 'pair.auth.publicKey')
  validateName(value.name, 'pair.auth.name')
  pairingRelay(value.relay, options.relay)
  nonce(value.nonce, 'pair.auth.nonce')
  nonce(value.peerNonce, 'pair.auth.peerNonce')
  if (value.peerNonce !== b64urlEncode(options.peerNonce)) throw pclinkError('auth_failed', 'pair.auth peerNonce mismatch')
  const expectedMac = pairMac(options.pairKey, PAIR_DOMAINS.auth, value)
  if (!timingSafeEqualBytes(macValue(value.mac, 'pair.auth.mac'), expectedMac)) throw pclinkError('auth_failed', 'pair.auth MAC invalid')
  if (machineIdFromPublicKey(phonePublicKey) !== phoneMachineId) throw pclinkError('auth_failed', 'pair.auth machineId/key mismatch')
  return { auth: value, publicKey: phonePublicKey, machineId: phoneMachineId }
}

/**
 * Build a MACed `pair.auth`.
 * @param {{identity: {machineId: string, publicKey: Uint8Array}, name: string, relay: string, nonce: Uint8Array, peerNonce: Uint8Array, pairKey: Uint8Array}} input Fields.
 * @returns {Record<string, unknown>} pair.auth.
 */
export function buildPairAuth(input) {
  const auth = {
    v: 1,
    type: 'pair.auth',
    role: 'phone',
    machineId: input.identity.machineId,
    publicKey: b64urlEncode(input.identity.publicKey),
    name: validateName(input.name, 'pair.auth.name'),
    relay: input.relay,
    nonce: b64urlEncode(input.nonce),
    peerNonce: b64urlEncode(input.peerNonce),
  }
  auth.mac = b64urlEncode(pairMac(input.pairKey, PAIR_DOMAINS.auth, auth))
  return auth
}

/**
 * Build a MACed `pair.confirm`.
 * @param {{pairKey: Uint8Array, nonce: Uint8Array, peerNonce: Uint8Array, transcriptHash: Uint8Array}} input Fields.
 * @returns {Record<string, unknown>} pair.confirm.
 */
export function buildPairConfirm(input) {
  const confirm = {
    v: 1,
    type: 'pair.confirm',
    role: 'pc',
    nonce: b64urlEncode(input.nonce),
    peerNonce: b64urlEncode(input.peerNonce),
    transcriptHash: b64urlEncode(input.transcriptHash),
  }
  confirm.mac = b64urlEncode(pairMac(input.pairKey, PAIR_DOMAINS.confirm, confirm))
  return confirm
}

/**
 * Verify a `pair.confirm` MAC and transcript hash.
 * @param {unknown} value Parsed payload.
 * @param {{pairKey: Uint8Array, expectedNonce: Uint8Array, expectedPeerNonce: Uint8Array, transcriptHash: Uint8Array}} options Verification inputs.
 * @returns {Record<string, unknown>} verified pair.confirm.
 */
export function verifyPairConfirm(value, options) {
  exact(value, ['v', 'type', 'role', 'nonce', 'peerNonce', 'transcriptHash', 'mac'], 'pair.confirm')
  if (value.v !== 1 || value.type !== 'pair.confirm' || value.role !== 'pc') throw pclinkError('bad_frame', 'not a pair.confirm from the PC')
  nonce(value.nonce, 'pair.confirm.nonce')
  nonce(value.peerNonce, 'pair.confirm.peerNonce')
  if (value.nonce !== b64urlEncode(options.expectedNonce)) throw pclinkError('auth_failed', 'pair.confirm hello nonce mismatch')
  if (value.peerNonce !== b64urlEncode(options.expectedPeerNonce)) throw pclinkError('auth_failed', 'pair.confirm auth nonce mismatch')
  let transcriptHash
  try {
    transcriptHash = b64urlDecode(value.transcriptHash, { length: 32 })
  } catch (error) {
    throw pclinkError('bad_frame', `pair.confirm.transcriptHash: ${error.message}`)
  }
  if (!timingSafeEqualBytes(transcriptHash, Buffer.from(options.transcriptHash))) throw pclinkError('auth_failed', 'pair.confirm transcript hash mismatch')
  const expectedMac = pairMac(options.pairKey, PAIR_DOMAINS.confirm, value)
  if (!timingSafeEqualBytes(macValue(value.mac, 'pair.confirm.mac'), expectedMac)) throw pclinkError('auth_failed', 'pair.confirm MAC invalid')
  return value
}

/**
 * Build a MACed `pair.final`.
 * @param {{pairKey: Uint8Array, nonce: Uint8Array, peerNonce: Uint8Array, transcriptHash: Uint8Array}} input Fields.
 * @returns {Record<string, unknown>} pair.final.
 */
export function buildPairFinal(input) {
  const final = {
    v: 1,
    type: 'pair.final',
    role: 'phone',
    nonce: b64urlEncode(input.nonce),
    peerNonce: b64urlEncode(input.peerNonce),
    transcriptHash: b64urlEncode(input.transcriptHash),
  }
  final.mac = b64urlEncode(pairMac(input.pairKey, PAIR_DOMAINS.final, final))
  return final
}

/**
 * Verify a `pair.final` MAC and transcript hash.
 * @param {unknown} value Parsed payload.
 * @param {{pairKey: Uint8Array, expectedNonce: Uint8Array, expectedPeerNonce: Uint8Array, transcriptHash: Uint8Array}} options Verification inputs.
 * @returns {Record<string, unknown>} verified pair.final.
 */
export function verifyPairFinal(value, options) {
  exact(value, ['v', 'type', 'role', 'nonce', 'peerNonce', 'transcriptHash', 'mac'], 'pair.final')
  if (value.v !== 1 || value.type !== 'pair.final' || value.role !== 'phone') throw pclinkError('bad_frame', 'not a pair.final from the phone')
  nonce(value.nonce, 'pair.final.nonce')
  nonce(value.peerNonce, 'pair.final.peerNonce')
  if (value.nonce !== b64urlEncode(options.expectedNonce)) throw pclinkError('auth_failed', 'pair.final auth nonce mismatch')
  if (value.peerNonce !== b64urlEncode(options.expectedPeerNonce)) throw pclinkError('auth_failed', 'pair.final hello nonce mismatch')
  let transcriptHash
  try {
    transcriptHash = b64urlDecode(value.transcriptHash, { length: 32 })
  } catch (error) {
    throw pclinkError('bad_frame', `pair.final.transcriptHash: ${error.message}`)
  }
  if (!timingSafeEqualBytes(transcriptHash, Buffer.from(options.transcriptHash))) throw pclinkError('auth_failed', 'pair.final transcript hash mismatch')
  const expectedMac = pairMac(options.pairKey, PAIR_DOMAINS.final, value)
  if (!timingSafeEqualBytes(macValue(value.mac, 'pair.final.mac'), expectedMac)) throw pclinkError('auth_failed', 'pair.final MAC invalid')
  return value
}

/**
 * Build the §4.2 QR URI.
 * @param {{origin: string, machineId: string, publicKey: Uint8Array, secret: Uint8Array, name: string}} input QR fields.
 * @returns {string} URI, at most 512 bytes.
 */
export function buildQrUri(input) {
  const origin = validateRelayOrigin(input.origin)
  if (!MACHINE_ID.test(input.machineId)) throw pclinkError('bad_frame', 'QR machineId')
  validateName(input.name, 'QR name')
  const uri = `pclink://pair?v=1&r=${encodeURIComponent(origin)}&m=${input.machineId}&k=${b64urlEncode(input.publicKey)}&s=${b64urlEncode(input.secret)}&n=${encodeURIComponent(input.name)}`
  if (Buffer.byteLength(uri, 'utf8') > 512) throw pclinkError('frame_too_large', 'QR URI exceeds 512 bytes')
  return uri
}

/**
 * Strictly parse the §4.2 QR URI. Raw `+`, unknown/duplicate parameters, uppercase
 * origins and a path/fragment/userinfo are rejected.
 * @param {unknown} uri Candidate URI.
 * @returns {{origin: string, machineId: string, publicKey: string, secret: string, name: string, wsUrl: string}} parsed facts.
 */
export function parseQrUri(uri) {
  if (typeof uri !== 'string') throw pclinkError('bad_frame', 'QR URI must be a string')
  if (Buffer.byteLength(uri, 'utf8') > 512) throw pclinkError('bad_frame', 'QR URI exceeds 512 bytes')
  if (uri.includes('#')) throw pclinkError('bad_frame', 'QR URI must not have a fragment')
  if (!uri.startsWith('pclink://pair?')) throw pclinkError('bad_frame', 'QR URI must be pclink://pair?...')
  const queryStart = 'pclink://pair?'.length
  const query = uri.slice(queryStart)
  if (query.includes('+')) throw pclinkError('bad_frame', 'raw + is not allowed in the QR query')
  const params = new Map()
  for (const part of query.split('&')) {
    const equals = part.indexOf('=')
    if (equals <= 0) throw pclinkError('bad_frame', 'malformed QR query parameter')
    const name = part.slice(0, equals)
    const rawValue = part.slice(equals + 1)
    if (params.has(name)) throw pclinkError('bad_frame', `duplicate QR parameter ${name}`)
    let value
    try {
      value = decodeURIComponent(rawValue)
    } catch {
      throw pclinkError('bad_frame', 'invalid percent-encoding in QR URI')
    }
    params.set(name, value)
  }
  const allowed = ['v', 'r', 'm', 'k', 's', 'n']
  for (const name of params.keys()) {
    if (!allowed.includes(name)) throw pclinkError('bad_frame', `unknown QR parameter ${name}`)
  }
  for (const name of allowed) {
    if (!params.has(name)) throw pclinkError('bad_frame', `QR URI missing ${name}`)
  }
  if (params.get('v') !== '1') throw pclinkError('bad_frame', 'QR URI version')
  const origin = validateRelayOrigin(params.get('r'))
  const qrMachineId = params.get('m')
  if (!MACHINE_ID.test(qrMachineId)) throw pclinkError('bad_frame', 'QR machineId')
  const pcPublicKey = publicKey(params.get('k'), 'QR publicKey')
  const secret = (() => {
    try {
      return b64urlDecode(params.get('s'), { length: 16 })
    } catch (error) {
      throw pclinkError('bad_frame', `QR secret: ${error.message}`)
    }
  })()
  const name = validateName(params.get('n'), 'QR name')
  if (machineIdFromPublicKey(pcPublicKey) !== qrMachineId) throw pclinkError('auth_failed', 'QR machineId/key mismatch')
  return {
    origin,
    machineId: qrMachineId,
    publicKey: params.get('k'),
    secret: b64urlEncode(secret),
    name,
    wsUrl: relayWsUrl(origin),
  }
}

function pairingTime(value, where) {
  if (!isRfc3339(value)) throw pclinkError('bad_frame', `${where} must be a canonical RFC 3339 timestamp`)
  return value
}

function validateConnection(connection) {
  exact(connection, ['mode'], 'record.connection')
  if (connection.mode !== 'relay') throw pclinkError('version_unsupported', 'record mode is not relay')
}

/**
 * Validate one PC pairing record (§4.6).
 * @param {unknown} record Parsed record.
 * @returns {Record<string, unknown>} the record.
 */
export function validatePairingRecord(record) {
  exact(record, ['peerMachineId', 'peerPublicKey', 'peerName', 'pairedAt', 'relayOrigin', 'connection', 'approvedAt', 'approvedVia'], 'pairing record')
  machineId(record.peerMachineId, 'pairing record.peerMachineId')
  publicKey(record.peerPublicKey, 'pairing record.peerPublicKey')
  validateName(record.peerName, 'pairing record.peerName')
  pairingTime(record.pairedAt, 'pairing record.pairedAt')
  pairingTime(record.approvedAt, 'pairing record.approvedAt')
  if (!['qr', 'manual', 'cli', 'webui'].includes(record.approvedVia)) throw pclinkError('bad_frame', 'pairing record.approvedVia')
  validateRelayOrigin(record.relayOrigin)
  validateConnection(record.connection)
  return record
}

/**
 * Validate one phone pairing record (§4.6).
 * @param {unknown} record Parsed record.
 * @returns {Record<string, unknown>} the record.
 */
export function validatePhonePairingRecord(record) {
  exact(record, ['peerMachineId', 'peerPublicKey', 'peerName', 'pairedAt', 'relayOrigin', 'connection'], 'phone pairing record')
  machineId(record.peerMachineId, 'phone record.peerMachineId')
  publicKey(record.peerPublicKey, 'phone record.peerPublicKey')
  validateName(record.peerName, 'phone record.peerName')
  pairingTime(record.pairedAt, 'phone record.pairedAt')
  validateRelayOrigin(record.relayOrigin)
  validateConnection(record.connection)
  return record
}

/**
 * Build the PC record from verified pairing facts.
 * @param {{peerMachineId: string, peerPublicKey: string, peerName: string, relayOrigin: string, pairedAt: string, approvedAt: string, approvedVia: 'qr'|'manual'|'cli'|'webui'}} input Fields.
 * @returns {Record<string, unknown>} PC record.
 */
export function buildPairingRecord(input) {
  return validatePairingRecord({
    peerMachineId: input.peerMachineId,
    peerPublicKey: input.peerPublicKey,
    peerName: input.peerName,
    pairedAt: input.pairedAt,
    relayOrigin: input.relayOrigin,
    connection: { mode: 'relay' },
    approvedAt: input.approvedAt,
    approvedVia: input.approvedVia,
  })
}

/**
 * Build the phone record from a verified pair.hello.
 * @param {{hello: Record<string, unknown>, pairedAt?: string, relayOrigin: string}} input Facts.
 * @returns {Record<string, unknown>} phone record.
 */
export function buildPhoneRecord(input) {
  return validatePhonePairingRecord({
    peerMachineId: input.hello.machineId,
    peerPublicKey: input.hello.publicKey,
    peerName: input.hello.name,
    pairedAt: input.pairedAt ?? formatRfc3339(),
    relayOrigin: input.relayOrigin,
    connection: { mode: 'relay' },
  })
}

/**
 * SHA-256 over canonical_json(record), lowercase hex (§4.6).
 * @param {Record<string, unknown>} record PC record.
 * @returns {string} 64 lowercase hex characters.
 */
export function recordSha256(record) {
  return sha256(canonicalBytes(validatePairingRecord(record))).toString('hex')
}

/**
 * Build one `pair` audit line.
 * @param {Record<string, unknown>} record PC record.
 * @param {string} at Event time.
 * @returns {Record<string, unknown>} audit event.
 */
export function buildAuditPairEntry(record, at = record.approvedAt) {
  return {
    v: 1,
    event: 'pair',
    peerMachineId: record.peerMachineId,
    peerPublicKey: record.peerPublicKey,
    recordSha256: recordSha256(record),
    approvedAt: record.approvedAt,
    approvedVia: record.approvedVia,
    at: pairingTime(at, 'audit.at'),
  }
}

/**
 * Build one `unpair` audit line.
 * @param {string} peerMachineId Peer being revoked.
 * @param {string} [at] Event time.
 * @returns {Record<string, unknown>} audit event.
 */
export function buildAuditUnpairEntry(peerMachineId, at = formatRfc3339()) {
  return { v: 1, event: 'unpair', peerMachineId: machineId(peerMachineId, 'unpair.peerMachineId'), at: pairingTime(at, 'audit.at') }
}

/**
 * Build one `rotate` audit line.
 * @param {string} oldMachineId Previous PC machineId.
 * @param {string} newMachineId New PC machineId.
 * @param {string} [at] Event time.
 * @returns {Record<string, unknown>} audit event.
 */
export function buildAuditRotateEntry(oldMachineId, newMachineId, at = formatRfc3339()) {
  return {
    v: 1,
    event: 'rotate',
    oldMachineId: machineId(oldMachineId, 'rotate.oldMachineId'),
    newMachineId: machineId(newMachineId, 'rotate.newMachineId'),
    at: pairingTime(at, 'audit.at'),
  }
}

/**
 * Evaluate whether a record is approved/usable from the append-only audit log (§4.6).
 * @param {Record<string, unknown>} record PC record.
 * @param {Array<Record<string, unknown>>} events Audit events in append order.
 * @returns {{usable: true} | {usable: false, reason: 'unapproved'|'revoked'}} usability.
 */
export function evaluateRecordAudit(record, events) {
  let latest
  for (const event of events) {
    if (event !== null && typeof event === 'object' && event.peerMachineId === record.peerMachineId
      && (event.event === 'pair' || event.event === 'unpair')) {
      latest = event
    }
  }
  if (latest === undefined) return { usable: false, reason: 'unapproved' }
  if (latest.event === 'unpair') return { usable: false, reason: 'revoked' }
  if (latest.peerPublicKey !== record.peerPublicKey) return { usable: false, reason: 'unapproved' }
  if (latest.recordSha256 !== recordSha256(record)) return { usable: false, reason: 'unapproved' }
  return { usable: true }
}

/**
 * Build the §4.6 new-pairing notice.
 * @param {{peerName: string, peerMachineId: string, approvedAt: string}} record Verified record facts.
 * @returns {Record<string, unknown>} `pclink.notice` inner message.
 */
export function buildPairingNotice(record) {
  return {
    type: 'pclink.notice',
    kind: 'paired',
    name: validateName(record.peerName, 'notice.name'),
    fingerprint: fingerprintOf(record.peerMachineId),
    at: pairingTime(record.approvedAt, 'notice.at'),
  }
}

/**
 * Parse one JSON object as a pairing payload (strict JSON rules).
 * @param {string | Uint8Array} text Payload JSON.
 * @returns {Record<string, unknown>} parsed payload.
 */
export function parsePairingPayload(text) {
  return parseStrictJsonObject(text)
}
