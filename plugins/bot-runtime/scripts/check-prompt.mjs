#!/usr/bin/env node
// SPDX-License-Identifier: MIT
import { assemblePrompt, PHONE_P0_TOOLS, PHONE_P1_TARGET_TOOLS, runtimePersonaBlock, variantBlock } from '../src/prompt/assemble.ts'

const reports = []
for (const lang of ['zh', 'en']) {
  for (const variant of [null, 'executor', 'wake-routine']) {
    const result = assemblePrompt({
      lang,
      variant,
      variantText: variant ? variantBlock(variant, lang) : undefined,
    })
    reports.push({ lang, variant: variant ?? 'none', ...result.mount })
  }
}
for (const lang of ['zh', 'en']) {
  const block = runtimePersonaBlock({ lang })
  if (!block.includes('大肥鱼')) throw new Error(`default runtime Bot name missing for ${lang}`)
  const custom = runtimePersonaBlock({ botName: 'Custom Fish', lang })
  if (!custom.includes('Custom Fish') || custom.includes('大肥鱼')) throw new Error(`runtime Bot name was not injected for ${lang}`)
}
const allTools = [...new Set(reports.flatMap(report => report.tools))]
const missing = PHONE_P0_TOOLS.filter(name => !allTools.includes(name))
if (missing.length) throw new Error(`P0 tools absent from persona declarations: ${missing.join(', ')}`)
for (const name of PHONE_P1_TARGET_TOOLS) {
  if (allTools.includes(name)) throw new Error(`P1 tool leaked into persona: ${name}`)
}
console.log(JSON.stringify({ ok: true, p0: PHONE_P0_TOOLS, p1: [], reports }, null, 2))
