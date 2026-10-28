// SPDX-License-Identifier: MIT
// G2-FIX-26: just-bash 3.6.0 evaluates `$(( ))` from a parser-time AST whose
// ArithBracedExpansion node only knows a variable name. `${x#0}` and
// `${x:0:2}` therefore reach the nounset check as the literal names `x#0` and
// `x:0:2`, and a plain `${x}` after a `10#` base prefix concatenates through
// the NaN base token. The Worker shell composes the engine with a transform
// plugin that expands these operands with the shell's own parameter expansion
// before numeric evaluation, so the whole class matches bash. These tests drive
// the Worker shell (`bash -c`), not the engine directly.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Bash, InMemoryFs } from 'just-bash/browser'
import { WorkerShell, disciplineEnvironment } from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'

/** A fresh in-memory VFS with the Worker's three roots. */
function memoryFs(): InMemoryFs {
  return new InMemoryFs({
    '/dsh/workspace/.keep': '',
    '/dsh/home/.keep': '',
    '/dsh/tmp/.keep': '',
  })
}

/** A Worker shell over an in-memory VFS. */
function workerShell(): WorkerShell {
  return new WorkerShell({ fs: memoryFs() })
}

/** Run one script through the Worker shell and return its result. */
async function runScript(script: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const result = await workerShell().run(['bash', '-c', script], { cwd: CWD })
  return { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode }
}

test('arithmetic expansion: ${x#0} inside 10# expands before numeric evaluation', async () => {
  const result = await runScript('x=02; echo $((10#${x#0}))')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '2\n')
})

test('arithmetic expansion: ${clock:0:2} inside 10# expands to the substring', async () => {
  const result = await runScript('clock=101530; echo $((10#${clock:0:2}))')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '10\n')
})

test('arithmetic expansion: (( 10#${clock:0:2} <= 23 )) evaluates the comparison', async () => {
  const result = await runScript('clock=101530; (( 10#${clock:0:2} <= 23 )); echo $?')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '0\n')
})

test('arithmetic expansion: the plain $x form keeps working', async () => {
  const result = await runScript('x=02; echo $((10#$x))')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '2\n')
})

test('arithmetic expansion: a plain ${x} after a base prefix also works', async () => {
  const result = await runScript('x=02; echo $((10#${x}))')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '2\n')
})

test('arithmetic expansion: the class covers prefix/suffix removal, substring and non-decimal bases', async () => {
  const prefix = await runScript('x=002; echo $((10#${x#0}))')
  assert.equal(prefix.stderr, '')
  assert.equal(prefix.stdout, '2\n')

  const suffix = await runScript('x=1230; echo $((10#${x%0}))')
  assert.equal(suffix.stderr, '')
  assert.equal(suffix.stdout, '123\n')

  const offsetOnly = await runScript('clock=101530; echo $((10#${clock:2}))')
  assert.equal(offsetOnly.stderr, '')
  assert.equal(offsetOnly.stdout, '1530\n')

  const hex = await runScript('x=ff; echo $((16#${x}))')
  assert.equal(hex.stderr, '')
  assert.equal(hex.stdout, '255\n')

  const dynamicBase = await runScript('base=2; bits=1010; echo $(( ${base}#${bits} ))')
  assert.equal(dynamicBase.stderr, '')
  assert.equal(dynamicBase.stdout, '10\n')
})

test('arithmetic expansion: assignments and side effects stay in the current shell', async () => {
  const result = await runScript('x=1; (( x++ + ${x#1} )); echo "x=$x"')
  assert.equal(result.stderr, '')
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'x=2\n')

  const status = await runScript('x=02; false; echo $((10#${x#0} + $?))')
  assert.equal(status.stderr, '')
  assert.equal(status.stdout, '3\n')

  // The shim's prelude uses `builtin eval`, so a script function named `eval`
  // cannot capture the expansion.
  const shadowed = await runScript('x=02; eval() { echo broken; }; echo $((10#${x#0}))')
  assert.equal(shadowed.stderr, '')
  assert.equal(shadowed.stdout, '2\n')
})

test('arithmetic expansion: nested command substitution, loops and functions are covered', async () => {
  const nested = await runScript('x=12; echo "$(echo $(( ${x:0:1} + 1 )))"')
  assert.equal(nested.stderr, '')
  assert.equal(nested.stdout, '2\n')

  const loop = await runScript('x=02; for i in 1 2; do (( 10#${x#0} + i > 2 )) && echo "loop$i"; done')
  assert.equal(loop.stderr, '')
  assert.equal(loop.stdout, 'loop1\nloop2\n')

  const fn = await runScript('f() { x=02; echo $((10#${x#0})); }; f')
  assert.equal(fn.stderr, '')
  assert.equal(fn.stdout, '2\n')
})

test('arithmetic expansion: set -u still reports a genuinely unset variable', async () => {
  const ok = await runScript('x=02; set -u; echo $((10#${x#0}))')
  assert.equal(ok.stderr, '')
  assert.equal(ok.stdout, '2\n')

  const missing = await runScript('set -u; echo $((10#${missing#0}))')
  assert.equal(missing.exitCode, 1)
  // The operand now goes through normal parameter expansion, so the unset
  // name is `missing` (not the engine's concatenated `missing#0`).
  assert.match(missing.stderr, /missing: unbound variable/u)
})

test('arithmetic expansion: arithmetic without parameter expansions is unchanged', async () => {
  const result = await runScript('echo $((1 + 2 * 3))')
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, '7\n')
})

test('arithmetic expansion baseline: the unshimmed 3.6.0 engine reports x#0 as a variable', async () => {
  const bash = new Bash({ fs: memoryFs(), cwd: CWD, env: disciplineEnvironment({}, CWD) })
  const result = await bash.exec('set -u; x=02; echo $((10#${x#0}))', { cwd: CWD })
  assert.equal(result.exitCode, 1)
  assert.match(result.stderr, /x#0: unbound variable/u)
})
