// SPDX-License-Identifier: MIT
/**
 * Codec tests for the git object/pack layer: the pure-JavaScript zlib codec
 * the Worker needs (its `node:zlib` proxy has no deflate/inflate) and the
 * pack-index CRC-32, including the standard known vectors.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/compress
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { crc32, deflate, inflate } from '../compress.ts'
import { encodeText } from '../fs.ts'

/** Standard CRC-32 (IEEE 802.3) check value for `"123456789"`. */
const CRC32_123456789 = 0xcbf43926

test('crc32 matches the standard known vectors', () => {
  assert.equal(crc32(new Uint8Array(0)), 0x00000000)
  assert.equal(crc32(encodeText('123456789')), CRC32_123456789)
  assert.equal(crc32(encodeText('The quick brown fox jumps over the lazy dog')), 0x414fa339)
  assert.equal(crc32(encodeText('a')), 0xe8b7be43)
  // The same checksum arrives when the input is fed in chunks.
  const incremental = crc32(encodeText('456789'), crc32(encodeText('123')))
  assert.equal(incremental, CRC32_123456789)
})

test('crc32 covers every byte and every bit position', () => {
  const single = (byte: number): number => crc32(Uint8Array.from([byte]))
  const seen = new Set<number>()
  for (let byte = 0; byte < 256; byte += 1) seen.add(single(byte))
  assert.equal(seen.size, 256, 'every single-byte input must produce a distinct value')
  assert.notEqual(single(0x01), single(0x02))
  assert.notEqual(single(0x01), single(0x80))
  assert.notEqual(single(0x01), single(0x00))
})

test('deflate/inflate round-trips empty, text and binary payloads', () => {
  const payloads: Uint8Array[] = [
    new Uint8Array(0),
    encodeText(''),
    encodeText('hello world\n'),
    encodeText('alpha\nbeta\ngamma\n'.repeat(1000)),
    Uint8Array.from({ length: 70_000 }, (_, index) => (index * 31 + 7) & 0xff),
  ]
  for (const payload of payloads) {
    const compressed = deflate(payload)
    // The zlib envelope: method 8, no preset dictionary and a header that is
    // a multiple of 31 (the standard 0x78 0x9c for the default level).
    assert.equal(compressed[0], 0x78)
    assert.equal((compressed[0] as number) & 0x0f, 8)
    assert.equal((((compressed[0] as number) << 8) | (compressed[1] as number)) % 31, 0)
    assert.deepEqual(inflate(compressed), payload)
  }
})

test('inflate rejects prefixes and truncated streams instead of guessing', () => {
  const compressed = deflate(encodeText('the quick brown fox'))
  for (let length = 0; length < 8; length += 1) {
    assert.throws(() => inflate(compressed.subarray(0, length)), /truncated zlib stream/)
  }
  assert.throws(() => inflate(compressed.subarray(0, compressed.byteLength - 1)))
  // Trailing bytes beyond the zlib stream are ignored by design; an inflated
  // result always reflects the complete stream.
  const padded = new Uint8Array(compressed.byteLength + 3)
  padded.set(compressed)
  assert.deepEqual(inflate(padded), encodeText('the quick brown fox'))
})
