// SPDX-License-Identifier: MIT
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parsePromptDoc, mountPrompt, checkToolExposure } from './markup.ts'
import type { MountContext } from './markup.ts'

export const PHONE_P0_TOOLS = Object.freeze([
  'ask_user', 'show_next_steps', 'show_attachment', 'show_document', 'show_progress',
  'show_checklist', 'show_link', 'UpdateMemory', 'RecallMemory', 'Task', 'AwaitTask',
  'StopSubagent', 'UpdateRoutine', 'ListRoutines', 'RequestApproval', 'SendToUser',
  'SendToAgent', 'CreateTeammate',
])
export const PHONE_P1_TARGET_TOOLS = Object.freeze(['show_table', 'show_callout', 'show_info', 'show_payload', 'show_library'])
export const PHONE_NATIVE_TOOLS = Object.freeze([
  'bash', 'read', 'write', 'edit', 'glob', 'grep', 'web_search', 'web_fetch',
  'job_list', 'job_output', 'job_kill',
])

export interface AssemblePromptOptions {
  readonly promptPath?: string
  readonly lang?: 'zh' | 'en'
  readonly workspace?: string
  readonly model?: string
  readonly provider?: string
  readonly platform?: string
  readonly variant?: string | null
  readonly variantText?: string
}

export function defaultPromptPath(lang: 'zh' | 'en' = 'zh'): string {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'prompts')
  return join(root, lang === 'en' ? 'system-prompt.md' : 'system-prompt.zh-CN.md')
}

export function assemblePrompt(options: AssemblePromptOptions = {}) {
  const lang = options.lang ?? 'zh'
  const promptPath = options.promptPath ?? defaultPromptPath(lang)
  const doc = parsePromptDoc(readFileSync(promptPath, 'utf8'))
  const context: MountContext = {
    engine: 'dsh', platform: options.platform ?? 'ios', lang,
    variant: options.variant ?? null,
  }
  const mounted = mountPrompt(doc, context, {
    insert: options.variantText ? { variant: options.variantText } : {},
    values: {
      workspace: options.workspace ?? '/dsh/workspace',
      model: options.model ?? 'deepseek-flash',
      provider: options.provider ?? 'deepseek-official',
    },
  })
  const exposure = checkToolExposure(mounted.text, mounted.mounted, {
    mcp: new Set(PHONE_P0_TOOLS),
    native: new Set(PHONE_NATIVE_TOOLS),
    p1: new Set(PHONE_P1_TARGET_TOOLS),
  })
  const errors = [...mounted.errors, ...exposure.errors]
  if (errors.length) throw new Error(`phone persona assembly failed: ${errors.join('; ')}`)
  return {
    persona: mounted.text,
    promptPath,
    lang,
    mount: {
      mounted: mounted.mounted.map(entry => entry.kind === 'section' ? entry.id : `insert:${entry.target}`),
      skipped: mounted.skipped.map(entry => entry.kind === 'section' ? entry.id : `insert:${entry.target}`),
      tools: exposure.declared,
      mentioned: exposure.mentioned,
      chars: mounted.text.length,
    },
  }
}

export function runtimePersonaBlock({ botName = '大肥鱼', personality = '', lang = 'zh' }: { botName?: string; personality?: string; lang?: 'zh' | 'en' } = {}): string {
  const name = botName.trim()
  if (!name) throw new Error('Bot name must not be empty')
  const traits = personality.trim()
  if (lang === 'en') {
    return `Your name is ${name}. Answer with that name when asked.${traits ? ` Personality: ${traits}` : ''}`
  }
  return `你的名字是${name}。用户问起名字时如实回答。${traits ? `个性：${traits}` : ''}`
}

export function variantBlock(kind: 'executor' | 'wake-routine', lang: 'zh' | 'en' = 'zh'): string {
  if (kind === 'executor') {
    return lang === 'en'
      ? '# 2. Task variant\n\nComplete the delegated task autonomously. Return one concise, self-contained final result to the parent. You cannot message the user directly; do not ask follow-up questions. Approval denial is final; report it instead of working around it.'
      : '# 2. 子代理变体\n\n自主完成被委派的任务，用一条简洁、自包含的最终结果回复父对话。你不能直接向用户发消息，不要追问。审批被拒绝是终局，不要绕过；如实报告。'
  }
  return lang === 'en'
    ? '# 2. Routine variant\n\nRun the saved instruction autonomously in a hidden turn. Do not emit process prose or call SendToUser. Surface only useful cards. Your final assistant text is the routine result; use exactly [quiet] when the saved instruction requires silence and nothing changed.'
    : '# 2. 例行任务变体\n\n在隐藏回合自主完成保存的指令，不输出过程散文，不调用 SendToUser，只呈现有用的卡片。最后一条助手文本就是本次结果；保存的指令要求安静且没有新结果时，最终只写 [quiet]。'
}
