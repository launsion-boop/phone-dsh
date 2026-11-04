// SPDX-License-Identifier: MIT
// L51: the boot probe that decides whether the `ubuntu` command exists.
//
// The transport half is exercised on the device (the probe is one EXEC_REQ and
// its answer is the host tool's JSON). These tests pin the decision itself: the
// answer shape, and the rule that anything other than `available: true` becomes
// "no environment" rather than a command that fails later.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { UBUNTU_PROBE_ARGV, UBUNTU_PROBE_TIMEOUT_MS, ubuntuCapabilityOf } from './ubuntu-probe.ts'

test('the probe asks the phone catalog, not a new wire method', () => {
  assert.deepEqual([...UBUNTU_PROBE_ARGV], ['phone', 'ubuntu', 'probe'])
  assert.ok(UBUNTU_PROBE_TIMEOUT_MS > 0 && UBUNTU_PROBE_TIMEOUT_MS <= 10_000)
})

test('a real answer becomes the boot capability', () => {
  assert.deepEqual(
    ubuntuCapabilityOf(JSON.stringify({
      available: true,
      env: 'ubuntu-24.04',
      backend: 'mock',
      commands: ['run', 'status', 'close'],
    })),
    { env: 'ubuntu-24.04', backend: 'mock', commands: ['run', 'status', 'close'] },
  )
})

test('not available is no capability, never a partial one', () => {
  for (const answer of [
    '{"available":false}',
    '{"available":true}',
    '{"available":true,"env":"","backend":"mock"}',
    '{"available":true,"env":"ubuntu-24.04"}',
    '{"available":"yes","env":"ubuntu-24.04","backend":"mock"}',
    '[]',
    'null',
    'not json',
    '',
  ]) {
    assert.equal(ubuntuCapabilityOf(answer), undefined, `answer ${JSON.stringify(answer)}`)
  }
})

test('a missing command list is empty, not invented', () => {
  assert.deepEqual(
    ubuntuCapabilityOf('{"available":true,"env":"ubuntu-24.04","backend":"real"}'),
    { env: 'ubuntu-24.04', backend: 'real', commands: [] },
  )
})
