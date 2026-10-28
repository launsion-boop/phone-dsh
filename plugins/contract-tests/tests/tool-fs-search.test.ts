// SPDX-License-Identifier: MIT
// tool-fs-search builds the ripgrep argv the Worker's rg implementation must
// match, and runRipgrep prepends --no-config so a host ripgrep config cannot
// inject a preprocessor.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { arrayPropertyElements, flagLiteralsInFunction, parseText } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'

test('tool fs search: rg argv carries the fixed flags and --no-config', (t) => {
  const grep = parseText(
    'grep.ts',
    readCheckoutFile('packages/fs/tool-fs-search/src/grep.ts'),
  )
  const glob = parseText(
    'glob.ts',
    readCheckoutFile('packages/fs/tool-fs-search/src/glob.ts'),
  )
  const searchCore = parseText(
    'search-core.ts',
    readCheckoutFile('packages/fs/tool-fs-search/src/search-core.ts'),
  )
  const grepFlags = flagLiteralsInFunction(grep, 'buildGrepCommand')
  const globFlags = flagLiteralsInFunction(glob, 'buildGlobCommand')
  const spawnArgv = arrayPropertyElements(searchCore, 'argv') ?? []
  observe(t, 'toolFsSearchRgArgv', { grepFlags, globFlags, spawnArgv })

  for (const flag of ['--json', '--regexp=', '--glob=', '--']) {
    assert.ok(grepFlags.includes(flag), `grep argv no longer carries ${flag}`)
  }
  for (const flag of ['--files', '--glob=', '--sort=modified', '--no-ignore', '--hidden']) {
    assert.ok(globFlags.includes(flag), `glob argv no longer carries ${flag}`)
  }
  assert.equal(spawnArgv[1], '--no-config', 'runRipgrep must prepend --no-config after the binary')
  assert.ok(spawnArgv.some(token => token.startsWith('...') && token.includes('argv')), 'the built rg argv must still be spread after --no-config')
  assert.match(spawnArgv[0] ?? '', /resolveRgPath/)
})
