// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { AssembleContext } from '@deepseek-ai/dsh-system-prompt'
import { createPhoneVolatileContextSource } from './volatile-mcp.ts'
import { BOT_SESSION_PREFIX } from './bot-sessions.ts'
import {
  MAINTAINER_AGENT_PRESET,
  MAINTAINER_SESSION_PREFIX,
  VERIFIER_AGENT_PRESET,
  VERIFIER_SESSION_PREFIX,
  isRestrictedAgent,
  restrictedPolicyForHeader,
  restrictedPresetForSessionId,
} from '../../lifecycle-gate/src/restricted-session.ts'

export {
  MAINTAINER_AGENT_PRESET,
  MAINTAINER_SESSION_PREFIX,
  VERIFIER_AGENT_PRESET,
  VERIFIER_SESSION_PREFIX,
}

/**
 * Both host-minted restricted sessions (the read-only verifier and the
 * background maintainer) are excluded from the ordinary Bot volatile blocks
 * (memory, automation, variant, persona): a verifier would otherwise receive
 * evidence it is supposed to re-check itself, and the maintainer would receive
 * the user-facing persona/automation surface. The exclusion is decided by the
 * shared mechanism in `restricted-session.ts`, so the two kinds cannot drift.
 */
export function isRestrictedVolatileAgent(agent: Agent | undefined): boolean {
  return isRestrictedAgent(agent)
}

export const VOLATILE_BLOCK_ORDER = Object.freeze([
  'variant',
  'time',
  'persona',
  'memory',
  'automation',
] as const)

export type VolatileBlockName = typeof VOLATILE_BLOCK_ORDER[number]
export type PromptLang = 'en' | 'zh'

export interface VolatileSnapshot {
  readonly variant?: string
  readonly persona?: string
  readonly memory?: string
  readonly automation?: string
}

export interface VolatileSourceRequest {
  readonly sessionId: string
  readonly signal?: AbortSignal
  readonly agent?: Agent
}

export type VolatileContextSource = (request: VolatileSourceRequest) => Promise<VolatileSnapshot>

export interface VolatileContextConfig {
  readonly source?: VolatileContextSource
  readonly now?: () => Date
  readonly lang?: () => PromptLang
  /**
   * Agent preset the App-minted Bot sessions (`gb-*`) must run. The session
   * is still blank in `agent/created`, so selecting here lands before the
   * first turn and leaves the DSH workbench's `standard` default untouched.
   * Empty/absent means no selection is attempted.
   */
  readonly botAgentPreset?: string
  /**
   * Agent preset for the host-issued maintainer session (`gb-maintainer-*`,
   * spec/bot/v2 §4.1). Empty/absent means no selection is attempted; the
   * profile sets it. The read-only verifier preset is frozen by contract
   * (`pdsh-verifier`) and is not configurable.
   */
  readonly maintainerAgentPreset?: string
}

/**
 * Pick the preset for one freshly created Bot-owned session. Restricted
 * sessions are selected by the same reserved prefixes the App mints; every
 * other Bot session gets the ordinary Bot surface.
 */
export function agentPresetForSession(
  sessionId: string,
  botAgentPreset: string,
  maintainerAgentPreset: string,
): string {
  if (sessionId.startsWith(MAINTAINER_SESSION_PREFIX)) return maintainerAgentPreset
  return restrictedPresetForSessionId(sessionId) ?? botAgentPreset
}

/** Session id of an Agent; `agent.id` is a SessionId, but resumed agents may
 * expose the live session id more reliably. */
export function agentSessionIdOf(agent: Agent): string {
  const sessionId = (agent as Agent & { session?: { id?: unknown } }).session?.id
  if (typeof sessionId === 'string' && sessionId !== '') return sessionId
  return typeof agent.id === 'string' ? agent.id : ''
}

/** Structural view of the DSH agent-preset registry, kept dependency-free. */
export interface BotAgentPresetSelector {
  select(agent: Agent, agentPreset: string): Promise<string>
}

/**
 * Select `agentPreset` for one freshly created Bot session. A session that
 * already started its first turn cannot change composition (`agent-preset/locked`);
 * that is a normal recovered session, not a failure. Every other error is
 * rethrown so a miscomposed image fails closed instead of silently keeping
 * the workbench's full tool surface.
 */
export async function selectBotAgentPreset(
  presets: BotAgentPresetSelector | undefined,
  agent: Agent,
  agentPreset: string,
): Promise<boolean> {
  const preset = agentPreset.trim()
  if (presets === undefined || preset === ''
      || !agentSessionIdOf(agent).startsWith(BOT_SESSION_PREFIX)) return false
  try {
    const committed = await presets.select(agent, preset)
    // The preset is the tool boundary, so a Worker that committed a different
    // composition must fail closed instead of silently keeping a wider one.
    if (committed !== preset) {
      throw new Error(`agent preset selection committed "${committed}" instead of "${preset}"`)
    }
    return true
  } catch (error) {
    if ((error as { code?: unknown }).code === 'agent-preset/locked') return false
    throw error
  }
}

export interface VolatileBlock {
  readonly name: VolatileBlockName
  readonly text: string
}

interface BotAssembleContext extends AssembleContext {
  readonly agent?: Agent
}

const MINUTE_MS = 60_000
const EMPTY_SNAPSHOT: VolatileSnapshot = Object.freeze({})

const TIME_TEXT = Object.freeze({
  en: {
    heading: '## Time',
    body: (tz: string, offset: string) => `The user lives in ${tz} (UTC${offset}), and this computer's clock is set to that zone, so \`date\`, file mtimes, and other local times already read in the user's time. Report every time to them in that zone with a short label; convert timestamps that carry their own zone (a trailing Z, an explicit offset, a git log line) before reporting them.`,
    current: (local: string, tz: string) => `Current local time: ${local} (${tz}).`,
  },
  zh: {
    heading: '## 时间',
    body: (tz: string, offset: string) => `用户住在 ${tz}（UTC${offset}），这台电脑的时钟也设在这个时区，所以 \`date\`、文件 mtime 和其他本地时间读出来已经是用户时区的时间。向用户报告任何时间，都用这个时区并带一个简短标签；自带时区的时间戳（以 Z 结尾、带明确偏移、git log 行）先换算再报告。`,
    current: (local: string, tz: string) => `当前本地时间：${local}（${tz}）。`,
  },
})

export function minutePrecision(now: Date | number | string = new Date()): Date {
  const ms = now instanceof Date ? now.getTime() : new Date(now).getTime()
  return new Date(Number.isFinite(ms) ? Math.floor(ms / MINUTE_MS) * MINUTE_MS : Date.now())
}

export function resolvePromptLang(value?: string): PromptLang {
  const locale = value ?? Intl.DateTimeFormat().resolvedOptions().locale
  return locale.trim().toLowerCase().startsWith('en') ? 'en' : 'zh'
}

export function timeZoneBlock(now = new Date(), lang?: PromptLang): string {
  const resolvedLang = resolvePromptLang(lang)
  const text = TIME_TEXT[resolvedLang]
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  const offsetMin = -now.getTimezoneOffset()
  const sign = offsetMin >= 0 ? '+' : '-'
  const hh = String(Math.floor(Math.abs(offsetMin) / 60)).padStart(2, '0')
  const mm = String(Math.abs(offsetMin) % 60).padStart(2, '0')
  const local = now.toLocaleString('sv-SE', { hour12: false })
  return [
    text.heading,
    '',
    text.body(tz, `${sign}${hh}:${mm}`),
    text.current(local, tz),
  ].join('\n')
}

function blockText(value: string | undefined): string {
  return typeof value === 'string' ? value.trim() : ''
}

export function sessionIdFor(context: BotAssembleContext | undefined): string {
  const agent = context?.agent
  return String(agent?.id || agent?.session?.id || '')
}

export function collectVolatileBlocks(
  snapshot: VolatileSnapshot = EMPTY_SNAPSHOT,
  options: { now?: Date; lang?: PromptLang } = {},
): VolatileBlock[] {
  const blocks: Record<VolatileBlockName, string> = {
    variant: blockText(snapshot.variant),
    time: timeZoneBlock(minutePrecision(options.now ?? new Date()), options.lang),
    persona: blockText(snapshot.persona),
    memory: blockText(snapshot.memory),
    automation: blockText(snapshot.automation),
  }
  return VOLATILE_BLOCK_ORDER.map(name => ({ name, text: blocks[name] }))
}

export function renderVolatileContext(
  snapshot: VolatileSnapshot = EMPTY_SNAPSHOT,
  options: { now?: Date; lang?: PromptLang } = {},
): string {
  return collectVolatileBlocks(snapshot, options)
    .map(block => block.text)
    .filter(Boolean)
    .join('\n\n')
}

export default function dshbotVolatileContext(ctx: Context, config: VolatileContextConfig = {}): void {
  const snapshots = new Map<string, VolatileSnapshot>()
  const revisions = new Map<string, number>()
  const source = config.source ?? createPhoneVolatileContextSource(ctx)
  const now = config.now ?? (() => new Date())
  const lang = config.lang ?? (() => resolvePromptLang())
  const botAgentPreset = typeof config.botAgentPreset === 'string' ? config.botAgentPreset.trim() : ''
  const maintainerAgentPreset = typeof config.maintainerAgentPreset === 'string'
    ? config.maintainerAgentPreset.trim()
    : ''

  if (botAgentPreset !== '' || maintainerAgentPreset !== '') {
    ctx.on('agent/created', async ({ agent }) => {
      // A host-minted restricted session (verifier or maintainer) already
      // carries its immutable creation header preset. Never overwrite it with
      // the ordinary Bot surface; the preset decides the tool boundary.
      // Ordinary sessions also have a header preset (`standard` is the
      // controller default), so only a *restricted* header may skip selection.
      if (restrictedPolicyForHeader(agent) !== undefined) return
      // Defense in depth: a transport that dropped the explicit header still
      // resolves the reserved session id to its frozen restricted preset.
      const preset = agentPresetForSession(
        agentSessionIdOf(agent), botAgentPreset, maintainerAgentPreset)
      if (preset === '') return
      const presets = ctx.get('agentPresets') as BotAgentPresetSelector | undefined
      if (presets === undefined) {
        if (!agent.id.startsWith(BOT_SESSION_PREFIX)) return
        throw new Error(`agent preset "${preset}" is configured but the agentPresets service is not mounted`)
      }
      await selectBotAgentPreset(presets, agent, preset)
    })
  }

  const snapshotFor = (context: BotAssembleContext): VolatileSnapshot => {
    const sessionId = sessionIdFor(context)
    return sessionId === '' ? EMPTY_SNAPSHOT : snapshots.get(sessionId) ?? EMPTY_SNAPSHOT
  }

  const refresh = async (context: BotAssembleContext): Promise<void> => {
    const sessionId = sessionIdFor(context)
    if (sessionId === '') return
    snapshots.set(sessionId, EMPTY_SNAPSHOT)
    const revision = (revisions.get(sessionId) ?? 0) + 1
    revisions.set(sessionId, revision)
    let snapshot = EMPTY_SNAPSHOT
    try {
      const candidate: unknown = await source({
        sessionId,
        ...context.signal === undefined ? {} : { signal: context.signal },
        ...context.agent === undefined ? {} : { agent: context.agent },
      })
      if (candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate)) {
        snapshot = candidate as VolatileSnapshot
      }
    } catch {}
    if (revisions.get(sessionId) === revision && !context.signal?.aborted) {
      snapshots.set(sessionId, snapshot)
    }
  }

  ctx.on('agent/disposed', ({ agent }) => {
    const sessionId = String(agent.id || agent.session?.id || '')
    snapshots.delete(sessionId)
    revisions.delete(sessionId)
  })

  ctx.systemPrompt.context({
    name: 'dshbot:volatile',
    order: 300,
    text: context => isRestrictedAgent(context.agent)
      ? ''
      : renderVolatileContext(snapshotFor(context), { now: now(), lang: lang() }),
  })

  ctx.on('system-prompt/assemble', async (_assembly, context, next) => {
    if (!isRestrictedAgent(context.agent)) await refresh(context)
    const transformed = await next()
    return ctx.systemPrompt.refreshContext({ ...transformed, tools: [] }, context)
  })
}

dshbotVolatileContext.inject = ['systemPrompt', 'tools']
