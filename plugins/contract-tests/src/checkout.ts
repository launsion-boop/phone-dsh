// SPDX-License-Identifier: MIT
/**
 * Resolve and inspect the DeepSeek Harness checkout the contract suite runs
 * against. The path is only ever read at runtime: it comes from `--checkout`,
 * `PDSH_DSH_CHECKOUT`, or the per-machine `$HOME/.config/phone-dsh/dsh-checkout` file,
 * and is never written into the repository or the report.
 * @module @phone-dsh/dsh-contract-tests/checkout
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Where the checkout path came from. */
export type CheckoutSource = 'argument' | 'PDSH_DSH_CHECKOUT' | 'home-file'

/** A resolved checkout directory and the selector that supplied it. */
export interface ResolvedCheckout {
  /** Absolute checkout directory, used only for reads and bundling. */
  readonly directory: string
  /** Which selector supplied the path; safe to print and record. */
  readonly source: CheckoutSource
}

/** Facts about the checkout that are safe to put in a report. */
export interface CheckoutInfo {
  /** Version field of the checkout's root package manifest, when present. */
  readonly version: string | undefined
  /** Full commit of the checkout, when it is a git work tree. */
  readonly commit: string | undefined
  /** Whether the commit equals the repository pin; undefined when either is unknown. */
  readonly pinMatch: boolean | undefined
}

/**
 * Read a JSON object without throwing.
 * @param file - absolute file to read.
 * @returns the parsed object, or undefined when the file is absent or malformed.
 */
function readJsonObject(file: string): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, 'utf8'))
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    return undefined
  }
  return undefined
}

/** Path of this repository's DSH pin, resolved relative to this module. */
function pinPath(): string {
  return join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'dsh-pin.json')
}

/**
 * Read the repository's DSH pin.
 * @returns the pinned commit and version, or undefined when the file is unusable.
 */
export function readPin(): { commit: string; version: string } | undefined {
  const parsed = readJsonObject(pinPath())
  if (parsed === undefined) return undefined
  const commit = parsed['commit']
  const version = parsed['version']
  if (typeof commit !== 'string' || typeof version !== 'string') return undefined
  return { commit, version }
}

/**
 * Read the first non-empty line of a file.
 * @param file - file to read.
 * @returns the trimmed line, or undefined when the file is absent or empty.
 */
function firstLine(file: string): string | undefined {
  try {
    const line = readFileSync(file, 'utf8').split('\n').map(value => value.trim()).find(value => value !== '')
    return line
  } catch {
    return undefined
  }
}

/**
 * Resolve the checkout the suite should run against.
 *
 * Order: the explicit argument, `PDSH_DSH_CHECKOUT`, then the single line of
 * `$HOME/.config/phone-dsh/dsh-checkout`.
 * @param explicit - value of `--checkout`, when given.
 * @returns the absolute directory and where it came from.
 * @throws when no selector is set or the directory is not a DSH checkout.
 */
export function resolveCheckout(explicit: string | undefined): ResolvedCheckout {
  let directory: string | undefined
  let source: CheckoutSource = 'argument'
  if (explicit !== undefined && explicit.trim() !== '') {
    directory = explicit.trim()
  } else {
    const fromEnvironment = process.env.PDSH_DSH_CHECKOUT
    if (fromEnvironment !== undefined && fromEnvironment.trim() !== '') {
      directory = fromEnvironment.trim()
      source = 'PDSH_DSH_CHECKOUT'
    } else {
      directory = firstLine(join(homedir(), '.config', 'xl', 'dsh-checkout'))
      source = 'home-file'
    }
  }
  if (directory === undefined || directory === '') {
    throw new Error(
      'no DeepSeek Harness checkout: pass --checkout <dir>, set PDSH_DSH_CHECKOUT, '
      + 'or write its path to $HOME/.config/phone-dsh/dsh-checkout',
    )
  }
  const requested = resolve(directory)
  if (!existsSync(requested) || !statSync(requested).isDirectory()) {
    throw new Error('the DeepSeek Harness checkout does not exist or is not a directory')
  }
  // Resolve symlinks in the root itself. esbuild resolves imported files to
  // their real paths, so a symlinked checkout root would otherwise load the
  // same module twice (once through the link and once through its target).
  let absolute = requested
  try {
    absolute = realpathSync(requested)
  } catch {
    // The directory exists; keep the requested spelling if realpath fails.
  }
  // The runtime sources are the first thing the suite imports; a directory
  // without them is not a checkout this contract can speak about.
  if (!existsSync(join(absolute, 'packages', 'experimental', 'webworker-runtime', 'src', 'index.ts'))) {
    throw new Error(
      'the checkout does not carry packages/experimental/webworker-runtime/src/index.ts, '
      + 'so it is not a DeepSeek Harness checkout',
    )
  }
  return { directory: absolute, source }
}

/**
 * Inspect the checkout's version, commit and pin agreement.
 *
 * Git is read-only here; a tarball checkout without `.git` simply reports no
 * commit instead of failing the suite.
 * @param directory - absolute checkout directory.
 * @returns safe facts for the report.
 */
export function inspectCheckout(directory: string): CheckoutInfo {
  const root = readJsonObject(join(directory, 'package.json'))
  const version = root !== undefined && typeof root['version'] === 'string' ? root['version'] : undefined
  let commit: string | undefined
  try {
    commit = execFileSync('git', ['-C', directory, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {
    commit = undefined
  }
  const pin = readPin()
  const pinMatch = pin !== undefined && commit !== undefined ? pin.commit === commit : undefined
  return { version, commit, pinMatch }
}
