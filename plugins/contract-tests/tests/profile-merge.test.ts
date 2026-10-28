// SPDX-License-Identifier: MIT
// The profile the Worker boots: app-boot merges bundle patches, the profile's
// own patch file, the image's HOME patch and launcher overlays, and the Worker
// host hands that list to boot() as its boot patches.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'

import { callCalleeTexts, findFunction, findVariableInitializer, parseText, resolveTemplate } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'

const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

test('profile: readProfilePatches merges bundles, profile, HOME patch then overlays', async (t) => {
  const probe = await loadProbe()
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-contract-profile-'))
  scratch.push(directory)
  const home = join(directory, 'home')
  const profileDir = join(directory, 'profile')
  mkdirSync(home)
  mkdirSync(profileDir)
  writeFileSync(join(home, probe.PROFILE_PATCH_FILENAME), '- id: from-home\n')
  const context = {
    name: 'phone',
    dir: profileDir,
    patchPath: join(profileDir, probe.PROFILE_PATCH_FILENAME),
    installAnchor: join(directory, 'node_modules'),
    cwd: directory,
    home,
    startedBundles: ['bundle-a'],
    overlays: [{ id: 'from-overlay' }],
  }
  const initialProfile = {
    name: 'phone',
    dir: profileDir,
    patchPath: context.patchPath,
    layers: [{ packageName: 'bundle-a', packageDir: directory, patchPaths: [], patches: [{ id: 'from-bundle' }] }],
    patches: [{ id: 'from-profile' }],
    skippedBundles: [],
  }
  const merged = probe.readProfilePatches('phone', context, initialProfile)
  const ids = merged.map(row => row.id)
  observe(t, 'readProfilePatchesOrder', {
    patchFilename: probe.PROFILE_PATCH_FILENAME,
    ids,
    home: 'home/cordis.patch.yml',
  })
  assert.deepEqual(ids, ['from-bundle', 'from-profile', 'from-home', 'from-overlay'])
  assert.equal(probe.PROFILE_PATCH_FILENAME, 'cordis.patch.yml')
})

test('profile: prepareProfile returns bootPatches and writes the HOME patch path', async (t) => {
  const probe = await loadProbe()
  const workerHost = parseText(
    'worker-host.ts',
    readCheckoutFile('packages/experimental/webworker-runtime/src/worker-host.ts'),
  )
  const prepareProfile = findFunction(workerHost, 'prepareProfile')
  assert.notEqual(prepareProfile, undefined, 'worker-host.ts must keep prepareProfile')
  assert.notEqual(prepareProfile?.body, undefined, 'prepareProfile must keep a body')
  const calls = prepareProfile === undefined ? [] : callCalleeTexts(prepareProfile, workerHost)
  const homeInitializer = prepareProfile === undefined ? undefined : findVariableInitializer(prepareProfile, 'home')
  const homeText = homeInitializer?.getText(workerHost) ?? ''
  observe(t, 'prepareProfile', {
    calls: calls.filter(name => /loadLayeredEnv|loadProfile|reportSkippedBundles|writeFileSync|readProfilePatches/.test(name)),
    home: homeText,
  })
  const relevant = ['appBoot.loadLayeredEnv', 'appBoot.loadProfile', 'appBoot.reportSkippedBundles', 'appBoot.readProfilePatches']
  const indexes = relevant.map(name => calls.indexOf(name))
  for (const [index, name] of relevant.entries()) {
    assert.notEqual(indexes[index], -1, `prepareProfile no longer calls ${name}`)
  }
  assert.deepEqual([...indexes].sort((left, right) => left - right), indexes, 'prepareProfile must keep its boot order')
  assert.equal(homeText.replace(/\s+/g, ''), 'join(root,IMAGE_HOME_DIRECTORY)')

  const writeIndex = calls.indexOf('vfs.writeFileSync')
  const readIndex = calls.indexOf('appBoot.readProfilePatches')
  assert.notEqual(writeIndex, -1, 'prepareProfile must still write the composed cordis.yml')
  assert.ok(writeIndex < readIndex, 'prepareProfile writes cordis.yml before reading the boot patches')

  const appBoot = parseText('app-boot.ts', readCheckoutFile('packages/boot/app-boot/src/index.ts'))
  const boot = findFunction(appBoot, 'boot')
  const bootParameter = boot?.parameters[2]
  const bootSignature = {
    name: bootParameter?.name.getText(appBoot) ?? '',
    type: bootParameter?.type?.getText(appBoot) ?? '',
    optional: bootParameter?.questionToken !== undefined,
  }
  observe(t, 'bootPatchesParameter', bootSignature)
  assert.equal(bootSignature.name, 'patches', 'boot() must keep taking patches as its third argument')
  assert.equal(bootSignature.type, 'PatchOptions[]')

  const packer = parseText(
    'pack.ts',
    readCheckoutFile('packages/experimental/webworker-packer/src/pack.ts'),
  )
  const homePatchPath = findVariableInitializer(packer, 'HOME_PATCH_PATH')
  assert.notEqual(homePatchPath, undefined, 'the packer must keep the HOME_PATCH_PATH constant')
  const resolved = homePatchPath === undefined
    ? undefined
    : resolveTemplate(homePatchPath, new Map([
      ['IMAGE_HOME_DIRECTORY', probe.IMAGE_HOME_DIRECTORY],
      ['PROFILE_PATCH_FILENAME', probe.PROFILE_PATCH_FILENAME],
    ]))
  observe(t, 'homePatchPath', { raw: homePatchPath?.getText(packer) ?? '', resolved: resolved ?? null })
  assert.equal(resolved, 'home/cordis.patch.yml', 'the image HOME patch must stay at home/cordis.patch.yml')
})
