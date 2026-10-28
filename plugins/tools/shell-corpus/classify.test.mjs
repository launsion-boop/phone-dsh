// SPDX-License-Identifier: MIT
/**
 * Tests for construct detection and result classification.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { classifyResult, detectConstructs, parseMissingProgram } from './classify.mjs'

const FIXTURE_URL = new URL('./fixtures/classification-corpus.jsonl', import.meta.url)

test('every construct the report can name is detected', () => {
  const expected = new Map([
    ['for f in a b; do echo "$f"; done', 'for'],
    ['while true; do break; done', 'while'],
    ['if [ -f package.json ]; then echo yes; fi', 'if'],
    ['case "$1" in start) echo go;; esac', 'case'],
    ['greet() { echo hello; }', 'function'],
    ['cat <<EOF\nhello\nEOF', 'heredoc'],
    ['cat README.md | grep demo', 'pipeline'],
    ['echo hi > out.txt', 'redirection'],
    ['(cd src && ls)', 'subshell'],
    ['echo $((1 + 2))', 'arithmetic'],
    ['((count++))', 'arithmetic'],
    ['echo ${HOME:-/tmp}', 'parameter-expansion'],
  ])
  for (const [command, construct] of expected) {
    assert.ok(detectConstructs(command).includes(construct), `${command} should name ${construct}: ${detectConstructs(command).join(',')}`)
  }
})

test('quoted characters never create constructs', () => {
  assert.deepEqual(detectConstructs('echo "a|b > c"'), [])
  assert.deepEqual(detectConstructs("echo 'for x in y'"), [])
  assert.equal(detectConstructs('true || echo fallback').includes('pipeline'), false)
})

test('bare arithmetic is attributed to arithmetic, not a subshell', () => {
  assert.equal(detectConstructs('((count++))')[0], 'arithmetic')
})

test('a here-string is a redirection, not a heredoc', () => {
  const constructs = detectConstructs('sort <<< "b"')
  assert.equal(constructs.includes('heredoc'), false)
  assert.ok(constructs.includes('redirection'))
})

test('block constructs outrank the operators inside them', () => {
  assert.equal(detectConstructs('for f in a; do cat "$f" | wc -l; done')[0], 'for')
  assert.equal(detectConstructs('cat <<EOF | head\nhello\nEOF')[0], 'heredoc')
})

test('parseMissingProgram reads command-not-found and unavailable programs', () => {
  assert.equal(parseMissingProgram('bash: git: command not found\n'), 'git')
  assert.equal(parseMissingProgram('bash: line 1: git: command not found\n'), 'git')
  assert.equal(parseMissingProgram('command not found: git\n'), 'git')
  assert.equal(parseMissingProgram('ln: not available in the worker host\n'), 'ln')
  assert.equal(parseMissingProgram('bash: cat: No such file or directory\n'), undefined)
})

test('classifier matches the fixture corpus end to end', () => {
  const records = readFileSync(FIXTURE_URL, 'utf8').split('\n').filter((line) => line.trim() !== '')
  for (const line of records) {
    const record = JSON.parse(line)
    let result
    switch (record.mode) {
      case 'ok':
        result = { exitCode: 0, stdout: '', stderr: '' }
        break
      case 'missing':
        result = { exitCode: 127, stdout: '', stderr: `bash: ${record.stderrProgram}: command not found\n` }
        break
      case 'keyword':
        result = { exitCode: 127, stdout: '', stderr: `bash: ${record.stderrProgram}: command not found\nbash: do: command not found\n` }
        break
      case 'syntax':
        result = { exitCode: 2, stdout: '', stderr: 'bash: syntax error: unexpected token\n' }
        break
      case 'unavailable':
        result = { exitCode: 127, stdout: '', stderr: 'ln: not available in the worker host\n' }
        break
      case 'runtime':
        result = { exitCode: 1, stdout: '', stderr: 'cat: missing.txt: No such file or directory\n' }
        break
      case 'error':
        result = { error: 'runner exploded' }
        break
      default:
        throw new Error(`unknown fixture mode ${record.mode}`)
    }
    const classification = classifyResult(record.cmd, result)
    assert.equal(classification.status, record.expectStatus, record.cmd)
    if (record.expectConstruct !== undefined) assert.equal(classification.construct, record.expectConstruct, record.cmd)
    if (record.expectProgram !== undefined) assert.equal(classification.program, record.expectProgram, record.cmd)
  }
})

test('classifier sees a missing program in an earlier pipeline stage', () => {
  const classification = classifyResult('curl -fsSL https://github.com | head -n 5', {
    exitCode: 0,
    stdout: '',
    stderr: 'bash: curl: command not found\n',
  })
  assert.deepEqual(classification, { status: 'command-missing', program: 'curl' })
})

test('classifier attributes keyword command-not-found to syntax', () => {
  const classification = classifyResult('for f in a; do echo "$f"; done', {
    exitCode: 127,
    stderr: 'bash: for: command not found\nbash: do: command not found\n',
  })
  assert.deepEqual(classification, { status: 'syntax-unsupported', construct: 'for' })
})

test('classifier falls back to the first word on a bare 127', () => {
  const classification = classifyResult('git status', { exitCode: 127, stderr: '' })
  assert.deepEqual(classification, { status: 'command-missing', program: 'git' })
})

test('classifier reports a syntax error with no recognisable construct', () => {
  const classification = classifyResult('echo "unterminated', { exitCode: 2, stderr: 'bash: syntax error: unterminated quote\n' })
  assert.deepEqual(classification, { status: 'syntax-unsupported', construct: 'unknown' })
})

test('classifier keeps a real failure as a runtime error', () => {
  const classification = classifyResult('cat missing.txt', { exitCode: 1, stderr: 'cat: missing.txt: No such file or directory\n' })
  assert.equal(classification.status, 'runtime-error')
  assert.match(classification.detail, /No such file or directory/)
})

test('classifier accepts structured hints from a runner', () => {
  assert.deepEqual(
    classifyResult('whatever', { exitCode: 2, stdout: '', stderr: '', syntaxConstruct: 'heredoc' }),
    { status: 'syntax-unsupported', construct: 'heredoc' },
  )
  assert.deepEqual(
    classifyResult('whatever', { exitCode: 127, stdout: '', stderr: '', missingProgram: 'git' }),
    { status: 'command-missing', program: 'git' },
  )
  assert.deepEqual(
    classifyResult('for f in a; do echo; done', { exitCode: 127, stdout: '', stderr: '', missingProgram: 'for' }),
    { status: 'syntax-unsupported', construct: 'for' },
  )
})

test('classifier marks a thrown runner as a runtime error', () => {
  assert.deepEqual(classifyResult('anything', { error: 'socket closed' }), { status: 'runtime-error', detail: 'socket closed' })
})
