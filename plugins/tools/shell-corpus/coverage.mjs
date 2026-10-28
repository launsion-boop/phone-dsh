// SPDX-License-Identifier: MIT
/**
 * Run the shell command corpus through a pluggable runner and report coverage.
 *
 * Usage:
 *   node tools/shell-corpus/coverage.mjs \
 *     [--runner runtime-js] [--runner-module FILE] \
 *     [--corpus tools/shell-corpus/corpus/public.jsonl] \
 *     [--out DIR] [--threshold PERCENT]
 *
 * The command is `ok` only when the runner exits 0. Failures are split into
 * `syntax-unsupported` (a named shell construct the runner does not implement),
 * `command-missing` (a named program) and `runtime-error`. Reports are written
 * as `coverage-report.json` and `coverage-report.md` under `--out`.
 *
 * @module tools/shell-corpus/coverage
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { classifyResult } from './classify.mjs'
import { createRunner, parseCorpus } from './runners.mjs'

/** Corpus shipped with the tool, resolved next to this module. */
export const DEFAULT_CORPUS = fileURLToPath(new URL('./corpus/public.jsonl', import.meta.url))

/** Status buckets, in report order. */
export const STATUSES = ['ok', 'syntax-unsupported', 'command-missing', 'runtime-error']

/**
 * Parse the coverage command line.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {{runner: string, runnerModule?: string, corpus: string, out: string, threshold?: number, help: boolean}} options.
 */
export function parseArguments(argv) {
  const options = {
    runner: 'runtime-js',
    runnerModule: undefined,
    corpus: DEFAULT_CORPUS,
    out: join(tmpdir(), 'pdsh-shell-corpus-coverage'),
    threshold: undefined,
    golden: undefined,
    help: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const value = argv[index + 1]
    if (argument === '--help' || argument === '-h') {
      options.help = true
      continue
    }
    if (argument === '--runner') {
      if (value === undefined) throw new Error('--runner needs a name')
      options.runner = value
      index += 1
      continue
    }
    if (argument === '--runner-module') {
      if (value === undefined) throw new Error('--runner-module needs a file')
      options.runnerModule = value
      index += 1
      continue
    }
    if (argument === '--corpus') {
      if (value === undefined) throw new Error('--corpus needs a file')
      options.corpus = value
      index += 1
      continue
    }
    if (argument === '--out') {
      if (value === undefined) throw new Error('--out needs a directory')
      options.out = value
      index += 1
      continue
    }
    if (argument === '--golden') {
      if (value === undefined) throw new Error('--golden needs a file')
      options.golden = value
      index += 1
      continue
    }
    if (argument === '--threshold') {
      if (value === undefined) throw new Error('--threshold needs a percentage')
      const threshold = Number(value)
      if (!Number.isFinite(threshold) || threshold < 0 || threshold > 100) {
        throw new Error(`--threshold must be a percentage between 0 and 100, got '${value}'`)
      }
      options.threshold = threshold
      index += 1
      continue
    }
    throw new Error(`unknown argument '${argument}'`)
  }
  return options
}

/** Print usage to standard error. */
function usage() {
  process.stderr.write(
    'usage: node coverage.mjs [--runner NAME] [--runner-module FILE] [--corpus FILE] [--out DIR] [--threshold PERCENT] [--golden FILE]\n',
  )
}

/**
 * Run every corpus command and aggregate the classification.
 *
 * @param {{cmd: string, category?: string}[]} entries - corpus entries.
 * @param {{name?: string, run: Function, start?: Function, close?: Function}} runner - shell runner.
 * @returns {Promise<object[]>} per-command results.
 */
export async function runCorpus(entries, runner) {
  await runner.start?.()
  const results = []
  try {
    for (const entry of entries) {
      let outcome
      try {
        outcome = await runner.run(entry.cmd)
      } catch (error) {
        outcome = { error: error instanceof Error ? error.message : String(error) }
      }
      const classification = classifyResult(entry.cmd, outcome)
      results.push({
        cmd: entry.cmd,
        category: entry.category ?? 'uncategorized',
        exitCode: Number.isFinite(outcome?.exitCode) ? outcome.exitCode : undefined,
        ...classification,
      })
    }
  } finally {
    await runner.close?.()
  }
  return results
}

/**
 * Build the machine-readable report object.
 *
 * @param {{runner: string, corpus: string, entries: object[], results: object[], threshold?: number}} input - run facts.
 * @returns {object} report.
 */
export function buildReport({ runner, corpus, entries, results, threshold }) {
  const byStatus = Object.fromEntries(STATUSES.map((status) => [status, 0]))
  const syntaxUnsupported = {}
  const commandMissing = {}
  const byCategory = {}
  for (const result of results) {
    byStatus[result.status] = (byStatus[result.status] ?? 0) + 1
    if (result.status === 'syntax-unsupported') {
      const construct = result.construct ?? 'unknown'
      syntaxUnsupported[construct] = (syntaxUnsupported[construct] ?? 0) + 1
    }
    if (result.status === 'command-missing') {
      const program = result.program ?? 'unknown'
      commandMissing[program] = (commandMissing[program] ?? 0) + 1
    }
    const category = (byCategory[result.category] ??= { total: 0, ok: 0, failed: 0 })
    category.total += 1
    if (result.status === 'ok') category.ok += 1
    else category.failed += 1
  }
  const total = results.length
  const ok = byStatus.ok ?? 0
  const percent = total === 0 ? 0 : Math.round((ok / total) * 1000) / 10
  const passed = threshold === undefined || (ok / Math.max(total, 1)) * 100 >= threshold
  const failures = results
    .filter((result) => result.status !== 'ok')
    .map((result) => ({
      cmd: result.cmd,
      category: result.category,
      status: result.status,
      exitCode: result.exitCode,
      ...(result.construct === undefined ? {} : { construct: result.construct }),
      ...(result.program === undefined ? {} : { program: result.program }),
      ...(result.detail === undefined ? {} : { detail: result.detail }),
    }))
  return {
    v: 1,
    runner,
    corpus,
    commands: total,
    ok,
    coveragePercent: percent,
    threshold: threshold ?? null,
    passed,
    byStatus,
    syntaxUnsupported,
    commandMissing,
    byCategory,
    failures,
    results,
  }
}

/** Escape one value for a Markdown table cell. */
function cell(value) {
  return String(value).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ')
}

/** Shorten a command for the failure table without losing its shape. */
function shortCommand(command, limit = 110) {
  return command.length > limit ? `${command.slice(0, limit - 3)}...` : command
}

/**
 * Render the human-readable Markdown report.
 *
 * @param {object} report - output of {@link buildReport}.
 * @returns {string} Markdown document.
 */
export function renderMarkdown(report) {
  const lines = []
  lines.push('# Shell corpus coverage')
  lines.push('')
  lines.push(`- Runner: \`${report.runner}\``)
  lines.push(`- Corpus: \`${report.corpus}\` (${String(report.commands)} commands)`)
  lines.push(`- Coverage: **${report.coveragePercent.toFixed(1)}%** (${String(report.ok)}/${String(report.commands)} ok)`)
  lines.push(`- Threshold: ${report.threshold === null ? 'none' : `${String(report.threshold)}%`}`)
  lines.push(`- Result: ${report.passed ? 'PASS' : 'FAIL'}`)
  lines.push('')
  if (report.golden !== undefined) {
    lines.push('## Golden vectors')
    lines.push('')
    lines.push(`- File: \`${report.golden.file}\``)
    lines.push(`- Result: **${report.golden.failed === 0 ? 'PASS' : 'FAIL'}** (${String(report.golden.passed)}/${String(report.golden.total)} vectors)`)
    for (const failure of report.golden.failures) {
      const details = failure.problems
        .map(problem => `${problem.field}: expected ${JSON.stringify(problem.expected)}, got ${JSON.stringify(problem.actual)}`)
        .join('; ')
      lines.push(`- \`${cell(failure.name)}\` — ${cell(details)}`)
    }
    lines.push('')
  }
  lines.push('## By status')
  lines.push('')
  lines.push('| Status | Count | Share |')
  lines.push('| --- | ---: | ---: |')
  for (const status of STATUSES) {
    const count = report.byStatus[status] ?? 0
    const share = report.commands === 0 ? 0 : (count / report.commands) * 100
    lines.push(`| ${status} | ${String(count)} | ${share.toFixed(1)}% |`)
  }
  lines.push('')
  lines.push('## By category')
  lines.push('')
  lines.push('| Category | Commands | ok | Coverage |')
  lines.push('| --- | ---: | ---: | ---: |')
  for (const category of Object.keys(report.byCategory).sort()) {
    const entry = report.byCategory[category]
    const share = entry.total === 0 ? 0 : (entry.ok / entry.total) * 100
    lines.push(`| ${cell(category)} | ${String(entry.total)} | ${String(entry.ok)} | ${share.toFixed(1)}% |`)
  }
  lines.push('')
  lines.push('## Unsupported syntax')
  lines.push('')
  if (Object.keys(report.syntaxUnsupported).length === 0) {
    lines.push('None.')
  } else {
    lines.push('| Construct | Count |')
    lines.push('| --- | ---: |')
    for (const construct of Object.keys(report.syntaxUnsupported).sort()) {
      lines.push(`| ${cell(construct)} | ${String(report.syntaxUnsupported[construct])} |`)
    }
  }
  lines.push('')
  lines.push('## Missing programs')
  lines.push('')
  if (Object.keys(report.commandMissing).length === 0) {
    lines.push('None.')
  } else {
    lines.push('| Program | Count |')
    lines.push('| --- | ---: |')
    const programs = Object.entries(report.commandMissing)
      .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    for (const [program, count] of programs) lines.push(`| ${cell(program)} | ${String(count)} |`)
  }
  lines.push('')
  lines.push('## Failing commands')
  lines.push('')
  if (report.failures.length === 0) {
    lines.push('None.')
  } else {
    lines.push('| # | Command | Category | Status | Detail |')
    lines.push('| ---: | --- | --- | --- | --- |')
    const shown = report.failures.slice(0, 100)
    for (const [index, failure] of shown.entries()) {
      const detail = failure.status === 'syntax-unsupported'
        ? failure.construct ?? ''
        : failure.status === 'command-missing'
          ? failure.program ?? ''
          : failure.detail ?? ''
      lines.push(`| ${String(index + 1)} | \`${cell(shortCommand(failure.cmd))}\` | ${cell(failure.category)} | ${failure.status} | ${cell(detail)} |`)
    }
    if (report.failures.length > shown.length) {
      lines.push('')
      lines.push(`_Showing ${String(shown.length)} of ${String(report.failures.length)} failing commands; the JSON report has all of them._`)
    }
  }
  lines.push('')
  return lines.join('\n')
}

/**
 * Write both reports.
 *
 * @param {object} report - output of {@link buildReport}.
 * @param {string} outDir - output directory.
 * @returns {{json: string, markdown: string}} written paths.
 */
export function writeReports(report, outDir) {
  const directory = resolve(outDir)
  mkdirSync(directory, { recursive: true })
  const jsonPath = join(directory, 'coverage-report.json')
  const markdownPath = join(directory, 'coverage-report.md')
  writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`)
  writeFileSync(markdownPath, renderMarkdown(report))
  return { json: jsonPath, markdown: markdownPath }
}

/** Print a short console summary (the full table lives in the report). */
function printSummary(report, paths) {
  const missing = Object.entries(report.commandMissing)
    .sort((left, right) => right[1] - left[1])
    .slice(0, 5)
    .map(([program, count]) => `${program}(${String(count)})`)
  process.stdout.write(`runner: ${report.runner}\n`)
  process.stdout.write(`coverage: ${report.coveragePercent.toFixed(1)}% (${String(report.ok)}/${String(report.commands)} ok)\n`)
  process.stdout.write(
    `statuses: ok ${String(report.byStatus.ok ?? 0)}, syntax-unsupported ${String(report.byStatus['syntax-unsupported'] ?? 0)}, `
    + `command-missing ${String(report.byStatus['command-missing'] ?? 0)}, runtime-error ${String(report.byStatus['runtime-error'] ?? 0)}\n`,
  )
  if (missing.length > 0) process.stdout.write(`missing: ${missing.join(', ')}\n`)
  if (report.threshold !== null) {
    process.stdout.write(`threshold: ${report.passed ? 'met' : 'not met'} (${String(report.threshold)}%)\n`)
  }
  if (report.golden !== undefined) {
    process.stdout.write(`golden: ${String(report.golden.passed)}/${String(report.golden.total)} vectors passed\n`)
  }
  process.stdout.write(`wrote: ${paths.json}\n`)
  process.stdout.write(`wrote: ${paths.markdown}\n`)
}

/**
 * CLI entry point.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {Promise<number>} process exit status.
 */
export async function main(argv) {
  let options
  try {
    options = parseArguments(argv)
  } catch (error) {
    process.stderr.write(`coverage: ${error instanceof Error ? error.message : String(error)}\n`)
    usage()
    return 2
  }
  if (options.help) {
    usage()
    return 0
  }
  let entries
  try {
    const corpusPath = isAbsolute(options.corpus) ? options.corpus : resolve(options.corpus)
    entries = parseCorpus(readFileSync(corpusPath, 'utf8'))
    if (entries.length === 0) {
      process.stderr.write(`coverage: corpus '${options.corpus}' has no commands\n`)
      return 2
    }
    let runner
    try {
      runner = await createRunner(options.runner, {
        runnerModule: options.runnerModule,
        checkout: process.env.PDSH_DSH_CHECKOUT,
      })
      const results = await runCorpus(entries, runner)
      const report = buildReport({
        runner: runner.name,
        corpus: options.corpus,
        entries,
        results,
        threshold: options.threshold,
      })
      // The golden gate asserts stdout bytes and exit status, which coverage
      // alone cannot see (a literal `%y` still exits 0). It runs against the
      // Worker shell, so it is loaded on demand and only when asked for.
      if (options.golden !== undefined) {
        const { parseGolden, runGoldenVectors } = await import('./golden.mjs')
        const goldenPath = isAbsolute(options.golden) ? options.golden : resolve(options.golden)
        const vectors = parseGolden(readFileSync(goldenPath, 'utf8'))
        const golden = await runGoldenVectors(vectors)
        report.golden = {
          file: options.golden,
          total: golden.total,
          passed: golden.passed,
          failed: golden.failed,
          failures: golden.results
            .filter(result => !result.pass)
            .map(result => ({ name: result.name, problems: result.problems })),
        }
        if (golden.failed > 0) report.passed = false
      }
      const paths = writeReports(report, options.out)
      printSummary(report, paths)
      return report.passed ? 0 : 1
    } catch (error) {
      process.stderr.write(`coverage: ${error instanceof Error ? error.message : String(error)}\n`)
      return 2
    }
  } catch (error) {
    process.stderr.write(`coverage: ${error instanceof Error ? error.message : String(error)}\n`)
    return 2
  }
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (invokedDirectly) {
  main(process.argv.slice(2)).then((status) => {
    process.exitCode = status
  }).catch((error) => {
    process.stderr.write(`coverage: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`)
    process.exitCode = 2
  })
}
