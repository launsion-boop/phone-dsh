// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { assemblePrompt, PHONE_NATIVE_TOOLS, PHONE_P0_TOOLS, PHONE_P1_TARGET_TOOLS, runtimePersonaBlock, variantBlock } from '../bot-runtime/src/prompt/assemble.ts'
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

test('the phone persona carries the upstream parity chapters adapted to iOS', () => {
  const sections = new Map<'zh' | 'en', string[]>()
  for (const lang of ['zh', 'en'] as const) {
    const result = assemblePrompt({ lang })
    sections.set(lang, result.persona.split('\n').filter(line => line.startsWith('## ')))
    for (const heading of lang === 'zh'
      ? ['目标验证', '回复长度', '单一聊天线程', '绝不编造数据', '排查问题', '未经请求绝不发送消息', '自主性', '审批与安全', '安全与凭据', '不可信内容', '个人资料', '用户身份', '委派与多任务', '内部细节边界', '时间', '记忆边界', '例行任务与交付', '队友协作', '你的工作区']
      : ['Goal verification', 'Reply length', 'One chat thread', 'Never fabricate data', 'Debugging', 'Never send messages unasked', 'Autonomy', 'Approval and security', 'Security and credentials', 'Untrusted content', 'Profile', 'User identity', 'Delegating and multitasking', 'Internal details boundary', 'Time', 'Memory boundaries', 'Routines and delivery', 'Teammates', 'Your workspace']) {
      assert.ok(result.persona.includes(heading), `${lang} is missing ${heading}`)
    }
    for (const name of PHONE_NATIVE_TOOLS) assert.ok(result.persona.includes(name), `${name} is not taught in ${lang}`)
    for (const forbidden of ['GenerateImage', 'ReportVerification', 'CreateAgent', 'CloudAgent', 'ListMachines', 'CopyToBox', 'Computer', 'mcp__dshbot__', '~/DSHBotWorkspace']) {
      assert.equal(result.persona.includes(forbidden), false, `${lang} still teaches ${forbidden}`)
    }
    assert.ok(result.persona.includes('FishAction'), `${lang} must keep the FishAction boundary`)
    assert.ok(result.persona.includes('<teammates>'), `${lang} must explain the teammates block`)
  }
  assert.equal(sections.get('zh')?.length, sections.get('en')?.length, 'both languages must mount the same chapter count')
})

test('persona description is appended and truncated to 300 characters', () => {
  const description = 'd'.repeat(400)
  const zh = runtimePersonaBlock({ botName: '小鱼', description })
  const en = runtimePersonaBlock({ botName: 'Little Fish', description, lang: 'en' })
  assert.ok(zh.includes('小鱼'))
  assert.ok(en.includes('Little Fish'))
  assert.equal(zh.includes('d'.repeat(301)), false)
  assert.equal(en.includes('d'.repeat(301)), false)
  assert.ok(zh.endsWith('d'.repeat(300)))
  assert.ok(en.endsWith('d'.repeat(300)))
})

test('the routine variant forbids cards and matches the Swift default text', () => {
  const zh = variantBlock('wake-routine', 'zh')
  const en = variantBlock('wake-routine', 'en')
  assert.match(zh, /不要出卡片/)
  assert.match(en, /Do not surface cards/)
  assert.doesNotMatch(zh, /只呈现有用的卡片/)
  assert.doesNotMatch(en, /Surface only useful cards/)
  const swift = readFileSync(join(repository, 'Sources/PhoneDSHBot/MCP/BotDomainVolatileContextProvider.swift'), 'utf8')
  const zhBody = zh.replace(/^# 2\. 例行任务变体\n\n/, '')
  const enBody = en.replace(/^# 2\. Routine variant\n\n/, '')
  assert.ok(swift.includes(zhBody.replace(/\n/g, '\\n')), 'Swift zh routine variant must be byte-identical to assemble.ts')
  assert.ok(swift.includes(enBody.replace(/\n/g, '\\n')), 'Swift en routine variant must be byte-identical to assemble.ts')
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
