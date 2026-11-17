// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import dshbotSkillUseGate, { filterSkillProvenanceMessages, removeCatalogLines, skillStatusFromToolResult, skillUseDecision, skillUseDenialCode } from '../bot-runtime/src/skill-use-gate.ts'

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

test('catalog filtering removes only the exact invalid entry lines', () => {
  const text = [
    '<available_skills>',
    '- `weekly-report`: marker-erased-description',
    '- `meeting-notes`: marker-unrelated-description',
    '- `weekly-report-extra`: marker-unrelated-extra',
    '</available_skills>',
  ].join('\n')
  const filtered = removeCatalogLines(text, new Set(['weekly-report']))
  assert.equal(filtered.includes('marker-erased-description'), false)
  assert.equal(filtered.includes('`weekly-report`'), false)
  assert.equal(filtered.includes('marker-unrelated-description'), true)
  assert.equal(filtered.includes('marker-unrelated-extra'), true)
})

test('catalog and loaded body markers are removed only for known-invalid skills', () => {
  const catalog = {
    role: 'user',
    content: [{
      type: 'text',
      text: [
        '<available_skills>',
        '- `erased-skill`: CATALOG_ERASED_MARKER',
        '- `current-skill`: CATALOG_CURRENT_MARKER',
        '</available_skills>',
      ].join('\n'),
    }],
    source: {
      kind: 'skill-catalog', form: 'catalog',
      entries: [
        { name: 'erased-skill', description: 'CATALOG_ERASED_MARKER' },
        { name: 'current-skill', description: 'CATALOG_CURRENT_MARKER' },
      ],
    },
  }
  const call = (id: string, name: string) => ({
    role: 'assistant',
    content: [{ type: 'tool-call', id, name: 'skill', arguments: JSON.stringify({ name }) }],
    source: { kind: 'model' },
  })
  const result = (id: string, text: string) => ({
    role: 'tool', content: [{ type: 'text', text }],
    source: { kind: 'tool', callId: id }, toolCallId: id,
  })
  const messages = [
    catalog,
    call('call-erased', 'erased-skill'),
    result('call-erased', 'BODY_ERASED_MARKER'),
    call('call-current', 'current-skill'),
    result('call-current', 'BODY_CURRENT_MARKER'),
  ]
  const filtered = filterSkillProvenanceMessages(messages, new Map([
    ['erased-skill', 'erased'], ['current-skill', 'current'],
  ]))
  const text = JSON.stringify(filtered)
  assert.equal(text.includes('CATALOG_ERASED_MARKER'), false)
  assert.equal(text.includes('BODY_ERASED_MARKER'), false)
  assert.equal(text.includes('CATALOG_CURRENT_MARKER'), true)
  assert.equal(text.includes('BODY_CURRENT_MARKER'), true)
  const entries = (filtered[0] as { source: { entries: { name: string }[] } }).source.entries
  assert.deepEqual(entries.map(entry => entry.name), ['current-skill'])
  assert.equal((filtered[2] as { isError?: boolean }).isError, true)
  assert.equal((filtered[4] as { isError?: boolean }).isError, undefined)
})

test('unknown and nil statuses keep the catalog and body untouched', () => {
  const messages = [{
    role: 'user',
    content: [{ type: 'text', text: '- `maybe-skill`: CATALOG_MAYBE_MARKER' }],
    source: {
      kind: 'skill-catalog', form: 'catalog',
      entries: [{ name: 'maybe-skill', description: 'CATALOG_MAYBE_MARKER' }],
    },
  }]
  for (const status of ['unknown', null] as const) {
    const filtered = filterSkillProvenanceMessages(messages, new Map([['maybe-skill', status]]))
    assert.equal(filtered, messages)
  }
})

test('status lookup failure is unavailable, while null is untracked and unknown is tracked unknown', () => {
  const ok = (status: unknown) => ({
    value: { structuredContent: { schema: 'bot-skill-use-status/v1', ok: true, status } },
  })
  assert.equal(skillStatusFromToolResult(ok(null)), null)
  assert.equal(skillStatusFromToolResult(ok('unknown')), 'unknown')
  assert.equal(skillStatusFromToolResult(ok('current')), 'current')
  assert.equal(skillStatusFromToolResult(undefined), undefined)
  assert.equal(skillStatusFromToolResult({ isError: true, value: {} }), undefined)
  assert.equal(skillStatusFromToolResult({}), undefined)
  assert.equal(skillStatusFromToolResult({ value: { structuredContent: {} } }), undefined)
  assert.equal(skillStatusFromToolResult({
    value: { structuredContent: { schema: 'wrong', ok: true, status: 'current' } },
  }), undefined)
  assert.equal(skillStatusFromToolResult(ok('bogus')), undefined)
})

test('the gate declares the tools service it calls', () => {
  assert.deepEqual(dshbotSkillUseGate.inject, ['tools'])
})
