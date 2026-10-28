// SPDX-License-Identifier: MIT
// The class-contract gate of the Worker command surface (ENG-02).
//
// `contract.mjs` is the CI gate the task names: it runs the committed gold
// corpus against the real command table and then drives the exit taxonomy and
// stderr-trailer protocol directly. These tests keep the gate itself honest:
// the committed corpus passes, and a corpus that encodes a silent success
// (0 bytes at exit 0) or drifts from the trailer protocol fails it.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  MAX_EXPECTED_DEVIATIONS,
  MIN_GOLDEN_VECTORS,
  auditCorpus,
  auditTrailers,
  main,
  runContract,
} from './contract.mjs'
import { parseGolden } from './golden.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const pluginRoot = resolve(here, '..', '..')
const contractCli = resolve(here, 'contract.mjs')
const fixtures = resolve(here, 'golden', 'fixtures')

/** One record, unique name, simple echo vector. */
function echoVector(index, extra = {}) {
  return {
    name: `fixture/echo-${String(index)}`,
    category: 'text',
    cmd: `echo ${String(index)}`,
    expect: { stdout: `${String(index)}\n`, exit: 0 },
    ...extra,
  }
}

/** Write a JSONL fixture into a fresh temp directory. */
function writeCorpus(vectors) {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-contract-corpus-'))
  const path = join(directory, 'corpus.jsonl')
  writeFileSync(path, `${vectors.map(vector => JSON.stringify(vector)).join('\n')}\n`)
  return path
}

test('contract: the committed corpus and every taxonomy check pass', () => {
  const result = spawnSync(process.execPath, [contractCli, '--quiet'], {
    cwd: pluginRoot,
    encoding: 'utf8',
    timeout: 300_000,
  })
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /contract: PASS/u)
  const normal = spawnSync(process.execPath, [contractCli], {
    cwd: pluginRoot,
    encoding: 'utf8',
    timeout: 300_000,
  })
  assert.equal(normal.status, 0, `${normal.stdout}\n${normal.stderr}`)
  const match = /contract: (\d+)\/(\d+) golden vectors passed/u.exec(normal.stdout)
  assert.ok(match !== null, normal.stdout)
  assert.ok(Number(match[2]) >= MIN_GOLDEN_VECTORS, `only ${match[2]} vectors`)
  for (const family of ['tar=', 'gzip=', 'find=', 'grep=', 'stat=', 'awk=', 'realpath=', 'readlink=', 'seq=', 'command-v=', 'which=', 'python=', 'rg=', 'curl=', 'cmp=', 'sort-zero=', 'du-human=', 'gnu-conventions=', 'jq-inputs=', 'redirection=', 'devnull=']) {
    assert.match(normal.stdout, new RegExp(` ${family}\\d+`, 'u'))
  }
  assert.match(normal.stdout, /^ok +taxonomy\/unknown-program-trailer-snapshot$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/zero-byte-gzip-success-is-illegal$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/python-alias-dispatches-python3$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/pipeline-throughput-is-not-final-output$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/od-N-bounds-format-work$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/a05-probe-sequence-has-no-ambiguous-answer$/mu)
  assert.match(normal.stdout, /^ok +taxonomy\/a05-probe-budget-significant-drop$/mu)
  assert.match(normal.stdout, /contract: A05 probe requests 26 -> 9 \(65\.4% fewer, 0 ambiguous, deliverable complete\)/u)
})

test('contract: the A05 probe budget locks the recorded baseline and the fixed replay', async () => {
  const { status, report } = await runContract({ quiet: true })
  assert.equal(status, 0, report.errors.join('\n'))
  // 26 is the recorded first-batch cost (shell-ext/src/command-paths.ts); the
  // fixed replay asks the same capability questions once each and every answer
  // is definitive, so no answer forces a retry.
  assert.deepEqual(report.a05, { baseline: 26, fixed: 9, ambiguous: 0, dropPercent: 65.4, deliverable: true })
})

test('contract: a corpus that encodes a 0-byte exit-0 gzip fails the gate', () => {
  const result = spawnSync(process.execPath, [contractCli, '--golden', join(fixtures, 'silent-zero.jsonl')], {
    cwd: pluginRoot,
    encoding: 'utf8',
    timeout: 300_000,
  })
  assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /fixture\/silent-zero-gzip/u)
  assert.match(result.stdout, /exitCode expected 0, got 1/u)
})

test('contract: a corpus below the committed-vector floor fails the gate', () => {
  const result = spawnSync(process.execPath, [contractCli, '--golden', join(fixtures, 'too-small.jsonl')], {
    cwd: pluginRoot,
    encoding: 'utf8',
    timeout: 120_000,
  })
  assert.equal(result.status, 1)
  assert.match(result.stdout, new RegExp(`at least ${String(MIN_GOLDEN_VECTORS)} are required`, 'u'))
})

test('contract: the manifest carries every expected deviation for the upstream report', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-contract-manifest-'))
  const manifest = join(directory, 'nested', 'deviations.json')
  const status = await main(['--quiet', '--manifest', manifest])
  assert.equal(status, 0)
  const report = JSON.parse(readFileSync(manifest, 'utf8'))
  assert.ok(report.vectors >= MIN_GOLDEN_VECTORS)
  // G2-FIX-89: the shell now owns `bash -n` itself, so the engine deviation
  // that recorded `-n` being read as a file no longer exists. G2-FIX-107: the
  // Worker `trap` builtin now runs the EXIT action, so `JB-TRAP` is no longer
  // a deviation; `JB-EPOCHSECONDS` remains the engine gap.
  assert.equal(report.deviations.length, 1)
  assert.deepEqual(report.upstreamGaps, ['JB-EPOCHSECONDS'])
  assert.equal(report.upstreamGaps.includes('JB-BASH-NOEXEC'), false)
})

test('corpus audit: more than the allowed deviations, or a reused gap id, fails', () => {
  const base = Array.from({ length: MIN_GOLDEN_VECTORS - 1 }, (_, index) => echoVector(index))
  const many = [...base, echoVector(999, { expectedDeviation: { upstreamGap: `GAP-${String(MAX_EXPECTED_DEVIATIONS)}` } })]
  for (let index = 0; index < MAX_EXPECTED_DEVIATIONS + 1; index += 1) {
    many.push(echoVector(1_000 + index, { expectedDeviation: { upstreamGap: `GAP-${String(index)}` } }))
  }
  const over = auditCorpus(parseGolden(many.map(JSON.stringify).join('\n')))
  assert.ok(over.errors.some(error => error.includes(`at most ${String(MAX_EXPECTED_DEVIATIONS)}`)), over.errors.join('\n'))
  const reused = auditCorpus(parseGolden([...base, echoVector(999, { expectedDeviation: { upstreamGap: 'SAME' } }), echoVector(1_000, { expectedDeviation: { upstreamGap: 'SAME' } })].map(JSON.stringify).join('\n')))
  assert.ok(reused.errors.some(error => error.includes("reuses upstream gap id 'SAME'")), reused.errors.join('\n'))
})

test('corpus audit: the required command families each carry several vectors', () => {
  const vectors = parseGolden(readFileSync(join(here, 'golden', 'worker-shell.jsonl'), 'utf8'))
  const audit = auditCorpus(vectors)
  assert.deepEqual(audit.errors, [])
  for (const [family, count] of audit.families) {
    assert.ok(count > 1, `family ${family} has only ${String(count)} vectors`)
  }
})

test('corpus audit: dropping the cmp family from the corpus fails the class gate', () => {
  // G2-D04: the POSIX byte-comparison class had no entry and no vector, so the
  // gate passed while `cmp` answered 127 not-available. The family minimum is
  // what makes that hole visible; this test locks the detection itself.
  const vectors = parseGolden(readFileSync(join(here, 'golden', 'worker-shell.jsonl'), 'utf8'))
  const audit = auditCorpus(vectors.filter(vector => !vector.name.startsWith('cmp/')))
  assert.ok(
    audit.errors.some(error => error.includes("family 'cmp'")),
    audit.errors.join('\n'),
  )
})

test('trailer audit: an unlabelled error from our layer is caught', () => {
  const vectors = parseGolden([
    JSON.stringify({ name: 'fixture/tar-error', category: 'files', cmd: 'tar --bogus', expect: { stdout: '', exit: 2 } }),
    JSON.stringify({ name: 'fixture/tar-ok', category: 'files', cmd: 'tar -tf x.tar', expect: { stdout: '', exit: 2 } }),
  ].join('\n'))
  const results = [
    { name: 'fixture/tar-error', pass: false, actual: { stdout: '', stderr: "tar: unrecognized option '--bogus'\n", exitCode: 2 } },
    {
      name: 'fixture/tar-ok',
      pass: true,
      actual: {
        stdout: '',
        stderr: "tar: x.tar: Cannot open: No such file or directory\npdsh-shell: exit=2 program=tar reason=backend-failed\n",
        exitCode: 2,
      },
    },
  ]
  const audit = auditTrailers(vectors, results)
  assert.equal(audit.errors.length, 1, audit.errors.join('\n'))
  assert.match(audit.errors[0], /fixture\/tar-error.*unlabelled error/u)
})

test('trailer audit: a 127 without the not-available reason or manifest hint is caught', () => {
  const vectors = parseGolden([
    JSON.stringify({ name: 'fixture/unknown-no-trailer', category: 'shell', cmd: 'pdsh-nope', expect: { stdout: '', exit: 127 } }),
    JSON.stringify({ name: 'fixture/unknown-no-hint', category: 'shell', cmd: 'pdsh-nope2', expect: { stdout: '', exit: 127 } }),
  ].join('\n'))
  const results = [
    { name: 'fixture/unknown-no-trailer', pass: true, actual: { stdout: '', stderr: 'bash: pdsh-nope: command not found\n', exitCode: 127 } },
    {
      name: 'fixture/unknown-no-hint',
      pass: true,
      actual: { stdout: '', stderr: 'bash: pdsh-nope2: command not found\npdsh-shell: exit=127 program=pdsh-nope2 reason=not-available\n', exitCode: 127 },
    },
  ]
  const audit = auditTrailers(vectors, results)
  assert.ok(audit.errors.some(error => error.includes('127 without reason=not-available')), audit.errors.join('\n'))
  assert.ok(audit.errors.some(error => error.includes('without the manifest hint')), audit.errors.join('\n'))
})

test('trailer audit: a trailer status that disagrees with the command status is caught', () => {
  const vector = parseGolden(JSON.stringify({ name: 'fixture/exit-mismatch', category: 'files', cmd: 'gzip -Q', expect: { stdout: '', exit: 2 } }))
  const audit = auditTrailers(vector, [{
    name: 'fixture/exit-mismatch',
    pass: true,
    actual: { stdout: '', stderr: "gzip: invalid option -- 'Q'\npdsh-shell: exit=1 program=gzip reason=unsupported-option\n", exitCode: 2 },
  }])
  assert.ok(audit.errors.some(error => error.includes('trailer exit=1')), audit.errors.join('\n'))
})

test('corpus audit: a vector authored in the compact cmd/fixture/expect shape is accepted', () => {
  const corpus = writeCorpus([
    {
      name: 'fixture/compact-shape',
      category: 'files',
      cmd: 'cat f.txt',
      fixture: { 'f.txt': 'x\n' },
      stdin: '',
      expect: { stdout: 'x\n', stderrPrefix: '', exit: 0 },
    },
  ])
  const vectors = parseGolden(readFileSync(corpus, 'utf8'))
  assert.equal(vectors[0].script, 'cat f.txt')
  assert.deepEqual(vectors[0].files, { 'f.txt': 'x\n' })
  assert.equal(vectors[0].exitCode, 0)
})
