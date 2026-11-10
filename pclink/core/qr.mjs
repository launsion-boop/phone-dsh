/**
 * Dependency-free QR Code encoder (Byte mode, ECC M) and terminal renderer.
 *
 * The PCLink pairing payload is a UTF-8 `pclink://pair?...` URI. This module
 * encodes it as QR Code Model 2, byte mode, error-correction level M, choosing
 * the smallest version that fits (1..40). The matrix follows ISO/IEC 18004:
 * finder/alignment/timing patterns, BCH format/version information, Reed-Solomon
 * ECC over GF(256), the eight data masks, and the standard penalty score.
 *
 * The renderer uses Unicode half blocks with a four-module quiet zone. ANSI
 * 256-colour escapes make the quiet zone white and the modules black regardless
 * of the terminal theme; callers that do not want escapes can use the plain
 * black-on-light form (e.g. redirected output).
 */

const ECC_FORMAT_BITS = Object.freeze({ L: 1, M: 0, Q: 3, H: 2 })
const ECC_CODEWORDS_PER_BLOCK = Object.freeze({
  // Index 0 is unused padding; version numbers are 1..40.
  L: [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  M: [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  Q: [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  H: [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
})
const NUM_ERROR_CORRECTION_BLOCKS = Object.freeze({
  L: [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  M: [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  Q: [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  H: [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
})
const PENALTY_N1 = 3
const PENALTY_N2 = 3
const PENALTY_N3 = 40
const PENALTY_N4 = 10
const MAX_VERSION = 40

/** Growable MSB-first bit buffer. */
class BitBuffer {
  constructor() {
    this.bits = []
  }

  /** Append `length` bits of `value`, most significant first. */
  append(value, length) {
    for (let i = length - 1; i >= 0; i -= 1) this.bits.push((value >>> i) & 1)
  }

  get length() {
    return this.bits.length
  }

  /** True when bit `index` is set. */
  bit(index) {
    return this.bits[index] === 1
  }
}

/**
 * Number of data modules available to codewords (ISO/IEC 18004 §7.3.1).
 * @param {number} version Version 1..40.
 * @returns {number} raw data module count.
 */
export function getNumRawDataModules(version) {
  if (!Number.isInteger(version) || version < 1 || version > MAX_VERSION) throw new RangeError('QR version must be 1..40')
  let result = (16 * version + 128) * version + 64
  if (version >= 2) {
    const numAlign = Math.floor(version / 7) + 2
    result -= (25 * numAlign - 10) * numAlign - 55
    if (version >= 7) result -= 36
  }
  return result
}

/**
 * Number of data codewords for one version and ECC level.
 * @param {number} version Version 1..40.
 * @param {'L'|'M'|'Q'|'H'} ecc ECC level.
 * @returns {number} data codewords.
 */
export function getNumDataCodewords(version, ecc) {
  if (!Object.hasOwn(ECC_CODEWORDS_PER_BLOCK, ecc)) throw new RangeError(`unknown QR ECC level ${String(ecc)}`)
  return Math.floor(getNumRawDataModules(version) / 8)
    - ECC_CODEWORDS_PER_BLOCK[ecc][version] * NUM_ERROR_CORRECTION_BLOCKS[ecc][version]
}

/** Byte-mode character-count bits by version. */
function charCountBits(version) {
  return version <= 9 ? 8 : 16
}

/** Choose the smallest version that fits a byte payload. */
function chooseVersion(byteLength, ecc) {
  for (let version = 1; version <= MAX_VERSION; version += 1) {
    const capacity = getNumDataCodewords(version, ecc) * 8
    if (4 + charCountBits(version) + byteLength * 8 <= capacity) return version
  }
  throw new RangeError(`payload of ${String(byteLength)} bytes is too large for a QR code with ECC ${ecc}`)
}

/** Multiply two GF(256) elements modulo x^8 + x^4 + x^3 + x^2 + 1. */
function gfMultiply(left, right) {
  let result = 0
  let a = left
  let b = right
  for (let i = 0; i < 8; i += 1) {
    if ((b & 1) !== 0) result ^= a
    const carry = (a & 0x80) !== 0
    a = (a << 1) & 0xff
    if (carry) a ^= 0x1d
    b >>>= 1
  }
  return result
}

/** Reed-Solomon generator polynomial for `degree` ECC codewords. */
function rsDivisor(degree) {
  const result = new Uint8Array(degree)
  result[degree - 1] = 1
  let root = 1
  for (let i = 0; i < degree; i += 1) {
    for (let j = 0; j < degree; j += 1) {
      result[j] = gfMultiply(result[j], root)
      if (j + 1 < degree) result[j] ^= result[j + 1]
    }
    root = gfMultiply(root, 0x02)
  }
  return result
}

/** Remainder of `data * x^degree` divided by the generator polynomial. */
function rsRemainder(data, divisor) {
  const result = new Uint8Array(divisor.length)
  for (const byte of data) {
    const factor = byte ^ result[0]
    result.copyWithin(0, 1)
    result[result.length - 1] = 0
    for (let i = 0; i < result.length; i += 1) result[i] ^= gfMultiply(divisor[i], factor)
  }
  return result
}

/** Split data codewords into blocks, append ECC, and interleave. */
function addEccAndInterleave(data, version, ecc) {
  const numBlocks = NUM_ERROR_CORRECTION_BLOCKS[ecc][version]
  const blockEccLen = ECC_CODEWORDS_PER_BLOCK[ecc][version]
  const rawCodewords = Math.floor(getNumRawDataModules(version) / 8)
  const numShortBlocks = numBlocks - (rawCodewords % numBlocks)
  const shortBlockLen = Math.floor(rawCodewords / numBlocks)
  const divisor = rsDivisor(blockEccLen)
  const blocks = []
  for (let i = 0, offset = 0; i < numBlocks; i += 1) {
    const dataLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1)
    const dat = Array.from(data.slice(offset, offset + dataLen))
    offset += dataLen
    const eccBytes = rsRemainder(dat, divisor)
    if (i < numShortBlocks) dat.push(0)
    blocks.push([...dat, ...eccBytes])
  }
  const result = []
  for (let i = 0; i < blocks[0].length; i += 1) {
    for (let j = 0; j < blocks.length; j += 1) {
      if (i !== shortBlockLen - blockEccLen || j >= numShortBlocks) result.push(blocks[j][i])
    }
  }
  return result
}

/** Encode a byte payload into interleaved codewords. */
function encodeCodewords(bytes, version, ecc) {
  const capacityBits = getNumDataCodewords(version, ecc) * 8
  const bits = new BitBuffer()
  bits.append(0b0100, 4) // byte mode
  bits.append(bytes.length, charCountBits(version))
  for (const byte of bytes) bits.append(byte, 8)
  const terminator = Math.min(4, capacityBits - bits.length)
  bits.append(0, terminator)
  while (bits.length % 8 !== 0) bits.append(0, 1)
  const data = []
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0
    for (let j = 0; j < 8; j += 1) byte = (byte << 1) | (bits.bit(i + j) ? 1 : 0)
    data.push(byte)
  }
  for (let pad = 0xec; data.length < getNumDataCodewords(version, ecc); pad ^= 0xec ^ 0x11) data.push(pad)
  return addEccAndInterleave(data, version, ecc)
}

/** Create an empty function-module map for one version. */
function emptyMatrix(size) {
  const modules = Array.from({ length: size }, () => Array(size).fill(false))
  const isFunction = Array.from({ length: size }, () => Array(size).fill(false))
  const set = (x, y, dark, isFn = true) => {
    if (x < 0 || x >= size || y < 0 || y >= size) return
    modules[y][x] = dark
    if (isFn) isFunction[y][x] = true
  }
  return { modules, isFunction, set }
}

/** Draw a 7x7 finder pattern centred at (x, y), including its separator. */
function drawFinder(set, centerX, centerY) {
  for (let dy = -4; dy <= 4; dy += 1) {
    for (let dx = -4; dx <= 4; dx += 1) {
      const distance = Math.max(Math.abs(dx), Math.abs(dy))
      set(centerX + dx, centerY + dy, distance !== 2 && distance !== 4)
    }
  }
}

/** Draw a 5x5 alignment pattern centred at (x, y). */
function drawAlignment(set, centerX, centerY) {
  for (let dy = -2; dy <= 2; dy += 1) {
    for (let dx = -2; dx <= 2; dx += 1) {
      set(centerX + dx, centerY + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1)
    }
  }
}

/** Alignment-pattern centre coordinates for one version. */
function alignmentPositions(version, size) {
  if (version === 1) return []
  const count = Math.floor(version / 7) + 2
  const step = version === 32 ? 26 : Math.ceil((version * 4 + 4) / (count * 2 - 2)) * 2
  const result = [6]
  for (let pos = size - 7; result.length < count; pos -= step) result.splice(1, 0, pos)
  return result
}

/** Draw all function patterns and provisional format bits (mask 0). */
function drawFunctionPatterns(modules, isFunction, set, version, ecc) {
  const size = modules.length
  for (let i = 0; i < size; i += 1) {
    set(6, i, i % 2 === 0)
    set(i, 6, i % 2 === 0)
  }
  drawFinder(set, 3, 3)
  drawFinder(set, size - 4, 3)
  drawFinder(set, 3, size - 4)
  const positions = alignmentPositions(version, size)
  for (let i = 0; i < positions.length; i += 1) {
    for (let j = 0; j < positions.length; j += 1) {
      if ((i === 0 && j === 0) || (i === 0 && j === positions.length - 1) || (i === positions.length - 1 && j === 0)) continue
      drawAlignment(set, positions[i], positions[j])
    }
  }
  drawFormatBits(set, size, ecc, 0)
  drawVersionBits(set, size, version)
}

/** BCH(15,5) format information for ECC level and mask. */
function formatBits(ecc, mask) {
  const data = (ECC_FORMAT_BITS[ecc] << 3) | mask
  let remainder = data
  for (let i = 0; i < 10; i += 1) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537)
  return ((data << 10) | remainder) ^ 0x5412
}

/** BCH(18,6) version information for versions 7..40. */
function versionBits(version) {
  let remainder = version
  for (let i = 0; i < 12; i += 1) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25)
  return (version << 12) | remainder
}

function getBit(value, index) {
  return ((value >>> index) & 1) !== 0
}

/** Draw both copies of the format information. */
function drawFormatBits(set, size, ecc, mask) {
  const bits = formatBits(ecc, mask)
  for (let i = 0; i <= 5; i += 1) set(8, i, getBit(bits, i))
  set(8, 7, getBit(bits, 6))
  set(8, 8, getBit(bits, 7))
  set(7, 8, getBit(bits, 8))
  for (let i = 9; i < 15; i += 1) set(14 - i, 8, getBit(bits, i))
  for (let i = 0; i < 8; i += 1) set(size - 1 - i, 8, getBit(bits, i))
  for (let i = 8; i < 15; i += 1) set(8, size - 15 + i, getBit(bits, i))
  set(8, size - 8, true)
}

/** Draw both copies of the version information (versions 7+). */
function drawVersionBits(set, size, version) {
  if (version < 7) return
  const bits = versionBits(version)
  for (let i = 0; i < 18; i += 1) {
    const bit = getBit(bits, i)
    const a = size - 11 + (i % 3)
    const b = Math.floor(i / 3)
    set(a, b, bit)
    set(b, a, bit)
  }
}

/** True when mask `mask` flips module (x, y). */
export function maskBit(mask, x, y) {
  switch (mask) {
    case 0: return (x + y) % 2 === 0
    case 1: return y % 2 === 0
    case 2: return x % 3 === 0
    case 3: return (x + y) % 3 === 0
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0
    case 5: return ((x * y) % 2) + ((x * y) % 3) === 0
    case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0
    case 7: return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
    default: throw new RangeError(`QR mask must be 0..7, got ${String(mask)}`)
  }
}

/** Place the data codewords in the two-column zigzag, skipping function modules. */
function drawCodewords(modules, isFunction, codewords) {
  const size = modules.length
  let index = 0
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5
    for (let vertical = 0; vertical < size; vertical += 1) {
      for (let offset = 0; offset < 2; offset += 1) {
        const x = right - offset
        const upward = ((right + 1) & 2) === 0
        const y = upward ? size - 1 - vertical : vertical
        if (!isFunction[y][x] && index < codewords.length * 8) {
          modules[y][x] = getBit(codewords[index >>> 3], 7 - (index & 7))
          index += 1
        }
      }
    }
  }
}

/** Apply one mask to all non-function modules. */
function applyMask(modules, isFunction, mask) {
  const size = modules.length
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      if (!isFunction[y][x] && maskBit(mask, x, y)) modules[y][x] = !modules[y][x]
    }
  }
}

/** Penalty rule 1: runs of five or more same-colour modules in rows/columns. */
function penaltyRuns(modules) {
  const size = modules.length
  let result = 0
  for (let y = 0; y < size; y += 1) {
    let run = 1
    for (let x = 1; x <= size; x += 1) {
      if (x < size && modules[y][x] === modules[y][x - 1]) {
        run += 1
      } else {
        if (run >= 5) result += PENALTY_N1 + (run - 5)
        run = 1
      }
    }
  }
  for (let x = 0; x < size; x += 1) {
    let run = 1
    for (let y = 1; y <= size; y += 1) {
      if (y < size && modules[y][x] === modules[y - 1][x]) {
        run += 1
      } else {
        if (run >= 5) result += PENALTY_N1 + (run - 5)
        run = 1
      }
    }
  }
  return result
}

/** Penalty rule 2: 2x2 blocks of the same colour. */
function penaltyBlocks(modules) {
  const size = modules.length
  let result = 0
  for (let y = 0; y < size - 1; y += 1) {
    for (let x = 0; x < size - 1; x += 1) {
      const colour = modules[y][x]
      if (colour === modules[y][x + 1] && colour === modules[y + 1][x] && colour === modules[y + 1][x + 1]) result += PENALTY_N2
    }
  }
  return result
}

/** Penalty rule 3: 1:1:3:1:1 finder-like patterns with four light modules. */
function penaltyFinderPatterns(modules) {
  const size = modules.length
  const patterns = ['10111010000', '00001011101']
  let result = 0
  const matches = (get) => {
    let line = ''
    for (let i = 0; i < size; i += 1) line += get(i) ? '1' : '0'
    for (let i = 0; i + 11 <= size; i += 1) {
      const window = line.slice(i, i + 11)
      if (patterns.includes(window)) result += PENALTY_N3
    }
  }
  for (let y = 0; y < size; y += 1) matches(x => modules[y][x])
  for (let x = 0; x < size; x += 1) matches(y => modules[y][x])
  return result
}

/** Penalty rule 4: deviation from a 50/50 dark-light balance in 5% steps. */
function penaltyBalance(modules) {
  const size = modules.length
  let dark = 0
  for (const row of modules) for (const cell of row) if (cell) dark += 1
  const total = size * size
  const ratio = Math.abs(dark * 20 - total * 10) / total
  return Math.floor(ratio) * PENALTY_N4
}

/** Total mask-evaluation penalty. */
export function penaltyScore(modules) {
  return penaltyRuns(modules) + penaltyBlocks(modules) + penaltyFinderPatterns(modules) + penaltyBalance(modules)
}

/** Build the final matrix for a version, ECC level and mask. */
function buildMatrix(version, ecc, mask, codewords) {
  const size = version * 4 + 17
  const { modules, isFunction, set } = emptyMatrix(size)
  drawFunctionPatterns(modules, isFunction, set, version, ecc)
  drawCodewords(modules, isFunction, codewords)
  applyMask(modules, isFunction, mask)
  // The format bits depend on the mask and are not part of the data mask.
  drawFormatBits(set, size, ecc, mask)
  return modules
}

/**
 * Encode bytes as a QR Code (Model 2, byte mode).
 * @param {Uint8Array|Buffer|string} input UTF-8 text or raw bytes.
 * @param {{ecc?: 'L'|'M'|'Q'|'H', version?: number|'auto', mask?: number|'auto'}} [options] Encoding options.
 * @returns {{version: number, size: number, ecc: string, mask: number, modules: boolean[][]}} encoded symbol.
 */
export function encodeQr(input, options = {}) {
  const ecc = options.ecc ?? 'M'
  if (!Object.hasOwn(ECC_CODEWORDS_PER_BLOCK, ecc)) throw new RangeError(`unknown QR ECC level ${String(ecc)}`)
  const bytes = typeof input === 'string' ? Buffer.from(input, 'utf8') : Buffer.from(input)
  let version = options.version ?? 'auto'
  if (version === 'auto') version = chooseVersion(bytes.length, ecc)
  else {
    if (!Number.isInteger(version) || version < 1 || version > MAX_VERSION) throw new RangeError('QR version must be 1..40 or "auto"')
    const capacity = getNumDataCodewords(version, ecc) * 8
    if (4 + charCountBits(version) + bytes.length * 8 > capacity) throw new RangeError(`payload does not fit QR version ${String(version)} with ECC ${ecc}`)
  }
  const codewords = encodeCodewords(bytes, version, ecc)
  let mask = options.mask ?? 'auto'
  let modules
  if (mask === 'auto') {
    let bestMask = 0
    let bestScore = Number.POSITIVE_INFINITY
    for (let candidate = 0; candidate < 8; candidate += 1) {
      const candidateModules = buildMatrix(version, ecc, candidate, codewords)
      const score = penaltyScore(candidateModules)
      if (score < bestScore) {
        bestScore = score
        bestMask = candidate
        modules = candidateModules
      }
    }
    mask = bestMask
  } else {
    if (!Number.isInteger(mask) || mask < 0 || mask > 7) throw new RangeError('QR mask must be 0..7 or "auto"')
    modules = buildMatrix(version, ecc, mask, codewords)
  }
  return { version, size: modules.length, ecc, mask, modules }
}

/** Convenience: encode text and return just the matrix. */
export function encodeQrText(text, options = {}) {
  return encodeQr(text, options).modules
}

/**
 * Render a matrix as Unicode half blocks.
 *
 * With `ansi: true` each cell gets a 256-colour foreground (upper half) and
 * background (lower half), so dark modules stay dark and the quiet zone stays
 * white on both light and dark terminals. With `ansi: false` the output assumes
 * dark ink on a light background: `█`, `▀`, `▄` and space.
 * @param {boolean[][]} modules Square QR matrix.
 * @param {{quietZone?: number, ansi?: boolean}} [options] Render options.
 * @returns {string} terminal text ending in a newline.
 */
export function renderQrUnicode(modules, options = {}) {
  const quietZone = options.quietZone ?? 4
  const ansi = options.ansi ?? true
  if (!Number.isInteger(quietZone) || quietZone < 0) throw new RangeError('quiet zone must be a non-negative integer')
  const sourceSize = modules.length
  if (sourceSize === 0 || modules.some(row => row.length !== sourceSize)) throw new RangeError('QR matrix must be square')
  const size = sourceSize + quietZone * 2
  const dark = (x, y) => {
    const sx = x - quietZone
    const sy = y - quietZone
    if (sx < 0 || sy < 0 || sx >= sourceSize || sy >= sourceSize) return false
    return modules[sy][sx] === true
  }
  let output = ''
  for (let y = 0; y < size; y += 2) {
    for (let x = 0; x < size; x += 1) {
      const top = dark(x, y)
      const bottom = y + 1 < size ? dark(x, y + 1) : false
      if (ansi) {
        output += `\x1b[38;5;${top ? 16 : 231};48;5;${bottom ? 16 : 231}m▀`
      } else if (top && bottom) output += '█'
      else if (top) output += '▀'
      else if (bottom) output += '▄'
      else output += ' '
    }
    output += ansi ? '\x1b[0m\n' : '\n'
  }
  return output
}

/** Encode and render in one call. */
export function renderQr(text, options = {}) {
  const encoded = encodeQr(text, options)
  return { ...encoded, text: renderQrUnicode(encoded.modules, options) }
}
