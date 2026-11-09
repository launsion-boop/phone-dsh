/** PCLink canonical JSON (§2.3): scalar-order keys, exact escapes, literal UTF-8. */

import { pclinkError } from './errors.mjs'

function compareCodePointSequences(left, right) {
  const a = Array.from(left, character => character.codePointAt(0))
  const b = Array.from(right, character => character.codePointAt(0))
  const length = Math.min(a.length, b.length)
  for (let index = 0; index < length; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1
  }
  return a.length - b.length
}

function encodeString(value) {
  if (value.isWellFormed !== undefined && !value.isWellFormed()) {
    throw pclinkError('bad_frame', 'canonical JSON string contains an unpaired surrogate')
  }
  let output = '"'
  for (const character of value) {
    const codePoint = character.codePointAt(0)
    if (character === '"') output += '\\"'
    else if (character === '\\') output += '\\\\'
    else if (character === '\b') output += '\\b'
    else if (character === '\t') output += '\\t'
    else if (character === '\n') output += '\\n'
    else if (character === '\f') output += '\\f'
    else if (character === '\r') output += '\\r'
    else if (codePoint < 0x20) output += `\\u${codePoint.toString(16).padStart(4, '0')}`
    else output += character
  }
  return `${output}"`
}

/**
 * Serialize one value with the §2.3 canonical rules.
 * @param {unknown} value JSON-compatible value.
 * @returns {string} canonical JSON text.
 */
export function canonicalJson(value) {
  if (value === null) return 'null'
  if (value === true) return 'true'
  if (value === false) return 'false'
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw pclinkError('bad_frame', 'canonical JSON rejects a non-finite number')
    return JSON.stringify(value)
  }
  if (typeof value === 'string') return encodeString(value)
  if (Array.isArray(value)) return `[${value.map(item => canonicalJson(item)).join(',')}]`
  if (typeof value === 'object') {
    if (value instanceof Uint8Array) throw pclinkError('bad_frame', 'canonical JSON rejects bytes')
    const keys = Object.keys(value)
    keys.sort(compareCodePointSequences)
    return `{${keys.map(key => `${encodeString(key)}:${canonicalJson(value[key])}`).join(',')}}`
  }
  throw pclinkError('bad_frame', `canonical JSON rejects ${typeof value}`)
}

/**
 * UTF-8 bytes of the canonical encoding.
 * @param {unknown} value JSON-compatible value.
 * @returns {Buffer} canonical UTF-8 bytes.
 */
export function canonicalBytes(value) {
  return Buffer.from(canonicalJson(value), 'utf8')
}
