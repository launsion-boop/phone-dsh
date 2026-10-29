// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { hotInstanceBytesFromEnvironment } from '../worker-entry/src/entry.ts'

const MIB = 1024 * 1024

test('hot instance: the host tier value passes through inside the contract range', () => {
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: String(260 * MIB) }), 260 * MIB)
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: String(640 * MIB) }), 640 * MIB)
})

test('hot instance: an out-of-range host value is clamped, never a boot failure', () => {
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: String(32 * MIB) }), 96 * MIB)
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: String(4096 * MIB) }), 640 * MIB)
})

test('hot instance: a missing or malformed value leaves the 8 GiB default', () => {
  assert.equal(hotInstanceBytesFromEnvironment(undefined), undefined)
  assert.equal(hotInstanceBytesFromEnvironment({}), undefined)
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: '' }), undefined)
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: '12.5' }), undefined)
  assert.equal(hotInstanceBytesFromEnvironment({ PDSH_WASI_HOT_INSTANCE_BYTES: '0' }), undefined)
})
