/** Deterministic package build facts used by the CLI and the running plugin (§8.2/§8.3). */

import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SKIPPED_DIRECTORIES = new Set(['node_modules', 'test', '.spike'])

/**
 * Compute a deterministic SHA-256 over a package's shipped files.
 *
 * The digest is over the sorted relative path, a NUL, the decimal byte length,
 * a NUL and the file bytes. `node_modules`, `test` and `.spike` are excluded so
 * the installed package and a source checkout of the same build agree.
 * @param {string} root Package root.
 * @returns {string} lowercase hex digest.
 */
export function packageSha256(root) {
  const hash = createHash('sha256')
  const files = []
  const walk = (directory, prefix) => {
    for (const name of readdirSync(directory).sort()) {
      if (SKIPPED_DIRECTORIES.has(name)) continue
      const path = join(directory, name)
      const relative = prefix === '' ? name : `${prefix}/${name}`
      const stat = statSync(path)
      if (stat.isDirectory()) walk(path, relative)
      else if (stat.isFile()) files.push({ relative, path })
    }
  }
  walk(root, '')
  files.sort((left, right) => (left.relative < right.relative ? -1 : left.relative > right.relative ? 1 : 0))
  for (const file of files) {
    const bytes = readFileSync(file.path)
    hash.update(file.relative)
    hash.update('\0')
    hash.update(String(bytes.length))
    hash.update('\0')
    hash.update(bytes)
  }
  return hash.digest('hex')
}

/**
 * Package root of this source tree (`pclink/`).
 * @returns {string} absolute package root.
 */
export function pclinkPackageRoot() {
  return dirname(dirname(fileURLToPath(import.meta.url)))
}

/**
 * Read the package version from the root manifest, falling back to
 * `plugin/package.json` when the core is vendored separately.
 * @param {string} [root] Package root.
 * @returns {string} version or `0.0.0`.
 */
export function packageVersion(root = pclinkPackageRoot()) {
  for (const candidate of [join(root, 'package.json'), join(root, 'plugin', 'package.json')]) {
    try {
      const manifest = JSON.parse(readFileSync(candidate, 'utf8'))
      if (typeof manifest.version === 'string' && manifest.version !== '') return manifest.version
    } catch {
      // Try the next manifest.
    }
  }
  return '0.0.0'
}

/**
 * Build facts for the currently loaded code. `packageSha256` is the digest of
 * the package files on disk when this process started; it intentionally does
 * not change when an installer later replaces those files under a running
 * process (§8.2 `plugin`).
 * @param {{root?: string}} [options] Test seam.
 * @returns {{version: string, packageSha256: string}} build facts.
 */
export function pluginBuildInfo(options = {}) {
  const root = options.root ?? pclinkPackageRoot()
  const version = packageVersion(root)
  let sha = '0'.repeat(64)
  if (existsSync(root)) {
    try {
      sha = packageSha256(root)
    } catch {
      // A package layout the walker cannot read still reports a valid shape;
      // the installer sees the all-zero digest and restarts.
    }
  }
  return { version, packageSha256: sha }
}
