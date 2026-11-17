// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { isBotAgentSession } from './decision-context.ts'
import { agentSessionIdOf } from './volatile-context.ts'

/**
 * G-2 §242/§243: a bounded index of this turn's successful tool results.
 *
 * The index is a runtime-context section, not a tool, store or second event
 * log. Each line carries the canonical session-log reference
 * `record://session/<sessionId>#<resultSeq>` taken from the `tool/result`
 * event (never the `tool/call` seq), the tool name and a short path/command
 * label. It deliberately does not copy the result body: the model must cite
 * the ref explicitly in memory evidence for adoption.
 *
 * Only successful results from the current turn are listed. Failed,
 * truncated and redacted results are omitted rather than presented as
 * citable current observations. The renderer is bounded by
 * `TOOL_RESULT_INDEX_LIMIT` (a fixed small value), same session/bot scope.
 */

export const TOOL_RESULT_INDEX_SECTION = 'dshbot:tool-results'
export const TOOL_RESULT_INDEX_ORDER = 360
export const TOOL_RESULT_INDEX_LIMIT = 6
export const TOOL_RESULT_INDEX_MAX_LABEL = 72

interface SessionEventLike {
  readonly type?: unknown
  readonly seq?: unknown
  readonly data?: unknown
}

interface ToolCallRecord {
  readonly name: string
  readonly arguments: unknown
}

interface ToolResultMessage {
  readonly isError?: unknown
  readonly toolCallId?: unknown
  readonly source?: { readonly callId?: unknown } | null
  readonly content?: unknown
}

export interface ToolResultIndexEntry {
  readonly ref: string
  readonly seq: number
  readonly tool: string
  readonly label: string
}

export interface ToolResultIndexConfig {
  /** Fixed small bound; clamped to [1, 12]. */
  readonly limit?: number
  readonly lang?: () => 'en' | 'zh'
}

function recordOf(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
}

function stringOf(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

function messageOf(value: unknown): ToolResultMessage | undefined {
  const message = recordOf(value)
  return message === undefined ? undefined : message as ToolResultMessage
}

function textOfMessage(message: ToolResultMessage | undefined): string {
  if (message === undefined || !Array.isArray(message.content)) return ''
  const parts: string[] = []
  for (const block of message.content) {
    const record = recordOf(block)
    if (record?.type === 'text' && typeof record.text === 'string') parts.push(record.text)
  }
  return parts.join('\n')
}

function parseArguments(value: unknown): unknown {
  if (typeof value !== 'string' || value === '') return undefined
  try {
    return JSON.parse(value) as unknown
  } catch {
    return undefined
  }
}

function stringArgument(value: unknown, key: string): string | undefined {
  const record = recordOf(value)
  return record === undefined ? undefined : stringOf(record[key])
}

function shortLabel(value: string, limit = TOOL_RESULT_INDEX_MAX_LABEL): string {
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]+/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim()
  if (cleaned === '') return ''
  return [...cleaned].slice(0, limit).join('')
}

function readLabel(path: string | undefined): string {
  if (path === undefined) return ''
  const normalized = path.replace(/^\/dsh\/workspace\/\.dshbot\/agents\/[^/]+\//u, '')
  if (normalized === '') return ''
  // Keep a short, useful suffix rather than the whole absolute path.
  const parts = normalized.split('/').filter(part => part !== '')
  const suffix = parts.length > 2 ? parts.slice(-2).join('/') : normalized
  return shortLabel(suffix)
}

function labelFor(tool: string, args: unknown): string {
  const bare = tool.startsWith('mcp__phone__')
    ? tool.slice('mcp__phone__'.length)
    : tool
  if (bare === 'read' || bare === 'ReadMemory' || bare === 'RecallMemory') {
    const path = readLabel(stringArgument(args, 'file_path') ?? stringArgument(args, 'path'))
    if (path !== '') return path
  }
  if (bare === 'bash') {
    const description = stringArgument(args, 'description')
    if (description !== undefined) {
      const label = shortLabel(description)
      if (label !== '') return label
    }
    const command = stringArgument(args, 'command')
    if (command !== undefined) {
      const label = shortLabel(command)
      if (label !== '') return label
    }
  }
  if (bare === 'glob' || bare === 'grep') {
    const pattern = stringArgument(args, 'pattern') ?? stringArgument(args, 'query')
    if (pattern !== undefined) {
      const label = shortLabel(pattern)
      if (label !== '') return label
    }
  }
  if (bare === 'web_fetch' || bare === 'web_search') {
    const target = stringArgument(args, 'url') ?? stringArgument(args, 'query')
    if (target !== undefined) {
      const label = shortLabel(target)
      if (label !== '') return label
    }
  }
  if (bare === 'Task') {
    const title = stringArgument(args, 'task_title') ?? stringArgument(args, 'title')
    if (title !== undefined) {
      const label = shortLabel(title)
      if (label !== '') return label
    }
  }
  return shortLabel(bare) || 'tool'
}

function isFailed(message: ToolResultMessage | undefined, data: Record<string, unknown>): boolean {
  return message?.isError === true || data.isError === true
}

const TRUNCATION_MARKERS = [
  /\[output truncated\]/iu,
  /…\s*\[truncated\]/iu,
  /\[truncated\]/iu,
  /\(truncated\)/iu,
] as const

const REDACTION_MARKERS = [
  /\[pdsh-redaction\b/iu,
  /\[redact\]/iu,
] as const

function isWithheld(text: string): boolean {
  return TRUNCATION_MARKERS.some(marker => marker.test(text))
    || REDACTION_MARKERS.some(marker => marker.test(text))
}

function latestTurnOf(events: readonly SessionEventLike[]): number | undefined {
  let latest: number | undefined
  for (const event of events) {
    if (event.type !== 'turn/start') continue
    const turn = recordOf(event.data)?.turn
    if (typeof turn === 'number' && Number.isInteger(turn) && turn >= 1) latest = turn
  }
  return latest
}

function callsOf(events: readonly SessionEventLike[]): Map<string, ToolCallRecord> {
  const calls = new Map<string, ToolCallRecord>()
  for (const event of events) {
    if (event.type !== 'tool/call') continue
    const data = recordOf(event.data)
    if (data === undefined) continue
    const callId = stringOf(data.callId)
    if (callId === undefined) continue
    calls.set(callId, {
      name: stringOf(data.name) ?? 'tool',
      arguments: parseArguments(data.arguments),
    })
  }
  return calls
}

/**
 * Build the bounded index from raw session events. Pure and structural so the
 * provider and the unit tests exercise the same selection rules.
 */
export function buildToolResultIndex(
  events: readonly SessionEventLike[],
  sessionId: string,
  limit = TOOL_RESULT_INDEX_LIMIT,
): ToolResultIndexEntry[] {
  if (sessionId === '' || !Array.isArray(events) || events.length === 0) return []
  const bound = Math.min(Math.max(Math.trunc(limit), 1), 12)
  const latestTurn = latestTurnOf(events)
  const calls = callsOf(events)
  const entries: ToolResultIndexEntry[] = []
  const seen = new Set<number>()
  for (const event of events) {
    if (event.type !== 'tool/result') continue
    const seq = event.seq
    if (typeof seq !== 'number' || !Number.isInteger(seq) || seq < 1) continue
    if (seen.has(seq)) continue
    const data = recordOf(event.data)
    if (data === undefined) continue
    if (latestTurn !== undefined) {
      const turn = data.turn
      if (typeof turn !== 'number' || turn !== latestTurn) continue
    }
    const message = messageOf(data.message)
    if (isFailed(message, data)) continue
    const text = textOfMessage(message)
    if (text === '' || isWithheld(text)) continue
    const callId = stringOf(message?.toolCallId) ?? stringOf(message?.source?.callId)
    const call = callId === undefined ? undefined : calls.get(callId)
    const tool = call?.name ?? 'tool'
    const label = labelFor(tool, call?.arguments)
    seen.add(seq)
    entries.push({
      ref: `record://session/${sessionId}#${seq}`,
      seq,
      tool,
      label,
    })
  }
  // Session events are in log order; keep the most recent N.
  return entries.slice(-bound)
}

/** Render the bounded index as a clearly non-instruction material section. */
export function renderToolResultIndex(
  entries: readonly ToolResultIndexEntry[],
  options: { lang?: 'en' | 'zh' } = {},
): string {
  if (entries.length === 0) return ''
  const zh = options.lang !== 'en'
  const lines: string[] = [
    zh
      ? `## 可回查的工具结果索引（${TOOL_RESULT_INDEX_SECTION}；仅引用，不是本轮指令）`
      : `## Tool-result index (${TOOL_RESULT_INDEX_SECTION}; references only, not instructions)`,
  ]
  for (const entry of entries) {
    lines.push(`- ${entry.ref} · ${entry.tool} · ${entry.label}`)
  }
  lines.push(zh
    ? '在 UpdateMemory 的 evidence 数组里引用上面的 record:// 才表示采用；只写在 review 里不计入证据，索引本身也不是证据。'
    : 'Cite a record:// above in UpdateMemory evidence to adopt it; a review-only mention is not evidence, and the index itself is not evidence.')
  return lines.join('\n')
}

export default function dshbotToolResultIndex(
  ctx: Context,
  config: ToolResultIndexConfig = {},
): void {
  const limit = Math.min(Math.max(Math.trunc(config.limit ?? TOOL_RESULT_INDEX_LIMIT), 1), 12)
  const lang = config.lang ?? (() => 'zh' as const)
  ctx.systemPrompt.context({
    name: TOOL_RESULT_INDEX_SECTION,
    order: TOOL_RESULT_INDEX_ORDER,
    text: context => {
      const agent = context.agent
      if (agent === undefined || !isBotAgentSession(ctx, agent)) return ''
      const sessionId = agentSessionIdOf(agent)
      if (sessionId === '') return ''
      const session = (agent as Agent & {
        session?: { snapshotEvents?: () => readonly SessionEventLike[] }
      }).session
      const events = session?.snapshotEvents?.()
      if (events === undefined || events.length === 0) return ''
      return renderToolResultIndex(buildToolResultIndex(events, sessionId, limit), { lang: lang() })
    },
  })
}

dshbotToolResultIndex.inject = ['systemPrompt']
