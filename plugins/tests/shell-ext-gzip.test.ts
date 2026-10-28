// SPDX-License-Identifier: MIT
// G2-FIX-24: the Worker shell's gzip/gunzip must not treat the browser Worker's
// stubbed node:zlib as a non-fatal condition. These tests drive the production
// command table in a child process whose `node:zlib` is the upstream refusing
// stub (the exact G2-A05 host), and in a child where every backend is removed.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { gunzipSync } from 'node:zlib'
import { createWorkerCommands, isWorkerShellProgram } from '../shell-ext/src/index.ts'

const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const fixtures = join(pluginRoot, 'tests', 'fixtures')

/** The shape `WorkerShell.run()` returns inside the probe. */
interface ProbeShellResult {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
}

/** One JSON line from `tests/fixtures/gzip-probe.ts`. */
interface ProbeResult {
  readonly names: readonly string[]
  readonly gzip: ProbeShellResult
  readonly gzipBytes: readonly number[]
  readonly gunzip: ProbeShellResult
  readonly gzipD: ProbeShellResult
  readonly bare: ProbeShellResult
  readonly fileMode: ProbeShellResult
  readonly binary: ProbeShellResult
  readonly binaryInput: readonly number[]
  readonly binaryBytes: readonly number[]
  readonly invalid: ProbeShellResult
  /** Everything the child process wrote to stderr, including upstream logs. */
  readonly childStderr: string
}

interface ProbeOptions {
  /** Load the upstream `node:zlib` refusing stub through a module loader. */
  readonly zlibUnavailable?: boolean
  /** Remove `CompressionStream`/`DecompressionStream` from the child global. */
  readonly disableWeb?: boolean
}

/** Run the production command table in a child with the requested host shape. */
function runProbe(options: ProbeOptions = {}): ProbeResult {
  const args: string[] = []
  if (options.zlibUnavailable === true) args.push('--import', join(fixtures, 'zlib-unavailable-register.mjs'))
  args.push(join(fixtures, 'gzip-probe.ts'))
  const env = { ...process.env }
  if (options.disableWeb === true) env.PDSH_GZIP_PROBE_DISABLE_WEB = '1'
  else delete env.PDSH_GZIP_PROBE_DISABLE_WEB
  const child = spawnSync(process.execPath, args, {
    cwd: pluginRoot,
    encoding: 'utf8',
    timeout: 120_000,
    env,
  })
  assert.equal(
    child.status,
    0,
    `gzip probe exited ${String(child.status)}\nstdout:\n${child.stdout}\nstderr:\n${child.stderr}`,
  )
  const parsed = JSON.parse(child.stdout) as ProbeResult
  return { ...parsed, childStderr: child.stderr }
}

/** Assert the probe's gzip output is one complete member of the input text. */
function assertGzipMember(bytes: readonly number[], expected: string): void {
  assert.ok(bytes.length >= 18, `a gzip member is at least 18 bytes, got ${String(bytes.length)}`)
  assert.deepEqual(bytes.slice(0, 2), [0x1f, 0x8b], 'gzip output must start with the gzip magic')
  assert.equal(gunzipSync(Buffer.from(bytes)).toString('utf8'), expected, 'the member must decompress to the input')
}

test('gzip: gzip/gunzip/zcat are Worker shell programs, not just-bash node:zlib builtins', () => {
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  for (const program of ['gzip', 'gunzip', 'zcat']) {
    assert.equal(isWorkerShellProgram(program), true, `a direct spawn of ${program} must reach the Worker shell table`)
    assert.ok(commands.some(command => command.name === program), `createWorkerCommands must register ${program}`)
  }
})

test('gzip: a browser Worker host (node:zlib refuses) still writes a valid member and roundtrips', () => {
  const probe = runProbe({ zlibUnavailable: true })
  assert.equal(probe.gzip.exitCode, 0, `gzip failed: ${probe.gzip.stderr}`)
  assert.equal(probe.gzip.stdout, '')
  assertGzipMember(probe.gzipBytes, 'hello\n')
  assert.doesNotMatch(probe.childStderr, /web-preview: node:zlib/, 'the Web backend must not call the refusing stub')
  assert.equal(probe.gunzip.exitCode, 0, `gunzip failed: ${probe.gunzip.stderr}`)
  assert.equal(probe.gunzip.stdout, 'hello\n')
  assert.equal(probe.gzipD.exitCode, 0, `gzip -d failed: ${probe.gzipD.stderr}`)
  assert.equal(probe.gzipD.stdout, 'hello\n')
  assert.equal(probe.fileMode.exitCode, 0, `in-place gzip/gunzip failed: ${probe.fileMode.stderr}`)
  assert.equal(probe.fileMode.stdout, 'file data\n')
  assert.equal(probe.binary.exitCode, 0, `binary gzip/gunzip failed: ${probe.binary.stderr}`)
  assert.deepEqual(probe.binaryBytes, probe.binaryInput, 'gzip must preserve arbitrary byte values')
  assert.notEqual(probe.invalid.exitCode, 0, 'a non-gzip stdin must not be reported as success')
  assert.equal(probe.invalid.stdout, '')
  assert.match(probe.invalid.stderr, /gunzip: .*gzip format/)
})

test('gzip: with every backend unavailable it exits non-zero and emits no gzip bytes', () => {
  const probe = runProbe({ zlibUnavailable: true, disableWeb: true })
  assert.notEqual(probe.gzip.exitCode, 0, 'gzip must fail loud when no backend is usable')
  assert.equal(probe.gzip.stdout, '')
  assert.match(probe.gzip.stderr, /gzip: .*backend/)
  assert.equal(probe.gzipBytes.length, 0, 'a failed gzip must not leave a gzip member behind')
  assert.notEqual(probe.bare.exitCode, 0, 'the stdout form must fail loud as well')
  assert.equal(probe.bare.stdout, '')
  assert.match(probe.bare.stderr, /gzip: .*backend/)
  assert.notEqual(probe.gunzip.exitCode, 0, 'gunzip must fail loud when no backend is usable')
  assert.equal(probe.gunzip.stdout, '')
})

test('gzip: node:zlib remains an optional backend when Web Compression Streams are absent', () => {
  const probe = runProbe({ disableWeb: true })
  assert.equal(probe.gzip.exitCode, 0, `gzip failed: ${probe.gzip.stderr}`)
  assertGzipMember(probe.gzipBytes, 'hello\n')
  assert.equal(probe.gunzip.exitCode, 0, `gunzip failed: ${probe.gunzip.stderr}`)
  assert.equal(probe.gunzip.stdout, 'hello\n')
  assert.equal(probe.fileMode.exitCode, 0, `in-place gzip/gunzip failed: ${probe.fileMode.stderr}`)
  assert.equal(probe.fileMode.stdout, 'file data\n')
  assert.equal(probe.binary.exitCode, 0, `binary gzip/gunzip failed: ${probe.binary.stderr}`)
  assert.deepEqual(probe.binaryBytes, probe.binaryInput, 'gzip must preserve arbitrary byte values')
})
