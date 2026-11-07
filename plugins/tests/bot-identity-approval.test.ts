// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import { BotRuntimeRemote, BotStreamHub } from '../bot-runtime/src/channel.ts'
import dshbotIdentityBridge, { argsDigest, needsIdentityRegistration } from '../bot-runtime/src/identity-bridge.ts'
import dshbotApprovalGate, { needsStructuralApproval, phoneEffectsForApproval } from '../bot-runtime/src/approval-gate.ts'

const WORKBENCH_SESSION = 'session-workbench'

function agent(id = 'gb-main'): Agent {
  return { id, session: { id } } as unknown as Agent
}

async function mount(withBot = true): Promise<Context> {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  if (withBot) registerProbe(ctx, 'mcp__phone__BotVolatileContext')
  return ctx
}

function registerProbe(ctx: Context, name = 'mcp__phone__ListRoutines'): void {
  ctx.tools.register(defineTool({
    name,
    description: 'probe',
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => 'ok',
  }))
}

test('ordinary DSH without Bot MCP never calls Bot identity or approval endpoints', async () => {
  const ctx = await mount(false)
  let calls = 0
  try {
    registerProbe(ctx, 'bash')
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => { calls += 1; return { ok: true, id: 'unexpected' } },
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { calls += 1; return { ok: true, allowed: true } },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('ordinary-bash'), name: 'bash',
      arguments: { command: 'rm -rf /tmp/wp7-artifact' },
      signal: new AbortController().signal, agent: agent(WORKBENCH_SESSION),
    })
    assert.equal(result.isError, false)
    assert.equal(calls, 0)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('workbench session keeps the ordinary DSH chain even when Bot MCP is visible', async () => {
  const ctx = await mount()
  let registrations = 0
  let approvals = 0
  let executed = 0
  try {
    ctx.tools.register(defineTool({
      name: 'bash', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => { executed += 1; return 'ok' },
    }))
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => { registrations += 1; return { ok: true, id: 'unexpected' } },
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('workbench-bash'), name: 'bash',
      arguments: { command: 'rm -rf /tmp/wp7-artifact' },
      signal: new AbortController().signal, agent: agent(WORKBENCH_SESSION),
    })
    assert.equal(result.isError, false)
    assert.equal(executed, 1)
    assert.equal(registrations, 0)
    assert.equal(approvals, 0)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('Bot session with unavailable Bot MCP fails closed', async () => {
  const ctx = await mount(false)
  let registrations = 0
  let approvals = 0
  let executed = 0
  try {
    ctx.tools.register(defineTool({
      name: 'bash', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => { executed += 1; return 'must-not-run' },
    }))
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => { registrations += 1; return { ok: true, id: 'unexpected' } },
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('unavailable-bash'), name: 'bash',
      arguments: { command: 'rm -rf /tmp/wp7-artifact' },
      signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, true)
    assert.equal(executed, 0)
    assert.equal(registrations, 0)
    assert.equal(approvals, 0)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('Bot session registers once, asks once and executes once', async () => {
  const ctx = await mount()
  const registrations: Record<string, unknown>[] = []
  const approvals: Record<string, unknown>[] = []
  const cancellations: string[] = []
  let executed = 0
  try {
    ctx.tools.register(defineTool({
      name: 'bash', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => { executed += 1; return 'ok' },
    }))
    await ctx.plugin(dshbotIdentityBridge, {
      request: async payload => {
        registrations.push(payload)
        return { ok: true, id: 'registration-bash' }
      },
      cancel: async id => { cancellations.push(id) },
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async payload => {
        approvals.push(payload)
        return { ok: true, allowed: true }
      },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('single-registration'), name: 'bash',
      arguments: { command: 'printf ONCE' },
      signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.equal(executed, 1)
    assert.equal(registrations.length, 1)
    assert.equal(approvals.length, 1)
    assert.deepEqual(cancellations, ['registration-bash'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('botClaimSession owns a legacy session id without the gb- namespace', async () => {
  const ctx = await mount()
  const hub = new BotStreamHub()
  const registrations: Record<string, unknown>[] = []
  let approvals = 0
  let executed = 0
  try {
    await ctx.plugin(channelCtx => { new BotRuntimeRemote(channelCtx, hub) })
    const remote = ctx.get('botRuntimeRemote') as {
      botClaimSession(request: { sessionId: string }): { ok: boolean; sessionId: string }
    }
    assert.deepEqual(remote.botClaimSession({ sessionId: 'session-legacy' }),
      { ok: true, sessionId: 'session-legacy' })
    ctx.tools.register(defineTool({
      name: 'bash', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => { executed += 1; return 'ok' },
    }))
    await ctx.plugin(dshbotIdentityBridge, {
      request: async payload => {
        registrations.push(payload)
        return { ok: true, id: 'legacy-registration' }
      },
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('legacy-bash'), name: 'bash',
      arguments: { command: 'printf LEGACY' },
      signal: new AbortController().signal, agent: agent('session-legacy'),
    })
    assert.equal(result.isError, false)
    assert.equal(executed, 1)
    assert.equal(registrations.length, 1)
    assert.equal(approvals, 1)
  } finally {
    hub.close()
    await ctx.fiber.dispose()
  }
})

test('pre-execute and execute share the pinned identity and cancel once', async () => {
  assert.equal(argsDigest({ secret: 'not-recorded' }), '9c58b105c0e3377b8052885445b4db03b3a2024b847396617dfd5152c05e9c06')
  assert.equal(argsDigest({ b: [1, true, null], a: { nested: '值' } }), argsDigest({ a: { nested: '值' }, b: [1, true, null] }))
  const ctx = await mount()
  const registrations: Record<string, unknown>[] = []
  const cancellations: string[] = []
  try {
    registerProbe(ctx)
    await ctx.plugin(dshbotIdentityBridge, {
      request: async payload => {
        registrations.push(payload)
        return { ok: true, id: 'registration-1' }
      },
      cancel: async id => { cancellations.push(id) },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('call-1'), name: 'mcp__phone__ListRoutines',
      arguments: { value: 1 }, signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.equal(registrations.length, 1)
    assert.equal(registrations[0]!.runtimeId, 'phone-worker')
    assert.equal(registrations[0]!.sessionId, 'gb-main')
    assert.equal(registrations[0]!.callId, 'call-1')
    assert.equal(registrations[0]!.argsDigest, argsDigest({ value: 1 }))
    assert.deepEqual(registrations[0]!.arguments, { value: 1 })
    assert.deepEqual(cancellations, ['registration-1'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('identical call IDs in independent sessions do not deadlock or overwrite identity', async () => {
  const ctx = await mount()
  const registrations: Record<string, unknown>[] = []
  let parentDidStart!: () => void
  const parentStarted = new Promise<void>(resolve => { parentDidStart = resolve })
  let childDidStart!: () => void
  const childStarted = new Promise<void>(resolve => { childDidStart = resolve })
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  try {
    ctx.tools.register(defineTool({
      name: 'mcp__phone__Task', description: 'probe', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async (_args, exec) => {
        if (exec.agent?.id === 'gb-parent') parentDidStart()
        else childDidStart()
        await gate
        return exec.agent?.id === 'gb-parent' ? 'parent' : 'child'
      },
    }))
    await ctx.plugin(dshbotIdentityBridge, {
      request: async payload => {
        registrations.push(payload)
        return { ok: true, id: `${String(payload.sessionId)}-registration` }
      },
      cancel: async () => {},
    })
    const args = { prompt: 'same', task_title: 'same' }
    const parent = ctx.tools.execute({
      callId: ToolCallId('shared'), name: 'mcp__phone__Task', arguments: args,
      signal: new AbortController().signal, agent: agent('gb-parent'),
    })
    await parentStarted
    const child = ctx.tools.execute({
      callId: ToolCallId('shared'), name: 'mcp__phone__Task', arguments: args,
      signal: new AbortController().signal, agent: agent('gb-child'),
    })
    const childState = await Promise.race([
      childStarted.then(() => 'started'),
      new Promise<string>(resolve => { setTimeout(() => { resolve('waiting') }, 100) }),
    ])
    const identities = ctx.get('dshbotIdentityCalls') as {
      get(callId: string, sessionId?: string): { sessionId: string } | undefined
    }
    const parentSession = identities.get('shared', 'gb-parent')?.sessionId
    const childSession = identities.get('shared', 'gb-child')?.sessionId
    finish()
    await parent
    await child
    assert.equal(childState, 'started')
    assert.equal(parentSession, 'gb-parent')
    assert.equal(childSession, 'gb-child')
    assert.equal(registrations.length, 2)
    assert.deepEqual(new Set(registrations.map(registration => registration.sessionId)),
      new Set(['gb-parent', 'gb-child']))
  } finally {
    finish()
    await ctx.fiber.dispose()
  }
})

test('identity unknown_tool fails closed for every registration-required tool', async () => {
  const names = ['bash', 'write', 'edit', 'mcp__phone__ListRoutines']
  for (const name of names) {
    assert.equal(needsIdentityRegistration(name), true)
    const ctx = await mount()
    let executed = 0
    try {
      ctx.tools.register(defineTool({
        name,
        description: 'probe',
        parameters: {},
        output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
        execute: async () => { executed += 1; return 'must-not-run' },
      }))
      await ctx.plugin(dshbotIdentityBridge, {
        request: async () => ({ ok: false, error: 'unknown_tool' }),
        cancel: async () => {},
      })
      const result = await ctx.tools.execute({
        callId: ToolCallId(`unknown-tool-${name}`), name, arguments: {},
        signal: new AbortController().signal, agent: agent(),
      })
      assert.equal(result.isError, true, `${name} must fail closed`)
      assert.equal(executed, 0, `${name} body must not run without App identity`)
    } finally {
      await ctx.fiber.dispose()
    }
  }
})

test('ReplyToDevice approval payload matches the shared host extension', async () => {
  const effects = phoneEffectsForApproval('mcp__phone__ReplyToDevice', { message: '已收到' })
  assert.equal(effects.length, 1)
  assert.equal(effects[0]!.tool, 'ReplyToDevice')
  assert.equal(effects[0]!.operation, 'device.reply')
  assert.equal(effects[0]!.resource, 'device:*')
  assert.equal(effects[0]!.target, '*')
  assert.equal(effects[0]!.mutability, 'external-send')
  assert.equal(effects[0]!.policy, 'ask')
  assert.equal(effects[0]!.execution, 'device-reply')
  assert.equal(effects[0]!.known, true)
  assert.equal(needsStructuralApproval('mcp__phone__ReplyToDevice'), true)
  assert.equal(needsIdentityRegistration('mcp__phone__ReplyToDevice'), true)

  const ctx = await mount()
  const payloads: Record<string, unknown>[] = []
  try {
    registerProbe(ctx, 'mcp__phone__ReplyToDevice')
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => ({ ok: true, id: 'device-reply-registration' }),
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async payload => {
        payloads.push(payload)
        return { ok: true, allowed: true }
      },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('device-reply'), name: 'mcp__phone__ReplyToDevice',
      arguments: { message: '已收到' }, signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.equal(payloads.length, 1)
    const proposed = payloads[0]!.effects as { operation: string; known: boolean; execution: string | null }[]
    assert.equal(proposed.length, 1)
    assert.equal(proposed[0]!.operation, 'device.reply')
    assert.equal(proposed[0]!.known, true)
    assert.equal(proposed[0]!.execution, 'device-reply')
    assert.equal(payloads[0]!.alwaysScope, 'until')
    assert.equal(payloads[0]!.deferConsumption, true)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('approval memory effect matches the Swift execution resource and sensitive reads never reach approval', async () => {
  const effects = phoneEffectsForApproval('mcp__phone__UpdateMemory', {
    action: 'forget', scope: 'user', fact: '  private   fact ',
  })
  assert.equal(effects.length, 1)
  assert.equal(effects[0]!.resource, 'memory:user&fact=private fact')
  assert.equal(effects[0]!.execution, 'memory')
  assert.equal(phoneEffectsForApproval('mcp__phone__show_table', {}).length, 1)

  const ctx = await mount()
  let sent = 0
  try {
    registerProbe(ctx, 'bash')
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { sent += 1; return { ok: true, allowed: true } },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('sensitive'), name: 'bash',
      arguments: { command: 'cat ~/.ssh/id_rsa' }, signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, true)
    assert.equal(sent, 0)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('approval gate forwards the full effect before allowing the real tool body', async () => {
  const ctx = await mount()
  const payloads: Record<string, unknown>[] = []
  try {
    registerProbe(ctx, 'mcp__phone__UpdateMemory')
    await ctx.plugin(dshbotApprovalGate, {
      request: async payload => {
        payloads.push(payload)
        return { ok: true, allowed: true }
      },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('forget-user'), name: 'mcp__phone__UpdateMemory',
      arguments: { action: 'forget', scope: 'user', fact: 'private' },
      signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.equal(payloads.length, 1)
    assert.equal(payloads[0]!.callId, 'forget-user')
    assert.equal(payloads[0]!.argsDigest, argsDigest({ action: 'forget', scope: 'user', fact: 'private' }))
    assert.equal(payloads[0]!.alwaysScope, 'until')
    assert.equal(payloads[0]!.deferConsumption, true)
    const effects = payloads[0]!.effects as { resource: string }[]
    assert.equal(effects[0]!.resource, 'memory:user&fact=private')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('structural bash approval carries recomputable effects and consumes at its own execution point', async () => {
  const ctx = await mount()
  const payloads: Record<string, unknown>[] = []
  const args = { command: 'rm -rf /tmp/wp7-artifact' }
  try {
    registerProbe(ctx, 'bash')
    await ctx.plugin(dshbotApprovalGate, {
      request: async payload => {
        payloads.push(payload)
        return { ok: true, allowed: true }
      },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('destructive'), name: 'bash', arguments: args,
      signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.equal(payloads.length, 1)
    assert.equal(payloads[0]!.command, args.command)
    assert.equal(payloads[0]!.argsDigest, argsDigest(args))
    assert.equal(payloads[0]!.alwaysScope, 'until')
    assert.equal(payloads[0]!.deferConsumption, false)
    const effects = payloads[0]!.effects as { operation: string; resource: string }[]
    assert.deepEqual(effects.map(effect => effect.operation), ['rm-destructive'])
    assert.equal(effects[0]!.resource, '/tmp/wp7-artifact')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('identity registration precedes the structural approval gate for bash', async () => {
  const ctx = await mount()
  const order: string[] = []
  const registered = new Map<string, { name: string; digest: string }>()
  try {
    registerProbe(ctx, 'bash')
    // Mount order mirrors phone.worker.cordis.patch.yml: identity first.
    await ctx.plugin(dshbotIdentityBridge, {
      request: async payload => {
        order.push('register')
        registered.set(String(payload.callId), {
          name: String(payload.name), digest: String(payload.argsDigest),
        })
        return { ok: true, id: `registration-${payload.callId}` }
      },
      cancel: async () => { order.push('cancel') },
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async payload => {
        order.push('approval')
        // Mirrors Swift BotMCPRuntime.approve: the call must already be
        // registered, otherwise it answers "unattributed".
        const entry = registered.get(String(payload.callId))
        if (entry === undefined) return { ok: false, message: 'unattributed' }
        assert.equal(entry.name, 'bash')
        assert.equal(entry.digest, payload.argsDigest)
        return { ok: true, allowed: true }
      },
    })
    const result = await ctx.tools.execute({
      callId: ToolCallId('structural-bash'),
      name: 'bash', arguments: { command: 'rm -rf /tmp/wp7-artifact' },
      signal: new AbortController().signal, agent: agent(),
    })
    assert.equal(result.isError, false)
    assert.deepEqual(order, ['register', 'approval', 'cancel'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('native phone tools and unrelated built-ins neither register nor ask for approval', async () => {
  assert.equal(needsIdentityRegistration('mcp__phone__android_connect'), false)
  assert.equal(needsStructuralApproval('mcp__phone__android_connect'), false)
  assert.equal(needsIdentityRegistration('read'), false)
  assert.equal(needsStructuralApproval('read'), false)
  assert.equal(needsIdentityRegistration('bash'), true)
  assert.equal(needsStructuralApproval('mcp__phone__UpdateMemory'), true)

  const ctx = await mount()
  let registrations = 0
  let approvals = 0
  try {
    registerProbe(ctx, 'mcp__phone__android_connect')
    registerProbe(ctx, 'read')
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => { registrations += 1; return { ok: true, id: 'unexpected' } },
      cancel: async () => {},
    })
    await ctx.plugin(dshbotApprovalGate, {
      request: async () => { approvals += 1; return { ok: true, allowed: true } },
    })
    for (const name of ['mcp__phone__android_connect', 'read']) {
      const result = await ctx.tools.execute({
        callId: ToolCallId(`skip-${name}`), name, arguments: {},
        signal: new AbortController().signal, agent: agent(),
      })
      assert.equal(result.isError, false)
    }
    assert.equal(registrations, 0)
    assert.equal(approvals, 0)
  } finally {
    await ctx.fiber.dispose()
  }
})
