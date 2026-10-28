// SPDX-License-Identifier: MIT
/**
 * Report model, sanitizer and writer for `contract-report.json`.
 *
 * The report is machine-readable evidence for one checkout: the tests that
 * ran, their result, and the value each test observed. Absolute local paths
 * never enter it, so it can be published as a CI artifact and diffed between
 * the pin and master runs.
 * @module @phone-dsh/dsh-contract-tests/report
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

/** Schema identifier of the report document. */
export const REPORT_SCHEMA = 'pdsh-dsh-contract-report/1'

/** Result of one node:test case. */
export interface ContractTestResult {
  readonly file: string
  readonly name: string
  readonly status: 'passed' | 'failed' | 'skipped'
  readonly duration_ms?: number
  readonly failure?: string
}

/** One observed value, keyed by the test that printed it. */
export interface ObservedRecord {
  readonly test: string
  readonly name: string
  readonly value: unknown
}

/** Test-runner counts, in the shape node:test reports them. */
export interface ContractCounts {
  readonly tests: number
  readonly passed: number
  readonly failed: number
  readonly skipped: number
  readonly todo: number
  readonly cancelled: number
}

/** The complete report document. */
export interface ContractReport {
  readonly schema: string
  readonly generated_at: string
  readonly checkout: {
    readonly version: string | undefined
    readonly commit: string | undefined
    readonly pin_match: boolean | undefined
    readonly resolved_as: string
  }
  readonly result: {
    readonly status: 'pass' | 'fail' | 'error'
    readonly exit_code: number | undefined
    readonly duration_ms: number | undefined
    readonly counts: ContractCounts | undefined
    readonly error?: string
  }
  readonly tests: readonly ContractTestResult[]
  readonly observed: readonly ObservedRecord[]
  readonly environment: {
    readonly node: string
    readonly platform: string
  }
}

/**
 * Replace absolute local paths with placeholders.
 *
 * Two mechanisms are used: explicit secrets (the checkout and scratch
 * directories of this run) and the home-path pattern the public-repository
 * hygiene contract already forbids.
 * @param text - text to sanitize.
 * @param secrets - absolute paths that must not survive.
 * @returns the sanitized text.
 */
export function sanitizeText(text: string, secrets: readonly string[]): string {
  let result = text
  for (const secret of secrets) {
    if (secret === '') continue
    result = result.split(secret).join('<path>')
  }
  result = result.replace(/(?<![\w.-])\/(?:Users|home)\/[^\s"'`<>),;\]]*/g, '<path>')
  result = result.replace(/[A-Za-z]:\\Users\\[^\s"'`<>),;\]]*/g, '<path>')
  return result
}

/**
 * Recursively sanitize every string in a JSON value.
 * @param value - value to sanitize.
 * @param secrets - absolute paths that must not survive.
 * @returns a sanitized copy.
 */
export function sanitizeValue(value: unknown, secrets: readonly string[]): unknown {
  if (typeof value === 'string') return sanitizeText(value, secrets)
  if (Array.isArray(value)) return value.map(item => sanitizeValue(item, secrets))
  if (value !== null && typeof value === 'object') {
    const source = value as Record<string, unknown>
    const result: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(source)) result[key] = sanitizeValue(item, secrets)
    return result
  }
  return value
}

/**
 * Sanitize a report and write it as pretty JSON.
 * @param report - report document.
 * @param file - absolute output path.
 * @param secrets - absolute paths that must not survive.
 */
export function writeReport(report: ContractReport, file: string, secrets: readonly string[]): void {
  const sanitized = sanitizeValue(report, secrets)
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, `${JSON.stringify(sanitized, null, 2)}\n`)
}
