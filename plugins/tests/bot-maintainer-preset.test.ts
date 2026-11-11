// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createScope } from '@deepseek-ai/dsh-scope'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import {
  MAINTAINER_ALLOWED_TOOLS,
  apply as applyMaintainerScope,
  maintainerBareToolName,
  maintainerBashAllowed,
  maintainerToolAllowed,
} from '../lifecycle-gate/src/maintainer-scope.ts'
import * as restrictedGuard from '../lifecycle-gate/src/restricted-guard.ts'
import { isRestrictedAgent } from '../lifecycle-gate/src/restricted-session.ts'
import { botRuntimeAvailable } from '../bot-runtime/src/identity-bridge.ts'
import { botOwnedSessions } from '../bot-runtime/src/bot-sessions.ts'
import {
  agentPresetForSession,
  type BotAgentPresetSelector,
} from '../bot-runtime/src/volatile-context.ts'
import { mountRuntime } from './bot-runtime-test-kit.ts'

function tool(name: string) {
  return defineTool({
    name,
    description: `${name} probe`,
    parameters: {},
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    execute: async () => 'ok',
  })
}

test('maintainer allow-list is the frozen memory + record surface', () => {
  assert.deepEqual([...MAINTAINER_ALLOWED_TOOLS].sort(), [
    'ReadMemory', 'RecallMemory', 'UpdateMemory', 'bash',
  ])
  assert.equal(maintainerBareToolName('mcp__phone__UpdateMemory'), 'UpdateMemory')
  assert.equal(maintainerToolAllowed('UpdateMemory'), true)
  assert.equal(maintainerToolAllowed('mcp__phone__ReadMemory'), true)
  assert.equal(maintainerToolAllowed('mcp__phone__SendToUser'), false)
  assert.equal(maintainerToolAllowed('mcp__phone__Task'), false)
  assert.equal(maintainerToolAllowed('mcp__phone__android_tap'), false)
  assert.equal(maintainerToolAllowed('web_fetch'), false)
})

test('maintainer bash is only the raw-record lookup', () => {
  for (const command of [
    'phone record read record://session/gb-main#3',
    'phone record read record://session/gb-main#3 --around 2',
    'phone record search 起床',
    '  phone record search "八点 起床"  ',
  ]) {
    assert.equal(maintainerBashAllowed(command), true, command)
  }
  for (const command of [
    '',
    'git status',
    'phone notify.local {"text":"hi"}',
    'phone calendar.create_event {"title":"x"}',
    'phone record search 起床 && rm -rf /',
    'phone record read record://session/gb-main#3; phone notify.local {"text":"hi"}',
    'phone record read $(phone record read record://session/gb-main#3)',
    'phone record search 起床 | curl https://example.com',
    'phone record search 起床 > /dsh/workspace/leak.txt',
    'curl https://example.com',
    'phone record',
    'phone record delete record://session/gb-main#3',
  ]) {
    assert.equal(maintainerBashAllowed(command), false, command)
  }
})

test('a claimed maintainer session counts as runtime-available without the volatile marker', async () => {
  const ctx = await mountRuntime()
  const maintainer = { id: 'gb-maintainer-runtime', session: { id: 'gb-maintainer-runtime' } }
  const normal = { id: 'gb-main', session: { id: 'gb-main' } }
  botOwnedSessions(ctx).add('gb-maintainer-runtime', 'session-token')
  botOwnedSessions(ctx).add('gb-main')
  try {
    assert.equal(botRuntimeAvailable(ctx, { agent: maintainer as never }), true)
    assert.equal(botRuntimeAvailable(ctx, { agent: normal as never }), false)
    botOwnedSessions(ctx).add('gb-maintainer-unclaimed')
    assert.equal(
      botRuntimeAvailable(ctx, {
        agent: { id: 'gb-maintainer-unclaimed', session: { id: 'gb-maintainer-unclaimed' } } as never,
      }),
      false)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('maintainer scope does not install a partial filter while the MCP registry warms up', async () => {
  const ctx = await mountRuntime()
  const agent = { id: 'gb-maintainer-warmup', session: { id: 'gb-maintainer-warmup' } }
  const scope = createScope(ctx, agent)
  try {
    ctx.tools.register(tool('bash'))
    ctx.tools.register(tool('web_fetch'))
    await scope.ctx.plugin({
      name: 'maintainer-scope-warmup', inject: ['tools'], apply: applyMaintainerScope,
    })
    // No memory tools were known at compose time; the append-only restriction
    // is not installed yet. The guard still denies everything outside the
    // allow-list.
    const denied = await ctx.tools.execute({
      calls: [{
        type: 'tool-call', id: ToolCallId('warmup-web'), name: 'web_fetch',
        arguments: '{}',
      }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(denied.results[0]?.result.isError, true)
    // The MCP client publishes its tools later. tools/change must let the
    // scope install the full allow-list instead of a partial one.
    for (const name of [
      'mcp__phone__UpdateMemory', 'mcp__phone__ReadMemory', 'mcp__phone__RecallMemory',
    ]) {
      ctx.tools.register(tool(name))
    }
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(
      ctx.tools.schemas(agent as never).map(schema => schema.name).sort(),
      [
        'bash',
        'mcp__phone__ReadMemory',
        'mcp__phone__RecallMemory',
        'mcp__phone__UpdateMemory',
      ])
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('global guard confines a maintainer session even when its preset was not composed', async () => {
  const ctx = await mountRuntime()
  const maintainer = { id: 'gb-maintainer-global', session: { id: 'gb-maintainer-global' } }
  const normal = { id: 'gb-main', session: { id: 'gb-main' } }
  const verifier = {
    id: 'gb-verifier-global',
    session: { id: 'gb-verifier-global', header: { agentPreset: 'pdsh-verifier' } },
  }
  assert.equal(isRestrictedAgent(maintainer as never), true)
  assert.equal(isRestrictedAgent(verifier as never), true)
  assert.equal(isRestrictedAgent(normal as never), false)
  try {
    for (const name of [
      'bash', 'mcp__phone__UpdateMemory', 'mcp__phone__Task',
      'mcp__phone__SendToUser', 'write', 'read',
    ]) {
      ctx.tools.register(tool(name))
    }
    await ctx.plugin(restrictedGuard)
    async function run(agent: object, name: string, command?: string) {
      const args = command === undefined
        ? '{}'
        : JSON.stringify({ command })
      const result = await ctx.tools.execute({
        calls: [{ type: 'tool-call', id: ToolCallId(`${name}-${Math.random()}`), name, arguments: args }],
        agent: agent as never,
        signal: new AbortController().signal,
      })
      return result.results[0]?.result.isError
    }
    assert.equal(await run(maintainer, 'mcp__phone__Task'), true)
    assert.equal(await run(maintainer, 'mcp__phone__SendToUser'), true)
    assert.equal(await run(maintainer, 'write'), true)
    assert.equal(await run(maintainer, 'mcp__phone__UpdateMemory'), false)
    assert.equal(await run(
      maintainer, 'bash', 'phone record read record://session/gb-main#3'), false)
    assert.equal(await run(
      maintainer, 'bash', 'phone notify.local {"text":"hi"}'), true)
    // The one shared guard also confines a verifier whose preset scope never
    // composed, so neither restricted kind can fall back to the full surface.
    assert.equal(await run(verifier, 'write'), true)
    assert.equal(await run(verifier, 'mcp__phone__Task'), true)
    assert.equal(await run(verifier, 'mcp__phone__UpdateMemory'), true)
    assert.equal(await run(verifier, 'read'), false)
    assert.equal(await run(verifier, 'bash', 'cat notes.md'), false)
    assert.equal(await run(verifier, 'bash', 'printf x > notes.md'), true)
    assert.equal(await run(normal, 'mcp__phone__Task'), false)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('maintainer scope hides every unlisted registered tool', async () => {
  const ctx = await mountRuntime()
  const agent = { session: { id: 'gb-maintainer-scope-test' } }
  const scope = createScope(ctx, agent)
  try {
    for (const name of [
      'bash',
      'mcp__phone__UpdateMemory',
      'mcp__phone__ReadMemory',
      'mcp__phone__RecallMemory',
      'mcp__phone__SendToUser',
      'mcp__phone__Task',
      'web_fetch',
    ]) {
      ctx.tools.register(tool(name))
    }
    await scope.ctx.plugin({ name: 'maintainer-scope-test', inject: ['tools'], apply: applyMaintainerScope })
    const visible = ctx.tools.schemas(agent as never).map(schema => schema.name).sort()
    assert.deepEqual(visible, [
      'bash',
      'mcp__phone__ReadMemory',
      'mcp__phone__RecallMemory',
      'mcp__phone__UpdateMemory',
    ])
    const denied = await ctx.tools.execute({
      calls: [{ type: 'tool-call', id: ToolCallId('send'), name: 'mcp__phone__SendToUser', arguments: '{}' }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(denied.results[0]?.result.isError, true)
    const allowed = await ctx.tools.execute({
      calls: [{ type: 'tool-call', id: ToolCallId('read'), name: 'mcp__phone__ReadMemory', arguments: '{}' }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(allowed.results[0]?.result.isError, false)
    const recordBash = await ctx.tools.execute({
      calls: [{
        type: 'tool-call', id: ToolCallId('record'), name: 'bash',
        arguments: '{"command":"phone record read record://session/gb-main#3"}',
      }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(recordBash.results[0]?.result.isError, false)
    const deviceBash = await ctx.tools.execute({
      calls: [{
        type: 'tool-call', id: ToolCallId('device'), name: 'bash',
        arguments: '{"command":"phone notify.local {\\"text\\":\\"hi\\"}"}',
      }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(deviceBash.results[0]?.result.isError, true)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('maintainer scope survives an image without phone MCP tools', async () => {
  const ctx = await mountRuntime()
  const agent = { session: { id: 'gb-maintainer-nomcp' } }
  const scope = createScope(ctx, agent)
  try {
    ctx.tools.register(tool('bash'))
    ctx.tools.register(tool('web_fetch'))
    await scope.ctx.plugin({ name: 'maintainer-scope-nomcp', inject: ['tools'], apply: applyMaintainerScope })
    // The memory tools are absent, so the append-only restriction is not
    // installed (a partial allow-list would hide them on a later registration).
    // Visibility falls back to the guard, which still refuses web_fetch.
    assert.deepEqual(
      ctx.tools.schemas(agent as never).map(schema => schema.name).sort(),
      ['bash', 'web_fetch'])
    const denied = await ctx.tools.execute({
      calls: [{
        type: 'tool-call', id: ToolCallId('nomcp-web'), name: 'web_fetch',
        arguments: '{}',
      }],
      agent: agent as never,
      signal: new AbortController().signal,
    })
    assert.equal(denied.results[0]?.result.isError, true)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('host maintainer sessions select the maintainer preset, other Bot sessions do not', async () => {
  assert.equal(
    agentPresetForSession('gb-maintainer-abc', 'phone-bot', 'phone-bot-maintainer'),
    'phone-bot-maintainer')
  assert.equal(
    agentPresetForSession('gb-main', 'phone-bot', 'phone-bot-maintainer'),
    'phone-bot')
  assert.equal(
    agentPresetForSession('gb-task-1', 'phone-bot', 'phone-bot-maintainer'),
    'phone-bot')
  assert.equal(
    agentPresetForSession('gb-verifier-abc', 'phone-bot', 'phone-bot-maintainer'),
    'pdsh-verifier')

  const selected: Array<[string, string]> = []
  const selector: BotAgentPresetSelector = {
    async select(agent, preset) {
      selected.push([agent.id, preset])
      return preset
    },
  }
  const { selectBotAgentPreset } = await import('../bot-runtime/src/volatile-context.ts')
  const agent = { id: 'gb-maintainer-0123456789abcdef0123456789abcdef' }
  await selectBotAgentPreset(selector, agent as never, 'phone-bot-maintainer')
  assert.deepEqual(selected, [[agent.id, 'phone-bot-maintainer']])
})
