// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { assemblePrompt, PHONE_P0_TOOLS, PHONE_P1_TARGET_TOOLS, runtimePersonaBlock, variantBlock } from '../bot-runtime/src/prompt/assemble.ts'
import { parseMountSpec } from '../bot-runtime/src/prompt/markup.ts'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

test('both persona languages mount every P0 and no P1, with all variants', () => {
  for (const lang of ['zh', 'en'] as const) {
    for (const variant of [null, 'executor', 'wake-routine'] as const) {
      const result = assemblePrompt({ lang, variant, variantText: variant ? variantBlock(variant, lang) : undefined })
      for (const name of PHONE_P0_TOOLS) {
        assert.ok(result.mount.tools.includes(name), `${name} missing from ${lang}`)
        if (name !== 'show_attachment') assert.ok(result.persona.includes(name), `${name} is not taught in ${lang}`)
      }
      for (const name of PHONE_P1_TARGET_TOOLS) assert.equal(result.persona.includes(name), false)
      assert.equal(result.persona.includes('mcp__dshbot__'), false)
      if (variant) assert.ok(result.mount.mounted.includes('insert:variant'))
    }
  }
  assert.equal(parseMountSpec('when: platform=ios').error, undefined)
  assert.ok(parseMountSpec('when: platform=android').error)
  assert.ok(parseMountSpec('when: unknown=value').error)
})

test('Bot name comes from runtime context and profile persona matches the checked assembly', () => {
  assert.ok(runtimePersonaBlock().includes('大肥鱼'))
  const custom = runtimePersonaBlock({ botName: 'Custom Fish' })
  assert.ok(custom.includes('Custom Fish'))
  assert.equal(custom.includes('大肥鱼'), false)
  const profile = readFileSync(join(repository, 'plugins/profile/phone.worker.cordis.patch.yml'), 'utf8')
  const expected = assemblePrompt().persona
  const personaBlock = profile.split('personaPrefix: |\n')[1]?.split('\n# WP12 default context profile')[0]
  assert.ok(personaBlock)
  const actual = personaBlock.split('\n').map(line => line.startsWith('      ') ? line.slice(6) : line).join('\n').trim()
  assert.equal(actual, expected)
  assert.equal(profile.includes('plugins/profile/bot-context.cordis.patch.yml'), false)
  assert.match(profile, /thresholdRatio: 0\.8/)
  assert.match(profile, /maxInlineTokens: 12500/)
  assert.doesNotMatch(profile, /thresholdRatio: 0\.4/)
})
