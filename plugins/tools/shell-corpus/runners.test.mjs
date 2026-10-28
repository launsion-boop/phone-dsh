// SPDX-License-Identifier: MIT
/**
 * Tests for the pluggable runner interface and the coverage CLI.
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { createRunner, parseCorpus } from './runners.mjs'

const COVERAGE_PATH = fileURLToPath(new URL('./coverage.mjs', import.meta.url))
const FAKE_RUNNER_PATH = fileURLToPath(new URL('./fixtures/fake-runner.mjs', import.meta.url))

/** Run the coverage CLI and return the spawn result. */
function runCoverage(args) {
  return spawnSync(process.execPath, [COVERAGE_PATH, ...args], { encoding: 'utf8' })
}

test('the runtime-js runner exposes the documented interface without starting the checkout', async () => {
  const runner = await createRunner('runtime-js')
  assert.equal(runner.name, 'runtime-js')
  assert.equal(typeof runner.run, 'function')
  assert.equal(typeof runner.start, 'function')
  assert.equal(typeof runner.close, 'function')
})

test('an external runner module is loaded through the same interface', async () => {
  const runner = await createRunner('fake', { runnerModule: FAKE_RUNNER_PATH })
  assert.equal(runner.name, 'fake')
  assert.deepEqual(await runner.run('ok-one'), { exitCode: 0, stdout: 'ok\n', stderr: '' })
  assert.deepEqual(await runner.run('missing-one'), { exitCode: 127, stdout: '', stderr: 'bash: git: command not found\n' })
  await runner.close()
})

test('an unknown runner reports the locations it searched', async () => {
  await assert.rejects(createRunner('definitely-not-a-runner'), /unknown runner 'definitely-not-a-runner'/)
})

test('coverage CLI classifies the fake runner corpus and enforces a threshold', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-coverage-'))
  try {
    const corpusPath = join(directory, 'corpus.jsonl')
    const outPath = join(directory, 'report')
    const commands = [
      ['ok-one', 'text'],
      ['ok-two', 'text'],
      ['missing-one', 'git'],
      ['loop-one', 'script'],
      ['syntax-one', 'script'],
      ['unavailable-one', 'files'],
      ['broken-one', 'text'],
      ['boom-one', 'script'],
    ]
    writeFileSync(corpusPath, commands.map(([cmd, category]) => `${JSON.stringify({ cmd, category })}\n`).join(''))

    const failed = runCoverage([
      '--runner', 'fake',
      '--runner-module', FAKE_RUNNER_PATH,
      '--corpus', corpusPath,
      '--out', outPath,
      '--threshold', '90',
    ])
    assert.equal(failed.status, 1, failed.stderr)
    assert.match(failed.stdout, /coverage: 25\.0% \(2\/8 ok\)/)
    const report = JSON.parse(readFileSync(join(outPath, 'coverage-report.json'), 'utf8'))
    assert.equal(report.commands, 8)
    assert.equal(report.ok, 2)
    assert.equal(report.passed, false)
    assert.equal(report.threshold, 90)
    assert.deepEqual(report.byStatus, {
      ok: 2,
      'syntax-unsupported': 2,
      'command-missing': 2,
      'runtime-error': 2,
    })
    assert.deepEqual(report.syntaxUnsupported, { for: 1, unknown: 1 })
    assert.deepEqual(report.commandMissing, { git: 1, ln: 1 })
    const failures = report.failures.map((failure) => failure.cmd)
    assert.deepEqual(failures, ['missing-one', 'loop-one', 'syntax-one', 'unavailable-one', 'broken-one', 'boom-one'])
    assert.ok(existsSync(join(outPath, 'coverage-report.md')))
    const markdown = readFileSync(join(outPath, 'coverage-report.md'), 'utf8')
    assert.match(markdown, /\| ok \| 2 \|/)
    assert.match(markdown, /## Missing programs/)
    assert.match(markdown, /\| git \| 1 \|/)

    const passed = runCoverage([
      '--runner', 'fake',
      '--runner-module', FAKE_RUNNER_PATH,
      '--corpus', corpusPath,
      '--out', outPath,
      '--threshold', '20',
    ])
    assert.equal(passed.status, 0, passed.stderr)
    assert.match(passed.stdout, /threshold: met/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('coverage CLI rejects an out-of-range threshold', () => {
  const result = runCoverage(['--threshold', '101'])
  assert.equal(result.status, 2)
  assert.match(result.stderr, /between 0 and 100/)
})

test('parseCorpus rejects malformed lines and keeps categories', () => {
  const entries = parseCorpus('{"cmd":"ls","category":"files"}\n\n{"cmd":"pwd"}')
  assert.deepEqual(entries, [
    { cmd: 'ls', category: 'files', origin: undefined },
    { cmd: 'pwd', category: 'uncategorized', origin: undefined },
  ])
  assert.throws(() => parseCorpus('{"cmd":""}'), /no command string/)
  assert.throws(() => parseCorpus('not json'), /not JSON/)
})

test('coverage CLI --golden runs stdout vectors and folds them into pass/fail', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-coverage-golden-'))
  try {
    const corpusPath = join(directory, 'corpus.jsonl')
    writeFileSync(corpusPath, `${JSON.stringify({ cmd: 'ok-one', category: 'text' })}\n`)
    const goldenPath = fileURLToPath(new URL('./golden/worker-shell.jsonl', import.meta.url))
    const passing = runCoverage([
      '--runner', 'fake',
      '--runner-module', FAKE_RUNNER_PATH,
      '--corpus', corpusPath,
      '--out', join(directory, 'pass'),
      '--golden', goldenPath,
    ])
    assert.equal(passing.status, 0, `${passing.stdout}\n${passing.stderr}`)
    const vectorCount = readFileSync(goldenPath, 'utf8').split('\n').filter(line => line.trim() !== '').length
    assert.ok(vectorCount >= 300, `the golden corpus must hold at least 300 vectors, found ${String(vectorCount)}`)
    assert.match(passing.stdout, new RegExp(`golden: ${String(vectorCount)}/${String(vectorCount)} vectors passed`, 'u'))
    const report = JSON.parse(readFileSync(join(directory, 'pass', 'coverage-report.json'), 'utf8'))
    assert.equal(report.golden.failed, 0)
    assert.equal(report.passed, true)
    const markdown = readFileSync(join(directory, 'pass', 'coverage-report.md'), 'utf8')
    assert.match(markdown, /## Golden vectors/)

    const divergent = fileURLToPath(new URL('./golden/fixtures/divergent.jsonl', import.meta.url))
    const failing = runCoverage([
      '--runner', 'fake',
      '--runner-module', FAKE_RUNNER_PATH,
      '--corpus', corpusPath,
      '--out', join(directory, 'fail'),
      '--golden', divergent,
    ])
    assert.equal(failing.status, 1)
    const failedReport = JSON.parse(readFileSync(join(directory, 'fail', 'coverage-report.json'), 'utf8'))
    assert.equal(failedReport.golden.failed, 1)
    assert.equal(failedReport.passed, false)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
