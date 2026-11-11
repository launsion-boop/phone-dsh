// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import { botOwnedSessions } from './bot-sessions.ts'
import { sessionIdFor } from './identity-bridge.ts'

export interface RedactionReport {
  readonly count: number
  readonly rules: readonly { rule: string; count: number }[]
}

export interface Redactor {
  redact(text: string): string
  redactWithReport(text: string): { text: string } & RedactionReport
}

const RULES: readonly { id: string; re: RegExp; replacement: string }[] = [
  { id: 'private-key', re: /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----|$)/g, replacement: '«secret:private-key»' },
  { id: 'sk-token', re: /\bsk-[A-Za-z0-9][A-Za-z0-9_-]{14,}\b/g, replacement: '«secret:sk-token»' },
  { id: 'aws-access-key', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, replacement: '«secret:aws-access-key»' },
  { id: 'github-token', re: /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g, replacement: '«secret:github-token»' },
  { id: 'gitlab-token', re: /\bglpat-[A-Za-z0-9_-]{20,}\b/g, replacement: '«secret:gitlab-token»' },
  { id: 'slack-token', re: /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/g, replacement: '«secret:slack-token»' },
  { id: 'jwt', re: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, replacement: '«secret:jwt»' },
]

export function createRedactor(secrets: readonly string[] = []): Redactor {
  const variants = [...new Set(secrets.filter(secret => secret.length >= 4).flatMap(secret => {
    const bytes = new TextEncoder().encode(secret)
    const base64 = btoa(String.fromCharCode(...bytes))
    return [secret, encodeURIComponent(secret), base64, base64.replace(/=+$/, ''), base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')]
  }))].sort((a, b) => b.length - a.length)
  return {
    redact(text) { return this.redactWithReport(text).text },
    redactWithReport(text) {
      let output = text
      const counts = new Map<string, number>()
      for (const variant of variants) {
        if (!variant || !output.includes(variant)) continue
        const count = output.split(variant).length - 1
        output = output.split(variant).join('«secret:known-secret»')
        counts.set('known-secret', (counts.get('known-secret') ?? 0) + count)
      }
      for (const rule of RULES) {
        output = output.replace(rule.re, match => {
          counts.set(rule.id, (counts.get(rule.id) ?? 0) + 1)
          return rule.replacement
        })
      }
      output = output.replace(/\b(password|passwd|passphrase)(\s*[:=]\s*)("[^"\n]{4,}"|'[^'\n]{4,}')/gi, (_match, key: string, separator: string) => {
        counts.set('password', (counts.get('password') ?? 0) + 1)
        return `${key}${separator}«secret:password»`
      })
      const rules = [...counts.entries()].map(([rule, count]) => ({ rule, count }))
      return { text: output, count: rules.reduce((sum, entry) => sum + entry.count, 0), rules }
    },
  }
}


/** One classified external origin for the observation envelope. */
export interface ObservationSource {
  readonly source: 'tool' | 'connector' | 'device' | 'device-task' | 'web' | 'subagent' | 'agent' | 'attachment'
  readonly origin: string
  readonly owner: string
}

const OBSERVATION_ATTRIBUTE_ORDER = ['source', 'origin', 'at', 'owner', 'ref'] as const

/** Escape one attribute value; the body uses the marker-only rule below. */
export function escapeObservationAttribute(value: string): string {
  return value.replace(/[&"<>]/gu, character => {
    switch (character) {
      case '&': return '&amp;'
      case '"': return '&quot;'
      case '<': return '&lt;'
      default: return '&gt;'
    }
  }).replace(/[\u0000-\u001f\u007f]/gu, character => `\\u${character.charCodeAt(0).toString(16).padStart(4, '0')}`)
}

/** Escape only a marker-looking `<`; ordinary angle brackets stay literal. */
export function escapeObservationBody(text: string): string {
  return text.replace(/<(?=\s*\/?\s*observation\b)/giu, '\\u003c')
}

/** Encode one observation envelope exactly as the shared golden expects. */
export function encodeObservationEnvelope(
  envelope: { readonly source: string; readonly origin: string; readonly at: string; readonly owner: string; readonly ref: string; readonly text: string },
): string {
  const attributes = OBSERVATION_ATTRIBUTE_ORDER.map(name => {
    const value = name === 'source' ? envelope.source
      : name === 'origin' ? envelope.origin
        : name === 'at' ? envelope.at
          : name === 'owner' ? envelope.owner
            : envelope.ref
    return `${name}="${escapeObservationAttribute(value)}"`
  }).join(' ')
  return `<observation ${attributes}>\n${escapeObservationBody(envelope.text)}\n</observation>`
}

/** The single redaction trace line appended to one redacted Bot tool result. */
export function redactionTraceMarker(request: { readonly rules: readonly { rule: string; count: number }[] }): string {
  const rules = [...request.rules]
    .filter(entry => entry.count > 0)
    .sort((lhs, rhs) => lhs.rule < rhs.rule ? -1 : lhs.rule > rhs.rule ? 1 : 0)
    .map(entry => `${entry.rule}:${entry.count}`)
  return rules.length === 0 ? '' : `[pdsh-redaction rules=${rules.join(',')}]`
}

function stringArgument(value: unknown, key: string): string | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const member = (value as Record<string, unknown>)[key]
  return typeof member === 'string' && member !== '' ? member : undefined
}

/**
 * Classify one tool result. `mcp__phone__` is the App's own Bot surface, not an
 * external connector; its Android/BLE tools are device output. A bash result
 * and every other host tool deliberately return undefined (no envelope).
 */
export function classifyObservation(name: string, args: unknown): ObservationSource | undefined {
  const bareName = name.startsWith('mcp__phone__') ? name.slice('mcp__phone__'.length) : name
  if (bareName === 'web_fetch' || bareName === 'web_search') {
    return { source: 'web', origin: stringArgument(args, 'url') ?? bareName, owner: 'unknown' }
  }
  if (bareName === 'Task' || bareName === 'AwaitTask' || bareName === 'StopSubagent') {
    const id = stringArgument(args, 'task_id') ?? stringArgument(args, 'agent_id') ?? stringArgument(args, 'id') ?? bareName
    return { source: 'subagent', origin: `task:${id}`, owner: `agent:${id}` }
  }
  if (name.startsWith('mcp__phone__android_') || name.startsWith('mcp__phone__ble_')) {
    const id = stringArgument(args, 'device_id') ?? stringArgument(args, 'deviceId')
      ?? stringArgument(args, 'address') ?? stringArgument(args, 'id') ?? name
    return { source: 'device', origin: `device:${id}`, owner: `device:${id}` }
  }
  if (name.startsWith('mcp__phone__')) return undefined
  if (name.startsWith('mcp__')) {
    const parts = name.split('__')
    const server = parts[1] ?? 'unknown'
    const tool = parts.slice(2).join('__')
    return { source: 'connector', origin: `mcp://${server}/${tool}`, owner: 'unknown' }
  }
  if (bareName === 'read') {
    const path = stringArgument(args, 'path')
    if (path !== undefined && path.includes('/imports/attachments-')) {
      const base = path.split('/').pop() ?? path
      return { source: 'attachment', origin: `attachment:${base}`, owner: 'user' }
    }
  }
  return undefined
}

interface ToolCallEventLike {
  readonly type?: unknown
  readonly seq?: unknown
  readonly data?: { readonly callId?: unknown } | null
}

function toolCallSequence(agent: unknown, callId: string | undefined): { sessionId: string; seq: number } | undefined {
  if (callId === undefined || callId === '') return undefined
  const session = (agent as { session?: { snapshotEvents?: () => readonly ToolCallEventLike[] } } | undefined)?.session
  if (session?.snapshotEvents === undefined) return undefined
  let found: number | undefined
  for (const event of session.snapshotEvents()) {
    if (event.type !== 'tool/call') continue
    if (event.data?.callId === callId && typeof event.seq === 'number') found = event.seq
  }
  const sessionId = sessionIdFor(agent as never)
  return found === undefined || sessionId === '' ? undefined : { sessionId, seq: found }
}

function sessionIsBotOwned(ctx: Context, agent: unknown): boolean {
  const sessionId = sessionIdFor(agent as never)
  if (sessionId === '') return false
  return botOwnedSessions(ctx).has(sessionId)
}

export function redactContentBlocks(blocks: unknown, redactor: Redactor): { blocks: unknown } & RedactionReport {
  if (!Array.isArray(blocks)) return { blocks, count: 0, rules: [] }
  const counts = new Map<string, number>()
  const output = blocks.map(block => {
    if (block === null || typeof block !== 'object' || typeof (block as { text?: unknown }).text !== 'string') return block
    const result = redactor.redactWithReport((block as { text: string }).text)
    for (const rule of result.rules) counts.set(rule.rule, (counts.get(rule.rule) ?? 0) + rule.count)
    return { ...block, text: result.text }
  })
  const rules = [...counts.entries()].map(([rule, count]) => ({ rule, count }))
  return { blocks: output, count: rules.reduce((sum, entry) => sum + entry.count, 0), rules }
}

export default function dshbotRedact(ctx: Context): void {
  const redactor = createRedactor()
  ctx.on('tools/post-execute', async (exec: {
    readonly name: string
    readonly callId?: string
    readonly arguments?: unknown
    readonly agent?: unknown
  }, result: { content?: unknown }, next: () => Promise<any>) => {
    const downstream = await next()
    try {
      if (downstream?.kind === 'block') {
        const redacted = redactContentBlocks(downstream.feedback, redactor)
        return redacted.count ? { ...downstream, feedback: redacted.blocks } : downstream
      }
      const sourceContent = Array.isArray(downstream?.content) ? downstream.content : result.content
      if (!Array.isArray(sourceContent)) return downstream
      const redacted = redactContentBlocks(sourceContent, redactor)
      let blocks = redacted.blocks as readonly unknown[]
      const botOwned = sessionIsBotOwned(ctx, exec.agent)
      let wrapped = false
      const observation = botOwned ? classifyObservation(exec.name, exec.arguments) : undefined
      const call = observation === undefined ? undefined : toolCallSequence(exec.agent, exec.callId)
      if (observation !== undefined && call !== undefined) {
        const ref = `record://session/${call.sessionId}#${call.seq}`
        const at = new Date().toISOString()
        blocks = blocks.map(block => {
          if (block === null || typeof block !== 'object'
              || (block as { type?: unknown }).type !== 'text'
              || typeof (block as { text?: unknown }).text !== 'string') return block
          const text = (block as { text: string }).text
          if (/^\s*<observation\s/u.test(text) && text.includes('</observation>')) return block
          wrapped = true
          return { ...block, text: encodeObservationEnvelope({ ...observation, at, ref, text }) }
        })
      }
      const trace = redacted.count > 0 && botOwned ? redactionTraceMarker(redacted) : ''
      if (trace !== '') {
        blocks = appendRedactionTrace(blocks, trace)
      }
      if (!redacted.count && !wrapped && trace === '') return downstream
      return {
        kind: 'accept', content: blocks,
        ...(Array.isArray(downstream?.additionalContexts) ? { additionalContexts: downstream.additionalContexts } : {}),
      }
    } catch {
      return {
        kind: 'block',
        feedback: [{ type: 'text', text: '[redact] Tool output could not be checked for secrets and was withheld.' }],
      }
    }
  })
}

/** Append the trace line to the last text block, adding one when needed. */
function appendRedactionTrace(blocks: readonly unknown[], trace: string): readonly unknown[] {
  for (let index = blocks.length - 1; index >= 0; index -= 1) {
    const block = blocks[index]
    if (block === null || typeof block !== 'object'
        || (block as { type?: unknown }).type !== 'text'
        || typeof (block as { text?: unknown }).text !== 'string') continue
    const copy = [...blocks]
    copy[index] = { ...block, text: `${(block as { text: string }).text}\n${trace}` }
    return copy
  }
  return [...blocks, { type: 'text', text: trace }]
}

dshbotRedact.inject = ['tools']
