// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import test from 'node:test'
import {
  needsStructuralApproval,
  phoneEffectsForApproval,
} from '../bot-runtime/src/approval-gate.ts'

test('attach_to_model is a structural, approval-gated external send', () => {
  assert.equal(needsStructuralApproval('mcp__phone__attach_to_model'), true)
  const effects = phoneEffectsForApproval('mcp__phone__attach_to_model', {
    path: '/dsh/workspace/camera.jpg',
    purpose: '看看这张照片',
  })
  assert.equal(effects.length, 1)
  const effect = effects[0]!
  assert.equal(effect.operation, 'model.image.attach')
  assert.equal(effect.mutability, 'external-send')
  assert.equal(effect.policy, 'ask')
  assert.equal(effect.known, true)
  assert.equal(effect.resource, 'attachment=/dsh/workspace/camera.jpg')
  assert.match(effect.detail, /看看这张照片/u)
})

test('attach_to_model prefers fileId when a camera artifact has no path', () => {
  const effects = phoneEffectsForApproval('mcp__phone__attach_to_model', {
    fileId: 'art_camera',
    purpose: 'describe',
  })
  assert.equal(effects[0]?.resource, 'attachment=art_camera')
})
