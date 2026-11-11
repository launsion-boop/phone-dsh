// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import { createScope } from '@deepseek-ai/dsh-scope'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import * as nativeExecutor from '@deepseek-ai/dsh-tool-executor-native'
import * as verifierScope from '../lifecycle-gate/src/verifier-scope.ts'
import * as restrictedGuard from '../lifecycle-gate/src/restricted-guard.ts'

const fixture = JSON.parse(readFileSync(
  new URL('../../spec/bot/v1/golden/verification.phone.json', import.meta.url), 'utf8',
)) as {
  policy: { tools: string[]; bash: { allowed: string[]; denied: string[] } }
}

function tool(name: string, run: () => void) {
  return defineTool({
    name, description: `verifier scope test tool ${name}`,
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { run(); return 'ran' },
  })
}

async function execute(ctx: Context, name: string, args: unknown, agent: { session: { id: string } }) {
  const batch = await ctx.tools.execute({
    calls: [{ type: 'tool-call', id: ToolCallId(`call-${name}-${Math.random()}`), name, arguments: JSON.stringify(args) }],
    agent: agent as never,
    signal: new AbortController().signal,
  })
  return batch.results[0]?.result
}

test('the shared verifier vectors drive the read-only bash rule', () => {
  assert.deepEqual(fixture.policy.tools, ['read', 'grep', 'glob', 'bash'])
  for (const command of fixture.policy.bash.allowed) {
    assert.equal(verifierScope.isReadOnlyBashCommand(command), true, command)
  }
  for (const command of fixture.policy.bash.denied) {
    assert.equal(verifierScope.isReadOnlyBashCommand(command), false, command)
  }
})

test('verifier scope hides inherited globals and keeps only read-only local tools', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  let ran = 0
  ctx.tools.register(tool('write', () => { ran++ }))
  ctx.tools.register(tool('Task', () => { ran++ }))
  const agent = { session: { id: 'gb-verifier-test', header: { agentPreset: 'pdsh-verifier' } } }
  const scope = createScope(ctx, agent)
  try {
    await scope.ctx.plugin(verifierScope)
    await scope.ctx.plugin({
      name: 'verifier-local-tools',
      inject: ['tools'],
      apply(scoped) {
        for (const name of ['read', 'grep', 'glob', 'bash']) {
          scoped.tools.register(tool(name, () => { ran++ }))
        }
      },
    })
    assert.deepEqual(ctx.tools.schemas(agent as never).map(item => item.name).sort(),
      ['bash', 'glob', 'grep', 'read'])

    assert.equal((await execute(ctx, 'read', { file_path: 'notes.md' }, agent))?.isError, false)
    assert.equal(ran, 1)
    assert.equal((await execute(ctx, 'write', { file_path: 'out.txt' }, agent))?.isError, true)
    assert.equal((await execute(ctx, 'Task', { prompt: 'x' }, agent))?.isError, true)
    assert.equal(ran, 1)

    assert.equal((await execute(ctx, 'bash', { command: 'cat notes.md' }, agent))?.isError, false)
    assert.equal((await execute(ctx, 'bash',
      { command: 'phone record read record://session/gb-task-abc#2 --around 2' }, agent))?.isError, false)
    assert.equal((await execute(ctx, 'bash', { command: 'printf x > out.txt' }, agent))?.isError, true)
    assert.equal((await execute(ctx, 'bash', { command: 'sed -i s/a/b/ notes.md' }, agent))?.isError, true)
    assert.equal(ran, 3)
  } finally {
    await scope.dispose()
    await ctx.fiber.dispose()
  }
})

test('the global verifier guard denies writes even without the preset scope', async () => {
  const ctx = new Context()
  try {
    await ctx.plugin(SystemPrompt)
    await ctx.plugin(ToolRuntime)
    await ctx.plugin(nativeExecutor)
    ctx.tools.register(tool('read', () => {}))
    ctx.tools.register(tool('write', () => {}))
    await ctx.plugin(restrictedGuard)

    const verifier = { session: { id: 'gb-verifier-global', header: { agentPreset: 'pdsh-verifier' } } }
    const ordinary = { session: { id: 'gb-main', header: { agentPreset: 'phone' } } }
    assert.equal((await execute(ctx, 'read', { file_path: 'notes.md' }, verifier))?.isError, false)
    assert.equal((await execute(ctx, 'write', { file_path: 'out.txt' }, verifier))?.isError, true)
    assert.equal((await execute(ctx, 'write', { file_path: 'out.txt' }, ordinary))?.isError, false)
  } finally {
    await ctx.fiber.dispose()
  }
})
