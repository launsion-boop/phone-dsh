// SPDX-License-Identifier: MIT
// packVfsImage's PackOptions keys are how the phone image packer supplies the
// profile, roster, overlay directories, installation and HOME patch.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { exportedNames, findFunction, interfaceMembers, parseText } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'

/** PackOptions keys the phone image build passes. */
const REQUIRED_KEYS = [
  'profile',
  'roster',
  'installation',
  'workspaces',
  'resolveFrom',
  'homePatch',
  'entries',
] as const

test('packer: packVfsImage PackOptions keys match the phone image build', (t) => {
  const packSource = parseText(
    'pack.ts',
    readCheckoutFile('packages/experimental/webworker-packer/src/pack.ts'),
  )
  const members = interfaceMembers(packSource, 'PackOptions')
  observe(t, 'packVfsImagePackOptions', members)
  const names = members.map(member => member.name)
  for (const key of REQUIRED_KEYS) {
    assert.ok(names.includes(key), `PackOptions no longer carries the ${key} key`)
  }

  const factory = findFunction(packSource, 'packVfsImage')
  assert.notEqual(factory, undefined, 'packVfsImage must stay a function declaration')
  const parameterType = factory?.parameters[0]?.type?.getText(packSource) ?? ''
  observe(t, 'packVfsImageParameter', parameterType)
  assert.equal(parameterType, 'PackOptions', 'packVfsImage must keep taking PackOptions')

  const exports = exportedNames(parseText(
    'index.ts',
    readCheckoutFile('packages/experimental/webworker-packer/src/index.ts'),
  ))
  observe(t, 'packerIndexExports', exports)
  for (const name of ['packVfsImage', 'PackOptions']) {
    assert.ok(exports.includes(name), `the packer index no longer exports ${name}`)
  }
})
