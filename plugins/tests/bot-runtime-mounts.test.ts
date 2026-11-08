// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import GoalService from '@deepseek-ai/dsh-goal'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import { createAgent, executeTool, mountRuntime, ScriptAdapter, textResponse, userMessage } from './bot-runtime-test-kit.ts'

test('tools pre-execute, execute wrapper and post-execute run in the real ToolRuntime pipeline', async () => {
  const ctx = new Context()
  const calls: string[] = []
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    ctx.on('tools/pre-execute', async (_exec, next) => {
      calls.push('pre')
      return next()
    })
    ctx.on('tools/execute', async (_exec, next) => {
      calls.push('around:before')
      const result = await next()
      calls.push('around:after')
      return result
    })
    ctx.on('tools/post-execute', async (_exec, _result, next) => {
      calls.push('post')
      return next()
    })
    ctx.tools.register(defineTool({
      name: 'bot_mount_probe',
      description: 'Probe the three tool waterfalls.',
      parameters: {},
      output: {
        schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: value }],
      },
      execute: async () => {
        calls.push('body')
        return 'ok'
      },
    }))
    const result = await executeTool(ctx, {
      callId: ToolCallId('bot-mount-probe'),
      name: 'bot_mount_probe',
      arguments: {},
      signal: new AbortController().signal,
    })
    assert.equal(result.isError, false)
    assert.deepEqual(calls, ['pre', 'around:before', 'body', 'around:after', 'post'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('agent/assistant-stream publishes real model deltas', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter([textResponse('streamed-bot-text')])
  const frames: string[] = []
  try {
    ctx.llm.registerAdapter(['mock'], adapter)
    ctx.on('agent/assistant-stream', ({ frame }) => {
      if (frame.type === 'start' || frame.type === 'end') frames.push(frame.type)
      if (frame.type === 'chunk' && frame.chunk.type === 'text-delta') frames.push(frame.chunk.text)
    }, { global: true })
    const agent = await createAgent(ctx, 'bot-assistant-stream')
    agent.followup(userMessage('stream'))
    await agent.whenIdle()
    assert.deepEqual(frames, ['start', 'streamed-bot-text', 'end'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('Agent.cancel aborts only the active model call and preserves the live agent', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter(['hang'])
  try {
    ctx.llm.registerAdapter(['mock'], adapter)
    const agent = await createAgent(ctx, 'bot-agent-cancel')
    agent.followup(userMessage('cancel'))
    await adapter.waitForHanging(1)
    const liveAgent = ctx.agents.get(agent.id)
    agent.cancel({ kind: 'user' }, { keepInbox: true })
    await agent.whenIdle()
    assert.equal(ctx.agents.get(agent.id), liveAgent)
    assert.equal(adapter.aborts.length, 1)
    assert.deepEqual(adapter.aborts[0], { kind: 'user' })
    assert.equal(agent.status, 'idle')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('ctx.goals.block commits a blocked goal through the real GoalService', async () => {
  const ctx = await mountRuntime()
  try {
    await ctx.plugin(GoalService)
    const agent = await createAgent(ctx, 'bot-goal-block')
    const created = ctx.goals.create(agent, { objective: 'verify the phone goal seam' })
    const blocked = ctx.goals.block(agent, { id: created.id, revision: created.revision }, {
      code: 'budget-exceeded',
      message: 'test budget stop',
    })
    assert.equal(blocked.phase, 'blocked')
    assert.equal(blocked.blockedReason?.code, 'budget-exceeded')
    assert.equal(ctx.goals.get(agent)?.phase, 'blocked')
    assert.equal(agent.session.snapshotEvents().at(-1)?.type, 'goal/change')
  } finally {
    await ctx.fiber.dispose()
  }
})
