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

test('activity guidance teaches one short, object-bearing, result-carrying sentence', () => {
  for (const lang of ['zh', 'en'] as const) {
    const { persona } = assemblePrompt({ lang })
    assert.ok(persona.includes('`description`'), `${lang} must keep bash.description guidance`)
    assert.ok(persona.includes('`task_title`'), `${lang} must keep Task.task_title guidance`)
    assert.ok(persona.includes('等待响应'), `${lang} must use the code-aligned wait sentence`)
    assert.equal(persona.includes('等待模型响应'), false, `${lang} still uses the removed wait sentence`)
    if (lang === 'zh') {
      for (const token of ['10–20 个中文字', '动作 + 这次任务里的对象', '文件名', '#PR', '人名', '会议名',
        '在对比 #174 和 main 的冲突', '冲突在 3 个文件里，在逐个看', '读取相关资料', '已收到查询结果']) {
        assert.ok(persona.includes(token), `zh activity guidance must include ${token}`)
      }
      assert.ok(persona.includes('不要把完整路径、长 URL、整条命令、JSON、原始长回答或技术参数搬上屏'))
      assert.ok(persona.includes('不要写凭证或内部 id'))
      assert.ok(persona.includes('下一句要接住上一句的真实结果'))
      assert.ok(persona.includes('不要往未声明的字段写 intent'))
      assert.ok(persona.includes('不另开摘要模型或请求'))
      assert.ok(persona.includes('不调用专用活动工具'))
      assert.ok(persona.includes('不为刷新气泡发旁白'))
      assert.equal(persona.includes('不要包含文件名、路径、扩展名、网址、命令、内部 ID 或代码'), false,
        'zh must not keep the generalized filename/path prohibition')
    } else {
      for (const token of ['10–20 Chinese characters', "action + this task's object", 'file name', '#PR',
        'person', 'meeting', 'Comparing #174 with main', 'The conflict is in 3 files; checking each one',
        'Reading related material', 'Got the query result']) {
        assert.ok(persona.includes(token), `en activity guidance must include ${token}`)
      }
      assert.ok(persona.includes('never put a full path, long URL, whole command, JSON, raw long answer or technical parameters'))
      assert.ok(persona.includes('never include credentials or internal ids'))
      assert.ok(persona.includes('the next sentence must build on the real result'))
      assert.ok(persona.includes('never write intent into an undeclared field'))
      assert.ok(persona.includes('no separate summary model or request'))
      assert.ok(persona.includes('no dedicated activity tool'))
      assert.ok(persona.includes('no narration just to refresh the bubble'))
      assert.equal(persona.includes('Do not include filenames, paths, extensions, URLs, commands, internal IDs or code'), false,
        'en must not keep the generalized filename/path prohibition')
    }
  }
})

test('reply length and the work step agree on meaningful public progress', () => {
  for (const lang of ['zh', 'en'] as const) {
    const { persona } = assemblePrompt({ lang })
    if (lang === 'zh') {
      assert.ok(persona.includes('这个上限针对最终答复'))
      assert.ok(persona.includes('最终答复不叙述工具调用'))
      assert.ok(persona.includes('有意义的进展、结果或转向节点'))
      assert.ok(persona.includes('带这次任务对象的公开进度'))
      assert.ok(persona.includes('不逐条命令旁白'))
      assert.ok(persona.includes('不专门调用工具或模型来刷新气泡'))
      assert.ok(persona.includes('为了刷新活动气泡专门调用工具或模型'))
      assert.ok(persona.includes('最终答复保持简短；进度句只服务于真实的中间节点'))
      assert.equal(persona.includes('- 不叙述工具调用、文件修改、命令或工作顺序；只给结果'), false,
        'zh must not keep the absolute no-narration bullet in reply length')
      assert.equal(persona.includes('长任务只发一条简短进度'), false,
        'zh must not cap progress to a single long-task line')
    } else {
      assert.ok(persona.includes('This cap is for the final answer'))
      assert.ok(persona.includes('The final answer never narrates tool calls'))
      assert.ok(persona.includes('meaningful progress, result or direction change'))
      assert.ok(persona.includes('naming the real task object'))
      assert.ok(persona.includes('do not narrate each command'))
      assert.ok(persona.includes('do not call a tool or model just to refresh the bubble'))
      assert.ok(persona.includes('refresh the activity bubble'))
      assert.ok(persona.includes('Keep the final answer brief; a progress sentence serves a real intermediate node'))
      assert.equal(persona.includes('- Never narrate tool calls, files changed, commands, or the order of work; state the result'), false,
        'en must not keep the absolute no-narration bullet in reply length')
      assert.equal(persona.includes('Long work gets one short progress line'), false,
        'en must not cap progress to a single long-task line')
    }
  }
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
    assert.ok(result.persona.includes(lang === 'zh'
      ? '面向用户的正文只用人话：不写内部 id、工具名或英文状态枚举'
      : 'Write user-facing prose in plain language: never include internal ids, tool names, or English status enums'),
    `${lang} must keep the internal-detail boundary for user-facing prose`)
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

test('wrap-up content cards use final:true and the host drops later text', () => {
  for (const lang of ['zh', 'en'] as const) {
    const { persona } = assemblePrompt({ lang })
    if (lang === 'zh') {
      assert.ok(persona.includes('收尾卡传 `final: true`'), 'zh tells the model to mark the wrap-up card')
      assert.ok(persona.includes('宿主会压掉之后的助手文本和 SendToUser'), 'zh states the host suppression contract')
      assert.ok(persona.includes('传了就不需要也不应再写字'), 'zh says no text is needed after the final card')
      assert.ok(persona.includes('中途更新进度卡不传 `final`'), 'zh exempts mid-task progress updates')
      assert.ok(persona.includes('内容卡（progress / checklist / link / attachment / document）'), 'zh includes every content-card type')
      assert.ok(persona.includes('一回合最多两张内容卡'), 'zh keeps the two-card cap')
      assert.ok(persona.includes('先把结论写进正文，再把卡放在回复最后'), 'zh keeps cards after the prose conclusion')
      assert.equal(persona.includes('**硬规则：收尾内容卡工具返回后，本回合就结束。**'), false,
        'zh must not keep the round-2 hard-rule paragraph')
      assert.equal(persona.includes('工具返回只是回执，不是新的用户消息'), false,
        'zh must not keep the round-2 receipt paragraph')
    } else {
      assert.ok(persona.includes('Pass `final:true` on the wrap-up card'), 'en tells the model to mark the wrap-up card')
      assert.ok(persona.includes('the host then suppresses later assistant text and SendToUser'), 'en states the host suppression contract')
      assert.ok(persona.includes('you neither need nor should write anything after it'), 'en says no text is needed after the final card')
      assert.ok(persona.includes('Omit `final` for mid-task progress updates'), 'en exempts mid-task progress updates')
      assert.ok(persona.includes('content card (progress / checklist / link / attachment / document)'), 'en includes every content-card type')
      assert.ok(persona.includes('At most two content cards per turn'), 'en keeps the two-card cap')
      assert.ok(persona.includes('put the conclusion in prose first, then the card at the end'), 'en keeps cards after the prose conclusion')
      assert.equal(persona.includes('**Hard rule: a wrap-up content-card tool return ends the turn.**'), false,
        'en must not keep the round-2 hard-rule paragraph')
      assert.equal(persona.includes('the tool return is just a receipt, not a new user message'), false,
        'en must not keep the round-2 receipt paragraph')
    }
  }
})

test('an explicit content-card request outranks the no-manufactured-card default', () => {
  for (const lang of ['zh', 'en'] as const) {
    const { persona } = assemblePrompt({ lang })
    if (lang === 'zh') {
      assert.ok(persona.includes('与任务长短无关'), 'zh must not qualify content cards by task length')
      assert.ok(persona.includes('最后一卡传 `final: true`'), 'zh must mark the last requested card as final')
      assert.equal(persona.includes('长工作进度'), false, 'zh must not call progress cards long-work only')
      assert.ok(persona.includes('一回合最多两张'), 'zh keeps the two-card cap')
      assert.ok(persona.includes('先把结论写进正文，再把卡放在回复最后'), 'zh keeps cards after the prose conclusion')
      assert.ok(persona.includes('**硬规则：回复里只要是在请用户做选择，就必须用卡片。**'), 'zh keeps the decision-card hard rule')
    } else {
      assert.ok(persona.includes('task length does not matter'), 'en must not qualify content cards by task length')
      assert.ok(persona.includes('pass `final:true` on the last card'), 'en must mark the last requested card as final')
      assert.equal(persona.includes('show_progress` for long work'), false, 'en must not call progress cards long-work only')
      assert.ok(persona.includes('At most two content cards per turn'), 'en keeps the two-card cap')
      assert.ok(persona.includes('put the conclusion in prose first, then the card at the end'), 'en keeps cards after the prose conclusion')
      assert.ok(persona.includes('**Hard rule: when your reply would ASK the user to choose, use the card.**'), 'en keeps the decision-card hard rule')
    }
  }
})
