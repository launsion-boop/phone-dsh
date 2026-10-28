// SPDX-License-Identifier: MIT
/**
 * Gate bootstrap for the dependencies W5-SHELL adds to `plugins`.
 *
 * `wasi-toolbox/tools/ensure-dev-deps.mjs` (outside this package's write scope)
 * decides readiness from `typescript` and `@types/node` alone. A worktree that
 * already had those two installed before `just-bash` and the
 * `@phone-dsh/*` workspace links were added therefore skipped `npm ci`, and
 * `tsc` failed with `TS2307`. This hook checks the packages this work package
 * resolved into the lockfile and falls back to the pinned `npm ci` when any of
 * them is missing.
 *
 * It installs only versions already pinned by `plugins/package-lock.json`;
 * it never edits `package.json` or `package-lock.json`.
 */
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const packageRoot = fileURLToPath(new URL('../../', import.meta.url))
const fromRoot = (relative) => fileURLToPath(new URL(relative, new URL('../../', import.meta.url)))

/** The new runtime dependency plus one link per workspace package. */
const required = ['node_modules/just-bash/package.json']
const manifest = JSON.parse(readFileSync(fromRoot('package.json'), 'utf8'))
for (const workspace of manifest.workspaces ?? []) {
  const workspaceManifest = JSON.parse(readFileSync(fromRoot(`${workspace}/package.json`), 'utf8'))
  required.push(`node_modules/${workspaceManifest.name}/package.json`)
}

if (required.some(entry => !existsSync(fromRoot(entry)))) {
  process.stderr.write('shell-ext: installing pinned plugins dependencies with npm ci\n')
  const install = (args) => spawnSync('npm', ['ci', '--no-audit', '--no-fund', ...args], {
    cwd: packageRoot,
    stdio: 'inherit',
  })
  let result = install([])
  if (result.error !== undefined) {
    process.stderr.write(`shell-ext: npm ci failed: ${result.error.message}\n`)
    process.exit(1)
  }
  if ((result.status ?? 1) !== 0) {
    // Some hosts have an unusable default npm cache (for example a cache that
    // still contains root-owned entries from an older npm). Retry once with a
    // cache under the system temp directory; the lockfile is unchanged.
    const cache = mkdtempSync(join(tmpdir(), 'pdsh-npm-cache-'))
    process.stderr.write('shell-ext: retrying npm ci with a temporary cache\n')
    try {
      result = install(['--cache', cache])
    } finally {
      rmSync(cache, { recursive: true, force: true })
    }
    if (result.error !== undefined) {
      process.stderr.write(`shell-ext: npm ci failed: ${result.error.message}\n`)
      process.exit(1)
    }
  }
  process.exit(result.status ?? 1)
}
