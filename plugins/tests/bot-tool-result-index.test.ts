// SPDX-License-Identifier: MIT
/**
 * G-2 §242/§243: the Worker-side bounded tool-result index. The index must
 * expose the canonical `record://session/<id>#<resultSeq>` from the
 * `tool/result` event (never a `tool/call` seq), omit failed/truncated/redacted
 * results and never copy the result body. The model adopts a ref only by
 * citing it explicitly; the index itself performs no memory write.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { StreamChunk } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotToolResultIndex, {
  TOOL_RESULT_INDEX_SECTION,
  buildToolResultIndex,
  renderToolResultIndex,
} from '../bot-runtime/src/tool-result-index.ts'
import {
  createAgent,
  mountRuntime,
  ScriptAdapter,
  textResponse,
  userMessage,
} from './bot-runtime-test-kit.ts'

interface ModelMessageView {
  readonly role: string
  readonly source?: {
    readonly kind?: string
    readonly sections?: readonly { name?: string }[]
  }
  readonly content?: readonly { type?: string; text?: string }[]
}

function textOf(message: ModelMessageView): string {
  return (message.content ?? [])
    .map(block => block.type === 'text' ? String(block.text ?? '') : '')
    .join('')
}

function runtimeContextMessages(messages: readonly ModelMessageView[]): ModelMessageView[] {
  return messages.filter(message => message.source?.kind === 'runtime-context')
}

function toolCallResponse(callId: string, name: string, args: object): StreamChunk[] {
  const id = ToolCallId(callId)
  const argumentsJson = JSON.stringify(args)
  return [
    { type: 'block-start', index: 0, blockType: 'tool-call' },
    { type: 'tool-call-delta', index: 0, id, name, argumentsDelta: argumentsJson },
    { type: 'block-end', index: 0, block: { type: 'tool-call', id, name, arguments: argumentsJson } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
  ]
}

function sessionEvent(type: string, seq: number, data: Record<string, unknown>): Record<string, unknown> {
  return { type, seq, data }
}

function toolRound(options: {
  turn?: number
  callSeq?: number
  resultSeq?: number
  callId?: string
  name?: string
  arguments?: string
  text?: string
  isError?: boolean
}): Record<string, unknown>[] {
  const turn = options.turn ?? 1
  const callSeq = options.callSeq ?? 2
  const resultSeq = options.resultSeq ?? 3
  const callId = options.callId ?? 'call_1'
  return [
    sessionEvent('turn/start', 1, { turn }),
    sessionEvent('tool/call', callSeq, {
      turn,
      step: 1,
      callId,
      name: options.name ?? 'bash',
      arguments: options.arguments ?? JSON.stringify({ command: 'cat docs/report.md', description: '读取报告原文' }),
    }),
    sessionEvent('tool/result', resultSeq, {
      turn,
      step: 1,
      message: {
        role: 'tool',
        toolCallId: callId,
        content: [{ type: 'text', text: options.text ?? 'RESULT_BODY_SHOULD_NOT_APPEAR' }],
        isError: options.isError ?? false,
      },
    }),
  ]
}

test('the index uses the tool/result seq and never copies the result body', () => {
  const events = toolRound({ callSeq: 2, resultSeq: 3 })
  const entries = buildToolResultIndex(events, 'gb-index')
  assert.equal(entries.length, 1)
  assert.equal(entries[0]!.ref, 'record://session/gb-index#3')
  assert.notEqual(entries[0]!.ref, 'record://session/gb-index#2')
  assert.equal(entries[0]!.tool, 'bash')
  assert.equal(entries[0]!.label, '读取报告原文')
  const rendered = renderToolResultIndex(entries)
  assert.match(rendered, /dshbot:tool-results/gu)
  assert.match(rendered, /record:\/\/session\/gb-index#3/gu)
  assert.doesNotMatch(rendered, /RESULT_BODY_SHOULD_NOT_APPEAR/u)
})

test('failed, truncated and redacted results are not listed', () => {
  const failed = buildToolResultIndex(toolRound({ resultSeq: 4, isError: true }), 'gb-index')
  assert.deepEqual(failed, [])
  const truncated = buildToolResultIndex(toolRound({ resultSeq: 5, text: 'line\n… [truncated]' }), 'gb-index')
  assert.deepEqual(truncated, [])
  const redacted = buildToolResultIndex(toolRound({ resultSeq: 6, text: 'mail\n[pdsh-redaction rules=email:1]' }), 'gb-index')
  assert.deepEqual(redacted, [])
})

test('only the current turn is listed and the index is bounded to the last N', () => {
  const events: Record<string, unknown>[] = [
    sessionEvent('turn/start', 1, { turn: 1 }),
    ...toolRound({ turn: 1, callSeq: 2, resultSeq: 3 }),
    sessionEvent('turn/start', 4, { turn: 2 }),
  ]
  for (let index = 0; index < 7; index += 1) {
    events.push(...toolRound({
      turn: 2,
      callSeq: 10 + index * 2,
      resultSeq: 11 + index * 2,
      callId: `call_${index}`,
      arguments: JSON.stringify({ command: `echo ${index}`, description: `步骤 ${index}` }),
      text: `result ${index}`,
    }).slice(1))
  }
  const entries = buildToolResultIndex(events, 'gb-index')
  assert.equal(entries.length, 6)
  assert.deepEqual(entries.map(entry => entry.seq), [13, 15, 17, 19, 21, 23])
  assert.ok(entries.every(entry => entry.ref.startsWith('record://session/gb-index#')))
  assert.ok(entries.every(entry => !entry.ref.includes('#3')))
})

test('the accepted request carries the index as runtime-context, not a user message', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter([
    toolCallResponse('call_1', 'bash', { command: 'cat docs/report.md', description: '读取报告原文' }),
    textResponse('done'),
  ])
  ctx.llm.registerAdapter(['mock'], adapter)
  ctx.tools.register(defineTool({
    name: 'bash',
    description: 'read a file',
    parameters: {
      command: { type: 'string' },
      description: { type: 'string' },
    },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => 'RESULT_BODY_SHOULD_NOT_APPEAR',
  }))
  await ctx.plugin(dshbotToolResultIndex, { lang: () => 'zh' as const })
  const agent: Agent = await createAgent(ctx, 'gb-index')
  try {
    agent.followup(userMessage('读一下报告'))
    await agent.whenIdle()
    assert.equal(adapter.requests.length, 2)

    const events = agent.session.snapshotEvents() as unknown as readonly { type?: string; seq?: number }[]
    const result = events.find(event => event.type === 'tool/result')
    assert.ok(result !== undefined)
    assert.equal(typeof result.seq, 'number')

    const request = adapter.requests[1]!.messages as unknown as ModelMessageView[]
    const indexSection = runtimeContextMessages(request).find(message =>
      message.source?.sections?.some(section => section.name === TOOL_RESULT_INDEX_SECTION))
    assert.ok(indexSection, 'the real model request carries the tool-result index section')
    const sectionText = textOf(indexSection)
    assert.match(sectionText, new RegExp(`record://session/gb-index#${result.seq}`, 'u'))
    assert.match(sectionText, /读取报告原文/u)
    assert.doesNotMatch(sectionText, /RESULT_BODY_SHOULD_NOT_APPEAR/u)
    assert.doesNotMatch(sectionText, /读一下报告/u, 'user text is not copied into the index')

    const user = request.filter(message => message.role === 'user'
      && message.source?.kind === 'user')
    assert.equal(user.length, 1)
    assert.doesNotMatch(textOf(user[0]!), /dshbot:tool-results/u)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('another Bot cannot see this session index', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter([
    toolCallResponse('call_1', 'bash', { command: 'cat docs/report.md', description: '读取报告原文' }),
    textResponse('done'),
    textResponse('done too'),
  ])
  ctx.llm.registerAdapter(['mock'], adapter)
  ctx.tools.register(defineTool({
    name: 'bash',
    description: 'read a file',
    parameters: { command: { type: 'string' }, description: { type: 'string' } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => 'result',
  }))
  await ctx.plugin(dshbotToolResultIndex, { lang: () => 'zh' as const })
  const first: Agent = await createAgent(ctx, 'gb-first')
  const second: Agent = await createAgent(ctx, 'gb-second')
  try {
    first.followup(userMessage('第一个 Bot'))
    await first.whenIdle()
    second.followup(userMessage('第二个 Bot'))
    await second.whenIdle()

    const firstRequest = adapter.requests[1]!.messages as unknown as ModelMessageView[]
    const firstSection = runtimeContextMessages(firstRequest).find(message =>
      message.source?.sections?.some(section => section.name === TOOL_RESULT_INDEX_SECTION))
    assert.ok(firstSection)
    assert.match(textOf(firstSection), /record:\/\/session\/gb-first#/u)

    const secondRequest = adapter.requests[2]!.messages as unknown as ModelMessageView[]
    const secondSection = runtimeContextMessages(secondRequest).find(message =>
      message.source?.sections?.some(section => section.name === TOOL_RESULT_INDEX_SECTION))
    assert.equal(secondSection, undefined, 'the second Bot has no tool result of its own')
  } finally {
    await ctx.fiber.dispose()
  }
})
