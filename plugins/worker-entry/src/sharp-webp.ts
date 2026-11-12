// SPDX-License-Identifier: MIT
/**
 * Pure-TypeScript WebP Lossless (`VP8L`, RFC 9649) encoder for the Worker-side
 * `sharp` shim.
 *
 * WebKit's `OffscreenCanvas.convertToBlob({ type: 'image/webp' })` has no
 * native WebP encoder on iOS/macOS and falls back to `image/png` per the HTML
 * Canvas specification. DSH's `attachment-local` routes every image with
 * `hasAlpha: true` (including `1920x1080` RGBA PNG screenshots from Android
 * `screencap -p` when downscaled for the model request budget) through
 * `.webp({ quality, effort: 0 })`.
 *
 * When `convertToBlob` falls back to `image/png`, `sharp-shim.ts` encodes the
 * canvas RGBA buffer into a single-frame `RIFF....WEBPVP8L` container using:
 *   1. `SUBTRACT_GREEN` transform (`R' = (R - G) & 0xff`, `B' = (B - G) & 0xff`),
 *   2. `PREDICTOR_TRANSFORM` (mode 1 = left-pixel predictor, top predictor on
 *      column 0),
 *   3. 2D backward-reference run-length encoding (RFC 9649 distance codes:
 *      0 = above, 1 = left) + canonical prefix coding.
 *
 * For the quality ladder (`[85, 75, 60]`), RGB residuals apply near-lossless
 * bit-depth quantization (`quantBits` 1..3) while keeping `lossless: true` and
 * `quality >= 95` bit-exact (`quantBits = 0`) and never quantizing the alpha
 * channel.
 * @module @phone-dsh/dsh-worker-entry/sharp-webp
 */
import { SharpEncoderOutputError } from './sharp-errors.ts'

/** Options accepted by the WebP encoder. */
export interface WebpEncodeOptions {
  quality?: number
  lossless?: boolean
}

const MAX_WEBP_DIMENSION = 16384
const MAX_PREFIX_BITS = 15
const CODE_LENGTH_ORDER = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] as const

function reverseBits(code: number, length: number): number {
  let out = 0
  for (let i = 0; i < length; i += 1) {
    out = (out << 1) | ((code >> i) & 1)
  }
  return out
}

interface HuffmanTree {
  readonly lengths: Uint8Array
  readonly active: readonly number[]
}

interface WeightedNode {
  sym: number
  weight: number
  left: number
  right: number
}

function buildHuffmanLengths(freqs: Uint32Array, maxLen: number = MAX_PREFIX_BITS): HuffmanTree {
  const n = freqs.length
  const lengths = new Uint8Array(n)
  const active: number[] = []
  for (let i = 0; i < n; i += 1) {
    if ((freqs[i] ?? 0) > 0) active.push(i)
  }
  if (active.length === 0) {
    lengths[0] = 1
    return { lengths, active: [0] }
  }
  if (active.length === 1) {
    const only = active[0] as number
    lengths[only] = 1
    return { lengths, active }
  }

  const pool: WeightedNode[] = active.map(sym => ({
    sym,
    weight: freqs[sym] ?? 0,
    left: -1,
    right: -1,
  }))
  const activeIndices = pool.map((_, index) => index)
  while (activeIndices.length > 1) {
    activeIndices.sort((a, b) => (pool[a]?.weight ?? 0) - (pool[b]?.weight ?? 0))
    const a = activeIndices.shift() as number
    const b = activeIndices.shift() as number
    const parent: WeightedNode = {
      sym: -1,
      weight: (pool[a]?.weight ?? 0) + (pool[b]?.weight ?? 0),
      left: a,
      right: b,
    }
    activeIndices.push(pool.length)
    pool.push(parent)
  }

  const rawLengths: { sym: number; len: number; weight: number }[] = []
  const walk = (idx: number, depth: number): void => {
    const node = pool[idx]
    if (node === undefined) return
    if (node.sym >= 0) {
      rawLengths.push({ sym: node.sym, len: depth, weight: node.weight })
    } else {
      walk(node.left, depth + 1)
      walk(node.right, depth + 1)
    }
  }
  walk(activeIndices[0] as number, 0)

  let maxObserved = 0
  for (const item of rawLengths) {
    if (item.len > maxObserved) maxObserved = item.len
  }
  if (maxObserved <= maxLen) {
    for (const item of rawLengths) lengths[item.sym] = item.len
    return { lengths, active }
  }

  rawLengths.sort((a, b) => b.weight - a.weight || a.sym - b.sym)
  for (const item of rawLengths) {
    item.len = Math.min(maxLen, Math.max(1, item.len))
  }
  const target = 1 << maxLen
  let kraft = 0
  for (const item of rawLengths) kraft += 1 << (maxLen - item.len)
  for (let i = rawLengths.length - 1; i >= 0 && kraft > target; i -= 1) {
    const item = rawLengths[i]
    if (item === undefined) continue
    while (item.len < maxLen && kraft > target) {
      kraft -= 1 << (maxLen - item.len - 1)
      item.len += 1
    }
  }
  for (let i = 0; i < rawLengths.length && kraft < target; i += 1) {
    const item = rawLengths[i]
    if (item === undefined) continue
    while (item.len > 1 && kraft + (1 << (maxLen - item.len)) <= target) {
      kraft += 1 << (maxLen - item.len)
      item.len -= 1
    }
  }
  for (const item of rawLengths) lengths[item.sym] = item.len
  return { lengths, active }
}

function buildCanonicalCodes(lengths: Uint8Array): Uint16Array {
  const blCount = new Int32Array(MAX_PREFIX_BITS + 1)
  for (let i = 0; i < lengths.length; i += 1) {
    const len = lengths[i] ?? 0
    if (len > 0) blCount[len] = (blCount[len] ?? 0) + 1
  }
  const nextCode = new Int32Array(MAX_PREFIX_BITS + 1)
  let code = 0
  for (let bits = 1; bits <= MAX_PREFIX_BITS; bits += 1) {
    code = (code + (blCount[bits - 1] ?? 0)) << 1
    nextCode[bits] = code
  }
  const codes = new Uint16Array(lengths.length)
  for (let i = 0; i < lengths.length; i += 1) {
    const len = lengths[i] ?? 0
    if (len > 0) {
      const assigned = nextCode[len] ?? 0
      nextCode[len] = assigned + 1
      codes[i] = reverseBits(assigned, len)
    }
  }
  return codes
}

class BitWriter {
  private buf: Uint8Array
  private bytePos = 0
  private bitBuf = 0
  private bitCount = 0

  constructor(initialBytes = 65536) {
    this.buf = new Uint8Array(Math.max(64, initialBytes))
  }

  private ensure(extraBytes: number): void {
    if (this.bytePos + extraBytes <= this.buf.length) return
    let nextLen = this.buf.length * 2
    while (nextLen < this.bytePos + extraBytes) nextLen *= 2
    const next = new Uint8Array(nextLen)
    next.set(this.buf)
    this.buf = next
  }

  writeBits(value: number, count: number): void {
    this.bitBuf |= (value & ((1 << count) - 1)) << this.bitCount
    this.bitCount += count
    if (this.bitCount >= 16) {
      this.ensure(4)
      while (this.bitCount >= 8) {
        this.buf[this.bytePos] = this.bitBuf & 0xff
        this.bytePos += 1
        this.bitBuf >>>= 8
        this.bitCount -= 8
      }
    }
  }

  finish(): Uint8Array {
    this.ensure(4)
    while (this.bitCount > 0) {
      this.buf[this.bytePos] = this.bitBuf & 0xff
      this.bytePos += 1
      this.bitBuf >>>= 8
      this.bitCount -= 8
    }
    return this.buf.subarray(0, this.bytePos)
  }
}

function writeSingleSymbolTree(bw: BitWriter, symbol: number): void {
  bw.writeBits(1, 1) // is_simple = 1
  bw.writeBits(0, 1) // num_symbols - 1 = 0
  if (symbol > 1) {
    bw.writeBits(1, 1) // is_first_8bits = 1
    bw.writeBits(symbol, 8)
  } else {
    bw.writeBits(0, 1) // is_first_8bits = 0
    bw.writeBits(symbol, 1)
  }
}

function writePrefixTree(bw: BitWriter, lengths: Uint8Array, active: readonly number[]): Uint16Array {
  if (active.length === 1 && (active[0] ?? 0) < 256) {
    writeSingleSymbolTree(bw, active[0] as number)
    return new Uint16Array(lengths.length)
  }
  if (active.length === 2 && (active[0] ?? 0) < 256 && (active[1] ?? 0) < 256) {
    const s0 = active[0] as number
    const s1 = active[1] as number
    bw.writeBits(1, 1) // is_simple = 1
    bw.writeBits(1, 1) // num_symbols - 1 = 1
    if (s0 > 1) {
      bw.writeBits(1, 1)
      bw.writeBits(s0, 8)
    } else {
      bw.writeBits(0, 1)
      bw.writeBits(s0, 1)
    }
    bw.writeBits(s1, 8)
    lengths.fill(0)
    lengths[s0] = 1
    lengths[s1] = 1
    const codes = new Uint16Array(lengths.length)
    codes[s0] = 0
    codes[s1] = 1
    return codes
  }

  bw.writeBits(0, 1) // is_simple = 0
  bw.writeBits(19 - 4, 4) // num_code_lengths = 19
  for (const sym of CODE_LENGTH_ORDER) {
    bw.writeBits(sym <= 15 ? 4 : 0, 3)
  }
  bw.writeBits(0, 1) // use_max_symbol = 0
  for (let i = 0; i < lengths.length; i += 1) {
    bw.writeBits(reverseBits(lengths[i] ?? 0, 4), 4)
  }
  return buildCanonicalCodes(lengths)
}

function lengthSlot(len: number): { sym: number; extraBits: number; extraVal: number } {
  if (len <= 4) {
    return { sym: 256 + (len - 1), extraBits: 0, extraVal: 0 }
  }
  const offset = len - 1
  const highestBit = 31 - Math.clz32(offset)
  const secondBit = (offset >> (highestBit - 1)) & 1
  const prefix = 2 * highestBit + secondBit
  const extraBits = highestBit - 1
  const extraVal = offset & ((1 << extraBits) - 1)
  return { sym: 256 + prefix, extraBits, extraVal }
}

function resolveQuantizationBits(options: WebpEncodeOptions): number {
  if (options.lossless === true) return 0
  const quality = options.quality ?? 85
  if (quality >= 95) return 0
  if (quality >= 80) return 1
  if (quality >= 70) return 2
  return 3
}

/**
 * Encode raw 8-bit sRGBA pixels into a single-frame `RIFF....WEBPVP8L` container.
 * @param rgba - row-major 4-channel RGBA pixels (`width * height * 4` bytes).
 * @param width - raster width in pixels (`1..16384`).
 * @param height - raster height in pixels (`1..16384`).
 * @param options - quality / lossless options from `.webp(options)`.
 * @returns complete WebP container bytes.
 */
export function encodeWebpLossless(
  rgba: Uint8Array | Uint8ClampedArray,
  width: number,
  height: number,
  options: WebpEncodeOptions = {},
): Uint8Array {
  if (
    !Number.isInteger(width)
    || !Number.isInteger(height)
    || width < 1
    || height < 1
    || width > MAX_WEBP_DIMENSION
    || height > MAX_WEBP_DIMENSION
  ) {
    throw new SharpEncoderOutputError(
      'sharp.webp',
      `invalid WebP dimensions ${String(width)}x${String(height)} (must be integers in 1..${String(MAX_WEBP_DIMENSION)})`,
    )
  }
  const numPixels = width * height
  if (rgba.byteLength !== numPixels * 4) {
    throw new SharpEncoderOutputError(
      'sharp.webp',
      `RGBA buffer length ${String(rgba.byteLength)} does not match ${String(width)}x${String(height)}x4`,
    )
  }

  const quantBits = resolveQuantizationBits(options)
  const mask = (0xff << quantBits) & 0xff
  let hasAlpha = false
  for (let i = 3; i < rgba.byteLength; i += 4) {
    if (rgba[i] !== 255) {
      hasAlpha = true
      break
    }
  }

  const curA = new Uint8Array(numPixels)
  const curR = new Uint8Array(numPixels)
  const curG = new Uint8Array(numPixels)
  const curB = new Uint8Array(numPixels)
  for (let i = 0, p = 0; i < numPixels; i += 1, p += 4) {
    const r = (rgba[p] ?? 0) & mask
    const g = (rgba[p + 1] ?? 0) & mask
    const b = (rgba[p + 2] ?? 0) & mask
    const a = hasAlpha ? (rgba[p + 3] ?? 255) : 255
    curA[i] = a
    curG[i] = g
    curR[i] = (r - g) & 0xff
    curB[i] = (b - g) & 0xff
  }

  const packed = new Uint32Array(numPixels)
  for (let y = 0; y < height; y += 1) {
    const rowOffset = y * width
    for (let x = 0; x < width; x += 1) {
      const i = rowOffset + x
      let predA: number
      let predR: number
      let predG: number
      let predB: number
      if (x === 0) {
        if (y === 0) {
          predA = 255
          predR = 0
          predG = 0
          predB = 0
        } else {
          const top = i - width
          predA = curA[top] ?? 255
          predR = curR[top] ?? 0
          predG = curG[top] ?? 0
          predB = curB[top] ?? 0
        }
      } else {
        const left = i - 1
        predA = curA[left] ?? 255
        predR = curR[left] ?? 0
        predG = curG[left] ?? 0
        predB = curB[left] ?? 0
      }
      const da = ((curA[i] ?? 255) - predA) & 0xff
      const dr = ((curR[i] ?? 0) - predR) & 0xff
      const dg = ((curG[i] ?? 0) - predG) & 0xff
      const db = ((curB[i] ?? 0) - predB) & 0xff
      packed[i] = ((da << 24) | (dr << 16) | (dg << 8) | db) >>> 0
    }
  }

  const gFreq = new Uint32Array(280)
  const rFreq = new Uint32Array(256)
  const bFreq = new Uint32Array(256)
  const aFreq = new Uint32Array(256)
  const dFreq = new Uint32Array(40)

  const tokens = new Int32Array(numPixels)
  let tokenCount = 0

  let i = 0
  while (i < numPixels) {
    const px = packed[i] ?? 0
    let runLeft = 0
    if (i > 0 && packed[i - 1] === px) {
      const maxRun = Math.min(4096, numPixels - i)
      while (runLeft < maxRun && packed[i + runLeft] === packed[i + runLeft - 1]) {
        runLeft += 1
      }
    }
    let runAbove = 0
    if (i >= width && packed[i - width] === px) {
      const maxRun = Math.min(4096, numPixels - i)
      while (runAbove < maxRun && packed[i + runAbove] === packed[i + runAbove - width]) {
        runAbove += 1
      }
    }

    if (runLeft >= 2 || runAbove >= 2) {
      const useLeft = runLeft >= runAbove
      const len = useLeft ? runLeft : runAbove
      const distSym = useLeft ? 1 : 0
      tokens[tokenCount] = -((len << 1) | distSym)
      tokenCount += 1
      const slot = lengthSlot(len)
      gFreq[slot.sym] = (gFreq[slot.sym] ?? 0) + 1
      dFreq[distSym] = (dFreq[distSym] ?? 0) + 1
      i += len
    } else {
      tokens[tokenCount] = i
      tokenCount += 1
      const g = (px >>> 8) & 0xff
      const r = (px >>> 16) & 0xff
      const b = px & 0xff
      const a = px >>> 24
      gFreq[g] = (gFreq[g] ?? 0) + 1
      rFreq[r] = (rFreq[r] ?? 0) + 1
      bFreq[b] = (bFreq[b] ?? 0) + 1
      aFreq[a] = (aFreq[a] ?? 0) + 1
      i += 1
    }
  }

  const gTree = buildHuffmanLengths(gFreq)
  const rTree = buildHuffmanLengths(rFreq)
  const bTree = buildHuffmanLengths(bFreq)
  const aTree = buildHuffmanLengths(aFreq)
  const dTree = buildHuffmanLengths(dFreq)

  const bw = new BitWriter(numPixels)
  // Transform 1: SUBTRACT_GREEN (2)
  bw.writeBits(1, 1)
  bw.writeBits(2, 2)
  // Transform 2: PREDICTOR_TRANSFORM (0) with size_bits = 4 (4 - 2 = 2)
  bw.writeBits(1, 1)
  bw.writeBits(0, 2)
  bw.writeBits(4 - 2, 3)
  // Predictor sub-image: constant mode 1 (Left predictor), no color cache
  bw.writeBits(0, 1)
  writeSingleSymbolTree(bw, 1)   // Green = 1 (Left predictor)
  writeSingleSymbolTree(bw, 0)   // Red = 0
  writeSingleSymbolTree(bw, 0)   // Blue = 0
  writeSingleSymbolTree(bw, 255) // Alpha = 255
  writeSingleSymbolTree(bw, 0)   // Distance = 0
  // End of transforms
  bw.writeBits(0, 1)

  // Main image: color_cache = 0, meta_prefix = 0
  bw.writeBits(0, 1)
  bw.writeBits(0, 1)

  const gCodes = writePrefixTree(bw, gTree.lengths, gTree.active)
  const rCodes = writePrefixTree(bw, rTree.lengths, rTree.active)
  const bCodes = writePrefixTree(bw, bTree.lengths, bTree.active)
  const aCodes = writePrefixTree(bw, aTree.lengths, aTree.active)
  const dCodes = writePrefixTree(bw, dTree.lengths, dTree.active)

  const gLen = gTree.lengths
  const rLen = rTree.lengths
  const bLen = bTree.lengths
  const aLen = aTree.lengths
  const dLen = dTree.lengths

  const singleG = gTree.active.length === 1 && (gTree.active[0] ?? 0) < 256
  const singleR = rTree.active.length === 1 && (rTree.active[0] ?? 0) < 256
  const singleB = bTree.active.length === 1 && (bTree.active[0] ?? 0) < 256
  const singleA = aTree.active.length === 1 && (aTree.active[0] ?? 0) < 256
  const singleD = dTree.active.length === 1 && (dTree.active[0] ?? 0) < 256

  for (let t = 0; t < tokenCount; t += 1) {
    const tok = tokens[t] ?? 0
    if (tok >= 0) {
      const px = packed[tok] ?? 0
      const g = (px >>> 8) & 0xff
      const r = (px >>> 16) & 0xff
      const b = px & 0xff
      const a = px >>> 24
      if (!singleG) bw.writeBits(gCodes[g] ?? 0, gLen[g] ?? 0)
      if (!singleR) bw.writeBits(rCodes[r] ?? 0, rLen[r] ?? 0)
      if (!singleB) bw.writeBits(bCodes[b] ?? 0, bLen[b] ?? 0)
      if (!singleA) bw.writeBits(aCodes[a] ?? 0, aLen[a] ?? 0)
    } else {
      const val = -tok
      const len = val >>> 1
      const distSym = val & 1
      const slot = lengthSlot(len)
      if (!singleG) bw.writeBits(gCodes[slot.sym] ?? 0, gLen[slot.sym] ?? 0)
      if (slot.extraBits > 0) bw.writeBits(slot.extraVal, slot.extraBits)
      if (!singleD) bw.writeBits(dCodes[distSym] ?? 0, dLen[distSym] ?? 0)
    }
  }

  const stream = bw.finish()
  const vp8lSize = 5 + stream.byteLength
  const pad = vp8lSize & 1
  const riffSize = 4 + 8 + vp8lSize + pad
  const out = new Uint8Array(8 + riffSize)
  const view = new DataView(out.buffer)
  out.set([0x52, 0x49, 0x46, 0x46], 0) // 'RIFF'
  view.setUint32(4, riffSize, true)
  out.set([0x57, 0x45, 0x42, 0x50], 8) // 'WEBP'
  out.set([0x56, 0x50, 0x38, 0x4c], 12) // 'VP8L'
  view.setUint32(16, vp8lSize, true)
  out[20] = 0x2f // VP8L signature
  const headerBits = ((width - 1) & 0x3fff) | (((height - 1) & 0x3fff) << 14) | ((hasAlpha ? 1 : 0) << 28)
  view.setUint32(21, headerBits >>> 0, true)
  out.set(stream, 25)
  return out
}
