// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope, scopeOf } from '@deepseek-ai/dsh-scope'
import { defineTool } from '@deepseek-ai/dsh-tools'
import activityIntent from '../bot-runtime/src/activity-intent.ts'
import { botOwnedSessions } from '../bot-runtime/src/bot-sessions.ts'
import { mountRuntime } from './bot-runtime-test-kit.ts'

const NAMES = ['read', 'glob', 'grep', 'web_search', 'web_fetch'] as const

function probe(name: string, seen: unknown[] = []) {
  return defineTool({
    name,
    description: `probe ${name}`,
    parameters: {
      ...(name === 'read' ? { file_path: { type: 'string', required: true } } : {}),
      ...(name === 'glob' || name === 'grep' ? { pattern: { type: 'string', required: true } } : {}),
      ...(name === 'web_search' ? { queries: { type: 'array', required: true, items: { type: 'string' } } } : {}),
      ...(name === 'web_fetch' ? { url: { type: 'string', required: true } } : {}),
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    execute: async args => {
      seen.push(args)
      return 'ok'
    },
  })
}

function schemaFor(schemas: readonly { name: string; parameters: unknown }[], name: string) {
  const schema = schemas.find(entry => entry.name === name)
  assert.ok(schema, `${name} schema must exist`)
  return schema.parameters as {
    properties?: Record<string, { type?: string; maxLength?: number }>
    required?: string[]
  }
}

async function registerInScope(scope: ReturnType<typeof createScope>, tool: ReturnType<typeof probe>): Promise<() => void> {
  let dispose: (() => void) | undefined
  await scope.ctx.plugin({
    inject: ['tools'],
    apply(scoped: Context) {
      dispose = scoped.tools.register(tool)
    },
  })
  assert.ok(dispose)
  return dispose
}

/** Production shape: preset scope owns the Bot tool, Agent is its child. */
interface EventSink {
  readonly events: { type: string; data: Record<string, unknown> }[]
}

async function productionAgent(
  root: Context,
  id: string,
  presetRead: ReturnType<typeof probe>,
  sink?: EventSink,
) {
  const presetKey = {}
  const preset = createScope(root, presetKey)
  await registerInScope(preset, presetRead)
  await root.plugin(activityIntent)
  botOwnedSessions(root).add(id)
  const session = sink === undefined
    ? { id }
    : {
        id,
        append(type: string, data: Record<string, unknown>) {
          sink.events.push({ type, data })
          return { seq: sink.events.length - 1 }
        },
        snapshotEvents() { return sink.events },
      }
  const agent = { id, session } as { id: string; session: { id: string }; ctx?: Context }
  const agentScope = createScope(root, agent, { parent: presetKey })
  agent.ctx = agentScope.ctx
  await root.serial('agent/created', { agent: agent as never, source: 'startup' })
  return { presetKey, preset, agent, agentScope, scope: agent }
}

test('activity-intent is a global profile row, not a preset row', () => {
  const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
  const profile = readFileSync(join(repository, 'plugins/profile/phone.worker.cordis.patch.yml'), 'utf8')
  const preset = profile.indexOf('    - id: preset-phone-bot\n')
  const maintainer = profile.indexOf('    - id: preset-phone-bot-maintainer\n')
  const identity = profile.indexOf('    - id: dshbot-identity-bridge\n')
  const activity = profile.indexOf('    - id: dshbot-activity-intent\n')
  const approval = profile.indexOf('    - id: dshbot-approval-gate\n')
  assert.ok(preset >= 0 && maintainer > preset)
  assert.ok(identity >= 0 && activity > identity && activity < approval)
  assert.equal(activity > preset && activity < maintainer, false,
    'activity-intent must not be mounted inside preset-phone-bot')
  assert.ok(profile.includes("name: '@phone-dsh/dsh-bot-runtime/activity-intent'"))
})

test('a claimed legacy non-gb Bot still receives activity', async () => {
  const ctx = await mountRuntime()
  try {
    const { agent } = await productionAgent(ctx, 'legacy-bot-session', probe('read'))
    assert.ok(agent.ctx)
    const scope = scopeOf(agent.ctx)
    assert.ok(scope)
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'read').properties?.activity?.type, 'string')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('apply does not claim the shared Bot ownership service', async () => {
  const ctx = await mountRuntime()
  try {
    await ctx.plugin(activityIntent)
    assert.equal(ctx.get('dshbotOwnedSessions'), undefined,
      'activity-intent must wait for the channel/identity provider; creating it at apply races them')
    const presetKey = {}
    const preset = createScope(ctx, presetKey)
    const agent = { id: 'gb-activity-owned-late', session: { id: 'gb-activity-owned-late' } } as { id: string; session: { id: string }; ctx?: Context }
    const agentScope = createScope(ctx, agent, { parent: presetKey })
    agent.ctx = agentScope.ctx
    await registerInScope(preset, probe('read'))
    botOwnedSessions(ctx).add(agent.id)
    await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })
    const scope = scopeOf(agentScope.ctx)
    assert.ok(scope)
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'read').properties?.activity?.type, 'string')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('the shadow wraps the Bot-scope handler, not the global handler', async () => {
  const ctx = await mountRuntime()
  const globalSeen: unknown[] = []
  const botSeen: unknown[] = []
  const globalOnlySeen: unknown[] = []
  try {
    ctx.tools.register(probe('read', globalSeen))
    ctx.tools.register(probe('grep', globalOnlySeen))
    const { preset, agent } = await productionAgent(ctx, 'gb-activity-schema', probe('read', botSeen))
    const scope = scopeOf((agent as { ctx: Context }).ctx)
    assert.ok(scope)

    const parameters = schemaFor(ctx.tools.schemas(scope), 'read')
    assert.equal(parameters.properties?.activity?.type, 'string')
    assert.equal(parameters.properties?.activity?.maxLength, 160)
    assert.equal(parameters.required?.includes('activity') ?? false, false)

    const wrapped = ctx.tools.get('read', scope)
    assert.ok(wrapped)
    await wrapped!.execute({ file_path: '/dsh/workspace/notes.md', activity: '定位 #174 的合并资料' }, {} as never)
    assert.deepEqual(botSeen, [{ file_path: '/dsh/workspace/notes.md' }])
    assert.deepEqual(globalSeen, [])
    assert.equal(schemaFor(ctx.tools.schemas(scopeOf(preset.ctx)), 'read').properties?.activity, undefined)
    assert.equal(schemaFor(ctx.tools.schemas(), 'read').properties?.activity, undefined)

    // A workbench agent is not Bot-owned; agent/created must not install.
    const workbench = { id: 'workbench-activity', session: { id: 'workbench-activity' } } as { id: string; session: { id: string }; ctx?: Context }
    const workbenchScope = createScope(ctx, workbench)
    workbench.ctx = workbenchScope.ctx
    await ctx.serial('agent/created', { agent: workbench as never, source: 'startup' })
    assert.equal(schemaFor(ctx.tools.schemas(workbench), 'read').properties?.activity, undefined)
    assert.equal(ctx.tools.get('read', workbench), ctx.tools.get('read'))
    // A Bot agent inherits a global tool that the preset did not restate: it
    // must stay the global definition and receive no activity field.
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'grep').properties?.activity, undefined)
    const globalOnly = ctx.tools.get('grep', scope)
    assert.ok(globalOnly)
    await globalOnly!.execute({ pattern: 'x' }, {} as never)
    assert.deepEqual(globalOnlySeen, [{ pattern: 'x' }])
    assert.deepEqual(botSeen, [{ file_path: '/dsh/workspace/notes.md' }])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('tool/call arguments retain activity while the real handler receives none', async () => {
  const ctx = await mountRuntime()
  const seen: unknown[] = []
  const sink: EventSink = { events: [] }
  try {
    const { agent } = await productionAgent(ctx, 'gb-activity-execute', probe('read', seen), sink)
    const result = await ctx.tools.execute({
      calls: [{
        type: 'tool-call',
        id: ToolCallId('activity-read-1'),
        name: 'read',
        arguments: JSON.stringify({ file_path: '/dsh/workspace/notes.md', activity: '定位 #174 的合并资料' }),
      }],
      signal: new AbortController().signal,
      agent: agent as never,
      log: { turn: 1, step: 1 },
    })
    assert.equal(result.results[0]?.result.isError, false)
    assert.deepEqual(seen, [{ file_path: '/dsh/workspace/notes.md' }])
    const call = sink.events.find(event => event.type === 'tool/call')
    assert.ok(call)
    const parsed = JSON.parse(String(call.data.arguments)) as Record<string, unknown>
    assert.equal(parsed.activity, '定位 #174 的合并资料')
    assert.equal(parsed.file_path, '/dsh/workspace/notes.md')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('web_search and web_fetch keep their provider readiness condition', async () => {
  const ctx = await mountRuntime()
  const searchSeen: unknown[] = []
  const fetchSeen: unknown[] = []
  const secondSearchSeen: unknown[] = []
  try {
    const flags = { search: false, fetch: false }
    ctx.provide('web', {
      searchReady: async () => flags.search,
      fetchReady: async () => flags.fetch,
    })
    const presetKey = {}
    const preset = createScope(ctx, presetKey)
    const disposeSearch = await registerInScope(preset, probe('web_search', searchSeen))
    await registerInScope(preset, probe('web_fetch', fetchSeen))
    await ctx.plugin(activityIntent)
    const agent = { id: 'gb-activity-web', session: { id: 'gb-activity-web' } } as { id: string; session: { id: string }; ctx?: Context }
    const agentScope = createScope(ctx, agent, { parent: presetKey })
    agent.ctx = agentScope.ctx
    botOwnedSessions(ctx).add(agent.id)
    await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })
    const scope = scopeOf(agentScope.ctx)
    assert.ok(scope)

    const admitted = async (): Promise<Set<string>> => {
      const set = await ctx.tools.resolve({
        agent: agent as never,
        modelSelection: { provider: 'mock', model: 'mock' },
        signal: new AbortController().signal,
      })
      try {
        return new Set(set.view(scope).keys())
      } finally {
        set.dispose()
      }
    }

    assert.equal((await admitted()).has('web_search'), false)
    assert.equal((await admitted()).has('web_fetch'), false)
    flags.search = true
    const searchOnly = await admitted()
    assert.equal(searchOnly.has('web_search'), true)
    assert.equal(searchOnly.has('web_fetch'), false)
    flags.fetch = true
    const both = await admitted()
    assert.equal(both.has('web_search'), true)
    assert.equal(both.has('web_fetch'), true)
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'web_search').properties?.activity?.type, 'string')
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'web_fetch').properties?.activity?.type, 'string')

    const search = ctx.tools.get('web_search', scope)
    const fetch = ctx.tools.get('web_fetch', scope)
    assert.ok(search)
    assert.ok(fetch)
    await search!.execute({ queries: ['#174'], activity: '定位 #174 的合并资料' }, {} as never)
    await fetch!.execute({ url: 'https://example.com/174', activity: '核对 #174 的合并资料' }, {} as never)
    assert.deepEqual(searchSeen, [{ queries: ['#174'] }])
    assert.deepEqual(fetchSeen, [{ url: 'https://example.com/174' }])

    // Re-registering the Bot web tool must update the stable shadow, keeping
    // the readiness condition and using the new Bot handler.
    disposeSearch()
    await new Promise(resolve => setImmediate(resolve))
    await registerInScope(preset, probe('web_search', secondSearchSeen))
    await new Promise(resolve => setImmediate(resolve))
    const renewed = ctx.tools.get('web_search', scope)
    assert.ok(renewed)
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'web_search').properties?.activity?.type, 'string')
    await renewed!.execute({ queries: ['#174'], activity: '对比 #174 与 main 的冲突' }, {} as never)
    assert.deepEqual(secondSearchSeen, [{ queries: ['#174'] }])
    assert.deepEqual(searchSeen, [{ queries: ['#174'] }])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('late Bot-scope registration and re-registration update the same shadow', async () => {
  const ctx = await mountRuntime()
  const firstSeen: unknown[] = []
  const secondSeen: unknown[] = []
  try {
    const presetKey = {}
    const preset = createScope(ctx, presetKey)
    await ctx.plugin(activityIntent)
    const agent = { id: 'gb-activity-reconnect', session: { id: 'gb-activity-reconnect' } } as { id: string; session: { id: string }; ctx?: Context }
    const agentScope = createScope(ctx, agent, { parent: presetKey })
    agent.ctx = agentScope.ctx
    botOwnedSessions(ctx).add(agent.id)
    await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })
    const scope = scopeOf(agentScope.ctx)
    assert.ok(scope)
    assert.equal(ctx.tools.schemas(scope).some(entry => entry.name === 'read'), false)

    const disposeFirst = await registerInScope(preset, probe('read', firstSeen))
    await new Promise(resolve => setImmediate(resolve))
    const first = ctx.tools.get('read', scope)
    assert.ok(first)
    await first!.execute({ file_path: '/a', activity: '定位 #174 的合并资料' }, {} as never)
    assert.deepEqual(firstSeen, [{ file_path: '/a' }])

    disposeFirst()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(ctx.tools.schemas(scope).some(entry => entry.name === 'read'), false)
    await registerInScope(preset, probe('read', secondSeen))
    await new Promise(resolve => setImmediate(resolve))
    const second = ctx.tools.get('read', scope)
    assert.ok(second)
    assert.equal(schemaFor(ctx.tools.schemas(scope), 'read').properties?.activity?.type, 'string')
    await second!.execute({ file_path: '/b', activity: '对比 #174 与 main 的冲突' }, {} as never)
    assert.deepEqual(secondSeen, [{ file_path: '/b' }])
    assert.deepEqual(firstSeen, [{ file_path: '/a' }])
  } finally {
    await ctx.fiber.dispose()
  }
})
