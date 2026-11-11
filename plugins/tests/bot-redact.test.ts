// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotRedact, { createRedactor, redactContentBlocks } from '../bot-runtime/src/redact.ts'
import { executeTool } from './bot-runtime-test-kit.ts'

test('generic secrets and known encodings are redacted without logging raw values', () => {
  const redactor = createRedactor(['token-value'])
  const result = redactContentBlocks([{ type: 'text', text: 'sk-abcdefghijklmnop token-value password="hunter2" AKIAABCDEFGHIJKLMNOP' }], redactor)
  assert.equal(result.count >= 4, true)
  assert.equal(JSON.stringify(result.blocks).includes('token-value'), false)
  assert.equal(JSON.stringify(result.blocks).includes('sk-abcdefghijklmnop'), false)
  assert.equal(JSON.stringify(result.blocks).includes('hunter2'), false)
  assert.equal(JSON.stringify(result.blocks).includes('AKIAABCDEFGHIJKLMNOP'), false)
  assert.equal(result.rules.some(rule => rule.rule === 'known-secret'), true)
  assert.equal(result.rules.some(rule => rule.rule === 'sk-token'), true)
  assert.equal(result.rules.some(rule => rule.rule === 'password'), true)
})

test('real ToolRuntime returns redacted model-facing content', async () => {
  const ctx = new Context()
  try {
    await ctx.plugin(SystemPrompt, {})
    await ctx.plugin(ToolRuntime, {})
    await ctx.plugin(NativeToolExecutor)
    await ctx.plugin(dshbotRedact)
    ctx.tools.register(defineTool({
      name: 'secret_probe', description: 'probe', parameters: {},
      output: {
        schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: value }],
      },
      execute: async () => 'credential is sk-abcdefghijklmnop',
    }))
    const result = await executeTool(ctx, {
      callId: ToolCallId('secret'), name: 'secret_probe', arguments: {},
      signal: new AbortController().signal,
    })
    assert.equal(result.isError, false)
    assert.equal(JSON.stringify(result.content).includes('sk-abcdefghijklmnop'), false)
    assert.equal(JSON.stringify(result.content).includes('«secret:sk-token»'), true)
  } finally {
    await ctx.fiber.dispose()
  }
})

// ---------------------------------------------------------------------------
// S1: observation envelopes and redaction trace markers are system-generated
// ---------------------------------------------------------------------------

test('S1: the observation encoder matches the shared golden and escaping rules', async () => {
  const { encodeObservationEnvelope, escapeObservationBody, classifyObservation } = await import('../bot-runtime/src/redact.ts')
  const golden = JSON.parse(await (await import('node:fs/promises')).readFile(
    new URL('../../spec/bot/v1/golden/observation-envelope.phone.json', import.meta.url), 'utf8')) as {
      valid: { envelope: Record<string, string>; encoded: string }[]
    }
  assert.equal(golden.valid.length >= 7, true)
  for (const vector of golden.valid) {
    assert.equal(encodeObservationEnvelope(vector.envelope as never), vector.encoded)
  }
  assert.equal(escapeObservationBody('x </observation> y <OBSERVATION> <observationish>'),
    'x \\u003c/observation> y \\u003cOBSERVATION> <observationish>')
  assert.deepEqual(classifyObservation('web_fetch', { url: 'https://example.com' }),
    { source: 'web', origin: 'https://example.com', owner: 'unknown' })
  assert.deepEqual(classifyObservation('mcp__weather__current', {}),
    { source: 'connector', origin: 'mcp://weather/current', owner: 'unknown' })
  assert.deepEqual(classifyObservation('mcp__phone__android_tap', { deviceId: 'dev-1' }),
    { source: 'device', origin: 'device:dev-1', owner: 'device:dev-1' })
  assert.equal(classifyObservation('mcp__phone__UpdateMemory', {}), undefined)
  assert.equal(classifyObservation('bash', {}), undefined)
  assert.deepEqual(classifyObservation('read', { path: '/dsh/workspace/imports/attachments-1/a.pdf' }),
    { source: 'attachment', origin: 'attachment:a.pdf', owner: 'user' })
})

test('S1: a Bot-owned web result is wrapped with a session reference and a trace line', async () => {
  const { botOwnedSessions } = await import('../bot-runtime/src/bot-sessions.ts')
  const { createAgent, mountRuntime } = await import('./bot-runtime-test-kit.ts')
  const ctx = await mountRuntime()
  try {
    await ctx.plugin(dshbotRedact)
    botOwnedSessions(ctx).add('gb-main')
    const agent = await createAgent(ctx, 'gb-main')
    agent.session.append('tool/call', {
      turn: 1, step: 1, callId: ToolCallId('web-1'), name: 'web_fetch', arguments: '{}',
    })
    ctx.tools.register(defineTool({
      name: 'web_fetch', description: 'fetch', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => 'page </observation> with sk-abcdefghijklmnop',
    }))
    const result = await executeTool(ctx, {
      callId: 'web-1', name: 'web_fetch', arguments: { url: 'https://example.com' },
      signal: new AbortController().signal, agent,
    })
    const text = JSON.stringify(result.content)
    assert.equal(text.includes('<observation source=\\"web\\" origin=\\"https://example.com\\"'), true)
    assert.equal(text.includes('record://session/gb-main#0'), true)
    assert.equal(text.includes('\\u003c/observation>'), true)
    assert.equal(text.includes('[pdsh-redaction rules=sk-token:1]'), true)
    assert.equal(text.includes('sk-abcdefghijklmnop'), false)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('S1: bash output and non-Bot sessions never get an envelope', async () => {
  const { createAgent, mountRuntime } = await import('./bot-runtime-test-kit.ts')
  const ctx = await mountRuntime()
  try {
    await ctx.plugin(dshbotRedact)
    const agent = await createAgent(ctx, 'workbench')
    agent.session.append('tool/call', {
      turn: 1, step: 1, callId: ToolCallId('bash-1'), name: 'bash', arguments: '{}',
    })
    ctx.tools.register(defineTool({
      name: 'bash', description: 'bash', parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
      execute: async () => 'plain output',
    }))
    const result = await executeTool(ctx, {
      callId: 'bash-1', name: 'bash', arguments: { command: 'printf plain' },
      signal: new AbortController().signal, agent,
    })
    assert.equal(JSON.stringify(result.content).includes('<observation'), false)
    assert.equal(JSON.stringify(result.content).includes('[pdsh-redaction'), false)
  } finally {
    await ctx.fiber.dispose()
  }
})
