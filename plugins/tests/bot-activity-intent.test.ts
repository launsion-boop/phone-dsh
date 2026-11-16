// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope, scopeOf } from '@deepseek-ai/dsh-scope'
import { defineTool } from '@deepseek-ai/dsh-tools'
import activityIntent from '../bot-runtime/src/activity-intent.ts'
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
  await new Promise(resolve => setImmediate(resolve))
  return { presetKey, preset, agent, agentScope, scope: agent }
}

test('the shadow wraps the Bot-scope handler, not the global handler', async () => {
  const ctx = await mountRuntime()
  const globalSeen: unknown[] = []
  const botSeen: unknown[] = []
  try {
    ctx.tools.register(probe('read', globalSeen))
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
  try {
    const flags = { search: false, fetch: false }
    ctx.provide('web', {
      searchReady: () => flags.search,
      fetchReady: () => flags.fetch,
    })
    const presetKey = {}
    const preset = createScope(ctx, presetKey)
    await registerInScope(preset, probe('web_search'))
    await registerInScope(preset, probe('web_fetch'))
    await ctx.plugin(activityIntent)
    const agent = { id: 'gb-activity-web', session: { id: 'gb-activity-web' } } as { id: string; session: { id: string }; ctx?: Context }
    const agentScope = createScope(ctx, agent, { parent: presetKey })
    agent.ctx = agentScope.ctx
    await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })
    await new Promise(resolve => setImmediate(resolve))
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
  } finally {
    await ctx.fiber.dispose()
  }
})


