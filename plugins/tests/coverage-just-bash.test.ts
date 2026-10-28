// SPDX-License-Identifier: MIT
// W5-SHELL: the public corpus must clear the 95% gate through the real
// `tools/shell-corpus/coverage.mjs` runner interface.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const out = mkdtempSync(join(tmpdir(), 'pdsh-just-bash-cov-'))

after(() => { rmSync(out, { recursive: true, force: true }) })

test('coverage: the just-bash runner clears the 95% public-corpus threshold', () => {
  const result = spawnSync(process.execPath, [
    join(root, 'tools/shell-corpus/coverage.mjs'),
    '--runner', 'just-bash',
    '--corpus', join(root, 'tools/shell-corpus/corpus/public.jsonl'),
    '--out', out,
    '--threshold', '95',
  ], { cwd: root, encoding: 'utf8', timeout: 180_000, env: { ...process.env, PDSH_SHELL_CORPUS_MODE: 'host' } })
  assert.equal(result.status, 0, `coverage exited ${String(result.status)}\n${result.stdout}\n${result.stderr}`)

  const report = JSON.parse(readFileSync(join(out, 'coverage-report.json'), 'utf8')) as {
    runner: string
    commands: number
    ok: number
    coveragePercent: number
    passed: boolean
    byStatus: Record<string, number>
    failures: Array<{ cmd: string; status: string; detail?: string }>
  }
  assert.equal(report.runner, 'just-bash')
  assert.equal(report.commands, 428)
  assert.equal(report.passed, true)
  assert.ok(report.coveragePercent >= 95, `coverage was ${String(report.coveragePercent)}%`)
  assert.ok(report.ok >= Math.ceil(report.commands * 0.95), `only ${String(report.ok)} of ${String(report.commands)} commands ran`)
  assert.equal(report.byStatus['command-missing'] ?? 0, 0)
  assert.equal(report.byStatus['syntax-unsupported'] ?? 0, 0)
  // The only expected misses are the three commands the corpus deliberately
  // classifies as non-zero: `! true` (status 1) and curl -X PUT/DELETE (the
  // shim refuses methods outside GET/HEAD/POST).
  assert.ok(report.failures.length <= 5, JSON.stringify(report.failures))
  for (const failure of report.failures) {
    assert.match(failure.cmd, /^! true$|curl .* -X (PUT|DELETE)/)
  }
})
