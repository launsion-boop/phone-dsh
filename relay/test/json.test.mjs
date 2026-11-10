// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import { performance } from 'node:perf_hooks'
import { StrictJsonError, parseStrictJsonObject } from '../src/json.mjs'

test('strict JSON strings still decode escapes and reject duplicates after the slice rewrite', () => {
  const value = parseStrictJsonObject(
    '{"plain":"abc","escaped":"a\\n\\t\\"\\\\\\/b","unicode":"\\u0041\\ud83d\\ude00",'
    + '"raw":"😀","__proto__":{"nested":1}}',
  )
  assert.equal(Object.getPrototypeOf(value), null)
  assert.equal(Object.getPrototypeOf(value.__proto__), null)
  assert.equal(value.plain, 'abc')
  assert.equal(value.escaped, 'a\n\t"\\/b')
  assert.equal(value.unicode, 'A😀')
  assert.equal(value.raw, '😀')
  assert.equal(value.__proto__.nested, 1)

  assert.throws(
    () => parseStrictJsonObject('{"a":1,"a":2}'),
    /duplicate member name/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":1,"\\u0061":2}'),
    /duplicate member name/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":{"b":1,"b":2}}'),
    /duplicate member name/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":[1,2,]}'),
    /trailing comma/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":"\\ud800"}'),
    /unpaired high surrogate/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":"\\udc00"}'),
    /unpaired low surrogate/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":"x\\u0000y"}'),
    /NUL is not allowed/,
  )
  assert.throws(
    () => parseStrictJsonObject('{"a":1} trailing'),
    /trailing bytes/,
  )
  assert.ok(new StrictJsonError('x') instanceof Error)
})

test('large JSON string frames parse with bounded heap (no per-character amplification)', () => {
  const size = 8 * 1024 * 1024
  const text = `{"v":1,"type":"e2e","body":"${'x'.repeat(size)}"}`
  const before = process.memoryUsage().heapUsed
  const started = performance.now()
  const value = parseStrictJsonObject(text)
  const elapsed = performance.now() - started
  const growth = process.memoryUsage().heapUsed - before

  assert.equal(value.body.length, size)
  assert.equal(value.body.charCodeAt(0), 0x78)
  assert.equal(value.body.charCodeAt(size - 1), 0x78)
  assert.ok(elapsed < 2000, `large string parse took ${Math.round(elapsed)} ms`)
  assert.ok(
    growth < 64 * 1024 * 1024,
    `large string parse grew the heap by ${Math.round(growth / 1048576)} MiB (expected < 64 MiB)`,
  )
})
