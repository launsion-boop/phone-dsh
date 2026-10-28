// SPDX-License-Identifier: MIT
/**
 * W5/G2-FIX-25 golden-vector gate.
 *
 * Coverage says "the command exited 0". These vectors say "the command printed
 * exactly what GNU/POSIX prints and returned the same status". They are the
 * regression gate for the class of silent built-in divergence that reached
 * G2-A01/G2-A05: missing `tar`/`realpath`, `readlink -m`, literal `find
 * -printf %y`, the `awk -f` command line, and fabricated `command -v` paths.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  DEFAULT_GOLDEN,
  GoldenFormatError,
  parseGolden,
  runGoldenVector,
  runGoldenVectors,
} from './golden.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const vectors = parseGolden(readFileSync(DEFAULT_GOLDEN, 'utf8'))

test('golden: the committed vector file covers every G2-FIX-25 defect class', () => {
  const names = vectors.map(vector => vector.name)
  for (const required of [
    'paths/realpath-normalizes-relative',
    'paths/readlink-m-missing-tail',
    'find/printf-expands-type',
    'awk/gsub-trim-inline',
    'awk/gsub-trim-program-file',
    'tar/create-list-extract-gzip',
    'command-v/every-reported-path-exists',
    'command-v/path-directories-exist',
  ]) {
    assert.ok(names.includes(required), `missing golden vector ${required}`)
  }
  assert.ok(vectors.length >= 300, `only ${String(vectors.length)} golden vectors`)
})

for (const vector of vectors) {
  test(`golden: ${vector.name}`, async () => {
    const result = await runGoldenVector(vector)
    assert.equal(result.pass, true, JSON.stringify(result.problems, null, 2))
  })
}

test('golden: a divergent vector fails with both sides of the comparison', async () => {
  const result = await runGoldenVector({
    name: 'gate/divergence-is-caught',
    script: 'echo actual',
    stdout: 'expected\n',
    exitCode: 0,
  })
  assert.equal(result.pass, false)
  assert.deepEqual(result.problems, [{ field: 'stdout', expected: 'expected\n', actual: 'actual\n' }])
})

test('golden: a malformed vector file names the offending line', () => {
  assert.throws(() => parseGolden('{"name":"a"}\n'), (error) => error instanceof GoldenFormatError && error.line === 1)
  assert.throws(() => parseGolden('{"name":"a","script":"echo","stdout":"","exitCode":0}\n{"name":"a","script":"echo","stdout":"","exitCode":0}\n'),
    (error) => error instanceof GoldenFormatError && /duplicate/u.test((error).message))
  assert.throws(() => parseGolden('{"name":"a","script":"echo","stdout":0,"exitCode":0}\n'),
    (error) => error instanceof GoldenFormatError && /stdout/u.test((error).message))
})

test('golden: the CLI exits 0 on the committed vectors and 1 on a divergent fixture', () => {
  const cli = resolve(here, 'golden.mjs')
  const good = spawnSync(process.execPath, [cli, '--quiet'], { cwd: resolve(here, '..', '..'), encoding: 'utf8', timeout: 120_000 })
  assert.equal(good.status, 0, `${good.stdout}\n${good.stderr}`)
  const broken = spawnSync(process.execPath, [cli, '--golden', resolve(here, 'golden/fixtures/divergent.jsonl')], {
    cwd: resolve(here, '..', '..'),
    encoding: 'utf8',
    timeout: 120_000,
  })
  assert.equal(broken.status, 1, `${broken.stdout}\n${broken.stderr}`)
  assert.match(broken.stdout, /FAIL gate\/committed-expectation/u)
})

test('golden: the summary counts every vector', async () => {
  const summary = await runGoldenVectors([vectors[0]])
  assert.equal(summary.total, 1)
  assert.equal(summary.passed, 1)
  assert.equal(summary.failed, 0)
})
