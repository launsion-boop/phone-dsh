// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import dshbotVolatileContext, {
  collectVolatileBlocks,
  minutePrecision,
  renderVolatileContext,
  VOLATILE_BLOCK_ORDER,
} from '../bot-runtime/src/volatile-context.ts'
import type { VolatileSnapshot } from '../bot-runtime/src/volatile-context.ts'

function agent(id: string): Agent {
  return { id, session: { id } } as unknown as Agent
}

test('volatile blocks preserve variant, time, persona, memory, automation order and trim optional blocks', () => {
  const now = new Date('2026-11-06T08:09:59.900Z')
  assert.equal(minutePrecision(now).toISOString(), '2026-11-06T08:09:00.000Z')
  const blocks = collectVolatileBlocks({
    variant: ' variant ',
    persona: ' persona ',
    memory: ' memory ',
    automation: ' automation ',
  }, { now, lang: 'en' })
  assert.deepEqual(blocks.map(block => block.name), [...VOLATILE_BLOCK_ORDER])
  assert.deepEqual(blocks.filter(block => block.name !== 'time').map(block => block.text), [
    'variant', 'persona', 'memory', 'automation',
  ])
  const rendered = renderVolatileContext({
    variant: '<variant>', persona: '<persona>', memory: '<memory>', automation: '<automation>',
  }, { now, lang: 'en' })
  const positions = ['<variant>', '## Time', '<persona>', '<memory>', '<automation>'].map(text => rendered.indexOf(text))
  assert.ok(positions.every((position, index) => position >= 0 && (index === 0 || position > positions[index - 1]!)))
})

test('the real SystemPrompt registry refreshes an App-hosted snapshot before every assembly', async () => {
  const ctx = new Context()
  const calls: string[] = []
  let snapshot: VolatileSnapshot = {
    variant: 'variant-v1', persona: 'persona-v1', memory: 'memory-v1', automation: 'automation-v1',
  }
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    await ctx.plugin(dshbotVolatileContext, {
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async ({ sessionId }) => {
        calls.push(sessionId)
        return snapshot
      },
    })
    const subject = agent('bot-session-1')
    const first = await ctx.systemPrompt.assemble({ agent: subject, scope: subject })
    const firstText = first.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
    assert.match(firstText, /variant-v1[\s\S]*## Time[\s\S]*persona-v1[\s\S]*memory-v1[\s\S]*automation-v1/)
    assert.match(firstText, /Current local time: .+ \(.+\)\./)

    snapshot = { variant: 'variant-v2', memory: 'memory-v2' }
    const second = await ctx.systemPrompt.assemble({ agent: subject, scope: subject })
    const secondText = second.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
    assert.match(secondText, /variant-v2/)
    assert.match(secondText, /memory-v2/)
    assert.doesNotMatch(secondText, /persona-v1|automation-v1/)
    assert.deepEqual(calls, ['bot-session-1', 'bot-session-1'])

    const noAgent = await ctx.systemPrompt.assemble()
    const noAgentText = noAgent.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
    assert.doesNotMatch(noAgentText, /memory-v2|variant-v2/)
    assert.deepEqual(calls.length, 2)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a failed or late snapshot never exposes stale memory', async () => {
  const ctx = new Context()
  const subject = agent('bot-session-race')
  let fail = false
  let calls = 0
  let markStarted: () => void = () => {}
  let releaseFirst: (value: VolatileSnapshot) => void = () => {}
  const started = new Promise<void>(resolve => { markStarted = resolve })
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    await ctx.plugin(dshbotVolatileContext, {
      lang: () => 'en' as const,
      source: async () => {
        calls += 1
        if (fail) throw new Error('App MCP unavailable')
        if (calls === 1) {
          return new Promise<VolatileSnapshot>(resolve => {
            releaseFirst = resolve
            markStarted()
          })
        }
        return { memory: 'fresh-memory' }
      },
    })
    const slowAssembly = ctx.systemPrompt.assemble({ agent: subject, scope: subject })
    await started
    const fresh = await ctx.systemPrompt.assemble({ agent: subject, scope: subject })
    releaseFirst({ memory: 'late-memory' })
    const slow = await slowAssembly
    for (const assembly of [fresh, slow]) {
      const text = assembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
      assert.match(text, /fresh-memory/)
      assert.doesNotMatch(text, /late-memory/)
    }

    fail = true
    const failed = await ctx.systemPrompt.assemble({ agent: subject, scope: subject })
    assert.doesNotMatch(failed.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? '', /fresh-memory|late-memory/)
  } finally {
    await ctx.fiber.dispose()
  }
})
