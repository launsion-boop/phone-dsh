// SPDX-License-Identifier: MIT
//
// Real pre-step regression for the BotSkillUseStatus service-injection layer:
// `skill-use-gate` must declare inject=['tools'], actually reach
// ctx.tools.execute from an agent/pre-step waterfall, and the approval gate
// must see an empty internal-read effect list (no card, no denial).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotApprovalGate from '../bot-runtime/src/approval-gate.ts'
import dshbotSkillUseGate from '../bot-runtime/src/skill-use-gate.ts'
import { botOwnedSessions } from '../bot-runtime/src/bot-sessions.ts'

test('real pre-step skill lookup calls BotSkillUseStatus without an approval ask', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(NativeToolExecutor)
  let statusCalls = 0
  let approvals = 0
  try {
    botOwnedSessions(ctx).add('gb-main')
    ctx.tools.register(defineTool({
      name: 'mcp__phone__BotVolatileContext', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => 'ok',
    }))
    ctx.tools.register(defineTool({
      name: 'mcp__phone__BotSkillUseStatus', description: 'probe', parameters: {},
      output: { schema: { type: 'object', additionalProperties: true }, render: () => [{ type: 'text', text: 'ok' }] },
      execute: async () => { statusCalls += 1; return { schema: 'bot-skill-use-status/v1', ok: true, status: 'current' } },
    }))
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    await ctx.plugin(dshbotSkillUseGate, { enabled: true })
    const agent = { id: 'gb-main', session: { id: 'gb-main', header: { agentPreset: 'phone-bot' } } } as unknown as Agent
    const skillMessage = {
      role: 'user',
      source: { kind: 'skill-catalog', entries: [{ name: 'weekly-report' }] },
      content: [{ type: 'text', text: 'skill catalog' }],
    }
    const messages = [skillMessage]
    const decision = await ctx.waterfall('agent/pre-step', {
      agent, messages, turn: 1, step: 1, signal: new AbortController().signal,
    }, async () => ({ kind: 'enter', messages }))
    assert.ok(decision)
    assert.equal(statusCalls, 1, 'the real pre-step path queried BotSkillUseStatus once')
    assert.equal(approvals, 0, 'the internal status read must not ask for approval')
  } finally {
    await ctx.fiber.dispose()
  }
})
