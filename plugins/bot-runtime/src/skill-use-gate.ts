// SPDX-License-Identifier: MIT
/**
 * Bot-only gate for the official `skill` loader.
 *
 * The official `@deepseek-ai/dsh-tool-skill` reads the winning skill body from
 * the official filesystem provider; it has no provenance hook. This plugin
 * therefore runs only on the Bot preset, before the official `skill` tool
 * executes, and asks the host for L's scoped derivation status. Only `current`
 * may load. Known erased/revoked/changed/unavailable and unknown deny with the
 * real status; a nil/untracked identity denies as
 * `skill-provenance-untracked`, never as current. No body is read here.
 *
 * The host adapter is C's internal MCP tool `BotSkillUseStatus`:
 *   args  { schema: "bot-skill-use-status/v1", name }
 *   reply { ok: true, status: "current" | ... | null }
 * It resolves `(source, owner, name)` with the same Bot identity/roots as the
 * producer; the Worker never reads the skill file to decide.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import { botSessionOwned } from './identity-bridge.ts'

export const BOT_SKILL_USE_STATUS_TOOL = 'mcp__phone__BotSkillUseStatus'
export const BOT_SKILL_USE_STATUS_SCHEMA = 'bot-skill-use-status/v1'

export interface SkillUseGateConfig {
  readonly enabled?: boolean
  readonly statusTool?: string
}

type JsonRecord = Record<string, unknown>

function isRecord(value: unknown): value is JsonRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function parseArguments(value: unknown): JsonRecord {
  if (isRecord(value)) return value
  if (typeof value !== 'string') return {}
  try {
    const parsed: unknown = JSON.parse(value)
    return isRecord(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

export function skillUseDenialCode(status: string | null): string {
  return status === null ? 'skill-provenance-untracked' : `skill-provenance-${status}`
}

export const SKILL_STATUS_UNAVAILABLE = 'skill-provenance-status-unavailable'
export const SKILL_CONTENT_UNKNOWN = 'skill-provenance-content-unknown'

const STATUS_FAILURE_DETAIL = /^[a-z0-9:_-]{1,48}$/u

function statusUnavailable(detail?: string): { readonly kind: 'deny'; readonly reason: string } {
  const safe = detail !== undefined && STATUS_FAILURE_DETAIL.test(detail)
    ? detail : 'unknown'
  return {
    kind: 'deny',
    reason: `[skill provenance] The skill status could not be verified (${SKILL_STATUS_UNAVAILABLE}; detail=${safe}); its instructions were NOT loaded.`,
  }
}

function contentUnknown(): { readonly kind: 'deny'; readonly reason: string } {
  return {
    kind: 'deny',
    reason: `[skill provenance] The skill has no verifiable content source (${SKILL_CONTENT_UNKNOWN}); its instructions were NOT loaded.`,
  }
}

export function skillUseGateCode(
  status: string | null,
  contentBasis: 'known' | 'unknown',
): string | null {
  if (status === 'current') {
    return contentBasis === 'known' ? null : SKILL_CONTENT_UNKNOWN
  }
  if (status === 'unknown') {
    return contentBasis === 'unknown' ? SKILL_CONTENT_UNKNOWN : skillUseDenialCode(status)
  }
  return skillUseDenialCode(status)
}

function denial(status: string | null): { readonly kind: 'deny'; readonly reason: string } {
  const code = skillUseDenialCode(status)
  return {
    kind: 'deny',
    reason: `[skill provenance] This skill is not current (${code}); its instructions were NOT loaded.`,
  }
}

/**
 * Parse one internal BotSkillUseStatus tool result. `undefined` means the
 * lookup itself failed (missing/error/wrong schema), which must not be
 * reported as a tracked `unknown`; `null` means L has no tracked identity.
 */
export type SkillStatusLookup =
  | { readonly status: string | null; readonly contentBasis: 'known' | 'unknown' }
  | { readonly failure: string }

export function skillStatusLookup(result: unknown): SkillStatusLookup {
  if (!isRecord(result) || result.isError === true || !isRecord(result.value)) {
    return { failure: 'missing' }
  }
  const value = result.value.structuredContent
  if (!isRecord(value) || value.schema !== BOT_SKILL_USE_STATUS_SCHEMA || value.ok !== true) {
    return { failure: 'schema' }
  }
  const raw = value.status
  let status: string | null
  if (raw === null || raw === undefined) {
    status = null
  } else if (typeof raw === 'string'
    && ['current', 'changed', 'unavailable', 'revoked', 'erased', 'unknown'].includes(raw)) {
    status = raw
  } else {
    return { failure: 'status' }
  }
  // G-SCB-1: missing/invalid content_basis is an unknown basis, never known.
  const contentBasis = value.content_basis === 'known' ? 'known' : 'unknown'
  return { status, contentBasis }
}

export function skillStatusFromToolResult(result: unknown): string | null | undefined {
  const lookup = skillStatusLookup(result)
  return 'status' in lookup ? lookup.status : undefined
}

/**
 * Pure mapping used by both the hook and unit tests. Only `current` is
 * readable. `null` means L has no tracked identity for this name; it is
 * explicitly denied as `skill-provenance-untracked`, never treated as current.
 */
export function skillUseDecision(status: string | null): 'allow' | 'deny' {
  return status === 'current' ? 'allow' : 'deny'
}

const KNOWN_INVALID = new Set(['changed', 'unavailable', 'revoked', 'erased'])

function isKnownInvalid(status: string | null | undefined): status is string {
  return status !== null && status !== undefined && KNOWN_INVALID.has(status)
}

function catalogLinePrefix(name: string): string {
  return `- \`${name}\`: `
}

/** Remove only the catalog lines for `names`; descriptions are never parsed. */
export function removeCatalogLines(text: string, names: ReadonlySet<string>): string {
  if (names.size === 0) return text
  return text.split('\n').filter(line =>
    ![...names].some(name => line.startsWith(catalogLinePrefix(name)))).join('\n')
}

function filterCatalogMessage(message: unknown, invalid: ReadonlySet<string>): unknown {
  if (!isRecord(message) || !isRecord(message.source)) return message
  const source = message.source
  if (source.kind !== 'skill-catalog' || !Array.isArray(source.entries)) return message
  const entries = source.entries.filter(entry => isRecord(entry)
    && typeof entry.name === 'string' && !invalid.has(entry.name))
  if (entries.length === source.entries.length) return message
  const content = Array.isArray(message.content)
    ? message.content.map(block => {
      if (!isRecord(block) || block.type !== 'text' || typeof block.text !== 'string') return block
      return { ...block, text: removeCatalogLines(block.text, invalid) }
    })
    : message.content
  return { ...message, content, source: { ...source, entries } }
}

function parseSkillCallName(value: unknown): string | undefined {
  const args = parseArguments(value)
  const name = typeof args.name === 'string' ? args.name.trim() : ''
  return name === '' ? undefined : name
}

function loadedSkillCalls(messages: readonly unknown[]): Map<string, string> {
  const calls = new Map<string, string>()
  for (const message of messages) {
    if (!isRecord(message) || message.role !== 'assistant' || !Array.isArray(message.content)) continue
    for (const block of message.content) {
      if (!isRecord(block) || block.type !== 'tool-call' || block.name !== 'skill') continue
      if (typeof block.id !== 'string') continue
      const name = parseSkillCallName(block.arguments)
      if (name !== undefined) calls.set(block.id, name)
    }
  }
  return calls
}

async function queryStatus(
  ctx: Context, statusTool: string, name: string, agent: unknown,
  signal: AbortSignal | undefined, callId: number,
): Promise<SkillStatusLookup> {
  try {
    const batch = await ctx.tools.execute({
      calls: [{
        type: 'tool-call',
        id: `dshbot-skill-status-${callId}` as ToolCallId,
        name: statusTool,
        arguments: JSON.stringify({ schema: BOT_SKILL_USE_STATUS_SCHEMA, name }),
      }],
      ...signal === undefined ? {} : { signal },
      ...agent === undefined ? {} : { agent: agent as never },
    })
    return skillStatusLookup(batch.results[0]?.result)
  } catch {
    return { failure: 'exception' }
  }
}

function replaceLoadedSkillResult(message: unknown, status: string): unknown {
  if (!isRecord(message)) return message
  return {
    ...message,
    isError: true,
    content: [{
      type: 'text',
      text: `Error: skill provenance is ${status}; its instructions were NOT loaded. Re-read the corrected skill before acting.`,
    }],
  }
}

function replaceUnverifiedSkillResult(message: unknown): unknown {
  if (!isRecord(message)) return message
  return {
    ...message,
    isError: true,
    content: [{
      type: 'text',
      text: `Error: [skill provenance] The skill has no verifiable content source (${SKILL_CONTENT_UNKNOWN}); its instructions were NOT loaded.`,
    }],
  }
}


/** Apply known-invalid statuses to catalog and loaded skill messages. */
export function filterSkillProvenanceMessages(
  messages: readonly unknown[],
  statuses: ReadonlyMap<string, string | null | undefined>,
  contentUnknown: ReadonlySet<string> = new Set(),
): readonly unknown[] {
  const invalid = new Set([...statuses]
    .filter(([, status]) => isKnownInvalid(status))
    .map(([name]) => name))
  const blocked = new Set([...invalid, ...contentUnknown])
  if (blocked.size === 0) return messages
  const calls = loadedSkillCalls(messages)
  return messages.map(message => {
    const catalog = filterCatalogMessage(message, blocked)
    if (catalog !== message) return catalog
    if (!isRecord(message) || message.role !== 'tool') return message
    if (!isRecord(message.source) || typeof message.source.callId !== 'string') return message
    const name = calls.get(message.source.callId)
    if (name === undefined || !blocked.has(name)) return message
    if (invalid.has(name)) {
      return replaceLoadedSkillResult(message, statuses.get(name) ?? 'unknown')
    }
    return replaceUnverifiedSkillResult(message)
  })
}

export default function dshbotSkillUseGate(
  ctx: Context,
  config: SkillUseGateConfig = {},
): void {
  const enabled = config.enabled !== false
  const statusTool = config.statusTool ?? BOT_SKILL_USE_STATUS_TOOL
  let nextCallId = 0

  ctx.on('agent/pre-step', async (payload: {
    agent?: unknown
    signal?: AbortSignal
  }, next: () => Promise<unknown>) => {
    if (!enabled) return next()
    if (!botSessionOwned(ctx, payload as never)) return next()
    const decision = await next()
    if (!isRecord(decision) || !Array.isArray(decision.messages)) return decision
    const messages = decision.messages
    const names = new Set<string>()
    for (const message of messages) {
      if (!isRecord(message) || !isRecord(message.source)) continue
      if (message.source.kind !== 'skill-catalog'
        || !Array.isArray(message.source.entries)) continue
      for (const entry of message.source.entries) {
        if (isRecord(entry) && typeof entry.name === 'string') names.add(entry.name)
      }
    }
    const calls = loadedSkillCalls(messages)
    for (const name of calls.values()) names.add(name)
    if (names.size === 0) return decision

    const statuses = new Map<string, string | null | undefined>()
    const contentUnknown = new Set<string>()
    let callId = nextCallId
    for (const name of names) {
      callId += 1
      const lookup = await queryStatus(
        ctx, statusTool, name, payload.agent, payload.signal, callId)
      if ('status' in lookup) {
        statuses.set(name, lookup.status)
        if (lookup.contentBasis !== 'known') contentUnknown.add(name)
      } else {
        statuses.set(name, undefined)
      }
    }
    nextCallId = callId
    const filtered = filterSkillProvenanceMessages(messages, statuses, contentUnknown)
    if (filtered === messages) return decision
    return { ...decision, messages: filtered }
  })

  ctx.on('tools/pre-execute', async (exec: {
    name: string
    arguments?: unknown
    agent?: unknown
    callId?: string
    signal?: AbortSignal
  }, next: () => Promise<unknown>) => {
    if (!enabled) return next()
    if (exec.name !== 'skill') return next()
    if (!botSessionOwned(ctx, exec as never)) return next()

    const args = parseArguments(exec.arguments)
    const name = typeof args.name === 'string' ? args.name.trim() : ''
    if (name === '') {
      return { kind: 'deny', reason: '[skill provenance] Missing skill name; the loader was NOT run.' }
    }

    nextCallId += 1
    let status: string | null
    try {
      const batch = await ctx.tools.execute({
        calls: [{
          type: 'tool-call',
          id: `dshbot-skill-use-${nextCallId}` as ToolCallId,
          name: statusTool,
          arguments: JSON.stringify({ schema: BOT_SKILL_USE_STATUS_SCHEMA, name }),
        }],
        ...exec.signal === undefined ? {} : { signal: exec.signal },
        ...exec.agent === undefined ? {} : { agent: exec.agent as never },
      })
      const lookup = skillStatusLookup(batch.results[0]?.result)
      if ('failure' in lookup) return statusUnavailable()
      status = lookup.status
      const code = skillUseGateCode(status, lookup.contentBasis)
      if (code === null) return next()
      if (code === SKILL_CONTENT_UNKNOWN) return contentUnknown()
      return denial(status)
    } catch {
      return statusUnavailable('exception')
    }
    if (skillUseDecision(status) === 'allow') return next()
    return denial(status)
  })
}

// The gate calls the internal status tool through `ctx.tools.execute`; Cordis
// requires the service dependency to be declared, otherwise the pre-step
// lookup throws before the host ever sees the status request.
dshbotSkillUseGate.inject = ['tools']
