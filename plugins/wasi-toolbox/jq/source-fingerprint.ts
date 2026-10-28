// SPDX-License-Identifier: MIT
/**
 * Deterministic source identity of the jq WASI engine.
 *
 * A wasm digest only says "these bytes"; it does not say which Rust sources
 * produced them. The build report therefore carries a fingerprint over the
 * crate sources, the workspace manifests/lockfile and the build/probe scripts
 * that shape the artifact. The shell build (`build.sh`), artifact discovery,
 * the image packer and the Worker boot all read this one module, so a stale
 * artifact cannot be advertised after a source edit.
 *
 * The fingerprint is content based: paths are repository-relative and
 * newline-normalised separators are used, so the same checkout gives the same
 * value on macOS and Linux regardless of mtimes.
 * @module @phone-dsh/dsh-wasi-toolbox/jq/source-fingerprint
 */
import { createHash } from 'node:crypto'
import { existsSync, lstatSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Fingerprint algorithm name recorded in every report. */
export const JQ_SOURCE_ALGORITHM = 'pdsh-jq-source-v1'

/** Repository root, derived from this file's location. */
export const JQ_SOURCE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')

/** One source file bound into the artifact. */
export interface JqSourceFile {
  readonly path: string
  readonly sha256: string
}

/** Deterministic source identity carried by `engine.json`/`sizes.json`. */
export interface JqSourceReport {
  readonly algorithm: string
  readonly fingerprint: string
  readonly files: readonly JqSourceFile[]
}

/** Files outside the crate directory that own its build inputs. */
const ROOT_FILES: readonly string[] = Object.freeze([
  'shell/Cargo.toml',
  'shell/Cargo.lock',
  'shell/rust-toolchain.toml',
  'plugins/wasi-toolbox/jq/build.sh',
  'plugins/wasi-toolbox/jq/verify.mjs',
  'plugins/wasi-toolbox/jq/source-fingerprint.ts',
])

/** Directories under the crate that never contribute to the artifact. */
const IGNORED_DIRECTORIES = new Set(['target', '.git', 'node_modules'])

function sha256(bytes: Uint8Array | string): string {
  return createHash('sha256').update(bytes).digest('hex')
}

function walk(directory: string, root: string, out: string[]): void {
  for (const name of readdirSync(directory).sort()) {
    if (IGNORED_DIRECTORIES.has(name)) continue
    const path = resolve(directory, name)
    const info = lstatSync(path)
    if (info.isSymbolicLink()) throw new Error(`jq source contains a symbolic link: ${path}`)
    if (info.isDirectory()) {
      walk(path, root, out)
      continue
    }
    if (info.isFile() && (name === 'Cargo.toml' || name.endsWith('.rs'))) {
      out.push(relative(root, path).replaceAll('\\', '/'))
    }
  }
}

/**
 * Collect the exact source paths that bind one built artifact.
 * @param root - repository root.
 * @returns sorted, repository-relative paths.
 */
export function jqSourcePaths(root = JQ_SOURCE_ROOT): string[] {
  const paths: string[] = []
  for (const path of ROOT_FILES) {
    const absolute = resolve(root, path)
    if (existsSync(absolute)) paths.push(path)
  }
  const crate = resolve(root, 'shell/crates/pdsh-jaq-wasm')
  if (!existsSync(crate)) throw new Error(`jq source crate is missing: ${crate}`)
  walk(crate, root, paths)
  const cargoConfig = resolve(root, 'shell/.cargo/config.toml')
  if (existsSync(cargoConfig)) paths.push('shell/.cargo/config.toml')
  return [...new Set(paths)].sort()
}

/**
 * Compute the source report for one checkout.
 * @param root - repository root.
 * @returns algorithm, fingerprint and the per-file digests.
 */
export function jqSourceReport(root = JQ_SOURCE_ROOT): JqSourceReport {
  const files = jqSourcePaths(root).map(path => ({
    path,
    sha256: sha256(readFileSync(resolve(root, path))),
  }))
  const hash = createHash('sha256')
  hash.update(`${JQ_SOURCE_ALGORITHM}\n`)
  for (const file of files) hash.update(`${file.path}\0${file.sha256}\n`)
  return {
    algorithm: JQ_SOURCE_ALGORITHM,
    fingerprint: hash.digest('hex'),
    files,
  }
}

/**
 * The fingerprint alone, for reports that do not need the file list.
 * @param root - repository root.
 * @returns the hex digest.
 */
export function jqSourceFingerprint(root = JQ_SOURCE_ROOT): string {
  return jqSourceReport(root).fingerprint
}

/**
 * Explain why a report does not describe the current checkout.
 *
 * A malformed or missing source block is an error, not a pass: an artifact
 * from before source binding existed cannot be reused.
 * @param report - parsed `sizes.json` or `engine.json`.
 * @param root - repository root.
 * @returns undefined when it matches, else a diagnosis.
 */
export function jqSourceMismatch(report: unknown, root = JQ_SOURCE_ROOT): string | undefined {
  if (typeof report !== 'object' || report === null || Array.isArray(report)) {
    return 'the jq source report is not a JSON object'
  }
  const source = (report as { source?: unknown }).source
  if (typeof source !== 'object' || source === null || Array.isArray(source)) {
    return 'the report carries no source fingerprint'
  }
  const record = source as { algorithm?: unknown; fingerprint?: unknown }
  if (record.algorithm !== JQ_SOURCE_ALGORITHM) {
    return `the report source algorithm is ${JSON.stringify(record.algorithm)}, expected ${JQ_SOURCE_ALGORITHM}`
  }
  if (typeof record.fingerprint !== 'string' || !/^[0-9a-f]{64}$/u.test(record.fingerprint)) {
    return 'the report source fingerprint is not a sha256 hex digest'
  }
  const actual = jqSourceReport(root)
  if (record.fingerprint !== actual.fingerprint) {
    return `the report source fingerprint ${record.fingerprint} does not match this checkout ${actual.fingerprint}`
  }
  return undefined
}

const invokedAsScript = process.argv[1] !== undefined
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (invokedAsScript) {
  const args = process.argv.slice(2)
  const value = (name: string): string | undefined => {
    const index = args.indexOf(name)
    return index === -1 ? undefined : args[index + 1]
  }
  const root = value('--root') ?? JQ_SOURCE_ROOT
  if (args.includes('--fingerprint')) {
    process.stdout.write(`${jqSourceFingerprint(root)}\n`)
  } else {
    process.stdout.write(`${JSON.stringify(jqSourceReport(root), null, 2)}\n`)
  }
}
