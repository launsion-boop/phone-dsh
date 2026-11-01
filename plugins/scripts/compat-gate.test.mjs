// SPDX-License-Identifier: MIT
/**
 * Tests for the M99 build-time compatibility gate.
 *
 * Every case builds a throwaway tree under `os.tmpdir()` with its own
 * `baseline.json`, then runs the gate exactly as CI does: one `node` process,
 * `--today` pinned so expiry cases never depend on the wall clock. The last
 * case runs the shipped baseline against the real `plugins` tree, which keeps
 * the baseline file itself under test.
 *
 * @module @phone-dsh/dsh-plugins/scripts/compat-gate.test
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const gatePath = join(scriptDirectory, 'compat-gate.mjs')
const pluginRoot = dirname(scriptDirectory)
const today = '2026-10-31'

/** @type {string[]} */
const scratchDirectories = []

after(() => {
  for (const directory of scratchDirectories) rmSync(directory, { recursive: true, force: true })
})

/** A baseline with the required shape and one always-on rule. */
function baseline(overrides = {}) {
  return {
    target: 'fixture-m99',
    esVersion: 'ES2022',
    forbiddenApis: [
      { name: 'Array.prototype.at', pattern: '\\.at\\s*\\(', since: 'ES2022', sinceChromium: 92 },
      { name: 'Array.prototype.toSorted', pattern: '\\.toSorted\\s*\\(', since: 'ES2023', sinceChromium: 110 },
    ],
    forbiddenSyntax: [
      { name: 'Logical assignment (??=)', pattern: '\\?\\?=', since: 'ES2021', sinceChromium: 85 },
    ],
    polyfills: [],
    allow: [],
    ...overrides,
  }
}

/**
 * Create a scratch tree.
 * @param {Record<string, string>} files - scan-root-relative path to contents.
 * @param {object} [baselineOverrides] - baseline fields to override.
 * @returns {string} the scratch root.
 */
function makeTree(files, baselineOverrides) {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-compat-gate-'))
  scratchDirectories.push(root)
  writeFileSync(join(root, 'baseline.json'), `${JSON.stringify(baseline(baselineOverrides), null, 2)}\n`)
  for (const [relativePath, contents] of Object.entries(files)) {
    const absolute = join(root, ...relativePath.split('/'))
    mkdirSync(dirname(absolute), { recursive: true })
    writeFileSync(absolute, contents)
  }
  return root
}

/**
 * Run the gate over a scratch tree.
 * @param {string} root - scratch root.
 * @param {string[]} [extra] - extra CLI flags.
 * @returns {{status: number, stdout: string, stderr: string}} process result.
 */
function runGate(root, extra = []) {
  const result = spawnSync(
    process.execPath,
    [gatePath, '--root', root, '--baseline', join(root, 'baseline.json'), '--today', today, ...extra],
    { encoding: 'utf8' },
  )
  assert.equal(result.error, undefined, `gate failed to start: ${result.error?.message}`)
  return { status: result.status, stdout: result.stdout, stderr: result.stderr }
}

/** Parse a `--json` run and assert the process contract. */
function runJson(root, extra = []) {
  const result = runGate(root, ['--json', ...extra])
  let report
  assert.doesNotThrow(() => { report = JSON.parse(result.stdout) }, `stdout is not JSON: ${result.stdout}`)
  assert.equal(report.exitCode, result.status)
  assert.equal(report.ok, result.status === 0)
  return { ...result, report }
}

test('records a Chromium 92 API as a note instead of failing', () => {
  const root = makeTree({ 'pkg/src/code.ts': 'const last = items.at(-1)\n' })
  const { status, report } = runJson(root)
  assert.equal(status, 0)
  assert.equal(report.totals.notes, 1)
  assert.equal(report.totals.blocking, 0)
  assert.equal(report.hits[0].severity, 'note')
  assert.equal(report.hits[0].sinceChromium, 92)
  assert.equal(report.hits[0].reason, 'Chromium 92 <= 99')
})

test('blocks an API introduced after the M99 milestone', () => {
  const root = makeTree({ 'pkg/src/code.ts': 'const sorted = list.toSorted()\n' })
  const result = runGate(root)
  assert.equal(result.status, 1)
  assert.match(result.stdout, /pkg\/src\/code\.ts:1: Array\.prototype\.toSorted/)
  assert.match(result.stdout, /hits: 1 \(blocking 1, /)
})

test('exempts a live whitelist entry and reports it as allowed', () => {
  const root = makeTree(
    { 'pkg/src/code.ts': 'const sorted = list.toSorted()\n' },
    { allow: [{ path: 'pkg/src/code.ts', api: 'Array.prototype.toSorted', reason: 'frozen legacy', expires: '2099-12-31' }] },
  )
  const { status, report } = runJson(root)
  assert.equal(status, 0)
  assert.equal(report.totals.allowed, 1)
  assert.equal(report.totals.blocking, 0)
  assert.equal(report.totals.allowUsed, 1)
  assert.equal(report.hits[0].severity, 'allowed')
})

test('fails on an expired whitelist entry even when the code is exempt', () => {
  const root = makeTree(
    { 'pkg/src/code.ts': 'const sorted = list.toSorted()\n' },
    { allow: [{ path: 'pkg/src/code.ts', api: 'Array.prototype.toSorted', reason: 'stale freeze', expires: '2020-01-01' }] },
  )
  const human = runGate(root)
  assert.equal(human.status, 1)
  assert.match(human.stdout, /EXPIRED allow: Array\.prototype\.toSorted/)
  const { report } = runJson(root)
  assert.equal(report.totals.expiredAllow, 1)
  assert.equal(report.totals.allowed, 0)
})

test('ignores comment lines and obvious string-literal lines', () => {
  const root = makeTree({
    'pkg/src/notes.mjs': [
      '// items.at(-1) is the forbidden spelling',
      '/* items.at(-1) in a block comment */',
      ' * items.at(-1) inside a doc block',
      "  'items.at(-1)'",
      'export const clean = 1',
      '',
    ].join('\n'),
  })
  const { status, report } = runJson(root)
  assert.equal(status, 0)
  assert.equal(report.totals.hits, 0)
  assert.equal(report.totals.skippedStringLines, 1)
})

test('warns on an unverified rule and blocks it only under --strict', () => {
  const root = makeTree(
    { 'pkg/src/code.ts': 'const pending = Promise.try(run)\n' },
    { forbiddenApis: [{ name: 'Promise.try', pattern: '\\bPromise\\.try\\s*\\(', since: 'ES2025', sinceChromium: 'unverified' }] },
  )
  const lenient = runJson(root)
  assert.equal(lenient.status, 0)
  assert.equal(lenient.report.totals.warnings, 1)
  assert.equal(lenient.report.totals.blocking, 0)
  assert.equal(lenient.report.hits[0].reason, 'unverified')
  assert.match(runGate(root).stdout, /warning: unverified/)
  const strict = runJson(root, ['--strict'])
  assert.equal(strict.status, 1)
  assert.equal(strict.report.totals.blocking, 1)
})

test('passes a clean tree', () => {
  const root = makeTree({
    'pkg/src/a.ts': 'export const answer = 42\n',
    'pkg/src/b.mjs': 'export function pick(list) { return list[list.length - 1] }\n',
  })
  const { status, report } = runJson(root)
  assert.equal(status, 0)
  assert.equal(report.totals.hits, 0)
  assert.equal(report.totals.files, 2)
  assert.ok(report.totals.lines >= 2)
})

test('--json is a single machine-readable report with the documented shape', () => {
  const root = makeTree({ 'pkg/src/code.ts': 'const sorted = list.toSorted()\n' })
  const { status, report } = runJson(root)
  assert.equal(status, 1)
  for (const key of ['target', 'esVersion', 'root', 'baseline', 'today', 'ok', 'exitCode', 'totals', 'hits']) {
    assert.ok(key in report, `missing ${key}`)
  }
  for (const key of ['files', 'lines', 'hits', 'blocking', 'warnings', 'allowed', 'notes', 'expiredAllow']) {
    assert.equal(typeof report.totals[key], 'number', `totals.${key} must be a number`)
  }
  assert.equal(report.hits.length, 1)
  assert.deepEqual(Object.keys(report.hits[0]).sort(), [
    'api', 'kind', 'line', 'origin', 'path', 'reason', 'severity', 'since', 'sinceChromium',
  ])
  assert.equal(report.hits[0].api, 'Array.prototype.toSorted')
  assert.equal(report.hits[0].sinceChromium, 110)
  assert.equal(report.hits[0].origin, 'src')
  assert.ok(Array.isArray(report.byApi))
})

test('records logical assignment as inside the baseline instead of failing', () => {
  const root = makeTree({ 'pkg/src/code.ts': 'value ??= fallback\n' })
  const { status, report } = runJson(root)
  assert.equal(status, 0)
  assert.equal(report.totals.notes, 1)
  assert.equal(report.totals.blocking, 0)
  assert.equal(report.hits[0].severity, 'note')
  assert.equal(report.hits[0].reason, 'Chromium 85 <= 99')
})

test('does not block test-file hits unless --block-tests is given', () => {
  const root = makeTree({ 'tests/legacy.test.ts': 'const sorted = frames.toSorted()\n' })
  const lenient = runJson(root)
  assert.equal(lenient.status, 0)
  assert.equal(lenient.report.totals.warnings, 1)
  assert.equal(lenient.report.hits[0].reason, 'test-only')
  const blocked = runJson(root, ['--block-tests'])
  assert.equal(blocked.status, 1)
})

test('requires a declared polyfill provider to exist and downgrades its hits', () => {
  const missing = makeTree(
    { 'pkg/src/code.ts': 'const gate = Promise.withResolvers()\n' },
    {
      forbiddenApis: [{ name: 'Promise.withResolvers', pattern: '\\bPromise\\.withResolvers\\s*\\(', since: 'ES2024', sinceChromium: 119 }],
      polyfills: [{ api: 'Promise.withResolvers', provider: 'pkg/src/absent.ts', expires: '2099-12-31' }],
    },
  )
  const broken = runGate(missing)
  assert.equal(broken.status, 1)
  assert.match(broken.stderr, /does not exist/)

  const present = makeTree(
    { 'pkg/src/code.ts': 'const gate = Promise.withResolvers()\n', 'pkg/src/polyfill.ts': 'export const installed = true\n' },
    {
      forbiddenApis: [{ name: 'Promise.withResolvers', pattern: '\\bPromise\\.withResolvers\\s*\\(', since: 'ES2024', sinceChromium: 119 }],
      polyfills: [{ api: 'Promise.withResolvers', provider: 'pkg/src/polyfill.ts', expires: '2099-12-31' }],
    },
  )
  const { status, report } = runJson(present)
  assert.equal(status, 0)
  assert.equal(report.totals.polyfillUsed, 1)
  assert.equal(report.hits[0].reason, 'polyfilled')
})

test('every shipped rule fires on its own construct', () => {
  const fixture = {
    'pkg/src/all.ts': [
      '@sealed',
      'class Example {}',
      '',
      'using handle = open()',
      "import data from './data.json' with { type: 'json' }",
      "import legacy from './legacy.json' assert { type: 'json' }",
      '',
      'const a = list.at(-1)',
      'const b = list.findLast(predicate)',
      'const c = list.findLastIndex(predicate)',
      'const d = list.toSorted()',
      'const e = list.toReversed()',
      'const f = list.toSpliced(0, 1)',
      'const g = list.with(0, 1)',
      "const h = Object.hasOwn(record, 'key')",
      'const i = Object.groupBy(rows, key)',
      'const j = Map.groupBy(rows, key)',
      'const k = Promise.withResolvers<void>()',
      'const l = Array.fromAsync(source)',
      'const m = structuredClone(value)',
      'const n = RegExp.escape(text)',
      'const o = /[a&&b]/v',
      'let p',
      'p ??= fallback',
      '',
    ].join('\n'),
  }
  const root = makeTree(fixture)
  const result = spawnSync(
    process.execPath,
    [gatePath, '--root', root, '--today', today, '--json'],
    { encoding: 'utf8' },
  )
  const report = JSON.parse(result.stdout)
  assert.equal(report.target, 'huawei-webview-m99')
  assert.deepEqual(
    report.hits.map((hit) => hit.api).sort(),
    [
      'Array.fromAsync',
      'Array.prototype.at',
      'Array.prototype.findLast',
      'Array.prototype.findLastIndex',
      'Array.prototype.toReversed',
      'Array.prototype.toSorted',
      'Array.prototype.toSpliced',
      'Array.prototype.with',
      'Decorator',
      'Logical assignment (??=)',
      'Map.groupBy',
      'Object.groupBy',
      'Object.hasOwn',
      'Promise.withResolvers',
      'RegExp v flag',
      'RegExp.escape',
      'import assertions (assert { type: })',
      'import attributes (with { type: })',
      'structuredClone',
      'using / await using',
    ],
  )
  assert.equal(report.totals.notes, 6)
  assert.equal(report.totals.warnings, 2)
  assert.equal(report.totals.blocking, 12)
  assert.equal(report.hits.find((hit) => hit.api === 'Decorator').severity, 'warning')
  assert.equal(report.hits.find((hit) => hit.api === 'Decorator').reason, 'unverified')
})

test('rejects a rule without a Chromium milestone', () => {
  const root = makeTree(
    { 'pkg/src/code.ts': 'export const clean = 1\n' },
    { forbiddenApis: [{ name: 'Array.prototype.at', pattern: '\\.at\\s*\\(', since: 'ES2022' }] },
  )
  const result = runGate(root)
  assert.equal(result.status, 1)
  assert.match(result.stderr, /sinceChromium must be a positive Chromium milestone or "unverified"/)
})

test('fails when the scan root does not exist', () => {
  const root = makeTree({})
  const result = spawnSync(
    process.execPath,
    [gatePath, '--root', join(root, 'absent'), '--baseline', join(root, 'baseline.json'), '--today', today],
    { encoding: 'utf8' },
  )
  assert.equal(result.status, 1)
  assert.match(result.stderr, /scan root does not exist/)
})

test('the shipped baseline loads and scans the real plugins tree', () => {
  const result = spawnSync(process.execPath, [gatePath, '--root', pluginRoot, '--today', today, '--json'], {
    encoding: 'utf8',
  })
  assert.equal(result.error, undefined)
  const report = JSON.parse(result.stdout)
  assert.equal(report.target, 'huawei-webview-m99')
  assert.equal(report.esVersion, 'ES2022')
  assert.ok(report.totals.files > 300, `expected the whole tree, got ${report.totals.files} files`)
  assert.ok(report.totals.lines > 100_000, `expected the whole tree, got ${report.totals.lines} lines`)
  assert.equal(report.problems.length, 0)
  assert.equal(report.expired.length, 0)
  assert.equal(report.totals.expiredAllow, 0)
})
