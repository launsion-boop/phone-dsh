/** Inner message codec and schema-level validation (§6). */

import {
  b64urlDecode,
  fingerprintOf,
  isRfc3339,
  MAX_CHUNK_B64_CHARS,
  utf8,
  validateName,
} from './encoding.mjs'
import { isPclinkCode, pclinkError, SESSION_CLOSE_CODES } from './errors.mjs'
import { parseStrictJson, parseStrictJsonObject } from './json.mjs'
import { SUITE } from './handshake.mjs'

/** The only PCLink inner version. */
export const INNER_VERSION = 1
/** Required capability names for v1 (§5.6). */
export const REQUIRED_CAPS = Object.freeze(['workspace/1', SUITE])
/** Tested DSH range. */
export const DSH_TESTED_RANGE = '>=0.2.2-rc.1 <0.3.0'

const ID = /^[A-Za-z0-9._:-]{1,64}$/
const ENDPOINT = /^\$?[A-Za-z][A-Za-z0-9.]*(\/[A-Za-z][A-Za-z0-9.]*)?$/
const CAP = /^[A-Za-z0-9._/-]{1,64}$/
const ERROR_CODE = /^[A-Za-z0-9_$][A-Za-z0-9_$./:-]{0,127}$/
const SEMVER = /^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?$/

function exact(value, required, where) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', `${where} must be an object`)
  for (const name of required) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `${where} missing ${name}`)
  }
  for (const name of Object.keys(value)) {
    if (!required.includes(name)) throw pclinkError('bad_frame', `${where} unknown member ${name}`)
  }
}

function optionalMembers(value, required, optional, where) {
  requireObject(value, where)
  for (const name of required) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `${where} missing ${name}`)
  }
  for (const name of Object.keys(value)) {
    if (!required.includes(name) && !optional.includes(name)) throw pclinkError('bad_frame', `${where} unknown member ${name}`)
  }
}

function requireId(value, where) {
  if (typeof value !== 'string' || !ID.test(value)) throw pclinkError('bad_frame', `${where} is not a valid id`)
  return value
}

function requireEndpoint(value, where) {
  if (typeof value !== 'string' || !ENDPOINT.test(value)) throw pclinkError('bad_frame', `${where} is not a DSH endpoint`)
  return value
}

function requireObject(value, where) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', `${where} must be an object`)
  return value
}

/**
 * Validate the `{code,message,details?}` error object shared by rpc results and streams.
 * @param {unknown} value Candidate error.
 * @param {string} where Location label.
 * @returns {Record<string, unknown>} the error object.
 */
export function validateErrorObject(value, where = 'error') {
  optionalMembers(value, ['code', 'message'], ['details'], where)
  if (typeof value.code !== 'string' || !ERROR_CODE.test(value.code)) throw pclinkError('bad_frame', `${where}.code`)
  if (typeof value.message !== 'string' || Buffer.byteLength(value.message, 'utf8') < 1 || Buffer.byteLength(value.message, 'utf8') > 2048) {
    throw pclinkError('bad_frame', `${where}.message`)
  }
  rejectNul(value.message, `${where}.message`)
  if (value.details !== undefined) requireObject(value.details, `${where}.details`)
  return value
}

/**
 * Reject U+0000 in a PCLink-owned text field. Escaped `\u0000` remains legal
 * inside DSH passthrough values (args/results/stream items/details); the
 * PCLink-owned name/message fields keep rejecting it.
 * @param {string} value Validated text.
 * @param {string} where Field label.
 * @returns {void}
 */
function rejectNul(value, where) {
  if (value.includes('\u0000')) throw pclinkError('bad_frame', `${where} contains U+0000`)
}

/**
 * Truncate a human message to the 2048-byte wire cap without splitting a code point.
 * @param {unknown} message Candidate message.
 * @returns {string} safe message (at least one character).
 */
export function truncateMessage(message) {
  let text = typeof message === 'string' ? message : String(message)
  if (text.length === 0) text = 'error'
  // message is a PCLink-owned field: never emit U+0000 even when a DSH error
  // message contained one. Passthrough values are left untouched.
  text = text.replace(/\u0000/g, '\uFFFD')
  while (Buffer.byteLength(text, 'utf8') > 2048) text = Array.from(text).slice(0, -1).join('')
  return text
}

/**
 * Normalize a failure object to the exactly `{code,message,details?}` wire shape.
 * @param {{code?: unknown, message?: unknown, details?: unknown}} failure Failure facts.
 * @returns {{code: string, message: string, details?: object}} wire error.
 */
export function normalizeFailure(failure) {
  const code = typeof failure?.code === 'string' && ERROR_CODE.test(failure.code) ? failure.code : 'unavailable'
  const fallback = code === 'forbidden' ? 'remote pclink.admin calls are forbidden' : 'unavailable'
  const error = { code, message: truncateMessage(failure?.message ?? fallback) }
  if (failure?.details !== null && typeof failure?.details === 'object' && !Array.isArray(failure.details)) {
    error.details = failure.details
  }
  return error
}

/**
 * Parse and validate one SemVer string.
 * @param {unknown} value Candidate version.
 * @returns {{major: number, minor: number, patch: number, prerelease: string[]} | undefined} parsed version.
 */
export function parseSemVer(value) {
  if (typeof value !== 'string') return undefined
  const match = SEMVER.exec(value)
  if (match === null) return undefined
  const prerelease = match[4] === undefined ? [] : match[4].split('.')
  if (prerelease.some(part => part.length === 0)) return undefined
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]), prerelease }
}

function comparePrerelease(left, right) {
  if (left.length === 0 && right.length === 0) return 0
  if (left.length === 0) return 1
  if (right.length === 0) return -1
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index]
    const b = right[index]
    if (a === undefined) return -1
    if (b === undefined) return 1
    const aNumeric = /^[0-9]+$/.test(a)
    const bNumeric = /^[0-9]+$/.test(b)
    if (aNumeric && bNumeric) {
      const difference = Number(a) - Number(b)
      if (difference !== 0) return difference < 0 ? -1 : 1
    } else if (aNumeric !== bNumeric) {
      return aNumeric ? -1 : 1
    } else if (a !== b) {
      return a < b ? -1 : 1
    }
  }
  return 0
}

/**
 * Compare two parsed SemVer values.
 * @param {ReturnType<typeof parseSemVer>} left Left version.
 * @param {ReturnType<typeof parseSemVer>} right Right version.
 * @returns {number} -1, 0 or 1.
 */
export function compareSemVer(left, right) {
  for (const field of ['major', 'minor', 'patch']) {
    if (left[field] !== right[field]) return left[field] < right[field] ? -1 : 1
  }
  return comparePrerelease(left.prerelease, right.prerelease)
}

/**
 * Check the tested DSH range `>=0.2.2-rc.1 <0.3.0` (prereleases included).
 * @param {unknown} version Candidate version string.
 * @returns {boolean} true when inside the range.
 */
export function isDshVersionTested(version) {
  const parsed = parseSemVer(version)
  if (parsed === undefined) return false
  const lower = { major: 0, minor: 2, patch: 2, prerelease: ['rc', '1'] }
  const upper = { major: 0, minor: 3, patch: 0, prerelease: [] }
  return compareSemVer(parsed, lower) >= 0 && compareSemVer(parsed, upper) < 0
}

/**
 * Validate the `app` metadata object.
 * @param {unknown} value Candidate app.
 * @returns {Record<string, unknown>} validated app.
 */
export function validateApp(value) {
  exact(value, ['name', 'version'], 'peer.hello.app')
  if (typeof value.name !== 'string' || Buffer.byteLength(value.name, 'utf8') < 1 || Buffer.byteLength(value.name, 'utf8') > 64) {
    throw pclinkError('bad_frame', 'peer.hello.app.name')
  }
  validateName(value.name, 'peer.hello.app.name')
  if (typeof value.version !== 'string' || !/^[0-9A-Za-z.+-]{1,32}$/.test(value.version)) {
    throw pclinkError('bad_frame', 'peer.hello.app.version')
  }
  return value
}

/**
 * Validate one `peer.hello`.
 * @param {unknown} value Candidate message.
 * @param {'phone'|'pc'} [expectedRole] Required sender role.
 * @returns {Record<string, unknown>} validated message.
 */
export function validatePeerHello(value, expectedRole) {
  exact(value, ['v', 'type', 'role', 'caps', 'dsh', 'app', 'name'], 'peer.hello')
  if (value.v !== INNER_VERSION || value.type !== 'peer.hello') throw pclinkError('bad_frame', 'not a peer.hello')
  if (value.role !== 'phone' && value.role !== 'pc') throw pclinkError('bad_frame', 'peer.hello.role')
  if (expectedRole !== undefined && value.role !== expectedRole) throw pclinkError('bad_frame', 'peer.hello role is wrong for this direction')
  if (!Array.isArray(value.caps) || value.caps.length < 1 || value.caps.length > 16) throw pclinkError('bad_frame', 'peer.hello.caps')
  const seen = new Set()
  for (const cap of value.caps) {
    if (typeof cap !== 'string' || !CAP.test(cap)) throw pclinkError('bad_frame', 'peer.hello.caps entry')
    if (seen.has(cap)) throw pclinkError('bad_frame', 'peer.hello.caps duplicate')
    seen.add(cap)
  }
  optionalMembers(value.dsh, ['version'], ['commit'], 'peer.hello.dsh')
  if (parseSemVer(value.dsh.version) === undefined) throw pclinkError('bad_frame', 'peer.hello.dsh.version')
  if (value.dsh.commit !== undefined) {
    if (typeof value.dsh.commit !== 'string' || !/^[0-9a-f]{7,64}$/.test(value.dsh.commit)) throw pclinkError('bad_frame', 'peer.hello.dsh.commit')
  }
  validateApp(value.app)
  validateName(value.name, 'peer.hello.name')
  return value
}

/**
 * Check the capability intersection required by §5.6.
 * @param {string[]} caps Caps from a peer hello.
 * @returns {string[]} missing required capabilities (empty when satisfied).
 */
export function missingRequiredCaps(caps) {
  return REQUIRED_CAPS.filter(required => !caps.includes(required))
}

/**
 * Validate one `rpc.call`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateRpcCall(value) {
  exact(value, ['type', 'id', 'endpoint', 'args'], 'rpc.call')
  if (value.type !== 'rpc.call') throw pclinkError('bad_frame', 'not an rpc.call')
  requireId(value.id, 'rpc.call.id')
  requireEndpoint(value.endpoint, 'rpc.call.endpoint')
  requireObject(value.args, 'rpc.call.args')
  return value
}

/**
 * Validate one `rpc.result` (ok result or error, never both).
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateRpcResult(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', 'rpc.result must be an object')
  if (value.type !== 'rpc.result') throw pclinkError('bad_frame', 'not an rpc.result')
  requireId(value.id, 'rpc.result.id')
  if (value.ok === true) {
    exact(value, ['type', 'id', 'ok', 'result'], 'rpc.result')
  } else if (value.ok === false) {
    exact(value, ['type', 'id', 'ok', 'error'], 'rpc.result')
    validateErrorObject(value.error, 'rpc.result.error')
  } else {
    throw pclinkError('bad_frame', 'rpc.result.ok must be a boolean')
  }
  return value
}

/**
 * Validate one `rpc.result.chunk`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateResultChunk(value) {
  exact(value, ['type', 'id', 'part', 'last', 'data'], 'rpc.result.chunk')
  if (value.type !== 'rpc.result.chunk') throw pclinkError('bad_frame', 'not an rpc.result.chunk')
  requireId(value.id, 'rpc.result.chunk.id')
  return validateChunkFields(value, 'rpc.result.chunk')
}

function validateChunkFields(value, where) {
  if (!Number.isInteger(value.part) || value.part < 0 || value.part > 65535) throw pclinkError('bad_frame', `${where}.part`)
  if (typeof value.last !== 'boolean') throw pclinkError('bad_frame', `${where}.last`)
  if (typeof value.data !== 'string' || value.data.length < 1 || value.data.length > MAX_CHUNK_B64_CHARS) throw pclinkError('bad_frame', `${where}.data`)
  b64urlDecode(value.data)
  return value
}

/**
 * Validate one `rpc.stream.open`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamOpen(value) {
  exact(value, ['type', 'streamId', 'endpoint', 'payload'], 'rpc.stream.open')
  if (value.type !== 'rpc.stream.open') throw pclinkError('bad_frame', 'not an rpc.stream.open')
  requireId(value.streamId, 'rpc.stream.open.streamId')
  requireEndpoint(value.endpoint, 'rpc.stream.open.endpoint')
  exact(value.payload, ['args'], 'rpc.stream.open.payload')
  requireObject(value.payload.args, 'rpc.stream.open.payload.args')
  return value
}

/**
 * Validate one `rpc.stream.item`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamItem(value) {
  exact(value, ['type', 'streamId', 'value'], 'rpc.stream.item')
  if (value.type !== 'rpc.stream.item') throw pclinkError('bad_frame', 'not an rpc.stream.item')
  requireId(value.streamId, 'rpc.stream.item.streamId')
  return value
}

/**
 * Validate one `rpc.stream.chunk`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamChunk(value) {
  exact(value, ['type', 'streamId', 'part', 'last', 'data'], 'rpc.stream.chunk')
  if (value.type !== 'rpc.stream.chunk') throw pclinkError('bad_frame', 'not an rpc.stream.chunk')
  requireId(value.streamId, 'rpc.stream.chunk.streamId')
  return validateChunkFields(value, 'rpc.stream.chunk')
}

/**
 * Validate one `rpc.stream.end`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamEnd(value) {
  exact(value, ['type', 'streamId'], 'rpc.stream.end')
  if (value.type !== 'rpc.stream.end') throw pclinkError('bad_frame', 'not an rpc.stream.end')
  requireId(value.streamId, 'rpc.stream.end.streamId')
  return value
}

/**
 * Validate one `rpc.stream.error`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamError(value) {
  exact(value, ['type', 'streamId', 'error'], 'rpc.stream.error')
  if (value.type !== 'rpc.stream.error') throw pclinkError('bad_frame', 'not an rpc.stream.error')
  requireId(value.streamId, 'rpc.stream.error.streamId')
  validateErrorObject(value.error, 'rpc.stream.error.error')
  return value
}

/**
 * Validate one `rpc.stream.cancel`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateStreamCancel(value) {
  exact(value, ['type', 'streamId'], 'rpc.stream.cancel')
  if (value.type !== 'rpc.stream.cancel') throw pclinkError('bad_frame', 'not an rpc.stream.cancel')
  requireId(value.streamId, 'rpc.stream.cancel.streamId')
  return value
}

/**
 * Validate one `session.close`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateSessionClose(value) {
  optionalMembers(value, ['type', 'code'], ['message'], 'session.close')
  if (value.type !== 'session.close') throw pclinkError('bad_frame', 'not a session.close')
  if (!SESSION_CLOSE_CODES.includes(value.code)) throw pclinkError('bad_frame', 'unknown session.close code')
  if (value.message !== undefined) {
    if (typeof value.message !== 'string' || Buffer.byteLength(value.message, 'utf8') > 512) {
      throw pclinkError('bad_frame', 'session.close.message')
    }
    rejectNul(value.message, 'session.close.message')
  }
  return value
}

/**
 * Validate one `pclink.notice`.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateNotice(value) {
  exact(value, ['type', 'kind', 'name', 'fingerprint', 'at'], 'pclink.notice')
  if (value.type !== 'pclink.notice' || value.kind !== 'paired') throw pclinkError('bad_frame', 'pclink.notice shape')
  validateName(value.name, 'pclink.notice.name')
  if (!/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/.test(value.fingerprint)) throw pclinkError('bad_frame', 'pclink.notice.fingerprint')
  if (!isRfc3339(value.at)) throw pclinkError('bad_frame', 'pclink.notice.at')
  return value
}

/**
 * Whether a type is in the reserved task/call namespace (including a proper `.error`).
 * @param {unknown} type Candidate inner type.
 * @returns {boolean} true for the reserved namespace.
 */
export function isReservedType(type) {
  return typeof type === 'string' && /^(?:task|call)\./.test(type)
}

/**
 * Whether a type is the reserved error reply form.
 * @param {unknown} type Candidate inner type.
 * @returns {boolean} true for `<task|call>.<suffix>.error`.
 */
export function isReservedErrorType(type) {
  return typeof type === 'string' && /^(?:task|call)\.[A-Za-z][A-Za-z0-9._-]{0,63}\.error$/.test(type)
}

/**
 * Build the §6 default reply for an unmatched reserved message.
 * @param {Record<string, unknown>} message Received reserved message.
 * @returns {Record<string, unknown>} `<same type>.error` with `code:"unavailable"`.
 */
export function reservedErrorReply(message) {
  const type = `${String(message.type)}.error`
  const reply = { type, code: 'unavailable' }
  if (typeof message.id === 'string') reply.id = message.id
  return reply
}

/**
 * Validate one reserved error reply.
 * @param {unknown} value Candidate message.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateReservedError(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', 'reserved error must be an object')
  if (!isReservedErrorType(value.type)) throw pclinkError('bad_frame', 'not a reserved error type')
  for (const name of ['type', 'code']) {
    if (!Object.prototype.hasOwnProperty.call(value, name)) throw pclinkError('bad_frame', `reserved error missing ${name}`)
  }
  for (const name of Object.keys(value)) {
    if (!['type', 'id', 'code', 'message'].includes(name)) throw pclinkError('bad_frame', `reserved error unknown member ${name}`)
  }
  if (value.code !== 'unavailable') throw pclinkError('bad_frame', 'reserved error code must be unavailable')
  if (value.id !== undefined) requireId(value.id, 'reserved error.id')
  if (value.message !== undefined) {
    if (typeof value.message !== 'string' || Buffer.byteLength(value.message, 'utf8') > 512) {
      throw pclinkError('bad_frame', 'reserved error.message')
    }
    rejectNul(value.message, 'reserved error.message')
  }
  return value
}

/**
 * Whether an endpoint is the one forbidden remote prefix (§6.1/§7).
 * @param {unknown} endpoint Candidate endpoint string.
 * @returns {boolean} true when it starts with the exact `pclink.admin/` prefix.
 */
export function isForbiddenAdminEndpoint(endpoint) {
  return typeof endpoint === 'string' && endpoint.startsWith('pclink.admin/')
}

/**
 * Validate one inner message, enforcing direction and the closed type set.
 * @param {unknown} value Parsed message.
 * @param {{direction?: 'phone_to_pc'|'pc_to_phone'}} [options] Expected direction.
 * @returns {Record<string, unknown>} validated message.
 */
export function validateInnerMessage(value, options = {}) {
  requireObject(value, 'inner message')
  const type = value.type
  if (typeof type !== 'string') throw pclinkError('bad_frame', 'inner message type')
  if (isReservedType(type)) {
    if (isReservedErrorType(type)) return validateReservedError(value)
    // An unmatched task.*/call.* request is answered by the dispatcher, not decoded further.
    if (options.direction !== undefined) { /* both directions may carry the reserved namespace */ }
    return value
  }
  const phoneToPc = ['peer.hello', 'rpc.call', 'rpc.stream.open', 'rpc.stream.cancel', 'session.close']
  const pcToPhone = ['peer.hello', 'rpc.result', 'rpc.result.chunk', 'rpc.stream.item', 'rpc.stream.chunk', 'rpc.stream.end', 'rpc.stream.error', 'session.close', 'pclink.notice']
  const expected = options.direction === undefined ? undefined : options.direction === 'phone_to_pc' ? phoneToPc : pcToPhone
  if (expected !== undefined && !expected.includes(type)) throw pclinkError('bad_frame', `inner type ${type} is wrong for direction ${options.direction}`)
  switch (type) {
    case 'peer.hello': return validatePeerHello(value, options.direction === 'phone_to_pc' ? 'phone' : options.direction === 'pc_to_phone' ? 'pc' : undefined)
    case 'rpc.call': return validateRpcCall(value)
    case 'rpc.result': return validateRpcResult(value)
    case 'rpc.result.chunk': return validateResultChunk(value)
    case 'rpc.stream.open': return validateStreamOpen(value)
    case 'rpc.stream.item': return validateStreamItem(value)
    case 'rpc.stream.chunk': return validateStreamChunk(value)
    case 'rpc.stream.end': return validateStreamEnd(value)
    case 'rpc.stream.error': return validateStreamError(value)
    case 'rpc.stream.cancel': return validateStreamCancel(value)
    case 'session.close': return validateSessionClose(value)
    case 'pclink.notice': return validateNotice(value)
    default: throw pclinkError('bad_frame', `unknown inner type ${String(type)}`)
  }
}

/**
 * Encode one inner message as compact JSON text.
 *
 * The exact serialized form is validated before it can be sealed: JSON.stringify
 * drops members whose value is `undefined`, so validating the in-memory object
 * alone would still allow an illegal frame (for example `rpc.result{ok:true}`
 * without `result`) to reach the wire (CCR-1).
 * @param {Record<string, unknown>} message Inner message.
 * @returns {string} JSON text.
 */
export function encodeInnerMessage(message) {
  const text = JSON.stringify(message)
  if (typeof text !== 'string') throw pclinkError('bad_frame', 'inner message is not JSON encodable')
  validateInnerMessage(parseStrictJsonObject(text))
  return text
}

/**
 * Decode strict JSON and validate one inner message.
 * @param {string | Uint8Array} text Plaintext.
 * @param {{direction?: 'phone_to_pc'|'pc_to_phone'}} [options] Expected direction.
 * @returns {Record<string, unknown>} validated message.
 */
export function decodeInnerMessage(text, options = {}) {
  const message = parseStrictJsonObject(text)
  return validateInnerMessage(message, options)
}

/**
 * UTF-8 byte length of a compact JSON encoding, capped by the §6.1 args limit.
 * @param {unknown} value Parsed value.
 * @returns {number} byte length.
 */
export function jsonByteLength(value) {
  return utf8(JSON.stringify(value)).length
}

/**
 * Validate a decrypted outer `rpc.result`/stream error code namespace:
 * PCLink codes are only allowed where named; unknown DSH codes pass through.
 * @param {unknown} code Candidate code.
 * @returns {boolean} true for the PCLink `forbidden` code only (all others are DSH namespace).
 */
export function isPclinkResultErrorCode(code) {
  return code === 'forbidden' && isPclinkCode(code)
}

/**
 * Format a fingerprint from a machineId for notices (re-export convenience).
 * @param {string} machineId Peer machineId.
 * @returns {string} display fingerprint.
 */
export function noticeFingerprint(machineId) {
  return fingerprintOf(machineId)
}

/**
 * Parse strict JSON and validate it as a peer hello (vector helper).
 * @param {string} text JSON.
 * @returns {Record<string, unknown>} hello.
 */
export function parsePeerHello(text) {
  return validatePeerHello(parseStrictJson(text))
}
