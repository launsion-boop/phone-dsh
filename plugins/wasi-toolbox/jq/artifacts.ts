// SPDX-License-Identifier: MIT
/**
 * Locate (or build) the jq WASI artifact the engine tests execute.
 *
 * Build products never enter the repository. An explicit `PDSH_JQ_ARTIFACTS`
 * is trusted and a broken directory fails the test; otherwise the default
 * `$TMPDIR/pdsh-jq-wasi` is used and `build.sh --check` provisions it when it
 * is absent or stale. When `cargo` is not installed the caller receives a
 * `skipReason`, so a Linux unit suite that cannot build the artifact reports
 * NOT_RUN instead of pretending the engine ran.
 * @module @phone-dsh/dsh-wasi-toolbox/jq/artifacts
 */
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { JQ_SOURCE_ALGORITHM, jqSourceReport } from './source-fingerprint.ts'

/** Executable file name `build.sh` writes. */
export const JQ_WASM_FILE = 'jq.wasm'
/** Build report file name. */
export const JQ_ENGINE_FILE = 'engine.json'
/** Digest report file name. */
export const JQ_SIZES_FILE = 'sizes.json'

const buildScript = fileURLToPath(new URL('./build.sh', import.meta.url))

/** One discovered engine artifact. */
export interface JqArtifact {
  readonly directory: string
  readonly wasm: string
  readonly engine: string
}

/** Discovery result: an artifact, or the honest reason the tests cannot run it. */
export interface JqArtifactDiscovery {
  readonly artifact?: JqArtifact
  readonly skipReason?: string
  readonly provisioned?: string
}

function usable(file: string): boolean {
  try {
    return existsSync(file) && statSync(file).isFile() && statSync(file).size > 0
  } catch {
    return false
  }
}

function sha256File(file: string): string {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

/**
 * Check both build reports against the executable and this checkout.
 *
 * A self-consistent wasm digest is not enough: the report must also name this
 * checkout's source fingerprint, and `engine.json` must describe the same
 * bytes and source as `sizes.json`. Otherwise a source edit (or a swapped
 * report) would let a test run yesterday's engine and call it PASS.
 * @param directory - artifact directory.
 * @returns undefined when consistent, else a diagnosis.
 */
function checkSizes(directory: string): string | undefined {
  const wasm = join(directory, JQ_WASM_FILE)
  const engine = join(directory, JQ_ENGINE_FILE)
  const sizes = join(directory, JQ_SIZES_FILE)
  if (!usable(sizes)) return `${sizes} is missing or empty`
  if (!usable(engine)) return `${engine} is missing or empty`
  try {
    const record = JSON.parse(readFileSync(sizes, 'utf8')) as {
      jqWasm?: { sha256?: unknown; bytes?: unknown }
      source?: { algorithm?: unknown; fingerprint?: unknown }
      engine?: unknown
    }
    const reported = JSON.parse(readFileSync(engine, 'utf8')) as {
      wasm?: { sha256?: unknown; bytes?: unknown }
      source?: { algorithm?: unknown; fingerprint?: unknown }
      engine?: unknown
    }
    const source = jqSourceReport()
    if (record.source?.algorithm !== JQ_SOURCE_ALGORITHM
      || record.source?.fingerprint !== source.fingerprint) {
      return `${sizes} source fingerprint does not match this checkout (${source.fingerprint})`
    }
    if (reported.source?.algorithm !== JQ_SOURCE_ALGORITHM
      || reported.source?.fingerprint !== source.fingerprint) {
      return `${engine} source fingerprint does not match this checkout (${source.fingerprint})`
    }
    if (typeof record.jqWasm?.sha256 !== 'string') return `${sizes} has no jqWasm.sha256`
    if (typeof record.engine !== 'string' || record.engine.trim() === '') return `${sizes} has no engine identity`
    if (typeof reported.engine !== 'string' || reported.engine.trim() === '') return `${engine} has no engine identity`
    if (record.engine !== reported.engine) return `${sizes} and ${engine} name different engines`
    const actual = sha256File(wasm)
    const bytes = statSync(wasm).size
    if (actual !== record.jqWasm.sha256) return `${wasm} sha256 ${actual} does not match ${sizes}`
    if (typeof record.jqWasm.bytes === 'number' && record.jqWasm.bytes !== bytes) {
      return `${sizes} records ${String(record.jqWasm.bytes)} bytes but ${wasm} has ${String(bytes)}`
    }
    if (reported.wasm?.sha256 !== actual) return `${engine} does not describe the wasm bytes`
    if (typeof reported.wasm?.bytes === 'number' && reported.wasm.bytes !== bytes) {
      return `${engine} records ${String(reported.wasm.bytes)} bytes but ${wasm} has ${String(bytes)}`
    }
    return undefined
  } catch (error) {
    return `${sizes} or ${engine} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`
  }
}

/**
 * Serialize provisioning of the shared default artifact directory.
 *
 * `node --test` runs test files in parallel processes. Without a lock two
 * suites both see a missing/stale default artifact and race two `build.sh`
 * runs into the same directory; one can observe the other's removed
 * `engine.json` and report the suite as skipped. The lock makes the second
 * process wait for the first and then re-check the completed pair.
 * @param lock - directory used as the mutex (created atomically with mkdir).
 * @returns true when this process owns the lock.
 */
function acquireBuildLock(lock: string): boolean {
  const deadline = Date.now() + 15 * 60_000
  while (Date.now() < deadline) {
    try {
      mkdirSync(lock)
      return true
    } catch (error) {
      if ((error as { code?: unknown }).code !== 'EEXIST') throw error
    }
    try {
      // A crashed builder must not wedge every later suite forever.
      if (Date.now() - statSync(lock).mtimeMs > 30 * 60_000) {
        rmSync(lock, { recursive: true, force: true })
        continue
      }
    } catch {
      // The lock disappeared between the failed mkdir and the stat; retry.
    }
    // The build is synchronous and the caller is synchronous, so a short
    // SharedArrayBuffer sleep is the portable wait here.
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)
  }
  return false
}

/**
 * Resolve the artifact, provisioning the default directory when needed.
 * @param options - environment and an injection seam for tests.
 * @returns an artifact or a skip reason.
 */
export function discoverJqArtifact({
  env = process.env,
  build = true,
}: {
  readonly env?: Readonly<Record<string, string | undefined>>
  readonly build?: boolean
} = {}): JqArtifactDiscovery {
  const explicit = typeof env.PDSH_JQ_ARTIFACTS === 'string' ? env.PDSH_JQ_ARTIFACTS.trim() : ''
  const directory = explicit === '' ? join(tmpdir(), 'pdsh-jq-wasi') : explicit
  const wasm = join(directory, JQ_WASM_FILE)
  const engine = join(directory, JQ_ENGINE_FILE)
  if (usable(wasm) && usable(engine)) {
    const bad = checkSizes(directory)
    if (bad !== undefined) {
      if (explicit !== '') return { skipReason: `explicit PDSH_JQ_ARTIFACTS is inconsistent: ${bad}` }
      // A stale ambient default is rebuilt below.
    } else {
      return { artifact: { directory, wasm, engine } }
    }
  }
  if (!build) return { skipReason: `no usable jq artifact in ${directory}` }
  const cargo = spawnSync('bash', ['-c', 'command -v cargo || test -x "$HOME/.cargo/bin/cargo"'], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  })
  if (cargo.status !== 0) {
    return { skipReason: `cargo is not installed, so ${wasm} cannot be built (bash ${buildScript} --check)` }
  }
  mkdirSync(directory, { recursive: true })
  const lock = join(directory, '.build-lock')
  if (!acquireBuildLock(lock)) {
    return { skipReason: `timed out waiting for another jq artifact build in ${directory}` }
  }
  try {
    // Another test process may have completed the build while we waited.
    if (usable(wasm) && usable(engine)) {
      const checked = checkSizes(directory)
      if (checked === undefined) return { artifact: { directory, wasm, engine } }
    }
    const args = explicit === '' ? ['--check'] : ['--out', directory]
    const built = spawnSync('bash', [buildScript, ...args], {
      encoding: 'utf8',
      timeout: 600_000,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    if (built.status !== 0) {
      const output = `${built.stdout ?? ''}${built.stderr ?? ''}`.trim().split('\n').slice(-6).join('\n')
      return { skipReason: `the jq artifact build failed: ${output}` }
    }
    const bad = checkSizes(directory)
    if (bad !== undefined) return { skipReason: `the built jq artifact is inconsistent: ${bad}` }
    return {
      artifact: { directory, wasm, engine },
      provisioned: explicit === '' ? `built ${directory} with build.sh --check` : `built ${directory} with build.sh --out`,
    }
  } finally {
    rmSync(lock, { recursive: true, force: true })
  }
}

/** Directory name used by tests for diagnostics. */
export function jqArtifactDirectory(env: Readonly<Record<string, string | undefined>> = process.env): string {
  const explicit = typeof env.PDSH_JQ_ARTIFACTS === 'string' ? env.PDSH_JQ_ARTIFACTS.trim() : ''
  return explicit === '' ? join(tmpdir(), 'pdsh-jq-wasi') : dirname(join(explicit, JQ_WASM_FILE))
}
