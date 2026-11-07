// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { VolatileContextSource, VolatileSnapshot } from './volatile-context.ts'

export const BOT_VOLATILE_CONTEXT_TOOL = 'mcp__phone__BotVolatileContext'
export const VOLATILE_TOTAL_TEXT_LIMIT = 24_000

const RESPONSE_KEYS = new Set(['schemaVersion', 'sessionId', 'revision', 'blocks'])
const BLOCK_LIMITS = Object.freeze({
  variant: 12_000,
  persona: 12_000,
  memory: 4_000,
  automation: 4_000,
})
const BLOCK_KEYS = new Set(Object.keys(BLOCK_LIMITS))
const EMPTY_SNAPSHOT: VolatileSnapshot = Object.freeze({})

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasExactKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>, required: readonly string[]): boolean {
  return Object.keys(value).every(key => allowed.has(key))
    && required.every(key => Object.hasOwn(value, key))
}

export function validVolatileSessionId(value: unknown): value is string {
  if (typeof value !== 'string') return false
  const length = textLength(value)
  return length >= 1 && length <= 200
}

function textLength(value: string): number {
  let length = 0
  for (const _character of value) length += 1
  return length
}

export function validateVolatileContextResponse(
  response: unknown,
  expectedSessionId: string,
): VolatileSnapshot | undefined {
  if (!validVolatileSessionId(expectedSessionId) || !isRecord(response)) return undefined
  if (!hasExactKeys(response, RESPONSE_KEYS, ['schemaVersion', 'sessionId', 'revision', 'blocks'])) return undefined
  if (response.schemaVersion !== 1 || response.sessionId !== expectedSessionId) return undefined
  if (!Number.isInteger(response.revision) || (response.revision as number) < 1) return undefined
  if (!isRecord(response.blocks) || !hasExactKeys(response.blocks, BLOCK_KEYS, [])) return undefined

  const snapshot: Record<string, string> = {}
  let totalLength = 0
  for (const [name, limit] of Object.entries(BLOCK_LIMITS)) {
    const text = response.blocks[name]
    if (text === undefined) continue
    if (typeof text !== 'string') return undefined
    const length = textLength(text)
    if (length > limit) return undefined
    totalLength += length
    snapshot[name] = text
  }
  if (totalLength > VOLATILE_TOTAL_TEXT_LIMIT) return undefined
  return Object.freeze(snapshot) as VolatileSnapshot
}

export function createPhoneVolatileContextSource(ctx: Context): VolatileContextSource {
  let nextCallId = 0
  return async ({ sessionId, signal, agent }) => {
    if (!validVolatileSessionId(sessionId)) return EMPTY_SNAPSHOT
    nextCallId += 1
    try {
      const result = await ctx.tools.execute({
        callId: `dshbot-volatile-${nextCallId}` as ToolCallId,
        name: BOT_VOLATILE_CONTEXT_TOOL,
        arguments: { sessionId },
        signal: signal ?? new AbortController().signal,
        ...agent === undefined ? {} : { agent },
      })
      if (result.isError || signal?.aborted || !isRecord(result.value)) return EMPTY_SNAPSHOT
      return validateVolatileContextResponse(result.value.structuredContent, sessionId) ?? EMPTY_SNAPSHOT
    } catch {
      return EMPTY_SNAPSHOT
    }
  }
}
