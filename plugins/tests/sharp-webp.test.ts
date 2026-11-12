// SPDX-License-Identifier: MIT
/**
 * VP8L encoder regression: a golden lock on the bitstream plus a real decode.
 *
 * The golden hashes below were produced by this encoder and decoded
 * pixel-exact with libwebp (Pillow 12.1.1) on 2026-11-12. They cover the paths
 * the container-only assertions in sharp-shim.test.ts cannot see: vertical
 * runs, a full 4096-pixel run, a deep Huffman tree, alpha, and the
 * 1764x992 screenshot shape DSH sends to the model.
 *
 * When a native `sharp` (libwebp) happens to be installed the test also decodes
 * every vector and compares the RGBA bytes. Without it the hashes still fail
 * any change to the emitted bitstream; the module never depends on native sharp
 * at runtime.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { parseImageMetadata } from '../worker-entry/src/sharp-metadata.ts'
import { encodeWebpLossless } from '../worker-entry/src/sharp-webp.ts'

interface Vector {
  name: string
  width: number
  height: number
  bytes: number
  sha256: string
  pixel?: (x: number, y: number) => [number, number, number, number]
  build?: () => Uint8Array
}

/**
 * A 20-symbol Fibonacci histogram (raw Huffman depth 19) over a 4096x5 raster.
 * VP8L caps prefix lengths at 15, so this vector is the encoder's
 * length-limiting path; libwebp decodes it pixel-exact.
 */
function fibonacciRaster(): Uint8Array {
  const weights = [1, 1]
  while (weights.length < 20) {
    weights.push((weights[weights.length - 1] ?? 0) + (weights[weights.length - 2] ?? 0))
  }
  const symbols: number[] = []
  for (let s = 0; s < weights.length; s += 1) {
    for (let n = 0; n < (weights[s] ?? 0); n += 1) symbols.push(s)
  }
  let seed = 424242
  for (let i = symbols.length - 1; i > 0; i -= 1) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    const j = seed % (i + 1)
    const swap = symbols[i] as number
    symbols[i] = symbols[j] as number
    symbols[j] = swap
  }
  const width = 4096
  const height = 5
  const data = new Uint8Array(width * height * 4)
  let green = 0
  for (let i = 0; i < width * height; i += 1) {
    green = (green + (symbols[i] ?? 0)) & 0xff
    data[i * 4] = green
    data[i * 4 + 1] = green
    data[i * 4 + 2] = green
    data[i * 4 + 3] = 255
  }
  return data
}

function raster(vector: Vector): Uint8Array {
  if (vector.build !== undefined) return vector.build()
  const pixel = vector.pixel as (x: number, y: number) => [number, number, number, number]
  const data = new Uint8Array(vector.width * vector.height * 4)
  for (let y = 0; y < vector.height; y += 1) {
    for (let x = 0; x < vector.width; x += 1) {
      const [r, g, b, a] = pixel(x, y)
      const index = (y * vector.width + x) * 4
      data[index] = r
      data[index + 1] = g
      data[index + 2] = b
      data[index + 3] = a
    }
  }
  return data
}

function noise(): (x: number, y: number) => [number, number, number, number] {
  let seed = 987654321
  const next = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return seed & 0xff
  }
  return () => [next(), next(), next(), 255]
}

const VECTORS: Vector[] = [
  {
    name: 'vertical run 8x64',
    width: 8,
    height: 64,
    bytes: 322,
    sha256: '5b8300e95a9b4c30f0a8edbf51936043fd2fa9f6afba35c2694c32e3d593bcc5',
    pixel: x => [x * 30, x * 7, 255 - x * 4, 255],
  },
  {
    name: 'single 4096 run 64x64',
    width: 64,
    height: 64,
    bytes: 186,
    sha256: '975cd5ce777a454a58c9b04b64c0c62ba3f5330112128438d36d7a008f8a1c42',
    pixel: () => [10, 20, 30, 255],
  },
  {
    name: 'deep Huffman noise 101x37',
    width: 101,
    height: 37,
    bytes: 3908,
    sha256: '5c08010678b60bb61fba30ae5e41869a7fbdab380d9a85cb821beaedd771ea6b',
    pixel: noise(),
  },
  {
    name: 'alpha gradient 77x53',
    width: 77,
    height: 53,
    bytes: 746,
    sha256: '0fa45e7afd23eb41247405ae02838cafcfb9a45bf873abc66f6432b2f4feec62',
    pixel: (x, y) => [x & 255, y & 255, (x * y) & 255, (x * 3) & 255],
  },
  {
    name: 'fibonacci 15-bit cap 4096x5',
    width: 4096,
    height: 5,
    bytes: 6258,
    sha256: '4036d92310e4af7baa7bdafd5a385511b4c74d9f12bba67bc81ee1db2afb6ebb',
    build: fibonacciRaster,
  },
  {
    name: 'screenshot 1764x992',
    width: 1764,
    height: 992,
    bytes: 1256,
    sha256: 'da82639a4bcd10e7c7f3bfc48c82d88cae0a18fc7ec538f6ede0d7a78ac53891',
    pixel: (x, y) => {
      const band = y < 120 ? 20 : y < 240 ? 240 : (x >> 4) & 1 ? 33 : 221
      return [band, (x + y) & 255, band ^ 0x55, 255]
    },
  },
]

test('VP8L bitstream stays byte-identical to the decoded golden', () => {
  for (const vector of VECTORS) {
    const rgba = raster(vector)
    const webp = encodeWebpLossless(rgba, vector.width, vector.height, { lossless: true })
    const digest = createHash('sha256').update(webp).digest('hex')
    assert.equal(webp.byteLength, vector.bytes, `${vector.name}: encoded size`)
    assert.equal(digest, vector.sha256, `${vector.name}: bitstream digest`)
    const facts = parseImageMetadata(webp)
    assert.equal(facts.format, 'webp', `${vector.name}: container`)
    assert.deepEqual({ width: facts.width, height: facts.height },
      { width: vector.width, height: vector.height }, `${vector.name}: dimensions`)
  }
})

test('VP8L output decodes pixel-exact with libwebp', async t => {
  // Not a declared dependency: the Worker must never need native sharp. When a
  // dev checkout happens to have it, decode through libwebp and compare pixels.
  const specifier: string = 'sharp'
  const nativeSharp = await import(specifier).then(module => module.default ?? module).catch(() => null)
  if (nativeSharp === null) {
    t.diagnostic('native sharp is not installed; the golden hashes still lock the bitstream')
    return
  }
  {
    for (const vector of VECTORS) {
      const rgba = raster(vector)
      const webp = encodeWebpLossless(rgba, vector.width, vector.height, { lossless: true })
      const decoded = await (nativeSharp as (input: Uint8Array) => any)(Buffer.from(webp))
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true })
      assert.equal(decoded.info.width, vector.width, `${vector.name}: decoded width`)
      assert.equal(decoded.info.height, vector.height, `${vector.name}: decoded height`)
      assert.deepEqual(Buffer.from(decoded.data), Buffer.from(rgba), `${vector.name}: decoded pixels`)
    }
  }
})
