// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { AssembleContext } from '@deepseek-ai/dsh-system-prompt'
import { createPhoneVolatileContextSource } from './volatile-mcp.ts'

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
    text: context => renderVolatileContext(snapshotFor(context), { now: now(), lang: lang() }),
  })

  ctx.on('system-prompt/assemble', async (_assembly, context, next) => {
    await refresh(context)
    const transformed = await next()
    return ctx.systemPrompt.refreshContext({ ...transformed, tools: [] }, context)
  })
}

dshbotVolatileContext.inject = ['systemPrompt', 'tools']
