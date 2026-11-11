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

function tool(name: string, run: () => void) {
  return defineTool({
    name, description: `verifier scope test tool ${name}`,
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { run(); return 'ran' },
  })
}

const fixture = JSON.parse(readFileSync(
  new URL('../../spec/bot/v1/golden/verification.phone.json', import.meta.url), 'utf8',
)) as {
  policy: { tools: string[]; bash: { allowed: string[]; denied: string[] } }
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
  const counted = (name: string) => defineTool({
    name, description: `verifier scope test tool ${name}`, parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute() { ran++; return 'ran' },
  })
  let host!: Context
  await ctx.plugin({ name: 'verifier-host', inject: ['tools'], apply(scoped) { host = scoped } })
  // The phone Worker image inherits the dsh-base global tool rows, including
  // the four names the verifier preset also mounts.
  for (const name of ['read', 'write', 'edit', 'grep', 'glob', 'bash', 'Task', 'subagent']) {
    ctx.tools.register(counted(name))
  }
  // The production shape: a preset scope owns the verifier tool rows and the
  // isolation row; the Agent is parented to that preset scope.
  const presetKey = {}
  const presetScope = createScope(host, presetKey)
  try {
    await presetScope.ctx.plugin({
      name: 'verifier-preset-tools',
      inject: ['tools'],
      apply(scoped) {
        for (const name of ['read', 'grep', 'glob', 'bash']) scoped.tools.register(counted(name))
      },
    })
    await presetScope.ctx.plugin(verifierScope)
    const agent = {
      id: 'gb-verifier-scope-test',
      session: { id: 'gb-verifier-scope-test', header: { agentPreset: 'pdsh-verifier' } },
    }
    const agentScope = createScope(host, agent, { parent: presetKey })
    ;(agent as { ctx?: Context }).ctx = agentScope.ctx
    try {
      await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })

      // The Agent, not the preset scope, is the surface the model sees.
      assert.deepEqual(ctx.tools.schemas(agent as never).map(item => item.name).sort(),
        ['bash', 'glob', 'grep', 'read'])
      // The shared preset scope stays wide; only the agent's own surface is
      // filtered, so sibling consumers of the preset are not affected.
      assert.deepEqual(ctx.tools.schemas(presetKey as never).map(item => item.name).sort(),
        ['Task', 'bash', 'edit', 'glob', 'grep', 'read', 'subagent', 'write'])

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

      // An allow-list is future-proof: a global tool registered after the
      // filter stays hidden without a second convergence pass.
      ctx.tools.register(counted('late_global_tool'))
      assert.deepEqual(ctx.tools.schemas(agent as never).map(item => item.name).sort(),
        ['bash', 'glob', 'grep', 'read'])
      assert.equal((await execute(ctx, 'late_global_tool', {}, agent))?.isError, true)
    } finally {
      await agentScope.dispose()
    }
  } finally {
    await presetScope.dispose()
    await ctx.fiber.dispose()
  }
})

test('verifier visibility never leaves a restricted session empty', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(nativeExecutor)
  let host!: Context
  await ctx.plugin({ name: 'verifier-host-empty', inject: ['tools'], apply(scoped) { host = scoped } })
  const agent = {
    id: 'gb-verifier-empty',
    session: { id: 'gb-verifier-empty', header: { agentPreset: 'pdsh-verifier' } },
  }
  const scope = createScope(host, agent)
  ;(agent as { ctx?: Context }).ctx = scope.ctx
  try {
    // Production always inherits read/grep/glob/bash from dsh-base. Even when
    // only some are registered, the filter waits instead of installing an
    // empty or partial allow-list.
    for (const name of ['read', 'grep', 'glob', 'bash']) ctx.tools.register(
      defineTool({
        name, description: `verifier empty probe ${name}`, parameters: {},
        output: { schema: { type: 'string' }, render: () => [{ type: 'text', text: 'ok' }] },
        async execute() { return 'ok' },
      }))
    await scope.ctx.plugin(verifierScope)
    await ctx.serial('agent/created', { agent: agent as never, source: 'startup' })
    assert.deepEqual(ctx.tools.schemas(agent as never).map(item => item.name).sort(),
      ['bash', 'glob', 'grep', 'read'])
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
