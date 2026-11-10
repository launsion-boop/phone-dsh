/** E2E handshake transcripts, signatures, keys and PC/phone state machines (§5.2/§5.3). */

import {
  b64urlDecode,
  b64urlEncode,
  concatBytes,
  hkdf32,
  hmacSha256,
  randomBytes,
  sha256,
  timingSafeEqualBytes,
} from './encoding.mjs'
import { pclinkError, isSessionRejectCode } from './errors.mjs'
import { ed25519Sign, ed25519Verify, generateEphemeralX25519, x25519Dh } from './identity.mjs'

/** The only v1 suite name. */
export const SUITE = 'pclink-x25519-ed25519-chacha20poly1305-1'

const SID = /^[A-Za-z0-9_-]{22}$/
const MACHINE_ID = /^[a-z2-7]{26}$/

function bytes(value, length, what) {
  try {
    return b64urlDecode(value, { length })
  } catch (error) {
    throw pclinkError('bad_frame', `${what}: ${error.message}`)
  }
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

function sidText(value, where) {
  if (typeof value !== 'string' || !SID.test(value)) throw pclinkError('bad_frame', `${where} is not a sid`)
  return value
}

function messageText(value, where) {
  if (value === undefined) return undefined
  if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > 512) throw pclinkError('bad_frame', `${where} invalid`)
  if (value.includes('\u0000')) throw pclinkError('bad_frame', `${where} contains U+0000`)
  return value
}

/**
 * Validate a `session.init` body.
 * @param {unknown} value Parsed body.
 * @returns {Record<string, unknown>} validated body.
 */
export function validateSessionInit(value) {
  exact(value, ['v', 'type', 'sid', 'suite', 'eph', 'nonce'], 'session.init')
  if (value.v !== 1 || value.type !== 'session.init') throw pclinkError('bad_frame', 'not a session.init')
  sidText(value.sid, 'session.init.sid')
  if (typeof value.suite !== 'string') throw pclinkError('bad_frame', 'session.init.suite')
  bytes(value.eph, 32, 'session.init.eph')
  bytes(value.nonce, 32, 'session.init.nonce')
  return value
}

/**
 * Validate a `session.resp` body.
 * @param {unknown} value Parsed body.
 * @returns {Record<string, unknown>} validated body.
 */
export function validateSessionResp(value) {
  exact(value, ['v', 'type', 'sid', 'eph', 'nonce', 'sig', 'confirm'], 'session.resp')
  if (value.v !== 1 || value.type !== 'session.resp') throw pclinkError('bad_frame', 'not a session.resp')
  sidText(value.sid, 'session.resp.sid')
  bytes(value.eph, 32, 'session.resp.eph')
  bytes(value.nonce, 32, 'session.resp.nonce')
  bytes(value.sig, 64, 'session.resp.sig')
  bytes(value.confirm, 32, 'session.resp.confirm')
  return value
}

/**
 * Validate a `session.confirm` body.
 * @param {unknown} value Parsed body.
 * @returns {Record<string, unknown>} validated body.
 */
export function validateSessionConfirm(value) {
  exact(value, ['v', 'type', 'sid', 'sig', 'confirm'], 'session.confirm')
  if (value.v !== 1 || value.type !== 'session.confirm') throw pclinkError('bad_frame', 'not a session.confirm')
  sidText(value.sid, 'session.confirm.sid')
  bytes(value.sig, 64, 'session.confirm.sig')
  bytes(value.confirm, 32, 'session.confirm.confirm')
  return value
}

/**
 * Validate a `session.reject` body.
 * @param {unknown} value Parsed body.
 * @returns {Record<string, unknown>} validated body.
 */
export function validateSessionReject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', 'session.reject must be an object')
  for (const name of ['v', 'type', 'sid', 'code']) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `session.reject missing ${name}`)
  }
  for (const name of Object.keys(value)) {
    if (!['v', 'type', 'sid', 'code', 'sig', 'message'].includes(name)) throw pclinkError('bad_frame', `session.reject unknown member ${name}`)
  }
  if (value.v !== 1 || value.type !== 'session.reject') throw pclinkError('bad_frame', 'not a session.reject')
  sidText(value.sid, 'session.reject.sid')
  if (!isSessionRejectCode(value.code)) throw pclinkError('bad_frame', 'unknown session.reject code')
  if (value.sig !== undefined) bytes(value.sig, 64, 'session.reject.sig')
  messageText(value.message, 'session.reject.message')
  return value
}

/**
 * Transcript for `session.init` and its hash `th1` (§5.2).
 * @param {{phoneMachineId: string, pcMachineId: string, sid: string, suite: string, ephPhone: Uint8Array, noncePhone: Uint8Array, version?: string}} input Handshake fields.
 * @returns {Buffer} T_init bytes.
 */
export function initTranscript(input) {
  return concatBytes(
    Buffer.from('pclink-v1/session-init', 'utf8'), Buffer.from([0]),
    Buffer.from(input.version ?? '1', 'utf8'), Buffer.from([0]),
    Buffer.from(input.suite, 'utf8'), Buffer.from([0]),
    Buffer.from(machineId(input.phoneMachineId, 'phoneMachineId'), 'utf8'), Buffer.from([0]),
    Buffer.from(machineId(input.pcMachineId, 'pcMachineId'), 'utf8'), Buffer.from([0]),
    b64urlDecode(input.sid, { length: 16 }), Buffer.from([0]),
    Buffer.from(input.ephPhone), Buffer.from([0]),
    Buffer.from(input.noncePhone),
  )
}

/**
 * Transcript for `session.resp`; `th2 = sha256(T_resp)`.
 * @param {Uint8Array} th1 Init transcript hash.
 * @param {Uint8Array} ephPc PC ephemeral public key.
 * @param {Uint8Array} noncePc PC nonce.
 * @returns {Buffer} T_resp bytes.
 */
export function respTranscript(th1, ephPc, noncePc) {
  return concatBytes(
    Buffer.from('pclink-v1/session-resp', 'utf8'), Buffer.from([0]),
    Buffer.from(th1), Buffer.from([0]),
    Buffer.from(ephPc), Buffer.from([0]),
    Buffer.from(noncePc),
  )
}

/**
 * Transcript for `session.confirm`; `th3 = sha256(T_confirm)`.
 * @param {Uint8Array} th2 Response transcript hash.
 * @param {string} phoneMachineId Phone machineId.
 * @param {string} pcMachineId PC machineId.
 * @param {string} sid Session id text.
 * @returns {Buffer} T_confirm bytes.
 */
export function confirmTranscript(th2, phoneMachineId, pcMachineId, sid) {
  return concatBytes(
    Buffer.from('pclink-v1/session-confirm', 'utf8'), Buffer.from([0]),
    Buffer.from(th2), Buffer.from([0]),
    Buffer.from(machineId(phoneMachineId, 'phoneMachineId'), 'utf8'), Buffer.from([0]),
    Buffer.from(machineId(pcMachineId, 'pcMachineId'), 'utf8'), Buffer.from([0]),
    b64urlDecode(sid, { length: 16 }),
  )
}

/**
 * Transcript for a signed `session.reject` (§5.2).
 * @param {Uint8Array} th1 Init transcript hash being rejected.
 * @param {string} code Reject code.
 * @returns {Buffer} T_reject bytes.
 */
export function rejectTranscript(th1, code) {
  if (!isSessionRejectCode(code)) throw pclinkError('bad_frame', 'unknown session.reject code')
  return concatBytes(
    Buffer.from('pclink-v1/session-reject', 'utf8'), Buffer.from([0]),
    Buffer.from(th1), Buffer.from([0]),
    Buffer.from(code, 'utf8'),
  )
}

/**
 * Derive the four §5.3 keys from the X25519 secret and `salt = th2`.
 * @param {Uint8Array} dh 32-byte shared secret.
 * @param {Uint8Array} th2 Response transcript hash.
 * @returns {{phoneToPc: Buffer, pcToPhone: Buffer, confirmPhone: Buffer, confirmPc: Buffer}}
 */
export function deriveHandshakeKeys(dh, th2) {
  return {
    phoneToPc: hkdf32(dh, th2, 'pclink-v1/key/phone->pc'),
    pcToPhone: hkdf32(dh, th2, 'pclink-v1/key/pc->phone'),
    confirmPhone: hkdf32(dh, th2, 'pclink-v1/key-confirm/phone->pc'),
    confirmPc: hkdf32(dh, th2, 'pclink-v1/key-confirm/pc->phone'),
  }
}

/**
 * `confirm_pc` (PC proves the derived key to the phone).
 * @param {Uint8Array} kConfirmPc Confirmation key.
 * @param {Uint8Array} th2 Response transcript hash.
 * @returns {Buffer} 32-byte confirmation.
 */
export function confirmPcValue(kConfirmPc, th2) {
  return hmacSha256(kConfirmPc, concatBytes(Buffer.from('pclink-v1/confirm', 'utf8'), Buffer.from([0]), th2))
}

/**
 * `confirm_phone` (phone proves the derived key to the PC).
 * @param {Uint8Array} kConfirmPhone Confirmation key.
 * @param {Uint8Array} th3 Confirm transcript hash.
 * @returns {Buffer} 32-byte confirmation.
 */
export function confirmPhoneValue(kConfirmPhone, th3) {
  return hmacSha256(kConfirmPhone, concatBytes(Buffer.from('pclink-v1/confirm', 'utf8'), Buffer.from([0]), th3))
}

/**
 * Build a signed PC `session.reject` for one valid init.
 * @param {{identity: {privateKey: import('node:crypto').KeyObject}}} input PC identity.
 * @param {{sid: string, code: string, th1: Uint8Array, message?: string}} args Reject fields.
 * @returns {Record<string, unknown>} session.reject body.
 */
export function buildSessionReject({ identity }, { sid, code, th1, message }) {
  if (!isSessionRejectCode(code)) throw pclinkError('bad_frame', 'unknown session.reject code')
  const signature = ed25519Sign(identity.privateKey, rejectTranscript(th1, code))
  return {
    v: 1,
    type: 'session.reject',
    sid,
    code,
    sig: b64urlEncode(signature),
    ...(message === undefined ? {} : { message: message.slice(0, 512) }),
  }
}

/**
 * Phone-side policy after a handshake reject (§5.2/§5.5): only a verified,
 * th1-matching signed `unpaired` reject may prompt the user; every other
 * outcome keeps the record and never auto-deletes or auto-pairs.
 * @param {{verified: boolean, code: string, th1Matches: boolean, hasRecord: boolean}} input Reject facts.
 * @returns {'prompt'|'keep_record'} policy decision.
 */
export function decideRejectHandling(input) {
  if (!input.verified || !input.th1Matches) return 'keep_record'
  if (input.code === 'unpaired' && input.hasRecord) return 'prompt'
  return 'keep_record'
}

/**
 * Verify a PC-signed reject with the pinned PC public key.
 * @param {Uint8Array} pcPublicKey Pinned raw PC key.
 * @param {Record<string, unknown>} reject Parsed reject body.
 * @param {{sid: string, th1: Uint8Array}} expected Phone's in-progress init facts.
 * @returns {{code: string}} verified reject facts.
 */
export function verifySessionReject(pcPublicKey, reject, expected) {
  validateSessionReject(reject)
  if (reject.sid !== expected.sid) throw pclinkError('auth_failed', 'reject sid mismatch')
  if (reject.sig === undefined) throw pclinkError('auth_failed', 'reject is unsigned')
  const signature = b64urlDecode(reject.sig, { length: 64 })
  if (!ed25519Verify(pcPublicKey, rejectTranscript(expected.th1, reject.code), signature)) {
    throw pclinkError('auth_failed', 'reject signature invalid')
  }
  return { code: reject.code }
}

/** Phone-side handshake initiator: creates init, verifies resp, sends confirm. */
export class HandshakeInitiator {
  /**
   * @param {{identity: {privateKey: import('node:crypto').KeyObject, publicKey: Uint8Array, machineId: string}, pcMachineId: string, pcPublicKey: Uint8Array, sid?: string, eph?: {privateKey: import('node:crypto').KeyObject, publicKey: Uint8Array}, nonce?: Uint8Array}} options Handshake inputs.
   */
  constructor(options) {
    this.identity = options.identity
    this.pcMachineId = machineId(options.pcMachineId, 'pcMachineId')
    this.pcPublicKey = Buffer.from(options.pcPublicKey)
    this.sid = options.sid ?? b64urlEncode(randomBytes(16))
    if (!SID.test(this.sid)) throw pclinkError('bad_frame', 'sid must be 16 bytes')
    this.ephemeral = options.eph ?? generateEphemeralX25519()
    this.nonce = Buffer.from(options.nonce ?? randomBytes(32))
    this.th1 = sha256(initTranscript({
      phoneMachineId: this.identity.machineId,
      pcMachineId: this.pcMachineId,
      sid: this.sid,
      suite: SUITE,
      ephPhone: this.ephemeral.publicKey,
      noncePhone: this.nonce,
    }))
    this.established = false
    this.keys = undefined
    this.th2 = undefined
  }

  /**
   * Build the init body.
   * @returns {Record<string, unknown>} session.init.
   */
  buildInit() {
    return {
      v: 1,
      type: 'session.init',
      sid: this.sid,
      suite: SUITE,
      eph: b64urlEncode(this.ephemeral.publicKey),
      nonce: b64urlEncode(this.nonce),
    }
  }

  /**
   * Verify one resp and build the confirm. Keys are installed only after verification.
   * @param {unknown} resp Parsed session.resp.
   * @returns {Record<string, unknown>} session.confirm to send.
   */
  acceptResp(resp) {
    validateSessionResp(resp)
    if (resp.sid !== this.sid) throw pclinkError('replay', 'resp sid does not match this init')
    const ephPc = b64urlDecode(resp.eph, { length: 32 })
    const noncePc = b64urlDecode(resp.nonce, { length: 32 })
    const dh = x25519Dh(this.ephemeral.privateKey, ephPc)
    const th2 = sha256(respTranscript(this.th1, ephPc, noncePc))
    const keys = deriveHandshakeKeys(dh, th2)
    const signature = b64urlDecode(resp.sig, { length: 64 })
    if (!ed25519Verify(this.pcPublicKey, respTranscript(this.th1, ephPc, noncePc), signature)) {
      throw pclinkError('auth_failed', 'PC response signature invalid')
    }
    const expectedConfirm = confirmPcValue(keys.confirmPc, th2)
    if (!timingSafeEqualBytes(b64urlDecode(resp.confirm, { length: 32 }), expectedConfirm)) {
      throw pclinkError('auth_failed', 'PC key confirmation invalid')
    }
    const th3 = sha256(confirmTranscript(th2, this.identity.machineId, this.pcMachineId, this.sid))
    const confirm = {
      v: 1,
      type: 'session.confirm',
      sid: this.sid,
      sig: b64urlEncode(ed25519Sign(this.identity.privateKey, confirmTranscript(th2, this.identity.machineId, this.pcMachineId, this.sid))),
      confirm: b64urlEncode(confirmPhoneValue(keys.confirmPhone, th3)),
    }
    this.keys = keys
    this.th2 = th2
    this.ephPc = ephPc
    this.noncePc = noncePc
    this.established = true
    this.ephemeral = { publicKey: this.ephemeral.publicKey, privateKey: undefined }
    return confirm
  }

  /** Destroy handshake state and ephemeral private key. */
  drop() {
    this.established = false
    this.keys = undefined
    this.ephemeral = { privateKey: undefined, publicKey: this.ephemeral.publicKey }
  }
}

/** PC-side handshake responder: verifies init, builds resp, verifies confirm. */
export class HandshakeResponder {
  /**
   * @param {{identity: {privateKey: import('node:crypto').KeyObject, publicKey: Uint8Array, machineId: string}, phoneMachineId: string, phonePublicKey: Uint8Array, eph?: {privateKey: import('node:crypto').KeyObject, publicKey: Uint8Array}, nonce?: Uint8Array}} options Handshake inputs.
   */
  constructor(options) {
    this.identity = options.identity
    this.phoneMachineId = machineId(options.phoneMachineId, 'phoneMachineId')
    this.phonePublicKey = Buffer.from(options.phonePublicKey)
    this.injectedEph = options.eph
    this.injectedNonce = options.nonce
  }

  /**
   * Validate an init, build the resp and keep pending keys until confirm.
   * @param {Record<string, unknown>} init Parsed session.init body.
   * @param {{from: string, to: string, sid: string}} outer Validated outer facts.
   * @returns {{resp: Record<string, unknown>, th1: Buffer, th2: Buffer}} response and transcripts.
   */
  respond(init, outer) {
    validateSessionInit(init)
    if (init.sid !== outer.sid) throw pclinkError('bad_frame', 'outer/body sid mismatch')
    if (outer.from !== this.phoneMachineId) throw pclinkError('auth_failed', 'init from does not match the pairing record')
    if (outer.to !== this.identity.machineId) throw pclinkError('auth_failed', 'init to does not match this PC')
    if (init.suite !== SUITE) throw pclinkError('version_unsupported', 'unsupported suite')
    const th1 = sha256(initTranscript({
      phoneMachineId: this.phoneMachineId,
      pcMachineId: this.identity.machineId,
      sid: init.sid,
      suite: init.suite,
      ephPhone: b64urlDecode(init.eph, { length: 32 }),
      noncePhone: b64urlDecode(init.nonce, { length: 32 }),
    }))
    const eph = this.injectedEph ?? generateEphemeralX25519()
    const nonce = Buffer.from(this.injectedNonce ?? randomBytes(32))
    const dh = x25519Dh(eph.privateKey, b64urlDecode(init.eph, { length: 32 }))
    const th2 = sha256(respTranscript(th1, eph.publicKey, nonce))
    const keys = deriveHandshakeKeys(dh, th2)
    const resp = {
      v: 1,
      type: 'session.resp',
      sid: init.sid,
      eph: b64urlEncode(eph.publicKey),
      nonce: b64urlEncode(nonce),
      sig: b64urlEncode(ed25519Sign(this.identity.privateKey, respTranscript(th1, eph.publicKey, nonce))),
      confirm: b64urlEncode(confirmPcValue(keys.confirmPc, th2)),
    }
    this.th1 = th1
    this.th2 = th2
    this.th3 = undefined
    this.keys = keys
    this.ephemeral = eph
    this.established = false
    return { resp, th1, th2 }
  }

  /**
   * Verify the phone confirm and install the session keys.
   * @param {unknown} confirm Parsed session.confirm.
   * @returns {{keys: object, th3: Buffer}} established facts.
   */
  acceptConfirm(confirm) {
    validateSessionConfirm(confirm)
    if (this.keys === undefined || this.th2 === undefined) throw pclinkError('bad_frame', 'no handshake in progress')
    const signature = b64urlDecode(confirm.sig, { length: 64 })
    const th3 = sha256(confirmTranscript(this.th2, this.phoneMachineId, this.identity.machineId, confirm.sid))
    if (!ed25519Verify(this.phonePublicKey, confirmTranscript(this.th2, this.phoneMachineId, this.identity.machineId, confirm.sid), signature)) {
      throw pclinkError('auth_failed', 'phone confirmation signature invalid')
    }
    if (!timingSafeEqualBytes(b64urlDecode(confirm.confirm, { length: 32 }), confirmPhoneValue(this.keys.confirmPhone, th3))) {
      throw pclinkError('auth_failed', 'phone key confirmation invalid')
    }
    this.th3 = th3
    this.established = true
    const keys = this.keys
    this.ephemeral = { privateKey: undefined, publicKey: this.ephemeral.publicKey }
    this.keys = undefined
    return { keys, th3 }
  }

  /** Destroy handshake state and ephemeral private key. */
  drop() {
    this.established = false
    this.keys = undefined
    this.ephemeral = { privateKey: undefined, publicKey: this.ephemeral?.publicKey }
  }
}
