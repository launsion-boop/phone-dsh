// SPDX-License-Identifier: MIT
// The patched just-bash engine reports an authoritative terminal state after a
// root execution: real unwound cwd/env, shell options, functions/arrays, the
// last pipeline statuses and a typed cause. These tests drive the production
// WorkerShell path and compare the observable handler behavior with GNU bash
// on Linux. The engine metadata itself is validated separately.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Bash } from 'just-bash/browser'
import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import {
  readTerminalState,
  terminalHandlerEligible,
} from '../shell-ext/src/terminal.ts'

const roots: string[] = []
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const HAS_GNU_BASH = spawnSync('bash', ['-c', 'exit 0'], { encoding: 'utf8' }).status === 0
// lastpipe was added after the legacy Bash 3.2 shipped with macOS. Keep the
// Worker assertions active everywhere; use a native comparison only where
// the installed Bash actually enables the option.
const HAS_GNU_LASTPIPE = spawnSync('bash', ['-c', 'shopt -s lastpipe && shopt -q lastpipe'], {
  encoding: 'utf8',
}).status === 0
const GNU_BASH_VERSION = spawnSync('bash', ['-c', 'printf %s "$BASH_VERSION"'], {
  encoding: 'utf8',
}).stdout.trim()

/** A temporary root used by either the Worker VFS or GNU bash. */
function temporaryRoot(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix))
  roots.push(root)
  return root
}

/** A WorkerShell whose VFS has /work, /work/other and /tmp. */
async function workerShell(): Promise<{ fs: VfsFileSystem; shell: WorkerShell }> {
  const fs = new VfsFileSystem({ root: temporaryRoot('pdsh-terminal-') })
  await fs.mkdir('/work', { recursive: true })
  await fs.mkdir('/work/other', { recursive: true })
  await fs.mkdir('/tmp', { recursive: true })
  return { fs, shell: new WorkerShell({ fs }) }
}

/** Real directories matching {@link workerShell}. */
function gnuRoot(): string {
  const root = temporaryRoot('pdsh-gnu-')
  mkdirSync(join(root, 'work', 'other'), { recursive: true })
  mkdirSync(join(root, 'tmp'))
  mkdirSync(join(root, 'home'))
  return root
}

/** Run the same script through GNU bash in the matching real tree. */
function runGnu(root: string, script: string): { exitCode: number; stdout: string; stderr: string } {
  const result = spawnSync('bash', ['-c', script], {
    cwd: join(root, 'work'),
    env: {
      PATH: process.env.PATH ?? '/usr/bin:/bin',
      HOME: join(root, 'home'),
      PWD: join(root, 'work'),
      OLDPWD: join(root, 'work'),
    },
    encoding: 'utf8',
  })
  return { exitCode: result.status ?? 1, stdout: result.stdout, stderr: result.stderr }
}

/**
 * Compare one script's status and stdout with GNU bash.
 * @param script - the script to run.
 * @param files - optional relative files to create in both trees.
 * @returns the Worker result and filesystem for further side-effect checks.
 */
async function compareWithGnu(
  script: string,
  files: Readonly<Record<string, string>> = {},
): Promise<{ result: Awaited<ReturnType<WorkerShell['run']>>; fs: VfsFileSystem }> {
  const { fs, shell } = await workerShell()
  const root = gnuRoot()
  for (const [name, content] of Object.entries(files)) {
    await fs.writeFile(`/work/${name}`, content)
    writeFileSync(join(root, 'work', name), content)
  }
  const result = await shell.run(['bash', '-c', script], { cwd: '/work' })
  const gnu = runGnu(root, script)
  assert.equal(result.exitCode, gnu.exitCode, `status: ${result.stderr}`)
  assert.equal(result.stdout, gnu.stdout)
  return { result, fs }
}

test('the terminal record validates and labels a non-ordinary interruption as ineligible', () => {
  assert.equal(readTerminalState({ exitCode: 1 }), undefined)
  const terminal = {
    format: 'just-bash-terminal/1',
    authority: 'engine',
    engine: { name: 'just-bash', version: '3.6.0', seam: 'phone-dsh/terminal-state/1' },
    authoritative: true,
    cause: 'execution-limit',
    termination: 'not-ordinary',
    status: 126,
    cwd: '/work',
    env: { PWD: '/work' },
    options: {},
    shopt: {},
    functions: [],
    arrays: {},
    pipeline: { statuses: [126], status: 126, negated: false },
    unwound: true,
  } as const
  const parsed = readTerminalState({ exitCode: 126, metadata: { terminal } })
  assert.ok(parsed !== undefined)
  assert.equal(parsed?.termination, 'not-ordinary')
  assert.equal(terminalHandlerEligible(parsed), false)
})

test('top-level set-e reports the real final pipeline statuses and state', { skip: !HAS_GNU_BASH }, async () => {
  const { result, fs } = await compareWithGnu([
    'trap \'printf "status=%s pipe=%s x=%s dir=%s\\n" "$?" "${PIPESTATUS[*]}" "$X" "${PWD##*/}"; echo cleaned > cleaned.txt\' EXIT',
    'set -euo pipefail',
    'X=1',
    'false | true',
    'echo unreachable',
  ].join('\n'))
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, 'status=1 pipe=1 0 x=1 dir=work\n')
  assert.equal(result.stderr, '')
  assert.equal(await fs.readFile('/work/cleaned.txt'), 'cleaned\n')

  const explicit = await compareWithGnu("trap 'echo st=$? pipe=${PIPESTATUS[*]}' EXIT; false | true; exit 7")
  assert.equal(explicit.result.exitCode, 7)
  assert.equal(explicit.result.stdout, 'st=7 pipe=1 0\n')
})

test('source, dot, eval and a negated condition do not trip errexit', { skip: !HAS_GNU_BASH }, async () => {
  for (const use of ['source ./helper.sh', '. ./helper.sh', "eval 'Y=2; :'"]) {
    const { result } = await compareWithGnu([
      'trap \'printf "status=%s pipe=%s x=%s y=%s\\n" "$?" "${PIPESTATUS[*]}" "$X" "$Y"\' EXIT',
      'set -e',
      'X=1',
      use,
      "eval ':'",
      '! false',
      'echo continued',
    ].join('\n'), { 'helper.sh': 'Y=2\n' })
    assert.equal(result.exitCode, 0, use)
    assert.equal(result.stdout, 'continued\nstatus=0 pipe=0 x=1 y=2\n', use)
    assert.equal(result.stderr, '', use)
  }
})

test('function locals are unwound and PWD stays a variable separate from cwd', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    'trap \'printf "x=%s y=%s pwd=%s real=%s\\n" "${X-}" "${Y-}" "$PWD" "$(basename "$(pwd)")"\' EXIT',
    'X=global',
    'Y=globalY',
    'f(){ local X=local; local Y=localY; cd other; PWD=/bogus; }',
    'f',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'x=global y=globalY pwd=/bogus real=other\n')
  assert.equal(result.stderr, '')
})

test('a function cd inside a pipeline does not leak into the parent', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    'trap \'printf "dir=%s\\n" "${PWD##*/}"\' EXIT',
    'f(){ cd ../tmp; }',
    'f | cat',
    'printf "after=%s\\n" "${PWD##*/}"',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'after=work\ndir=work\n')
  assert.equal(result.stderr, '')
})

test('readonly RHS side effects survive the fatal unwind', { skip: !HAS_GNU_BASH }, async () => {
  const cases = [
    { script: 'X=${Y:=7} R=2', stdout: 'x=7 y=7 z= status=1\n' },
    { script: 'X=$((Y=7)) R=2', stdout: 'x=7 y=7 z= status=1\n' },
  ] as const
  const fatal = 'trap \'printf "x=%s y=%s z=%s status=%s\\n" "${X-}" "${Y-}" "${Z-}" "$?"\' EXIT\nX=before\nreadonly R=1\n: ${Y:=7} ${MISSING?}'
  for (const { script, stdout } of cases) {
    const { result } = await compareWithGnu([
      'trap \'printf "x=%s y=%s z=%s status=%s\\n" "${X-}" "${Y-}" "${Z-}" "$?"\' EXIT',
      'X=before',
      'readonly R=1',
      script,
    ].join('\n'))
    assert.equal(result.exitCode, 1, script)
    assert.equal(result.stdout, stdout, script)
  }
  // GNU reports 127 for a fatal expansion in a special-builtin argument while
  // the engine reports 1; the side effects and the handler state are the same,
  // so this case checks the engine directly rather than claiming status parity.
  const { shell } = await workerShell()
  const result = await shell.run(['bash', '-c', fatal], { cwd: '/work' })
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, 'x=before y=7 z= status=1\n')
})

test('command substitution restores parent verbose tracing on success and failure', { skip: !HAS_GNU_BASH }, async () => {
  for (const command of [
    'x=$(echo child)',
    'echo "$(echo child)"',
    'x=$(readonly R=1; R=2)',
    'echo "$(readonly R=1; R=2)"',
  ]) {
    const { result } = await compareWithGnu(`set -v\n${command}\necho after\n`)
    assert.match(result.stderr, /(?:^|\n)echo after(?:\n|$)/u, command)
  }
})

test('command substitution cannot leak shell namespace state into EXIT', { skip: !HAS_GNU_BASH }, async () => {
  const cases = [
    {
      script: "trap 'echo handler NOPE=$NOPE' EXIT; x=$(set -u); :",
      stdout: 'handler NOPE=\n',
      stderr: '',
    },
    {
      script: "trap 'shopt -q extglob; echo extglob=$?' EXIT; x=$(shopt -s extglob); :",
      stdout: 'extglob=1\n',
      stderr: '',
    },
    {
      script: "trap 'childfn arg' EXIT; x=$(childfn(){ echo CHILD; }); :",
      stdout: '',
      stderr: /command not found/u,
    },
    {
      script: "trap 'R=2; echo after' EXIT; x=$(readonly R=1)",
      stdout: 'after\n',
      stderr: '',
    },
  ] as const
  for (const { script, stdout, stderr } of cases) {
    const { result } = await compareWithGnu(script)
    assert.equal(result.exitCode, 0, script)
    assert.equal(result.stdout, stdout, script)
    if (stderr === '') assert.equal(result.stderr, '', script)
    else assert.match(result.stderr, stderr, script)
    assert.doesNotMatch(result.stdout, /CHILD/u, script)
  }
})

test('function-local array assignments unwind before EXIT, normally and on a fatal', { skip: !HAS_GNU_BASH }, async () => {
  for (const assignment of ['B=(secret)', 'B+=secret', 'B[0]=secret']) {
    const normal = [
      'trap \'printf "B=%s\\n" "${B[*]}"\' EXIT',
      'B=(global)',
      `f(){ local B; ${assignment}; }`,
      'f',
    ].join('\n')
    const { result } = await compareWithGnu(normal)
    assert.equal(result.exitCode, 0, assignment)
    assert.equal(result.stdout, 'B=global\n', assignment)
    assert.equal(result.stderr, '', assignment)

    const fatal = [
      'trap \'printf "B=%s\\n" "${B[*]}"\' EXIT',
      'B=(global)',
      `f(){ local B; ${assignment}; readonly r=1; r=2; }`,
      'f',
    ].join('\n')
    const failed = await compareWithGnu(fatal)
    assert.equal(failed.result.exitCode, 1, assignment)
    assert.equal(failed.result.stdout, 'B=global\n', assignment)
    assert.match(failed.result.stderr, /readonly variable/u, assignment)
  }
})

test('user stderr containing unbound/readonly words is not a termination signal', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    'trap \'printf "status=%s\\n" "$?"\' EXIT',
    "printf 'unbound variable readonly variable\\n' >&2",
    'exit 3',
  ].join('\n'))
  assert.equal(result.exitCode, 3)
  assert.equal(result.stdout, 'status=3\n')
  assert.match(result.stderr, /unbound variable readonly variable/u)

  const normal = await compareWithGnu([
    'trap \'printf "status=%s\\n" "$?"\' EXIT',
    "printf 'readonly variable unbound variable\\n' >&2",
    ':',
  ].join('\n'))
  assert.equal(normal.result.exitCode, 0)
  assert.equal(normal.result.stdout, 'status=0\n')
})

test('the EXIT handler sees global functions, arrays and no hidden environment', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    'trap \'f cleanup; printf "array=%s env=%s\\n" "${A[1]}" "$(env | grep -c __pdsh || true)"\' EXIT',
    'A=(zero one)',
    'f(){ printf "f=%s\\n" "$1"; }',
    ':',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'f=cleanup\narray=one env=0\n')
  assert.doesNotMatch(result.stderr, /__pdsh/u)
})

test('set -x does not trace the hidden terminal seed', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    "trap 'echo handler' EXIT",
    'set -x',
    'X=1',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'handler\n')
  assert.match(result.stderr, /\+ X=1/mu)
  assert.doesNotMatch(result.stderr, /__pdsh/u)
})

test('an explicit exit in the handler changes the status; a plain failure does not', { skip: !HAS_GNU_BASH }, async () => {
  const explicit = await compareWithGnu("trap 'exit 9' EXIT; true")
  assert.equal(explicit.result.exitCode, 9)
  assert.equal(explicit.result.stdout, '')

  const failure = await compareWithGnu("trap 'false' EXIT; true")
  assert.equal(failure.result.exitCode, 0)

  const overrides = await compareWithGnu("trap 'false' EXIT; exit 3")
  assert.equal(overrides.result.exitCode, 3)
})

test('the handler runs in the same filesystem and virtual cwd', { skip: !HAS_GNU_BASH }, async () => {
  const { result, fs } = await compareWithGnu([
    'trap \'echo cleaned > cleaned.txt\' EXIT',
    'f(){ cd other; }',
    'f',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(await fs.readFile('/work/other/cleaned.txt'), 'cleaned\n')
  assert.equal(await fs.exists('/work/cleaned.txt'), false)
})

test('a missing GNU bash does not turn the metadata checks into a PASS', () => {
  if (!HAS_GNU_BASH) {
    assert.equal(readTerminalState({ exitCode: 0, metadata: { terminal: {} } }), undefined)
  } else {
    assert.ok(true)
  }
})


test('an explicit exit in the handler still wins after source/dot/eval', { skip: !HAS_GNU_BASH }, async () => {
  for (const { handler, status } of [
    { handler: 'source /dev/null; exit 9', status: 9 },
    { handler: '. /dev/null; exit 9', status: 9 },
    { handler: 'eval :; exit 9', status: 9 },
    { handler: 'source /dev/null; exit 0', status: 0 },
    { handler: 'source /dev/null; exit $?', status: 0 },
  ]) {
    const { result } = await compareWithGnu(`trap '${handler}' EXIT; true`)
    assert.equal(result.exitCode, status, handler)
    assert.equal(result.stdout, '', handler)
  }
})

test('the handler status is engine-seeded, not a user-definable command name', { skip: !HAS_GNU_BASH }, async () => {
  for (const script of [
    'trap \'printf "st=%s pipe=%s\\n" "$?" "${PIPESTATUS[*]}"\' EXIT; function __pdsh_status { return 42; }; false',
    'trap \'printf "st=%s pipe=%s\\n" "$?" "${PIPESTATUS[*]}"\' EXIT; alias __pdsh_status=false; false',
    'trap \'printf "st=%s pipe=%s\\n" "$?" "${PIPESTATUS[*]}"\' EXIT; __pdsh_status() { return 0; }; false',
  ]) {
    const { result } = await compareWithGnu(script)
    assert.equal(result.exitCode, 1, script)
    assert.equal(result.stdout, 'st=1 pipe=1\n', script)
    assert.equal(result.stderr, '', script)
  }
})

test('source and eval leave no hidden variable or prepare trace', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    "printf 'Y=2\\n' > helper.sh",
    'source ./helper.sh',
    "printf 'E=3\\n' > evalsrc",
    'eval "$(cat evalsrc)"',
    'env | grep __pdsh || true',
    'set -x',
    'source ./helper.sh',
    'eval "Z=4"',
    'set +x',
    'printf "y=%s e=%s z=%s\\n" "$Y" "$E" "$Z"',
  ].join('\n'))
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'y=2 e=3 z=4\n')
  assert.doesNotMatch(result.stdout, /__pdsh/u)
  assert.doesNotMatch(result.stderr, /__pdsh|pdsh-source/u)
  assert.match(result.stderr, /\+ source \.\/helper\.sh/mu)
  assert.match(result.stderr, /\+ eval Z=4/mu)
})

test('cannot-assign special parameters keep the GNU diagnostic and a typed fatal', async () => {
  const { shell } = await workerShell()
  for (const parameter of ['*', '@']) {
    const result = await shell.run(['bash', '-c', `set -u; : \${${parameter}:=x}`], { cwd: '/work' })
    assert.equal(result.exitCode, 1, parameter)
    assert.match(result.stderr, new RegExp(`bash: \\\$${parameter === '*' ? '\\*' : '@'}: cannot assign in this way`, 'u'), parameter)
    assert.doesNotMatch(result.stderr, /Cannot set properties|backend-failed/u, parameter)
  }
})

test('a function defined by source is isolated inside a pipeline', { skip: !HAS_GNU_BASH }, async () => {
  const { result } = await compareWithGnu([
    "printf 'f(){ cd /tmp; }\\n' > defs.sh",
    'source defs.sh',
    'f | cat',
    'printf "after=%s\\n" "${PWD##*/}"',
  ].join('\n'), { 'defs.sh': 'f(){ cd /tmp; }\n' })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'after=work\n')
})


test('the engine labels an explicit exit after a completed source as explicit-exit', async () => {
  const fs = new VfsFileSystem({ root: temporaryRoot('pdsh-engine-cause-') })
  await fs.mkdir('/work', { recursive: true })
  await fs.writeFile('/work/helper.sh', ':')
  const bash = new Bash({ fs, cwd: '/work', env: { PWD: '/work', PATH: '/usr/bin:/bin' } })
  const result = await bash.exec('source /work/helper.sh; exit 7')
  const terminal = readTerminalState(result)
  assert.ok(terminal !== undefined)
  assert.equal(terminal.cause, 'exit')
  assert.equal(terminal.termination, 'explicit-exit')
  assert.equal(terminal.status, 7)
})

test('a dynamic or eval-shadowed pipeline stage cannot move the EXIT handler cwd', { skip: !HAS_GNU_BASH }, async () => {
  const cases = [
    {
      script: [
        'trap \'echo cleaned > cleaned.txt\' EXIT',
        'f(){ cd /tmp; }',
        'g=f',
        '$g | cat',
      ].join('\n'),
    },
    {
      script: [
        'trap \'echo cleaned > cleaned.txt\' EXIT',
        'eval \'cat(){ cd /tmp; }\'',
        'cat | cat',
      ].join('\n'),
    },
    {
      script: [
        'trap \'echo cleaned > cleaned.txt\' EXIT',
        'source defs.sh',
        'cat | cat',
      ].join('\n'),
    },
  ]
  const files = { 'defs.sh': 'cat(){ cd /tmp; }\n' }
  for (const { script } of cases) {
    const { result, fs } = await compareWithGnu(script, files)
    assert.equal(result.exitCode, 0, script)
    assert.equal(result.stdout, '', script)
    assert.equal(result.stderr, '', script)
    assert.equal(await fs.readFile('/work/cleaned.txt'), 'cleaned\n', script)
    assert.equal(await fs.exists('/tmp/cleaned.txt'), false, script)
  }
})

test('a caught child fatal cannot turn a later root or handler exit into fatal-unwind', { skip: !HAS_GNU_BASH }, async () => {
  const scripts = [
    { script: "trap 'x=$(readonly r=1; r=2); exit 9' EXIT; true", status: 9, diagnostic: /readonly variable/u },
    { script: "trap 'x=$(set -e; false); exit 9' EXIT; true", status: 9, diagnostic: undefined },
    { script: "trap '(readonly q=1; q=2); exit 9' EXIT; true", status: 9, diagnostic: /readonly variable/u },
    { script: "trap 'readonly q=1; q=2 | cat; exit 9' EXIT; true", status: 9, diagnostic: /readonly variable/u },
    { script: "trap 'x=$(readonly r=1; r=2); :' EXIT; true", status: 0, diagnostic: /readonly variable/u },
  ] as const
  for (const { script, status, diagnostic } of scripts) {
    const { result } = await compareWithGnu(script)
    assert.equal(result.exitCode, status, script)
    assert.equal(result.stdout, '', script)
    if (diagnostic === undefined) assert.equal(result.stderr, '', script)
    else assert.match(result.stderr, diagnostic, script)
  }

  const pipestatus = await compareWithGnu([
    'trap \'echo st=$? pipe=${PIPESTATUS[*]}\' EXIT',
    'x=$(readonly r=1; r=2)',
    'exit 0',
  ].join('\n'))
  assert.equal(pipestatus.result.exitCode, 0)
  assert.equal(pipestatus.result.stdout, 'st=0 pipe=1\n')
})

test('an arithmetic failure has a consistent PIPESTATUS instead of the previous pipeline', { skip: !HAS_GNU_BASH }, async () => {
  for (const expression of ['1/0', '1%0', '2#2']) {
    const script = [
      'trap \'echo st=$? pipe=${PIPESTATUS[*]}\' EXIT',
      ':',
      `echo $(( ${expression} ))`,
    ].join('\n')
    const { shell } = await workerShell()
    const result = await shell.run(['bash', '-c', script], { cwd: '/work' })
    assert.equal(result.exitCode, 1, expression)
    assert.equal(result.stdout, 'st=1 pipe=1\n', expression)
    assert.match(result.stderr, /^(?:bash: )/u, expression)

    // GNU Bash 5.1 reports the failed arithmetic command as PIPESTATUS=1.
    // macOS's Bash 3.2 leaves the previous `:` status there instead. Always
    // keep the Worker assertion above; compare against native output only for
    // the known version-specific behavior, and reject unknown oracle shapes.
    const native = spawnSync('bash', ['-c', script], { encoding: 'utf8' })
    assert.equal(native.status, 1, `${GNU_BASH_VERSION}: ${expression}`)
    if (native.stdout === 'st=1 pipe=1\n') {
      assert.equal(result.stdout, native.stdout, `${GNU_BASH_VERSION}: ${expression}`)
    } else {
      assert.match(GNU_BASH_VERSION, /^3\.2\./u, `unexpected GNU Bash PIPESTATUS oracle: ${native.stdout}`)
      assert.equal(native.stdout, 'st=1 pipe=0\n', `${GNU_BASH_VERSION}: ${expression}`)
      assert.match(native.stderr, /division by 0|value too great for base/u, expression)
    }
  }
})

test('a typed fatal inside a pipeline stage stays in that stage', { skip: !HAS_GNU_BASH }, async () => {
  for (const [script, expected] of [
    ['set -u; echo $MISSING | cat; printf \'st=%s pipe=%s\\n\' "$?" "${PIPESTATUS[*]}"', 'st=0 pipe=127 0\n'],
    ['echo $((1/0)) | cat; printf \'st=%s pipe=%s\\n\' "$?" "${PIPESTATUS[*]}"', 'st=0 pipe=1 0\n'],
  ] as const) {
    const { result } = await compareWithGnu(script)
    assert.equal(result.exitCode, 0, script)
    assert.equal(result.stdout, expected, script)
  }
})

test('lastpipe fatal and trap effects stay in the parent shell', async () => {
  const cases = [
    {
      script: [
        'shopt -s lastpipe',
        'set +m',
        'trap \'printf "trap:%s\\n" "$?"\' EXIT',
        'true | exit 7',
        'echo after',
      ].join('\n'),
      status: 7,
      stdout: 'trap:7\n',
    },
    {
      script: [
        'shopt -s lastpipe',
        'set +m',
        'trap \'echo trapped\' EXIT',
        'echo x | trap - EXIT',
        'echo after',
      ].join('\n'),
      status: 0,
      stdout: 'after\n',
    },
  ] as const
  for (const { script, status, stdout } of cases) {
    const { shell } = await workerShell()
    const result = await shell.run(['bash', '-c', script], { cwd: '/work' })
    assert.equal(result.exitCode, status, script)
    assert.equal(result.stdout, stdout, script)
    assert.equal(result.stderr, '', script)
    if (HAS_GNU_LASTPIPE) {
      const { result: native } = await compareWithGnu(script)
      assert.equal(result.exitCode, native.exitCode, script)
      assert.equal(result.stdout, native.stdout, script)
    }
  }
})

test('a POSIX special-builtin fatal in a child pipeline stage does not exit the root shell', { skip: !HAS_GNU_BASH }, async () => {
  const script = [
    'trap \'printf "trap:%s\\n" "$?"\' EXIT',
    'set -o posix',
    'shift 1 | cat',
    'echo after',
  ].join('\n')
  const { result } = await compareWithGnu(script)
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'after\ntrap:0\n')
  assert.match(result.stderr, /shift count out of range/u)
})

test('a bad substitution in the root shell remains fatal instead of becoming a status-1 command', { skip: !HAS_GNU_BASH }, async () => {
  const script = 'echo ${#var:1:3}; echo after'
  const { result } = await compareWithGnu(script)
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /bad substitution/u)
})

test('an EXIT handler without a terminal record fails loud instead of returning 0', async () => {
  const { fs, shell } = await workerShell()
  const prototype = Bash.prototype as unknown as {
    exec: (...args: unknown[]) => Promise<Record<string, unknown>>
  }
  const original = prototype.exec
  prototype.exec = async function (this: unknown, ...args: unknown[]): Promise<Record<string, unknown>> {
    const result = await original.apply(this, args)
    const { metadata: _metadata, ...rest } = result
    return rest
  }
  try {
    const result = await shell.run(
      ['bash', '-c', "trap 'echo cleaned > cleaned.txt' EXIT; true"],
      { cwd: '/work' },
    )
    assert.equal(result.exitCode, 1)
    assert.match(result.stderr, /no terminal-state record/u)
    assert.match(result.stderr, /reason=backend-failed/u)
    assert.equal(await fs.exists('/work/cleaned.txt'), false)
  } finally {
    prototype.exec = original
  }
})

test('an EXIT handler with a non-authoritative terminal record fails loud', async () => {
  const { fs, shell } = await workerShell()
  const prototype = Bash.prototype as unknown as {
    exec: (...args: unknown[]) => Promise<Record<string, unknown>>
  }
  const original = prototype.exec
  prototype.exec = async function (this: unknown, ...args: unknown[]): Promise<Record<string, unknown>> {
    const result = await original.apply(this, args)
    const metadata = result.metadata as { terminal?: Record<string, unknown> } | undefined
    if (metadata?.terminal === undefined) return result
    return {
      ...result,
      metadata: {
        ...metadata,
        terminal: {
          ...metadata.terminal,
          authoritative: false,
          unwound: false,
          unsupportedReason: 'test seam refused the terminal state',
        },
      },
    }
  }
  try {
    const result = await shell.run(
      ['bash', '-c', "trap 'echo cleaned > cleaned.txt' EXIT; true"],
      { cwd: '/work' },
    )
    assert.equal(result.exitCode, 1)
    assert.match(result.stderr, /test seam refused the terminal state/u)
    assert.match(result.stderr, /reason=backend-failed/u)
    assert.equal(await fs.exists('/work/cleaned.txt'), false)
  } finally {
    prototype.exec = original
  }
})
