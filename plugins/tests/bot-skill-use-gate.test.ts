// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { skillUseDecision, skillUseDenialCode } from '../bot-runtime/src/skill-use-gate.ts'

test('only a current skill may load', () => {
  assert.equal(skillUseDecision('current'), 'allow')
})

test('unknown, nil/untracked and every non-current status deny', () => {
  for (const status of ['changed', 'unavailable', 'revoked', 'erased', 'unknown'] as const) {
    assert.equal(skillUseDecision(status), 'deny')
    assert.equal(skillUseDenialCode(status), `skill-provenance-${status}`)
  }
  assert.equal(skillUseDecision(null), 'deny')
  assert.equal(skillUseDenialCode(null), 'skill-provenance-untracked')
})
