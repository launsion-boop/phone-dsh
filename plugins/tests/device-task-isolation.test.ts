// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope } from '@deepseek-ai/dsh-scope'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import * as nativeExecutor from '@deepseek-ai/dsh-tool-executor-native'
import * as isolation from '../lifecycle-gate/src/device-scope.ts'

function tool(name: string, run: () => void) {
  return defineTool({
    name, description: 'test device task isolation', parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { run(); return 'ran' },
  })
}

test('device scope hides present and future global tools and denies scoped tools', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  let ran = 0
  ctx.tools.register(tool('before', () => { ran++ }))
  const agent = { session: { id: 'device-task-test' } }
  const scope = createScope(ctx, agent)
  try {
    await scope.ctx.plugin(isolation)
    ctx.tools.register(tool('after', () => { ran++ }))
    assert.deepEqual(ctx.tools.schemas(agent).map(x => x.name), [])
    assert.deepEqual(ctx.tools.schemas().map(x => x.name).sort(), ['after', 'before'])
    const hidden = await ctx.tools.execute({calls: [{type: 'tool-call', id: ToolCallId('before'), name: 'before', arguments: '{}'}], agent: agent as never, signal: new AbortController().signal})
    assert.equal(hidden.results[0]?.result.isError, true)
    await scope.ctx.plugin({name: 'scoped-test-tool', inject: ['tools'], apply(scoped) { scoped.tools.register(tool('local', () => { ran++ })) }})
    const scoped = await ctx.tools.execute({calls: [{type: 'tool-call', id: ToolCallId('local'), name: 'local', arguments: '{}'}], agent: agent as never, signal: new AbortController().signal})
    assert.equal(scoped.results[0]?.result.isError, true)
    assert.equal(ran, 0)
    const normal = await ctx.tools.execute({calls: [{type: 'tool-call', id: ToolCallId('normal'), name: 'after', arguments: '{}'}], signal: new AbortController().signal})
    assert.equal(normal.results[0]?.result.isError, false)
    assert.equal(ran, 1)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('immutable device session header denies tools even after scope changes', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  const guard = await import('../lifecycle-gate/src/device-guard.ts')
  await ctx.plugin(guard)
  let ran = 0
  ctx.tools.register(tool('available', () => { ran++ }))
  try {
    const deviceAgent = { session: { id: 'device-session', header: { agentPreset: 'pdsh-device-task' } } }
    const denied = await ctx.tools.execute({calls: [{type: 'tool-call', id: ToolCallId('device'), name: 'available', arguments: '{}'}], agent: deviceAgent as never, signal: new AbortController().signal})
    assert.equal(denied.results[0]?.result.isError, true)
    assert.equal(ran, 0)
    const normalAgent = { session: { id: 'normal-session', header: { agentPreset: 'standard' } } }
    const allowed = await ctx.tools.execute({calls: [{type: 'tool-call', id: ToolCallId('normal2'), name: 'available', arguments: '{}'}], agent: normalAgent as never, signal: new AbortController().signal})
    assert.equal(allowed.results[0]?.result.isError, false)
    assert.equal(ran, 1)
  } finally { await ctx.fiber.dispose() }
})
