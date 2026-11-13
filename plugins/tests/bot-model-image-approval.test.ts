// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
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

test('read_image is gated as the same external send', () => {
  assert.equal(needsStructuralApproval('read_image'), true)
  const effects = phoneEffectsForApproval('read_image', { path: '/dsh/workspace/camera.jpg' })
  assert.equal(effects.length, 1)
  assert.equal(effects[0]?.operation, 'model.image.attach')
  assert.equal(effects[0]?.mutability, 'external-send')
  assert.equal(effects[0]?.policy, 'ask')
  assert.equal(effects[0]?.resource, 'attachment=/dsh/workspace/camera.jpg')
})

test('attach_to_model prefers fileId when a camera artifact has no path', () => {
  const effects = phoneEffectsForApproval('mcp__phone__attach_to_model', {
    fileId: 'art_camera',
    purpose: 'describe',
  })
  assert.equal(effects[0]?.resource, 'attachment=art_camera')
})

test('the Worker effect matches the shared Swift golden for attach_to_model', () => {
  const path = new URL('../../spec/bot/v1/golden/tool-effects.phone.json', import.meta.url)
  const golden = JSON.parse(readFileSync(path, 'utf8')) as {
    valid: Array<{ name: string; args: Record<string, unknown>; effect: Record<string, unknown> }>
  }
  const entry = golden.valid.find(value => value.name === 'attach_to_model')
  assert.ok(entry, 'the shared tool-effects.phone.json must carry attach_to_model')
  const readEntry = golden.valid.find(value => value.name === 'read_image')
  assert.ok(readEntry, 'the shared tool-effects.phone.json must carry read_image')
  const readEffects = phoneEffectsForApproval('read_image', readEntry.args)
  assert.equal(readEffects[0]?.operation, readEntry.effect.operation)
  assert.equal(readEffects[0]?.resource, readEntry.effect.resource)
  assert.equal(readEffects[0]?.detail, readEntry.effect.detail)
  const effects = phoneEffectsForApproval('mcp__phone__attach_to_model', entry.args)
  assert.equal(effects.length, 1)
  const effect = effects[0]!
  assert.equal(effect.tool, 'mcp__phone__attach_to_model')
  assert.equal(effect.operation, entry.effect.operation)
  assert.equal(effect.resource, entry.effect.resource)
  assert.equal(effect.target, entry.effect.target)
  assert.equal(effect.mutability, entry.effect.mutability)
  assert.equal(effect.policy, entry.effect.policy)
  assert.equal(effect.known, entry.effect.known)
  assert.equal(effect.label, entry.effect.label)
  assert.equal(effect.detail, entry.effect.detail)
})
