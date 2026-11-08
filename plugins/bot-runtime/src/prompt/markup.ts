// SPDX-License-Identifier: MIT

export interface PromptSection {
  readonly kind: 'section'
  readonly id: string
  readonly mountSpec: string
  readonly conditions: { key: string; value: string }[]
  readonly tools: string[]
  readonly text: string
  readonly line: number
}

export interface PromptInsert {
  readonly kind: 'insert'
  readonly target: string
  readonly line: number
}

export interface PromptDocument {
  readonly entries: (PromptSection | PromptInsert)[]
  readonly errors: string[]
}

export interface MountContext {
  readonly engine?: string
  readonly platform?: string
  readonly lang?: string
  readonly variant?: string | null
}

const MOUNT_RE = /^\s*<!--\s*mount:\s*(.*?)\s*-->\s*$/
const TOOLS_RE = /^\s*<!--\s*tools:\s*(.*?)\s*-->\s*$/
const INSERT_RE = /^\s*<!--\s*insert:\s*([A-Za-z0-9_-]+)\s*-->\s*$/
const COMMENT_RE = /<!--[\s\S]*?-->/g
const PLACEHOLDER_RE = /\{\{\s*([A-Za-z0-9_]+)\s*\}\}/g
const TOOL_NAME_RE = /^(?:mcp__[A-Za-z0-9_]+__)?[A-Za-z_][A-Za-z0-9_-]*$/
const INSERT_TARGETS = new Set(['variant'])
const CONDITION_VALUES: Record<string, Set<string>> = {
  engine: new Set(['dsh']),
  platform: new Set(['ios']),
  lang: new Set(['zh', 'en']),
  variant: new Set(['executor', 'wake-routine']),
}

function list(value: string): string[] {
  return value.split(',').map(part => part.trim()).filter(Boolean)
}

export function parseMountSpec(spec: string): { conditions: { key: string; value: string }[]; error?: string } {
  const text = spec.trim()
  if (text === 'always') return { conditions: [] }
  const match = text.match(/^when:\s*(.+)$/)
  if (!match) return { conditions: [], error: `unsupported mount spec "${text}"` }
  const conditions: { key: string; value: string }[] = []
  for (const part of list(match[1]!)) {
    const pair = part.match(/^([a-z]+)=([A-Za-z0-9_-]+)$/)
    if (!pair) return { conditions: [], error: `unsupported mount condition "${part}"` }
    const key = pair[1]!
    const value = pair[2]!
    if (!CONDITION_VALUES[key]) return { conditions: [], error: `unknown mount condition key "${key}"` }
    if (!CONDITION_VALUES[key].has(value)) return { conditions: [], error: `unknown ${key} "${value}"` }
    conditions.push({ key, value })
  }
  return { conditions }
}

export function parsePromptDoc(markdown: string): PromptDocument {
  const errors: string[] = []
  const entries: (PromptSection | PromptInsert)[] = []
  const lines = markdown.replace(COMMENT_RE, comment => {
    if (MOUNT_RE.test(comment) || TOOLS_RE.test(comment) || INSERT_RE.test(comment)) return comment
    return ''
  }).split('\n')
  let pending: { spec: string; line: number; tools: string[]; lines: string[] } | undefined

  const flush = (): void => {
    if (!pending) return
    const body = pending.lines.join('\n').trim()
    if (!body) {
      errors.push(`line ${pending.line}: mount marker has no content`)
      pending = undefined
      return
    }
    const heading = body.match(/^##\s+(.+)$/m)?.[1]?.trim()
    const id = heading ?? (entries.length === 0 ? 'preamble' : `text-${entries.length + 1}`)
    if (entries.some(entry => entry.kind === 'section' && entry.id === id)) errors.push(`duplicate section id "${id}"`)
    const parsed = parseMountSpec(pending.spec)
    if (parsed.error) errors.push(`section "${id}": ${parsed.error}`)
    entries.push({ kind: 'section', id, mountSpec: pending.spec, conditions: parsed.conditions, tools: pending.tools, text: body, line: pending.line })
    pending = undefined
  }

  lines.forEach((raw, index) => {
    const line = index + 1
    const mount = raw.match(MOUNT_RE)
    if (mount) {
      flush()
      pending = { spec: mount[1]!, line, tools: [], lines: [] }
      return
    }
    const tools = raw.match(TOOLS_RE)
    if (tools) {
      if (!pending) {
        errors.push(`line ${line}: tools marker without mount`)
        return
      }
      for (const name of list(tools[1]!)) {
        if (!TOOL_NAME_RE.test(name)) errors.push(`line ${line}: invalid tool "${name}"`)
        else pending.tools.push(name)
      }
      return
    }
    const insert = raw.match(INSERT_RE)
    if (insert) {
      flush()
      if (!INSERT_TARGETS.has(insert[1]!)) errors.push(`line ${line}: unknown insert target "${insert[1]}"`)
      entries.push({ kind: 'insert', target: insert[1]!, line })
      return
    }
    if (!pending) {
      if (raw.trim()) errors.push(`line ${line}: content before first mount marker`)
      return
    }
    pending.lines.push(raw)
  })
  flush()
  if (!entries.some(entry => entry.kind === 'section')) errors.push('prompt has no mounted sections')
  return { entries, errors }
}

export function expandPlaceholders(text: string, values: Record<string, string>): { text: string; errors: string[] } {
  const errors: string[] = []
  const output = text.replace(PLACEHOLDER_RE, (match, key: string) => {
    if (!values[key]) {
      errors.push(`missing value for placeholder {{${key}}}`)
      return match
    }
    return values[key]
  })
  if (/\{\{[A-Za-z0-9_]+\}\}/.test(output)) errors.push('unexpanded prompt placeholder remains')
  return { text: output, errors }
}

export function mountPrompt(
  doc: PromptDocument,
  context: MountContext,
  options: { insert?: Record<string, string>; values?: Record<string, string> } = {},
): { text: string; mounted: (PromptSection | PromptInsert)[]; skipped: (PromptSection | PromptInsert)[]; errors: string[] } {
  const errors = [...doc.errors]
  const mounted: (PromptSection | PromptInsert)[] = []
  const skipped: (PromptSection | PromptInsert)[] = []
  const pieces: string[] = []
  const ctx = { engine: 'dsh', platform: 'ios', lang: 'zh', variant: null, ...context }
  for (const entry of doc.entries) {
    if (entry.kind === 'insert') {
      const text = options.insert?.[entry.target]?.trim()
      if (text) {
        pieces.push(text)
        mounted.push(entry)
      } else skipped.push(entry)
      continue
    }
    const matches = entry.conditions.every(condition => ctx[condition.key as keyof MountContext] === condition.value)
    if (!matches) {
      skipped.push(entry)
      continue
    }
    const expanded = expandPlaceholders(entry.text, options.values ?? {})
    errors.push(...expanded.errors.map(error => `section "${entry.id}": ${error}`))
    pieces.push(expanded.text)
    mounted.push(entry)
  }
  return { text: pieces.filter(Boolean).join('\n\n'), mounted, skipped, errors }
}

export interface ExposureSets {
  readonly mcp: ReadonlySet<string>
  readonly native: ReadonlySet<string>
}

export function checkToolExposure(
  text: string,
  sections: (PromptSection | PromptInsert)[],
  exposed: ExposureSets & { p1: ReadonlySet<string> },
): { ok: boolean; errors: string[]; declared: string[]; mentioned: string[] } {
  const errors: string[] = []
  const declared = [...new Set(sections.flatMap(section => section.kind === 'section' ? section.tools : []))]
  const mentioned = new Set<string>()
  for (const name of declared) {
    const bare = name.startsWith('mcp__') ? name.split('__').slice(2).join('__') : name
    if (!exposed.mcp.has(bare) && !exposed.native.has(bare)) errors.push(`declared tool "${name}" is not exposed`)
  }
  for (const match of text.matchAll(/mcp__([A-Za-z0-9_]+)__([A-Za-z0-9_]+)/g)) {
    const namespace = match[1]!
    const name = match[2]!
    if (namespace !== 'phone') errors.push(`prompt mentions forbidden namespace mcp__${namespace}__${name}`)
    else if (!exposed.mcp.has(name)) errors.push(`prompt mentions unregistered mcp__phone__${name}`)
    else mentioned.add(name)
  }
  for (const name of exposed.p1) {
    if (new RegExp(`\\b${name}\\b`).test(text) || declared.includes(name)) errors.push(`P1 tool "${name}" appears in phone persona`)
  }
  return { ok: errors.length === 0, errors, declared, mentioned: [...mentioned] }
}
