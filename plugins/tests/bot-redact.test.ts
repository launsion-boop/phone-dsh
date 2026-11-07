// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotRedact, { createRedactor, redactContentBlocks } from '../bot-runtime/src/redact.ts'

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
    await ctx.plugin(dshbotRedact)
    ctx.tools.register(defineTool({
      name: 'secret_probe', description: 'probe', parameters: {},
      output: {
        schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: value }],
      },
      execute: async () => 'credential is sk-abcdefghijklmnop',
    }))
    const result = await ctx.tools.execute({
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
