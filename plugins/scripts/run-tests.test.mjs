// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import test from 'node:test'

import { excludeNodeModulesPaths } from './run-tests.mjs'

test('run-tests excludes every node_modules path component', () => {
  const paths = [
    'tests/first.test.ts',
    'node_modules/pkg/test.test.ts',
    'workspace/node_modules/pkg/test.test.ts',
    String.raw`workspace\node_modules\pkg\test.test.ts`,
    '/checkout/node_modules/pkg/test.test.ts',
    'tests/not_node_modules.test.ts',
  ]

  assert.deepEqual(excludeNodeModulesPaths(paths), [
    'tests/first.test.ts',
    'tests/not_node_modules.test.ts',
  ])
})
