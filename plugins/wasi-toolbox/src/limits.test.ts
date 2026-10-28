// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  DEFAULT_HOT_INSTANCE_MEMORY_BYTES,
  HOT_INSTANCE_MEMORY_BYTES_BY_TIER,
  MEBIBYTE,
} from './limits.ts'

/**
 * The 8 GiB row of `spec/v1/budgets.md` §4. The W12-BIGFILE revision raised the
 * WASI hot-instance row to 260 MB in the spec and in the published
 * capabilities manifest, but the enforcement constant stayed at 150 MB: a real
 * device killed python3 at exactly 157286400 bytes (150 MiB) while the manifest
 * already published 272629760 (260 MiB). Pin the enforced constant to the spec
 * row so the two owners cannot drift apart again without a failing test.
 */
test('limits: the default WASI hot-instance ceiling is the 8 GiB budgets.md §4 row', () => {
  assert.equal(DEFAULT_HOT_INSTANCE_MEMORY_BYTES, 272_629_760)
  assert.equal(DEFAULT_HOT_INSTANCE_MEMORY_BYTES, 260 * MEBIBYTE)
  assert.equal(HOT_INSTANCE_MEMORY_BYTES_BY_TIER['8GiB'], DEFAULT_HOT_INSTANCE_MEMORY_BYTES)
})

test('limits: the WASI hot-instance row of every tier matches budgets.md §4', () => {
  assert.deepEqual({ ...HOT_INSTANCE_MEMORY_BYTES_BY_TIER }, {
    '8GiB': 260 * MEBIBYTE,
    '6GiB': 200 * MEBIBYTE,
    '4GiB': 144 * MEBIBYTE,
    '3GiB': 96 * MEBIBYTE,
  })
})
