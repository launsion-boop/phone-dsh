// SPDX-License-Identifier: MIT
/**
 * Print and record the value each contract test observed.
 *
 * The console line is what a human diffs between runs; the JSONL file is what
 * the CLI folds into `contract-report.json` so the CI diff tool can compare the
 * pin and master checkouts field by field.
 * @module @phone-dsh/dsh-contract-tests/observed
 */
import { appendFileSync } from 'node:fs'

/** The node:test context member the record keys on. */
export interface NamedTest {
  readonly name: string
}

/**
 * Convert a JSON value into canonical form: object keys are sorted, arrays keep
 * their order, and unsupported values become null. The result is valid JSON.
 * @param value - value to canonicalize.
 * @returns a JSON value.
 */
function canonicalValue(value: unknown): unknown {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (Array.isArray(value)) return value.map(item => canonicalValue(item))
  if (value instanceof Uint8Array) return Array.from(value)
  if (typeof value === 'object') {
    const source = value as Record<string, unknown>
    const result: Record<string, unknown> = {}
    for (const key of Object.keys(source).sort()) {
      const item = source[key]
      if (item === undefined) continue
      result[key] = canonicalValue(item)
    }
    return result
  }
  return null
}

/**
 * Canonical JSON text for a value, with sorted keys.
 * @param value - value to encode.
 * @returns the JSON text.
 */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalValue(value))
}

/**
 * Print one observed value and append it to the run's observation log.
 * @param test - current node:test context (only its name is used).
 * @param name - stable observation name inside this test.
 * @param value - JSON-able observed value.
 */
export function observe(test: NamedTest, name: string, value: unknown): void {
  const canonical = canonicalValue(value)
  const text = JSON.stringify(canonical)
  console.log(`observed ${name}: ${text}`)
  const file = process.env.PDSH_DSH_CONTRACT_OBSERVED
  if (file === undefined || file === '') return
  appendFileSync(file, `${JSON.stringify({ test: test.name, name, value: canonical })}\n`)
}
