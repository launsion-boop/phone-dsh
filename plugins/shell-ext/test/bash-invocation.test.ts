// SPDX-License-Identifier: MIT
// G2-FIX-89: the Worker's `bash`/`sh` invocation surface.
//
// The bundled just-bash command understands only `-c`: every other first word
// is opened as a script filename, so an option answered `No such file or
// directory` (127), and a script that did run used a nested interpreter whose
// output accounting the engine rejected (`invalid stdout accounting`, 126).
// These tests drive the real `WorkerShell.run`, the same argv shape
// subprocess-xl hands it, and compare the script forms against the shebang
// execution path (the reference behaviour).
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { VfsFileSystem, WorkerShell } from '../src/index.ts'

/** vfs cwd every invocation runs in. */
const CWD = '/dsh/workspace'

/** Prints $0, BASH_SOURCE and the positional parameters, then exits non-zero. */
const SCRIPT = `#!/bin/bash
printf 'argv0=%s\\n' "$0"
printf 'source0=%s\\n' "\${BASH_SOURCE[0]}"
printf 'source=%s\\n' "$BASH_SOURCE"
printf 'sources-at=%s\\n' "\${BASH_SOURCE[@]}"
printf 'sources-star=%s\\n' "\${BASH_SOURCE[*]}"
show_source() { printf 'fn-source=%s\\n' "\${BASH_SOURCE[0]}"; }
show_source
printf 'first=%s second=%s\\n' "$1" "$2"
printf 'count=%s\\n' "$#"
printf 'all=%s\\n' "$*"
exit 3
`

const roots: string[] = []

interface Fixture {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

async function fixture(): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-invocation-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir(CWD, { recursive: true })
  await fs.writeFile(`${CWD}/helper.sh`, SCRIPT)
  // The shebang path needs the executable bit on a real-directory backend.
  await fs.chmod(`${CWD}/helper.sh`, 0o755)
  await fs.writeFile(`${CWD}/valid.sh`, 'if true; then echo ok; fi\n')
  await fs.writeFile(`${CWD}/bad.sh`, 'if true; then\n')
  await fs.writeFile(`${CWD}/side-effect.sh`, 'echo wrote > side-effect.txt\n')
  await fs.writeFile(`${CWD}/missing-command.sh`, '#!/bin/sh\npdsh-not-a-worker-program\n')
  await fs.mkdir(`${CWD}/dir`, { recursive: true })
  await fs.writeFile(`${CWD}/dir/a.txt`, 'a\n')
  await fs.writeFile(`${CWD}/dir/b.txt`, 'b\n')
  return { fs, shell: new WorkerShell({ fs }) }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

test('bash/sh script invocation runs the same script as the shebang path', async () => {
  const { shell } = await fixture()
  // The reference: `./helper.sh` through the interpreter's shebang execution.
  const shebang = await shell.run(['./helper.sh', 'alpha', 'beta'], { cwd: CWD })
  assert.equal(shebang.exitCode, 3)
  assert.equal(
    shebang.stdout,
    'argv0=/dsh/workspace/helper.sh\n'
      + 'source0=/dsh/workspace/helper.sh\n'
      + 'source=/dsh/workspace/helper.sh\n'
      + 'sources-at=/dsh/workspace/helper.sh\n'
      + 'sources-star=/dsh/workspace/helper.sh\n'
      + 'fn-source=/dsh/workspace/helper.sh\n'
      + 'first=alpha second=beta\n'
      + 'count=2\n'
      + 'all=alpha beta\n',
  )

  for (const argv of [
    ['bash', 'helper.sh', 'alpha', 'beta'],
    ['sh', 'helper.sh', 'alpha', 'beta'],
    ['/bin/bash', 'helper.sh', 'alpha', 'beta'],
    ['/bin/sh', 'helper.sh', 'alpha', 'beta'],
    ['/usr/bin/bash', 'helper.sh', 'alpha', 'beta'],
    ['bash', '--', 'helper.sh', 'alpha', 'beta'],
  ]) {
    const result = await shell.run(argv, { cwd: CWD })
    assert.equal(result.exitCode, shebang.exitCode, `${argv.join(' ')} status`)
    assert.equal(result.stdout, shebang.stdout, `${argv.join(' ')} stdout (incl. $0 and positionals)`)
    assert.equal(result.stderr, '')
    assert.equal(result.missingProgram, undefined)
  }

  // The same form inside a `bash -c` step: the registered command takes the
  // top-level path instead of the bundled command's nested interpreter.
  const nested = await shell.run(['bash', '-c', 'bash helper.sh alpha beta'], { cwd: CWD })
  assert.equal(nested.exitCode, shebang.exitCode)
  assert.equal(nested.stdout, shebang.stdout)
})

test('BASH_SOURCE stays unset for bash -c, like GNU top level', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'printf "[%s]\\n" "${BASH_SOURCE[0]}"'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '[]\n')
  assert.equal(result.stderr, '')
})

test('bash -c binds $0/$1... from the operands after the command string', async () => {
  const { shell } = await fixture()
  const shape = 'printf "0=%s 1=%s n=%s\\n" "$0" "$1" "$#"'
  for (const argv of [
    ['bash', '-c', shape, '_', 'ARG'],
    ['/bin/bash', '-c', shape, '_', 'ARG'],
    ['sh', '-c', shape, '_', 'ARG'],
    ['bash', '-c', shape, 'custom', 'one', 'two'],
  ]) {
    const result = await shell.run(argv, { cwd: CWD })
    assert.equal(result.exitCode, 0, argv.join(' '))
    const expected = argv[3] === 'custom'
      ? '0=custom 1=one n=2\n'
      : '0=_ 1=ARG n=1\n'
    assert.equal(result.stdout, expected, argv.join(' '))
    assert.equal(result.stderr, '')
  }
  // With no operand, $0 is the shell name and there are no positionals.
  const bare = await shell.run(['bash', '-c', shape], { cwd: CWD })
  assert.equal(bare.stdout, '0=bash 1= n=0\n')
  const bareSh = await shell.run(['sh', '-c', shape], { cwd: CWD })
  assert.equal(bareSh.stdout, '0=sh 1= n=0\n')
})

test('find -exec sh -c receives {} as $1 for both ; and +', async () => {
  const { shell } = await fixture()
  const semicolon = await shell.run([
    'bash',
    '-c',
    "find dir -type f -exec sh -c 'echo \"arg=$1\"' _ {} \\; | sort",
  ], { cwd: CWD })
  assert.equal(semicolon.exitCode, 0, semicolon.stderr)
  assert.equal(semicolon.stdout, 'arg=dir/a.txt\narg=dir/b.txt\n')

  const plus = await shell.run([
    'bash',
    '-c',
    "find dir -type f -exec sh -c 'printf \"arg=%s\\n\" \"$@\"' _ {} + | sort",
  ], { cwd: CWD })
  assert.equal(plus.exitCode, 0, plus.stderr)
  assert.equal(plus.stdout, 'arg=dir/a.txt\narg=dir/b.txt\n')
})

test('bash -n parses without executing: 0 valid, 2 syntax error', async () => {
  const { fs, shell } = await fixture()
  const valid = await shell.run(['bash', '-n', 'valid.sh'], { cwd: CWD })
  assert.equal(valid.exitCode, 0)
  assert.equal(valid.stdout, '')
  assert.equal(valid.stderr, '')

  const bad = await shell.run(['bash', '-n', 'bad.sh'], { cwd: CWD })
  assert.equal(bad.exitCode, 2)
  assert.match(bad.stderr, /(?:syntax|parse) error/iu)
  assert.doesNotMatch(bad.stderr, /No such file or directory/u)

  const sideEffect = await shell.run(['bash', '-n', 'side-effect.sh'], { cwd: CWD })
  assert.equal(sideEffect.exitCode, 0)
  assert.equal(await fs.exists(`${CWD}/side-effect.txt`), false, '-n must not execute the script')

  // Combined short flags: -nc is a syntax check of the -c string.
  assert.equal((await shell.run(['bash', '-nc', 'if true; then echo ok; fi'], { cwd: CWD })).exitCode, 0)
  assert.equal((await shell.run(['bash', '-nc', 'if true; then'], { cwd: CWD })).exitCode, 2)
  // GNU reads the command string from the first non-option word: options after
  // -c are options, not the command, and `--` ends the option prefix.
  const optionAfterC = await shell.run(['bash', '-c', '-n', 'echo must-not-run'], { cwd: CWD })
  assert.equal(optionAfterC.exitCode, 0)
  assert.equal(optionAfterC.stdout, '')
  const terminator = await shell.run(['bash', '-c', '--', 'echo executed'], { cwd: CWD })
  assert.equal(terminator.exitCode, 0)
  assert.equal(terminator.stdout, 'executed\n')
})

test('bash -e/-u/-x options reach the engine set semantics', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile(`${CWD}/strict.sh`, 'echo before\nfalse\necho after\n')

  // -e: the engine's own errexit aborts the -c string and the script file.
  const errexit = await shell.run(['bash', '-e', '-c', 'echo one; false; echo two'], { cwd: CWD })
  assert.equal(errexit.exitCode, 1)
  assert.equal(errexit.stdout, 'one\n')
  const errexitScript = await shell.run(['bash', '-e', 'strict.sh'], { cwd: CWD })
  assert.equal(errexitScript.exitCode, 1)
  assert.equal(errexitScript.stdout, 'before\n')

  // -u: an unset expansion is fatal, not an empty string.
  const nounset = await shell.run(['bash', '-u', '-c', 'printf "[%s]\\n" "$PDSH_UNSET_FOR_NOUNSET"'], { cwd: CWD })
  assert.notEqual(nounset.exitCode, 0)
  assert.equal(nounset.stdout, '')
  assert.match(nounset.stderr, /unbound variable/iu)

  // -x: xtrace goes to stderr and does not change stdout or status.
  const xtrace = await shell.run(['bash', '-x', '-c', 'echo traced'], { cwd: CWD })
  assert.equal(xtrace.exitCode, 0)
  assert.equal(xtrace.stdout, 'traced\n')
  assert.match(xtrace.stderr, /\+ echo traced/u)

  // Clustered flags compose, and -c still consumes the next word as the script.
  const combo = await shell.run(['bash', '-eux', '-c', 'echo combo'], { cwd: CWD })
  assert.equal(combo.exitCode, 0)
  assert.equal(combo.stdout, 'combo\n')
  assert.match(combo.stderr, /\+ echo combo/u)

  // -n still parses only: -ne must not run the script or apply tracing.
  const noexec = await shell.run(['bash', '-ne', 'side-effect.sh'], { cwd: CWD })
  assert.equal(noexec.exitCode, 0)
  assert.equal(noexec.stdout, '')
  assert.equal(noexec.stderr, '')
  assert.equal(await fs.exists(`${CWD}/side-effect.txt`), false)
})

test('bash --version prints one version line matching $BASH_VERSION', async () => {
  const { shell } = await fixture()
  const version = await shell.run(['bash', '--version'], { cwd: CWD })
  assert.equal(version.exitCode, 0)
  assert.equal(version.stderr, '')
  assert.equal(version.stdout.trimEnd().split('\n').length, 1)
  // The line cannot drift from the engine's own emulated release.
  const engine = await shell.run(['bash', '-c', 'printf %s "$BASH_VERSION"'], { cwd: CWD })
  assert.match(engine.stdout, /^\d+\.\d+/u)
  assert.ok(version.stdout.includes(engine.stdout), `${version.stdout} should name ${engine.stdout}`)
  const sh = await shell.run(['sh', '--version'], { cwd: CWD })
  assert.equal(sh.exitCode, 0)
  assert.match(sh.stdout, /^sh \d+\./u)
})

test('an option this layer does not implement fails loud and is never a filename', async () => {
  const { shell } = await fixture()
  for (const argv of [
    ['bash', '-Q', 'valid.sh'],
    ['bash', '-Z', 'valid.sh'],
    ['bash', '--posix', 'valid.sh'],
    ['bash', '-c'],
    ['sh', '-Z', 'valid.sh'],
  ]) {
    const result = await shell.run(argv, { cwd: CWD })
    assert.equal(result.exitCode, 2, `${argv.join(' ')} status`)
    assert.match(result.stderr, /usage:/iu, `${argv.join(' ')} names the usage`)
    assert.match(result.stderr, /reason=unsupported-option/u)
    assert.doesNotMatch(result.stderr, /No such file or directory/u)
  }
})

test('a script failure is a command result, not a spawn failure', async () => {
  const { shell } = await fixture()
  const missing = await shell.run(['bash', 'missing.sh'], { cwd: CWD })
  assert.equal(missing.exitCode, 127)
  assert.match(missing.stderr, /missing\.sh: No such file or directory/u)
  // A missing *command inside* the script must not be reported as a failed
  // spawn of `bash` (subprocess-xl turns that field into a spawn ENOENT).
  const inner = await shell.run(['bash', 'missing-command.sh'], { cwd: CWD })
  assert.equal(inner.exitCode, 127)
  assert.equal(inner.missingProgram, undefined)
  assert.match(inner.stderr, /program=pdsh-not-a-worker-program/u)
})
