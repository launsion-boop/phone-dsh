// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { LlmAttemptId, ToolCallId } from '@deepseek-ai/dsh-llm'
import { SessionSeq } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import { BotRuntimeRemote, BotStreamHub } from '../bot-runtime/src/channel.ts'
import type { BotStreamFrame } from '../bot-runtime/src/channel.ts'
import dshbotStreamForward from '../bot-runtime/src/stream-forward.ts'
import { steerInsertedMessage } from '../bot-runtime/src/steering.ts'
import { createAgent, mountRuntime, ScriptAdapter, userMessage } from './bot-runtime-test-kit.ts'
import { botStreamHub, registerBotStreamHub } from '../bot-runtime/src/runtime-registry.ts'

test('stream hub registry is shared by sibling plugin contexts', async () => {
  const ctx = new Context()
  const hub = new BotStreamHub()
  try {
    await ctx.plugin(channelCtx => { registerBotStreamHub(channelCtx, hub) })
    await ctx.plugin(consumerCtx => { assert.equal(botStreamHub(consumerCtx), hub) })
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('stream-forward publishes real model deltas through the Bot channel', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter([{ text: 'unused' } as never])
  const hub = new BotStreamHub()
  const frames: BotStreamFrame[] = []
  try {
    registerBotStreamHub(ctx, hub)
    await ctx.plugin(dshbotStreamForward, { hub })
    const stream = hub.subscribe('gb-stream')
    const collecting = (async () => {
      for await (const frame of stream) {
        frames.push(frame)
        if (frame.type === 'end') break
      }
    })()
    const agent = await createAgent(ctx, 'gb-stream')
    const scripted = new ScriptAdapter([
      [
        { type: 'block-start', index: 0, blockType: 'text' },
        { type: 'text-delta', index: 0, text: 'streamed' },
        { type: 'block-end', index: 0, block: { type: 'text', text: 'streamed' } },
        { type: 'usage', usage: { inputTokens: 1, outputTokens: 1 } },
        { type: 'finish', reason: { kind: 'stop' } },
      ],
    ])
    ctx.llm.registerAdapter(['mock'], scripted)
    agent.followup(userMessage('stream'))
    await agent.whenIdle()
    await collecting
    assert.deepEqual(frames.map(frame => frame.type), ['start', 'text', 'end'])
    assert.equal(frames[1]!.text, 'streamed')
    assert.equal(frames[1]!.sessionId, 'gb-stream')
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('Bot cancel channel aborts only the addressed live turn', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter(['hang'])
  const hub = new BotStreamHub()
  try {
    ctx.llm.registerAdapter(['mock'], adapter)
    const remote = new BotRuntimeRemote(ctx, hub)
    const agent = await createAgent(ctx, 'gb-cancel')
    agent.followup(userMessage('cancel'))
    await adapter.waitForHanging(1)
    const live = ctx.agents.get(agent.id)
    assert.deepEqual(remote.botCancel({ sessionId: agent.id }), { ok: true, sessionId: agent.id })
    await agent.whenIdle()
    assert.equal(ctx.agents.get(agent.id), live)
    assert.equal(adapter.aborts.length, 1)
    assert.equal(remote.botCancel({ sessionId: 'gb-other' }).ok, false)
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('question cards suppress trailing deltas and hidden prompts never steer into the hidden turn', async () => {
  const ctx = new Context()
  const hub = new BotStreamHub()
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    registerBotStreamHub(ctx, hub)
    await ctx.plugin(dshbotStreamForward, { hub })
    const agent = { id: 'gb-main', session: { id: 'gb-main' } } as unknown as Agent
    const frames: BotStreamFrame[] = []
    const stream = hub.subscribe('gb-main')
    const collecting = (async () => {
      for await (const frame of stream) {
        frames.push(frame)
        if (frame.type === 'end') break
      }
    })()
    ctx.tools.register(defineTool({
      name: 'mcp__phone__ask_user', description: 'card', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => 'ok',
    }))
    await ctx.tools.execute({
      callId: ToolCallId('question'), name: 'mcp__phone__ask_user', arguments: {},
      signal: new AbortController().signal, agent,
    })
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'start', revision: 1, turn: 1, step: 1, attemptId: LlmAttemptId('a1') } })
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'chunk', revision: 1, time: 1, attemptId: LlmAttemptId('a1'), index: 0, chunk: { type: 'text-delta', index: 0, text: 'must not escape' } } })
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'end', revision: 1, index: 1, attemptId: LlmAttemptId('a1'), outcome: { kind: 'committed', eventType: 'assistant/message', seq: SessionSeq(1) } } })
    await collecting
    assert.deepEqual(frames.map(frame => frame.type), ['start', 'end'])

    const hidden = new Set(['gb-hidden'])
    const prompt = userMessage('visible later')
    const running = {
      id: 'gb-hidden', session: { id: 'gb-hidden' }, status: 'running',
      inbox: { nextTurn: [prompt], remove: () => true },
      steer: () => { throw new Error('must not steer') },
      followup: () => {},
    } as unknown as Agent
    assert.equal(steerInsertedMessage(running, prompt, new WeakSet(), hidden), false)
    assert.equal(running.inbox.nextTurn.some(entry => entry.id === prompt.id), true)
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('question suppression clears at turn end rather than attempt end', async () => {
  const ctx = new Context()
  const hub = new BotStreamHub()
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    registerBotStreamHub(ctx, hub)
    await ctx.plugin(dshbotStreamForward, { hub })
    const agent = { id: 'gb-main', session: { id: 'gb-main' } } as unknown as Agent
    ctx.tools.register(defineTool({
      name: 'mcp__phone__ask_user', description: 'card', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => 'ok',
    }))
    await ctx.tools.execute({
      callId: ToolCallId('question-turn'), name: 'mcp__phone__ask_user', arguments: {},
      signal: new AbortController().signal, agent,
    })
    const frames = await driveAttemptsAcrossTurnEnd(ctx, agent, hub)
    assert.deepEqual(frames, ['allowed after turn end'])
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('hidden prompt suppression clears at turn end rather than attempt end', async () => {
  const ctx = new Context()
  const hub = new BotStreamHub()
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    registerBotStreamHub(ctx, hub)
    await ctx.plugin(dshbotStreamForward, { hub })
    const agent = { id: 'gb-hidden', session: { id: 'gb-hidden' } } as unknown as Agent
    ctx.emit('agent/inbox/inserted', { agent, message: userMessage('[SAND_HIDDEN_PROMPT] hidden') })
    const frames = await driveAttemptsAcrossTurnEnd(ctx, agent, hub)
    assert.deepEqual(frames, ['allowed after turn end'])
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

async function driveAttemptsAcrossTurnEnd(ctx: Context, agent: Agent, hub: BotStreamHub): Promise<string[]> {
  const frames: BotStreamFrame[] = []
  const stream = hub.subscribe(String(agent.id))
  const collecting = (async () => {
    for await (const frame of stream) {
      frames.push(frame)
      if (frames.filter(entry => entry.type === 'end').length === 3) break
    }
  })()
  const attempt = (id: string, text: string) => {
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'start', revision: 1, turn: 1, step: 1, attemptId: LlmAttemptId(id) } })
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'chunk', revision: 1, time: 1, attemptId: LlmAttemptId(id), index: 0, chunk: { type: 'text-delta', index: 0, text } } })
    ctx.emit('agent/assistant-stream', { agent, frame: { type: 'end', revision: 1, index: 1, attemptId: LlmAttemptId(id), outcome: { kind: 'committed', eventType: 'assistant/message', seq: SessionSeq(1) } } })
  }
  attempt('attempt-1', 'blocked before first attempt end')
  attempt('attempt-2', 'blocked before turn end')
  ctx.emit('session/event', { id: agent.id } as never, { type: 'turn/end', data: { turn: 1 } } as never)
  attempt('attempt-3', 'allowed after turn end')
  await collecting
  return frames.filter(frame => frame.type === 'text').map(frame => frame.text ?? '')
}
