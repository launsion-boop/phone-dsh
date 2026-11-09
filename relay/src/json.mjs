// SPDX-License-Identifier: MIT
// Strict JSON input for PCLink relay frames.
//
// The PCLink contract requires exactly one UTF-8 JSON object with no BOM, no
// leading/trailing bytes, no duplicate member names at any depth, no NUL, no
// unpaired surrogates and no NaN/Infinity.  JSON.parse cannot report duplicate
// names, so the relay uses this small, dependency-free parser instead of
// JSON.parse for inbound frames.  It deliberately returns null-prototype
// objects so a member named "__proto__" cannot mutate a prototype.

const MAX_DEPTH = 256

export class StrictJsonError extends Error {
  constructor(message) {
    super(message)
    this.name = 'StrictJsonError'
  }
}

function isWhitespace(code) {
  return code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d
}

function isDigit(code) {
  return code >= 0x30 && code <= 0x39
}

function isHex(code) {
  return (code >= 0x30 && code <= 0x39)
    || (code >= 0x41 && code <= 0x46)
    || (code >= 0x61 && code <= 0x66)
}

export function parseStrictJsonObject(text) {
  if (typeof text !== 'string') throw new StrictJsonError('frame must be a UTF-8 JSON text')
  if (text.length === 0) throw new StrictJsonError('empty frame')
  if (text.charCodeAt(0) === 0xfeff) throw new StrictJsonError('BOM is not allowed')
  if (text.charCodeAt(0) !== 0x7b) throw new StrictJsonError('root must be a JSON object')
  if (text.includes('\u0000')) throw new StrictJsonError('NUL is not allowed')

  let index = 0
  const length = text.length

  const fail = (message) => {
    throw new StrictJsonError(`${message} at offset ${index}`)
  }

  const skipWhitespace = () => {
    while (index < length && isWhitespace(text.charCodeAt(index))) index += 1
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
        const escaped = text.charCodeAt(index)
        index += 1
        switch (escaped) {
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
            for (let offset = 0; offset < 4; offset += 1) {
              if (!isHex(text.charCodeAt(index + offset))) fail('bad unicode escape')
            }
            const value = Number.parseInt(text.slice(index, index + 4), 16)
            index += 4
            if (value === 0) fail('NUL is not allowed')
            if (value >= 0xd800 && value <= 0xdbff) {
              if (index + 6 > length || text.charCodeAt(index) !== 0x5c || text.charCodeAt(index + 1) !== 0x75) {
                fail('unpaired high surrogate')
              }
              for (let offset = 0; offset < 4; offset += 1) {
                if (!isHex(text.charCodeAt(index + 2 + offset))) fail('bad low surrogate escape')
              }
              const low = Number.parseInt(text.slice(index + 2, index + 6), 16)
              if (low < 0xdc00 || low > 0xdfff) fail('unpaired high surrogate')
              index += 6
              out += String.fromCodePoint(0x10000 + ((value - 0xd800) << 10) + (low - 0xdc00))
            } else if (value >= 0xdc00 && value <= 0xdfff) {
              fail('unpaired low surrogate')
            } else {
              out += String.fromCharCode(value)
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
    const start = index
    if (text.charCodeAt(index) === 0x2d) index += 1
    if (index >= length) fail('bad number')
    if (text.charCodeAt(index) === 0x30) {
      index += 1
      if (index < length && isDigit(text.charCodeAt(index))) fail('leading zero in number')
    } else if (text.charCodeAt(index) >= 0x31 && text.charCodeAt(index) <= 0x39) {
      while (index < length && isDigit(text.charCodeAt(index))) index += 1
    } else {
      fail('bad number')
    }
    if (index < length && text.charCodeAt(index) === 0x2e) {
      index += 1
      if (index >= length || !isDigit(text.charCodeAt(index))) fail('bad fraction')
      while (index < length && isDigit(text.charCodeAt(index))) index += 1
    }
    if (index < length && (text.charCodeAt(index) === 0x65 || text.charCodeAt(index) === 0x45)) {
      index += 1
      if (index < length && (text.charCodeAt(index) === 0x2b || text.charCodeAt(index) === 0x2d)) index += 1
      if (index >= length || !isDigit(text.charCodeAt(index))) fail('bad exponent')
      while (index < length && isDigit(text.charCodeAt(index))) index += 1
    }
    const value = Number(text.slice(start, index))
    if (!Number.isFinite(value)) fail('number is not finite')
    return value
  }

  const parseValue = (depth) => {
    if (depth > MAX_DEPTH) fail('JSON nesting is too deep')
    skipWhitespace()
    if (index >= length) fail('unexpected end of input')
    const code = text.charCodeAt(index)
    if (code === 0x7b) return parseObject(depth)
    if (code === 0x5b) return parseArray(depth)
    if (code === 0x22) return parseString()
    if (code === 0x74) {
      if (text.slice(index, index + 4) !== 'true') fail('bad literal')
      index += 4
      return true
    }
    if (code === 0x66) {
      if (text.slice(index, index + 5) !== 'false') fail('bad literal')
      index += 5
      return false
    }
    if (code === 0x6e) {
      if (text.slice(index, index + 4) !== 'null') fail('bad literal')
      index += 4
      return null
    }
    if (code === 0x2d || isDigit(code)) return parseNumber()
    fail('unexpected token')
  }

  const parseArray = (depth) => {
    index += 1
    const out = []
    skipWhitespace()
    if (index < length && text.charCodeAt(index) === 0x5d) {
      index += 1
      return out
    }
    while (true) {
      out.push(parseValue(depth + 1))
      skipWhitespace()
      if (index >= length) fail('unterminated array')
      const code = text.charCodeAt(index)
      if (code === 0x2c) {
        index += 1
        skipWhitespace()
        if (index < length && text.charCodeAt(index) === 0x5d) fail('trailing comma')
        continue
      }
      if (code === 0x5d) {
        index += 1
        return out
      }
      fail('expected comma or closing bracket')
    }
  }

  const parseObject = (depth) => {
    if (depth > MAX_DEPTH) fail('JSON nesting is too deep')
    index += 1
    const out = Object.create(null)
    const keys = new Set()
    skipWhitespace()
    if (index < length && text.charCodeAt(index) === 0x7d) {
      index += 1
      return out
    }
    while (true) {
      skipWhitespace()
      if (index >= length) fail('unterminated object')
      if (text.charCodeAt(index) !== 0x22) fail('object member name must be a string')
      const key = parseString()
      if (keys.has(key)) fail(`duplicate member name ${JSON.stringify(key)}`)
      keys.add(key)
      skipWhitespace()
      if (index >= length || text.charCodeAt(index) !== 0x3a) fail('expected colon')
      index += 1
      out[key] = parseValue(depth + 1)
      skipWhitespace()
      if (index >= length) fail('unterminated object')
      const code = text.charCodeAt(index)
      if (code === 0x2c) {
        index += 1
        skipWhitespace()
        if (index < length && text.charCodeAt(index) === 0x7d) fail('trailing comma')
        continue
      }
      if (code === 0x7d) {
        index += 1
        return out
      }
      fail('expected comma or closing brace')
    }
  }

  const value = parseObject(0)
  if (index !== length) fail('trailing bytes')
  return value
}
