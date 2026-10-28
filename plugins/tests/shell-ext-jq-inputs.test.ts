// SPDX-License-Identifier: MIT
/**
 * G2-FIX-130: jq's input-consumption family.
 *
 * The pinned just-bash 3.6.0 `jq` built-in does not implement `inputs` or
 * `input` (both exit 3 with `Unknown function: ...`) and its
 * `input_line_number` is a constant `1`. This suite keeps that pre-fix
 * behaviour visible on an unshadowed `Bash`, then drives the Worker `jq` shim
 * through the production `createWorkerCommands` table for the common NDJSON,
 * file and stdin shapes. It also pins the direct-argv route to the same shim as
 * `bash -c`, so the two dispatch forms cannot disagree.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Bash } from 'just-bash/browser'
import {
  JQ_INPUT_FUNCTIONS,
  VfsFileSystem,
  WORKER_SHELL_PROGRAMS,
  WorkerShell,
  createWorkerCommands,
  findUnsafeInputConsumption,
  findUnsafeInputsValueArgument,
  isWorkerShellProgram,
  parseJqInvocation,
  planJqShim,
  rewriteJqInputFunctions,
  scanJqInputReferences,
  workerShellIdentity,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

interface Fixture {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/** A production-table Worker shell with the jq input fixtures. */
async function fixture(): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-inputs-'))
  roots.push(root)
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root })
  await fs.writeFile(`${CWD}/a.json`, '{"a":1}\n{"a":2}\n')
  await fs.writeFile(`${CWD}/b.json`, '{"a":3}\n')
  await fs.writeFile(`${CWD}/nums.json`, '1\n2\n3\n4\n')
  await fs.writeFile(`${CWD}/nums3.json`, '1\n2\n3\n')
  await fs.writeFile(`${CWD}/one.json`, '1\n')
  await fs.writeFile(`${CWD}/two.json`, '1\n2\n')
  await fs.writeFile(`${CWD}/strings.json`, '"aaaa"\n"x"\n"y"\n"z"\n')
  await fs.writeFile(`${CWD}/lines.json`, '{"a":1}\n{"a":2}\n{"a":3}\n')
  await fs.writeFile(`${CWD}/multi.json`, '{\n"a":1\n}\n{\n"a":2\n}\n')
  await fs.writeFile(`${CWD}/bare.json`, '1\n2')
  await fs.writeFile(`${CWD}/leading.json`, '\n\n1\n2')
  await fs.writeFile(`${CWD}/boundary-empty.json`, '\n\n1')
  await fs.writeFile(`${CWD}/blank-between.json`, '1\n\n2')
  await fs.writeFile(`${CWD}/multi-bare.json`, '{\n"a":1\n}')
  await fs.writeFile(`${CWD}/empty.json`, '')
  await fs.writeFile(`${CWD}/--help`, '7\n8\n')
  await fs.writeFile(`${CWD}/fields.json`, '{"inputs":5}\n{"input_line_number":7}\n')
  await fs.writeFile(`${CWD}/keys.json`, '{"x":1}\n"x"\n"y"\n')
  await fs.writeFile(`${CWD}/patterns.json`, '"x"\n"x"\n"y"\n')
  await fs.writeFile(`${CWD}/index.json`, '[10,20]\n0\n[30,40]\n1\n')
  await fs.writeFile(`${CWD}/bad.json`, '{\n')
  await fs.writeFile(`${CWD}/merge-a.json`, '1')
  await fs.writeFile(`${CWD}/merge-b.json`, '2\n')
  await fs.writeFile(`${CWD}/primitive-literal.json`, 'true')
  await fs.writeFile(`${CWD}/primitive-object.json`, '{"a":2}\n')
  await fs.writeFile(`${CWD}/primitive-array.json`, '[2]\n')
  await fs.writeFile(`${CWD}/primitive-string.json`, '"s"\n')
  await fs.writeFile(`${CWD}/overflow.json`, '1e400\n[1e400]\n')
  await fs.writeFile(`${CWD}/line-a.json`, '1\n2\n')
  await fs.writeFile(`${CWD}/line-b.json`, '3\n4\n')
  await fs.writeFile(`${CWD}/blank-start.json`, '\n2\n')
  await fs.writeFile(`${CWD}/nums3-noLF.json`, '1\n2\n3')
  await fs.writeFile(`${CWD}/spaces.json`, '  \t')
  await fs.writeFile(`${CWD}/bom-only.json`, '\uFEFF')
  await fs.writeFile(`${CWD}/fields-def.json`, '{"def":5}\n{"def":6}\n')
  await fs.writeFile(`${CWD}/unicode.json`, '{"é":"✓"}\n"漢字"\n')
  // jq 1.6 skips one BOM only at the very start of the concatenated stream,
  // but its three bytes still count for input_line_number and source offsets.
  await fs.writeFile(`${CWD}/bom-blank.json`, '\uFEFF\n\n1\n')
  await fs.writeFile(`${CWD}/bom-a.json`, '\uFEFF1\n')
  await fs.writeFile(`${CWD}/bom-b.json`, '\n\n2\n')
  await fs.writeFile(`${CWD}/bom-ascii-4089.json`, `\uFEFF"${'a'.repeat(4089)}"\n1\n`)
  await fs.writeFile(`${CWD}/bom-ascii-4090.json`, `\uFEFF"${'a'.repeat(4090)}"\n1\n`)
  await fs.writeFile(`${CWD}/bom-multi-2044.json`, `\uFEFF"${'é'.repeat(2044)}"\n1\n`)
  await fs.writeFile(`${CWD}/bom-multi-2045.json`, `\uFEFF"${'é'.repeat(2045)}"\n1\n`)
  await fs.writeFile(`${CWD}/bom-later.json`, '\n\uFEFF2\n')
  await fs.writeFile(`${CWD}/bom-merge-a.json`, '\uFEFF1')
  await fs.writeFile(`${CWD}/bom-merge-b.json`, '2\n')
  // jq joins operands as one byte stream. The two operands below are the two
  // halves of e-acute: concatenated they are valid UTF-8 `"é"`.
  await fs.writeFile(`${CWD}/split-a.json`, new Uint8Array([0x22, 0xc3]))
  await fs.writeFile(`${CWD}/split-b.json`, new Uint8Array([0xa9, 0x22, 0x0a]))
  await fs.writeFile(`${CWD}/invalid-utf8.json`, new Uint8Array([0x22, 0xff, 0x22, 0x0a]))
  // jq reads with fgets(buf, 4096): a value that ends exactly at the 4095-byte
  // read boundary does not yet see the following newline. Multi-byte
  // characters move that newline in bytes, not in JavaScript characters.
  await fs.writeFile(`${CWD}/ascii-4092.json`, `"${'a'.repeat(4092)}"\n1\n`)
  await fs.writeFile(`${CWD}/ascii-4093.json`, `"${'a'.repeat(4093)}"\n1\n`)
  await fs.writeFile(`${CWD}/multi-4094.json`, `"${'é'.repeat(4094)}"\n1\n`)
  await fs.writeFile(`${CWD}/multi-later.json`, `"${'é'.repeat(4094)}"\n2\n`)
  await fs.writeFile(`${CWD}/one-no-newline.json`, '1')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell }
}

test('jq baseline: the unshadowed built-in has no inputs/input and a constant line number', async () => {
  const bash = new Bash({ cwd: CWD })
  const write = await bash.exec(`printf '{"a":1}\\n{"a":2}\\n' > a.json`)
  assert.equal(write.exitCode, 0, write.stderr)
  const inputs = await bash.exec(`jq -n '[inputs]' a.json`)
  assert.equal(inputs.exitCode, 3)
  assert.equal(inputs.stdout, '')
  assert.match(inputs.stderr, /Unknown function: inputs/u)
  const input = await bash.exec(`jq -n 'input' a.json`)
  assert.equal(input.exitCode, 3)
  assert.match(input.stderr, /Unknown function: input/u)
  const line = await bash.exec(`jq 'input_line_number' a.json`)
  assert.equal(line.exitCode, 0, line.stderr)
  assert.equal(line.stdout, '1\n1\n')
})

test('jq: the production table registers the shim for bash -c and direct argv', async () => {
  assert.ok(WORKER_SHELL_PROGRAMS.includes('jq'), 'jq must be in WORKER_SHELL_PROGRAMS')
  assert.equal(isWorkerShellProgram('jq'), true, 'a direct spawn(["jq", ...]) must route through the Worker shell table')
  assert.equal(workerShellIdentity('/usr/bin/jq'), 'jq')
  assert.ok(
    createWorkerCommands({ git: false, toolbox: false, curl: false }).some(command => command.name === 'jq'),
    'the production command table must carry the jq shim',
  )
  const { shell } = await fixture()
  const located = await shell.run(['bash', '-c', 'p=$(command -v jq) && test -n "$p" && test -x "$p" && echo "$p"'], { cwd: CWD })
  assert.equal(located.exitCode, 0, located.stderr)
  assert.match(located.stdout, /^\/usr\/bin\/jq\n$/u)
})

test('jq: -n inputs reads every document from two file operands', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq -n '[inputs]' a.json b.json`], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '[\n  {\n    "a": 1\n  },\n  {\n    "a": 2\n  },\n  {\n    "a": 3\n  }\n]\n')
})

test('jq: file operands form one continuous stream at a missing newline boundary', async () => {
  const { shell } = await fixture()
  // jq 1.6 does not insert a separator between operands: `1` followed by
  // `2\n` is one document, 12, not two documents.
  const merged = await shell.run(
    ['bash', '-c', `jq -n -c '[inputs]' merge-a.json merge-b.json`],
    { cwd: CWD },
  )
  assert.equal(merged.exitCode, 0, merged.stderr)
  assert.equal(merged.stdout, '[12]\n')
  const line = await shell.run(
    ['bash', '-c', `jq -c 'input_line_number' merge-a.json merge-b.json`],
    { cwd: CWD },
  )
  assert.equal(line.exitCode, 0, line.stderr)
  assert.equal(line.stdout, '1\n', 'the merged token ends in the second source, whose first line is terminated')
})

test('jq: a primitive at a file boundary does not swallow the next document opener', async () => {
  const { shell } = await fixture()
  // jq 1.6's lexer terminates a number/literal as soon as the next byte cannot
  // continue the token. A primitive at the end of one operand (no trailing
  // newline) followed by an object, array or string in the next operand is two
  // documents; only a continuation such as `1` + `2` stays one number.
  const cases: readonly { readonly files: string; readonly stdout: string }[] = [
    { files: 'merge-a.json primitive-object.json', stdout: '[1,{"a":2}]\n' },
    { files: 'merge-a.json primitive-array.json', stdout: '[1,[2]]\n' },
    { files: 'merge-a.json primitive-string.json', stdout: '[1,"s"]\n' },
    { files: 'primitive-literal.json primitive-object.json', stdout: '[true,{"a":2}]\n' },
  ]
  for (const entry of cases) {
    const result = await shell.run(
      ['bash', '-c', `jq -n -c '[inputs]' ${entry.files}`],
      { cwd: CWD },
    )
    assert.equal(result.exitCode, 0, `${entry.files}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.files}: ${result.stderr}`)
  }
  // The same lexer boundary inside one stream: `1[2]` is `1` then `[2]`. The
  // input-family path parses the stream itself, while a non-input filter
  // delegates and pins the built-in path too.
  const singleShim = await shell.run(['bash', '-c', `printf '1[2]' | jq -n -c '[inputs]'`], { cwd: CWD })
  assert.equal(singleShim.exitCode, 0, singleShim.stderr)
  assert.equal(singleShim.stdout, '[1,[2]]\n')
  const single = await shell.run(['bash', '-c', `printf '1[2]' | jq -c '.'`], { cwd: CWD })
  assert.equal(single.exitCode, 0, single.stderr)
  assert.equal(single.stdout, '1\n[2]\n')
})

test('jq: input_line_number resets per file operand and follows boundary lookahead', async () => {
  const { shell } = await fixture()
  const reset = await shell.run(
    ['bash', '-c', `jq -c 'input_line_number' line-a.json line-b.json`],
    { cwd: CWD },
  )
  assert.equal(reset.exitCode, 0, reset.stderr)
  assert.equal(reset.stdout, '1\n2\n1\n2\n')
  // The first document ends at the first file's EOF without a newline, so jq
  // reads the next source to terminate the number; the second file's first
  // line is blank, making the reported line 1.
  const lookahead = await shell.run(
    ['bash', '-c', `jq -c 'input_line_number' merge-a.json blank-start.json`],
    { cwd: CWD },
  )
  assert.equal(lookahead.exitCode, 0, lookahead.stderr)
  assert.equal(lookahead.stdout, '1\n2\n')
})

test('jq: -n inputs emits each remaining document', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq -n 'inputs' a.json b.json`], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '{\n  "a": 1\n}\n{\n  "a": 2\n}\n{\n  "a": 3\n}\n')
})

test('jq: -n inputs reads the pipeline stdin', async () => {
  const { shell } = await fixture()
  const result = await shell.run(
    ['bash', '-c', `printf '{"a":1}\\n{"a":2}\\n' | jq -n '[inputs]'`],
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '[\n  {\n    "a": 1\n  },\n  {\n    "a": 2\n  }\n]\n')
})

test('jq: input consumes the next document and advances the outer cursor by two', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq 'input' nums.json`], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '2\n4\n')
})

test('jq: input at EOF reports the real source and native no-newline position', async () => {
  const { shell } = await fixture()
  const odd = await shell.run(['bash', '-c', `jq 'input' nums3.json`], { cwd: CWD })
  assert.equal(odd.exitCode, 5, odd.stderr)
  assert.equal(odd.stdout, '2\n')
  assert.match(odd.stderr, /jq: error \(at nums3\.json:3\): break/u)
  const nullInput = await shell.run(['bash', '-c', `jq -n 'input' empty.json`], { cwd: CWD })
  assert.equal(nullInput.exitCode, 5, nullInput.stderr)
  assert.equal(nullInput.stdout, '')
  assert.match(nullInput.stderr, /jq: error \(at empty\.json:0\): break/u)
  const stdin = await shell.run(['bash', '-c', `printf '' | jq -n 'input'`], { cwd: CWD })
  assert.equal(stdin.exitCode, 5, stdin.stderr)
  assert.equal(stdin.stdout, '')
  assert.match(stdin.stderr, /jq: error \(at <stdin>:0\): break/u)
  // EOF line attribution is raw-byte based: horizontal whitespace without LF
  // keeps stdin open at line 0 for space, tab and carriage return.
  for (const whitespace of [' ', '\t', '\r']) {
    const whitespaceStdin = await shell.run(
      ['jq', '-n', 'input'],
      { cwd: CWD, stdin: whitespace },
    )
    assert.equal(whitespaceStdin.exitCode, 5, whitespaceStdin.stderr)
    assert.equal(whitespaceStdin.stdout, '')
    assert.match(whitespaceStdin.stderr, /jq: error \(at <stdin>:0\): break/u)
  }
  // jq keeps stdin open while the reading is newline-terminated, but a final
  // primitive without a delimiter has already closed the source: <unknown>,
  // not a fabricated <stdin> label.
  const stdinNoLF = await shell.run(['bash', '-c', `printf '1\n2\n3' | jq 'input'`], { cwd: CWD })
  assert.equal(stdinNoLF.exitCode, 5, stdinNoLF.stderr)
  assert.equal(stdinNoLF.stdout, '2\n')
  assert.match(stdinNoLF.stderr, /jq: error \(at <unknown>\): break/u)
  const fileNoLF = await shell.run(['bash', '-c', `jq 'input' nums3-noLF.json`], { cwd: CWD })
  assert.equal(fileNoLF.exitCode, 5, fileNoLF.stderr)
  assert.equal(fileNoLF.stdout, '2\n')
  assert.match(fileNoLF.stderr, /jq: error \(at <unknown>\): break/u)
})

test('jq: EOF break attribution keeps final horizontal-whitespace operand', async () => {
  const { shell } = await fixture()
  const trailingWhitespace = await shell.run(
    ['jq', '-c', 'input', 'nums3.json', 'spaces.json'],
    { cwd: CWD },
  )
  assert.equal(trailingWhitespace.exitCode, 5, trailingWhitespace.stderr)
  assert.equal(trailingWhitespace.stdout, '2\n')
  assert.match(trailingWhitespace.stderr, /jq: error \(at spaces\.json:0\): break/u)
})

test('jq: EOF break attribution keeps a final BOM-only operand', async () => {
  const { shell } = await fixture()
  const bomOnly = await shell.run(['jq', '-n', 'input', 'bom-only.json'], { cwd: CWD })
  assert.equal(bomOnly.exitCode, 5, bomOnly.stderr)
  assert.equal(bomOnly.stdout, '')
  assert.match(bomOnly.stderr, /jq: error \(at bom-only\.json:0\): break/u)
})

test('jq: input_line_number reports each one-line document line', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq 'input_line_number' lines.json`], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '1\n2\n3\n')
})

test('jq: input_line_number reports the line where a multi-line document ends', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq 'input_line_number' multi.json`], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '3\n6\n')
})

test('jq: input_line_number follows jq 1.6 line counting at EOF boundaries', async () => {
  const { shell } = await fixture()
  const cases: readonly { readonly file: string; readonly stdout: string }[] = [
    // `1\n2`: the first document's line is newline-terminated (1); the last
    // document's line runs to EOF without a newline, so it reports one less
    // than its end line (1).
    { file: 'bare.json', stdout: '1\n1\n' },
    // Two leading blank lines are counted before the documents, which both
    // occupy line 3; that line is newline-terminated, so both report 3.
    { file: 'leading.json', stdout: '3\n3\n' },
    // A blank line between documents is counted, so the second document is on
    // line 3; its line has no trailing newline, so it reports 2.
    { file: 'blank-between.json', stdout: '1\n2\n' },
    // Multi-line document without a trailing newline: the two internal
    // newlines are counted but the last line is not, so it reports 2.
    { file: 'multi-bare.json', stdout: '2\n' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['bash', '-c', `jq 'input_line_number' ${entry.file}`], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${entry.file}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.file}: ${result.stderr}`)
  }
  // A trailing empty operand must not be skipped: the primitive still ends at
  // the first source's EOF without a newline, and opening the empty second
  // source resets the counter to 0 (native jq 1.6 prints 1,0).
  const emptyLater = await shell.run(
    ['bash', '-c', `jq -c 'input_line_number' bare.json empty.json`],
    { cwd: CWD },
  )
  assert.equal(emptyLater.exitCode, 0, emptyLater.stderr)
  assert.equal(emptyLater.stdout, '1\n0\n')
  const single = await shell.run(['bash', '-c', `printf '1' | jq -c 'input_line_number'`], { cwd: CWD })
  assert.equal(single.exitCode, 0, single.stderr)
  assert.equal(single.stdout, '0\n', 'a one-line document with no trailing newline reports 0')
})

test('jq: input functions inside string interpolation are scanned and evaluated', async () => {
  const { shell } = await fixture()
  const run = async (
    filter: string,
    rest = '',
    files = '',
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> =>
    shell.run(
      ['bash', '-c', `jq ${rest}'${filter}'${files === '' ? '' : ` ${files}`}`],
      { cwd: CWD },
    )
  const nullLine = await run(String.raw`"\(input_line_number)"`, '-n ')
  assert.equal(nullLine.exitCode, 0, nullLine.stderr)
  assert.equal(nullLine.stdout, '"0"\n')
  const lines = await run(String.raw`"\(input_line_number)"`, '', 'lines.json')
  assert.equal(lines.exitCode, 0, lines.stderr)
  assert.equal(lines.stdout, '"1"\n"2"\n"3"\n')
  const inputs = await run(String.raw`"\(inputs)"`, '-n ', 'nums.json')
  assert.equal(inputs.exitCode, 0, inputs.stderr)
  assert.equal(inputs.stdout, '"1"\n"2"\n"3"\n"4"\n')
  const input = await run(String.raw`"\(input)"`, '-n ', 'nums.json')
  assert.equal(input.exitCode, 0, input.stderr)
  assert.equal(input.stdout, '"1"\n')
  const prefix = await run(String.raw`"prefix \(inputs)"`, '-n -c ', 'nums.json')
  assert.equal(prefix.exitCode, 0, prefix.stderr)
  assert.equal(prefix.stdout, '"prefix 1"\n"prefix 2"\n"prefix 3"\n"prefix 4"\n')
  // `inputs` in anything other than the whole interpolation body cannot be
  // lifted without changing generator semantics (the built-in joins multiple
  // body values into one string), so it fails loud instead.
  for (const filter of [
    String.raw`"\(inputs | length)"`,
    String.raw`"\( "\(inputs)" )"`,
    String.raw`"\(inputs, 1)"`,
  ]) {
    const rejected = await run(filter, '-n -c ')
    assert.equal(rejected.exitCode, 2, `${filter}: ${rejected.stderr}`)
    assert.equal(rejected.stdout, '', filter)
    assert.match(rejected.stderr, /inputs inside a string interpolation/u, filter)
  }
  // A literal `\\(` is not an interpolation; the scanner leaves it alone (the
  // pinned built-in's own string parser is responsible for that literal).
})

test('jq: multi-value input interpolation fails loud instead of concatenating', async () => {
  const { shell } = await fixture()
  for (const filter of [
    '"\\(input,1)"',
    '"\\(input_line_number,1)"',
    '"\\(input) \\(1,2)"',
    '"\\( "\\(input)" )"',
  ]) {
    const result = await shell.run(['bash', '-c', 'jq -n -c ' + "'" + filter + "' nums.json"], { cwd: CWD })
    assert.equal(result.exitCode, 2, filter + ': ' + result.stderr)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /interpolation is supported only/u, filter)
  }
})

test('jq: parse errors use exit 4 and -n input_line_number ignores file operands', async () => {
  const { shell } = await fixture()
  const malformed = await shell.run(
    ['bash', '-c', "jq -c input_line_number bad.json"],
    { cwd: CWD },
  )
  assert.equal(malformed.exitCode, 4, malformed.stderr)
  assert.match(malformed.stderr, /parse error/u)

  const missing = await shell.run(
    ['bash', '-c', "jq -n -c input_line_number missing.json"],
    { cwd: CWD },
  )
  assert.equal(missing.exitCode, 0, missing.stderr)
  assert.equal(missing.stdout, '0\n')

  const ignoredMalformed = await shell.run(
    ['bash', '-c', "jq -n -c input_line_number bad.json"],
    { cwd: CWD },
  )
  assert.equal(ignoredMalformed.exitCode, 0, ignoredMalformed.stderr)
  assert.equal(ignoredMalformed.stdout, '0\n')
})

test('jq: comments do not hide a following input function', async () => {
  const { shell } = await fixture()
  const run = async (
    filter: string,
    rest: string,
    files: string,
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> =>
    shell.run(['bash', '-c', `jq ${rest}'${filter}' ${files}`], { cwd: CWD })
  const cases = [
    // A comment ending in `.` used to look like a field access to the old
    // backward scan, so the next line delegated to the unshadowed built-in.
    { filter: '# Read the line.\ninput_line_number', rest: '', files: 'lines.json', stdout: '1\n2\n3\n' },
    // A comment ending in `def` used to look like a definition name.
    { filter: '# Read the rest.\ninputs', rest: '-n -c ', files: 'nums.json', stdout: '1\n2\n3\n4\n' },
    { filter: '# do not def\ninputs', rest: '-n -c ', files: 'nums.json', stdout: '1\n2\n3\n4\n' },
    // A comment ending in `$` or `@` used to look like a variable/format.
    { filter: '# cost $\ninput', rest: '-n -c ', files: 'nums.json', stdout: '1\n' },
    { filter: '# format @\ninput_line_number', rest: '-n -c ', files: 'nums.json', stdout: '0\n' },
  ]
  for (const entry of cases) {
    const result = await run(entry.filter, entry.rest, entry.files)
    assert.equal(result.exitCode, 0, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.filter}: ${result.stderr}`)
  }
})

test('jq: inputs interpolation is lifted only when it is the sole interpolation and not a format string', async () => {
  const { shell } = await fixture()
  const run = async (
    filter: string,
    rest: string,
    files: string,
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> =>
    shell.run(['bash', '-c', `jq ${rest}'${filter}' ${files}`], { cwd: CWD })
  // Lifting `\(inputs)` to `($pdsh_inputs[] | "...")` rebinds every other `.`
  // in the string to the input document, and a parenthesized generator is not
  // a valid @format string. Both cases must fail loud instead of changing the
  // value or producing null/empty output.
  for (const [filter, files] of [
    [String.raw`"\(inputs) \(.a)"`, 'lines.json'],
    [String.raw`"\(inputs) \(1+1)"`, 'nums.json'],
    [String.raw`@json "\(inputs)"`, 'nums.json'],
    [String.raw`@text "\(inputs)"`, 'nums.json'],
  ] as const) {
    const rejected = await run(filter, '-n -c ', files)
    assert.equal(rejected.exitCode, 2, `${filter}: ${rejected.stderr}`)
    assert.equal(rejected.stdout, '', filter)
    assert.match(rejected.stderr, /inputs inside a string interpolation/u, filter)
  }
  const sole = await run(String.raw`"\(inputs)"`, '-n -c ', 'nums.json')
  assert.equal(sole.exitCode, 0, sole.stderr)
  assert.equal(sole.stdout, '"1"\n"2"\n"3"\n"4"\n')
})

test('jq: inputs as a function argument fails loud instead of keeping only the first value', async () => {
  const { shell } = await fixture()
  // jq 1.6 evaluates the argument filter once per value, so `has(inputs)` on
  // {"x":1}, "x", "y" prints true,false and `test(inputs)` on "x", "x", "y"
  // prints true,false. The built-in's argument evaluator reads only the first
  // generator value, which used to print just `true` at exit 0. A lifted
  // string interpolation in the same position had the same silent loss.
  const cases: readonly { readonly filter: string; readonly file: string }[] = [
    { filter: 'has(inputs)', file: 'keys.json' },
    { filter: 'test(inputs)', file: 'patterns.json' },
    { filter: 'split(inputs)', file: 'patterns.json' },
    { filter: String.raw`test("\(inputs)")`, file: 'strings.json' },
    { filter: String.raw`split("\(inputs)")`, file: 'strings.json' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', '-c', entry.filter, entry.file], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, /^jq: .*function argument/u, entry.filter)
  }
  // The argument-free lift keeps its one-string-per-document semantics.
  const lifted = await shell.run(
    ['jq', '-n', '-c', String.raw`"\(inputs)"`, 'nums.json'],
    { cwd: CWD },
  )
  assert.equal(lifted.exitCode, 0, lifted.stderr)
  assert.equal(lifted.stdout, '"1"\n"2"\n"3"\n"4"\n')
})

test('jq: a consuming input in a function argument is rejected conservatively', async () => {
  const { shell } = await fixture()
  // A function may evaluate its filter argument zero or more times, so a
  // single textual `input` rewrite cannot prove the cursor advance. These are
  // refused even where one particular builtin happens to evaluate the
  // argument once; `input_line_number` is informational and stays supported.
  const cases: readonly { readonly filter: string; readonly file: string }[] = [
    { filter: 'has(input)', file: 'keys.json' },
    { filter: 'test(input)', file: 'strings.json' },
    { filter: String.raw`test("\(input)")`, file: 'strings.json' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', '-c', entry.filter, entry.file], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, /^jq: .*function argument/u, entry.filter)
  }
  const lineArgument = await shell.run(
    ['jq', '-c', 'test(input_line_number | tostring)', 'strings.json'],
    { cwd: CWD },
  )
  assert.equal(lineArgument.exitCode, 0, lineArgument.stderr)
  assert.equal(lineArgument.stdout, 'false\nfalse\nfalse\nfalse\n')
})

test('jq: a comma sequence before input is rejected instead of losing emitted values', async () => {
  const { shell } = await fixture()
  for (const filter of ['., input', '1, input', '(1, input)', '1 | ., input']) {
    const result = await shell.run(['bash', '-c', `jq -c '${filter}' nums3.json`], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /comma sequence before input/u, filter)
  }
  const nullInput = await shell.run(['bash', '-c', `jq -n -c '1, input' empty.json`], { cwd: CWD })
  assert.equal(nullInput.exitCode, 2, nullInput.stderr)
  assert.equal(nullInput.stdout, '')
  assert.match(nullInput.stderr, /comma sequence before input/u)
  // Commas inside array/object constructors build the value before emitting
  // it, so a failing input emits no prefix and the wrapper stays exact.
  const array = await shell.run(['bash', '-c', `jq -c '[1, input]' nums3.json`], { cwd: CWD })
  assert.equal(array.exitCode, 5, array.stderr)
  assert.equal(array.stdout, '[1,2]\n')
  assert.match(array.stderr, /break/u)
})

test('jq: top-level and array comma positions still rewrite bare inputs', async () => {
  const { shell } = await fixture()
  const sequence = await shell.run(['bash', '-c', `jq -n -c '1, inputs, 2' nums.json`], { cwd: CWD })
  assert.equal(sequence.exitCode, 0, sequence.stderr)
  assert.equal(sequence.stdout, '1\n1\n2\n3\n4\n2\n')
  const array = await shell.run(['bash', '-c', `jq -n -c '[1, inputs, 2]' nums.json`], { cwd: CWD })
  assert.equal(array.exitCode, 0, array.stderr)
  assert.equal(array.stdout, '[1,1,2,3,4,2]\n')
  const once = await shell.run(['bash', '-c', `jq -n -c '[1, input, 2]' nums.json`], { cwd: CWD })
  assert.equal(once.exitCode, 0, once.stderr)
  assert.equal(once.stdout, '[1,1,2]\n')
  const leading = await shell.run(['bash', '-c', `jq -c 'input, 1' nums.json`], { cwd: CWD })
  assert.equal(leading.exitCode, 0, leading.stderr)
  assert.equal(leading.stdout, '2\n1\n4\n1\n')
  // A plain `as` binding does not repeat the consumption: the shim keeps it
  // supported and the bounded name validator leaves its scope unproven (but
  // still validates function names/arities).
  const bound = await shell.run(['bash', '-c', `jq -c 'input as $x | $x' nums.json`], { cwd: CWD })
  assert.equal(bound.exitCode, 0, bound.stderr)
  assert.equal(bound.stdout, '2\n4\n')
  const boundLine = await shell.run(
    ['bash', '-c', `jq -c '. as $x | $x, input_line_number' nums.json`],
    { cwd: CWD },
  )
  assert.equal(boundLine.exitCode, 0, boundLine.stderr)
  assert.equal(boundLine.stdout, '1\n1\n2\n2\n3\n3\n4\n4\n')
})

test('jq: as/label scopes still fail loud on variables no declaration covers', async () => {
  const { shell } = await fixture()
  // The built-in resolves an unknown variable lazily as null. A filter with an
  // unrelated `as`/`label` scope used to skip variable validation entirely and
  // then print null/null at exit 0; native jq 1.6 is a compile error.
  const cases: readonly { readonly filter: string; readonly file: string; readonly variable: string }[] = [
    { filter: 'input_line_number as $x | $undefined', file: 'nums.json', variable: 'undefined' },
    { filter: 'input_line_number | label $out | $undefined', file: 'nums.json', variable: 'undefined' },
    { filter: 'input as $v | $undefined', file: 'a.json', variable: 'undefined' },
    // The binding only covers the right-hand side of its own scope; a use
    // outside that scope must not be accepted from a global name set.
    { filter: '(input_line_number as $x | $x), $x', file: 'nums.json', variable: 'x' },
    { filter: '$x, (input_line_number as $x | $x)', file: 'nums.json', variable: 'x' },
    { filter: '(input_line_number as $x | $x), (1 as $y | $x)', file: 'nums.json', variable: 'x' },
    { filter: String.raw`input_line_number | ("\(1 as $x | $x)" | $x)`, file: 'nums.json', variable: 'x' },
    { filter: String.raw`input_line_number, "\(1 as $x | $x) \($x)"`, file: 'nums.json', variable: 'x' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', '-c', entry.filter, entry.file], { cwd: CWD })
    assert.notEqual(result.exitCode, 0, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, new RegExp(`variable '${entry.variable}'`, 'u'), entry.filter)
  }
  // Simple declarations and a label reference without `break` keep working.
  // Destructuring/alternative patterns and all input-family `break` filters
  // are refused because the shim cannot prove their value-preservation rules.
  const labelled = await shell.run(
    ['jq', '-c', 'label $out | input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(labelled.exitCode, 0, labelled.stderr)
  assert.equal(labelled.stdout, '1\n2\n')
  // A binding outside a string interpolation covers references inside it.
  const interpolated = await shell.run(
    ['jq', '-c', String.raw`input_line_number as $x | "\($x)"`, 'two.json'],
    { cwd: CWD },
  )
  assert.equal(interpolated.exitCode, 0, interpolated.stderr)
  assert.equal(interpolated.stdout, '"1"\n"2"\n')
  // Native jq 1.6 emits `2\n` for this input. The shim keeps that behavior
  // explicitly unsupported because its evaluator can lose output at break.
  const broken = await shell.run(
    ['jq', '-c', 'label $out | input_line_number | if . == 1 then break $out else . end', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(broken.exitCode, 2, broken.stderr)
  assert.equal(broken.stdout, '')
  assert.match(broken.stderr, /input-family label-break shape/u)
})

test('jq: unprovable as/label scopes and label value references fail loud', async () => {
  const { shell } = await fixture()
  // jq's `if`/`reduce`/`foreach` introduce lexical boundaries that are not
  // brackets. The shim does not model those boundaries, so a declaration that
  // appears after one is refused instead of leaking into the sibling branch.
  const scopeCases: readonly string[] = [
    'input_line_number | if . == 1 then 1 as $x | $x else $x end',
    'input_line_number | if . == 1 then . else 1 as $x | $x end',
    'input_line_number | reduce (0,1) as $x (0; . + $x), $x',
    'input_line_number | foreach (0,1) as $x (0; . + $x; $x), $x',
  ]
  for (const filter of scopeCases) {
    const result = await shell.run(['jq', '-c', filter, 'two.json'], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /cannot prove as\/label binding scope|if\/elif\/then\/else\/end pairing/u, filter)
  }
  // A label binds a break target, not a value. Native jq rejects these at
  // compile time; the built-in would otherwise resolve them to null.
  const labelCases: readonly string[] = [
    'input_line_number | label $x | $x',
    'input_line_number | label $x | [$x]',
    String.raw`input_line_number | label $x | "\($x)"`,
    'label $x | input_line_number | [$x]',
    // `break` needs a visible label, not an `as`/`--arg` binding.
    '1 as $x | break $x, input_line_number',
    'break $x, input_line_number',
  ]
  for (const filter of labelCases) {
    const result = await shell.run(['jq', '-c', filter, 'two.json'], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /label variable|visible label/u, filter)
  }
  // Destructuring and alternative patterns are not modelled. A partial scan
  // used to accept `{$x}` and then print nothing; native jq either indexes the
  // document or fails at runtime.
  const patternCases: readonly string[] = [
    'input_line_number | 1 as {$x} | $x',
    'input_line_number | 1 as [$x] | $x',
    'input_line_number | . as {$a} ?// {$a} | $a',
    'input as {a: $v} | $v',
  ]
  for (const filter of patternCases) {
    const result = await shell.run(['jq', '-c', filter, 'a.json'], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /cannot prove as\/label binding scope/u, filter)
  }
  // A simple `as` binding remains supported.
  const bound = await shell.run(['jq', '-c', 'input as $x | $x', 'nums.json'], { cwd: CWD })
  assert.equal(bound.exitCode, 0, bound.stderr)
  assert.equal(bound.stdout, '2\n4\n')
  // Native jq 1.6 emits `2\n` for the label-break filter, but the shim
  // explicitly declines all input-family break evaluation.
  const labelled = await shell.run(
    ['jq', '-c', 'label $out | input_line_number | if . == 1 then break $out else . end', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(labelled.exitCode, 2, labelled.stderr)
  assert.equal(labelled.stdout, '')
  assert.match(labelled.stderr, /input-family label-break shape/u)
})

test('jq: unsupported variables fail loud instead of exposing shim internals', async () => {
  const { shell } = await fixture()
  // The pinned built-in does not implement `$__loc__`; it used to be on the
  // whitelist and silently became null.
  const loc = await shell.run(['jq', '-c', 'input_line_number | $__loc__', 'two.json'], { cwd: CWD })
  assert.equal(loc.exitCode, 2, loc.stderr)
  assert.equal(loc.stdout, '')
  assert.match(loc.stderr, /variable '__loc__'/u)
  // `$ARGS.named` would expose the shim's injected --argjson state, so an
  // input-family filter that reads `$ARGS` fails loud. Native jq prints `{}`.
  for (const filter of ['input_line_number | $ARGS.named', '[inputs] | $ARGS.named']) {
    const args = await shell.run(['jq', '-c', filter, 'two.json'], { cwd: CWD })
    assert.equal(args.exitCode, 2, `${filter}: ${args.stderr}`)
    assert.equal(args.stdout, '', filter)
    assert.match(args.stderr, /cannot expose \$ARGS/u, filter)
  }
  // A filter binding to an internal name would silently replace the injected
  // document/line value, exactly like a user --arg; refuse it too.
  for (const filter of [
    '1 as $__pdsh_jq_line | input_line_number',
    'label $__pdsh_jq_line | input_line_number',
  ]) {
    const reserved = await shell.run(['jq', '-c', filter, 'two.json'], { cwd: CWD })
    assert.equal(reserved.exitCode, 2, `${filter}: ${reserved.stderr}`)
    assert.equal(reserved.stdout, '', filter)
    assert.match(reserved.stderr, /reserved for the Worker jq shim's internal state/u, filter)
  }
})

test('jq: object and index generators fail closed before input consumption', async () => {
  const { shell } = await fixture()
  const cases = [
    { filter: '{a:(1,2),b:inputs}', file: 'nums.json', diagnostic: /object constructor/u },
    { filter: '{a:(.[0,1]),b:input}', file: 'index.json', diagnostic: /object constructor/u },
    { filter: '{a:(.[0,1]),b:inputs}', file: 'index.json', diagnostic: /object constructor/u },
    { filter: '.[0,1] | input', file: 'index.json', diagnostic: /comma sequence feeding a pipe|index generator/u },
    { filter: '.[0,1] | inputs', file: 'index.json', diagnostic: /comma sequence feeding a pipe|index generator/u },
    { filter: '.[inputs:2]', file: 'index.json', diagnostic: /index expression/u },
    { filter: '[(1,2), inputs]', file: 'nums.json', diagnostic: /comma sequence/u },
  ] as const
  for (const entry of cases) {
    const result = await shell.run(
      ['bash', '-c', 'jq -c ' + "'" + entry.filter + "' " + entry.file],
      { cwd: CWD },
    )
    assert.equal(result.exitCode, 2, entry.filter + ': ' + result.stderr)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, entry.diagnostic, entry.filter)
  }
  // A single scalar consumption in a slice has a fixed cursor advance.
  const slice = await shell.run(['bash', '-c', "jq -c '.[input:2]' index.json"], { cwd: CWD })
  assert.equal(slice.exitCode, 0, slice.stderr)
  assert.equal(slice.stdout, '[10,20]\n[40]\n')
})

test('jq: conditional or lazy input consumption fails loud instead of dropping documents', async () => {
  const { shell } = await fixture()
  const cases: readonly { readonly filter: string; readonly diagnostic: RegExp }[] = [
    { filter: 'if . == 3 then input else . end', diagnostic: /'if'/u },
    { filter: 'select(. > 1) | inputs', diagnostic: /'select'/u },
    { filter: 'first(inputs)', diagnostic: /'first'/u },
    { filter: 'limit(1; inputs)', diagnostic: /'limit'/u },
    { filter: 'try input catch .', diagnostic: /'try'/u },
    { filter: 'input?', diagnostic: /optional operator/u },
    { filter: '.a // input', diagnostic: /alternative operator/u },
    { filter: '.[] | input', diagnostic: /iterator/u },
    { filter: '.[0], .[1] | input', diagnostic: /comma sequence/u },
    { filter: '1, 2 | input', diagnostic: /comma sequence/u },
    { filter: 'values | input', diagnostic: /'values'/u },
    { filter: 'paths | input', diagnostic: /'paths'/u },
  ]
  for (const entry of cases) {
    const result = await shell.run(['bash', '-c', `jq -c '${entry.filter}' nums.json`], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, /^jq: conditional or lazy input consumption is not supported/u, entry.filter)
    assert.match(result.stderr, entry.diagnostic, entry.filter)
  }
})

test('jq: sub/gsub replacement expressions that can re-evaluate input are rejected', async () => {
  const { shell } = await fixture()
  for (const filter of ['sub("a"; input)', 'sub("z"; input)', 'gsub("a"; input)']) {
    const result = await shell.run(['bash', '-c', `jq -c '${filter}' strings.json`], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /^jq: conditional or lazy input consumption is not supported/u, filter)
    assert.match(result.stderr, /'(?:sub|gsub)'/u, filter)
  }
})

test('jq: a comma generator feeding a pipe stays unsafe after a later comma', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', `jq -n -c '(1,2) | (., input)' nums.json`], { cwd: CWD })
  assert.equal(result.exitCode, 2, result.stderr)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /^jq: conditional or lazy input consumption is not supported/u)
  assert.match(result.stderr, /comma sequence/u)
})

test('jq: -e uses the last output across every outer document', async () => {
  const { shell } = await fixture()
  const truthyLast = await shell.run(['bash', '-c', `jq -e 'input_line_number > 1' two.json`], { cwd: CWD })
  assert.equal(truthyLast.exitCode, 0, truthyLast.stderr)
  assert.equal(truthyLast.stdout, 'false\ntrue\n')
  const falseyLast = await shell.run(['bash', '-c', `jq -e 'input_line_number == 1' two.json`], { cwd: CWD })
  assert.equal(falseyLast.exitCode, 1, falseyLast.stderr)
  assert.equal(falseyLast.stdout, 'true\nfalse\n')
  const nullLast = await shell.run(['bash', '-c', `jq -e 'if input_line_number == 1 then 1 else null end' two.json`], { cwd: CWD })
  assert.equal(nullLast.exitCode, 1, nullLast.stderr)
  assert.equal(nullLast.stdout, '1\nnull\n')
  // The status probe must not inherit -r/-j or a combined short flag, and the
  // output bytes must still be produced by the normal evaluation.
  const raw = await shell.run(['bash', '-c', `jq -r -e 'input_line_number' two.json`], { cwd: CWD })
  assert.equal(raw.exitCode, 0, raw.stderr)
  assert.equal(raw.stdout, '1\n2\n')
  const joined = await shell.run(['bash', '-c', `jq -j -e 'input_line_number' two.json`], { cwd: CWD })
  assert.equal(joined.exitCode, 0, joined.stderr)
  assert.equal(joined.stdout, '12')
  const combined = await shell.run(['bash', '-c', `jq -ce 'input_line_number == 1' two.json`], { cwd: CWD })
  assert.equal(combined.exitCode, 1, combined.stderr)
  assert.equal(combined.stdout, 'true\nfalse\n')
  const longFlag = await shell.run(['bash', '-c', `jq --exit-status 'input_line_number > 1' two.json`], { cwd: CWD })
  assert.equal(longFlag.exitCode, 0, longFlag.stderr)
  assert.equal(longFlag.stdout, 'false\ntrue\n')
  const nanTruthy = await shell.run(
    ['bash', '-c', "jq -e 'input_line_number | nan' two.json"],
    { cwd: CWD },
  )
  assert.equal(nanTruthy.exitCode, 0, nanTruthy.stderr)
  assert.match(nanTruthy.stdout, /^(?:null\n)+$/u,
               'jq serializes NaN as null but -e still treats the numeric value as truthy')

  // jq 1.6 decides -e from the *last outer document*, not from the last
  // non-empty value of the whole stream. A final document that emits nothing
  // is status 4 even when earlier documents emitted truthy values.
  const finalNoOutput = await shell.run(
    ['bash', '-c', "jq -e 'if input_line_number == 3 then empty else true end' nums3.json"],
    { cwd: CWD },
  )
  assert.equal(finalNoOutput.exitCode, 4, finalNoOutput.stderr)
  assert.equal(finalNoOutput.stdout, 'true\ntrue\n')
  const onlyFirstOutput = await shell.run(
    ['bash', '-c', "jq -e 'if input_line_number == 1 then true else empty end' nums3.json"],
    { cwd: CWD },
  )
  assert.equal(onlyFirstOutput.exitCode, 4, onlyFirstOutput.stderr)
  assert.equal(onlyFirstOutput.stdout, 'true\n')
  const allEmpty = await shell.run(
    ['bash', '-c', "jq -e 'input_line_number | empty' nums3.json"],
    { cwd: CWD },
  )
  assert.equal(allEmpty.exitCode, 4, allEmpty.stderr)
  assert.equal(allEmpty.stdout, '')
  const finalFalse = await shell.run(
    ['bash', '-c', "jq -e 'if input_line_number == 1 then false else empty end' nums3.json"],
    { cwd: CWD },
  )
  assert.equal(finalFalse.exitCode, 4, finalFalse.stderr)
  assert.equal(finalFalse.stdout, 'false\n')

  const compileError = await shell.run(
    ['bash', '-c', "jq -e 'input_line_number +' two.json"],
    { cwd: CWD },
  )
  assert.notEqual(compileError.exitCode, 0, compileError.stderr)
  const compileErrorEmpty = await shell.run(
    ['bash', '-c', "jq -e 'input_line_number +' empty.json"],
    { cwd: CWD },
  )
  assert.notEqual(compileErrorEmpty.exitCode, 0, compileErrorEmpty.stderr)
  assert.equal(compileErrorEmpty.stdout, '')
})

test('jq: number exponents are literals, not function names', async () => {
  const { shell } = await fixture()
  // The bounded name validator must consume the whole number token before it
  // looks for identifiers. Previously the exponent in `1e3` was reported as
  // the undefined function `e3/0`, which regressed filters that jq accepts.
  const cases: readonly { readonly filter: string; readonly stdout: string }[] = [
    { filter: 'input_line_number + 1e3', stdout: '1001\n1002\n' },
    { filter: 'input_line_number + 1E3', stdout: '1001\n1002\n' },
    { filter: 'input_line_number + 1.5e-3', stdout: '1.0015\n2.0015\n' },
    { filter: '[1e3, input_line_number]', stdout: '[1000,1]\n[1000,2]\n' },
    { filter: '-1e3, input_line_number', stdout: '-1000\n1\n-1000\n2\n' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', '-c', entry.filter, 'two.json'], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.filter}: ${result.stderr}`)
  }
  // The zero-document compile-validation path uses the same scanner and must
  // not invent an identifier either; native jq never enters the filter.
  const empty = await shell.run(
    ['jq', '-c', 'input_line_number + 1e3', 'empty.json'],
    { cwd: CWD },
  )
  assert.equal(empty.exitCode, 0, empty.stderr)
  assert.equal(empty.stdout, '')
})

test('jq: zero-input validation catches compile names and option errors without running filters', async () => {
  const { shell } = await fixture()
  const cases = [
    { command: "jq 'input_line_number +' empty.json", diagnostic: /parse error/u },
    { command: "jq 'input_line_number | no_such_jq_function' empty.json", diagnostic: /function 'no_such_jq_function\/0'/u },
    { command: "jq 'input_line_number | $no_such_jq_variable' empty.json", diagnostic: /variable 'no_such_jq_variable'/u },
    { command: "jq 'input_line_number | length(1)' empty.json", diagnostic: /function 'length\/1'/u },
    { command: "jq 'input_line_number | map(.;.)' empty.json", diagnostic: /function 'map\/2'/u },
    { command: "jq 'input_line_number as $x | $x' empty.json", diagnostic: /cannot prove as\/label binding scope/u },
    { command: "jq --argjson value nope 'input_line_number' empty.json", diagnostic: /argjson|JSON|parse|invalid/u },
    { command: "jq --rawfile value missing.txt 'input_line_number' empty.json", diagnostic: /missing.txt|open|No such/u },
    { command: "jq --slurpfile value missing.json 'input_line_number' empty.json", diagnostic: /missing.json|open|No such/u },
  ] as const
  for (const entry of cases) {
    const result = await shell.run(['bash', '-c', entry.command], { cwd: CWD })
    assert.notEqual(result.exitCode, 0, entry.command + ': ' + result.stderr)
    assert.match(result.stderr, entry.diagnostic, entry.command)
  }
  const runtimeError = await shell.run(
    ['bash', '-c', "jq 'input_line_number | error' empty.json"],
    { cwd: CWD },
  )
  assert.equal(runtimeError.exitCode, 0, runtimeError.stderr)
  assert.equal(runtimeError.stdout, '')
  assert.equal(runtimeError.stderr, '')
  // error/1 is a different builtin from error/0. The empty-input validation
  // must resolve it without executing it: native jq exits 0 and prints nothing.
  const runtimeErrorOne = await shell.run(
    ['bash', '-c', "jq 'input_line_number | error(\"x\")' empty.json"],
    { cwd: CWD },
  )
  assert.equal(runtimeErrorOne.exitCode, 0, runtimeErrorOne.stderr)
  assert.equal(runtimeErrorOne.stdout, '')
  assert.equal(runtimeErrorOne.stderr, '')
})

test('jq: --help is delegated once regardless of input document count', async () => {
  const { shell } = await fixture()
  const empty = await shell.run(['bash', '-c', "jq --help 'input_line_number' empty.json"], { cwd: CWD })
  const multiple = await shell.run(['bash', '-c', "jq --help 'input_line_number' nums.json"], { cwd: CWD })
  assert.equal(empty.exitCode, 0, empty.stderr)
  assert.ok(empty.stdout.length > 0)
  assert.equal(multiple.stdout, empty.stdout)
})

test('jq: --help option values stay data on real input-family requests', async () => {
  const { shell } = await fixture()
  const arg = await shell.run(
    ['jq', '-c', '--arg', 'x', '--help', '$x, input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(arg.exitCode, 0, arg.stderr)
  assert.equal(arg.stdout, '"--help"\n1\n"--help"\n2\n')
  const argStatus = await shell.run(
    ['jq', '-e', '--arg', 'x', '--help', '$x, input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(argStatus.exitCode, 0, argStatus.stderr)
  assert.equal(argStatus.stdout, '"--help"\n1\n"--help"\n2\n')

  const rawfile = await shell.run(
    ['jq', '-c', '--rawfile', 'x', '--help', '$x, input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(rawfile.exitCode, 0, rawfile.stderr)
  assert.equal(rawfile.stdout, '"7\\n8\\n"\n1\n"7\\n8\\n"\n2\n')

  const slurpfile = await shell.run(
    ['jq', '-c', '--slurpfile', 'x', '--help', '$x, input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(slurpfile.exitCode, 0, slurpfile.stderr)
  assert.equal(slurpfile.stdout, '[7,8]\n1\n[7,8]\n2\n')
})

test('jq: malformed if/end pairing fails loud without input documents', async () => {
  const { shell } = await fixture()
  const filter = 'input_line_number | if . then 1 end'
  const cases: readonly { readonly args: readonly string[]; readonly file: string }[] = [
    { args: ['-c', filter], file: 'two.json' },
    { args: ['-e', filter], file: 'empty.json' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', ...entry.args, entry.file], { cwd: CWD })
    assert.equal(result.exitCode, 2, result.stderr)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /if\/elif\/then\/else\/end pairing/u)
  }
  const complete = await shell.run(
    ['jq', '-c', 'input_line_number | if . == 1 then "one" elif . == 2 then "two" else "other" end', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(complete.exitCode, 0, complete.stderr)
  assert.equal(complete.stdout, '"one"\n"two"\n')
})

test('jq: a trailing filter comment does not swallow the wrapper close paren', async () => {
  const { shell } = await fixture()
  const consuming = await shell.run(['jq', '-c', 'input # tail', 'nums3.json'], { cwd: CWD })
  assert.equal(consuming.exitCode, 5, consuming.stderr)
  assert.equal(consuming.stdout, '2\n')
  assert.match(consuming.stderr, /jq: error \(at nums3\.json:3\): break/u)
  const line = await shell.run(
    ['jq', '-c', 'input_line_number # tail', 'lines.json'],
    { cwd: CWD },
  )
  assert.equal(line.exitCode, 0, line.stderr)
  assert.equal(line.stdout, '1\n2\n3\n')
  const tight = await shell.run(
    ['jq', '-c', 'input_line_number# no space', 'lines.json'],
    { cwd: CWD },
  )
  assert.equal(tight.exitCode, 0, tight.stderr)
  assert.equal(tight.stdout, '1\n2\n3\n')
})

test('jq: .def/$def fields and object keys are not mistaken for def declarations', async () => {
  const { shell } = await fixture()
  const field = await shell.run(
    ['jq', '-c', '.def | input_line_number', 'fields-def.json'],
    { cwd: CWD },
  )
  assert.equal(field.exitCode, 0, field.stderr)
  assert.equal(field.stdout, '1\n2\n')
  const objectKey = await shell.run(
    ['jq', '-c', '{def: 1} | input_line_number', 'fields-def.json'],
    { cwd: CWD },
  )
  assert.equal(objectKey.exitCode, 0, objectKey.stderr)
  assert.equal(objectKey.stdout, '1\n2\n')
  const variable = await shell.run(
    ['jq', '-c', '$def | input_line_number', 'fields-def.json'],
    { cwd: CWD },
  )
  assert.notEqual(variable.exitCode, 0, variable.stderr)
  assert.doesNotMatch(variable.stderr, /defines functions/u)
  const definition = await shell.run(
    ['jq', '-c', 'def f: 1; f | input_line_number', 'fields-def.json'],
    { cwd: CWD },
  )
  assert.equal(definition.exitCode, 2, definition.stderr)
  assert.match(definition.stderr, /defines functions/u)
})

test('jq: user variables cannot collide with the shim internal names', async () => {
  const { shell } = await fixture()
  // jq 1.6 accepts a user binding for the old internal spelling and exposes it
  // unchanged; the shim no longer reuses that name.
  const oldName = await shell.run(
    ['jq', '-n', '--argjson', 'pdsh_line', '123', '$pdsh_line,input_line_number'],
    { cwd: CWD, stdin: '' },
  )
  assert.equal(oldName.exitCode, 0, oldName.stderr)
  assert.equal(oldName.stdout, '123\n0\n')
  const currentName = await shell.run(
    ['jq', '-n', '-c', '--argjson', 'pdsh_current', '{"u":1}', '$pdsh_current,input_line_number'],
    { cwd: CWD, stdin: '' },
  )
  assert.equal(currentName.exitCode, 0, currentName.stderr)
  assert.equal(currentName.stdout, '{"u":1}\n0\n')
  // The actual internal names are reserved: refuse instead of silently
  // replacing the user's value with the shim's document/line.
  const reserved = await shell.run(
    ['jq', '-n', '--argjson', '__pdsh_jq_line', '123', '$__pdsh_jq_line,input_line_number'],
    { cwd: CWD, stdin: '' },
  )
  assert.equal(reserved.exitCode, 2, reserved.stderr)
  assert.equal(reserved.stdout, '')
  assert.match(reserved.stderr, /reserved for the Worker jq shim's internal state/u)
})

test('jq: a negative filter is recognized while unknown options are not', async () => {
  const { shell } = await fixture()
  const negative = await shell.run(['jq', '-c', '-1, inputs', 'nums3.json'], { cwd: CWD })
  assert.equal(negative.exitCode, 0, negative.stderr)
  assert.equal(negative.stdout, '-1\n2\n3\n')
  // jq 1.6 treats `--` before the filter as usage (exit 2). Either way it must
  // not be re-read as a working filter; the Worker already fails loud.
  const terminator = await shell.run(
    ['jq', '-c', '--', '-1, inputs', 'nums3.json'],
    { cwd: CWD },
  )
  assert.notEqual(terminator.exitCode, 0, terminator.stderr)
  assert.equal(terminator.stdout, '')
  const unknown = await shell.run(['jq', '--bogus', '.'], { cwd: CWD })
  assert.notEqual(unknown.exitCode, 0, unknown.stderr)
  assert.equal(unknown.stdout, '')
})

test('jq: all-empty later sources reset a boundary input line to zero', async () => {
  const { shell } = await fixture()
  const result = await shell.run(
    ['bash', '-c', "jq -c 'input_line_number' boundary-empty.json empty.json"],
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '0\n')
})

test('jq: overflowing JSON numbers fail explicitly instead of serializing as null', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "jq -n -c '[inputs]' overflow.json"], { cwd: CWD })
  assert.equal(result.exitCode, 4, result.stderr)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /number out of range/u)
})

test('jq: multi-file input is joined as raw bytes before UTF-8 decoding', async () => {
  const { shell } = await fixture()
  // Operands are concatenated by jq before decoding, so a codepoint split
  // across two files is still one valid character.
  const split = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'split-a.json', 'split-b.json'],
    { cwd: CWD },
  )
  assert.equal(split.exitCode, 0, split.stderr)
  assert.equal(split.stdout, '["é"]\n')
  const line = await shell.run(
    ['jq', '-c', 'input_line_number', 'split-a.json', 'split-b.json'],
    { cwd: CWD },
  )
  assert.equal(line.exitCode, 0, line.stderr)
  assert.equal(line.stdout, '1\n')
  const unicode = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'unicode.json'],
    { cwd: CWD },
  )
  assert.equal(unicode.exitCode, 0, unicode.stderr)
  assert.equal(unicode.stdout, '[{"é":"✓"},"漢字"]\n')
  // jq 1.6 itself replaces invalid UTF-8 with U+FFFD. This shim cannot promise
  // that every replacement boundary matches jq, so it refuses the stream
  // instead of silently claiming byte-exact output.
  const invalid = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'invalid-utf8.json'],
    { cwd: CWD },
  )
  assert.equal(invalid.exitCode, 2, invalid.stderr)
  assert.equal(invalid.stdout, '')
  assert.match(invalid.stderr, /invalid UTF-8 input is not supported/u)
})

test('jq: a leading BOM is skipped without losing its byte offsets', async () => {
  const { shell } = await fixture()
  // BOM + two blank lines + `1\n`: native jq 1.6 reports line 3, not 1. The
  // BOM bytes belong to the stream even though the parser skips the character.
  const single = await shell.run(['jq', '-c', 'input_line_number', 'bom-blank.json'], { cwd: CWD })
  assert.equal(single.exitCode, 0, single.stderr)
  assert.equal(single.stdout, '3\n')
  // A BOM at the start of the first operand, then a second operand whose
  // first document follows two blank lines: native 1,3.
  const multi = await shell.run(
    ['jq', '-c', 'input_line_number', 'bom-a.json', 'bom-b.json'],
    { cwd: CWD },
  )
  assert.equal(multi.exitCode, 0, multi.stderr)
  assert.equal(multi.stdout, '1\n3\n')
  const values = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'bom-a.json', 'bom-b.json'],
    { cwd: CWD },
  )
  assert.equal(values.exitCode, 0, values.stderr)
  assert.equal(values.stdout, '[1,2]\n')
  // The BOM bytes must not shift the source range: a primitive ending at the
  // first operand's EOF merges with the next operand, and an exhausted input
  // names that second operand.
  const merged = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'bom-merge-a.json', 'bom-merge-b.json'],
    { cwd: CWD },
  )
  assert.equal(merged.exitCode, 0, merged.stderr)
  assert.equal(merged.stdout, '[12]\n')
  const breakSource = await shell.run(
    ['jq', '-c', 'input', 'bom-merge-a.json', 'bom-merge-b.json'],
    { cwd: CWD },
  )
  assert.equal(breakSource.exitCode, 5, breakSource.stderr)
  assert.equal(breakSource.stdout, '')
  assert.match(breakSource.stderr, /jq: error \(at bom-merge-b\.json:1\): break/u)
  const singleBreak = await shell.run(['jq', '-c', 'input', 'bom-a.json'], { cwd: CWD })
  assert.equal(singleBreak.exitCode, 5, singleBreak.stderr)
  assert.match(singleBreak.stderr, /jq: error \(at bom-a\.json:1\): break/u)
  // The BOM shifts the 4095-byte fgets boundary by exactly three bytes.
  const boundary: readonly { readonly file: string; readonly stdout: string }[] = [
    { file: 'bom-ascii-4089.json', stdout: '1\n2\n' },
    { file: 'bom-ascii-4090.json', stdout: '0\n2\n' },
    { file: 'bom-multi-2044.json', stdout: '1\n2\n' },
    { file: 'bom-multi-2045.json', stdout: '0\n2\n' },
  ]
  for (const entry of boundary) {
    const result = await shell.run(['jq', '-c', 'input_line_number', entry.file], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${entry.file}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.file}: ${result.stderr}`)
  }
  // Native jq only skips a BOM at the very start of the stream; one after a
  // newline is a parse error (exit 4), never a silently ignored character.
  const later = await shell.run(['jq', '-c', 'input_line_number', 'bom-later.json'], { cwd: CWD })
  assert.equal(later.exitCode, 4, later.stderr)
  assert.equal(later.stdout, '')
  assert.match(later.stderr, /parse error/u)
})

test('jq: input_line_number follows jq 1.6 4095-byte fgets boundaries', async () => {
  const { shell } = await fixture()
  // The value's closing quote is the last byte of the first 4095-byte read:
  // jq returns it before reading the newline in the next chunk, so the count
  // is 0. One byte earlier the same newline is in the first chunk (1).
  const cases: readonly { readonly file: string; readonly stdout: string }[] = [
    { file: 'ascii-4092.json', stdout: '1\n2\n' },
    { file: 'ascii-4093.json', stdout: '0\n2\n' },
    { file: 'multi-4094.json', stdout: '0\n2\n' },
  ]
  for (const entry of cases) {
    const result = await shell.run(
      ['jq', '-c', 'input_line_number', entry.file],
      { cwd: CWD },
    )
    assert.equal(result.exitCode, 0, `${entry.file}: ${result.stderr}`)
    assert.equal(result.stdout, entry.stdout, `${entry.file}: ${result.stderr}`)
  }
  // A primitive ending at the first operand's EOF reads the next operand's
  // first chunk. Its newline is beyond byte 4095, so the primitive reports 0
  // and the long string that follows also ends on that same read boundary.
  const later = await shell.run(
    ['jq', '-c', 'input_line_number', 'one-no-newline.json', 'multi-later.json'],
    { cwd: CWD },
  )
  assert.equal(later.exitCode, 0, later.stderr)
  assert.equal(later.stdout, '0\n0\n2\n')
})

test('jq: as/label declarations stop at function arguments and object values', async () => {
  const { shell } = await fixture()
  // jq 1.6 scopes an `as` binding to the current expression, not to the whole
  // enclosing call: a later `;` argument cannot see it. An `as`/`label`
  // directly in an object value is a syntax error; only a parenthesized value
  // is a legal binding expression.
  const rejected: readonly { readonly filter: string; readonly diagnostic: RegExp }[] = [
    {
      filter: 'input_line_number | test(1 as $x | "a"; $x)',
      diagnostic: /variable 'x'/u,
    },
    {
      filter: 'input_line_number | test((1 as $x | "a"); $x)',
      diagnostic: /variable 'x'/u,
    },
    {
      filter: 'input_line_number | {a: 1 as $x | $x}',
      diagnostic: /cannot prove as\/label binding scope/u,
    },
    {
      filter: 'input_line_number | {a: label $l | 1}',
      diagnostic: /cannot prove as\/label binding scope/u,
    },
  ]
  for (const entry of rejected) {
    const result = await shell.run(['jq', '-c', entry.filter, 'two.json'], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.filter)
    assert.match(result.stderr, entry.diagnostic, entry.filter)
  }
  // Parenthesized object values remain legal jq and stay supported.
  const object = await shell.run(
    ['jq', '-c', 'input_line_number | {a: (1 as $x | $x)}', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(object.exitCode, 0, object.stderr)
  assert.equal(object.stdout, '{"a":1}\n{"a":1}\n')
  const array = await shell.run(
    ['jq', '-c', 'input_line_number | [1 as $x | $x]', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(array.exitCode, 0, array.stderr)
  assert.equal(array.stdout, '[1]\n[1]\n')
})

test('jq: an empty function argument list is a syntax error, not arity zero', async () => {
  const { shell } = await fixture()
  for (const filter of ['input_line_number | length()', 'input_line_number | length( # no arguments\n )']) {
    const result = await shell.run(['jq', '-c', filter, 'two.json'], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${filter}: ${result.stderr}`)
    assert.equal(result.stdout, '', filter)
    assert.match(result.stderr, /empty argument list/u, filter)
  }
  // The zero-document compile check must not turn the syntax error into -e's
  // success status.
  const empty = await shell.run(
    ['jq', '-e', 'input_line_number | length()', 'empty.json'],
    { cwd: CWD },
  )
  assert.equal(empty.exitCode, 2, empty.stderr)
  assert.equal(empty.stdout, '')
  assert.match(empty.stderr, /empty argument list/u)
  // The bare zero-argument builtin is different from `name()` and still works.
  const bare = await shell.run(['jq', '-c', 'input_line_number | length', 'two.json'], { cwd: CWD })
  assert.equal(bare.exitCode, 0, bare.stderr)
  assert.equal(bare.stdout, '1\n2\n')
})

test('jq: variable names follow the jq 1.6 lexer', async () => {
  const { shell } = await fixture()
  const rejected: readonly { readonly args: readonly string[]; readonly diagnostic: RegExp }[] = [
    { args: ['--arg', 'if', 'X', '$if, input_line_number', 'two.json'], diagnostic: /variable name/u },
    { args: ['-c', 'input_line_number | 1 as $if | $if', 'two.json'], diagnostic: /variable name/u },
    { args: ['-c', 'input_line_number | 1 as $1abc | $1abc', 'two.json'], diagnostic: /variable name/u },
    { args: ['-c', 'input_line_number | 1 as $__loc__ | $__loc__', 'two.json'], diagnostic: /binding scope/u },
    // A user --arg cannot replace jq's special location variable.
    { args: ['-c', '--arg', '__loc__', 'X', '$__loc__, input_line_number', 'two.json'], diagnostic: /variable '__loc__'/u },
  ]
  for (const entry of rejected) {
    const result = await shell.run(['jq', ...entry.args], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.args.join(' ')}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.args.join(' '))
    assert.match(result.stderr, entry.diagnostic, entry.args.join(' '))
  }
  // true/false/null are IDENT tokens after `$` in jq 1.6, so binding or
  // --arg use is legal even though the bare words are literals in value
  // position.
  const arg = await shell.run(
    ['jq', '-c', '--arg', 'true', 'X', '$true, input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(arg.exitCode, 0, arg.stderr)
  assert.equal(arg.stdout, '"X"\n1\n"X"\n2\n')
  const binding = await shell.run(
    ['jq', '-c', 'input_line_number | 1 as $true | $true', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(binding.exitCode, 0, binding.stderr)
  assert.equal(binding.stdout, '1\n1\n')
  // An invalid *unused* --arg name is not a filter reference and native jq
  // accepts it; only the `$name` token in the filter is a lexer error.
  const unused = await shell.run(
    ['jq', '-c', '--arg', 'if', 'X', 'input_line_number', 'two.json'],
    { cwd: CWD },
  )
  assert.equal(unused.exitCode, 0, unused.stderr)
  assert.equal(unused.stdout, '1\n2\n')
})

test('jq: a break that can drop earlier label values fails loud', async () => {
  const { shell } = await fixture()
  // The pinned evaluator discards `1` when `break` interrupts the label body.
  // Native jq emits the value first; refuse the shape instead of underprinting.
  const cases: readonly { readonly args: readonly string[]; readonly file: string }[] = [
    { args: ['-n', '-c', 'inputs | label $l | 1, break $l'], file: 'nums.json' },
    { args: ['-n', '-c', 'inputs | [label $l | 1, break $l]'], file: 'nums.json' },
    { args: ['-n', '-c', 'inputs | label $l | 1, if true then break $l else . end'], file: 'nums.json' },
    { args: ['-c', 'input_line_number | label $l | 1, break $l'], file: 'two.json' },
    { args: ['-c', 'input_line_number | [label $l | 1, break $l]'], file: 'two.json' },
  ]
  for (const entry of cases) {
    const result = await shell.run(['jq', ...entry.args, entry.file], { cwd: CWD })
    assert.equal(result.exitCode, 2, `${entry.args.join(' ')}: ${result.stderr}`)
    assert.equal(result.stdout, '', entry.args.join(' '))
    assert.match(result.stderr, /label.break/u, entry.args.join(' '))
  }
})

test('jq: a filesystem without readFileBytes falls back to raw readFileBuffer', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-raw-fallback-'))
  roots.push(root)
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const base = new VfsFileSystem({ root })
  await base.writeFile(`${CWD}/f-a.bin`, new Uint8Array([0x22, 0xc3]))
  await base.writeFile(`${CWD}/f-b.bin`, new Uint8Array([0xa9, 0x22, 0x0a]))
  await base.writeFile(`${CWD}/bad.bin`, new Uint8Array([0x22, 0xe0, 0x80, 0x80, 0x22, 0x0a]))
  let readFileCalls = 0
  const fs = new Proxy(base, {
    get(target, property, receiver) {
      if (property === 'readFileBytes') return undefined
      if (property === 'readFile') {
        return async () => {
          readFileCalls += 1
          return '\uFFFD'
        }
      }
      return Reflect.get(target, property, receiver)
    },
  })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  const split = await shell.run(
    ['jq', '-n', '-c', '[inputs]', 'f-a.bin', 'f-b.bin'],
    { cwd: CWD },
  )
  assert.equal(split.exitCode, 0, split.stderr)
  assert.equal(split.stdout, '["é"]\n')
  assert.equal(readFileCalls, 0, 'the decoded readFile fallback must never supply jq bytes')
  const invalid = await shell.run(['jq', '-n', '-c', '[inputs]', 'bad.bin'], { cwd: CWD })
  assert.equal(invalid.exitCode, 2, invalid.stderr)
  assert.equal(invalid.stdout, '')
  assert.match(invalid.stderr, /invalid UTF-8 input is not supported/u)
  // A backend with no raw-byte surface at all is refused, not decoded first.
  const textOnly = new Proxy(base, {
    get(target, property, receiver) {
      if (property === 'readFileBytes' || property === 'readFileBuffer') return undefined
      return Reflect.get(target, property, receiver)
    },
  })
  const textShell = new WorkerShell({
    fs: textOnly,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  const refused = await textShell.run(['jq', '-n', '-c', '[inputs]', 'f-a.bin'], { cwd: CWD })
  assert.equal(refused.exitCode, 2, refused.stderr)
  assert.equal(refused.stdout, '')
  assert.match(refused.stderr, /neither readFileBytes nor readFileBuffer/u)
})

test('jq: -e returns 4 when an evaluated document produces no output', async () => {
  const { shell } = await fixture()
  const noRemaining = await shell.run(['bash', '-c', `jq -e 'inputs' one.json`], { cwd: CWD })
  assert.equal(noRemaining.exitCode, 4, noRemaining.stderr)
  assert.equal(noRemaining.stdout, '')
  const nullInputEmpty = await shell.run(['bash', '-c', `jq -n -e 'inputs' empty.json`], { cwd: CWD })
  assert.equal(nullInputEmpty.exitCode, 4, nullInputEmpty.stderr)
  assert.equal(nullInputEmpty.stdout, '')
  // jq 1.6 never enters the filter when a non-null invocation has no input
  // document; that case is exit 0, not the "no output" status 4.
  const emptyInput = await shell.run(['bash', '-c', `jq -e 'inputs' empty.json`], { cwd: CWD })
  assert.equal(emptyInput.exitCode, 0, emptyInput.stderr)
  assert.equal(emptyInput.stdout, '')
})

test('jq: a filter without the input family is delegated unchanged', async () => {
  const { shell } = await fixture()
  const identity = await shell.run(['bash', '-c', `jq '.' a.json`], { cwd: CWD })
  assert.equal(identity.exitCode, 0, identity.stderr)
  assert.equal(identity.stdout, '{\n  "a": 1\n}\n{\n  "a": 2\n}\n')
  // `.inputs` is a field access, not the built-in function: it must not be
  // rewritten by the shim.
  const field = await shell.run(['bash', '-c', `jq '.inputs' fields.json`], { cwd: CWD })
  assert.equal(field.exitCode, 0, field.stderr)
  assert.equal(field.stdout, '5\nnull\n')
  const lineField = await shell.run(['bash', '-c', `jq '.input_line_number' fields.json`], { cwd: CWD })
  assert.equal(lineField.exitCode, 0, lineField.stderr)
  assert.equal(lineField.stdout, 'null\n7\n')
})

test('jq: a direct argv spawn and bash -c reach the same shim', async () => {
  const { shell } = await fixture()
  const direct = await shell.run(['jq', '-n', '[inputs]', 'a.json', 'b.json'], { cwd: CWD })
  const viaBash = await shell.run(['bash', '-c', `jq -n '[inputs]' a.json b.json`], { cwd: CWD })
  assert.equal(direct.exitCode, viaBash.exitCode)
  assert.equal(direct.stdout, viaBash.stdout)
  assert.equal(direct.stderr, viaBash.stderr)
})

test('jq: unsupported input-consumption combinations fail loud', async () => {
  const { shell } = await fixture()
  const slurp = await shell.run(['bash', '-c', `jq -s 'inputs' a.json`], { cwd: CWD })
  assert.equal(slurp.exitCode, 2)
  assert.match(slurp.stderr, /--slurp together with inputs\/input\/input_line_number is not supported/u)
  const twice = await shell.run(['bash', '-c', `jq '[input, input]' nums.json`], { cwd: CWD })
  assert.equal(twice.exitCode, 2)
  assert.match(twice.stderr, /calling input more than once is not supported/u)
  const mixed = await shell.run(['bash', '-c', `jq '[inputs, input]' nums.json`], { cwd: CWD })
  assert.equal(mixed.exitCode, 2)
  assert.match(mixed.stderr, /combining inputs and input is not supported/u)
})

test('jq: the argv parser separates options, filter and file operands', () => {
  assert.deepEqual(parseJqInvocation(['-c', '-n', '--arg', 'x', '-1', '--argjson', 'y', '{"a":1}', '[inputs]', 'a.json']), {
    options: ['-c', '-n', '--arg', 'x', '-1', '--argjson', 'y', '{"a":1}'],
    filter: '[inputs]',
    files: ['a.json'],
    positional: [],
    nullInput: true,
    slurp: false,
    rawInput: false,
    exitStatus: false,
    help: false,
    argsMode: undefined,
    unsupportedOption: undefined,
  })
  assert.equal(parseJqInvocation(['--arg', 'x', '--help', '$x, input_line_number']).help, false)
  assert.equal(parseJqInvocation(['--rawfile', 'x', '--help', '$x']).help, false)
  assert.equal(parseJqInvocation(['--slurpfile', 'x', '--help', '$x']).help, false)
  assert.equal(parseJqInvocation(['--help', '.']).help, true)
  const args = parseJqInvocation(['-n', '--args', '$ARGS.positional', 'one', 'two'])
  assert.equal(args.filter, '$ARGS.positional')
  assert.deepEqual(args.positional, ['one', 'two'])
  assert.deepEqual(args.files, [])
  assert.equal(parseJqInvocation(['-n', '.']).nullInput, true)
  // jq 1.6 only accepts `--` after the filter. Before it, the token is not an
  // end-of-options marker and must not turn the next option into a filter.
  const earlyTerminator = parseJqInvocation(['--', '-n'])
  assert.equal(earlyTerminator.filter, undefined)
  assert.equal(earlyTerminator.unsupportedOption, '--')
  const lateTerminator = parseJqInvocation(['.', '--', '-n'])
  assert.equal(lateTerminator.filter, '.')
  assert.deepEqual(lateTerminator.files, ['-n'])
  // Negative filters are not option-shaped (`isoptish` in jq only accepts a
  // second letter or `-`), while a real unknown option is delegated.
  assert.equal(parseJqInvocation(['-1, inputs', 'a.json']).filter, '-1, inputs')
  assert.equal(parseJqInvocation(['-1x']).filter, '-1x')
  assert.equal(parseJqInvocation(['-x']).unsupportedOption, '-x')
  assert.equal(parseJqInvocation(['--bogus', '.']).unsupportedOption, '--bogus')
})

test('jq: the filter scanner only rewrites bare identifiers', () => {
  assert.deepEqual(JQ_INPUT_FUNCTIONS, ['inputs', 'input', 'input_line_number'])
  assert.deepEqual(scanJqInputReferences('[inputs]').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('.[input:2]').map(reference => reference.name), ['input'])
  assert.deepEqual(scanJqInputReferences('[., input]').map(reference => reference.name), ['input'])
  assert.deepEqual(scanJqInputReferences('1, inputs, 2').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('[1, inputs, 2]').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('[1, input, 2]').map(reference => reference.name), ['input'])
  assert.deepEqual(scanJqInputReferences('{inputs: inputs}').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('{a: inputs}').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('{a: [inputs]}').map(reference => reference.name), ['inputs'])
  assert.deepEqual(scanJqInputReferences('[{inputs}]'), [])
  assert.deepEqual(scanJqInputReferences('{a: {inputs}}'), [])
  assert.deepEqual(
    scanJqInputReferences(String.raw`"\(inputs)"`).map(reference => reference.name),
    ['inputs'],
  )
  assert.deepEqual(
    scanJqInputReferences(String.raw`"a\(input) b"`).map(reference => reference.name),
    ['input'],
  )
  assert.deepEqual(
    scanJqInputReferences(String.raw`"\(inputs) \(input) \(input_line_number)"`)
      .map(reference => reference.name),
    ['inputs', 'input', 'input_line_number'],
  )
  assert.deepEqual(scanJqInputReferences(String.raw`"\( "inputs" )"`), [])
  assert.deepEqual(scanJqInputReferences(String.raw`"\\(inputs)"`), [])
  assert.equal(rewriteJqInputFunctions('[inputs]'), '[$__pdsh_jq_inputs[]]')
  assert.equal(rewriteJqInputFunctions('[inputs, 2]'), '[$__pdsh_jq_inputs[], 2]')
  assert.equal(rewriteJqInputFunctions('1, inputs, 2'), '1, $__pdsh_jq_inputs[], 2')
  assert.equal(rewriteJqInputFunctions('input_line_number'), '$__pdsh_jq_line')
  assert.equal(
    rewriteJqInputFunctions(String.raw`"\(inputs)"`),
    String.raw`"\($__pdsh_jq_inputs[])"`,
  )
  assert.deepEqual(
    scanJqInputReferences('# Read the line.\ninput_line_number').map(reference => reference.name),
    ['input_line_number'],
  )
  assert.deepEqual(
    scanJqInputReferences('# Read the rest.\ninputs').map(reference => reference.name),
    ['inputs'],
  )
  assert.deepEqual(
    scanJqInputReferences('# do not def\ninput').map(reference => reference.name),
    ['input'],
  )
  assert.deepEqual(
    scanJqInputReferences('# cost $\ninput').map(reference => reference.name),
    ['input'],
  )
  assert.deepEqual(
    scanJqInputReferences('# format @\ninput_line_number').map(reference => reference.name),
    ['input_line_number'],
  )
  const lifted = planJqShim(String.raw`"\(inputs)"`)
  assert.equal(lifted?.liftedInputsInterpolation, true)
  assert.equal(lifted?.filter, String.raw`($__pdsh_jq_inputs[] | "\(.)")`)
  assert.equal(planJqShim(String.raw`"\(inputs | length)"`)?.unsupportedInputInterpolation, true)
  assert.equal(planJqShim(String.raw`"\(inputs) \(.a)"`)?.unsupportedInputInterpolation, true)
  assert.equal(planJqShim(String.raw`"\(inputs) \(1+1)"`)?.unsupportedInputInterpolation, true)
  assert.equal(planJqShim(String.raw`@json "\(inputs)"`)?.unsupportedInputInterpolation, true)
  assert.equal(planJqShim(String.raw`@text "\(inputs)"`)?.unsupportedInputInterpolation, true)
  for (const filter of ['.inputs', '.input_line_number', '$inputs', 'my_inputs', '{inputs: 1}', '{inputs}', '"inputs"', '# inputs\n.']) {
    assert.deepEqual(scanJqInputReferences(filter), [], filter)
    assert.equal(planJqShim(filter), undefined, filter)
  }
  assert.equal(findUnsafeInputsValueArgument('[inputs]'), undefined)
  assert.equal(findUnsafeInputsValueArgument(String.raw`"\(inputs)"`), undefined)
  assert.equal(findUnsafeInputsValueArgument('[1, inputs, 2]'), undefined)
  assert.equal(findUnsafeInputsValueArgument('inputs | length'), undefined)
  assert.match(findUnsafeInputsValueArgument('has(inputs)') ?? '', /function argument/u)
  assert.match(findUnsafeInputsValueArgument('test(inputs)') ?? '', /function argument/u)
  assert.match(findUnsafeInputsValueArgument('split(inputs)') ?? '', /function argument/u)
  assert.match(findUnsafeInputsValueArgument('has(input)') ?? '', /function argument/u)
  assert.match(findUnsafeInputsValueArgument(String.raw`test("\(input)")`) ?? '', /function argument/u)
  assert.equal(findUnsafeInputsValueArgument('test(input_line_number | tostring)'), undefined)
  assert.match(
    findUnsafeInputsValueArgument(String.raw`test("\(inputs)")`) ?? '',
    /interpolation used as a function argument/u,
  )
  assert.equal(findUnsafeInputConsumption('[inputs]'), undefined)
  assert.equal(findUnsafeInputConsumption('input | .[]'), undefined)
  assert.match(findUnsafeInputConsumption('1, input') ?? '', /comma sequence/u)
  assert.equal(findUnsafeInputConsumption('input, 1'), undefined)
  assert.equal(findUnsafeInputConsumption('[1, input]'), undefined)
  assert.match(findUnsafeInputConsumption('{a: 1, b: input}') ?? '', /object constructor/u)
  assert.match(findUnsafeInputConsumption('(1, input)') ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption('1 | ., input') ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption(String.raw`"\(1, input)"`) ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption(String.raw`"\(if . then input else . end)"`) ?? '', /'if'/u)
  assert.match(findUnsafeInputConsumption('1, 2 | input') ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption('.[0], .[1] | input') ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption('(1,2) | (., input)') ?? '', /comma sequence/u)
  assert.match(findUnsafeInputConsumption('sub("a"; input)') ?? '', /'sub'/u)
  assert.match(findUnsafeInputConsumption('gsub("a"; input)') ?? '', /'gsub'/u)
  assert.match(findUnsafeInputConsumption('if . then input else . end') ?? '', /'if'/u)
  assert.match(findUnsafeInputConsumption('select(. > 1) | inputs') ?? '', /'select'/u)
  assert.match(findUnsafeInputConsumption('first(inputs)') ?? '', /'first'/u)
  assert.match(findUnsafeInputConsumption('.[] | input') ?? '', /iterator/u)
  assert.match(findUnsafeInputConsumption('values | input') ?? '', /'values'/u)
  assert.match(findUnsafeInputConsumption('paths | input') ?? '', /'paths'/u)
  assert.match(findUnsafeInputConsumption('input?') ?? '', /optional operator/u)
  assert.match(findUnsafeInputConsumption('.a // input') ?? '', /alternative operator/u)
})
