// SPDX-License-Identifier: MIT
/**
 * Contract-suite CLI.
 *
 * Usage: `npm run contract -- --checkout <dsh-checkout> [--report <file>]`
 *
 * It resolves the checkout, bundles the probe against that checkout's sources,
 * runs the node:test suite with the contract reporter, and writes
 * `contract-report.json` with every observed value. The checkout is only read.
 * @module @phone-dsh/dsh-contract-tests/cli
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import { bundleProbe } from './bundle.ts'
import { inspectCheckout, resolveCheckout, type CheckoutInfo, type CheckoutSource } from './checkout.ts'
import {
  REPORT_SCHEMA,
  sanitizeText,
  writeReport,
  type ContractCounts,
  type ContractReport,
  type ContractTestResult,
  type ObservedRecord,
} from './report.ts'

const CONTRACT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PACKAGE_ROOT = resolve(CONTRACT_ROOT, '..')
const TESTS_DIR = join(CONTRACT_ROOT, 'tests')
const PROBE_ENTRY = join(CONTRACT_ROOT, 'src', 'probe.ts')
const REPORTER = join(CONTRACT_ROOT, 'src', 'reporter.mjs')
const DEFAULT_REPORT = join(CONTRACT_ROOT, 'contract-report.json')

/** Test-runner results the reporter writes. */
interface RawResults {
  readonly tests?: readonly {
    readonly file?: unknown
    readonly name?: unknown
    readonly status?: unknown
    readonly duration_ms?: unknown
    readonly failure?: unknown
  }[]
  readonly summary?: {
    readonly counts?: Readonly<Record<string, unknown>>
    readonly duration_ms?: unknown
  } | null
}

/** Report fields the CLI composes from one run. */
interface RunFacts {
  readonly info: CheckoutInfo
  readonly source: CheckoutSource
  readonly status: 'pass' | 'fail' | 'error'
  readonly exitCode: number | undefined
  readonly durationMs: number | undefined
  readonly counts: ContractCounts | undefined
  readonly tests: readonly ContractTestResult[]
  readonly observed: readonly ObservedRecord[]
  readonly error?: string
}

/** Print the command's usage. */
function usage(): void {
  process.stdout.write([
    'usage: npm run contract -- --checkout <dsh-checkout> [--report <file>]',
    '',
    'The checkout may also come from PDSH_DSH_CHECKOUT or $HOME/.config/phone-dsh/dsh-checkout.',
    'The report defaults to plugins/contract-tests/contract-report.json.',
    '',
  ].join('\n'))
}

/**
 * Read a non-negative integer from a summary record.
 * @param source - summary record.
 * @param key - field name.
 * @returns the number, or zero when absent or malformed.
 */
function countOf(source: Readonly<Record<string, unknown>> | undefined, key: string): number {
  const value = source?.[key]
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : 0
}

/**
 * Convert the reporter's summary into the report's counts shape.
 * @param summary - reporter summary.
 * @returns counts, or undefined when the runner wrote none.
 */
function countsOf(summary: RawResults['summary']): ContractCounts | undefined {
  if (summary === undefined || summary === null || summary.counts === undefined) return undefined
  const counts = summary.counts
  return {
    tests: countOf(counts, 'tests'),
    passed: countOf(counts, 'passed'),
    failed: countOf(counts, 'failed'),
    skipped: countOf(counts, 'skipped'),
    todo: countOf(counts, 'todo'),
    cancelled: countOf(counts, 'cancelled'),
  }
}

/**
 * Read the reporter's results file.
 * @param file - results JSON path.
 * @returns the parsed results, or undefined when the reporter wrote none.
 */
function readResults(file: string): RawResults | undefined {
  try {
    return JSON.parse(readFileSync(file, 'utf8')) as RawResults
  } catch {
    return undefined
  }
}

/**
 * Read the observation log written by the tests.
 * @param file - JSONL path.
 * @returns every well-formed observed record in write order.
 */
function readObserved(file: string): ObservedRecord[] {
  let text: string
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return []
  }
  const records: ObservedRecord[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const parsed = JSON.parse(line) as Record<string, unknown>
      const test = parsed['test']
      const name = parsed['name']
      if (typeof test !== 'string' || typeof name !== 'string') continue
      records.push({ test, name, value: parsed['value'] })
    } catch {
      // A torn line can only come from a killed test process; ignore it.
    }
  }
  return records
}

/**
 * Map the reporter's raw test rows onto the report shape.
 * @param results - reporter results.
 * @returns test rows in runner order.
 */
function testsOf(results: RawResults | undefined): ContractTestResult[] {
  const tests: ContractTestResult[] = []
  for (const item of results?.tests ?? []) {
    if (typeof item.name !== 'string') continue
    const status = item.status === 'failed' ? 'failed' : item.status === 'skipped' ? 'skipped' : 'passed'
    tests.push({
      file: typeof item.file === 'string' ? item.file : '',
      name: item.name,
      status,
      ...typeof item.duration_ms === 'number' ? { duration_ms: item.duration_ms } : {},
      ...typeof item.failure === 'string' && item.failure !== '' ? { failure: item.failure } : {},
    })
  }
  return tests
}

/**
 * Compose the report document.
 * @param facts - one run's facts.
 * @returns the report.
 */
function composeReport(facts: RunFacts): ContractReport {
  return {
    schema: REPORT_SCHEMA,
    generated_at: new Date().toISOString(),
    checkout: {
      version: facts.info.version,
      commit: facts.info.commit,
      pin_match: facts.info.pinMatch,
      resolved_as: facts.source,
    },
    result: {
      status: facts.status,
      exit_code: facts.exitCode,
      duration_ms: facts.durationMs,
      counts: facts.counts,
      ...facts.error === undefined ? {} : { error: facts.error },
    },
    tests: facts.tests,
    observed: facts.observed,
    environment: {
      node: process.version,
      platform: `${process.platform}-${process.arch}`,
    },
  }
}

/**
 * Run the node:test suite.
 * @param options - test files and environment.
 * @returns the child's exit code.
 */
function runTests(options: {
  readonly checkout: string
  readonly probe: string
  readonly results: string
  readonly observed: string
  readonly files: readonly string[]
}): Promise<number> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(process.execPath, [
      '--test',
      `--test-reporter=${REPORTER}`,
      '--test-timeout=120000',
      ...options.files,
    ], {
      cwd: PACKAGE_ROOT,
      env: {
        ...process.env,
        PDSH_DSH_CONTRACT_CHECKOUT: options.checkout,
        PDSH_DSH_CONTRACT_PROBE: options.probe,
        PDSH_DSH_CONTRACT_RESULTS: options.results,
        PDSH_DSH_CONTRACT_OBSERVED: options.observed,
      },
      stdio: 'inherit',
    })
    child.once('error', rejectRun)
    child.once('close', (code, signal) => resolveRun(code ?? (signal === null ? 0 : 2)))
  })
}

/**
 * List the suite's test files.
 * @returns absolute test file paths in stable order.
 */
function testFiles(): string[] {
  return readdirSync(TESTS_DIR)
    .filter(name => name.endsWith('.test.ts'))
    .sort()
    .map(name => join(TESTS_DIR, name))
}

/**
 * Print a report path without leaking an absolute local path into logs.
 * @param file - absolute report path.
 * @returns a relative path when it is below the current directory, else the basename.
 */
function displayPath(file: string): string {
  const rel = relative(process.cwd(), file)
  return rel === '' || rel.startsWith('..') ? basename(file) : rel
}

/**
 * Run one contract session.
 * @returns the process exit code.
 */
async function main(): Promise<number> {
  let values: { checkout?: string | undefined; report?: string | undefined; help?: boolean | undefined }
  try {
    ({ values } = parseArgs({
      args: process.argv.slice(2),
      options: {
        checkout: { type: 'string' },
        report: { type: 'string' },
        help: { type: 'boolean', short: 'h' },
      },
    }))
  } catch (reason) {
    process.stderr.write(`contract: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    usage()
    return 2
  }
  if (values.help === true) {
    usage()
    return 0
  }

  let resolved: ReturnType<typeof resolveCheckout>
  try {
    resolved = resolveCheckout(values.checkout)
  } catch (reason) {
    process.stderr.write(`contract: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    return 2
  }
  const info = inspectCheckout(resolved.directory)
  const reportPath = values.report === undefined || values.report === ''
    ? DEFAULT_REPORT
    : resolve(values.report)
  const temp = mkdtempSync(join(tmpdir(), 'pdsh-dsh-contract-'))
  let tempReal = temp
  try {
    tempReal = realpathSync(temp)
  } catch {
    // The scratch path is advisory in sanitization; mkdtemp already returned it.
  }
  const secrets = [
    resolved.directory,
    temp,
    tempReal,
    CONTRACT_ROOT,
    PACKAGE_ROOT,
    process.env.HOME ?? '',
  ].filter(secret => secret !== '')
  const commit = info.commit ?? 'unknown'
  const version = info.version === undefined ? '' : ` (${info.version})`
  process.stdout.write(
    `dsh contract: checkout ${commit}${version}, pin match: `
    + `${info.pinMatch === undefined ? 'unknown' : info.pinMatch ? 'yes' : 'no'}\n`,
  )

  try {
    const probePath = join(temp, 'probe.mjs')
    const resultsPath = join(temp, 'results.json')
    const observedPath = join(temp, 'observed.jsonl')
    writeFileSync(observedPath, '')
    let durationMs: number | undefined
    try {
      const start = Date.now()
      await bundleProbe({ checkout: resolved.directory, entry: PROBE_ENTRY, outfile: probePath })
      durationMs = Date.now() - start
    } catch (reason) {
      const message = sanitizeText(reason instanceof Error ? reason.message : String(reason), secrets)
      const report = composeReport({
        info,
        source: resolved.source,
        status: 'error',
        exitCode: 2,
        durationMs,
        counts: undefined,
        tests: [],
        observed: [],
        error: `probe bundle failed: ${message}`,
      })
      writeReport(report, reportPath, secrets)
      process.stderr.write(`contract: probe bundle failed: ${message}\n`)
      process.stderr.write(`contract: report written to ${displayPath(reportPath)}\n`)
      return 2
    }

    const files = testFiles()
    if (files.length === 0) {
      process.stderr.write('contract: no tests/*.test.ts files found\n')
      return 2
    }
    const start = Date.now()
    const exitCode = await runTests({
      checkout: resolved.directory,
      probe: probePath,
      results: resultsPath,
      observed: observedPath,
      files,
    })
    durationMs = Date.now() - start
    const results = readResults(resultsPath)
    const observed = readObserved(observedPath)
    const tests = testsOf(results)
    const counts = countsOf(results?.summary ?? undefined)
    const summaryDuration = results?.summary?.duration_ms
    const report = composeReport({
      info,
      source: resolved.source,
      status: exitCode === 0 ? 'pass' : 'fail',
      exitCode,
      durationMs: typeof summaryDuration === 'number' ? summaryDuration : durationMs,
      counts,
      tests,
      observed,
      ...results === undefined ? { error: 'the test reporter wrote no results file' } : {},
    })
    writeReport(report, reportPath, secrets)
    const observedCount = observed.length
    const failed = counts?.failed ?? (exitCode === 0 ? 0 : tests.filter(item => item.status === 'failed').length)
    process.stdout.write(
      `contract: ${failed === 0 && exitCode === 0 ? 'PASS' : 'FAIL'} `
      + `(${tests.length} test(s), ${observedCount} observed value(s))\n`,
    )
    process.stdout.write(`contract: report written to ${displayPath(reportPath)}\n`)
    return exitCode
  } finally {
    rmSync(temp, { recursive: true, force: true })
  }
}

process.exitCode = await main()
