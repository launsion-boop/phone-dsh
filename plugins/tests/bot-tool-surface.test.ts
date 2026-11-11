// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { assemblePrompt, PHONE_NATIVE_TOOLS, PHONE_P0_TOOLS, PHONE_P1_TARGET_TOOLS } from '../bot-runtime/src/prompt/assemble.ts'
import { selectBotAgentPreset, type BotAgentPresetSelector } from '../bot-runtime/src/volatile-context.ts'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const patchPath = join(repository, 'plugins/profile/phone.worker.cordis.patch.yml')

interface YamlType {
  new (tag: string, options: { kind: string; construct: (data: unknown) => unknown }): unknown
}
interface YamlModule {
  readonly Type: YamlType
  readonly DEFAULT_SCHEMA: { extend(types: unknown[]): unknown }
  load(text: string, options: { schema: unknown }): unknown
}
const yaml = createRequire(import.meta.url)('js-yaml') as YamlModule

interface PatchRow {
  readonly id?: string
  readonly name?: string
  readonly disabled?: unknown
  readonly config?: Record<string, unknown>
  readonly insert?: readonly PatchRow[]
}

/** Patch rows use DSH's `!!js` secondary tag; preserve its source as a string. */
function loadPatch(text: string): PatchRow[] {
  const jsType = new yaml.Type('!js', { kind: 'scalar', construct: value => String(value) })
  const schema = yaml.DEFAULT_SCHEMA.extend([jsType])
  return yaml.load(text.replace(/!!js/g, '!js'), { schema }) as PatchRow[]
}

function flatten(rows: readonly PatchRow[]): PatchRow[] {
  const all: PatchRow[] = []
  const visit = (list: readonly PatchRow[] | undefined): void => {
    if (!Array.isArray(list)) return
    for (const row of list) {
      if (row === null || typeof row !== 'object') continue
      all.push(row)
      visit(row.insert)
      const plugins = row.config?.plugins
      if (Array.isArray(plugins)) visit(plugins as PatchRow[])
    }
  }
  visit(rows)
  return all
}

function preset(id: string): PatchRow {
  const row = flatten(loadPatch(readFileSync(patchPath, 'utf8')))
    .find(candidate => candidate.name === '@deepseek-ai/dsh-agent-preset' && candidate.config?.id === id)
  assert.ok(row, `agent preset ${id} is missing from the phone Worker patch`)
  return row
}

const TOOL_ROWS: Record<string, readonly string[]> = {
  '@deepseek-ai/dsh-tool-bash': ['bash'],
  '@deepseek-ai/dsh-tool-fs': ['read', 'write', 'edit'],
  '@deepseek-ai/dsh-tool-fs-search': ['glob', 'grep'],
  '@deepseek-ai/dsh-tool-jobs': ['job_list', 'job_output', 'job_kill'],
  '@deepseek-ai/dsh-tool-todo': ['todo_write'],
  '@deepseek-ai/dsh-tool-goal': ['create_goal', 'get_goal', 'update_goal'],
  '@deepseek-ai/dsh-tool-web': ['web_search', 'web_fetch'],
}

function enabledNativeTools(presetRow: PatchRow): string[] {
  const tools: string[] = []
  const plugins = presetRow.config?.plugins
  assert.ok(Array.isArray(plugins), 'the Bot preset must declare plugins')
  for (const row of flatten(plugins as PatchRow[])) {
    if (row.disabled === true) continue
    const names = TOOL_ROWS[row.name ?? '']
    if (names === undefined) continue
    if (row.name === '@deepseek-ai/dsh-tool-fs') {
      assert.equal(row.config?.readImage, false, 'tool-fs must not add read_image')
      assert.equal(row.config?.applyPatch, false, 'tool-fs must not add apply_patch')
    }
    if (row.name === '@deepseek-ai/dsh-tool-web') {
      assert.ok('search' in (row.config ?? {}), 'tool-web must declare search')
      assert.ok('fetch' in (row.config ?? {}), 'tool-web must declare fetch')
    }
    tools.push(...names)
  }
  return [...new Set(tools)].sort()
}

test('Bot sessions use a phone-bot preset that exposes exactly the prompt native tools', () => {
  const bot = preset('phone-bot')
  const rows = flatten(bot.config?.plugins as PatchRow[])
  const names = rows.map(row => row.name ?? '')
  const ids = rows.map(row => row.id ?? '')

  // Upstream disables the raw subagent tools and the shared workspace skill
  // provider; phoneDSH also drops the DSH schedule, native ask-user, plan,
  // present, workflow and subagent-control rows because the phone persona
  // does not teach them and App routines own scheduling.
  for (const forbidden of [
    '@deepseek-ai/dsh-tool-subagent',
    '@deepseek-ai/dsh-tool-subagent-control',
    '@deepseek-ai/dsh-skill-filesystem',
    '@deepseek-ai/dsh-tool-skill',
    '@deepseek-ai/dsh-tool-schedule',
    '@deepseek-ai/dsh-tool-ask-user',
    '@deepseek-ai/dsh-tool-present',
    '@deepseek-ai/dsh-tool-workflow',
    '@deepseek-ai/dsh-plan-mode',
    '@deepseek-ai/dsh-persona',
  ]) {
    assert.equal(names.includes(forbidden), false, `phone-bot must not mount ${forbidden}`)
  }
  for (const forbiddenId of ['delegation', 'planning', 'tool-subagent', 'tool-subagent-fork', 'tool-skill', 'tool-schedule', 'plan-mode']) {
    assert.equal(ids.includes(forbiddenId), false, `phone-bot must not mount row ${forbiddenId}`)
  }

  assert.deepEqual(enabledNativeTools(bot), [...PHONE_NATIVE_TOOLS].sort())
  assert.deepEqual(rows.map(row => row.id), [
    'agent-instructions', 'time-context', 'tool-bash', 'tool-fs', 'tool-fs-search',
    'tool-jobs', 'command-goal', 'tool-goal', 'tool-todo', 'tool-web', 'compaction',
  ])
})

test('the prompt declares exactly the P0 MCP tools and the preset native tools', () => {
  for (const lang of ['zh', 'en'] as const) {
    const declared = assemblePrompt({ lang }).mount.tools
    const declaredNative = declared.filter(name => (PHONE_NATIVE_TOOLS as readonly string[]).includes(name)).sort()
    const declaredMcp = declared.filter(name => (PHONE_P0_TOOLS as readonly string[]).includes(name)).sort()
    assert.deepEqual(declaredNative, [...PHONE_NATIVE_TOOLS].sort(), `${lang} native tool drift`)
    assert.deepEqual(declaredMcp, [...PHONE_P0_TOOLS].sort(), `${lang} P0 tool drift`)
    for (const name of PHONE_P1_TARGET_TOOLS) assert.equal(declared.includes(name), false)
    assert.equal(declared.length, declaredNative.length + declaredMcp.length, `${lang} declares an unknown tool`)
  }
})

test('the workbench keeps the standard preset and the Bot preset is selected by the plugin', () => {
  const rows = flatten(loadPatch(readFileSync(patchPath, 'utf8')))
  const registry = rows.find(row => row.id === 'agent-preset-registry')
  assert.equal(registry?.config?.default, 'standard', 'the workbench default preset must stay standard')
  assert.equal(rows.some(row => row.name === '@deepseek-ai/dsh-agent-preset' && row.config?.id === 'standard'), false,
    'the phone patch must not override the workbench standard preset')
  const volatile = rows.find(row => row.id === 'dshbot-volatile-context')
  assert.equal(volatile?.config?.botAgentPreset, 'phone-bot')
})

test('only blank gb- sessions select the Bot preset; locked sessions stay recoverable', async () => {
  const calls: [string, string][] = []
  const selector: BotAgentPresetSelector = {
    async select(agent, agentPreset) {
      calls.push([agent.id, agentPreset])
      return agentPreset
    },
  }
  const bot = { id: 'gb-agent-x' } as unknown as Agent
  const workbench = { id: 'session-x' } as unknown as Agent
  assert.equal(await selectBotAgentPreset(selector, bot, ' phone-bot '), true)
  assert.equal(await selectBotAgentPreset(selector, workbench, 'phone-bot'), false)
  assert.equal(await selectBotAgentPreset(undefined, bot, 'phone-bot'), false)
  assert.deepEqual(calls, [['gb-agent-x', 'phone-bot']])

  const locked: BotAgentPresetSelector = {
    async select() {
      throw Object.assign(new Error('This session has already started'), { code: 'agent-preset/locked' })
    },
  }
  assert.equal(await selectBotAgentPreset(locked, bot, 'phone-bot'), false)

  const broken: BotAgentPresetSelector = {
    async select() {
      throw new Error('agent-preset/not-found')
    },
  }
  await assert.rejects(selectBotAgentPreset(broken, bot, 'phone-bot'), /agent-preset\/not-found/)

  // The committed identity is the tool boundary: a Worker that mounted a
  // different preset must fail closed instead of keeping a wider surface.
  const miscomposed: BotAgentPresetSelector = {
    async select() {
      return 'standard'
    },
  }
  await assert.rejects(
    selectBotAgentPreset(miscomposed, bot, 'phone-bot'),
    /committed "standard" instead of "phone-bot"/)
})
