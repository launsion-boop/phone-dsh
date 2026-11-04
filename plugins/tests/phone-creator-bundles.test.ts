// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { Context } from '@deepseek-ai/cordis'
import { LocalPresetBundles } from '../phone-feature-admin/src/creator-bundles.ts'

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'phone-creator-'))
  const workspace = join(root, 'workspace')
  const profile = join(root, 'profile')
  const home = join(root, 'home')
  for (const directory of [workspace, profile, home]) mkdirSync(directory)
  const profileText = JSON.stringify({name: 'fixture-profile', dsh: {profile: {bundles: []}}})
  writeFileSync(join(profile, 'package.json'), profileText)
  writeFileSync(join(home, 'cordis.patch.yml'), '- insert:\n    - id: preset-fixture\n      name: "@deepseek-ai/dsh-agent-preset"\n      config:\n        id: fixture\n        plugins:\n          - id: persona\n            name: "@deepseek-ai/dsh-persona"\n')
  // Validation stops before any service call: filesystem and DSH's real profile
  // parser are exercised; no Loader outcome is substituted by this context.
  const context = {profileContext: {name: 'web', cwd: workspace, dir: profile, home,
    patchPath: join(profile, 'cordis.patch.yml'), installAnchor: join(profile, 'package.json'),
    overlays: [], startedBundles: []}} as unknown as Context
  const source = join(workspace, 'bundle')
  mkdirSync(source)
  writeFileSync(join(source, 'package.json'), JSON.stringify({name: '@local/review', version: '1.0.0', dsh: {bundle: {patch: './cordis.patch.yml'}}}))
  writeFileSync(join(source, 'cordis.patch.yml'), '- insert:\n    - id: preset-review\n      name: "@deepseek-ai/dsh-agent-preset"\n      config:\n        id: review\n        plugins:\n          - id: persona\n            name: "@deepseek-ai/dsh-persona"\n')
  return {root, workspace, profile, profileText, source, manager: new LocalPresetBundles(context), signal: new AbortController().signal}
}

test('local preset installation refuses a source symlink outside the workspace', async () => {
  const f = fixture()
  try {
    const outside = join(f.root, 'outside')
    mkdirSync(outside)
    symlinkSync(outside, join(f.workspace, 'escape'))
    const result = await f.manager.install(join(f.workspace, 'escape'), true, f.signal, () => {})
    assert.equal(result.application, 'failed')
    assert.match(result.error?.diagnostic ?? '', /inside the phone workspace/)
    assert.equal(readFileSync(join(f.profile, 'package.json'), 'utf8'), f.profileText)
  } finally { rmSync(f.root, {recursive: true, force: true}) }
})

test('local preset installation never follows a destination parent symlink', async () => {
  const f = fixture()
  try {
    const outside = join(f.root, 'outside')
    mkdirSync(outside)
    symlinkSync(outside, join(f.profile, 'node_modules'))
    await assert.rejects(f.manager.install(f.source, true, f.signal, () => {}), /symlinks/)
    assert.equal(readFileSync(join(f.profile, 'package.json'), 'utf8'), f.profileText)
  } finally { rmSync(f.root, {recursive: true, force: true}) }
})

test('lifecycle scripts and unavailable scoped modules are rejected before publication', async () => {
  const f = fixture()
  try {
    const file = join(f.source, 'package.json')
    const manifest = JSON.parse(readFileSync(file, 'utf8'))
    writeFileSync(file, JSON.stringify({...manifest, scripts: {install: 'touch should-not-run'}}))
    await assert.rejects(f.manager.install(f.source, true, f.signal, () => {}), /lifecycle scripts/)
    writeFileSync(file, JSON.stringify(manifest))
    writeFileSync(join(f.source, 'cordis.patch.yml'), '- insert:\n    - id: preset-review\n      name: "@deepseek-ai/dsh-agent-preset"\n      config:\n        id: review\n        plugins:\n          - id: missing\n            name: "@local/missing-module"\n')
    await assert.rejects(f.manager.install(f.source, true, f.signal, () => {}), /not in this Worker's shipped preset catalog/)
    assert.equal(readFileSync(join(f.profile, 'package.json'), 'utf8'), f.profileText)
  } finally { rmSync(f.root, {recursive: true, force: true}) }
})

test('expressions cannot turn a declarative preset into arbitrary Host code', async () => {
  const f = fixture()
  try {
    writeFileSync(join(f.source, 'cordis.patch.yml'), '- insert:\n    - id: preset-review\n      name: "@deepseek-ai/dsh-agent-preset"\n      config:\n        id: review\n        plugins:\n          - id: persona\n            name: "@deepseek-ai/dsh-persona"\n            config:\n              prefix: !!js "process.env.PRIVATE_VALUE"\n')
    await assert.rejects(f.manager.install(f.source, true, f.signal, () => {}), /!!js/)
    assert.equal(readFileSync(join(f.profile, 'package.json'), 'utf8'), f.profileText)
  } finally { rmSync(f.root, {recursive: true, force: true}) }
})

test('malformed dependency fields cannot bypass the offline bundle policy', async () => {
  const f = fixture()
  try {
    const file = join(f.source, 'package.json')
    const manifest = JSON.parse(readFileSync(file, 'utf8'))
    for (const dependencies of ['@local/not-installed', ['@local/not-installed'], null]) {
      writeFileSync(file, JSON.stringify({...manifest, dependencies}))
      await assert.rejects(f.manager.install(f.source, true, f.signal, () => {}), /cannot install dependencies/)
    }
    assert.equal(readFileSync(join(f.profile, 'package.json'), 'utf8'), f.profileText)
  } finally { rmSync(f.root, {recursive: true, force: true}) }
})
