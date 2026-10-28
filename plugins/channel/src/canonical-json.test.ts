// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  CanonicalJsonError, canonicalStringify, compareByCodePoint, Crc32c, crc32c,
} from './index.ts'

test('CRC32C known answer for 123456789 is 0xE3069283', () => {
  assert.equal(crc32c(new TextEncoder().encode('123456789')), 0xe3069283)
  assert.equal(crc32c(new Uint8Array(0)), 0)
})

test('incremental CRC32C equals the one-shot value', () => {
  const bytes = new TextEncoder().encode('the quick brown fox jumps over the lazy dog')
  const incremental = new Crc32c()
  incremental.update(bytes.subarray(0, 7))
  incremental.update(bytes.subarray(7, 19))
  incremental.update(bytes.subarray(19))
  assert.equal(incremental.digest(), crc32c(bytes))
})

test('canonical JSON sorts keys by code point, not UTF-16 code unit', () => {
  assert.equal(canonicalStringify({ b: 1, a: 2 }), '{"a":2,"b":1}')
  const bmp = '\uE000'
  const astral = '\u{10000}'
  assert.ok(compareByCodePoint(bmp, astral) < 0)
  assert.equal(
    canonicalStringify({ [astral]: 1, [bmp]: 2 }),
    `{"${bmp}":2,"${astral}":1}`,
  )
})

test('canonical JSON has no whitespace and leaves slashes unescaped', () => {
  assert.equal(
    canonicalStringify({ p: '/dsh/home/a b', list: [1, 2], nested: { y: true, x: null } }),
    '{"list":[1,2],"nested":{"x":null,"y":true},"p":"/dsh/home/a b"}',
  )
})

test('canonical JSON emits non-ASCII literally and bigint as an integer', () => {
  assert.equal(canonicalStringify({ t: 'ready ✓\n' }), '{"t":"ready ✓\\n"}')
  assert.equal(canonicalStringify({ mseq: 18446744073709551615n }), '{"mseq":18446744073709551615}')
})

test('canonical JSON rejects floats, non-finite numbers and -0', () => {
  assert.throws(() => canonicalStringify({ n: 1.5 }), CanonicalJsonError)
  assert.throws(() => canonicalStringify({ n: Number.NaN }), CanonicalJsonError)
  assert.throws(() => canonicalStringify({ n: Number.POSITIVE_INFINITY }), CanonicalJsonError)
  assert.throws(() => canonicalStringify({ n: -0 }), CanonicalJsonError)
})

test('canonical JSON rejects values with no JSON representation and cycles', () => {
  assert.throws(() => canonicalStringify({ n: undefined }), CanonicalJsonError)
  assert.throws(() => canonicalStringify({ n: () => 1 }), CanonicalJsonError)
  const cyclic: Record<string, unknown> = {}
  cyclic['self'] = cyclic
  assert.throws(() => canonicalStringify(cyclic), CanonicalJsonError)
  const sparse: unknown[] = []
  sparse.length = 1
  assert.throws(() => canonicalStringify(sparse), CanonicalJsonError)
})
