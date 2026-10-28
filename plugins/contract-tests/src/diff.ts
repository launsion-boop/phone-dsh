// SPDX-License-Identifier: MIT
/**
 * Compare the pin and master contract reports and write the daily diff.
 *
 * Usage: `npm run contract:diff -- <pin-report.json> <master-report.json> [--out <dir>]`
 *
 * The tool writes `contract-diff.md` (human-readable) and `contract-diff.json`
 * (machine-readable). Differences do not make the command fail: the workflow
 * uploads the diff, and the contract run's own exit code already says whether a
 * seam broke.
 * @module @phone-dsh/dsh-contract-tests/diff
 */
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { basename, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

/** One test row from a contract report. */
interface ReportTest {
  readonly file?: unknown
  readonly name?: unknown
  readonly status?: unknown
  readonly failure?: unknown
}

/** One observed row from a contract report. */
interface ReportObserved {
  readonly test?: unknown
  readonly name?: unknown
  readonly value?: unknown
}

/** The report fields the diff reads. */
interface ReportLike {
  readonly checkout?: {
    readonly version?: unknown
    readonly commit?: unknown
    readonly pin_match?: unknown
  }
  readonly result?: {
    readonly status?: unknown
    readonly counts?: unknown
  }
  readonly tests?: readonly ReportTest[]
  readonly observed?: readonly ReportObserved[]
}

/** A test that differs between the two reports. */
export interface ChangedTest {
  readonly file: string
  readonly name: string
  readonly pin: string
  readonly master: string
}

/** An observed value that differs between the two reports. */
export interface ChangedObservation {
  readonly key: string
  readonly pin: unknown
  readonly master: unknown
}

/** The complete diff document. */
export interface DiffDocument {
  readonly generated_at: string
  readonly missing: { readonly pin: boolean; readonly master: boolean }
  readonly checkout: {
    readonly pin: { readonly commit: unknown; readonly version: unknown } | null
    readonly master: { readonly commit: unknown; readonly version: unknown } | null
  }
  readonly tests: {
    readonly only_pin: readonly { readonly file: string; readonly name: string; readonly status: string }[]
    readonly only_master: readonly { readonly file: string; readonly name: string; readonly status: string }[]
    readonly changed: readonly ChangedTest[]
  }
  readonly observed: {
    readonly only_pin: readonly { readonly key: string; readonly value: unknown }[]
    readonly only_master: readonly { readonly key: string; readonly value: unknown }[]
    readonly changed: readonly ChangedObservation[]
  }
}

/**
 * Read a test's stable key.
 * @param test - report test row.
 * @returns `file::name`, with empty parts allowed for malformed rows.
 */
function testKey(test: ReportTest): string {
  const file = typeof test.file === 'string' ? test.file : ''
  const name = typeof test.name === 'string' ? test.name : ''
  return `${file}::${name}`
}

/**
 * Read an observation's stable key.
 * @param observation - report observed row.
 * @returns `test::name`, with empty parts allowed for malformed rows.
 */
function observationKey(observation: ReportObserved): string {
  const test = typeof observation.test === 'string' ? observation.test : ''
  const name = typeof observation.name === 'string' ? observation.name : ''
  return `${test}::${name}`
}

/**
 * Compare two reports.
 * @param pin - pin report, or undefined when its run failed before writing.
 * @param master - master report, or undefined.
 * @returns every test and observed difference.
 */
export function diffReports(pin: ReportLike | undefined, master: ReportLike | undefined): DiffDocument {
  const pinTests = new Map<string, ReportTest>()
  for (const test of pin?.tests ?? []) pinTests.set(testKey(test), test)
  const masterTests = new Map<string, ReportTest>()
  for (const test of master?.tests ?? []) masterTests.set(testKey(test), test)
  const onlyPinTests: { file: string; name: string; status: string }[] = []
  const onlyMasterTests: { file: string; name: string; status: string }[] = []
  const changedTests: ChangedTest[] = []
  for (const [key, test] of pinTests) {
    const other = masterTests.get(key)
    if (other === undefined) {
      onlyPinTests.push({ file: typeof test.file === 'string' ? test.file : '', name: typeof test.name === 'string' ? test.name : '', status: String(test.status ?? '') })
      continue
    }
    const pinStatus = String(test.status ?? '')
    const masterStatus = String(other.status ?? '')
    if (pinStatus !== masterStatus) {
      changedTests.push({ file: typeof test.file === 'string' ? test.file : '', name: typeof test.name === 'string' ? test.name : '', pin: pinStatus, master: masterStatus })
    }
  }
  for (const [key, test] of masterTests) {
    if (pinTests.has(key)) continue
    onlyMasterTests.push({ file: typeof test.file === 'string' ? test.file : '', name: typeof test.name === 'string' ? test.name : '', status: String(test.status ?? '') })
  }

  const pinObserved = new Map<string, ReportObserved>()
  for (const observation of pin?.observed ?? []) pinObserved.set(observationKey(observation), observation)
  const masterObserved = new Map<string, ReportObserved>()
  for (const observation of master?.observed ?? []) masterObserved.set(observationKey(observation), observation)
  const onlyPinObserved: { key: string; value: unknown }[] = []
  const onlyMasterObserved: { key: string; value: unknown }[] = []
  const changedObserved: ChangedObservation[] = []
  for (const [key, observation] of pinObserved) {
    const other = masterObserved.get(key)
    if (other === undefined) {
      onlyPinObserved.push({ key, value: observation.value })
      continue
    }
    if (JSON.stringify(observation.value) !== JSON.stringify(other.value)) {
      changedObserved.push({ key, pin: observation.value, master: other.value })
    }
  }
  for (const [key, observation] of masterObserved) {
    if (!pinObserved.has(key)) onlyMasterObserved.push({ key, value: observation.value })
  }

  return {
    generated_at: new Date().toISOString(),
    missing: { pin: pin === undefined, master: master === undefined },
    checkout: {
      pin: pin === undefined ? null : { commit: pin.checkout?.commit, version: pin.checkout?.version },
      master: master === undefined ? null : { commit: master.checkout?.commit, version: master.checkout?.version },
    },
    tests: {
      only_pin: onlyPinTests.sort((left, right) => testKey(left).localeCompare(testKey(right))),
      only_master: onlyMasterTests.sort((left, right) => testKey(left).localeCompare(testKey(right))),
      changed: changedTests.sort((left, right) => testKey(left).localeCompare(testKey(right))),
    },
    observed: {
      only_pin: onlyPinObserved.sort((left, right) => left.key.localeCompare(right.key)),
      only_master: onlyMasterObserved.sort((left, right) => left.key.localeCompare(right.key)),
      changed: changedObserved.sort((left, right) => left.key.localeCompare(right.key)),
    },
  }
}

/**
 * Render a JSON value for one Markdown line.
 * @param value - value to render.
 * @returns compact JSON, truncated when long.
 */
function inlineJson(value: unknown): string {
  const text = JSON.stringify(value)
  if (text === undefined) return 'undefined'
  return text.length > 600 ? `${text.slice(0, 600)}…` : text
}

/**
 * Render the diff document as Markdown.
 * @param diff - diff to render.
 * @returns Markdown text.
 */
export function renderMarkdown(diff: DiffDocument): string {
  const lines: string[] = ['# DSH seam contract diff — pin vs master', '']
  lines.push(`- generated: ${diff.generated_at}`)
  lines.push(`- pin: ${diff.checkout.pin === null ? 'missing report' : `${String(diff.checkout.pin.commit ?? 'unknown')} (${String(diff.checkout.pin.version ?? 'unknown')})`}`)
  lines.push(`- master: ${diff.checkout.master === null ? 'missing report' : `${String(diff.checkout.master.commit ?? 'unknown')} (${String(diff.checkout.master.version ?? 'unknown')})`}`)
  const changedCount = diff.tests.changed.length + diff.observed.changed.length
  const addedCount = diff.tests.only_master.length + diff.observed.only_master.length
  const removedCount = diff.tests.only_pin.length + diff.observed.only_pin.length
  lines.push(`- changes: ${changedCount} changed, ${addedCount} only in master, ${removedCount} only in pin`)
  lines.push('')
  if (diff.missing.pin || diff.missing.master) {
    lines.push('> A report is missing because that contract run failed before writing it; see the workflow log.')
    lines.push('')
  }

  lines.push('## Tests', '')
  if (diff.tests.changed.length === 0 && diff.tests.only_pin.length === 0 && diff.tests.only_master.length === 0) {
    lines.push('No test-result differences.', '')
  } else {
    for (const test of diff.tests.changed) {
      lines.push(`- changed: \`${test.file} :: ${test.name}\` — pin \`${test.pin}\`, master \`${test.master}\``)
    }
    for (const test of diff.tests.only_pin) {
      lines.push(`- only in pin: \`${test.file} :: ${test.name}\` — \`${test.status}\``)
    }
    for (const test of diff.tests.only_master) {
      lines.push(`- only in master: \`${test.file} :: ${test.name}\` — \`${test.status}\``)
    }
    lines.push('')
  }

  lines.push('## Observed seams', '')
  if (diff.observed.changed.length === 0 && diff.observed.only_pin.length === 0 && diff.observed.only_master.length === 0) {
    lines.push('No observed-value differences.', '')
  } else {
    for (const observation of diff.observed.changed) {
      lines.push(`- changed: \`${observation.key}\``)
      lines.push(`  - pin: \`${inlineJson(observation.pin)}\``)
      lines.push(`  - master: \`${inlineJson(observation.master)}\``)
    }
    for (const observation of diff.observed.only_pin) {
      lines.push(`- only in pin: \`${observation.key}\` — \`${inlineJson(observation.value)}\``)
    }
    for (const observation of diff.observed.only_master) {
      lines.push(`- only in master: \`${observation.key}\` — \`${inlineJson(observation.value)}\``)
    }
    lines.push('')
  }
  if (changedCount + addedCount + removedCount === 0 && !diff.missing.pin && !diff.missing.master) {
    lines.push('No seam changes detected.')
    lines.push('')
  }
  return lines.join('\n')
}

/**
 * Read a report file, tolerating absence.
 * @param file - report path.
 * @returns the parsed report, or undefined.
 */
function readReport(file: string): ReportLike | undefined {
  if (!existsSync(file)) return undefined
  try {
    return JSON.parse(readFileSync(file, 'utf8')) as ReportLike
  } catch {
    return undefined
  }
}

/**
 * Whether this file is the process entry point.
 * @returns true when the CLI should run.
 */
function invokedByCli(): boolean {
  const entry = process.argv[1]
  if (entry === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(entry))
  } catch {
    return false
  }
}

/**
 * Write the report diff produced by the CLI arguments.
 * @returns the process exit code.
 */
function main(): number {
  let positionals: string[]
  let outDir = process.cwd()
  try {
    const parsed = parseArgs({
      args: process.argv.slice(2),
      allowPositionals: true,
      options: { out: { type: 'string' } },
    })
    positionals = parsed.positionals
    if (parsed.values.out !== undefined && parsed.values.out !== '') outDir = resolve(parsed.values.out)
  } catch (reason) {
    process.stderr.write(`contract diff: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    return 2
  }
  if (positionals.length !== 2) {
    process.stderr.write('usage: npm run contract:diff -- <pin-report.json> <master-report.json> [--out <dir>]\n')
    return 2
  }
  const pin = readReport(positionals[0] as string)
  const master = readReport(positionals[1] as string)
  const diff = diffReports(pin, master)
  mkdirSync(outDir, { recursive: true })
  writeFileSync(join(outDir, 'contract-diff.json'), `${JSON.stringify(diff, null, 2)}\n`)
  writeFileSync(join(outDir, 'contract-diff.md'), renderMarkdown(diff))
  const changed = diff.tests.changed.length + diff.observed.changed.length
  const added = diff.tests.only_master.length + diff.observed.only_master.length
  const removed = diff.tests.only_pin.length + diff.observed.only_pin.length
  process.stdout.write(
    `contract diff: ${changed} changed, ${added} only in master, ${removed} only in pin; `
    + `wrote ${basename(join(outDir, 'contract-diff.md'))} and ${basename(join(outDir, 'contract-diff.json'))}\n`,
  )
  return 0
}

if (invokedByCli()) process.exitCode = main()
