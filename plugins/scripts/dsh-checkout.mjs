#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Verify the pinned DeepSeek Harness checkout named by PDSH_DSH_CHECKOUT.
 *
 * The verifier is deliberately read-only: it runs `git rev-parse HEAD` and
 * `git status --porcelain -z --untracked-files=all` inside the checkout,
 * compares HEAD with `dsh-pin.json`, and checks that the built runtime and
 * packer artifacts the image tooling imports are present.
 *
 * Cleanliness is judged by what the packer can read. Any tracked modification
 * anywhere fails verification. An untracked file fails verification when it
 * lies under a root the packer materializes (`apps/`, `native/`, `packages/`,
 * `vendor/`), because `indexWorkspacePackages`, package `files` allowlists,
 * config trees, and the installation manifest all read the live filesystem:
 * an extra file there can enter the image while HEAD still matches the pin.
 * Unrelated untracked scratch files outside those roots cannot affect the
 * image and are reported in the facts without making the checkout dirty.
 *
 * Usage:
 *   PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --verify
 *   PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --print-json
 *   PDSH_DSH_CHECKOUT=<checkout> node scripts/dsh-checkout.mjs --print-json \
 *     --commit <40-hex> --version <version>
 *
 * The checkout path is read from the environment and never written into the
 * repository. `--commit`/`--version` form a controlled override pair: both are
 * required and the checkout must be clean, built, and at exactly that HEAD and
 * installation version. The facts keep the expected pair as `pin` and the
 * unmodified `dsh-pin.json` values as `canonicalPin`, so callers can record
 * both sides of the override.
 *
 * The script exits 2 on usage errors and 1 when verification fails.
 * @module @phone-dsh/dsh-plugins/scripts/dsh-checkout
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Absolute path of the pin file shipped beside this script's parent. */
export const PIN_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', 'dsh-pin.json')

/**
 * Built artifacts `--verify` requires. The runtime files are copied into the
 * image output; the packer, app-boot, and runtime library entry points are
 * imported by `pack-image.mjs` (the runtime library also supplies the lowering
 * oracle used to validate every packed plug-in face).
 */
export const REQUIRED_BUILDS = Object.freeze([
  'packages/experimental/webworker-runtime/lib/worker.js',
  'packages/experimental/webworker-runtime/lib/client.js',
  'packages/experimental/webworker-runtime/lib/index.js',
  'packages/experimental/webworker-packer/lib/index.js',
  'packages/experimental/webworker-packer/lib/bin.js',
  'packages/boot/app-boot/lib/index.js',
  // The image asserts its browser roster by composing window.__DSH_BOOT__ with
  // the checkout's own client-modules node half.
  'packages/client/modules/lib/index.js',
])

/**
 * Repository roots the image packer reads. These are the packer's own workspace
 * scan roots (`vendor`, `packages`, `native/system/packages`, `apps`); the
 * installation manifest and config trees also live under `apps`. An untracked
 * file below one of them can change the packed image, so it counts as dirty.
 */
export const MATERIALIZED_ROOTS = Object.freeze(['apps', 'native', 'packages', 'vendor'])

/** Verification failure with a user-facing message. */
export class CheckoutError extends Error {
  /** @param message - human-readable failure. */
  constructor(message) {
    super(message)
    this.name = 'CheckoutError'
  }
}

/**
 * Read and validate the pin document.
 * @param file - pin file; defaults to the repository's `dsh-pin.json`.
 * @returns The parsed pin.
 * @throws {CheckoutError} When the file is missing or malformed.
 */
export function readPin(file = PIN_PATH) {
  let parsed
  try {
    parsed = JSON.parse(readFileSync(file, 'utf8'))
  } catch (reason) {
    throw new CheckoutError(`cannot read pin ${file}: ${reason instanceof Error ? reason.message : String(reason)}`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new CheckoutError(`pin ${file} must hold a JSON object`)
  }
  for (const key of ['repo', 'commit', 'version']) {
    if (typeof parsed[key] !== 'string' || parsed[key] === '') {
      throw new CheckoutError(`pin ${file} is missing the string field ${JSON.stringify(key)}`)
    }
  }
  if (!/^[0-9a-f]{40}$/.test(parsed.commit)) {
    throw new CheckoutError(`pin ${file} commit must be a full 40-character lowercase hex sha`)
  }
  return /** @type {{repo: string, commit: string, version: string}} */ (parsed)
}

/**
 * Run one git command inside a checkout.
 * @param checkout - absolute checkout directory.
 * @param args - git arguments after the explicit `-C`.
 * @param options - `trim: false` keeps NUL delimiters and trailing bytes for
 *   machine-readable status output.
 * @returns stdout.
 * @throws {CheckoutError} When git fails.
 */
function git(checkout, args, { trim = true } = {}) {
  try {
    const output = execFileSync('git', ['-C', checkout, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    return trim ? output.trimEnd() : output
  } catch (reason) {
    const stderr = typeof reason?.stderr === 'string' ? reason.stderr.trim() : ''
    throw new CheckoutError(`git ${args.join(' ')} failed in ${checkout}${stderr === '' ? '' : `: ${stderr}`}`)
  }
}

/**
 * Whether a repository-relative path lies under a root the image packer reads.
 * @param file - path from `git status`, always `/`-separated in porcelain v1.
 * @returns True for `packages/x`, false for a root-level scratch file.
 */
export function underMaterializedRoot(file) {
  return MATERIALIZED_ROOTS.some(root => file === root || file.startsWith(`${root}/`))
}

/**
 * Parse NUL-delimited porcelain v1 output.
 *
 * `-z` never quotes paths, so spaces and newlines stay literal. A rename or
 * copy entry is followed by the original path as a separate NUL field; only
 * the current path participates in the clean-tree decision.
 * @param output - `git status --porcelain=v1 -z` stdout.
 * @returns Parsed entries with the two status bytes and the current path.
 */
export function parseStatus(output) {
  const entries = []
  const fields = output.split('\0')
  for (let index = 0; index < fields.length; index += 1) {
    const field = fields[index]
    if (field === undefined || field === '') continue
    const status = field.slice(0, 2)
    const file = field.slice(3)
    if (status.includes('R') || status.includes('C')) index += 1
    if (file !== '') entries.push({ status, path: file })
  }
  return entries
}

/**
 * Verify one checkout against a pin.
 * @param options - Verification inputs.
 * @param options.checkout - checkout directory from PDSH_DSH_CHECKOUT.
 * @param options.pin - expected pin to enforce; defaults to the repository's
 *   pin file. A controlled override replaces its commit/version.
 * @param options.canonicalPin - the unmodified pin document recorded beside an
 *   override; defaults to `pin` when the caller has no separate canonical pin.
 * @param options.requiredBuilds - build artifacts to require.
 * @returns Facts about the verified checkout, including untracked paths that
 *   lie outside the roots the image packer reads.
 * @throws {CheckoutError} On a missing checkout, wrong HEAD, tracked
 * modification, untracked file under a materialized root, missing build
 * artifact, or installation version mismatch.
 */
export function verifyCheckout({
  checkout,
  pin = readPin(),
  canonicalPin = pin,
  requiredBuilds = REQUIRED_BUILDS,
} = {}) {
  if (typeof checkout !== 'string' || checkout.trim() === '') {
    throw new CheckoutError(
      'PDSH_DSH_CHECKOUT is not set. Set it to the checkout of the pinned DeepSeek Harness '
      + `${pin.version} commit ${pin.commit}.`,
    )
  }
  const directory = resolve(checkout)
  if (!existsSync(directory)) {
    throw new CheckoutError(`PDSH_DSH_CHECKOUT points at ${directory}, which does not exist`)
  }

  const head = git(directory, ['rev-parse', 'HEAD'])
  if (head !== pin.commit) {
    throw new CheckoutError(
      `checkout HEAD is ${head}, but dsh-pin.json pins ${pin.commit} (${pin.version}); `
      + `check out ${pin.repo} at the pinned commit`,
    )
  }

  // Every tracked change is a deviation from the pinned tree. Untracked paths
  // are judged separately: the packer reads the live filesystem, so an
  // untracked file under a materialized root can enter the image even though
  // HEAD still names the pin.
  const status = parseStatus(git(
    directory,
    ['status', '--porcelain=v1', '-z', '--untracked-files=all'],
    { trim: false },
  ))
  const tracked = status.filter(entry => entry.status !== '??')
  if (tracked.length > 0) {
    const lines = tracked.slice(0, 20).map(entry => `${entry.status} ${entry.path}`)
    throw new CheckoutError(
      `checkout has tracked modifications, so it is not the pinned tree:\n  ${lines.join('\n  ')}`,
    )
  }
  const untracked = status.filter(entry => entry.status === '??')
  const untrackedInImage = untracked.filter(entry => underMaterializedRoot(entry.path))
  if (untrackedInImage.length > 0) {
    const lines = untrackedInImage.slice(0, 20).map(entry => `?? ${entry.path}`)
    throw new CheckoutError(
      'checkout has untracked files under a root the image packer reads '
      + `(${MATERIALIZED_ROOTS.join(', ')}), so the packed image would not match the pinned tree:\n`
      + `  ${lines.join('\n  ')}\n`
      + ' remove them or move them outside those roots',
    )
  }
  const untrackedOutsideImageRoots = untracked.map(entry => entry.path).sort()

  const missingBuilds = requiredBuilds.filter(file => !existsSync(join(directory, file)))
  if (missingBuilds.length > 0) {
    throw new CheckoutError(
      `checkout is missing built artifacts:\n  ${missingBuilds.join('\n  ')}\n`
      + 'build the runtime and packer packages in the checkout (their lib/ directories are required)',
    )
  }

  const versionFile = join(directory, 'apps', 'cli', 'package.json')
  let installationVersion
  if (existsSync(versionFile)) {
    try {
      installationVersion = JSON.parse(readFileSync(versionFile, 'utf8')).version
    } catch {
      installationVersion = undefined
    }
  }
  if (installationVersion !== undefined && installationVersion !== pin.version) {
    throw new CheckoutError(
      `checkout version is ${installationVersion}, but dsh-pin.json pins ${pin.version} `
      + `(commit ${pin.commit}); use the pinned release or update the pin deliberately`,
    )
  }

  return {
    checkout: directory,
    head,
    clean: true,
    untrackedOutsideImageRoots,
    pin: { repo: pin.repo, commit: pin.commit, version: pin.version },
    canonicalPin: {
      repo: canonicalPin.repo,
      commit: canonicalPin.commit,
      version: canonicalPin.version,
    },
    version: installationVersion,
    built: Object.fromEntries(requiredBuilds.map(file => [file, true])),
  }
}

/**
 * Whether this file is the process entry point.
 * @returns True when the CLI should run.
 */
function invokedByCli() {
  const entry = process.argv[1]
  if (entry === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(entry))
  } catch {
    return false
  }
}

function main() {
  const args = process.argv.slice(2)
  let verify = false
  let printJson = false
  let commit
  let version
  const usage = message => {
    if (message !== undefined) process.stderr.write(`dsh-checkout: ${message}\n`)
    process.stderr.write(
      'usage: PDSH_DSH_CHECKOUT=<dir> node scripts/dsh-checkout.mjs '
      + '(--verify | --print-json) [--commit <40-hex> --version <version>]\n',
    )
    process.exitCode = 2
  }
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg === '--verify') {
      verify = true
    } else if (arg === '--print-json') {
      printJson = true
    } else if (arg === '--commit' || arg === '--version') {
      const value = args[index + 1]
      if (value === undefined || value === '') {
        usage(`${arg} needs a value`)
        return
      }
      if (arg === '--commit') commit = value
      else version = value
      index += 1
    } else {
      usage(`unknown argument: ${arg}`)
      return
    }
  }
  if (verify === printJson) {
    usage('choose exactly one of --verify and --print-json')
    return
  }
  if ((commit === undefined) !== (version === undefined)) {
    usage('--commit and --version must be supplied together')
    return
  }
  if (commit !== undefined && !/^[0-9a-f]{40}$/.test(commit)) {
    usage('--commit must be a full 40-character lowercase hex sha')
    return
  }

  try {
    const pin = readPin()
    const expectedPin = commit === undefined ? pin : { ...pin, commit, version }
    const facts = verifyCheckout({
      checkout: process.env.PDSH_DSH_CHECKOUT,
      pin: expectedPin,
      canonicalPin: pin,
    })
    if (printJson) {
      process.stdout.write(`${JSON.stringify(facts, null, 2)}\n`)
      return
    }
    process.stdout.write([
      `dsh-checkout: OK (${facts.pin.version})`,
      `  checkout: ${facts.checkout}`,
      `  HEAD:     ${facts.head}`,
      ...(facts.pin.commit === facts.canonicalPin.commit
        && facts.pin.version === facts.canonicalPin.version
        ? []
        : [`  override: expected ${facts.pin.version} ${facts.pin.commit}, actual ${facts.version} ${facts.head}`]),
      `  built:    ${Object.keys(facts.built).length} artifact(s) present`,
      ...facts.untrackedOutsideImageRoots.length === 0
        ? []
        : [`  ignored:  ${facts.untrackedOutsideImageRoots.length} untracked path(s) outside ${MATERIALIZED_ROOTS.join(', ')}`],
      '',
    ].join('\n'))
  } catch (reason) {
    process.stderr.write(`dsh-checkout: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    process.exitCode = 1
  }
}

if (invokedByCli()) main()
