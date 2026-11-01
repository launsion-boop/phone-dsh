// SPDX-License-Identifier: MIT
/**
 * Tests for the worker-bundle staleness gate.
 *
 * Every case builds a throwaway repository under `os.tmpdir()` with controlled
 * mtimes, then the CLI cases run the gate exactly as CI does: one `node`
 * process with `--root`. The last case runs the shipped gate against the real
 * repository, which keeps the real `Bundle/worker` state under the same rule
 * (it SKIPs when the gitignored bundle is absent).
 * @module @phone-dsh/dsh-plugins/scripts/check-bundle-freshness.test
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  ARTIFACTS,
  BUNDLE_DIR,
  checkBundleFreshness,
  formatResult,
  newestSource,
  sourceRoots,
} from './check-bundle-freshness.mjs'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const gatePath = join(scriptDirectory, 'check-bundle-freshness.mjs')
const repoRoot = dirname(dirname(scriptDirectory))

/** @type {string[]} */
const scratchDirectories = []

after(() => {
  for (const directory of scratchDirectories) rmSync(directory, { recursive: true, force: true })
})

/** A fixed clock so a case never depends on the wall clock (seconds since epoch). */
const T0 = 1_700_000_000
const OLD = T0
const NEW = T0 + 60

/** Write one file and set its mtime. */
function writeFile(path, text, mtimeSeconds) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text)
  utimesSync(path, mtimeSeconds, mtimeSeconds)
}

/**
 * A throwaway repository with the real layout: plugin sources and the bundle.
 * @param {object} options - which sources/artifacts to create and their mtimes.
 * @returns {string} the repository root.
 */
function fixture({ sourceMtime = OLD, artifactMtime = NEW, artifacts = ['worker-entry.js'] } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-bundle-fresh-'))
  scratchDirectories.push(root)
  writeFile(join(root, 'plugins/worker-entry/src/entry.ts'), 'export {}\n', sourceMtime)
  writeFile(join(root, 'plugins/shell-ext/src/bridge.ts'), 'export {}\n', sourceMtime)
  for (const artifact of artifacts) {
    writeFile(join(root, BUNDLE_DIR, artifact), '// artifact\n', artifactMtime)
  }
  return root
}

test('a bundle newer than every source is fresh', () => {
  const root = fixture()
  const results = checkBundleFreshness(root, ['worker-entry.js', 'image.tar.gz'])
  assert.deepEqual(results.map(result => [result.artifact, result.status]), [
    ['worker-entry.js', 'fresh'],
    ['image.tar.gz', 'absent'],
  ])
  assert.match(formatResult(results[0]), /^PASS bundle-freshness worker-entry\.js/u)
  assert.match(formatResult(results[0]), /plugins\/(?:worker-entry|shell-ext)\/src\//u)
  assert.match(formatResult(results[1]), /^SKIP bundle-freshness image\.tar\.gz/u)
})

test('an artifact older than its newest source is stale and names the file and the rebuild', () => {
  // The source edit lands after the build: exactly the incident this gate exists
  // for. The gate must name the artifact, the source *file* and the command.
  const root = fixture({ sourceMtime: NEW, artifactMtime: OLD })
  // One clear newest file, so the reported path is deterministic.
  writeFile(join(root, 'plugins/shell-ext/src/bridge.ts'), 'export {}\n', OLD)
  const [result] = checkBundleFreshness(root, ['worker-entry.js'])
  assert.equal(result.status, 'stale')
  assert.equal(result.source.path, 'plugins/worker-entry/src/entry.ts')
  const line = formatResult(result)
  assert.match(line, /^FAIL bundle-freshness worker-entry\.js: artifact /u)
  assert.match(line, /is older than plugins\/worker-entry\/src\/entry\.ts /u)
  assert.match(line, /rebuild: node plugins\/worker-entry\/build\.mjs --out examples\/probe-app\/Bundle\/worker$/u)
})

test('the image has its own rebuild command', () => {
  const root = fixture({ sourceMtime: NEW, artifactMtime: OLD, artifacts: ['image.tar.gz'] })
  const [result] = checkBundleFreshness(root, ['image.tar.gz'])
  assert.equal(result.status, 'stale')
  assert.match(formatResult(result), /rebuild: node plugins\/scripts\/pack-image\.mjs /u)
})

test('a worker-entry edit demands a rebuild of the bundle, not a 25 MB image repack', () => {
  // pack-image excludes the workspace `worker-entry` package, so a newer file
  // there cannot change image.tar.gz; telling the operator to repack would be a
  // wrong (and expensive) instruction.
  const root = fixture({ sourceMtime: OLD, artifactMtime: NEW, artifacts: ['worker-entry.js', 'image.tar.gz'] })
  writeFile(join(root, 'plugins/worker-entry/src/entry.ts'), 'export {}\n', NEW + 60)
  const [entry, image] = checkBundleFreshness(root, ['worker-entry.js', 'image.tar.gz'])
  assert.equal(entry.status, 'stale')
  assert.equal(image.status, 'fresh')
})

test('tests and documentation do not make an artifact stale', () => {
  // Rebuilding is required for a code change, not for a test or a README edit;
  // otherwise the gate would be red for every test-only commit and get ignored.
  const root = fixture({ sourceMtime: OLD, artifactMtime: NEW })
  writeFile(join(root, 'plugins/shell-ext/src/bridge.test.ts'), '// test\n', NEW + 60)
  writeFile(join(root, 'plugins/worker-entry/src/README.md'), '# docs\n', NEW + 60)
  writeFile(join(root, 'plugins/worker-entry/src/entry.ts.map'), '{}\n', NEW + 60)
  const [result] = checkBundleFreshness(root, ['worker-entry.js'])
  assert.equal(result.status, 'fresh')
})

test('source discovery covers every plugins package plus the staged faces', () => {
  const root = fixture()
  writeFile(join(root, 'plugins/profile/phone.worker.cordis.patch.yml'), 'x: 1\n', OLD)
  writeFile(join(root, 'plugins/wasi-toolbox/python/tool-worker-python.ts'), 'export {}\n', NEW + 120)
  const roots = sourceRoots(root)
  assert.ok(roots.includes('plugins/worker-entry/src'))
  assert.ok(roots.includes('plugins/shell-ext/src'))
  assert.ok(roots.includes('plugins/profile'), 'the staged image patch is a source')
  assert.ok(roots.includes('plugins/wasi-toolbox/python'), 'the python tool worker source is a source')
  assert.equal(newestSource(root).path, 'plugins/wasi-toolbox/python/tool-worker-python.ts')
})

test('the CLI exits 1 on a stale bundle and 0 on a fresh one', () => {
  const stale = fixture({ sourceMtime: NEW, artifactMtime: OLD, artifacts: [...ARTIFACTS] })
  const failed = spawnSync(process.execPath, [gatePath, '--root', stale], { encoding: 'utf8' })
  assert.equal(failed.status, 1, `expected exit 1, got ${String(failed.status)}: ${failed.stdout}${failed.stderr}`)
  assert.match(failed.stdout, /^FAIL bundle-freshness worker-entry\.js:/mu)
  assert.match(failed.stdout, /^bundle-freshness: \d+ fresh, \d+ stale, \d+ absent$/mu)

  const fresh = fixture({ sourceMtime: OLD, artifactMtime: NEW, artifacts: [...ARTIFACTS] })
  const passed = spawnSync(process.execPath, [gatePath, '--root', fresh], { encoding: 'utf8' })
  assert.equal(passed.status, 0, `expected exit 0, got ${String(passed.status)}: ${passed.stdout}${passed.stderr}`)
  assert.match(passed.stdout, /^PASS bundle-freshness image\.tar\.gz /mu)
})

test('an empty checkout (no gitignored bundle) is SKIP, never a failure', () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-bundle-fresh-'))
  scratchDirectories.push(root)
  writeFile(join(root, 'plugins/worker-entry/src/entry.ts'), 'export {}\n', NEW)
  const result = spawnSync(process.execPath, [gatePath, '--root', root], { encoding: 'utf8' })
  assert.equal(result.status, 0, `a clean checkout must not fail: ${result.stdout}${result.stderr}`)
  assert.match(result.stdout, /^SKIP bundle-freshness worker-entry\.js /mu)
})

test('the real repository state is reported by the same rule', () => {
  // BLOCKING for the next build round: this asserts the gate runs, not that the
  // bundle is fresh. A stale bundle is a finding to report, not a test failure —
  // the CI stage is what must go red, and `checkBundleFreshness` is its rule.
  const results = checkBundleFreshness(repoRoot)
  assert.deepEqual(results.map(result => result.artifact), [...ARTIFACTS])
  for (const result of results) {
    assert.ok(['fresh', 'stale', 'absent'].includes(result.status))
    assert.match(formatResult(result), /^(?:PASS|FAIL|SKIP) bundle-freshness /u)
  }
})
