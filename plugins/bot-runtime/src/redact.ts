// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'

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
  ctx.on('tools/post-execute', async (_exec: unknown, result: { content?: unknown }, next: () => Promise<any>) => {
    const downstream = await next()
    try {
      if (downstream?.kind === 'block') {
        const redacted = redactContentBlocks(downstream.feedback, redactor)
        return redacted.count ? { ...downstream, feedback: redacted.blocks } : downstream
      }
      const content = Array.isArray(downstream?.content) ? downstream.content : result.content
      if (!Array.isArray(content)) return downstream
      const redacted = redactContentBlocks(content, redactor)
      if (!redacted.count) return downstream
      return {
        kind: 'accept', content: redacted.blocks,
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

dshbotRedact.inject = ['tools']
