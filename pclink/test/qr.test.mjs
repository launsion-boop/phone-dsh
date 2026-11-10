/** Dependency-free QR encoder/renderer regressions (Byte mode, ECC M). */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import {
  encodeQr,
  getNumDataCodewords,
  encodeQrText,
  maskBit,
  penaltyScore,
  renderQrUnicode,
} from '../core/qr.mjs'

// Reference: Python `qrcode` 8.x, byte mode forced, ECC M, version 1, border 0,
// mask 5, standard penalty scoring. Pinned module-for-module so a table,
// Reed-Solomon, placement, mask or format-bit regression cannot hide behind a
// "valid-looking" matrix. Mask choice itself is implementation-defined among
// the eight valid masks (penalty evaluation may include or exclude the format
// area), so the module comparison fixes the mask explicitly. The long pclink
// URI below is pinned by SHA-256 at version 9, mask 6, against the same
// independent implementation.
const V1_M_MASK5 = [
  '111111100011001111111',
  '100000101001101000001',
  '101110101010101011101',
  '101110101110001011101',
  '101110100011101011101',
  '100000100100101000001',
  '111111101010101111111',
  '000000001011100000000',
  '100000101010111001110',
  '111100011100111100110',
  '010101110111011101100',
  '010010000010000010100',
  '001100101010011010011',
  '000000001101111110111',
  '111111100010101100000',
  '100000100111110110101',
  '101110100000100001001',
  '101110100000100110100',
  '101110100100001110011',
  '100000100110000000100',
  '111111101111010001010',
]

const LONG_URI = 'pclink://pair?v=1&r=https%3A%2F%2Fpclink-staging.tonoai.cn&m=eknzcuqiffucs5wg6w63csu4qk&k=WTeP2TMD29IQh5XJ2L43cDiG82Iq8PUsNMxf8lqcRIY&s=EOoyAcuT2Gwyc316wqR9qQ&n=My%20MacBook%20Pro'
const LONG_URI_MATRIX_SHA256 = '520fe2edc0ae73db24e47e960171e6706be83f1aa69b1738841573382dd9d5ea'

test('QR byte mode v1-M matches the pinned independent reference matrix', () => {
  const encoded = encodeQr('01234567', { version: 1, ecc: 'M', mask: 5 })
  assert.equal(encoded.version, 1)
  assert.equal(encoded.size, 21)
  assert.equal(encoded.mask, 5)
  assert.deepEqual(encoded.modules.map(row => row.map(cell => (cell ? '1' : '0')).join('')), V1_M_MASK5)
  assert.equal(encoded.modules.length, encoded.size)
  assert.ok(encoded.modules.every(row => row.length === encoded.size))
  // Auto selection is a valid mask and is deterministic for this payload.
  assert.equal(encodeQr('01234567', { version: 1, ecc: 'M' }).mask, 6)
})

test('QR auto version handles a realistic pclink pairing URI (v9-M)', () => {
  const encoded = encodeQr(LONG_URI, { ecc: 'M', mask: 6 })
  assert.equal(encoded.version, 9)
  assert.equal(encoded.size, 53)
  const hash = createHash('sha256')
  for (const row of encoded.modules) hash.update(row.map(cell => (cell ? '1' : '0')).join('')).update('\n')
  assert.equal(hash.digest('hex'), LONG_URI_MATRIX_SHA256)
  assert.equal(encodeQr(LONG_URI, { ecc: 'M' }).version, 9)
})

test('QR capacity boundaries and UTF-8 bytes', () => {
  assert.equal(encodeQr('a'.repeat(14), { ecc: 'M' }).version, 1)
  assert.equal(encodeQr('a'.repeat(15), { ecc: 'M' }).version, 2)
  assert.equal(encodeQr('a'.repeat(14), { ecc: 'M' }).mask >= 0, true)
  assert.equal(encodeQr('中文', { ecc: 'M' }).version, 1)
  assert.throws(() => encodeQr('x'.repeat(3000), { ecc: 'M' }), /too large/)
  assert.throws(() => encodeQr('x', { ecc: 'Z' }), /ECC/)
  assert.throws(() => encodeQr('xxxxxxxx', { version: 1, ecc: 'H' }), /does not fit/)
  assert.ok(getNumDataCodewords(40, 'M') > getNumDataCodewords(1, 'M'))
})

test('all eight QR masks differ and have standard format-bit positions', () => {
  const matrices = []
  for (let mask = 0; mask < 8; mask += 1) {
    const encoded = encodeQr('mask check', { version: 1, ecc: 'M', mask })
    assert.equal(encoded.mask, mask)
    assert.equal(penaltyScore(encoded.modules) > 0, true)
    matrices.push(encoded.modules.map(row => row.join('')).join(''))
  }
  assert.equal(new Set(matrices).size, 8)
  assert.equal(maskBit(0, 0, 0), true)
  assert.equal(maskBit(1, 0, 1), false)
  assert.throws(() => maskBit(8, 0, 0), /mask/)
})

test('terminal renderer uses half blocks, a four-module quiet zone and ANSI colours', () => {
  const modules = encodeQrText('01234567', { version: 1 })
  const plain = renderQrUnicode(modules, { ansi: false })
  const lines = plain.replace(/\n$/, '').split('\n')
  // 21 modules + 4 quiet modules on each side = 29 columns; 29 rows -> 15 lines.
  assert.equal(lines.length, 15)
  assert.equal(lines[0].length, 29)
  assert.equal(lines[0], ' '.repeat(29))
  assert.equal(lines[lines.length - 1], ' '.repeat(29))
  assert.match(plain, /[▀▄█]/)
  assert.doesNotMatch(plain, /\x1b\[/)

  const ansi = renderQrUnicode(modules, { ansi: true })
  assert.match(ansi, /\x1b\[38;5;16;48;5;231m▀/)
  assert.match(ansi, /\x1b\[38;5;231;48;5;16m▀/)
  const stripped = ansi.replace(/\x1b\[[0-9;]*m/g, '')
  assert.equal(stripped.replace(/\n$/, '').split('\n').length, 15)
  assert.equal(stripped.replace(/\n$/, '').split('\n')[0].length, 29)
})
