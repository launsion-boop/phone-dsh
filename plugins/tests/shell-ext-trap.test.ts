// SPDX-License-Identifier: MIT
// G2-FIX-107: `trap` must be a real builtin, not a `type` answer that lies.
//
// just-bash 3.6.0 lists `trap` as a shell builtin for `type`/`command -v`, but
// executing it fell through to the external-command path (`trap: command not
// found`, 127) and the EXIT action never ran. These tests drive the real
// WorkerShell and require the EXIT handler to execute, output to merge, the
// original status to survive and unsupported signals to fail loud (exit 2 with
// the `unsupported-option` trailer) instead of silently degrading.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

async function fixture(options: { productionCommands?: boolean } = {}): Promise<{ fs: VfsFileSystem; shell: WorkerShell }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-trap-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir(CWD, { recursive: true })
  const shell = options.productionCommands === true
    ? new WorkerShell({ fs, commands: createWorkerCommands({ curl: false, git: false, toolbox: false, gzip: false }) })
    : new WorkerShell({ fs })
  return { fs, shell }
}

test('type trap is a shell builtin and executing trap is not a 127 fallback', async () => {
  const { shell } = await fixture()
  const type = await shell.run(['bash', '-c', 'type trap'], { cwd: CWD })
  assert.equal(type.exitCode, 0)
  assert.equal(type.stdout, 'trap is a shell builtin\n')
  assert.equal(type.stderr, '')

  const result = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; echo hi'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'hi\nbye\n')
  assert.equal(result.stderr, '')
  assert.doesNotMatch(result.stderr, /command not found/u)
})

test('the EXIT handler runs for an explicit non-zero exit and the original status is kept', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; exit 3'], { cwd: CWD })
  assert.equal(result.exitCode, 3)
  assert.equal(result.stdout, 'bye\n')
  assert.equal(result.stderr, '')
})

test('trap -p, trap -l and trap - / empty handler', async () => {
  const { shell } = await fixture()
  const list = await shell.run(['bash', '-c', 'trap -l'], { cwd: CWD })
  assert.equal(list.exitCode, 0)
  assert.match(list.stdout, /EXIT/u)
  assert.equal(list.stderr, '')

  const print = await shell.run([
    'bash',
    '-c',
    'trap "echo bye" EXIT; trap -p EXIT; trap -p',
  ], { cwd: CWD })
  assert.equal(print.exitCode, 0)
  assert.equal(print.stdout, "trap -- 'echo bye' EXIT\ntrap -- 'echo bye' EXIT\nbye\n")
  assert.equal(print.stderr, '')

  const cleared = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; trap - EXIT; echo hi'], { cwd: CWD })
  assert.equal(cleared.exitCode, 0)
  assert.equal(cleared.stdout, 'hi\n')

  const emptied = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; trap "" EXIT; echo hi'], { cwd: CWD })
  assert.equal(emptied.exitCode, 0)
  assert.equal(emptied.stdout, 'hi\n')
})

test('an unsupported signal fails loud with exit 2 and the unsupported-option trailer', async () => {
  const { shell } = await fixture()
  for (const signal of ['TERM', 'INT', '15']) {
    const result = await shell.run(['bash', '-c', `trap "echo bye" ${signal}`], { cwd: CWD })
    assert.equal(result.exitCode, 2, signal)
    assert.match(result.stderr, /only EXIT/u, signal)
    assert.match(result.stderr, /reason=unsupported-option/u, signal)
    assert.doesNotMatch(result.stderr, /command not found/u, signal)
    assert.doesNotMatch(result.stderr, /: 127$/mu, signal)
  }
})

test('the handler runs in the same filesystem, cwd and environment as the script', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run([
    'bash',
    '-c',
    'X=visible; trap \'printf "handler-cwd=%s var=%s\\n" "$PWD" "$X"; echo persisted > trap.txt\' EXIT; echo hi',
  ], { cwd: CWD, env: { PDSH_TRAP_TEST: 'visible' } })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'hi\nhandler-cwd=/dsh/workspace var=visible\n')
  assert.equal(await fs.readFile(`${CWD}/trap.txt`), 'persisted\n')
})

test('the handler runs in the directory the script ended in', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    `trap 'echo cleanup > cleaned.txt; printf "handler-pwd=%s\\n" "$(pwd)"' EXIT; cd ${CWD}/other; echo main > main.txt`,
  ], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'handler-pwd=/dsh/workspace/other\n')
  assert.equal(result.stderr, '')
  assert.equal(await fs.readFile(`${CWD}/other/main.txt`), 'main\n')
  assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleanup\n')
  assert.equal(await fs.exists(`${CWD}/cleaned.txt`), false)
})

test('the handler starts with the script\'s final status in $?', async () => {
  const { shell } = await fixture()
  const failed = await shell.run(['bash', '-c', 'trap \'echo status=$?\' EXIT; false'], { cwd: CWD })
  assert.equal(failed.exitCode, 1)
  assert.equal(failed.stdout, 'status=1\n')
  assert.equal(failed.stderr, '')

  const explicit = await shell.run(['bash', '-c', 'trap \'echo status=$?\' EXIT; exit 3'], { cwd: CWD })
  assert.equal(explicit.exitCode, 3)
  assert.equal(explicit.stdout, 'status=3\n')
  assert.equal(explicit.stderr, '')

  const options = await shell.run(['bash', '-x', '-c', 'trap \'echo status=$?\' EXIT; echo main'], { cwd: CWD })
  assert.equal(options.exitCode, 0)
  assert.equal(options.stdout, 'main\nstatus=0\n')
  assert.match(options.stderr, /\+ echo status=0/mu)
})

test('set -e with pipefail runs EXIT with the failing pipeline status and side effects', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-status=%s pipe=%s pwd=%s x=%s\\n" "$?" "${PIPESTATUS[*]}" "$PWD" "$X"; '
      + 'echo cleaned > cleaned.txt\' EXIT; '
      + 'set -euo pipefail; X=1; false | true; echo unreachable',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, `handler-status=1 pipe=1 0 pwd=${CWD} x=1\n`)
  assert.equal(result.stderr, '')
  assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n')
})

test('a final conditional pipeline keeps its set-e exemption and can recover', async () => {
  const { fs, shell } = await fixture()
  const cases = [
    {
      label: 'final || recovery',
      script: 'set -e; X=1; false || echo recovered',
      expected: 'recovered\nH:0 pipe=0 x=1\n',
    },
    {
      label: 'final && after an earlier skipped &&',
      script: 'set -e; X=1; false && true; true && echo OK',
      expected: 'OK\nH:0 pipe=0 x=1\n',
    },
    {
      label: 'source before final ||',
      script: 'set -e; X=1; source /dev/null; false || echo recovered',
      expected: 'recovered\nH:0 pipe=0 x=1\n',
    },
    {
      label: 'eval before final ||',
      script: "set -e; X=1; eval ':'; false || echo recovered",
      expected: 'recovered\nH:0 pipe=0 x=1\n',
    },
  ] as const
  for (const { label, script, expected } of cases) {
    const result = await shell.run([
      'bash',
      '-c',
      'trap \'printf "H:%s pipe=%s x=%s\\n" "$?" "${PIPESTATUS[*]}" "$X"; '
        + 'echo cleaned > cleaned.txt\' EXIT; '
        + script,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${label}: ${result.stderr}`)
    assert.equal(result.stdout, expected, label)
    assert.equal(result.stderr, '', label)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', label)
    await fs.rm(`${CWD}/cleaned.txt`)
  }
})

test('a final conditional inside command substitution does not run the main checkpoint', async () => {
  const { shell } = await fixture()
  const assigned = await shell.run([
    'bash',
    '-c',
    'set -e; trap \'echo H:$?\' EXIT; x=$(false || echo recovered); echo x=$x',
  ], { cwd: CWD })
  assert.equal(assigned.exitCode, 0, assigned.stderr)
  assert.equal(assigned.stdout, 'x=recovered\nH:0\n')
  assert.equal(assigned.stderr, '')

  const substituted = await shell.run([
    'bash',
    '-c',
    'set -e; trap \'echo H:$?\' EXIT; echo "$(false && true; true && echo OK)"',
  ], { cwd: CWD })
  assert.equal(substituted.exitCode, 0, substituted.stderr)
  assert.equal(substituted.stdout, 'OK\nH:0\n')
  assert.equal(substituted.stderr, '')
})

test('a command-level assignment prefix is unwound before EXIT runs', async () => {
  const { fs, shell } = await fixture()
  const cases = [
    { command: 'X=5 echo ${MISSING?}', expected: 'X=before Y=\n' },
    // Earlier expansions in the same command still apply: Y=set survives the
    // fatal, while the X=5 command prefix does not leak into the shell.
    { command: 'X=5 : ${Y:=set} ${MISSING?}', expected: 'X=before Y=set\n' },
  ] as const
  for (const { command, expected } of cases) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "X=%s Y=%s\\n" "\${X-}" "\${Y-}"; echo cleaned > cleaned.txt' EXIT; X=before; ${command}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${command}: ${result.stderr}`)
    assert.equal(result.stdout, expected, command)
    assert.match(result.stderr, /parameter null or not set/u, command)
    assert.doesNotMatch(result.stderr, /reason=backend-failed/u, command)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', command)
    await fs.rm(`${CWD}/cleaned.txt`)
  }

  // Assignment-only commands are not a command-level prefix: bash applies
  // their assignments before a later word fails, so they remain visible.
  const assignmentOnly = await shell.run([
    'bash',
    '-c',
    'trap \'echo X=${X-} Y=${Y-}\' EXIT; X=before; X=5 Y=${MISSING?}',
  ], { cwd: CWD })
  assert.equal(assignmentOnly.exitCode, 1, assignmentOnly.stderr)
  assert.equal(assignmentOnly.stdout, 'X=5 Y=\n')
  assert.match(assignmentOnly.stderr, /parameter null or not set/u)
})

test('a fatal ${name?message} expansion runs EXIT from the live error-word state', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-status=%s pipe=%s pwd=%s x=%s y=%s\\n" '
      + '"$?" "${PIPESTATUS[*]}" "$PWD" "${X-}" "${y-}"; echo cleaned > cleaned.txt\' EXIT; '
      + 'set -u; X=1; : ${y:=set} ${MISSING?missing-for-test}',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, `handler-status=1 pipe=1 pwd=${CWD} x=1 y=set\n`)
  assert.equal(result.stderr, 'bash: missing-for-test\n')
  assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n')

  const defaultMessage = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-status=%s pwd=%s\\n" "$?" "$PWD"\' EXIT; '
      + 'set -u; echo ${MISSING?}',
  ], { cwd: CWD })
  assert.equal(defaultMessage.exitCode, 1, defaultMessage.stderr)
  assert.equal(defaultMessage.stdout, `handler-status=1 pwd=${CWD}\n`)
  assert.equal(defaultMessage.stderr, 'bash: MISSING: parameter null or not set\n')
})

test('a readonly assignment fatal runs EXIT in the final cwd and environment', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-status=%s pipe=%s pwd=%s x=%s\\n" '
      + '"$?" "${PIPESTATUS[*]}" "$PWD" "$X"; echo cleaned > cleaned.txt\' EXIT; '
      + `set -o posix; X=1; cd ${CWD}/other; readonly r=1; r=2`,
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, `handler-status=1 pipe=1 pwd=${CWD}/other x=1\n`)
  assert.equal(result.stderr, 'bash: r: readonly variable\n')
  assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleaned\n')
  assert.equal(await fs.exists(`${CWD}/cleaned.txt`), false)
})

test('a child fatal expansion cannot seed EXIT after a later engine ceiling failure', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'echo H; echo $PWD ${Z-}; echo stale > stale.txt\' EXIT; '
      + `f(){ f; }; ! (cd ${CWD}/other; Z=child; echo \${MISSING?child}); f`,
  ], { cwd: CWD })
  assert.equal(result.exitCode, 126, result.stderr)
  assert.equal(result.stdout, '')
  assert.doesNotMatch(result.stdout, /H|child/u)
  assert.match(result.stderr, /maximum recursion depth/u)
  assert.match(result.stderr, /reason=backend-failed/u)
  assert.equal(await fs.exists(`${CWD}/other/stale.txt`), false)
  assert.equal(await fs.exists(`${CWD}/stale.txt`), false)
})

test('normal completion uses only the pipeline that produced the final $?', async () => {
  const { shell } = await fixture()
  const shortCircuited = await shell.run([
    'bash',
    '-c',
    'trap \'echo $? ${PIPESTATUS[*]}\' EXIT; true | false; false && true',
  ], { cwd: CWD })
  assert.equal(shortCircuited.exitCode, 1, shortCircuited.stderr)
  assert.equal(shortCircuited.stdout, '1 1\n')
  assert.equal(shortCircuited.stderr, '')

  const negated = await shell.run([
    'bash',
    '-c',
    'trap \'echo $? ${PIPESTATUS[*]}\' EXIT; true | false; ! true',
  ], { cwd: CWD })
  assert.equal(negated.exitCode, 1, negated.stderr)
  assert.equal(negated.stdout, '1 0\n')
  assert.equal(negated.stderr, '')

  const plainPipeline = await shell.run([
    'bash',
    '-c',
    'trap \'echo $? ${PIPESTATUS[*]}\' EXIT; true | false',
  ], { cwd: CWD })
  assert.equal(plainPipeline.exitCode, 1, plainPipeline.stderr)
  assert.equal(plainPipeline.stdout, '1 0 1\n')
  assert.equal(plainPipeline.stderr, '')

  const negatedErrexit = await shell.run([
    'bash',
    '-c',
    'set -e; trap \'echo $? ${PIPESTATUS[*]}\' EXIT; ! false; echo continued',
  ], { cwd: CWD })
  assert.equal(negatedErrexit.exitCode, 0, negatedErrexit.stderr)
  assert.equal(negatedErrexit.stdout, 'continued\n0 0\n')
  assert.equal(negatedErrexit.stderr, '')
})

test('a fatal statement falls back to its own status instead of the previous PIPESTATUS', async () => {
  const { shell } = await fixture()
  const result = await shell.run([
    'bash',
    '-c',
    'set -o pipefail; trap \'echo $? ${PIPESTATUS[*]}\' EXIT; '
      + 'false | true; echo ${MISSING?msg}',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '1 1\n')
  assert.equal(result.stderr, 'bash: msg\n')
})

test('a readonly failure exposes assignments applied before the throw', async () => {
  const { fs, shell } = await fixture()
  const cases = [
    { assignment: 'X=5', expected: 'X=5\n' },
    { assignment: 'X=$(echo hi)', expected: 'X=hi\n' },
  ] as const
  for (const { assignment, expected } of cases) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'echo X=\${X-}; echo cleaned > cleaned.txt' EXIT; readonly r=1; ${assignment} r=2`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, result.stderr)
    assert.equal(result.stdout, expected, assignment)
    assert.match(result.stderr, /readonly variable/u)
    assert.doesNotMatch(result.stderr, /reason=backend-failed/u, assignment)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', assignment)
    await fs.rm(`${CWD}/cleaned.txt`)
  }
})

test('a child fatal in a short-circuited condition cannot seed a later ordinary fatal', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-pwd=%s x=%s\\n" "$PWD" "${X-}"; echo cleaned > cleaned.txt\' EXIT; '
      + 'readonly r=1; '
      + `f(){ cd ${CWD}/other; X=child; echo \${MISSING?child}; }; `
      + '( f ) && :; r=2',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.match(result.stderr, /readonly variable/u)
  assert.equal(result.stdout, `handler-pwd=${CWD} x=\n`)
  assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n')
  assert.equal(await fs.exists(`${CWD}/other/cleaned.txt`), false,
    'the short-circuited child capture must not choose the handler cwd')
})

test('readonly fatal uses the state after earlier assignments, not a stale checkpoint', async () => {
  const cases = [
    { script: 'readonly r=1; X=5 r=2; echo after', expected: 'x=5\n' },
    { script: 'readonly r=1 r=2', expected: 'x=\n' },
    { script: 'readonly r=1; X=$(echo hi) r=2', expected: 'x=hi\n' },
    { script: 'readonly r=1; f(){ X=5 r=2; }; f', expected: 'x=5\n' },
    { script: 'readonly r=1; r=2; X=5 true', expected: 'x=\n' },
    { script: 'readonly r=1; X=1; r=2', expected: 'x=1\n' },
  ] as const
  for (const { script, expected } of cases) {
    const { fs, shell } = await fixture()
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "x=%s\\n" "\${X-}"; echo cleaned > cleaned.txt' EXIT; ${script}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, expected, script)
    assert.match(result.stderr, /readonly variable/u, script)
    assert.doesNotMatch(result.stderr, /reason=backend-failed/u, script)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', script)
  }
})

test('source, dot and eval fatal unwinds use the same terminal seam', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile(`${CWD}/unsafe.sh`, 'readonly r=1\nX=5 r=2\n')
  await fs.writeFile(`${CWD}/safe.sh`, 'readonly r=1\nr=2\n')
  await fs.writeFile(`${CWD}/harmless.sh`, 'X=5 true\n')

  for (const script of [
    'source /dsh/workspace/unsafe.sh',
    '. /dsh/workspace/unsafe.sh',
    "eval 'readonly r=1; X=5 r=2'",
  ]) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'echo x=\${X-}; echo cleaned > cleaned.txt' EXIT; ${script}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, 'x=5\n', script)
    assert.match(result.stderr, /readonly variable/u, script)
    assert.doesNotMatch(result.stderr, /reason=backend-failed/u, script)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', script)
    await fs.rm(`${CWD}/cleaned.txt`)
  }

  for (const script of [
    'source /dsh/workspace/safe.sh',
    "eval 'readonly r=1; r=2'",
  ]) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "x=%s r=%s\\n" "\${X-}" "\${r-}"; echo cleaned > cleaned.txt' EXIT; `
        + `X=before; ${script}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, 'x=before r=1\n', script)
    assert.match(result.stderr, /readonly variable/u, script)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', script)
  }

  for (const script of [
    'source /dsh/workspace/harmless.sh',
    "eval 'X=5 true'",
  ]) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "x=%s\\n" "\${X-}"; echo cleaned > cleaned.txt' EXIT; `
        + `readonly r=1; ${script}; r=2`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, 'x=\n', `${script}: a later transform must not lock the flag`)
    assert.equal(await fs.readFile(`${CWD}/cleaned.txt`), 'cleaned\n', script)
  }
})

test('the arithmetic nounset fatal runs EXIT and does not use a child error capture', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler-status=%s pipe=%s pwd=%s x=%s\\n" '
      + '"$?" "${PIPESTATUS[*]}" "$PWD" "${X-}"; echo cleaned > cleaned.txt\' EXIT; '
      + `set -u; X=main; (X=child; cd ${CWD}/other; echo \${MISSING?child}) || :; `
      + `X=after; cd ${CWD}/other; (( missing >= 5 ))`,
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, `handler-status=1 pipe=1 pwd=${CWD}/other x=after\n`)
  assert.match(result.stderr, /bash: (child|missing: unbound variable)/u)
  assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleaned\n')
})

test('a trap installed through a runtime command word captures the failing state', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const handler = 'printf "handler-status=%s pipe=%s pwd=%s x=%s\\n" '
    + '"$?" "${PIPESTATUS[*]}" "$PWD" "$X"; echo cleaned > cleaned.txt'
  // A command word stored in a variable and a `command`/`builtin` dispatcher
  // install the same real handler as the literal spelling. Before the
  // transform recognised those forms it inserted no checkpoints, so the
  // following readonly fatal used the engine's initial cwd/environment and
  // the handler wrote `stale.txt` in the wrong directory. GNU bash reports the
  // state after `cd other; X=1`.
  for (const install of ['b=trap; $b', 'command trap', 'builtin trap']) {
    const result = await shell.run([
      'bash',
      '-c',
      `${install} '${handler}' EXIT; cd ${CWD}/other; X=1; readonly r=1; r=2`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${install}: ${result.stderr}`)
    assert.equal(result.stdout, `handler-status=1 pipe=1 pwd=${CWD}/other x=1\n`, install)
    assert.match(result.stderr, /readonly variable/u, install)
    assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleaned\n', install)
    assert.equal(await fs.exists(`${CWD}/cleaned.txt`), false, install)
    await fs.rm(`${CWD}/other/cleaned.txt`)
  }
})

test('a runtime trap sees the live state of a fatal expansion', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const handler = 'printf "handler-status=%s pipe=%s pwd=%s x=%s\\n" '
    + '"$?" "${PIPESTATUS[*]}" "$PWD" "${X-}"; echo cleaned > cleaned.txt'
  // `${MISSING?message}` throws before any checkpoint, so this path needs both
  // the error-word capture and the statement boundary. A runtime spelling must
  // get the same live state as the literal `trap` spelling; the initial
  // environment would report the original cwd and an unset X.
  for (const install of ['b=trap; $b', 'command trap', 'builtin trap']) {
    const result = await shell.run([
      'bash',
      '-c',
      `${install} '${handler}' EXIT; set -u; cd ${CWD}/other; X=1; echo \${MISSING?msg}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${install}: ${result.stderr}`)
    assert.equal(result.stdout, `handler-status=1 pipe=1 pwd=${CWD}/other x=1\n`, install)
    assert.equal(result.stderr, 'bash: msg\n', install)
    assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleaned\n', install)
    assert.equal(await fs.exists(`${CWD}/cleaned.txt`), false, install)
    await fs.rm(`${CWD}/other/cleaned.txt`)
  }
})

test('a runtime trap sees assignments applied before the readonly throw', async () => {
  const { fs, shell } = await fixture()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  // The assignment-only command applies X=5 before r=2 fails, so the handler
  // runs in the directory and with the variable the script actually reached.
  for (const install of ['b=trap; $b', 'command trap', 'builtin trap']) {
    const result = await shell.run([
      'bash',
      '-c',
      `${install} 'printf "X=%s\\n" "\${X-}"; echo cleaned > cleaned.txt' EXIT; `
        + `readonly r=1; cd ${CWD}/other; X=5 r=2`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${install}: ${result.stderr}`)
    assert.equal(result.stdout, 'X=5\n', install)
    assert.match(result.stderr, /readonly variable/u, install)
    assert.doesNotMatch(result.stderr, /reason=backend-failed/u, install)
    assert.equal(await fs.readFile(`${CWD}/other/cleaned.txt`), 'cleaned\n', install)
    assert.equal(await fs.exists(`${CWD}/cleaned.txt`), false, install)
    await fs.rm(`${CWD}/other/cleaned.txt`)
  }
})

test('a slow EXIT handler is bounded by the wall clock and maps to 124', async () => {
  const { shell } = await fixture()
  const started = Date.now()
  const result = await shell.run(['bash', '-c', 'trap \'sleep 5\' EXIT; echo hi'], {
    cwd: CWD,
    timeoutMs: 100,
  })
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.ok(Date.now() - started < 2_000, `handler timeout took ${String(Date.now() - started)}ms`)
})

test('a caller abort during the EXIT handler maps to 130', async () => {
  const { shell } = await fixture()
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 50)
  try {
    const result = await shell.run(['bash', '-c', 'trap \'sleep 1\' EXIT; echo hi'], {
      cwd: CWD,
      signal: controller.signal,
      timeoutMs: 5_000,
    })
    assert.equal(result.exitCode, 130)
    assert.equal(result.aborted, true)
  } finally {
    clearTimeout(timer)
  }
})

test('trap state is scoped to subshells, pipelines and command substitution', async () => {
  const cases = [
    {
      script: "trap 'echo parent' EXIT; ( trap - EXIT; : ); echo after",
      stdout: 'after\nparent\n',
    },
    {
      script: "trap 'echo parent' EXIT; x=$(trap 'echo child' EXIT); echo after",
      stdout: 'after\nparent\n',
    },
    {
      script: "trap 'echo parent' EXIT; ( trap 'echo child' EXIT; : ) >/dev/null; echo after",
      stdout: 'after\nparent\n',
    },
    {
      script: "trap 'echo parent' EXIT; trap - EXIT | cat; echo after",
      stdout: 'after\nparent\n',
    },
    {
      script: "trap 'echo parent' EXIT; trap 'echo child' EXIT | cat >/dev/null; echo after",
      stdout: 'after\nparent\n',
    },
  ] as const
  for (const { script, stdout } of cases) {
    const { shell } = await fixture()
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 0, script)
    assert.equal(result.stdout, stdout, script)
    assert.equal(result.stderr, '', script)
  }
})

test('a dynamic function pipeline cannot clear or replace the root EXIT handler', async () => {
  // The AST transform can wrap a statically known function stage, but
  // `g=f; $g | cat` reaches the function through a runtime command word. The
  // engine keeps one bashPid for that stage, so the stage-scoped trap identity
  // is what keeps `trap - EXIT` inside the child from removing root cleanup.
  const cases = [
    {
      script: "trap 'echo root' EXIT; f(){ trap - EXIT; }; g=f; $g | cat; echo after",
      stdout: 'after\nroot\n',
    },
    {
      script: "trap 'echo root' EXIT; f(){ trap 'echo CHILD' EXIT; }; g=f; $g | cat; echo after",
      stdout: 'after\nroot\n',
    },
    {
      script: "trap 'echo root' EXIT; f(){ trap 'echo CHILD' EXIT; :; }; g=f; $g | cat; echo after",
      stdout: 'after\nroot\n',
    },
    {
      script: "trap 'echo root' EXIT; f(){ trap - EXIT; }; g=f; $g | cat; trap -p EXIT",
      stdout: "trap -- 'echo root' EXIT\nroot\n",
    },
  ] as const
  for (const { script, stdout } of cases) {
    const { shell } = await fixture()
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 0, script)
    assert.equal(result.stdout, stdout, script)
    assert.equal(result.stderr, '', script)
    assert.doesNotMatch(result.stdout, /CHILD/u, script)
  }
})

test('trap state is private to one execution', async () => {
  const { shell } = await fixture()
  const first = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; echo first'], { cwd: CWD })
  assert.equal(first.stdout, 'first\nbye\n')
  const second = await shell.run(['bash', '-c', 'echo second'], { cwd: CWD })
  assert.equal(second.exitCode, 0)
  assert.equal(second.stdout, 'second\n')
  assert.equal(second.stderr, '')
})

test('bash -n never runs an EXIT handler', async () => {
  const { fs, shell } = await fixture()
  const result = await shell.run(['bash', '-n', '-c', 'trap "echo bye > ran.txt" EXIT; echo hi'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '')
  assert.equal(await fs.exists(`${CWD}/ran.txt`), false)
})

test('an EXIT handler does not run on a wall-clock timeout or caller abort', async () => {
  const { shell } = await fixture()
  const timedOut = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; sleep 5'], {
    cwd: CWD,
    timeoutMs: 50,
  })
  assert.equal(timedOut.exitCode, 124)
  assert.equal(timedOut.stdout, '')
  assert.doesNotMatch(timedOut.stdout, /bye/u)

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 20)
  try {
    const aborted = await shell.run(['bash', '-c', 'trap "echo bye" EXIT; sleep 5'], {
      cwd: CWD,
      signal: controller.signal,
    })
    assert.equal(aborted.exitCode, 130)
    assert.equal(aborted.stdout, '')
    assert.doesNotMatch(aborted.stdout, /bye/u)
  } finally {
    clearTimeout(timer)
  }
})

test('createWorkerCommands serves the same real trap builtin', async () => {
  const { shell } = await fixture({ productionCommands: true })
  const result = await shell.run(['bash', '-c', 'trap "echo from-production" EXIT; type trap'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'trap is a shell builtin\nfrom-production\n')
  assert.equal(result.stderr, '')
})
