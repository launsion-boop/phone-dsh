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
  hourPrecision,
  localHourBucket,
  renderVolatileContext,
  VOLATILE_BLOCK_ORDER,
} from '../bot-runtime/src/volatile-context.ts'
import type { VolatileSnapshot } from '../bot-runtime/src/volatile-context.ts'

/** Minimal production-shaped agent scope: every Bot agent has a tool registry. */
function agent(id: string): Agent {
  return {
    id,
    session: { id },
    ctx: {
      tools: {
        definitions: () => [{ name: 'bash' }, { name: 'read' }],
        restrict: () => () => {},
        guard: () => () => {},
      },
      on: () => () => {},
    },
  } as unknown as Agent
}

test('volatile blocks preserve variant, time, persona, memory, automation order and trim optional blocks', () => {
  const now = new Date('2026-11-06T08:09:59.900Z')
  // W5: the injected block is a local hour bucket, not a minute bucket.
  const bucket = hourPrecision(now)
  assert.equal(bucket.getMinutes(), 0)
  assert.equal(bucket.getSeconds(), 0)
  assert.equal(bucket.getMilliseconds(), 0)
  assert.match(localHourBucket(now), /^\d{4}-\d{2}-\d{2} \d{2}:00$/)
  assert.equal(localHourBucket(now), localHourBucket(new Date(now.getTime() + 10 * 60_000)),
    'two instants inside one local hour share the same bucket')
  assert.notEqual(localHourBucket(now), localHourBucket(new Date(now.getTime() + 60 * 60_000)))
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

test('the time block changes at most once per hour and never carries a non-zero minute', () => {
  const first = new Date('2026-11-12T09:07:31.000Z')
  const laterInHour = new Date('2026-11-12T09:59:59.999Z')
  const nextHour = new Date('2026-11-12T10:00:00.000Z')
  const timeAt = (now: Date): string =>
    collectVolatileBlocks({}, { now, lang: 'en' }).find(block => block.name === 'time')!.text
  assert.equal(timeAt(first), timeAt(laterInHour))
  assert.notEqual(timeAt(first), timeAt(nextHour))
  assert.match(timeAt(first), /Current local time: \d{4}-\d{2}-\d{2} \d{2}:00 \(.+\)\./)
  assert.doesNotMatch(timeAt(first), /Current local time: .*:\d{2}:\d{2}/)
})

test('an unchanged volatile snapshot is not re-read inside the freshness window', async () => {
  const ctx = new Context()
  let calls = 0
  const snapshot: VolatileSnapshot = { memory: 'stable-memory' }
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    await ctx.plugin(dshbotVolatileContext, {
      now: () => new Date('2026-11-12T09:07:00.000Z'),
      lang: () => 'en' as const,
      refreshMinIntervalMs: 60_000,
      source: async () => {
        calls += 1
        return snapshot
      },
    })
    const subject = agent('gb-freshness-window')
    for (let index = 0; index < 3; index += 1) {
      const assembly = await ctx.systemPrompt.assemble({ agent: subject, scope: subject })
      assert.match(assembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? '',
        /stable-memory/)
    }
    assert.equal(calls, 1, 'three assemblies inside the window share one BotVolatileContext read')
  } finally {
    await ctx.fiber.dispose()
  }
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
    // The session controller records the resolved default (`standard`) in the
    // creation header for every session. Only a restricted header may skip
    // the Bot preset selection; an ordinary Bot keeps the pre-existing select.
    const defaultComposed = agent('gb-agent-default')
    ;(defaultComposed.session as { header?: { agentPreset?: string } }).header = { agentPreset: 'standard' }
    await ctx.serial('agent/created', { agent: defaultComposed, source: 'startup' })
    assert.deepEqual(selected, [
      ['gb-agent-a', 'phone-bot'],
      ['gb-agent-default', 'phone-bot'],
    ])
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

test('restricted gb- sessions without an explicit header still select their frozen preset', async () => {
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
      maintainerAgentPreset: 'phone-bot-maintainer',
      now: () => new Date('2026-11-06T08:09:59.900Z'),
      lang: () => 'en' as const,
      source: async () => ({}),
    })
    await ctx.serial('agent/created', { agent: agent('gb-verifier-fallback'), source: 'startup' })
    await ctx.serial('agent/created', { agent: agent('gb-maintainer-fallback'), source: 'startup' })
    assert.deepEqual(selected, [
      ['gb-verifier-fallback', 'pdsh-verifier'],
      ['gb-maintainer-fallback', 'phone-bot-maintainer'],
    ])
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

test('both restricted session kinds receive no Bot memory or automation from volatile context', async () => {
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
    const maintainer = agent('gb-maintainer-no-memory')
    ;(maintainer.session as { header?: { agentPreset?: string } }).header = { agentPreset: 'phone-bot-maintainer' }
    for (const restricted of [verifier, maintainer]) {
      const assembly = await ctx.systemPrompt.assemble({ agent: restricted, scope: restricted })
      const text = assembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
      assert.equal(text, '')
    }
    assert.equal(calls, 0)
    // The prefix alone (creation header dropped by a transport) is still
    // excluded: the exclusion and the guard resolve the same policy.
    const prefixOnly = agent('gb-maintainer-prefix-only')
    const prefixAssembly = await ctx.systemPrompt.assemble({ agent: prefixOnly, scope: prefixOnly })
    assert.equal(prefixAssembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? '', '')
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
