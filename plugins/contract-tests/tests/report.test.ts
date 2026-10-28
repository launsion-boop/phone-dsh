// SPDX-License-Identifier: MIT
// The report writer is part of the deliverable: canonical observed values,
// no absolute local paths, and a diff a human can read between pin and master.
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'

import { diffReports, renderMarkdown } from '../src/diff.ts'
import { canonicalJson, observe } from '../src/observed.ts'
import { REPORT_SCHEMA, sanitizeText, writeReport, type ContractReport } from '../src/report.ts'

const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

test('report: canonical observed values sort object keys', (t) => {
  const canonical = canonicalJson({ b: 1, a: [{ z: true, y: null }] })
  observe(t, 'canonicalJson', canonical)
  assert.equal(canonical, '{"a":[{"y":null,"z":true}],"b":1}')
})

test('report: sanitizer removes local absolute paths', (t) => {
  // Built at runtime so the repository contains no literal home path.
  const homePath = ['', 'Users', 'example', 'checkout', 'src', 'index.ts'].join('/')
  const tempPath = ['', 'private', 'var', 'folders', 'pdsh-contract-1'].join('/')
  const sanitized = sanitizeText(
    `failed reading ${homePath} from ${tempPath}`,
    [tempPath],
  )
  observe(t, 'sanitizedText', sanitized)
  assert.ok(!sanitized.includes(homePath))
  assert.ok(!sanitized.includes(tempPath))
  assert.match(sanitized, /<path>/)
})

test('report: diff names changed tests and observed values', (t) => {
  const pin = {
    checkout: { commit: 'pin-commit', version: '0.2.1-rc.2' },
    result: { status: 'pass' },
    tests: [
      { file: 'tests/a.test.ts', name: 'seam a', status: 'passed' },
      { file: 'tests/b.test.ts', name: 'seam b', status: 'passed' },
    ],
    observed: [
      { test: 'seam a', name: 'options', value: ['image', 'overlays'] },
      { test: 'seam b', name: 'programs', value: ['cat', 'ls'] },
    ],
  }
  const master = {
    checkout: { commit: 'master-commit', version: '0.2.2' },
    result: { status: 'fail' },
    tests: [
      { file: 'tests/a.test.ts', name: 'seam a', status: 'passed' },
      { file: 'tests/c.test.ts', name: 'seam c', status: 'failed' },
    ],
    observed: [
      { test: 'seam a', name: 'options', value: ['image', 'env', 'overlays'] },
      { test: 'seam c', name: 'programs', value: ['cat'] },
    ],
  }
  const diff = diffReports(pin, master)
  observe(t, 'diff', {
    onlyMasterTests: diff.tests.only_master.map(item => item.name),
    onlyPinTests: diff.tests.only_pin.map(item => item.name),
    changedObserved: diff.observed.changed.map(item => item.key),
  })
  assert.deepEqual(diff.tests.only_master.map(item => item.name), ['seam c'])
  assert.deepEqual(diff.tests.only_pin.map(item => item.name), ['seam b'])
  assert.equal(diff.observed.changed.length, 1)
  assert.equal(diff.observed.changed[0]?.key, 'seam a::options')
  assert.equal(diff.observed.only_master.length, 1)
  const markdown = renderMarkdown(diff)
  assert.match(markdown, /DSH seam contract diff/)
  assert.match(markdown, /seam a::options/)
})

test('report: writer emits the schema and never keeps a checkout path', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-contract-report-'))
  scratch.push(directory)
  const checkout = ['', 'Users', 'example', 'checkout'].join('/')
  const report: ContractReport = {
    schema: REPORT_SCHEMA,
    generated_at: '2026-01-01T00:00:00.000Z',
    checkout: { version: '0.2.1-rc.2', commit: 'abcdef', pin_match: true, resolved_as: 'argument' },
    result: { status: 'pass', exit_code: 0, duration_ms: 1, counts: { tests: 0, passed: 0, failed: 0, skipped: 0, todo: 0, cancelled: 0 } },
    tests: [{ file: 'tests/a.test.ts', name: 'seam', status: 'passed', failure: `read ${checkout}` }],
    observed: [{ test: 'seam', name: 'path', value: checkout }],
    environment: { node: process.version, platform: 'test' },
  }
  const file = join(directory, 'contract-report.json')
  writeReport(report, file, [checkout])
  const written = readFileSync(file, 'utf8')
  observe(t, 'reportBytes', { bytes: written.length, hasSchema: written.includes(REPORT_SCHEMA) })
  assert.ok(!written.includes(checkout))
  assert.match(written, /pdsh-dsh-contract-report\/1/)
  assert.match(written, /<path>/)
})
