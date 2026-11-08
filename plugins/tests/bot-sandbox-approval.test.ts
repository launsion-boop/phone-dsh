// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { answerSandboxApproval, approvalPayload, outcomeFromDecision } from '../bot-runtime/src/sandbox-approval.ts'

test('sandbox escalation reuses the structural approval card exactly once', async () => {
  const agent = { id: 'gb-main', session: { id: 'gb-main' } } as unknown as Agent
  const payloads: Record<string, unknown>[] = []
  const result = await answerSandboxApproval({
    agent,
    callId: 'sandbox-1',
    reason: 'escalate sandbox to danger-full-access: generated artifact required',
    toolName: 'bash',
    arguments: { command: 'printf safe' },
  }, {
    request: async payload => {
      payloads.push(payload)
      return { ok: true, allowed: true }
    },
  })
  assert.equal(result, 'allowed-once')
  assert.equal(payloads.length, 1)
  assert.equal(payloads[0]!.onceOnly, true)
  assert.equal(payloads[0]!.callId, 'sandbox-1')
  assert.equal(payloads[0]!.askAction, 'sandbox-escalation')
  assert.equal(payloads[0]!.alwaysScope, 'none')
  assert.equal(payloads[0]!.command, 'printf safe')
  assert.equal(typeof payloads[0]!.argsDigest, 'string')
  assert.equal((payloads[0]!.effects as { resource: string }[])[0]!.resource,
    'escalate sandbox to danger-full-access: generated artifact required')
  assert.equal(outcomeFromDecision({ ok: true, allowed: false }), 'rejected')
  assert.equal(outcomeFromDecision({ ok: false, message: 'approval timed out' }), 'cancelled')
  assert.equal(outcomeFromDecision({ ok: false, message: 'bridge down' }), 'unavailable')
})

test('sandbox escalation without an attributed session fails closed', async () => {
  assert.equal(await answerSandboxApproval({ reason: 'escalate sandbox to danger-full-access' }, {
    request: async () => { throw new Error('must not be called') },
  }), 'unavailable')
})
