// SPDX-License-Identifier: MIT
/**
 * Consumer-side regression for PC-20261116-bot-aha-evidence §4.3.
 *
 * The host and the Worker are two processes. The Worker side is real here:
 * `createMcpToolDefinition` -> ToolRuntime -> AgentLoop -> the actual model
 * request. The host response is the frozen `memory-recall.json` reviewed hit,
 * shaped like `BotMCPCallResult.success` (structuredContent + JSON text); the
 * Swift host process is not started by this Node test. It proves the new
 * `evidence_status` / `review` members are not lost in a helper: the second
 * model request contains the RecallMemory tool result verbatim.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readBotGoldenMerged } from './bot-golden.ts'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { StreamChunk } from '@deepseek-ai/dsh-llm'
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client'
import type { Agent } from '@deepseek-ai/dsh-agent'
import {
  createAgent,
  mountRuntime,
  ScriptAdapter,
  textResponse,
  userMessage,
} from './bot-runtime-test-kit.ts'

interface RecallGolden {
  hits: {
    path: string
    scope: string
    snippet: string
    score: number
    relevance: number
    recency: number
    matched: boolean
    updated_at_ms: number
    version: number
    evidence: string[]
    evidence_status: { ref: string; observed_at_ms: number | null; source_version: number | null }[]
    review: { state: string; basis: string; method?: string; at_ms?: number; refs?: string[] }
  }[]
}

// The shared `memory-recall.json` baseline stays review-free for consumers that
// only implement the common fields; the reviewed hit lives in the phone overlay.
const golden = readBotGoldenMerged('memory-recall') as unknown as RecallGolden
const hit = golden.hits.find(candidate => candidate.review !== undefined)
assert.ok(hit !== undefined, 'the shared recall golden carries a reviewed hit')

/** One model-shaped tool call, matching the DSH stream contract. */
function toolCallResponse(callId: string, name: string, args: object): StreamChunk[] {
  const id = ToolCallId(callId)
  const argumentsJson = JSON.stringify(args)
  return [
    { type: 'block-start', index: 0, blockType: 'tool-call' },
    { type: 'tool-call-delta', index: 0, id, name, argumentsDelta: argumentsJson.slice(0, 5) },
    { type: 'tool-call-delta', index: 0, id, argumentsDelta: argumentsJson.slice(5) },
    {
      type: 'block-end', index: 0,
      block: { type: 'tool-call', id, name, arguments: argumentsJson },
    },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
  ]
}

function textOf(message: { content?: readonly { type?: string; text?: string }[] }): string {
  return (message.content ?? [])
    .map(block => block.type === 'text' ? String(block.text ?? '') : '')
    .join('')
}

test('the real Worker path carries evidence_status and review from RecallMemory to the model request', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter([
    toolCallResponse('recall-1', 'mcp__phone__RecallMemory', {
      query: '简洁', limit: 5, scope: 'all',
    }),
    textResponse('done'),
  ])
  const calls: Record<string, unknown>[] = []
  try {
    ctx.llm.registerAdapter(['mock'], adapter)
    ctx.tools.register(createMcpToolDefinition(ctx, {
      name: 'mcp__phone__RecallMemory',
      rawName: 'RecallMemory',
      description: 'Search memory document bodies.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string' },
          limit: { type: 'number' },
          scope: { type: 'string' },
        },
      },
      call: async args => {
        calls.push(args)
        // The App's BotMCPCallResult.success shape: structuredContent is the
        // frozen result, content is its JSON text (the model-visible block).
        const result = { ok: true, hits: [hit], count: 1, total: 1, truncated: false }
        return {
          content: [{ type: 'text', text: JSON.stringify(result) }],
          structuredContent: result,
        }
      },
    }))
    const agent: Agent = await createAgent(ctx, 'gb-recall-consumer')
    agent.followup(userMessage('找一下我喜欢什么'))
    await agent.whenIdle()

    assert.equal(calls.length, 1)
    assert.deepEqual(calls[0], { query: '简洁', limit: 5, scope: 'all' })
    assert.equal(adapter.requests.length, 2, 'the tool call opens a second model request')

    const second = adapter.requests[1]!.messages
    const toolMessage = second.find(message => message.role === 'tool')
    assert.ok(toolMessage, 'the model request carries the tool result message')
    const projected = textOf(toolMessage)
    assert.match(projected, /"evidence_status"/)
    assert.match(projected, /"observed_at_ms":\s*1760000003000/)
    assert.match(projected, /"source_version":\s*null/)
    assert.match(projected, /"review"/)
    assert.match(projected, /"state":\s*"verified"/)
    assert.match(projected, /"basis":\s*"user-statement"/)
    assert.match(projected, /record:\/\/session\/gb-main#3/)
  } finally {
    await ctx.fiber.dispose()
  }
})
