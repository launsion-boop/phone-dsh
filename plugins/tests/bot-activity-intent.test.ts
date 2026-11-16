// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import activityIntent from '../bot-runtime/src/activity-intent.ts'
import { createAgent, mountRuntime } from './bot-runtime-test-kit.ts'

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

test('real ToolRuntime exposes activity only on the five Bot-scoped tools', async () => {
  const ctx = await mountRuntime()
  try {
    for (const name of NAMES) ctx.tools.register(probe(name))
    const agent = await createAgent(ctx, 'gb-activity-schema')
    await agent.ctx.plugin(activityIntent)
    const schemas = ctx.tools.schemas(agent)
    for (const name of NAMES) {
      const parameters = schemaFor(schemas, name)
      assert.equal(parameters.properties?.activity?.type, 'string')
      assert.equal(parameters.properties?.activity?.maxLength, 160)
      assert.equal(parameters.required?.includes('activity') ?? false, false)
    }
    const workbench = await createAgent(ctx, 'workbench-activity-schema')
    const workbenchSchemas = ctx.tools.schemas(workbench)
    for (const name of NAMES) {
      assert.equal(schemaFor(workbenchSchemas, name).properties?.activity, undefined)
    }
  } finally {
    await ctx.fiber.dispose()
  }
})

test('activity stays in tool/call arguments but never reaches the original handler', async () => {
  const ctx = await mountRuntime()
  try {
    const seen: unknown[] = []
    ctx.tools.register(probe('read', seen))
    const agent = await createAgent(ctx, 'gb-activity-execute')
    await agent.ctx.plugin(activityIntent)
    const result = await ctx.tools.execute({
      calls: [{
        type: 'tool-call',
        id: ToolCallId('activity-read-1'),
        name: 'read',
        arguments: JSON.stringify({ file_path: '/dsh/workspace/notes.md', activity: '定位 #174 的合并资料' }),
      }],
      signal: new AbortController().signal,
      agent,
      log: { turn: 1, step: 1 },
    })
    assert.equal(result.results[0]?.result.isError, false)
    assert.deepEqual(seen, [{ file_path: '/dsh/workspace/notes.md' }])
    const call = agent.session.snapshotEvents().find(event => event.type === 'tool/call')
    assert.ok(call)
    const parsed = JSON.parse(call.data.arguments) as Record<string, unknown>
    assert.equal(parsed.activity, '定位 #174 的合并资料')
    assert.equal(parsed.file_path, '/dsh/workspace/notes.md')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a late or re-registered global tool is re-wrapped without restarting the agent', async () => {
  const ctx = await mountRuntime()
  try {
    const agent = await createAgent(ctx, 'gb-activity-reconnect')
    await agent.ctx.plugin(activityIntent)
    assert.equal(ctx.tools.schemas(agent).some(entry => entry.name === 'read'), false)

    const first = probe('read')
    const disposeFirst = ctx.tools.register(first)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(schemaFor(ctx.tools.schemas(agent), 'read').properties?.activity?.type, 'string')

    disposeFirst()
    const second = probe('read')
    ctx.tools.register(second)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(schemaFor(ctx.tools.schemas(agent), 'read').properties?.activity?.type, 'string')
  } finally {
    await ctx.fiber.dispose()
  }
})
