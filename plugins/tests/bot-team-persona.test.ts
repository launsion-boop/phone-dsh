// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { assemblePrompt, PHONE_P0_TOOLS } from '../bot-runtime/src/prompt/assemble.ts'

test('both personas expose the team tools and describe the multi-Bot boundary', () => {
  assert.ok(PHONE_P0_TOOLS.includes('SendToAgent'))
  assert.ok(PHONE_P0_TOOLS.includes('CreateTeammate'))
  for (const lang of ['zh', 'en'] as const) {
    const result = assemblePrompt({ lang })
    assert.ok(result.mount.tools.includes('SendToAgent'), `SendToAgent missing from ${lang}`)
    assert.ok(result.mount.tools.includes('CreateTeammate'), `CreateTeammate missing from ${lang}`)
    assert.ok(result.persona.includes('SendToAgent'))
    assert.ok(result.persona.includes('CreateTeammate'))
    assert.ok(result.persona.includes('priority'))
    assert.ok(result.persona.includes('delivery'))
    assert.match(result.persona, /main Bot|主 Bot/)
    assert.match(result.persona, /Team sharing|Team 共享/)
    assert.match(result.persona, /<teammates>/)
    assert.match(result.persona, /agent-comm/)
    assert.match(result.persona, /permission error|权限错误/)
    assert.match(result.persona, /queued/)
    assert.match(result.persona, /now/)
    assert.doesNotMatch(result.persona, /no computer-use, cloud-agent, team, cross-machine/i)
    assert.doesNotMatch(result.persona, /没有电脑操作、云端代理、团队、跨机器/)
  }
})
