// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope } from '@deepseek-ai/dsh-scope'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
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
  let ran = 0
  ctx.tools.register(tool('before', () => { ran++ }))
  const agent = { session: { id: 'device-task-test' } }
  const scope = createScope(ctx, agent)
  try {
    await scope.ctx.plugin(isolation)
    ctx.tools.register(tool('after', () => { ran++ }))
    assert.deepEqual(ctx.tools.schemas(agent).map(x => x.name), [])
    assert.deepEqual(ctx.tools.schemas().map(x => x.name).sort(), ['after', 'before'])
    const hidden = await ctx.tools.execute({callId: ToolCallId('before'), name: 'before', arguments: {}, agent: agent as never, signal: new AbortController().signal})
    assert.equal(hidden.isError, true)
    await scope.ctx.plugin({name: 'scoped-test-tool', inject: ['tools'], apply(scoped) { scoped.tools.register(tool('local', () => { ran++ })) }})
    const scoped = await ctx.tools.execute({callId: ToolCallId('local'), name: 'local', arguments: {}, agent: agent as never, signal: new AbortController().signal})
    assert.equal(scoped.isError, true)
    assert.equal(ran, 0)
    const normal = await ctx.tools.execute({callId: ToolCallId('normal'), name: 'after', arguments: {}, signal: new AbortController().signal})
    assert.equal(normal.isError, false)
    assert.equal(ran, 1)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})
