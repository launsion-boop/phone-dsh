// SPDX-License-Identifier: MIT
// G2-A05 probe-budget evidence (ENG-02 repair).
//
// The first real-model batch spent 26 model requests probing an environment
// whose `tar` answered a bare 127 and whose `gzip` reported a 0-byte success.
// `probe-budget.mjs` replays the same capability questions against the real
// command table and requires a definitive answer on the first request plus at
// least a halved count. These tests keep the evidence honest: the recorded
// baseline and the fixed replay both have to be present, a re-introduced silent
// 0-byte gzip has to fail the gate, and the `--compare` path has to apply the
// same rule to real scenario `report.json` files.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { defineCommand } from 'just-bash/browser'
import {
  A05_BASELINE,
  A05_PROBES,
  classifyAnswer,
  compareProbeBudget,
  main,
  runProbeReplay,
  scenarioModelRequests,
} from './probe-budget.mjs'
import { VfsFileSystem, WorkerShell, createWorkerCommands } from '../../shell-ext/src/index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const pluginRoot = resolve(here, '..', '..')
const cli = join(here, 'probe-budget.mjs')

/** A command table with the recorded pre-fix lies: no tar, a silent 0-byte gzip. */
function legacyCommands() {
  return [
    defineCommand('gzip', async () => ({ stdout: '', stderr: '', exitCode: 0 })),
  ]
}

test('a05 probe budget: the fixed surface halves the recorded 26 requests with no retry', async () => {
  const replay = await runProbeReplay()
  assert.equal(replay.baseline.scenario, 'G2-A05')
  assert.equal(replay.baseline.modelRequests, 26)
  assert.equal(A05_BASELINE.modelRequests, 26)
  assert.equal(replay.probes.length, A05_PROBES.length)
  assert.equal(replay.counts.ambiguous, 0, JSON.stringify(replay.probes.filter(probe => !probe.definitive)))
  assert.equal(replay.counts.definitive, replay.counts.requests)
  assert.equal(replay.counts.forcedRetries, 0)
  assert.ok(replay.counts.requests * 2 <= replay.baseline.modelRequests, `${String(replay.counts.requests)} requests`)
  assert.equal(replay.deliverable.complete, true, JSON.stringify(replay.deliverable.steps))
  const verdict = compareProbeBudget(replay)
  assert.equal(verdict.pass, true, JSON.stringify(verdict.checks))
  assert.equal(verdict.dropPercent, 65.4)
})

test('a05 probe budget: the two recorded silent lies are now definitive answers', async (t) => {
  const replay = await runProbeReplay()
  const byName = new Map(replay.probes.map(probe => [probe.name, probe]))
  // G2-A05 transcript:18 - `tar` was a bare 127. It now answers with a version.
  assert.equal(byName.get('archiver-version')?.exitCode, 0)
  assert.equal(byName.get('archiver-version')?.outcome, 'ok')
  // G2-A05 transcript:45-46 - `gzip` wrote 0 bytes and exited 0. The member is
  // now real (the success predicate decompresses it) or the command fails with
  // a trailer; a 0-byte exit 0 can never be classified definitive.
  assert.equal(byName.get('gzip-member')?.outcome, 'ok')
  // The fabricated `command -v` path is gone: the path it prints executes.
  assert.equal(byName.get('archiver-path')?.outcome, 'ok')
  const root = mkdtempSync(join(tmpdir(), 'pdsh-a05-path-'))
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  const resolved = await shell.run(['bash', '-c', 'p=$(command -v tar) && test -n "$p" && "$p" --version'], { cwd: '/dsh/workspace' })
  assert.equal(resolved.exitCode, 0, resolved.stderr)
  assert.match(resolved.stdout, /^tar \(/u)
})

test('a05 probe budget: a re-introduced silent 0-byte gzip fails the gate', async () => {
  const replay = await runProbeReplay({ commands: legacyCommands() })
  const gzipProbe = replay.probes.find(probe => probe.name === 'gzip-member')
  assert.equal(gzipProbe?.exitCode, 0, 'the injected stub reproduces the recorded exit 0')
  assert.equal(gzipProbe?.outcome, 'ambiguous', 'a 0-byte success must be ambiguous')
  assert.equal(gzipProbe?.definitive, false)
  assert.ok(replay.counts.ambiguous > 0)
  assert.equal(replay.deliverable.complete, false, 'a table without tar cannot deliver the archive')
  const verdict = compareProbeBudget(replay)
  assert.equal(verdict.pass, false, JSON.stringify(verdict.checks))
  assert.equal(verdict.checks.find(check => check.name === 'the A05 deliverable completes')?.pass, false)
})

test('a05 probe budget: classifyAnswer separates definitive failures from silent lies', () => {
  // Exit 0 with bytes: definitive.
  assert.deepEqual(
    classifyAnswer({ exitCode: 0, stdout: 'tar (Worker shell', stderr: '' }, true),
    { definitive: true, outcome: 'ok', why: 'exit 0 with the promised bytes/artifact' },
  )
  // Exit 0 with no bytes where bytes were promised: the 0-byte success lie.
  assert.equal(classifyAnswer({ exitCode: 0, stdout: '', stderr: '' }, false).definitive, false)
  // A bare 127: the model cannot tell what the Worker provides.
  assert.equal(classifyAnswer({ exitCode: 127, stdout: '', stderr: 'bash: tar: command not found\n' }, false).definitive, false)
  // A 127 with the manifest hint: definitive, no second request needed.
  const labelled = classifyAnswer({
    exitCode: 127,
    stdout: '',
    stderr: 'bash: unzip: command not found\npdsh-shell: exit=127 program=unzip reason=not-available hint=see /dsh/home/capabilities.json\n',
  }, false)
  assert.equal(labelled.definitive, true)
  assert.equal(labelled.outcome, 'unavailable')
  // A trailer whose status disagrees with the command is not a parseable answer.
  assert.equal(classifyAnswer({
    exitCode: 127,
    stdout: '',
    stderr: 'pdsh-shell: exit=2 program=tar reason=unsupported-option\n',
  }, false).definitive, false)
})

test('a05 probe budget: --compare applies the halving rule to scenario reports', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-a05-reports-'))
  const baseline = join(directory, 'baseline.json')
  const rerun = join(directory, 'rerun.json')
  const tooClose = join(directory, 'too-close.json')
  writeFileSync(baseline, JSON.stringify({ status: 'BUDGET', usage: { model_requests: 26, tool_calls: 31 }, turns: [] }))
  writeFileSync(rerun, JSON.stringify({ status: 'PASS', usage: { model_requests: 9, tool_calls: 11 }, turns: [] }))
  writeFileSync(tooClose, JSON.stringify({ status: 'PASS', usage: { model_requests: 20, tool_calls: 25 }, turns: [] }))
  assert.equal(scenarioModelRequests(baseline).modelRequests, 26)
  assert.equal(scenarioModelRequests(baseline).status, 'BUDGET')
  assert.equal(await main(['--compare', baseline, rerun]), 0)
  assert.equal(await main(['--compare', baseline, tooClose]), 1)
  assert.equal(await main(['--compare', baseline]), 2)
})

test('a05 probe budget: the CLI is the gate shape the check command runs', () => {
  const result = spawnSync(process.execPath, [cli, '--quiet'], { cwd: pluginRoot, encoding: 'utf8', timeout: 300_000 })
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /probe-budget: PASS/u)
})
