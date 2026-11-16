#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Derive the Worker profile's Bot persona prefixes from the Bot-owned prompt
 * sources. Source of truth:
 *   plugins/bot-runtime/prompts/system-prompt.md / system-prompt.zh-CN.md
 *   plugins/bot-runtime/prompts/bot-only-increment.md
 *
 * The global `system-prompt.personaPrefix` is the base Bot prompt (shared
 * baseline; no r8 increment). `preset-phone-bot` shadows it with a scope-only
 * persona row whose prefix is base + the Bot-only increment. `--check` fails on
 * drift; without it both profile blocks are rewritten.
 *
 * Usage:
 *   node scripts/sync-bot-persona.mjs --check
 *   node scripts/sync-bot-persona.mjs
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { assemblePrompt } from '../bot-runtime/src/prompt/assemble.ts'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPOSITORY = resolve(HERE, '..', '..')
const PROFILE = join(REPOSITORY, 'plugins/profile/phone.worker.cordis.patch.yml')
const INCREMENT_FILE = join(REPOSITORY, 'plugins/bot-runtime/prompts/bot-only-increment.md')
const GLOBAL_PREFIX = '    personaPrefix: |\n'
const GLOBAL_END = '\n# WP12 default context profile'
const GLOBAL_INDENT = '      '
const BOT_MARKER = '    - id: preset-phone-bot\n'
const BOT_PREFIX = "          - id: persona\n            name: '@deepseek-ai/dsh-persona'\n            config:\n              prefix: |\n"
const BOT_END = '\n          - id: agent-instructions'
const BOT_INDENT = '                '

function readProfile() {
  return readFileSync(PROFILE, 'utf8')
}

function stripIncrementComments(text) {
  return text.split('\n').filter(line => !line.trimStart().startsWith('<!--')).join('\n').trim()
}

export function expectedBasePersona() {
  return assemblePrompt({ lang: 'zh' }).persona
}

export function expectedBotPersona() {
  const increment = stripIncrementComments(readFileSync(INCREMENT_FILE, 'utf8'))
  if (increment === '') throw new Error('sync-bot-persona: bot-only increment is empty')
  return `${expectedBasePersona()}\n\n${increment}`
}

function personaAt(profile, prefix, end) {
  const start = profile.indexOf(prefix)
  if (start < 0) throw new Error(`sync-bot-persona: missing marker ${JSON.stringify(prefix.trim())}`)
  const bodyStart = start + prefix.length
  const stop = profile.indexOf(end, bodyStart)
  if (stop < 0) throw new Error(`sync-bot-persona: missing end marker ${JSON.stringify(end.trim())}`)
  return {
    bodyStart,
    stop,
    text: profile.slice(bodyStart, stop)
      .split('\n')
      .map(line => line.startsWith('      ') ? line.slice(6) : line)
      .join('\n')
      .trim(),
  }
}

function assertIncrementOnlyInBotBlock(profile, increment, block) {
  const first = profile.indexOf(increment)
  const last = profile.lastIndexOf(increment)
  if (first < 0) throw new Error('sync-bot-persona: bot-only increment missing from the profile')
  if (first !== last) throw new Error('sync-bot-persona: bot-only increment appears more than once in the profile')
  if (first < block.bodyStart || first >= block.stop) {
    throw new Error('sync-bot-persona: bot-only increment appears outside preset-phone-bot')
  }
}

function globalBlock(profile) {
  return personaAt(profile, GLOBAL_PREFIX, GLOBAL_END)
}

function botBlock(profile) {
  const marker = profile.indexOf(BOT_MARKER)
  if (marker < 0) throw new Error('sync-bot-persona: preset-phone-bot missing')
  const slice = profile.slice(marker)
  const prefixAt = slice.indexOf(BOT_PREFIX)
  if (prefixAt < 0) throw new Error('sync-bot-persona: preset-phone-bot persona row missing')
  const bodyStart = marker + prefixAt + BOT_PREFIX.length
  const stop = profile.indexOf(BOT_END, bodyStart)
  if (stop < 0) throw new Error('sync-bot-persona: preset-phone-bot persona end marker missing')
  return {
    bodyStart,
    stop,
    text: profile.slice(bodyStart, stop)
      .split('\n')
      .map(line => line.startsWith(BOT_INDENT) ? line.slice(BOT_INDENT.length) : line)
      .join('\n')
      .trim(),
  }
}

export function checkBotPersonaProfile() {
  const profile = readProfile()
  const base = expectedBasePersona()
  const bot = expectedBotPersona()
  if (globalBlock(profile).text !== base) {
    throw new Error('sync-bot-persona: global personaPrefix is not the base Bot prompt; run sync-bot-persona.mjs')
  }
  const botBlockValue = botBlock(profile)
  if (botBlockValue.text !== bot) {
    throw new Error('sync-bot-persona: preset-phone-bot persona is not base + Bot-only increment; run sync-bot-persona.mjs')
  }
  assertIncrementOnlyInBotBlock(profile, stripIncrementComments(readFileSync(INCREMENT_FILE, 'utf8')), botBlockValue)
  return true
}

function writeBlock(profile, block, text, indent) {
  const generated = text.split('\n').map(line => line ? indent + line : '').join('\n') + '\n'
  return profile.slice(0, block.bodyStart) + generated + profile.slice(block.stop)
}

export function writeBotPersonaProfile() {
  const profile = readProfile()
  const base = expectedBasePersona()
  const bot = expectedBotPersona()
  // Replace the bot block first: its offsets are after the global block.
  let next = writeBlock(profile, botBlock(profile), bot, BOT_INDENT)
  next = writeBlock(next, globalBlock(next), base, GLOBAL_INDENT)
  assertIncrementOnlyInBotBlock(
    next, stripIncrementComments(readFileSync(INCREMENT_FILE, 'utf8')), botBlock(next))
  if (next === profile) return false
  writeFileSync(PROFILE, next)
  return true
}

function invokedByCli() {
  return process.argv[1] !== undefined
    && pathToFileURL(resolve(process.argv[1])).href === import.meta.url
}

if (invokedByCli()) {
  try {
    if (process.argv.includes('--check')) {
      checkBotPersonaProfile()
      console.log('sync-bot-persona: OK (global base + phone-bot increment)')
    } else {
      const changed = writeBotPersonaProfile()
      console.log(changed
        ? 'sync-bot-persona: updated plugins/profile/phone.worker.cordis.patch.yml'
        : 'sync-bot-persona: already up to date')
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
