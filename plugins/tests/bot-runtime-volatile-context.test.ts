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

test('the configured Bot preset is selected for gb- sessions before their first turn', async () => {
  const ctx = new Context()
  const selected: [string, string][] = []
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    ctx.provide('agentPresets', {
      async select(subject: Agent, preset: string) {
        selected.push([subject.id, preset])
        return preset
      },
    })
    await ctx.plugin(dshbotVolatileContext, {
      botAgentPreset: 'phone-bot',
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async () => ({}),
    })
    await ctx.serial('agent/created', { agent: agent('gb-agent-a'), source: 'startup' })
    await ctx.serial('agent/created', { agent: agent('session-workbench'), source: 'startup' })
    assert.deepEqual(selected, [['gb-agent-a', 'phone-bot']])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('an explicit immutable preset header is never overwritten by the Bot preset selection', async () => {
  const ctx = new Context()
  const selected: [string, string][] = []
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    ctx.provide('agentPresets', {
      async select(subject: Agent, preset: string) {
        selected.push([subject.id, preset])
        return preset
      },
    })
    await ctx.plugin(dshbotVolatileContext, {
      botAgentPreset: 'phone-bot',
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async () => ({}),
    })
    const restricted = agent('gb-verifier-a')
    ;(restricted.session as { header?: { agentPreset?: string } }).header = { agentPreset: 'pdsh-verifier' }
    await ctx.serial('agent/created', { agent: restricted, source: 'startup' })
    assert.deepEqual(selected, [])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a verifier-gb session without an explicit header still selects the read-only preset', async () => {
  const ctx = new Context()
  const selected: [string, string][] = []
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    ctx.provide('agentPresets', {
      async select(subject: Agent, preset: string) {
        selected.push([subject.id, preset])
        return preset
      },
    })
    await ctx.plugin(dshbotVolatileContext, {
      botAgentPreset: 'phone-bot',
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async () => ({}),
    })
    await ctx.serial('agent/created', { agent: agent('gb-verifier-fallback'), source: 'startup' })
    assert.deepEqual(selected, [['gb-verifier-fallback', 'pdsh-verifier']])
  } finally {
    await ctx.fiber.dispose()
  }
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

test('a verifier session receives no Bot memory or automation from volatile context', async () => {
  const ctx = new Context()
  let calls = 0
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    await ctx.plugin(dshbotVolatileContext, {
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async () => {
        calls += 1
        return { variant: 'leak-variant', persona: 'leak-persona', memory: 'leak-memory', automation: 'leak-automation' }
      },
    })
    const verifier = agent('gb-verifier-no-memory')
    ;(verifier.session as { header?: { agentPreset?: string } }).header = { agentPreset: 'pdsh-verifier' }
    const assembly = await ctx.systemPrompt.assemble({ agent: verifier, scope: verifier })
    const text = assembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
    assert.equal(text, '')
    assert.equal(calls, 0)

    const ordinary = agent('gb-main')
    const ordinaryAssembly = await ctx.systemPrompt.assemble({ agent: ordinary, scope: ordinary })
    const ordinaryText = ordinaryAssembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
    assert.match(ordinaryText, /leak-variant[\s\S]*leak-persona[\s\S]*leak-memory[\s\S]*leak-automation/)
    assert.equal(calls, 1)
  } finally {
    await ctx.fiber.dispose()
  }
})
