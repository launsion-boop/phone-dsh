#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Derive the Worker profile's Bot persona prefix from the Bot-owned prompt
 * sources. Source of truth:
 *   plugins/bot-runtime/prompts/system-prompt.md
 *   plugins/bot-runtime/prompts/system-prompt.zh-CN.md
 *
 * `personaPrefix` in plugins/profile/phone.worker.cordis.patch.yml is generated
 * from assemblePrompt().persona; a hand-edited copy is fail-closed. `--check`
 * only validates; without it the profile is rewritten.
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
const PREFIX = '    personaPrefix: |\n'
const END = '\n# WP12 default context profile'
const INDENT = '      '

function readProfile() {
  return readFileSync(PROFILE, 'utf8')
}

function actualPersona(profile) {
  const start = profile.indexOf(PREFIX)
  if (start < 0) throw new Error(`sync-bot-persona: ${PREFIX.trim()} missing from ${PROFILE}`)
  const bodyStart = start + PREFIX.length
  const end = profile.indexOf(END, bodyStart)
  if (end < 0) throw new Error('sync-bot-persona: persona end marker missing from the profile')
  const block = profile.slice(bodyStart, end)
  return block.split('\n').map(line => line.startsWith(INDENT) ? line.slice(INDENT.length) : line).join('\n').trim()
}

export function expectedPersona() {
  return assemblePrompt({ lang: 'zh' }).persona
}

export function checkBotPersonaProfile() {
  const expected = expectedPersona()
  const actual = actualPersona(readProfile())
  if (actual !== expected) {
    throw new Error(
      'sync-bot-persona: profile personaPrefix does not match the Bot prompt sources; '
      + 'run `node plugins/scripts/sync-bot-persona.mjs`')
  }
  return true
}

export function writeBotPersonaProfile() {
  const profile = readProfile()
  const expected = expectedPersona()
  const start = profile.indexOf(PREFIX)
  if (start < 0) throw new Error('sync-bot-persona: personaPrefix marker missing')
  const bodyStart = start + PREFIX.length
  const end = profile.indexOf(END, bodyStart)
  if (end < 0) throw new Error('sync-bot-persona: persona end marker missing')
  const generated = expected.split('\n').map(line => line ? INDENT + line : '').join('\n') + '\n'
  const next = profile.slice(0, bodyStart) + generated + profile.slice(end)
  if (next === profile) return false
  writeFileSync(PROFILE, next)
  return true
}

function invokedByCli() {
  return process.argv[1] !== undefined
    && pathToFileURL(resolve(process.argv[1])).href === import.meta.url
}

if (invokedByCli()) {
  const check = process.argv.includes('--check')
  try {
    if (check) {
      checkBotPersonaProfile()
      console.log('sync-bot-persona: OK (profile persona matches the Bot prompt sources)')
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
