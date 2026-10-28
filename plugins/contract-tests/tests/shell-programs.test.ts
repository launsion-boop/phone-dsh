// SPDX-License-Identifier: MIT
// The runtime's command table is the Worker's /bin. A shrinking table removes
// commands the phone shell relies on, so the contract pins the command set.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'

/** Programs the baseline DSH shell provides and the phone host relies on. */
const REQUIRED_PROGRAMS = [
  ':',
  '[',
  'basename',
  'cat',
  'cd',
  'cp',
  'cut',
  'date',
  'dirname',
  'echo',
  'env',
  'exit',
  'export',
  'false',
  'find',
  'grep',
  'head',
  'ln',
  'ls',
  'mkdir',
  'mv',
  'printenv',
  'printf',
  'pwd',
  'readlink',
  'rm',
  'rmdir',
  'sed',
  'seq',
  'sleep',
  'sort',
  'stat',
  'tail',
  'tee',
  'test',
  'touch',
  'tr',
  'true',
  'uniq',
  'unset',
  'wc',
  'which',
] as const

test('shell programs: standard table carries the required command set', async (t) => {
  const probe = await loadProbe()
  const table = probe.standardPrograms()
  const programs = [...table.keys()].sort()
  observe(t, 'shellPrograms', programs)
  for (const name of REQUIRED_PROGRAMS) {
    assert.ok(programs.includes(name), `the shell command table no longer carries ${name}`)
  }
  for (const [name, program] of table) {
    assert.equal(typeof program, 'function', `command ${name} must stay a callable program`)
  }
})
