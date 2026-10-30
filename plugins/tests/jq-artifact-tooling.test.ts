// SPDX-License-Identifier: MIT
/**
 * Tooling-level regression for the source-bound jq artifact.
 *
 * These tests do not need a Rust toolchain or the real engine: they build a
 * tiny WASI no-op module whose reports carry the current checkout's source
 * fingerprint, then exercise the verification/provisioning scripts. That is
 * enough to pin the two review defects:
 *
 *  - `build.sh --check` must accept a valid prebuilt artifact without cargo
 *    (verification comes before any rebuild-only toolchain requirement);
 *  - `scripts/ci/jq-artifacts.sh` must not return a stale/incomplete directory
 *    just because `jq.wasm` and `sizes.json` exist.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { jqSourceReport } from '../wasi-toolbox/jq/source-fingerprint.ts'

const root = resolve(fileURLToPath(new URL('.', import.meta.url)), '../..')
const buildScript = join(root, 'plugins/wasi-toolbox/jq/build.sh')
const artifactsScript = join(root, 'scripts/ci/jq-artifacts.sh')

/**
 * Minimal WASI command module: exports `_start`/`memory` and returns 0.
 * `verify.mjs` executes the real probe arguments only for exit status, so this
 * fixture exercises the report/source checks without pretending to be jq.
 */
const NOOP_WASM = Uint8Array.from([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
  0x03, 0x02, 0x01, 0x00,
  0x05, 0x03, 0x01, 0x00, 0x01,
  0x07, 0x13, 0x02,
  0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
  0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
  0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
])

/** Publish a self-consistent, current-source artifact pair for script tests. */
function writeArtifact(directory: string): void {
  const source = jqSourceReport(root)
  const sha256 = createHash('sha256').update(NOOP_WASM).digest('hex')
  const engine = {
    format: 2,
    engine: 'jaq-core 3.1.2 + jaq-std 3.0.4 + jaq-json 2.0.3',
    source: { algorithm: source.algorithm, fingerprint: source.fingerprint },
    toolchain: 'synthetic test fixture',
    wasm: { bytes: NOOP_WASM.byteLength, sha256 },
    probes: ['-n -c 1, 2'],
  }
  const sizes = {
    format: 2,
    engine: engine.engine,
    source,
    jqWasm: { bytes: NOOP_WASM.byteLength, sha256 },
    toolchain: 'synthetic test fixture; node test runner',
  }
  writeFileSync(join(directory, 'jq.wasm'), NOOP_WASM)
  writeFileSync(join(directory, 'engine.json'), `${JSON.stringify(engine, null, 2)}\n`)
  writeFileSync(join(directory, 'sizes.json'), `${JSON.stringify(sizes, null, 2)}\n`)
}

/**
 * PATH/HOME that contains the shell utilities the scripts need but no cargo
 * (and no `$HOME/.cargo/bin` fallback).
 */
function withoutCargo(directory: string): NodeJS.ProcessEnv {
  const bin = join(directory, 'bin')
  const home = join(directory, 'home')
  mkdirSync(bin)
  mkdirSync(home)
  for (const tool of ['bash', 'node', 'dirname', 'basename', 'mkdir', 'wc', 'tr']) {
    const found = spawnSync('bash', ['-c', `command -v ${tool}`], { encoding: 'utf8' })
    const target = found.stdout.trim()
    if (target !== '') symlinkSync(target, join(bin, tool))
  }
  return { ...process.env, HOME: home, PATH: bin }
}

test('jq source: the script entry resolves a symlinked invocation path', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-entry-'))
  try {
    const script = join(directory, 'source-fingerprint.ts')
    symlinkSync(join(root, 'plugins/wasi-toolbox/jq/source-fingerprint.ts'), script)
    const run = spawnSync(process.execPath, [
      '--no-warnings', script, '--root', root, '--fingerprint',
    ], { encoding: 'utf8' })
    assert.equal(run.status, 0, run.stderr)
    assert.equal(run.stdout.trim(), jqSourceReport(root).fingerprint)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('jq build: --check accepts a verified prebuilt artifact without cargo', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-check-tooling-'))
  try {
    writeArtifact(directory)
    const run = spawnSync('bash', [buildScript, '--out', directory, '--check'], {
      encoding: 'utf8',
      env: withoutCargo(directory),
    })
    assert.equal(run.status, 0, `${run.stdout}${run.stderr}`)
    assert.match(run.stderr, /existing artifact verified/u)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('jq build: --check rejects missing, blank and mismatched engine identity', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-engine-check-'))
  try {
    const env = withoutCargo(directory)
    const check = () => spawnSync('bash', [buildScript, '--out', directory, '--check'], {
      encoding: 'utf8',
      env,
    })
    const mutateReport = (name: string, update: (report: Record<string, unknown>) => void): void => {
      const path = join(directory, name)
      const report = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
      update(report)
      writeFileSync(path, `${JSON.stringify(report, null, 2)}\n`)
    }

    // 1. engine.json has no engine field at all.
    writeArtifact(directory)
    mutateReport('engine.json', report => { delete report.engine })
    const missing = check()
    assert.notEqual(missing.status, 0, 'an engine.json without an identity must be rejected')
    assert.match(missing.stderr, /engine\.json has no engine identity/u)

    // 2. Both reports carry only whitespace.
    writeArtifact(directory)
    mutateReport('engine.json', report => { report.engine = '   ' })
    mutateReport('sizes.json', report => { report.engine = '   ' })
    const blank = check()
    assert.notEqual(blank.status, 0, 'a blank engine identity must be rejected')
    assert.match(blank.stderr, /engine\.json has no engine identity/u)

    // 3. sizes.json lost the identity that binds its digest to the engine.
    writeArtifact(directory)
    mutateReport('sizes.json', report => { delete report.engine })
    const sizesMissing = check()
    assert.notEqual(sizesMissing.status, 0, 'sizes.json without an identity must be rejected')
    assert.match(sizesMissing.stderr, /sizes\.json has no engine identity/u)

    // 4. Both are non-empty but name different engines.
    writeArtifact(directory)
    mutateReport('sizes.json', report => { report.engine = 'jaq-core other' })
    const mismatched = check()
    assert.notEqual(mismatched.status, 0, 'mismatched engine identities must be rejected')
    assert.match(mismatched.stderr, /name different engines/u)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('jq artifacts: a stale source-bound pair is not returned as reusable', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-stale-tooling-'))
  try {
    writeArtifact(directory)
    const sizesPath = join(directory, 'sizes.json')
    const sizes = JSON.parse(readFileSync(sizesPath, 'utf8')) as {
      source: { fingerprint: string }
    }
    sizes.source.fingerprint = '0'.repeat(64)
    writeFileSync(sizesPath, `${JSON.stringify(sizes, null, 2)}\n`)

    const run = spawnSync('bash', [artifactsScript], {
      encoding: 'utf8',
      env: { ...withoutCargo(directory), PDSH_JQ_ARTIFACTS: directory },
    })
    assert.notEqual(run.status, 0, 'a stale artifact must not be returned')
    assert.equal(run.stdout.trim(), '', 'the failing resolver must not print a reusable path')
    assert.match(run.stderr, /stale or inconsistent; rebuilding/u)
    assert.match(run.stderr, /cargo is required to build or rebuild/u)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('jq artifacts: a directory without engine.json is rebuilt, never reused', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-noengine-tooling-'))
  try {
    writeArtifact(directory)
    rmSync(join(directory, 'engine.json'))
    const run = spawnSync('bash', [artifactsScript], {
      encoding: 'utf8',
      env: { ...withoutCargo(directory), PDSH_JQ_ARTIFACTS: directory },
    })
    assert.notEqual(run.status, 0, 'an artifact without engine.json must not be reused')
    assert.equal(run.stdout.trim(), '', 'the failing resolver must not print a reusable path')
    assert.match(run.stderr, /stale or inconsistent; rebuilding/u)
    assert.match(run.stderr, /cargo is required to build or rebuild/u)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
