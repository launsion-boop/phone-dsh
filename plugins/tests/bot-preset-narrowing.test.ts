// SPDX-License-Identifier: MIT
// The phone Worker image inherits the `dsh-base` global tool rows (the official
// Web-app bundle that disables them is not materialized), and a session started
// before the explicit `phone-bot` creation header can also carry the wider
// `standard` composition. DSH cannot recompose a started session
// (`agent-preset/locked`), so the per-agent allow-list is the supported
// migration: the conversation survives and the model only sees the contract
// surface (the phone-bot native tools plus the App MCP catalog).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope } from '@deepseek-ai/dsh-scope'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import * as nativeExecutor from '@deepseek-ai/dsh-tool-executor-native'
import dshbotVolatileContext, {
  narrowBotToolSurface,
  type BotAgentPresetSelector,
} from '../bot-runtime/src/volatile-context.ts'
import { PHONE_NATIVE_TOOLS } from '../bot-runtime/src/prompt/assemble.ts'

function tool(name: string, run: () => void = () => {}) {
  return defineTool({
    name, description: `bot preset narrowing test tool ${name}`, parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { run(); return 'ran' },
  })
}

async function execute(ctx: Context, name: string, agent: object) {
  const batch = await ctx.tools.execute({
    calls: [{
      type: 'tool-call', id: ToolCallId(`call-${name}-${Math.random()}`),
      name, arguments: '{}',
    }],
    agent: agent as never,
    signal: new AbortController().signal,
  })
  return batch.results[0]?.result
}

interface ScopedTools {
  register(definition: ReturnType<typeof tool>): () => void
}

async function registerTools(
  scope: ReturnType<typeof createScope>, names: readonly string[],
  counted: (name: string) => ReturnType<typeof tool>,
): Promise<void> {
  await scope.ctx.plugin({
    name: 'test-scope-tools',
    inject: ['tools'],
    apply(scoped) {
      const tools = (scoped as unknown as { tools: ScopedTools }).tools
      for (const name of names) tools.register(counted(name))
    },
  })
}

interface Boot {
  ctx: Context
  agent: { id: string; session: { id: string; header?: { agentPreset: string } }; ctx?: Context }
  standardKey: object
  ran: () => number
}

/**
 * Boot one Worker-shaped world: global base/reconnect tools, the composition
 * scope the agent actually mounted, and an agent scope parented to it.
 */
async function boot(options: {
  header: string
  selection: 'committed' | 'locked'
  withScopedRegistry?: boolean
}): Promise<Boot> {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  let ran = 0
  const counted = (name: string) => tool(name, () => { ran++ })
  // A real agent ctx is minted from a context that injects `tools`; mirror
  // that here so `agent.ctx.tools` is reachable exactly as in production.
  let scopeHost!: Context
  await ctx.plugin({
    name: 'test-scope-host', inject: ['tools'],
    apply(host) { scopeHost = host },
  })

  // The App MCP catalog and the inherited `dsh-base` global rows (the leaks).
  for (const name of ['mcp__phone__SendToUser', 'mcp__phone__UpdateMemory',
    'subagent', 'skill', 'working_directory', 'read_image', 'list_mcp_resources']) {
    ctx.tools.register(counted(name))
  }

  // The composition the session mounted (`standard` or `phone-bot`). Both
  // register the native contract tools; `standard` adds the forbidden rows.
  const standardKey = {}
  const composition = createScope(scopeHost, standardKey)
  const compositionTools = [...PHONE_NATIVE_TOOLS]
  if (options.header !== 'phone-bot') {
    compositionTools.push('subagent', 'subagent_fork', 'schedule_create', 'skill', 'exit_plan_mode')
  }
  await registerTools(composition, compositionTools, counted)

  const agent: Boot['agent'] = {
    id: 'gb-main', session: { id: 'gb-main', header: { agentPreset: options.header } },
  }
  if (options.withScopedRegistry !== false) {
    const agentScope = createScope(scopeHost, agent, { parent: standardKey })
    agent.ctx = agentScope.ctx
  }

  const presets: BotAgentPresetSelector = {
    async select(_agent, preset) {
      if (options.selection === 'locked') {
        throw Object.assign(new Error('This session has already started'), {
          code: 'agent-preset/locked',
        })
      }
      return preset
    },
  }
  ctx.provide('agentPresets', presets)
  await ctx.plugin(dshbotVolatileContext, {
    botAgentPreset: 'phone-bot',
    now: () => new Date('2026-11-06T08:09:59.900Z'),
    lang: () => 'en' as const,
    source: async () => ({}),
  })
  return { ctx, agent, standardKey, ran: () => ran }
}

function toolsOf(ctx: Context, scope: object): string[] {
  return ctx.tools.definitions(scope as never).map(definition => definition.name).sort()
}

const EXPECTED = [...PHONE_NATIVE_TOOLS, 'mcp__phone__SendToUser', 'mcp__phone__UpdateMemory']
  .sort()

test('a new phone-bot session hides inherited dsh-base tools', async () => {
  const fixture = await boot({ header: 'phone-bot', selection: 'committed' })
  try {
    await fixture.ctx.serial('agent/created', {
      agent: fixture.agent as never, source: 'startup',
    })
    assert.deepEqual(toolsOf(fixture.ctx, fixture.agent), EXPECTED,
      'only the phone-bot contract surface plus the App MCP catalog may stay')
    assert.equal((await execute(fixture.ctx, 'read', fixture.agent))?.isError, false)
    for (const hidden of ['subagent', 'skill', 'working_directory', 'read_image', 'list_mcp_resources']) {
      assert.equal((await execute(fixture.ctx, hidden, fixture.agent))?.isError, true, hidden)
    }

    // A tool registered after the snapshot is hidden by the tools/change
    // convergence and blocked by the guard even before the next prompt.
    fixture.ctx.tools.register(tool('late_base_extra'))
    assert.equal(toolsOf(fixture.ctx, fixture.agent).includes('late_base_extra'), false)
    assert.equal((await execute(fixture.ctx, 'late_base_extra', fixture.agent))?.isError, true)

    // The App MCP catalog may reconnect after the session resumes; its tools
    // stay visible and executable.
    fixture.ctx.tools.register(tool('mcp__phone__NewTool'))
    assert.equal(toolsOf(fixture.ctx, fixture.agent).includes('mcp__phone__NewTool'), true)
    assert.equal((await execute(fixture.ctx, 'mcp__phone__NewTool', fixture.agent))?.isError, false)

    // A tool registered directly in the agent scope is exempt from DSH's
    // restriction, so the same-predicate guard is the execution boundary.
    await (fixture.agent.ctx as Context).plugin({
      name: 'test-own-tool', inject: ['tools'],
      apply(scoped) {
        (scoped as unknown as { tools: ScopedTools }).tools.register(tool('own_extra'))
      },
    })
    assert.ok(toolsOf(fixture.ctx, fixture.agent).includes('own_extra'))
    assert.equal((await execute(fixture.ctx, 'own_extra', fixture.agent))?.isError, true)
  } finally {
    await fixture.ctx.fiber.dispose()
  }
})

test('a resumed standard Bot session is narrowed to the same surface', async () => {
  const fixture = await boot({ header: 'standard', selection: 'locked' })
  try {
    assert.ok(toolsOf(fixture.ctx, fixture.agent).includes('subagent'))
    await fixture.ctx.serial('agent/created', {
      agent: fixture.agent as never, source: 'resume',
    })
    assert.deepEqual(toolsOf(fixture.ctx, fixture.agent), EXPECTED)
    for (const hidden of ['subagent', 'subagent_fork', 'schedule_create', 'skill', 'exit_plan_mode']) {
      assert.equal((await execute(fixture.ctx, hidden, fixture.agent))?.isError, true, hidden)
    }
    // The restriction is per agent: an untouched workbench composition still
    // sees its own rows.
    assert.ok(toolsOf(fixture.ctx, fixture.standardKey).includes('subagent'))
  } finally {
    await fixture.ctx.fiber.dispose()
  }
})

test('a legacy Bot session without a scoped registry fails closed', async () => {
  const fixture = await boot({
    header: 'standard', selection: 'locked', withScopedRegistry: false,
  })
  try {
    await assert.rejects(
      fixture.ctx.serial('agent/created', {
        agent: fixture.agent as never, source: 'resume',
      }),
      /gb-main.*cannot be pinned.*refusing to run the Bot turn/i)
  } finally {
    await fixture.ctx.fiber.dispose()
  }
})

test('an agent whose composition exposes no Bot tools fails closed', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  let scopeHost!: Context
  await ctx.plugin({
    name: 'test-scope-host', inject: ['tools'],
    apply(host) { scopeHost = host },
  })
  const agent: { id: string; session: { id: string }; ctx?: Context } = {
    id: 'gb-empty', session: { id: 'gb-empty' },
  }
  const scope = createScope(scopeHost, agent)
  agent.ctx = scope.ctx
  try {
    assert.throws(() => narrowBotToolSurface(agent as never), /no scoped tool registry|exposed no tools/)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('non-Bot sessions with a locked composition are left untouched', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  ctx.tools.register(tool('read'))
  const workbench = { id: 'session-workbench', session: { id: 'session-workbench' } }
  try {
    ctx.provide('agentPresets', {
      async select() {
        throw Object.assign(new Error('This session has already started'), {
          code: 'agent-preset/locked',
        })
      },
    })
    await ctx.plugin(dshbotVolatileContext, {
      botAgentPreset: 'phone-bot', source: async () => ({}),
    })
    await ctx.serial('agent/created', { agent: workbench as never, source: 'resume' })
    assert.deepEqual(toolsOf(ctx, workbench), ['read'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a locked restricted session is never narrowed to the Bot surface', async () => {
  const ctx = new Context()
  try {
    await ctx.plugin(SystemPrompt)
    await ctx.plugin(ToolRuntime)
    await ctx.plugin(nativeExecutor)
    ctx.provide('agentPresets', {
      async select() {
        throw Object.assign(new Error('This session has already started'), {
          code: 'agent-preset/locked',
        })
      },
    })
    await ctx.plugin(dshbotVolatileContext, {
      botAgentPreset: 'phone-bot',
      maintainerAgentPreset: 'phone-bot-maintainer',
      source: async () => ({}),
    })
    // The prefix is the transport-dropped-header fallback: the frozen preset
    // is selected when possible, but it is never the ordinary Bot surface.
    await ctx.serial('agent/created', {
      agent: { id: 'gb-verifier-locked', session: { id: 'gb-verifier-locked' } } as never,
      source: 'resume',
    })
  } finally {
    await ctx.fiber.dispose()
  }
})
