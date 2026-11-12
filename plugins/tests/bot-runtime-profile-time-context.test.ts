// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const profile = readFileSync(
  join(repository, 'plugins/profile/phone.worker.cordis.patch.yml'), 'utf8')

function preset(id: string): string {
  const start = profile.indexOf(`- id: ${id}\n`)
  assert.ok(start >= 0, `missing preset ${id}`)
  const next = profile.indexOf('\n    - id: preset-', start + 1)
  return profile.slice(start, next < 0 ? undefined : next)
}

test('Bot sessions disable the duplicate upstream time-context row', () => {
  const bot = preset('preset-phone-bot')
  const row = bot.indexOf("name: '@deepseek-ai/dsh-time-context'")
  assert.ok(row >= 0, 'the Bot preset still names the upstream time row')
  const after = bot.slice(row, row + 200)
  assert.match(after, /\n\s+disabled: true/,
    'the Bot preset must disable upstream dsh-time-context; the W5 volatile block is the only time injection')

  // The workbench/legacy preset keeps its upstream row: the profile is
  // Bot-scoped, not a global removal.
  const legacy = preset('preset-phone')
  assert.doesNotMatch(legacy, /dsh-time-context'\n\s+disabled: true/)
})

test('the Bot volatile context reads at most once per freshness window', () => {
  const block = profile.slice(profile.indexOf('- id: dshbot-volatile-context'))
  assert.match(block, /refreshMinIntervalMs: \d+/)
})

test('compaction is configured to the small model on the phone profile', () => {
  for (const line of profile.split('\n')) {
    if (!line.includes('summarizationModel:')) continue
    assert.match(line, /summarizationModel: "deepseek-flash"/)
  }
})
