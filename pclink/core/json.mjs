/** A strict JSON reader for PCLink messages (§2.3): no duplicates, NUL or lone surrogates. */

import { pclinkError } from './errors.mjs'

const WHITESPACE = new Set([0x20, 0x09, 0x0a, 0x0d])

class JsonReader {
  constructor(text) {
    this.text = text
    this.index = 0
  }

  error(message) {
    throw pclinkError('bad_frame', `invalid JSON at offset ${String(this.index)}: ${message}`)
  }

  skipWhitespace() {
    while (this.index < this.text.length && WHITESPACE.has(this.text.charCodeAt(this.index))) this.index += 1
  }

  parseValue(depth) {
    if (depth > 256) this.error('nesting too deep')
    this.skipWhitespace()
    const character = this.text[this.index]
    if (character === '{') return this.parseObject(depth)
    if (character === '[') return this.parseArray(depth)
    if (character === '"') return this.parseString()
    if (character === 't') return this.parseLiteral('true', true)
    if (character === 'f') return this.parseLiteral('false', false)
    if (character === 'n') return this.parseLiteral('null', null)
    if (character === '-' || (character >= '0' && character <= '9')) return this.parseNumber()
    this.error('unexpected token')
  }

  parseLiteral(word, value) {
    if (!this.text.startsWith(word, this.index)) this.error(`expected ${word}`)
    this.index += word.length
    return value
  }

  parseNumber() {
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(this.text.slice(this.index))
    if (match === null) this.error('invalid number')
    this.index += match[0].length
    const value = Number(match[0])
    if (!Number.isFinite(value)) this.error('number is not finite')
    return value
  }

  parseString() {
    if (this.text[this.index] !== '"') this.error('expected string')
    this.index += 1
    let result = ''
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index)
      if (code === 0x22) {
        this.index += 1
        if (result.isWellFormed !== undefined && !result.isWellFormed()) this.error('unpaired surrogate')
        // A raw NUL is rejected by the control-character check below; an
        // escaped \u0000 is legal JSON data carried inside a DSH value.
        return result
      }
      if (code === 0x5c) {
        this.index += 1
        const escape = this.text[this.index]
        this.index += 1
        switch (escape) {
          case '"': result += '"'; break
          case '\\': result += '\\'; break
          case '/': result += '/'; break
          case 'b': result += '\b'; break
          case 'f': result += '\f'; break
          case 'n': result += '\n'; break
          case 'r': result += '\r'; break
          case 't': result += '\t'; break
          case 'u': {
            const hex = this.text.slice(this.index, this.index + 4)
            if (!/^[0-9A-Fa-f]{4}$/.test(hex)) this.error('invalid \\u escape')
            const unit = Number.parseInt(hex, 16)
            this.index += 4
            result += String.fromCharCode(unit)
            break
          }
          default:
            this.error('invalid escape')
        }
        continue
      }
      if (code < 0x20) this.error('raw control character in string')
      if (code >= 0xd800 && code <= 0xdbff) {
        const low = this.text.charCodeAt(this.index + 1)
        if (!(low >= 0xdc00 && low <= 0xdfff)) this.error('unpaired high surrogate')
        result += this.text.slice(this.index, this.index + 2)
        this.index += 2
        continue
      }
      if (code >= 0xdc00 && code <= 0xdfff) this.error('unpaired low surrogate')
      result += this.text[this.index]
      this.index += 1
    }
    this.error('unterminated string')
  }

  parseArray(depth) {
    this.index += 1
    const result = []
    this.skipWhitespace()
    if (this.text[this.index] === ']') {
      this.index += 1
      return result
    }
    for (;;) {
      result.push(this.parseValue(depth + 1))
      this.skipWhitespace()
      const separator = this.text[this.index]
      if (separator === ']') {
        this.index += 1
        return result
      }
      if (separator !== ',') this.error('expected , or ]')
      this.index += 1
    }
  }

  parseObject(depth) {
    this.index += 1
    const result = {}
    const names = new Set()
    this.skipWhitespace()
    if (this.text[this.index] === '}') {
      this.index += 1
      return result
    }
    for (;;) {
      this.skipWhitespace()
      if (this.text[this.index] !== '"') this.error('expected object member name')
      const name = this.parseString()
      if (names.has(name)) this.error(`duplicate member ${JSON.stringify(name)}`)
      names.add(name)
      this.skipWhitespace()
      if (this.text[this.index] !== ':') this.error('expected :')
      this.index += 1
      const value = this.parseValue(depth + 1)
      Object.defineProperty(result, name, { value, enumerable: true, configurable: true, writable: true })
      this.skipWhitespace()
      const separator = this.text[this.index]
      if (separator === '}') {
        this.index += 1
        return result
      }
      if (separator !== ',') this.error('expected , or }')
      this.index += 1
    }
  }
}

/**
 * Parse one strict JSON value.
 *
 * Rejects a BOM, leading/trailing bytes, duplicate member names at any depth,
 * NUL, unpaired surrogates, non-finite numbers and invalid UTF-8.
 * @param {string | Uint8Array} input Text or UTF-8 bytes.
 * @param {{maxBytes?: number}} [options] Optional byte cap.
 * @returns {unknown} parsed value.
 */
export function parseStrictJson(input, options = {}) {
  let text
  if (typeof input === 'string') {
    text = input
  } else if (input instanceof Uint8Array) {
    if (options.maxBytes !== undefined && input.byteLength > options.maxBytes) {
      throw pclinkError('frame_too_large', 'JSON text exceeds its limit')
    }
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(input)
    } catch {
      throw pclinkError('bad_frame', 'invalid UTF-8')
    }
  } else {
    throw pclinkError('bad_frame', 'expected JSON text')
  }
  if (text.length === 0) throw pclinkError('bad_frame', 'empty JSON text')
  if (text.charCodeAt(0) === 0xfeff) throw pclinkError('bad_frame', 'byte-order mark is not allowed')
  const reader = new JsonReader(text)
  const value = reader.parseValue(0)
  reader.skipWhitespace()
  if (reader.index !== text.length) throw pclinkError('bad_frame', 'trailing bytes after JSON value')
  return value
}

/**
 * Parse exactly one JSON object (the only root every PCLink frame allows).
 * @param {string | Uint8Array} input Text or bytes.
 * @param {{maxBytes?: number}} [options] Optional byte cap.
 * @returns {Record<string, unknown>} parsed object.
 */
export function parseStrictJsonObject(input, options = {}) {
  const value = parseStrictJson(input, options)
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw pclinkError('bad_frame', 'JSON root must be an object')
  }
  return value
}

/**
 * Compare two parsed JSON values structurally.
 * @param {unknown} left Left value.
 * @param {unknown} right Right value.
 * @returns {boolean} true when structurally equal.
 */
export function jsonEquals(left, right) {
  if (left === right) return true
  if (typeof left !== typeof right) return false
  if (left === null || right === null) return false
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false
    return left.every((value, index) => jsonEquals(value, right[index]))
  }
  if (typeof left === 'object') {
    const leftKeys = Object.keys(left)
    const rightKeys = Object.keys(right)
    if (leftKeys.length !== rightKeys.length) return false
    return leftKeys.every(key => Object.prototype.hasOwnProperty.call(right, key) && jsonEquals(left[key], right[key]))
  }
  return false
}
