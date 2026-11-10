#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// PCLink v1.3 shared vectors.  `--write` derives the golden document from fixed,
// public test labels.  `--check` re-derives every value with an independent
// minimal implementation (it does not call the generator helpers, and it owns
// its own domain/suite/alphabet/PKCS#8 constants) and rejects every invalid
// row.  No npm dependencies: Node's `node:crypto` supplies Ed25519, X25519,
// HKDF-SHA256 and ChaCha20-Poly1305.
//
// The fixed private keys are SHA-256 of public labels.  They are test keys and
// MUST NOT be used outside the fixtures.  The golden document stores the labels
// and public values, so a second implementation can derive the same test keys
// from the rule in the contract (`sha256(label)`).
//
// Usage: node spec/pclink/v1/tools/vectors.mjs --write|--check [--root DIR]

import {
  createCipheriv, createDecipheriv, createHash, createHmac,
  createPrivateKey, createPublicKey, diffieHellman, hkdfSync, sign, verify,
} from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const DEFAULT_ROOT = resolve(HERE, '..')
const GOLDEN = 'golden/pclink-v1-vectors.json'
const SUITE = 'pclink-x25519-ed25519-chacha20poly1305-1'
const REVISION = 'pclink-v1.6'
const DOMAIN = {
  relayAuth: 'pclink-v1/relay-auth',
  pair: 'pclink-v1/pair',
  pairKey: 'pclink-v1/pair-mac',
  pairHello: 'pclink-v1/pair-hello',
  pairAuth: 'pclink-v1/pair-auth',
  pairConfirm: 'pclink-v1/pair-confirm',
  pairFinal: 'pclink-v1/pair-final',
  sessionInit: 'pclink-v1/session-init',
  sessionResp: 'pclink-v1/session-resp',
  sessionConfirm: 'pclink-v1/session-confirm',
  sessionReject: 'pclink-v1/session-reject',
  keyPhoneToPc: 'pclink-v1/key/phone->pc',
  keyPcToPhone: 'pclink-v1/key/pc->phone',
  keyConfirmPhone: 'pclink-v1/key-confirm/phone->pc',
  keyConfirmPc: 'pclink-v1/key-confirm/pc->phone',
  confirm: 'pclink-v1/confirm',
  aad: 'pclink-v1/aad',
  adminProof: 'pclink-v1/admin-proof',
}
const THRESHOLD = 1024 * 1024
const MAX_VALUE = 8 * 1024 * 1024
const MAX_FRAME = 16 * 1024 * 1024
const SEQ_REKEY = 2 ** 19
const SEQ_MAX = 2 ** 20
const BYTE_REKEY = 1024 * 1024 * 1024
const BYTE_HARD = 2 * 1024 * 1024 * 1024
const ZERO = Buffer.from([0])
const ZERO32 = Buffer.alloc(32)
const ED25519_PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex')
const X25519_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex')
const X25519_SPKI = Buffer.from('302a300506032b656e032100', 'hex')
const ED25519_SPKI = Buffer.from('302a300506032b6570032100', 'hex')
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
const PCLINK_CODES = new Set([
  'unavailable', 'unknown_outcome', 'peer_offline', 'unpaired', 'auth_failed',
  'replaced', 'session_expired', 'replay', 'bad_frame', 'frame_too_large',
  'rate_limited', 'version_unsupported', 'rendezvous_expired',
  'rendezvous_exhausted', 'rekey', 'forbidden',
])
const DSH_PASSTHROUGH_FIELDS = new Set([
  'rpc.call.args',
  'rpc.stream.open.payload.args',
  'rpc.result.result',
  'rpc.stream.item.value',
  'rpc.result.chunk.data(decoded)',
  'rpc.stream.chunk.data(decoded)',
])

// ---------------------------------------------------------------------------
// Generator helpers
// ---------------------------------------------------------------------------

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest()
}
function hex(bytes) {
  return Buffer.from(bytes).toString('hex')
}
function b64u(bytes) {
  return Buffer.from(bytes).toString('base64url')
}
function unb64u(text, expectedLength) {
  if (typeof text !== 'string' || !/^[A-Za-z0-9_-]+$/.test(text)) {
    throw new Error(`not base64url: ${JSON.stringify(text)}`)
  }
  const bytes = Buffer.from(text, 'base64url')
  if (bytes.toString('base64url') !== text) throw new Error(`non-canonical base64url: ${text}`)
  if (expectedLength !== undefined && bytes.length !== expectedLength) {
    throw new Error(`base64url length ${bytes.length}, expected ${expectedLength}`)
  }
  return bytes
}
function utf8(text) {
  return Buffer.from(text, 'utf8')
}
function cat(...parts) {
  return Buffer.concat(parts.map(part => Buffer.isBuffer(part) ? part : Buffer.from(part)))
}
function hkdf(ikm, salt, info, length = 32) {
  return Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), length))
}
function hmac(key, bytes) {
  return createHmac('sha256', key).update(bytes).digest()
}
function base32Lower(bytes) {
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31]
  return out.toLowerCase()
}
function machineIdOf(rawPublicKey) {
  if (!Buffer.isBuffer(rawPublicKey) || rawPublicKey.length !== 32) {
    throw new Error('machineId input must be a raw 32-byte Ed25519 public key')
  }
  return base32Lower(sha256(rawPublicKey)).slice(0, 26)
}
function compareCodePoints(a, b) {
  const left = Array.from(a, char => char.codePointAt(0))
  const right = Array.from(b, char => char.codePointAt(0))
  const count = Math.min(left.length, right.length)
  for (let index = 0; index < count; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index]
  }
  return left.length - right.length
}
function quoteJsonString(text) {
  let out = '"'
  for (const char of text) {
    const code = char.codePointAt(0)
    if (code >= 0xd800 && code <= 0xdfff) throw new Error('lone surrogate in canonical JSON')
    if (char === '"') out += '\\"'
    else if (char === '\\') out += '\\\\'
    else if (code === 0x08) out += '\\b'
    else if (code === 0x09) out += '\\t'
    else if (code === 0x0a) out += '\\n'
    else if (code === 0x0c) out += '\\f'
    else if (code === 0x0d) out += '\\r'
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, '0')}`
    else out += char
  }
  return `${out}"`
}
function canonicalJson(value) {
  if (value === null) return 'null'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('non-finite number in canonical JSON')
    return JSON.stringify(value)
  }
  if (typeof value === 'string') return quoteJsonString(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort(compareCodePoints)
    return `{${keys.map(key => `${quoteJsonString(key)}:${canonicalJson(value[key])}`).join(',')}}`
  }
  throw new Error(`cannot canonicalise ${typeof value}`)
}
function checkDisplayName(name) {
  if (typeof name !== 'string') throw new Error('name must be a string')
  if (!(Buffer.byteLength(name, 'utf8') >= 1 && Buffer.byteLength(name, 'utf8') <= 64)) {
    throw new Error('name must be 1..64 UTF-8 bytes')
  }
  if (name.normalize('NFC') !== name) throw new Error('name must be NFC')
  for (const char of name) {
    const code = char.codePointAt(0)
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f) || /\p{Cf}/u.test(char)) {
      throw new Error(`name contains control/format U+${code.toString(16)}`)
    }
  }
  return name
}
function normalizeOrigin(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 128) {
    throw new Error('origin must be a non-empty string')
  }
  if (value !== value.toLowerCase()) throw new Error('origin must be lowercase')
  const url = new URL(value)
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new Error('origin must be http(s)')
  if (url.username || url.password || url.search || url.hash) throw new Error('origin has userinfo/query/fragment')
  if (url.pathname !== '/' && url.pathname !== '') throw new Error('origin has a path')
  if (url.origin !== value) throw new Error('origin is not canonical (default port omitted, no path)')
  return url.origin
}
function wsUrl(origin) {
  const normalized = normalizeOrigin(origin)
  return normalized.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:') + '/'
}
function seedFromLabel(label) {
  return sha256(utf8(label))
}
function edPrivate(label) {
  return createPrivateKey({ key: cat(ED25519_PKCS8, seedFromLabel(label)), format: 'der', type: 'pkcs8' })
}
function xPrivate(label) {
  return createPrivateKey({ key: cat(X25519_PKCS8, seedFromLabel(label)), format: 'der', type: 'pkcs8' })
}
function rawPublic(priv) {
  return createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32)
}
function xPublic(raw) {
  if (!Buffer.isBuffer(raw) || raw.length !== 32) throw new Error('X25519 public key must be 32 bytes')
  return createPublicKey({ key: cat(X25519_SPKI, raw), format: 'der', type: 'spki' })
}
function edPublic(raw) {
  if (!Buffer.isBuffer(raw) || raw.length !== 32) throw new Error('Ed25519 public key must be 32 bytes')
  return createPublicKey({ key: cat(ED25519_SPKI, raw), format: 'der', type: 'spki' })
}
function relayAuthTranscript(origin, nonce) {
  return cat(utf8(DOMAIN.relayAuth), ZERO, utf8(origin), ZERO, nonce)
}
function aadBytes(sidText, seq, from, to, outerType = 'e2e', version = '1') {
  return cat(
    utf8(DOMAIN.aad), ZERO,
    utf8(version), ZERO,
    utf8(outerType), ZERO,
    utf8(sidText), ZERO,
    utf8(String(seq)), ZERO,
    utf8(from), ZERO,
    utf8(to),
  )
}
function aeadNonce(seq) {
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error('seq must be a non-negative integer')
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64BE(BigInt(seq), 4)
  return nonce
}
function seal(key, seq, aad, plaintext) {
  const nonce = aeadNonce(seq)
  const cipher = createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  cipher.setAAD(aad)
  return cat(cipher.update(plaintext), cipher.final(), cipher.getAuthTag())
}
function open(key, seq, aad, body) {
  const nonce = aeadNonce(seq)
  if (body.length < 16) throw new Error('ciphertext shorter than the tag')
  const decipher = createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  decipher.setAAD(aad)
  decipher.setAuthTag(body.subarray(-16))
  try {
    return cat(decipher.update(body.subarray(0, -16)), decipher.final())
  } catch {
    throw new Error('auth_failed')
  }
}
function pairKey(secret) {
  return hkdf(secret, ZERO32, DOMAIN.pairKey, 32)
}
function rendezvousOf(secret, origin) {
  return b64u(sha256(cat(utf8(DOMAIN.pair), ZERO, utf8(normalizeOrigin(origin)), ZERO, secret))).slice(0, 22)
}
function pairMac(key, domain, objectWithoutMac) {
  return hmac(key, cat(utf8(domain), ZERO, utf8(canonicalJson(objectWithoutMac))))
}
function withMac(key, domain, objectWithoutMac) {
  return { ...objectWithoutMac, mac: b64u(pairMac(key, domain, objectWithoutMac)) }
}
function crockfordEncode(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length !== 10) throw new Error('Crockford input must be 10 bytes')
  let value = 0n
  for (const byte of bytes) value = (value << 8n) | BigInt(byte)
  let out = ''
  for (let index = 15; index >= 0; index -= 1) {
    out += CROCKFORD[Number((value >> BigInt(index * 5)) & 31n)]
  }
  return out
}
function crockfordDecode(input) {
  if (typeof input !== 'string') throw new Error('manual code must be a string')
  const normalized = input.toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
  if (!new RegExp(`^[${CROCKFORD}]{16}$`).test(normalized)) {
    throw new Error(`invalid manual code: ${JSON.stringify(input)}`)
  }
  let value = 0n
  for (const char of normalized) value = (value << 5n) | BigInt(CROCKFORD.indexOf(char))
  const bytes = Buffer.alloc(10)
  for (let index = 9; index >= 0; index -= 1) {
    bytes[index] = Number(value & 0xffn)
    value >>= 8n
  }
  return { normalized, display: normalized.match(/.{4}/g).join('-'), bytes }
}
function qrUri({ origin, machineId, publicKey, secret, name }) {
  const encode = value => encodeURIComponent(value)
  return 'pclink://pair'
    + `?v=1&r=${encode(origin)}&m=${encode(machineId)}&k=${encode(b64u(publicKey))}`
    + `&s=${encode(b64u(secret))}&n=${encode(name)}`
}
function parseQr(uri) {
  if (typeof uri !== 'string' || Buffer.byteLength(uri, 'utf8') < 1 || Buffer.byteLength(uri, 'utf8') > 512) {
    throw new Error('qr length')
  }
  if (!uri.startsWith('pclink://pair?')) throw new Error('qr scheme')
  if (uri.includes('#')) throw new Error('qr fragment')
  const query = uri.slice('pclink://pair?'.length)
  if (query.includes('+')) throw new Error('qr raw +')
  const allowed = new Set(['v', 'r', 'm', 'k', 's', 'n'])
  const values = {}
  for (const part of query.split('&')) {
    if (part === '') throw new Error('qr empty parameter')
    const index = part.indexOf('=')
    if (index < 0) throw new Error('qr parameter without =')
    const key = part.slice(0, index)
    if (!allowed.has(key) || key in values) throw new Error(`qr parameter ${key}`)
    let value
    try {
      value = decodeURIComponent(part.slice(index + 1))
    } catch {
      throw new Error('qr percent encoding')
    }
    values[key] = value
  }
  for (const key of allowed) {
    if (!(key in values)) throw new Error(`qr missing ${key}`)
  }
  if (values.v !== '1') throw new Error('qr version')
  const origin = normalizeOrigin(values.r)
  const machineId = values.m
  if (!/^[a-z2-7]{26}$/.test(machineId)) throw new Error('qr machineId')
  const publicKey = unb64u(values.k, 32)
  if (machineIdOf(publicKey) !== machineId) throw new Error('qr machineId does not match k')
  const secret = unb64u(values.s, 16)
  const name = checkDisplayName(values.n)
  return { v: 1, origin, machineId, publicKey, secret, name }
}
function splitChunks(bytes, chunkBytes) {
  if (!Number.isInteger(chunkBytes) || chunkBytes <= 0) throw new Error('chunk size')
  const chunks = []
  for (let offset = 0, part = 0; offset < bytes.length; offset += chunkBytes, part += 1) {
    const end = Math.min(offset + chunkBytes, bytes.length)
    chunks.push({ part, last: end === bytes.length, data: b64u(bytes.subarray(offset, end)) })
  }
  return chunks
}
function joinChunks(chunks) {
  if (!Array.isArray(chunks) || chunks.length === 0) throw new Error('no chunks')
  const parts = []
  for (let index = 0; index < chunks.length; index += 1) {
    const chunk = chunks[index]
    if (chunk.part !== index) throw new Error('chunk part order')
    if (index < chunks.length - 1 && chunk.last !== false) throw new Error('premature last chunk')
    if (index === chunks.length - 1 && chunk.last !== true) throw new Error('missing last chunk')
    parts.push(unb64u(chunk.data))
  }
  return cat(...parts)
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

function generate() {
  const labels = {
    phoneIdentity: 'pclink-v1/test/identity/phone',
    pcIdentity: 'pclink-v1/test/identity/pc',
    phoneEph: 'pclink-v1/test/eph/phone',
    pcEph: 'pclink-v1/test/eph/pc',
    relayNonce: 'pclink-v1/test/nonce/relay',
    phoneNonce: 'pclink-v1/test/nonce/session/phone',
    pcNonce: 'pclink-v1/test/nonce/session/pc',
    pairNoncePc: 'pclink-v1/test/nonce/pair/pc',
    pairNoncePhone: 'pclink-v1/test/nonce/pair/phone',
    sid: 'pclink-v1/test/sid',
  }
  const phoneEd = edPrivate(labels.phoneIdentity)
  const pcEd = edPrivate(labels.pcIdentity)
  const phonePub = rawPublic(phoneEd)
  const pcPub = rawPublic(pcEd)
  const phoneMachine = machineIdOf(phonePub)
  const pcMachine = machineIdOf(pcPub)
  const relayOrigin = 'https://relay.example'
  const relayNonce = sha256(utf8(labels.relayNonce))
  const sid = sha256(utf8(labels.sid)).subarray(0, 16)
  const sidText = b64u(sid)
  const phoneNonce = sha256(utf8(labels.phoneNonce))
  const pcNonce = sha256(utf8(labels.pcNonce))
  const phoneEph = xPrivate(labels.phoneEph)
  const pcEph = xPrivate(labels.pcEph)
  const phoneEphPub = rawPublic(phoneEph)
  const pcEphPub = rawPublic(pcEph)

  const relayPhoneSig = sign(null, relayAuthTranscript(relayOrigin, relayNonce), phoneEd)
  const relayPcSig = sign(null, relayAuthTranscript(relayOrigin, relayNonce), pcEd)

  const init = {
    v: 1,
    type: 'session.init',
    sid: sidText,
    suite: SUITE,
    eph: b64u(phoneEphPub),
    nonce: b64u(phoneNonce),
  }
  const transcriptInit = cat(
    utf8(DOMAIN.sessionInit), ZERO,
    utf8('1'), ZERO,
    utf8(SUITE), ZERO,
    utf8(phoneMachine), ZERO,
    utf8(pcMachine), ZERO,
    sid, ZERO,
    phoneEphPub, ZERO,
    phoneNonce,
  )
  const th1 = sha256(transcriptInit)
  const dh = diffieHellman({ privateKey: phoneEph, publicKey: xPublic(pcEphPub) })
  if (dh.equals(ZERO32)) throw new Error('generator DH is all zero')
  const transcriptResp = cat(
    utf8(DOMAIN.sessionResp), ZERO,
    th1, ZERO,
    pcEphPub, ZERO,
    pcNonce,
  )
  const th2 = sha256(transcriptResp)
  const phoneToPcKey = hkdf(dh, th2, DOMAIN.keyPhoneToPc, 32)
  const pcToPhoneKey = hkdf(dh, th2, DOMAIN.keyPcToPhone, 32)
  const confirmPhoneKey = hkdf(dh, th2, DOMAIN.keyConfirmPhone, 32)
  const confirmPcKey = hkdf(dh, th2, DOMAIN.keyConfirmPc, 32)
  const respSig = sign(null, transcriptResp, pcEd)
  const respConfirm = hmac(confirmPcKey, cat(utf8(DOMAIN.confirm), ZERO, th2))
  const resp = {
    v: 1,
    type: 'session.resp',
    sid: sidText,
    eph: b64u(pcEphPub),
    nonce: b64u(pcNonce),
    sig: b64u(respSig),
    confirm: b64u(respConfirm),
  }
  const transcriptConfirm = cat(
    utf8(DOMAIN.sessionConfirm), ZERO,
    th2, ZERO,
    utf8(phoneMachine), ZERO,
    utf8(pcMachine), ZERO,
    sid,
  )
  const th3 = sha256(transcriptConfirm)
  const confirmSig = sign(null, transcriptConfirm, phoneEd)
  const confirm = {
    v: 1,
    type: 'session.confirm',
    sid: sidText,
    sig: b64u(confirmSig),
    confirm: b64u(hmac(confirmPhoneKey, cat(utf8(DOMAIN.confirm), ZERO, th3))),
  }
  const transcriptReject = cat(utf8(DOMAIN.sessionReject), ZERO, th1, ZERO, utf8('unpaired'))
  const reject = {
    v: 1,
    type: 'session.reject',
    sid: sidText,
    code: 'unpaired',
    sig: b64u(sign(null, transcriptReject, pcEd)),
    message: 'no pairing record',
  }

  const phoneHello = {
    v: 1,
    type: 'peer.hello',
    role: 'phone',
    caps: ['workspace/1', SUITE],
    dsh: { version: '0.2.2-rc.1', commit: '66491b05' },
    app: { name: 'phoneDSH', version: '0.1.0' },
    name: 'iPhone',
  }
  const pcHello = {
    v: 1,
    type: 'peer.hello',
    role: 'pc',
    caps: ['workspace/1', SUITE],
    dsh: { version: '0.2.2-rc.1', commit: '66491b05' },
    app: { name: 'dsh-pclink', version: '0.1.0' },
    name: 'My PC',
  }
  const rpcCall = { type: 'rpc.call', id: 'call-1', endpoint: 'session/list', args: { _request: {} } }
  const rpcResult = { type: 'rpc.result', id: 'call-1', ok: true, result: { items: [] } }
  const streamOpen = {
    type: 'rpc.stream.open',
    streamId: 'stream-1',
    endpoint: 'session/follow',
    payload: { args: { request: { address: { kind: 'session', sessionId: 'session-1' }, maxMessages: 1, assistantStream: true } } },
  }
  const streamItem = { type: 'rpc.stream.item', streamId: 'stream-1', value: { type: 'snapshot', cursor: 0, records: [] } }
  const resultValue = { type: 'rpc.result', id: 'call-2', ok: true, result: { items: [] } }
  const streamChunk = {
    type: 'rpc.stream.chunk', streamId: 'stream-1', part: 0, last: true,
    data: b64u(utf8(JSON.stringify(streamItem.value))),
  }
  const resultChunk = {
    type: 'rpc.result.chunk', id: 'call-2', part: 0, last: true,
    data: b64u(utf8(JSON.stringify(resultValue))),
  }
  const sessionClose = { type: 'session.close', code: 'unavailable', message: 'test close' }

  const frames = []
  const addFrame = (name, direction, seq, inner) => {
    const from = direction === 'phone_to_pc' ? phoneMachine : pcMachine
    const to = direction === 'phone_to_pc' ? pcMachine : phoneMachine
    const key = direction === 'phone_to_pc' ? phoneToPcKey : pcToPhoneKey
    const plaintext = utf8(JSON.stringify(inner))
    const aad = aadBytes(sidText, seq, from, to)
    const body = seal(key, seq, aad, plaintext)
    frames.push({
      case: name, direction, sid: sidText, seq, from, to,
      inner_type: inner.type, plaintext: plaintext.toString('utf8'),
      aad_hex: hex(aad), nonce_hex: hex(aeadNonce(seq)), body: b64u(body),
    })
  }
  addFrame('phone-peer-hello-seq0', 'phone_to_pc', 0, phoneHello)
  addFrame('pc-peer-hello-seq0', 'pc_to_phone', 0, pcHello)
  addFrame('phone-rpc-call-seq1', 'phone_to_pc', 1, rpcCall)
  addFrame('pc-rpc-result-seq1', 'pc_to_phone', 1, rpcResult)
  addFrame('phone-stream-open-seq2', 'phone_to_pc', 2, streamOpen)
  addFrame('pc-stream-item-seq2', 'pc_to_phone', 2, streamItem)
  addFrame('pc-stream-chunk-seq3', 'pc_to_phone', 3, streamChunk)
  addFrame('pc-result-chunk-seq4', 'pc_to_phone', 4, resultChunk)
  addFrame('phone-session-close-seq3', 'phone_to_pc', 3, sessionClose)

  const smallValue = { text: 'abcdef' }
  const smallBytes = utf8(JSON.stringify(smallValue))
  const smallChunks = splitChunks(smallBytes, 5)
  if (!joinChunks(smallChunks).equals(smallBytes)) throw new Error('small chunk self-test failed')

  const interleaveA = { text: 'alpha-0123456789' }
  const interleaveB = { text: 'beta-ABCDEFGHIJ' }
  const interleaveBytesA = utf8(JSON.stringify(interleaveA))
  const interleaveBytesB = utf8(JSON.stringify(interleaveB))
  const chunksA = splitChunks(interleaveBytesA, 4).map(chunk => ({ ...chunk, streamId: 'stream-a' }))
  const chunksB = splitChunks(interleaveBytesB, 4).map(chunk => ({ ...chunk, streamId: 'stream-b' }))
  const interleaveEvents = []
  for (let index = 0; index < Math.max(chunksA.length, chunksB.length); index += 1) {
    if (index < chunksA.length) interleaveEvents.push(chunksA[index])
    if (index < chunksB.length) interleaveEvents.push(chunksB[index])
  }

  const thresholdBytes = utf8(JSON.stringify('a'.repeat(THRESHOLD)))
  const thresholdChunks = splitChunks(thresholdBytes, THRESHOLD)
  if (!joinChunks(thresholdChunks).equals(thresholdBytes)) throw new Error('threshold chunk self-test failed')

  const chunking = {
    threshold_bytes: THRESHOLD,
    max_value_bytes: MAX_VALUE,
    max_frame_bytes: MAX_FRAME,
    seq_rekey: SEQ_REKEY,
    seq_max: SEQ_MAX,
    byte_rekey: BYTE_REKEY,
    byte_hard: BYTE_HARD,
    small: {
      test_only: true, value: smallValue, chunk_bytes: 5, chunks: smallChunks,
      reassembled_sha256: hex(sha256(smallBytes)),
    },
    result_chunk: {
      test_only: true, result: resultValue, chunk_bytes: 8,
      chunks: splitChunks(utf8(JSON.stringify(resultValue)), 8),
      reassembled_sha256: hex(sha256(utf8(JSON.stringify(resultValue)))),
    },
    interleave: {
      test_only: true, chunk_bytes: 4, events: interleaveEvents,
      values: { 'stream-a': interleaveA, 'stream-b': interleaveB },
      reassembled_sha256: {
        'stream-a': hex(sha256(interleaveBytesA)),
        'stream-b': hex(sha256(interleaveBytesB)),
      },
    },
    threshold: {
      repeat: 'a', repeat_count: THRESHOLD, json_bytes: thresholdBytes.length,
      chunk_bytes: THRESHOLD, parts: thresholdChunks.length,
      last_last: thresholdChunks[thresholdChunks.length - 1].last,
      reassembled_sha256: hex(sha256(thresholdBytes)),
    },
    too_large: { json_bytes: MAX_VALUE + 1, limit: MAX_VALUE, expected: 'frame_too_large' },
    cancel: { chunks_before_cancel: 1, expected: 'discard' },
  }

  const secretS = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex')
  const secretC = Buffer.from('0a1b2c3d4e5f60718293', 'hex')
  const manualDisplay = crockfordEncode(secretC)
  const manualInput = 'l8dj-rfae bxg7-3omk'
  const manual = crockfordDecode(manualInput)
  if (!manual.bytes.equals(secretC)) throw new Error('manual code self-test failed')
  const pairingOrigin = relayOrigin
  const pairNoncePc = sha256(utf8(labels.pairNoncePc))
  const pairNoncePhone = sha256(utf8(labels.pairNoncePhone))
  const pairNamePc = 'My PC'
  const pairNamePhone = 'iPhone'
  const keyS = pairKey(secretS)
  const keyC = pairKey(secretC)
  const helloNoMac = {
    v: 1, type: 'pair.hello', role: 'pc', machineId: pcMachine,
    publicKey: b64u(pcPub), name: pairNamePc, relay: pairingOrigin,
    nonce: b64u(pairNoncePc),
  }
  const authNoMac = {
    v: 1, type: 'pair.auth', role: 'phone', machineId: phoneMachine,
    publicKey: b64u(phonePub), name: pairNamePhone, relay: pairingOrigin,
    nonce: b64u(pairNoncePhone), peerNonce: b64u(pairNoncePc),
  }
  const trans1 = sha256(utf8(canonicalJson(helloNoMac)))
  const trans2 = sha256(utf8(canonicalJson(authNoMac)))
  const transcriptHash = sha256(cat(trans1, ZERO, trans2))
  const hello = withMac(keyS, DOMAIN.pairHello, helloNoMac)
  const auth = withMac(keyS, DOMAIN.pairAuth, authNoMac)
  const confirmNoMac = {
    v: 1, type: 'pair.confirm', role: 'pc', nonce: b64u(pairNoncePc),
    peerNonce: b64u(pairNoncePhone), transcriptHash: b64u(transcriptHash),
  }
  const finalNoMac = {
    v: 1, type: 'pair.final', role: 'phone', nonce: b64u(pairNoncePhone),
    peerNonce: b64u(pairNoncePc), transcriptHash: b64u(transcriptHash),
  }
  const pairConfirm = withMac(keyS, DOMAIN.pairConfirm, confirmNoMac)
  const pairFinal = withMac(keyS, DOMAIN.pairFinal, finalNoMac)
  // Complete manual-mode exchange under keyC.  The payload objects are the same
  // as the QR ones; only the pairing key differs.  These MACs are real crypto
  // evidence, not a boolean model.
  const manualHello = withMac(keyC, DOMAIN.pairHello, helloNoMac)
  const manualAuth = withMac(keyC, DOMAIN.pairAuth, authNoMac)
  const manualConfirm = withMac(keyC, DOMAIN.pairConfirm, confirmNoMac)
  const manualFinal = withMac(keyC, DOMAIN.pairFinal, finalNoMac)
  const pairedAt = '2026-11-09T00:00:00Z'
  const approvedAt = '2026-11-09T00:00:05Z'
  const approvalAt = '2026-11-09T00:00:05Z'
  const pcRecord = {
    peerMachineId: phoneMachine,
    peerPublicKey: b64u(phonePub),
    peerName: pairNamePhone,
    pairedAt,
    relayOrigin: pairingOrigin,
    connection: { mode: 'relay' },
    approvedAt,
    approvedVia: 'qr',
  }
  const phoneRecord = {
    peerMachineId: pcMachine,
    peerPublicKey: b64u(pcPub),
    peerName: pairNamePc,
    pairedAt,
    relayOrigin: pairingOrigin,
    connection: { mode: 'relay' },
    pairingMode: 'qr',
  }
  const recordSha256 = hex(sha256(utf8(canonicalJson(pcRecord))))
  const pairEntry = {
    v: 1, event: 'pair', peerMachineId: phoneMachine,
    peerPublicKey: b64u(phonePub), recordSha256,
    approvedAt, approvedVia: 'qr', at: approvalAt,
  }
  const unpairEntry = { v: 1, event: 'unpair', peerMachineId: phoneMachine, at: '2026-11-09T01:00:00Z' }
  const fingerprint = `${phoneMachine.slice(0, 4)}-${phoneMachine.slice(4, 8)}-${phoneMachine.slice(8, 12)}`
  const pcFingerprint = `${pcMachine.slice(0, 4)}-${pcMachine.slice(4, 8)}-${pcMachine.slice(8, 12)}`
  const fingerprintInputs = [
    fingerprint,
    fingerprint.toUpperCase(),
    fingerprint.replace(/-/g, ' '),
    fingerprint.replace(/-/g, ''),
    fingerprint.toUpperCase().replace(/-/g, '  '),
  ]
  const wrongFingerprint = '2222-2222-2222'
  if (!/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/.test(fingerprint)) {
    throw new Error('generator fingerprint format self-test failed')
  }
  // A second well-formed init is used only by the real-crypto reject negative:
  // a signature valid for init A must not verify against init B's th1.
  const initBNonce = sha256(utf8('pclink-v1/test/nonce/session/phone/2'))
  const initB = { ...init, nonce: b64u(initBNonce) }
  const transcriptInitB = cat(
    utf8(DOMAIN.sessionInit), ZERO,
    utf8('1'), ZERO,
    utf8(SUITE), ZERO,
    utf8(phoneMachine), ZERO,
    utf8(pcMachine), ZERO,
    sid, ZERO,
    phoneEphPub, ZERO,
    initBNonce,
  )
  const th1B = sha256(transcriptInitB)
  const qr = {
    uri: qrUri({ origin: pairingOrigin, machineId: pcMachine, publicKey: pcPub, secret: secretS, name: pairNamePc }),
  }
  const parsed = parseQr(qr.uri)
  qr.parsed = {
    origin: parsed.origin, machineId: parsed.machineId,
    publicKey: b64u(parsed.publicKey), secret: b64u(parsed.secret),
    name: parsed.name, ws_url: wsUrl(parsed.origin),
  }

  const canonical = {
    scalar_order: {
      object: {
        [String.fromCodePoint(0xe000)]: 'bmp-private-use',
        [String.fromCodePoint(0x10000)]: 'astral',
      },
    },
    slash_and_nonascii: {
      object: { path: 'a/b', name: 'café', note: 'line\nbreak' },
    },
    nul_escape: {
      object: { 'a\u0000b': 'key', note: 'a\u0000b' },
    },
  }
  for (const entry of Object.values(canonical)) {
    entry.canonical = canonicalJson(entry.object)
    entry.sha256_hex = hex(sha256(utf8(entry.canonical)))
  }

  // §2.3: the strict JSON rules apply to wire bytes.  A legal \u0000 escape
  // inside a carried DSH value is data; a literal 0x00 byte, BOM, duplicate
  // member, lone surrogate or non-object root is bad_frame.  PCLink-owned
  // fields keep their own field rules, so a name/machineId containing U+0000
  // is still rejected.
  const jsonBoundary = {
    rule: '§2.3: strict JSON applies to wire bytes; a legal JSON escape \\u0000 in a carried DSH value is accepted and preserved, while a literal 0x00 byte, BOM, duplicate member, lone surrogate and non-object root are rejected; PCLink-owned fields keep their own field rules',
    passthrough: [
      'rpc.call.args',
      'rpc.stream.open.payload.args',
      'rpc.result.result',
      'rpc.stream.item.value',
      'rpc.result.chunk.data(decoded)',
      'rpc.stream.chunk.data(decoded)',
    ],
    accepted: [
      {
        case: 'carried-escaped-nul-rpc-args',
        passthrough: 'rpc.call.args',
        wire: JSON.stringify({
          type: 'rpc.call', id: 'call-nul', endpoint: 'session/list',
          args: { _request: {}, note: 'a\u0000b' },
        }),
        nul_paths: [['args', 'note']],
        expected: 'accept',
      },
      {
        case: 'carried-escaped-nul-stream-open-args',
        passthrough: 'rpc.stream.open.payload.args',
        wire: JSON.stringify({
          type: 'rpc.stream.open', streamId: 'stream-nul', endpoint: 'session/follow',
          payload: { args: { request: { note: 'a\u0000b' } } },
        }),
        nul_paths: [['payload', 'args', 'request', 'note']],
        expected: 'accept',
      },
      {
        case: 'carried-escaped-nul-rpc-result',
        passthrough: 'rpc.result.result',
        wire: JSON.stringify({
          type: 'rpc.result', id: 'call-nul', ok: true,
          result: { text: 'a\u0000b', nested: ['c\u0000d'] },
        }),
        nul_paths: [['result', 'text'], ['result', 'nested', 0]],
        expected: 'accept',
      },
      {
        case: 'carried-escaped-nul-stream-item',
        passthrough: 'rpc.stream.item.value',
        wire: JSON.stringify({
          type: 'rpc.stream.item', streamId: 'stream-nul',
          value: { text: 'a\u0000b' },
        }),
        nul_paths: [['value', 'text']],
        expected: 'accept',
      },
      {
        case: 'carried-escaped-nul-stream-chunk',
        passthrough: 'rpc.stream.chunk.data(decoded)',
        wire: JSON.stringify({
          type: 'rpc.stream.chunk', streamId: 'stream-nul', part: 0, last: true,
          data: b64u(utf8(JSON.stringify({ text: 'a\u0000b' }))),
        }),
        chunk_data_nul_paths: [['text']],
        expected: 'accept',
      },
      {
        case: 'carried-escaped-nul-result-chunk',
        passthrough: 'rpc.result.chunk.data(decoded)',
        wire: JSON.stringify({
          type: 'rpc.result.chunk', id: 'call-nul', part: 0, last: true,
          data: b64u(utf8(JSON.stringify({ text: 'a\u0000b' }))),
        }),
        chunk_data_nul_paths: [['text']],
        expected: 'accept',
      },
    ],
    rejected: [
      {
        case: 'wire-literal-nul',
        failure: 'wire',
        wire_hex: hex(Buffer.from(
          '{"type":"rpc.call","id":"call-nul","endpoint":"session/list","args":{"note":"a\u0000b"}}',
          'utf8',
        )),
        expected: 'bad_frame',
      },
      {
        case: 'wire-bom',
        failure: 'wire',
        wire_hex: hex(Buffer.from('\ufeff{"v":1}', 'utf8')),
        expected: 'bad_frame',
      },
      {
        case: 'wire-duplicate-key',
        failure: 'wire',
        wire: '{"type":"rpc.call","id":"call-nul","endpoint":"session/list","args":{"note":"a","note":"b"}}',
        expected: 'bad_frame',
      },
      {
        case: 'wire-nested-duplicate-key',
        failure: 'wire',
        wire: '{"type":"rpc.call","id":"call-nul","endpoint":"session/list","args":{"note":{"a":1,"a":2}}}',
        expected: 'bad_frame',
      },
      {
        case: 'wire-lone-surrogate',
        failure: 'wire',
        wire: '{"type":"rpc.call","id":"call-nul","endpoint":"session/list","args":{"note":"\\ud800"}}',
        expected: 'bad_frame',
      },
      {
        case: 'wire-non-object-root',
        failure: 'wire',
        wire: '[]',
        expected: 'bad_frame',
      },
      {
        case: 'pclink-name-escaped-nul',
        failure: 'field',
        field_rule: 'name',
        field_path: ['name'],
        wire: JSON.stringify({
          type: 'pclink.notice', kind: 'paired', name: 'a\u0000b',
          fingerprint: '7gdx-eack-pmfr', at: '2026-11-09T00:00:05Z',
        }),
        expected: 'bad_frame',
      },
      {
        case: 'pclink-to-escaped-nul',
        failure: 'field',
        field_rule: 'machineId',
        field_path: ['to'],
        wire: JSON.stringify({ v: 1, type: 'relay.offline', to: 'a\u0000b' }),
        expected: 'bad_frame',
      },
    ],
  }

  const adminToken = sha256(utf8('pclink-v1/test/admin/token'))
  const adminNonce = sha256(utf8('pclink-v1/test/admin/nonce'))
  const adminProof = hmac(adminToken, cat(utf8(DOMAIN.adminProof), ZERO, adminNonce))

  const resources = {
    sid_cache: {
      limit: 4096,
      cases: [
        { entries: 4096, expected: 'accept' },
        { entries: 4097, expected: 'evict_lru' },
      ],
    },
    pairing_slots: {
      limit: 2,
      cases: [
        { open: 2, expected: 'accept' },
        { open: 3, expected: 'exhausted' },
      ],
    },
    ipv6: { address: '2001:db8:1:2::1', expected: '2001:db8:1:2::/64' },
    e2e_idle: { idle_ms: 900001, limit_ms: 900000, expected: 'session_expired' },
    confirm_recheck: {
      approved: { record: pcRecord, audit: [pairEntry], expected: 'establish' },
      revoked: { record: pcRecord, audit: [pairEntry, unpairEntry], expected: 'abort' },
    },
    unpair_abort: { handshake_in_progress: true, unpair: true, expected: 'abort' },
    approval: {
      auto_qr: { mode: 'qr', approved: true, expected: 'confirm_sent' },
      auto_manual: { mode: 'manual', approved: true, expected: 'confirm_sent' },
      bad_mode: { mode: 'future', approved: true, expected: 'bad_frame' },
    },
    admin_peer: {
      rule: 'the /api/pclink.admin/* handler decides by the request source Peer, not by the endpoint string; the forwarder prefix check is a fast path only',
      cases: [
        { source: 'pclink_remote', endpoint: 'pclink.admin/status', expected: 'forbidden' },
        { source: 'pclink_remote', endpoint: 'PCLink.Admin/status', expected: 'forbidden' },
        { source: 'owner_webui', endpoint: 'pclink.admin/status', expected: 'allow' },
      ],
    },
  }

  const invalid = []
  const add = row => invalid.push(row)

  // Handshake signature/transcript negatives.
  add({
    case: 'hs-resp-wrong-signature', kind: 'handshake_signature',
    transcript_hex: hex(transcriptResp), public_key: b64u(pcPub),
    signature: b64u(Buffer.concat([Buffer.from([respSig[0] ^ 0xff]), respSig.subarray(1)])),
    expected: 'auth_failed',
  })
  add({
    case: 'hs-resp-signed-by-phone-key', kind: 'handshake_signature',
    transcript_hex: hex(transcriptResp), public_key: b64u(pcPub),
    signature: b64u(sign(null, transcriptResp, phoneEd)), expected: 'auth_failed',
  })
  add({
    case: 'hs-confirm-signed-by-pc-key', kind: 'handshake_signature',
    transcript_hex: hex(transcriptConfirm), public_key: b64u(phonePub),
    signature: b64u(sign(null, transcriptConfirm, pcEd)), expected: 'auth_failed',
  })
  add({
    case: 'hs-init-version-mutated', kind: 'handshake_transcript',
    init: { ...init, v: 2 }, from: phoneMachine, to: pcMachine,
    reference_hex: hex(th1), expected: 'auth_failed',
  })
  add({
    case: 'hs-init-suite-mutated', kind: 'handshake_transcript',
    init: { ...init, suite: 'pclink-unknown-suite' }, from: phoneMachine, to: pcMachine,
    reference_hex: hex(th1), expected: 'auth_failed',
  })
  add({
    case: 'hs-init-machineid-swapped', kind: 'handshake_transcript',
    init, from: pcMachine, to: phoneMachine,
    reference_hex: hex(th1), expected: 'auth_failed',
  })
  add({
    case: 'hs-outer-body-sid-mismatch', kind: 'sid_mismatch',
    outer_sid: sidText, body_sid: b64u(sha256(utf8('pclink-v1/test/sid/other')).subarray(0, 16)),
    expected: 'bad_frame',
  })
  add({
    case: 'hs-resp-cross-sid', kind: 'cross_sid',
    expected_sid: sidText, message_type: 'session.resp',
    message_sid: b64u(sha256(utf8('pclink-v1/test/sid/other')).subarray(0, 16)),
    expected: 'replay',
  })
  add({
    case: 'hs-confirm-cross-sid-replay', kind: 'cross_sid',
    expected_sid: sidText, message_type: 'session.confirm',
    message_sid: b64u(sha256(utf8('pclink-v1/test/sid/third')).subarray(0, 16)),
    expected: 'replay',
  })
  add({
    case: 'hs-x25519-all-zero', kind: 'x25519', private_label: labels.phoneEph,
    public_key: b64u(ZERO32), expected: 'auth_failed',
  })
  add({
    case: 'hs-x25519-low-order-one', kind: 'x25519', private_label: labels.phoneEph,
    public_key: b64u(cat(Buffer.from([1]), Buffer.alloc(31))), expected: 'auth_failed',
  })
  add({
    case: 'hs-reflect-init-to-phone', kind: 'reflection',
    sender: 'pc', body_type: 'session.init', expected: 'bad_frame',
  })
  add({
    case: 'hs-phone-sends-resp', kind: 'reflection',
    sender: 'phone', body_type: 'session.resp', expected: 'bad_frame',
  })
  add({
    case: 'hs-unpaired-from', kind: 'pairing_lookup',
    from: 'aaaaaaaabbbbbbbbccccccccdd', paired_machine_ids: [phoneMachine],
    records_sid: false, expected: 'unpaired',
  })
  add({
    case: 'reject-unsigned-unpaired-keeps-record', kind: 'reject',
    verified: false, code: 'unpaired', th1_matches: true, has_record: true,
    expected: 'keep_record',
  })
  add({
    case: 'reject-wrong-key-unpaired-keeps-record', kind: 'reject',
    verified: false, code: 'unpaired', th1_matches: true, has_record: true,
    expected: 'keep_record',
  })
  add({
    case: 'reject-signed-unpaired-prompts', kind: 'reject',
    verified: true, code: 'unpaired', th1_matches: true, has_record: true,
    expected: 'prompt',
  })
  add({
    case: 'reject-signed-auth-failed-keeps-record', kind: 'reject',
    verified: true, code: 'auth_failed', th1_matches: true, has_record: true,
    expected: 'keep_record',
  })
  add({
    case: 'unapproved-record-rejected', kind: 'record',
    record: pcRecord, audit: [], expected: 'unapproved',
  })
  add({
    case: 'revoked-record-rejected', kind: 'record',
    record: pcRecord, audit: [pairEntry, unpairEntry], expected: 'revoked',
  })
  add({
    case: 'pairing-auto-approved-qr', kind: 'approval',
    mode: 'qr', approved: true, expected: 'confirm_sent',
  })
  add({
    case: 'pairing-auto-approved-manual', kind: 'approval',
    mode: 'manual', approved: true, expected: 'confirm_sent',
  })
  add({
    case: 'fingerprint-unpair-target-wrong', kind: 'fingerprint',
    public_key: b64u(phonePub), entered: wrongFingerprint, expected: 'blocked',
  })
  add({
    case: 'status-awaiting-approval-hides-fingerprint', kind: 'status_redaction',
    state: 'awaiting_approval',
    fields: ['id', 'state', 'mode', 'expiresAt', 'peerName'],
    forbidden: ['peerFingerprint', 'peerMachineId', 'peerPublicKey'],
    expected: 'redacted',
  })

  // Real-crypto reject negatives: the signature is valid for the named
  // reference transcript and must fail for the other th1/code.
  add({
    case: 'reject-valid-for-init-a-fails-init-b', kind: 'reject_transcript',
    signed_th1_hex: hex(th1), signed_code: 'unpaired',
    verified_th1_hex: hex(th1B), verified_code: 'unpaired',
    public_key: b64u(pcPub), signature: reject.sig, expected: 'auth_failed',
  })
  add({
    case: 'reject-unpaired-code-swapped', kind: 'reject_transcript',
    signed_th1_hex: hex(th1), signed_code: 'unpaired',
    verified_th1_hex: hex(th1), verified_code: 'auth_failed',
    public_key: b64u(pcPub), signature: reject.sig, expected: 'auth_failed',
  })

  // AEAD negatives.
  add({
    case: 'aead-reverse-direction-key', kind: 'aead', direction: 'phone_to_pc',
    key_direction: 'pc_to_phone', frame: { ...frames[2] }, expected: 'auth_failed',
  })
  add({
    case: 'aead-tamper-from', kind: 'aead', direction: 'phone_to_pc',
    frame: { ...frames[2], from: pcMachine }, expected: 'auth_failed',
  })
  add({
    case: 'aead-tamper-sid', kind: 'aead', direction: 'phone_to_pc',
    frame: { ...frames[2], sid: b64u(sha256(utf8('pclink-v1/test/sid/other')).subarray(0, 16)) },
    expected: 'auth_failed',
  })
  add({
    case: 'aead-tamper-v', kind: 'aead', direction: 'phone_to_pc',
    frame: { ...frames[2], v: 2 }, expected: 'auth_failed',
  })
  add({
    case: 'aead-cross-session-splice', kind: 'aead', direction: 'phone_to_pc',
    key_b64: b64u(sha256(utf8('pclink-v1/test/key/other'))),
    frame: { ...frames[2] }, expected: 'auth_failed',
  })
  add({ case: 'seq-first-nonzero', kind: 'seq', first: true, last_seq: 0, seq: 1, expected: 'bad_frame' })
  add({ case: 'seq-replay', kind: 'seq', first: false, last_seq: 3, seq: 3, expected: 'replay' })
  add({ case: 'seq-gap', kind: 'seq', first: false, last_seq: 3, seq: 5, expected: 'bad_frame' })
  add({ case: 'seq-hard-cap', kind: 'seq', first: false, last_seq: SEQ_MAX - 1, seq: SEQ_MAX, expected: 'session_expired' })
  add({ case: 'seq-byte-hard-cap', kind: 'seq', first: false, last_seq: 0, seq: 1, bytes: BYTE_HARD + 1, expected: 'session_expired' })
  add({ case: 'first-frame-rpc-call', kind: 'first_frame', type: 'rpc.call', expected: 'bad_frame' })
  add({ case: 'b64url-padding', kind: 'encoding', text: `${b64u(pcPub)}=`, expected: 'bad_frame' })
  add({ case: 'b64url-noncanonical-last-char', kind: 'encoding', text: `${b64u(ZERO32).slice(0, 42)}B`, expected: 'bad_frame' })

  // Canonical JSON negatives.
  add({
    case: 'canonical-slash-escaped', kind: 'canonical',
    candidate: '{"path":"a\\/b","name":"café","note":"line\\nbreak"}', expected: 'bad_frame',
  })
  add({
    case: 'canonical-nonascii-escaped', kind: 'canonical',
    candidate: '{"path":"a/b","name":"caf\\u00e9","note":"line\\nbreak"}', expected: 'bad_frame',
  })
  add({
    case: 'canonical-utf16-key-order', kind: 'canonical',
    candidate: `{${JSON.stringify(String.fromCodePoint(0x10000))}:"astral",${JSON.stringify(String.fromCodePoint(0xe000))}:"bmp"}`,
    expected: 'bad_frame',
  })
  add({
    case: 'canonical-uppercase-hex-escape', kind: 'canonical',
    candidate: '{"path":"a/b","name":"café","note":"line\\u000Abreak"}', expected: 'bad_frame',
  })

  // Chunking negatives.
  add({
    case: 'chunk-duplicate-part', kind: 'chunk',
    events: [
      { streamId: 'stream-x', part: 0, last: false, data: b64u(utf8('a')) },
      { streamId: 'stream-x', part: 0, last: false, data: b64u(utf8('b')) },
      { streamId: 'stream-x', part: 1, last: true, data: b64u(utf8('c')) },
    ], expected: 'bad_frame',
  })
  add({
    case: 'chunk-two-last', kind: 'chunk',
    events: [
      { streamId: 'stream-y', part: 0, last: true, data: b64u(utf8('a')) },
      { streamId: 'stream-y', part: 1, last: true, data: b64u(utf8('b')) },
    ], expected: 'bad_frame',
  })
  add({
    case: 'chunk-missing-part', kind: 'chunk',
    events: [
      { streamId: 'stream-z', part: 0, last: false, data: b64u(utf8('a')) },
      { streamId: 'stream-z', part: 2, last: true, data: b64u(utf8('c')) },
    ], expected: 'bad_frame',
  })
  add({
    case: 'chunk-too-large', kind: 'chunk', bytes: MAX_VALUE + 1, limit: MAX_VALUE,
    expected: 'frame_too_large',
  })

  // QR/manual negatives.
  add({ case: 'qr-unknown-param', kind: 'qr', uri: `${qr.uri}&x=1`, expected: 'bad_frame' })
  add({ case: 'qr-duplicate-param', kind: 'qr', uri: `${qr.uri}&v=1`, expected: 'bad_frame' })
  add({ case: 'qr-plus', kind: 'qr', uri: qr.uri.replace('My%20PC', 'My+PC'), expected: 'bad_frame' })
  add({
    case: 'qr-too-long', kind: 'qr',
    uri: qrUri({ origin: pairingOrigin, machineId: pcMachine, publicKey: pcPub, secret: secretS, name: 'a'.repeat(64) }) + '&x=' + 'a'.repeat(600),
    expected: 'bad_frame',
  })
  add({ case: 'qr-wrong-scheme', kind: 'qr', uri: 'https://pair.example/?v=1', expected: 'bad_frame' })
  add({
    case: 'qr-key-swap', kind: 'qr',
    uri: qrUri({ origin: pairingOrigin, machineId: phoneMachine, publicKey: phonePub, secret: secretS, name: pairNamePc }),
    expected_public_key: b64u(pcPub), expected: 'auth_failed',
  })
  add({
    case: 'qr-machineid-mismatch', kind: 'qr',
    uri: qrUri({ origin: pairingOrigin, machineId: phoneMachine, publicKey: pcPub, secret: secretS, name: pairNamePc }),
    expected_machine_id: pcMachine, expected: 'auth_failed',
  })
  add({ case: 'manual-illegal-u', kind: 'manual', input: `U${manualDisplay.slice(1)}`, expected: 'bad_frame' })
  add({ case: 'manual-too-short', kind: 'manual', input: '18DJ-RFAE', expected: 'bad_frame' })
  add({ case: 'manual-illegal-char', kind: 'manual', input: `18DJ-RFAE-BXG7-30M!`, expected: 'bad_frame' })

  // Names, origin, errors, sizes, suites, slots, MACs, frames.
  add({ case: 'name-overlong-bytes', kind: 'name', name: '汉'.repeat(33), expected: 'bad_frame' })
  add({ case: 'name-non-nfc', kind: 'name', name: 'Cafe\u0301', expected: 'bad_frame' })
  add({ case: 'name-bidi-format', kind: 'name', name: 'My \u202ePC', expected: 'bad_frame' })
  add({ case: 'name-c0-control', kind: 'name', name: 'My\nPC', expected: 'bad_frame' })
  add({ case: 'relay-origin-mismatch', kind: 'origin', actual: 'https://other.example', expected_origin: relayOrigin, expected: 'auth_failed' })
  add({ case: 'unknown-pclink-code', kind: 'unknown_code', code: 'too_many_requests', expected: 'bad_frame' })
  add({ case: 'frame-missing-to', kind: 'frame', frame: { v: 1, type: 'e2e', sid: sidText, seq: 0, from: phoneMachine, body: frames[0].body }, expected: 'bad_frame' })
  add({ case: 'frame-too-large', kind: 'size', bytes: MAX_FRAME + 1, limit: MAX_FRAME, expected: 'frame_too_large' })
  add({ case: 'value-too-large', kind: 'size', bytes: MAX_VALUE + 1, limit: MAX_VALUE, expected: 'frame_too_large' })
  add({ case: 'suite-unsupported', kind: 'suite', suite: 'pclink-unknown-suite', expected: 'version_unsupported' })
  add({ case: 'caps-no-intersection', kind: 'caps', caps: ['workspace/1'], required: ['workspace/1', SUITE], expected: 'version_unsupported' })
  add({ case: 'slot-expired', kind: 'slot', opened_ms: 0, now_ms: 300001, ttl_ms: 300000, joins: 1, limit: 10, matched: false, expected: 'expired' })
  add({ case: 'slot-exhausted', kind: 'slot', opened_ms: 0, now_ms: 1, ttl_ms: 300000, joins: 11, limit: 10, matched: false, expected: 'exhausted' })
  add({
    case: 'chunk-interleave-missing-last', kind: 'chunk',
    events: [
      { streamId: 'stream-a', part: 0, last: false, data: b64u(utf8('a')) },
      { streamId: 'stream-b', part: 0, last: true, data: b64u(utf8('b')) },
      { streamId: 'stream-a', part: 1, last: false, data: b64u(utf8('c')) },
    ], expected: 'bad_frame',
  })
  add({ case: 'remote-admin-endpoint-forbidden', kind: 'forbidden_endpoint', endpoint: 'pclink.admin/status', expected: 'forbidden' })
  add({
    case: 'admin-remote-peer-case-variant', kind: 'admin_peer',
    source: 'pclink_remote', endpoint: 'PCLink.Admin/status', expected: 'forbidden',
  })
  add({ case: 'confirm-recheck-revoked', kind: 'confirm_recheck', record: pcRecord, audit: [pairEntry, unpairEntry], expected: 'abort' })
  add({ case: 'unpair-aborts-in-progress-handshake', kind: 'unpair_abort', handshake_in_progress: true, unpair: true, expected: 'abort' })
  add({ case: 'e2e-idle-timeout', kind: 'idle', idle_ms: 900001, limit_ms: 900000, expected: 'session_expired' })
  add({ case: 'pair-slots-per-connection', kind: 'slots', open: 3, limit: 2, expected: 'exhausted' })
  add({ case: 'relay-origin-uppercase', kind: 'origin', actual: 'https://Relay.Example', expected_origin: relayOrigin, expected: 'auth_failed' })
  add({
    case: 'pair-mac-mutated', kind: 'pair_mac', pair_key_b64: b64u(keyS), domain: DOMAIN.pairAuth,
    object: {
      ...auth,
      mac: b64u(Buffer.concat([Buffer.from([unb64u(auth.mac, 32)[0] ^ 0xff]), unb64u(auth.mac, 32).subarray(1)])),
    }, expected: 'auth_failed',
  })
  add({
    case: 'manual-auth-mac-mutated', kind: 'pair_mac', pair_key_b64: b64u(keyC), domain: DOMAIN.pairAuth,
    object: {
      ...manualAuth,
      mac: b64u(Buffer.concat([
        Buffer.from([unb64u(manualAuth.mac, 32)[0] ^ 0xff]),
        unb64u(manualAuth.mac, 32).subarray(1),
      ])),
    }, expected: 'auth_failed',
  })
  add({
    case: 'manual-confirm-mac-wrong-key', kind: 'pair_mac', pair_key_b64: b64u(keyS), domain: DOMAIN.pairConfirm,
    object: manualConfirm, expected: 'auth_failed',
  })
  add({
    case: 'manual-hello-mac-wrong-key', kind: 'pair_mac', pair_key_b64: b64u(keyC), domain: DOMAIN.pairHello,
    object: { ...manualHello, mac: hello.mac }, expected: 'auth_failed',
  })

  // The boolean state-machine rows are counted separately from crypto rows.
  const MODEL_CASES = new Set([
    'pairing-auto-approved-qr',
    'pairing-auto-approved-manual',
    'status-awaiting-approval-hides-fingerprint',
    'unapproved-record-rejected',
    'revoked-record-rejected',
    'reject-unsigned-unpaired-keeps-record',
    'reject-wrong-key-unpaired-keeps-record',
    'reject-signed-unpaired-prompts',
    'reject-signed-auth-failed-keeps-record',
    'hs-reflect-init-to-phone',
    'hs-phone-sends-resp',
    'hs-unpaired-from',
    'seq-first-nonzero',
    'seq-replay',
    'seq-gap',
    'seq-hard-cap',
    'seq-byte-hard-cap',
    'first-frame-rpc-call',
    'slot-expired',
    'slot-exhausted',
    'confirm-recheck-revoked',
    'unpair-aborts-in-progress-handshake',
    'e2e-idle-timeout',
    'pair-slots-per-connection',
    'remote-admin-endpoint-forbidden',
    'admin-remote-peer-case-variant',
  ])
  for (const row of invalid) row.evidence = MODEL_CASES.has(row.case) ? 'model' : 'crypto'

  return {
    format: 'pclink-v1-vectors',
    format_version: 3,
    revision: REVISION,
    suite: SUITE,
    test_key_rule: 'sha256(utf8(label)) is the raw private key; these are public test labels, never production keys',
    labels,
    identities: {
      phone: { seed_label: labels.phoneIdentity, public_key: b64u(phonePub), machine_id: phoneMachine, sha256_hex: hex(sha256(phonePub)) },
      pc: { seed_label: labels.pcIdentity, public_key: b64u(pcPub), machine_id: pcMachine, sha256_hex: hex(sha256(pcPub)) },
    },
    relay_auth: {
      origin: relayOrigin, nonce: b64u(relayNonce),
      transcript_hex: hex(relayAuthTranscript(relayOrigin, relayNonce)),
      phone: { machine_id: phoneMachine, public_key: b64u(phonePub), role: 'phone', signature: b64u(relayPhoneSig) },
      pc: { machine_id: pcMachine, public_key: b64u(pcPub), role: 'pc', signature: b64u(relayPcSig) },
    },
    handshake: {
      from: phoneMachine, to: pcMachine, sid: sidText, suite: SUITE,
      version: '1',
      phone_eph: { seed_label: labels.phoneEph, public_key: b64u(phoneEphPub) },
      pc_eph: { seed_label: labels.pcEph, public_key: b64u(pcEphPub) },
      phone_nonce: b64u(phoneNonce), pc_nonce: b64u(pcNonce),
      init, resp, confirm, reject,
      transcripts: {
        init_hex: hex(transcriptInit), th1_hex: hex(th1),
        resp_hex: hex(transcriptResp), th2_hex: hex(th2),
        confirm_hex: hex(transcriptConfirm), th3_hex: hex(th3),
        reject_hex: hex(transcriptReject),
      },
      dh_hex: hex(dh),
      keys: {
        phone_to_pc: b64u(phoneToPcKey), pc_to_phone: b64u(pcToPhoneKey),
        confirm_phone: b64u(confirmPhoneKey), confirm_pc: b64u(confirmPcKey),
      },
      confirmations: { pc: b64u(respConfirm), phone: confirm.confirm },
    },
    frames,
    chunking,
    canonical_json: canonical,
    json_boundary: jsonBoundary,
    admin_proof: {
      test_only: true,
      token: b64u(adminToken),
      nonce: b64u(adminNonce),
      proof: b64u(adminProof),
      rule: 'HMAC-SHA256(token, "pclink-v1/admin-proof" || 0x00 || nonce)',
    },
    resources,
    pairing: {
      origin: pairingOrigin,
      qr,
      manual: {
        display: manualDisplay.match(/.{4}/g).join('-'),
        canonical: manualDisplay,
        input: manualInput,
        equivalent_inputs: [
          manualDisplay,
          manualInput,
          manualDisplay.toLowerCase(),
        ],
        normalized: manual.normalized,
        secret_hex: hex(manual.bytes),
        rendezvous: rendezvousOf(manual.bytes, pairingOrigin),
        pair_key: b64u(keyC),
        hello: manualHello,
        auth: manualAuth,
        confirm: manualConfirm,
        final: manualFinal,
        transcript_hash: b64u(transcriptHash),
      },
      secret_s: b64u(secretS),
      rendezvous_s: rendezvousOf(secretS, pairingOrigin),
      rendezvous_s_other_origin: rendezvousOf(secretS, 'https://other.example'),
      pair_key_s: b64u(keyS),
      hello,
      auth,
      confirm: pairConfirm,
      final: pairFinal,
      transcript_hash: b64u(transcriptHash),
      records: { phone: phoneRecord, pc: pcRecord },
      approval: {
        peerName: pairNamePhone,
        peerMachineId: phoneMachine,
        fingerprint,
        pcFingerprint,
        accepted_inputs: fingerprintInputs,
        rejected_input: wrongFingerprint,
        approvedAt,
        approvedVia: 'qr',
        auto_approval: { qr: 'confirm_sent', manual: 'confirm_sent' },
        rule: 'v1.6: the verified pair.auth proves possession of the one-time screen secret and is approved automatically; the fingerprint is display/unpair-target normalization only',
      },
      audit: {
        pair_entry: pairEntry,
        unpair_entry: unpairEntry,
        record_sha256: recordSha256,
        approved_usable: { record: pcRecord, audit: [pairEntry], expected: 'usable' },
      },
    },
    invalid,
  }
}


// ---------------------------------------------------------------------------
// Independent verification
// ---------------------------------------------------------------------------

class CheckError extends Error {}

// The checker owns these constants deliberately: it must not share the
// generator's DOMAIN/SUITE/alphabet/PKCS#8 values.  A typo in either copy makes
// --check fail against the generated golden instead of silently agreeing.
const CHECK_DOMAIN = {
  relayAuth: 'pclink-v1/relay-auth',
  pair: 'pclink-v1/pair',
  pairKey: 'pclink-v1/pair-mac',
  pairHello: 'pclink-v1/pair-hello',
  pairAuth: 'pclink-v1/pair-auth',
  pairConfirm: 'pclink-v1/pair-confirm',
  pairFinal: 'pclink-v1/pair-final',
  sessionInit: 'pclink-v1/session-init',
  sessionResp: 'pclink-v1/session-resp',
  sessionConfirm: 'pclink-v1/session-confirm',
  sessionReject: 'pclink-v1/session-reject',
  keyPhoneToPc: 'pclink-v1/key/phone->pc',
  keyPcToPhone: 'pclink-v1/key/pc->phone',
  keyConfirmPhone: 'pclink-v1/key-confirm/phone->pc',
  keyConfirmPc: 'pclink-v1/key-confirm/pc->phone',
  confirm: 'pclink-v1/confirm',
  aad: 'pclink-v1/aad',
  adminProof: 'pclink-v1/admin-proof',
}
const CHECK_SUITE = 'pclink-x25519-ed25519-chacha20poly1305-1'
const CHECK_CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const CHECK_B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
const CHECK_ED25519_PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex')
const CHECK_X25519_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex')
const CHECK_X25519_SPKI = Buffer.from('302a300506032b656e032100', 'hex')
const CHECK_ED25519_SPKI = Buffer.from('302a300506032b6570032100', 'hex')

function assertCheck(condition, message) {
  if (!condition) throw new CheckError(message)
}

function checkerSha256(bytes) {
  return createHash('sha256').update(bytes).digest()
}
function checkerHex(bytes) {
  return Buffer.from(bytes).toString('hex')
}
function checkerUtf8(text) {
  return Buffer.from(text, 'utf8')
}
function checkerCat(...parts) {
  return Buffer.concat(parts.map(part => Buffer.isBuffer(part) ? part : Buffer.from(part)))
}
function checkerHmac(key, bytes) {
  return createHmac('sha256', key).update(bytes).digest()
}
// RFC 5869 implemented directly: no hkdfSync and no generator helpers.
function checkerHkdf(ikm, salt, info, length = 32) {
  if (!Buffer.isBuffer(ikm) || !Buffer.isBuffer(salt) || typeof info !== 'string') {
    throw new CheckError('bad HKDF input')
  }
  const prk = checkerHmac(salt, ikm)
  const infoBytes = checkerUtf8(info)
  let block = Buffer.alloc(0)
  let okm = Buffer.alloc(0)
  for (let counter = 1; okm.length < length; counter += 1) {
    if (counter > 255) throw new CheckError('HKDF output too long')
    block = checkerHmac(prk, checkerCat(block, infoBytes, Buffer.from([counter])))
    okm = checkerCat(okm, block)
  }
  return okm.subarray(0, length)
}
const B64URL_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
function checkerB64uEncode(bytes) {
  let out = ''
  for (let index = 0; index < bytes.length; index += 3) {
    const first = bytes[index]
    const second = index + 1 < bytes.length ? bytes[index + 1] : 0
    const third = index + 2 < bytes.length ? bytes[index + 2] : 0
    out += B64URL_ALPHABET[first >> 2]
    out += B64URL_ALPHABET[((first & 3) << 4) | (second >> 4)]
    if (index + 1 < bytes.length) out += B64URL_ALPHABET[((second & 15) << 2) | (third >> 6)]
    if (index + 2 < bytes.length) out += B64URL_ALPHABET[third & 63]
  }
  return out
}
function checkerB64uDecode(text, expectedLength) {
  if (typeof text !== 'string' || !/^[A-Za-z0-9_-]*$/.test(text)) {
    throw new CheckError(`not base64url: ${JSON.stringify(text)}`)
  }
  if (text.length % 4 === 1) throw new CheckError('impossible base64url length')
  const bytes = []
  let bits = 0
  let value = 0
  for (const char of text) {
    const digit = B64URL_ALPHABET.indexOf(char)
    if (digit < 0) throw new CheckError('invalid base64url character')
    value = (value << 6) | digit
    bits += 6
    if (bits >= 8) {
      bits -= 8
      bytes.push((value >> bits) & 0xff)
    }
  }
  if (bits > 0 && (value & ((1 << bits) - 1)) !== 0) {
    throw new CheckError('non-canonical base64url trailing bits')
  }
  const result = Buffer.from(bytes)
  if (checkerB64uEncode(result) !== text) throw new CheckError('non-canonical base64url text')
  if (expectedLength !== undefined && result.length !== expectedLength) {
    throw new CheckError(`base64url length ${result.length}, expected ${expectedLength}`)
  }
  return result
}
function checkerBase32Lower(bytes) {
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      out += CHECK_B32[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }
  if (bits > 0) out += CHECK_B32[(value << (5 - bits)) & 31]
  return out.toLowerCase()
}
function checkerMachineId(rawPublicKey) {
  if (!Buffer.isBuffer(rawPublicKey) || rawPublicKey.length !== 32) {
    throw new CheckError('machineId input is not 32 bytes')
  }
  return checkerBase32Lower(checkerSha256(rawPublicKey)).slice(0, 26)
}
function checkerCompareCodePoints(left, right) {
  const a = Array.from(left, char => char.codePointAt(0))
  const b = Array.from(right, char => char.codePointAt(0))
  const count = Math.min(a.length, b.length)
  for (let index = 0; index < count; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index]
  }
  return a.length - b.length
}
function checkerQuoteString(text) {
  let out = '"'
  for (const char of text) {
    const code = char.codePointAt(0)
    if (code >= 0xd800 && code <= 0xdfff) throw new CheckError('lone surrogate')
    if (char === '"') out += '\\"'
    else if (char === '\\') out += '\\\\'
    else if (code === 0x08) out += '\\b'
    else if (code === 0x09) out += '\\t'
    else if (code === 0x0a) out += '\\n'
    else if (code === 0x0c) out += '\\f'
    else if (code === 0x0d) out += '\\r'
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, '0')}`
    else out += char
  }
  return `${out}"`
}
function checkerCanonicalJson(value) {
  if (value === null) return 'null'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new CheckError('non-finite number')
    return JSON.stringify(value)
  }
  if (typeof value === 'string') return checkerQuoteString(value)
  if (Array.isArray(value)) return `[${value.map(checkerCanonicalJson).join(',')}]`
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort(checkerCompareCodePoints)
    return `{${keys.map(key => `${checkerQuoteString(key)}:${checkerCanonicalJson(value[key])}`).join(',')}}`
  }
  throw new CheckError(`cannot canonicalise ${typeof value}`)
}
// Independent strict JSON reader for the §2.3 wire boundary.  It is
// deliberately not JSON.parse: duplicate members and lone surrogates have to
// be detectable, and a legal escaped \u0000 must be allowed (while a literal
// 0x00 byte is not).
function checkerParseWireJson(text, requireObject = true) {
  if (typeof text !== 'string') throw new CheckError('wire JSON is not text')
  if (text.length === 0) throw new CheckError('empty wire JSON')
  if (text.charCodeAt(0) === 0xfeff) throw new CheckError('BOM is not allowed')
  if (text.includes('\u0000')) throw new CheckError('literal NUL is not allowed')

  let index = 0
  const length = text.length
  const fail = message => { throw new CheckError(`${message} at offset ${index}`) }
  const skipWhitespace = () => {
    while (index < length) {
      const code = text.charCodeAt(index)
      if (code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d) index += 1
      else break
    }
  }
  const parseString = () => {
    if (text.charCodeAt(index) !== 0x22) fail('expected string')
    index += 1
    let out = ''
    while (index < length) {
      const code = text.charCodeAt(index)
      if (code === 0x22) {
        index += 1
        return out
      }
      if (code === 0x5c) {
        index += 1
        if (index >= length) fail('unterminated escape')
        const escape = text.charCodeAt(index)
        index += 1
        switch (escape) {
          case 0x22: out += '"'; break
          case 0x5c: out += '\\'; break
          case 0x2f: out += '/'; break
          case 0x62: out += '\b'; break
          case 0x66: out += '\f'; break
          case 0x6e: out += '\n'; break
          case 0x72: out += '\r'; break
          case 0x74: out += '\t'; break
          case 0x75: {
            if (index + 4 > length) fail('short unicode escape')
            const hexText = text.slice(index, index + 4)
            if (!/^[0-9A-Fa-f]{4}$/.test(hexText)) fail('bad unicode escape')
            const unit = Number.parseInt(hexText, 16)
            index += 4
            if (unit >= 0xd800 && unit <= 0xdbff) {
              if (index + 6 > length || text.charCodeAt(index) !== 0x5c || text.charCodeAt(index + 1) !== 0x75) {
                fail('unpaired high surrogate')
              }
              const lowText = text.slice(index + 2, index + 6)
              if (!/^[0-9A-Fa-f]{4}$/.test(lowText)) fail('bad low surrogate escape')
              const low = Number.parseInt(lowText, 16)
              if (low < 0xdc00 || low > 0xdfff) fail('unpaired high surrogate')
              index += 6
              out += String.fromCodePoint(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00))
            } else if (unit >= 0xdc00 && unit <= 0xdfff) {
              fail('unpaired low surrogate')
            } else {
              out += String.fromCharCode(unit)
            }
            break
          }
          default:
            fail('unknown escape')
        }
        continue
      }
      if (code < 0x20) fail('raw control character in string')
      if (code >= 0xd800 && code <= 0xdbff) {
        if (index + 1 >= length) fail('unpaired high surrogate')
        const low = text.charCodeAt(index + 1)
        if (low < 0xdc00 || low > 0xdfff) fail('unpaired high surrogate')
        out += text.slice(index, index + 2)
        index += 2
        continue
      }
      if (code >= 0xdc00 && code <= 0xdfff) fail('unpaired low surrogate')
      out += text[index]
      index += 1
    }
    fail('unterminated string')
  }
  const parseNumber = () => {
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(index))
    if (match === null) fail('bad number')
    index += match[0].length
    const value = Number(match[0])
    if (!Number.isFinite(value)) fail('number is not finite')
    return value
  }
  const parseArray = depth => {
    index += 1
    const result = []
    skipWhitespace()
    if (text.charCodeAt(index) === 0x5d) {
      index += 1
      return result
    }
    for (;;) {
      result.push(parseValue(depth + 1))
      skipWhitespace()
      const separator = text.charCodeAt(index)
      if (separator === 0x5d) {
        index += 1
        return result
      }
      if (separator !== 0x2c) fail('expected , or ]')
      index += 1
    }
  }
  const parseObject = depth => {
    index += 1
    const result = Object.create(null)
    const names = new Set()
    skipWhitespace()
    if (text.charCodeAt(index) === 0x7d) {
      index += 1
      return result
    }
    for (;;) {
      skipWhitespace()
      if (text.charCodeAt(index) !== 0x22) fail('expected member name')
      const name = parseString()
      if (names.has(name)) fail(`duplicate member ${JSON.stringify(name)}`)
      names.add(name)
      skipWhitespace()
      if (text.charCodeAt(index) !== 0x3a) fail('expected :')
      index += 1
      result[name] = parseValue(depth + 1)
      skipWhitespace()
      const separator = text.charCodeAt(index)
      if (separator === 0x7d) {
        index += 1
        return result
      }
      if (separator !== 0x2c) fail('expected , or }')
      index += 1
    }
  }
  const parseValue = depth => {
    if (depth > 256) fail('nesting too deep')
    skipWhitespace()
    if (index >= length) fail('unexpected end')
    const character = text[index]
    if (character === '{') return parseObject(depth)
    if (character === '[') return parseArray(depth)
    if (character === '"') return parseString()
    if (text.startsWith('true', index)) {
      index += 4
      return true
    }
    if (text.startsWith('false', index)) {
      index += 5
      return false
    }
    if (text.startsWith('null', index)) {
      index += 4
      return null
    }
    if (character === '-' || (character >= '0' && character <= '9')) return parseNumber()
    fail('unexpected token')
  }

  const value = parseValue(0)
  skipWhitespace()
  if (index !== length) fail('trailing bytes')
  if (requireObject && (value === null || typeof value !== 'object' || Array.isArray(value))) {
    throw new CheckError('root must be a JSON object')
  }
  return value
}
function checkerWirePath(value, path) {
  let current = value
  for (const key of path) {
    if (Array.isArray(current) && Number.isInteger(key)) {
      current = current[key]
    } else if (current !== null && typeof current === 'object'
      && Object.prototype.hasOwnProperty.call(current, key)) {
      current = current[key]
    } else {
      throw new CheckError(`wire path ${JSON.stringify(path)} is missing`)
    }
  }
  return current
}
function checkerRequireNul(value, path) {
  const target = checkerWirePath(value, path)
  if (typeof target !== 'string' || !target.includes('\u0000')) {
    throw new CheckError(`decoded U+0000 was not preserved at ${JSON.stringify(path)}`)
  }
}
function checkerPclinkOwnField(rule, value) {
  if (rule === 'name') return checkerName(value)
  if (rule === 'machineId') {
    if (typeof value !== 'string' || !/^[a-z2-7]{26}$/.test(value)) throw new CheckError('bad machineId')
    return value
  }
  throw new CheckError(`unknown PCLink field rule ${rule}`)
}
function checkJsonBoundary(row) {
  const text = row.wire_hex === undefined
    ? row.wire
    : Buffer.from(row.wire_hex, 'hex').toString('utf8')
  if (row.expected === 'accept') {
    const value = checkerParseWireJson(text, true)
    if (!DSH_PASSTHROUGH_FIELDS.has(row.passthrough)) {
      throw new CheckError(`${row.case}: unknown DSH passthrough ${JSON.stringify(row.passthrough)}`)
    }
    for (const path of row.nul_paths ?? []) checkerRequireNul(value, path)
    for (const path of row.chunk_data_nul_paths ?? []) {
      if (typeof value.data !== 'string') throw new CheckError(`${row.case}: chunk data is not a string`)
      const decodedText = checkerB64uDecode(value.data).toString('utf8')
      const decoded = checkerParseWireJson(decodedText, false)
      checkerRequireNul(decoded, path)
    }
    return
  }
  if (row.expected !== 'bad_frame') throw new CheckError(`${row.case}: unknown expected verdict`)
  if (row.failure === 'field') {
    const value = checkerParseWireJson(text, true)
    const target = checkerWirePath(value, row.field_path)
    try {
      checkerPclinkOwnField(row.field_rule, target)
    } catch {
      return
    }
    throw new CheckError(`${row.case}: PCLink-owned field accepted U+0000`)
  }
  try {
    checkerParseWireJson(text, true)
  } catch {
    return
  }
  throw new CheckError(`${row.case}: wire JSON accepted`)
}

function checkerCrockfordDecode(input) {
  if (typeof input !== 'string') throw new CheckError('manual code is not a string')
  const normalized = input.toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
  if (!new RegExp(`^[${CHECK_CROCKFORD}]{16}$`).test(normalized)) {
    throw new CheckError(`invalid manual code: ${JSON.stringify(input)}`)
  }
  let value = 0n
  for (const char of normalized) value = (value << 5n) | BigInt(CHECK_CROCKFORD.indexOf(char))
  const bytes = Buffer.alloc(10)
  for (let index = 9; index >= 0; index -= 1) {
    bytes[index] = Number(value & 0xffn)
    value >>= 8n
  }
  return { normalized, display: normalized.match(/.{4}/g).join('-'), bytes }
}
function checkerCrockfordEncode(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length !== 10) throw new CheckError('Crockford needs 10 bytes')
  let value = 0n
  for (const byte of bytes) value = (value << 8n) | BigInt(byte)
  let out = ''
  for (let index = 15; index >= 0; index -= 1) {
    out += CHECK_CROCKFORD[Number((value >> BigInt(index * 5)) & 31n)]
  }
  return out
}
function checkerNormalizeOrigin(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 128) {
    throw new CheckError('bad origin length')
  }
  if (value !== value.toLowerCase()) throw new CheckError('origin is not lowercase')
  const url = new URL(value)
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new CheckError('bad origin scheme')
  if (url.username || url.password || url.search || url.hash) throw new CheckError('origin has userinfo/query/fragment')
  if (url.pathname !== '/' && url.pathname !== '') throw new CheckError('origin has a path')
  if (url.origin !== value) throw new CheckError('origin is not canonical')
  return url.origin
}
function checkerWsUrl(origin) {
  return checkerNormalizeOrigin(origin).replace(/^https:/, 'wss:').replace(/^http:/, 'ws:') + '/'
}
function checkerEdPublic(raw) {
  if (!Buffer.isBuffer(raw) || raw.length !== 32) throw new CheckError('bad Ed25519 public key')
  return createPublicKey({ key: checkerCat(CHECK_ED25519_SPKI, raw), format: 'der', type: 'spki' })
}
function checkerEdPrivateFromLabel(label) {
  return createPrivateKey({ key: checkerCat(CHECK_ED25519_PKCS8, checkerSha256(checkerUtf8(label))), format: 'der', type: 'pkcs8' })
}
function checkerXPrivateFromLabel(label) {
  return createPrivateKey({ key: checkerCat(CHECK_X25519_PKCS8, checkerSha256(checkerUtf8(label))), format: 'der', type: 'pkcs8' })
}
function checkerXPublic(raw) {
  if (!Buffer.isBuffer(raw) || raw.length !== 32) throw new CheckError('bad X25519 public key')
  return createPublicKey({ key: checkerCat(CHECK_X25519_SPKI, raw), format: 'der', type: 'spki' })
}
function checkerRawPublic(priv) {
  return createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32)
}
function checkerVerify(transcript, publicKey, signature) {
  return verify(null, transcript, checkerEdPublic(publicKey), signature)
}
function checkerDh(privateKey, publicRaw) {
  const dh = diffieHellman({ privateKey, publicKey: checkerXPublic(publicRaw) })
  if (dh.equals(ZERO32)) throw new CheckError('all-zero X25519 result')
  return dh
}
function checkerRelayTranscript(origin, nonce) {
  return checkerCat(checkerUtf8(CHECK_DOMAIN.relayAuth), ZERO, checkerUtf8(origin), ZERO, nonce)
}
function checkerAad(sidText, seq, from, to, outerType = 'e2e', version = '1') {
  return checkerCat(
    checkerUtf8(CHECK_DOMAIN.aad), ZERO,
    checkerUtf8(version), ZERO,
    checkerUtf8(outerType), ZERO,
    checkerUtf8(sidText), ZERO,
    checkerUtf8(String(seq)), ZERO,
    checkerUtf8(from), ZERO,
    checkerUtf8(to),
  )
}
function checkerNonce(seq) {
  if (!Number.isSafeInteger(seq) || seq < 0) throw new CheckError('bad seq')
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64BE(BigInt(seq), 4)
  return nonce
}
function checkerOpen(key, seq, aad, body) {
  if (body.length < 16) throw new CheckError('short AEAD body')
  const decipher = createDecipheriv('chacha20-poly1305', key, checkerNonce(seq), { authTagLength: 16 })
  decipher.setAAD(aad)
  decipher.setAuthTag(body.subarray(-16))
  try {
    return checkerCat(decipher.update(body.subarray(0, -16)), decipher.final())
  } catch {
    throw new CheckError('auth_failed')
  }
}
function checkerSplitChunks(bytes, chunkBytes) {
  if (!Number.isInteger(chunkBytes) || chunkBytes <= 0) throw new CheckError('bad chunk size')
  const chunks = []
  for (let offset = 0, part = 0; offset < bytes.length; offset += chunkBytes, part += 1) {
    const end = Math.min(offset + chunkBytes, bytes.length)
    chunks.push({ part, last: end === bytes.length, data: checkerB64uEncode(bytes.subarray(offset, end)) })
  }
  return chunks
}
function checkerJoinChunks(chunks) {
  if (!Array.isArray(chunks) || chunks.length === 0) throw new CheckError('no chunks')
  const parts = []
  for (let index = 0; index < chunks.length; index += 1) {
    const chunk = chunks[index]
    if (chunk.part !== index) throw new CheckError('chunk part order')
    if (index < chunks.length - 1 && chunk.last !== false) throw new CheckError('premature last')
    if (index === chunks.length - 1 && chunk.last !== true) throw new CheckError('missing last')
    parts.push(checkerB64uDecode(chunk.data))
  }
  return checkerCat(...parts)
}
function checkerReassemble(events) {
  if (!Array.isArray(events) || events.length === 0) throw new CheckError('no events')
  const streams = new Map()
  for (const event of events) {
    if (typeof event.streamId !== 'string' || event.streamId.length === 0) throw new CheckError('missing streamId')
    if (!Number.isInteger(event.part) || event.part < 0) throw new CheckError('bad part')
    if (typeof event.last !== 'boolean') throw new CheckError('bad last')
    let state = streams.get(event.streamId)
    if (!state) {
      state = { parts: [], last: false }
      streams.set(event.streamId, state)
    }
    if (state.last) throw new CheckError('chunk after last')
    if (event.part !== state.parts.length) throw new CheckError('out-of-order/duplicate/missing part')
    state.parts.push(checkerB64uDecode(event.data))
    if (event.last) state.last = true
  }
  const result = new Map()
  for (const [streamId, state] of streams) {
    if (!state.last) throw new CheckError('stream without last chunk')
    result.set(streamId, checkerCat(...state.parts))
  }
  return result
}
function checkerPairKey(secret) {
  return checkerHkdf(secret, ZERO32, CHECK_DOMAIN.pairKey, 32)
}
function checkerRendezvous(secret, origin) {
  const normalized = checkerNormalizeOrigin(origin)
  return checkerB64uEncode(checkerSha256(checkerCat(
    checkerUtf8(CHECK_DOMAIN.pair), ZERO, checkerUtf8(normalized), ZERO, secret,
  ))).slice(0, 22)
}
function checkerPairMac(key, domain, objectWithoutMac) {
  return checkerHmac(key, checkerCat(checkerUtf8(domain), ZERO, checkerUtf8(checkerCanonicalJson(objectWithoutMac))))
}
function checkerInitTranscript(init, from, to) {
  const sid = checkerB64uDecode(init.sid, 16)
  const eph = checkerB64uDecode(init.eph, 32)
  const nonce = checkerB64uDecode(init.nonce, 32)
  return checkerSha256(checkerCat(
    checkerUtf8(CHECK_DOMAIN.sessionInit), ZERO,
    checkerUtf8(String(init.v)), ZERO,
    checkerUtf8(init.suite), ZERO,
    checkerUtf8(from), ZERO,
    checkerUtf8(to), ZERO,
    sid, ZERO, eph, ZERO, nonce,
  ))
}
function checkerRespTranscript(th1, eph, nonce) {
  return checkerCat(checkerUtf8(CHECK_DOMAIN.sessionResp), ZERO, th1, ZERO, eph, ZERO, nonce)
}
function checkerConfirmTranscript(th2, sid, from, to) {
  return checkerCat(
    checkerUtf8(CHECK_DOMAIN.sessionConfirm), ZERO,
    th2, ZERO,
    checkerUtf8(from), ZERO,
    checkerUtf8(to), ZERO,
    sid,
  )
}
function checkerRejectTranscript(th1, code) {
  return checkerCat(checkerUtf8(CHECK_DOMAIN.sessionReject), ZERO, th1, ZERO, checkerUtf8(code))
}
function checkerName(name) {
  if (typeof name !== 'string') throw new CheckError('name is not a string')
  const length = Buffer.byteLength(name, 'utf8')
  if (length < 1 || length > 64) throw new CheckError('name byte length')
  if (name.normalize('NFC') !== name) throw new CheckError('name is not NFC')
  for (const char of name) {
    const code = char.codePointAt(0)
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f) || /\p{Cf}/u.test(char)) {
      throw new CheckError('name control/format character')
    }
  }
  return name
}
function checkerQrParse(uri) {
  if (typeof uri !== 'string') throw new CheckError('qr is not a string')
  if (Buffer.byteLength(uri, 'utf8') < 1 || Buffer.byteLength(uri, 'utf8') > 512) throw new CheckError('qr length')
  if (!uri.startsWith('pclink://pair?')) throw new CheckError('qr scheme')
  if (uri.includes('#')) throw new CheckError('qr fragment')
  const query = uri.slice('pclink://pair?'.length)
  if (query.includes('+')) throw new CheckError('qr raw +')
  const allowed = new Set(['v', 'r', 'm', 'k', 's', 'n'])
  const values = {}
  for (const part of query.split('&')) {
    if (part === '') throw new CheckError('qr empty part')
    const index = part.indexOf('=')
    if (index < 0) throw new CheckError('qr part without =')
    const key = part.slice(0, index)
    if (!allowed.has(key)) throw new CheckError(`qr unknown parameter ${key}`)
    if (key in values) throw new CheckError(`qr duplicate parameter ${key}`)
    let value
    try {
      value = decodeURIComponent(part.slice(index + 1))
    } catch {
      throw new CheckError('qr percent encoding')
    }
    values[key] = value
  }
  for (const key of allowed) if (!(key in values)) throw new CheckError(`qr missing ${key}`)
  if (values.v !== '1') throw new CheckError('qr version')
  const origin = checkerNormalizeOrigin(values.r)
  const machineId = values.m
  if (!/^[a-z2-7]{26}$/.test(machineId)) throw new CheckError('qr machineId')
  const publicKey = checkerB64uDecode(values.k, 32)
  const secret = checkerB64uDecode(values.s, 16)
  const name = checkerName(values.n)
  return { v: 1, origin, machineId, publicKey, secret, name }
}
function checkerLoadRecord(record, audit) {
  const entries = audit.filter(entry => entry.peerMachineId === record.peerMachineId)
  if (entries.length === 0) return 'unapproved'
  const latest = entries[entries.length - 1]
  if (latest.event === 'unpair') return 'revoked'
  if (latest.event !== 'pair') return 'unapproved'
  if (latest.peerPublicKey !== record.peerPublicKey) return 'unapproved'
  if (latest.recordSha256 !== checkerHex(checkerSha256(checkerUtf8(checkerCanonicalJson(record))))) return 'unapproved'
  if (typeof record.approvedAt !== 'string' || !['qr', 'manual', 'cli', 'webui'].includes(record.approvedVia)) return 'unapproved'
  return 'usable'
}
function checkerApplyReject(row) {
  if (!row.has_record) return 'no_record'
  if (!row.verified || !row.th1_matches) return 'keep_record'
  if (row.code !== 'unpaired') return 'keep_record'
  return 'prompt'
}
function checkerApproval(row) {
  if (row.mode !== 'qr' && row.mode !== 'manual') return 'bad_frame'
  return row.approved === true ? 'confirm_sent' : 'blocked'
}
function checkerSlot(row) {
  if (row.matched) return 'exhausted'
  if (row.now_ms - row.opened_ms > row.ttl_ms) return 'expired'
  if (row.joins > row.limit) return 'exhausted'
  return 'open'
}
function checkerSeq(row) {
  if (!Number.isSafeInteger(row.seq) || row.seq < 0) return 'bad_frame'
  if (row.seq >= SEQ_MAX) return 'session_expired'
  if (Number.isSafeInteger(row.bytes) && row.bytes > BYTE_HARD) return 'session_expired'
  if (row.first) return row.seq === 0 ? 'ok' : 'bad_frame'
  if (!Number.isSafeInteger(row.last_seq) || row.seq <= row.last_seq) return 'replay'
  if (row.seq !== row.last_seq + 1) return 'bad_frame'
  return 'ok'
}
function checkerFirstFrame(type) {
  return type === 'peer.hello' || type === 'session.close' ? 'ok' : 'bad_frame'
}
function checkerDirection(sender, bodyType) {
  const okay = (sender === 'phone' && (bodyType === 'session.init' || bodyType === 'session.confirm'))
    || (sender === 'pc' && (bodyType === 'session.resp' || bodyType === 'session.reject'))
  return okay ? 'ok' : 'bad_frame'
}
function checkerOriginMatch(actual, expected) {
  try {
    if (checkerNormalizeOrigin(actual) !== checkerNormalizeOrigin(expected)) return 'auth_failed'
  } catch {
    return 'auth_failed'
  }
  return 'ok'
}
function checkerSize(bytes, limit) {
  return Number.isSafeInteger(bytes) && bytes > limit ? 'frame_too_large' : 'ok'
}
function checkerSuite(suite) {
  return suite === CHECK_SUITE ? 'ok' : 'version_unsupported'
}
function checkerCaps(caps, required) {
  if (!Array.isArray(caps)) return 'version_unsupported'
  return required.every(cap => caps.includes(cap)) ? 'ok' : 'version_unsupported'
}
function checkerOuterFrame(frame) {
  if (!frame || typeof frame !== 'object') return 'bad_frame'
  if (frame.v !== 1 || frame.type !== 'e2e') return 'bad_frame'
  if (typeof frame.sid !== 'string' || !/^[A-Za-z0-9_-]{22}$/.test(frame.sid)) return 'bad_frame'
  if (!Number.isSafeInteger(frame.seq) || frame.seq < 0) return 'bad_frame'
  if (typeof frame.from !== 'string' || !/^[a-z2-7]{26}$/.test(frame.from)) return 'bad_frame'
  if (typeof frame.to !== 'string' || !/^[a-z2-7]{26}$/.test(frame.to)) return 'bad_frame'
  if (typeof frame.body !== 'string' || frame.body.length === 0) return 'bad_frame'
  return 'ok'
}
function checkerUnknownCode(code) {
  return PCLINK_CODES.has(code) ? 'ok' : 'bad_frame'
}
function checkerFingerprint(machineId) {
  return `${machineId.slice(0, 4)}-${machineId.slice(4, 8)}-${machineId.slice(8, 12)}`
}
function checkerNormalizeFingerprint(input) {
  if (typeof input !== 'string') throw new CheckError('fingerprint is not a string')
  const normalized = input.toLowerCase().replace(/[\s-]/g, '')
  if (!/^[a-z2-7]{12}$/.test(normalized)) throw new CheckError('fingerprint is not 12 base32 characters')
  return `${normalized.slice(0, 4)}-${normalized.slice(4, 8)}-${normalized.slice(8, 12)}`
}
function checkerFingerprintMatch(machineId, entered) {
  try {
    return checkerNormalizeFingerprint(entered) === checkerFingerprint(machineId) ? 'match' : 'blocked'
  } catch {
    return 'bad_frame'
  }
}
function checkerForbiddenEndpoint(endpoint) {
  return endpoint.startsWith('pclink.admin/') ? 'forbidden' : 'forward'
}
function checkerAdminPeer(source) {
  // The source Peer, not the endpoint string, decides.  An endpoint casing
  // variant must not bypass the handler gate.
  return source === 'pclink_remote' ? 'forbidden' : 'allow'
}
function checkerConfirmRecheck(record, audit) {
  return checkerLoadRecord(record, audit) === 'usable' ? 'establish' : 'abort'
}
function checkerUnpairAbort(handshakeInProgress, unpair) {
  return handshakeInProgress && unpair ? 'abort' : 'noop'
}
function checkerIdle(idleMs, limitMs) {
  return idleMs > limitMs ? 'session_expired' : 'ok'
}
function checkerSlots(open, limit) {
  return open > limit ? 'exhausted' : 'accept'
}
function checkerIpv6Bucket(address) {
  if (typeof address !== 'string' || !address.includes(':')) throw new CheckError('not an IPv6 address')
  const halves = address.split('::')
  const left = halves[0] ? halves[0].split(':') : []
  const right = halves.length > 1 && halves[1] ? halves[1].split(':') : []
  const missing = 8 - left.length - right.length
  const groups = [...left, ...Array(Math.max(0, missing)).fill('0'), ...right]
  if (groups.length !== 8) throw new CheckError('bad IPv6 address')
  return `${groups.slice(0, 4).join(':')}::/64`
}
function checkerSidCache(entries, limit) {
  return entries > limit ? 'evict_lru' : 'accept'
}

function checkVectors(doc) {
  const counts = {
    sections: 0, frames: 0, invalid: 0, crypto: 0, model: 0,
    jsonAccepted: 0, jsonRejected: 0,
  }
  assertCheck(doc && doc.format === 'pclink-v1-vectors', 'format')
  assertCheck(doc.format_version === 3, 'format_version')
  assertCheck(doc.revision === REVISION, 'revision')
  assertCheck(doc.suite === CHECK_SUITE, 'suite')

  // Identities.
  for (const side of ['phone', 'pc']) {
    const entry = doc.identities[side]
    const priv = checkerEdPrivateFromLabel(entry.seed_label)
    const pub = checkerRawPublic(priv)
    assertCheck(checkerB64uEncode(pub) === entry.public_key, `${side}: public key`)
    assertCheck(checkerHex(checkerSha256(pub)) === entry.sha256_hex, `${side}: sha256`)
    assertCheck(checkerMachineId(pub) === entry.machine_id, `${side}: machineId`)
    counts.sections += 1
  }

  // Relay auth.
  const relay = doc.relay_auth
  const relayOrigin = checkerNormalizeOrigin(relay.origin)
  const relayNonce = checkerB64uDecode(relay.nonce, 32)
  assertCheck(checkerHex(checkerRelayTranscript(relayOrigin, relayNonce)) === relay.transcript_hex, 'relay: transcript')
  for (const side of ['phone', 'pc']) {
    const entry = relay[side]
    assertCheck(entry.public_key === doc.identities[side].public_key, `relay ${side}: public key`)
    assertCheck(entry.machine_id === doc.identities[side].machine_id, `relay ${side}: machineId`)
    assertCheck(checkerMachineId(checkerB64uDecode(entry.public_key, 32)) === entry.machine_id, `relay ${side}: derived machineId`)
    assertCheck(checkerVerify(checkerRelayTranscript(relayOrigin, relayNonce), checkerB64uDecode(entry.public_key, 32), checkerB64uDecode(entry.signature, 64)), `relay ${side}: signature`)
    counts.sections += 1
  }

  // Handshake.
  const hs = doc.handshake
  assertCheck(hs.suite === CHECK_SUITE, 'handshake: suite')
  assertCheck(hs.version === '1', 'handshake: version')
  assertCheck(hs.from === doc.identities.phone.machine_id, 'handshake: from')
  assertCheck(hs.to === doc.identities.pc.machine_id, 'handshake: to')
  const sid = checkerB64uDecode(hs.sid, 16)
  const initEph = checkerB64uDecode(hs.init.eph, 32)
  const initNonce = checkerB64uDecode(hs.init.nonce, 32)
  assertCheck(hs.init.v === 1 && hs.init.type === 'session.init', 'handshake: init shape')
  assertCheck(hs.init.sid === hs.sid && hs.init.suite === hs.suite, 'handshake: init sid/suite')
  const transcriptInit = checkerCat(
    checkerUtf8(CHECK_DOMAIN.sessionInit), ZERO,
    checkerUtf8('1'), ZERO,
    checkerUtf8(hs.suite), ZERO,
    checkerUtf8(hs.from), ZERO,
    checkerUtf8(hs.to), ZERO,
    sid, ZERO,
    initEph, ZERO,
    initNonce,
  )
  assertCheck(checkerHex(checkerInitTranscript(hs.init, hs.from, hs.to)) === hs.transcripts.th1_hex, 'handshake: independent th1')
  assertCheck(checkerHex(transcriptInit) === hs.transcripts.init_hex, 'handshake: init transcript')
  const th1 = checkerSha256(transcriptInit)
  assertCheck(checkerHex(th1) === hs.transcripts.th1_hex, 'handshake: th1')
  const respEph = checkerB64uDecode(hs.resp.eph, 32)
  const respNonce = checkerB64uDecode(hs.resp.nonce, 32)
  const transcriptResp = checkerRespTranscript(th1, respEph, respNonce)
  assertCheck(checkerHex(transcriptResp) === hs.transcripts.resp_hex, 'handshake: resp transcript')
  const th2 = checkerSha256(transcriptResp)
  assertCheck(checkerHex(th2) === hs.transcripts.th2_hex, 'handshake: th2')
  const phoneEphPriv = checkerXPrivateFromLabel(hs.phone_eph.seed_label)
  const pcEphPriv = checkerXPrivateFromLabel(hs.pc_eph.seed_label)
  assertCheck(checkerB64uEncode(checkerRawPublic(phoneEphPriv)) === hs.phone_eph.public_key, 'handshake: phone eph public')
  assertCheck(checkerB64uEncode(checkerRawPublic(pcEphPriv)) === hs.pc_eph.public_key, 'handshake: pc eph public')
  const dh1 = checkerDh(phoneEphPriv, respEph)
  const dh2 = checkerDh(pcEphPriv, initEph)
  assertCheck(dh1.equals(dh2), 'handshake: DH disagreement')
  assertCheck(checkerHex(dh1) === hs.dh_hex, 'handshake: DH vector')
  const phoneToPc = checkerHkdf(dh1, th2, CHECK_DOMAIN.keyPhoneToPc, 32)
  const pcToPhone = checkerHkdf(dh1, th2, CHECK_DOMAIN.keyPcToPhone, 32)
  const confirmPhoneKey = checkerHkdf(dh1, th2, CHECK_DOMAIN.keyConfirmPhone, 32)
  const confirmPcKey = checkerHkdf(dh1, th2, CHECK_DOMAIN.keyConfirmPc, 32)
  assertCheck(checkerB64uEncode(phoneToPc) === hs.keys.phone_to_pc, 'handshake: phone->pc key')
  assertCheck(checkerB64uEncode(pcToPhone) === hs.keys.pc_to_phone, 'handshake: pc->phone key')
  assertCheck(checkerB64uEncode(confirmPhoneKey) === hs.keys.confirm_phone, 'handshake: confirm phone key')
  assertCheck(checkerB64uEncode(confirmPcKey) === hs.keys.confirm_pc, 'handshake: confirm pc key')
  const pcPub = checkerB64uDecode(doc.identities.pc.public_key, 32)
  const phonePub = checkerB64uDecode(doc.identities.phone.public_key, 32)
  assertCheck(checkerVerify(transcriptResp, pcPub, checkerB64uDecode(hs.resp.sig, 64)), 'handshake: PC signature')
  const pcConfirm = checkerHmac(confirmPcKey, checkerCat(checkerUtf8(CHECK_DOMAIN.confirm), ZERO, th2))
  assertCheck(pcConfirm.equals(checkerB64uDecode(hs.resp.confirm, 32)), 'handshake: PC key confirmation')
  assertCheck(hs.confirmations.pc === hs.resp.confirm, 'handshake: confirmation vector pc')
  const transcriptConfirm = checkerConfirmTranscript(th2, sid, hs.from, hs.to)
  assertCheck(checkerHex(transcriptConfirm) === hs.transcripts.confirm_hex, 'handshake: confirm transcript')
  const th3 = checkerSha256(transcriptConfirm)
  assertCheck(checkerHex(th3) === hs.transcripts.th3_hex, 'handshake: th3')
  assertCheck(checkerVerify(transcriptConfirm, phonePub, checkerB64uDecode(hs.confirm.sig, 64)), 'handshake: phone signature')
  const phoneConfirm = checkerHmac(confirmPhoneKey, checkerCat(checkerUtf8(CHECK_DOMAIN.confirm), ZERO, th3))
  assertCheck(phoneConfirm.equals(checkerB64uDecode(hs.confirm.confirm, 32)), 'handshake: phone key confirmation')
  assertCheck(hs.confirmations.phone === hs.confirm.confirm, 'handshake: confirmation vector phone')
  assertCheck(hs.confirm.sid === hs.sid && hs.resp.sid === hs.sid, 'handshake: resp/confirm sid')
  const rejectTranscript = checkerRejectTranscript(th1, hs.reject.code)
  assertCheck(checkerHex(rejectTranscript) === hs.transcripts.reject_hex, 'handshake: reject transcript')
  assertCheck(checkerVerify(rejectTranscript, pcPub, checkerB64uDecode(hs.reject.sig, 64)), 'handshake: reject signature')
  assertCheck(hs.reject.sid === hs.sid && hs.reject.code === 'unpaired', 'handshake: reject shape')
  counts.sections += 1

  // AEAD frames.
  for (const frame of doc.frames) {
    const from = frame.direction === 'phone_to_pc' ? doc.identities.phone.machine_id : doc.identities.pc.machine_id
    const to = frame.direction === 'phone_to_pc' ? doc.identities.pc.machine_id : doc.identities.phone.machine_id
    assertCheck(frame.from === from && frame.to === to, `${frame.case}: direction`)
    const key = frame.direction === 'phone_to_pc' ? phoneToPc : pcToPhone
    const aad = checkerAad(frame.sid, frame.seq, frame.from, frame.to)
    assertCheck(checkerHex(aad) === frame.aad_hex, `${frame.case}: AAD`)
    assertCheck(checkerHex(checkerNonce(frame.seq)) === frame.nonce_hex, `${frame.case}: nonce`)
    const plaintext = checkerOpen(key, frame.seq, aad, checkerB64uDecode(frame.body))
    assertCheck(plaintext.toString('utf8') === frame.plaintext, `${frame.case}: plaintext`)
    const inner = JSON.parse(plaintext.toString('utf8'))
    assertCheck(inner.type === frame.inner_type, `${frame.case}: inner type`)
    counts.frames += 1
  }
  counts.sections += 1

  // Canonical JSON.
  for (const [name, entry] of Object.entries(doc.canonical_json)) {
    const canonical = checkerCanonicalJson(entry.object)
    assertCheck(canonical === entry.canonical, `canonical ${name}: text`)
    assertCheck(checkerHex(checkerSha256(checkerUtf8(canonical))) === entry.sha256_hex, `canonical ${name}: sha256`)
  }
  counts.sections += 1

  // §2.3 JSON wire/carried boundary.
  const boundary = doc.json_boundary
  assertCheck(boundary !== null && typeof boundary === 'object', 'json_boundary: section')
  assertCheck(Array.isArray(boundary.passthrough), 'json_boundary: passthrough list')
  assertCheck(Array.isArray(boundary.accepted) && boundary.accepted.length >= 6, 'json_boundary: accepted rows')
  assertCheck(Array.isArray(boundary.rejected) && boundary.rejected.length >= 8, 'json_boundary: rejected rows')
  const boundaryCases = new Set()
  for (const row of boundary.accepted) {
    checkJsonBoundary(row)
    boundaryCases.add(row.case)
    counts.jsonAccepted += 1
  }
  for (const row of boundary.rejected) {
    checkJsonBoundary(row)
    boundaryCases.add(row.case)
    counts.jsonRejected += 1
  }
  for (const required of [
    'carried-escaped-nul-rpc-args',
    'carried-escaped-nul-stream-open-args',
    'carried-escaped-nul-rpc-result',
    'carried-escaped-nul-stream-item',
    'carried-escaped-nul-stream-chunk',
    'carried-escaped-nul-result-chunk',
    'wire-literal-nul',
    'pclink-name-escaped-nul',
  ]) {
    assertCheck(boundaryCases.has(required), `json_boundary: missing ${required}`)
  }
  counts.sections += 1

  // Admin server proof.
  assertCheck(doc.admin_proof.test_only === true, 'admin proof: test_only')
  const adminToken = checkerB64uDecode(doc.admin_proof.token, 32)
  const adminNonce = checkerB64uDecode(doc.admin_proof.nonce, 32)
  const adminProof = checkerHmac(adminToken, checkerCat(checkerUtf8(CHECK_DOMAIN.adminProof), ZERO, adminNonce))
  assertCheck(adminProof.equals(checkerB64uDecode(doc.admin_proof.proof, 32)), 'admin proof: HMAC')
  counts.sections += 1

  // Resource and lifecycle state machines.
  const resources = doc.resources
  for (const entry of resources.sid_cache.cases) {
    assertCheck(checkerSidCache(entry.entries, resources.sid_cache.limit) === entry.expected, 'resources: sid cache')
  }
  for (const entry of resources.pairing_slots.cases) {
    assertCheck(checkerSlots(entry.open, resources.pairing_slots.limit) === entry.expected, 'resources: pairing slots')
  }
  assertCheck(checkerIpv6Bucket(resources.ipv6.address) === resources.ipv6.expected, 'resources: ipv6 /64')
  assertCheck(checkerIdle(resources.e2e_idle.idle_ms, resources.e2e_idle.limit_ms) === resources.e2e_idle.expected, 'resources: e2e idle')
  assertCheck(checkerConfirmRecheck(resources.confirm_recheck.approved.record, resources.confirm_recheck.approved.audit) === resources.confirm_recheck.approved.expected, 'resources: confirm approved')
  assertCheck(checkerConfirmRecheck(resources.confirm_recheck.revoked.record, resources.confirm_recheck.revoked.audit) === resources.confirm_recheck.revoked.expected, 'resources: confirm revoked')
  assertCheck(checkerUnpairAbort(resources.unpair_abort.handshake_in_progress, resources.unpair_abort.unpair) === resources.unpair_abort.expected, 'resources: unpair abort')
  for (const entry of Object.values(resources.approval)) {
    assertCheck(checkerApproval(entry) === entry.expected, 'resources: approval')
  }
  for (const entry of resources.admin_peer.cases) {
    assertCheck(checkerAdminPeer(entry.source) === entry.expected, `resources: admin peer ${entry.source} ${entry.endpoint}`)
  }
  counts.sections += 1

  // Chunking.
  const chunking = doc.chunking
  assertCheck(chunking.threshold_bytes === THRESHOLD, 'chunking: threshold')
  assertCheck(chunking.max_value_bytes === MAX_VALUE, 'chunking: max value')
  assertCheck(chunking.seq_rekey === SEQ_REKEY && chunking.seq_max === SEQ_MAX, 'chunking: seq constants')
  const smallBytes = checkerUtf8(JSON.stringify(chunking.small.value))
  assertCheck(checkerHex(checkerSha256(checkerJoinChunks(checkerSplitChunks(smallBytes, chunking.small.chunk_bytes)))) === chunking.small.reassembled_sha256, 'chunking: small')
  assertCheck(checkerHex(checkerSha256(checkerJoinChunks(chunking.small.chunks))) === chunking.small.reassembled_sha256, 'chunking: small stored')
  const resultBytes = checkerUtf8(JSON.stringify(chunking.result_chunk.result))
  assertCheck(checkerHex(checkerSha256(checkerJoinChunks(checkerSplitChunks(resultBytes, chunking.result_chunk.chunk_bytes)))) === chunking.result_chunk.reassembled_sha256, 'chunking: result')
  const interleaved = checkerReassemble(chunking.interleave.events)
  for (const [streamId, value] of Object.entries(chunking.interleave.values)) {
    const bytes = checkerUtf8(JSON.stringify(value))
    assertCheck(checkerHex(checkerSha256(bytes)) === chunking.interleave.reassembled_sha256[streamId], `chunking: interleave ${streamId} value`)
    assertCheck(interleaved.get(streamId).equals(bytes), `chunking: interleave ${streamId} bytes`)
  }
  const thresholdBytes = checkerUtf8(JSON.stringify(chunking.threshold.repeat.repeat(chunking.threshold.repeat_count)))
  const thresholdChunks = checkerSplitChunks(thresholdBytes, chunking.threshold.chunk_bytes)
  assertCheck(thresholdChunks.length === chunking.threshold.parts, 'chunking: threshold parts')
  assertCheck(thresholdChunks[thresholdChunks.length - 1].last === chunking.threshold.last_last, 'chunking: threshold last')
  assertCheck(checkerHex(checkerSha256(checkerJoinChunks(thresholdChunks))) === chunking.threshold.reassembled_sha256, 'chunking: threshold')
  counts.sections += 1

  // Pairing.
  const pairing = doc.pairing
  const parsedQr = checkerQrParse(pairing.qr.uri)
  assertCheck(parsedQr.origin === pairing.qr.parsed.origin, 'pairing: qr origin')
  assertCheck(parsedQr.machineId === pairing.qr.parsed.machineId, 'pairing: qr machineId')
  assertCheck(checkerB64uEncode(parsedQr.publicKey) === pairing.qr.parsed.publicKey, 'pairing: qr public key')
  assertCheck(checkerB64uEncode(parsedQr.secret) === pairing.qr.parsed.secret, 'pairing: qr secret')
  assertCheck(parsedQr.name === pairing.qr.parsed.name, 'pairing: qr name')
  assertCheck(checkerWsUrl(parsedQr.origin) === pairing.qr.parsed.ws_url, 'pairing: ws url')
  assertCheck(checkerMachineId(parsedQr.publicKey) === parsedQr.machineId, 'pairing: qr key/machineId')
  assertCheck(parsedQr.machineId === doc.identities.pc.machine_id, 'pairing: qr pc machineId')
  assertCheck(checkerB64uEncode(parsedQr.publicKey) === doc.identities.pc.public_key, 'pairing: qr pc key')
  const secretS = checkerB64uDecode(pairing.secret_s, 16)
  for (const input of pairing.manual.equivalent_inputs) {
    const manual = checkerCrockfordDecode(input)
    assertCheck(manual.normalized === pairing.manual.normalized, 'pairing: manual normalization')
    assertCheck(manual.display === pairing.manual.display, 'pairing: manual display')
    assertCheck(checkerHex(manual.bytes) === pairing.manual.secret_hex, 'pairing: manual bytes')
    assertCheck(checkerCrockfordEncode(manual.bytes) === pairing.manual.canonical, 'pairing: manual canonical')
  }
  assertCheck(checkerRendezvous(secretS, pairing.origin) === pairing.rendezvous_s, 'pairing: S rendezvous')
  assertCheck(checkerRendezvous(secretS, 'https://other.example') === pairing.rendezvous_s_other_origin, 'pairing: rendezvous origin binding')
  assertCheck(pairing.rendezvous_s !== pairing.rendezvous_s_other_origin, 'pairing: rendezvous origin must differ')
  const manualBytes = Buffer.from(pairing.manual.secret_hex, 'hex')
  assertCheck(manualBytes.length === 10, 'pairing: manual secret length')
  assertCheck(checkerRendezvous(manualBytes, pairing.origin) === pairing.manual.rendezvous, 'pairing: C rendezvous')
  const keyS = checkerPairKey(secretS)
  const keyC = checkerPairKey(manualBytes)
  assertCheck(checkerB64uEncode(keyS) === pairing.pair_key_s, 'pairing: S key')
  assertCheck(checkerB64uEncode(keyC) === pairing.manual.pair_key, 'pairing: C key')
  const hello = pairing.hello
  const auth = pairing.auth
  const helloNoMac = { ...hello }
  delete helloNoMac.mac
  const authNoMac = { ...auth }
  delete authNoMac.mac
  assertCheck(checkerPairMac(keyS, CHECK_DOMAIN.pairHello, helloNoMac).equals(checkerB64uDecode(hello.mac, 32)), 'pairing: hello MAC')
  assertCheck(checkerPairMac(keyS, CHECK_DOMAIN.pairAuth, authNoMac).equals(checkerB64uDecode(auth.mac, 32)), 'pairing: auth MAC')
  const trans1 = checkerSha256(checkerUtf8(checkerCanonicalJson(helloNoMac)))
  const trans2 = checkerSha256(checkerUtf8(checkerCanonicalJson(authNoMac)))
  const transcriptHash = checkerSha256(checkerCat(trans1, ZERO, trans2))
  assertCheck(checkerB64uEncode(transcriptHash) === pairing.transcript_hash, 'pairing: transcript hash')
  for (const [name, object, domain] of [
    ['confirm', pairing.confirm, CHECK_DOMAIN.pairConfirm],
    ['final', pairing.final, CHECK_DOMAIN.pairFinal],
  ]) {
    const copy = { ...object }
    delete copy.mac
    assertCheck(checkerPairMac(keyS, domain, copy).equals(checkerB64uDecode(object.mac, 32)), `pairing: ${name} MAC`)
  }
  assertCheck(checkerMachineId(checkerB64uDecode(auth.publicKey, 32)) === auth.machineId, 'pairing: auth machineId')
  assertCheck(checkerMachineId(checkerB64uDecode(hello.publicKey, 32)) === hello.machineId, 'pairing: hello machineId')
  // Complete manual-mode (keyC) positive MAC set.
  for (const [name, object, domain, key] of [
    ['manual hello', pairing.manual.hello, CHECK_DOMAIN.pairHello, keyC],
    ['manual auth', pairing.manual.auth, CHECK_DOMAIN.pairAuth, keyC],
    ['manual confirm', pairing.manual.confirm, CHECK_DOMAIN.pairConfirm, keyC],
    ['manual final', pairing.manual.final, CHECK_DOMAIN.pairFinal, keyC],
  ]) {
    const copy = { ...object }
    delete copy.mac
    assertCheck(checkerPairMac(key, domain, copy).equals(checkerB64uDecode(object.mac, 32)), `pairing: ${name} MAC`)
  }
  const manualHelloNoMac = { ...pairing.manual.hello }
  delete manualHelloNoMac.mac
  const manualAuthNoMac = { ...pairing.manual.auth }
  delete manualAuthNoMac.mac
  const manualTranscriptHash = checkerSha256(checkerCat(
    checkerSha256(checkerUtf8(checkerCanonicalJson(manualHelloNoMac))), ZERO,
    checkerSha256(checkerUtf8(checkerCanonicalJson(manualAuthNoMac))),
  ))
  assertCheck(checkerB64uEncode(manualTranscriptHash) === pairing.manual.transcript_hash, 'pairing: manual transcript hash')
  assertCheck(pairing.manual.hello.mac !== hello.mac && pairing.manual.auth.mac !== auth.mac, 'pairing: manual MACs use keyC')
  assertCheck(checkerMachineId(checkerB64uDecode(pairing.manual.auth.publicKey, 32)) === pairing.manual.auth.machineId, 'pairing: manual auth machineId')
  assertCheck(pairing.records.phone.peerMachineId === doc.identities.pc.machine_id, 'pairing: phone record peer')
  assertCheck(pairing.records.phone.peerPublicKey === doc.identities.pc.public_key, 'pairing: phone record key')
  assertCheck(pairing.records.pc.peerMachineId === doc.identities.phone.machine_id, 'pairing: pc record peer')
  assertCheck(pairing.records.pc.peerPublicKey === doc.identities.phone.public_key, 'pairing: pc record key')
  assertCheck(['qr', 'manual'].includes(pairing.records.pc.approvedVia) && typeof pairing.records.pc.approvedAt === 'string', 'pairing: pc approval fields')
  assertCheck(!('approvedVia' in pairing.records.phone) && !('approvedAt' in pairing.records.phone), 'pairing: phone record has no PC approval')
  const recordSha = checkerHex(checkerSha256(checkerUtf8(checkerCanonicalJson(pairing.records.pc))))
  assertCheck(recordSha === pairing.audit.record_sha256, 'pairing: record sha256')
  assertCheck(pairing.audit.pair_entry.recordSha256 === recordSha, 'pairing: audit record hash')
  assertCheck(checkerLoadRecord(pairing.records.pc, [pairing.audit.pair_entry]) === 'usable', 'pairing: approved record usable')
  assertCheck(pairing.approval.peerMachineId === pairing.records.pc.peerMachineId, 'pairing: approval peer')
  assertCheck(pairing.approval.peerName === pairing.records.pc.peerName, 'pairing: approval name')
  assertCheck(checkerFingerprint(pairing.records.pc.peerMachineId) === pairing.approval.fingerprint, 'pairing: fingerprint')
  assertCheck(checkerFingerprint(doc.identities.pc.machine_id) === pairing.approval.pcFingerprint, 'pairing: pc fingerprint')
  for (const input of pairing.approval.accepted_inputs) {
    assertCheck(checkerFingerprintMatch(pairing.records.pc.peerMachineId, input) === 'match', `pairing: fingerprint tolerance ${JSON.stringify(input)}`)
  }
  assertCheck(checkerFingerprintMatch(pairing.records.pc.peerMachineId, pairing.approval.rejected_input) === 'blocked', 'pairing: wrong fingerprint blocked')
  counts.sections += 1

  // Negative rows.  Crypto evidence and boolean state-machine model samples
  // are counted separately; a model row is not cryptographic evidence.
  for (const row of doc.invalid) {
    checkInvalid(doc, row)
    counts.invalid += 1
    if (row.evidence === 'model') counts.model += 1
    else counts.crypto += 1
  }
  assertCheck(counts.crypto + counts.model === counts.invalid, 'invalid row evidence count')
  return counts
}

function checkInvalid(doc, row) {
  switch (row.kind) {
    case 'handshake_signature': {
      const ok = checkerVerify(
        Buffer.from(row.transcript_hex, 'hex'),
        checkerB64uDecode(row.public_key, 32),
        checkerB64uDecode(row.signature, 64),
      )
      if (ok) throw new CheckError(`${row.case}: signature verified`)
      return
    }
    case 'handshake_transcript': {
      const computed = checkerInitTranscript(row.init, row.from, row.to)
      if (checkerHex(computed) === row.reference_hex) throw new CheckError(`${row.case}: transcript unchanged`)
      return
    }
    case 'sid_mismatch': {
      if (row.outer_sid === row.body_sid) throw new CheckError(`${row.case}: sid matched`)
      return
    }
    case 'cross_sid': {
      if (row.expected_sid === row.message_sid) throw new CheckError(`${row.case}: sid matched`)
      return
    }
    case 'x25519': {
      try {
        checkerDh(checkerXPrivateFromLabel(row.private_label), checkerB64uDecode(row.public_key, 32))
      } catch {
        return
      }
      throw new CheckError(`${row.case}: DH accepted`)
    }
    case 'reflection': {
      if (checkerDirection(row.sender, row.body_type) !== row.expected) {
        throw new CheckError(`${row.case}: direction verdict mismatch`)
      }
      return
    }
    case 'pairing_lookup': {
      if (row.paired_machine_ids.includes(row.from)) throw new CheckError(`${row.case}: peer was paired`)
      if (row.records_sid !== false) throw new CheckError(`${row.case}: unknown peer must not create a sid cache entry`)
      return
    }
    case 'reject': {
      const verdict = checkerApplyReject(row)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      if (verdict === 'delete') throw new CheckError(`${row.case}: reject deleted a record`)
      return
    }
    case 'record': {
      const verdict = checkerLoadRecord(row.record, row.audit)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'approval': {
      const verdict = checkerApproval(row)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'fingerprint': {
      const machineId = checkerMachineId(checkerB64uDecode(row.public_key, 32))
      const verdict = checkerFingerprintMatch(machineId, row.entered)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'admin_peer': {
      const verdict = checkerAdminPeer(row.source)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'status_redaction': {
      if (row.state !== 'awaiting_approval') throw new CheckError(`${row.case}: wrong state`)
      if (!row.fields.includes('peerName')) throw new CheckError(`${row.case}: peerName is missing`)
      for (const field of row.forbidden) {
        if (row.fields.includes(field)) throw new CheckError(`${row.case}: ${field} leaked during awaiting_approval`)
      }
      if (row.expected !== 'redacted') throw new CheckError(`${row.case}: unexpected expected value`)
      return
    }
    case 'reject_transcript': {
      const publicKey = checkerB64uDecode(row.public_key, 32)
      const signature = checkerB64uDecode(row.signature, 64)
      const signed = checkerVerify(
        checkerRejectTranscript(Buffer.from(row.signed_th1_hex, 'hex'), row.signed_code),
        publicKey,
        signature,
      )
      if (!signed) throw new CheckError(`${row.case}: the reference signature does not verify`)
      const wrong = checkerVerify(
        checkerRejectTranscript(Buffer.from(row.verified_th1_hex, 'hex'), row.verified_code),
        publicKey,
        signature,
      )
      if (wrong) throw new CheckError(`${row.case}: the signature verified for the wrong transcript`)
      return
    }
    case 'aead': {
      const key = row.key_b64
        ? checkerB64uDecode(row.key_b64, 32)
        : row.key_direction === 'pc_to_phone'
          ? checkerB64uDecode(doc.handshake.keys.pc_to_phone, 32)
          : row.key_direction === 'phone_to_pc'
            ? checkerB64uDecode(doc.handshake.keys.phone_to_pc, 32)
            : row.direction === 'phone_to_pc'
              ? checkerB64uDecode(doc.handshake.keys.phone_to_pc, 32)
              : checkerB64uDecode(doc.handshake.keys.pc_to_phone, 32)
      const frame = row.frame
      const version = String(frame.v ?? 1)
      const type = frame.type ?? 'e2e'
      const aad = checkerAad(frame.sid, frame.seq, frame.from, frame.to, type, version)
      try {
        checkerOpen(key, frame.seq, aad, checkerB64uDecode(frame.body))
      } catch {
        return
      }
      throw new CheckError(`${row.case}: AEAD accepted`)
    }
    case 'seq': {
      const verdict = checkerSeq(row)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'first_frame': {
      const verdict = checkerFirstFrame(row.type)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'encoding': {
      try {
        checkerB64uDecode(row.text)
      } catch {
        return
      }
      throw new CheckError(`${row.case}: encoding accepted`)
    }
    case 'canonical': {
      let canonical
      try {
        canonical = checkerCanonicalJson(JSON.parse(row.candidate))
      } catch {
        return
      }
      if (canonical === row.candidate) throw new CheckError(`${row.case}: canonical text accepted`)
      return
    }
    case 'chunk': {
      if (row.bytes !== undefined) {
        const verdict = checkerSize(row.bytes, row.limit)
        if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
        return
      }
      try {
        checkerReassemble(row.events)
      } catch {
        return
      }
      throw new CheckError(`${row.case}: chunk sequence accepted`)
    }
    case 'qr': {
      let parsed
      try {
        parsed = checkerQrParse(row.uri)
      } catch {
        if (row.expected === 'bad_frame') return
        throw new CheckError(`${row.case}: QR parse threw, expected ${row.expected}`)
      }
      if (row.expected_public_key && checkerB64uEncode(parsed.publicKey) !== row.expected_public_key) return
      if (row.expected_machine_id && parsed.machineId !== row.expected_machine_id) return
      throw new CheckError(`${row.case}: QR accepted`)
    }
    case 'manual': {
      try {
        checkerCrockfordDecode(row.input)
      } catch {
        return
      }
      throw new CheckError(`${row.case}: manual code accepted`)
    }
    case 'name': {
      try {
        checkerName(row.name)
      } catch {
        return
      }
      throw new CheckError(`${row.case}: name accepted`)
    }
    case 'origin': {
      const verdict = checkerOriginMatch(row.actual, row.expected_origin)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'unknown_code': {
      const verdict = checkerUnknownCode(row.code)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'frame': {
      const verdict = checkerOuterFrame(row.frame)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'size': {
      const verdict = checkerSize(row.bytes, row.limit)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'suite': {
      const verdict = checkerSuite(row.suite)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'caps': {
      const verdict = checkerCaps(row.caps, row.required)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'slot': {
      const verdict = checkerSlot(row)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'forbidden_endpoint': {
      const verdict = checkerForbiddenEndpoint(row.endpoint)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'confirm_recheck': {
      const verdict = checkerConfirmRecheck(row.record, row.audit)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'unpair_abort': {
      const verdict = checkerUnpairAbort(row.handshake_in_progress, row.unpair)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'idle': {
      const verdict = checkerIdle(row.idle_ms, row.limit_ms)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'slots': {
      const verdict = checkerSlots(row.open, row.limit)
      if (verdict !== row.expected) throw new CheckError(`${row.case}: ${verdict} != ${row.expected}`)
      return
    }
    case 'pair_mac': {
      const key = row.pair_key_b64
        ? checkerB64uDecode(row.pair_key_b64, 32)
        : checkerPairKey(checkerB64uDecode(row.key_secret, 16))
      const copy = { ...row.object }
      delete copy.mac
      const expected = checkerHmac(key, checkerCat(checkerUtf8(row.domain), ZERO, checkerUtf8(checkerCanonicalJson(copy))))
      if (expected.equals(checkerB64uDecode(row.object.mac, 32))) throw new CheckError(`${row.case}: mutated pair MAC verified`)
      return
    }
    default:
      throw new CheckError(`unknown invalid row kind ${row.kind}`)
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function usage() {
  console.log('usage: node spec/pclink/v1/tools/vectors.mjs --write|--check [--root DIR]')
}

function main(argv) {
  let mode
  let root = DEFAULT_ROOT
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--write') mode = 'write'
    else if (arg === '--check') mode = 'check'
    else if (arg === '--root') {
      root = resolve(argv[++index] ?? '')
    } else if (arg === '--help' || arg === '-h') {
      usage()
      return 0
    } else {
      console.error(`vectors: unknown argument ${JSON.stringify(arg)}`)
      usage()
      return 2
    }
  }
  if (mode === undefined) {
    usage()
    return 2
  }
  const path = join(root, GOLDEN)
  try {
    if (mode === 'write') {
      const doc = generate()
      writeFileSync(path, `${JSON.stringify(doc, null, 2)}\n`, 'utf8')
      console.log(`PASS PCLink vectors: wrote ${path}`)
      return 0
    }
    const doc = JSON.parse(readFileSync(path, 'utf8'))
    const counts = checkVectors(doc)
    console.log(`PASS PCLink vectors: ${counts.sections} sections, ${counts.frames} AEAD frames, ${counts.crypto} crypto negative rows rejected, ${counts.model} state-machine model samples rejected (状态机模型样例，非密码证据), ${counts.jsonAccepted} JSON-boundary accepts (escaped U+0000 preserved), ${counts.jsonRejected} JSON-boundary rejects (literal NUL/BOM/duplicate/lone surrogate/non-object root/PCLink field U+0000)`)
    return 0
  } catch (error) {
    console.error(`FAIL PCLink vectors: ${error instanceof Error ? error.message : String(error)}`)
    return 1
  }
}

process.exit(main(process.argv.slice(2)))
