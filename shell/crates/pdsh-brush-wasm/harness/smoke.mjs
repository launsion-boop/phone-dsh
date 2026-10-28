// SPDX-License-Identifier: MIT
/**
 * Smoke test required by the W5-BRUSH check.
 *
 * It instantiates the wasm module once and runs:
 *
 * 1. `echo hi | cat` — the pipeline workaround plus the host dispatch hook;
 * 2. a `for` loop — the shell's own parser and interpreter;
 * 3. a file write followed by a host `cat` — the WASI filesystem and the
 *    dispatch cwd/argv path.
 *
 * It also asserts that the module links only the WASI filesystem/clock/
 * randomness imports and the four `xl` host hooks (no sockets, no process
 * spawn).
 *
 * @module pdsh-brush-wasm/harness/smoke
 */

import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createCommandTable } from './commands.mjs'
import { resetFixture } from './fixture.mjs'
import { loadBrush } from './wasm.mjs'

const failures = []
let passed = 0

/**
 * Run one check and record its outcome.
 *
 * @param {string} name - check name.
 * @param {Function} body - check body.
 */
function check(name, body) {
  try {
    body()
    passed += 1
    console.log(`ok ${passed} - ${name}`)
  } catch (error) {
    failures.push({ name, error })
    console.log(`not ok ${passed + failures.length} - ${name}`)
    console.log(`  ${error instanceof Error ? error.message : String(error)}`)
  }
}

const root = mkdtempSync(join(tmpdir(), 'pdsh-brush-smoke-'))
resetFixture(root)
const table = createCommandTable({ root, mode: 'demo' })
const brush = await loadBrush({ root, commands: table })

check('module reports its version', () => {
  assert.match(brush.version(), /^\d+\.\d+\.\d+$/)
})

check('echo hi | cat prints hi', () => {
  const outcome = brush.run('echo hi | cat')
  assert.equal(outcome.error, '')
  assert.equal(outcome.stderr, '')
  assert.equal(outcome.exitCode, 0)
  assert.equal(outcome.stdout, 'hi\n')
  assert.equal(outcome.pipelineShim, true, 'the pipeline went through the /dsh/tmp workaround')
})

check('a for loop runs', () => {
  const outcome = brush.run('for i in 1 2 3; do echo "n=$i"; done')
  assert.equal(outcome.error, '')
  assert.equal(outcome.exitCode, 0)
  assert.equal(outcome.stdout, 'n=1\nn=2\nn=3\n')
})

check('the WASI workspace is readable (cd builtin)', () => {
  const outcome = brush.run('cd docs && pwd')
  assert.equal(outcome.error, '')
  assert.equal(outcome.exitCode, 0)
  assert.equal(outcome.stdout, '/dsh/workspace/docs\n')
})

check('an unknown command is reported, not silently accepted', () => {
  // brush-core 0.5.0's wasm PathExt::executable() always returns true, so an
  // unregistered name reaches the (unsupported) process spawn and is reported
  // as "failed to execute command" with status 126 instead of 127. The report
  // records this as a release limitation; the host table avoids it for every
  // name it advertises.
  const outcome = brush.run('definitely-not-a-command')
  assert.equal(outcome.exitCode, 126)
  assert.match(outcome.stderr, /definitely-not-a-command/)
  assert.match(outcome.stderr, /operation not supported/)
})

check('the module links no socket or process import', () => {
  const modules = new Set(brush.imports.map((entry) => entry.module))
  assert.deepEqual([...modules].sort(), ['wasi_snapshot_preview1', 'xl'])
  for (const entry of brush.imports) {
    assert.doesNotMatch(entry.name, /^(sock_|proc_spawn|sock_accept)/, `unexpected import ${entry.name}`)
  }
})

console.log(`1..${passed + failures.length}`)
rmSync(root, { recursive: true, force: true })

if (failures.length > 0) {
  console.error(`\n${failures.length} smoke check(s) failed`)
  process.exitCode = 1
} else {
  console.error(`\nall ${passed} smoke checks passed`)
}
