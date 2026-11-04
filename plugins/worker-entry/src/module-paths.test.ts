// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { test } from 'node:test'
import { metadataSearchPaths } from './module-paths.ts'

test('profile-local metadata follows the Node ancestor search before global paths', () => {
  const actual = metadataSearchPaths('/dsh/home/profiles/web')
  const native = createRequire('/dsh/home/profiles/web/package.json').resolve.paths('@local/example')!
  assert.deepEqual(actual, native.slice(0, actual.length))
  assert.equal(actual[0], '/dsh/home/profiles/web/node_modules')
  assert.ok(actual.includes('/dsh/node_modules'))
})

test('nested packages do not introduce node_modules/node_modules', () => {
  const actual = metadataSearchPaths('/dsh/node_modules/@local/example')
  const native = createRequire('/dsh/node_modules/@local/example/package.json').resolve.paths('example')!
  assert.deepEqual(actual, native.slice(0, actual.length))
  assert.ok(actual.every(path => !path.includes('/node_modules/node_modules')))
  assert.throws(() => metadataSearchPaths('relative/profile'), /absolute/)
})
