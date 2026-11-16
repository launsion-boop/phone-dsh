// SPDX-License-Identifier: MIT
/**
 * Q-01 direction test: the model-facing UpdateMemory MCP tool accepts a
 * `review` object from the frozen catalog and passes it to the handler. The
 * Swift-side schema exposure is covered by BotToolCatalogReviewSchemaTests.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client'
import { executeTool, mountRuntime } from './bot-runtime-test-kit.ts'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const catalog = JSON.parse(readFileSync(
  join(repository, 'spec/bot/v1/golden/tool-catalog.phone.json'), 'utf8',
)) as { memory: { updateMemory: { review: Record<string, unknown> } } }

function agent(id: string): Agent {
  return { id, session: { id } } as unknown as Agent
}

test('UpdateMemory accepts review through the frozen MCP tool schema', async () => {
  const ctx = await mountRuntime()
  const seen: Record<string, unknown>[] = []
  try {
    ctx.tools.register(createMcpToolDefinition(ctx, {
      name: 'mcp__phone__UpdateMemory',
      rawName: 'UpdateMemory',
      description: 'Write one memory document.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string' },
          path: { type: 'string' },
          expected_version: { type: 'number' },
          review: catalog.memory.updateMemory.review,
        },
        required: ['action', 'path', 'expected_version'],
        additionalProperties: false,
      },
      call: async args => {
        seen.push(args)
        return {
          content: [{ type: 'text', text: '{"ok":true}' }],
          structuredContent: { ok: true },
        }
      },
    }))
    const review = {
      state: 'verified',
      basis: 'record-recheck',
      refs: ['record://session/gb-main#3'],
    }
    const result = await executeTool(ctx, {
      callId: 'review-schema',
      name: 'mcp__phone__UpdateMemory',
      arguments: {
        action: 'write', path: 'agent/review.md', expected_version: 0, review,
      },
      signal: new AbortController().signal,
      agent: agent('gb-main'),
    })
    assert.equal(result.isError, false)
    assert.deepEqual(seen[0]?.review, review)
  } finally {
    await ctx.fiber.dispose()
  }
})
