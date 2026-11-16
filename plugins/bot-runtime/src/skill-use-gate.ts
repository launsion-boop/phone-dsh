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

function denial(status: string | null): { readonly kind: 'deny'; readonly reason: string } {
  const code = skillUseDenialCode(status)
  return {
    kind: 'deny',
    reason: `[skill provenance] This skill is not current (${code}); its instructions were NOT loaded.`,
  }
}

/**
 * Pure mapping used by both the hook and unit tests. Only `current` is
 * readable. `null` means L has no tracked identity for this name; it is
 * explicitly denied as `skill-provenance-untracked`, never treated as current.
 */
export function skillUseDecision(status: string | null): 'allow' | 'deny' {
  return status === 'current' ? 'allow' : 'deny'
}

export default function dshbotSkillUseGate(
  ctx: Context,
  config: SkillUseGateConfig = {},
): void {
  const enabled = config.enabled !== false
  const statusTool = config.statusTool ?? BOT_SKILL_USE_STATUS_TOOL
  let nextCallId = 0

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
      const result = batch.results[0]?.result
      if (result === undefined || result.isError || !isRecord(result.value)) {
        return denial('unknown')
      }
      const value = result.value.structuredContent
      if (!isRecord(value) || value.schema !== BOT_SKILL_USE_STATUS_SCHEMA || value.ok !== true) {
        return denial('unknown')
      }
      const raw = value.status
      if (raw === null || raw === undefined) {
        status = null
      } else if (typeof raw === 'string'
        && ['current', 'changed', 'unavailable', 'revoked', 'erased', 'unknown'].includes(raw)) {
        status = raw
      } else {
        return denial('unknown')
      }
    } catch {
      return denial('unknown')
    }
    if (skillUseDecision(status) === 'allow') return next()
    return denial(status)
  })
}
