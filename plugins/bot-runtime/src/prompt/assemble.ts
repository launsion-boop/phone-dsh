// SPDX-License-Identifier: MIT
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parsePromptDoc, mountPrompt, checkToolExposure } from './markup.ts'
import type { MountContext } from './markup.ts'

export const PHONE_P0_TOOLS = Object.freeze([
  'ask_user', 'show_next_steps', 'show_attachment', 'show_document', 'show_progress',
  'show_checklist', 'show_link', 'UpdateMemory', 'ReadMemory', 'RecallMemory', 'Task', 'AwaitTask',
  'StopSubagent', 'UpdateRoutine', 'ListRoutines', 'RequestApproval', 'SendToUser',
  'SendToAgent', 'CreateTeammate',
])
export const PHONE_P1_TARGET_TOOLS = Object.freeze(['show_table', 'show_callout', 'show_info', 'show_payload', 'show_library'])
export const PHONE_NATIVE_TOOLS = Object.freeze([
  'bash', 'read', 'write', 'edit', 'glob', 'grep', 'web_search', 'web_fetch',
  'job_list', 'job_output', 'job_kill', 'todo_write', 'create_goal', 'get_goal',
  'update_goal',
])

export interface AssemblePromptOptions {
  readonly promptPath?: string
  readonly lang?: 'zh' | 'en'
  readonly workspace?: string
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

export function runtimePersonaBlock({ botName = '大肥鱼', personality = '', description = '', lang = 'zh' }: { botName?: string; personality?: string; description?: string; lang?: 'zh' | 'en' } = {}): string {
  const name = botName.trim()
  if (!name) throw new Error('Bot name must not be empty')
  const traits = personality.trim()
  const detail = Array.from(description.trim()).slice(0, 300).join('')
  if (lang === 'en') {
    return `Your name is ${name}. Answer with that name when asked.${traits ? ` Personality: ${traits}` : ''}${detail ? `\n\n${detail}` : ''}`
  }
  return `你的名字是${name}。用户问起名字时如实回答。${traits ? `个性：${traits}` : ''}${detail ? `\n\n${detail}` : ''}`
}

export function variantBlock(kind: 'executor' | 'wake-routine', lang: 'zh' | 'en' = 'zh'): string {
  if (kind === 'executor') {
    return lang === 'en'
      ? '# 2. Task variant\n\nComplete the delegated task autonomously. Return one concise, self-contained final result to the parent. You cannot message the user directly; do not ask follow-up questions. Approval denial is final; report it instead of working around it.'
      : '# 2. 子代理变体\n\n自主完成被委派的任务，用一条简洁、自包含的最终结果回复父对话。你不能直接向用户发消息，不要追问。审批被拒绝是终局，不要绕过；如实报告。'
  }
  return lang === 'en'
    ? '# 2. Routine variant\n\nYou are running a routine as a hidden turn with the same tools as a normal turn. Carry out the saved instruction autonomously. Do not surface cards (ask_user, show_next_steps, show_*), do not ask questions in the reply, and do not call SendToUser or SendToAgent; the only card this run may raise is RequestApproval. Stay quiet by default: no acknowledgement or progress narration. Your final assistant text is the routine result shown on the routine card; when the saved instruction requires silence and nothing changed, write exactly [quiet].'
    : '# 2. 例行任务变体\n\n你正以隐藏回合运行一次例行任务，具备和正常回合相同的工具能力。自主完成已保存的指令。不要出卡片（ask_user、show_next_steps、show_*），不要在回复里问问题，也不要调用 SendToUser 或 SendToAgent；唯一可能出现的卡片是 RequestApproval。默认保持安静：不确认收到，不播报进度。最后一条助手文本就是本次结果，会显示在例行任务卡片上；保存的指令要求安静且没有新结果时，最终只写 [quiet]。'
}
