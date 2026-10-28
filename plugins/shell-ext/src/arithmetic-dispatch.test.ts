// SPDX-License-Identifier: MIT
// G2-FIX-66: arithmetic `base#value` literals and nounset fatality.
//
// The Worker shell is an assembly (just-bash engine + the transform plugin and
// command table at our layer). G2-A06 exposed that the assembly splits the
// arithmetic semantics by dispatch path: `bash -c` ran the composed shell, but
// a script launched by path (`./script.sh`) reached the engine's bare
// arithmetic evaluator, where `10#1` parses as the literal NaN base token
// concatenated with the expanded digits and is then resolved as a *variable*
// named `NaN1`. `(( 10#$n >= 5 ))` therefore reported `NaN5: unbound variable`,
// and because an arithmetic-command error is a normal command failure in the
// engine, `set -euo pipefail` did not abort: the comparison silently evaluated
// false and the dependent `rm` was skipped. GNU bash evaluates the base prefix
// in one path for every dispatch and aborts the script on an unbound
// arithmetic operand under `set -u`.
//
// These tests are component level: they drive `WorkerShell` (the same core
// `subprocess-xl` uses for both `bash -c` and direct spawns) through the three
// script dispatch paths and compare every value with the GNU bash 3.2 gold
// (`bash -c` on this build host); the engine's own error behaviour for
// non-nounset arithmetic failures is pinned too so the shim cannot over-abort.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { InMemoryFs } from 'just-bash/browser'
import { WorkerShell } from './index.ts'

const CWD = '/dsh/workspace'
const SCRIPT = '/dsh/workspace/script.sh'

/** The three ways a DSH exec step can hand a script to the Worker shell. */
const DISPATCHES = [
  { name: 'bash -c', argv: (source: string) => ['bash', '-c', source] },
  { name: 'bash script.sh', argv: () => ['bash', 'script.sh'] },
  { name: './script.sh', argv: () => ['./script.sh'] },
] as const

interface ShellOutcome {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
}

/** Run one script through one dispatch path on a fresh VFS. */
async function runDispatch(
  dispatch: (typeof DISPATCHES)[number],
  source: string,
  options: { readonly executable?: boolean } = {},
): Promise<ShellOutcome> {
  const fs = new InMemoryFs({ '/dsh/workspace/.keep': '' })
  await fs.writeFile(SCRIPT, `#!/bin/bash\n${source}`)
  if (options.executable !== false) await fs.chmod(SCRIPT, 0o755)
  const shell = new WorkerShell({ fs })
  const result = await shell.run(dispatch.argv(source), { cwd: CWD })
  return { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode }
}

/** One GNU bash gold row: the source and its exact stdout/exit status. */
interface GoldenCase {
  readonly name: string
  readonly source: string
  readonly stdout: string
  readonly exitCode: number
}

/** Values produced by GNU bash (3.2.57) for the same source. */
const GOLDEN: readonly GoldenCase[] = [
  { name: '10#1', source: 'echo $((10#1))', stdout: '1\n', exitCode: 0 },
  { name: '10#08', source: 'echo $((10#08))', stdout: '8\n', exitCode: 0 },
  { name: '16#FF', source: 'echo $((16#FF))', stdout: '255\n', exitCode: 0 },
  { name: '2#101', source: 'echo $((2#101))', stdout: '5\n', exitCode: 0 },
  { name: '8#17', source: 'echo $((8#17))', stdout: '15\n', exitCode: 0 },
  {
    // bases 2..64: lower/upper digit split above 36, `@`=62, `_`=63.
    name: 'bases 2..64',
    source: 'echo $((3#12)) $((4#33)) $((5#44)) $((7#66)) $((12#AB)) $((36#Z)) $((37#10)) $((62#Z)) $((64#@)) $((64#_)) $((16#ff))',
    stdout: '5 15 24 48 131 35 37 61 62 63 255\n',
    exitCode: 0,
  },
  { name: 'compare n=1', source: 'n=1; (( 10#$n >= 5 )); echo status=$?', stdout: 'status=1\n', exitCode: 0 },
  { name: 'compare n=5', source: 'n=5; (( 10#$n >= 5 )); echo status=$?', stdout: 'status=0\n', exitCode: 0 },
  { name: 'compare n=6', source: 'n=6; (( 10#$n >= 5 )); echo status=$?', stdout: 'status=0\n', exitCode: 0 },
  { name: 'base digits from a braced operand', source: 'n=08; echo $((10#${n}))', stdout: '8\n', exitCode: 0 },
  {
    name: 'a base prefix inside a compound test',
    source: 'suffix=6; max=5; if [[ "$suffix" =~ ^[0-9]+$ ]] && (( 10#$suffix >= max )); then echo removed; else echo kept; fi',
    stdout: 'removed\n',
    exitCode: 0,
  },
  {
    // The nounset check runs before the arithmetic command; `$?` must still be
    // the status of the command before the whole construct.
    name: '$? is captured before the nounset prelude',
    source: 'false; x=1; (( $? == 0 && x )); echo status=$?',
    stdout: 'status=0\n',
    exitCode: 0,
  },
]

for (const dispatch of DISPATCHES) {
  test(`arithmetic base literals match GNU bash through ${dispatch.name}`, async () => {
    for (const row of GOLDEN) {
      const result = await runDispatch(dispatch, row.source)
      assert.equal(result.stdout, row.stdout, `${row.name}: stdout`)
      assert.equal(result.stderr, '', `${row.name}: stderr`)
      assert.equal(result.exitCode, row.exitCode, `${row.name}: exit`)
    }
  })
}

test('arithmetic base literals: the G2-A06 rotation shape is identical through every dispatch', async () => {
  // The reported script: `${old##*.}` feeds a base-prefixed comparison inside a
  // `set -euo pipefail` compound test. Every path must remove the old archive
  // and must not surface the engine's `NaN<n>: unbound variable`.
  const source = [
    'set -euo pipefail',
    'old=app.log.6',
    'suffix="${old##*.}"',
    'MAX_BACKUPS=5',
    'if [[ "$suffix" =~ ^[0-9]+$ ]] && (( 10#$suffix >= MAX_BACKUPS )); then',
    '  echo "rm $old"',
    'else',
    '  echo "keep $old"',
    'fi',
    'echo done',
  ].join('\n')
  const outcomes: Record<string, ShellOutcome> = {}
  for (const dispatch of DISPATCHES) {
    const result = await runDispatch(dispatch, source)
    outcomes[dispatch.name] = result
    assert.equal(result.stdout, 'rm app.log.6\ndone\n', `${dispatch.name}: stdout`)
    assert.equal(result.exitCode, 0, `${dispatch.name}: exit`)
    assert.doesNotMatch(result.stderr, /NaN\d+/u, `${dispatch.name}: no NaN pseudo-variable`)
    assert.doesNotMatch(result.stderr, /unbound variable/u, `${dispatch.name}: no unbound variable`)
  }
  assert.deepEqual(outcomes['./script.sh'], outcomes['bash -c'])
  assert.deepEqual(outcomes['bash script.sh'], outcomes['bash -c'])
})

for (const dispatch of DISPATCHES) {
  test(`set -u: an unbound arithmetic operand aborts through ${dispatch.name}`, async () => {
    const topLevel = await runDispatch(dispatch, 'set -u\n(( missing >= 5 ))\necho continued\necho still-here\n')
    assert.notEqual(topLevel.exitCode, 0, 'top-level arithmetic error is fatal')
    assert.equal(topLevel.stdout, '', 'no command after the failed arithmetic runs')
    assert.match(topLevel.stderr, /missing: unbound variable/u)

    const conditional = await runDispatch(
      dispatch,
      'set -euo pipefail\nif (( missing >= 5 )); then\n  echo big\nfi\necho continued\n',
    )
    assert.notEqual(conditional.exitCode, 0, 'conditional arithmetic error is fatal')
    assert.equal(conditional.stdout, '', 'the rest of the script does not run')
    assert.match(conditional.stderr, /missing: unbound variable/u)

    const defined = await runDispatch(dispatch, 'set -u\nn=6\n(( 10#$n >= 5 ))\necho continued\n')
    assert.equal(defined.stdout, 'continued\n', 'a defined operand still evaluates')
    assert.equal(defined.stderr, '', 'no diagnostic for a defined operand')
    assert.equal(defined.exitCode, 0)

    // A `$(( ))` operand is the same class: the engine downgrades an unset
    // expansion to a command failure in a nested body, bash aborts.
    const word = await runDispatch(
      dispatch,
      'set -u\nif true; then\n  echo $((missing))\nfi\necho continued\n',
    )
    assert.notEqual(word.exitCode, 0, 'unset word-arithmetic operand is fatal')
    assert.equal(word.stdout, '', 'no command after the failed expansion runs')
    assert.match(word.stderr, /missing: unbound variable/u)

    // The same fatality covers a braced operand inside the arithmetic command
    // (the adjacent G2-FIX-26 operand class), not only a bare name.
    const braced = await runDispatch(
      dispatch,
      'set -u\nif (( 10#${missing#0} >= 5 )); then\n  echo big\nfi\necho continued\n',
    )
    assert.notEqual(braced.exitCode, 0, 'unset braced arithmetic operand is fatal')
    assert.equal(braced.stdout, '', 'the rest of the script does not run')
    assert.match(braced.stderr, /missing: unbound variable/u)
  })

  test(`set +u: an unset arithmetic operand stays zero through ${dispatch.name}`, async () => {
    const result = await runDispatch(dispatch, '(( missing >= 5 ))\necho after status=$?\n')
    assert.equal(result.stdout, 'after status=1\n')
    assert.equal(result.stderr, '')
    assert.equal(result.exitCode, 0)
  })

  test(`non-nounset arithmetic failures stay non-fatal through ${dispatch.name}`, async () => {
    // GNU bash reports division by zero as a normal `(( ))` failure and keeps
    // going; the nounset shim must not turn it into a script abort.
    const result = await runDispatch(dispatch, 'set -u\n(( 1/0 ))\necho after\n')
    assert.equal(result.stdout, 'after\n')
    assert.equal(result.exitCode, 0)
  })
}

test('./script.sh respects the execute bit like bash', async () => {
  const denied = await runDispatch(DISPATCHES[2], 'echo hi\n', { executable: false })
  assert.equal(denied.stdout, '')
  assert.equal(denied.exitCode, 126)
  assert.match(denied.stderr, /Permission denied/u)

  const viaBash = await runDispatch(DISPATCHES[1], 'echo hi\n', { executable: false })
  assert.equal(viaBash.stdout, 'hi\n')
  assert.equal(viaBash.exitCode, 0)
})
