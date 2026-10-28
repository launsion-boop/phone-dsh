// SPDX-License-Identifier: MIT
/**
 * G2-A05 probe-request budget: the recorded pre-fix run against the production
 * command surface.
 *
 * Scenario G2-A05 ("repeatable backup script") asks the Worker for a `tar -czf`
 * archive plus a `sha256` file. In the first real-model batch the model burned
 * **26 model requests probing the environment** (the count is recorded in
 * `shell-ext/src/command-paths.ts`, which fixes the fabricated-PATH cause)
 * because two answers were silent lies:
 *
 * - `tar` answered 127 with no statement about what the Worker does provide, so
 *   the model retried spellings and fallback programs;
 * - `gzip` answered exit 0 while the browser Worker's `node:zlib` stub produced
 *   no member, and `command -v` answered a `/usr/bin/...` path that could not
 *   execute.
 *
 * This module turns the rerun comparison into a deterministic gate instead of a
 * sentence in a report. It replays the capability questions the A05 script
 * needs against the real `createWorkerCommands` table and counts:
 *
 * - **probe requests**: one shell request per capability question;
 * - **definitive answers**: an answer the model can act on without probing
 *   again - either a success with the promised bytes/artifact, or a failure
 *   carrying the class-contract trailer (`pdsh-shell: exit=… reason=…`), whose
 *   `not-available` hint names `/dsh/home/capabilities.json`;
 * - **ambiguous answers**: a 127 with no trailer, or exit 0 with the promised
 *   bytes/artifact missing - each one forces at least one more request.
 *
 * The fixed surface must answer every question definitively on the first
 * request (no forced retries) and must at least halve the recorded baseline.
 * When the real-model batch is unpaused, `--compare` reads two scenario
 * `report.json` files and applies the same "at least halved" rule to their
 * `usage.model_requests`, which is the recorded metric.
 *
 * Usage:
 *   node tools/shell-corpus/probe-budget.mjs [--json] [--quiet]
 *   node tools/shell-corpus/probe-budget.mjs --compare <baseline-report.json> <rerun-report.json>
 *
 * Exit status: 0 when the comparison passes, 1 when it does not, 2 on bad
 * arguments or an unreadable report.
 * @module tools/shell-corpus/probe-budget
 */

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { gunzipSync } from 'node:zlib'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  parseShellTrailer,
} from '../../shell-ext/src/index.ts'

/** Working directory of every A05 request. */
export const A05_CWD = '/dsh/workspace'

/** The three notes files the scenario's workspace starts with. */
export const A05_NOTES = Object.freeze(['notes/a.md', 'notes/b.md', 'notes/c.md'])

/**
 * The recorded first-batch cost of G2-A05.
 *
 * `command-paths.ts` records that the scenario "burned 26 turns probing the
 * environment"; the catalog budget is 25 model requests (`max_model_requests`),
 * so the ambiguity overran the scenario budget. This is a recorded measurement,
 * not a projection: the first real-model batch produced it.
 */
export const A05_BASELINE = Object.freeze({
  scenario: 'G2-A05',
  modelRequests: 26,
  maxModelRequests: 25,
  source: 'first real-model batch: 26 requests, recorded while fixing the fabricated-PATH cause in shell-ext/src/command-paths.ts; scenario budget max_model_requests=25',
})

/** The `backup.sh` the scenario asks for (its own text is part of the check). */
export const A05_BACKUP_SCRIPT = `#!/usr/bin/env bash
# usage: bash backup.sh -- rebuild notes-backup.tar.gz and its sha256 file
set -u
tar -czf notes-backup.tar.gz notes
sha256sum notes-backup.tar.gz > notes-backup.sha256
wc -c < notes-backup.tar.gz
`

/** Parse the trailer lines of one stderr stream. */
function trailerLines(stderr) {
  return stderr
    .split('\n')
    .map(line => parseShellTrailer(line))
    .filter(trailer => trailer !== undefined)
}

/** True when the file is a complete gzip member (magic and trailer present). */
function isGzipFile(path) {
  try {
    const bytes = readFileSync(path)
    if (bytes.byteLength < 18) return false
    if (bytes[0] !== 0x1f || bytes[1] !== 0x8b || bytes[2] !== 0x08) return false
    gunzipSync(bytes)
    return true
  } catch {
    return false
  }
}

/** The archive members of `probe.tgz`, read through the production `tar`. */
function archiveMembers(result) {
  return result.stdout.trimEnd().split('\n').filter(member => member !== '')
}

/**
 * The capability questions A05's script depends on.
 *
 * Each `success` decides whether an exit-0 answer delivered what the question
 * promised; a non-zero answer is definitive only when it carries the contract
 * trailer (see {@link classifyAnswer}).
 */
export const A05_PROBES = Object.freeze([
  {
    name: 'archiver-version',
    question: 'is tar available and what is it?',
    script: 'tar --version',
    success: ({ result }) => /^tar \(/u.test(result.stdout),
  },
  {
    name: 'archiver-path',
    question: 'does the path command -v prints actually execute?',
    script: 'p=$(command -v tar) && test -n "$p" && "$p" --version',
    success: ({ result }) => /^tar \(/u.test(result.stdout),
  },
  {
    name: 'archiver-create',
    question: 'can tar create a gzip archive of the notes tree?',
    script: 'tar -czf probe.tgz notes',
    success: ({ root }) => isGzipFile(join(root, A05_CWD, 'probe.tgz')),
  },
  {
    name: 'gzip-member',
    question: 'does gzip produce a real member on stdout?',
    script: "printf 'probe\\n' | gzip > probe.gz",
    success: ({ root }) => {
      const path = join(root, A05_CWD, 'probe.gz')
      if (!existsSync(path) || statSync(path).size < 18) return false
      return gunzipSync(readFileSync(path)).toString('utf8') === 'probe\n'
    },
  },
  {
    name: 'gunzip-member',
    question: 'can the Worker expand its own member?',
    script: 'gunzip -c probe.gz',
    success: ({ result }) => result.stdout === 'probe\n',
  },
  {
    name: 'archiver-list',
    question: 'does the archive list the three notes files?',
    script: 'tar -tzf probe.tgz',
    success: ({ result }) => {
      const members = archiveMembers(result).sort()
      return JSON.stringify(members) === JSON.stringify(['notes/', ...A05_NOTES].sort())
    },
  },
  {
    name: 'checksum',
    question: 'is sha256sum a real, usable checksum program?',
    script: 'sha256sum probe.tgz',
    success: ({ result }) => /^[0-9a-f]{64} {2}probe\.tgz\n$/u.test(result.stdout),
  },
  {
    name: 'python3-fallback',
    question: 'is the python3 fallback available?',
    script: "python3 -c 'import tarfile'",
    success: () => true,
  },
  {
    name: 'unzip-fallback',
    question: 'is the unzip fallback available?',
    script: 'unzip -l probe.tgz',
    success: () => true,
  },
])

/**
 * Classify one answer the way a model decides whether to probe again.
 *
 * @param {{exitCode: number, stdout: string, stderr: string}} result - shell result.
 * @param {boolean} success - whether the answer delivered its promised bytes.
 * @returns {{definitive: boolean, outcome: 'ok'|'unavailable'|'ambiguous', why: string}} classification.
 */
export function classifyAnswer(result, success) {
  const trailers = trailerLines(result.stderr)
  if (result.exitCode === 0) {
    if (!success) {
      return { definitive: false, outcome: 'ambiguous', why: 'exit 0 with the promised bytes/artifact missing or invalid' }
    }
    return { definitive: true, outcome: 'ok', why: 'exit 0 with the promised bytes/artifact' }
  }
  const trailer = trailers[0]
  if (trailer !== undefined && trailer.exitCode === result.exitCode) {
    return { definitive: true, outcome: 'unavailable', why: `exit ${String(result.exitCode)} with reason=${trailer.reason}` }
  }
  return {
    definitive: false,
    outcome: 'ambiguous',
    why: `exit ${String(result.exitCode)} without a contract trailer`,
  }
}

/** Build a VFS root seeded with the A05 workspace. */
function createRoot() {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-a05-budget-'))
  for (const directory of [A05_CWD, '/dsh/home', '/dsh/tmp', join(A05_CWD, 'notes')]) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  for (const relative of A05_NOTES) {
    writeFileSync(join(root, A05_CWD, relative), `# ${relative.slice(relative.lastIndexOf('/') + 1)}\n`)
  }
  return root
}

/** Run one request against the shell. */
async function request(shell, script) {
  return await shell.run(['bash', '-c', script], { cwd: A05_CWD, timeoutMs: 30_000 })
}

/** Replay the scenario's deliverable and verify the artifacts it promises. */
async function replayDeliverable(shell, root) {
  const steps = []
  const record = (name, pass, detail) => { steps.push({ name, pass, detail }) }

  const written = await request(shell, `cat > backup.sh <<'BACKUP'\n${A05_BACKUP_SCRIPT}BACKUP`)
  record(
    'write-backup-script',
    written.exitCode === 0 && existsSync(join(root, A05_CWD, 'backup.sh')),
    `exit=${String(written.exitCode)} stderr=${JSON.stringify(written.stderr)}`,
  )

  const ran = await request(shell, 'bash backup.sh')
  record(
    'run-backup-script',
    ran.exitCode === 0 && /^\d+\n$/u.test(ran.stdout) && Number(ran.stdout.trim()) > 0,
    `exit=${String(ran.exitCode)} stdout=${JSON.stringify(ran.stdout)} stderr=${JSON.stringify(ran.stderr)}`,
  )

  const archive = join(root, A05_CWD, 'notes-backup.tar.gz')
  const checksumFile = join(root, A05_CWD, 'notes-backup.sha256')
  const archiveOk = isGzipFile(archive)
  const checksumText = existsSync(checksumFile) ? readFileSync(checksumFile, 'utf8') : ''
  const checksumOk = archiveOk
    && /^[0-9a-f]{64} {2}notes-backup\.tar\.gz\n$/u.test(checksumText)
    && checksumText.slice(0, 64) === createHash('sha256').update(readFileSync(archive)).digest('hex')
  record(
    'verify-archive-and-checksum',
    archiveOk && checksumOk,
    `archive=${String(archiveOk)} checksum=${String(checksumOk)}`,
  )

  const listed = await request(shell, 'tar -tzf notes-backup.tar.gz')
  const members = archiveMembers(listed).sort()
  record(
    'archive-lists-notes',
    listed.exitCode === 0 && JSON.stringify(members) === JSON.stringify(['notes/', ...A05_NOTES].sort()),
    `exit=${String(listed.exitCode)} members=${JSON.stringify(members)}`,
  )

  const again = await request(shell, 'bash backup.sh')
  const rerunChecksum = existsSync(checksumFile) ? readFileSync(checksumFile, 'utf8') : ''
  const rerunArchiveOk = isGzipFile(archive)
  record(
    'run-backup-script-again',
    again.exitCode === 0
      && /^\d+\n$/u.test(again.stdout)
      && rerunArchiveOk
      && rerunChecksum.slice(0, 64) === createHash('sha256').update(readFileSync(archive)).digest('hex'),
    `exit=${String(again.exitCode)} stdout=${JSON.stringify(again.stdout)}`,
  )

  return { steps, complete: steps.every(step => step.pass) }
}

/**
 * Replay every A05 capability question and the deliverable.
 *
 * @param {{commands?: import('just-bash/browser').CustomCommand[]}} options -
 *   command table override (the defect-injection tests use it); the default is
 *   the production `createWorkerCommands` table.
 * @returns {Promise<object>} per-probe answers, deliverable steps and counts.
 */
export async function runProbeReplay(options = {}) {
  const root = createRoot()
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const commands = options.commands ?? createWorkerCommands({ git: false, toolbox: false, curl: false })
  const shell = new WorkerShell({ fs, commands })
  try {
    const probes = []
    for (const probe of A05_PROBES) {
      const result = await request(shell, probe.script)
      const success = result.exitCode === 0 && probe.success({ result, root })
      const answer = classifyAnswer(result, success)
      probes.push({
        name: probe.name,
        question: probe.question,
        script: probe.script,
        exitCode: result.exitCode,
        stdoutBytes: Buffer.byteLength(result.stdout, 'utf8'),
        stderr: result.stderr,
        ...answer,
      })
    }
    const deliverable = await replayDeliverable(shell, root)
    const ambiguous = probes.filter(probe => !probe.definitive)
    return {
      baseline: A05_BASELINE,
      probes,
      deliverable,
      counts: {
        requests: probes.length,
        definitive: probes.length - ambiguous.length,
        ambiguous: ambiguous.length,
        // Every ambiguous answer is an answer the model cannot act on, so a
        // real run issues at least one more request for it.
        forcedRetries: ambiguous.length,
      },
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

/**
 * Apply the G2-A05 acceptance rule to one replay.
 *
 * @param {object} replay - output of {@link runProbeReplay}.
 * @returns {{pass: boolean, dropPercent: number, checks: object[]}} verdict.
 */
export function compareProbeBudget(replay) {
  const baseline = replay.baseline.modelRequests
  const fixed = replay.counts.requests
  const dropPercent = Math.round(((baseline - fixed) / baseline) * 1000) / 10
  const checks = [
    {
      name: 'every probe answer is definitive',
      pass: replay.counts.ambiguous === 0,
      detail: replay.probes
        .filter(probe => !probe.definitive)
        .map(probe => `${probe.name}: ${probe.why}`)
        .join('; ') || 'no ambiguous answer needs a second probe',
    },
    {
      name: 'no probe forces a retry',
      pass: replay.counts.forcedRetries === 0,
      detail: `${String(replay.counts.forcedRetries)} forced retr${replay.counts.forcedRetries === 1 ? 'y' : 'ies'}`,
    },
    {
      name: 'probe requests at least halve',
      pass: fixed * 2 <= baseline,
      detail: `${String(baseline)} -> ${String(fixed)} (${String(dropPercent)}% fewer)`,
    },
    {
      name: 'the A05 deliverable completes',
      pass: replay.deliverable.complete,
      detail: replay.deliverable.steps
        .filter(step => !step.pass)
        .map(step => `${step.name}: ${step.detail}`)
        .join('; ') || 'backup.sh runs twice with a valid archive and checksum',
    },
  ]
  return { pass: checks.every(check => check.pass), dropPercent, checks }
}

/** Read the recorded model-request count from one scenario result directory. */
export function scenarioModelRequests(reportPath) {
  const path = resolve(reportPath)
  const report = JSON.parse(readFileSync(path, 'utf8'))
  const turns = Array.isArray(report.turns) ? report.turns : []
  const requests = report.usage?.model_requests
    ?? turns.reduce((sum, turn) => sum + (Number(turn.model_requests) || 0), 0)
  const toolCalls = report.usage?.tool_calls
    ?? turns.reduce((sum, turn) => sum + (Number(turn.tool_calls) || 0), 0)
  return {
    path,
    status: typeof report.status === 'string' ? report.status : 'unknown',
    modelRequests: Number(requests) || 0,
    toolCalls: Number(toolCalls) || 0,
  }
}

/** Print the replay summary. */
function describe(replay, verdict) {
  const lines = []
  lines.push(`probe-budget: recorded baseline ${replay.baseline.scenario}: ${String(replay.baseline.modelRequests)} model requests probing the environment (budget ${String(replay.baseline.maxModelRequests)})`)
  lines.push(`probe-budget: fixed surface: ${String(replay.counts.requests)} probe requests, ${String(replay.counts.definitive)} definitive answers, ${String(replay.counts.ambiguous)} ambiguous`)
  lines.push(`probe-budget: probe requests ${String(replay.baseline.modelRequests)} -> ${String(replay.counts.requests)} (${String(verdict.dropPercent)}% fewer)`)
  lines.push(`probe-budget: deliverable: ${replay.deliverable.complete ? 'backup.sh runs twice, archive lists 3 notes, sha256 matches' : 'incomplete'}`)
  for (const check of verdict.checks) lines.push(`${check.pass ? 'ok  ' : 'FAIL'} ${check.name}${check.pass ? '' : ` — ${check.detail}`}`)
  return lines.join('\n')
}

/**
 * CLI entry point.
 * @param {string[]} argv - arguments after the script name.
 * @returns {Promise<number>} process exit status.
 */
export async function main(argv) {
  let json = false
  let quiet = false
  let compare
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      process.stdout.write('usage: node tools/shell-corpus/probe-budget.mjs [--json] [--quiet] [--compare BASELINE_REPORT RERUN_REPORT]\n')
      return 0
    }
    if (argument === '--json') { json = true; continue }
    if (argument === '--quiet') { quiet = true; continue }
    if (argument === '--compare') {
      const baseline = argv[index + 1]
      const rerun = argv[index + 2]
      if (baseline === undefined || rerun === undefined) {
        process.stderr.write('probe-budget: --compare needs a baseline and a rerun report.json\n')
        return 2
      }
      compare = { baseline, rerun }
      index += 2
      continue
    }
    process.stderr.write(`probe-budget: unknown argument '${argument}'\n`)
    return 2
  }

  if (compare !== undefined) {
    let baseline
    let rerun
    try {
      baseline = scenarioModelRequests(compare.baseline)
      rerun = scenarioModelRequests(compare.rerun)
    } catch (error) {
      process.stderr.write(`probe-budget: cannot read a scenario report (${error instanceof Error ? error.message : String(error)})\n`)
      return 2
    }
    const pass = rerun.modelRequests * 2 <= baseline.modelRequests && rerun.modelRequests > 0
    const drop = baseline.modelRequests === 0
      ? 0
      : Math.round(((baseline.modelRequests - rerun.modelRequests) / baseline.modelRequests) * 1000) / 10
    const result = { pass, baseline, rerun, dropPercent: drop }
    if (json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
    else {
      process.stdout.write(`probe-budget: baseline ${compare.baseline}: ${String(baseline.modelRequests)} model requests (${baseline.status})\n`)
      process.stdout.write(`probe-budget: rerun ${compare.rerun}: ${String(rerun.modelRequests)} model requests (${rerun.status})\n`)
      process.stdout.write(`probe-budget: drop ${String(baseline.modelRequests)} -> ${String(rerun.modelRequests)} (${String(drop)}% fewer)\n`)
    }
    process.stdout.write(`probe-budget: ${pass ? 'PASS' : 'FAIL'}\n`)
    return pass ? 0 : 1
  }

  const replay = await runProbeReplay()
  const verdict = compareProbeBudget(replay)
  if (json) {
    process.stdout.write(`${JSON.stringify({ ...replay, verdict }, null, 2)}\n`)
  } else if (!quiet || !verdict.pass) {
    process.stdout.write(`${describe(replay, verdict)}\n`)
  }
  process.stdout.write(`probe-budget: ${verdict.pass ? 'PASS' : 'FAIL'}\n`)
  return verdict.pass ? 0 : 1
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (invokedDirectly) {
  main(process.argv.slice(2)).then((status) => {
    process.exitCode = status
  }).catch((error) => {
    process.stderr.write(`probe-budget: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`)
    process.exitCode = 2
  })
}
