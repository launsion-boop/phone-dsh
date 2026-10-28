// SPDX-License-Identifier: MIT
/**
 * Pick the CPython wasm32-wasi artifact pair the compression regression tests
 * may execute.
 *
 * Build products never enter the repository, so the tests can only run the
 * import and `tarfile` programs when a pair is available. The precedence is
 * the same as `build.sh` and `runtime.test.ts`:
 *
 *   1. `PDSH_PYTHON_WASM` (with `PDSH_PYTHON_STDLIB`, defaulting to the
 *      `python313.zip` sibling) — an explicit file selection is trusted and a
 *      bad artifact makes the tests fail loudly;
 *   2. `PDSH_PYTHON_ARTIFACTS` — an explicit directory selection, also trusted;
 *   3. the default `$TMPDIR/pdsh-python-wasi` build output, which is *ambient*
 *      machine state. A pair without `compression.json` is a pre-fix build (or
 *      a hand-copied pair) and is skipped: a stale leftover must not turn every
 *      `npm test` into a reproduction of the original
 *      `ModuleNotFoundError: No module named 'zlib'` defect. A pair that
 *      carries both `sizes.json` and `compression.json` is a current build's
 *      claim: both files are hash-checked, and the pair is probed. Any
 *      mismatch or probe failure fails the suite instead of skipping, so a
 *      regression in the stamped build is still caught. `build.sh --check`
 *      remains the loud gate for a produced artifact.
 *
 * The compression tests call {@link ensurePythonArtifacts} rather than
 * {@link discoverPythonArtifacts} directly: when the default pair is absent or
 * pre-fix, `ensure` runs the pinned `build.sh --check`, which rebuilds the
 * managed default directory and probes it. The tests therefore always execute
 * a verified interpreter (or fail loudly when the build cannot provide one),
 * instead of passing with the capability unverified because of ambient state.
 *
 * Keeping that distinction in one module makes the selection testable without
 * a real 30 MB interpreter and keeps the ambient-state policy out of the
 * individual test bodies.
 * @module @phone-dsh/dsh-wasi-toolbox/python/python-artifacts
 */
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** File name `build.sh` writes for the interpreter. */
export const PYTHON_WASM_FILE = 'python.wasm'

/** File name `build.sh` writes for the zipped standard library. */
export const PYTHON_STDLIB_FILE = 'python313.zip'

const verifyScript = fileURLToPath(new URL('./verify-compression.mjs', import.meta.url))
const buildScript = fileURLToPath(new URL('./build.sh', import.meta.url))

/** The two files that make one runnable CPython-on-WASI pair. */
export interface PythonArtifactPair {
  readonly wasm: string
  readonly stdlib: string
}

/** Result of running the compression probe against one pair. */
export interface ArtifactProbeResult {
  /** True only when every capability (import, roundtrip, tarfile w:gz) held. */
  readonly ok: boolean
  /** Last lines of the probe output, for the skip diagnostic. */
  readonly output: string
}

/** Injection seam for tests: run the capability probe on one pair. */
export type ArtifactProbe = (pair: PythonArtifactPair) => ArtifactProbeResult

/** What the compression tests should execute, or why they cannot. */
export interface PythonArtifactDiscovery {
  /** The pair to exercise; absent when the tests must skip or fail. */
  readonly pair?: PythonArtifactPair
  /** Why the tests skip; present when the default directory has no usable pair. */
  readonly skipReason?: string
  /**
   * A default artifact that *claims* to be a current build (it carries
   * `sizes.json` and `compression.json`) but fails its report check or its
   * capability probe. This must fail the suite, never be skipped: skipping
   * would hide a regression in the build that produced a stamped artifact.
   */
  readonly failure?: string
  /** True when the default pair passed the report check and the capability probe. */
  readonly probeVerified?: boolean
  /**
   * Why {@link ensurePythonArtifacts} had to run the pinned build. Present only
   * when a pair was provisioned; the compression-test log prints it so the
   * authoritative gate output names the stale state that was repaired.
   */
  readonly provisioned?: string
}

type BuildReportCheck =
  | { readonly kind: 'verified' }
  | { readonly kind: 'unverified'; readonly reason: string }
  | { readonly kind: 'invalid'; readonly reason: string }

function sha256File(file: string): string {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

function recordOf(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
}

/**
 * Check the reports `build.sh` writes beside a produced pair.
 *
 * `compression.json` only exists after the produced interpreter passed the
 * compression probe, and `sizes.json` records the size and sha256 of both
 * files. A directory without `compression.json` is a pre-fix build (or a hand
 * copied pair): that is ambient state to skip, not a regression. A directory
 * that carries both reports is a *current* build's claim and must be
 * internally consistent; a mismatch is a broken artifact and fails the suite.
 * @param directory - the `build.sh --out` directory being considered.
 * @param pair - the two files to hash and compare with `sizes.json`.
 * @returns verified, absent-because-legacy, or invalid with a reason.
 */
function checkBuildReports(directory: string, pair: PythonArtifactPair): BuildReportCheck {
  const sizesPath = join(directory, 'sizes.json')
  const compressionPath = join(directory, 'compression.json')
  if (!existsSync(compressionPath)) {
    return {
      kind: 'unverified',
      reason: 'it has no compression.json, so it predates the zlib/bz2/lzma build '
        + 'or was copied without its build report',
    }
  }
  if (!existsSync(sizesPath)) {
    return { kind: 'invalid', reason: 'compression.json is present but sizes.json is missing' }
  }

  let sizes: Record<string, unknown> | undefined
  let compression: Record<string, unknown> | undefined
  try {
    sizes = recordOf(JSON.parse(readFileSync(sizesPath, 'utf8')))
    compression = recordOf(JSON.parse(readFileSync(compressionPath, 'utf8')))
  } catch (error) {
    return { kind: 'invalid', reason: `the build reports are not valid JSON: ${String(error)}` }
  }
  if (sizes === undefined || compression === undefined) {
    return { kind: 'invalid', reason: 'the build reports are not JSON objects' }
  }

  const modules = Array.isArray(compression.modules)
    ? compression.modules.filter((entry): entry is string => typeof entry === 'string')
    : []
  const missing = ['zlib', 'bz2', 'lzma'].filter(name => !modules.includes(name))
  if (missing.length > 0) {
    return {
      kind: 'invalid',
      reason: `compression.modules is ${JSON.stringify(modules)}, missing ${missing.join(', ')}`,
    }
  }
  if (compression.tarfileGzip !== true) {
    return { kind: 'invalid', reason: 'compression.tarfileGzip is not true' }
  }

  const wasm = recordOf(sizes.pythonWasm)
  const stdlib = recordOf(sizes.pythonStdlibZip)
  if (typeof wasm?.sha256 !== 'string' || typeof stdlib?.sha256 !== 'string') {
    return { kind: 'invalid', reason: 'sizes.json does not record both file sha256 digests' }
  }
  const actualWasm = sha256File(pair.wasm)
  if (wasm.sha256 !== actualWasm) {
    return {
      kind: 'invalid',
      reason: `python.wasm sha256 is ${actualWasm}, but sizes.json records ${wasm.sha256}`,
    }
  }
  const actualStdlib = sha256File(pair.stdlib)
  if (stdlib.sha256 !== actualStdlib) {
    return {
      kind: 'invalid',
      reason: `python313.zip sha256 is ${actualStdlib}, but sizes.json records ${stdlib.sha256}`,
    }
  }
  return { kind: 'verified' }
}

/**
 * Run `verify-compression.mjs` against a pair with the current Node binary.
 * @param pair - interpreter and stdlib zip to probe.
 * @param timeoutMs - wall-clock bound for one probe.
 * @returns whether the probe passed and its trailing output.
 */
export function probeCompression(pair: PythonArtifactPair, timeoutMs = 180_000): ArtifactProbeResult {
  const result = spawnSync(
    process.execPath,
    [verifyScript, '--wasm', pair.wasm, '--stdlib', pair.stdlib],
    {
      encoding: 'utf8',
      timeout: timeoutMs,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    },
  )
  if (result.error !== undefined) return { ok: false, output: result.error.message }
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`.trim()
  return {
    ok: result.status === 0,
    output: output.split('\n').slice(-4).join('\n'),
  }
}

/**
 * Name the two files one artifact directory is expected to hold.
 * @param directory - `build.sh --out` directory (or `$TMPDIR/pdsh-python-wasi`).
 * @returns the pair of absolute-ish paths, whether or not they exist.
 */
export function artifactPairIn(directory: string): PythonArtifactPair {
  return {
    wasm: join(directory, PYTHON_WASM_FILE),
    stdlib: join(directory, PYTHON_STDLIB_FILE),
  }
}

function isUsableFile(file: string): boolean {
  try {
    return existsSync(file) && statSync(file).isFile() && statSync(file).size > 0
  } catch {
    return false
  }
}

/**
 * Resolve the artifact pair to test from the environment.
 *
 * Explicit selections (`PDSH_PYTHON_WASM`, then `PDSH_PYTHON_ARTIFACTS`) are
 * returned as-is so a broken deployment fails the tests instead of silently
 * skipping. The default directory is ambient machine state: it is skipped when
 * absent, incomplete, or a legacy pre-fix build without `compression.json`;
 * a *stamped* current build is hash-checked and probed, and any inconsistency
 * is reported through {@link PythonArtifactDiscovery.failure} so the suite
 * fails loudly.
 * @param options - environment, default directory and probe override.
 * @returns the pair to run, the reason to skip, or the reason to fail.
 */
export function discoverPythonArtifacts(options: {
  env?: NodeJS.ProcessEnv
  defaultDirectory?: string
  probe?: ArtifactProbe
} = {}): PythonArtifactDiscovery {
  const env = options.env ?? process.env
  const probe = options.probe ?? (pair => probeCompression(pair))

  const explicitWasm = env.PDSH_PYTHON_WASM?.trim() ?? ''
  if (explicitWasm !== '') {
    const explicitStdlib = env.PDSH_PYTHON_STDLIB?.trim() ?? ''
    return {
      pair: {
        wasm: explicitWasm,
        stdlib: explicitStdlib === '' ? join(dirname(explicitWasm), PYTHON_STDLIB_FILE) : explicitStdlib,
      },
    }
  }

  const explicitDirectory = env.PDSH_PYTHON_ARTIFACTS?.trim() ?? ''
  if (explicitDirectory !== '') {
    return { pair: artifactPairIn(explicitDirectory) }
  }

  const directory = options.defaultDirectory ?? join(tmpdir(), 'pdsh-python-wasi')
  const pair = artifactPairIn(directory)
  const absent = [pair.wasm, pair.stdlib].filter(file => !existsSync(file))
  if (absent.length === 2) {
    return {
      skipReason: 'no built python.wasm/python313.zip; set PDSH_PYTHON_WASM or PDSH_PYTHON_ARTIFACTS, '
        + 'or run bash plugins/wasi-toolbox/python/build.sh --out "$TMPDIR/pdsh-python-wasi"',
    }
  }
  const unusable = [pair.wasm, pair.stdlib].filter(file => !isUsableFile(file))
  if (unusable.length > 0) {
    return {
      skipReason: `ignoring incomplete artifact under ${directory}: ${unusable.join(', ')} `
        + 'is missing or empty; rebuild with bash plugins/wasi-toolbox/python/build.sh',
    }
  }

  const reports = checkBuildReports(directory, pair)
  if (reports.kind === 'unverified') {
    return {
      skipReason: `ignoring unverified artifact under ${directory}: ${reports.reason}; rebuild with `
        + `bash plugins/wasi-toolbox/python/build.sh --out ${directory}`,
    }
  }
  if (reports.kind === 'invalid') {
    return {
      failure: `artifact under ${directory} has inconsistent build reports: ${reports.reason}; `
        + `rebuild with bash plugins/wasi-toolbox/python/build.sh --out ${directory}`,
    }
  }

  const probed = probe(pair)
  if (!probed.ok) {
    return {
      failure: `artifact under ${directory} is stamped as a compression-capable build, but its probe `
        + `failed: ${probed.output}; rebuild it with bash `
        + `plugins/wasi-toolbox/python/build.sh --out ${directory}`,
    }
  }
  return { pair, probeVerified: true }
}

/** What the pinned build reported when asked to produce/verify the default pair. */
export interface ArtifactBuildResult {
  /** True only when `build.sh --check` exited 0 and the pair passed its probe. */
  readonly ok: boolean
  /** Combined build/probe output, kept for the failure message. */
  readonly output: string
}

/** Injection seam for tests: produce and verify the default artifact pair. */
export type ArtifactBuilder = () => ArtifactBuildResult

/** Upper bound for one build; a cold CPython wasm build is minutes, not seconds. */
export const DEFAULT_ARTIFACT_BUILD_TIMEOUT_MS = 60 * 60 * 1000

/**
 * Run the pinned build's `--check` against its default output directory.
 *
 * With no explicit `--out`, `build.sh` treats the default directory as managed
 * state: a missing or stale pair is rebuilt and probed, and a pair that cannot
 * provide zlib/_bz2/_lzma fails the command. That is the same assertion the
 * spec gate runs (`build.sh --check && npm test`), reused here so `npm test`
 * alone cannot pass without a verified interpreter.
 * @param timeoutMs - wall-clock bound; defaults to one hour.
 * @returns whether the command passed and its trailing combined output.
 */
export function buildDefaultArtifact(timeoutMs = DEFAULT_ARTIFACT_BUILD_TIMEOUT_MS): ArtifactBuildResult {
  const result = spawnSync('bash', [buildScript, '--check'], {
    encoding: 'utf8',
    timeout: timeoutMs,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.error !== undefined) return { ok: false, output: result.error.message }
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`.trim()
  return { ok: result.status === 0, output }
}

/** Keep a build failure diagnosable without dumping thousands of log lines. */
function lastLines(output: string, count = 60): string {
  const trimmed = output.trim()
  if (trimmed === '') return ''
  const lines = trimmed.split('\n')
  if (lines.length <= count) return trimmed
  return `(last ${count} of ${lines.length} lines)\n${lines.slice(-count).join('\n')}`
}

/**
 * Resolve the pair the compression tests execute, building one if needed.
 *
 * This is {@link discoverPythonArtifacts} plus the one missing step that made
 * the old skip policy a hole: when there is no verified pair (absent, legacy
 * pre-fix, or incomplete) the pinned `build.sh --check` runs and the discovery
 * is repeated. A build failure, or a successful command that still leaves no
 * verified pair, becomes {@link PythonArtifactDiscovery.failure} so the suite
 * fails loudly; it is never a skip. An inconsistent *stamped* artifact is
 * returned as a failure without rebuilding, because that is a regression in a
 * build that claimed the capability, not ambient leftovers.
 * @param options - environment, default directory, probe and build overrides.
 * @returns the verified pair, or the reason the suite must fail.
 */
export function ensurePythonArtifacts(options: {
  env?: NodeJS.ProcessEnv
  defaultDirectory?: string
  probe?: ArtifactProbe
  build?: ArtifactBuilder
} = {}): PythonArtifactDiscovery {
  const first = discoverPythonArtifacts(options)
  if (first.pair !== undefined || first.failure !== undefined) return first

  const build = options.build ?? (() => buildDefaultArtifact())
  const built = build()
  if (!built.ok) {
    const output = lastLines(built.output)
    const tail = output === '' ? '' : `\n${output}`
    return {
      failure: 'no verified python.wasm/python313.zip for the compression tests and the pinned '
        + `build.sh --check did not produce one; refusing to pass with the capability unverified.${tail}`,
    }
  }

  const second = discoverPythonArtifacts(options)
  if (second.pair === undefined) {
    const reason = second.failure ?? second.skipReason ?? 'the pair is still unverified'
    const output = lastLines(built.output)
    const tail = output === '' ? '' : `\nbuild.sh --check output:\n${output}`
    return {
      failure: `build.sh --check exited 0 but the default artifact is still not verified: ${reason}${tail}`,
    }
  }
  return { ...second, provisioned: first.skipReason ?? 'no verified default pair' }
}
