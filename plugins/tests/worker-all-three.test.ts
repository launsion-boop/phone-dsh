// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotApprovalGate, { needsStructuralApproval, phoneEffectsForApproval } from '../bot-runtime/src/approval-gate.ts'
import { botOwnedSessions } from '../bot-runtime/src/bot-sessions.ts'
import { executeTool } from './bot-runtime-test-kit.ts'

const names = ['BotVolatileContext', 'BotDecisionContext', 'BotSkillUseStatus'] as const
const args: Record<string, Record<string, unknown>> = {
  BotVolatileContext: { sessionId: 'gb-main' },
  BotDecisionContext: {
    schema: 'bot-decision-context-request/v1', session_id: 'gb-main',
    turn_id: 'gb-main#1', step: 1, stage: 'pre_step', query: 'probe',
    scopes: ['user'], limits: {
      max_materials: 4, max_characters: 1600, max_snippet_characters: 240, deadline_ms: 1500,
    },
  },
  BotSkillUseStatus: { schema: 'bot-skill-use-status/v1', name: 'weekly-report' },
}

function probe(ctx: Context, name: string, calls: string[]): void {
  ctx.tools.register(defineTool({
    name, description: 'probe', parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => { calls.push(name); return 'ok' },
  }))
}

test('all three internal reads are empty-effect and execute without an approval ask', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(NativeToolExecutor)
  const calls: string[] = []
  let approvals = 0
  try {
    botOwnedSessions(ctx).add('gb-main')
    for (const name of names) {
      const effects = phoneEffectsForApproval(`mcp__phone__${name}`, args[name]!)
      assert.deepEqual(effects, [], `${name} must be an empty-effect internal read`)
      assert.equal(needsStructuralApproval(`mcp__phone__${name}`), true, `${name} still enters the structural gate`)
      probe(ctx, `mcp__phone__${name}`, calls)
    }
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    for (const name of names) {
      const result = await executeTool(ctx, {
        callId: ToolCallId(`internal-${name}`), name: `mcp__phone__${name}`,
        arguments: args[name]!, signal: new AbortController().signal,
        agent: { id: 'gb-main', session: { id: 'gb-main' } } as unknown as Agent,
      })
      assert.equal(result.isError, false, `${name}: ${JSON.stringify(result)}`)
    }
    assert.deepEqual(calls, names.map(name => `mcp__phone__${name}`))
    assert.equal(approvals, 0, 'no internal read may create an approval request')
  } finally {
    await ctx.fiber.dispose()
  }
})
